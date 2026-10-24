'use strict';

/** Edit history, checklist ticks, delete window. WARNING: wipes the test database. */
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
const settings = require('../src/services/settings.service');

async function user(phone) {
  rateLimit.reset();
  const r = await auth.requestOtp(phone, '10.4.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.4.0.1');
  await db.query("UPDATE users SET first_name = 'U', created_at = now() - interval '3 days' WHERE id = $1", [t.user.id]);
  return t.user.id;
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('edit history keeps earlier versions; checklist ticks are free; delete-for-everyone window', async () => {
  const a = await user('+923661110001');
  const b = await user('+923661110002');
  const chat = await chats.getOrCreatePrivate(a, b);
  const m = await messages.sendMessage(a, chat.id, { text: 'meet at 5' });
  await messages.editMessage(a, m.id, { text: 'meet at 6' });
  await messages.editMessage(a, m.id, { text: 'meet at 7' });
  const h = await messages.editHistory(b, m.id);
  assert.deepEqual(h.versions.map((x) => x.text), ['meet at 5', 'meet at 6', 'meet at 7']);
  assert.equal(h.versions[2].current, true);

  // checklist: ticking works even after the edit window and does not mark it edited
  const notes = await chats.getOrCreatePrivate(a, a);
  const list = await messages.sendMessage(a, notes.id, { text: 'Shopping\n[ ] milk\n[ ] eggs' });
  await db.query("UPDATE messages SET created_at = now() - interval '10 days' WHERE id = $1", [list.id]);
  const ticked = await messages.editMessage(a, list.id, { text: 'Shopping\n[x] milk\n[ ] eggs' });
  assert.equal(ticked.text, 'Shopping\n[x] milk\n[ ] eggs');
  assert.equal(ticked.edited_at, null);
  await assert.rejects(messages.editMessage(a, list.id, { text: 'Shopping\n[x] milk\n[ ] bread' }), (e) => e.code === 'edit_window_passed');

  // delete for everyone: only within 48 h (still possible "for me")
  const old = await messages.sendMessage(a, chat.id, { text: 'old one' });
  await db.query("UPDATE messages SET created_at = now() - interval '3 days' WHERE id = $1", [old.id]);
  await assert.rejects(messages.deleteMessages(a, chat.id, { message_ids: [old.id], for_everyone: true }), (e) => e.code === 'delete_window_passed');
  assert.equal((await messages.deleteMessages(a, chat.id, { message_ids: [old.id] })).deleted, 1);
  const fresh = await messages.sendMessage(a, chat.id, { text: 'oops' });
  assert.equal((await messages.deleteMessages(a, chat.id, { message_ids: [fresh.id], for_everyone: true })).deleted, 1);
});
