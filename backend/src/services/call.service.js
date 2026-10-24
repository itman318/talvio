'use strict';

/**
 * One-to-one voice & video calls (WebRTC).
 *
 * The server never touches audio/video: it rings the other person, relays the WebRTC
 * offer/answer/ICE candidates between the two devices, hands out STUN/TURN servers,
 * and keeps the call history.
 *
 * Flow:  caller  call:start ──► callee devices ring (socket + push)
 *        callee  call:accept ──► caller gets call:accepted, creates the WebRTC offer
 *        both    call:signal (offer / answer / ice / media) relayed device-to-device
 *        either  call:hangup ──► both get call:ended; a "call" message lands in the chat
 */
const crypto = require('crypto');
const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const chatService = require('./chat.service');
const moderation = require('./moderation.service');
const push = require('./push.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const ACTIVE = ['ringing', 'accepted'];
const FINAL = ['ended', 'missed', 'declined', 'busy', 'failed'];
const SIGNAL_KINDS = ['offer', 'answer', 'ice', 'media'];
const MAX_SDP = 20000;

const ringTimers = new Map(); // callId -> Timeout
const live = new Map(); // callId -> { callerId, calleeId, callerSession, calleeSession, status } (fast path for signaling)

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function durationSec(row) {
  if (!row.answered_at) return 0;
  const end = row.ended_at ? new Date(row.ended_at) : new Date();
  return Math.max(0, Math.round((end - new Date(row.answered_at)) / 1000));
}

function serialize(row, viewerId, users) {
  const outgoing = row.caller_id === viewerId;
  const peerId = outgoing ? row.callee_id : row.caller_id;
  return {
    id: row.id,
    chat_id: row.chat_id,
    video: row.video,
    status: row.status,
    direction: outgoing ? 'outgoing' : 'incoming',
    end_reason: row.end_reason || null,
    peer: users ? users.get(peerId) || null : null,
    peer_id: peerId,
    duration_sec: durationSec(row),
    created_at: iso(row.created_at),
    answered_at: iso(row.answered_at),
    ended_at: iso(row.ended_at),
  };
}

async function serializeOne(row, viewerId) {
  const users = await userService.getUsersMap(viewerId, [row.caller_id, row.callee_id]);
  return serialize(row, viewerId, users);
}

function emit(event, payload, { userIds = [], sessionIds = [] }) {
  bus.emit('call:emit', { event, payload, userIds, sessionIds });
}

// ------------------------------------------------------------------ ICE servers
/** STUN + TURN servers for this user. TURN uses coturn's time-limited REST credentials when TURN_SECRET is set. */
async function iceServers(userId) {
  const s = await settings.getAll();
  const servers = [];
  if (s.stun_urls && s.stun_urls.length) servers.push({ urls: s.stun_urls });
  const turnUrls = [...new Set([...config.turn.urls, ...(s.turn_urls || [])])];
  if (turnUrls.length) {
    if (config.turn.secret) {
      const expires = Math.floor(Date.now() / 1000) + config.turn.credentialTtlSec;
      const username = `${expires}:${userId}`;
      const credential = crypto.createHmac('sha1', config.turn.secret).update(username).digest('base64');
      servers.push({ urls: turnUrls, username, credential });
    } else if (config.turn.username) {
      servers.push({ urls: turnUrls, username: config.turn.username, credential: config.turn.password });
    }
  }
  return servers;
}

// ------------------------------------------------------------------ permission checks
async function assertCanCall(caller, calleeId, video, { viaLink = false } = {}) {
  await settings.requireFeature('feature_calls', 'Calls');
  if (video) await settings.requireFeature('feature_video_calls', 'Video calls');
  moderation.assertNotRestricted(caller);
  if (calleeId === caller.id) throw badRequest('invalid_call', 'You can’t call yourself');
  const callee = await db.one('SELECT id, status, privacy_calls FROM users WHERE id = $1', [calleeId]);
  if (!callee || callee.status !== 'active') throw notFound('user_not_found', 'This user can’t be called');
  if (await userService.isBlockedEither(caller.id, calleeId)) throw forbidden('blocked', 'You can’t call this user');
  if (viaLink) return callee; // the callee shared a call link: privacy allows it, blocks still apply
  const rel = await userService.relations(caller.id, [calleeId]);
  if (!userService.allowedFor(rel, calleeId, 'calls', callee.privacy_calls || 'everyone')) {
    throw forbidden(
      'privacy_calls',
      callee.privacy_calls === 'contacts' ? 'This user only accepts calls from their contacts' : 'This user doesn’t accept calls',
    );
  }
  return callee;
}

/** Every ringing / accepted call of a user (a second one can ring while the first is connected = call waiting). */
async function activeCallsOf(userId, client = db) {
  const r = await client.query(
    `SELECT * FROM calls WHERE status IN ('ringing', 'accepted') AND (caller_id = $1 OR callee_id = $1) ORDER BY id DESC`,
    [userId],
  );
  return r.rows;
}

async function activeCallOf(userId, client = db) {
  const r = await client.query(
    `SELECT * FROM calls WHERE status IN ('ringing', 'accepted') AND (caller_id = $1 OR callee_id = $1)
     ORDER BY id DESC LIMIT 1`,
    [userId],
  );
  return r.rows[0] || null;
}

// ------------------------------------------------------------------ start / accept / decline / hang up
/**
 * Starts a call. body: { user_id } or { chat_id } (private chat), video.
 * Returns { call, ice_servers } — call.status is 'busy' when the other person is already on a call.
 */
async function startCall(userId, sessionId, body = {}) {
  let video = body.video === true;
  let calleeId;
  let viaLink = false;
  if (body.link !== undefined && body.link !== null) {
    const link = await db.one('SELECT * FROM call_links WHERE code = $1', [String(body.link).slice(0, 24)]);
    if (!link) throw notFound('link_not_found', 'This call link is not valid anymore');
    calleeId = link.user_id;
    if (calleeId === userId) throw badRequest('invalid_call', 'This is your own call link');
    video = video || link.video;
    viaLink = true;
  } else if (body.chat_id !== undefined && body.chat_id !== null) {
    const chat = await chatService.getChat(userId, body.chat_id);
    if (chat.type !== 'private') throw badRequest('invalid_call', 'Calls are only available in private chats');
    calleeId = await chatService.privatePeerId(chat.id, userId);
    if (!calleeId) throw badRequest('invalid_call', 'You can’t call yourself');
  } else {
    calleeId = v.id(body.user_id, 'user_id');
  }
  const caller = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  await assertCanCall(caller, calleeId, video, { viaLink });
  rateLimit.enforce(`call:${userId}`, 20, 10 * 60 * 1000, 'Too many calls. Please wait a few minutes.');

  const chat = await chatService.getOrCreatePrivate(userId, calleeId);
  const row = await db.tx(async (c) => {
    // Lock both users (in id order) so simultaneous calls can't double-book anyone.
    for (const id of [userId, calleeId].sort((a, b) => a - b)) {
      await c.query('SELECT pg_advisory_xact_lock(7311, $1::int)', [id]);
    }
    const mine = await activeCallOf(userId, c);
    if (mine) {
      // Calling the person who is already calling you = answering their call.
      if (mine.status === 'ringing' && mine.caller_id === calleeId && mine.callee_id === userId) return { answer: mine };
      throw conflict('already_in_call', 'Finish your current call first');
    }
    // Call waiting: one call may ring while the other person is talking; a third call is "busy".
    const theirs = await activeCallsOf(calleeId, c);
    const waiting = theirs.length === 1 && theirs[0].status === 'accepted';
    const busy = theirs.length > 0 && !waiting;
    const status = busy ? 'busy' : 'ringing';
    const r = await c.query(
      `INSERT INTO calls (chat_id, caller_id, callee_id, caller_session_id, video, status, ended_at, end_reason)
       VALUES ($1, $2, $3, $4, $5, $6, ${busy ? 'now()' : 'NULL'}, ${busy ? "'busy'" : 'NULL'}) RETURNING *`,
      [chat.id, userId, calleeId, sessionId || null, video, status],
    );
    return { created: r.rows[0], waiting };
  });
  if (row.answer) return acceptCall(userId, sessionId, row.answer.id);

  const call = row.created;
  if (call.status === 'busy') {
    await afterFinish(call);
    return { call: await serializeOne(call, userId), ice_servers: [] };
  }
  live.set(call.id, { callerId: userId, calleeId, callerSession: sessionId || null, calleeSession: null, status: 'ringing' });
  const timeoutSec = await settings.get('call_ring_timeout_sec');
  const t = setTimeout(() => {
    ringTimers.delete(call.id);
    finishCall(call.id, { status: 'missed', reason: 'no_answer', onlyIf: ['ringing'] }).catch(() => {});
  }, timeoutSec * 1000);
  if (t.unref) t.unref();
  ringTimers.set(call.id, t);

  const forCallee = await serializeOne(call, calleeId);
  if (row.waiting) forCallee.waiting = true;
  emit('call:incoming', { call: forCallee }, { userIds: [calleeId] });
  const name = userService.displayName(caller);
  push
    .sendToUsers(
      [calleeId],
      { title: name, body: (row.waiting ? 'Waiting · ' : '') + (video ? '📹 Incoming video call' : '📞 Incoming voice call') },
      { type: 'call', call_id: call.id, chat_id: chat.id, video: video ? '1' : '0' },
      { ttlSec: timeoutSec, tag: `call-${call.id}` },
    )
    .catch(() => {});
  const out = await serializeOne(call, userId);
  if (row.waiting) out.waiting = true; // the other person is on another call; it rings for them as "waiting"
  return { call: out, ice_servers: await iceServers(userId) };
}

async function lockCall(c, callIdRaw) {
  const r = await c.query('SELECT * FROM calls WHERE id = $1 FOR UPDATE', [v.id(callIdRaw, 'call_id')]);
  if (!r.rows[0]) throw notFound('call_not_found', 'Call not found');
  return r.rows[0];
}

async function acceptCall(userId, sessionId, callIdRaw) {
  const row = await db.tx(async (c) => {
    const call = await lockCall(c, callIdRaw);
    if (call.callee_id !== userId) throw forbidden('not_participant', 'This call is not for you');
    if (call.status === 'accepted') throw conflict('answered_elsewhere', 'This call was answered on another device');
    if (call.status !== 'ringing') throw conflict('call_ended', 'This call has ended');
    const r = await c.query(
      `UPDATE calls SET status = 'accepted', answered_at = now(), callee_session_id = $2 WHERE id = $1 RETURNING *`,
      [call.id, sessionId || null],
    );
    return r.rows[0];
  });
  clearRing(row.id);
  // "End & answer": the call this person was on ends now.
  const others = (await activeCallsOf(userId)).filter((c) => c.id !== row.id);
  for (const o of others) {
    await finishCall(o.id, { status: o.status === 'accepted' ? 'ended' : (o.callee_id === userId ? 'declined' : 'missed'), reason: 'hangup', by: userId, onlyIf: ACTIVE });
  }
  live.set(row.id, {
    callerId: row.caller_id,
    calleeId: row.callee_id,
    callerSession: row.caller_session_id,
    calleeSession: row.callee_session_id,
    status: 'accepted',
  });
  // Caller starts the WebRTC offer; the callee's other devices stop ringing.
  emit('call:accepted', { call_id: row.id }, { userIds: [row.caller_id, row.callee_id] });
  return { call: await serializeOne(row, userId), ice_servers: await iceServers(userId) };
}

async function declineCall(userId, callIdRaw) {
  const call = await db.one('SELECT * FROM calls WHERE id = $1', [v.id(callIdRaw, 'call_id')]);
  if (!call) throw notFound('call_not_found', 'Call not found');
  if (call.callee_id !== userId) throw forbidden('not_participant', 'This call is not for you');
  const done = await finishCall(call.id, { status: 'declined', reason: 'declined', by: userId, onlyIf: ['ringing'] });
  return { call: done ? await serializeOne(done, userId) : await serializeOne(call, userId) };
}

/** reason: hangup | failed | cancelled */
async function hangup(userId, callIdRaw, reasonRaw) {
  const call = await db.one('SELECT * FROM calls WHERE id = $1', [v.id(callIdRaw, 'call_id')]);
  if (!call) throw notFound('call_not_found', 'Call not found');
  if (call.caller_id !== userId && call.callee_id !== userId) throw forbidden('not_participant', 'You are not on this call');
  if (!ACTIVE.includes(call.status)) return { call: await serializeOne(call, userId) };
  const reason = reasonRaw === 'failed' ? 'failed' : 'hangup';
  let status;
  if (call.status === 'ringing') status = call.caller_id === userId ? 'missed' : 'declined';
  else status = reason === 'failed' ? 'failed' : 'ended';
  const endReason = call.status === 'ringing' && call.caller_id === userId ? 'cancelled' : reason;
  const done = await finishCall(call.id, { status, reason: endReason, by: userId, onlyIf: ACTIVE });
  return { call: await serializeOne(done || call, userId) };
}

/** Atomically moves an active call to a final status. Returns the updated row, or null if it was no longer active. */
async function finishCall(callId, { status, reason, by = null, onlyIf = ACTIVE }) {
  const row = await db.one(
    `UPDATE calls SET status = $2, end_reason = $3, ended_by = $4, ended_at = now()
     WHERE id = $1 AND status = ANY($5::text[]) RETURNING *`,
    [callId, status, reason, by, onlyIf],
  );
  if (!row) return null;
  await afterFinish(row);
  return row;
}

function clearRing(callId) {
  const t = ringTimers.get(callId);
  if (t) clearTimeout(t);
  ringTimers.delete(callId);
}

async function afterFinish(row) {
  clearRing(row.id);
  live.delete(row.id);
  const payload = { call_id: row.id, status: row.status, end_reason: row.end_reason, duration_sec: durationSec(row) };
  emit('call:ended', payload, { userIds: [row.caller_id, row.callee_id] });
  if (row.chat_id) {
    const messageService = require('./message.service'); // lazy: avoids circular import
    await messageService
      .createCallMessage(row.chat_id, row.caller_id, {
        call: { id: row.id, video: row.video, status: row.status, duration_sec: durationSec(row), reason: row.end_reason },
      })
      .catch((err) => console.error('call message failed', err.message)); // eslint-disable-line no-console
  }
  if (row.status === 'missed' || row.status === 'busy') {
    const caller = await db.one('SELECT * FROM users WHERE id = $1', [row.caller_id]);
    push
      .sendToUsers(
        [row.callee_id],
        { title: caller ? userService.displayName(caller) : 'Missed call', body: row.video ? '📹 Missed video call' : '📞 Missed call' },
        { type: 'call_missed', call_id: row.id, chat_id: row.chat_id || '' },
        { tag: `call-${row.id}` },
      )
      .catch(() => {});
  }
}

// ------------------------------------------------------------------ signaling relay
/**
 * Relays WebRTC signaling to the other device on the call.
 * body: { call_id, kind: offer|answer|ice|media, sdp?, candidate?, muted?, video_off? }
 */
async function relaySignal(userId, sessionId, body = {}) {
  const callId = v.id(body.call_id, 'call_id');
  const kind = v.oneOf(body.kind, SIGNAL_KINDS, 'kind');
  let s = live.get(callId);
  if (!s) {
    const row = await db.one('SELECT * FROM calls WHERE id = $1', [callId]);
    if (!row || row.status !== 'accepted') throw conflict('call_not_active', 'This call is not active');
    s = { callerId: row.caller_id, calleeId: row.callee_id, callerSession: row.caller_session_id, calleeSession: row.callee_session_id, status: row.status };
    live.set(callId, s);
  }
  if (s.status !== 'accepted') throw conflict('call_not_active', 'This call is not connected yet');
  let target;
  if (userId === s.callerId && (!s.callerSession || s.callerSession === sessionId)) target = { user: s.calleeId, session: s.calleeSession };
  else if (userId === s.calleeId && (!s.calleeSession || s.calleeSession === sessionId)) target = { user: s.callerId, session: s.callerSession };
  else throw forbidden('not_participant', 'You are not on this call');

  const out = { call_id: callId, kind };
  if (kind === 'offer' || kind === 'answer') {
    if (typeof body.sdp !== 'string' || body.sdp.length === 0 || body.sdp.length > MAX_SDP) throw badRequest('invalid_signal', 'Invalid SDP');
    out.sdp = body.sdp;
    if (body.ice_restart === true) out.ice_restart = true;
  } else if (kind === 'ice') {
    const cnd = body.candidate;
    if (!cnd || typeof cnd !== 'object' || typeof cnd.candidate !== 'string' || cnd.candidate.length > 1000) {
      throw badRequest('invalid_signal', 'Invalid ICE candidate');
    }
    out.candidate = {
      candidate: cnd.candidate,
      sdpMid: typeof cnd.sdpMid === 'string' ? cnd.sdpMid.slice(0, 64) : null,
      sdpMLineIndex: Number.isInteger(cnd.sdpMLineIndex) ? cnd.sdpMLineIndex : null,
    };
  } else {
    out.muted = body.muted === true;
    out.video_off = body.video_off === true;
  }
  emit('call:signal', out, target.session ? { sessionIds: [target.session] } : { userIds: [target.user] });
  return {};
}

/** A device went offline for good (socket gone past the grace period, or logged out): end its calls. */
async function endBySession(sessionId) {
  if (!sessionId) return 0;
  const rows = await db.many(
    `SELECT * FROM calls WHERE status IN ('ringing', 'accepted') AND (caller_session_id = $1 OR callee_session_id = $1)`,
    [sessionId],
  );
  for (const call of rows) {
    const status = call.status === 'ringing' ? 'missed' : 'ended';
    const by = call.caller_session_id === sessionId ? call.caller_id : call.callee_id;
    await finishCall(call.id, { status, reason: 'connection_lost', by, onlyIf: [call.status] });
  }
  return rows.length;
}

/** Logged out / banned / deleted: end every active call of this user. */
async function endByUser(userId) {
  const rows = await db.many(`SELECT * FROM calls WHERE status IN ('ringing', 'accepted') AND (caller_id = $1 OR callee_id = $1)`, [userId]);
  for (const call of rows) {
    const status = call.status === 'ringing' ? (call.caller_id === userId ? 'missed' : 'declined') : 'ended';
    await finishCall(call.id, { status, reason: 'connection_lost', by: userId, onlyIf: [call.status] });
  }
  return rows.length;
}

/** Scheduler safety net (server restarts lose the in-memory timers). */
async function sweep() {
  const s = await settings.getAll();
  const stale = await db.many(
    `SELECT id FROM calls WHERE status = 'ringing' AND created_at < now() - make_interval(secs => $1)`,
    [s.call_ring_timeout_sec + 15],
  );
  for (const r of stale) await finishCall(r.id, { status: 'missed', reason: 'no_answer', onlyIf: ['ringing'] });
  const long = await db.many(
    `SELECT id FROM calls WHERE status = 'accepted' AND answered_at < now() - make_interval(mins => $1)`,
    [s.call_max_minutes],
  );
  for (const r of long) await finishCall(r.id, { status: 'ended', reason: 'time_limit', onlyIf: ['accepted'] });
  return stale.length + long.length;
}

// ------------------------------------------------------------------ history
async function listCalls(userId, query = {}) {
  const limit = v.limit(query.limit, 50, 100);
  const params = [userId, limit];
  const where = [`((c.caller_id = $1 AND NOT c.hidden_caller) OR (c.callee_id = $1 AND NOT c.hidden_callee))`, `c.status <> 'ringing'`];
  if (query.before) {
    params.push(v.id(query.before, 'before'));
    where.push(`c.id < $${params.length}`);
  }
  if (query.missed === '1' || query.missed === 'true' || query.missed === true) {
    where.push(`c.callee_id = $1 AND c.status IN ('missed', 'busy')`);
  }
  const rows = await db.many(`SELECT c.* FROM calls c WHERE ${where.join(' AND ')} ORDER BY c.id DESC LIMIT $2`, params);
  const users = await userService.getUsersMap(userId, rows.flatMap((r) => [r.caller_id, r.callee_id]));
  return rows.map((r) => serialize(r, userId, users));
}

async function deleteCalls(userId, body = {}) {
  if (body.all === true) {
    await db.query('UPDATE calls SET hidden_caller = TRUE WHERE caller_id = $1 AND status <> ALL($2::text[])', [userId, ACTIVE]);
    await db.query('UPDATE calls SET hidden_callee = TRUE WHERE callee_id = $1 AND status <> ALL($2::text[])', [userId, ACTIVE]);
    return { ok: true };
  }
  const ids = v.idList(body.ids, 'ids', 200);
  await db.query('UPDATE calls SET hidden_caller = TRUE WHERE caller_id = $1 AND id = ANY($2::bigint[])', [userId, ids]);
  await db.query('UPDATE calls SET hidden_callee = TRUE WHERE callee_id = $1 AND id = ANY($2::bigint[])', [userId, ids]);
  return { ok: true };
}

/** The ringing/ongoing call of this user, if any (the app calls this when opened from a call notification). */
async function getActive(userId) {
  const rows = await activeCallsOf(userId);
  const row = rows.find((r) => r.status === 'accepted') || rows[0];
  const waiting = rows.find((r) => r !== row && r.status === 'ringing' && r.callee_id === userId);
  return {
    call: row ? await serializeOne(row, userId) : null,
    waiting: waiting ? { ...(await serializeOne(waiting, userId)), waiting: true } : null,
  };
}

async function rateCall(userId, callIdRaw, body = {}) {
  const call = await db.one('SELECT * FROM calls WHERE id = $1', [v.id(callIdRaw, 'call_id')]);
  if (!call) throw notFound('call_not_found', 'Call not found');
  if (call.caller_id !== userId && call.callee_id !== userId) throw forbidden('not_participant', 'You were not on this call');
  if (!call.answered_at || !FINAL.includes(call.status)) throw badRequest('invalid_rating', 'You can rate a call after it ends');
  const rating = parseInt(body.rating, 10);
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) throw badRequest('invalid_rating', 'Rating must be 1–5');
  const comment = v.str(body.comment, { field: 'comment', max: 500 }) || null;
  const col = call.caller_id === userId ? 'rating_caller' : 'rating_callee';
  await db.query(`UPDATE calls SET ${col} = $2, rating_comment = COALESCE($3, rating_comment) WHERE id = $1`, [call.id, rating, comment]);
  return { ok: true };
}

