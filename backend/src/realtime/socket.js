'use strict';

const { Server } = require('socket.io');
const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const presence = require('../services/presence');
const authService = require('../services/auth.service');
const chatService = require('../services/chat.service');
const messageService = require('../services/message.service');
const userService = require('../services/user.service');
const push = require('../services/push.service');
const rateLimit = require('../utils/rateLimit');
const { AppError } = require('../utils/errors');

/*
 Client → server events (all accept an optional ack callback → {ok, ...} | {ok:false, error, message}):
   message:send      { chat_id, type, text, media_id, reply_to_id, client_id }  → { ok, message }
   message:read      { chat_id, message_id }
   message:delivered { chat_id, message_id }
   typing            { chat_id }

 Server → client events:
   message:new       { chat_id, message }
   message:edited    { chat_id, message }
   message:deleted   { chat_id, message_ids }
   receipt:read      { chat_id, user_id, message_id }
   receipt:delivered { chat_id, user_id, message_id }
   chat:updated      { chat_id }     → refetch GET /api/chats/:id
   chat:removed      { chat_id }     → drop from list
   typing            { chat_id, user_id }
   presence          { user_id, online, last_seen }
   user:updated      { user_id }
   message:reactions { chat_id, message_id, reactions, user_id, emoji }
   message:poll      { chat_id, message_id, poll }        (counts only; keep your own my_votes)
   support:updated   { ticket_id }   → an admin replied to your support ticket
   session:revoked   { reason }      → log out locally
*/

let io = null;

const userRoom = (id) => `user:${id}`;
const sessionRoom = (id) => `session:${id}`;

function toAck(err) {
  if (err instanceof AppError) return { ok: false, error: err.code, message: err.message, ...(err.extra || {}) };
  // eslint-disable-next-line no-console
  console.error('Socket handler error', err);
  return { ok: false, error: 'server_error', message: 'Something went wrong' };
}

function handler(fn) {
  return async (payload, ack) => {
    const reply = typeof ack === 'function' ? ack : () => {};
    try {
      const result = await fn(payload && typeof payload === 'object' ? payload : {});
      reply({ ok: true, ...(result || {}) });
    } catch (err) {
      reply(toAck(err));
    }
  };
}

function emitToUsers(userIds, event, payload) {
  if (!io) return;
  for (const id of new Set(userIds)) io.to(userRoom(id)).emit(event, payload);
}

/** Users allowed to see `userId`'s online status: private-chat peers, filtered by privacy and blocks. */
async function presenceAudience(userId) {
  const u = await db.one('SELECT privacy_last_seen FROM users WHERE id = $1', [userId]);
  if (!u || u.privacy_last_seen === 'nobody') return [];
  const rows = await db.many(
    `SELECT DISTINCT cm2.user_id FROM chat_members cm1
     JOIN chats c ON c.id = cm1.chat_id AND c.type = 'private'
     JOIN chat_members cm2 ON cm2.chat_id = c.id AND cm2.user_id <> cm1.user_id
     WHERE cm1.user_id = $1
       AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = $1 AND b.blocked_id = cm2.user_id)
                                                OR (b.blocker_id = cm2.user_id AND b.blocked_id = $1))
       AND ($2 = 'everyone' OR EXISTS (SELECT 1 FROM contacts ct WHERE ct.owner_id = $1 AND ct.contact_id = cm2.user_id))`,
    [userId, u.privacy_last_seen],
  );
  return rows.map((r) => r.user_id);
}

async function broadcastPresence(userId, online) {
  let lastSeen = null;
  if (!online) {
    const r = await db.one('UPDATE users SET last_seen_at = now() WHERE id = $1 RETURNING last_seen_at', [userId]);
    lastSeen = r ? new Date(r.last_seen_at).toISOString() : null;
  }
  const audience = await presenceAudience(userId);
  emitToUsers(audience, 'presence', { user_id: userId, online, last_seen: lastSeen });
}

