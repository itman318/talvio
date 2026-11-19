'use strict';

/**
 * Promote a channel: its admins pay Hushavia Coins and the channel is shown first (marked "Promoted")
 * in the channel directory for a number of days. Days add up when you promote again.
 */
const db = require('../db');
const v = require('../utils/validate');
const settings = require('./settings.service');
const rateLimit = require('../utils/rateLimit');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const DAYS = [1, 3, 7, 14, 30];

async function requireAdmin(userId, chatIdRaw) {
  const chat = await db.one(
    `SELECT c.*, cm.role AS my_role FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2 WHERE c.id = $1`,
    [v.id(chatIdRaw, 'chat_id'), userId],
  );
  if (!chat) throw notFound('chat_not_found', 'Chat not found');
  if (chat.type !== 'channel') throw badRequest('invalid_input', 'Only channels can be promoted');
  if (!['owner', 'admin'].includes(chat.my_role)) throw forbidden('not_admin', 'Only channel admins can promote it');
  return chat;
}

async function info(userId, chatIdRaw) {
  const chat = await requireAdmin(userId, chatIdRaw);
  const perDay = Number(await settings.get('boost_coins_per_day'));
  const until = chat.promoted_until && new Date(chat.promoted_until) > new Date() ? new Date(chat.promoted_until).toISOString() : null;
  const history = await db.many('SELECT days, coins, ends_at, created_at FROM chat_boosts WHERE chat_id = $1 ORDER BY id DESC LIMIT 10', [chat.id]);
  return {
    per_day: perDay,
    options: DAYS.map((d) => ({ days: d, coins: d * perDay })),
    promoted_until: until,
    public: !!chat.username && !chat.is_suspended,
    history: history.map((h) => ({ days: h.days, coins: h.coins, ends_at: new Date(h.ends_at).toISOString(), created_at: new Date(h.created_at).toISOString() })),
  };
}

async function boost(userId, chatIdRaw, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const chat = await requireAdmin(userId, chatIdRaw);
  if (!chat.username) throw badRequest('not_public', 'Make the channel public (give it a @username) to promote it');
  if (chat.is_suspended) throw forbidden('suspended', 'This channel is suspended');
  await require('./tags.service').assertNotBlocked(userId, 'promote channels'); // eslint-disable-line global-require
  const days = Number(body.days);
  if (!DAYS.includes(days)) throw badRequest('invalid_input', `Pick ${DAYS.join(', ')} days`);
  const perDay = Number(await settings.get('boost_coins_per_day'));
  const cost = days * perDay;
  if (body.expected_coins !== undefined && Number(body.expected_coins) !== cost) {
    throw conflict('price_changed', `The price is now ${cost.toLocaleString('en-US')} coins — check it and try again`);
  }
  rateLimit.enforce(`boost:${userId}`, 10, 60 * 60 * 1000, 'Too many tries. Try again later.');
  const coins = require('./coin.service'); // eslint-disable-line global-require
  const r = await db.tx(async (c) => {
    await c.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
    const ch = (await c.query('SELECT promoted_until FROM chats WHERE id = $1 FOR UPDATE', [chat.id])).rows[0];
    const twice = (await c.query(`SELECT 1 FROM chat_boosts WHERE chat_id = $1 AND user_id = $2 AND created_at > now() - interval '10 seconds'`, [chat.id, userId])).rows[0];
    if (twice) throw conflict('just_boosted', 'You promoted this channel a moment ago');
    const balance = await coins.change(c, userId, -cost, 'boost', { note: `Promote @${chat.username} · ${days} day${days > 1 ? 's' : ''}` });
    const from = ch.promoted_until && new Date(ch.promoted_until) > new Date() ? new Date(ch.promoted_until) : new Date();
    const ends = new Date(from.getTime() + days * 86400000);
    await c.query('UPDATE chats SET promoted_until = $2 WHERE id = $1', [chat.id, ends]);
    await c.query('INSERT INTO chat_boosts (chat_id, user_id, days, coins, ends_at) VALUES ($1, $2, $3, $4, $5)', [chat.id, userId, days, cost, ends]);
    return { balance, ends };
  });
  coins.announce(userId, r.balance);
  return { ok: true, promoted_until: r.ends.toISOString(), balance: r.balance, coins: cost };
}

module.exports = { info, boost, DAYS };
