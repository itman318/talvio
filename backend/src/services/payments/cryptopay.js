'use strict';

/**
 * Paying for Hushavia Plus with USDT from the person's own (non-custodial) wallet.
 *
 * The app sends the money itself — the server never sees a key or a recovery phrase. Here we only
 * READ the public network to check that a transaction really paid the order:
 *   the real USDT contract, to OUR address, exactly the order's amount, successful, final,
 *   and made after the order was created.
 */
const crypto = require('crypto');

const TRANSFER = 'ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'; // Transfer(address,address,uint256)
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/** TRON Base58 address → 20-byte hex (without the 0x41 prefix); null when it is not a TRON address. */
function tronHex(a) {
  if (typeof a !== 'string' || !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(a)) return null;
  let n = 0n;
  for (const ch of a) n = n * 58n + BigInt(B58.indexOf(ch));
  const b = Buffer.from(n.toString(16).padStart(50, '0'), 'hex');
  if (b.length !== 25 || b[0] !== 0x41) return null;
  const sum = crypto.createHash('sha256').update(crypto.createHash('sha256').update(b.subarray(0, 21)).digest()).digest().subarray(0, 4);
  return sum.equals(b.subarray(21)) ? b.subarray(1, 21).toString('hex') : null;
}

const isEvm = (a) => typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a);

const NETWORKS = {
  bsc: {
    id: 'bsc',
    name: 'BNB Smart Chain (BEP-20)',
    fee_hint: 'Lowest fee — a few cents, paid in BNB',
    symbol: 'USDT',
    contract: '0x55d398326f99059fF775485246999027B3197955',
    decimals: 18,
    setting: 'crypto_pay_bsc_address',
    valid: isEvm,
    txOk: (t) => /^0x[0-9a-f]{64}$/.test(t),
    explorer: 'https://bscscan.com/tx/',
    confirmations: 15,
    rpcs: ['https://bsc-dataseed.binance.org', 'https://bsc-rpc.publicnode.com', 'https://bsc-dataseed1.defibit.io'],
  },
  tron: {
    id: 'tron',
    name: 'TRON (TRC-20)',
    fee_hint: 'Fee is paid in TRX (usually 14–28 TRX)',
    symbol: 'USDT',
    contract: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
    decimals: 6,
    setting: 'crypto_pay_tron_address',
    valid: (a) => tronHex(a) !== null,
    txOk: (t) => /^[0-9a-f]{64}$/.test(t),
    explorer: 'https://tronscan.org/#/transaction/',
    api: 'https://api.trongrid.io',
  },
};

/** "0xABC…" / "abc…" → canonical lowercase id for that network; null when malformed. */
function normalizeTx(network, raw) {
  const n = NETWORKS[network];
  let t = String(raw || '').trim().toLowerCase();
  if (!n) return null;
  if (network === 'tron' && t.startsWith('0x')) t = t.slice(2);
  if (network === 'bsc' && /^[0-9a-f]{64}$/.test(t)) t = `0x${t}`;
  return n.txOk(t) ? t : null;
}

// ------------------------------------------------------------------ transport (replaced in tests)
async function httpJson(url, body, headers = {}) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json', ...headers },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(12000),
    redirect: 'error',
  });
  if (!r.ok) throw new Error(`network answered ${r.status}`);
  return r.json();
}
let transport = httpJson;
function setTransport(fn) {
  transport = fn || httpJson;
}

const word = (hex) => String(hex || '').replace(/^0x/, '').toLowerCase();
const addrOfTopic = (t) => word(t).slice(-40);

/**
 * Looks through the Transfer events of a finished transaction.
 * logs: [{ address (20-byte hex, no prefix), topics: [hex…], data: hex }]
 */
function judge(logs, { contractHex, toHex, amount }) {
  let other = null;
  for (const l of logs) {
    const topics = (l.topics || []).map(word);
    if (word(l.address).slice(-40) !== contractHex || topics[0] !== TRANSFER || topics.length < 3) continue;
    if (addrOfTopic(topics[2]) !== toHex) continue;
    const data = word(l.data);
    if (!/^[0-9a-f]{1,64}$/.test(data)) continue;
    const got = BigInt(`0x${data}`);
    if (got === amount) return { state: 'paid', from: addrOfTopic(topics[1]) };
    other = got;
  }
  if (other !== null) return { state: 'mismatch', reason: `Paid a different amount (${other} units instead of ${amount})` };
  return { state: 'mismatch', reason: 'This transaction did not send USDT to our address' };
}

