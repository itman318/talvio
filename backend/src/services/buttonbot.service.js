'use strict';

/**
 * @HushaviaButtonsBot ("Button Maker") — make a post with link buttons, without writing any code.
 *
 *   1. send the post (text, or a photo with a caption)
 *   2. send the buttons, one row per line:   Join VIP - https://example.com
 *      two or three buttons side by side:     XAUUSD - https://a.com | BTCUSD - https://b.com
 *   3. preview → publish in a channel or group you run, or forward the preview anywhere (the buttons go with it)
 *
 * Built into the server (no token). Steps are kept in memory per person for an hour.
 */
const db = require('../db');

const lazy = {
  sys: () => require('./sysbots.service'), // eslint-disable-line global-require
  messages: () => require('./message.service'), // eslint-disable-line global-require
};

const MAX_ROWS = 10;
const MAX_PER_ROW = 3;
const MAX_LABEL = 40;
const STATE_TTL = 60 * 60 * 1000;
const state = new Map(); // userId → { step: 'post' | 'buttons' | 'ready', post, markup, at }

function get(userId) {
  const s = state.get(userId);
  if (s && Date.now() - s.at > STATE_TTL) {
    state.delete(userId);
    return null;
  }
  return s || null;
}
function put(userId, s) {
  state.set(userId, { ...s, at: Date.now() });
}

const btn = (text, data) => ({ text, callback_data: data });
async function me() {
  return lazy.sys().ensureOne('buttons');
}
async function say(chatId, text, buttons = null) {
  return lazy.sys().say('buttons', chatId, text, buttons);
}

const HOW_BUTTONS = [
  '🔘 Now send the buttons — one row per line:',
  '',
  'Join VIP - https://example.com/vip',
  'XAUUSD - https://a.com | BTCUSD - https://b.com',
  '',
  '• “Text - link” makes one button',
  '• “|” puts up to 3 buttons side by side',
  `• up to ${MAX_ROWS} rows`,
].join('\n');

const HELP = [
  '👋 Hi! I make posts with link buttons — like signal posts with “Join VIP” or “Open chart” buttons.',
  '',
  '1️⃣ Send me your post (text, or a photo with a caption)',
  '2️⃣ Send the buttons',
  '3️⃣ Publish it in your channel or group — or forward it anywhere',
  '',
  '/new — make a new post',
  '/cancel — stop',
].join('\n');

