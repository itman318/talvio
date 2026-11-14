'use strict';

/**
 * Coins by deposit: every member gets their OWN USDT address on BNB Smart Chain, made from the
 * owner's xpub (a public key — the server can make addresses but can never move the money).
 * Whatever USDT arrives there becomes coins (1 USDT = 100 coins), after enough confirmations.
 *
 * Address number 0 is the owner's own (it holds the BNB for fees when the money is collected),
 * members get 1, 2, 3… in the order they first open "Add coins".
 */
const crypto = require('crypto');
const db = require('../db');
const settings = require('./settings.service');
const coins = require('./coin.service');
const cryptopay = require('./payments/cryptopay');
const keys = require('../utils/evmkeys');
const rateLimit = require('../utils/rateLimit');
const { forbidden, badRequest } = require('../utils/errors');

const NET = cryptopay.NETWORKS.bsc;
const UNIT = 10n ** BigInt(NET.decimals); // 1 USDT
const COINS_PER_USDT = 100n;
const CONFIRMATIONS = 15;
const WATCH_DAYS = 180;
const MAX_SPANS = 60; // per round: catching up after a pause takes a few rounds, nothing is skipped
const GIVE_UP = 2000000; // blocks (weeks): older than this the public nodes no longer answer
const SCAN_SPAN = 2000; // blocks per log query
const CHECK_BACK = 20000; // "check now": about 4 hours of blocks

const fp = (xpub) => crypto.createHash('sha256').update(String(xpub)).digest('hex').slice(0, 16);

async function config() {
  const s = await settings.getAll();
  const xpub = String(s.coins_deposit_xpub || '').trim();
  const parsed = xpub ? keys.parseXpub(xpub) : null;
  return { on: !!(s.feature_coins && parsed), xpub, parsed, fp: parsed ? fp(xpub) : null, minUsd: s.coins_deposit_min_usd };
}

/** The member's address (made once per xpub) and a fresh "watch it" window. */
async function myAddress(userId) {
  const c = await config();
  if (!c.on) throw forbidden('deposits_off', 'Adding coins with USDT is not open yet');
  rateLimit.enforce(`dep:addr:${userId}`, 60, 60 * 60 * 1000, 'Too many requests. Try again later.');
  let row = await db.one('SELECT * FROM coin_deposit_addresses WHERE user_id = $1 AND xpub_fp = $2', [userId, c.fp]);
  if (!row) {
    const idx = await db.one(`SELECT COALESCE(max(idx), 0) + 1 AS n FROM coin_deposit_addresses WHERE xpub_fp = $1`, [c.fp]);
    for (let n = idx.n; !row; n += 1) {
      row = await db.one(
        `INSERT INTO coin_deposit_addresses (user_id, xpub_fp, idx, address) VALUES ($1, $2, $3, $4)
         ON CONFLICT DO NOTHING RETURNING *`,
        [userId, c.fp, n, keys.addressAt(c.parsed, n).toLowerCase()],
      );
      if (!row) row = await db.one('SELECT * FROM coin_deposit_addresses WHERE user_id = $1 AND xpub_fp = $2', [userId, c.fp]); // a second request raced us
    }
  }
  await db.query(`UPDATE coin_deposit_addresses SET watch_until = now() + make_interval(days => $2) WHERE user_id = $1 AND xpub_fp = $3`, [userId, WATCH_DAYS, c.fp]);
  return {
    address: keys.checksum(row.address.slice(2)),
    network: NET.id,
    network_name: NET.name,
    symbol: NET.symbol,
    contract: NET.contract,
    decimals: NET.decimals,
    coins_per_usdt: Number(COINS_PER_USDT),
    min_usd: c.minUsd,
    deposits: await recent(userId),
  };
}

async function recent(userId) {
  const rows = await db.many('SELECT * FROM coin_deposits WHERE user_id = $1 ORDER BY id DESC LIMIT 10', [userId]);
  return rows.map((r) => ({
    tx: r.tx_hash,
    tx_url: `${NET.explorer}${r.tx_hash}`,
    usdt: Number(BigInt(r.amount) * 10000n / UNIT) / 10000,
    coins: r.coins,
    status: r.status,
    created_at: new Date(r.created_at).toISOString(),
  }));
}

