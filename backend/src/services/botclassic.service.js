'use strict';

/**
 * Talvio Bot API — Classic.
 *
 * A second doorway into the same bot platform, shaped like the de-facto standard used by most chat-bot
 * libraries (python aiogram / python-telegram-bot, node grammY / telegraf, …), so existing bots run on
 * Talvio by changing only their server address:
 *
 *   POST {base}/bot<id>:<secret>/<methodName>          base = https://your-server/api/classic
 *   GET  {base}/file/bot<id>:<secret>/<file_path>      (downloads from getFile)
 *   → { ok: true, result } | { ok: false, error_code, description, parameters? }
 *
 * The token is the Talvio token written as "<id>:<secret>" (tlv_<id>_<secret> works too).
 * Everything here is Talvio's own code; methods call the regular bot service underneath.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const db = require('../db');
const v = require('../utils/validate');
const bot = require('./bot.service');
const media = require('./media.service');
const { AppError, badRequest } = require('../utils/errors');

// ------------------------------------------------------------------ token
function toTalvioToken(raw) {
  const t = String(raw || '').trim();
  const m = /^(\d+):([A-Za-z0-9]{20,})$/.exec(t);
  return m ? `tlv_${m[1]}_${m[2]}` : t;
}
function toClassicToken(talvio) {
  const m = /^tlv_(\d+)_([A-Za-z0-9]+)$/.exec(String(talvio || ''));
  return m ? `${m[1]}:${m[2]}` : null;
}

// ------------------------------------------------------------------ text formatting → Talvio marks
const ENT = { '&lt;': '<', '&gt;': '>', '&amp;': '&', '&quot;': '"', '&#39;': "'", '&apos;': "'", '&nbsp;': ' ' };
function decodeEntities(s) {
  return s.replace(/&(lt|gt|amp|quot|apos|nbsp|#39);/g, (m) => ENT[m] || m).replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)));
}

function fromHtml(s) {
  let out = String(s)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_, url, text) => {
      const t = text.replace(/<[^>]+>/g, '');
      return t.trim() === url.trim() ? url : `${t} (${url})`;
    })
    .replace(/<\/?(b|strong)(\s[^>]*)?>/gi, '**')
    .replace(/<\/?(i|em)(\s[^>]*)?>/gi, '_')
    .replace(/<\/?(s|strike|del)(\s[^>]*)?>/gi, '~')
    .replace(/<tg-spoiler>|<\/tg-spoiler>|<span\s+class=["']tg-spoiler["']>/gi, '||')
    .replace(/<pre[^>]*>\s*<code[^>]*>([\s\S]*?)<\/code>\s*<\/pre>/gi, (_, c) => c)
    .replace(/<\/?pre[^>]*>/gi, '')
    .replace(/<code[^>]*>([^<\n]*)<\/code>/gi, '`$1`')
    .replace(/<[^>]+>/g, '');
  out = decodeEntities(out);
  return out;
}

function fromMarkdown(s, v2) {
  const keep = [];
  let t = String(s);
  if (v2) t = t.replace(/\\([\s\S])/g, (_, c) => `\u0000${keep.push(c) - 1}\u0000`);
  t = t
    .replace(/```[a-zA-Z0-9_+-]*\n?([\s\S]*?)```/g, (_, c) => c)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, text, url) => (text === url ? url : `${text} (${url})`))
    .replace(/__([^_\n]+)__/g, '$1') // underline: no such mark in Talvio
    .replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1**$2**');
  if (v2) t = t.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[Number(i)]);
  return t;
}

function formatText(text, mode) {
  if (text === undefined || text === null) return text;
  const m = String(mode || '').toLowerCase();
  if (m === 'html') return fromHtml(text);
  if (m === 'markdownv2') return fromMarkdown(text, true);
  if (m === 'markdown') return fromMarkdown(text, false);
  return String(text);
}

// ------------------------------------------------------------------ objects → classic shapes
const uniq = (id) => crypto.createHash('sha1').update(`tlv-file-${id}`).digest('base64url').slice(0, 16);

async function fileFields(f) {
  if (!f || !f.file_id) return f;
  const row = await db.one('SELECT width, height, duration_sec FROM media WHERE id = $1', [Number(f.file_id)]).catch(() => null);
  return { ...f, file_unique_id: uniq(f.file_id), width: (row && row.width) || 0, height: (row && row.height) || 0, duration: (row && row.duration_sec) || 0 };
}

async function message(m) {
  if (!m || typeof m !== 'object') return m;
  const out = { ...m };
  if (!out.date) out.date = Math.floor(Date.now() / 1000);
  if (out.from) out.from = { language_code: 'en', ...out.from };
  if (out.photo && !Array.isArray(out.photo)) {
    const f = await fileFields(out.photo);
    out.photo = [{ file_id: f.file_id, file_unique_id: f.file_unique_id, width: f.width, height: f.height, file_size: f.file_size }];
  }
  for (const k of ['document', 'video', 'voice', 'audio']) {
    if (out[k]) {
      const f = await fileFields(out[k]);
      out[k] = k === 'document'
        ? { file_id: f.file_id, file_unique_id: f.file_unique_id, file_name: f.file_name, mime_type: f.mime_type, file_size: f.file_size }
        : { file_id: f.file_id, file_unique_id: f.file_unique_id, width: f.width, height: f.height, duration: f.duration, mime_type: f.mime_type, file_size: f.file_size };
    }
  }
  if (out.reply_to_message) out.reply_to_message = { date: out.date, chat: out.chat, ...out.reply_to_message };
  return out;
}

async function updateShape(u) {
  const out = { ...u };
  if (out.message) out.message = await message(out.message);
  if (out.edited_message) out.edited_message = await message(out.edited_message);
  if (out.callback_query) {
    out.callback_query = { chat_instance: '0', ...out.callback_query };
    if (out.callback_query.message) out.callback_query.message = await message(out.callback_query.message);
  }
  return out;
}

// ------------------------------------------------------------------ files: upload, by id, by URL
const MAX_URL_BYTES = 20 * 1024 * 1024;

function isPrivateHost(host) {
  const h = host.toLowerCase();
  return h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal')
    || /^(127\.|10\.|192\.168\.|169\.254\.|0\.)/.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || h === '[::1]' || h.startsWith('[fc') || h.startsWith('[fd');
}

/** A file the bot downloads from a public https URL, saved like a normal upload. */
async function download(url) {
  let u;
  try {
    u = new URL(String(url));
  } catch (_) {
    throw badRequest('invalid_file', 'wrong file identifier/HTTP URL specified');
  }
  if (!['http:', 'https:'].includes(u.protocol) || isPrivateHost(u.hostname)) throw badRequest('invalid_file', 'wrong HTTP URL specified');
  const res = await fetch(u, { signal: AbortSignal.timeout(20000), redirect: 'follow' });
  if (!res.ok) throw badRequest('invalid_file', `failed to get HTTP URL content (${res.status})`);
  const len = Number(res.headers.get('content-length') || 0);
  if (len > MAX_URL_BYTES) throw badRequest('file_too_large', 'file is too big');
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length > MAX_URL_BYTES) throw badRequest('file_too_large', 'file is too big');
  const config = require('../config'); // eslint-disable-line global-require
  const d = new Date();
  const dir = path.join(config.uploadDir, String(d.getUTCFullYear()), String(d.getUTCMonth() + 1).padStart(2, '0'));
  fs.mkdirSync(dir, { recursive: true });
  const name = path.basename(u.pathname) || 'file';
  const file = path.join(dir, `${crypto.randomBytes(16).toString('hex')}${path.extname(name).slice(0, 10)}`);
  fs.writeFileSync(file, buf);
  return { path: file, size: buf.length, mimetype: (res.headers.get('content-type') || 'application/octet-stream').split(';')[0], originalname: name };
}

