'use strict';

/* Two-step verification: an optional account password asked after the login code.
 * Forgot it? A reset request removes it after 7 days (unless the owner cancels it from a logged-in device). */
const config = require('../config');
const db = require('../db');
const mail = require('./mail.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { hashPassword, verifyPassword, signJwt, verifyJwt } = require('../utils/crypto');
const { badRequest, unauthorized } = require('../utils/errors');

const RESET_DAYS = 7;
const LOGIN_TTL_SEC = 15 * 60;

function checkNew(password) {
  const p = String(password || '');
  if (p.length < 6) throw badRequest('password_too_short', 'Use at least 6 characters');
  if (p.length > 128) throw badRequest('password_too_long', 'Use at most 128 characters');
  return p;
}

function status(u) {
  return {
    enabled: !!u.password_hash,
    hint: u.password_hash ? u.password_hint || '' : '',
    reset_pending_until: u.password_hash && u.password_reset_after ? new Date(u.password_reset_after).toISOString() : null,
  };
}

/** Called at login: either the password step is needed (returns a challenge) or null. Expired resets are applied here. */
async function loginChallenge(user, device) {
  if (!user.password_hash) return null;
  if (user.password_reset_after && new Date(user.password_reset_after) <= new Date()) {
    await db.query('UPDATE users SET password_hash = NULL, password_hint = NULL, password_reset_after = NULL WHERE id = $1', [user.id]);
    return null;
  }
  return {
    needs_password: true,
    login_token: signJwt({ sub: user.id, typ: '2fa', dev: device && typeof device === 'object' ? device : {} }, config.jwtSecret, LOGIN_TTL_SEC),
    hint: user.password_hint || '',
    reset_pending_until: user.password_reset_after ? new Date(user.password_reset_after).toISOString() : null,
  };
}

function readLoginToken(token) {
  const p = verifyJwt(String(token || ''), config.jwtSecret);
  if (!p || p.typ !== '2fa') throw unauthorized('login_expired', 'This login has expired. Start again.');
  return p;
}

async function userFor(token) {
  const p = readLoginToken(token);
  const u = await db.one(`SELECT * FROM users WHERE id = $1 AND status = 'active'`, [p.sub]);
  if (!u) throw unauthorized('login_expired', 'This login has expired. Start again.');
  return { u, p };
}

/** Second login step. Returns the same as a normal login. */
async function verifyLogin(token, password, device, ip) {
  const { u, p } = await userFor(token);
  rateLimit.enforce(`pwd:login:${u.id}`, 10, 60 * 60 * 1000, 'Too many attempts. Try again in an hour.');
  rateLimit.enforce(`pwd:login:ip:${ip}`, 30, 60 * 60 * 1000, 'Too many attempts. Try again in an hour.');
  if (!u.password_hash) {
    // removed meanwhile (reset finished): just log in
  } else if (!verifyPassword(String(password || ''), u.password_hash)) {
    throw badRequest('password_invalid', 'Wrong password');
  }
  if (u.password_reset_after) await db.query('UPDATE users SET password_reset_after = NULL WHERE id = $1', [u.id]);
  const auth = require('./auth.service'); // lazy: auth.service requires this file
  const userService = require('./user.service');
  const tokens = await auth.createSession(u.id, device || p.dev, ip);
  return { ...tokens, user: userService.serialize(u, u.id), needs_profile: !u.first_name };
}

/** "Forgot password": the password is removed after RESET_DAYS unless the owner logs in and cancels. */
async function requestReset(token) {
  const { u } = await userFor(token);
  if (!u.password_hash) return { ok: true, reset_pending_until: null };
  const row = await db.one(
    `UPDATE users SET password_reset_after = COALESCE(password_reset_after, now() + make_interval(days => $2))
     WHERE id = $1 RETURNING password_reset_after`,
    [u.id, RESET_DAYS],
  );
  if (u.email) {
    mail.send(u.email, 'Two-step verification reset requested',
      `Someone asked to reset the two-step verification password of your Talvio account.\n\nIf this was not you, open Talvio on a logged-in device: Settings → Privacy → Two-step verification → Cancel reset.\n\nOtherwise the password will be removed on ${new Date(row.password_reset_after).toUTCString()}.`).catch(() => {});
  }
  return { ok: true, reset_pending_until: new Date(row.password_reset_after).toISOString() };
}

// ------------------------------------------------------------------ settings (logged in)
async function get(userId) {
  return status(await db.one('SELECT * FROM users WHERE id = $1', [userId]));
}

async function requireCurrent(u, current) {
  if (!u.password_hash) return;
  rateLimit.enforce(`pwd:check:${u.id}`, 10, 60 * 60 * 1000, 'Too many attempts. Try again in an hour.');
  if (!verifyPassword(String(current || ''), u.password_hash)) throw badRequest('password_invalid', 'Current password is wrong');
}

async function set(userId, body = {}) {
  const u = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  await requireCurrent(u, body.current_password);
  const password = checkNew(body.new_password);
  const hint = v.str(body.hint, { field: 'hint', max: 64 }) || '';
  if (hint && hint.toLowerCase() === password.toLowerCase()) throw badRequest('hint_is_password', 'The hint cannot be the password');
  const row = await db.one(
    `UPDATE users SET password_hash = $2, password_hint = $3, password_set_at = now(), password_reset_after = NULL WHERE id = $1 RETURNING *`,
    [userId, hashPassword(password), hint || null],
  );
  return status(row);
}

async function remove(userId, body = {}) {
  const u = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  await requireCurrent(u, body.current_password);
  const row = await db.one(
    'UPDATE users SET password_hash = NULL, password_hint = NULL, password_reset_after = NULL WHERE id = $1 RETURNING *',
    [userId],
  );
  return status(row);
}

async function cancelReset(userId) {
  const row = await db.one('UPDATE users SET password_reset_after = NULL WHERE id = $1 RETURNING *', [userId]);
  return status(row);
}

/** Admin: remove a user's password (support case). */
async function adminDisable(userId) {
  await db.query('UPDATE users SET password_hash = NULL, password_hint = NULL, password_reset_after = NULL WHERE id = $1', [userId]);
  return { ok: true };
}

module.exports = { loginChallenge, verifyLogin, requestReset, get, set, remove, cancelReset, adminDisable, status };
