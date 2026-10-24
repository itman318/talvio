'use strict';

/** Reply / mark as read from a notification. WARNING: wipes the test database. */
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
const notify = require('../src/services/notify.service');
const users = require('../src/services/user.service');
const settings = require('../src/services/settings.service');

async function user(phone) {
  rateLimit.reset();
  const r = await auth.requestOtp(phone, '10.5.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.5.0.1');
  await db.query("UPDATE users SET first_name = 'U', created_at = now() - interval '3 days' WHERE id = $1", [t.user.id]);
  return { id: t.user.id, sid: t.session_id };
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('reply token: reply + read work only for that chat and session', async () => {
  const a = await user('+923551110001');
  const b = await user('+923551110002');
  await users.addContact(b.id, a.id);
  const chat = await chats.getOrCreatePrivate(a.id, b.id);
  const m = await messages.sendMessage(a.id, chat.id, { text: 'are you coming?' });
  const tok = notify.replyToken(b.id, b.sid, chat.id);
  const r = await notify.reply({ token: tok, text: 'yes, 5 min' });
  const list = await messages.listMessages(a.id, chat.id);
  assert.equal(list.messages[0].text, 'yes, 5 min');
  assert.equal(list.messages[0].id, r.message_id);
  const bc = (await chats.listChats(b.id)).find((c) => c.id === chat.id);
  assert.equal(bc.unread_count, 0, 'replying marks the chat read');
  await messages.sendMessage(a.id, chat.id, { text: 'ok' });
  await notify.read({ token: tok });
  assert.equal((await chats.listChats(b.id)).find((c) => c.id === chat.id).unread_count, 0);
  assert.ok(m.id);
  await assert.rejects(notify.reply({ token: 'bad', text: 'x' }), (e) => e.code === 'token_expired');
  await db.query('UPDATE sessions SET revoked_at = now() WHERE id = $1', [b.sid]);
  await assert.rejects(notify.reply({ token: tok, text: 'x' }), (e) => e.code === 'session_revoked');
});
