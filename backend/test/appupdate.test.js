'use strict';

/** In-app updates. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';

const db = require('../src/db');
const settings = require('../src/services/settings.service');
const updates = require('../src/services/appupdate.service');

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

const release = {
  name: 'Hushavia Android (test build #42)',
  body: 'Hushavia 1.1.42 · built from abc',
  published_at: '2026-11-07T10:00:00Z',
  assets: [
    { name: 'hushavia.apk', browser_download_url: 'https://github.com/x/y/releases/download/android-latest/hushavia.apk', size: 60000000, digest: 'sha256:abcd' },
    { name: 'hushavia-arm32.apk', browser_download_url: 'https://github.com/x/y/releases/download/android-latest/hushavia-arm32.apk', size: 52000000 },
    { name: 'hushavia-playstore.aab', browser_download_url: 'https://github.com/x/y/a.aab', size: 1 },
  ],
};

test('older app gets the right APK for its CPU, with size and checksum', async () => {
  updates._setRelease(release);
  const r = await updates.check({ build: '40', abi: 'arm64-v8a' });
  assert.equal(r.update, true);
  assert.equal(r.version, '1.1.42');
  assert.match(r.url, /hushavia\.apk$/);
  assert.equal(r.sha256, 'abcd');
  assert.equal(r.force, false);
  const old = await updates.check({ build: '40', abi: 'armeabi-v7a' });
  assert.match(old.url, /hushavia-arm32\.apk$/);
  assert.equal(old.sha256, null);
});

test('up to date, dev builds and GitHub being down never offer an update', async () => {
  updates._setRelease(release);
  assert.equal((await updates.check({ build: '42', abi: 'arm64-v8a' })).update, false);
  assert.equal((await updates.check({ build: '0', abi: 'arm64-v8a' })).update, false);
  updates._setRelease(null);
  assert.equal((await updates.check({ build: '5' })).update, false);
});

test('admin minimum version forces the update', async () => {
  updates._setRelease(release);
  await settings.update({ min_app_version: '1.1.41' }, null);
  assert.equal((await updates.check({ build: '40', abi: 'arm64-v8a' })).force, true);
  assert.equal((await updates.check({ build: '41', abi: 'arm64-v8a' })).force, false);
});