const pad = (a) => `0x${a.replace(/^0x/, '').toLowerCase().padStart(64, '0')}`;

/** Every USDT Transfer to these addresses between two blocks. */
async function logsTo(addresses, from, to) {
  const out = [];
  for (let i = 0; i < addresses.length; i += 200) {
    const chunk = addresses.slice(i, i + 200).map(pad);
    const logs = await cryptopay.rpc(NET, 'eth_getLogs', [{
      address: NET.contract, fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}`, topics: [`0x${cryptopay.TRANSFER}`, null, chunk],
    }]);
    out.push(...(logs || []));
  }
  return out;
}

/** Books one Transfer log exactly once. */
async function book(log, byAddress, minUsd) {
  const to = `0x${String(log.topics[2]).slice(-40)}`.toLowerCase();
  const who = byAddress.get(to);
  if (!who || log.removed) return null;
  const amount = BigInt(log.data && log.data !== '0x' ? log.data : 0);
  const cents = (amount * COINS_PER_USDT) / UNIT;
  const enough = amount * 100n >= BigInt(Math.round(minUsd * 100)) * UNIT;
  const status = enough && cents > 0n ? 'credited' : 'too_small';
  return db.tx(async (c) => {
    const r = (await c.query(
      `INSERT INTO coin_deposits (user_id, address, tx_hash, log_index, block, amount, coins, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (tx_hash, log_index) DO NOTHING RETURNING id`,
      [who, to, String(log.transactionHash).toLowerCase(), Number(BigInt(log.logIndex)), Number(BigInt(log.blockNumber)), amount.toString(), status === 'credited' ? Number(cents) : 0, status],
    )).rows[0];
    if (!r) return null; // seen before
    if (status !== 'credited') return { userId: who, status, amount };
    const balance = await coins.change(c, who, Number(cents), 'deposit', { note: 'USDT deposit' });
    return { userId: who, status, amount, coins: Number(cents), balance };
  });
}

async function announce(results) {
  for (const r of results.filter(Boolean)) {
    const usdt = (Number(r.amount * 100n / UNIT) / 100).toFixed(2);
    if (r.status === 'credited') {
      coins.announce(r.userId, r.balance);
      await require('./notice.service').notify(r.userId, 'payment', `${r.coins.toLocaleString('en-US')} coins added 🪙`, `${usdt} USDT received. Thank you!`); // eslint-disable-line global-require
    } else {
      await require('./notice.service').notify(r.userId, 'payment', 'Deposit too small', `${usdt} USDT arrived, but the smallest deposit is the minimum shown in the app, so no coins were added. Contact support if you need help.`); // eslint-disable-line global-require
    }
  }
}

let scanning = false;

/** Scheduler: new confirmed blocks, for the addresses people are using. */
async function scan() {
  const c = await config();
  if (!c.on || scanning) return;
  scanning = true;
  try {
    const head = Number(BigInt(await cryptopay.rpc(NET, 'eth_blockNumber', [])));
    const safe = head - CONFIRMATIONS;
    const st = await db.one('SELECT last_block FROM coin_deposit_state WHERE id = 1');
    let last = st ? Number(st.last_block) : safe - 200;
    // after a pause (a restart, the network away) every block is still read — a deposit made meanwhile must not be missed
    if (safe - last > GIVE_UP) last = safe - GIVE_UP;
    // addresses made from an earlier receiving key are still watched: people keep an address they once copied
    const watched = await db.many(`SELECT user_id, address FROM coin_deposit_addresses WHERE watch_until > now() ORDER BY watch_until DESC LIMIT 5000`);
    const byAddress = new Map(watched.map((w) => [w.address, w.user_id]));
    const results = [];
    let at = last;
    let spans = 0;
    while (at < safe && spans < MAX_SPANS) {
      spans += 1;
      const to = Math.min(safe, at + SCAN_SPAN);
      if (byAddress.size) {
        for (const log of await logsTo([...byAddress.keys()], at + 1, to)) results.push(await book(log, byAddress, c.minUsd));
      }
      at = to;
      await db.query(`INSERT INTO coin_deposit_state (id, last_block) VALUES (1, $1) ON CONFLICT (id) DO UPDATE SET last_block = EXCLUDED.last_block`, [at]);
      if (results.length > 200) break;
    }
    await announce(results);
    return results.filter(Boolean).length;
  } finally {
    scanning = false;
  }
}

/** "I've sent it": looks back a few hours for this one member, right now. */
async function checkMine(userId) {
  const c = await config();
  if (!c.on) throw forbidden('deposits_off', 'Adding coins with USDT is not open yet');
  rateLimit.enforce(`dep:check:${userId}`, 6, 10 * 60 * 1000, 'Please wait a minute and check again.');
  const row = await db.one('SELECT address FROM coin_deposit_addresses WHERE user_id = $1 AND xpub_fp = $2', [userId, c.fp]);
  if (!row) throw badRequest('invalid_input', 'Open “Add coins” first to get your address');
  await db.query(`UPDATE coin_deposit_addresses SET watch_until = now() + make_interval(days => $2) WHERE user_id = $1`, [userId, WATCH_DAYS]);
  // every address this member ever had (also from an earlier receiving key)
  const mine = (await db.many('SELECT address FROM coin_deposit_addresses WHERE user_id = $1', [userId])).map((r) => r.address);
  const head = Number(BigInt(await cryptopay.rpc(NET, 'eth_blockNumber', [])));
  const safe = head - CONFIRMATIONS;
  const byAddress = new Map(mine.map((a) => [a, userId]));
  const results = [];
  for (let from = Math.max(0, safe - CHECK_BACK); from <= safe; from += SCAN_SPAN + 1) {
    for (const log of await logsTo(mine, from, Math.min(safe, from + SCAN_SPAN))) results.push(await book(log, byAddress, c.minUsd));
  }
  await announce(results);
  const fresh = results.filter((r) => r && r.status === 'credited');
  const pending = await pendingFor(row.address, safe, head);
  return {
    added: fresh.reduce((n, r) => n + r.coins, 0),
    balance: Number((await db.one('SELECT coins FROM users WHERE id = $1', [userId])).coins),
    confirming: pending,
    deposits: await recent(userId),
  };
}

/** USDT on its way: in a block, but not deep enough yet. */
async function pendingFor(address, safe, head) {
  try {
    const logs = await logsTo([address], safe + 1, head);
    return logs.length;
  } catch (_) {
    return 0;
  }
}

/**
 * For the owner's phone: which address numbers have received money (so the app knows what to
 * collect). The xpub itself is the key to this list — whoever has it can see these addresses anyway.
 */
async function sweepList(xpubRaw) {
  const c = await config();
  if (!c.on || String(xpubRaw || '').trim() !== c.xpub) throw forbidden('forbidden', 'This receiving key is not the one set in Hushavia');
  const rows = await db.many(
    `SELECT a.idx, a.address, sum(d.amount)::text AS received FROM coin_deposits d JOIN coin_deposit_addresses a ON a.address = d.address AND a.xpub_fp = $1
     GROUP BY a.idx, a.address ORDER BY a.idx LIMIT 5000`,
    [c.fp],
  );
  return { network: NET.id, contract: NET.contract, addresses: rows.map((r) => ({ index: r.idx, address: keys.checksum(r.address.slice(2)) })) };
}

/** Info for the coins page. */
async function publicInfo() {
  const c = await config();
  return c.on ? { network: NET.id, network_name: NET.name, symbol: NET.symbol, coins_per_usdt: Number(COINS_PER_USDT), min_usd: c.minUsd } : null;
}

function validXpub(x) {
  return !!keys.parseXpub(x);
}

module.exports = { myAddress, scan, checkMine, sweepList, publicInfo, validXpub, COINS_PER_USDT };
