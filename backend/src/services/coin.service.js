'use strict';

/**
 * Hushavia Coins — the app's own money (like game coins): bought with USDT from the in-app wallet,
 * spent on Hushavia Plus or sent to other members as a gift.
 *
 * NOT a crypto token: a balance on our server. Coins can't be withdrawn or turned back into money.
 * Every change is one row in coin_tx, written in the same database transaction as the balance,
 * and a balance can never go below zero.
 *
 * 1 coin = 1 US cent of Hushavia Plus (a $3.99 plan costs 399 coins).
 */
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const KINDS = ['deposit', 'purchase', 'gift_sent', 'gift_received', 'plus', 'admin', 'tip_sent', 'tip_received', 'sub_paid', 'sub_income', 'giveaway', 'giveaway_win', 'giveaway_refund', 'ad_budget', 'ad_refund', 'ad_income', 'shop_paid', 'shop_income', 'shop_refund', 'boost'];
const MAX_SEND = 100000;

const iso = (d) => (d ? new Date(d).toISOString() : null);

/**
 * Changes a balance inside an open transaction. Throws not_enough_coins when it would go below zero.
 * @param c a pg client inside db.tx
 */
async function change(c, userId, delta, kind, { peerId = null, orderId = null, note = null } = {}) {
  if (!Number.isInteger(delta) || delta === 0) throw badRequest('invalid_input', 'Invalid amount');
  const u = (await c.query('UPDATE users SET coins = coins + $2 WHERE id = $1 AND coins + $2 >= 0 RETURNING coins', [userId, delta])).rows[0];
  if (!u) throw forbidden('not_enough_coins', 'You don’t have enough coins');
  await c.query('INSERT INTO coin_tx (user_id, delta, balance, kind, peer_id, order_id, note) VALUES ($1, $2, $3, $4, $5, $6, $7)', [
    userId, delta, u.coins, kind, peerId, orderId, note,
  ]);
  return Number(u.coins);
}

function announce(userId, balance) {
  bus.emit('rt:emit', { event: 'coins:updated', payload: { balance }, userIds: [userId] });
}

const serializePack = (p) => ({
  id: p.id,
  coins: p.coins,
  bonus: p.bonus,
  total: p.coins + p.bonus,
  price_usd: Number(p.price_usd),
  price_text: `$${Number(p.price_usd).toFixed(2)}`,
  badge: p.badge || null,
  is_active: p.is_active,
  sort: p.sort,
});

const plusPrice = (plan) => {
  const usd = Number((plan.prices || {}).USD);
  return Number.isFinite(usd) && usd > 0 ? Math.round(usd * 100) : null;
};

function serializeTx(r) {
  return {
    id: r.id,
    delta: Number(r.delta),
    balance: Number(r.balance),
    kind: r.kind,
    note: r.note,
    peer: r.peer_id ? { id: r.peer_id, name: `${r.first_name || ''} ${r.last_name || ''}`.trim() || 'Deleted account', username: r.username || null } : null,
    created_at: iso(r.created_at),
  };
}

async function history(userId, query = {}) {
  const before = query.before ? v.id(query.before, 'before') : null;
  const rows = await db.many(
    `SELECT t.*, p.first_name, p.last_name, p.username FROM coin_tx t LEFT JOIN users p ON p.id = t.peer_id
     WHERE t.user_id = $1 AND ($2::bigint IS NULL OR t.id < $2) ORDER BY t.id DESC LIMIT 40`,
    [userId, before],
  );
  return rows.map(serializeTx);
}

async function info(userId) {
  await settings.requireFeature('feature_coins', 'Coins');
  const payments = require('./payment.service'); // eslint-disable-line global-require
  const s = await settings.getAll();
  const u = await db.one('SELECT coins FROM users WHERE id = $1', [userId]);
  const packs = await db.many('SELECT * FROM coin_packs WHERE is_active ORDER BY sort, coins');
  const plans = s.feature_premium && s.plus_sales_open ? await db.many('SELECT * FROM premium_plans WHERE is_active ORDER BY sort, months') : [];
  const networks = payments.cryptoNetworksPublic(s);
  const deposit = await require('./deposit.service').publicInfo(); // eslint-disable-line global-require
  return {
    balance: Number(u ? u.coins : 0),
    deposit,
    // packs paid by card (Stripe), when switched on
    card: (await payments.cardOpen()) ? { packs: packs.map(serializePack) } : null,
    // with deposits on, any amount works: the fixed packs (one order each) are not needed
    packs: networks.length && !deposit ? packs.map(serializePack) : [],
    crypto_networks: networks,
    buy_note: networks.length || deposit ? null : 'Buying coins is not open yet.',
    plus: plans.map((p) => ({ plan_id: p.id, name: p.name, months: p.months, coins: plusPrice(p), badge: p.badge || null })).filter((p) => p.coins),
    history: await history(userId),
    rules: 'Coins are for use inside Hushavia. They can’t be withdrawn or exchanged back for money.',
  };
}

