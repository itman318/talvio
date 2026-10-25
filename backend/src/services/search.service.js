'use strict';

/**
 * One search for everything (like Telegram's global search):
 *   my chats · people · bots · public groups · public channels  (+ messages via /search/messages)
 * With an empty query it returns "Discover": popular channels, groups and bots.
 */
const db = require('../db');
const v = require('../utils/validate');
const rateLimit = require('../utils/rateLimit');
const userService = require('./user.service');
const chatService = require('./chat.service');

const TYPES = ['all', 'chats', 'people', 'bots', 'groups', 'channels'];

function like(q) {
  return q.replace(/[\\%_]/g, (c) => `\\${c}`);
}

async function myChats(userId, term, limit) {
  const rows = await db.many(
    `SELECT c.id FROM chat_members cm JOIN chats c ON c.id = cm.chat_id
     LEFT JOIN LATERAL (
       SELECT u.first_name, u.last_name, u.username FROM chat_members o JOIN users u ON u.id = o.user_id
       WHERE c.type = 'private' AND o.chat_id = c.id AND o.user_id <> $1 LIMIT 1
     ) p ON TRUE
     WHERE cm.user_id = $1 AND NOT cm.is_hidden
       AND (c.title ILIKE '%' || $2 || '%' OR lower(c.username) LIKE lower($2) || '%'
            OR (p.first_name || ' ' || COALESCE(p.last_name, '')) ILIKE '%' || $2 || '%'
            OR lower(p.username) LIKE lower($2) || '%')
     ORDER BY c.last_message_at DESC NULLS LAST LIMIT $3`,
    [userId, term, limit],
  );
  return chatService.getChatsByIds(userId, rows.map((r) => r.id));
}

async function people(userId, q, limit) {
  const list = await userService.searchUsers(userId, q);
  return list.filter((u) => !u.is_bot).slice(0, limit);
}

async function botsFor(userId, rows) {
  const map = await userService.getUsersMap(userId, rows.map((r) => r.id));
  return rows
    .map((r) => {
      const u = map.get(r.id);
      return u ? { ...u, about: r.about || '', users: Number(r.users || 0) } : null;
    })
    .filter(Boolean);
}

async function bots(userId, term, limit) {
  const rows = await db.many(
    `SELECT u.id, b.about, (SELECT count(*) FROM chat_members cm WHERE cm.user_id = u.id) AS users
     FROM users u JOIN bots b ON b.user_id = u.id
     WHERE u.is_bot AND u.status = 'active' AND b.status = 'active'
       AND (lower(u.username) LIKE lower($1) || '%' OR u.first_name ILIKE '%' || $1 || '%' OR b.about ILIKE '%' || $1 || '%')
     ORDER BY (lower(u.username) = lower($1)) DESC, users DESC LIMIT $2`,
    [term, limit],
  );
  return botsFor(userId, rows);
}

async function publicChats(userId, type, term, limit) {
  const rows = await db.many(
    `SELECT c.*, (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id) AS n,
            EXISTS (SELECT 1 FROM chat_members me WHERE me.chat_id = c.id AND me.user_id = $3) AS me
     FROM chats c
     WHERE c.type = $1 AND c.is_public AND NOT c.is_suspended
       AND (lower(c.username) LIKE lower($2) || '%' OR c.title ILIKE '%' || $2 || '%' OR c.description ILIKE '%' || $2 || '%')
     ORDER BY (lower(c.username) = lower($2)) DESC, c.is_verified DESC, n DESC LIMIT $4`,
    [type, term, userId, limit],
  );
  return rows.map((c) => ({ ...chatService.publicSummary(c, Number(c.n), c.me), category: c.category || null }));
}

async function search(userId, query = {}) {
  const q = String(query.q || '').trim().replace(/^@/, '').slice(0, 64);
  const type = query.type ? v.oneOf(query.type, TYPES, 'type') : 'all';
  if (q.length < 2) return discover(userId);
  rateLimit.enforce(`gsearch:${userId}`, 60, 60 * 1000, 'Searching too fast, wait a moment');
  const n = type === 'all' ? 6 : v.limit(query.limit, 30, 50);
  const term = like(q);
  const want = (t) => type === 'all' || type === t;
  const [chats, ppl, bts, groups, channels] = await Promise.all([
    want('chats') ? myChats(userId, term, n) : [],
    want('people') ? people(userId, q, n) : [],
    want('bots') ? bots(userId, term, n) : [],
    want('groups') ? publicChats(userId, 'group', term, n) : [],
    want('channels') ? publicChats(userId, 'channel', term, n) : [],
  ]);
  // public groups/channels I'm already in show up under "chats"
  const mine = new Set(chats.map((c) => c.id));
  return {
    query: q,
    chats,
    people: ppl,
    bots: bts,
    groups: groups.filter((g) => !mine.has(g.chat_id)),
    channels: channels.filter((c) => !mine.has(c.chat_id)),
  };
}

/** Empty search box: popular channels, groups and bots to discover. */
async function discover(userId) {
  const top = (type) => db.many(
    `SELECT c.*, (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id) AS n,
            EXISTS (SELECT 1 FROM chat_members me WHERE me.chat_id = c.id AND me.user_id = $2) AS me
     FROM chats c WHERE c.type = $1 AND c.is_public AND NOT c.is_suspended
     ORDER BY c.is_verified DESC, n DESC LIMIT 10`,
    [type, userId],
  );
  const [channels, groups, botRows] = await Promise.all([
    top('channel'),
    top('group'),
    db.many(
      `SELECT u.id, b.about, (SELECT count(*) FROM chat_members cm WHERE cm.user_id = u.id) AS users
       FROM users u JOIN bots b ON b.user_id = u.id
       WHERE u.is_bot AND u.status = 'active' AND b.status = 'active' AND u.username IS NOT NULL
       ORDER BY (b.owner_id = b.user_id) DESC, users DESC LIMIT 10`,
    ),
  ]);
  return {
    query: '',
    discover: true,
    chats: [],
    people: [],
    bots: await botsFor(userId, botRows),
    groups: groups.map((c) => chatService.publicSummary(c, Number(c.n), c.me)),
    channels: channels.map((c) => ({ ...chatService.publicSummary(c, Number(c.n), c.me), category: c.category || null })),
  };
}

module.exports = { search, discover };
