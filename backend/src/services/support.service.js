'use strict';

/** Help-desk tickets between users and the admin team. */
const db = require('../db');
const bus = require('../bus');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { notFound, forbidden } = require('../utils/errors');

const CATEGORIES = ['account', 'bug', 'abuse', 'payment', 'feature', 'other'];
const STATUSES = ['open', 'pending', 'resolved', 'closed'];
const PRIORITIES = ['low', 'normal', 'high', 'urgent'];

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function serializeTicket(t) {
  return {
    id: t.id,
    number: t.number ? Number(t.number) : t.id,
    subject: t.subject,
    category: t.category,
    status: t.status,
    priority: t.priority,
    unread: t.user_unread,
    created_at: iso(t.created_at),
    updated_at: iso(t.updated_at),
    last_message: t.last_text === undefined ? undefined : t.last_text,
    rating: t.rating || null,
    can_rate: !t.rating && ['resolved', 'closed'].includes(t.status),
  };
}

/** A screenshot the user attaches: their own uploaded image. */
async function ownImage(userId, mediaIdRaw) {
  if (mediaIdRaw === undefined || mediaIdRaw === null) return null;
  const m = await db.one('SELECT id, kind, uploader_id FROM media WHERE id = $1', [v.id(mediaIdRaw, 'media_id')]);
  if (!m || Number(m.uploader_id) !== Number(userId) || !['image', 'avatar'].includes(m.kind)) throw notFound('media_not_found', 'Picture not found');
  return m.id;
}

function serializeMessage(m, { forAdmin = false } = {}) {
  return {
    id: m.id,
    from_user: m.from_user,
    text: m.text,
    media_url: m.media_id ? `/api/media/${m.media_id}` : null,
    media_id: m.media_id || null,
    created_at: iso(m.created_at),
    ...(forAdmin ? { admin_id: m.admin_id, admin_name: m.admin_name || null, is_note: !!m.is_note } : {}),
  };
}

// ------------------------------------------------------------------ user side
async function createTicket(userId, body = {}) {
  rateLimit.enforce(`ticket:${userId}`, 5, 24 * 3600 * 1000, 'You can open up to 5 tickets a day');
  const subject = v.str(body.subject, { field: 'subject', min: 3, max: 150, required: true });
  const category = v.oneOf(body.category || 'other', CATEGORIES, 'category');
  const text = v.str(body.message, { field: 'message', min: 1, max: 4000, required: true });
  const device = v.str(body.device, { field: 'device', max: 120 }) || null;
  const mediaId = await ownImage(userId, body.media_id);
  const t = await db.tx(async (c) => {
    const r = await c.query(
      // Hushavia Plus: priority support — the ticket starts as "high", so it is answered first
      `INSERT INTO support_tickets (user_id, subject, category, device, priority)
       VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN 'high' ELSE 'normal' END) RETURNING *`,
      [userId, subject, category, device, await require('./payment.service').isPremium(userId)], // eslint-disable-line global-require
    );
    await c.query('INSERT INTO support_messages (ticket_id, from_user, text, media_id) VALUES ($1, TRUE, $2, $3)', [r.rows[0].id, text, mediaId]);
    return r.rows[0];
  });
  bus.emit('support:new', { ticketId: t.id });
  return getMine(userId, t.id);
}

async function listMine(userId) {
  const rows = await db.many(
    `SELECT t.*, (SELECT left(text, 120) FROM support_messages WHERE ticket_id = t.id AND NOT is_note ORDER BY id DESC LIMIT 1) AS last_text
     FROM support_tickets t WHERE t.user_id = $1 ORDER BY t.updated_at DESC LIMIT 100`,
    [userId],
  );
  return rows.map(serializeTicket);
}

async function getMine(userId, ticketIdRaw) {
  const t = await db.one('SELECT * FROM support_tickets WHERE id = $1 AND user_id = $2', [v.id(ticketIdRaw, 'ticket_id'), userId]);
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  if (t.user_unread) await db.query('UPDATE support_tickets SET user_unread = FALSE WHERE id = $1', [t.id]);
  // team notes never reach the user
  const msgs = await db.many('SELECT * FROM support_messages WHERE ticket_id = $1 AND NOT is_note ORDER BY id', [t.id]);
  return { ticket: serializeTicket({ ...t, user_unread: false }), messages: msgs.map((m) => serializeMessage(m)) };
}

