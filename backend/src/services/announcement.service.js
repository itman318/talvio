'use strict';

/** Admin broadcasts: in-app banners and/or push notifications to all or targeted users. */
const db = require('../db');
const push = require('./push.service');
const v = require('../utils/validate');
const { badRequest, notFound } = require('../utils/errors');

const PLATFORMS = ['android', 'ios'];

function parseTarget(raw = {}) {
  const t = {};
  if (raw.phone_prefix) {
    const p = String(raw.phone_prefix).trim();
    if (!/^\+\d{1,6}$/.test(p)) throw badRequest('invalid_input', 'Phone prefix must look like +92');
    t.phone_prefix = p;
  }
  if (raw.platform) t.platform = v.oneOf(raw.platform, PLATFORMS, 'platform');
  return t;
}

/** SQL selecting active user ids that match a target. */
function targetSql(target, params) {
  const where = [`u.status = 'active'`];
  if (target.phone_prefix) {
    params.push(`${target.phone_prefix}%`);
    where.push(`u.phone LIKE $${params.length}`);
  }
  if (target.platform) {
    params.push(target.platform);
    where.push(`EXISTS (SELECT 1 FROM sessions s WHERE s.user_id = u.id AND s.revoked_at IS NULL
                        AND s.expires_at > now() AND s.platform = $${params.length})`);
  }
  return `SELECT u.id FROM users u WHERE ${where.join(' AND ')}`;
}

async function create(adminId, body = {}) {
  const title = v.str(body.title, { field: 'title', min: 1, max: 120, required: true });
  const text = v.str(body.body, { field: 'body', min: 1, max: 1000, required: true });
  const inApp = body.in_app !== false;
  const sendPush = body.push === true;
  if (!inApp && !sendPush) throw badRequest('invalid_input', 'Choose in-app, push, or both');
  const target = parseTarget(body.target || {});
  let hours = null;
  if (body.expires_hours !== undefined && body.expires_hours !== null && body.expires_hours !== '') {
    hours = parseInt(body.expires_hours, 10);
    if (!Number.isInteger(hours) || hours < 1 || hours > 24 * 90) throw badRequest('invalid_input', 'expires_hours must be 1–2160');
  }
  const params = [];
  const ids = (await db.many(targetSql(target, params), params)).map((r) => r.id);
  const a = await db.one(
    `INSERT INTO announcements (title, body, target, in_app, push, recipients, created_by, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, CASE WHEN $8::int IS NULL THEN NULL ELSE now() + make_interval(hours => $8::int) END)
     RETURNING *`,
    [title, text, JSON.stringify(target), inApp, sendPush, ids.length, adminId, hours],
  );
  if (sendPush && ids.length) {
    // fire and forget in batches; push.sendToUsers is a no-op when FCM isn't configured
    (async () => {
      for (let i = 0; i < ids.length; i += 1000) {
        await push.sendToUsers(ids.slice(i, i + 1000), { title, body: text }, { type: 'announcement', announcement_id: a.id });
      }
    })().catch((err) => console.error('broadcast push failed', err)); // eslint-disable-line no-console
  }
  return a;
}

async function list(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const total = await db.one('SELECT count(*) AS n FROM announcements');
  const rows = await db.many(
    `SELECT an.*, a.name AS admin_name,
            (SELECT count(*) FROM announcement_dismissals d WHERE d.announcement_id = an.id) AS dismissed
     FROM announcements an LEFT JOIN admins a ON a.id = an.created_by
     ORDER BY an.id DESC LIMIT ${limit} OFFSET ${(page - 1) * limit}`,
  );
  return { total: total.n, page, limit, announcements: rows };
}

async function expire(idRaw) {
  const r = await db.one('UPDATE announcements SET expires_at = now() WHERE id = $1 RETURNING id', [v.id(idRaw, 'id')]);
  if (!r) throw notFound('announcement_not_found', 'Announcement not found');
  return { ok: true };
}

/** Active in-app announcements for this user (newest first, max 3). */
async function forUser(userId) {
  const user = await db.one('SELECT id, phone FROM users WHERE id = $1', [userId]);
  const platforms = (await db.many(
    'SELECT DISTINCT platform FROM sessions WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()',
    [userId],
  )).map((r) => r.platform);
  const rows = await db.many(
    `SELECT an.* FROM announcements an
     WHERE an.in_app AND (an.expires_at IS NULL OR an.expires_at > now())
       AND NOT EXISTS (SELECT 1 FROM announcement_dismissals d WHERE d.announcement_id = an.id AND d.user_id = $1)
     ORDER BY an.id DESC LIMIT 20`,
    [userId],
  );
  return rows
    .filter((a) => {
      const t = a.target || {};
      if (t.phone_prefix && !user.phone.startsWith(t.phone_prefix)) return false;
      if (t.platform && !platforms.includes(t.platform)) return false;
      return true;
    })
    .slice(0, 3)
    .map((a) => ({ id: a.id, title: a.title, body: a.body, created_at: new Date(a.created_at).toISOString() }));
}

async function dismiss(userId, idRaw) {
  await db.query('INSERT INTO announcement_dismissals (announcement_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [
    v.id(idRaw, 'id'),
    userId,
  ]);
  return { ok: true };
}

module.exports = { create, list, expire, forUser, dismiss };
