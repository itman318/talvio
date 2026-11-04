'use strict';

/** "Online" follows the app being on screen, with a short grace for quick app switches. No database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const presence = require('../src/services/presence');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

test('online = app on screen; hidden → last seen after the grace time; back quickly → no flicker', async () => {
  const events = [];
  presence.setListener((uid, online) => events.push([uid, online]));
  const U = 9001;

  presence.add(U);
  presence.socketUp('s1', U);
  assert.deepEqual(events, [[U, true]]);
  assert.equal(presence.isShownOnline(U), true);

  // switched to another app and back within the grace time: nothing changes for others
  presence.setForeground('s1', U, false);
  assert.equal(presence.isShownOnline(U), true);
  await wait(300);
  presence.setForeground('s1', U, true);
  await wait(presence.HIDE_GRACE_MS + 200);
  assert.deepEqual(events, [[U, true]]);

  // hidden for longer: "last seen" (socket still connected)
  presence.setForeground('s1', U, false);
  await wait(presence.HIDE_GRACE_MS + 200);
  assert.deepEqual(events, [[U, true], [U, false]]);
  assert.equal(presence.isShownOnline(U), false);
  assert.equal(presence.isOnline(U), true); // still connected (pushes still go out: not active)
  assert.equal(presence.isActive(U), false);

  // opened again
  presence.setForeground('s1', U, true);
  assert.deepEqual(events.at(-1), [U, true]);

  // app closed (socket gone) while another device is hidden: last seen
  presence.add(U);
  presence.socketUp('s2', U, { foreground: false }); // reconnected while hidden: doesn't count as online
  assert.equal(events.length, 3);
  presence.remove(U);
  presence.socketDown('s1', U);
  await wait(presence.HIDE_GRACE_MS + 200);
  assert.deepEqual(events.at(-1), [U, false]);
  presence.remove(U);
  presence.socketDown('s2', U);
  assert.equal(presence.isOnline(U), false);
  assert.equal(events.length, 4);
});
