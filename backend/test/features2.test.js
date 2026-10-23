'use strict';

/** Disappearing messages, live location, contact cards. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const bus = require('../src/bus');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const settings = require('../src/services/settings.service');

async function rejects(p, code) {
  await assert.rejects(p, (e) => { assert.equal(e.code, code, `${e.code}: ${e.message}`); return true; });
}
let n = 0;
async function signup(first, phone) {
  rateLimit.reset();
  n += 1;
  const ip = `10.8.0.${n}`;
  const r = phone ? await auth.requestOtp(phone, ip) : await auth.requestEmailCode(`${first.toLowerCase()}${n}@talvio.test`, ip);
  const s = phone ? await auth.verifyOtp(phone, r.dev_code, {}, ip) : await auth.verifyEmailCode(r.email, r.dev_code, {}, ip);
  await users.updateProfile(s.user.id, { first_name: first });
  return s.user.id;
}
const msgOf = (r) => r.message || r;

let A; let B; let C; let chat;
test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('Asad');
  B = await signup('Bina', '+923007000002');
  C = await signup('Chand');
  chat = await chats.getOrCreatePrivate(A, B);
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

test('disappearing messages: timer on → messages expire and are deleted for everyone', async () => {
  await rejects(chats.setDisappearing(A, chat.id, 123), 'invalid_input');
  const c = await chats.setDisappearing(A, chat.id, 3600);
  assert.equal(c.disappear_after_sec, 3600);
  const m = msgOf(await messages.sendMessage(A, chat.id, { text: 'yeh khud mit jaye ga' }));
  assert.ok(m.expires_at, 'has an expiry');
  const deleted = [];
  const h = (e) => deleted.push(...e.messageIds);
  bus.on('message:deleted', h);
  await db.query(`UPDATE messages SET expires_at = now() - interval '1 second' WHERE id = $1`, [m.id]);
  assert.equal(await messages.sweepExpired(), 1);
  bus.off('message:deleted', h);
  assert.deepEqual(deleted, [m.id]);
  const list = await messages.listMessages(B, chat.id, {});
  assert.ok(!(list.messages || list).some((x) => x.id === m.id && !x.deleted));
  await chats.setDisappearing(B, chat.id, 0);
  const later = msgOf(await messages.sendMessage(A, chat.id, { text: 'normal' }));
  assert.equal(later.expires_at, null);
  // groups: only admins
  const g = (await chats.createGroup(A, { title: 'G', member_ids: [B] })).chat;
  await rejects(chats.setDisappearing(B, g.id, 86400), 'not_admin');
});

test('live location: sender updates and stops; others cannot', async () => {
  const m = msgOf(await messages.sendMessage(A, chat.id, { type: 'location', location: { lat: 31.52, lng: 74.35, live_minutes: 15 } }));
  assert.ok(m.meta.live.until);
  await rejects(messages.sendMessage(A, chat.id, { type: 'location', location: { lat: 1, lng: 1, live_minutes: 7 } }), 'invalid_location');
  await messages.updateLiveLocation(A, m.id, { lat: 31.53, lng: 74.36, accuracy: 12 });
  let row = await db.one('SELECT meta FROM messages WHERE id = $1', [m.id]);
  assert.equal(row.meta.location.lat, 31.53);
  await rejects(messages.updateLiveLocation(B, m.id, { lat: 1, lng: 1 }), 'not_allowed');
  await messages.updateLiveLocation(A, m.id, { stop: true });
  row = await db.one('SELECT meta FROM messages WHERE id = $1', [m.id]);
  assert.equal(row.meta.live.stopped, true);
  assert.equal((await messages.updateLiveLocation(A, m.id, { lat: 2, lng: 2 })).ended, true);
});

test('contact cards link to Talvio accounts by phone', async () => {
  const r = msgOf(await messages.sendMessage(A, chat.id, { type: 'contact', contact: { name: 'Bina', phone: '+92 300 7000002' } }));
  assert.equal(r.meta.contact.user_id, B);
  assert.equal(r.meta.contact.phone, '+923007000002');
  const r2 = msgOf(await messages.sendMessage(A, chat.id, { type: 'contact', contact: { name: 'Plumber', phone: '+923111111111' } }));
  assert.equal(r2.meta.contact.user_id, null);
  await rejects(messages.sendMessage(A, chat.id, { type: 'contact', contact: { name: 'Nobody' } }), 'invalid_contact');
  assert.ok(C);
});
