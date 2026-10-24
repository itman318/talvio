'use strict';

/** Shared media tabs + video messages. WARNING: wipes the test database. */
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
  const r = await auth.requestOtp(phone, '10.8.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.8.0.1');
  await db.query("UPDATE users SET first_name = 'T', created_at = now() - interval '3 days' WHERE id = $1", [t.user.id]);
  return t.user.id;
}
async function media(uploader, kind, extra = {}) {
  return db.one(
    `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name, duration_sec)
     VALUES ($1, $2, $3, 100, $4, 'x', $5) RETURNING id`,
    [uploader, kind, kind === 'video' ? 'video/mp4' : kind === 'voice' ? 'audio/mp4' : kind === 'image' ? 'image/jpeg' : 'application/pdf', `t/${Math.random()}`, extra.duration || null],
  );
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('shared media filters, counts and round video messages', async () => {
  const a = await user('+923331110001');
  const b = await user('+923331110002');
  const chat = await chats.getOrCreatePrivate(a, b);
  const send = (body) => messages.sendMessage(a, chat.id, body);
  await send({ type: 'text', text: 'hello' });
  await send({ type: 'text', text: 'see https://example.com/page' });
  await send({ type: 'image', media_id: (await media(a, 'image')).id });
  await send({ type: 'file', media_id: (await media(a, 'file')).id });
  await send({ type: 'voice', media_id: (await media(a, 'voice')).id });
  const vn = await send({ type: 'video_note', media_id: (await media(a, 'video', { duration: 12 })).id });
  assert.equal(vn.type, 'video_note');
  await assert.rejects(send({ type: 'video_note', media_id: (await media(a, 'video', { duration: 90 })).id }), /60 seconds/);
  await assert.rejects(send({ type: 'video_note', media_id: (await media(a, 'image')).id }), (e) => e.code === 'invalid_media');

  const counts = await messages.mediaCounts(b, chat.id);
  assert.deepEqual(counts, { media: 1, files: 1, voice: 2, links: 1 });
  const links = await messages.listMessages(b, chat.id, { filter: 'links' });
  assert.equal(links.messages.length, 1);
  assert.match(links.messages[0].text, /example\.com/);
  const voice = await messages.listMessages(b, chat.id, { filter: 'voice' });
  assert.deepEqual(voice.messages.map((m) => m.type).sort(), ['video_note', 'voice']);
  await assert.rejects(messages.listMessages(b, chat.id, { filter: 'nope' }), (e) => e.code === 'invalid_filter');
  await assert.rejects(messages.listMessages(b, chat.id, { filter: 'constructor' }), (e) => e.code === 'invalid_filter');

  // voice messages carry their waveform (clamped to 0–31, at most 100 bars)
  const w = await send({ type: 'voice', media_id: (await media(a, 'voice')).id, waveform: [0, 5, 40, -3, 12, 31, 7, 9, 'x', 3] });
  assert.deepEqual(w.meta.waveform, [0, 5, 31, 0, 12, 31, 7, 9, 0, 3]);
});