/** "Text - link | Text - link" lines → inline keyboard, or an error message. */
function parseButtons(raw) {
  const lines = String(raw || '').split('\n').map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return { error: 'Send at least one button, like:\nJoin VIP - https://example.com' };
  if (lines.length > MAX_ROWS) return { error: `That’s ${lines.length} rows — the most is ${MAX_ROWS}.` };
  const rows = [];
  for (const [i, line] of lines.entries()) {
    const parts = line.split('|').map((p) => p.trim()).filter(Boolean);
    if (parts.length > MAX_PER_ROW) return { error: `Row ${i + 1} has ${parts.length} buttons — the most side by side is ${MAX_PER_ROW}.` };
    const row = [];
    for (const p of parts) {
      // the link is the last " - " part, so a label may itself contain a dash
      const m = /^(.+?)\s+[-–—]\s+(\S+)$/.exec(p);
      if (!m) return { error: `I couldn’t read “${p}”.\nWrite it as:  Button text - https://link` };
      const label = m[1].trim();
      let url = m[2].trim();
      if (/^www\./i.test(url) || /^[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?$/i.test(url)) url = `https://${url}`;
      if (!/^(https?:\/\/[^\s/]+\.[^\s]+|tg:\/\/\S+|hushavia:\/\/\S+)$/i.test(url)) return { error: `“${m[2]}” isn’t a link. Links start with https://` };
      if (label.length > MAX_LABEL) return { error: `“${label.slice(0, 20)}…” is too long — keep button text under ${MAX_LABEL} letters.` };
      row.push({ text: label, url });
    }
    rows.push(row);
  }
  return { markup: { inline_keyboard: rows } };
}

/** What the person sent as the post: text, or a photo / video / GIF with its caption. */
function postFrom(row) {
  const text = String(row.text || '');
  if (['image', 'video', 'gif'].includes(row.type) && row.media_id) return { type: row.type, text, media_id: row.media_id };
  if (row.type === 'text' && text.trim()) return { type: 'text', text };
  return null;
}

async function preview(userId, chatId, s) {
  const bot = await me();
  // the preview is a normal message with only link buttons, so it can be forwarded anywhere as it is
  await lazy.messages().sendMessage(bot, chatId, { ...s.post }, { replyMarkup: s.markup, skipRateLimit: true, anyMedia: true });
  await say(chatId, '✅ Your post is ready (above).\n\nForward it to any chat — the buttons go with it — or publish it here:', [
    [btn('📣 Publish in my channel / group', 'bb:pub')],
    [btn('🔘 Change buttons', 'bb:btn'), btn('📝 Change post', 'bb:post')],
    [btn('➕ New post', 'bb:new')],
  ]);
}

/** Channels and groups where this person may post (owner / admin). */
async function placesFor(userId) {
  return db.many(
    `SELECT c.id, c.title, c.type FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $1
     WHERE c.type IN ('channel', 'group') AND cm.role IN ('owner', 'admin') AND NOT COALESCE(c.is_suspended, FALSE)
     ORDER BY c.type DESC, c.title LIMIT 20`,
    [userId],
  );
}

async function onMessage(userId, chatId, row) {
  const text = String(row.text || '').trim();
  const cmd = /^\/(\w+)/.exec(text);
  const c = cmd ? cmd[1].toLowerCase() : null;
  if (c === 'start' || c === 'help') {
    state.delete(userId);
    return say(chatId, HELP, [[btn('➕ Make a post', 'bb:new')]]);
  }
  if (c === 'new') {
    put(userId, { step: 'post' });
    return say(chatId, '📝 Send me the post: text, or a photo with a caption.');
  }
  if (c === 'cancel') {
    state.delete(userId);
    return say(chatId, 'OK, stopped. Send /new to make a post.');
  }

  const s = get(userId) || { step: 'post' };
  if (s.step === 'post' || (s.step === 'ready' && !cmd && !s.awaiting)) {
    const post = postFrom(row);
    if (!post) return say(chatId, 'Send the post as text, or a photo / video with a caption.');
    if (s.step === 'ready' && s.markup && s.changing === 'post') {
      const next = { ...s, post, changing: null };
      put(userId, next);
      return preview(userId, chatId, next);
    }
    put(userId, { step: 'buttons', post });
    return say(chatId, HOW_BUTTONS);
  }
  if (s.step === 'buttons') {
    const r = parseButtons(row.text);
    if (r.error) return say(chatId, `⚠️ ${r.error}`);
    const next = { ...s, step: 'ready', markup: r.markup };
    put(userId, next);
    return preview(userId, chatId, next);
  }
  return say(chatId, HELP, [[btn('➕ Make a post', 'bb:new')]]);
}

async function onCallback(userId, chatId, data) {
  const s = get(userId);
  if (data === 'bb:new') {
    put(userId, { step: 'post' });
    return say(chatId, '📝 Send me the post: text, or a photo with a caption.');
  }
  if (!s || !s.post) return say(chatId, 'That post has expired — send /new to make another.');
  if (data === 'bb:btn') {
    put(userId, { ...s, step: 'buttons' });
    return say(chatId, HOW_BUTTONS);
  }
  if (data === 'bb:post') {
    put(userId, { ...s, step: 'post', changing: 'post' });
    return say(chatId, '📝 Send the new post (the buttons stay the same).');
  }
  if (data === 'bb:pub') {
    const places = await placesFor(userId);
    if (!places.length) return say(chatId, 'You don’t run any channel or group yet. Forward the post instead — the buttons go with it.');
    return say(chatId, '📣 Where should I publish it?', [
      ...places.map((p) => [btn(`${p.type === 'channel' ? '📣' : '👥'} ${p.title}`.slice(0, 60), `bb:to:${p.id}`)]),
    ]);
  }
  const to = /^bb:to:(\d+)$/.exec(data);
  if (to) {
    const target = Number(to[1]);
    const ok = (await placesFor(userId)).find((p) => Number(p.id) === target);
    if (!ok) return say(chatId, 'You can’t post there any more.');
    try {
      // sent by the person (as the channel), with the link buttons; their own photo is theirs to post
      const r = await lazy.messages().sendMessage(userId, target, { ...s.post }, { replyMarkup: s.markup, anyMedia: true });
      if (r && r.queued) return say(chatId, `🕓 Sent to “${ok.title}” for approval — an admin there publishes it.`);
      return say(chatId, `✅ Published in “${ok.title}”.`, [[btn('➕ New post', 'bb:new')]]);
    } catch (err) {
      return say(chatId, `⚠️ ${err.message || 'Couldn’t publish it.'}`);
    }
  }
  return null;
}

module.exports = { onMessage, onCallback, parseButtons };
