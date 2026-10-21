'use strict';

const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const chatService = require('./chat.service');
const mediaService = require('./media.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const SEND_TYPES = ['text', 'image', 'video', 'voice', 'file'];
const MEDIA_KINDS_FOR_TYPE = {
  image: ['image'],
  video: ['video'],
  voice: ['voice'],
  file: ['file', 'image', 'video', 'voice'],
};
const MAX_TEXT = 4096;
const MAX_CAPTION = 1024;
const BROADCAST_VIEWER = 0; // serialize as a stranger would see it (privacy-safe for fan-out)

const VISIBLE_SQL = `m.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $USER AND h.message_id = m.id)`;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function minimalUser(u) {
  if (!u) return null;
  return {
    id: u.id,
    first_name: u.first_name,
    last_name: u.last_name,
    username: u.username,
    avatar_url: u.avatar_url,
    deleted: !!u.deleted,
  };
}

/** Converts message rows to API objects (batched lookups for media, replies, senders). */
async function serializeRows(viewerId, rows) {
  if (rows.length === 0) return [];
  const replyIds = [...new Set(rows.map((r) => r.reply_to_id).filter(Boolean))];
  const replies = replyIds.length
    ? await db.many('SELECT id, sender_id, type, text, media_id, deleted_at FROM messages WHERE id = ANY($1::bigint[])', [replyIds])
    : [];
  const replyMap = new Map(replies.map((r) => [r.id, r]));

  const mediaIds = [...new Set(rows.map((r) => r.media_id).filter(Boolean))];
  const medias = mediaIds.length ? await db.many('SELECT * FROM media WHERE id = ANY($1::bigint[])', [mediaIds]) : [];
  const mediaMap = new Map(medias.map((m) => [m.id, m]));

  const userIds = [...rows.map((r) => r.sender_id), ...replies.map((r) => r.sender_id)].filter(Boolean);
  const users = await userService.getUsersMap(viewerId, userIds);

  return rows.map((m) => {
    const r = m.reply_to_id ? replyMap.get(m.reply_to_id) : null;
    const replyUser = r && r.sender_id ? users.get(r.sender_id) : null;
    return {
      id: m.id,
      chat_id: m.chat_id,
      sender_id: m.sender_id,
      sender: minimalUser(m.sender_id ? users.get(m.sender_id) : null),
      type: m.type,
      text: m.text,
      media: m.media_id ? mediaService.serialize(mediaMap.get(m.media_id)) : null,
      reply_to: r
        ? {
            id: r.id,
            sender_id: r.sender_id,
            sender_name: replyUser ? userService.displayName({ ...replyUser, status: replyUser.deleted ? 'deleted' : 'active' }) : 'Deleted Account',
            type: r.type,
            text: r.deleted_at ? '' : String(r.text || '').slice(0, 120),
            deleted: !!r.deleted_at,
          }
        : null,
      forwarded_from: m.forwarded_from_name ? { user_id: m.forwarded_from_user_id, name: m.forwarded_from_name } : null,
      meta: m.meta || null,
      client_id: m.client_id || null,
      edited_at: iso(m.edited_at),
      created_at: iso(m.created_at),
    };
  });
}

async function serializeByIds(viewerId, ids) {
  const map = new Map();
  if (!ids.length) return map;
  const rows = await db.many('SELECT * FROM messages WHERE id = ANY($1::bigint[])', [ids]);
  for (const m of await serializeRows(viewerId, rows)) map.set(m.id, m);
  return map;
}

// ------------------------------------------------------------------ reading
async function listMessages(userId, chatIdRaw, query = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const lim = v.limit(query.limit, 50, 100);
  const params = [chat.id, chat.cleared_before_id, userId];
  let cond = `m.chat_id = $1 AND m.id > $2 AND ${VISIBLE_SQL.replace(/\$USER/g, '$3')}`;
  let order = 'DESC';
  if (query.before) {
    params.push(v.id(query.before, 'before'));
    cond += ` AND m.id < $${params.length}`;
  } else if (query.after) {
    params.push(v.id(query.after, 'after'));
    cond += ` AND m.id > $${params.length}`;
    order = 'ASC';
  }
  params.push(lim);
  const rows = await db.many(`SELECT m.* FROM messages m WHERE ${cond} ORDER BY m.id ${order} LIMIT $${params.length}`, params);
  if (order === 'ASC') rows.reverse();
  return { messages: await serializeRows(userId, rows), has_more: rows.length === lim };
}

// ------------------------------------------------------------------ sending
/** Throws if `userId` may not post in `chat` (suspended group, blocked / deleted peer). */
async function assertCanSend(userId, chat) {
  if (chat.is_suspended) throw forbidden('chat_suspended', 'This group has been suspended');
  if (chat.type === 'private') {
    const peerId = await chatService.privatePeerId(chat.id, userId);
    if (peerId) {
      const peer = await db.one('SELECT id, status, banned_until FROM users WHERE id = $1', [peerId]);
      if (!peer || peer.status === 'deleted') throw forbidden('peer_deleted', 'You can’t message a deleted account');
      if (await userService.isBlockedEither(userId, peerId)) {
        throw forbidden('blocked', 'You can’t send messages to this user');
      }
    }
  }
}

function cleanText(text) {
  return typeof text === 'string' ? text.replace(/\r\n?/g, '\n').trim() : '';
}

/** Low-level insert used by send / forward / system messages. Emits message:new. */
async function insertMessage({
  chatId,
  senderId = null,
  type,
  text = '',
  mediaId = null,
  replyToId = null,
  clientId = null,
  fwdUserId = null,
  fwdName = null,
  meta = null,
}) {
  let row;
  try {
    row = await db.tx(async (c) => {
      const r = await c.query(
        `INSERT INTO messages (chat_id, sender_id, type, text, media_id, reply_to_id, client_id,
                               forwarded_from_user_id, forwarded_from_name, meta)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
        [chatId, senderId, type, text, mediaId, replyToId, clientId, fwdUserId, fwdName, meta ? JSON.stringify(meta) : null],
      );
      const m = r.rows[0];
      await c.query('UPDATE chats SET last_message_id = $2, last_message_at = $3, updated_at = now() WHERE id = $1', [
        chatId,
        m.id,
        m.created_at,
      ]);
      await c.query('UPDATE chat_members SET is_hidden = FALSE WHERE chat_id = $1 AND is_hidden', [chatId]);
      if (senderId) {
        await c.query(
          `UPDATE chat_members SET last_read_message_id = GREATEST(last_read_message_id, $3),
             last_delivered_message_id = GREATEST(last_delivered_message_id, $3)
           WHERE chat_id = $1 AND user_id = $2`,
          [chatId, senderId, m.id],
        );
      }
      return m;
    });
  } catch (err) {
    if (err.code === '23505' && clientId && senderId) {
      // Same client_id sent twice (retry after a flaky connection) → return the original.
      const existing = await db.one('SELECT * FROM messages WHERE sender_id = $1 AND client_id = $2', [senderId, clientId]);
      if (existing) return (await serializeRows(BROADCAST_VIEWER, [existing]))[0];
    }
    throw err;
  }
  const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
  const memberIds = await chatService.memberIds(chatId);
  bus.emit('message:new', { chatId, message, memberIds, senderId });
  return message;
}

async function createSystemMessage(chatId, actorId, meta) {
  return insertMessage({ chatId, senderId: actorId, type: 'system', meta });
}

async function sendMessage(userId, chatIdRaw, body = {}) {
  rateLimit.enforce(`msg:${userId}`, 30, 10 * 1000, 'You are sending messages too fast');
  const chat = await chatService.requireMember(chatIdRaw, userId);
  await assertCanSend(userId, chat);

  const type = v.oneOf(body.type || 'text', SEND_TYPES, 'type');
  const clientId = body.client_id ? v.str(String(body.client_id), { field: 'client_id', max: 64 }) : null;
  if (clientId) {
    const existing = await db.one('SELECT * FROM messages WHERE sender_id = $1 AND client_id = $2', [userId, clientId]);
    if (existing) return (await serializeRows(userId, [existing]))[0];
  }

  const text = cleanText(body.text);
  let mediaId = null;
  if (type === 'text') {
    if (!text) throw badRequest('empty_message', 'Message is empty');
    if (text.length > MAX_TEXT) throw badRequest('message_too_long', `Messages can be at most ${MAX_TEXT} characters`);
  } else {
    if (text.length > MAX_CAPTION) throw badRequest('caption_too_long', `Captions can be at most ${MAX_CAPTION} characters`);
    const media = await db.one('SELECT * FROM media WHERE id = $1 AND uploader_id = $2', [v.id(body.media_id, 'media_id'), userId]);
    if (!media) throw notFound('media_not_found', 'Upload the file first');
    if (!MEDIA_KINDS_FOR_TYPE[type].includes(media.kind)) throw badRequest('invalid_media', `This file can't be sent as ${type}`);
    mediaId = media.id;
  }

  let replyToId = null;
  if (body.reply_to_id) {
    const r = await db.one('SELECT id FROM messages WHERE id = $1 AND chat_id = $2 AND deleted_at IS NULL', [
      v.id(body.reply_to_id, 'reply_to_id'),
      chat.id,
    ]);
    if (!r) throw notFound('reply_not_found', 'The message you are replying to no longer exists');
    replyToId = r.id;
  }

  return insertMessage({ chatId: chat.id, senderId: userId, type, text, mediaId, replyToId, clientId });
}

async function forwardMessages(userId, body = {}) {
  const from = await chatService.requireMember(body.from_chat_id, userId);
  const ids = v.idList(body.message_ids, 'message_ids', 100);
  const targets = v.idList(body.to_chat_ids, 'to_chat_ids', 10);
  if (!ids.length || !targets.length) throw badRequest('invalid_input', 'Nothing to forward');
  rateLimit.enforce(`fwd:${userId}`, 20, 60 * 1000, 'You are forwarding too fast');

  const rows = await db.many(
    `SELECT m.* FROM messages m
     WHERE m.chat_id = $1 AND m.id = ANY($2::bigint[]) AND m.id > $3 AND m.type <> 'system'
       AND ${VISIBLE_SQL.replace(/\$USER/g, '$4')}
     ORDER BY m.id`,
    [from.id, ids, from.cleared_before_id, userId],
  );
  if (!rows.length) throw notFound('message_not_found', 'Messages not found');
  const senders = await db.many('SELECT * FROM users WHERE id = ANY($1::bigint[])', [
    rows.map((r) => r.sender_id).filter(Boolean),
  ]);
  const senderMap = new Map(senders.map((u) => [u.id, u]));

  const targetChats = [];
  for (const t of targets) {
    const chat = await chatService.requireMember(t, userId);
    await assertCanSend(userId, chat);
    targetChats.push(chat);
  }
  let count = 0;
  for (const chat of targetChats) {
    for (const r of rows) {
      await insertMessage({
        chatId: chat.id,
        senderId: userId,
        type: r.type,
        text: r.text,
        mediaId: r.media_id,
        fwdUserId: r.forwarded_from_user_id || r.sender_id,
        fwdName: r.forwarded_from_name || userService.displayName(senderMap.get(r.sender_id)),
      });
      count += 1;
    }
  }
  return { forwarded: count };
}

// ------------------------------------------------------------------ editing / deleting
async function editMessage(userId, messageIdRaw, body = {}) {
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND deleted_at IS NULL', [v.id(messageIdRaw, 'message_id')]);
  if (!m) throw notFound('message_not_found', 'Message not found');
  await chatService.requireMember(m.chat_id, userId);
  if (m.sender_id !== userId || m.type === 'system' || m.forwarded_from_name) {
    throw forbidden('cannot_edit', 'You can only edit your own messages');
  }
  const hours = await settings.get('message_edit_window_hours');
  if (hours > 0 && Date.now() - new Date(m.created_at).getTime() > hours * 3600 * 1000) {
    throw forbidden('edit_window_passed', 'This message is too old to edit');
  }
  const text = cleanText(body.text);
  if (m.type === 'text' && !text) throw badRequest('empty_message', 'Message is empty');
  const max = m.type === 'text' ? MAX_TEXT : MAX_CAPTION;
  if (text.length > max) throw badRequest('message_too_long', `At most ${max} characters`);
  if (text === m.text) return (await serializeRows(userId, [m]))[0];

  const row = await db.one('UPDATE messages SET text = $2, edited_at = now() WHERE id = $1 RETURNING *', [m.id, text]);
  const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
  bus.emit('message:edited', { chatId: m.chat_id, message, memberIds: await chatService.memberIds(m.chat_id) });
  return message;
}

/**
 * Deletes messages. forEveryone: own messages anywhere; in private chats both sides' messages;
 * in groups admins may delete any message. Otherwise "delete for me" (hidden only for this user).
 */
async function deleteMessages(userId, chatIdRaw, body = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const ids = v.idList(body.message_ids, 'message_ids', 100);
  const forEveryone = body.for_everyone === true;
  const rows = await db.many(
    'SELECT id, sender_id, type FROM messages WHERE chat_id = $1 AND id = ANY($2::bigint[]) AND deleted_at IS NULL',
    [chat.id, ids],
  );
  if (!rows.length) return { deleted: 0 };
  const found = rows.map((r) => r.id);

  if (forEveryone) {
    const isAdmin = chat.type === 'group' && chatService.ADMIN_ROLES.includes(chat.my_role);
    for (const r of rows) {
      const own = r.sender_id === userId && r.type !== 'system';
      const allowed = own || isAdmin || (chat.type === 'private' && r.type !== 'system');
      if (!allowed) throw forbidden('cannot_delete', 'You can only delete your own messages for everyone');
    }
    await db.query(
      `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL
       WHERE id = ANY($1::bigint[])`,
      [found],
    );
    bus.emit('message:deleted', { chatId: chat.id, messageIds: found, userIds: await chatService.memberIds(chat.id) });
  } else {
    await db.query(
      `INSERT INTO message_hidden (user_id, message_id) SELECT $1, x FROM unnest($2::bigint[]) AS x ON CONFLICT DO NOTHING`,
      [userId, found],
    );
    bus.emit('message:deleted', { chatId: chat.id, messageIds: found, userIds: [userId] });
  }
  return { deleted: found.length };
}

/** Admin moderation delete (no membership required). */
async function adminDeleteMessage(messageId) {
  const m = await db.one(
    `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL
     WHERE id = $1 AND deleted_at IS NULL RETURNING id, chat_id`,
    [messageId],
  );
  if (m) {
    bus.emit('message:deleted', { chatId: m.chat_id, messageIds: [m.id], userIds: await chatService.memberIds(m.chat_id) });
  }
  return !!m;
}

// ------------------------------------------------------------------ receipts
async function chatMaxMessageId(chatId) {
  const r = await db.one('SELECT COALESCE(max(id), 0) AS id FROM messages WHERE chat_id = $1', [chatId]);
  return r.id;
}

async function markRead(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const target = Math.min(v.id(messageIdRaw, 'message_id'), await chatMaxMessageId(chat.id));
  const r = await db.one(
    `UPDATE chat_members SET last_read_message_id = $3,
       last_delivered_message_id = GREATEST(last_delivered_message_id, $3)
     WHERE chat_id = $1 AND user_id = $2 AND last_read_message_id < $3
     RETURNING last_read_message_id`,
    [chat.id, userId, target],
  );
  if (r) {
    bus.emit('receipt:read', { chatId: chat.id, userId, messageId: target, memberIds: await chatService.memberIds(chat.id) });
  }
  return { last_read_message_id: r ? r.last_read_message_id : chat.last_read_message_id };
}

async function markDelivered(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const target = Math.min(v.id(messageIdRaw, 'message_id'), await chatMaxMessageId(chat.id));
  const r = await db.one(
    `UPDATE chat_members SET last_delivered_message_id = $3
     WHERE chat_id = $1 AND user_id = $2 AND last_delivered_message_id < $3 RETURNING chat_id`,
    [chat.id, userId, target],
  );
  if (r) {
    bus.emit('receipt:delivered', { chatId: chat.id, userId, messageId: target, memberIds: await chatService.memberIds(chat.id) });
  }
  return { ok: true };
}

/** Called when a user's device connects: everything up to now counts as delivered. */
async function markAllDelivered(userId) {
  const rows = await db.many(
    `UPDATE chat_members cm SET last_delivered_message_id = c.last_message_id
     FROM chats c
     WHERE c.id = cm.chat_id AND cm.user_id = $1 AND c.last_message_id > cm.last_delivered_message_id
     RETURNING cm.chat_id, cm.last_delivered_message_id`,
    [userId],
  );
  for (const r of rows) {
    bus.emit('receipt:delivered', {
      chatId: r.chat_id,
      userId,
      messageId: r.last_delivered_message_id,
      memberIds: await chatService.memberIds(r.chat_id),
    });
  }
  return rows.length;
}

module.exports = {
  serializeRows,
  serializeByIds,
  listMessages,
  sendMessage,
  forwardMessages,
  editMessage,
  deleteMessages,
  adminDeleteMessage,
  createSystemMessage,
  markRead,
  markDelivered,
  markAllDelivered,
};
