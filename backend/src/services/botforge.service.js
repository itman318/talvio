'use strict';

/**
 * BotForge — Talvio's built-in bot that creates and manages other bots from a chat.
 * Lives inside the server: messages to @BotForge are answered here (no token, no webhook).
 *
 *   /newbot      create a bot (name → username → token)
 *   /mybots      buttons for every bot you own: token, edit name/description/about/commands/photo,
 *                mini app, group privacy, inline mode, revoke token, delete
 *   /token /revoke /setname /setdescription /setcommands /setuserpic /setmenu /setprivacy /deletebot
 *   /cancel      stop the current step
 */
const crypto = require('crypto');
const db = require('../db');
const bus = require('../bus');
const config = require('../config');
const { sha256 } = require('../utils/crypto');

const USERNAME = 'BotForge';
let cachedId = null;

const lazy = {
  bots: () => require('./bot.service'), // eslint-disable-line global-require
  messages: () => require('./message.service'), // eslint-disable-line global-require
};

/** Creates the BotForge account once; returns its user id. */
async function ensure() {
  if (cachedId) return cachedId;
  // the system bot owns itself (also finds it under an older name and renames it)
  let u = await db.one(`SELECT u.id FROM bots b JOIN users u ON u.id = b.user_id WHERE b.owner_id = b.user_id AND u.is_bot ORDER BY u.id LIMIT 1`);
  if (u) {
    await db.query(
      `UPDATE users SET username = $2, first_name = 'BotForge', is_verified = TRUE WHERE id = $1 AND (username IS DISTINCT FROM $2 OR first_name <> 'BotForge')`,
      [u.id, USERNAME],
    ).catch(() => {});
  }
  if (!u) {
    u = await db.tx(async (c) => {
      const row = (await c.query(
        `INSERT INTO users (phone, first_name, username, is_bot, is_verified, privacy_phone, privacy_group_add, privacy_calls, bio)
         VALUES (NULL, 'BotForge', $1, TRUE, TRUE, 'nobody', 'nobody', 'nobody', 'I can help you create and manage Talvio bots.')
         ON CONFLICT DO NOTHING RETURNING id`,
        [USERNAME],
      )).rows[0];
      if (!row) return null;
      await c.query(
        `INSERT INTO bots (user_id, owner_id, token_hash, about, commands) VALUES ($1, $1, $2, $3, $4) ON CONFLICT DO NOTHING`,
        [
          row.id,
          sha256(crypto.randomBytes(32).toString('hex')), // nobody gets a token for BotForge
          'I can help you create and manage Talvio bots. Send /newbot to start.',
          JSON.stringify(COMMANDS),
        ],
      );
      return row;
    });
    if (!u) u = await db.one(`SELECT id FROM users WHERE lower(username) = lower($1)`, [USERNAME]);
  }
  await db.query(`UPDATE bots SET commands = $2 WHERE user_id = $1`, [u.id, JSON.stringify(COMMANDS)]);
  cachedId = u.id;
  return cachedId;
}

const COMMANDS = [
  { command: 'newbot', description: 'Create a new bot' },
  { command: 'mybots', description: 'Edit your bots' },
  { command: 'token', description: 'Get a bot’s API token' },
  { command: 'revoke', description: 'Make a new token (the old one stops working)' },
  { command: 'setname', description: 'Change a bot’s name' },
  { command: 'setdescription', description: 'Change the text people see before they start the bot' },
  { command: 'setcommands', description: 'Change the list of commands' },
  { command: 'setuserpic', description: 'Change a bot’s profile photo' },
  { command: 'setmenu', description: 'Set the mini app opened by the Menu button' },
  { command: 'setprivacy', description: 'Group privacy mode' },
  { command: 'setinline', description: 'Inline mode (@bot query in any chat)' },
  { command: 'deletebot', description: 'Delete a bot' },
  { command: 'help', description: 'What I can do' },
  { command: 'cancel', description: 'Stop the current step' },
];

