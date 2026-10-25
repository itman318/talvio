'use strict';

/**
 * Bots & mini apps — the Talvio Bot API (POST /api/bot/v1/<method>, token in the Authorization header).
 *
 *   POST https://your-server/api/bot/v1/<method>   Authorization: Bearer <TOKEN>   (JSON, form or multipart)
 *   → { ok: true, data } | { ok: false, error: { code, message } }
 *
 * Methods: me, updates (long polling), webhook.set, webhook.delete, webhook.info,
 * messages.send, photos.send, files.send, messages.edit, messages.edit-buttons, messages.delete,
 * buttons.answer, commands.set, commands.get, commands.delete, chats.get.
 *
 * Updates: message (private chats; groups → commands, @mentions and replies unless privacy is off),
 * callback_query (inline buttons), web_app_data (mini app sent data).
 *
 * Mini apps: a web_app button opens the URL inside the app with `#talvioData=<init data>`.
 * Verify it on your server:  secret = HMAC_SHA256(key="TalvioMiniApp", msg=SHA256_HEX(bot_token))
 *                           hash   = HEX(HMAC_SHA256(key=secret, msg=data_check_string))
 * where data_check_string = all fields except hash, sorted, "key=value" joined by "\n".
 */
const crypto = require('crypto');
const { EventEmitter } = require('events');
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const chatService = require('./chat.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { randomToken, sha256 } = require('../utils/crypto');
const { AppError, badRequest, forbidden, notFound, conflict, unauthorized } = require('../utils/errors');

const USERNAME_RE = /^[A-Za-z][A-Za-z0-9_]{1,28}bot$/i;
const MAX_UPDATES_KEPT = 1000;
const waiters = new EventEmitter();
waiters.setMaxListeners(0);

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}
const unix = (d) => Math.floor(new Date(d).getTime() / 1000);

// ------------------------------------------------------------------ bot management (owner side)
function serializeBot(u, b, { pending = 0 } = {}) {
  return {
    id: u.id,
    name: u.first_name,
    username: u.username,
    about: b.about,
    commands: b.commands || [],
    menu_url: b.menu_url,
    group_privacy: b.group_privacy,
    status: b.status,
    disabled_reason: b.disabled_reason,
    webhook_url: b.webhook_url,
    webhook_error: b.webhook_error,
    pending_updates: pending,
    avatar_url: userService.avatarUrl(u.avatar_media_id),
    created_at: iso(b.created_at),
    last_used_at: iso(b.last_used_at),
  };
}

function newToken(botId) {
  return `tlv_${botId}_${randomToken(24).replace(/[^A-Za-z0-9]/g, '').slice(0, 32)}`;
}

async function createBot(ownerId, body = {}) {
  await settings.requireFeature('feature_bots', 'Bots');
  const name = v.str(body.name, { field: 'name', min: 1, max: 64, required: true });
  const username = String(body.username || '').trim().replace(/^@/, '');
  if (!USERNAME_RE.test(username)) throw badRequest('invalid_username', 'Bot username must be 3–32 letters/numbers and end with "bot", e.g. weather_bot');
  await chatService.assertNotReserved(username);
  if (await chatService.usernameTaken(username)) throw conflict('username_taken', 'This username is taken');
  const max = await settings.get('max_bots_per_user');
  const n = await db.one('SELECT count(*)::int AS n FROM bots WHERE owner_id = $1', [ownerId]);
  if (n.n >= max) throw forbidden('too_many_bots', `You can have up to ${max} bots`);
  rateLimit.enforce(`bot:new:${ownerId}`, 5, 60 * 60 * 1000, 'You created too many bots. Try again later.');
  const { user, token } = await db.tx(async (c) => {
    const u = (await c.query(
      `INSERT INTO users (phone, first_name, username, is_bot, privacy_phone, privacy_group_add, privacy_calls)
       VALUES (NULL, $1, $2, TRUE, 'nobody', 'everyone', 'nobody') RETURNING *`,
      [name, username],
    )).rows[0];
    const t = newToken(u.id);
    await c.query('INSERT INTO bots (user_id, owner_id, token_hash, about) VALUES ($1, $2, $3, $4)', [
      u.id,
      ownerId,
      sha256(t),
      v.str(body.about, { field: 'about', max: 512 }) || '',
    ]);
    return { user: u, token: t };
  });
  const b = await db.one('SELECT * FROM bots WHERE user_id = $1', [user.id]);
  return { bot: serializeBot(user, b), token };
}

async function ownedBot(ownerId, botIdRaw) {
  const row = await db.one(
    `SELECT u.*, b.* FROM bots b JOIN users u ON u.id = b.user_id WHERE b.user_id = $1 AND b.owner_id = $2 AND u.status <> 'deleted'`,
    [v.id(botIdRaw, 'bot_id'), ownerId],
  );
  if (!row) throw notFound('bot_not_found', 'Bot not found');
  return row;
}

async function listMyBots(ownerId) {
  const rows = await db.many(
    `SELECT u.*, b.*, (SELECT count(*)::int FROM bot_updates x WHERE x.bot_id = b.user_id) AS pending
     FROM bots b JOIN users u ON u.id = b.user_id WHERE b.owner_id = $1 AND u.status <> 'deleted' ORDER BY b.created_at DESC`,
    [ownerId],
  );
  return rows.map((r) => serializeBot(r, r, { pending: r.pending }));
}

