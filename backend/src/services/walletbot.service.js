'use strict';

/**
 * @HushaviaWalletBot — money news in one chat: coins that arrive (deposits, gifts, tips, prizes,
 * subscriptions), Hushavia Plus payments, your balance and deposit address, and coin prices.
 * The wallet itself stays on the phone: this bot never sees a key or a recovery phrase.
 */
const db = require('../db');

const sys = () => require('./sysbots.service'); // eslint-disable-line global-require
const fmt = (n) => Number(n).toLocaleString('en-US');

const COINS = {
  btc: ['bitcoin', 'Bitcoin'], eth: ['ethereum', 'Ethereum'], bnb: ['binancecoin', 'BNB'], trx: ['tron', 'TRON'], sol: ['solana', 'Solana'],
  ltc: ['litecoin', 'Litecoin'], doge: ['dogecoin', 'Dogecoin'], usdt: ['tether', 'Tether'], usdc: ['usd-coin', 'USD Coin'], xrp: ['ripple', 'XRP'],
  ton: ['the-open-network', 'Toncoin'], matic: ['polygon-ecosystem-token', 'Polygon'], avax: ['avalanche-2', 'Avalanche'], ada: ['cardano', 'Cardano'],
};
const TOP = ['btc', 'eth', 'bnb', 'sol', 'trx', 'ltc', 'doge', 'ton'];

let cache = { at: 0, data: null };
let fetcher = async (ids) => {
  const r = await fetch(`https://api.coingecko.com/api/v3/simple/price?ids=${ids.join(',')}&vs_currencies=usd,pkr&include_24hr_change=true`, {
    headers: { accept: 'application/json' }, signal: AbortSignal.timeout(10000), redirect: 'error',
  });
  if (!r.ok) throw new Error(`prices answered ${r.status}`);
  return r.json();
};
function setFetcher(f) {
  fetcher = f;
  cache = { at: 0, data: null };
}

async function prices() {
  if (cache.data && Date.now() - cache.at < 60 * 1000) return cache.data;
  const data = await fetcher(Object.values(COINS).map((c) => c[0]));
  cache = { at: Date.now(), data };
  return data;
}

function money(n, cur) {
  if (!Number.isFinite(n)) return '—';
  const digits = n >= 100 ? 0 : n >= 1 ? 2 : 6;
  return `${cur === 'usd' ? '$' : 'Rs '}${n.toLocaleString('en-US', { maximumFractionDigits: digits, minimumFractionDigits: n >= 100 ? 0 : 2 })}`;
}

function line(sym, p) {
  const [id, name] = COINS[sym];
  const x = p[id] || {};
  const ch = Number(x.usd_24h_change);
  const arrow = !Number.isFinite(ch) ? '' : ch >= 0 ? ` 🟢 +${ch.toFixed(1)}%` : ` 🔴 ${ch.toFixed(1)}%`;
  return `**${name}** (${sym.toUpperCase()}): ${money(Number(x.usd), 'usd')} · ${money(Number(x.pkr), 'pkr')}${arrow}`;
}

const HELP = [
  '👛 Hi! I’m your Hushavia Wallet assistant.',
  '',
  'I tell you here when coins arrive — deposits, gifts, tips, giveaway prizes and subscriptions — and when Hushavia Plus is paid.',
  '',
  '/balance — your coins',
  '/deposit — your USDT address for adding coins',
  '/history — your last coin activity',
  '/price btc — the price of a coin (btc, eth, bnb, sol, trx, usdt…)',
  '/prices — the main coins at a glance',
  '',
  'I never ask for your 12 words or a code. Anyone who does is a scammer.',
].join('\n');

const KIND = {
  deposit: 'USDT deposit', purchase: 'Bought', gift_sent: 'Gift sent', gift_received: 'Gift received', plus: 'Hushavia Plus', admin: 'From Hushavia',
  tip_sent: 'Tip sent', tip_received: 'Tip received', sub_paid: 'Subscription', sub_income: 'Subscriber', giveaway: 'Giveaway started',
  giveaway_win: 'Giveaway prize', giveaway_refund: 'Giveaway refund',
};