// ------------------------------------------------------------------ state
async function getState(userId) {
  return db.one('SELECT step, data FROM botfather_state WHERE user_id = $1 AND updated_at > now() - interval \'1 hour\'', [userId]);
}
async function setState(userId, step, data = {}) {
  await db.query(
    `INSERT INTO botfather_state (user_id, step, data, updated_at) VALUES ($1, $2, $3, now())
     ON CONFLICT (user_id) DO UPDATE SET step = $2, data = $3, updated_at = now()`,
    [userId, step, JSON.stringify(data)],
  );
}
async function clearState(userId) {
  await db.query('DELETE FROM botfather_state WHERE user_id = $1', [userId]);
}

// ------------------------------------------------------------------ replies
async function say(chatId, text, markup = null) {
  const bf = await ensure();
  await lazy.messages().sendMessage(bf, chatId, { type: 'text', text }, { replyMarkup: markup, skipRateLimit: true });
}

async function edit(chatId, messageId, text, markup = null) {
  const bf = await ensure();
  const m = await db.one('SELECT id FROM messages WHERE id = $1 AND chat_id = $2 AND sender_id = $3 AND deleted_at IS NULL', [messageId, chatId, bf]);
  if (!m) return say(chatId, text, markup);
  await db.query('UPDATE messages SET text = $2, reply_markup = $3, edited_at = now() WHERE id = $1', [m.id, text, markup ? JSON.stringify(markup) : null]);
  const map = await lazy.messages().serializeByIds(0, [m.id]);
  const members = await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId]);
  bus.emit('message:edited', { chatId, message: map.get(m.id), memberIds: members.map((r) => r.user_id) });
  return null;
}

const kb = (rows) => ({ inline_keyboard: rows });
const btn = (text, data) => ({ text, callback_data: data });
const link = (username) => `${config.publicUrl}/c/${username}`;

const HELP = [
  'Hi, I’m BotForge 🛠 — I build and manage Talvio bots for you.',
  '',
  'You can control me with these commands:',
  '',
  '/newbot — create a new bot',
  '/mybots — edit your bots',
  '',
  'Edit bots',
  '/setname — change a bot’s name',
  '/setdescription — change the bot description',
  '/setcommands — change the list of commands',
  '/setuserpic — change the bot’s profile photo',
  '/setmenu — the mini app for the Menu button',
  '/setprivacy — group privacy mode',
  '/setinline — inline mode (@bot query in any chat)',
  '/token — get the API token',
  '/revoke — make a new token',
  '/deletebot — delete a bot',
  '',
  `Bot API: POST ${config.publicUrl}/api/bot/v1/<method> with the header “Authorization: Bearer <token>”.`,
].join('\n');

async function myBots(ownerId) {
  return db.many(
    `SELECT u.id, u.first_name, u.username, b.about, b.commands, b.menu_url, b.group_privacy, b.status, b.webhook_url, b.inline_placeholder,
            (SELECT count(*)::int FROM chat_members cm WHERE cm.user_id = u.id) AS chats
     FROM bots b JOIN users u ON u.id = b.user_id
     WHERE b.owner_id = $1 AND u.status <> 'deleted' AND u.id <> b.owner_id ORDER BY b.created_at DESC`,
    [ownerId],
  );
}

async function ownedBot(ownerId, botId) {
  const rows = await myBots(ownerId);
  return rows.find((b) => b.id === Number(botId)) || null;
}

async function listMessage(ownerId, action = 'bot') {
  const bots = await myBots(ownerId);
  if (!bots.length) return { text: 'You don’t have any bots yet. Send /newbot to create one.', markup: kb([[btn('➕ Create a new bot', 'new')]]) };
  const rows = [];
  for (let i = 0; i < bots.length; i += 2) rows.push(bots.slice(i, i + 2).map((b) => btn(`@${b.username}`, `${action}:${b.id}`)));
  if (action === 'bot') rows.push([btn('➕ Create a new bot', 'new')]);
  return { text: action === 'bot' ? 'Choose a bot from the list below:' : 'Choose a bot:', markup: kb(rows) };
}