function parseCommands(raw) {
  if (!Array.isArray(raw) || raw.length > 100) throw badRequest('invalid_commands', 'commands must be a list of up to 100 items');
  return raw.map((c) => {
    const command = String((c && c.command) || '').trim().replace(/^\//, '').toLowerCase();
    if (!/^[a-z0-9_]{1,32}$/.test(command)) throw badRequest('invalid_commands', `Invalid command "${command}"`);
    const description = v.str(String((c && c.description) || ''), { field: 'description', min: 1, max: 256 });
    return { command, description };
  });
}

function parseHttpsUrl(raw, field) {
  if (raw === null || raw === '') return null;
  let u;
  try {
    u = new URL(String(raw));
  } catch (_) {
    throw badRequest('invalid_url', `${field} must be a valid https:// URL`);
  }
  if (u.protocol !== 'https:' && !(process.env.NODE_ENV !== 'production' && u.protocol === 'http:')) {
    throw badRequest('invalid_url', `${field} must start with https://`);
  }
  return u.toString().slice(0, 500);
}

async function updateBot(ownerId, botIdRaw, body = {}) {
  const bot = await ownedBot(ownerId, botIdRaw);
  if (body.name !== undefined) {
    await db.query('UPDATE users SET first_name = $2, updated_at = now() WHERE id = $1', [bot.user_id, v.str(body.name, { field: 'name', min: 1, max: 64 })]);
  }
  const about = body.about === undefined ? null : v.str(body.about, { field: 'about', max: 512 }) || '';
  const commands = body.commands === undefined ? null : JSON.stringify(parseCommands(body.commands));
  const menu = body.menu_url === undefined ? undefined : parseHttpsUrl(body.menu_url, 'menu_url');
  const privacy = body.group_privacy === undefined ? null : v.bool(body.group_privacy, 'group_privacy');
  await db.query(
    `UPDATE bots SET about = COALESCE($2, about), commands = COALESCE($3::jsonb, commands),
       menu_url = CASE WHEN $4 THEN $5 ELSE menu_url END, group_privacy = COALESCE($6, group_privacy) WHERE user_id = $1`,
    [bot.user_id, about, commands, menu !== undefined, menu === undefined ? null : menu, privacy],
  );
  bus.emit('user:updated', { userId: bot.user_id });
  const r = await ownedBot(ownerId, bot.user_id);
  return serializeBot(r, r);
}

async function regenerateToken(ownerId, botIdRaw) {
  const bot = await ownedBot(ownerId, botIdRaw);
  const token = newToken(bot.user_id);
  await db.query('UPDATE bots SET token_hash = $2 WHERE user_id = $1', [bot.user_id, sha256(token)]);
  return { token };
}

async function deleteBot(ownerId, botIdRaw) {
  const bot = await ownedBot(ownerId, botIdRaw);
  await db.tx(async (c) => {
    await c.query(`UPDATE users SET status = 'deleted', username = NULL, first_name = 'Deleted Bot', updated_at = now() WHERE id = $1`, [bot.user_id]);
    await c.query(`UPDATE bots SET status = 'disabled', token_hash = $2, webhook_url = NULL WHERE user_id = $1`, [bot.user_id, sha256(randomToken(32))]);
    await c.query('DELETE FROM bot_updates WHERE bot_id = $1', [bot.user_id]);
  });
  return { ok: true };
}

// ------------------------------------------------------------------ auth for the Bot API
async function authenticate(token) {
  if (typeof token !== 'string' || !/^tlv_\d+_[A-Za-z0-9]{20,}$/.test(token)) throw unauthorized('invalid_token', 'Invalid bot token');
  const row = await db.one(
    `SELECT u.*, b.*, u.status AS user_status, o.status AS owner_status
     FROM bots b JOIN users u ON u.id = b.user_id JOIN users o ON o.id = b.owner_id
     WHERE b.token_hash = $1`,
    [sha256(token)],
  );
  if (!row || row.user_status === 'deleted') throw unauthorized('invalid_token', 'Invalid bot token');
  if (row.status !== 'active' || row.owner_status !== 'active') {
    throw forbidden('bot_disabled', row.disabled_reason ? `Bot disabled: ${row.disabled_reason}` : 'This bot is disabled');
  }
  // (row.status is the bots.status column — b.* comes after u.*)
  if (!(await settings.get('feature_bots'))) throw forbidden('feature_disabled', 'Bots are turned off right now');
  db.query('UPDATE bots SET last_used_at = now() WHERE user_id = $1', [row.user_id]).catch(() => {});
  return row;
}

// ------------------------------------------------------------------ updates queue
function botUser(u) {
  return { id: u.id, is_bot: !!u.is_bot, first_name: u.first_name || '', last_name: u.last_name || '', username: u.username || null };
}

async function enqueue(botId, payload) {
  const r = await db.one('INSERT INTO bot_updates (bot_id, payload) VALUES ($1, $2) RETURNING id', [botId, JSON.stringify(payload)]);
  // keep the queue bounded for bots that never read it
  await db.query(
    `DELETE FROM bot_updates WHERE bot_id = $1 AND id <= (SELECT id FROM bot_updates WHERE bot_id = $1 ORDER BY id DESC OFFSET $2 LIMIT 1)`,
    [botId, MAX_UPDATES_KEPT],
  );
  waiters.emit(`bot:${botId}`);
  const b = await db.one('SELECT webhook_url FROM bots WHERE user_id = $1', [botId]);
  if (b && b.webhook_url) deliverWebhook(botId).catch(() => {});
  return r.id;
}

const delivering = new Set();
/** POSTs queued updates to the bot's webhook one by one; stops at the first failure (retried by the scheduler). */
async function deliverWebhook(botId) {
  if (delivering.has(botId)) return;
  delivering.add(botId);
  try {
    for (;;) {
      const b = await db.one('SELECT webhook_url, webhook_secret FROM bots WHERE user_id = $1 AND status = $2', [botId, 'active']);
      if (!b || !b.webhook_url) return;
      const u = await db.one('SELECT * FROM bot_updates WHERE bot_id = $1 ORDER BY id LIMIT 1', [botId]);
      if (!u) return;
      try {
        const res = await fetch(b.webhook_url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(b.webhook_secret ? { 'X-Talvio-Webhook-Secret': b.webhook_secret } : {}),
          },
          body: JSON.stringify({ update_id: Number(u.id), ...u.payload }),
          signal: AbortSignal.timeout(10000),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        await db.query('DELETE FROM bot_updates WHERE id = $1', [u.id]);
        await db.query('UPDATE bots SET webhook_error = NULL WHERE user_id = $1 AND webhook_error IS NOT NULL', [botId]);
      } catch (err) {
        await db.query('UPDATE bot_updates SET attempts = attempts + 1 WHERE id = $1', [u.id]);
        await db.query('UPDATE bots SET webhook_error = $2, webhook_error_at = now() WHERE user_id = $1', [botId, String(err.message).slice(0, 300)]);
        if (u.attempts + 1 >= 20) await db.query('DELETE FROM bot_updates WHERE id = $1', [u.id]); // give up on this one
        return;
      }
    }
  } finally {
    delivering.delete(botId);
  }
}

/** Scheduler: retry webhooks that failed, drop updates nobody read for a day. */
async function sweep() {
  await db.query(`DELETE FROM bot_updates WHERE created_at < now() - interval '24 hours'`);
  await db.query(`DELETE FROM bot_callback_queries WHERE created_at < now() - interval '1 hour'`);
  const rows = await db.many(
    `SELECT DISTINCT b.user_id FROM bots b JOIN bot_updates u ON u.bot_id = b.user_id WHERE b.webhook_url IS NOT NULL AND b.status = 'active'`,
  );
  for (const r of rows) await deliverWebhook(r.user_id);
}

async function toBotMessage(m, chatRow, extra = {}) {
  const from = m.sender_id ? await db.one('SELECT * FROM users WHERE id = $1', [m.sender_id]) : null;
  const chat = { id: chatRow.id, type: chatRow.type };
  if (chatRow.type !== 'private') chat.title = chatRow.title;
  else if (from) Object.assign(chat, { first_name: from.first_name, last_name: from.last_name, username: from.username });
  const out = {
    message_id: Number(m.id),
    from: from ? botUser(from) : undefined,
    chat,
    date: unix(m.created_at),
    ...extra,
  };
  if (m.text) out[m.type === 'text' ? 'text' : 'caption'] = m.text;
  if (m.reply_to_id) out.reply_to_message = { message_id: Number(m.reply_to_id) };
  if (m.topic_id) out.message_thread_id = Number(m.topic_id);
  if (m.media_id && ['image', 'video', 'voice', 'file'].includes(m.type)) {
    const md = await db.one('SELECT id, mime, size_bytes, original_name FROM media WHERE id = $1', [m.media_id]);
    if (md) {
      const file = { file_id: String(md.id), file_size: Number(md.size_bytes), mime_type: md.mime, file_name: md.original_name };
      out[{ image: 'photo', video: 'video', voice: 'voice', file: 'document' }[m.type]] = file;
    }
  }
  if (m.type === 'location' && m.meta && m.meta.location) out.location = { latitude: m.meta.location.lat, longitude: m.meta.location.lng };
  return out;
}

/** bus message:new → updates for bots that are members of the chat. */
async function onNewMessage({ chatId, message, memberIds, senderId }) {
  if (!message || ['system', 'call'].includes(message.type) || message.thread_id) return;
  const bots = await db.many(
    `SELECT u.id, u.username, b.group_privacy FROM users u JOIN bots b ON b.user_id = u.id
     WHERE u.id = ANY($1::bigint[]) AND u.is_bot AND b.status = 'active' AND u.id <> $2`,
    [memberIds, senderId || 0],
  );
  if (!bots.length) return;
  const chat = await db.one('SELECT id, type, title FROM chats WHERE id = $1', [chatId]);
  if (!chat || chat.type === 'channel') return;
  const sender = senderId ? await db.one('SELECT is_bot FROM users WHERE id = $1', [senderId]) : null;
  if (sender && sender.is_bot) return; // bots don't see each other's messages
  const row = await db.one('SELECT * FROM messages WHERE id = $1', [message.id]);
  const text = String(row.text || '');
  const botfather = require('./botforge.service'); // eslint-disable-line global-require
  for (const b of bots) {
    if (botfather.isBotForge(b.id)) {
      if (chat.type === 'private' && senderId) await botfather.onMessage(senderId, chat.id, row);
      continue;
    }
    if (chat.type === 'group' && b.group_privacy) {
      const mentioned = b.username && text.toLowerCase().includes(`@${b.username.toLowerCase()}`);
      let repliedToBot = false;
      if (row.reply_to_id) {
        const r = await db.one('SELECT sender_id FROM messages WHERE id = $1', [row.reply_to_id]);
        repliedToBot = !!r && r.sender_id === b.id;
      }
      if (!text.startsWith('/') && !mentioned && !repliedToBot) continue;
    }
    await enqueue(b.id, { message: await toBotMessage(row, chat) });
  }
}

bus.on('message:new', (e) => {
  onNewMessage(e).catch((err) => console.error('bot update error', err)); // eslint-disable-line no-console
});

async function getUpdates(bot, q = {}) {
  if (bot.webhook_url) throw new AppError(409, 'webhook_active', 'can’t use getUpdates while a webhook is set; call deleteWebhook first');
  const offset = q.offset !== undefined ? parseInt(q.offset, 10) : 0;
  const limit = Math.min(100, Math.max(1, parseInt(q.limit, 10) || 100));
  const timeout = Math.min(50, Math.max(0, parseInt(q.timeout, 10) || 0));
  if (offset > 0) await db.query('DELETE FROM bot_updates WHERE bot_id = $1 AND id < $2', [bot.user_id, offset]);
  const read = () => db.many('SELECT id, payload FROM bot_updates WHERE bot_id = $1 AND id >= $2 ORDER BY id LIMIT $3', [bot.user_id, Math.max(0, offset), limit]);
  let rows = await read();
  if (!rows.length && timeout > 0) {
    await new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        waiters.removeListener(`bot:${bot.user_id}`, done);
        resolve();
      };
      const t = setTimeout(done, timeout * 1000);
      waiters.once(`bot:${bot.user_id}`, done);
    });
    rows = await read();
  }
  return rows.map((r) => ({ update_id: Number(r.id), ...r.payload }));
}

