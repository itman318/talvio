'use strict';

/** Stickers & GIF messages. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';
process.env.UPLOAD_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'talvio-st-'));

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const media = require('../src/services/media.service');
const stickers = require('../src/services/sticker.service');
const settings = require('../src/services/settings.service');

async function rejects(p, code) {
  await assert.rejects(p, (e) => { assert.equal(e.code, code, `${e.code}: ${e.message}`); return true; });
}
let n = 0;
async function signup(first) {
  rateLimit.reset();
  const email = `${first.toLowerCase()}${(n += 1)}@talvio.test`;
  const r = await auth.requestEmailCode(email, `10.9.0.${n}`);
  const s = await auth.verifyEmailCode(email, r.dev_code, {}, `10.9.0.${n}`);
  await users.updateProfile(s.user.id, { first_name: first });
  return s.user.id;
}
function fakeUpload(name, bytes = 2000, mimetype = 'image/png') {
  const p = path.join(process.env.UPLOAD_DIR, `up-${Date.now()}-${name}`);
  fs.writeFileSync(p, Buffer.alloc(bytes, 1));
  return { path: p, size: bytes, mimetype, originalname: name };
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

test('official pack is installed once and everyone has it', async () => {
  await stickers.ensureOfficialPacks();
  await stickers.ensureOfficialPacks(); // idempotent
  const mine = await stickers.myPacks(A);
  const desi = mine.find((p) => p.slug === 'quack-zib');
  assert.ok(desi, 'official pack listed');
  assert.equal(desi.is_official, true);
  assert.equal(desi.stickers.length, 9);
  assert.match(desi.stickers[0].url, /\/api\/media\/\d+\/public$/);
  const m = await media.getPublic(desi.stickers[0].media_id);
  assert.ok(fs.existsSync(media.absolutePath(m)), 'sticker file copied into uploads');
});

test('send a sticker; the other person can see it', async () => {
  const desi = (await stickers.myPacks(A)).find((p) => p.slug === 'quack-zib');
  const r = await messages.sendMessage(A, chat.id, { type: 'sticker', sticker_id: desi.stickers[0].id });
  const msg = r.message || r;
  assert.equal(msg.type, 'sticker');
  assert.equal(msg.meta.sticker.emoji, '🔍📚🤓');
  assert.ok((await media.getAccessible(B, desi.stickers[0].media_id)).id);
  await rejects(messages.sendMessage(A, chat.id, { type: 'sticker', sticker_id: 999999 }), 'sticker_not_found');
});

test('own pack: create, add sticker (only sticker uploads), share, install, delete', async () => {
  const pack = await stickers.createPack(A, { title: 'Office jokes' });
  const up = await media.registerUpload(A, fakeUpload('s.png'), { kind: 'sticker' });
  const photo = await media.registerUpload(A, fakeUpload('p.png'), { kind: 'image' });
  await rejects(stickers.addSticker(A, pack.id, { media_id: photo.id }), 'invalid_media');
  await rejects(media.registerUpload(A, fakeUpload('big.png', 2 * 1024 * 1024), { kind: 'sticker' }), 'file_too_large');
  await rejects(media.registerUpload(A, fakeUpload('x.jpg', 1000, 'image/jpeg'), { kind: 'sticker' }), 'invalid_file_type');
  const st = await stickers.addSticker(A, pack.id, { media_id: up.id, emoji: '😎' });
  await rejects(stickers.addSticker(B, pack.id, { media_id: up.id }), 'not_owner');
  const found = await stickers.searchPacks(B, 'office');
  assert.equal(found[0].id, pack.id);
  await stickers.installPack(B, pack.id);
  assert.ok((await stickers.myPacks(B)).some((p) => p.id === pack.id));
  const sent = await messages.sendMessage(B, chat.id, { type: 'sticker', sticker_id: st.id });
  assert.equal((sent.message || sent).type, 'sticker');
  await stickers.uninstallPack(B, pack.id);
  assert.ok(!(await stickers.myPacks(B)).some((p) => p.id === pack.id));
  await rejects(stickers.deletePack(B, pack.id), 'not_owner');
  await stickers.deletePack(A, pack.id);
});

test('GIF messages only from Tenor', async () => {
  await settings.update({ gif_api_key: 'test-key' });
  const ok = await messages.sendMessage(A, chat.id, { type: 'gif', gif: { url: 'https://media.tenor.com/abc/x.gif', preview: 'https://media.tenor.com/abc/s.gif', width: 220, height: 160 } });
  assert.equal((ok.message || ok).meta.gif.width, 220);
  await rejects(messages.sendMessage(A, chat.id, { type: 'gif', gif: { url: 'https://evil.example/x.gif' } }), 'invalid_gif');
  await settings.update({ feature_gifs: false });
  await rejects(messages.sendMessage(A, chat.id, { type: 'gif', gif: { url: 'https://media.tenor.com/abc/x.gif' } }), 'feature_disabled');
  await settings.update({ feature_gifs: true });
});