function previewText(message) {
  switch (message.type) {
    case 'image':
      return message.text ? `📷 ${message.text}` : '📷 Photo';
    case 'video':
      return message.text ? `🎬 ${message.text}` : '🎬 Video';
    case 'voice':
      return '🎤 Voice message';
    case 'file':
      return `📎 ${message.media && message.media.name ? message.media.name : 'File'}`;
    case 'poll':
      return `📊 ${message.text}`;
    default:
      return message.text;
  }
}

async function pushNewMessage({ chatId, message, memberIds, senderId }) {
  if (message.type === 'system') return;
  const offline = memberIds.filter((id) => id !== senderId && !presence.isOnline(id));
  if (offline.length === 0) return;
  const rows = await db.many(
    `SELECT user_id FROM chat_members
     WHERE chat_id = $1 AND user_id = ANY($2::bigint[]) AND (muted_until IS NULL OR muted_until < now())`,
    [chatId, offline],
  );
  const targets = rows.map((r) => r.user_id);
  if (targets.length === 0) return;
  const chat = await db.one('SELECT type, title FROM chats WHERE id = $1', [chatId]);
  if (chat.type === 'channel') {
    await push.sendToUsers(targets, { title: chat.title, body: previewText(message) }, { type: 'message', chat_id: chatId, message_id: message.id });
    return;
  }
  const senderName = message.sender
    ? userService.displayName({ ...message.sender, status: message.sender.deleted ? 'deleted' : 'active' })
    : 'Someone';
  const body = previewText(message);
  const notification =
    chat.type === 'group' ? { title: chat.title, body: `${senderName}: ${body}` } : { title: senderName, body };
  await push.sendToUsers(targets, notification, { type: 'message', chat_id: chatId, message_id: message.id });
}

function wireBus() {
  bus.on('message:new', (e) => {
    emitToUsers(e.memberIds, 'message:new', { chat_id: e.chatId, message: e.message });
    pushNewMessage(e).catch((err) => console.error('push error', err)); // eslint-disable-line no-console
  });
  bus.on('message:edited', (e) => emitToUsers(e.memberIds, 'message:edited', { chat_id: e.chatId, message: e.message }));
  bus.on('message:deleted', (e) => emitToUsers(e.userIds, 'message:deleted', { chat_id: e.chatId, message_ids: e.messageIds }));
  bus.on('chat:updated', (e) => emitToUsers(e.memberIds, 'chat:updated', { chat_id: e.chatId }));
  bus.on('chat:removed', (e) => emitToUsers(e.userIds, 'chat:removed', { chat_id: e.chatId }));
  bus.on('receipt:read', (e) =>
    emitToUsers(e.memberIds.filter((id) => id !== e.userId), 'receipt:read', {
      chat_id: e.chatId,
      user_id: e.userId,
      message_id: e.messageId,
    }),
  );
  bus.on('receipt:delivered', (e) =>
    emitToUsers(e.memberIds.filter((id) => id !== e.userId), 'receipt:delivered', {
      chat_id: e.chatId,
      user_id: e.userId,
      message_id: e.messageId,
    }),
  );
  bus.on('message:reactions', (e) =>
    emitToUsers(e.memberIds, 'message:reactions', {
      chat_id: e.chatId,
      message_id: e.messageId,
      reactions: e.reactions,
      user_id: e.userId,
    }),
  );
  bus.on('message:poll', (e) => emitToUsers(e.memberIds, 'message:poll', { chat_id: e.chatId, message_id: e.messageId, poll: e.poll }));
  bus.on('support:reply', (e) => {
    emitToUsers([e.userId], 'support:updated', { ticket_id: e.ticketId });
    if (!presence.isOnline(e.userId)) {
      push
        .sendToUsers([e.userId], { title: `Support: ${e.subject}`, body: e.text }, { type: 'support', ticket_id: e.ticketId })
        .catch(() => {});
    }
  });
  bus.on('user:updated', async ({ userId }) => {
    try {
      const rows = await db.many(
        `SELECT DISTINCT cm2.user_id FROM chat_members cm1
         JOIN chats c ON c.id = cm1.chat_id AND c.type = 'private'
         JOIN chat_members cm2 ON cm2.chat_id = c.id
         WHERE cm1.user_id = $1`,
        [userId],
      );
      emitToUsers(rows.map((r) => r.user_id), 'user:updated', { user_id: userId });
    } catch (err) {
      console.error(err); // eslint-disable-line no-console
    }
  });
  bus.on('sessions:revoked', ({ userId, sessionIds, reason }) => {
    if (!io) return;
    const rooms = sessionIds ? sessionIds.map(sessionRoom) : [userRoom(userId)];
    for (const room of rooms) {
      io.to(room).emit('session:revoked', { reason });
      io.in(room).disconnectSockets(true);
    }
  });
}

