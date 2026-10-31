'use strict';

/**
 * Talvio Business (for anyone who talks to customers):
 *  - greeting message: sent automatically to someone who writes for the first time (or after N quiet days)
 *  - away message: sent automatically outside working hours / always / while you're offline
 *  - working hours: per weekday, in the owner's time zone
 *  - quick replies: "/shortcut" → saved text, picked in the composer
 * Auto-replies only happen in private chats with real people, at most once per person every 6 hours (away).
 */
const db = require('../db');
const bus = require('../bus');
const v = require('../utils/validate');
const presence = require('./presence');
const { badRequest, notFound } = require('../utils/errors');

const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const MODES = ['always', 'outside_hours', 'offline'];
const AWAY_GAP_HOURS = 6;
const MAX_REPLIES = 100;

function serialize(r) {
  return {
    greeting_on: !!(r && r.greeting_on),
    greeting_text: (r && r.greeting_text) || '',
    greeting_days: (r && r.greeting_days) || 7,
    away_on: !!(r && r.away_on),
    away_text: (r && r.away_text) || '',
    away_mode: (r && r.away_mode) || 'outside_hours',
    hours: (r && r.hours) || {},
    tz_offset_min: (r && r.tz_offset_min) || 0,
  };
}

async function get(userId) {
  return serialize(await db.one('SELECT * FROM business_settings WHERE user_id = $1', [userId]));
}

/** hours: { mon: [[540, 1080]], tue: [], … } — minutes from midnight; a missing day means closed. */
function parseHours(raw) {
  if (raw === undefined) return undefined;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw badRequest('invalid_input', 'hours must be an object');
  const out = {};
  for (const d of DAYS) {
    const spans = raw[d];
    if (spans === undefined || spans === null) continue;
    if (!Array.isArray(spans) || spans.length > 3) throw badRequest('invalid_input', `hours.${d} must be a list of [from, to]`);
    out[d] = spans.map((s) => {
      if (!Array.isArray(s) || s.length !== 2) throw badRequest('invalid_input', `hours.${d} must be a list of [from, to]`);
      const a = Number(s[0]), b = Number(s[1]);
      if (!Number.isInteger(a) || !Number.isInteger(b) || a < 0 || b > 1440 || a >= b) throw badRequest('invalid_input', `hours.${d}: from must be before to`);
      return [a, b];
    });
  }
  return out;
}

async function set(userId, body = {}) {
  const cur = await get(userId);
  const next = { ...cur };
  if (body.greeting_on !== undefined) next.greeting_on = v.bool(body.greeting_on, 'greeting_on');
  if (body.greeting_text !== undefined) next.greeting_text = v.str(String(body.greeting_text), { field: 'greeting_text', max: 1000 });
  if (body.greeting_days !== undefined) {
    const d = Number(body.greeting_days);
    if (![1, 7, 14, 28].includes(d)) throw badRequest('invalid_input', 'greeting_days must be 1, 7, 14 or 28');
    next.greeting_days = d;
  }
  if (body.away_on !== undefined) next.away_on = v.bool(body.away_on, 'away_on');
  if (body.away_text !== undefined) next.away_text = v.str(String(body.away_text), { field: 'away_text', max: 1000 });
  if (body.away_mode !== undefined) next.away_mode = v.oneOf(body.away_mode, MODES, 'away_mode');
  const h = parseHours(body.hours);
  if (h !== undefined) next.hours = h;
  if (body.tz_offset_min !== undefined) {
    const z = Number(body.tz_offset_min);
    if (!Number.isInteger(z) || z < -720 || z > 840) throw badRequest('invalid_input', 'tz_offset_min is out of range');
    next.tz_offset_min = z;
  }
  if (next.greeting_on && !next.greeting_text.trim()) throw badRequest('invalid_input', 'Write the greeting message first');
  if (next.away_on && !next.away_text.trim()) throw badRequest('invalid_input', 'Write the away message first');
  await db.query(
    `INSERT INTO business_settings (user_id, greeting_on, greeting_text, greeting_days, away_on, away_text, away_mode, hours, tz_offset_min, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, now())
     ON CONFLICT (user_id) DO UPDATE SET greeting_on = $2, greeting_text = $3, greeting_days = $4, away_on = $5, away_text = $6,
       away_mode = $7, hours = $8::jsonb, tz_offset_min = $9, updated_at = now()`,
    [userId, next.greeting_on, next.greeting_text, next.greeting_days, next.away_on, next.away_text, next.away_mode, JSON.stringify(next.hours), next.tz_offset_min],
  );
  return next;
}

/** Is the business open right now (in its own time zone)? No hours set = always open. */
function isOpen(s, now = new Date()) {
  const hours = s.hours || {};
  if (!Object.keys(hours).length) return true;
  const local = new Date(now.getTime() + s.tz_offset_min * 60000);
  const day = DAYS[local.getUTCDay()];
  const min = local.getUTCHours() * 60 + local.getUTCMinutes();
  return (hours[day] || []).some(([a, b]) => min >= a && min < b);
}

// ------------------------------------------------------------------ quick replies
const replyJson = (r) => ({ id: Number(r.id), shortcut: r.shortcut, text: r.text });

async function listReplies(userId) {
  return (await db.many('SELECT * FROM quick_replies WHERE user_id = $1 ORDER BY shortcut', [userId])).map(replyJson);
}

