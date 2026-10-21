'use strict';

const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const sms = require('./sms.service');
const settings = require('./settings.service');
const userService = require('./user.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { randomToken, sha256, hmac, safeEqual, randomDigits, signJwt, verifyJwt } = require('../utils/crypto');
const { badRequest, unauthorized, forbidden } = require('../utils/errors');

const PLATFORMS = ['android', 'ios', 'web', 'desktop', 'other'];

function otpHash(phone, code) {
  return hmac(config.otpSecret, `${phone}:${code}`);
}

function banError(u) {
  return forbidden('account_banned', 'Your account has been banned', {
    reason: u.ban_reason || null,
    until: u.banned_until ? new Date(u.banned_until).toISOString() : null,
  });
}

/** Lifts a temporary ban whose time has passed. Returns the (possibly updated) user row. */
async function liftExpiredBan(u) {
  if (u.status === 'banned' && u.banned_until && new Date(u.banned_until) <= new Date()) {
    await db.query(`UPDATE users SET status = 'active', ban_reason = NULL, banned_until = NULL WHERE id = $1`, [u.id]);
    return { ...u, status: 'active', ban_reason: null, banned_until: null };
  }
  return u;
}

async function requestOtp(rawPhone, ip) {
  const phone = v.normalizePhone(rawPhone);
  rateLimit.enforce(`otp:phone1m:${phone}`, 1, 60 * 1000, 'Please wait a minute before requesting another code');
  rateLimit.enforce(`otp:phone1h:${phone}`, 5, 60 * 60 * 1000, 'Too many codes requested for this number. Try later.');
  rateLimit.enforce(`otp:ip:${ip}`, 20, 60 * 60 * 1000);

  const s = await settings.getAll();
  const existing = await db.one('SELECT id FROM users WHERE phone = $1', [phone]);
  if (!existing && !s.registration_open) {
    throw forbidden('registration_closed', 'New registrations are currently closed');
  }

  const code = randomDigits(config.otp.length);
  await db.query('UPDATE otp_codes SET consumed_at = now() WHERE phone = $1 AND consumed_at IS NULL', [phone]);
  await db.query(
    `INSERT INTO otp_codes (phone, code_hash, ip, expires_at)
     VALUES ($1, $2, $3, now() + make_interval(secs => $4))`,
    [phone, otpHash(phone, code), ip || null, config.otp.ttlSec],
  );

  if (config.otp.devMode) {
    // eslint-disable-next-line no-console
    console.log(`[OTP dev mode] ${phone} → ${code}`);
  } else {
    await sms.send(phone, `Your verification code is ${code}. Do not share it with anyone.`);
  }

  return {
    phone,
    expires_in: config.otp.ttlSec,
    ...(config.otp.devMode ? { dev_code: code } : {}),
  };
}

function parseDevice(device) {
  const d = device && typeof device === 'object' ? device : {};
  return {
    name: (v.str(d.name, { field: 'device.name', max: 100 }) || '').slice(0, 100),
    platform: PLATFORMS.includes(d.platform) ? d.platform : 'other',
    appVersion: (v.str(d.app_version, { field: 'device.app_version', max: 20 }) || '').slice(0, 20),
  };
}

function issueTokens(userId, sessionId, refreshToken) {
  return {
    access_token: signJwt({ sub: userId, sid: sessionId, typ: 'access' }, config.jwtSecret, config.accessTokenTtlSec),
    refresh_token: refreshToken,
    expires_in: config.accessTokenTtlSec,
    session_id: sessionId,
  };
}

async function createSession(userId, device, ip) {
  const d = parseDevice(device);
  const refresh = randomToken(48);
  const s = await db.one(
    `INSERT INTO sessions (user_id, refresh_token_hash, device_name, platform, app_version, ip, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(days => $7)) RETURNING id`,
    [userId, sha256(refresh), d.name, d.platform, d.appVersion, ip || null, config.refreshTokenTtlDays],
  );
  return issueTokens(userId, s.id, refresh);
}

async function verifyOtp(rawPhone, rawCode, device, ip) {
  const phone = v.normalizePhone(rawPhone);
  const code = String(rawCode || '').trim();
  if (!/^\d{4,8}$/.test(code)) throw badRequest('otp_invalid', 'Enter the code you received');
  rateLimit.enforce(`otp:verify:ip:${ip}`, 30, 60 * 60 * 1000);

  const row = await db.one(
    'SELECT * FROM otp_codes WHERE phone = $1 AND consumed_at IS NULL ORDER BY id DESC LIMIT 1',
    [phone],
  );
  if (!row || new Date(row.expires_at) <= new Date()) {
    throw badRequest('otp_expired', 'This code has expired. Request a new one.');
  }
  if (row.attempts >= config.otp.maxAttempts) {
    throw badRequest('otp_too_many_attempts', 'Too many wrong attempts. Request a new code.');
  }
  if (!safeEqual(otpHash(phone, code), row.code_hash)) {
    const upd = await db.one('UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1 RETURNING attempts', [row.id]);
    throw badRequest('otp_invalid', 'Incorrect code', {
      attempts_left: Math.max(0, config.otp.maxAttempts - upd.attempts),
    });
  }
  const consumed = await db.one(
    'UPDATE otp_codes SET consumed_at = now() WHERE id = $1 AND consumed_at IS NULL RETURNING id',
    [row.id],
  );
  if (!consumed) throw badRequest('otp_expired', 'This code was already used. Request a new one.');

  let user = await db.one('SELECT * FROM users WHERE phone = $1', [phone]);
  let isNew = false;
  if (!user) {
    if (!(await settings.get('registration_open'))) {
      throw forbidden('registration_closed', 'New registrations are currently closed');
    }
    user = await db.one('INSERT INTO users (phone) VALUES ($1) ON CONFLICT (phone) DO NOTHING RETURNING *', [phone]);
    if (user) isNew = true;
    else user = await db.one('SELECT * FROM users WHERE phone = $1', [phone]);
  }
  user = await liftExpiredBan(user);
  if (userService.isBanned(user)) throw banError(user);

  const tokens = await createSession(user.id, device, ip);
  return {
    ...tokens,
    user: userService.serialize(user, user.id),
    needs_profile: isNew || !user.first_name,
  };
}

async function refresh(refreshToken, ip) {
  if (typeof refreshToken !== 'string' || refreshToken.length < 20) {
    throw unauthorized('invalid_refresh_token', 'Please log in again');
  }
  const next = randomToken(48);
  const s = await db.one(
    `UPDATE sessions SET refresh_token_hash = $2, last_active_at = now(), ip = COALESCE($3, ip),
       expires_at = now() + make_interval(days => $4)
     WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
     RETURNING id, user_id`,
    [sha256(refreshToken), sha256(next), ip || null, config.refreshTokenTtlDays],
  );
  if (!s) throw unauthorized('invalid_refresh_token', 'Please log in again');

  let user = await db.one('SELECT * FROM users WHERE id = $1', [s.user_id]);
  user = await liftExpiredBan(user);
  if (user.status === 'deleted' || userService.isBanned(user)) {
    await db.query('UPDATE sessions SET revoked_at = now() WHERE id = $1', [s.id]);
    if (user.status === 'deleted') throw unauthorized('account_deleted', 'This account was deleted');
    throw banError(user);
  }
  return issueTokens(user.id, s.id, next);
}

/**
 * Validates an access token and returns { user, sessionId }.
 * Used by the REST middleware and the Socket.IO handshake.
 */
async function authenticate(accessToken) {
  const p = verifyJwt(accessToken, config.jwtSecret);
  if (!p || p.typ !== 'access') throw unauthorized('invalid_token', 'Invalid or expired token');
  const row = await db.one(
    `SELECT u.*, s.id AS session_id, s.revoked_at AS session_revoked_at
     FROM sessions s JOIN users u ON u.id = s.user_id
     WHERE s.id = $1 AND s.user_id = $2`,
    [p.sid, p.sub],
  );
  if (!row || row.session_revoked_at) throw unauthorized('session_revoked', 'This session has ended. Please log in again.');
  if (row.status === 'deleted') throw unauthorized('account_deleted', 'This account was deleted');
  const user = await liftExpiredBan(row);
  if (userService.isBanned(user)) throw banError(user);
  return { user, sessionId: row.session_id };
}

async function logout(userId, sessionId) {
  await db.query('UPDATE sessions SET revoked_at = now() WHERE id = $1 AND user_id = $2', [sessionId, userId]);
  bus.emit('sessions:revoked', { userId, sessionIds: [sessionId], reason: 'logout' });
  return { ok: true };
}

module.exports = { requestOtp, verifyOtp, refresh, authenticate, logout, createSession };
