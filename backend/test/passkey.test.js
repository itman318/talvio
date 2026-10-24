'use strict';

/** Passkey login. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const pk = require('../src/services/passkey.service');
const settings = require('../src/services/settings.service');

function keyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(12);
  return { pub: raw.toString('base64'), sign: (s) => crypto.sign(null, Buffer.from(s), privateKey).toString('base64') };
}
async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

test('passkey: register → challenge → signed login; wrong key, replay and removed key fail', async () => {
  const r = await auth.requestEmailCode('pk@talvio.test', '10.6.0.1');
  const t = await auth.verifyEmailCode('pk@talvio.test', r.dev_code, { name: 'x' }, '10.6.0.1');
  const k = keyPair();
  await rejects(pk.register(t.user.id, { public_key: 'abc' }), 'invalid_key');
  const reg = await pk.register(t.user.id, { public_key: k.pub, name: 'Pixel 8' });
  assert.equal((await pk.list(t.user.id)).length, 1);

  const { challenge } = await pk.challenge({ credential_id: reg.id }, '10.6.0.2');
  const other = keyPair();
  await rejects(pk.verify({ credential_id: reg.id, challenge, signature: other.sign(challenge) }, '10.6.0.2'), 'passkey_invalid');
  const c2 = (await pk.challenge({ credential_id: reg.id }, '10.6.0.2')).challenge;
  const ok = await pk.verify({ credential_id: reg.id, challenge: c2, signature: k.sign(c2), device: { name: 'Pixel' } }, '10.6.0.2');
  assert.ok(ok.access_token && ok.refresh_token);
  assert.equal(ok.user.id, t.user.id);
  await rejects(pk.verify({ credential_id: reg.id, challenge: c2, signature: k.sign(c2) }, '10.6.0.2'), 'challenge_expired');
  // a challenge for another passkey can't be reused
  const c3 = (await pk.challenge({ credential_id: reg.id + 1 }, '10.6.0.2')).challenge;
  await rejects(pk.verify({ credential_id: reg.id, challenge: c3, signature: k.sign(c3) }, '10.6.0.2'), 'challenge_expired');

  await pk.remove(t.user.id, reg.id);
  const c4 = (await pk.challenge({ credential_id: reg.id }, '10.6.0.2')).challenge;
  await rejects(pk.verify({ credential_id: reg.id, challenge: c4, signature: k.sign(c4) }, '10.6.0.2'), 'passkey_not_found');
});
