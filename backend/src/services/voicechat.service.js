'use strict';

/**
 * Live voice chats in groups and channels (like Telegram's voice chats / group calls).
 * Audio goes peer-to-peer between the participants (WebRTC mesh, TURN as fallback); the server keeps the
 * room state (who is in, muted, raised hand) and relays the WebRTC signalling.
 *
 *  - groups: any admin starts it, every member can join and talk;
 *  - channels: admins start and talk, subscribers listen and can raise a hand → an admin lets them speak.
 */
const db = require('../db');
const bus = require('../bus');
const v = require('../utils/validate');
const rateLimit = require('../utils/rateLimit');
const { badRequest, forbidden, notFound } = require('../utils/errors');
const chatService = require('./chat.service');
const userService = require('./user.service');

const MAX_PARTICIPANTS = 30; // mesh audio: fine for small rooms

const lazyMessages = () => require('./message.service'); // eslint-disable-line global-require
const iceServers = (uid) => require('./call.service').iceServers(uid); // eslint-disable-line global-require

async function active(chatId) {
  return db.one('SELECT * FROM voice_chats WHERE chat_id = $1 AND ended_at IS NULL', [chatId]);
}

async function participants(vcId) {
  return db.many(
    `SELECT user_id, muted, can_speak, hand_raised, joined_at FROM voice_chat_participants
     WHERE voice_chat_id = $1 AND left_at IS NULL ORDER BY joined_at`,
    [vcId],
  );
}

async function serialize(vc, viewerId) {
  if (!vc) return null;
  const list = await participants(vc.id);
  const users = await userService.getUsersMap(viewerId, list.map((p) => p.user_id));
  return {
    id: vc.id,
    chat_id: vc.chat_id,
    title: vc.title || '',
    started_at: new Date(vc.started_at).toISOString(),
    participants: list
      .filter((p) => users.has(p.user_id))
      .map((p) => ({ user: users.get(p.user_id), muted: p.muted, can_speak: p.can_speak, hand_raised: p.hand_raised })),
  };
}

/** Tells the chat's members the room changed (join banner, counts) and the participants the details. */
async function broadcast(vc, extra = {}) {
  const memberIds = await chatService.memberIds(vc.chat_id);
  const state = await serialize(vc, 0);
  bus.emit('rt:emit', { event: 'vc:update', payload: { chat_id: vc.chat_id, voice_chat: vc.ended_at ? null : state, ...extra }, userIds: memberIds });
}

function canManage(chat) {
  return chatService.ADMIN_ROLES.includes(chat.my_role) && chatService.hasRight(chat, 'manage_voice_chats');
}

async function start(userId, chatIdRaw, body = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  if (!chatService.isMulti(chat)) throw badRequest('invalid_input', 'Voice chats are for groups and channels');
  if (!canManage(chat)) throw forbidden('not_admin', 'Only admins can start a voice chat');
  const title = v.str(body.title, { field: 'title', max: 64 }) || '';
  let vc = await active(chat.id);
  if (!vc) {
    vc = await db.one(
      `INSERT INTO voice_chats (chat_id, started_by, title) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING *`,
      [chat.id, userId, title],
    ) || await active(chat.id);
    await lazyMessages().createSystemMessage(chat.id, userId, { event: 'voice_chat_started', title });
    await chatService.emitUpdated(chat.id);
  }
  return join(userId, chat.id, body);
}

async function join(userId, chatIdRaw, body = {}, sessionId = null) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const vc = await active(chat.id);
  if (!vc) throw notFound('voice_chat_not_found', 'There is no voice chat here right now');
  const n = await db.one('SELECT count(*)::int AS n FROM voice_chat_participants WHERE voice_chat_id = $1 AND left_at IS NULL AND user_id <> $2', [vc.id, userId]);
  if (n.n >= MAX_PARTICIPANTS) throw forbidden('voice_chat_full', `This voice chat is full (${MAX_PARTICIPANTS} people)`);
  // channels: subscribers listen; admins speak
  const canSpeak = chat.type === 'group' || canManage(chat);
  await db.query(
    `INSERT INTO voice_chat_participants (voice_chat_id, user_id, session_id, muted, can_speak)
     VALUES ($1, $2, $3, TRUE, $4)
     ON CONFLICT (voice_chat_id, user_id) DO UPDATE SET left_at = NULL, joined_at = now(), session_id = $3, muted = TRUE, hand_raised = FALSE`,
    [vc.id, userId, sessionId || (body && body.session_id) || null, canSpeak],
  );
  await broadcast(vc, { joined: userId });
  return { voice_chat: await serialize(vc, userId), ice_servers: await iceServers(userId), can_manage: canManage(chat) };
}

async function leave(userId, chatIdRaw) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const vc = await active(chatId);
  if (!vc) return { ok: true };
  await db.query('UPDATE voice_chat_participants SET left_at = now(), hand_raised = FALSE WHERE voice_chat_id = $1 AND user_id = $2 AND left_at IS NULL', [vc.id, userId]);
  const left = await participants(vc.id);
  if (!left.length) return endVc(vc, userId); // the last one out closes the room
  await broadcast(vc, { left: userId });
  return { ok: true };
}

