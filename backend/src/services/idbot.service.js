'use strict';

/**
 * @TalvioIDBot — tells people their numeric Talvio ID (bot hosting panels and bot configs ask for IDs,
 * not usernames). Built into the server like BotForge: no token, no webhook.
 *
 *  - any message / /start / /id  → your ID (with a Copy button)
 *  - a forwarded message         → the original sender's ID (or the channel/group it came from)
 *  - "@username"                 → that user's, bot's, group's or channel's ID
 *  - in a group: /id             → the group's ID (and yours)
 * Group and channel IDs are shown the way bot libraries use them: with a minus sign.
 */
const crypto = require('crypto');
const db = require('../db');
const { sha256 } = require('../utils/crypto');

const USERNAME = 'TalvioIDBot';
const NAME = 'Talvio ID';
let cachedId = null;

const COMMANDS = [
  { command: 'id', description: 'Show my Talvio ID' },
  { command: 'help', description: 'How to find any ID' },
];

async function ensure() {
  if (cachedId) return cachedId;
  let u = await db.one('SELECT id FROM users WHERE lower(username) = lower($1) AND is_bot', [USERNAME]);
  if (!u) {
    const owner = await require('./botforge.service').ensure(); // eslint-disable-line global-require
    u = await db.tx(async (c) => {
      const row = (await c.query(
        `INSERT INTO users (phone, first_name, username, is_bot, is_verified, privacy_phone, privacy_group_add, privacy_calls, bio)
         VALUES (NULL, $1, $2, TRUE, TRUE, 'nobody', 'everyone', 'nobody', 'I show your Talvio ID — and anyone else’s.')
         ON CONFLICT DO NOTHING RETURNING id`,
        [NAME, USERNAME],
      )).rows[0];
      if (!row) return null;
      await c.query(
        `INSERT INTO bots (user_id, owner_id, token_hash, about, commands, group_privacy) VALUES ($1, $2, $3, $4, $5, TRUE) ON CONFLICT DO NOTHING`,
        [row.id, owner, sha256(crypto.randomBytes(32).toString('hex')), 'Send me anything and I’ll tell you your Talvio ID. Forward a message to see who sent it.', JSON.stringify(COMMANDS)],
      );
      return row;
    });
    if (!u) u = await db.one('SELECT id FROM users WHERE lower(username) = lower($1)', [USERNAME]);
  }
  cachedId = u.id;
  return cachedId;
}

function isIdBot(id) {
  return cachedId !== null && Number(id) === Number(cachedId);
}

const copyBtn = (label, value) => ({ text: `📋 ${label}`, copy_text: { text: String(value) } });

async function say(chatId, text, buttons = []) {
  const me = await ensure();
  const markup = buttons.length ? { inline_keyboard: buttons.map((b) => [b]) } : null;
  await require('./message.service').sendMessage(me, chatId, { type: 'text', text }, { replyMarkup: markup, skipRateLimit: true }); // eslint-disable-line global-require
}

const fullName = (u) => `${u.first_name || ''} ${u.last_name || ''}`.trim() || 'No name';
const gid = (id) => require('./botclassic.service').toGroupId(id); // eslint-disable-line global-require
const kindOf = (c) => ({ group: 'Group', channel: 'Channel' }[c.type] || 'Chat');

async function describeUser(u, title) {
  return [
    `${title}`,
    '',
    `🆔 ID: \`${u.id}\``,
    `👤 Name: ${fullName(u)}`,
    u.username ? `🔗 Username: @${u.username}` : null,
    u.is_bot ? '🤖 This is a bot' : null,
  ].filter((x) => x !== null).join('\n');
}

const HELP = [
  'I tell you Talvio IDs 🆔 — bot panels and bot settings need these numbers, not @usernames.',
  '',
  '• Send me anything → your ID',
  '• Forward me a message → the ID of whoever sent it (or the channel it came from)',
  '• Send @username → the ID of that person, bot, group or channel',
  '• Add me to a group and send /id → the group’s ID',
  '',
  'Group and channel IDs start with −100 — that’s how bots use them.',
].join('\n');

async function onMessage(userId, chatId, row) {
  const chat = await db.one('SELECT id, type, title FROM chats WHERE id = $1', [chatId]);
  const me = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  const text = String(row.text || '').trim();

  // in groups: only /id (or a mention) gets an answer
  if (chat.type !== 'private') {
    await say(chatId, [
      `👥 ${chat.title}`,
      `🆔 Group ID: \`${gid(chat.id)}\``,
      '',
      `👤 ${fullName(me)} — your ID: \`${me.id}\``,
    ].join('\n'), [copyBtn('Copy group ID', gid(chat.id)), copyBtn('Copy my ID', me.id)]);
    return;
  }

  if (/^\/(help)\b/i.test(text)) return say(chatId, HELP);

  // a forwarded message: who wrote it originally?
  if (row.forwarded_from_name || row.forward_source_id) {
    if (row.forwarded_from_user_id) {
      const u = await db.one('SELECT * FROM users WHERE id = $1', [row.forwarded_from_user_id]);
      if (u) return say(chatId, await describeUser(u, '↪️ Forwarded from'), [copyBtn('Copy ID', u.id)]);
    }
    if (row.forward_source_id) {
      const src = await db.one('SELECT c.id, c.type, c.title FROM messages m JOIN chats c ON c.id = m.chat_id WHERE m.id = $1', [row.forward_source_id]);
      if (src && src.type !== 'private') {
        return say(chatId, [`↪️ Forwarded from a ${kindOf(src).toLowerCase()}`, '', `📣 ${src.title}`, `🆔 ${kindOf(src)} ID: \`${gid(src.id)}\``].join('\n'), [copyBtn(`Copy ${kindOf(src).toLowerCase()} ID`, gid(src.id))]);
      }
    }
    return say(chatId, `↪️ Forwarded from ${row.forwarded_from_name || 'someone'}\n\n🔒 They hide their account in forwarded messages, so I can’t see their ID. Ask them to send /id to @${USERNAME}.`);
  }

  // "@username" → look it up
  const at = /^@?([A-Za-z][A-Za-z0-9_]{2,31})$/.exec(text);
  if (at && !text.startsWith('/') && text.startsWith('@')) {
    const u = await db.one(`SELECT * FROM users WHERE lower(username) = lower($1) AND status <> 'deleted'`, [at[1]]);
    if (u) return say(chatId, await describeUser(u, `🔎 @${u.username}`), [copyBtn('Copy ID', u.id)]);
    const c = await db.one(`SELECT id, type, title FROM chats WHERE lower(username) = lower($1)`, [at[1]]).catch(() => null);
    if (c) return say(chatId, [`🔎 @${at[1]}`, '', `📣 ${c.title}`, `🆔 ${kindOf(c)} ID: \`${gid(c.id)}\``].join('\n'), [copyBtn('Copy ID', gid(c.id))]);
    return say(chatId, `I couldn’t find @${at[1]} on Talvio.`);
  }

  // anything else: your own ID
  return say(chatId, `${await describeUser(me, '👋 This is you')}\n\nForward me a message or send @username to get someone else’s ID. /help`, [copyBtn('Copy my ID', me.id)]);
}

module.exports = { ensure, isIdBot, onMessage, USERNAME };
