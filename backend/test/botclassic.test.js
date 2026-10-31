'use strict';

/** Talvio Bot API — Classic: classic-library-shaped requests and responses. WARNING: wipes the test DB. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const config = require('../src/config');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const settings = require('../src/services/settings.service');
const bots = require('../src/services/bot.service');
const classic = require('../src/services/botclassic.service');

// the fields classic libraries insist on (checked against a popular Python library's models)
const REQUIRED = {
  message: ['message_id', 'date', 'chat'],
  user: ['id', 'is_bot', 'first_name'],
  chat: ['id', 'type'],
  callback_query: ['id', 'chat_instance', 'from'],
  photo: ['file_id', 'file_unique_id', 'width', 'height'],
  document: ['file_id', 'file_unique_id'],
};
function has(obj, keys, what) {
  for (const k of keys) assert.ok(obj[k] !== undefined && obj[k] !== null, `${what}.${k} is missing`);
}
function checkMessage(m) {
  has(m, REQUIRED.message, 'message');
  has(m.chat, REQUIRED.chat, 'message.chat');
  if (m.from) has(m.from, REQUIRED.user, 'message.from');
  if (m.photo) {
    assert.ok(Array.isArray(m.photo), 'photo must be a list of sizes');
    has(m.photo[0], REQUIRED.photo, 'photo[0]');
  }
  if (m.document) has(m.document, REQUIRED.document, 'document');
  if (m.reply_to_message) checkMessage(m.reply_to_message);
}

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.50.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [s.user.id]);
  return { id: s.user.id };
}
const flush = (ms = 250) => new Promise((r) => setTimeout(r, ms));

let OWNER;
let U;
let TOKEN; // "<id>:<secret>"
let BOT_ID;
let CHAT;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  OWNER = await signup('+923290000001', 'Owner');
  U = await signup('+923290000002', 'Usman');
  const r = await bots.createBot(OWNER.id, { name: 'Signals', username: 'xau_signals_bot' });
  TOKEN = r.classic_token;
  BOT_ID = r.bot.id;
  assert.match(TOKEN, /^\d+:[A-Za-z0-9]{20,}$/);
  CHAT = await chats.getOrCreatePrivate(U.id, BOT_ID);
});
test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  await db.close();
});

test('formatting: HTML, MarkdownV2 and Markdown become Talvio marks', () => {
  assert.equal(classic.formatText('<b>Buy</b> <i>XAUUSD</i> &amp; <code>2350</code> <a href="https://t.co/x">chart</a><br>TP', 'HTML'), '**Buy** _XAUUSD_ & `2350` chart (https://t.co/x)\nTP');
  assert.equal(classic.formatText('*Done* \\! SL\\: 2340 _now_', 'MarkdownV2'), '**Done** ! SL: 2340 _now_');
  assert.equal(classic.formatText('*bold* [site](https://a.b)', 'Markdown'), '**bold** site (https://a.b)');
  assert.equal(classic.formatText('plain *x*', undefined), 'plain *x*');
});

test('getMe, bad token, unknown method', async () => {
  const me = await classic.call(TOKEN, 'getMe', {});
  assert.equal(me.id, BOT_ID);
  assert.equal(me.is_bot, true);
  assert.equal(me.username, 'xau_signals_bot');
  await assert.rejects(classic.call('123:abcdefghijklmnopqrstuvwxyz', 'getMe', {}), (e) => classic.errorBody(e).status === 401);
  await assert.rejects(classic.call(TOKEN, 'sendDice', {}), (e) => {
    const { status, body } = classic.errorBody(e);
    assert.equal(status, 404);
    assert.equal(body.ok, false);
    assert.match(body.description, /^Not Found/);
    return true;
  });
});

test('updates: a user message arrives in the classic shape', async () => {
  await messages.sendMessage(U.id, CHAT.id, { text: '/start' });
  await flush();
  const ups = await classic.call(TOKEN, 'getUpdates', { offset: '0', timeout: '0' });
  assert.ok(ups.length >= 1);
  const m = ups[ups.length - 1].message;
  checkMessage(m);
  assert.equal(m.text, '/start');
  assert.equal(m.chat.id, CHAT.id);
  await classic.call(TOKEN, 'getUpdates', { offset: String(ups[ups.length - 1].update_id + 1) });
});

test('sendMessage: form-style params, HTML, inline keyboard, reply_parameters', async () => {
  const first = await db.one('SELECT id FROM messages WHERE chat_id = $1 ORDER BY id DESC LIMIT 1', [CHAT.id]);
  const res = await classic.call(TOKEN, 'sendMessage', {
    chat_id: String(CHAT.id),
    text: '<b>Gold</b> signal: <i>BUY</i>',
    parse_mode: 'HTML',
    reply_markup: JSON.stringify({ inline_keyboard: [[{ text: 'Join VIP', callback_data: 'vip' }]] }),
    reply_parameters: JSON.stringify({ message_id: first.id }),
  });
  checkMessage(res);
  assert.equal(res.text, '**Gold** signal: _BUY_');
  assert.equal(res.reply_to_message.message_id, Number(first.id));
  const row = await db.one('SELECT text, reply_markup FROM messages WHERE id = $1', [res.message_id]);
  assert.equal(row.reply_markup.inline_keyboard[0][0].callback_data, 'vip');
});

test('buttons: callback_query has chat_instance; answer + edit with MarkdownV2', async () => {
  const msg = await db.one('SELECT id FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id DESC LIMIT 1', [CHAT.id, BOT_ID]);
  await bots.pressButton(U.id, msg.id, { data: 'vip' });
  const ups = await classic.call(TOKEN, 'getUpdates', {});
  const cq = ups.find((u) => u.callback_query).callback_query;
  has(cq, REQUIRED.callback_query, 'callback_query');
  checkMessage(cq.message);
  assert.equal(cq.data, 'vip');
  assert.equal(await classic.call(TOKEN, 'answerCallbackQuery', { callback_query_id: cq.id, text: 'Welcome!' }), true);
  const ed = await classic.call(TOKEN, 'editMessageText', { chat_id: CHAT.id, message_id: msg.id, text: '*VIP* unlocked \\!', parse_mode: 'MarkdownV2' });
  assert.equal(ed.text, '**VIP** unlocked !');
  await classic.call(TOKEN, 'getUpdates', { offset: String(ups[ups.length - 1].update_id + 1) });
});

test('files: upload a document, getFile, then resend a photo by file_id', async () => {
  const dir = path.join(config.uploadDir, 'test');
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, `chart-${Date.now()}.pdf`);
  fs.writeFileSync(f, '%PDF-1.4 test');
  const doc = await classic.call(TOKEN, 'sendDocument', { chat_id: CHAT.id, caption: '<b>Report</b>', parse_mode: 'HTML' }, {
    document: { path: f, size: 13, mimetype: 'application/pdf', originalname: 'report.pdf' },
  });
  checkMessage(doc);
  assert.equal(doc.caption, '**Report**');
  const info = await classic.call(TOKEN, 'getFile', { file_id: doc.document.file_id });
  assert.match(info.file_path, /^media\/\d+\//);
  const m = await classic.fileFor(TOKEN, info.file_path);
  assert.equal(String(m.id), doc.document.file_id);

  const png = path.join(dir, `p-${Date.now()}.png`);
  fs.writeFileSync(png, Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da6364f8ff1f0003030200ef9a4f1e0000000049454e44ae426082', 'hex'));
  const ph = await classic.call(TOKEN, 'sendPhoto', { chat_id: CHAT.id }, { photo: { path: png, size: 70, mimetype: 'image/png', originalname: 'p.png' } });
  checkMessage(ph);
  const again = await classic.call(TOKEN, 'sendPhoto', { chat_id: CHAT.id, photo: ph.photo[0].file_id, caption: 'again' });
  checkMessage(again);
  assert.equal(again.photo[0].file_id, ph.photo[0].file_id);
});

test('commands, chat info, members, webhook info', async () => {
  assert.equal(await classic.call(TOKEN, 'setMyCommands', { commands: JSON.stringify([{ command: 'start', description: 'Start the bot' }, { command: 'vip', description: 'VIP signals' }]) }), true);
  const cmds = await classic.call(TOKEN, 'getMyCommands', {});
  assert.equal(cmds.length, 2);
  const chat = await classic.call(TOKEN, 'getChat', { chat_id: CHAT.id });
  for (const k of ['id', 'type', 'accent_color_id', 'max_reaction_count', 'accepted_gift_types']) assert.ok(chat[k] !== undefined, k);
  const mem = await classic.call(TOKEN, 'getChatMember', { chat_id: CHAT.id, user_id: U.id });
  assert.equal(mem.status, 'member');
  assert.equal(mem.user.id, U.id);
  const wh = await classic.call(TOKEN, 'getWebhookInfo', {});
  for (const k of ['url', 'has_custom_certificate', 'pending_update_count']) assert.ok(wh[k] !== undefined, k);
  assert.equal(await classic.call(TOKEN, 'sendChatAction', { chat_id: CHAT.id, action: 'typing' }), true);
});
