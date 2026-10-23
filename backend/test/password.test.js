'use strict';

/** Two-step verification. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const pwd = require('../src/services/password.service');
const users = require('../src/services/user.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

async function login(email) {
  rateLimit.reset();
  const r = await auth.requestEmailCode(email, '10.9.0.1');
  return auth.verifyEmailCode(email, r.dev_code, { name: 'test' }, '10.9.0.1');
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

test('two-step verification: set → login asks for it → wrong/right password → change → remove', async () => {
  const first = await login('two.step@talvio.test');
  const id = first.user.id;
  assert.equal((await pwd.get(id)).enabled, false);
  await rejects(pwd.set(id, { new_password: '123' }), 'password_too_short');
  await rejects(pwd.set(id, { new_password: 'secret-pass', hint: 'Secret-Pass' }), 'hint_is_password');
  const st = await pwd.set(id, { new_password: 'secret-pass', hint: 'my usual' });
  assert.equal(st.enabled, true);
  assert.equal(st.hint, 'my usual');
  const me = await users.getMe(id);
  assert.equal(me.has_password, true);
  assert.equal(me.password_hash, undefined);

  // login now stops at the password step
  const ch = await login('two.step@talvio.test');
  assert.equal(ch.needs_password, true);
  assert.equal(ch.access_token, undefined);
  assert.equal(ch.hint, 'my usual');
  await rejects(pwd.verifyLogin(ch.login_token, 'nope', { name: 'x' }, '10.9.0.2'), 'password_invalid');
  await rejects(pwd.verifyLogin('garbage', 'secret-pass', {}, '10.9.0.2'), 'login_expired');
  const ok = await pwd.verifyLogin(ch.login_token, 'secret-pass', { name: 'phone' }, '10.9.0.2');
  assert.ok(ok.access_token && ok.refresh_token);
  assert.equal(ok.user.id, id);

  // changing needs the current password
  await rejects(pwd.set(id, { current_password: 'wrong', new_password: 'another-one' }), 'password_invalid');
  await pwd.set(id, { current_password: 'secret-pass', new_password: 'another-one' });
  await rejects(pwd.remove(id, { current_password: 'secret-pass' }), 'password_invalid');
  assert.equal((await pwd.remove(id, { current_password: 'another-one' })).enabled, false);
  const plain = await login('two.step@talvio.test');
  assert.ok(plain.access_token, 'no password step any more');
});

test('forgot password: reset waits 7 days, owner can cancel, then it is removed', async () => {
  const first = await login('forgot@talvio.test');
  const id = first.user.id;
  await pwd.set(id, { new_password: 'hunter22' });
  const ch = await login('forgot@talvio.test');
  const r = await pwd.requestReset(ch.login_token);
  const days = (new Date(r.reset_pending_until) - Date.now()) / 86400000;
  assert.ok(days > 6.9 && days <= 7.01, `reset in ${days} days`);
  assert.ok((await pwd.get(id)).reset_pending_until);
  // owner cancels from a logged-in device
  assert.equal((await pwd.cancelReset(id)).reset_pending_until, null);
  // ask again and let the time pass
  await pwd.requestReset(ch.login_token);
  await db.query(`UPDATE users SET password_reset_after = now() - interval '1 minute' WHERE id = $1`, [id]);
  const after = await login('forgot@talvio.test');
  assert.ok(after.access_token, 'password removed after the waiting period');
  assert.equal((await pwd.get(id)).enabled, false);
});