// ------------------------------------------------------------------ admin
async function adminList(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const offset = (page - 1) * limit;
  const params = [];
  const where = [];
  if (query.user_id) {
    params.push(v.id(query.user_id, 'user_id'));
    where.push(`(c.caller_id = $${params.length} OR c.callee_id = $${params.length})`);
  }
  if (query.status) {
    params.push(v.oneOf(query.status, [...ACTIVE, ...FINAL], 'status'));
    where.push(`c.status = $${params.length}`);
  }
  if (query.video === 'true' || query.video === 'false') where.push(`c.video = ${query.video === 'true'}`);
  const w = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*)::int AS n FROM calls c ${w}`, params);
  params.push(limit, offset);
  const rows = await db.many(
    `SELECT c.*, uc.first_name AS caller_first, uc.last_name AS caller_last, uc.username AS caller_username,
            ue.first_name AS callee_first, ue.last_name AS callee_last, ue.username AS callee_username
     FROM calls c JOIN users uc ON uc.id = c.caller_id JOIN users ue ON ue.id = c.callee_id
     ${w} ORDER BY c.id DESC LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  const name = (f, l) => `${f || ''} ${l || ''}`.trim() || 'Deleted Account';
  return {
    total: total.n,
    page,
    limit,
    items: rows.map((r) => ({
      id: r.id,
      video: r.video,
      status: r.status,
      end_reason: r.end_reason,
      caller: { id: r.caller_id, name: name(r.caller_first, r.caller_last), username: r.caller_username },
      callee: { id: r.callee_id, name: name(r.callee_first, r.callee_last), username: r.callee_username },
      duration_sec: durationSec(r),
      rating: r.rating_caller || r.rating_callee ? { caller: r.rating_caller, callee: r.rating_callee, comment: r.rating_comment } : null,
      created_at: iso(r.created_at),
      answered_at: iso(r.answered_at),
      ended_at: iso(r.ended_at),
    })),
  };
}

