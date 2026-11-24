'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { cut } = require('../src/utils/text');
const { id, idList } = require('../src/utils/validate');

test('previews keep complete grapheme clusters within their code-point limit', () => {
  assert.equal(cut('a👩‍💻b', 3), 'a');
  assert.equal(cut('a👩‍💻b', 4), 'a👩‍💻');
  assert.equal(cut('a🇵🇰b', 2), 'a');
  assert.equal(cut('ae\u0301b', 2), 'a');
  assert.equal(cut('ae\u0301b', 3), 'ae\u0301');
});

test('IDs must be positive integer numbers or digit strings', () => {
  assert.equal(id(42), 42);
  assert.equal(id('42'), 42);
  assert.deepEqual(idList([1, '1', 2]), [1, 2]);
  for (const value of [[42], {}, true, null, '42.5', 0, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => id(value), { code: 'invalid_input' });
  }
});