/**
 * The file a send* method should carry: an uploaded part, an earlier file_id, or an http(s) URL.
 * Returns { file } (a multer-like upload) or { mediaId }.
 */
async function resolveFile(value, uploaded) {
  if (uploaded) return { file: uploaded };
  if (value === undefined || value === null || value === '') throw badRequest('file_required', 'there is no file in the request');
  const s = String(value);
  if (/^\d+$/.test(s)) return { mediaId: Number(s) };
  if (/^attach:\/\//.test(s)) throw badRequest('file_required', 'attached file not found in the request');
  return { file: await download(s) };
}

// ------------------------------------------------------------------ parameters
function json(x) {
  if (typeof x !== 'string') return x;
  try {
    return JSON.parse(x);
  } catch (_) {
    return x;
  }
}

function common(p) {
  const out = { ...p };
  const rp = json(p.reply_parameters);
  if (rp && typeof rp === 'object' && rp.message_id) out.reply_to_message_id = rp.message_id;
  if (p.reply_markup !== undefined) {
    const m = json(p.reply_markup);
    // force_reply / empty markup: nothing to show
    out.reply_markup = m && (m.inline_keyboard || m.keyboard || m.remove_keyboard) ? m : undefined;
  }
  if (out.chat_id !== undefined) out.chat_id = String(out.chat_id);
  return out;
}

// ------------------------------------------------------------------ IDs the classic way
const GROUP_BASE = 1000000000000;
/** Group/channel chat → the ID bots use: "-100" followed by the chat number (e.g. -1001000004321). */
const toGroupId = (chatId) => -(GROUP_BASE + Math.abs(Number(chatId)));
const fromGroupId = (n) => {
  const m = Math.abs(Number(n));
  return m > GROUP_BASE ? m - GROUP_BASE : m; // a plain -<id> still works
};
// Private chats are addressed by the other person's user ID; groups and channels by a negative ID.
// (Inside Talvio every chat has its own positive ID — this maps between the two.)
async function resolveChatId(raw, botId) {
  const s = String(raw || '').trim();
  if (s.startsWith('@')) {
    const r = await db.one('SELECT id FROM chats WHERE lower(username) = lower($1)', [s.slice(1)]).catch(() => null);
    if (!r) throw badRequest('chat_not_found', 'chat not found');
    return String(r.id);
  }
  const n = Number(s);
  if (!Number.isSafeInteger(n) || n === 0) throw badRequest('chat_not_found', 'chat not found');
  if (n < 0) return String(fromGroupId(n));
  const r = await db.one(
    `SELECT c.id FROM chats c
     JOIN chat_members a ON a.chat_id = c.id AND a.user_id = $1
     JOIN chat_members b ON b.chat_id = c.id AND b.user_id = $2
     WHERE c.type = 'private' LIMIT 1`,
    [botId, n],
  );
  if (!r) throw badRequest('chat_not_found', 'chat not found (the user has to start the bot first)');
  return String(r.id);
}

async function classicChat(chat, botId, cache) {
  if (!chat || chat.id === undefined || !chat.type) return chat;
  const key = `${chat.id}`;
  if (cache.has(key)) return cache.get(key);
  let out;
  if (chat.type === 'private') {
    const peer = await db.one(
      `SELECT u.id, u.first_name, u.last_name, u.username FROM chat_members m JOIN users u ON u.id = m.user_id
       WHERE m.chat_id = $1 AND m.user_id <> $2 LIMIT 1`,
      [Number(chat.id), botId],
    );
    out = peer
      ? { id: Number(peer.id), type: 'private', first_name: peer.first_name || '', ...(peer.last_name ? { last_name: peer.last_name } : {}), ...(peer.username ? { username: peer.username } : {}) }
      : chat;
  } else {
    out = { ...chat, id: toGroupId(chat.id), type: chat.type === 'group' ? 'supergroup' : chat.type };
  }
  cache.set(key, out);
  return out;
}

/** Walks a result and rewrites every chat object (and top-level chat results) to classic IDs. */
async function mapIds(x, botId, cache = new Map()) {
  if (Array.isArray(x)) return Promise.all(x.map((y) => mapIds(y, botId, cache)));
  if (!x || typeof x !== 'object') return x;
  const out = {};
  for (const [k, val] of Object.entries(x)) {
    out[k] = k === 'chat' && val && typeof val === 'object' && val.type ? await classicChat(val, botId, cache) : await mapIds(val, botId, cache);
  }
  return out;
}

async function update(u, botId) {
  const shaped = await updateShape(u);
  return botId ? mapIds(shaped, botId) : shaped;
}

// ------------------------------------------------------------------ methods
async function sendWithFile(token, p, files, field, kind) {
  const r = await resolveFile(p[field], files[field] || files.file);
  const params = { ...p, caption: formatText(p.caption, p.parse_mode) };
  if (r.mediaId) {
    // resend a file the bot already has
    const b = await bot.authenticate(token);
    await media.getAccessible(b.user_id, r.mediaId);
    return bot.sendMessageWithMedia(b, params, kind, r.mediaId);
  }
  return bot.callMethod(token, kind === 'image' ? 'photos.send' : 'files.send', params, r.file);
}

const MAP = {
  getMe: (t) => bot.callMethod(t, 'me', {}),
  logOut: async () => true,
  close: async () => true,
  getUpdates: async (t, p) => Promise.all((await bot.callMethod(t, 'updates', p)).map((u) => updateShape(u))),
  setWebhook: (t, p) => bot.callMethod(t, 'webhook.set', { ...p, api_version: 'cls' }),
  deleteWebhook: (t, p) => bot.callMethod(t, 'webhook.delete', p),
  getWebhookInfo: async (t) => ({ has_custom_certificate: false, max_connections: 40, ...(await bot.callMethod(t, 'webhook.info', {})) }),
  sendMessage: async (t, p) => message(await bot.callMethod(t, 'messages.send', { ...p, text: formatText(p.text, p.parse_mode) })),
  sendPhoto: async (t, p, f) => message(await sendWithFile(t, p, f, 'photo', 'image')),
  sendDocument: async (t, p, f) => message(await sendWithFile(t, p, f, 'document', 'file')),
  sendVideo: async (t, p, f) => message(await sendWithFile(t, p, f, 'video', 'file')),
  sendAudio: async (t, p, f) => message(await sendWithFile(t, p, f, 'audio', 'file')),
  sendVoice: async (t, p, f) => message(await sendWithFile(t, p, f, 'voice', 'file')),
  sendAnimation: async (t, p, f) => message(await sendWithFile(t, p, f, 'animation', 'file')),
  sendSticker: async (t, p, f) => message(await sendWithFile(t, p, f, 'sticker', 'image')),
  editMessageText: async (t, p) => message(await bot.callMethod(t, 'messages.edit', { ...p, text: formatText(p.text, p.parse_mode) })),
  editMessageReplyMarkup: async (t, p) => message(await bot.callMethod(t, 'messages.edit-buttons', { ...p, reply_markup: p.reply_markup ?? null })),
  deleteMessage: (t, p) => bot.callMethod(t, 'messages.delete', p),
  deleteMessages: async (t, p) => {
    for (const id of json(p.message_ids) || []) await bot.callMethod(t, 'messages.delete', { chat_id: p.chat_id, message_id: id });
    return true;
  },
  answerCallbackQuery: (t, p) => bot.callMethod(t, 'buttons.answer', p),
  answerInlineQuery: (t, p) => bot.callMethod(t, 'inline.answer', p),
  setMyCommands: (t, p) => bot.callMethod(t, 'commands.set', { commands: json(p.commands) }),
  getMyCommands: (t) => bot.callMethod(t, 'commands.get', {}),
  deleteMyCommands: (t) => bot.callMethod(t, 'commands.delete', {}),
  setMyDescription: (t, p) => bot.callMethod(t, 'me.set', { description: p.description || '' }),
  setMyShortDescription: (t, p) => bot.callMethod(t, 'me.set', { description: p.short_description || '' }),
  setMyName: (t, p) => bot.callMethod(t, 'me.set', { name: p.name }),
  setChatMenuButton: async (t, p) => {
    const mb = json(p.menu_button);
    return bot.callMethod(t, 'me.set', { menu_url: mb && mb.web_app ? mb.web_app.url : null });
  },
  sendChatAction: (t, p) => bot.callMethod(t, 'chat.action', { ...p, action: String(p.action || 'typing').replace('upload_photo', 'uploading_photo').replace('upload_document', 'uploading_file').replace('upload_video', 'uploading_video').replace('record_voice', 'recording_voice') }),
  sendPoll: async (t, p) => message(await bot.callMethod(t, 'polls.send', { ...p, options: (json(p.options) || []).map((o) => (typeof o === 'string' ? o : o.text)) })),
  sendLocation: async (t, p) => message(await bot.callMethod(t, 'locations.send', p)),
  forwardMessage: async (t, p) => message(await bot.callMethod(t, 'messages.forward', p)),
  copyMessage: async (t, p) => {
    const m = await bot.callMethod(t, 'messages.forward', p);
    return { message_id: m.message_id };
  },
  pinChatMessage: (t, p) => bot.callMethod(t, 'messages.pin', p),
  unpinChatMessage: (t, p) => bot.callMethod(t, 'messages.unpin', p),
  getChat: async (t, p) => ({
    ...(await bot.callMethod(t, 'chats.get', p).then(async (c) => (c.type === 'private' ? { ...c, ...(await classicChat(c, botIdOf(t), new Map())) } : { ...c, id: toGroupId(c.id), type: c.type === 'group' ? 'supergroup' : c.type }))),
    accent_color_id: 0,
    max_reaction_count: 11,
    accepted_gift_types: { unlimited_gifts: false, limited_gifts: false, unique_gifts: false, premium_subscription: false, gifts_from_channels: false },
  }),
  getChatMember: async (t, p) => {
    const r = await bot.callMethod(t, 'chats.member', p);
    const user = r.user || { id: Number(p.user_id), is_bot: false, first_name: '' };
    if (r.status === 'creator') return { status: 'creator', user, is_anonymous: false };
    if (r.status === 'administrator') {
      const yes = true;
      return {
        status: 'administrator', user, can_be_edited: false, is_anonymous: false, can_manage_chat: yes, can_delete_messages: yes,
        can_manage_video_chats: yes, can_restrict_members: yes, can_promote_members: false, can_change_info: yes, can_invite_users: yes,
        can_post_stories: false, can_edit_stories: false, can_delete_stories: false, can_send_welcome_messages: false,
      };
    }
    return { status: r.status === 'left' ? 'left' : 'member', user };
  },
  getChatMemberCount: (t, p) => bot.callMethod(t, 'chats.member-count', p),
  getChatMembersCount: (t, p) => bot.callMethod(t, 'chats.member-count', p),
  getFile: async (t, p) => {
    const b = await bot.authenticate(t);
    const m = await media.getAccessible(b.user_id, p.file_id);
    return { file_id: String(m.id), file_unique_id: uniq(m.id), file_size: Number(m.size_bytes), file_path: `media/${m.id}/${encodeURIComponent(m.original_name || 'file')}` };
  },
};

const botIdOf = (token) => Number((/^tlv_(\d+)_/.exec(token) || [])[1] || 0);

async function call(rawToken, method, params = {}, files = {}) {
  const token = toTalvioToken(rawToken);
  const fn = MAP[method];
  if (!fn) throw new AppError(404, 'method_not_found', `Not Found: method ${method} is not available on Talvio yet`);
  const botId = botIdOf(token);
  await bot.authenticate(token); // a bad token is "Unauthorized" before anything else
  const p = common(params);
  if (p.chat_id !== undefined) p.chat_id = await resolveChatId(p.chat_id, botId);
  if (p.from_chat_id !== undefined) p.from_chat_id = await resolveChatId(p.from_chat_id, botId);
  const result = await fn(token, p, files || {});
  return method === 'getChat' ? result : mapIds(result, botId);
}

/** For GET {base}/file/bot<token>/media/<id>/<name>: the media row the bot may download. */
async function fileFor(rawToken, filePath) {
  const b = await bot.authenticate(toTalvioToken(rawToken));
  const id = /^media\/(\d+)/.exec(String(filePath || ''));
  if (!id) throw new AppError(404, 'not_found', 'Not Found');
  const m = await media.getAccessible(b.user_id, id[1]);
  return m;
}

/** Error → classic error body. */
function errorBody(err) {
  const status = err instanceof AppError ? err.status : err.code === 'LIMIT_FILE_SIZE' ? 413 : 500;
  const label = { 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict', 413: 'Request Entity Too Large', 429: 'Too Many Requests' }[status] || 'Internal Server Error';
  const msg = status === 500 ? 'Internal Server Error' : `${label}: ${err.message}`;
  const body = { ok: false, error_code: status, description: msg };
  if (err.extra && err.extra.retry_after) body.parameters = { retry_after: err.extra.retry_after };
  return { status, body };
}

module.exports = { toGroupId, fromGroupId, call, fileFor, errorBody, update, message, formatText, toTalvioToken, toClassicToken, tmpDir: os.tmpdir(), v };
