'use strict';

const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const sms = require('./sms.service');
const mail = require('./mail.service');
const settings = require('./settings.service');
const moderation = require('./moderation.service');
const userService = require('./user.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { randomToken, sha256, hmac, safeEqual, randomDigits, signJwt, verifyJwt } = require('../utils/crypto');
const { badRequest, unauthorized, forbidden } = require('../utils/errors');

const PLATFORMS = ['android', 'ios', 'web', 'desktop', 'other'];

function otpHash(phone, code) {
  return hmac(config.otpSecret, `${phone}:${code}`);
}

function banError(u, extra = {}) {
  return forbidden('account_banned', 'Your account has been banned', {
    reason: u.ban_reason || null,
    until: u.banned_until ? new Date(u.banned_until).toISOString() : null,
    ...extra,
  });
}

/** After a successful OTP, a banned user gets a short-lived token to file an appeal. */
async function appealExtra(u) {
  const last = await db.one(
    'SELECT status, admin_reply, created_at FROM ban_appeals WHERE user_id = $1 ORDER BY id DESC LIMIT 1',
    [u.id],
  );
  return {
    appeal_token: signJwt({ sub: u.id, typ: 'appeal' }, config.jwtSecret, 3600),
    appeal: last ? { status: last.status, reply: last.admin_reply, created_at: new Date(last.created_at).toISOString() } : null,
  };
}

/** Lifts a temporary ban whose time has passed. Returns the (possibly updated) user row. */
async function liftExpiredBan(u) {
  if (u.status === 'banned' && u.banned_until && new Date(u.banned_until) <= new Date()) {
    await db.query(`UPDATE users SET status = 'active', ban_reason = NULL, banned_until = NULL WHERE id = $1`, [u.id]);
    return { ...u, status: 'active', ban_reason: null, banned_until: null };
  }
  return u;
}

/**
 * Login codes. `target` is the normalized phone ("+92…", sent by SMS) or email address
 * (sent by email); both use the same otp_codes table and the same verification rules.
 */
async function issueCode(target, kind, ip) {
  const label = kind === 'email' ? 'email address' : 'number';
  rateLimit.enforce(`otp:phone1m:${target}`, 1, 60 * 1000, 'Please wait a minute before requesting another code');
  rateLimit.enforce(`otp:phone1h:${target}`, 5, 60 * 60 * 1000, `Too many codes requested for this ${label}. Try later.`);
  rateLimit.enforce(`otp:ip:${ip}`, 20, 60 * 60 * 1000);

  const s = await settings.getAll();
  if (kind === 'email' && !s.login_email_enabled) throw forbidden('login_method_disabled', 'Email login is turned off');
  if (kind === 'phone' && !s.login_phone_enabled) throw forbidden('login_method_disabled', 'Phone login is turned off');
  const existing = await findUserByTarget(target, kind);
  if (!existing && !s.registration_open) {
    throw forbidden('registration_closed', 'New registrations are currently closed');
  }

  const code = randomDigits(config.otp.length);
  await db.query('UPDATE otp_codes SET consumed_at = now() WHERE phone = $1 AND consumed_at IS NULL', [target]);
  await db.query(
    `INSERT INTO otp_codes (phone, code_hash, ip, expires_at)
     VALUES ($1, $2, $3, now() + make_interval(secs => $4))`,
    [target, otpHash(target, code), ip || null, config.otp.ttlSec],
  );

  if (config.otp.devMode) {
    // eslint-disable-next-line no-console
    console.log(`[OTP dev mode] ${target} → ${code}`);
  } else if (kind === 'email') {
    const m = mail.codeEmail(code);
    await mail.send(target, m.subject, m.text, m.html);
  } else {
    await sms.send(target, `Your Talvio code is ${code}. Do not share it with anyone.`);
  }

  return {
    [kind]: target,
    expires_in: config.otp.ttlSec,
    ...(config.otp.devMode ? { dev_code: code } : {}),
  };
}

function findUserByTarget(target, kind) {
  return kind === 'email'
    ? db.one('SELECT * FROM users WHERE lower(email) = $1', [target])
    : db.one('SELECT * FROM users WHERE phone = $1', [target]);
}

async function requestOtp(rawPhone, ip) {
  const phone = v.normalizePhone(rawPhone);
  // no SMS gateway on a live server: say so clearly, the app then offers email instead
  if (config.isProd && config.sms.provider === 'console') {
    throw badRequest('sms_unavailable', 'SMS verification isn’t available in your country yet. Please continue with your email address.');
  }
  if (await moderation.isPhoneBlocked(phone)) {
    throw forbidden('phone_not_allowed', 'This phone number cannot be used to sign up');
  }
  return issueCode(phone, 'phone', ip);
}

async function requestEmailCode(rawEmail, ip) {
  return issueCode(v.normalizeEmail(rawEmail), 'email', ip);
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
  alertNewLogin(userId, s.id, d).catch(() => {});
  recordLoginEvent(userId, 'login', device, ip, s.id).catch(() => {});
  return issueTokens(userId, s.id, refresh);
}

/** Login activity: every login, wrong two-step password and "code was right but the password stopped them". */
async function recordLoginEvent(userId, kind, device, ip, sessionId = null) {
  const d = parseDevice(device);
  await db.query(
    'INSERT INTO login_events (user_id, kind, session_id, ip, device_name, platform) VALUES ($1, $2, $3, $4, $5, $6)',
    [userId, kind, sessionId, ip ? String(ip).slice(0, 64) : null, d.name || null, d.platform || null],
  );
  if (kind === 'login') return;
  // someone has the login code (or is guessing the password): warn the owner on their devices
  const device2 = [d.name, d.platform].filter(Boolean).join(' · ') || 'an unknown device';
  const body = kind === 'wrong_password'
    ? `A wrong two-step password was entered on ${device2}. If this wasn't you, change your password.`
    : `Someone on ${device2} entered your login code. Your two-step password stopped them — if it wasn't you, keep your codes private.`;
  await require('./push.service').sendToUsers([userId], { title: 'Security alert', body }, { type: 'security_alert' }, { tag: `sec-${userId}` }).catch(() => {});
  bus.emit('rt:emit', { event: 'security:alert', payload: { kind, device: device2, at: new Date().toISOString() }, userIds: [userId] });
}

/** "New login on <device>": tells the account's other devices, so a stranger's login can be logged out at once. */
async function alertNewLogin(userId, sessionId, d) {
  const others = await db.many(
    'SELECT id FROM sessions WHERE user_id = $1 AND id <> $2 AND revoked_at IS NULL AND expires_at > now()',
    [userId, sessionId],
  );
  if (!others.length) return;
  const device = [d.name, d.platform].filter(Boolean).join(' · ') || 'a new device';
  bus.emit('rt:emit', {
    event: 'session:new',
    payload: { session_id: sessionId, device_name: d.name || null, platform: d.platform || null, at: new Date().toISOString() },
    sessionIds: others.map((o) => o.id),
  });
  await require('./push.service').sendToUsers(
    [userId],
    { title: 'New login to your account', body: `${device} just logged in. Not you? Open Talvio to log it out.` },
    { type: 'new_login', session_id: sessionId },
    { tag: `login-${sessionId}` },
  );
}

async function checkCode(target, rawCode, ip) {
  const code = String(rawCode || '').trim();
  if (!/^\d{4,8}$/.test(code)) throw badRequest('otp_invalid', 'Enter the code you received');
  rateLimit.enforce(`otp:verify:ip:${ip}`, 30, 60 * 60 * 1000);

  const row = await db.one(
    'SELECT * FROM otp_codes WHERE phone = $1 AND consumed_at IS NULL ORDER BY id DESC LIMIT 1',
    [target],
  );
  if (!row || new Date(row.expires_at) <= new Date()) {
    throw badRequest('otp_expired', 'This code has expired. Request a new one.');
  }
  if (row.attempts >= config.otp.maxAttempts) {
    throw badRequest('otp_too_many_attempts', 'Too many wrong attempts. Request a new code.');
  }
  if (!safeEqual(otpHash(target, code), row.code_hash)) {
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
}

async function loginWithTarget(target, kind, device, ip) {
  let user = await findUserByTarget(target, kind);
  let isNew = false;
  if (!user) {
    if (!(await settings.get('registration_open'))) {
      throw forbidden('registration_closed', 'New registrations are currently closed');
    }
    user = kind === 'email'
      ? await db.one('INSERT INTO users (email) VALUES ($1) ON CONFLICT DO NOTHING RETURNING *', [target])
      : await db.one('INSERT INTO users (phone) VALUES ($1) ON CONFLICT (phone) DO NOTHING RETURNING *', [target]);
    if (user) isNew = true;
    else user = await findUserByTarget(target, kind);
  }
  user = await liftExpiredBan(user);
  if (userService.isBanned(user)) throw banError(user, await appealExtra(user));

  // two-step verification: ask for the password before creating a session
  const challenge = await require('./password.service').loginChallenge(user, device);
  if (challenge) {
    recordLoginEvent(user.id, 'password_needed', device, ip).catch(() => {});
    return challenge;
  }

  const tokens = await createSession(user.id, device, ip);
  return {
    ...tokens,
    user: userService.serialize(user, user.id),
    needs_profile: isNew || !user.first_name,
  };
}

async function verifyOtp(rawPhone, rawCode, device, ip) {
  const phone = v.normalizePhone(rawPhone);
  await checkCode(phone, rawCode, ip);
  return loginWithTarget(phone, 'phone', device, ip);
}

async function verifyEmailCode(rawEmail, rawCode, device, ip) {
  const email = v.normalizeEmail(rawEmail);
  await checkCode(email, rawCode, ip);
  return loginWithTarget(email, 'email', device, ip);
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

module.exports = { requestOtp, verifyOtp, requestEmailCode, verifyEmailCode, refresh, authenticate, logout, createSession, recordLoginEvent };