function botCard(b) {
  const cmds = (b.commands || []).length;
  const text = [
    `🤖 ${b.first_name} — @${b.username}`,
    '',
    b.about ? `📝 ${b.about}` : '📝 No description yet',
    `⌨️ ${cmds} command${cmds === 1 ? '' : 's'} · 💬 ${b.chats} chat${b.chats === 1 ? '' : 's'}`,
    `🔒 Group privacy: ${b.group_privacy ? 'on (only commands, mentions and replies)' : 'off (sees every message)'}`,
    `🔌 Updates: ${b.webhook_url ? 'webhook' : 'long polling (updates)'}`,
    `🔎 Inline mode: ${b.inline_placeholder ? `on (“${b.inline_placeholder}”)` : 'off'}`,
    b.menu_url ? `📱 Mini app: ${b.menu_url}` : null,
    b.status !== 'active' ? '⛔ Disabled by the moderators' : null,
    '',
    `🔗 ${link(b.username)}`,
    '',
    'What do you want to do with the bot?',
  ].filter((x) => x !== null).join('\n');
  const id = b.id;
  return {
    text,
    markup: kb([
      [btn('🔑 API token', `tok:${id}`), btn('✏️ Edit bot', `edit:${id}`)],
      [btn(b.group_privacy ? '👥 Privacy: ON' : '👥 Privacy: OFF', `priv:${id}`), btn('📱 Mini app', `menu:${id}`)],
      [btn(b.inline_placeholder ? '🔎 Inline: ON' : '🔎 Inline: OFF', `inl:${id}`)],
      [btn('🔄 Revoke token', `rev:${id}`), btn('🗑 Delete bot', `del:${id}`)],
      [btn('« Back to bot list', 'list')],
    ]),
  };
}

function editCard(b) {
  const id = b.id;
  return {
    text: `Edit @${b.username}\n\nName: ${b.first_name}\nDescription: ${b.about || '—'}\nCommands: ${(b.commands || []).map((c) => `/${c.command}`).join(' ') || '—'}`,
    markup: kb([
      [btn('Edit name', `ename:${id}`), btn('Edit description', `edesc:${id}`)],
      [btn('Edit commands', `ecmd:${id}`), btn('Edit photo', `epic:${id}`)],
      [btn('« Back to bot', `bot:${id}`)],
    ]),
  };
}

function tokenText(b, token) {
  return [
    `Here is the token for @${b.username}:`,
    '',
    token,
    '',
    'Keep it secret — anyone with it can control the bot.',
    `API: ${config.publicUrl}/api/bot/v1/me  (header “Authorization: Bearer <token>”)`,
  ].join('\n');
}

function parseCommandsText(text) {
  return String(text)
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      const m = l.match(/^\/?([A-Za-z0-9_]{1,32})\s*[-–—:]\s*(.+)$/);
      if (!m) throw new Error(`I couldn’t read “${l}”. Use: command - description`);
      return { command: m[1].toLowerCase(), description: m[2].slice(0, 256) };
    });
}

