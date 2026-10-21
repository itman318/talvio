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
    subject: t.subject,
    category: t.category,
    status: t.status,
    priority: t.priority,
    unread: t.user_unread,
    created_at: iso(t.created_at),
    updated_at: iso(t.updated_at),
    last_message: t.last_text === undefined ? undefined : t.last_text,
  };
}

function serializeMessage(m, { forAdmin = false } = {}) {
  return {
    id: m.id,
    from_user: m.from_user,
    text: m.text,
    created_at: iso(m.created_at),
    ...(forAdmin ? { admin_id: m.admin_id, admin_name: m.admin_name || null } : {}),
  };
}

// ------------------------------------------------------------------ user side
async function createTicket(userId, body = {}) {
  rateLimit.enforce(`ticket:${userId}`, 5, 24 * 3600 * 1000, 'You can open up to 5 tickets a day');
  const subject = v.str(body.subject, { field: 'subject', min: 3, max: 150, required: true });
  const category = v.oneOf(body.category || 'other', CATEGORIES, 'category');
  const text = v.str(body.message, { field: 'message', min: 1, max: 4000, required: true });
  const t = await db.tx(async (c) => {
    const r = await c.query(
      'INSERT INTO support_tickets (user_id, subject, category) VALUES ($1, $2, $3) RETURNING *',
      [userId, subject, category],
    );
    await c.query('INSERT INTO support_messages (ticket_id, from_user, text) VALUES ($1, TRUE, $2)', [r.rows[0].id, text]);
    return r.rows[0];
  });
  bus.emit('support:new', { ticketId: t.id });
  return getMine(userId, t.id);
}

async function listMine(userId) {
  const rows = await db.many(
    `SELECT t.*, (SELECT left(text, 120) FROM support_messages WHERE ticket_id = t.id ORDER BY id DESC LIMIT 1) AS last_text
     FROM support_tickets t WHERE t.user_id = $1 ORDER BY t.updated_at DESC LIMIT 100`,
    [userId],
  );
  return rows.map(serializeTicket);
}

async function getMine(userId, ticketIdRaw) {
  const t = await db.one('SELECT * FROM support_tickets WHERE id = $1 AND user_id = $2', [v.id(ticketIdRaw, 'ticket_id'), userId]);
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  if (t.user_unread) await db.query('UPDATE support_tickets SET user_unread = FALSE WHERE id = $1', [t.id]);
  const msgs = await db.many('SELECT * FROM support_messages WHERE ticket_id = $1 ORDER BY id', [t.id]);
  return { ticket: serializeTicket({ ...t, user_unread: false }), messages: msgs.map((m) => serializeMessage(m)) };
}

async function userReply(userId, ticketIdRaw, body = {}) {
  const t = await db.one('SELECT * FROM support_tickets WHERE id = $1 AND user_id = $2', [v.id(ticketIdRaw, 'ticket_id'), userId]);
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  if (t.status === 'closed') throw forbidden('ticket_closed', 'This ticket is closed. Please open a new one.');
  rateLimit.enforce(`ticket-msg:${userId}`, 30, 60 * 60 * 1000, 'Slow down');
  const text = v.str(body.text, { field: 'text', min: 1, max: 4000, required: true });
  await db.query('INSERT INTO support_messages (ticket_id, from_user, text) VALUES ($1, TRUE, $2)', [t.id, text]);
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
    where.push(`(t.subject ILIKE $${params.length} OR u.phone ILIKE $${params.length} OR u.username ILIKE $${params.length})`);
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*) AS n FROM support_tickets t JOIN users u ON u.id = t.user_id ${whereSql}`, params);
  const rows = await db.many(
    `SELECT t.*, u.first_name, u.last_name, u.username, u.phone, a.name AS assigned_name,
            (SELECT from_user FROM support_messages WHERE ticket_id = t.id ORDER BY id DESC LIMIT 1) AS awaiting_admin
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
    `SELECT t.*, u.first_name, u.last_name, u.username, u.phone, u.status AS user_status, a.name AS assigned_name
     FROM support_tickets t JOIN users u ON u.id = t.user_id LEFT JOIN admins a ON a.id = t.assigned_to WHERE t.id = $1`,
    [id],
  );
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  const msgs = await db.many(
    `SELECT m.*, a.name AS admin_name FROM support_messages m LEFT JOIN admins a ON a.id = m.admin_id
     WHERE m.ticket_id = $1 ORDER BY m.id`,
    [id],
  );
  return { ticket: t, messages: msgs.map((m) => serializeMessage(m, { forAdmin: true })) };
}

async function adminReply(admin, ticketIdRaw, body = {}) {
  const id = v.id(ticketIdRaw, 'ticket_id');
  const text = v.str(body.text, { field: 'text', min: 1, max: 4000, required: true });
  const status = body.status ? v.oneOf(body.status, STATUSES, 'status') : 'pending';
  const t = await db.one(
    `UPDATE support_tickets SET status = $2, user_unread = TRUE, updated_at = now(),
       assigned_to = COALESCE(assigned_to, $3) WHERE id = $1 RETURNING *`,
    [id, status, admin.id],
  );
  if (!t) throw notFound('ticket_not_found', 'Ticket not found');
  await db.query('INSERT INTO support_messages (ticket_id, admin_id, from_user, text) VALUES ($1, $2, FALSE, $3)', [id, admin.id, text]);
  bus.emit('support:reply', { userId: t.user_id, ticketId: t.id, subject: t.subject, text });
  return adminGet(id);
}

async function adminUpdate(ticketIdRaw, body = {}) {
  const id = v.id(ticketIdRaw, 'ticket_id');
  const sets = [];
  const params = [id];
  if (body.status !== undefined) {
    params.push(v.oneOf(body.status, STATUSES, 'status'));
    sets.push(`status = $${params.length}`);
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
};
