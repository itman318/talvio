'use strict';

/** Batch E end-to-end tests: QR login for web/desktop, photo albums. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const config = require('../src/config');
const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const media = require('../src/services/media.service');
const qr = require('../src/services/qr.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.12.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  return { id: s.user.id };
}

let A;
let B;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923270000001', 'Asad');
  B = await signup('+923270000002', 'Bilal');
});
test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  for (const f of fs.readdirSync(config.uploadDir)) if (f.startsWith('test-e-')) fs.rmSync(path.join(config.uploadDir, f), { force: true });
  await db.close();
});

test('QR login: create → scan → approve wakes the long poll → tokens are handed out once', async () => {
  const c = await qr.create({ name: 'Chrome on Windows', platform: 'web' }, '203.0.113.9');
  assert.match(c.qr, /^talvio:\/\/login\?token=[A-Za-z0-9_-]{20,}$/);
  assert.equal((await qr.status(c.token, 0)).status, 'pending');

  const info = await qr.scan(A.id, c.qr); // the phone passes the whole scanned text
  assert.equal(info.device_name, 'Chrome on Windows');
  assert.equal(info.ip, '203.0.113.9');
  assert.equal((await qr.status(c.token, 0)).status, 'scanned');

  const waiting = qr.status(c.token, 10, '203.0.113.9');
  await new Promise((r) => setTimeout(r, 100));
  const t0 = Date.now();
  await qr.approve(A.id, c.token);
  const done = await waiting;
  assert.ok(Date.now() - t0 < 2000, 'long poll returns right away');
  assert.equal(done.status, 'approved');
  assert.equal(done.user.id, A.id);
  const { user, sessionId } = await auth.authenticate(done.access_token);
  assert.equal(user.id, A.id);
  const s = await db.one('SELECT platform, device_name FROM sessions WHERE id = $1', [sessionId]);
  assert.deepEqual({ ...s }, { platform: 'web', device_name: 'Chrome on Windows' });

  assert.equal((await qr.status(c.token, 0)).status, 'used', 'tokens only once');
  await rejects(qr.approve(B.id, c.token), 'qr_expired');
  await rejects(qr.scan(B.id, c.token), 'qr_used');
});

test('QR login: decline, expiry, bad codes, feature switch', async () => {
  const c = await qr.create({}, '1.2.3.4');
  await qr.decline(A.id, c.token);
  assert.equal((await qr.status(c.token, 0)).status, 'declined');

  const c2 = await qr.create({ platform: 'desktop' }, '1.2.3.4');
  await db.query(`UPDATE qr_logins SET expires_at = now() - interval '1 second' WHERE token_hash = encode(sha256($1::bytea), 'hex')`, [c2.token]);
  assert.equal((await qr.status(c2.token, 0)).status, 'expired');
  await rejects(qr.scan(A.id, c2.token), 'qr_expired');
  await rejects(qr.approve(A.id, c2.token), 'qr_expired');

  await rejects(qr.scan(A.id, 'https://evil.example.com'), 'invalid_qr');
  await rejects(qr.status('x'.repeat(30), 0), 'qr_not_found');

  await settings.update({ feature_web_login: false });
  await rejects(qr.create({}, '1.2.3.4'), 'feature_disabled');
  await settings.update({ feature_web_login: true });
  assert.equal((await settings.publicConfig()).max_accounts, 3);
});

test('albums: several photos share an album_id', async () => {
  const chat = await chats.getOrCreatePrivate(A.id, B.id);
  fs.mkdirSync(config.uploadDir, { recursive: true });
  const album = 'a1b2c3d4-0000-4000-8000-000000000001';
  const ids = [];
  for (let i = 0; i < 3; i++) {
    const file = path.join(config.uploadDir, `test-e-${Date.now()}-${i}.png`);
    fs.writeFileSync(file, Buffer.alloc(10));
    const m = await media.registerUpload(A.id, { path: file, size: 10, mimetype: 'image/png', originalname: `p${i}.png` }, { kind: 'image' });
    const msg = await messages.sendMessage(A.id, chat.id, { type: 'image', media_id: m.id, album_id: album, text: i === 0 ? 'Trip photos' : '' });
    assert.equal(msg.album_id, album);
    ids.push(msg.id);
  }
  const list = await messages.listMessages(B.id, chat.id, {});
  assert.equal(list.messages.filter((m) => m.album_id === album).length, 3);
  await rejects(messages.sendMessage(A.id, chat.id, { text: 'hi', album_id: album }), 'invalid_input');
  await rejects(messages.sendMessage(A.id, chat.id, { type: 'image', media_id: 1, album_id: 'bad id!' }), 'invalid_input');
});