// ------------------------------------------------------------------ actions shared by commands & buttons
async function runAction(userId, chatId, action, botId, messageId = null) {
  const b = await ownedBot(userId, botId);
  if (!b) return say(chatId, 'That bot wasn’t found. Send /mybots to see your bots.');
  const show = (card) => (messageId ? edit(chatId, messageId, card.text, card.markup) : say(chatId, card.text, card.markup));
  const bots = lazy.bots();
  switch (action) {
    case 'bot':
      await clearState(userId);
      return show(botCard(b));
    case 'edit':
      return show(editCard(b));
    case 'tok':
    case 'rev': {
      if (action === 'tok') {
        // tokens are stored hashed: showing it means issuing a fresh one
        await say(chatId, 'For safety I only keep a fingerprint of your token, so I can’t show the old one. Tap below to make a new token (the old one stops working).', kb([[btn('🔄 Make a new token', `revyes:${b.id}`)], [btn('« Back', `bot:${b.id}`)]]));
        return null;
      }
      return show({
        text: `Make a new token for @${b.username}? The current token will stop working immediately.`,
        markup: kb([[btn('Yes, make a new token', `revyes:${b.id}`)], [btn('« Back', `bot:${b.id}`)]]),
      });
    }
    case 'revyes': {
      const { token } = await bots.regenerateToken(userId, b.id);
      return say(chatId, tokenText(b, token), kb([[{ text: '📋 Copy token', copy_text: { text: token } }], [btn('« Back to bot', `bot:${b.id}`)]]));
    }
    case 'priv': {
      await bots.updateBot(userId, b.id, { group_privacy: !b.group_privacy });
      return show(botCard(await ownedBot(userId, b.id)));
    }
    case 'menu':
      await setState(userId, 'set_menu', { bot: b.id });
      return say(chatId, `Send the https:// address of the mini app for @${b.username}'s Menu button.\nSend /empty to remove it, or /cancel to stop.`);
    case 'inl':
      await setState(userId, 'set_inline', { bot: b.id });
      return say(chatId, `Inline mode lets people type @${b.username} and a query in any chat. Your bot gets an "inline_query" update and answers with inline.answer.\n\nSend the placeholder shown in the message box (e.g. “Search gold prices…”), or /empty to turn inline mode off.`);
    case 'ename':
      await setState(userId, 'set_name', { bot: b.id });
      return say(chatId, `OK. Send the new name for @${b.username}.`);
    case 'edesc':
      await setState(userId, 'set_about', { bot: b.id });
      return say(chatId, `OK. Send the new description for @${b.username} (people see it before they press Start). Up to 512 characters. /empty clears it.`);
    case 'ecmd':
      await setState(userId, 'set_commands', { bot: b.id });
      return say(chatId, `OK. Send the list of commands for @${b.username}, one per line:\n\nstart - Start the bot\nhelp - How it works\nprice - Today’s prices\n\nSend /empty to remove all commands.`);
    case 'epic':
      await setState(userId, 'set_photo', { bot: b.id });
      return say(chatId, `OK. Send me the new profile photo for @${b.username}.`);
    case 'del':
      return show({
        text: `Delete @${b.username}? This can’t be undone and the username becomes free.`,
        markup: kb([[btn('Yes, delete the bot', `delyes:${b.id}`)], [btn('No', `bot:${b.id}`)]]),
      });
    case 'delyes':
      await bots.deleteBot(userId, b.id);
      return show({ text: `Done! @${b.username} was deleted.`, markup: kb([[btn('« Back to bot list', 'list')]]) });
    default:
      return null;
  }
}

const COMMAND_ACTIONS = {
  token: 'tok',
  revoke: 'rev',
  setname: 'ename',
  setdescription: 'edesc',
  setabout: 'edesc',
  setcommands: 'ecmd',
  setuserpic: 'epic',
  setmenu: 'menu',
  setprivacy: 'priv',
  setinline: 'inl',
  deletebot: 'del',
};

