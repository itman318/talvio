'use strict';

/** View-once media, message effects, chat lock. WARNING: wipes the test database. */
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
const mediaService = require('../src/services/media.service');
const settings = require('../src/services/settings.service');

async function user(phone) {
  rateLimit.reset();
  const r = await auth.requestOtp(phone, '10.9.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.9.0.1');
  await db.query("UPDATE users SET first_name = 'T', created_at = now() - interval '3 days' WHERE id = $1", [t.user.id]);
  return t.user.id;
}
async function image(uploader) {
  return db.one(
    `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name) VALUES ($1, 'image', 'image/jpeg', 100, $2, 'x') RETURNING id`,
    [uploader, `t/${Math.random()}`],
  );
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('view once: opened a single time, file only right after opening, not forwardable', async () => {
  const a = await user('+923771110001');
  const b = await user('+923771110002');
  const chat = await chats.getOrCreatePrivate(a, b);
  const img = await image(a);
  const m = await messages.sendMessage(a, chat.id, { type: 'image', media_id: img.id, view_once: true });
  assert.equal(m.view_once, true);
  assert.deepEqual(m.opened_by, []);
  await assert.rejects(messages.sendMessage(a, chat.id, { type: 'text', text: 'x', view_once: true }));

  // b can't fetch the file before opening; the sender always can
  await assert.rejects(mediaService.getAccessible(b, img.id));
  assert.ok(await mediaService.getAccessible(a, img.id));
  await assert.rejects(messages.openOnce(a, m.id), (e) => e.code === 'own_view_once');
  await messages.openOnce(b, m.id);
  assert.ok(await mediaService.getAccessible(b, img.id));
  await assert.rejects(messages.openOnce(b, m.id), (e) => e.code === 'already_opened');
  // a few minutes later the file is gone for b
  await db.query("UPDATE message_once_views SET opened_at = now() - interval '10 minutes'");
  await assert.rejects(mediaService.getAccessible(b, img.id));
  const list = await messages.listMessages(a, chat.id, {});
  assert.deepEqual(list.messages.find((x) => x.id === m.id).opened_by, [b]);
  // not forwardable, not in shared media
  await assert.rejects(messages.forwardMessages(b, { from_chat_id: chat.id, message_ids: [m.id], to_chat_ids: [chat.id] }));
  assert.equal((await messages.mediaCounts(b, chat.id)).media, 0);
});

test('message effects and chat lock', async () => {
  const a = await user('+923771110003');
  const b = await user('+923771110004');
  const chat = await chats.getOrCreatePrivate(a, b);
  const m = await messages.sendMessage(a, chat.id, { text: 'Happy birthday!', effect: 'confetti' });
  assert.equal(m.meta.effect, 'confetti');
  await assert.rejects(messages.sendMessage(a, chat.id, { text: 'x', effect: 'explode' }), (e) => e.code === 'invalid_input');
  const locked = await chats.updateMySettings(b, chat.id, { is_locked: true });
  assert.equal(locked.is_locked, true);
  const other = (await chats.listChats(a)).find((c) => c.id === chat.id);
  assert.equal(other.is_locked, false, 'lock is per person');
});
