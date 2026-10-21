'use strict';

/** Ban appeals: banned users (after proving their phone with OTP) can ask moderators to review. */
const config = require('../config');
const db = require('../db');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { verifyJwt } = require('../utils/crypto');
const { badRequest, unauthorized, conflict, notFound } = require('../utils/errors');

async function create(body = {}) {
  const p = verifyJwt(body.appeal_token, config.jwtSecret);
  if (!p || p.typ !== 'appeal') throw unauthorized('invalid_token', 'Verify your phone number again to appeal');
  const message = v.str(body.message, { field: 'message', min: 10, max: 2000, required: true });
  rateLimit.enforce(`appeal:${p.sub}`, 3, 24 * 3600 * 1000, 'You can send up to 3 appeals a day');
  const u = await db.one(`SELECT id, status FROM users WHERE id = $1`, [p.sub]);
  if (!u || u.status !== 'banned') throw badRequest('not_banned', 'This account is not banned');
  const pending = await db.one(`SELECT id FROM ban_appeals WHERE user_id = $1 AND status = 'pending'`, [u.id]);
  if (pending) throw conflict('appeal_pending', 'Your appeal is already being reviewed');
  const a = await db.one('INSERT INTO ban_appeals (user_id, message) VALUES ($1, $2) RETURNING id, status, created_at', [u.id, message]);
  return { ok: true, appeal_id: a.id };
}

async function list(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const status = v.oneOf(query.status || 'pending', ['pending', 'accepted', 'rejected', 'all'], 'status');
  const params = [];
  let where = '';
  if (status !== 'all') {
    params.push(status);
    where = 'WHERE a.status = $1';
  }
  const total = await db.one(`SELECT count(*) AS n FROM ban_appeals a ${where}`, params);
  const rows = await db.many(
    `SELECT a.*, u.first_name, u.last_name, u.username, u.phone, u.ban_reason, u.banned_until, u.status AS user_status,
            ad.name AS resolved_by_name
     FROM ban_appeals a JOIN users u ON u.id = a.user_id LEFT JOIN admins ad ON ad.id = a.resolved_by
     ${where} ORDER BY a.id DESC LIMIT ${limit} OFFSET ${(page - 1) * limit}`,
    params,
  );
  return { total: total.n, page, limit, appeals: rows };
}

/** accept → unban; reject → keep ban. `reply` is shown to the user at their next login attempt. */
async function resolve(admin, idRaw, body = {}, ip) {
  const adminService = require('./admin.service'); // lazy: avoids circular import
  const id = v.id(idRaw, 'appeal_id');
  const accept = v.bool(body.accept, 'accept');
  const reply = v.str(body.reply, { field: 'reply', max: 1000 }) || null;
  const a = await db.one(
    `UPDATE ban_appeals SET status = $2, admin_reply = $3, resolved_by = $4, resolved_at = now()
     WHERE id = $1 AND status = 'pending' RETURNING *`,
    [id, accept ? 'accepted' : 'rejected', reply, admin.id],
  );
  if (!a) throw notFound('appeal_not_found', 'Appeal not found or already handled');
  if (accept) {
    const u = await db.one('SELECT status FROM users WHERE id = $1', [a.user_id]);
    if (u && u.status === 'banned') await adminService.unbanUser(admin, a.user_id, ip);
  }
  await db.query(
    `INSERT INTO admin_logs (admin_id, action, target_type, target_id, details, ip) VALUES ($1, $2, 'user', $3, $4, $5)`,
    [admin.id, accept ? 'appeal.accept' : 'appeal.reject', a.user_id, JSON.stringify({ appeal_id: id, reply }), ip || null],
  );
  return { ok: true };
}

module.exports = { create, list, resolve };
