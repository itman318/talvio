'use strict';

/* Passkeys: log in with the phone's fingerprint / face / screen lock instead of a code.
 * The phone keeps an Ed25519 private key (in its secure storage, unlocked with biometrics);
 * the server stores only the public key and checks a signature over a one-time challenge. */
const crypto = require('crypto');
const config = require('../config');
const db = require('../db');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { signJwt, verifyJwt, randomToken } = require('../utils/crypto');
const { badRequest, unauthorized, forbidden, notFound } = require('../utils/errors');

const MAX_PER_USER = 10;
const CHALLENGE_TTL_SEC = 120;
const SPKI_ED25519 = Buffer.from('302a300506032b6570032100', 'hex');
const used = new Map(); // challenge nonce → expiry (single use)

function publicKeyObject(b64) {
  const raw = Buffer.from(String(b64 || ''), 'base64');
  if (raw.length !== 32) throw badRequest('invalid_key', 'Invalid passkey');
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_ED25519, raw]), format: 'der', type: 'spki' });
}

const json = (p) => ({
  id: p.id,
  name: p.name,
  created_at: new Date(p.created_at).toISOString(),
  last_used_at: p.last_used_at ? new Date(p.last_used_at).toISOString() : null,
});

async function list(userId) {
  return (await db.many('SELECT * FROM user_passkeys WHERE user_id = $1 ORDER BY id', [userId])).map(json);
}

async function register(userId, body = {}) {
  publicKeyObject(body.public_key); // validates
  const name = (v.str(body.name, { field: 'name', max: 100 }) || 'Phone').slice(0, 100);
  const n = await db.one('SELECT count(*) AS n FROM user_passkeys WHERE user_id = $1', [userId]);
  if (Number(n.n) >= MAX_PER_USER) throw badRequest('too_many_passkeys', `You can have up to ${MAX_PER_USER} passkeys`);
  const row = await db.one('INSERT INTO user_passkeys (user_id, public_key, name) VALUES ($1, $2, $3) RETURNING *', [userId, String(body.public_key), name]);
  return json(row);
}

async function remove(userId, idRaw) {
  const r = await db.one('DELETE FROM user_passkeys WHERE id = $1 AND user_id = $2 RETURNING id', [v.id(idRaw, 'passkey_id'), userId]);
  if (!r) throw notFound('passkey_not_found', 'Passkey not found');
  return { ok: true };
}

/** Step 1: a one-time challenge for this passkey. */
async function challenge(body = {}, ip) {
  rateLimit.enforce(`pk:challenge:${ip}`, 60, 60 * 60 * 1000);
  const id = v.id(body.credential_id, 'credential_id');
  return { challenge: signJwt({ typ: 'pk', cid: id, n: randomToken(12) }, config.jwtSecret, CHALLENGE_TTL_SEC) };
}

/** Step 2: the phone signed the challenge → a normal session. */
async function verify(body = {}, ip) {
  rateLimit.enforce(`pk:verify:${ip}`, 30, 60 * 60 * 1000, 'Too many attempts. Try again later.');
  const id = v.id(body.credential_id, 'credential_id');
  const ch = String(body.challenge || '');
  const p = verifyJwt(ch, config.jwtSecret);
  if (!p || p.typ !== 'pk' || p.cid !== id) throw unauthorized('challenge_expired', 'Try again');
  const now = Date.now();
  for (const [k, exp] of used) if (exp < now) used.delete(k);
  if (used.has(p.n)) throw unauthorized('challenge_expired', 'Try again');
  used.set(p.n, now + CHALLENGE_TTL_SEC * 1000);

  const pk = await db.one('SELECT * FROM user_passkeys WHERE id = $1', [id]);
  if (!pk) throw notFound('passkey_not_found', 'This passkey was removed. Log in with a code.');
  const sig = Buffer.from(String(body.signature || ''), 'base64');
  if (sig.length !== 64 || !crypto.verify(null, Buffer.from(ch), publicKeyObject(pk.public_key), sig)) {
    throw unauthorized('passkey_invalid', 'Passkey check failed');
  }
  const userService = require('./user.service');
  const u = await db.one('SELECT * FROM users WHERE id = $1', [pk.user_id]);
  if (!u || u.status !== 'active') throw unauthorized('account_deleted', 'This account no longer exists');
  if (userService.isBanned(u)) throw forbidden('account_banned', 'Your account has been banned');
  await db.query('UPDATE user_passkeys SET last_used_at = now() WHERE id = $1', [pk.id]);
  const tokens = await require('./auth.service').createSession(u.id, body.device, ip);
  return { ...tokens, user: userService.serialize(u, u.id), needs_profile: !u.first_name };
}

module.exports = { list, register, remove, challenge, verify };
