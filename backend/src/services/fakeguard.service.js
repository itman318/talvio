'use strict';

/**
 * Against fake members (the "buy 10,000 subscribers" kind):
 *   1. brand-new accounts can't mass-join, mass-add or mass-message,
 *   2. channels earn on REAL subscribers and real views (not on numbers anyone can buy),
 *   3. the admin panel lists accounts that look like a fake-account farm, to ban them in one go.
 */
const db = require('../db');
const settings = require('./settings.service');
const { forbidden } = require('../utils/errors');

// ------------------------------------------------------------------ 1. new accounts
// the automated tests make brand-new accounts all the time: there the limits are on only when a test asks
let enforced = !process.env.NODE_TEST_CONTEXT && process.env.NEW_ACCOUNT_LIMITS !== 'off';
function setEnforced(on) {
  enforced = !!on;
}

/** Hours since the account was made, or null for bots / accounts old enough to be free of these limits. */
async function newAccountAge(userId) {
  if (!enforced) return null;
  const s = await settings.getAll();
  const hours = s.new_account_hours;
  if (!(hours > 0)) return null;
  const u = await db.one(
    `SELECT EXTRACT(EPOCH FROM (now() - created_at)) / 3600 AS age, is_bot FROM users WHERE id = $1`,
    [userId],
  );
  if (!u || u.is_bot || Number(u.age) >= hours) return null;
  return { age: Number(u.age), hours, s };
}

const wait = (n) => (n.hours - n.age >= 1 ? `${Math.ceil(n.hours - n.age)} hours` : 'an hour');

/** Joining a group / channel by itself (an admin adding or approving someone is not counted). */
async function assertCanJoin(userId) {
  const n = await newAccountAge(userId);
  if (!n) return;
  const r = await db.one(
    `SELECT count(*)::int AS c FROM chat_members m JOIN chats c ON c.id = m.chat_id
     WHERE m.user_id = $1 AND c.type IN ('group', 'channel') AND m.joined_at > now() - interval '24 hours'
       AND NOT EXISTS (SELECT 1 FROM users o WHERE o.id = c.created_by AND o.is_bot)`, // the official news channel doesn't count
    [userId],
  );
  if (r.c >= n.s.new_account_max_joins) {
    throw forbidden('new_account_limit', `New accounts can join ${n.s.new_account_max_joins} groups or channels a day. You can join more in ${wait(n)}.`);
  }
}

/** Adding other people to a group / channel. */
async function assertCanAdd(userId, count) {
  if (!count) return;
  const n = await newAccountAge(userId);
  if (!n) return;
  throw forbidden('new_account_limit', `New accounts can’t add people to groups yet. Share the invite link instead — or try again in ${wait(n)}.`);
}

/** Starting a private chat with someone who isn't in my contacts. */
async function assertCanStartChat(userId, peerId) {
  // a flagged (scam / fake) account can only write to people who have it in their contacts
  if (await require('./tags.service').isFlagged(userId)) { // eslint-disable-line global-require
    const ok = await db.one('SELECT 1 AS x FROM contacts WHERE owner_id = $2 AND contact_id = $1 LIMIT 1', [userId, peerId]);
    if (!ok) throw forbidden('account_flagged', 'Your account is flagged after confirmed reports, so you can’t start new chats. You can appeal in Help & support.');
  }
  const n = await newAccountAge(userId);
  if (!n) return;
  const known = await db.one('SELECT 1 AS x FROM contacts WHERE (owner_id = $1 AND contact_id = $2) OR (owner_id = $2 AND contact_id = $1) LIMIT 1', [userId, peerId]);
  if (known) return;
  const r = await db.one(
    `SELECT count(*)::int AS c FROM chat_members m JOIN chats c ON c.id = m.chat_id
     WHERE m.user_id = $1 AND c.type = 'private' AND c.created_by = $1 AND m.joined_at > now() - interval '24 hours'`,
    [userId],
  );
  if (r.c >= n.s.new_account_max_new_chats) {
    throw forbidden('new_account_limit', `New accounts can start ${n.s.new_account_max_new_chats} chats with people outside their contacts a day. Try again in ${wait(n)}.`);
  }
}

// ------------------------------------------------------------------ 2. real subscribers
/** SQL: user `u` is a real, active person (not a bot, not brand new, opened the app in the last 30 days). */
const REAL_SQL = `u.status = 'active' AND NOT u.is_bot AND u.created_at < now() - interval '7 days'
  AND u.last_seen_at > now() - interval '30 days'`;

async function realSubscribers(chatId) {
  const r = await db.one(
    `SELECT count(*)::int AS n FROM chat_members m JOIN users u ON u.id = m.user_id WHERE m.chat_id = $1 AND ${REAL_SQL}`,
    [chatId],
  );
  return r.n;
}

