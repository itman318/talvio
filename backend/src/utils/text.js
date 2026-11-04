'use strict';

/**
 * First `n` characters of a text without cutting an emoji in half.
 * (String.slice counts UTF-16 units: cutting inside an emoji leaves half of it, which apps show as "�".)
 */
function cut(s, n) {
  const str = String(s || '');
  if (str.length <= n) return str;
  return Array.from(str).slice(0, n).join('');
}

module.exports = { cut };
