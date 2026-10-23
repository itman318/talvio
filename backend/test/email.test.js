'use strict';

/** Email-code login. WARNING: wipes the test database. */
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
const settings = require('../src/services/settings.service');
const mail = require('../src/services/mail.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  // the migration must be re-runnable
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

test('email login: code → new account without a phone → profile → same account next time', async () => {
  const r = await auth.requestEmailCode('  Sana.Ahmed@Gmail.com ', '10.1.0.1');
  assert.equal(r.email, 'sana.ahmed@gmail.com');
  assert.match(r.dev_code, /^\d{6}$/);
  await rejects(auth.verifyEmailCode('sana.ahmed@gmail.com', '000000', {}, '10.1.0.1'), 'otp_invalid');
  const s = await auth.verifyEmailCode('SANA.AHMED@gmail.com', r.dev_code, { platform: 'android' }, '10.1.0.1');
  assert.ok(s.access_token && s.refresh_token);
  assert.equal(s.needs_profile, true);
  assert.equal(s.user.email, 'sana.ahmed@gmail.com');
  assert.equal(s.user.phone, null);
  await users.updateProfile(s.user.id, { first_name: 'Sana' });

  rateLimit.reset();
  const r2 = await auth.requestEmailCode('sana.ahmed@gmail.com', '10.1.0.2');
  const s2 = await auth.verifyEmailCode('sana.ahmed@gmail.com', r2.dev_code, {}, '10.1.0.2');
  assert.equal(s2.user.id, s.user.id);
  assert.equal(s2.needs_profile, false);
  await rejects(auth.verifyEmailCode('sana.ahmed@gmail.com', r2.dev_code, {}, '10.1.0.2'), 'otp_expired');

  const me = await users.getMe(s.user.id);
  assert.equal(me.email, 'sana.ahmed@gmail.com');
});

test('email and phone accounts can chat with each other', async () => {
  const e = await auth.requestEmailCode('ali@example.com', '10.1.0.3');
  const ea = await auth.verifyEmailCode('ali@example.com', e.dev_code, {}, '10.1.0.3');
  const p = await auth.requestOtp('+923001234500', '10.1.0.4');
  const pa = await auth.verifyOtp('+923001234500', p.dev_code, {}, '10.1.0.4');
  await users.updateProfile(ea.user.id, { first_name: 'Ali', username: 'ali_mail' });
  await users.updateProfile(pa.user.id, { first_name: 'Bilal' });
  const chat = await chats.getOrCreatePrivate(pa.user.id, ea.user.id);
  assert.ok(chat.id);
  // other users never see the email
  const seen = await users.getUser(pa.user.id, ea.user.id);
  assert.equal(seen.email, undefined);
});

test('email validation, rate limit, and the admin switch', async () => {
  await rejects(auth.requestEmailCode('not-an-email', '10.1.0.5'), 'invalid_email');
  await auth.requestEmailCode('wait@example.com', '10.1.0.5');
  await rejects(auth.requestEmailCode('wait@example.com', '10.1.0.5'), 'rate_limited');
  rateLimit.reset();
  await settings.update({ login_email_enabled: false });
  await rejects(auth.requestEmailCode('off@example.com', '10.1.0.6'), 'login_method_disabled');
  const pub = await settings.publicConfig();
  assert.deepEqual(pub.login_methods, { email: false, phone: true });
  await settings.update({ login_email_enabled: true });
});

test('code email content', () => {
  const m = mail.codeEmail('123456');
  assert.match(m.subject, /123456/);
  assert.match(m.text, /123456/);
  assert.match(m.html, /123456/);
});