/** Average views of the channel's posts in the last 30 days. */
async function averageViews(chatId) {
  const r = await db.one(
    `SELECT COALESCE(round(avg(views_count)), 0)::int AS v FROM messages
     WHERE chat_id = $1 AND deleted_at IS NULL AND thread_id IS NULL AND type NOT IN ('system', 'call') AND created_at > now() - interval '30 days'`,
    [chatId],
  );
  return r.v;
}

/**
 * Hourly: a monetized channel whose real audience fell far below the requirement stops earning
 * (subscribers bought after monetization was switched on don't count either).
 */
async function recheckMonetized() {
  const s = await settings.getAll();
  const min = s.monetize_min_subscribers;
  if (!(min > 0)) return;
  const rows = await db.many(
    `SELECT c.id, c.title, (SELECT user_id FROM chat_members WHERE chat_id = c.id AND role = 'owner' LIMIT 1) AS owner
     FROM chats c WHERE c.monetized AND c.type = 'channel' AND c.monetized_at < now() - interval '3 days'
     ORDER BY c.id LIMIT 200`,
  );
  for (const c of rows) {
    const real = await realSubscribers(c.id);
    if (real >= Math.floor(min * 0.8)) continue;
    await db.query('UPDATE chats SET monetized = FALSE, sub_price = 0 WHERE id = $1', [c.id]);
    await require('./chat.service').emitUpdated(c.id).catch(() => {}); // eslint-disable-line global-require
    if (c.owner) {
      await require('./notice.service').notify(c.owner, 'payment', `${c.title}: monetization paused`, // eslint-disable-line global-require
        `The channel has ${real.toLocaleString('en-US')} active subscribers — it needs ${min.toLocaleString('en-US')}. It can be turned on again when it gets there.`, { chat_id: c.id }).catch(() => {});
    }
  }
}

// ------------------------------------------------------------------ 3. suspicious accounts (admin panel)
/**
 * Accounts made in the last 30 days, with a score from things fake-account farms have in common.
 * Many real people share one mobile IP in Pakistan, so the same IP alone is never enough.
 */
async function suspicious(query = {}) {
  const min = Math.max(1, Math.min(10, parseInt(query.min_score, 10) || 4));
  const rows = await db.many(
    `WITH fresh AS (
       SELECT u.id, u.first_name, u.last_name, u.username, u.phone, u.created_at, u.last_seen_at, u.avatar_media_id,
              (SELECT s.ip FROM sessions s WHERE s.user_id = u.id ORDER BY s.id LIMIT 1) AS ip
       FROM users u WHERE u.status = 'active' AND NOT u.is_bot AND u.created_at > now() - interval '30 days'
     ), ips AS (
       SELECT ip, count(*)::int AS n FROM fresh WHERE ip IS NOT NULL GROUP BY ip
     )
     SELECT f.*, COALESCE(i.n, 1) AS same_ip,
            (SELECT count(*)::int FROM chat_members m JOIN chats c ON c.id = m.chat_id
               WHERE m.user_id = f.id AND c.type IN ('group', 'channel') AND m.joined_at < f.created_at + interval '2 days') AS early_joins,
            EXISTS (SELECT 1 FROM messages x WHERE x.sender_id = f.id AND x.type <> 'system' LIMIT 1) AS wrote,
            EXISTS (SELECT 1 FROM contacts k WHERE k.owner_id = f.id LIMIT 1) AS has_contacts
     FROM fresh f LEFT JOIN ips i ON i.ip = f.ip
     ORDER BY f.id DESC LIMIT 3000`,
  );
  const out = [];
  for (const r of rows) {
    const why = [];
    let score = 0;
    if (r.same_ip >= 10) { score += 2; why.push(`${r.same_ip} new accounts from the same IP`); }
    if (r.early_joins >= 10) { score += 2; why.push(`joined ${r.early_joins} groups/channels in its first 2 days`); } else if (r.early_joins >= 5) { score += 1; why.push(`joined ${r.early_joins} groups/channels at once`); }
    if (!r.wrote) { score += 1; why.push('never wrote a message'); }
    if (!r.avatar_media_id) { score += 1; why.push('no photo'); }
    if (!r.has_contacts) { score += 1; why.push('no contacts'); }
    if (!r.last_seen_at || new Date(r.last_seen_at) < new Date(Date.now() - 7 * 86400000)) { score += 1; why.push('not seen in a week'); }
    if (score >= min) {
      out.push({
        user: { id: r.id, name: `${r.first_name || ''} ${r.last_name || ''}`.trim() || '(no name)', username: r.username, phone: r.phone },
        score,
        reasons: why,
        ip: r.ip ? String(r.ip).replace(/^::ffff:/, '') : null,
        created_at: new Date(r.created_at).toISOString(),
      });
    }
  }
  out.sort((a, b) => b.score - a.score || b.user.id - a.user.id);
  return { min_score: min, total: out.length, users: out.slice(0, 500) };
}

module.exports = { setEnforced, assertCanJoin, assertCanAdd, assertCanStartChat, realSubscribers, averageViews, recheckMonetized, suspicious, REAL_SQL };
