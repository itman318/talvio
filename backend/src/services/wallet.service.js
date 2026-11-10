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

const NETWORKS = ['tron', 'eth', 'bsc', 'polygon', 'arbitrum', 'base', 'avalanche', 'btc', 'ltc', 'doge'];
const UTXO = {
  btc: { hrp: 'bc', p2pkh: [0x00], p2sh: [0x05] },
  ltc: { hrp: 'ltc', p2pkh: [0x30], p2sh: [0x32, 0x05] },
  doge: { hrp: null, p2pkh: [0x1e], p2sh: [0x16] },
};
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

const CS = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
function bech32Ok(addr, hrp) {
  if (addr !== addr.toLowerCase() && addr !== addr.toUpperCase()) return false;
  const a = addr.toLowerCase();
  const pos = a.lastIndexOf('1');
  if (pos < 1 || a.slice(0, pos) !== hrp || a.length > 90 || pos + 7 > a.length) return false;
  const data = [];
  for (const ch of a.slice(pos + 1)) {
    const v = CS.indexOf(ch);
    if (v < 0) return false;
    data.push(v);
  }
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let c = 1;
  for (const x of [...[...hrp].map((h) => h.charCodeAt(0) >> 5), 0, ...[...hrp].map((h) => h.charCodeAt(0) & 31), ...data]) {
    const b = c >>> 25;
    c = ((c & 0x1ffffff) << 5) ^ x;
    for (let i = 0; i < 5; i += 1) if ((b >> i) & 1) c ^= GEN[i];
  }
  c >>>= 0;
  return (data[0] === 0 && c === 1) || (data[0] > 0 && data[0] <= 16 && c === 0x2bc830a3);
}

function base58Version(a) {
  if (typeof a !== 'string' || !/^[1-9A-HJ-NP-Za-km-z]{25,35}$/.test(a)) return null;
  let n = 0n;
  for (const ch of a) n = n * 58n + BigInt(B58.indexOf(ch));
  let hex = n.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  const zeros = a.match(/^1*/)[0].length;
  const b = Buffer.concat([Buffer.alloc(zeros), Buffer.from(hex, 'hex')]);
  if (b.length !== 25) return null;
  const sum = crypto.createHash('sha256').update(crypto.createHash('sha256').update(b.subarray(0, 21)).digest()).digest().subarray(0, 4);
  return sum.equals(b.subarray(21)) ? b[0] : null;
}

/** A Bitcoin / Litecoin / Dogecoin address of that network. */
function isUtxoAddress(network, a) {
  const c = UTXO[network];
  if (!c || typeof a !== 'string') return false;
  if (c.hrp && a.toLowerCase().startsWith(`${c.hrp}1`)) return bech32Ok(a, c.hrp);
  const ver = base58Version(a);
  return ver !== null && (c.p2pkh.includes(ver) || c.p2sh.includes(ver));
}

function validFor(network, a) {
  if (network === 'tron') return isTron(a);
  if (UTXO[network]) return isUtxoAddress(network, a);
  return isEvm(a);
}

async function setMine(userId, body = {}) {
  await settings.requireFeature('feature_wallet', 'Wallet');
  const share = body.share === true;
  const tron = share && body.tron ? String(body.tron) : null;
  const evm = share && body.evm ? String(body.evm) : null;
  if (tron && !isTron(tron)) throw badRequest('invalid_address', 'Not a TRON address');
  if (evm && !isEvm(evm)) throw badRequest('invalid_address', 'Not a valid address');
  const utxo = {};
  for (const n of Object.keys(UTXO)) {
    utxo[n] = share && body[n] ? String(body[n]) : null;
    if (utxo[n] && !isUtxoAddress(n, utxo[n])) throw badRequest('invalid_address', `Not a valid ${n.toUpperCase()} address`);
  }
  await db.query('UPDATE users SET wallet_tron = $2, wallet_evm = $3, wallet_btc = $4, wallet_ltc = $5, wallet_doge = $6, updated_at = now() WHERE id = $1',
    [userId, tron, evm, utxo.btc, utxo.ltc, utxo.doge]);
  return { share: !!(tron || evm), tron, evm, ...utxo };
}

/** Someone's shared addresses — only for people they can chat with (never if either blocked the other). */
async function getFor(userId, otherIdRaw) {
  await settings.requireFeature('feature_wallet', 'Wallet');
  const otherId = v.id(otherIdRaw, 'user_id');
  const u = await db.one(`SELECT id, wallet_tron, wallet_evm, wallet_btc, wallet_ltc, wallet_doge FROM users WHERE id = $1 AND status = 'active'`, [otherId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  if (await require('./user.service').isBlockedEither(userId, otherId)) throw forbidden('blocked', 'Not available'); // eslint-disable-line global-require
  return { tron: u.wallet_tron || null, evm: u.wallet_evm || null, btc: u.wallet_btc || null, ltc: u.wallet_ltc || null, doge: u.wallet_doge || null };
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
  const okAddr = (a) => validFor(network, a);
  const to = String(c.to || '');
  if (!okAddr(to)) throw badRequest('invalid_address', 'Invalid address');
  const contract = c.contract && !UTXO[network] ? String(c.contract) : null;
  if (contract && !okAddr(contract)) throw badRequest('invalid_address', 'Invalid token address');
  let tx = null;
  if (kind === 'sent') {
    tx = String(c.tx || '');
    if (!(network === 'tron' || UTXO[network] ? /^[0-9a-f]{64}$/i.test(tx) : /^0x[0-9a-f]{64}$/i.test(tx))) throw badRequest('invalid_tx', 'Invalid transaction id');
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

module.exports = { setMine, getFor, cardMeta, previewText, isTron, isEvm, isUtxoAddress, NETWORKS };
