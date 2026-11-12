'use strict';

/**
 * What coins are FOR, beyond a plain transfer:
 *   gifts      — a gift card in a private chat (the coins go to the other person)
 *   tips       — coins for a channel post (go to the channel's owner)
 *   paid channels — a monthly price in coins to be a member
 *   giveaways  — a channel puts coins up; random members who joined the giveaway win them
 *
 * All money moves go through coin.service.change() inside one database transaction each,
 * so nothing is ever created, lost or spent twice.
 */
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const coins = require('./coin.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const chats = () => require('./chat.service'); // eslint-disable-line global-require
const messages = () => require('./message.service'); // eslint-disable-line global-require
const notice = () => require('./notice.service'); // eslint-disable-line global-require
const iso = (d) => (d ? new Date(d).toISOString() : null);
const fmt = (n) => Number(n).toLocaleString('en-US');

// ------------------------------------------------------------------ gifts
const GIFTS = [
  { id: 'rose', name: 'Rose', emoji: '🌹', coins: 10 },
  { id: 'chai', name: 'Cup of chai', emoji: '☕', coins: 25 },
  { id: 'cake', name: 'Cake', emoji: '🎂', coins: 50 },
  { id: 'heart', name: 'Big heart', emoji: '💖', coins: 100 },
  { id: 'teddy', name: 'Teddy bear', emoji: '🧸', coins: 200 },
  { id: 'trophy', name: 'Trophy', emoji: '🏆', coins: 500 },
  { id: 'diamond', name: 'Diamond', emoji: '💎', coins: 1000 },
  { id: 'crown', name: 'Crown', emoji: '👑', coins: 2500 },
  { id: 'rocket', name: 'Rocket', emoji: '🚀', coins: 5000 },
];

function giftList() {
  return GIFTS;
}

/** The creator's part of a tip or a subscription (the rest stays with Hushavia). */
async function creatorPart(amount) {
  const pct = await settings.get('coins_creator_percent');
  return Math.max(0, Math.floor((amount * pct) / 100));
}

/** A gift card in a private chat: the coins move, then the card is posted (and are returned if the card can't be). */
async function sendGift(userId, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const gift = GIFTS.find((g) => g.id === String(body.gift_id || ''));
  if (!gift) throw badRequest('invalid_input', 'Choose a gift');
  const chat = await chats().requireMember(body.chat_id, userId);
  if (chat.type !== 'private') throw badRequest('invalid_input', 'Gifts are sent in private chats');
  const peer = await db.one(
    `SELECT u.id, u.first_name, u.is_bot, u.status FROM chat_members m JOIN users u ON u.id = m.user_id WHERE m.chat_id = $1 AND m.user_id <> $2 LIMIT 1`,
    [chat.id, userId],
  );
  if (!peer || peer.is_bot || peer.status !== 'active') throw badRequest('invalid_input', 'This chat can’t receive gifts');
  if (await require('./user.service').isBlockedEither(userId, peer.id)) throw forbidden('blocked', 'You can’t send a gift to this person'); // eslint-disable-line global-require
  const note = v.str(body.note, { field: 'note', max: 120 }) || null;
  rateLimit.enforce(`coins:gift:${userId}`, 40, 60 * 60 * 1000, 'Too many gifts. Try again later.');
  const move = (from, to, a, b) => db.tx(async (c) => {
    await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [from, to]);
    return { from: await coins.change(c, from, -gift.coins, a, { peerId: to, note: gift.name }), to: await coins.change(c, to, gift.coins, b, { peerId: from, note: gift.name }) };
  });
  const r = await move(userId, peer.id, 'gift_sent', 'gift_received');
  let message;
  try {
    message = await messages().sendMessage(userId, chat.id, { type: 'gift', client_id: body.client_id }, { meta: { gift: { id: gift.id, name: gift.name, emoji: gift.emoji, coins: gift.coins, note } } });
  } catch (e) {
    // the card could not be posted: the coins go back
    const back = await move(peer.id, userId, 'gift_sent', 'gift_received').catch(() => null);
    if (back) {
      coins.announce(userId, back.to);
      coins.announce(peer.id, back.from);
    }
    throw e;
  }
  coins.announce(userId, r.from);
  coins.announce(peer.id, r.to);
  return { balance: r.from, message };
}

