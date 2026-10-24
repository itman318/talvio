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
const callService = require('../services/call.service');
const secretService = require('../services/secret.service');
const rateLimit = require('../utils/rateLimit');
const { AppError } = require('../utils/errors');

/*
 Client → server events (all accept an optional ack callback → {ok, ...} | {ok:false, error, message}):
   message:send      { chat_id, type, text, media_id, reply_to_id, client_id }  → { ok, message }
   message:read      { chat_id, message_id }
   message:delivered { chat_id, message_id }
   typing            { chat_id }
   call:start        { user_id | chat_id, video }            → { ok, call, ice_servers }  (call.status 'busy' = line busy)
   call:accept       { call_id }                            → { ok, call, ice_servers }
   call:decline      { call_id }
   call:hangup       { call_id, reason?: 'hangup'|'failed' }
   call:signal       { call_id, kind: offer|answer|ice|media, sdp?, candidate?, muted?, video_off?, ice_restart? }
   secret:create     { user_id, public_key }                 → { ok, secret_chat }
   secret:accept     { secret_chat_id, public_key }          → { ok, secret_chat }
   secret:close      { secret_chat_id }                      (decline a request or close the chat)
   secret:send       { secret_chat_id, ciphertext, media_id?, ttl_sec, client_id } → { ok, message:{id, created_at} }
   secret:ack        { secret_chat_id, message_ids }         (stored on this device → server forgets the ciphertext)
   secret:read       { secret_chat_id, max_id }
   secret:typing     { secret_chat_id }
   secret:delete     { secret_chat_id, message_ids }         (delete for both)
   secret:notify     { secret_chat_id, kind: 'screenshot' }

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
   call:incoming     { call }        → ring (all of the callee's devices)
   call:accepted     { call_id }     → caller: create the WebRTC offer · callee's other devices: stop ringing
   call:signal       { call_id, kind, sdp?, candidate?, muted?, video_off? }  (only to the device on the call)
   call:ended        { call_id, status, end_reason, duration_sec }
   secret:request    { secret_chat }   → all of the peer's devices; the first to accept owns the chat
   secret:accepted   { secret_chat }   → the initiating device (their_key = peer's public key)
   secret:taken      { secret_chat_id, session_id }  → peer's other devices drop the request
   secret:closed     { secret_chat_id, reason }
   secret:message    { message }       → only to the other device of the chat (ciphertext)
   secret:delivered  { secret_chat_id, message_ids } · secret:read { secret_chat_id, max_id, read_at }
   secret:typing     { secret_chat_id } · secret:deleted { secret_chat_id, message_ids } · secret:notify { secret_chat_id, kind }
*/

let io = null;
const CALL_GRACE_MS = 15 * 1000;

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
  if (!u) return [];
  // "last seen" privacy + its exceptions (always / never share with)
  const rows = await db.many(
    `SELECT DISTINCT cm2.user_id FROM chat_members cm1
     JOIN chats c ON c.id = cm1.chat_id AND c.type = 'private'
     JOIN chat_members cm2 ON cm2.chat_id = c.id AND cm2.user_id <> cm1.user_id
     LEFT JOIN privacy_exceptions pe ON pe.owner_id = $1 AND pe.setting = 'last_seen' AND pe.target_id = cm2.user_id
     WHERE cm1.user_id = $1
       AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = $1 AND b.blocked_id = cm2.user_id)
                                                OR (b.blocker_id = cm2.user_id AND b.blocked_id = $1))
       AND (pe.allow IS TRUE OR (pe.allow IS NULL AND (
             $2 = 'everyone'
             OR ($2 = 'contacts' AND EXISTS (SELECT 1 FROM contacts ct WHERE ct.owner_id = $1 AND ct.contact_id = cm2.user_id)))))`,
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
  // Talvio custom emoji (Private Use Area U+E900…) show as a fox in notifications
  return previewRaw(message).replace(/[\uE900-\uE9FF]/g, '🦊');
}

