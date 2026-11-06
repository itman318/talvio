'use strict';

/**
 * Official helper bots built into the server (like BotForge / @HushaviaIDBot: no token, no webhook).
 *
 *  @HushaviaSupportBot — talk to the Hushavia team in a chat. Each message goes into a support ticket
 *                        (the same tickets the admin panel answers); team replies come back in this chat.
 *  @HushaviaSpamBot    — "is my account limited?" Shows any sending limit, why, and until when,
 *                        and lets a limited user ask the team to review it.
 *  @HushaviaButtonsBot — "Button Maker": posts with link buttons (see buttonbot.service.js).
 */
const crypto = require('crypto');
const db = require('../db');
const bus = require('../bus');
const { sha256 } = require('../utils/crypto');

const lazy = {
  messages: () => require('./message.service'), // eslint-disable-line global-require
  support: () => require('./support.service'), // eslint-disable-line global-require
  forge: () => require('./botforge.service'), // eslint-disable-line global-require
};

const BOTS = {
  support: {
    username: 'HushaviaSupportBot',
    name: 'Hushavia Support',
    bio: 'Questions, problems or ideas? Write here — the Hushavia team answers in this chat.',
    about: 'Write your question or problem and our team will reply right here. Photos of the problem help.',
    commands: [
      { command: 'start', description: 'How support works' },
      { command: 'new', description: 'Start a new request' },
      { command: 'status', description: 'My requests' },
      { command: 'close', description: 'Close my open request' },
    ],
  },
  spam: {
    username: 'HushaviaSpamBot',
    name: 'Account Status',
    bio: 'Check if your account can send messages freely — and ask for a review if it can’t.',
    about: 'Send me anything and I’ll tell you if your account has any limits.',
    commands: [
      { command: 'start', description: 'Check my account' },
      { command: 'appeal', description: 'Ask the team to review a limit' },
    ],
  },
  login: {
    username: 'HushaviaCodes',
    name: 'Hushavia',
    bio: 'Login codes and security alerts for your account. Never share a code with anyone.',
    about: 'I send your Hushavia login codes here, so you don’t need email or SMS when you’re already logged in on another device.',
    commands: [],
  },
  buttons: {
    username: 'HushaviaButtonsBot',
    name: 'Button Maker',
    bio: 'Make posts with link buttons for your channel or group — no code needed.',
    about: 'Send me a post, then its buttons (“Text - link”). I’ll make it ready to publish or forward.',
    commands: [
      { command: 'new', description: 'Make a post with buttons' },
      { command: 'myposts', description: 'Change or delete posts I published' },
      { command: 'help', description: 'How it works' },
      { command: 'cancel', description: 'Stop' },
    ],
  },
};

const ids = {}; // key → user id
const TAG = 'chat:@HushaviaSupportBot'; // marks tickets opened from the bot (stored in support_tickets.device)

async function ensureOne(key) {
  if (ids[key]) return ids[key];
  const d = BOTS[key];
  let u = await db.one('SELECT id FROM users WHERE lower(username) = lower($1) AND is_bot', [d.username]);
  if (!u) {
    const owner = await lazy.forge().ensure();
    u = await db.tx(async (c) => {
      const row = (await c.query(
        `INSERT INTO users (phone, first_name, username, is_bot, is_verified, privacy_phone, privacy_group_add, privacy_calls, bio)
         VALUES (NULL, $1, $2, TRUE, TRUE, 'nobody', 'nobody', 'nobody', $3)
         ON CONFLICT DO NOTHING RETURNING id`,
        [d.name, d.username, d.bio],
      )).rows[0];
      if (!row) return null;
      await c.query(
        `INSERT INTO bots (user_id, owner_id, token_hash, about, commands, group_privacy) VALUES ($1, $2, $3, $4, $5, TRUE) ON CONFLICT DO NOTHING`,
        [row.id, owner, sha256(crypto.randomBytes(32).toString('hex')), d.about, JSON.stringify(d.commands)],
      );
      return row;
    });
    if (!u) u = await db.one('SELECT id FROM users WHERE lower(username) = lower($1)', [d.username]);
  }
  // keep the command list and description current after updates
  await db.query('UPDATE bots SET commands = $2, about = $3 WHERE user_id = $1', [u.id, JSON.stringify(d.commands), d.about]).catch(() => {});
  await require('./botavatar').ensureAvatar(u.id, d.username); // eslint-disable-line global-require
  ids[key] = Number(u.id);
  return ids[key];
}

async function ensure() {
  for (const k of Object.keys(BOTS)) await ensureOne(k); // eslint-disable-line no-await-in-loop
  return { ...ids };
}

/** Which built-in helper bot this user id is (or null). */
function which(id) {
  const n = Number(id);
  return Object.keys(ids).find((k) => ids[k] === n) || null;
}