function parseShortcut(raw) {
  const s = String(raw || '').trim().replace(/^\//, '').toLowerCase();
  if (!/^[a-z0-9_]{1,32}$/.test(s)) throw badRequest('invalid_input', 'Shortcut: 1–32 letters, numbers or _');
  return s;
}

async function addReply(userId, body = {}) {
  const shortcut = parseShortcut(body.shortcut);
  const text = v.str(String(body.text || ''), { field: 'text', min: 1, max: 4000 });
  const n = await db.one('SELECT count(*)::int AS n FROM quick_replies WHERE user_id = $1', [userId]);
  if (n.n >= MAX_REPLIES) throw badRequest('too_many', `Up to ${MAX_REPLIES} quick replies`);
  const r = await db.one(
    `INSERT INTO quick_replies (user_id, shortcut, text) VALUES ($1, $2, $3) ON CONFLICT (user_id, shortcut) DO NOTHING RETURNING *`,
    [userId, shortcut, text],
  );
  if (!r) throw badRequest('shortcut_taken', `You already have /${shortcut}`);
  return replyJson(r);
}

async function updateReply(userId, idRaw, body = {}) {
  const id = v.id(idRaw, 'reply_id');
  const cur = await db.one('SELECT * FROM quick_replies WHERE id = $1 AND user_id = $2', [id, userId]);
  if (!cur) throw notFound('not_found', 'Quick reply not found');
  const shortcut = body.shortcut !== undefined ? parseShortcut(body.shortcut) : cur.shortcut;
  const text = body.text !== undefined ? v.str(String(body.text), { field: 'text', min: 1, max: 4000 }) : cur.text;
  try {
    return replyJson(await db.one('UPDATE quick_replies SET shortcut = $3, text = $4 WHERE id = $1 AND user_id = $2 RETURNING *', [id, userId, shortcut, text]));
  } catch (e) {
    if (e.code === '23505') throw badRequest('shortcut_taken', `You already have /${shortcut}`);
    throw e;
  }
}

async function deleteReply(userId, idRaw) {
  await db.query('DELETE FROM quick_replies WHERE id = $1 AND user_id = $2', [v.id(idRaw, 'reply_id'), userId]);
  return { ok: true };
}

// ------------------------------------------------------------------ automatic replies
async function autoReply({ chatId, message, memberIds, senderId }) {
  if (!senderId || !message || message.type === 'system' || (message.meta && message.meta.auto)) return;
  const others = (memberIds || []).map(Number).filter((id) => id !== Number(senderId));
  if (others.length !== 1) return;
  const chat = await db.one('SELECT type FROM chats WHERE id = $1', [chatId]);
  if (!chat || chat.type !== 'private') return;
  const ownerId = others[0];
  const s = await db.one('SELECT * FROM business_settings WHERE user_id = $1 AND (greeting_on OR away_on)', [ownerId]);
  if (!s) return;
  const people = await db.many('SELECT id, is_bot FROM users WHERE id = ANY($1::bigint[])', [[ownerId, senderId]]);
  if (people.some((p) => p.is_bot)) return;
  const st = serialize(s);
  const messageService = require('./message.service'); // eslint-disable-line global-require
  const send = (text, kind) => messageService.sendMessage(ownerId, chatId, { text }, { skipRateLimit: true, meta: { auto: kind } });

  if (st.greeting_on) {
    const before = await db.one(
      `SELECT 1 AS x FROM messages WHERE chat_id = $1 AND sender_id = $2 AND id <> $3 AND created_at > now() - make_interval(days => $4) LIMIT 1`,
      [chatId, senderId, message.id, st.greeting_days],
    );
    const greeted = await db.one(
      `SELECT 1 AS x FROM business_auto_log WHERE owner_id = $1 AND peer_id = $2 AND kind = 'greeting' AND sent_at > now() - make_interval(days => $3)`,
      [ownerId, senderId, st.greeting_days],
    );
    if (!before && !greeted) {
      await mark(ownerId, senderId, 'greeting');
      await send(st.greeting_text, 'greeting');
      return; // the greeting already answers; don't stack an away message on top
    }
  }
  if (st.away_on) {
    const away = st.away_mode === 'always' || (st.away_mode === 'offline' ? !presence.isOnline(ownerId) : !isOpen(st));
    if (!away) return;
    const recent = await db.one(
      `SELECT 1 AS x FROM business_auto_log WHERE owner_id = $1 AND peer_id = $2 AND kind = 'away' AND sent_at > now() - make_interval(hours => $3)`,
      [ownerId, senderId, AWAY_GAP_HOURS],
    );
    if (recent) return;
    await mark(ownerId, senderId, 'away');
    await send(st.away_text, 'away');
  }
}

async function mark(ownerId, peerId, kind) {
  await db.query(
    `INSERT INTO business_auto_log (owner_id, peer_id, kind) VALUES ($1, $2, $3)
     ON CONFLICT (owner_id, peer_id, kind) DO UPDATE SET sent_at = now()`,
    [ownerId, peerId, kind],
  );
}

bus.on('message:new', (e) => {
  autoReply(e).catch((err) => console.error('business auto-reply', err.message)); // eslint-disable-line no-console
});

module.exports = { get, set, isOpen, listReplies, addReply, updateReply, deleteReply, autoReply, DAYS };
