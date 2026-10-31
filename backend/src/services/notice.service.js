'use strict';

/**
 * In-app notifications ("Talvio notifications"): new logins, security events, being added to groups,
 * admin rights, support replies, payments… One list per user, newest first, with an unread count.
 */
const db = require('../db');
const bus = require('../bus');
const v = require('../utils/validate');

const KINDS = [
  'login', // a new device logged in
  'security', // wrong password, two-step changed, device logged out…
  'group', // added to / removed from a group or channel
  'admin', // made admin, rights changed
  'support', // support replied
  'payment', // payment approved / rejected
  'account', // restrictions, verification, Plus…
  'system', // anything else from Talvio
];

function serialize(n) {
  return {
    id: Number(n.id),
    kind: n.kind,
    title: n.title,
    body: n.body,
    data: n.data || {},
    read: !!n.read_at,
    created_at: new Date(n.created_at).toISOString(),
  };
}

/** Adds a notification for a user and tells their open apps. Never throws (best-effort). */
async function notify(userId, kind, title, body = '', data = {}) {
  try {
    const n = await db.one(
      `INSERT INTO notices (user_id, kind, title, body, data) VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING *`,
      [userId, KINDS.includes(kind) ? kind : 'system', String(title).slice(0, 120), String(body || '').slice(0, 500), JSON.stringify(data || {})],
    );
    // keep the list small: the newest 300
    await db.query(
      `DELETE FROM notices WHERE user_id = $1 AND id < (SELECT min(id) FROM (SELECT id FROM notices WHERE user_id = $1 ORDER BY id DESC LIMIT 300) x)`,
      [userId],
    );
    bus.emit('rt:emit', { event: 'notice:new', payload: serialize(n), userIds: [userId] });
    // not looking at the app → a phone notification too (support replies already push on their own)
    if (kind !== 'support') {
      try {
        const presence = require('./presence'); // eslint-disable-line global-require
        if (!presence.isActive(userId)) {
          const push = require('./push.service'); // eslint-disable-line global-require
          push.sendToUsers([userId], { title: String(title).slice(0, 120), body: String(body || '').slice(0, 200) }, { type: 'notice', notice_id: Number(n.id), kind: n.kind }).catch(() => {});
        }
      } catch (_) {
        /* best-effort */
      }
    }
    return serialize(n);
  } catch (e) {
    return null;
  }
}

async function list(userId, query = {}) {
  const before = query.before ? v.id(query.before, 'before') : null;
  const rows = await db.many(
    `SELECT * FROM notices WHERE user_id = $1 ${before ? 'AND id < $2' : ''} ORDER BY id DESC LIMIT ${v.limit(query.limit, 40, 100)}`,
    before ? [userId, before] : [userId],
  );
  const unread = await db.one('SELECT count(*)::int AS n FROM notices WHERE user_id = $1 AND read_at IS NULL', [userId]);
  return { items: rows.map(serialize), unread: unread.n };
}

async function unreadCount(userId) {
  const r = await db.one('SELECT count(*)::int AS n FROM notices WHERE user_id = $1 AND read_at IS NULL', [userId]);
  return { unread: r.n };
}

async function markAllRead(userId) {
  await db.query('UPDATE notices SET read_at = now() WHERE user_id = $1 AND read_at IS NULL', [userId]);
  return { ok: true, unread: 0 };
}

async function remove(userId, idRaw) {
  await db.query('DELETE FROM notices WHERE user_id = $1 AND id = $2', [userId, v.id(idRaw, 'notice_id')]);
  return { ok: true };
}

async function clear(userId) {
  await db.query('DELETE FROM notices WHERE user_id = $1', [userId]);
  return { ok: true };
}

bus.on('support:reply', (e) => {
  notify(e.userId, 'support', 'Support replied', `“${e.subject}”: ${String(e.text || '').slice(0, 160)}`, { ticket_id: e.ticketId });
});

module.exports = { notify, list, unreadCount, markAllRead, remove, clear, KINDS };
