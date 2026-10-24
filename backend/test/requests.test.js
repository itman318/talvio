'use strict';

/** Message requests. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const users = require('../src/services/user.service');
const settings = require('../src/services/settings.service');

async function user(phone, name) {
  rateLimit.reset();
  const r = await auth.requestOtp(phone, '10.7.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.7.0.1');
  await db.query("UPDATE users SET first_name = $2, created_at = now() - interval '3 days' WHERE id = $1", [t.user.id, name]);
  return t.user.id;
}
const mine = async (u, chatId) => (await chats.listChats(u)).find((c) => c.id === chatId);

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('a stranger lands in requests; replying accepts it', async () => {
  const a = await user('+923441110001', 'Stranger');
  const b = await user('+923441110002', 'Bea');
  const chat = await chats.getOrCreatePrivate(a, b);
  await messages.sendMessage(a, chat.id, { text: 'hi, buy crypto?' });
  assert.equal((await mine(b, chat.id)).is_request, true);
  assert.equal((await mine(a, chat.id)).is_request, false, 'the sender never sees it as a request');
  await messages.sendMessage(b, chat.id, { text: 'who are you?' });
  assert.equal((await mine(b, chat.id)).is_request, false);
});

test('contacts are not requests; adding a contact clears a request; decline + block', async () => {
  const a = await user('+923441110003', 'Friend');
  const b = await user('+923441110004', 'Owner');
  await users.addContact(b, a);
  const c1 = await chats.getOrCreatePrivate(a, b);
  await messages.sendMessage(a, c1.id, { text: 'hey' });
  assert.equal((await mine(b, c1.id)).is_request, false);

  const s = await user('+923441110005', 'Spammer');
  const c2 = await chats.getOrCreatePrivate(s, b);
  await messages.sendMessage(s, c2.id, { text: 'promo' });
  assert.equal((await mine(b, c2.id)).is_request, true);
  await users.addContact(b, s);
  assert.equal((await mine(b, c2.id)).is_request, false);

  const x = await user('+923441110006', 'Scammer');
  const c3 = await chats.getOrCreatePrivate(x, b);
  await messages.sendMessage(x, c3.id, { text: 'win money' });
  assert.equal((await mine(b, c3.id)).is_request, true);
  await chats.declineRequest(b, c3.id, { block: true });
  assert.equal(await mine(b, c3.id), undefined, 'declined request disappears');
  await assert.rejects(messages.sendMessage(x, c3.id, { text: 'again' }));
  // declined without blocking: a new message lands in Requests again, not in the chat list
  const w = await user('+923441110009', 'Pushy');
  const c6 = await chats.getOrCreatePrivate(w, b);
  await messages.sendMessage(w, c6.id, { text: 'hi' });
  await chats.declineRequest(b, c6.id, {});
  await messages.sendMessage(w, c6.id, { text: 'hi again' });
  assert.equal((await mine(b, c6.id)).is_request, true);

  // turned off in privacy: no more requests
  await users.updatePrivacy(b, { message_requests: false });
  const y = await user('+923441110007', 'Newbie');
  const c4 = await chats.getOrCreatePrivate(y, b);
  await messages.sendMessage(y, c4.id, { text: 'hello' });
  assert.equal((await mine(b, c4.id)).is_request, false);
  // accept endpoint
  await users.updatePrivacy(b, { message_requests: true });
  const z = await user('+923441110008', 'Zed');
  const c5 = await chats.getOrCreatePrivate(z, b);
  await messages.sendMessage(z, c5.id, { text: 'yo' });
  assert.equal((await chats.acceptRequest(b, c5.id)).is_request, false);
});