/** A login code delivered to the person's Hushavia app (their other logged-in devices). */
async function sendLoginCode(userId, code, ip) {
  const me = await ensureOne('login');
  const chat = await require('./chat.service').getOrCreatePrivate(userId, me); // eslint-disable-line global-require
  const where = ip ? `\n\nRequested from IP ${String(ip).replace(/^::ffff:/, '')}.` : '';
  const text = [
    `🔐 Login code: **${code}**`,
    '',
    'Don’t give this code to anyone — not even someone who says they’re from Hushavia. We never ask for it.',
    `Someone is logging in to your account on a new device.${where}`,
    '',
    'Wasn’t you? Ignore this message, and turn on two-step verification in Settings → Privacy & security.',
  ].join('\n');
  await say('login', chat.id, text, [[{ text: '📋 Copy code', copy_text: { text: String(code) } }]]);
  return true;
}

async function say(key, chatId, text, buttons = null) {
  const me = await ensureOne(key);
  const markup = buttons ? { inline_keyboard: buttons } : null;
  return lazy.messages().sendMessage(me, chatId, { type: 'text', text }, { replyMarkup: markup, skipRateLimit: true });
}

const btn = (text, data) => ({ text, callback_data: data });
const when = (d) => new Date(d).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' });
const STATUS = { open: '🟡 Waiting for the team', pending: '💬 The team replied', resolved: '✅ Solved', closed: '⚪ Closed' };

// in-memory: the user pressed "New request", so their next message starts a fresh ticket
const wantsNew = new Set();

// ------------------------------------------------------------------ @HushaviaSupportBot
async function openTicket(userId) {
  return db.one(
    `SELECT * FROM support_tickets WHERE user_id = $1 AND device = $2 AND status <> 'closed' ORDER BY id DESC LIMIT 1`,
    [userId, TAG],
  );
}

const SUPPORT_HELP = [
  '👋 Hi! This is Hushavia Support.',
  '',
  'Just write your question or problem here — one message or many, photos too. Our team reads every request and replies in this chat.',
  '',
  '/new — start a new request',
  '/status — your requests',
  '/close — close your open request',
].join('\n');

async function supportStatus(userId, chatId) {
  const rows = await db.many('SELECT * FROM support_tickets WHERE user_id = $1 ORDER BY id DESC LIMIT 5', [userId]);
  if (!rows.length) return say('support', chatId, 'You have no requests yet. Write your question here to start one.');
  const lines = rows.map((t) => `#${t.id} · ${t.subject}\n${STATUS[t.status] || t.status} · ${when(t.updated_at)}`);
  return say('support', chatId, `📋 Your requests\n\n${lines.join('\n\n')}`);
}

async function supportMessage(userId, chatId, row) {
  const text = String(row.text || '').trim();
  const cmd = /^\/(\w+)/.exec(text);
  const c = cmd ? cmd[1].toLowerCase() : null;
  if (c === 'start' || c === 'help') return say('support', chatId, SUPPORT_HELP, [[btn('📝 New request', 'new'), btn('📋 My requests', 'status')]]);
  if (c === 'status') return supportStatus(userId, chatId);
  if (c === 'new') {
    wantsNew.add(userId);
    return say('support', chatId, '📝 OK — write your new question or problem in one message.');
  }
  if (c === 'close') {
    const t = await openTicket(userId);
    if (!t) return say('support', chatId, 'You have no open request.');
    await lazy.support().userClose(userId, t.id);
    return say('support', chatId, `⚪ Request #${t.id} is closed. Write anytime to start a new one.`);
  }
  if (c) return say('support', chatId, 'I don’t know that command. Just write your question, or send /start.');

  // a photo of the problem goes with the request (only the user’s own pictures)
  let mediaId = null;
  if (row.media_id && row.type === 'image') {
    const own = await db.one(`SELECT id FROM media WHERE id = $1 AND uploader_id = $2 AND kind IN ('image', 'avatar')`, [row.media_id, userId]);
    if (own) mediaId = own.id;
  }
  if (!text && !mediaId) return say('support', chatId, 'Please write your question as text (a photo can go with it).');

  const current = wantsNew.has(userId) ? null : await openTicket(userId);
  wantsNew.delete(userId);
  try {
    if (current) {
      await lazy.support().userReply(userId, current.id, { text, media_id: mediaId || undefined });
      return say('support', chatId, `✉️ Added to request #${current.id}. The team will reply here.`);
    }
    const subject = require('../utils/text').cut((text || 'Photo').replace(/\s+/g, ' '), 80).padEnd(3, '.'); // eslint-disable-line global-require
    const r = await lazy.support().createTicket(userId, {
      subject,
      category: 'other',
      message: text || '📷 (photo)',
      media_id: mediaId || undefined,
      device: TAG,
    });
    return say('support', chatId, `✅ Request #${r.ticket.id} received.\n\nOur team will reply in this chat — usually within a day. Write more here to add details.`);
  } catch (err) {
    return say('support', chatId, `⚠️ ${err.message || 'Something went wrong. Please try again.'}`);
  }
}

