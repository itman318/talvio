'use strict';

/** Cut previews never split an emoji (a half emoji shows as "�" in the apps). No database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const { cut } = require('../src/utils/text');

test('cut keeps emoji whole', () => {
  const s = `${'a'.repeat(119)}🛑 Stop Loss`;
  const c = cut(s, 120);
  assert.equal(c, `${'a'.repeat(119)}🛑`);
  assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(c));
  assert.equal(cut('short', 120), 'short');
  assert.equal(cut(null, 5), '');
});

test('geo: where an IP is, and readable device names', () => {
  const geo = require('../src/utils/geo');
  const g = geo.lookup('::ffff:8.8.8.8');
  assert.equal(g.ip, '8.8.8.8');
  assert.equal(g.countryCode, 'US');
  assert.equal(g.country, 'United States');
  assert.equal(geo.lookup('').label, null);
  assert.equal(geo.deviceLabel({ name: 'Infinix X6880', platform: 'android', app_version: '1.0.0' }), 'Infinix X6880 · Android · Hushavia 1.0.0');
  assert.match(geo.localTime(new Date('2026-11-06T10:00:00Z'), 'Asia/Karachi'), /6 Nov, 15:00 \(Karachi time\)/);
});
