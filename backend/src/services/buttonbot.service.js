'use strict';

/**
 * @HushaviaButtonsBot ("Button Maker") — posts with buttons, no code needed.
 *
 *   1. send the post: text, or a photo / video / GIF with a caption (formatting is kept)
 *   2. send the buttons, one row per line:
 *        Join VIP - https://example.com          → opens a link
 *        XAUUSD - https://a.com | BTCUSD - b.com → up to 3 side by side
 *        My channel - @mychannel                 → opens a Hushavia channel / group / person
 *        Promo code - copy:GOLD50                → copies the text
 *   3. preview, then: publish now or at a time, silently or not — or forward the preview anywhere
 *   4. /myposts: change the buttons of a post that is already out, or delete it
 *
 * Steps are saved in the database (they survive a server restart) for a day.
 */
const db = require('../db');
const bus = require('../bus');
const config = require('../config');

const lazy = {
  sys: () => require('./sysbots.service'), // eslint-disable-line global-require
  messages: () => require('./message.service'), // eslint-disable-line global-require
  chats: () => require('./chat.service'), // eslint-disable-line global-require
};

const MAX_ROWS = 10;
const MAX_PER_ROW = 3;
const MAX_LABEL = 40;
const STATE_TTL_H = 24;
const TZ_OFFSET_MIN = 5 * 60; // times people type are Pakistan time (UTC+5)

// ------------------------------------------------------------------ state (in the database)
async function getState(userId) {
  const r = await db.one(
    `SELECT data FROM buttonbot_state WHERE user_id = $1 AND updated_at > now() - make_interval(hours => $2)`,
    [userId, STATE_TTL_H],
  );
  return r ? r.data : {};
}
async function setState(userId, data) {
  await db.query(
    `INSERT INTO buttonbot_state (user_id, data, updated_at) VALUES ($1, $2, now())
     ON CONFLICT (user_id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()`,
    [userId, JSON.stringify(data)],
  );
}
async function patchState(userId, patch) {
  const s = await getState(userId);
  const next = { ...s, ...patch };
  await setState(userId, next);
  return next;
}

// ------------------------------------------------------------------ replies
const btn = (text, data) => ({ text, callback_data: data });
async function say(chatId, text, buttons = null) {
  return lazy.sys().say('buttons', chatId, text, buttons);
}
async function botId() {
  return lazy.sys().ensureOne('buttons');
}

const HELP = [
  '👋 I make posts with buttons — like signal posts with “XAUUSD”, “Join VIP” or “Promo code” buttons.',
  '',
  '1️⃣ Send me your post (text, or a photo / video with a caption)',
  '2️⃣ Send the buttons',
  '3️⃣ Publish it in your channel or group — now or at a time — or forward it anywhere',
  '',
  '/new — make a new post',
  '/myposts — change or delete posts you published',
  '/cancel — stop',
].join('\n');

const HOW_BUTTONS = [
  '🔘 Now send the buttons — one row per line:',
  '',
  'Join VIP - https://example.com/vip',
  'XAUUSD - https://a.com | BTCUSD - https://b.com',
  'My channel - @mychannel',
  'Promo code - copy:GOLD50',
  '',
  '• “Text - link” → a button that opens the link',
  '• “Text - @name” → opens a Hushavia channel, group or person',
  '• “Text - copy:something” → copies that text',
  `• “|” puts up to ${MAX_PER_ROW} buttons side by side, up to ${MAX_ROWS} rows`,
].join('\n');

// ------------------------------------------------------------------ parsing
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
      // the target is after the last " - ", so a label may itself contain a dash
      const m = /^(.+)\s+[-–—]\s+(\S+)$/.exec(p);
      if (!m) return { error: `I couldn’t read “${p}”.\nWrite it as:  Button text - https://link` };
      const label = m[1].trim();
      const target = m[2].trim();
      if (!label) return { error: `A button in row ${i + 1} has no text.` };
      if ([...label].length > MAX_LABEL) return { error: `“${[...label].slice(0, 20).join('')}…” is too long — keep button text under ${MAX_LABEL} letters.` };
      const copy = /^copy:(.+)$/i.exec(target);
      if (copy) {
        if (copy[1].length > 256) return { error: 'The text a copy button copies can be at most 256 letters.' };
        row.push({ text: label, copy_text: { text: copy[1] } });
        continue;
      }
      let url = target;
      const at = /^@([A-Za-z][A-Za-z0-9_]{2,31})$/.exec(url);
      if (at) url = `${config.publicUrl}/c/${at[1]}`;
      else if (/^www\./i.test(url) || /^[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?$/i.test(url)) url = `https://${url}`;
      if (!/^(https?:\/\/[^\s/]+\.[^\s]+|https?:\/\/[^\s/]+:\d+\/\S*|tg:\/\/\S+|hushavia:\/\/\S+)$/i.test(url) && !at) {
        return { error: `“${target}” isn’t a link. Links start with https:// (or use @name, or copy:text)` };
      }
      if (url.length > 512) return { error: 'That link is too long.' };
      row.push({ text: label, url });
    }
    rows.push(row);
  }
  return { markup: { inline_keyboard: rows } };
}