// ------------------------------------------------------------------ incoming
async function onMessage(userId, chatId, row) {
  const text = String(row.text || '').trim();
  const bots = lazy.bots();
  if (text.startsWith('/')) {
    const cmd = text.slice(1).split(/[\s@]/)[0].toLowerCase();
    if (cmd === 'cancel') {
      const st = await getState(userId);
      await clearState(userId);
      return say(chatId, st ? 'Stopped. Anything else? Send /help for the list of commands.' : 'Nothing to stop. Send /help for the list of commands.');
    }
    if (cmd === 'start' || cmd === 'help') {
      await clearState(userId);
      return say(chatId, HELP, kb([[btn('➕ New bot', 'new'), btn('🤖 My bots', 'list')]]));
    }
    if (cmd === 'newbot') {
      await setState(userId, 'new_name');
      return say(chatId, 'Alright, a new bot. How are we going to call it? Please choose a name for your bot.');
    }
    if (cmd === 'mybots') {
      await clearState(userId);
      const l = await listMessage(userId);
      return say(chatId, l.text, l.markup);
    }
    if (COMMAND_ACTIONS[cmd]) {
      await clearState(userId);
      const l = await listMessage(userId, COMMAND_ACTIONS[cmd]);
      return say(chatId, l.text, l.markup);
    }
    const st = await getState(userId);
    if (!(st && text === '/empty')) return say(chatId, 'Unrecognized command. Send /help to see what I can do.');
  }

  const st = await getState(userId);
  if (!st) return say(chatId, 'I can help you create and manage bots. Send /newbot to create one, or /help to see everything.');
  const data = st.data || {};
  try {
    switch (st.step) {
      case 'new_name': {
        if (!text || text.length > 64) return say(chatId, 'The name should be 1–64 characters. Try again.');
        await setState(userId, 'new_username', { name: text });
        return say(chatId, 'Good. Now let’s choose a username for your bot. It must end in “bot”, like weather_bot or ShopBot.');
      }
      case 'new_username': {
        const username = text.replace(/^@/, '');
        const r = await bots.createBot(userId, { name: data.name, username });
        await clearState(userId);
        return say(
          chatId,
          [
            `Done! Congratulations on your new bot. You will find it at ${link(r.bot.username)}`,
            '',
            'You can now add a description, commands and a profile photo — see /mybots.',
            '',
            'Use this token to access the Bot API:',
            r.token,
            '',
            'Keep your token secure and store it safely — it can be used by anyone to control your bot.',
            '',
            `Bot API: POST ${config.publicUrl}/api/bot/v1/<method> with “Authorization: Bearer <token>”.`,
          ].join('\n'),
          kb([[{ text: '📋 Copy token', copy_text: { text: r.token } }], [btn('⚙️ Manage bot', `bot:${r.bot.id}`), { text: '💬 Open bot', url: link(r.bot.username) }]]),
        );
      }
      case 'set_name':
        await bots.updateBot(userId, data.bot, { name: text });
        await clearState(userId);
        return say(chatId, 'Success! Name updated.', kb([[btn('« Back to bot', `bot:${data.bot}`)]]));
      case 'set_about':
        await bots.updateBot(userId, data.bot, { about: text === '/empty' ? '' : text });
        await clearState(userId);
        return say(chatId, 'Success! Description updated.', kb([[btn('« Back to bot', `bot:${data.bot}`)]]));
      case 'set_commands': {
        const list = text === '/empty' ? [] : parseCommandsText(text);
        await bots.updateBot(userId, data.bot, { commands: list });
        await clearState(userId);
        return say(chatId, `Success! ${list.length ? `${list.length} command${list.length === 1 ? '' : 's'} saved.` : 'Commands removed.'}`, kb([[btn('« Back to bot', `bot:${data.bot}`)]]));
      }
      case 'set_inline':
        await bots.updateBot(userId, data.bot, { inline_placeholder: text === '/empty' ? null : text });
        await clearState(userId);
        return say(chatId, text === '/empty' ? 'Inline mode is off.' : 'Success! Inline mode is on.', kb([[btn('« Back to bot', `bot:${data.bot}`)]]));
      case 'set_menu':
        await bots.updateBot(userId, data.bot, { menu_url: text === '/empty' ? null : text });
        await clearState(userId);
        return say(chatId, text === '/empty' ? 'Menu mini app removed.' : 'Success! The Menu button now opens your mini app.', kb([[btn('« Back to bot', `bot:${data.bot}`)]]));
      case 'set_photo': {
        if (row.type !== 'image' || !row.media_id) return say(chatId, 'Please send a photo (or /cancel).');
        const b = await ownedBot(userId, data.bot);
        if (!b) throw new Error('That bot wasn’t found.');
        await db.query('UPDATE media SET is_public = TRUE WHERE id = $1', [row.media_id]);
        await db.query('UPDATE users SET avatar_media_id = $2, updated_at = now() WHERE id = $1', [b.id, row.media_id]);
        bus.emit('user:updated', { userId: b.id });
        await clearState(userId);
        return say(chatId, 'Success! Profile photo updated.', kb([[btn('« Back to bot', `bot:${b.id}`)]]));
      }
      default:
        await clearState(userId);
        return say(chatId, 'Send /help to see what I can do.');
    }
  } catch (err) {
    return say(chatId, `⚠️ ${err.message || 'Something went wrong'}\nTry again, or /cancel.`);
  }
}

/** Inline button pressed in a BotForge message. */
async function onCallback(userId, chatId, messageId, data) {
  const [action, id] = String(data).split(':');
  try {
    if (action === 'list') {
      const l = await listMessage(userId);
      return edit(chatId, messageId, l.text, l.markup);
    }
    if (action === 'new') {
      await setState(userId, 'new_name');
      return say(chatId, 'Alright, a new bot. How are we going to call it? Please choose a name for your bot.');
    }
    return runAction(userId, chatId, action, id, ['tok', 'revyes', 'menu', 'inl', 'ename', 'edesc', 'ecmd', 'epic'].includes(action) ? null : messageId);
  } catch (err) {
    return say(chatId, `⚠️ ${err.message || 'Something went wrong'}`);
  }
}

function isBotForge(id) {
  return cachedId !== null && Number(id) === cachedId;
}

module.exports = { ensure, onMessage, onCallback, isBotForge, USERNAME };
