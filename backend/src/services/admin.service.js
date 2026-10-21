'use strict';

const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const presence = require('./presence');
const settings = require('./settings.service');
const userService = require('./user.service');
const messageService = require('./message.service');
const mediaService = require('./media.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const moderation = require('./moderation.service');
const {
  signJwt, verifyJwt, hashPassword, verifyPassword, base32Encode, verifyTotp, sha256, randomToken,
} = require('../utils/crypto');
const crypto = require('crypto');
const { badRequest, unauthorized, forbidden, notFound, conflict } = require('../utils/errors');

const ROLES = ['super_admin', 'moderator', 'support'];
const PERMISSIONS = {
  super_admin: ['*'],
  moderator: [
    'dashboard',
    'users.view',
    'users.ban',
    'users.logout',
    'users.verify',
    'reports',
    'groups.view',
    'groups.suspend',
    'logs.view',
    'media',
    'support',
    'users.export',
    'calls.view',
    'calls.manage',
  ],
  support: ['dashboard', 'users.view', 'reports.view', 'groups.view', 'support', 'calls.view'],
};

// Used to keep login timing constant when the email does not exist.
const DUMMY_HASH = hashPassword('dummy-password-for-timing');

function can(admin, perm) {
  const perms = PERMISSIONS[admin.role] || [];
  if (perms.includes('*') || perms.includes(perm)) return true;
  const area = perm.split('.')[0];
  return perms.includes(area);
}

function requirePerm(admin, perm) {
  if (!can(admin, perm)) throw forbidden('no_permission', 'Your admin role does not allow this');
}

function serializeAdmin(a) {
  return {
    id: a.id,
    email: a.email,
    name: a.name,
    role: a.role,
    is_active: a.is_active,
    last_login_at: a.last_login_at,
    created_at: a.created_at,
    two_factor: !!a.totp_enabled,
    permissions: PERMISSIONS[a.role] || [],
  };
}

async function log(adminId, action, targetType, targetId, details, ip) {
  await db.query(
    `INSERT INTO admin_logs (admin_id, action, target_type, target_id, details, ip) VALUES ($1, $2, $3, $4, $5, $6)`,
    [adminId, action, targetType || null, targetId || null, details ? JSON.stringify(details) : null, ip || null],
  );
}

function pageParams(query) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  return { limit, page, offset: (page - 1) * limit };
}

// ------------------------------------------------------------------ auth
async function login(emailRaw, password, ip, code) {
  const email = v.str(emailRaw, { field: 'email', min: 3, max: 255, required: true }).toLowerCase();
  if (typeof password !== 'string' || !password) throw badRequest('invalid_input', 'Password is required');
  rateLimit.enforce(`admin-login-ip:${ip}`, 10, 15 * 60 * 1000, 'Too many login attempts. Try again later.');
  rateLimit.enforce(`admin-login-email:${email}`, 10, 15 * 60 * 1000, 'Too many login attempts. Try again later.');

  const admin = await db.one('SELECT * FROM admins WHERE lower(email) = $1', [email]);
  const ok = verifyPassword(password, admin ? admin.password_hash : DUMMY_HASH);
  if (!admin || !ok) throw unauthorized('invalid_credentials', 'Wrong email or password');
  if (!admin.is_active) throw forbidden('admin_disabled', 'This admin account is disabled');

  if (admin.totp_enabled) {
    if (!code) throw unauthorized('two_factor_required', 'Enter the 6-digit code from your authenticator app');
    if (!verifyTotp(admin.totp_secret, code) && !(await useBackupCode(admin, code))) {
      throw unauthorized('two_factor_invalid', 'Wrong authentication code');
    }
  }

  await db.query('UPDATE admins SET last_login_at = now() WHERE id = $1', [admin.id]);
  await log(admin.id, 'admin.login', 'admin', admin.id, null, ip);
  const token = signJwt({ sub: admin.id, typ: 'admin', tv: admin.token_version }, config.adminJwtSecret, config.adminTokenTtlSec);
  return { token, expires_in: config.adminTokenTtlSec, admin: serializeAdmin(admin) };
}

async function authenticate(token) {
  const p = verifyJwt(token, config.adminJwtSecret);
  if (!p || p.typ !== 'admin') throw unauthorized('invalid_token', 'Please log in again');
  const admin = await db.one('SELECT * FROM admins WHERE id = $1', [p.sub]);
  if (!admin || !admin.is_active || admin.token_version !== p.tv) {
    throw unauthorized('invalid_token', 'Please log in again');
  }
  return admin;
}