async function adminStats() {
  const totals = await db.one(
    `SELECT
       count(*) FILTER (WHERE status IN ('ringing', 'accepted'))::int AS active,
       count(*) FILTER (WHERE created_at > date_trunc('day', now()))::int AS today,
       count(*) FILTER (WHERE created_at > now() - interval '30 days')::int AS last_30d,
       count(*) FILTER (WHERE created_at > now() - interval '30 days' AND answered_at IS NOT NULL)::int AS answered_30d,
       count(*) FILTER (WHERE created_at > now() - interval '30 days' AND status = 'failed')::int AS failed_30d,
       count(*) FILTER (WHERE created_at > now() - interval '30 days' AND video)::int AS video_30d,
       COALESCE(round(avg(EXTRACT(EPOCH FROM (ended_at - answered_at)))
         FILTER (WHERE answered_at IS NOT NULL AND ended_at IS NOT NULL AND created_at > now() - interval '30 days')), 0)::int AS avg_duration_sec,
       round(avg(COALESCE(rating_caller, rating_callee))
         FILTER (WHERE COALESCE(rating_caller, rating_callee) IS NOT NULL AND created_at > now() - interval '30 days'), 2)::float AS avg_rating
     FROM calls`,
  );
  const days = await db.many(
    `SELECT to_char(d, 'YYYY-MM-DD') AS day,
            (SELECT count(*)::int FROM calls WHERE created_at >= d AND created_at < d + interval '1 day') AS calls,
            (SELECT COALESCE(round(sum(EXTRACT(EPOCH FROM (ended_at - answered_at))) / 60), 0)::int FROM calls
               WHERE created_at >= d AND created_at < d + interval '1 day' AND answered_at IS NOT NULL AND ended_at IS NOT NULL) AS minutes
     FROM generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') d
     ORDER BY d`,
  );
  const s = await settings.getAll();
  return {
    ...totals,
    answer_rate: totals.last_30d ? Math.round((totals.answered_30d / totals.last_30d) * 100) : 0,
    days,
    turn: {
      urls: [...new Set([...config.turn.urls, ...(s.turn_urls || [])])],
      auth: config.turn.secret ? 'secret' : config.turn.username ? 'static' : 'none',
    },
  };
}

