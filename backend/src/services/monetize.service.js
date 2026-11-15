'use strict';

/**
 * Channel monetization: a channel earns (ad share, tips, paid subscription) only after its owner
 * turns monetization on — and that is only possible when the channel meets the requirements.
 * A suspended channel never earns.
 */
const db = require('../db');
const settings = require('./settings.service');
const { forbidden, badRequest } = require('../utils/errors');

const iso = (d) => (d ? new Date(d).toISOString() : null);

/** The checklist for one channel (any viewer may not see it: owner only, see status()). */
async function checks(chat) {
  const s = await settings.getAll();
  const row = await db.one(
    `SELECT c.is_public, c.is_suspended, c.member_count, c.created_at,
            (SELECT count(*)::int FROM messages m WHERE m.chat_id = c.id AND m.deleted_at IS NULL AND m.thread_id IS NULL
               AND m.type NOT IN ('system', 'call') AND m.created_at > now() - interval '30 days') AS posts,
            o.created_at AS owner_since, (o.password_hash IS NOT NULL) AS two_step, o.restricted_until
     FROM chats c JOIN chat_members om ON om.chat_id = c.id AND om.role = 'owner' JOIN users o ON o.id = om.user_id
     WHERE c.id = $1`,
    [chat.id],
  );
  if (!row) return [];
  const days = (d) => Math.floor((Date.now() - new Date(d).getTime()) / 86400000);
  // real people only: bought / fake / sleeping accounts don't count
  const guard = require('./fakeguard.service'); // eslint-disable-line global-require
  const real = await guard.realSubscribers(chat.id);
  const views = await guard.averageViews(chat.id);
  const list = [
    { key: 'public', label: 'The channel is public (has a @username)', ok: !!row.is_public },
    { key: 'subscribers', label: `At least ${s.monetize_min_subscribers.toLocaleString('en-US')} active subscribers (real people who opened Hushavia in the last 30 days)`, ok: real >= s.monetize_min_subscribers, have: real, need: s.monetize_min_subscribers },
    { key: 'views', label: `On average ${s.monetize_min_avg_views.toLocaleString('en-US')} views per post (last 30 days)`, ok: views >= s.monetize_min_avg_views, have: views, need: s.monetize_min_avg_views },
    { key: 'age', label: `The channel is at least ${s.monetize_min_days} days old`, ok: days(row.created_at) >= s.monetize_min_days, have: days(row.created_at), need: s.monetize_min_days },
    { key: 'posts', label: `At least ${s.monetize_min_posts} posts in the last 30 days`, ok: row.posts >= s.monetize_min_posts, have: row.posts, need: s.monetize_min_posts },
    { key: 'owner_age', label: `Your account is at least ${s.monetize_min_days} days old`, ok: days(row.owner_since) >= s.monetize_min_days, have: days(row.owner_since), need: s.monetize_min_days },
    { key: 'clean', label: 'No limits on the channel or your account', ok: !row.is_suspended && !(row.restricted_until && new Date(row.restricted_until) > new Date()) },
  ];
  if (s.monetize_require_2fa) list.splice(5, 0, { key: 'two_step', label: 'Two-step verification is on (Settings → Privacy & security)', ok: !!row.two_step });
  return list;
}

async function requireOwner(userId, chatIdRaw) {
  const chat = await require('./chat.service').requireMember(chatIdRaw, userId); // eslint-disable-line global-require
  if (chat.type !== 'channel') throw badRequest('invalid_input', 'Monetization is for channels');
  if (chat.my_role !== 'owner') throw forbidden('forbidden', 'Only the channel’s owner can see this');
  return chat;
}

async function status(userId, chatIdRaw) {
  const chat = await requireOwner(userId, chatIdRaw);
  const s = await settings.getAll();
  const list = await checks(chat);
  const c = await db.one('SELECT monetized, monetized_at, is_suspended FROM chats WHERE id = $1', [chat.id]);
  const earned = await db.one(
    `SELECT COALESCE(sum(delta) FILTER (WHERE kind = 'tip_received'), 0)::bigint AS tips,
            COALESCE(sum(delta) FILTER (WHERE kind = 'sub_income'), 0)::bigint AS subs
     FROM coin_tx WHERE user_id = $1 AND note = $2`,
    [userId, chat.title],
  );
  const ads = await db.one('SELECT paid_coins FROM ad_owner_earnings WHERE owner_id = $1', [userId]);
  return {
    open: !!s.feature_coins,
    monetized: !!c.monetized && !c.is_suspended,
    since: iso(c.monetized_at),
    eligible: list.every((x) => x.ok),
    checks: list,
    shares: { ads_percent: s.ads_owner_percent, tips_percent: s.coins_creator_percent, subs_percent: s.coins_creator_percent },
    earned: { tips: Number(earned.tips), subscriptions: Number(earned.subs), ads_all_channels: ads ? Number(ads.paid_coins) : 0 },
  };
}

async function enable(userId, chatIdRaw) {
  await settings.requireFeature('feature_coins', 'Coins');
  const chat = await requireOwner(userId, chatIdRaw);
  const list = await checks(chat);
  const missing = list.filter((x) => !x.ok);
  if (missing.length) throw forbidden('not_eligible', `Not yet: ${missing.map((x) => x.label.toLowerCase()).join('; ')}`);
  await db.query('UPDATE chats SET monetized = TRUE, monetized_at = COALESCE(monetized_at, now()) WHERE id = $1', [chat.id]);
  await require('./chat.service').emitUpdated(chat.id); // eslint-disable-line global-require
  return status(userId, chat.id);
}

async function disable(userId, chatIdRaw) {
  const chat = await requireOwner(userId, chatIdRaw);
  await db.query('UPDATE chats SET monetized = FALSE, sub_price = 0 WHERE id = $1', [chat.id]);
  await require('./chat.service').emitUpdated(chat.id); // eslint-disable-line global-require
  return status(userId, chat.id);
}

/** True when this channel may earn right now. */
async function earns(chatId) {
  const c = await db.one('SELECT monetized, is_suspended FROM chats WHERE id = $1', [chatId]);
  return !!(c && c.monetized && !c.is_suspended);
}

module.exports = { checks, status, enable, disable, earns };
