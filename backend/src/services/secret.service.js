'use strict';

/**
 * Secret chats — end-to-end encrypted, bound to ONE device on each side.
 *
 * The server never sees keys or content. It only:
 *   - passes the two devices' public X25519 keys to each other (key exchange),
 *   - relays opaque ciphertext to the other device and forgets it once delivered,
 *   - relays receipts / typing / "delete for both" and enforces who may talk on which chat.
 *
 * Crypto (done in the app): X25519 → HKDF-SHA256 → per-direction hash ratchet → AES-256-GCM.
 */
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const moderation = require('./moderation.service');
const presence = require('./presence');
const push = require('./push.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const KEY_RE = /^[A-Za-z0-9+/]{43}=$/; // 32-byte key, base64
const MAX_CIPHERTEXT = 100000; // ~64 KB of plaintext after base64 + overhead
const TTL_VALUES = [0, 1, 2, 3, 4, 5, 10, 15, 30, 60, 300, 3600, 86400, 604800];
const MAX_OPEN_PER_DEVICE = 200;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function emit(event, payload, { userIds = [], sessionIds = [] }) {
  bus.emit('rt:emit', { event, payload, userIds, sessionIds });
}

function parseKey(raw) {
  if (typeof raw !== 'string' || !KEY_RE.test(raw)) throw badRequest('invalid_key', 'Invalid public key');
  return raw;
}

function roleOf(row, userId, sessionId) {
  if (row.initiator_id === userId && row.initiator_session_id === sessionId) return 'initiator';
  if (row.peer_id === userId && row.peer_session_id === sessionId) return 'peer';
  return null;
}

function otherSide(row, role) {
  return role === 'initiator'
    ? { userId: row.peer_id, sessionId: row.peer_session_id }
    : { userId: row.initiator_id, sessionId: row.initiator_session_id };
}

function serialize(row, viewerId, users) {
  const initiator = row.initiator_id === viewerId;
  const peerId = initiator ? row.peer_id : row.initiator_id;
  return {
    id: row.id,
    status: row.status,
    is_initiator: initiator,
    peer_id: peerId,
    peer: users ? users.get(peerId) || null : null,
    // the OTHER device's public key (null until the peer accepts)
    their_key: initiator ? row.peer_key : row.initiator_key,
    initiator_key: row.initiator_key,
    peer_key: row.peer_key,
    close_reason: row.close_reason || null,
    created_at: iso(row.created_at),
    accepted_at: iso(row.accepted_at),
    closed_at: iso(row.closed_at),
    last_message_at: iso(row.last_message_at),
  };
}

async function serializeOne(row, viewerId) {
  const users = await userService.getUsersMap(viewerId, [row.initiator_id, row.peer_id]);
  return serialize(row, viewerId, users);
}

/** Loads an active chat and checks that this exact device is one of its two ends. */
async function requireDevice(userId, sessionId, chatIdRaw, { allowRequested = false } = {}) {
  const row = await db.one('SELECT * FROM secret_chats WHERE id = $1', [v.id(chatIdRaw, 'secret_chat_id')]);
  if (!row || (row.initiator_id !== userId && row.peer_id !== userId)) throw notFound('secret_chat_not_found', 'Vault chat not found');
  if (row.status === 'closed') throw conflict('secret_chat_closed', 'This vault chat was closed');
  if (row.status === 'requested' && !allowRequested) throw conflict('secret_chat_pending', 'Waiting for the other person to come online');
  const role = roleOf(row, userId, sessionId);
  if (!role) throw forbidden('wrong_device', 'This vault chat is on another device');
  return { row, role };
}

// ------------------------------------------------------------------ lifecycle
async function create(userId, sessionId, body = {}) {
  await settings.requireFeature('feature_secret_chats', 'Vault chats');
  const peerId = v.id(body.user_id, 'user_id');
  const key = parseKey(body.public_key);
  if (peerId === userId) throw badRequest('invalid_input', 'You can’t start a vault chat with yourself');
  const me = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  moderation.assertNotRestricted(me);
  const peer = await db.one('SELECT id, status FROM users WHERE id = $1', [peerId]);
  if (!peer || peer.status !== 'active') throw notFound('user_not_found', 'User not found');
  if (await userService.isBlockedEither(userId, peerId)) throw forbidden('blocked', 'You can’t start a vault chat with this user');
  rateLimit.enforce(`secret:new:${userId}`, 10, 60 * 60 * 1000, 'You started too many vault chats. Try again later.');
  const open = await db.one(
    `SELECT count(*)::int AS n FROM secret_chats WHERE status <> 'closed' AND (initiator_session_id = $1 OR peer_session_id = $1)`,
    [sessionId],
  );
  if (open.n >= MAX_OPEN_PER_DEVICE) throw forbidden('too_many_secret_chats', 'Close some vault chats first');

  const row = await db.one(
    `INSERT INTO secret_chats (initiator_id, initiator_session_id, initiator_key, peer_id) VALUES ($1, $2, $3, $4) RETURNING *`,
    [userId, sessionId, key, peerId],
  );
  emit('secret:request', { secret_chat: await serializeOne(row, peerId) }, { userIds: [peerId] });
  push
    .sendToUsers([peerId], { title: userService.displayName(me), body: '🔒 Wants to start a vault chat' }, { type: 'secret', secret_chat_id: row.id })
    .catch(() => {});
  return { secret_chat: await serializeOne(row, userId) };
}

/** The first of the peer's devices to accept owns the chat (the app does this automatically). */
async function accept(userId, sessionId, chatIdRaw, body = {}) {
  const key = parseKey(body.public_key);
  const row = await db.tx(async (c) => {
    const r = await c.query('SELECT * FROM secret_chats WHERE id = $1 FOR UPDATE', [v.id(chatIdRaw, 'secret_chat_id')]);
    const sc = r.rows[0];
    if (!sc || sc.peer_id !== userId) throw notFound('secret_chat_not_found', 'Vault chat not found');
    if (sc.status === 'closed') throw conflict('secret_chat_closed', 'This vault chat was closed');
    if (sc.status === 'active') {
      if (sc.peer_session_id === sessionId) return sc;
      throw conflict('accepted_elsewhere', 'This vault chat was accepted on another device');
    }
    const u = await c.query(
      `UPDATE secret_chats SET status = 'active', peer_session_id = $2, peer_key = $3, accepted_at = now() WHERE id = $1 RETURNING *`,
      [sc.id, sessionId, key],
    );
    return u.rows[0];
  });
  emit('secret:accepted', { secret_chat: await serializeOne(row, row.initiator_id) }, { sessionIds: [row.initiator_session_id] });
  // the peer's other devices drop the request
  emit('secret:taken', { secret_chat_id: row.id, session_id: sessionId }, { userIds: [userId] });
  return { secret_chat: await serializeOne(row, userId) };
}

async function finish(row, by, reason) {
  const r = await db.one(
    `UPDATE secret_chats SET status = 'closed', closed_by = $2, close_reason = $3, closed_at = now()
     WHERE id = $1 AND status <> 'closed' RETURNING *`,
    [row.id, by, reason],
  );
  if (!r) return null;
  await db.query('DELETE FROM secret_messages WHERE secret_chat_id = $1', [row.id]);
  emit('secret:closed', { secret_chat_id: row.id, reason }, { userIds: [row.initiator_id, row.peer_id] });
  return r;
}

/** Decline a request (any of the peer's devices) or close a chat (one of its two devices). */
async function close(userId, sessionId, chatIdRaw) {
  const row = await db.one('SELECT * FROM secret_chats WHERE id = $1', [v.id(chatIdRaw, 'secret_chat_id')]);
  if (!row || (row.initiator_id !== userId && row.peer_id !== userId)) throw notFound('secret_chat_not_found', 'Vault chat not found');
  if (row.status === 'closed') return { ok: true };
  const may = roleOf(row, userId, sessionId) || (row.status === 'requested' && row.peer_id === userId);
  if (!may) throw forbidden('wrong_device', 'This vault chat is on another device');
  await finish(row, userId, row.status === 'requested' && row.peer_id === userId ? 'declined' : 'closed');
  return { ok: true };
}

/** A device logged out / was revoked: its secret chats can never be decrypted again. */
async function closeBySession(sessionId) {
  const rows = await db.many(
    `SELECT * FROM secret_chats WHERE status <> 'closed' AND (initiator_session_id = $1 OR peer_session_id = $1)`,
    [sessionId],
  );
  for (const r of rows) await finish(r, r.initiator_session_id === sessionId ? r.initiator_id : r.peer_id, 'device_logged_out');
  return rows.length;
}

async function closeByUser(userId) {
  const rows = await db.many(`SELECT * FROM secret_chats WHERE status <> 'closed' AND (initiator_id = $1 OR peer_id = $1)`, [userId]);
  for (const r of rows) await finish(r, userId, 'device_logged_out');
  return rows.length;
}

/** Secret chats that live on this device, plus requests waiting for any of my devices. */
async function list(userId, sessionId) {
  const rows = await db.many(
    `SELECT * FROM secret_chats
     WHERE (initiator_session_id = $2 OR peer_session_id = $2 OR (peer_id = $1 AND status = 'requested'))
       AND (status <> 'closed' OR closed_at > now() - interval '7 days')
     ORDER BY COALESCE(last_message_at, accepted_at, created_at) DESC LIMIT 300`,
    [userId, sessionId],
  );
  const users = await userService.getUsersMap(userId, rows.flatMap((r) => [r.initiator_id, r.peer_id]));
  return rows.map((r) => serialize(r, userId, users));
}

// ------------------------------------------------------------------ messages (opaque)
function serializeMessage(m) {
  return {
    id: m.id,
    secret_chat_id: m.secret_chat_id,
    sender_id: m.sender_id,
    client_id: m.client_id,
    ciphertext: m.ciphertext,
    media_id: m.media_id,
    ttl_sec: m.ttl_sec,
    created_at: iso(m.created_at),
  };
}

async function send(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  const me = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  moderation.assertNotRestricted(me);
  if (typeof body.ciphertext !== 'string' || body.ciphertext.length < 16 || body.ciphertext.length > MAX_CIPHERTEXT) {
    throw badRequest('invalid_ciphertext', 'Invalid encrypted message');
  }
  const ttl = body.ttl_sec === undefined ? 0 : parseInt(body.ttl_sec, 10);
  if (!TTL_VALUES.includes(ttl)) throw badRequest('invalid_input', 'Invalid self-destruct timer');
  let mediaId = null;
  if (body.media_id !== undefined && body.media_id !== null) {
    mediaId = v.id(body.media_id, 'media_id');
    const m = await db.one('SELECT id FROM media WHERE id = $1 AND uploader_id = $2', [mediaId, userId]);
    if (!m) throw badRequest('invalid_media', 'Upload the encrypted file first');
  }
  const clientId = body.client_id ? v.str(String(body.client_id), { field: 'client_id', max: 64 }) : null;
  rateLimit.enforce(`secret:msg:${userId}`, 60, 60 * 1000, 'You are sending messages too fast');
  let m;
  try {
    m = await db.one(
      `INSERT INTO secret_messages (secret_chat_id, sender_id, client_id, ciphertext, media_id, ttl_sec)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
      [row.id, userId, clientId, body.ciphertext, mediaId, ttl],
    );
  } catch (err) {
    if (err.code === '23505' && clientId) {
      const existing = await db.one('SELECT * FROM secret_messages WHERE sender_id = $1 AND client_id = $2', [userId, clientId]);
      if (existing) return { message: { id: existing.id, client_id: clientId, created_at: iso(existing.created_at) } };
    }
    throw err;
  }
  await db.query('UPDATE secret_chats SET last_message_at = now() WHERE id = $1', [row.id]);
  const other = otherSide(row, role);
  emit('secret:message', { message: serializeMessage(m) }, { sessionIds: [other.sessionId] });
  if (!presence.isActive(other.userId)) {
    push
      .sendToUsers([other.userId], { title: userService.displayName(me), body: '🔒 New secret message' }, { type: 'secret', secret_chat_id: row.id })
      .catch(() => {});
  }
  return { message: { id: m.id, client_id: clientId, created_at: iso(m.created_at) } };
}

/** Messages this device hasn't received yet (after being offline). */
async function pending(userId, sessionId) {
  const rows = await db.many(
    `SELECT sm.* FROM secret_messages sm JOIN secret_chats sc ON sc.id = sm.secret_chat_id
     WHERE sc.status = 'active' AND sm.delivered_at IS NULL AND sm.sender_id <> $1
       AND ((sc.initiator_id = $1 AND sc.initiator_session_id = $2) OR (sc.peer_id = $1 AND sc.peer_session_id = $2))
     ORDER BY sm.id LIMIT 1000`,
    [userId, sessionId],
  );
  return rows.map(serializeMessage);
}

/** Receiving device confirms it stored the messages → the server drops the ciphertext. */
async function ack(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  const ids = v.idList(body.message_ids, 'message_ids', 1000);
  const r = await db.many(
    `UPDATE secret_messages SET delivered_at = now(), ciphertext = NULL
     WHERE secret_chat_id = $1 AND id = ANY($2::bigint[]) AND sender_id <> $3 AND delivered_at IS NULL RETURNING id`,
    [row.id, ids, userId],
  );
  if (r.length) emit('secret:delivered', { secret_chat_id: row.id, message_ids: r.map((x) => x.id) }, { sessionIds: [otherSide(row, role).sessionId] });
  return { acked: r.length };
}

async function markRead(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  const maxId = v.id(body.max_id, 'max_id');
  await db.query(
    `UPDATE secret_messages SET read_at = now() WHERE secret_chat_id = $1 AND sender_id <> $2 AND id <= $3 AND read_at IS NULL`,
    [row.id, userId, maxId],
  );
  emit('secret:read', { secret_chat_id: row.id, max_id: maxId, read_at: new Date().toISOString() }, { sessionIds: [otherSide(row, role).sessionId] });
  return { ok: true };
}

async function typing(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  if (!rateLimit.hit(`secret:typing:${sessionId}:${row.id}`, 1, 2500).allowed) return {};
  emit('secret:typing', { secret_chat_id: row.id }, { sessionIds: [otherSide(row, role).sessionId] });
  return {};
}

/** "Delete for both": the other device removes these messages; undelivered copies are dropped here. */
async function deleteMessages(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  const ids = v.idList(body.message_ids, 'message_ids', 500);
  await db.query('DELETE FROM secret_messages WHERE secret_chat_id = $1 AND id = ANY($2::bigint[])', [row.id, ids]);
  emit('secret:deleted', { secret_chat_id: row.id, message_ids: ids }, { sessionIds: [otherSide(row, role).sessionId] });
  return { ok: true };
}

/** Relays an encrypted "screenshot taken" / timer-change service note (content stays encrypted). */
async function notify(userId, sessionId, body = {}) {
  const { row, role } = await requireDevice(userId, sessionId, body.secret_chat_id);
  const kind = v.oneOf(body.kind, ['screenshot'], 'kind');
  emit('secret:notify', { secret_chat_id: row.id, kind }, { sessionIds: [otherSide(row, role).sessionId] });
  return { ok: true };
}

/** Housekeeping (scheduler): forget delivered rows, expire very old undelivered ones, drop stale requests. */
async function sweep() {
  const a = await db.many(`DELETE FROM secret_messages WHERE delivered_at < now() - interval '2 days' RETURNING id`);
  const b = await db.many(`DELETE FROM secret_messages WHERE delivered_at IS NULL AND created_at < now() - interval '30 days' RETURNING id`);
  const stale = await db.many(`SELECT * FROM secret_chats WHERE status = 'requested' AND created_at < now() - interval '14 days'`);
  for (const r of stale) await finish(r, null, 'expired');
  return a.length + b.length + stale.length;
}

async function adminStats() {
  return db.one(
    `SELECT
       (SELECT count(*)::int FROM secret_chats WHERE status = 'active') AS active,
       (SELECT count(*)::int FROM secret_chats WHERE status = 'requested') AS waiting,
       (SELECT count(*)::int FROM secret_chats WHERE created_at >= date_trunc('day', now())) AS created_today,
       (SELECT count(*)::int FROM secret_messages WHERE created_at >= date_trunc('day', now())) AS messages_today,
       (SELECT count(*)::int FROM secret_messages WHERE delivered_at IS NULL) AS undelivered`,
  );
}

module.exports = {
  TTL_VALUES,
  create,
  accept,
  close,
  closeBySession,
  closeByUser,
  list,
  send,
  pending,
  ack,
  markRead,
  typing,
  deleteMessages,
  notify,
  sweep,
  adminStats,
};