async function userReply(userId, ticketIdRaw, body = {}) {
  const t = await db.one('SELECT * FROM support_tickets WHERE id = $1 AND user_id = $2', [v.id(ticketIdRaw, 'ticket_id'), userId]);
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  if (t.status === 'closed') throw forbidden('ticket_closed', 'This ticket is closed. Please open a new one.');
  rateLimit.enforce(`ticket-msg:${userId}`, 30, 60 * 60 * 1000, 'Slow down');
  const mediaId = await ownImage(userId, body.media_id);
  const text = v.str(body.text, { field: 'text', min: mediaId ? 0 : 1, max: 4000, required: !mediaId }) || '';
  await db.query('INSERT INTO support_messages (ticket_id, from_user, text, media_id) VALUES ($1, TRUE, $2, $3)', [t.id, text, mediaId]);
  await db.query(`UPDATE support_tickets SET status = 'open', updated_at = now() WHERE id = $1`, [t.id]);
  bus.emit('support:new', { ticketId: t.id });
  return getMine(userId, t.id);
}

async function userClose(userId, ticketIdRaw) {
  const r = await db.one(
    `UPDATE support_tickets SET status = 'closed', updated_at = now() WHERE id = $1 AND user_id = $2 RETURNING id`,
    [v.id(ticketIdRaw, 'ticket_id'), userId],
  );
  if (!r) throw notFound('ticket_not_found', 'Ticket not found');
  return getMine(userId, r.id);
}

/** After help: how did we do? (1–5 stars and a short note) */
async function rateTicket(userId, ticketIdRaw, body = {}) {
  const rating = parseInt(body.rating, 10);
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) throw require('../utils/errors').badRequest('invalid_input', 'Rating must be 1 to 5'); // eslint-disable-line global-require
  const comment = v.str(body.comment, { field: 'comment', max: 500 }) || null;
  const r = await db.one(
    `UPDATE support_tickets SET rating = $3, rating_comment = $4, status = 'closed', updated_at = now()
     WHERE id = $1 AND user_id = $2 AND status IN ('resolved', 'closed') AND rating IS NULL RETURNING id`,
    [v.id(ticketIdRaw, 'ticket_id'), userId, rating, comment],
  );
  if (!r) throw forbidden('cannot_rate', 'You can rate a request once, after it is resolved');
  return getMine(userId, r.id);
}