/** A gift to another member. */
async function send(userId, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const toId = v.id(body.user_id, 'user_id');
  const amount = Number(body.amount);
  if (!Number.isInteger(amount) || amount < 1 || amount > MAX_SEND) throw badRequest('invalid_input', `Send between 1 and ${MAX_SEND.toLocaleString('en-US')} coins`);
  if (toId === userId) throw badRequest('invalid_input', 'You can’t send coins to yourself');
  const note = v.str(body.note, { field: 'note', max: 120 }) || null;
  const to = await db.one(`SELECT id, first_name, is_bot FROM users WHERE id = $1 AND status = 'active'`, [toId]);
  if (!to || to.is_bot) throw notFound('user_not_found', 'This person can’t receive coins');
  if (await require('./user.service').isBlockedEither(userId, toId)) throw forbidden('blocked', 'You can’t send coins to this person'); // eslint-disable-line global-require
  await require('./tags.service').assertNotBlocked(userId, 'send coins'); // eslint-disable-line global-require
  rateLimit.enforce(`coins:send:${userId}`, 30, 60 * 60 * 1000, 'Too many gifts. Try again later.');
  const me = await db.one('SELECT first_name FROM users WHERE id = $1', [userId]);
  const r = await db.tx(async (c) => {
    // both rows are locked in the same order every time, so two people gifting each other can't deadlock
    await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [userId, toId]);
    // the same amount to the same person a moment ago: a repeated tap (or a retry after a lost answer), not a second gift
    const twice = (await c.query(
      `SELECT 1 FROM coin_tx WHERE user_id = $1 AND peer_id = $2 AND kind = 'gift_sent' AND delta = $3 AND created_at > now() - interval '10 seconds' LIMIT 1`,
      [userId, toId, -amount],
    )).rows[0];
    if (twice) throw conflict('just_sent', 'You sent this a moment ago — check your coin history before sending again');
    return {
    mine: await change(c, userId, -amount, 'gift_sent', { peerId: toId, note }),
    theirs: await change(c, toId, amount, 'gift_received', { peerId: userId, note }),
    };
  });
  announce(userId, r.mine);
  announce(toId, r.theirs);
  await require('./notice.service').notify(toId, 'payment', `${me.first_name || 'Someone'} sent you ${amount.toLocaleString('en-US')} coins 🪙`, note || 'Open Coins to see your balance.', { from: userId, amount }); // eslint-disable-line global-require
  return { balance: r.mine, sent: amount, to: { id: to.id, name: to.first_name } };
}

/** Hushavia Plus paid with coins. */
async function buyPlus(userId, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  await settings.requireFeature('feature_premium', 'Hushavia Plus');
  if (!(await settings.get('plus_sales_open'))) throw forbidden('coming_soon', 'Hushavia Plus is coming soon');
  const plan = await db.one('SELECT * FROM premium_plans WHERE id = $1 AND is_active', [v.id(body.plan_id, 'plan_id')]);
  const price = plan && plusPrice(plan);
  if (!price) throw notFound('plan_not_found', 'This plan is not available');
  rateLimit.enforce(`coins:plus:${userId}`, 10, 60 * 60 * 1000, 'Too many attempts. Try again later.');
  const r = await db.tx(async (c) => {
    // one purchase at a time, and a second tap right after the first is not a second purchase
    await c.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
    const twice = (await c.query(`SELECT 1 FROM payment_orders WHERE user_id = $1 AND provider = 'coins' AND created_at > now() - interval '15 seconds' LIMIT 1`, [userId])).rows[0];
    if (twice) throw conflict('just_bought', 'You bought Hushavia Plus a moment ago — check “My payments” before buying again');
    const o = (await c.query(
      `INSERT INTO payment_orders (user_id, plan_id, months, amount_pkr, provider, status, txn_ref, currency, amount, paid_at, provider_message)
       VALUES ($1, $2, $3, 0, 'coins', 'paid', $4, 'USD', 0, now(), $5) RETURNING id`,
      [userId, plan.id, plan.months, `HC${Date.now().toString(36).toUpperCase()}${require('crypto').randomBytes(3).toString('hex').toUpperCase()}`.slice(0, 20), `Paid with ${price} coins`], // eslint-disable-line global-require
    )).rows[0];
    const balance = await change(c, userId, -price, 'plus', { orderId: o.id, note: plan.name });
    const u = (await c.query(
      `UPDATE users SET premium_until = GREATEST(COALESCE(premium_until, now()), now()) + make_interval(months => $2), updated_at = now() WHERE id = $1 RETURNING premium_until`,
      [userId, plan.months],
    )).rows[0];
    return { balance, premium_until: u.premium_until, orderId: o.id };
  });
  announce(userId, r.balance);
  bus.emit('user:updated', { userId });
  await require('./notice.service').notify(userId, 'payment', 'Hushavia Plus is active ⭐', `${plan.name} paid with ${price.toLocaleString('en-US')} coins. Thank you!`, { order_id: r.orderId }); // eslint-disable-line global-require
  return { balance: r.balance, premium_until: iso(r.premium_until), spent: price };
}

