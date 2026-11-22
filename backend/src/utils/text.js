'use strict';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

/** First `n` code points, without splitting an emoji sequence or an accented character. */
function cut(s, n) {
  const str = String(s || '');
  if (str.length <= n) return str;
  let remaining = n;
  let out = '';
  for (const { segment } of segmenter.segment(str)) {
    remaining -= Array.from(segment).length;
    if (remaining < 0) break;
    out += segment;
  }
  return out;
}

module.exports = { cut };