/** "18:30", "tomorrow 9:00", "25.12 20:00" (Pakistan time) → Date, or null. */
function parseTime(raw, now = new Date()) {
  const t = String(raw || '').trim().toLowerCase();
  const m = /^(?:(today|tomorrow)\s+)?(?:(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?\s+)?(\d{1,2})[:.](\d{2})\s*(am|pm)?$/.exec(t);
  if (!m) return null;
  let h = Number(m[5]);
  const min = Number(m[6]);
  if (m[7] === 'pm' && h < 12) h += 12;
  if (m[7] === 'am' && h === 12) h = 0;
  if (h > 23 || min > 59) return null;
  // "local now" as UTC fields
  const local = new Date(now.getTime() + TZ_OFFSET_MIN * 60000);
  let y = local.getUTCFullYear();
  let mo = local.getUTCMonth();
  let d = local.getUTCDate();
  if (m[2]) {
    d = Number(m[2]);
    mo = Number(m[3]) - 1;
    if (m[4]) y = Number(m[4].length === 2 ? `20${m[4]}` : m[4]);
  } else if (m[1] === 'tomorrow') {
    d += 1;
  }
  let at = new Date(Date.UTC(y, mo, d, h, min) - TZ_OFFSET_MIN * 60000);
  if (!m[1] && !m[2] && at <= now) at = new Date(at.getTime() + 24 * 3600 * 1000); // "18:30" already passed today → tomorrow
  return Number.isNaN(at.getTime()) ? null : at;
}

const pkTime = (d) => new Date(d).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

/** What the person sent as the post: text, or a photo / video / GIF with its caption. */
function postFrom(row) {
  const text = String(row.text || '');
  if (['image', 'video', 'gif'].includes(row.type) && row.media_id) return { type: row.type, text, media_id: row.media_id };
  if (row.type === 'text' && text.trim()) return { type: 'text', text };
  return null;
}

const titleOf = (post) => {
  const t = String(post.text || '').replace(/[*_~`|]/g, '').replace(/\s+/g, ' ').trim();
  const short = [...t].slice(0, 40).join('');
  return short || (post.type === 'image' ? '📷 Photo' : post.type === 'video' ? '🎬 Video' : 'Post');
};

// ------------------------------------------------------------------ steps
async function askPost(userId, chatId, keep = {}) {
  await setState(userId, { step: 'post', lastMarkup: keep.lastMarkup || null });
  return say(chatId, '📝 Send me the post: text, or a photo / video with a caption.');
}

async function askButtons(userId, chatId, s) {
  const extra = s.lastMarkup ? [[btn('♻️ Use my last buttons', 'bb:last')]] : null;
  return say(chatId, HOW_BUTTONS, extra);
}

async function controls(chatId, s) {
  return say(chatId, `✅ Your post is ready (above).\n\nForward it to any chat — the buttons go with it — or publish it:${s.silent ? '\n🔕 Will be sent without sound' : ''}`, [
    [btn('📣 Publish now', 'bb:pub'), btn('🕓 Schedule', 'bb:sch')],
    [btn(s.silent ? '🔔 With sound' : '🔕 Without sound', 'bb:silent')],
    [btn('🔘 Change buttons', 'bb:btn'), btn('📝 Change post', 'bb:post')],
    [btn('➕ New post', 'bb:new')],
  ]);
}

async function preview(userId, chatId, s) {
  try {
    // a normal message with only link/copy buttons, so it can be forwarded anywhere as it is
    await lazy.messages().sendMessage(await botId(), chatId, { ...s.post }, { replyMarkup: s.markup, skipRateLimit: true, anyMedia: true });
  } catch (err) {
    await patchState(userId, { step: 'post' });
    return say(chatId, `⚠️ ${err.message || 'I couldn’t make that post.'}\n\nSend the post again.`);
  }
  return controls(chatId, s);
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

async function askPlace(userId, chatId, s, when) {
  const places = await placesFor(userId);
  if (!places.length) return say(chatId, 'You don’t run a channel or group yet. Forward the post instead — the buttons go with it.');
  await patchState(userId, { when: when ? when.toISOString() : null, step: 'ready' });
  return say(chatId, when ? `🕓 ${pkTime(when)} — where should it go?` : '📣 Where should I publish it?', [
    ...places.map((p) => [btn(`${p.type === 'channel' ? '📣' : '👥'} ${p.title}`.slice(0, 60), `bb:to:${p.id}`)]),
    [btn('✖️ Cancel', 'bb:back')],
  ]);
}

async function publish(userId, chatId, s, targetId) {
  const place = (await placesFor(userId)).find((p) => Number(p.id) === targetId);
  if (!place) return say(chatId, 'You can’t post there any more.');
  const when = s.when ? new Date(s.when) : null;
  if (when && when.getTime() < Date.now() + 60 * 1000) {
    await patchState(userId, { when: null });
    return say(chatId, '⚠️ That time has already passed. Pick it again.', [[btn('🕓 Schedule', 'bb:sch'), btn('📣 Publish now', 'bb:pub')]]);
  }
  try {
    const body = { ...s.post, silent: s.silent === true, ...(when ? { schedule_at: when.toISOString() } : {}) };
    const r = await lazy.messages().sendMessage(userId, targetId, body, { replyMarkup: s.markup, anyMedia: true });
    await patchState(userId, { when: null, lastMarkup: s.markup });
    if (r && r.queued) return say(chatId, `🕓 Sent to “${place.title}” for approval — an admin there publishes it.`);
    if (r && r.scheduled) {
      await db.query('INSERT INTO buttonbot_posts (user_id, chat_id, scheduled_id, title) VALUES ($1, $2, $3, $4)', [userId, targetId, r.scheduled.id, titleOf(s.post)]);
      return say(chatId, `🕓 Scheduled for ${pkTime(when)} in “${place.title}”.\nCancel it any time in that chat’s Scheduled messages.`, [[btn('➕ New post', 'bb:new')]]);
    }
    await db.query('INSERT INTO buttonbot_posts (user_id, chat_id, message_id, title) VALUES ($1, $2, $3, $4)', [userId, targetId, r.id, titleOf(s.post)]);
    return say(chatId, `✅ Published in “${place.title}”.`, [[btn('➕ New post', 'bb:new'), btn('📋 My posts', 'bb:my')]]);
  } catch (err) {
    return say(chatId, `⚠️ ${err.message || 'Couldn’t publish it.'}`);
  }
}

// ------------------------------------------------------------------ published posts
async function myPosts(userId, chatId) {
  const rows = await db.many(
    `SELECT p.id, p.title, p.message_id, c.title AS chat_title FROM buttonbot_posts p
     JOIN chats c ON c.id = p.chat_id
     LEFT JOIN messages m ON m.id = p.message_id
     WHERE p.user_id = $1 AND m.id IS NOT NULL AND m.deleted_at IS NULL
     ORDER BY p.id DESC LIMIT 10`,
    [userId],
  );
  if (!rows.length) return say(chatId, 'You haven’t published any posts with me yet. Send /new to make one.');
  return say(chatId, '📋 Your latest posts — tap one to change its buttons or delete it:', rows.map((r) => [btn(`${r.title} · ${r.chat_title}`.slice(0, 60), `bb:p:${r.id}`)]));
}

async function ownPost(userId, postId) {
  const p = await db.one(
    `SELECT p.*, c.title AS chat_title FROM buttonbot_posts p JOIN chats c ON c.id = p.chat_id
     JOIN messages m ON m.id = p.message_id AND m.deleted_at IS NULL
     WHERE p.id = $1 AND p.user_id = $2`,
    [postId, userId],
  );
  if (!p) return null;
  // still allowed to manage that chat?
  const ok = (await placesFor(userId)).some((x) => Number(x.id) === Number(p.chat_id));
  return ok ? p : null;
}

async function setLiveButtons(p, markup) {
  await db.query('UPDATE messages SET reply_markup = $2, edited_at = now() WHERE id = $1', [p.message_id, JSON.stringify(markup)]);
  const map = await lazy.messages().serializeByIds(0, [p.message_id]);
  bus.emit('message:edited', { chatId: p.chat_id, message: map.get(Number(p.message_id)) || map.get(p.message_id), memberIds: await lazy.chats().memberIds(p.chat_id) });
}

// ------------------------------------------------------------------ entry points
async function onMessage(userId, chatId, row) {
  const text = String(row.text || '').trim();
  const cmd = /^\/(\w+)/.exec(text);
  const c = cmd ? cmd[1].toLowerCase() : null;
  const s = await getState(userId);
  if (c === 'start' || c === 'help') return say(chatId, HELP, [[btn('➕ Make a post', 'bb:new'), btn('📋 My posts', 'bb:my')]]);
  if (c === 'new') return askPost(userId, chatId, s);
  if (c === 'myposts') return myPosts(userId, chatId);
  if (c === 'cancel') {
    await setState(userId, { lastMarkup: s.lastMarkup || null });
    return say(chatId, 'OK, stopped. Send /new to make a post.');
  }
  if (c) return say(chatId, 'I don’t know that command. Send /new to make a post, or /help.');

  if (s.step === 'buttons') {
    const r = parseButtons(row.text);
    if (r.error) return say(chatId, `⚠️ ${r.error}`);
    const next = await patchState(userId, { step: 'ready', markup: r.markup });
    return preview(userId, chatId, next);
  }
  if (s.step === 'time') {
    const at = parseTime(text);
    if (!at) return say(chatId, '⚠️ I couldn’t read that time. Write it like  18:30  or  tomorrow 9:00  or  25.12 20:00');
    if (at.getTime() < Date.now() + 60 * 1000) return say(chatId, '⚠️ That time has already passed — pick a later one.');
    return askPlace(userId, chatId, s, at);
  }
  if (s.step === 'edit_live') {
    const p = await ownPost(userId, s.postId);
    if (!p) {
      await patchState(userId, { step: null });
      return say(chatId, 'That post is gone, or you can’t manage that chat any more.');
    }
    const r = parseButtons(row.text);
    if (r.error) return say(chatId, `⚠️ ${r.error}`);
    await setLiveButtons(p, r.markup);
    await patchState(userId, { step: null, postId: null });
    return say(chatId, `✅ Buttons changed on “${p.title}” in “${p.chat_title}”.`, [[btn('📋 My posts', 'bb:my')]]);
  }

  // anything else starts (or replaces) the post
  const post = postFrom(row);
  if (!post) return say(chatId, 'Send the post as text, or a photo / video with a caption. /help');
  // sent the buttons first ("GOLD SELL - https://…" lines only)? keep them and ask for the post text
  if (post.type === 'text' && !s.changing) {
    const asButtons = parseButtons(post.text);
    if (asButtons.markup) {
      await setState(userId, { step: 'post', pendingMarkup: asButtons.markup, lastMarkup: s.lastMarkup || null, silent: s.silent === true });
      const n = asButtons.markup.inline_keyboard.flat().length;
      return say(chatId, `🔘 Got ${n} button${n === 1 ? '' : 's'}! Now send the post they go under — the text people read (or a photo with a caption).`);
    }
  }
  if (s.pendingMarkup) {
    const next = await setState(userId, { step: 'ready', post, markup: s.pendingMarkup, lastMarkup: s.lastMarkup || null, silent: s.silent === true }).then(() => getState(userId));
    return preview(userId, chatId, next);
  }
  if (s.step === 'post' && s.changing && s.markup) {
    const next = await patchState(userId, { step: 'ready', post, changing: null });
    return preview(userId, chatId, next);
  }
  const next = await setState(userId, { step: 'buttons', post, lastMarkup: s.lastMarkup || null, silent: s.silent === true }).then(() => getState(userId));
  return askButtons(userId, chatId, next);
}

async function onCallback(userId, chatId, data) {
  const s = await getState(userId);
  if (data === 'bb:new') return askPost(userId, chatId, s);
  if (data === 'bb:my') return myPosts(userId, chatId);

  const pm = /^bb:p:(\d+)$/.exec(data);
  if (pm) {
    const p = await ownPost(userId, Number(pm[1]));
    if (!p) return say(chatId, 'That post is gone, or you can’t manage that chat any more.');
    return say(chatId, `“${p.title}” in “${p.chat_title}”`, [
      [btn('🔘 Change buttons', `bb:pe:${p.id}`), btn('🗑 Delete post', `bb:pd:${p.id}`)],
      [btn('‹ Back', 'bb:my')],
    ]);
  }
  const pe = /^bb:pe:(\d+)$/.exec(data);
  if (pe) {
    const p = await ownPost(userId, Number(pe[1]));
    if (!p) return say(chatId, 'That post is gone, or you can’t manage that chat any more.');
    await patchState(userId, { step: 'edit_live', postId: p.id });
    return say(chatId, `🔘 Send the new buttons for “${p.title}” (same way as before). They change right away for everyone.`);
  }
  const pd = /^bb:pd:(\d+)$/.exec(data);
  if (pd) {
    const p = await ownPost(userId, Number(pd[1]));
    if (!p) return say(chatId, 'That post is gone already.');
    return say(chatId, `Delete “${p.title}” from “${p.chat_title}” for everyone?`, [[btn('🗑 Yes, delete', `bb:pdy:${p.id}`), btn('Keep it', `bb:p:${p.id}`)]]);
  }
  const pdy = /^bb:pdy:(\d+)$/.exec(data);
  if (pdy) {
    const p = await ownPost(userId, Number(pdy[1]));
    if (!p) return say(chatId, 'That post is gone already.');
    try {
      await lazy.messages().deleteMessages(userId, p.chat_id, { message_ids: [p.message_id], for_everyone: true });
      return say(chatId, `🗑 Deleted “${p.title}”.`, [[btn('📋 My posts', 'bb:my')]]);
    } catch (err) {
      return say(chatId, `⚠️ ${err.message || 'Couldn’t delete it.'}`);
    }
  }

  if (data === 'bb:last') {
    if (s.step !== 'buttons' || !s.post || !s.lastMarkup) return say(chatId, 'Send /new to make a post first.');
    const next = await patchState(userId, { step: 'ready', markup: s.lastMarkup });
    return preview(userId, chatId, next);
  }
  if (!s.post || !s.markup) return say(chatId, 'That post has expired — send /new to make another.');
  if (data === 'bb:btn') {
    await patchState(userId, { step: 'buttons' });
    return askButtons(userId, chatId, s);
  }
  if (data === 'bb:post') {
    await patchState(userId, { step: 'post', changing: true });
    return say(chatId, '📝 Send the new post (the buttons stay the same).');
  }
  if (data === 'bb:silent') {
    const next = await patchState(userId, { silent: !s.silent });
    return say(chatId, next.silent ? '🔕 It will be sent without sound — people get it quietly.' : '🔔 It will be sent with sound.', [
      [btn('📣 Publish now', 'bb:pub'), btn('🕓 Schedule', 'bb:sch')],
    ]);
  }
  if (data === 'bb:pub') return askPlace(userId, chatId, s, null);
  if (data === 'bb:sch') {
    const now = new Date();
    const local = new Date(now.getTime() + TZ_OFFSET_MIN * 60000);
    const at = (dayPlus, h) => new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + dayPlus, h, 0) - TZ_OFFSET_MIN * 60000).getTime();
    const opts = [
      ['In 1 hour', now.getTime() + 3600e3],
      ['In 3 hours', now.getTime() + 3 * 3600e3],
      ['Tomorrow 9:00', at(1, 9)],
      ['Tomorrow 18:00', at(1, 18)],
    ];
    await patchState(userId, { step: 'time' });
    return say(chatId, '🕓 When should it go out? (Pakistan time)\n\nTap one, or type a time like  18:30  or  tomorrow 9:00  or  25.12 20:00', [
      [btn(opts[0][0], `bb:at:${opts[0][1]}`), btn(opts[1][0], `bb:at:${opts[1][1]}`)],
      [btn(opts[2][0], `bb:at:${opts[2][1]}`), btn(opts[3][0], `bb:at:${opts[3][1]}`)],
      [btn('✖️ Cancel', 'bb:back')],
    ]);
  }
  const atm = /^bb:at:(\d+)$/.exec(data);
  if (atm) return askPlace(userId, chatId, s, new Date(Number(atm[1])));
  if (data === 'bb:back') {
    await patchState(userId, { step: 'ready', when: null });
    return controls(chatId, s);
  }
  const to = /^bb:to:(\d+)$/.exec(data);
  if (to) return publish(userId, chatId, s, Number(to[1]));
  return null;
}

module.exports = { onMessage, onCallback, parseButtons, parseTime };
