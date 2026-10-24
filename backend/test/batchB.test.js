'use strict';

/**
 * Batch B end-to-end tests: 1-to-1 voice/video calls — ringing, accept, signaling relay, hang up,
 * decline, busy, no-answer timeout sweep, lost connection, privacy & blocks, feature flags,
 * TURN credentials, call messages in the chat, history, rating and admin stats.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const nodeCrypto = require('crypto');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const config = require('../src/config');
const db = require('../src/db');
const bus = require('../src/bus');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const messages = require('../src/services/message.service');
const calls = require('../src/services/call.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.8.0.${(ip += 1)}`;
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  const { sessionId } = await auth.authenticate(s.access_token);
  return { id: s.user.id, sid: sessionId };
}

// capture realtime events
const events = [];
bus.on('call:emit', (e) => events.push(e));
const take = (event) => events.filter((e) => e.event === event);

let A;
let B;
let C;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923230000001', 'Asad');
  B = await signup('+923230000002', 'Bilal');
  C = await signup('+923230000003', 'Chand');
});

test.beforeEach(() => {
  events.length = 0;
  rateLimit.reset('call:');
});

test.after(async () => {
  calls._reset();
  await db.close();
});

test('voice call: ring → accept → signaling relay → hang up → call message + history', async () => {
  const start = await calls.startCall(A.id, A.sid, { user_id: B.id });
  assert.equal(start.call.status, 'ringing');
  assert.equal(start.call.direction, 'outgoing');
  assert.equal(start.call.peer.id, B.id);
  assert.ok(start.ice_servers.some((s) => String(s.urls).includes('stun:')), 'default STUN server');
  const incoming = take('call:incoming')[0];
  assert.deepEqual(incoming.userIds, [B.id]);
  assert.equal(incoming.payload.call.direction, 'incoming');
  assert.equal(incoming.payload.call.peer.id, A.id);

  // signaling before the call is answered is refused
  await rejects(calls.relaySignal(A.id, A.sid, { call_id: start.call.id, kind: 'offer', sdp: 'v=0' }), 'call_not_active');

  const acc = await calls.acceptCall(B.id, B.sid, start.call.id);
  assert.equal(acc.call.status, 'accepted');
  assert.deepEqual(take('call:accepted')[0].userIds.sort(), [A.id, B.id].sort());
  await rejects(calls.acceptCall(B.id, B.sid, start.call.id), 'answered_elsewhere');

  await calls.relaySignal(A.id, A.sid, { call_id: start.call.id, kind: 'offer', sdp: 'v=0 offer' });
  await calls.relaySignal(B.id, B.sid, { call_id: start.call.id, kind: 'answer', sdp: 'v=0 answer' });
  await calls.relaySignal(B.id, B.sid, {
    call_id: start.call.id,
    kind: 'ice',
    candidate: { candidate: 'candidate:1 1 udp 2122260223 10.0.0.2 50000 typ host', sdpMid: '0', sdpMLineIndex: 0 },
  });
  await calls.relaySignal(A.id, A.sid, { call_id: start.call.id, kind: 'media', muted: true });
  const sig = take('call:signal');
  assert.equal(sig.length, 4);
  assert.deepEqual(sig[0].sessionIds, [B.sid], 'offer goes only to the device that answered');
  assert.equal(sig[0].payload.sdp, 'v=0 offer');
  assert.deepEqual(sig[1].sessionIds, [A.sid]);
  assert.equal(sig[2].payload.candidate.sdpMLineIndex, 0);
  assert.equal(sig[3].payload.muted, true);

  // another device of B, or a stranger, cannot inject signals
  await rejects(calls.relaySignal(B.id, B.sid + 999, { call_id: start.call.id, kind: 'ice', candidate: { candidate: 'x' } }), 'not_participant');
  await rejects(calls.relaySignal(C.id, C.sid, { call_id: start.call.id, kind: 'offer', sdp: 'x' }), 'not_participant');
  await rejects(calls.relaySignal(A.id, A.sid, { call_id: start.call.id, kind: 'offer', sdp: 'x'.repeat(30000) }), 'invalid_signal');

  await db.query(`UPDATE calls SET answered_at = now() - interval '95 seconds' WHERE id = $1`, [start.call.id]);
  const end = await calls.hangup(A.id, start.call.id);
  assert.equal(end.call.status, 'ended');
  assert.ok(end.call.duration_sec >= 95);
  const ended = take('call:ended')[0];
  assert.equal(ended.payload.status, 'ended');
  assert.deepEqual(ended.userIds.sort(), [A.id, B.id].sort());

  const hist = await messages.listMessages(B.id, start.call.chat_id, {});
  const callMsg = (hist.messages || hist).find((m) => m.type === 'call');
  assert.ok(callMsg, 'call message in the chat');
  assert.equal(callMsg.sender.id, A.id);
  assert.equal(callMsg.meta.call.status, 'ended');
  assert.ok(callMsg.meta.call.duration_sec >= 95);
  assert.equal(callMsg.silent, true);

  const histA = await calls.listCalls(A.id, {});
  assert.equal(histA[0].direction, 'outgoing');
  const histB = await calls.listCalls(B.id, {});
  assert.equal(histB[0].direction, 'incoming');
  assert.equal(histB[0].peer.first_name, 'Asad');

  await calls.rateCall(B.id, start.call.id, { rating: 4, comment: 'thori echo thi' });
  await rejects(calls.rateCall(B.id, start.call.id, { rating: 9 }), 'invalid_rating');
  await rejects(calls.rateCall(C.id, start.call.id, { rating: 5 }), 'not_participant');
  // a hung-up call can't be hung up twice
  assert.equal((await calls.hangup(B.id, start.call.id)).call.status, 'ended');
});

test('decline, caller cancel = missed, busy line, missed filter', async () => {
  const c1 = await calls.startCall(A.id, A.sid, { user_id: B.id, video: true });
  assert.equal(c1.call.video, true);
  const d = await calls.declineCall(B.id, c1.call.id);
  assert.equal(d.call.status, 'declined');
  await rejects(calls.declineCall(A.id, c1.call.id), 'not_participant');

  const c2 = await calls.startCall(A.id, A.sid, { user_id: B.id });
  const cancel = await calls.hangup(A.id, c2.call.id);
  assert.equal(cancel.call.status, 'missed');
  assert.equal(cancel.call.end_reason, 'cancelled');

  // B on a call with C → A's call waits (call waiting); busy for a third call is in social.test.js
  const bc = await calls.startCall(C.id, C.sid, { user_id: B.id });
  await calls.acceptCall(B.id, B.sid, bc.call.id);
  const waiting = await calls.startCall(A.id, A.sid, { user_id: B.id });
  assert.equal(waiting.call.status, 'ringing');
  assert.equal(waiting.call.waiting, true);
  // and C can't start a second call while on one
  await rejects(calls.startCall(C.id, C.sid, { user_id: A.id }), 'already_in_call');
  await calls.hangup(A.id, waiting.call.id);
  await calls.hangup(B.id, bc.call.id);

  const missedB = await calls.listCalls(B.id, { missed: '1' });
  assert.deepEqual(missedB.map((x) => x.status).sort(), ['missed', 'missed']);

  // delete history only for me
  await calls.deleteCalls(B.id, { ids: [c2.call.id] });
  assert.equal((await calls.listCalls(B.id, { missed: '1' })).length, 1);
  assert.ok((await calls.listCalls(A.id, {})).some((x) => x.id === c2.call.id), 'still in the caller’s history');
});

test('calling each other at the same time answers the existing call', async () => {
  const c = await calls.startCall(A.id, A.sid, { user_id: C.id });
  const back = await calls.startCall(C.id, C.sid, { user_id: A.id });
  assert.equal(back.call.id, c.call.id);
  assert.equal(back.call.status, 'accepted');
  await calls.hangup(C.id, c.call.id);
});

test('no answer → missed by the sweep; lost connection ends the call; active call lookup', async () => {
  const c = await calls.startCall(A.id, A.sid, { user_id: B.id });
  assert.equal((await calls.getActive(B.id)).call.id, c.call.id);
  await db.query(`UPDATE calls SET created_at = now() - interval '5 minutes' WHERE id = $1`, [c.call.id]);
  assert.equal(await calls.sweep(), 1);
  const row = await db.one('SELECT status, end_reason FROM calls WHERE id = $1', [c.call.id]);
  assert.deepEqual({ ...row }, { status: 'missed', end_reason: 'no_answer' });
  assert.equal((await calls.getActive(B.id)).call, null);

  const c2 = await calls.startCall(A.id, A.sid, { user_id: B.id });
  await calls.acceptCall(B.id, B.sid, c2.call.id);
  assert.equal(await calls.endBySession(B.sid), 1);
  const row2 = await db.one('SELECT status, end_reason, ended_by FROM calls WHERE id = $1', [c2.call.id]);
  assert.equal(row2.status, 'ended');
  assert.equal(row2.end_reason, 'connection_lost');
  assert.equal(row2.ended_by, B.id);

  // over-long calls are cut by the sweep
  const c3 = await calls.startCall(A.id, A.sid, { user_id: B.id });
  await calls.acceptCall(B.id, B.sid, c3.call.id);
  await db.query(`UPDATE calls SET answered_at = now() - interval '5 hours' WHERE id = $1`, [c3.call.id]);
  await calls.sweep();
  assert.equal((await db.one('SELECT end_reason FROM calls WHERE id = $1', [c3.call.id])).end_reason, 'time_limit');
});

test('privacy, blocks, restrictions, self-calls and feature switches', async () => {
  await rejects(calls.startCall(A.id, A.sid, { user_id: A.id }), 'invalid_call');

  await users.updatePrivacy(B.id, { calls: 'nobody' });
  assert.equal((await users.getMe(B.id)).privacy.calls, 'nobody');
  await rejects(calls.startCall(A.id, A.sid, { user_id: B.id }), 'privacy_calls');
  await users.updatePrivacy(B.id, { calls: 'contacts' });
  await rejects(calls.startCall(A.id, A.sid, { user_id: B.id }), 'privacy_calls');
  await users.addContact(B.id, A.id);
  const ok = await calls.startCall(A.id, A.sid, { user_id: B.id });
  await calls.hangup(A.id, ok.call.id);
  await users.updatePrivacy(B.id, { calls: 'everyone' });

  await users.block(C.id, A.id);
  await rejects(calls.startCall(A.id, A.sid, { user_id: C.id }), 'blocked');
  await rejects(calls.startCall(C.id, C.sid, { user_id: A.id }), 'blocked');
  await users.unblock(C.id, A.id);

  await db.query(`UPDATE users SET restricted_until = now() + interval '1 hour' WHERE id = $1`, [A.id]);
  await rejects(calls.startCall(A.id, A.sid, { user_id: B.id }), 'restricted');
  await db.query('UPDATE users SET restricted_until = NULL WHERE id = $1', [A.id]);

  await settings.update({ feature_video_calls: false });
  await rejects(calls.startCall(A.id, A.sid, { user_id: B.id, video: true }), 'feature_disabled');
  assert.equal((await settings.publicConfig()).features.video_calls, false);
  await settings.update({ feature_calls: false, feature_video_calls: true });
  await rejects(calls.startCall(A.id, A.sid, { user_id: B.id }), 'feature_disabled');
  assert.equal((await settings.publicConfig()).features.video_calls, false, 'video needs calls on too');
  await settings.update({ feature_calls: true });
});

test('ICE servers: coturn time-limited credentials and static ones', async () => {
  const saved = { ...config.turn };
  await settings.update({ turn_urls: ['turn:turn.example.com:3478?transport=udp', 'turns:turn.example.com:5349'] });
  config.turn.secret = 'coturn-shared-secret';
  let s = await calls.iceServers(A.id);
  const turn = s.find((x) => x.username);
  assert.equal(turn.urls.length, 2);
  const [expires, uid] = turn.username.split(':');
  assert.equal(Number(uid), A.id);
  assert.ok(Number(expires) > Date.now() / 1000 + 3600);
  assert.equal(turn.credential, nodeCrypto.createHmac('sha1', 'coturn-shared-secret').update(turn.username).digest('base64'));

  config.turn.secret = '';
  config.turn.username = 'chat';
  config.turn.password = 'pw';
  s = await calls.iceServers(A.id);
  assert.deepEqual(s.find((x) => x.username), { urls: ['turn:turn.example.com:3478?transport=udp', 'turns:turn.example.com:5349'], username: 'chat', credential: 'pw' });

  config.turn.username = '';
  s = await calls.iceServers(A.id);
  assert.equal(s.some((x) => x.username), false, 'TURN without credentials is not handed out');
  Object.assign(config.turn, saved);
  await settings.update({ turn_urls: [] });
});

test('call messages cannot be edited or forwarded; admin list, stats and force end', async () => {
  const c = await calls.startCall(A.id, A.sid, { user_id: B.id });
  const accepted = await calls.acceptCall(B.id, B.sid, c.call.id);
  assert.equal(accepted.call.status, 'accepted');

  const dash = await admin.dashboard();
  assert.equal(Number(dash.calls_active), 1);
  assert.ok(Number(dash.calls_today) >= 5);

  const stats = await calls.adminStats();
  assert.equal(stats.active, 1);
  assert.ok(stats.answer_rate > 0 && stats.answer_rate <= 100);
  assert.equal(stats.days.length, 14);
  assert.ok(stats.avg_rating >= 4);

  const list = await calls.adminList({ user_id: String(A.id), status: 'accepted' });
  assert.equal(list.total, 1);
  assert.equal(list.items[0].caller.name, 'Asad');

  await calls.adminEnd(c.call.id);
  await rejects(calls.adminEnd(c.call.id), 'call_not_active');
  assert.equal((await db.one('SELECT end_reason FROM calls WHERE id = $1', [c.call.id])).end_reason, 'admin');

  const msg = await db.one(`SELECT id, chat_id FROM messages WHERE type = 'call' ORDER BY id DESC LIMIT 1`);
  await assert.rejects(messages.editMessage(A.id, msg.id, { text: 'hacked' }));
  await assert.rejects(messages.forwardMessages(A.id, { from_chat_id: msg.chat_id, message_ids: [msg.id], to_chat_ids: [msg.chat_id] }));
});