// ------------------------------------------------------------------ inline keyboards
function parseReplyMarkup(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  let m = raw;
  if (typeof m === 'string') {
    try {
      m = JSON.parse(m);
    } catch (_) {
      throw badRequest('invalid_markup', 'reply_markup must be JSON');
    }
  }
  if (m && m.remove_keyboard === true) return { remove_keyboard: true };
  if (m && Array.isArray(m.keyboard)) return parseReplyKeyboard(m);
  if (!m || !Array.isArray(m.inline_keyboard)) throw badRequest('invalid_markup', 'reply_markup needs inline_keyboard, keyboard or remove_keyboard');
  if (m.inline_keyboard.length > 10) throw badRequest('invalid_markup', 'At most 10 rows of buttons');
  const rows = m.inline_keyboard.map((row) => {
    if (!Array.isArray(row) || row.length === 0 || row.length > 8) throw badRequest('invalid_markup', 'Each row needs 1–8 buttons');
    return row.map((btn) => {
      const text = v.str(String((btn && btn.text) || ''), { field: 'button text', min: 1, max: 64 });
      if (btn.callback_data !== undefined) {
        const data = String(btn.callback_data);
        if (!data || Buffer.byteLength(data) > 64) throw badRequest('invalid_markup', 'callback_data must be 1–64 bytes');
        return { text, callback_data: data };
      }
      if (btn.url !== undefined) {
        let u;
        try {
          u = new URL(String(btn.url));
        } catch (_) {
          throw badRequest('invalid_markup', 'Invalid button url');
        }
        if (!['http:', 'https:', 'tg:'].includes(u.protocol)) throw badRequest('invalid_markup', 'Button url must be http(s)');
        return { text, url: u.toString() };
      }
      if (btn.web_app && btn.web_app.url) return { text, web_app: { url: parseHttpsUrl(btn.web_app.url, 'web_app.url') } };
      throw badRequest('invalid_markup', 'Each button needs callback_data, url or web_app');
    });
  });
  return { inline_keyboard: rows };
}