// ------------------------------------------------------------------ admin side
async function adminList(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const params = [];
  const where = [];
  const status = query.status || 'active';
  if (status === 'active') where.push(`t.status IN ('open', 'pending')`);
  else if (status !== 'all') {
    params.push(v.oneOf(status, STATUSES, 'status'));
    where.push(`t.status = $${params.length}`);
  }
  if (query.mine && query.admin_id) {
    params.push(query.admin_id);
    where.push(`t.assigned_to = $${params.length}`);
  }
  const q = String(query.q || '').trim();
  if (q) {
    params.push(`%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    const n = q.replace(/^#/, '');
    if (/^\d{3,12}$/.test(n)) {
      params.push(n);
      where.push(`(t.subject ILIKE $${params.length - 1} OR t.number::text = $${params.length} OR u.phone ILIKE $${params.length - 1})`);
    } else {
      where.push(`(t.subject ILIKE $${params.length} OR u.phone ILIKE $${params.length} OR u.username ILIKE $${params.length} OR u.email ILIKE $${params.length})`);
    }
  }
  if (query.category && CATEGORIES.includes(query.category)) {
    params.push(query.category);
    where.push(`t.category = $${params.length}`);
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*) AS n FROM support_tickets t JOIN users u ON u.id = t.user_id ${whereSql}`, params);
  const rows = await db.many(
    `SELECT t.*, u.first_name, u.last_name, u.username, u.phone, u.email, a.name AS assigned_name,
            (SELECT from_user FROM support_messages WHERE ticket_id = t.id AND NOT is_note ORDER BY id DESC LIMIT 1) AS awaiting_admin,
            (SELECT max(created_at) FROM support_messages WHERE ticket_id = t.id AND from_user) AS last_user_at
     FROM support_tickets t JOIN users u ON u.id = t.user_id LEFT JOIN admins a ON a.id = t.assigned_to
     ${whereSql}
     ORDER BY CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END, t.updated_at DESC
     LIMIT ${limit} OFFSET ${(page - 1) * limit}`,
    params,
  );
  return { total: total.n, page, limit, tickets: rows };
}

async function adminGet(ticketIdRaw) {
  const id = v.id(ticketIdRaw, 'ticket_id');
  const t = await db.one(
    `SELECT t.*, u.first_name, u.last_name, u.username, u.phone, u.email, u.status AS user_status, a.name AS assigned_name
     FROM support_tickets t JOIN users u ON u.id = t.user_id LEFT JOIN admins a ON a.id = t.assigned_to WHERE t.id = $1`,
    [id],
  );
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  const msgs = await db.many(
    `SELECT m.*, a.name AS admin_name FROM support_messages m LEFT JOIN admins a ON a.id = m.admin_id
     WHERE m.ticket_id = $1 ORDER BY m.id`,
    [id],
  );
  // the person's other requests (to spot repeats)
  const others = await db.many(
    `SELECT id, number, subject, status, created_at FROM support_tickets WHERE user_id = $1 AND id <> $2 ORDER BY id DESC LIMIT 10`,
    [t.user_id, id],
  );
  return { ticket: t, messages: msgs.map((m) => serializeMessage(m, { forAdmin: true })), other_tickets: others };
}

async function adminReply(admin, ticketIdRaw, body = {}) {
  const id = v.id(ticketIdRaw, 'ticket_id');
  const text = v.str(body.text, { field: 'text', min: 1, max: 4000, required: true });
  if (body.note === true) {
    // a note for the team only: the user doesn't see it and nothing changes for them
    const t = await db.one('SELECT id FROM support_tickets WHERE id = $1', [id]);
    if (!t) throw notFound('ticket_not_found', 'Ticket not found');
    await db.query('INSERT INTO support_messages (ticket_id, admin_id, from_user, text, is_note) VALUES ($1, $2, FALSE, $3, TRUE)', [id, admin.id, text]);
    return adminGet(id);
  }
  const status = body.status ? v.oneOf(body.status, STATUSES, 'status') : 'pending';
  const t = await db.one(
    `UPDATE support_tickets SET status = $2::varchar, user_unread = TRUE, updated_at = now(),
       first_reply_at = COALESCE(first_reply_at, now()),
       resolved_at = CASE WHEN $2::varchar IN ('resolved', 'closed') THEN now() ELSE NULL END,
       assigned_to = COALESCE(assigned_to, $3) WHERE id = $1 RETURNING *`,
    [id, status, admin.id],
  );
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  await db.query('INSERT INTO support_messages (ticket_id, admin_id, from_user, text) VALUES ($1, $2, FALSE, $3)', [id, admin.id, text]);
  bus.emit('support:reply', { userId: t.user_id, ticketId: t.id, number: Number(t.number), subject: t.subject, text });
  return adminGet(id);
}

/** Numbers for the support page: what's waiting and how fast the team answers. */
async function adminStats() {
  return db.one(
    `SELECT
       (SELECT count(*) FROM support_tickets WHERE status IN ('open', 'pending'))::int AS active,
       (SELECT count(*) FROM support_tickets t WHERE status IN ('open', 'pending')
          AND (SELECT from_user FROM support_messages WHERE ticket_id = t.id AND NOT is_note ORDER BY id DESC LIMIT 1))::int AS needs_reply,
       (SELECT count(*) FROM support_tickets WHERE status IN ('open', 'pending') AND assigned_to IS NULL)::int AS unassigned,
       (SELECT count(*) FROM support_tickets WHERE status IN ('open', 'pending') AND priority IN ('high', 'urgent'))::int AS urgent,
       (SELECT count(*) FROM support_tickets WHERE created_at > now() - interval '1 day')::int AS new_today,
       (SELECT count(*) FROM support_tickets WHERE resolved_at > now() - interval '7 days')::int AS resolved_week,
       (SELECT round(avg(extract(epoch FROM first_reply_at - created_at)) / 60)::int FROM support_tickets
          WHERE first_reply_at IS NOT NULL AND created_at > now() - interval '30 days') AS first_reply_min,
       (SELECT round(avg(rating)::numeric, 1)::float FROM support_tickets WHERE rating IS NOT NULL AND created_at > now() - interval '90 days') AS avg_rating,
       (SELECT count(*) FROM support_tickets WHERE rating IS NOT NULL AND created_at > now() - interval '90 days')::int AS ratings`,
  );
}

// ------------------------------------------------------------------ saved answers
async function cannedList() {
  return db.many('SELECT id, title, text FROM support_canned ORDER BY title LIMIT 200');
}

async function cannedSave(admin, body = {}) {
  const title = v.str(body.title, { field: 'title', min: 1, max: 80, required: true });
  const text = v.str(body.text, { field: 'text', min: 1, max: 4000, required: true });
  if (body.id) {
    const r = await db.one('UPDATE support_canned SET title = $2, text = $3 WHERE id = $1 RETURNING id, title, text', [v.id(body.id, 'id'), title, text]);
    if (!r) throw notFound('not_found', 'Saved answer not found');
    return r;
  }
  return db.one('INSERT INTO support_canned (title, text, created_by) VALUES ($1, $2, $3) RETURNING id, title, text', [title, text, admin.id]);
}

async function cannedDelete(idRaw) {
  await db.query('DELETE FROM support_canned WHERE id = $1', [v.id(idRaw, 'id')]);
  return { ok: true };
}

/** Resolved requests the user didn't answer for 3 days close by themselves. */
async function sweep() {
  const r = await db.query(
    `UPDATE support_tickets SET status = 'closed', updated_at = now()
     WHERE status = 'resolved' AND COALESCE(resolved_at, updated_at) < now() - interval '3 days'`,
  );
  return r.rowCount || 0;
}

async function adminUpdate(ticketIdRaw, body = {}) {
  const id = v.id(ticketIdRaw, 'ticket_id');
  const sets = [];
  const params = [id];
  if (body.status !== undefined) {
    params.push(v.oneOf(body.status, STATUSES, 'status'));
    sets.push(`status = $${params.length}::varchar`);
    sets.push(`resolved_at = CASE WHEN $${params.length}::varchar IN ('resolved', 'closed') THEN COALESCE(resolved_at, now()) ELSE NULL END`);
  }
  if (body.category !== undefined) {
    params.push(v.oneOf(body.category, CATEGORIES, 'category'));
    sets.push(`category = $${params.length}`);
  }
  if (body.priority !== undefined) {
    params.push(v.oneOf(body.priority, PRIORITIES, 'priority'));
    sets.push(`priority = $${params.length}`);
  }
  if (body.assigned_to !== undefined) {
    params.push(body.assigned_to === null ? null : v.id(body.assigned_to, 'assigned_to'));
    sets.push(`assigned_to = $${params.length}`);
  }
  if (sets.length) {
    const r = await db.one(`UPDATE support_tickets SET ${sets.join(', ')}, updated_at = now() WHERE id = $1 RETURNING user_id`, params);
    if (!r) throw notFound('ticket_not_found', 'Ticket not found');
  }
  return adminGet(id);
}

module.exports = {
  rateTicket,
  CATEGORIES,
  STATUSES,
  PRIORITIES,
  createTicket,
  listMine,
  getMine,
  userReply,
  userClose,
  adminList,
  adminGet,
  adminReply,
  adminUpdate,
  adminStats,
  cannedList,
  cannedSave,
  cannedDelete,
  sweep,
};
