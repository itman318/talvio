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
