'use strict';

/**
 * "Log in with QR code" for the web / desktop app (like WhatsApp Web / Telegram Desktop).
 *
 *  1. Browser: POST /api/auth/qr → { token, qr: "chatapp://login?token=…", expires_in }  (shows it as a QR code)
 *  2. Phone (logged in) scans it: POST /api/auth/qr/scan   → device name / IP to confirm
 *                                  POST /api/auth/qr/approve (or /decline)
 *  3. Browser polls GET /api/auth/qr/status?token=…&wait=25 → { status: "approved", access_token, refresh_token, user }
 *     The tokens are handed out exactly once; the code is valid for 2 minutes.
 */
const { EventEmitter } = require('events');
const db = require('../db');
const settings = require('./settings.service');
const userService = require('./user.service');
const authService = require('./auth.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { randomToken, sha256 } = require('../utils/crypto');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const TTL_SEC = 120;
const changes = new EventEmitter();
changes.setMaxListeners(0);

function parseToken(raw) {
  const t = String(raw || '').trim().replace(/^chatapp:\/\/login\?token=/, '');
  if (!/^[A-Za-z0-9_-]{20,64}$/.test(t)) throw badRequest('invalid_qr', 'This is not a login QR code');
  return t;
}

async function create(device = {}, ip) {
  await settings.requireFeature('feature_web_login', 'Web login');
  rateLimit.enforce(`qr:new:${ip}`, 30, 10 * 60 * 1000, 'Too many login codes. Wait a few minutes.');
  const token = randomToken(24);
  const platform = ['web', 'desktop'].includes(device.platform) ? device.platform : 'web';
  const name = String(device.name || (platform === 'desktop' ? 'Desktop app' : 'Web browser')).slice(0, 100);
  await db.query(
    `INSERT INTO qr_logins (token_hash, device_name, platform, ip, expires_at) VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5))`,
    [sha256(token), name, platform, ip || null, TTL_SEC],
  );
  return { token, qr: `chatapp://login?token=${token}`, expires_in: TTL_SEC };
}

async function load(token) {
  const row = await db.one('SELECT * FROM qr_logins WHERE token_hash = $1', [sha256(token)]);
  if (!row) throw notFound('qr_not_found', 'This login code is not valid');
  return row;
}

const expired = (row) => new Date(row.expires_at) <= new Date();

/** Phone scanned the code: returns what will be logged in, so the user can confirm. */
async function scan(userId, rawToken) {
  const token = parseToken(rawToken);
  rateLimit.enforce(`qr:scan:${userId}`, 20, 10 * 60 * 1000, 'Too many attempts');
  const row = await load(token);
  if (expired(row)) throw conflict('qr_expired', 'This code has expired — refresh it on the computer');
  if (!['pending', 'scanned'].includes(row.status)) throw conflict('qr_used', 'This code was already used');
  await db.query(`UPDATE qr_logins SET status = 'scanned' WHERE id = $1 AND status = 'pending'`, [row.id]);
  changes.emit(row.token_hash);
  return { device_name: row.device_name, platform: row.platform, ip: row.ip, created_at: new Date(row.created_at).toISOString() };
}

async function approve(userId, rawToken) {
  const token = parseToken(rawToken);
  const r = await db.one(
    `UPDATE qr_logins SET status = 'approved', user_id = $2
     WHERE token_hash = $1 AND status IN ('pending', 'scanned') AND expires_at > now() RETURNING *`,
    [sha256(token), userId],
  );
  if (!r) throw conflict('qr_expired', 'This code has expired or was already used');
  changes.emit(r.token_hash);
  return { ok: true };
}

async function decline(userId, rawToken) {
  const token = parseToken(rawToken);
  const r = await db.one(`UPDATE qr_logins SET status = 'declined' WHERE token_hash = $1 AND status IN ('pending', 'scanned') RETURNING token_hash`, [sha256(token)]);
  if (r) changes.emit(r.token_hash);
  return { ok: true };
}

/** Browser side. Long-polls up to `wait` seconds for a change. Approved → creates the session once. */
async function status(rawToken, waitRaw, ip) {
  const token = parseToken(rawToken);
  const wait = Math.min(30, Math.max(0, parseInt(waitRaw, 10) || 0));
  let row = await load(token);
  if (wait > 0 && ['pending', 'scanned'].includes(row.status) && !expired(row)) {
    const before = row.status;
    await new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        changes.removeListener(row.token_hash, done);
        resolve();
      };
      const t = setTimeout(done, Math.min(wait * 1000, Math.max(0, new Date(row.expires_at) - Date.now())));
      changes.once(row.token_hash, done);
    });
    row = await load(token);
    if (row.status === before && !expired(row)) return { status: row.status };
  }
  if (['pending', 'scanned'].includes(row.status)) return { status: expired(row) ? 'expired' : row.status };
  if (row.status !== 'approved') return { status: row.status === 'consumed' ? 'used' : row.status };

  const claimed = await db.one(`UPDATE qr_logins SET status = 'consumed' WHERE id = $1 AND status = 'approved' RETURNING *`, [row.id]);
  if (!claimed) return { status: 'used' };
  const user = await db.one('SELECT * FROM users WHERE id = $1', [claimed.user_id]);
  if (!user || user.status !== 'active') throw forbidden('account_unavailable', 'This account can’t log in');
  const tokens = await authService.createSession(user.id, { name: claimed.device_name, platform: claimed.platform, app_version: 'web' }, ip);
  return { status: 'approved', ...tokens, user: userService.serialize(user, user.id) };
}

async function sweep() {
  await db.query(`DELETE FROM qr_logins WHERE expires_at < now() - interval '1 hour'`);
}

module.exports = { create, scan, approve, decline, status, sweep, parseToken, TTL_SEC };
