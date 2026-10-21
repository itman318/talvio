'use strict';

/**
 * Batch C end-to-end tests: secret chats — key exchange, device binding, ciphertext relay,
 * delivery acks wipe ciphertext, read receipts, delete-for-both, media access, closing,
 * logout closes the device's chats, feature switch, blocks, sweep.
 * Includes a real X25519 + HKDF + AES-GCM round trip to show the server only relays ciphertext.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const bus = require('../src/bus');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const secret = require('../src/services/secret.service');
const media = require('../src/services/media.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function login(phone, firstName) {
  const addr = `10.9.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  if (firstName) await users.updateProfile(s.user.id, { first_name: firstName });
  const { sessionId } = await auth.authenticate(s.access_token);
  return { id: s.user.id, sid: sessionId, refresh: s.refresh_token };
}

// --- the app's crypto, in Node, to prove the scheme works end to end
function keyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  return { privateKey, pub: raw.toString('base64') };
}
function shared(privateKey, theirB64) {
  const spki = Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(theirB64, 'base64')]);
  const pub = crypto.createPublicKey({ key: spki, format: 'der', type: 'spki' });
  return crypto.diffieHellman({ privateKey, publicKey: pub });
}
function encrypt(key, text) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(text, 'utf8'), c.final(), c.getAuthTag()]);
  return Buffer.from(JSON.stringify({ v: 1, n: 0, iv: iv.toString('base64'), ct: ct.toString('base64') })).toString('base64');
}
function decrypt(key, b64) {
  const e = JSON.parse(Buffer.from(b64, 'base64').toString());
  const raw = Buffer.from(e.ct, 'base64');
  const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(e.iv, 'base64'));
  d.setAuthTag(raw.subarray(-16));
  return Buffer.concat([d.update(raw.subarray(0, -16)), d.final()]).toString('utf8');
}

const events = [];
bus.on('rt:emit', (e) => events.push(e));
const take = (ev) => events.filter((e) => e.event === ev);

let A;
let B;
let B2; // Bilal's second phone
let C;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await login('+923240000001', 'Asad');
  B = await login('+923240000002', 'Bilal');
  B2 = await login('+923240000002');
  C = await login('+923240000003', 'Chand');
});

test.beforeEach(() => {
  events.length = 0;
  rateLimit.reset('secret:');
});

test.after(async () => {
  await db.close();
});

test('key exchange, device binding and an encrypted round trip the server cannot read', async () => {
  const ka = keyPair();
  const { secret_chat: sc } = await secret.create(A.id, A.sid, { user_id: B.id, public_key: ka.pub });
  assert.equal(sc.status, 'requested');
  assert.equal(sc.their_key, null);
  const req = take('secret:request')[0];
  assert.deepEqual(req.userIds, [B.id], 'all of Bilal’s devices see the request');
  assert.equal(req.payload.secret_chat.their_key, ka.pub);

  // sending before the peer accepts is refused
  await rejects(secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40) }), 'secret_chat_pending');

  // Bilal's 2nd phone accepts first → it owns the chat; the first phone can't take it any more
  const kb = keyPair();
  const acc = await secret.accept(B.id, B2.sid, sc.id, { public_key: kb.pub });
  assert.equal(acc.secret_chat.status, 'active');
  assert.equal(acc.secret_chat.their_key, ka.pub);
  assert.deepEqual(take('secret:accepted')[0].sessionIds, [A.sid]);
  assert.equal(take('secret:accepted')[0].payload.secret_chat.their_key, kb.pub);
  assert.deepEqual(take('secret:taken')[0].userIds, [B.id]);
  await rejects(secret.accept(B.id, B.sid, sc.id, { public_key: keyPair().pub }), 'accepted_elsewhere');
  await rejects(secret.send(B.id, B.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40) }), 'wrong_device');
  await rejects(secret.send(C.id, C.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40) }), 'secret_chat_not_found');

  // both sides derive the same key
  const keyA = crypto.hkdfSync('sha256', shared(ka.privateKey, kb.pub), Buffer.from(`chat-${sc.id}`), 'test', 32);
  const keyB = crypto.hkdfSync('sha256', shared(kb.privateKey, ka.pub), Buffer.from(`chat-${sc.id}`), 'test', 32);
  assert.deepEqual(Buffer.from(keyA), Buffer.from(keyB));

  const ct = encrypt(Buffer.from(keyA), 'Assalam o alaikum — yeh sirf hum dono parh sakte hain');
  const sent = await secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: ct, ttl_sec: 30, client_id: 'c1' });
  const again = await secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: ct, ttl_sec: 30, client_id: 'c1' });
  assert.equal(again.message.id, sent.message.id, 'retries are de-duplicated');
  const relayed = take('secret:message');
  assert.equal(relayed.length, 1);
  assert.deepEqual(relayed[0].sessionIds, [B2.sid], 'only the device that owns the chat');
  const stored = await db.one('SELECT ciphertext FROM secret_messages WHERE id = $1', [sent.message.id]);
  assert.ok(!stored.ciphertext.includes('Assalam'), 'server stores ciphertext only');
  assert.equal(decrypt(Buffer.from(keyB), relayed[0].payload.message.ciphertext), 'Assalam o alaikum — yeh sirf hum dono parh sakte hain');

  // offline catch-up, then ack → server forgets the ciphertext
  const pend = await secret.pending(B.id, B2.sid);
  assert.deepEqual(pend.map((m) => m.id), [sent.message.id]);
  assert.equal((await secret.pending(B.id, B.sid)).length, 0, 'other phone gets nothing');
  await secret.ack(B.id, B2.sid, { secret_chat_id: sc.id, message_ids: [sent.message.id] });
  assert.equal((await db.one('SELECT ciphertext FROM secret_messages WHERE id = $1', [sent.message.id])).ciphertext, null);
  assert.deepEqual(take('secret:delivered')[0].sessionIds, [A.sid]);
  assert.equal((await secret.pending(B.id, B2.sid)).length, 0);

  await secret.markRead(B.id, B2.sid, { secret_chat_id: sc.id, max_id: sent.message.id });
  assert.equal(take('secret:read')[0].payload.max_id, sent.message.id);

  await secret.typing(B.id, B2.sid, { secret_chat_id: sc.id });
  assert.deepEqual(take('secret:typing')[0].sessionIds, [A.sid]);
  await secret.deleteMessages(A.id, A.sid, { secret_chat_id: sc.id, message_ids: [sent.message.id] });
  assert.deepEqual(take('secret:deleted')[0].payload.message_ids, [sent.message.id]);
  await secret.notify(B.id, B2.sid, { secret_chat_id: sc.id, kind: 'screenshot' });
  assert.equal(take('secret:notify')[0].payload.kind, 'screenshot');

  // lists are per device
  assert.equal((await secret.list(B.id, B2.sid)).length, 1);
  assert.equal((await secret.list(B.id, B.sid)).length, 0);
  assert.equal((await secret.list(A.id, A.sid))[0].peer.first_name, 'Bilal');
});

test('validation: keys, ciphertext size, timer values, self & blocked users, feature switch', async () => {
  await rejects(secret.create(A.id, A.sid, { user_id: C.id, public_key: 'short' }), 'invalid_key');
  await rejects(secret.create(A.id, A.sid, { user_id: A.id, public_key: keyPair().pub }), 'invalid_input');
  await users.block(C.id, A.id);
  await rejects(secret.create(A.id, A.sid, { user_id: C.id, public_key: keyPair().pub }), 'blocked');
  await users.unblock(C.id, A.id);

  const { secret_chat: sc } = await secret.create(A.id, A.sid, { user_id: C.id, public_key: keyPair().pub });
  await secret.accept(C.id, C.sid, sc.id, { public_key: keyPair().pub });
  await rejects(secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(200001) }), 'invalid_ciphertext');
  await rejects(secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40), ttl_sec: 7 }), 'invalid_input');

  await settings.update({ feature_secret_chats: false });
  await rejects(secret.create(A.id, A.sid, { user_id: B.id, public_key: keyPair().pub }), 'feature_disabled');
  assert.equal((await settings.publicConfig()).features.secret_chats, false);
  await settings.update({ feature_secret_chats: true });
});

test('encrypted media is only reachable by the two people of an active secret chat', async () => {
  const { secret_chat: sc } = await secret.create(C.id, C.sid, { user_id: B.id, public_key: keyPair().pub });
  await secret.accept(B.id, B.sid, sc.id, { public_key: keyPair().pub });
  const config = require('../src/config');
  fs.mkdirSync(config.uploadDir, { recursive: true });
  const file = path.join(config.uploadDir, `test-secret-${Date.now()}.bin`);
  fs.writeFileSync(file, crypto.randomBytes(2048));
  const m = await media.registerUpload(C.id, { path: file, size: 2048, mimetype: 'application/octet-stream', originalname: 'secret.bin' }, { kind: 'file' });
  await rejects(secret.send(A.id, A.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40), media_id: m.id }), 'secret_chat_not_found');
  await secret.send(C.id, C.sid, { secret_chat_id: sc.id, ciphertext: 'x'.repeat(40), media_id: m.id });
  assert.ok(await media.getAccessible(B.id, m.id));
  await rejects(media.getAccessible(A.id, m.id), 'media_not_found');
  await secret.close(B.id, B.sid, sc.id);
  await rejects(media.getAccessible(B.id, m.id), 'media_not_found');
});

test('decline, close wipes messages, logout closes the device’s chats, sweep, admin counts', async () => {
  const r1 = await secret.create(A.id, A.sid, { user_id: B.id, public_key: keyPair().pub });
  await rejects(secret.close(C.id, C.sid, r1.secret_chat.id), 'secret_chat_not_found');
  await secret.close(B.id, B.sid, r1.secret_chat.id); // any of Bilal's devices may decline a request
  assert.equal((await db.one('SELECT close_reason FROM secret_chats WHERE id = $1', [r1.secret_chat.id])).close_reason, 'declined');
  assert.deepEqual(take('secret:closed')[0].userIds.sort(), [A.id, B.id].sort());

  const r2 = await secret.create(A.id, A.sid, { user_id: B.id, public_key: keyPair().pub });
  await secret.accept(B.id, B.sid, r2.secret_chat.id, { public_key: keyPair().pub });
  await secret.send(A.id, A.sid, { secret_chat_id: r2.secret_chat.id, ciphertext: 'y'.repeat(50) });
  await rejects(secret.close(B.id, B2.sid, r2.secret_chat.id), 'wrong_device');

  const dash = await admin.dashboard();
  assert.ok(Number(dash.secret_chats_active) >= 2);
  assert.ok(Number(dash.secret_messages_today) >= 1);
  const st = await secret.adminStats();
  assert.ok(st.active >= 2);

  // logging out the phone that owns the chat closes it and deletes pending ciphertext
  await auth.logout(B.id, B.sid);
  assert.ok((await secret.closeBySession(B.sid)) >= 1);
  const row = await db.one('SELECT status, close_reason FROM secret_chats WHERE id = $1', [r2.secret_chat.id]);
  assert.deepEqual({ ...row }, { status: 'closed', close_reason: 'device_logged_out' });
  assert.equal((await db.one('SELECT count(*)::int AS n FROM secret_messages WHERE secret_chat_id = $1', [r2.secret_chat.id])).n, 0);
  await rejects(secret.send(A.id, A.sid, { secret_chat_id: r2.secret_chat.id, ciphertext: 'z'.repeat(50) }), 'secret_chat_closed');

  // sweep: stale requests expire
  const r3 = await secret.create(A.id, A.sid, { user_id: C.id, public_key: keyPair().pub });
  await db.query(`UPDATE secret_chats SET created_at = now() - interval '20 days' WHERE id = $1`, [r3.secret_chat.id]);
  assert.ok((await secret.sweep()) >= 1);
  assert.equal((await db.one('SELECT close_reason FROM secret_chats WHERE id = $1', [r3.secret_chat.id])).close_reason, 'expired');
});