/** Reply keyboard: big text buttons that replace the phone keyboard (like Telegram's ReplyKeyboardMarkup). */
function parseReplyKeyboard(m) {
  if (m.keyboard.length === 0 || m.keyboard.length > 12) throw badRequest('invalid_markup', 'A keyboard needs 1–12 rows');
  const rows = m.keyboard.map((row) => {
    if (!Array.isArray(row) || row.length === 0 || row.length > 8) throw badRequest('invalid_markup', 'Each row needs 1–8 buttons');
    return row.map((btn) => {
      const raw = typeof btn === 'string' ? { text: btn } : btn || {};
      const text = v.str(String(raw.text || ''), { field: 'button text', min: 1, max: 64 });
      const out = { text };
      if (raw.request_contact === true) out.request_contact = true;
      else if (raw.request_location === true) out.request_location = true;
      return out;
    });
  });
  const out = { keyboard: rows, resize_keyboard: m.resize_keyboard !== false, one_time_keyboard: m.one_time_keyboard === true };
  if (m.input_field_placeholder) out.input_field_placeholder = v.str(String(m.input_field_placeholder), { field: 'input_field_placeholder', max: 64 });
  if (m.is_persistent === true) out.is_persistent = true;
  return out;
}

const CHAT_ACTIONS = ['typing', 'uploading_photo', 'uploading_video', 'uploading_file', 'recording_voice', 'choosing_sticker'];

