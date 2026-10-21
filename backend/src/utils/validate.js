'use strict';

const { badRequest } = require('./errors');

/** Normalise to E.164 ("+923001234567"). Throws on invalid input. */
function normalizePhone(input) {
  if (typeof input !== 'string') throw badRequest('invalid_phone', 'Phone number is required');
  let p = input.trim().replace(/[\s\-().]/g, '');
  if (p.startsWith('00')) p = `+${p.slice(2)}`;
  if (!/^\+[1-9]\d{7,14}$/.test(p)) {
    throw badRequest('invalid_phone', 'Phone number must be in international format, e.g. +923001234567');
  }
  return p;
}

/** Same as normalizePhone but returns null instead of throwing. */
function tryNormalizePhone(input) {
  try {
    return normalizePhone(input);
  } catch (_) {
    return null;
  }
}

const USERNAME_RE = /^[a-zA-Z][a-zA-Z0-9_]{3,30}[a-zA-Z0-9]$/;

function validateUsername(value) {
  if (value === null || value === '') return null;
  if (typeof value !== 'string' || !USERNAME_RE.test(value) || value.includes('__')) {
    throw badRequest(
      'invalid_username',
      'Username must be 5-32 characters: letters, digits and underscores, starting with a letter',
    );
  }
  return value;
}

function str(value, { field, max, min = 0, trim = true, required = false } = {}) {
  if (value === undefined || value === null) {
    if (required) throw badRequest('invalid_input', `${field} is required`);
    return undefined;
  }
  if (typeof value !== 'string') throw badRequest('invalid_input', `${field} must be a string`);
  const v = trim ? value.trim() : value;
  if (v.length < min) throw badRequest('invalid_input', `${field} must be at least ${min} characters`);
  if (max && v.length > max) throw badRequest('invalid_input', `${field} must be at most ${max} characters`);
  return v;
}

function id(value, field = 'id') {
  const n = typeof value === 'number' ? value : parseInt(value, 10);
  if (!Number.isSafeInteger(n) || n <= 0 || (typeof value === 'string' && !/^\d+$/.test(value))) {
    throw badRequest('invalid_input', `${field} must be a positive integer`);
  }
  return n;
}

function optionalId(value, field) {
  if (value === undefined || value === null || value === '') return null;
  return id(value, field);
}

function idList(value, field = 'ids', max = 100) {
  if (!Array.isArray(value)) throw badRequest('invalid_input', `${field} must be an array`);
  if (value.length > max) throw badRequest('invalid_input', `${field} can contain at most ${max} items`);
  return [...new Set(value.map((v) => id(v, field)))];
}

function oneOf(value, allowed, field) {
  if (!allowed.includes(value)) {
    throw badRequest('invalid_input', `${field} must be one of: ${allowed.join(', ')}`);
  }
  return value;
}

function bool(value, field) {
  if (typeof value !== 'boolean') throw badRequest('invalid_input', `${field} must be true or false`);
  return value;
}

function limit(value, def = 50, max = 100) {
  const n = parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) return def;
  return Math.min(n, max);
}

module.exports = {
  normalizePhone,
  tryNormalizePhone,
  validateUsername,
  str,
  id,
  optionalId,
  idList,
  oneOf,
  bool,
  limit,
};