async function onMessage(userId, chatId, row) {
  const say = (t, b) => sys().say('wallet', chatId, t, b);
  const text = String(row.text || '').trim();
  const m = /^\/?(\w+)(?:@\w+)?\s*(.*)$/s.exec(text);
  const cmd = m ? m[1].toLowerCase() : '';
  const arg = m ? m[2].trim().toLowerCase().replace(/^\$/, '') : '';
  if (!text || cmd === 'start' || cmd === 'help') return say(HELP, [[{ text: '🪙 Balance', callback_data: 'balance' }, { text: '📈 Prices', callback_data: 'prices' }]]);
  if (cmd === 'balance') return balance(userId, chatId);
  if (cmd === 'history') return history(userId, chatId);
  if (cmd === 'deposit') {
    try {
      const d = await require('./deposit.service').myAddress(userId); // eslint-disable-line global-require
      return say([
        '📥 Your own address for adding coins',
        '',
        `\`${d.address}\``,
        '',
        `Send **USDT on ${d.network_name}** only — 1 USDT = ${d.coins_per_usdt} coins, smallest ${d.min_usd} USDT.`,
        'Other coins or networks are lost. I’ll tell you here when it arrives.',
      ].join('\n'), [[{ text: '📋 Copy address', copy_text: { text: d.address } }]]);
    } catch (e) {
      return say(e.code === 'deposits_off' ? 'Adding coins with USDT is not open yet.' : 'I couldn’t get your address right now. Try again in a moment.');
    }
  }
  if (cmd === 'prices') return pricesMsg(chatId);
  if (cmd === 'price' || COINS[cmd]) {
    const sym = COINS[cmd] ? cmd : arg;
    if (!COINS[sym]) return say(`Which coin? For example /price btc\n\nI know: ${Object.keys(COINS).join(', ')}`);
    try {
      return say(`${line(sym, await prices())}\n\nPrices from CoinGecko, about a minute old.`);
    } catch (_) {
      return say('Prices are not available right now. Try again in a minute.');
    }
  }
  return say('I didn’t get that. Send /start to see what I can do.');
}

async function balance(userId, chatId) {
  const u = await db.one('SELECT coins FROM users WHERE id = $1', [userId]);
  return sys().say('wallet', chatId, `🪙 Your balance: **${fmt(u ? u.coins : 0)} coins**\n\nAdd coins: /deposit · Activity: /history`);
}

async function history(userId, chatId) {
  const rows = await db.many(
    `SELECT t.*, p.first_name FROM coin_tx t LEFT JOIN users p ON p.id = t.peer_id WHERE t.user_id = $1 ORDER BY t.id DESC LIMIT 8`,
    [userId],
  );
  if (!rows.length) return sys().say('wallet', chatId, 'No coin activity yet. Add coins with /deposit.');
  const lines = rows.map((r) => {
    const d = Number(r.delta);
    const who = r.first_name && ['gift_sent', 'gift_received', 'tip_sent', 'tip_received'].includes(r.kind) ? ` · ${r.first_name}` : '';
    return `${d > 0 ? '➕' : '➖'} ${fmt(Math.abs(d))} · ${KIND[r.kind] || r.kind}${who}\n${new Date(r.created_at).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' })}`;
  });
  return sys().say('wallet', chatId, `🧾 Last activity\n\n${lines.join('\n\n')}`);
}

async function pricesMsg(chatId) {
  try {
    const p = await prices();
    return sys().say('wallet', chatId, `📈 Prices now\n\n${TOP.map((s) => line(s, p)).join('\n')}\n\nAny coin: /price eth`);
  } catch (_) {
    return sys().say('wallet', chatId, 'Prices are not available right now. Try again in a minute.');
  }
}

async function onCallback(userId, chatId, data) {
  if (data === 'balance') return balance(userId, chatId);
  if (data === 'prices') return pricesMsg(chatId);
  return null;
}

/** Money news for one person, as a message from the bot. True when it was delivered. */
async function tell(userId, title, body) {
  try {
    const me = await sys().ensureOne('wallet');
    const u = await db.one(`SELECT id FROM users WHERE id = $1 AND status = 'active' AND NOT is_bot`, [userId]);
    if (!u || Number(userId) === me) return false;
    const chat = await require('./chat.service').getOrCreatePrivate(userId, me); // eslint-disable-line global-require
    await sys().say('wallet', chat.id, `**${title}**${body ? `\n${body}` : ''}`);
    return true;
  } catch (_) {
    return false;
  }
}

module.exports = { onMessage, onCallback, tell, prices, setFetcher, COINS };
