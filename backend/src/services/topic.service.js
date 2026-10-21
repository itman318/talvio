'use strict';

/** Topics (forum mode) for groups: separate threads such as "Announcements", "Help", "Off-topic". */
const db = require('../db');
const bus = require('../bus');
const chatService = require('./chat.service');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const MAX_TOPICS = 200;

function serialize(t, last) {
  return {
    id: t.id,
    chat_id: t.chat_id,
    title: t.title,
    icon_color: t.icon_color,
    is_closed: t.is_closed,
    is_pinned: t.is_pinned,
    created_by: t.created_by,
    message_count: t.message_count || 0,
    last_message: last || null,
    last_message_at: t.last_message_at ? new Date(t.last_message_at).toISOString() : null,
    created_at: new Date(t.created_at).toISOString(),
  };
}

async function requireForum(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  if (chat.type !== 'group' || !chat.is_forum) throw badRequest('not_a_forum', 'Topics are not turned on in this group');
  return chat;
}

async function list(userId, chatIdRaw) {
  const chat = await requireForum(userId, chatIdRaw);
  const rows = await db.many(
    `SELECT t.*, (SELECT count(*)::int FROM messages m WHERE m.topic_id = t.id AND m.deleted_at IS NULL) AS message_count,
            (SELECT m.id FROM messages m WHERE m.topic_id = t.id AND m.deleted_at IS NULL AND m.id > $2 ORDER BY m.id DESC LIMIT 1) AS last_id
     FROM chat_topics t WHERE t.chat_id = $1
     ORDER BY t.is_pinned DESC, COALESCE(t.last_message_at, t.created_at) DESC`,
    [chat.id, chat.cleared_before_id],
  );
  const general = await db.one(
    `SELECT id FROM messages WHERE chat_id = $1 AND topic_id IS NULL AND thread_id IS NULL AND deleted_at IS NULL AND id > $2 ORDER BY id DESC LIMIT 1`,
    [chat.id, chat.cleared_before_id],
  );
  const ids = [...rows.map((r) => r.last_id), general && general.id].filter(Boolean);
  const msgs = await require('./message.service').serializeByIds(userId, ids); // lazy: avoids circular import
  return {
    general: { id: 0, title: 'General', last_message: general ? msgs.get(general.id) || null : null },
    topics: rows.map((r) => serialize(r, r.last_id ? msgs.get(r.last_id) : null)),
  };
}

function readBody(body, { partial }) {
  const out = {};
  if (!partial || body.title !== undefined) out.title = v.str(body.title, { field: 'title', min: 1, max: 128, required: !partial });
  if (body.icon_color !== undefined) {
    const c = parseInt(body.icon_color, 10);
    if (!Number.isInteger(c) || c < 0 || c > 7) throw badRequest('invalid_input', 'icon_color must be 0–7');
    out.icon_color = c;
  }
  if (body.is_closed !== undefined) out.is_closed = v.bool(body.is_closed, 'is_closed');
  if (body.is_pinned !== undefined) out.is_pinned = v.bool(body.is_pinned, 'is_pinned');
  return out;
}

async function create(userId, chatIdRaw, body = {}) {
  const chat = await requireForum(userId, chatIdRaw);
  if (!chatService.ADMIN_ROLES.includes(chat.my_role)) throw forbidden('not_admin', 'Only admins can create topics');
  const b = readBody(body, { partial: false });
  const n = await db.one('SELECT count(*)::int AS n FROM chat_topics WHERE chat_id = $1', [chat.id]);
  if (n.n >= MAX_TOPICS) throw forbidden('too_many_topics', `A group can have up to ${MAX_TOPICS} topics`);
  const t = await db.one(
    'INSERT INTO chat_topics (chat_id, title, icon_color, created_by) VALUES ($1, $2, $3, $4) RETURNING *',
    [chat.id, b.title, b.icon_color || 0, userId],
  );
  await require('./message.service').createSystemMessage(chat.id, userId, { event: 'topic_created', topic_id: t.id, title: t.title });
  bus.emit('chat:updated', { chatId: chat.id, memberIds: await chatService.memberIds(chat.id) });
  return serialize(t);
}

async function update(userId, chatIdRaw, topicIdRaw, body = {}) {
  const chat = await requireForum(userId, chatIdRaw);
  const t = await db.one('SELECT * FROM chat_topics WHERE id = $1 AND chat_id = $2', [v.id(topicIdRaw, 'topic_id'), chat.id]);
  if (!t) throw notFound('topic_not_found', 'Topic not found');
  if (!chatService.ADMIN_ROLES.includes(chat.my_role)) throw forbidden('not_admin', 'Only admins can change topics');
  const b = readBody(body, { partial: true });
  const r = await db.one(
    `UPDATE chat_topics SET title = COALESCE($2, title), icon_color = COALESCE($3, icon_color),
       is_closed = COALESCE($4, is_closed), is_pinned = COALESCE($5, is_pinned) WHERE id = $1 RETURNING *`,
    [t.id, b.title === undefined ? null : b.title, b.icon_color === undefined ? null : b.icon_color,
      b.is_closed === undefined ? null : b.is_closed, b.is_pinned === undefined ? null : b.is_pinned],
  );
  bus.emit('chat:updated', { chatId: chat.id, memberIds: await chatService.memberIds(chat.id) });
  return serialize(r);
}

async function remove(userId, chatIdRaw, topicIdRaw) {
  const chat = await requireForum(userId, chatIdRaw);
  if (!chatService.ADMIN_ROLES.includes(chat.my_role)) throw forbidden('not_admin', 'Only admins can delete topics');
  const t = await db.one('SELECT * FROM chat_topics WHERE id = $1 AND chat_id = $2', [v.id(topicIdRaw, 'topic_id'), chat.id]);
  if (!t) throw notFound('topic_not_found', 'Topic not found');
  const gone = await db.many(
    `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL WHERE topic_id = $1 AND deleted_at IS NULL RETURNING id`,
    [t.id],
  );
  await db.query('DELETE FROM chat_topics WHERE id = $1', [t.id]);
  const memberIds = await chatService.memberIds(chat.id);
  if (gone.length) bus.emit('message:deleted', { chatId: chat.id, messageIds: gone.map((g) => g.id), userIds: memberIds });
  bus.emit('chat:updated', { chatId: chat.id, memberIds });
  return { ok: true, deleted_messages: gone.length };
}

module.exports = { list, create, update, remove };