async function changeOwnPassword(admin, body, ip) {
  if (!verifyPassword(body.current_password || '', admin.password_hash)) {
    throw badRequest('invalid_credentials', 'Current password is wrong');
  }
  const next = v.str(body.new_password, { field: 'new_password', min: 10, max: 200, trim: false, required: true });
  await db.query('UPDATE admins SET password_hash = $2, token_version = token_version + 1 WHERE id = $1', [
    admin.id,
    hashPassword(next),
  ]);
  await log(admin.id, 'admin.password_changed', 'admin', admin.id, null, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ two-factor authentication (TOTP)
async function useBackupCode(admin, code) {
  const clean = String(code || '').trim().toLowerCase().replace(/[^a-z0-9]/g, '');
  if (clean.length < 8) return false;
  const list = Array.isArray(admin.backup_codes) ? admin.backup_codes : [];
  const h = sha256(clean);
  if (!list.includes(h)) return false;
  await db.query('UPDATE admins SET backup_codes = $2 WHERE id = $1', [admin.id, JSON.stringify(list.filter((x) => x !== h))]);
  return true;
}

async function twoFactorSetup(admin) {
  if (admin.totp_enabled) throw badRequest('already_enabled', 'Two-factor authentication is already on');
  const secret = base32Encode(crypto.randomBytes(20));
  await db.query('UPDATE admins SET totp_secret = $2 WHERE id = $1', [admin.id, secret]);
  const label = encodeURIComponent(`Talvio Admin:${admin.email}`);
  return { secret, otpauth_url: `otpauth://totp/${label}?secret=${secret}&issuer=Talvio%20Admin&digits=6&period=30` };
}

async function twoFactorEnable(admin, code, ip) {
  const fresh = await db.one('SELECT * FROM admins WHERE id = $1', [admin.id]);
  if (fresh.totp_enabled) throw badRequest('already_enabled', 'Two-factor authentication is already on');
  if (!fresh.totp_secret) throw badRequest('setup_required', 'Start the setup first');
  if (!verifyTotp(fresh.totp_secret, code)) throw badRequest('two_factor_invalid', 'Wrong code — check your phone’s time and try again');
  const codes = Array.from({ length: 8 }, () => randomToken(8).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 10).padEnd(10, '0'));
  await db.query('UPDATE admins SET totp_enabled = TRUE, backup_codes = $2 WHERE id = $1', [
    admin.id,
    JSON.stringify(codes.map((c) => sha256(c))),
  ]);
  await log(admin.id, 'admin.2fa_enabled', 'admin', admin.id, null, ip);
  return { ok: true, backup_codes: codes };
}

async function twoFactorDisable(admin, body, ip) {
  if (!verifyPassword(body.password || '', admin.password_hash)) throw badRequest('invalid_credentials', 'Wrong password');
  if (!admin.totp_enabled) return { ok: true };
  if (!verifyTotp(admin.totp_secret, body.code) && !(await useBackupCode(admin, body.code))) {
    throw badRequest('two_factor_invalid', 'Wrong authentication code');
  }
  if (await settings.get('require_admin_2fa')) {
    throw forbidden('two_factor_required_by_policy', 'Two-factor authentication is required for all admins');
  }
  await db.query('UPDATE admins SET totp_enabled = FALSE, totp_secret = NULL, backup_codes = NULL WHERE id = $1', [admin.id]);
  await log(admin.id, 'admin.2fa_disabled', 'admin', admin.id, null, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ restrictions (temporary mute)
async function restrictUser(admin, userIdRaw, body = {}, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const minutes = parseInt(body.minutes, 10);
  if (!Number.isInteger(minutes) || minutes < 1 || minutes > 525600) throw badRequest('invalid_input', 'minutes must be 1–525600');
  const reason = v.str(body.reason, { field: 'reason', max: 300 }) || 'Restricted by moderators';
  const u = await db.one(`SELECT id FROM users WHERE id = $1 AND status <> 'deleted'`, [id]);
  if (!u) throw notFound('user_not_found', 'User not found');
  await db.query(
    'UPDATE users SET restricted_until = now() + make_interval(mins => $2), restrict_reason = $3 WHERE id = $1',
    [id, minutes, reason],
  );
  await log(admin.id, 'user.restrict', 'user', id, { minutes, reason }, ip);
  return { ok: true };
}

async function unrestrictUser(admin, userIdRaw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  await moderation.liftRestriction(id);
  await log(admin.id, 'user.unrestrict', 'user', id, null, ip);
  return { ok: true };
}

async function setChatVerified(admin, chatIdRaw, value, ip) {
  const id = v.id(chatIdRaw, 'chat_id');
  const verified = v.bool(value, 'verified');
  const c = await db.one(`UPDATE chats SET is_verified = $2 WHERE id = $1 AND type <> 'private' RETURNING id`, [id, verified]);
  if (!c) throw notFound('chat_not_found', 'Group or channel not found');
  const memberIds = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [id])).map((r) => r.user_id);
  bus.emit('chat:updated', { chatId: id, memberIds });
  await log(admin.id, verified ? 'group.verify' : 'group.unverify', 'chat', id, null, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ moderator notes, export, usernames, ownership
async function addNote(admin, userIdRaw, body = {}, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const text = v.str(body.text, { field: 'text', min: 1, max: 2000, required: true });
  const u = await db.one('SELECT id FROM users WHERE id = $1', [id]);
  if (!u) throw notFound('user_not_found', 'User not found');
  const n = await db.one('INSERT INTO admin_notes (user_id, admin_id, text) VALUES ($1, $2, $3) RETURNING id', [id, admin.id, text]);
  await log(admin.id, 'user.note', 'user', id, null, ip);
  return { ok: true, note_id: n.id };
}

async function deleteNote(admin, noteIdRaw) {
  const r = await db.one('DELETE FROM admin_notes WHERE id = $1 AND (admin_id = $2 OR $3) RETURNING id', [
    v.id(noteIdRaw, 'note_id'),
    admin.id,
    admin.role === 'super_admin',
  ]);
  if (!r) throw notFound('note_not_found', 'Note not found (you can delete only your own notes)');
  return { ok: true };
}

/** Everything stored about a user, for data requests (GDPR-style). */
async function exportUser(admin, userIdRaw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const data = await userService.exportData(id);
  await log(admin.id, 'user.export', 'user', id, null, ip);
  return data;
}

/** Admins may assign any free username, including reserved ones. */
async function setUsername(admin, userIdRaw, raw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const name = raw === null || raw === '' ? null : v.validateUsername(String(raw).trim().replace(/^@/, ''));
  const chatService = require('./chat.service');
  if (name && (await chatService.usernameTaken(name, { exceptUserId: id }))) throw conflict('username_taken', 'This username is already taken');
  const u = await db.one(`UPDATE users SET username = $2, updated_at = now() WHERE id = $1 AND status <> 'deleted' RETURNING id`, [id, name]);
  if (!u) throw notFound('user_not_found', 'User not found');
  bus.emit('user:updated', { userId: id });
  await log(admin.id, 'user.set_username', 'user', id, { username: name }, ip);
  return { ok: true };
}

async function transferGroupOwner(admin, chatIdRaw, body = {}, ip) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const chat = await db.one(`SELECT id FROM chats WHERE id = $1 AND type IN ('group', 'channel')`, [chatId]);
  if (!chat) throw notFound('chat_not_found', 'Group or channel not found');
  await require('./chat.service').transferOwnership(chatId, null, body.user_id, { byAdmin: true });
  await log(admin.id, 'group.transfer_owner', 'chat', chatId, { to: body.user_id }, ip);
  return { ok: true };
}

async function groupMembers(chatIdRaw, query = {}) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const rows = await db.many(
    `SELECT u.id, u.first_name, u.last_name, u.username, u.phone, cm.role, cm.joined_at
     FROM chat_members cm JOIN users u ON u.id = cm.user_id WHERE cm.chat_id = $1
     ORDER BY CASE cm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, cm.joined_at
     LIMIT ${v.limit(query.limit, 100, 500)}`,
    [chatId],
  );
  return rows;
}

// ------------------------------------------------------------------ dashboard
async function dashboard() {
  const c = await db.one(`
    SELECT
      (SELECT count(*) FROM users WHERE status <> 'deleted') AS users_total,
      (SELECT count(*) FROM users WHERE created_at >= date_trunc('day', now())) AS users_new_today,
      (SELECT count(*) FROM users WHERE created_at >= now() - interval '7 days') AS users_new_7d,
      (SELECT count(*) FROM users u WHERE u.status = 'active' AND (u.last_seen_at >= now() - interval '24 hours'
         OR EXISTS (SELECT 1 FROM sessions s WHERE s.user_id = u.id AND s.last_active_at >= now() - interval '24 hours'))) AS users_active_24h,
      (SELECT count(*) FROM users u WHERE u.status = 'active' AND (u.last_seen_at >= now() - interval '30 days'
         OR EXISTS (SELECT 1 FROM sessions s WHERE s.user_id = u.id AND s.last_active_at >= now() - interval '30 days'))) AS users_active_30d,
      (SELECT count(*) FROM users WHERE status = 'banned') AS users_banned,
      (SELECT count(*) FROM messages WHERE type NOT IN ('system', 'call')) AS messages_total,
      (SELECT count(*) FROM messages WHERE type NOT IN ('system', 'call') AND created_at >= date_trunc('day', now())) AS messages_today,
      (SELECT count(*) FROM calls WHERE created_at >= date_trunc('day', now())) AS calls_today,
      (SELECT count(*) FROM calls WHERE status IN ('ringing', 'accepted')) AS calls_active,
      (SELECT count(*) FROM secret_chats WHERE status = 'active') AS secret_chats_active,
      (SELECT count(*) FROM users WHERE premium_until > now()) AS premium_users,
      (SELECT count(*) FROM payment_orders WHERE status = 'review') AS payments_to_review,
      (SELECT COALESCE(sum(amount_pkr), 0) FROM payment_orders WHERE status = 'paid' AND paid_at >= date_trunc('month', now())) AS revenue_month_pkr,
      (SELECT count(*) FROM bots b JOIN users bu ON bu.id = b.user_id WHERE bu.status <> 'deleted') AS bots_total,
      (SELECT count(*) FROM secret_messages WHERE created_at >= date_trunc('day', now())) AS secret_messages_today,
      (SELECT count(*) FROM chats WHERE type = 'group') AS groups_total,
      (SELECT count(*) FROM chats WHERE type = 'channel') AS channels_total,
      (SELECT count(*) FROM users WHERE restricted_until > now()) AS users_restricted,
      (SELECT count(*) FROM support_tickets WHERE status = 'open') AS tickets_open,
      (SELECT count(*) FROM ban_appeals WHERE status = 'pending') AS appeals_pending,
      (SELECT count(*) FROM stories WHERE deleted_at IS NULL AND expires_at > now()) AS stories_active,
      (SELECT count(*) FROM chats WHERE type = 'private') AS private_chats_total,
      (SELECT count(*) FROM reports WHERE status = 'open') AS reports_open,
      (SELECT COALESCE(sum(size_bytes), 0)::bigint FROM media) AS storage_bytes
  `);
  const signups = await db.many(`
    SELECT to_char(d, 'YYYY-MM-DD') AS day, count(u.id) AS count
    FROM generate_series(current_date - 29, current_date, interval '1 day') AS d
    LEFT JOIN users u ON u.created_at >= d AND u.created_at < d + interval '1 day'
    GROUP BY d ORDER BY d`);
  const messages = await db.many(`
    SELECT to_char(d, 'YYYY-MM-DD') AS day, count(m.id) AS count
    FROM generate_series(current_date - 13, current_date, interval '1 day') AS d
    LEFT JOIN messages m ON m.created_at >= d AND m.created_at < d + interval '1 day' AND m.type NOT IN ('system', 'call')
    GROUP BY d ORDER BY d`);
  return { ...c, online_now: presence.onlineCount(), signups_30d: signups, messages_14d: messages };
}

// ------------------------------------------------------------------ users
async function listUsers(query = {}) {
  const { limit, page, offset } = pageParams(query);
  const params = [];
  const where = [];
  const status = query.status || 'all';
  if (status === 'all') where.push(`u.status <> 'deleted'`);
  else if (status === 'restricted') where.push(`u.restricted_until > now()`);
  else {
    params.push(v.oneOf(status, ['active', 'banned', 'deleted'], 'status'));
    where.push(`u.status = $${params.length}`);
  }
  if (query.verified === 'true') where.push('u.is_verified');
  const q = String(query.q || '').trim();
  if (q) {
    params.push(`%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    const p = `$${params.length}`;
    const idCond = /^\d+$/.test(q) && q.length < 16 ? ` OR u.id = ${parseInt(q, 10)}` : '';
    where.push(`(u.phone ILIKE ${p} OR u.username ILIKE ${p} OR (u.first_name || ' ' || u.last_name) ILIKE ${p}${idCond})`);
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*) AS n FROM users u ${whereSql}`, params);
  const rows = await db.many(
    `SELECT u.id, u.phone, u.username, u.first_name, u.last_name, u.status, u.is_verified, u.ban_reason,
            u.banned_until, u.last_seen_at, u.created_at, u.avatar_media_id, u.restricted_until, u.restrict_reason
     FROM users u ${whereSql} ORDER BY u.id DESC LIMIT ${limit} OFFSET ${offset}`,
    params,
  );
  return {
    total: total.n,
    page,
    limit,
    users: rows.map((u) => ({ ...u, avatar_url: userService.avatarUrl(u.avatar_media_id), online: presence.isOnline(u.id) })),
  };
}

async function userDetail(userIdRaw) {
  const id = v.id(userIdRaw, 'user_id');
  const u = await db.one('SELECT * FROM users WHERE id = $1', [id]);
  if (!u) throw notFound('user_not_found', 'User not found');
  const stats = await db.one(
    `SELECT
       (SELECT count(*) FROM messages WHERE sender_id = $1 AND type NOT IN ('system', 'call')) AS messages_sent,
       (SELECT count(*) FROM calls WHERE caller_id = $1 OR callee_id = $1) AS calls,
       (SELECT count(*) FROM chat_members cm JOIN chats c ON c.id = cm.chat_id WHERE cm.user_id = $1 AND c.type = 'group') AS groups,
       (SELECT count(*) FROM blocks WHERE blocked_id = $1) AS blocked_by_count,
       (SELECT count(*) FROM reports r WHERE (r.target_type = 'user' AND r.target_id = $1)
           OR (r.target_type = 'message' AND (r.snapshot->'message'->>'sender_id')::bigint = $1)) AS reports_against`,
    [id],
  );
  const sessions = await db.many(
    `SELECT id, device_name, platform, app_version, ip, created_at, last_active_at
     FROM sessions WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now() ORDER BY last_active_at DESC`,
    [id],
  );
  const logs = await db.many(
    `SELECT l.id, l.action, l.details, l.created_at, a.name AS admin_name, a.email AS admin_email
     FROM admin_logs l LEFT JOIN admins a ON a.id = l.admin_id
     WHERE l.target_type = 'user' AND l.target_id = $1 ORDER BY l.id DESC LIMIT 20`,
    [id],
  );
  const notes = await db.many(
    `SELECT n.id, n.text, n.created_at, a.name AS admin_name FROM admin_notes n LEFT JOIN admins a ON a.id = n.admin_id
     WHERE n.user_id = $1 ORDER BY n.id DESC LIMIT 50`,
    [id],
  );
  const appeals = await db.many(
    'SELECT id, message, status, admin_reply, created_at, resolved_at FROM ban_appeals WHERE user_id = $1 ORDER BY id DESC LIMIT 10',
    [id],
  );
  return {
    user: {
      ...u,
      avatar_url: userService.avatarUrl(u.avatar_media_id),
      online: presence.isOnline(u.id),
    },
    stats,
    sessions,
    logs,
    notes,
    appeals,
  };
}

async function banUser(admin, userIdRaw, body = {}, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const reason = v.str(body.reason, { field: 'reason', min: 1, max: 500, required: true });
  let hours = null;
  if (body.duration_hours !== undefined && body.duration_hours !== null && body.duration_hours !== '') {
    hours = parseInt(body.duration_hours, 10);
    if (!Number.isInteger(hours) || hours < 1 || hours > 87600) {
      throw badRequest('invalid_input', 'duration_hours must be between 1 and 87600 (or empty for permanent)');
    }
  }
  const u = await db.one(
    `UPDATE users SET status = 'banned', ban_reason = $2,
       banned_until = CASE WHEN $3::int IS NULL THEN NULL ELSE now() + make_interval(hours => $3::int) END,
       updated_at = now()
     WHERE id = $1 AND status <> 'deleted' RETURNING id, banned_until`,
    [id, reason, hours],
  );
  if (!u) throw notFound('user_not_found', 'User not found');
  await db.query('UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [id]);
  bus.emit('sessions:revoked', { userId: id, sessionIds: null, reason: 'banned' });
  await log(admin.id, 'user.ban', 'user', id, { reason, duration_hours: hours }, ip);
  return { ok: true, banned_until: u.banned_until };
}

async function unbanUser(admin, userIdRaw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const u = await db.one(
    `UPDATE users SET status = 'active', ban_reason = NULL, banned_until = NULL, updated_at = now()
     WHERE id = $1 AND status = 'banned' RETURNING id`,
    [id],
  );
  if (!u) throw badRequest('not_banned', 'This user is not banned');
  await log(admin.id, 'user.unban', 'user', id, null, ip);
  return { ok: true };
}

async function logoutAll(admin, userIdRaw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const rows = await db.many('UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL RETURNING id', [id]);
  bus.emit('sessions:revoked', { userId: id, sessionIds: null, reason: 'admin_logout' });
  await log(admin.id, 'user.logout_all', 'user', id, { sessions: rows.length }, ip);
  return { ok: true, revoked: rows.length };
}

async function setVerified(admin, userIdRaw, value, ip) {
  const id = v.id(userIdRaw, 'user_id');
  const verified = v.bool(value, 'verified');
  const u = await db.one(`UPDATE users SET is_verified = $2 WHERE id = $1 AND status <> 'deleted' RETURNING id`, [id, verified]);
  if (!u) throw notFound('user_not_found', 'User not found');
  bus.emit('user:updated', { userId: id });
  await log(admin.id, verified ? 'user.verify' : 'user.unverify', 'user', id, null, ip);
  return { ok: true };
}

async function deleteUser(admin, userIdRaw, ip) {
  const id = v.id(userIdRaw, 'user_id');
  await userService.deleteAccount(id, { byAdmin: true });
  await log(admin.id, 'user.delete', 'user', id, null, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ reports
async function listReports(query = {}) {
  const { limit, page, offset } = pageParams(query);
  const status = v.oneOf(query.status || 'open', ['open', 'resolved', 'dismissed', 'all'], 'status');
  const params = [];
  let where = '';
  if (status !== 'all') {
    params.push(status);
    where = 'WHERE r.status = $1';
  }
  const total = await db.one(`SELECT count(*) AS n FROM reports r ${where}`, params);
  const rows = await db.many(
    `SELECT r.id, r.target_type, r.target_id, r.reason, r.details, r.status, r.action_taken, r.created_at, r.resolved_at, r.source,
            r.snapshot, u.id AS reporter_id, u.first_name AS reporter_first_name, u.username AS reporter_username,
            (SELECT count(*) FROM reports x WHERE x.target_type = r.target_type AND x.target_id = r.target_id
               AND x.status = 'open') AS open_reports_on_target
     FROM reports r LEFT JOIN users u ON u.id = r.reporter_id
     ${where} ORDER BY r.id DESC LIMIT ${limit} OFFSET ${offset}`,
    params,
  );
  return { total: total.n, page, limit, reports: rows };
}

async function reportDetail(reportIdRaw) {
  const id = v.id(reportIdRaw, 'report_id');
  const r = await db.one(
    `SELECT r.*, u.first_name AS reporter_first_name, u.username AS reporter_username, u.phone AS reporter_phone,
            a.name AS resolved_by_name
     FROM reports r LEFT JOIN users u ON u.id = r.reporter_id LEFT JOIN admins a ON a.id = r.resolved_by
     WHERE r.id = $1`,
    [id],
  );
  if (!r) throw notFound('report_not_found', 'Report not found');
  const out = { report: r, target: null, media: null };
  if (r.target_type === 'user') {
    out.target = await db.one('SELECT id, phone, username, first_name, last_name, status, is_verified FROM users WHERE id = $1', [r.target_id]);
  } else if (r.target_type === 'message') {
    out.target = await db.one(
      `SELECT m.id, m.chat_id, m.sender_id, m.type, m.deleted_at, u.first_name AS sender_first_name,
              u.username AS sender_username, u.status AS sender_status
       FROM messages m LEFT JOIN users u ON u.id = m.sender_id WHERE m.id = $1`,
      [r.target_id],
    );
    const mediaId = r.snapshot && r.snapshot.message && r.snapshot.message.media_id;
    if (mediaId) {
      const m = await db.one('SELECT * FROM media WHERE id = $1', [mediaId]);
      if (m) out.media = { ...mediaService.serialize(m), admin_url: `/api/admin/media/${m.id}` };
    }
  } else {
    out.target = await db.one(
      `SELECT c.id, c.type, c.title, c.is_suspended, (SELECT count(*) FROM chat_members WHERE chat_id = c.id) AS member_count
       FROM chats c WHERE c.id = $1`,
      [r.target_id],
    );
  }
  return out;
}

const REPORT_ACTIONS = ['dismiss', 'warn_only', 'delete_message', 'ban_user', 'delete_message_and_ban', 'suspend_chat', 'restrict_user'];

async function resolveReport(admin, reportIdRaw, body = {}, ip) {
  const id = v.id(reportIdRaw, 'report_id');
  const action = v.oneOf(body.action, REPORT_ACTIONS, 'action');
  const note = v.str(body.note, { field: 'note', max: 1000 }) || null;
  const r = await db.one('SELECT * FROM reports WHERE id = $1', [id]);
  if (!r) throw notFound('report_not_found', 'Report not found');
  if (r.status !== 'open') throw conflict('already_resolved', 'This report was already handled');

  let offenderId = null;
  let chatId = null;
  if (r.target_type === 'user') offenderId = r.target_id;
  if (r.target_type === 'message') {
    const m = await db.one('SELECT sender_id, chat_id FROM messages WHERE id = $1', [r.target_id]);
    offenderId = m ? m.sender_id : r.snapshot && r.snapshot.message && r.snapshot.message.sender_id;
    chatId = m ? m.chat_id : null;
  }
  if (r.target_type === 'chat') chatId = r.target_id;

  if (['delete_message', 'delete_message_and_ban'].includes(action)) {
    if (r.target_type !== 'message') throw badRequest('invalid_action', 'This report is not about a message');
    await messageService.adminDeleteMessage(r.target_id);
  }
  if (['ban_user', 'delete_message_and_ban'].includes(action)) {
    if (!offenderId) throw badRequest('invalid_action', 'No user to ban for this report');
    await banUser(admin, offenderId, { reason: body.ban_reason || `Report #${id}: ${r.reason}`, duration_hours: body.ban_hours }, ip);
  }
  if (action === 'restrict_user') {
    if (!offenderId) throw badRequest('invalid_action', 'No user to restrict for this report');
    await restrictUser(admin, offenderId, { minutes: body.restrict_minutes || 24 * 60, reason: `Report #${id}: ${r.reason}` }, ip);
  }
  if (action === 'suspend_chat') {
    const chat = chatId ? await db.one('SELECT id, type FROM chats WHERE id = $1', [chatId]) : null;
    if (!chat || chat.type === 'private') throw badRequest('invalid_action', 'Only groups and channels can be suspended');
    await setGroupSuspended(admin, chat.id, true, `Report #${id}`, ip);
  }

  const newStatus = action === 'dismiss' ? 'dismissed' : 'resolved';
  const updated = await db.many(
    `UPDATE reports SET status = $3, action_taken = $4, admin_note = $5, resolved_by = $6, resolved_at = now()
     WHERE status = 'open' AND target_type = $1 AND target_id = $2 RETURNING id`,
    [r.target_type, r.target_id, newStatus, action, note, admin.id],
  );
  await log(admin.id, 'report.resolve', 'report', id, { action, note, closed_reports: updated.length }, ip);
  return { ok: true, closed_reports: updated.length };
}

// ------------------------------------------------------------------ groups
async function listGroups(query = {}) {
  const { limit, page, offset } = pageParams(query);
  const params = [];
  const type = query.type || 'all';
  const where = [type === 'all' ? `c.type IN ('group', 'channel')` : `c.type = '${type === 'channel' ? 'channel' : 'group'}'`];
  if (query.status === 'suspended') where.push('c.is_suspended');
  const q = String(query.q || '').trim();
  if (q) {
    params.push(`%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    where.push(`(c.title ILIKE $${params.length} OR c.username ILIKE $${params.length})`);
  }
  const whereSql = `WHERE ${where.join(' AND ')}`;
  const total = await db.one(`SELECT count(*) AS n FROM chats c ${whereSql}`, params);
  const rows = await db.many(
    `SELECT c.id, c.type, c.username, c.is_public, c.is_verified, c.title, c.description, c.is_suspended, c.suspend_reason, c.created_at, c.last_message_at,
            c.avatar_media_id, (SELECT count(*) FROM chat_members WHERE chat_id = c.id) AS member_count,
            o.id AS owner_id, o.first_name AS owner_first_name, o.username AS owner_username
     FROM chats c
     LEFT JOIN chat_members om ON om.chat_id = c.id AND om.role = 'owner'
     LEFT JOIN users o ON o.id = om.user_id
     ${whereSql} ORDER BY c.id DESC LIMIT ${limit} OFFSET ${offset}`,
    params,
  );
  return {
    total: total.n,
    page,
    limit,
    groups: rows.map((g) => ({ ...g, avatar_url: userService.avatarUrl(g.avatar_media_id) })),
  };
}

async function setGroupSuspended(admin, chatIdRaw, suspended, reason, ip) {
  const id = v.id(chatIdRaw, 'chat_id');
  const c = await db.one(
    `UPDATE chats SET is_suspended = $2, suspend_reason = $3, updated_at = now()
     WHERE id = $1 AND type IN ('group', 'channel') RETURNING id`,
    [id, suspended, suspended ? reason || null : null],
  );
  if (!c) throw notFound('chat_not_found', 'Group not found');
  const memberIds = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [id])).map((r) => r.user_id);
  bus.emit('chat:updated', { chatId: id, memberIds });
  await log(admin.id, suspended ? 'group.suspend' : 'group.unsuspend', 'chat', id, { reason }, ip);
  return { ok: true };
}

async function deleteGroup(admin, chatIdRaw, ip) {
  const id = v.id(chatIdRaw, 'chat_id');
  const memberIds = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [id])).map((r) => r.user_id);
  const c = await db.one(`DELETE FROM chats WHERE id = $1 AND type IN ('group', 'channel') RETURNING id, title`, [id]);
  if (!c) throw notFound('chat_not_found', 'Group not found');
  bus.emit('chat:removed', { chatId: id, userIds: memberIds });
  await log(admin.id, 'group.delete', 'chat', id, { title: c.title }, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ settings
async function getSettings() {
  return { settings: await settings.getAll(), definitions: settings.DEFINITIONS };
}

async function updateSettings(admin, body, ip) {
  const result = await settings.update(body, admin.id);
  await log(admin.id, 'settings.update', 'settings', null, body, ip);
  return { settings: result };
}

// ------------------------------------------------------------------ admins (super admin only)
async function listAdmins() {
  const rows = await db.many('SELECT * FROM admins ORDER BY id');
  return rows.map(serializeAdmin);
}

async function createAdmin(actor, body = {}, ip) {
  const email = v.str(body.email, { field: 'email', min: 5, max: 255, required: true }).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw badRequest('invalid_input', 'Invalid email');
  const password = v.str(body.password, { field: 'password', min: 10, max: 200, trim: false, required: true });
  const name = v.str(body.name, { field: 'name', max: 100 }) || '';
  const role = v.oneOf(body.role || 'moderator', ROLES, 'role');
  try {
    const a = await db.one(
      'INSERT INTO admins (email, password_hash, name, role) VALUES ($1, $2, $3, $4) RETURNING *',
      [email, hashPassword(password), name, role],
    );
    await log(actor.id, 'admin.create', 'admin', a.id, { email, role }, ip);
    return serializeAdmin(a);
  } catch (err) {
    if (err.code === '23505') throw conflict('email_taken', 'An admin with this email already exists');
    throw err;
  }
}

async function updateAdmin(actor, adminIdRaw, body = {}, ip) {
  const id = v.id(adminIdRaw, 'admin_id');
  const target = await db.one('SELECT * FROM admins WHERE id = $1', [id]);
  if (!target) throw notFound('admin_not_found', 'Admin not found');
  const changes = {};
  if (body.name !== undefined) changes.name = v.str(body.name, { field: 'name', max: 100 });
  if (body.role !== undefined) changes.role = v.oneOf(body.role, ROLES, 'role');
  if (body.is_active !== undefined) changes.is_active = v.bool(body.is_active, 'is_active');
  if (body.password) changes.password_hash = hashPassword(v.str(body.password, { field: 'password', min: 10, max: 200, trim: false }));
  if (body.reset_2fa === true) {
    changes.totp_enabled = false;
    changes.totp_secret = null;
    changes.backup_codes = null;
  }
  if (id === actor.id && (changes.is_active === false || (changes.role && changes.role !== 'super_admin'))) {
    throw badRequest('invalid_input', 'You cannot disable or demote yourself');
  }
  const keys = Object.keys(changes);
  if (!keys.length) return serializeAdmin(target);
  const sets = keys.map((k, i) => `${k} = $${i + 2}`);
  const bump = changes.role || changes.is_active === false || changes.password_hash || body.reset_2fa === true
    ? ', token_version = token_version + 1'
    : '';
  const a = await db.one(`UPDATE admins SET ${sets.join(', ')}${bump} WHERE id = $1 RETURNING *`, [id, ...keys.map((k) => changes[k])]);
  const logged = { ...changes };
  if (logged.password_hash) logged.password_hash = '(changed)';
  delete logged.totp_secret;
  delete logged.backup_codes;
  await log(actor.id, 'admin.update', 'admin', id, logged, ip);
  return serializeAdmin(a);
}

// ------------------------------------------------------------------ logs
async function listLogs(query = {}) {
  const { limit, page, offset } = pageParams(query);
  const params = [];
  const where = [];
  if (query.admin_id) {
    params.push(v.id(query.admin_id, 'admin_id'));
    where.push(`l.admin_id = $${params.length}`);
  }
  if (query.action) {
    params.push(`${String(query.action).replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    where.push(`l.action LIKE $${params.length}`);
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*) AS n FROM admin_logs l ${whereSql}`, params);
  const rows = await db.many(
    `SELECT l.*, a.name AS admin_name, a.email AS admin_email FROM admin_logs l
     LEFT JOIN admins a ON a.id = l.admin_id ${whereSql} ORDER BY l.id DESC LIMIT ${limit} OFFSET ${offset}`,
    params,
  );
  return { total: total.n, page, limit, logs: rows };
}

module.exports = {
  log,
  addNote,
  deleteNote,
  exportUser,
  setUsername,
  transferGroupOwner,
  groupMembers,
  twoFactorSetup,
  twoFactorEnable,
  twoFactorDisable,
  restrictUser,
  unrestrictUser,
  setChatVerified,
  ROLES,
  PERMISSIONS,
  can,
  requirePerm,
  login,
  authenticate,
  changeOwnPassword,
  serializeAdmin,
  dashboard,
  listUsers,
  userDetail,
  banUser,
  unbanUser,
  logoutAll,
  setVerified,
  deleteUser,
  listReports,
  reportDetail,
  resolveReport,
  listGroups,
  setGroupSuspended,
  deleteGroup,
  getSettings,
  updateSettings,
  listAdmins,
  createAdmin,
  updateAdmin,
  listLogs,
};