async function sendChatAction(bot, p) {
  const chat = await botChat(bot, p.chat_id);
  const action = CHAT_ACTIONS.includes(p.action) ? p.action : 'typing';
  if (!rateLimit.hit(`botaction:${bot.user_id}:${chat.id}`, 1, 2000).allowed) return true;
  const ids = (await chatService.memberIds(chat.id)).filter((id) => id !== bot.user_id);
  bus.emit('rt:emit', { event: 'typing', payload: { chat_id: chat.id, user_id: bot.user_id, action }, userIds: ids });
  return true;
}

function bool(x) {
  return x === true || x === 'true';
}

async function sendPoll(bot, p) {
  const messageService = require('./message.service');
  const chat = await botChat(bot, p.chat_id);
  let options = p.options;
  if (typeof options === 'string') options = JSON.parse(options);
  const poll = {
    question: p.question,
    options,
    anonymous: p.is_anonymous === undefined ? true : bool(p.is_anonymous),
    multiple: bool(p.allows_multiple_answers),
    quiz: p.type === 'quiz',
    correct_option: p.correct_option_id === undefined ? undefined : Number(p.correct_option_id),
    explanation: p.explanation,
  };
  if (p.open_period) poll.close_in_sec = Number(p.open_period);
  const msg = await messageService.sendMessage(bot.user_id, chat.id, { type: 'poll', poll }, { replyMarkup: parseReplyMarkup(p.reply_markup) });
  return toBotMessage(await db.one('SELECT * FROM messages WHERE id = $1', [msg.id]), chat);
}

async function sendLocation(bot, p) {
  const messageService = require('./message.service');
  const chat = await botChat(bot, p.chat_id);
  const body = { type: 'location', location: { lat: Number(p.latitude), lng: Number(p.longitude), title: p.title || '' } };
  if (p.reply_to_message_id) body.reply_to_id = p.reply_to_message_id;
  const msg = await messageService.sendMessage(bot.user_id, chat.id, body, { replyMarkup: parseReplyMarkup(p.reply_markup) });
  return toBotMessage(await db.one('SELECT * FROM messages WHERE id = $1', [msg.id]), chat);
}

async function forwardMessage(bot, p) {
  const messageService = require('./message.service');
  await botChat(bot, p.from_chat_id);
  const to = await botChat(bot, p.chat_id);
  await messageService.forwardMessages(bot.user_id, { from_chat_id: p.from_chat_id, message_ids: [p.message_id], to_chat_ids: [to.id] });
  const row = await db.one('SELECT * FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id DESC LIMIT 1', [to.id, bot.user_id]);
  return toBotMessage(row, to);
}

async function getChatMember(bot, p) {
  const chat = await botChat(bot, p.chat_id);
  const row = await db.one(
    `SELECT u.*, cm.role FROM chat_members cm JOIN users u ON u.id = cm.user_id WHERE cm.chat_id = $1 AND cm.user_id = $2`,
    [chat.id, v.id(p.user_id, 'user_id')],
  );
  if (!row) return { status: 'left' };
  const status = row.role === 'owner' ? 'creator' : row.role === 'admin' ? 'administrator' : 'member';
  return { status, user: botUser(row) };
}

async function setProfile(bot, p) {
  const sets = [];
  const vals = [bot.user_id];
  if (p.description !== undefined) {
    vals.push(v.str(String(p.description), { field: 'description', max: 512 }) || '');
    sets.push(`about = $${vals.length}`);
  }
  if (p.menu_url !== undefined) {
    vals.push(p.menu_url ? parseHttpsUrl(p.menu_url, 'menu_url') : null);
    sets.push(`menu_url = $${vals.length}`);
  }
  if (sets.length) await db.query(`UPDATE bots SET ${sets.join(', ')} WHERE user_id = $1`, vals);
  if (p.name !== undefined) {
    const name = v.str(String(p.name), { field: 'name', min: 1, max: 64 });
    await db.query('UPDATE users SET first_name = $2 WHERE id = $1', [bot.user_id, name]);
  }
  bus.emit('user:updated', { userId: bot.user_id });
  return true;
}

// ------------------------------------------------------------------ Bot API methods
async function botChat(bot, chatIdRaw) {
  try {
    return await chatService.requireMember(chatIdRaw, bot.user_id);
  } catch (_) {
    throw badRequest('chat_not_found', 'chat not found (the user must start the bot first, or add it to the group)');
  }
}