function init(httpServer) {
  io = new Server(httpServer, {
    cors: { origin: config.corsOrigins.includes('*') ? '*' : config.corsOrigins },
    maxHttpBufferSize: 1e6,
    pingInterval: 25000,
    pingTimeout: 20000,
  });

  io.use(async (socket, next) => {
    try {
      const header = socket.handshake.headers.authorization || '';
      const token = (socket.handshake.auth && socket.handshake.auth.token) || (header.startsWith('Bearer ') ? header.slice(7) : null);
      const { user, sessionId } = await authService.authenticate(token);
      socket.data.userId = user.id;
      socket.data.sessionId = sessionId;
      socket.data.memberCache = new Map(); // chatId -> expiresAt
      next();
    } catch (err) {
      const e = new Error(err instanceof AppError ? err.code : 'unauthorized');
      e.data = err instanceof AppError ? { code: err.code, message: err.message, ...(err.extra || {}) } : {};
      next(e);
    }
  });

  io.on('connection', (socket) => {
    const uid = socket.data.userId;
    socket.join(userRoom(uid));
    socket.join(sessionRoom(socket.data.sessionId));
    if (presence.add(uid)) broadcastPresence(uid, true).catch(() => {});
    messageService.markAllDelivered(uid).catch(() => {});
    db.query('UPDATE sessions SET last_active_at = now() WHERE id = $1', [socket.data.sessionId]).catch(() => {});

    async function isMember(chatId) {
      const cached = socket.data.memberCache.get(chatId);
      if (cached && cached > Date.now()) return true;
      const r = await db.one('SELECT 1 AS x FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chatId, uid]);
      if (r) socket.data.memberCache.set(chatId, Date.now() + 60 * 1000);
      return !!r;
    }

    socket.on(
      'message:send',
      handler(async (p) => {
        const r = await messageService.sendMessage(uid, p.chat_id, p);
        return r && r.scheduled ? r : { message: r };
      }),
    );
    socket.on(
      'message:read',
      handler((p) => messageService.markRead(uid, p.chat_id, p.message_id)),
    );
    socket.on(
      'message:delivered',
      handler((p) => messageService.markDelivered(uid, p.chat_id, p.message_id)),
    );
    socket.on('typing', async (p) => {
      try {
        const chatId = parseInt(p && p.chat_id, 10);
        if (!Number.isSafeInteger(chatId) || chatId <= 0) return;
        if (!rateLimit.hit(`typing:${socket.id}:${chatId}`, 1, 2500).allowed) return;
        if (!(await isMember(chatId))) return;
        const ids = (await chatService.memberIds(chatId)).filter((id) => id !== uid);
        emitToUsers(ids, 'typing', { chat_id: chatId, user_id: uid });
      } catch (_) {
        /* ignore */
      }
    });

    socket.on('disconnect', () => {
      if (presence.remove(uid)) broadcastPresence(uid, false).catch(() => {});
    });
  });

  return io;
}

wireBus();

module.exports = { init, emitToUsers };