/** The team answered in the admin panel → deliver it in the bot chat (for requests opened from the bot). */
async function deliverReply({ userId, ticketId, text }) {
  const t = await db.one('SELECT id, device, status FROM support_tickets WHERE id = $1', [ticketId]);
  if (!t || t.device !== TAG) return;
  const me = await ensureOne('support');
  const chat = await db.one(
    `SELECT c.id FROM chats c
       JOIN chat_members a ON a.chat_id = c.id AND a.user_id = $1
       JOIN chat_members b ON b.chat_id = c.id AND b.user_id = $2
     WHERE c.type = 'private' LIMIT 1`,
    [me, userId],
  );
  if (!chat) return;
  const tail = t.status === 'resolved' ? '\n\n✅ The team marked this as solved. Write here if you still need help.' : '';
  await say('support', chat.id, `💬 Hushavia team · request #${t.id}\n\n${text}${tail}`);
}

bus.on('support:reply', (e) => {
  deliverReply(e).catch((err) => console.error('support bot reply error', err)); // eslint-disable-line no-console
});

// ------------------------------------------------------------------ @HushaviaSpamBot
async function statusText(user) {
  const limited = user.restricted_until && new Date(user.restricted_until) > new Date();
  if (!limited) {
    return {
      text: [
        '✅ Good news — your account has no limits.',
        '',
        'You can message anyone, create groups and channels as usual.',
        '',
        'If people can’t receive your messages, they may have blocked you or changed their privacy settings.',
      ].join('\n'),
      buttons: null,
    };
  }
  return {
    text: [
      '⚠️ Your account is limited for now.',
      '',
      `Until: ${when(user.restricted_until)} (Pakistan time)`,
      user.restrict_reason ? `Reason: ${user.restrict_reason}` : 'Reason: messages that looked like spam, or reports from other users.',
      '',
      'While limited you can’t send messages. The limit ends by itself at the time above.',
      '',
      'Think this is a mistake? Tap the button and tell the team what happened.',
    ].join('\n'),
    buttons: [[btn('🙋 This is a mistake', 'appeal')]],
  };
}

async function spamMessage(userId, chatId, row) {
  const user = await db.one('SELECT id, restricted_until, restrict_reason FROM users WHERE id = $1', [userId]);
  const text = String(row.text || '').trim();
  const appeal = /^\/appeal\b\s*([\s\S]*)$/i.exec(text);
  if (appeal) return spamAppeal(user, chatId, appeal[1].trim());
  if (wantsNew.has(-userId) && text && !text.startsWith('/')) {
    wantsNew.delete(-userId);
    return spamAppeal(user, chatId, text);
  }
  const s = await statusText(user);
  return say('spam', chatId, s.text, s.buttons);
}

async function spamAppeal(user, chatId, why) {
  const limited = user.restricted_until && new Date(user.restricted_until) > new Date();
  if (!limited) return say('spam', chatId, '✅ Your account has no limits, so there’s nothing to review.');
  if (!why) {
    wantsNew.add(-user.id);
    return say('spam', chatId, '📝 In one message, tell the team what you were doing and why the limit is a mistake.');
  }
  try {
    const r = await lazy.support().createTicket(user.id, {
      subject: 'Review my account limit',
      category: 'account',
      message: `Limit until ${new Date(user.restricted_until).toISOString()} (${user.restrict_reason || 'no reason given'}).\n\n${why}`,
      device: TAG, // the answer comes back through @HushaviaSupportBot
    });
    return say('spam', chatId, `✅ Sent to the team (request #${r.ticket.id}). They’ll answer in @${BOTS.support.username}.`);
  } catch (err) {
    return say('spam', chatId, `⚠️ ${err.message || 'Something went wrong. Please try again.'}`);
  }
}

// ------------------------------------------------------------------ routing
/** A message in a private chat with one of these bots. Returns true when handled. */
async function onMessage(botId, senderId, chat, row) {
  const key = which(botId);
  if (!key) return false;
  if (chat.type !== 'private' || !senderId) return true; // they only work in private chats
  if (key === 'support') await supportMessage(senderId, chat.id, row);
  if (key === 'spam') await spamMessage(senderId, chat.id, row);
  if (key === 'buttons') await require('./buttonbot.service').onMessage(senderId, chat.id, row); // eslint-disable-line global-require
  if (key === 'login') await say('login', chat.id, 'I only send login codes and security alerts. For help, write to @HushaviaSupportBot.');
  return true;
}

async function onCallback(botId, userId, chatId, data) {
  const key = which(botId);
  if (key === 'support') {
    if (data === 'status') return supportStatus(userId, chatId);
    if (data === 'new') {
      wantsNew.add(userId);
      return say('support', chatId, '📝 OK — write your new question or problem in one message.');
    }
  }
  if (key === 'buttons') return require('./buttonbot.service').onCallback(userId, chatId, data); // eslint-disable-line global-require
  if (key === 'spam' && data === 'appeal') {
    const user = await db.one('SELECT id, restricted_until, restrict_reason FROM users WHERE id = $1', [userId]);
    return spamAppeal(user, chatId, '');
  }
  return null;
}

module.exports = { ensure, ensureOne, say, which, onMessage, onCallback, sendLoginCode, BOTS, TAG };
