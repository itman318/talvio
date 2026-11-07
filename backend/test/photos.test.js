'use strict';

/** Fast photos: inline thumb + bubble-size preview. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';
process.env.UPLOAD_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'hushavia-ph-'));

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const media = require('../src/services/media.service');
const settings = require('../src/services/settings.service');
const images = require('../src/utils/images');

let n = 0;
async function signup(first) {
  rateLimit.reset();
  const email = `${first.toLowerCase()}${(n += 1)}@hushavia.test`;
  const r = await auth.requestEmailCode(email, `10.8.0.${n}`);
  const s = await auth.verifyEmailCode(email, r.dev_code, {}, `10.8.0.${n}`);
  await users.updateProfile(s.user.id, { first_name: first });
  return s.user.id;
}

let A; let B; let chat;
test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('Asad');
  B = await signup('Bina');
  chat = await chats.getOrCreatePrivate(A, B);
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

async function realPhoto(w, h) {
  const sharp = require('sharp'); // eslint-disable-line global-require
  const raw = Buffer.alloc(w * h * 3);
  for (let i = 0; i < raw.length; i += 1) raw[i] = (i * 7 + ((i / w) | 0) + Math.floor(Math.random() * 60)) & 255;
  const p = path.join(process.env.UPLOAD_DIR, `photo-${Date.now()}.jpg`);
  await sharp(raw, { raw: { width: w, height: h, channels: 3 } }).blur(1.2).jpeg({ quality: 88 }).toFile(p);
  return { path: p, size: fs.statSync(p).size, mimetype: 'image/jpeg', originalname: 'IMG_1.jpg' };
}

test('a photo gets an instant thumb, its real size and a smaller bubble preview', { skip: !images.available() && 'sharp not installed' }, async () => {
  const up = await media.registerUpload(A, await realPhoto(2000, 1500), { kind: 'image' }); // no width/height from the phone
  assert.ok(up.thumb && up.thumb.length < 3000, 'tiny base64 thumb');
  assert.equal(up.width, 2000);
  assert.equal(up.height, 1500);

  const msg = await messages.sendMessage(A, chat.id, { type: 'image', media_id: up.id });
  const list = await messages.listMessages(B, chat.id, {});
  const got = (list.messages || list).find((m) => m.id === msg.id);
  assert.equal(got.media.thumb, up.thumb, 'the receiver gets the thumb inside the message');

  const row = await db.one('SELECT * FROM media WHERE id = $1', [up.id]);
  const pv = await media.previewPath(row);
  assert.ok(pv.endsWith('.p.webp'), 'preview made');
  assert.ok(fs.statSync(pv).size < Number(row.size_bytes), 'preview is smaller');
});

test('files sharp cannot read still upload (no thumb, original served)', async () => {
  const p = path.join(process.env.UPLOAD_DIR, 'broken.jpg');
  fs.writeFileSync(p, Buffer.alloc(300000, 7));
  const up = await media.registerUpload(A, { path: p, size: 300000, mimetype: 'image/jpeg', originalname: 'broken.jpg' }, { kind: 'image' });
  assert.equal(up.thumb, undefined);
  const row = await db.one('SELECT * FROM media WHERE id = $1', [up.id]);
  assert.equal(await media.previewPath(row), media.absolutePath(row));
  await media.backfillThumbs(); // marks it, never loops on it
  assert.equal((await db.one('SELECT thumb_failed FROM media WHERE id = $1', [up.id])).thumb_failed, true);
});
