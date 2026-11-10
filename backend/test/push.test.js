'use strict';

/** The push library loads the way the server uses it (a broken upgrade once silently turned pushes off). */
const test = require('node:test');
const assert = require('node:assert/strict');

test('firebase-admin: the modular API the push service uses is there', () => {
  let appMod;
  try {
    appMod = require('firebase-admin/app');
  } catch (_) {
    return; // optional dependency not installed here
  }
  assert.equal(typeof appMod.initializeApp, 'function');
  assert.equal(typeof appMod.cert, 'function');
  assert.equal(typeof require('firebase-admin/messaging').getMessaging, 'function');
});
