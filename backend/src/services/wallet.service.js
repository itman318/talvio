'use strict';

/**
 * The server never sees wallet keys. It only keeps the PUBLIC addresses a person chose to share,
 * so friends can pay them from a chat, and checks the shape of "crypto" chat cards.
 */
const crypto = require('crypto');
const db = require('../db');
const settings = require('./settings.service');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const NETWORKS = ['tron', 'eth', 'bsc', 'polygon', 'arbitrum', 'base', 'avalanche'];
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function isTron(a) {
  if (typeof a !== 'string' || !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(a)) return false;
  let n = 0n;
  for (const ch of a) n = n * 58n + BigInt(B58.indexOf(ch));
  const hex = n.toString(16).padStart(50, '0');
  const b = Buffer.from(hex, 'hex');
  if (b.length !== 25 || b[0] !== 0x41) return false;
  const sum = crypto.createHash('sha256').update(crypto.createHash('sha256').update(b.subarray(0, 21)).digest()).digest().subarray(0, 4);
  return sum.equals(b.subarray(21));
}

const isEvm = (a) => typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a);

async function setMine(userId, body = {}) {
  await settings.requireFeature('feature_wallet', 'Wallet');
  const share = body.share === true;
  const tron = share && body.tron ? String(body.tron) : null;
  const evm = share && body.evm ? String(body.evm) : null;
  if (tron && !isTron(tron)) throw badRequest('invalid_address', 'Not a TRON address');
  if (evm && !isEvm(evm)) throw badRequest('invalid_address', 'Not a valid address');
  await db.query('UPDATE users SET wallet_tron = $2, wallet_evm = $3, updated_at = now() WHERE id = $1', [userId, tron, evm]);
  return { share: !!(tron || evm), tron, evm };
}

/** Someone's shared addresses — only for people they can chat with (never if either blocked the other). */
async function getFor(userId, otherIdRaw) {
  await settings.requireFeature('feature_wallet', 'Wallet');
  const otherId = v.id(otherIdRaw, 'user_id');
  const u = await db.one(`SELECT id, wallet_tron, wallet_evm FROM users WHERE id = $1 AND status = 'active'`, [otherId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  if (await require('./user.service').isBlockedEither(userId, otherId)) throw forbidden('blocked', 'Not available'); // eslint-disable-line global-require
  return { tron: u.wallet_tron || null, evm: u.wallet_evm || null };
}

/** Checks a crypto card before it is stored. Amounts are whole units as a decimal string. */
async function cardMeta(body = {}) {
  await settings.requireFeature('feature_wallet', 'Wallet');
  const c = body.crypto || {};
  const kind = v.oneOf(c.kind, ['sent', 'request'], 'kind');
  const network = v.oneOf(c.network, NETWORKS, 'network');
  const symbol = v.str(c.symbol, { field: 'symbol', min: 1, max: 12, required: true });
  const amount = String(c.amount || '');
  if (!/^[1-9]\d{0,77}$/.test(amount)) throw badRequest('invalid_amount', 'Invalid amount');
  const decimals = Number(c.decimals);
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 36) throw badRequest('invalid_amount', 'Invalid decimals');
  const okAddr = network === 'tron' ? isTron : isEvm;
  const to = String(c.to || '');
  if (!okAddr(to)) throw badRequest('invalid_address', 'Invalid address');
  const contract = c.contract ? String(c.contract) : null;
  if (contract && !okAddr(contract)) throw badRequest('invalid_address', 'Invalid token address');
  let tx = null;
  if (kind === 'sent') {
    tx = String(c.tx || '');
    if (!(network === 'tron' ? /^[0-9a-f]{64}$/i.test(tx) : /^0x[0-9a-f]{64}$/i.test(tx))) throw badRequest('invalid_tx', 'Invalid transaction id');
  }
  const note = c.note ? v.str(String(c.note), { field: 'note', max: 140 }) : null;
  return { crypto: { kind, network, symbol, amount, decimals, to, contract, tx, note } };
}

function previewText(meta) {
  const c = meta && meta.crypto;
  if (!c) return '💸 Crypto';
  const units = BigInt(c.amount);
  const base = 10n ** BigInt(c.decimals);
  const frac = (units % base).toString().padStart(c.decimals, '0').slice(0, 6).replace(/0+$/, '');
  const amt = `${units / base}${frac ? `.${frac}` : ''}`;
  return c.kind === 'request' ? `💸 Request: ${amt} ${c.symbol}` : `💸 Sent ${amt} ${c.symbol}`;
}

module.exports = { setMine, getFor, cardMeta, previewText, isTron, isEvm, NETWORKS };