// ------------------------------------------------------------------ tips on channel posts
async function tip(userId, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const amount = Number(body.amount);
  if (!Number.isInteger(amount) || amount < 1 || amount > 100000) throw badRequest('invalid_input', 'Tip between 1 and 100,000 coins');
  const m = await db.one('SELECT id, chat_id, deleted_at FROM messages WHERE id = $1', [v.id(body.message_id, 'message_id')]);
  if (!m || m.deleted_at) throw notFound('message_not_found', 'This post is gone');
  const chat = await chats().requireMember(m.chat_id, userId);
  if (chat.type !== 'channel') throw badRequest('invalid_input', 'Tips are for channel posts');
  const owner = await db.one(`SELECT user_id FROM chat_members WHERE chat_id = $1 AND role = 'owner' LIMIT 1`, [chat.id]);
  if (!owner) throw badRequest('invalid_input', 'This channel can’t receive tips');
  if (owner.user_id === userId) throw badRequest('invalid_input', 'This is your own channel');
  rateLimit.enforce(`coins:tip:${userId}`, 60, 60 * 60 * 1000, 'Too many tips. Try again later.');
  const part = await creatorPart(amount);
  const r = await db.tx(async (c) => {
    await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [userId, owner.user_id]);
    const mine = await coins.change(c, userId, -amount, 'tip_sent', { peerId: owner.user_id, note: chat.title });
    const theirs = part > 0 ? await coins.change(c, owner.user_id, part, 'tip_received', { peerId: userId, note: chat.title }) : null;
    const row = (await c.query('UPDATE messages SET coin_tips = coin_tips + $2 WHERE id = $1 RETURNING coin_tips', [m.id, amount])).rows[0];
    return { mine, theirs, tips: row.coin_tips };
  });
  coins.announce(userId, r.mine);
  if (r.theirs !== null) coins.announce(owner.user_id, r.theirs);
  bus.emit('rt:emit', { event: 'message:tips', payload: { chat_id: chat.id, message_id: m.id, tips: r.tips }, userIds: [userId, owner.user_id] });
  if (part > 0) await notice().notify(owner.user_id, 'payment', `A tip of ${fmt(part)} coins 🪙`, `Someone tipped a post in ${chat.title}.`, { chat_id: chat.id, message_id: m.id });
  return { balance: r.mine, tips: r.tips };
}

// ------------------------------------------------------------------ paid channels
const SUB_DAYS = 30;

async function setPrice(userId, chatIdRaw, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const chat = await chats().requireMember(chatIdRaw, userId);
  if (chat.type !== 'channel') throw badRequest('invalid_input', 'Only channels can have a subscription');
  if (chat.my_role !== 'owner') throw forbidden('forbidden', 'Only the owner can set the price');
  const price = Number(body.price);
  if (!Number.isInteger(price) || price < 0 || price > 100000) throw badRequest('invalid_input', 'The price must be 0 – 100,000 coins');
  await db.query('UPDATE chats SET sub_price = $2 WHERE id = $1', [chat.id, price]);
  await chats().emitUpdated(chat.id);
  return { sub_price: price, days: SUB_DAYS };
}

/** Pay for (or renew) a month and become a member. `invite` is needed for a channel that isn't public. */
async function subscribe(userId, chatIdRaw, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  let chat = await db.one(`SELECT * FROM chats WHERE id = $1 AND type = 'channel' AND NOT is_suspended`, [v.id(chatIdRaw, 'chat_id')]);
  if (!chat) throw notFound('chat_not_found', 'Channel not found');
  const member = await db.one('SELECT role FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  if (!member && !chat.is_public) {
    const viaInvite = await chats().findByInvite(String(body.invite || ''));
    if (viaInvite.id !== chat.id) throw notFound('chat_not_found', 'Channel not found');
    chat = viaInvite;
  }
  if (!(chat.sub_price > 0)) throw badRequest('invalid_input', 'This channel is free to join');
  if (member && ['owner', 'admin'].includes(member.role)) throw badRequest('invalid_input', 'Admins don’t pay for their own channel');
  if (!member && (await chats().isBanned(chat.id, userId))) throw forbidden('banned_from_chat', 'An admin removed you from this channel');
  const owner = await db.one(`SELECT user_id FROM chat_members WHERE chat_id = $1 AND role = 'owner' LIMIT 1`, [chat.id]);
  if (!owner) throw badRequest('invalid_input', 'This channel can’t take subscriptions right now');
  rateLimit.enforce(`coins:sub:${userId}`, 20, 60 * 60 * 1000, 'Too many attempts. Try again later.');
  const r = await charge(userId, owner.user_id, chat);
  if (!member) await chats().joinChat(userId, { ...chat, paid_ok: true });
  coins.announce(userId, r.mine);
  if (r.theirs !== null) coins.announce(owner.user_id, r.theirs);
  return { balance: r.mine, expires_at: iso(r.expires_at), chat_id: chat.id };
}