async function adminEnd(callIdRaw) {
  const id = v.id(callIdRaw, 'call_id');
  const row = await finishCall(id, { status: 'ended', reason: 'admin', onlyIf: ACTIVE });
  if (!row) throw conflict('call_not_active', 'This call is not active');
  return { ok: true };
}

/** For tests. */
function _reset() {
  for (const t of ringTimers.values()) clearTimeout(t);
  ringTimers.clear();
  live.clear();
}


// ------------------------------------------------------------------ call links
function newLinkCode() {
  return crypto.randomBytes(9).toString('base64url'); // 12 chars
}

function serializeLink(row) {
  return { code: row.code, video: row.video, path: `/call/${row.code}`, created_at: iso(row.created_at) };
}

/** A link that lets anyone who has it call me (my calls privacy is skipped; blocks still apply). */
async function createLink(userId, body = {}) {
  await settings.requireFeature('feature_calls', 'Calls');
  const n = await db.one('SELECT count(*)::int AS n FROM call_links WHERE user_id = $1', [userId]);
  if (n.n >= 10) throw badRequest('too_many_links', 'You can have up to 10 call links. Delete one first.');
  const row = await db.one('INSERT INTO call_links (code, user_id, video) VALUES ($1, $2, $3) RETURNING *', [newLinkCode(), userId, body.video === true]);
  return { link: serializeLink(row) };
}

async function listLinks(userId) {
  const rows = await db.many('SELECT * FROM call_links WHERE user_id = $1 ORDER BY created_at DESC', [userId]);
  return { links: rows.map(serializeLink) };
}

async function deleteLink(userId, code) {
  await db.query('DELETE FROM call_links WHERE user_id = $1 AND code = $2', [userId, String(code).slice(0, 24)]);
  return {};
}

/** Who a call link calls. */
async function resolveLink(viewerId, code) {
  const row = await db.one('SELECT * FROM call_links WHERE code = $1', [String(code).slice(0, 24)]);
  if (!row) throw notFound('link_not_found', 'This call link is not valid anymore');
  const user = await userService.getUser(viewerId, row.user_id);
  return { link: serializeLink(row), user, mine: row.user_id === viewerId };
}

module.exports = {
  createLink,
  listLinks,
  deleteLink,
  resolveLink,
  iceServers,
  startCall,
  acceptCall,
  declineCall,
  hangup,
  finishCall,
  relaySignal,
  endBySession,
  endByUser,
  sweep,
  listCalls,
  deleteCalls,
  getActive,
  rateCall,
  adminList,
  adminStats,
  adminEnd,
  _reset,
};
