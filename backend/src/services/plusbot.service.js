'use strict';

/**
 * @HushaviaPlusBot — Hushavia Plus in one chat: am I on Plus and until when, what it gives,
 * and buy or extend it with coins (two taps: choose, confirm). Card / USDT stay in the app.
 */
const db = require('../db');

const sys = () => require('./sysbots.service'); // eslint-disable-line global-require
const coins = () => require('./coin.service'); // eslint-disable-line global-require
const payments = () => require('./payment.service'); // eslint-disable-line global-require
const settings = () => require('./settings.service'); // eslint-disable-line global-require
const fmt = (n) => Number(n).toLocaleString('en-US');
const btn = (text, data) => ({ text, callback_data: data });
const day = (d) => new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Asia/Karachi' });

async function status(userId) {
  const u = await db.one('SELECT premium_until, coins FROM users WHERE id = $1', [userId]);
  const active = u && u.premium_until && new Date(u.premium_until) > new Date();
  return { active, until: active ? u.premium_until : null, coins: Number((u && u.coins) || 0) };
}

async function plans() {
  const s = await settings().getAll();
  if (!s.feature_premium || !s.plus_sales_open) return [];
  const rows = await db.many('SELECT * FROM premium_plans WHERE is_active ORDER BY sort, months');
  return rows.map((p) => ({ id: Number(p.id), name: p.name, months: p.months, coins: coins().plusPrice(p) })).filter((p) => p.coins);
}

async function home(userId, chatId) {
  const st = await status(userId);
  const list = await plans();
  const lines = [
    st.active ? `⭐ You have Hushavia Plus until ${day(st.until)}.` : '⭐ Hushavia Plus',
    '',
    st.active ? 'Extend it any time — the new months are added after the current ones.' : 'Bigger uploads, more folders and pins, no ads, exclusive themes and stickers, animated photo, Business tools and more.',
    '',
    `🪙 Your coins: ${fmt(st.coins)}`,
  ];
  if (!list.length) {
    lines.push('', 'Plus can’t be bought right now — it’s coming soon.');
    return sys().say('plus', chatId, lines.join('\n'), [[btn('✨ What Plus gives', 'perks')]]);
  }
  lines.push('', st.active ? 'Choose how long to extend:' : 'Choose a plan:');
  const rows = list.map((p) => [btn(`${p.name} · ${fmt(p.coins)} 🪙`, `pick:${p.id}`)]);
  rows.push([btn('✨ What Plus gives', 'perks')]);
  return sys().say('plus', chatId, lines.join('\n'), rows);
}

async function perks(chatId) {
  const list = await payments().perks();
  const text = ['✨ Hushavia Plus gives you:', '', ...list.map((p) => `• ${p.title} — ${p.text}`), '', 'You can also pay by card or USDT in the app: Settings → Hushavia Plus.'].join('\n');
  return sys().say('plus', chatId, text, [[btn('⬅️ Plans', 'home')]]);
}

async function pick(userId, chatId, planId) {
  const p = (await plans()).find((x) => x.id === planId);
  if (!p) return sys().say('plus', chatId, 'This plan isn’t available any more.', [[btn('⬅️ Plans', 'home')]]);
  const st = await status(userId);
  if (st.coins < p.coins) {
    return sys().say('plus', chatId,
      `${p.name} costs ${fmt(p.coins)} coins — you have ${fmt(st.coins)}.\n\nAdd coins in the app (Settings → Coins & wallet → Coins), or pay by card / USDT in Settings → Hushavia Plus.`,
      [[btn('⬅️ Plans', 'home')]]);
  }
  return sys().say('plus', chatId, `Pay ${fmt(p.coins)} coins for ${p.name} of Hushavia Plus?`, [[btn(`✅ Pay ${fmt(p.coins)} 🪙`, `buy:${p.id}`)], [btn('Cancel', 'home')]]);
}

async function buy(userId, chatId, planId) {
  try {
    const r = await coins().buyPlus(userId, { plan_id: planId });
    return sys().say('plus', chatId, `🎉 Done! Hushavia Plus is active until ${day(r.premium_until)}.\n🪙 Coins left: ${fmt(r.balance)}`);
  } catch (err) {
    return sys().say('plus', chatId, `⚠️ ${err.message || 'Could not pay. Try again.'}`, [[btn('⬅️ Plans', 'home')]]);
  }
}

async function onMessage(userId, chatId, row) {
  const t = String((row && row.text) || '').trim().toLowerCase();
  if (t.startsWith('/perks')) return perks(chatId);
  return home(userId, chatId);
}

async function onCallback(userId, chatId, data) {
  const d = String(data || '');
  if (d === 'home') return home(userId, chatId);
  if (d === 'perks') return perks(chatId);
  if (d.startsWith('pick:')) return pick(userId, chatId, parseInt(d.slice(5), 10));
  if (d.startsWith('buy:')) return buy(userId, chatId, parseInt(d.slice(4), 10));
  return null;
}

module.exports = { onMessage, onCallback };