const EARLY = 2 * 60 * 1000; // clocks differ a little
/** A payment counts for an order only when it was made inside the order's own day (see payment.service: amounts are not reused within a day). */
function timeProblem(ms, after, until) {
  if (after && ms < after - EARLY) return 'This transaction is older than the order';
  if (until && ms > until) return 'This transaction was made long after the order';
  return null;
}

async function checkTron(n, { tx, to, amount, after, until }) {
  const headers = process.env.TRONGRID_API_KEY ? { 'TRON-PRO-API-KEY': process.env.TRONGRID_API_KEY } : {};
  // "walletsolidity" answers only for transactions that are final (can no longer be undone)
  const info = await transport(`${n.api}/walletsolidity/gettransactioninfobyid`, { value: tx }, headers);
  if (!info || !info.id || !info.blockNumber) return { state: 'pending' };
  if (String(info.id).toLowerCase() !== tx) return { state: 'pending' };
  if (info.result === 'FAILED' || (info.receipt && info.receipt.result && info.receipt.result !== 'SUCCESS')) {
    return { state: 'failed', reason: 'The transaction failed on the network — nothing was paid' };
  }
  if (!info.receipt || info.receipt.result !== 'SUCCESS') return { state: 'mismatch', reason: 'Not a token transfer' };
  const late = timeProblem(Number(info.blockTimeStamp || 0), after, until);
  if (late) return { state: 'mismatch', reason: late };
  return judge(info.log || [], { contractHex: tronHex(n.contract), toHex: tronHex(to), amount });
}

async function rpc(n, method, params) {
  let last;
  for (const url of n.rpcs) {
    try {
      const j = await transport(url, { jsonrpc: '2.0', id: 1, method, params });
      if (j && j.error) throw new Error(String(j.error.message || 'rpc error'));
      return j ? j.result : null;
    } catch (e) {
      last = e;
    }
  }
  throw last || new Error('network unreachable');
}

async function checkEvm(n, { tx, to, amount, after, until }) {
  const rc = await rpc(n, 'eth_getTransactionReceipt', [tx]);
  if (!rc || !rc.blockNumber) return { state: 'pending' };
  if (String(rc.transactionHash || '').toLowerCase() !== tx) return { state: 'pending' };
  const head = BigInt(await rpc(n, 'eth_blockNumber', []));
  if (head - BigInt(rc.blockNumber) < BigInt(n.confirmations)) return { state: 'pending' };
  if (rc.status !== '0x1') return { state: 'failed', reason: 'The transaction failed on the network — nothing was paid' };
  if (after) {
    const block = await rpc(n, 'eth_getBlockByNumber', [rc.blockNumber, false]);
    // a block that vanished (re-organised away) is simply not final yet
    if (!block || !block.timestamp) return { state: 'pending' };
    const late = timeProblem(Number(BigInt(block.timestamp)) * 1000, after, until);
    if (late) return { state: 'mismatch', reason: late };
  }
  return judge(rc.logs || [], { contractHex: n.contract.slice(2).toLowerCase(), toHex: to.slice(2).toLowerCase(), amount });
}

/**
 * @param {{network:string, tx:string, to:string, amount:bigint, after?:number, until?:number}} p  after = order creation time (ms), until = the latest time a payment for it may carry
 * @returns {Promise<{state:'paid'|'pending'|'failed'|'mismatch', reason?:string, from?:string}>}
 *   pending  — not on the network yet / not final yet: ask again later
 *   failed   — reverted: certainly nothing was paid
 *   mismatch — a real transaction that does not pay this order as asked: a person must look
 * Throws when the network can't be reached (ask again later).
 */
async function check(p) {
  const n = NETWORKS[p.network];
  if (!n || !n.valid(p.to) || !n.txOk(p.tx)) return { state: 'mismatch', reason: 'Invalid payment details' };
  return n.id === 'tron' ? checkTron(n, p) : checkEvm(n, p);
}

module.exports = { NETWORKS, TRANSFER, tronHex, normalizeTx, check, setTransport, judge, rpc };