async function sendMessage(bot, p, kind = 'text', file = null) {
  const messageService = require('./message.service');
  const chat = await botChat(bot, p.chat_id);
  const body = { type: kind, text: kind === 'text' ? p.text : p.caption || '' };
  if (p.reply_to_message_id) body.reply_to_id = p.reply_to_message_id;
  if (p.message_thread_id) body.topic_id = p.message_thread_id;
  if (p.disable_notification === true || p.disable_notification === 'true') body.silent = true;
  if (file) {
    const media = await require('./media.service').registerUpload(bot.user_id, file, { kind: kind === 'image' ? 'image' : 'file' });
    body.media_id = media.id;
  }
  const msg = await messageService.sendMessage(bot.user_id, chat.id, body, { replyMarkup: parseReplyMarkup(p.reply_markup) });
  const row = await db.one('SELECT * FROM messages WHERE id = $1', [msg.id]);
  return toBotMessage(row, chat);
}

async function botMessage(bot, p) {
  const chat = await botChat(bot, p.chat_id);
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND chat_id = $2 AND deleted_at IS NULL', [v.id(p.message_id, 'message_id'), chat.id]);
  if (!m) throw badRequest('message_not_found', 'message to edit not found');
  if (m.sender_id !== bot.user_id) throw badRequest('cannot_edit', 'message can’t be edited');
  return { chat, m };
}

async function emitEdited(chat, messageId) {
  const messageService = require('./message.service');
  const map = await messageService.serializeByIds(0, [messageId]);
  bus.emit('message:edited', { chatId: chat.id, message: map.get(messageId), memberIds: await chatService.memberIds(chat.id) });
}

async function editMessageText(bot, p) {
  const { chat, m } = await botMessage(bot, p);
  const text = v.str(p.text, { field: 'text', min: 1, max: 4096, required: true });
  const markup = p.reply_markup === undefined ? m.reply_markup : parseReplyMarkup(p.reply_markup);
  const r = await db.one('UPDATE messages SET text = $2, reply_markup = $3, edited_at = now() WHERE id = $1 RETURNING *', [
    m.id,
    text,
    markup ? JSON.stringify(markup) : null,
  ]);
  await emitEdited(chat, m.id);
  return toBotMessage(r, chat);
}

async function editMessageReplyMarkup(bot, p) {
  const { chat, m } = await botMessage(bot, p);
  const markup = parseReplyMarkup(p.reply_markup);
  const r = await db.one('UPDATE messages SET reply_markup = $2 WHERE id = $1 RETURNING *', [m.id, markup ? JSON.stringify(markup) : null]);
  await emitEdited(chat, m.id);
  return toBotMessage(r, chat);
}

async function deleteMessage(bot, p) {
  const chat = await botChat(bot, p.chat_id);
  await require('./message.service').deleteMessages(bot.user_id, chat.id, { message_ids: [v.id(p.message_id, 'message_id')], for_everyone: true });
  return true;
}

async function answerCallbackQuery(bot, p) {
  const id = String(p.callback_query_id || '');
  const q = await db.one('SELECT * FROM bot_callback_queries WHERE id = $1 AND bot_id = $2', [id, bot.user_id]);
  if (!q) throw badRequest('query_not_found', 'query is too old or invalid');
  if (q.answered) return true;
  await db.query('UPDATE bot_callback_queries SET answered = TRUE WHERE id = $1', [id]);
  const text = p.text === undefined ? '' : v.str(String(p.text), { field: 'text', max: 200 }) || '';
  let url = null;
  if (p.url) url = parseHttpsUrl(p.url, 'url');
  bus.emit('rt:emit', {
    event: 'bot:callback_answer',
    payload: { callback_query_id: id, message_id: q.message_id, text, show_alert: p.show_alert === true || p.show_alert === 'true', url },
    userIds: [q.user_id],
  });
  return true;
}

async function setWebhook(bot, p) {
  const url = p.url ? parseHttpsUrl(p.url, 'url') : null;
  const secret = p.secret_token ? String(p.secret_token) : null;
  if (secret && !/^[A-Za-z0-9_-]{1,256}$/.test(secret)) throw badRequest('invalid_secret', 'secret_token: 1–256 characters A-Z a-z 0-9 _ -');
  await db.query('UPDATE bots SET webhook_url = $2, webhook_secret = $3, webhook_error = NULL WHERE user_id = $1', [bot.user_id, url, secret]);
  if (url) deliverWebhook(bot.user_id).catch(() => {});
  return true;
}

async function getWebhookInfo(bot) {
  const b = await db.one('SELECT webhook_url, webhook_error, webhook_error_at FROM bots WHERE user_id = $1', [bot.user_id]);
  const n = await db.one('SELECT count(*)::int AS n FROM bot_updates WHERE bot_id = $1', [bot.user_id]);
  return {
    url: b.webhook_url || '',
    pending_update_count: n.n,
    ...(b.webhook_error ? { last_error_message: b.webhook_error, last_error_date: unix(b.webhook_error_at) } : {}),
  };
}