/** Takes one month's price and moves the subscription's end forward. */
async function charge(userId, ownerId, chat) {
  const part = await creatorPart(chat.sub_price);
  return db.tx(async (c) => {
    await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [userId, ownerId]);
    const mine = await coins.change(c, userId, -chat.sub_price, 'sub_paid', { peerId: ownerId, note: chat.title });
    const theirs = part > 0 ? await coins.change(c, ownerId, part, 'sub_income', { peerId: userId, note: chat.title }) : null;
    const s = (await c.query(
      `INSERT INTO channel_subs (chat_id, user_id, expires_at, price) VALUES ($1, $2, now() + make_interval(days => $4), $3)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET expires_at = GREATEST(channel_subs.expires_at, now()) + make_interval(days => $4), price = $3
       RETURNING expires_at`,
      [chat.id, userId, chat.sub_price, SUB_DAYS],
    )).rows[0];
    return { mine, theirs, expires_at: s.expires_at };
  });
}

async function mySubscription(userId, chatIdRaw) {
  const s = await db.one('SELECT expires_at, price FROM channel_subs WHERE chat_id = $1 AND user_id = $2', [v.id(chatIdRaw, 'chat_id'), userId]);
  return s ? { expires_at: iso(s.expires_at), price: s.price } : null;
}

/** Subscriptions that ran out: renew from the balance when there is enough, otherwise the member leaves. */
async function sweepSubs() {
  const due = await db.many(
    `SELECT s.chat_id, s.user_id, c.title, c.sub_price, c.type, m.role,
            (SELECT o.user_id FROM chat_members o WHERE o.chat_id = s.chat_id AND o.role = 'owner' LIMIT 1) AS owner_id
     FROM channel_subs s JOIN chats c ON c.id = s.chat_id LEFT JOIN chat_members m ON m.chat_id = s.chat_id AND m.user_id = s.user_id
     WHERE s.expires_at < now() ORDER BY s.expires_at LIMIT 50`,
  );
  for (const d of due) {
    try {
      const stays = !d.role || d.role !== 'member' || !(d.sub_price > 0) || !d.owner_id;
      if (stays) {
        // left already, became an admin, or the channel is free now: nothing to pay for
        await db.query('DELETE FROM channel_subs WHERE chat_id = $1 AND user_id = $2', [d.chat_id, d.user_id]);
        continue;
      }
      try {
        const r = await charge(d.user_id, d.owner_id, { id: d.chat_id, title: d.title, sub_price: d.sub_price });
        coins.announce(d.user_id, r.mine);
        if (r.theirs !== null) coins.announce(d.owner_id, r.theirs);
        await notice().notify(d.user_id, 'payment', `${d.title}: subscription renewed`, `${fmt(d.sub_price)} coins for the next ${SUB_DAYS} days.`, { chat_id: d.chat_id });
      } catch (e) {
        if (e.code !== 'not_enough_coins') throw e;
        await db.query('DELETE FROM channel_subs WHERE chat_id = $1 AND user_id = $2', [d.chat_id, d.user_id]);
        await chats().leaveChat(d.user_id, d.chat_id);
        await notice().notify(d.user_id, 'payment', `${d.title}: subscription ended`, `You need ${fmt(d.sub_price)} coins to stay. Get coins and join again any time.`, { chat_id: d.chat_id });
      }
    } catch (_) {
      // one broken row must not stop the others; push it an hour ahead
      await db.query(`UPDATE channel_subs SET expires_at = now() + interval '1 hour' WHERE chat_id = $1 AND user_id = $2`, [d.chat_id, d.user_id]).catch(() => {});
    }
  }
}

