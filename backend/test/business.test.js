'use strict';

/** Talvio Business: greeting, away message, working hours, quick replies. WARNING: wipes the test DB. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const settings = require('../src/services/settings.service');
const business = require('../src/services/business.service');

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.40.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [s.user.id]);
  return { id: s.user.id };
}
const flush = (ms = 300) => new Promise((r) => setTimeout(r, ms));
const autos = async (chatId, kind) => (await db.many(`SELECT id FROM messages WHERE chat_id = $1 AND meta->>'auto' = $2`, [chatId, kind])).length;

let SHOP;
let C1;
let C2;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  SHOP = await signup('+923280000001', 'Shop');
  C1 = await signup('+923280000002', 'Customer');
  C2 = await signup('+923280000003', 'Other');
});
test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  await db.close();
});

test('settings: validation and saving', async () => {
  await assert.rejects(business.set(SHOP.id, { greeting_on: true }), /greeting/i);
  await assert.rejects(business.set(SHOP.id, { hours: { mon: [[600, 500]] } }), /before/);
  const s = await business.set(SHOP.id, { greeting_on: true, greeting_text: 'Welcome to our shop!', greeting_days: 7, hours: { mon: [[540, 1080]] }, tz_offset_min: 300 });
  assert.equal(s.greeting_on, true);
  assert.deepEqual((await business.get(SHOP.id)).hours, { mon: [[540, 1080]] });
});

test('greeting: once for a new customer, not again', async () => {
  const chat = await chats.getOrCreatePrivate(C1.id, SHOP.id);
  await messages.sendMessage(C1.id, chat.id, { text: 'hi' });
  await flush();
  assert.equal(await autos(chat.id, 'greeting'), 1);
  await messages.sendMessage(C1.id, chat.id, { text: 'price?' });
  await flush();
  assert.equal(await autos(chat.id, 'greeting'), 1);
});

test('away: always mode replies once every few hours, not to the owner’s own messages', async () => {
  await business.set(SHOP.id, { greeting_on: false, away_on: true, away_text: 'We are closed, back at 9.', away_mode: 'always' });
  const chat = await chats.getOrCreatePrivate(C2.id, SHOP.id);
  await messages.sendMessage(SHOP.id, chat.id, { text: 'hello from shop' });
  await flush();
  assert.equal(await autos(chat.id, 'away'), 0);
  await messages.sendMessage(C2.id, chat.id, { text: 'open?' });
  await flush();
  await messages.sendMessage(C2.id, chat.id, { text: 'hello??' });
  await flush();
  assert.equal(await autos(chat.id, 'away'), 1);
});

test('working hours: open / closed in the owner time zone', () => {
  const s = { hours: { mon: [[540, 1080]] }, tz_offset_min: 300 };
  // Monday 2026-11-02 05:00 UTC = 10:00 in UTC+5 → open; 14:00 UTC = 19:00 → closed
  assert.equal(business.isOpen(s, new Date('2026-11-02T05:00:00Z')), true);
  assert.equal(business.isOpen(s, new Date('2026-11-02T14:00:00Z')), false);
  assert.equal(business.isOpen({ hours: {}, tz_offset_min: 0 }), true);
});

test('quick replies: add, list, rename, duplicate, delete', async () => {
  const r = await business.addReply(SHOP.id, { shortcut: '/Price', text: 'Rs 1500 only' });
  assert.equal(r.shortcut, 'price');
  await assert.rejects(business.addReply(SHOP.id, { shortcut: 'price', text: 'x' }), /already/);
  await assert.rejects(business.addReply(SHOP.id, { shortcut: 'bad shortcut', text: 'x' }), /Shortcut/);
  const u = await business.updateReply(SHOP.id, r.id, { text: 'Rs 1200 today' });
  assert.equal(u.text, 'Rs 1200 today');
  assert.equal((await business.listReplies(SHOP.id)).length, 1);
  await business.deleteReply(SHOP.id, r.id);
  assert.equal((await business.listReplies(SHOP.id)).length, 0);
});
