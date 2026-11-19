'use strict';

/**
 * @HushaviaNews — the official channel: app updates, new features and announcements.
 * Created once on start (owned by the official support account, verified, public).
 * Everyone who signs up is subscribed (they can leave); existing users are added once.
 * Admins post to it from the admin panel (Broadcast → Hushavia News).
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const db = require('../db');
const config = require('../config');

const USERNAME = 'HushaviaNews';
let cached = null; // { chatId, ownerId }
// the automated tests make and count chats all the time: there, nobody is added unless a test asks
let autoFollow = !process.env.NODE_TEST_CONTEXT;
function setAutoFollow(on) {
  autoFollow = !!on;
}

async function ensureAvatar(chatId, ownerId) {
  const src = path.join(__dirname, '..', '..', 'assets', 'bots', `${USERNAME}.png`);
  if (!fs.existsSync(src)) return;
  const c = await db.one('SELECT avatar_media_id FROM chats WHERE id = $1', [chatId]);
  if (c && c.avatar_media_id) return;
  const dir = path.join(config.uploadDir, 'bots');
  fs.mkdirSync(dir, { recursive: true });
  const dst = path.join(dir, `sysbot-${USERNAME}-v1.png`);
  fs.copyFileSync(src, dst);
  const m = await db.one(
    `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name, width, height, is_public)
     VALUES ($1, 'avatar', 'image/png', $2, $3, $4, 512, 512, TRUE) RETURNING id`,
    [ownerId, fs.statSync(dst).size, path.relative(config.uploadDir, dst), `sysbot-${USERNAME}-v1.png`],
  );
  await db.query('UPDATE chats SET avatar_media_id = $2 WHERE id = $1', [chatId, m.id]);
}

async function ensure() {
  if (cached) return cached;
  const ownerId = await require('./sysbots.service').ensureOne('support'); // eslint-disable-line global-require
  let chat = await db.one(`SELECT id FROM chats WHERE type = 'channel' AND lower(username) = lower($1)`, [USERNAME]);
  if (!chat) {
    chat = await db.tx(async (c) => {
      const r = (await c.query(
        `INSERT INTO chats (type, title, description, created_by, invite_code, username, is_public, is_verified)
         VALUES ('channel', 'Hushavia News', 'Official news from Hushavia: updates, new features and tips.', $1, $2, $3, TRUE, TRUE)
         ON CONFLICT DO NOTHING RETURNING id`,
        [ownerId, crypto.randomBytes(9).toString('base64url'), USERNAME],
      )).rows[0];
      if (r) await c.query(`INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'owner') ON CONFLICT DO NOTHING`, [r.id, ownerId]);
      return r;
    });
    if (!chat) chat = await db.one(`SELECT id FROM chats WHERE type = 'channel' AND lower(username) = lower($1)`, [USERNAME]);
  }
  await ensureAvatar(chat.id, ownerId).catch(() => null);
  // the official channel shows "Official channel" instead of a subscriber count (once; the admin can show it again)
  const hid = await db.one(`SELECT 1 AS x FROM sys_flags WHERE key = 'news_hide_count'`);
  if (!hid) {
    await db.query('UPDATE chats SET hide_count = TRUE WHERE id = $1', [chat.id]);
    await db.query(`INSERT INTO sys_flags (key) VALUES ('news_hide_count') ON CONFLICT DO NOTHING`);
  }
  cached = { chatId: Number(chat.id), ownerId };
  // existing users: added once (someone who leaves later is never added again)
  const done = await db.one(`SELECT 1 AS x FROM sys_flags WHERE key = 'news_backfill'`);
  if (!done && autoFollow) {
    await db.query(
      `INSERT INTO chat_members (chat_id, user_id, role)
       SELECT $1, u.id, 'member' FROM users u WHERE u.status = 'active' AND NOT u.is_bot
       ON CONFLICT DO NOTHING`,
      [cached.chatId],
    );
    await db.query(`INSERT INTO sys_flags (key) VALUES ('news_backfill') ON CONFLICT DO NOTHING`);
  }
  return cached;
}

/** A new account follows the news channel (it can leave like any channel). */
async function subscribe(userId) {
  if (!autoFollow) return;
  const { chatId } = await ensure();
  await db.query(`INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING`, [chatId, userId]);
}

/** Admin panel: publish a post. */
async function post(body = {}) {
  const text = String(body.text || '').trim();
  if (text.length < 2 || text.length > 4000) throw require('../utils/errors').badRequest('invalid_input', 'Write the post (2–4000 characters)'); // eslint-disable-line global-require
  const { chatId, ownerId } = await ensure();
  const m = await require('./message.service').sendMessage(ownerId, chatId, { type: 'text', text, silent: body.silent === true }, { skipRateLimit: true }); // eslint-disable-line global-require
  return { ok: true, message_id: m.id, chat_id: chatId };
}

async function info() {
  const { chatId } = await ensure();
  const r = await db.one('SELECT member_count, hide_count FROM chats WHERE id = $1', [chatId]);
  const posts = await db.many(
    `SELECT id, text, created_at, views_count FROM messages WHERE chat_id = $1 AND deleted_at IS NULL AND type = 'text' ORDER BY id DESC LIMIT 10`,
    [chatId],
  );
  return { chat_id: chatId, username: USERNAME, subscribers: Number(r.member_count || 0), hide_count: !!r.hide_count, posts };
}

/** Admin panel: show or hide the subscriber count of the official channel. */
async function setHideCount(on) {
  const { chatId } = await ensure();
  await db.query('UPDATE chats SET hide_count = $2 WHERE id = $1', [chatId, !!on]);
  const ids = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId])).map((x) => Number(x.user_id));
  require('../bus').emit('chat:updated', { chatId, memberIds: ids }); // eslint-disable-line global-require
  return { ok: true, hide_count: !!on };
}

module.exports = { ensure, subscribe, post, info, setHideCount, setAutoFollow, USERNAME };