// ------------------------------------------------------------------ giveaways
function serializeGiveaway(g, extra = {}) {
  return {
    id: g.id,
    chat_id: g.chat_id,
    coins_each: g.coins_each,
    winners: g.winners,
    ends_at: iso(g.ends_at),
    status: g.status, // open | done
    entries: Number(g.entries || 0),
    joined: !!g.joined,
    mine: !!extra.mine,
    winner_list: extra.winners || [],
  };
}

async function loadGiveaway(userId, idRaw) {
  const g = await db.one(
    `SELECT g.*, (SELECT count(*) FROM giveaway_entries e WHERE e.giveaway_id = g.id) AS entries,
            EXISTS (SELECT 1 FROM giveaway_entries e WHERE e.giveaway_id = g.id AND e.user_id = $2) AS joined
     FROM giveaways g WHERE g.id = $1`,
    [v.id(idRaw, 'giveaway_id'), userId],
  );
  if (!g) throw notFound('giveaway_not_found', 'Giveaway not found');
  await chats().requireMember(g.chat_id, userId);
  return g;
}

async function getGiveaway(userId, idRaw) {
  const g = await loadGiveaway(userId, idRaw);
  const winners = g.status === 'done'
    ? await db.many(`SELECT u.id, u.first_name, u.last_name, u.username FROM giveaway_entries e JOIN users u ON u.id = e.user_id WHERE e.giveaway_id = $1 AND e.won ORDER BY e.user_id`, [g.id])
    : [];
  return serializeGiveaway(g, { mine: g.creator_id === userId, winners: winners.map((w) => ({ id: w.id, name: `${w.first_name || ''} ${w.last_name || ''}`.trim(), username: w.username })) });
}

/** The coins are taken from the creator now and held until the draw. */
async function createGiveaway(userId, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const chat = await chats().requireMember(body.chat_id, userId);
  if (!['channel', 'group'].includes(chat.type)) throw badRequest('invalid_input', 'Giveaways are for channels and groups');
  if (!chats().ADMIN_ROLES.includes(chat.my_role)) throw forbidden('forbidden', 'Only admins can start a giveaway');
  const each = Number(body.coins_each);
  const winners = Number(body.winners);
  const hours = Number(body.hours);
  if (!Number.isInteger(each) || each < 1 || each > 100000) throw badRequest('invalid_input', 'The prize must be 1 – 100,000 coins');
  if (!Number.isInteger(winners) || winners < 1 || winners > 100) throw badRequest('invalid_input', 'Winners must be 1 – 100');
  if (!Number.isFinite(hours) || hours < 1 / 60 || hours > 24 * 30) throw badRequest('invalid_input', 'The giveaway can run from a minute to 30 days');
  const open = await db.one(`SELECT count(*)::int AS n FROM giveaways WHERE chat_id = $1 AND status = 'open'`, [chat.id]);
  if (open.n >= 3) throw conflict('too_many', 'This chat already has 3 giveaways running');
  rateLimit.enforce(`coins:giveaway:${userId}`, 10, 60 * 60 * 1000, 'Too many giveaways. Try again later.');
  const total = each * winners;
  const g = await db.tx(async (c) => {
    const row = (await c.query(
      `INSERT INTO giveaways (chat_id, creator_id, coins_each, winners, ends_at) VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5)) RETURNING *`,
      [chat.id, userId, each, winners, Math.round(hours * 3600)],
    )).rows[0];
    row.balance = await coins.change(c, userId, -total, 'giveaway', { note: chat.title });
    return row;
  });
  let message;
  try {
    message = await messages().sendMessage(userId, chat.id, { type: 'giveaway' }, { skipQueue: true, meta: { giveaway: { id: g.id, coins_each: each, winners, ends_at: iso(g.ends_at) } } });
  } catch (e) {
    const back = await db.tx(async (c) => {
      await c.query('DELETE FROM giveaways WHERE id = $1', [g.id]);
      return coins.change(c, userId, total, 'giveaway_refund', { note: chat.title });
    }).catch(() => null);
    if (back !== null) coins.announce(userId, back);
    throw e;
  }
  await db.query('UPDATE giveaways SET message_id = $2 WHERE id = $1', [g.id, message.id]);
  coins.announce(userId, g.balance);
  return { balance: g.balance, giveaway: serializeGiveaway(g), message };
}

