'use strict';

/** Self-hosted crash reports. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const crash = require('../src/services/crash.service');
const content = require('../src/services/content.service');

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
});
test.beforeEach(() => rateLimit.reset());
test.after(() => db.close());

test('same crash from many phones is grouped; users counted; resolve/reopen', async () => {
  const report = (stack) => ({ platform: 'android', app_version: '1.0.0', device: 'Pixel 7', message: 'Null check operator used on a null value', stack });
  await crash.record(null, report('#0 ChatScreen.build (package:chatapp/screens/chat_screen.dart:120:15)\n#1 0x7f00aa'), '1.2.3.4');
  await crash.record(null, report('#0 ChatScreen.build (package:chatapp/screens/chat_screen.dart:120:15)\n#1 0x7f00bb'), '1.2.3.5');
  let r = await crash.list();
  assert.equal(r.crashes.length, 1, 'grouped despite different addresses');
  assert.equal(r.crashes[0].count, 2);
  assert.equal(Number(r.totals.open), 1);
  await crash.resolve(r.crashes[0].id);
  assert.equal((await crash.list()).crashes.length, 0);
  assert.equal((await crash.list({ status: 'resolved' })).crashes.length, 1);
  // the same crash happening again after "fixed" reopens it
  await crash.record(null, report('#0 ChatScreen.build (package:chatapp/screens/chat_screen.dart:120:15)\n#1 0x7f00cc'), '1.2.3.6');
  r = await crash.list();
  assert.equal(r.crashes.length, 1);
  assert.equal(r.crashes[0].count, 3);
});

test('long/garbage input is cut down, never throws', async () => {
  await crash.record(null, { message: 'x'.repeat(10000), stack: '\u0000'.repeat(10), platform: 'toaster' }, '9.9.9.9');
  const r = await crash.list({ status: 'all' });
  const big = r.crashes.find((c) => c.message.startsWith('xxx'));
  assert.ok(big.message.length <= 2000);
  assert.equal(big.platform, 'other');
});

test('legal pages have built-in text', async () => {
  const t = await content.get('terms');
  assert.match(t.body, /Acceptable use/);
  assert.match(content.renderHtml(t), /Terms of Service/);
});