/** Runs a Bot API method. `file` = multer upload for sendPhoto / sendDocument. */
async function callMethod(token, method, params = {}, file = null) {
  const bot = await authenticate(token);
  rateLimit.enforce(`botapi:${bot.user_id}`, 120, 10 * 1000, 'Too many requests — slow down');
  switch (method) {
    case 'me':
      return { ...botUser(bot), can_join_groups: true, can_read_all_group_messages: !bot.group_privacy, supports_inline_queries: false };
    case 'updates':
      return getUpdates(bot, params);
    case 'webhook.set':
      return setWebhook(bot, params);
    case 'webhook.delete':
      await db.query('UPDATE bots SET webhook_url = NULL, webhook_secret = NULL WHERE user_id = $1', [bot.user_id]);
      if (params.drop_pending_updates === true || params.drop_pending_updates === 'true') {
        await db.query('DELETE FROM bot_updates WHERE bot_id = $1', [bot.user_id]);
      }
      return true;
    case 'webhook.info':
      return getWebhookInfo(bot);
    case 'messages.send':
      return sendMessage(bot, params);
    case 'photos.send':
      if (!file) throw badRequest('file_required', 'upload the photo as multipart field "photo"');
      return sendMessage(bot, params, 'image', file);
    case 'files.send':
      if (!file) throw badRequest('file_required', 'upload the file as multipart field "document"');
      return sendMessage(bot, params, 'file', file);
    case 'messages.edit':
      return editMessageText(bot, params);
    case 'messages.edit-buttons':
      return editMessageReplyMarkup(bot, params);
    case 'messages.delete':
      return deleteMessage(bot, params);
    case 'buttons.answer':
      return answerCallbackQuery(bot, params);
    case 'commands.set': {
      let cmds = params.commands;
      if (typeof cmds === 'string') cmds = JSON.parse(cmds);
      await db.query('UPDATE bots SET commands = $2 WHERE user_id = $1', [bot.user_id, JSON.stringify(parseCommands(cmds))]);
      bus.emit('user:updated', { userId: bot.user_id });
      return true;
    }
    case 'commands.get':
      return (await db.one('SELECT commands FROM bots WHERE user_id = $1', [bot.user_id])).commands || [];
    case 'commands.delete':
      await db.query(`UPDATE bots SET commands = '[]' WHERE user_id = $1`, [bot.user_id]);
      return true;
    case 'chat.action':
      return sendChatAction(bot, params);
    case 'polls.send':
      return sendPoll(bot, params);
    case 'locations.send':
      return sendLocation(bot, params);
    case 'messages.forward':
      return forwardMessage(bot, params);
    case 'messages.pin': {
      const chat = await botChat(bot, params.chat_id);
      await require('./message.service').pinMessage(bot.user_id, chat.id, params.message_id);
      return true;
    }
    case 'messages.unpin': {
      const chat = await botChat(bot, params.chat_id);
      await require('./message.service').unpinMessage(bot.user_id, chat.id, params.message_id);
      return true;
    }
    case 'chats.member':
      return getChatMember(bot, params);
    case 'chats.member-count': {
      const chat = await botChat(bot, params.chat_id);
      return (await db.one('SELECT count(*)::int AS n FROM chat_members WHERE chat_id = $1', [chat.id])).n;
    }
    case 'me.set':
      return setProfile(bot, params);
    case 'chats.get': {
      const chat = await botChat(bot, params.chat_id);
      return { id: chat.id, type: chat.type, title: chat.title || undefined, description: chat.description || undefined };
    }
    default:
      throw new AppError(404, 'method_not_found', `Unknown method "${method}" — see the Talvio Bot API docs`);
  }
}

// ------------------------------------------------------------------ user side: buttons & mini apps
/** A user tapped an inline button with callback_data. Returns the query id; the answer arrives as bot:callback_answer. */
async function pressButton(userId, messageIdRaw, body = {}) {
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND deleted_at IS NULL', [v.id(messageIdRaw, 'message_id')]);
  if (!m) throw notFound('message_not_found', 'Message not found');
  await chatService.requireMember(m.chat_id, userId);
  const data = String(body.data || '');
  const buttons = ((m.reply_markup && m.reply_markup.inline_keyboard) || []).flat();
  if (!buttons.some((b) => b.callback_data === data)) throw badRequest('invalid_button', 'This button is no longer available');
  const bot = await db.one(`SELECT b.user_id FROM bots b WHERE b.user_id = $1 AND b.status = 'active'`, [m.sender_id]);
  if (!bot) throw badRequest('bot_unavailable', 'This bot is not available');
  rateLimit.enforce(`botbtn:${userId}`, 30, 60 * 1000, 'Slow down');
  const id = crypto.randomBytes(12).toString('hex');
  const botfather = require('./botforge.service'); // eslint-disable-line global-require
  if (botfather.isBotForge(bot.user_id)) {
    setImmediate(() => botfather.onCallback(userId, m.chat_id, m.id, data).catch((err) => console.error('botfather error', err))); // eslint-disable-line no-console
    // the app starts listening for the answer once this request returns
    setTimeout(() => bus.emit('rt:emit', { event: 'bot:callback_answer', payload: { callback_query_id: id, message_id: m.id, text: '' }, userIds: [userId] }), 400).unref();
    return { callback_query_id: id };
  }
  await db.query('INSERT INTO bot_callback_queries (id, bot_id, user_id, message_id) VALUES ($1, $2, $3, $4)', [id, bot.user_id, userId, m.id]);
  const chat = await db.one('SELECT id, type, title FROM chats WHERE id = $1', [m.chat_id]);
  const from = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  await enqueue(bot.user_id, {
    callback_query: { id, from: botUser(from), message: await toBotMessage(m, chat), chat_instance: String(m.chat_id), data },
  });
  return { callback_query_id: id };
}