function previewRaw(message) {
  if (message.view_once) return message.type === 'voice' ? '🎤 View once voice message' : message.type === 'video' ? '🎬 View once video' : '📷 View once photo';
  switch (message.type) {
    case 'image':
      return message.text ? `📷 ${message.text}` : '📷 Photo';
    case 'video':
      return message.text ? `🎬 ${message.text}` : '🎬 Video';
    case 'voice':
      return '🎤 Voice message';
    case 'video_note':
      return '📹 Video message';
    case 'file':
      return `📎 ${message.media && message.media.name ? message.media.name : 'File'}`;
    case 'poll':
      return `📊 ${message.text}`;
    case 'location':
      return message.meta && message.meta.live ? '📍 Live location' : '📍 Location';
    case 'sticker':
      return `${(message.meta && message.meta.sticker && message.meta.sticker.emoji) || '🙂'} Sticker`;
    case 'gif':
      return message.text ? `GIF · ${message.text}` : 'GIF';
    case 'contact':
      return `👤 ${(message.meta && message.meta.contact && message.meta.contact.name) || 'Contact'}`;
    default:
      // **bold** _italic_ ~strike~ `code` → plain; ||spoiler|| stays hidden
      return String(message.text || '')
        .replace(/\|\|([^\n]+?)\|\|/g, '▒▒▒▒')
        .replace(/\*\*([^\n]+?)\*\*/g, '$1')
        .replace(/`([^`\n]+)`/g, '$1')
        .replace(/(^|[^\w~])~([^\n~]+?)~(?![\w~])/g, '$1$2')
        .replace(/(^|[^\w\\])_([^\n_]+?)_(?!\w)/g, '$1$2');
  }
}

async function pushNewMessage({ chatId, message, memberIds, senderId }) {
  if (message.type === 'system' || message.silent || message.thread_id) return;
  const offline = memberIds.filter((id) => id !== senderId && !presence.isOnline(id));
  if (offline.length === 0) return;
  // muted chats still notify people who were @mentioned / replied to
  const rows = await db.many(
    `SELECT user_id, is_locked FROM chat_members
     WHERE chat_id = $1 AND user_id = ANY($2::bigint[]) AND NOT is_request
       AND (muted_until IS NULL OR muted_until < now() OR user_id = ANY($3::bigint[]))`,
    [chatId, offline, message.mentions || []],
  );
  // locked chats: a plain "New message" (no name, no text) — the phone opens the chat after the fingerprint
  const locked = rows.filter((r) => r.is_locked).map((r) => r.user_id);
  if (locked.length) {
    await push.sendToUsers(locked, { title: 'Talvio', body: 'New message' }, { type: 'message', chat_id: chatId, message_id: message.id, locked: 1 });
  }
  const targets = rows.filter((r) => !r.is_locked).map((r) => r.user_id);
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
  const notify = require('../services/notify.service');
  await push.sendToUsers(targets, notification, {
    type: 'message',
    chat_id: chatId,
    message_id: message.id,
    chat_title: chat.type === 'group' ? chat.title : senderName,
    sender: senderName,
    group: chat.type === 'group' ? 1 : 0,
  }, {
    dataOnlyAndroid: true,
    category: 'MESSAGE',
    perSession: (row) => ({ reply_token: notify.replyToken(row.user_id, row.id, chatId) }),
  });
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
  bus.on('draft:updated', (e) => emitToUsers([e.userId], 'draft:updated', { chat_id: e.chatId, text: e.text, at: e.at }));
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
  const relay = ({ event, payload, userIds, sessionIds }) => {
    if (!io) return;
    if (userIds && userIds.length) emitToUsers(userIds, event, payload);
    for (const sid of sessionIds || []) if (sid) io.to(sessionRoom(sid)).emit(event, payload);
  };
  bus.on('call:emit', relay);
  bus.on('rt:emit', relay);
  bus.on('sessions:revoked', ({ userId, sessionIds, reason }) => {
    (sessionIds ? Promise.all(sessionIds.map((id) => callService.endBySession(id))) : callService.endByUser(userId)).catch(() => {});
    (sessionIds ? Promise.all(sessionIds.map((id) => secretService.closeBySession(id))) : secretService.closeByUser(userId)).catch(() => {});
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
      if (await require('../http/middleware').isIpBlocked(socket.handshake.address)) throw new AppError(403, 'ip_blocked', 'Blocked');
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
        return r && (r.scheduled || r.queued) ? r : { message: r };
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
    // "typing…", "recording a voice message…", "sending a photo…" (cancel = stopped)
    const TYPING_ACTIONS = ['typing', 'recording_voice', 'recording_video', 'uploading_photo', 'uploading_video', 'uploading_file', 'choosing_sticker', 'cancel'];
    socket.on('typing', async (p) => {
      try {
        const chatId = parseInt(p && p.chat_id, 10);
        if (!Number.isSafeInteger(chatId) || chatId <= 0) return;
        const action = TYPING_ACTIONS.includes(p && p.action) ? p.action : 'typing';
        if (!rateLimit.hit(`typing:${socket.id}:${chatId}:${action}`, 1, 2500).allowed) return;
        if (!(await isMember(chatId))) return;
        const ids = (await chatService.memberIds(chatId)).filter((id) => id !== uid);
        emitToUsers(ids, 'typing', { chat_id: chatId, user_id: uid, action });
      } catch (_) {
        /* ignore */
      }
    });

    const callLimit = (fn, limit = 300) => async (p, ack) => {
      if (!rateLimit.hit(`callsig:${socket.id}`, limit, 10 * 1000).allowed) {
        if (typeof ack === 'function') ack({ ok: false, error: 'rate_limited', message: 'Slow down' });
        return;
      }
      return fn(p, ack);
    };
    const sid = socket.data.sessionId;
    socket.on('call:start', handler((p) => callService.startCall(uid, sid, p)));
    socket.on('call:accept', handler((p) => callService.acceptCall(uid, sid, p.call_id)));
    socket.on('call:decline', handler((p) => callService.declineCall(uid, p.call_id)));
    socket.on('call:hangup', handler((p) => callService.hangup(uid, p.call_id, p.reason)));
    socket.on('call:signal', callLimit(handler((p) => callService.relaySignal(uid, sid, p))));

    socket.on('secret:create', handler((p) => secretService.create(uid, sid, p)));
    socket.on('secret:accept', handler((p) => secretService.accept(uid, sid, p.secret_chat_id, p)));
    socket.on('secret:close', handler((p) => secretService.close(uid, sid, p.secret_chat_id)));
    socket.on('secret:send', handler((p) => secretService.send(uid, sid, p)));
    socket.on('secret:ack', handler((p) => secretService.ack(uid, sid, p)));
    socket.on('secret:read', handler((p) => secretService.markRead(uid, sid, p)));
    socket.on('secret:typing', handler((p) => secretService.typing(uid, sid, p)));
    socket.on('secret:delete', handler((p) => secretService.deleteMessages(uid, sid, p)));
    socket.on('secret:notify', handler((p) => secretService.notify(uid, sid, p)));

    socket.on('disconnect', () => {
      if (presence.remove(uid)) broadcastPresence(uid, false).catch(() => {});
      // Give a flaky mobile connection a moment to come back before dropping this device's call.
      const t = setTimeout(async () => {
        try {
          if (!io) return;
          const still = await io.in(sessionRoom(sid)).fetchSockets();
          if (still.length === 0) await callService.endBySession(sid);
        } catch (_) {
          /* ignore */
        }
      }, CALL_GRACE_MS);
      if (t.unref) t.unref();
    });
  });

  return io;
}

wireBus();

module.exports = { init, emitToUsers };
