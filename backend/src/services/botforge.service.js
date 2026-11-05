'use strict';

/**
 * BotForge — Hushavia's built-in bot that creates and manages other bots from a chat.
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
         VALUES (NULL, 'BotForge', $1, TRUE, TRUE, 'nobody', 'nobody', 'nobody', 'I can help you create and manage Hushavia bots.')
         ON CONFLICT DO NOTHING RETURNING id`,
        [USERNAME],
      )).rows[0];
      if (!row) return null;
      await c.query(
        `INSERT INTO bots (user_id, owner_id, token_hash, about, commands) VALUES ($1, $1, $2, $3, $4) ON CONFLICT DO NOTHING`,
        [
          row.id,
          sha256(crypto.randomBytes(32).toString('hex')), // nobody gets a token for BotForge
          'I can help you create and manage Hushavia bots. Send /newbot to start.',
          JSON.stringify(COMMANDS),
        ],
      );
      return row;
    });
    if (!u) u = await db.one(`SELECT id FROM users WHERE lower(username) = lower($1)`, [USERNAME]);
  }
  await db.query(`UPDATE bots SET commands = $2 WHERE user_id = $1`, [u.id, JSON.stringify(COMMANDS)]);
  await require('./botavatar').ensureAvatar(u.id, USERNAME); // eslint-disable-line global-require
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
  { command: 'setabouttext', description: 'Change the bot’s about text' },
  { command: 'stats', description: 'Users, groups and messages of a bot' },
  { command: 'transfer', description: 'Give a bot to someone else' },
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
  '🛠 **BotForge** — I build and manage your Hushavia bots.',
  '',
  '**Start**',
  '/newbot — create a new bot',
  '/mybots — your bots: stats, settings, links',
  '',
  '**Edit a bot**',
  '/setname — name',
  '/setdescription — what people read before they press Start',
  '/setabouttext — the short bio on the bot’s profile',
  '/setcommands — the command list (the “/” menu)',
  '/setuserpic — profile photo',
  '/setmenu — mini app for the Menu button',
  '/setprivacy — group privacy mode',
  '/setinline — inline mode (@bot query in any chat)',
  '',
  '**Keys & ownership**',
  '/token — a new API key',
  '/revoke — make a new key (the old one stops)',
  '/stats — users, groups and messages',
  '/transfer — give a bot to someone else',
  '/deletebot — delete a bot',
  '',
  `**API** · Classic (Telegram-style libraries): ${config.publicUrl}/api/classic/bot<key>/<method>`,
  `Hushavia Bot API v2: POST ${config.publicUrl}/api/bots/v2/<method> with the header “X-Bot-Key: <key>”.`,
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
      [btn(b.inline_placeholder ? '🔎 Inline: ON' : '🔎 Inline: OFF', `inl:${id}`), btn('📊 Stats', `stats:${id}`)],
      [btn('🔗 Share links', `share:${id}`), btn(b.webhook_url ? '🔌 Webhook: ON' : '🔌 Webhook: OFF', `hook:${id}`)],
      [btn('🔄 Revoke token', `rev:${id}`), btn('🤝 Transfer', `xfer:${id}`)],
      [btn('🗑 Delete bot', `del:${id}`)],
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
      [btn('Edit about text', `ebio:${id}`)],
      [btn('« Back to bot', `bot:${id}`)],
    ]),
  };
}

function tokenText(b, token) {
  return [
    `Here is the new key for @${b.username}:`,
    '',
    token,
    '',
    'Keep it secret — anyone with it can control the bot. The old key no longer works.',
    `Try it: POST ${config.publicUrl}/api/bots/v2/profile.get  (header “X-Bot-Key: <key>”)`,
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
      return say(chatId, tokenText(b, token), kb([[{ text: '📋 Copy key', copy_text: { text: token } }], [btn('« Back to bot', `bot:${b.id}`)]]));
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
    case 'stats': {
      const st = await db.one(
        `SELECT
           (SELECT count(*)::int FROM chat_members cm JOIN chats c ON c.id = cm.chat_id AND c.type = 'private' WHERE cm.user_id = $1) AS users,
           (SELECT count(*)::int FROM chat_members cm JOIN chats c ON c.id = cm.chat_id AND c.type = 'group' WHERE cm.user_id = $1) AS groups,
           (SELECT count(*)::int FROM chat_members cm JOIN chats c ON c.id = cm.chat_id AND c.type = 'channel' WHERE cm.user_id = $1) AS channels,
           (SELECT count(*)::int FROM messages WHERE sender_id = $1 AND created_at > now() - interval '1 day') AS sent_day,
           (SELECT count(*)::int FROM messages WHERE sender_id = $1 AND created_at > now() - interval '7 days') AS sent_week,
           (SELECT count(*)::int FROM messages m JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = $1
              JOIN chats c ON c.id = m.chat_id AND c.type = 'private'
            WHERE m.sender_id <> $1 AND m.created_at > now() - interval '1 day') AS got_day,
           (SELECT count(*)::int FROM bot_updates WHERE bot_id = $1) AS pending,
           (SELECT max(created_at) FROM messages WHERE sender_id = $1) AS last_sent`,
        [b.id],
      );
      const ago = st.last_sent ? `${Math.max(1, Math.round((Date.now() - new Date(st.last_sent).getTime()) / 60000))} min ago` : 'never';
      return show({
        text: [
          `📊 **@${b.username}** — stats`,
          '',
          `👤 Users: ${st.users}`,
          `👥 Groups: ${st.groups} · 📣 Channels: ${st.channels}`,
          '',
          `📨 Messages to the bot (24 h): ${st.got_day}`,
          `📤 Sent by the bot: ${st.sent_day} today · ${st.sent_week} this week`,
          `🕓 Last message sent: ${ago}`,
          `📥 Updates waiting to be read: ${st.pending}${st.pending > 50 ? ' ⚠️ is your bot running?' : ''}`,
        ].join('\n'),
        markup: kb([[btn('🔄 Refresh', `stats:${b.id}`)], [btn('« Back to bot', `bot:${b.id}`)]]),
      });
    }
    case 'share': {
      const url = link(b.username);
      return show({
        text: [
          `🔗 Links for @${b.username}`,
          '',
          `Open the bot: ${url}`,
          `With a start code: ${url}?start=promo1`,
          '',
          'A start code reaches your bot as “/start promo1” — use it to see where people came from (ads, channels, friends).',
        ].join('\n'),
        markup: kb([
          [{ text: '📋 Copy bot link', copy_text: { text: url } }],
          [{ text: '📋 Copy start link', copy_text: { text: `${url}?start=promo1` } }],
          [btn('« Back to bot', `bot:${b.id}`)],
        ]),
      });
    }
    case 'hook': {
      if (!b.webhook_url) {
        return show({
          text: `🔌 @${b.username} gets its updates by polling (getUpdates / events.poll).\n\nTo use a webhook, call setWebhook from your code with your https:// address.`,
          markup: kb([[btn('« Back to bot', `bot:${b.id}`)]]),
        });
      }
      return show({
        text: `🔌 Webhook for @${b.username}:\n${b.webhook_url}\n\nRemove it to switch the bot back to polling (getUpdates).`,
        markup: kb([[btn('🧹 Remove webhook', `hookoff:${b.id}`)], [btn('« Back to bot', `bot:${b.id}`)]]),
      });
    }
    case 'hookoff':
      await db.query('UPDATE bots SET webhook_url = NULL WHERE user_id = $1 AND owner_id = $2', [b.id, userId]);
      return show(botCard(await ownedBot(userId, b.id)));
    case 'ebio':
      await setState(userId, 'set_bio', { bot: b.id });
      return say(chatId, `OK. Send the new about text for @${b.username} — the short line on its profile (up to 120 characters). /empty clears it.`);
    case 'xfer':
      await setState(userId, 'transfer', { bot: b.id });
      return say(chatId, `🤝 Who should own @${b.username} from now on? Send their @username.\n\nThey get full control (keys, settings, delete) and you lose it. /cancel to stop.`);
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
  setabouttext: 'ebio',
  stats: 'stats',
  transfer: 'xfer',
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
            'Your bot key for the Hushavia Bot API:',
            r.token,
            '',
            'Keep your key secret — anyone who has it can control your bot.',
            '',
            `Hushavia Bot API v2: POST ${config.publicUrl}/api/bots/v2/<method> with the header “X-Bot-Key: <key>” — e.g. message.send {to, text, buttons}.`,
          ].join('\n'),
          kb([[{ text: '📋 Copy key', copy_text: { text: r.token } }], [btn('⚙️ Manage bot', `bot:${r.bot.id}`), { text: '💬 Open bot', url: link(r.bot.username) }]]),
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
      case 'set_bio': {
        const b = await ownedBot(userId, data.bot);
        if (!b) throw new Error('That bot wasn’t found.');
        const bio = text === '/empty' ? '' : text;
        if ([...bio].length > 120) return say(chatId, 'That’s longer than 120 characters — try a shorter line.');
        await db.query('UPDATE users SET bio = $2, updated_at = now() WHERE id = $1', [b.id, bio]);
        bus.emit('user:updated', { userId: b.id });
        await clearState(userId);
        return say(chatId, 'Success! About text updated.', kb([[btn('« Back to bot', `bot:${b.id}`)]]));
      }
      case 'transfer': {
        const b = await ownedBot(userId, data.bot);
        if (!b) throw new Error('That bot wasn’t found.');
        const to = await db.one(`SELECT id, first_name, username FROM users WHERE lower(username) = lower($1) AND NOT is_bot AND status = 'active'`, [text.replace(/^@/, '')]);
        if (!to) return say(chatId, 'I couldn’t find that person. Send their @username (not a bot), or /cancel.');
        if (to.id === userId) return say(chatId, 'That’s you 🙂 Send someone else’s @username, or /cancel.');
        await setState(userId, 'transfer_confirm', { bot: b.id, to: to.id });
        return say(chatId, `Give @${b.username} to ${to.first_name} (@${to.username})? This can’t be undone by you.`, kb([[btn('🤝 Yes, transfer', `xferyes:${b.id}`)], [btn('Cancel', `bot:${b.id}`)]]));
      }
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
    if (action === 'xferyes') {
      const st = await getState(userId);
      const b = await ownedBot(userId, id);
      if (!st || st.step !== 'transfer_confirm' || !b || Number(st.data.bot) !== b.id) return say(chatId, 'That transfer expired. Start again with /transfer.');
      const max = await require('./settings.service').get('max_bots_per_user'); // eslint-disable-line global-require
      const n = await db.one('SELECT count(*)::int AS n FROM bots WHERE owner_id = $1', [st.data.to]);
      if (n.n >= max) return say(chatId, `They already have ${max} bots — the most anyone can have.`);
      await db.query('UPDATE bots SET owner_id = $2 WHERE user_id = $1 AND owner_id = $3', [b.id, st.data.to, userId]);
      await clearState(userId);
      // tell the new owner (in their BotForge chat, if they have one)
      const me = await ensure();
      const theirs = await db.one(
        `SELECT c.id FROM chats c JOIN chat_members a ON a.chat_id = c.id AND a.user_id = $1 JOIN chat_members t ON t.chat_id = c.id AND t.user_id = $2 WHERE c.type = 'private' LIMIT 1`,
        [me, st.data.to],
      );
      if (theirs) await say(theirs.id, `🤝 You now own @${b.username}. Send /mybots to manage it — make a new key with /token.`).catch(() => {});
      return say(chatId, `✅ @${b.username} now belongs to its new owner.`, kb([[btn('« Back to bot list', 'list')]]));
    }
    if (action === 'new') {
      await setState(userId, 'new_name');
      return say(chatId, 'Alright, a new bot. How are we going to call it? Please choose a name for your bot.');
    }
    return runAction(userId, chatId, action, id, ['tok', 'revyes', 'menu', 'inl', 'ename', 'edesc', 'ecmd', 'epic', 'ebio', 'xfer'].includes(action) ? null : messageId);
  } catch (err) {
    return say(chatId, `⚠️ ${err.message || 'Something went wrong'}`);
  }
}

function isBotForge(id) {
  return cachedId !== null && Number(id) === cachedId;
}

module.exports = { ensure, onMessage, onCallback, isBotForge, USERNAME };