function webAppSecret(tokenHash) {
  return crypto.createHmac('sha256', 'TalvioMiniApp').update(tokenHash).digest();
}

/** Signed launch data for a mini app (opened from a web_app button or the bot's menu). */
async function webAppInit(userId, botIdRaw, body = {}) {
  await settings.requireFeature('feature_bots', 'Bots');
  const bot = await db.one(`SELECT b.*, u.username FROM bots b JOIN users u ON u.id = b.user_id WHERE b.user_id = $1 AND b.status = 'active'`, [
    v.id(botIdRaw, 'bot_id'),
  ]);
  if (!bot) throw notFound('bot_not_found', 'Bot not found');
  const me = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  const queryId = crypto.randomBytes(12).toString('hex');
  const fields = {
    auth_date: String(Math.floor(Date.now() / 1000)),
    query_id: queryId,
    user: JSON.stringify(botUser(me)),
  };
  if (body.chat_id) fields.chat_id = String(v.id(body.chat_id, 'chat_id'));
  const check = Object.keys(fields).sort().map((k) => `${k}=${fields[k]}`).join('\n');
  const hash = crypto.createHmac('sha256', webAppSecret(bot.token_hash)).update(check).digest('hex');
  const initData = new URLSearchParams({ ...fields, hash }).toString();
  return { init_data: initData, url: bot.menu_url || null };
}

/** For bot developers' tests: verifies init data the way their server should. */
function verifyInitData(initData, botToken) {
  const params = new URLSearchParams(initData);
  const hash = params.get('hash');
  params.delete('hash');
  const check = [...params.keys()].sort().map((k) => `${k}=${params.get(k)}`).join('\n');
  const expected = crypto.createHmac('sha256', webAppSecret(sha256(botToken))).update(check).digest('hex');
  return !!hash && hash.length === expected.length && crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(expected));
}

/** The mini app called Talvio.sendData(data) → the bot gets a web_app_data message. */
async function webAppData(userId, botIdRaw, body = {}) {
  const botId = v.id(botIdRaw, 'bot_id');
  const data = String(body.data || '');
  if (!data || Buffer.byteLength(data) > 4096) throw badRequest('invalid_input', 'data must be 1–4096 bytes');
  const bot = await db.one(`SELECT user_id FROM bots WHERE user_id = $1 AND status = 'active'`, [botId]);
  if (!bot) throw notFound('bot_not_found', 'Bot not found');
  rateLimit.enforce(`webapp:${userId}`, 20, 60 * 1000, 'Slow down');
  const chat = await chatService.getOrCreatePrivate(userId, botId);
  const from = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  await enqueue(botId, {
    message: {
      message_id: 0,
      from: botUser(from),
      chat: { id: chat.id, type: 'private', first_name: from.first_name, username: from.username },
      date: Math.floor(Date.now() / 1000),
      web_app_data: { data, button_text: v.str(String(body.button_text || ''), { field: 'button_text', max: 64 }) || '' },
    },
  });
  return { ok: true };
}

// ------------------------------------------------------------------ admin
async function adminList(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const params = [];
  const where = [`u.status <> 'deleted'`];
  if (query.q) {
    params.push(`%${String(query.q).replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
    where.push(`(u.username ILIKE $${params.length} OR u.first_name ILIKE $${params.length})`);
  }
  const w = `WHERE ${where.join(' AND ')}`;
  const total = await db.one(`SELECT count(*)::int AS n FROM bots b JOIN users u ON u.id = b.user_id ${w}`, params);
  params.push(limit, (page - 1) * limit);
  const rows = await db.many(
    `SELECT u.*, b.*, o.first_name AS owner_first, o.last_name AS owner_last, o.username AS owner_username,
            (SELECT count(*)::int FROM bot_updates x WHERE x.bot_id = b.user_id) AS pending,
            (SELECT count(*)::int FROM chat_members cm WHERE cm.user_id = b.user_id) AS chats
     FROM bots b JOIN users u ON u.id = b.user_id JOIN users o ON o.id = b.owner_id
     ${w} ORDER BY b.created_at DESC LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  return {
    total: total.n,
    page,
    limit,
    bots: rows.map((r) => ({
      ...serializeBot(r, r, { pending: r.pending }),
      chats: r.chats,
      owner: { id: r.owner_id, name: `${r.owner_first || ''} ${r.owner_last || ''}`.trim(), username: r.owner_username },
    })),
  };
}

async function adminSetStatus(botIdRaw, active, reason) {
  const id = v.id(botIdRaw, 'bot_id');
  const r = await db.one(
    `UPDATE bots SET status = $2, disabled_reason = $3 WHERE user_id = $1 RETURNING user_id`,
    [id, active ? 'active' : 'disabled', active ? null : v.str(reason, { field: 'reason', max: 300 }) || null],
  );
  if (!r) throw notFound('bot_not_found', 'Bot not found');
  return { ok: true };
}

module.exports = {
  createBot,
  listMyBots,
  updateBot,
  regenerateToken,
  deleteBot,
  authenticate,
  callMethod,
  parseReplyMarkup,
  pressButton,
  webAppInit,
  webAppData,
  verifyInitData,
  enqueue,
  sweep,
  adminList,
  adminSetStatus,
  _onNewMessage: onNewMessage,
};