async function joinGiveaway(userId, idRaw) {
  const g = await loadGiveaway(userId, idRaw);
  if (g.status !== 'open' || new Date(g.ends_at) <= new Date()) throw conflict('giveaway_over', 'This giveaway is over');
  if (g.creator_id === userId) throw badRequest('invalid_input', 'You started this giveaway');
  await db.query('INSERT INTO giveaway_entries (giveaway_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [g.id, userId]);
  return getGiveaway(userId, g.id);
}

/** Draws every giveaway whose time is up: random winners among people who joined and are still members. */
async function sweepGiveaways() {
  const due = await db.many(`SELECT * FROM giveaways WHERE status = 'open' AND ends_at <= now() ORDER BY id LIMIT 20`);
  for (const g of due) {
    try {
      const done = await db.tx(async (c) => {
        const locked = (await c.query(`UPDATE giveaways SET status = 'done' WHERE id = $1 AND status = 'open' RETURNING id`, [g.id])).rows[0];
        if (!locked) return null;
        const picked = (await c.query(
          `UPDATE giveaway_entries SET won = TRUE WHERE giveaway_id = $1 AND user_id IN (
             SELECT e.user_id FROM giveaway_entries e JOIN chat_members m ON m.chat_id = $2 AND m.user_id = e.user_id
               JOIN users u ON u.id = e.user_id AND u.status = 'active'
             WHERE e.giveaway_id = $1 ORDER BY random() LIMIT $3) RETURNING user_id`,
          [g.id, g.chat_id, g.winners],
        )).rows.map((r) => r.user_id);
        const balances = {};
        for (const w of picked.sort((a, b) => a - b)) balances[w] = await coins.change(c, w, g.coins_each, 'giveaway_win', { peerId: g.creator_id, orderId: null, note: 'Giveaway' });
        const left = (g.winners - picked.length) * g.coins_each;
        // prizes nobody could win go back to the creator
        const refund = left > 0 ? await coins.change(c, g.creator_id, left, 'giveaway_refund', { note: 'Giveaway' }) : null;
        return { picked, balances, refund };
      });
      if (!done) continue;
      for (const w of done.picked) {
        coins.announce(w, done.balances[w]);
        await notice().notify(w, 'payment', `You won ${fmt(g.coins_each)} coins 🎉`, 'A giveaway you joined has finished — the coins are in your balance.', { chat_id: g.chat_id, giveaway_id: g.id });
      }
      if (done.refund !== null) coins.announce(g.creator_id, done.refund);
      const names = done.picked.length
        ? (await db.many('SELECT first_name, username FROM users WHERE id = ANY($1::bigint[])', [done.picked])).map((u) => (u.username ? `@${u.username}` : u.first_name)).join(', ')
        : null;
      const text = names
        ? `🎉 Giveaway finished! ${done.picked.length === 1 ? 'Winner' : 'Winners'} of ${fmt(g.coins_each)} coins${done.picked.length === 1 ? '' : ' each'}: ${names}`
        : '🎁 The giveaway finished, but nobody joined. The coins went back.';
      await messages().sendMessage(g.creator_id, g.chat_id, { type: 'text', text, reply_to_id: g.message_id || undefined }, { skipQueue: true, skipRateLimit: true }).catch(() => {});
      bus.emit('rt:emit', { event: 'giveaway:done', payload: { giveaway_id: g.id, chat_id: g.chat_id }, userIds: await chats().memberIds(g.chat_id).catch(() => []) });
    } catch (err) {
      console.error('giveaway draw failed', g.id, err && err.message); // eslint-disable-line no-console
    }
  }
}

async function sweep() {
  await sweepGiveaways();
  await sweepSubs();
}

function previewText(type, meta) {
  if (type === 'gift') return `🎁 Gift: ${(meta && meta.gift && meta.gift.name) || 'coins'}`;
  return '🎉 Giveaway';
}

module.exports = { GIFTS, giftList, sendGift, tip, setPrice, subscribe, mySubscription, createGiveaway, getGiveaway, joinGiveaway, sweep, sweepSubs, sweepGiveaways, previewText, SUB_DAYS };