async function endVc(vc, actorId) {
  const r = await db.one('UPDATE voice_chats SET ended_at = now() WHERE id = $1 AND ended_at IS NULL RETURNING *', [vc.id]);
  if (!r) return { ok: true };
  await db.query('UPDATE voice_chat_participants SET left_at = now() WHERE voice_chat_id = $1 AND left_at IS NULL', [vc.id]);
  const seconds = Math.max(0, Math.round((new Date(r.ended_at) - new Date(r.started_at)) / 1000));
  await lazyMessages().createSystemMessage(vc.chat_id, actorId, { event: 'voice_chat_ended', duration_sec: seconds });
  await broadcast(r, { ended: true });
  await chatService.emitUpdated(vc.chat_id);
  return { ok: true };
}

async function end(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  if (!canManage(chat)) throw forbidden('not_admin', 'Only admins can end the voice chat');
  const vc = await active(chat.id);
  if (!vc) return { ok: true };
  return endVc(vc, userId);
}

async function myRow(vcId, userId) {
  return db.one('SELECT * FROM voice_chat_participants WHERE voice_chat_id = $1 AND user_id = $2 AND left_at IS NULL', [vcId, userId]);
}

/** Mute / unmute myself; admins can mute someone (and in channels let a listener speak). */
async function update(userId, chatIdRaw, body = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const vc = await active(chat.id);
  if (!vc) throw notFound('voice_chat_not_found', 'This voice chat has ended');
  const targetId = body.user_id ? v.id(body.user_id, 'user_id') : userId;
  const me = await myRow(vc.id, userId);
  if (!me) throw forbidden('not_in_voice_chat', 'Join the voice chat first');
  const target = targetId === userId ? me : await myRow(vc.id, targetId);
  if (!target) throw notFound('participant_not_found', 'This person left the voice chat');
  const admin = canManage(chat);
  if (targetId !== userId && !admin) throw forbidden('not_admin', 'Only admins can do this');
  const sets = [];
  const params = [vc.id, targetId];
  const set = (col, val) => {
    params.push(val);
    sets.push(`${col} = $${params.length}`);
  };
  if (body.muted !== undefined) {
    const muted = v.bool(body.muted, 'muted');
    if (targetId === userId && !muted && !target.can_speak) throw forbidden('cannot_speak', 'Raise your hand — an admin will let you speak');
    if (targetId !== userId && !muted) throw forbidden('not_allowed', 'Only they can unmute themselves');
    set('muted', muted);
  }
  if (body.hand_raised !== undefined && targetId === userId) set('hand_raised', v.bool(body.hand_raised, 'hand_raised'));
  if (body.can_speak !== undefined && admin && targetId !== userId) {
    const cs = v.bool(body.can_speak, 'can_speak');
    set('can_speak', cs);
    if (cs) set('hand_raised', false);
    else set('muted', true);
  }
  if (sets.length) await db.query(`UPDATE voice_chat_participants SET ${sets.join(', ')} WHERE voice_chat_id = $1 AND user_id = $2`, params);
  await broadcast(vc);
  return { voice_chat: await serialize(vc, userId) };
}

async function get(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  return { voice_chat: await serialize(await active(chat.id), userId), can_manage: canManage(chat) };
}

/** WebRTC offer / answer / ICE between two people in the same room. */
async function relay(userId, p = {}) {
  const chatId = v.id(p.chat_id, 'chat_id');
  const to = v.id(p.to, 'to');
  const vc = await active(chatId);
  if (!vc) return { ok: false };
  const [a, b] = await Promise.all([myRow(vc.id, userId), myRow(vc.id, to)]);
  if (!a || !b) return { ok: false };
  bus.emit('rt:emit', { event: 'vc:signal', payload: { chat_id: chatId, from: userId, data: p.data }, userIds: [to] });
  return { ok: true };
}

/** "Speaking" ring around someone's photo. */
async function speaking(userId, p = {}) {
  const chatId = v.id(p.chat_id, 'chat_id');
  if (!rateLimit.hit(`vcspeak:${userId}`, 4, 1000).allowed) return { ok: true };
  const vc = await active(chatId);
  if (!vc) return { ok: true };
  const list = await participants(vc.id);
  if (!list.some((x) => x.user_id === userId)) return { ok: true };
  bus.emit('rt:emit', {
    event: 'vc:speaking',
    payload: { chat_id: chatId, user_id: userId, speaking: !!p.speaking },
    userIds: list.map((x) => x.user_id).filter((id) => id !== userId),
  });
  return { ok: true };
}

/** A device went away (no reconnect within the grace period): leave its voice chats. */
async function leaveBySession(sessionId) {
  const rows = await db.many(
    `SELECT vc.chat_id, p.user_id FROM voice_chat_participants p JOIN voice_chats vc ON vc.id = p.voice_chat_id
     WHERE p.session_id = $1 AND p.left_at IS NULL AND vc.ended_at IS NULL`,
    [sessionId],
  );
  for (const r of rows) await leave(r.user_id, r.chat_id).catch(() => {});
}

module.exports = { start, join, leave, end, update, get, relay, speaking, leaveBySession, MAX_PARTICIPANTS };
