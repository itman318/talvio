'use strict';

/**
 * Drives a real Telegram-style bot (aiogram, python-telegram-bot…) that runs against this server's
 * classic Bot API, the way a person would: /start, then taps buttons and reply-keyboard buttons,
 * and writes a transcript of what the bot answered.
 *
 *   node test/e2e/classic_bot_drive.js setup  → creates two users + a bot, prints env lines
 *   node test/e2e/classic_bot_drive.js drive  → plays with the bot, writes $OUT/transcript.txt
 *
 * Needs DATABASE_URL (and OTP_DEV_MODE=true) like the server.
 */
const fs = require('fs');
const path = require('path');

const db = require('../../src/db');
const rateLimit = require('../../src/utils/rateLimit');
const auth = require('../../src/services/auth.service');
const users = require('../../src/services/user.service');
const chats = require('../../src/services/chat.service');
const messages = require('../../src/services/message.service');
const bots = require('../../src/services/bot.service');

const OUT = process.env.OUT || '.';
const STATE = path.join(OUT, 'drive-state.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MAX_PRESSES = Number(process.env.MAX_PRESSES || 60);

let ip = 0;
async function signup(phone, firstName, username) {
  const addr = `10.77.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName, username });
  return s.user.id;
}

async function setup() {
  const admin = await signup('+923001110001', 'Owner', 'vault_owner');
  const user = await signup('+923001110002', 'Ali', 'vault_tester');
  const r = await bots.createBot(admin, { name: 'EliteXauVault', username: 'elitexauvault_test_bot' });
  fs.writeFileSync(STATE, JSON.stringify({ admin, user, botId: r.bot.id || r.bot.user_id }));
  process.stdout.write(`BOT_TOKEN=${r.classic_token}\nADMIN_ID=${admin}\nTEST_USER_ID=${user}\n`);
}

const lines = [];
const log = (s = '') => {
  lines.push(s);
  console.log(s); // eslint-disable-line no-console
};
const short = (t, n = 400) => {
  const x = String(t || '').replace(/\n{3,}/g, '\n\n');
  return x.length > n ? `${x.slice(0, n)}…` : x;
};

async function snapshot(chatId, botId) {
  const rows = await db.many(
    `SELECT id, type, text, reply_markup, edited_at, deleted_at, meta FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id`,
    [chatId, botId],
  );
  return new Map(rows.map((r) => [r.id, r]));
}

function describe(m) {
  const kb = m.reply_markup || {};
  const inline = (kb.inline_keyboard || []).flat().map((b) => b.text + (b.url ? ' ↗' : ''));
  const reply = (kb.keyboard || []).flat().map((b) => (typeof b === 'string' ? b : b.text));
  let s = `  [${m.type}] ${short(m.text) || '(no text)'}`;
  if (inline.length) s += `\n     buttons: ${inline.join(' | ')}`;
  if (reply.length) s += `\n     keyboard: ${reply.join(' | ')}`;
  return s;
}

/** What changed in the chat since `before`: new bot messages, edits, deletions. */
function diff(before, after) {
  const out = [];
  for (const [id, m] of after) {
    const b = before.get(id);
    if (!b) out.push({ kind: 'new', m });
    else if (String(b.edited_at) !== String(m.edited_at) || b.text !== m.text || JSON.stringify(b.reply_markup) !== JSON.stringify(m.reply_markup)) {
      if (m.deleted_at && !b.deleted_at) out.push({ kind: 'deleted', m });
      else out.push({ kind: 'edited', m });
    } else if (m.deleted_at && !b.deleted_at) out.push({ kind: 'deleted', m });
  }
  return out;
}

async function waitForReply(chatId, botId, before, ms = 6000) {
  const end = Date.now() + ms;
  let changes = [];
  while (Date.now() < end) {
    await sleep(400);
    changes = diff(before, await snapshot(chatId, botId));
    if (changes.length) {
      await sleep(900); // let follow-up messages / edits land
      return diff(before, await snapshot(chatId, botId));
    }
  }
  return changes;
}

const stats = { actions: 0, answered: 0, silent: 0, errors: 0 };

async function act(label, who, chatId, botId, fn) {
  stats.actions += 1;
  const before = await snapshot(chatId, botId);
  log(`\n▶ ${label}`);
  try {
    rateLimit.reset();
    await fn();
  } catch (e) {
    stats.errors += 1;
    log(`  ✖ could not do it: ${e.code || ''} ${e.message}`);
    return [];
  }
  const ch = await waitForReply(chatId, botId, before);
  if (!ch.length) {
    stats.silent += 1;
    log('  … no answer');
  } else stats.answered += 1;
  for (const c of ch) log(`  ${c.kind === 'new' ? '←' : c.kind === 'edited' ? '✎' : '🗑'}${describe(c.m).slice(1)}`);
  return ch.map((c) => c.m);
}

async function explore(name, who, botId) {
  const chat = await chats.getOrCreatePrivate(who, botId);
  log(`\n================ ${name} ================`);
  const queue = [];
  const seen = new Set();
  const seenText = new Set();
  const push = (ms) => {
    for (const m of ms) {
      const kb = m.reply_markup || {};
      for (const b of (kb.inline_keyboard || []).flat()) {
        if (b.callback_data && !seen.has(b.callback_data)) {
          seen.add(b.callback_data);
          queue.push({ kind: 'button', messageId: m.id, data: b.callback_data, text: b.text });
        }
      }
      for (const b of (kb.keyboard || []).flat()) {
        const t = typeof b === 'string' ? b : b.text;
        if (t && !seenText.has(t)) {
          seenText.add(t);
          queue.push({ kind: 'text', text: t });
        }
      }
    }
  };
  push(await act('/start', who, chat.id, botId, () => messages.sendMessage(who, chat.id, { text: '/start' })));
  let presses = 0;
  while (queue.length && presses < MAX_PRESSES) {
    const q = queue.shift();
    presses += 1;
    if (q.kind === 'button') {
      // the message may have been edited since: find the latest message that still has this button
      const latest = await db.one(
        `SELECT id FROM messages WHERE chat_id = $1 AND sender_id = $2 AND deleted_at IS NULL
           AND reply_markup::text LIKE '%' || $3 || '%' ORDER BY id DESC LIMIT 1`,
        [chat.id, botId, JSON.stringify(q.data).slice(1, -1)],
      );
      const mid = latest ? latest.id : q.messageId;
      push(await act(`tap “${q.text}”`, who, chat.id, botId, () => bots.pressButton(who, mid, { data: q.data })));
    } else {
      push(await act(`send “${q.text}”`, who, chat.id, botId, () => messages.sendMessage(who, chat.id, { text: q.text })));
    }
  }
  if (queue.length) log(`\n(${queue.length} more buttons not tried — limit ${MAX_PRESSES})`);
  return chat;
}

async function drive() {
  const { admin, user, botId } = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  // the bot writes to its admin first thing sometimes: open that chat so it can
  await chats.getOrCreatePrivate(admin, botId);
  await explore('A normal user', user, botId);
  await explore('The admin (ADMIN_ID)', admin, botId);
  log(`\n================ Summary ================`);
  log(`actions: ${stats.actions}, bot answered: ${stats.answered}, no answer: ${stats.silent}, could not do: ${stats.errors}`);
  fs.writeFileSync(path.join(OUT, 'transcript.txt'), lines.join('\n'));
}

(async () => {
  try {
    if (process.argv[2] === 'setup') await setup();
    else await drive();
  } catch (e) {
    console.error(e); // eslint-disable-line no-console
    process.exitCode = 1;
  } finally {
    await db.close();
  }
})();