// ------------------------------------------------------------------ admin
async function adminAdjust(adminId, userIdRaw, body = {}) {
  const userId = v.id(userIdRaw, 'user_id');
  const amount = Number(body.amount);
  if (!Number.isInteger(amount) || amount === 0 || Math.abs(amount) > 10000000) throw badRequest('invalid_input', 'Enter a whole number of coins (negative to take away)');
  const note = v.str(body.note, { field: 'note', max: 120 }) || (amount > 0 ? 'Given by Hushavia' : 'Removed by Hushavia');
  const u = await db.one('SELECT id FROM users WHERE id = $1', [userId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  const balance = await db.tx((c) => change(c, userId, amount, 'admin', { note }));
  announce(userId, balance);
  if (amount > 0) await require('./notice.service').notify(userId, 'payment', `You received ${amount.toLocaleString('en-US')} coins 🪙`, note, { amount }); // eslint-disable-line global-require
  return { balance };
}

async function adminPacks() {
  const stats = await db.one(
    `SELECT (SELECT COALESCE(sum(coins), 0) FROM users) AS in_wallets,
            (SELECT COALESCE(sum(delta), 0) FROM coin_tx WHERE kind IN ('purchase', 'deposit')) AS bought,
            (SELECT COALESCE(-sum(delta), 0) FROM coin_tx WHERE kind = 'plus') AS spent_on_plus,
            (SELECT COALESCE(sum(delta), 0) FROM coin_tx WHERE kind = 'admin') AS given_by_admins`,
  );
  return {
    packs: (await db.many('SELECT * FROM coin_packs ORDER BY sort, coins')).map(serializePack),
    stats: { in_wallets: Number(stats.in_wallets), bought: Number(stats.bought), spent_on_plus: Number(stats.spent_on_plus), given_by_admins: Number(stats.given_by_admins) },
  };
}

async function adminSavePack(idRaw, body = {}) {
  const coins = Number(body.coins);
  const bonus = Number(body.bonus || 0);
  const price = Math.round(Number(body.price_usd) * 100) / 100;
  if (!Number.isInteger(coins) || coins < 1 || coins > 10000000) throw badRequest('invalid_input', 'coins must be 1 – 10,000,000');
  if (!Number.isInteger(bonus) || bonus < 0 || bonus > 10000000) throw badRequest('invalid_input', 'Invalid bonus');
  if (!Number.isFinite(price) || price < 0.5 || price > 10000) throw badRequest('invalid_input', 'The price must be $0.50 – $10,000');
  const active = body.is_active === undefined ? true : v.bool(body.is_active, 'is_active');
  const badge = v.str(body.badge, { field: 'badge', max: 20 }) || null;
  const r = idRaw
    ? await db.one('UPDATE coin_packs SET coins = $2, bonus = $3, price_usd = $4, is_active = $5, badge = $6, sort = $7 WHERE id = $1 RETURNING *', [v.id(idRaw, 'pack_id'), coins, bonus, price, active, badge, coins])
    : await db.one('INSERT INTO coin_packs (coins, bonus, price_usd, is_active, badge, sort) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *', [coins, bonus, price, active, badge, coins]);
  if (!r) throw notFound('pack_not_found', 'Pack not found');
  return serializePack(r);
}

module.exports = { KINDS, change, info, history, send, buyPlus, plusPrice, serializePack, adminAdjust, adminPacks, adminSavePack, announce };
