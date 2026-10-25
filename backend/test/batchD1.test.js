'use strict';

/**
 * Batch D1 end-to-end tests: bots (Bot API, updates, inline buttons, webhooks, mini app init data,
 * group privacy, admin disable), channel comments and group topics.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const http = require('http');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const bus = require('../src/bus');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const bots = require('../src/services/bot.service');
const topics = require('../src/services/topic.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName, username) {
  const addr = `10.10.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName, ...(username ? { username } : {}) });
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [s.user.id]);
  return { id: s.user.id };
}

const events = [];
bus.on('rt:emit', (e) => events.push(e));
const flush = () => new Promise((r) => setTimeout(r, 120)); // bus listeners are async

let A;
let B;
let bot;
let token;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923250000001', 'Asad', 'asad_dev');
  B = await signup('+923250000002', 'Bilal', 'bilal_b');
});

test.beforeEach(() => {
  events.length = 0;
  rateLimit.reset();
});

test.after(async () => {
  await db.close();
});

test('create a bot, getMe, user writes → getUpdates, bot replies with buttons, callback flow, edit', async () => {
  await rejects(bots.createBot(A.id, { name: 'Weather', username: 'weather' }), 'invalid_username');
  const created = await bots.createBot(A.id, { name: 'Weather', username: 'weather_info_bot', about: 'Shows the weather' });
  bot = created.bot;
  token = created.token;
  assert.match(token, /^tlv_\d+_[A-Za-z0-9]{20,}$/);
  await rejects(bots.createBot(B.id, { name: 'X', username: 'WEATHER_INFO_BOT' }), 'username_taken');
  assert.equal((await bots.listMyBots(A.id))[0].username, 'weather_info_bot');
  await rejects(bots.callMethod('tlv_1_wrongtokenwrongtokenwrong', 'me'), 'invalid_token');

  const me = await bots.callMethod(token, 'me');
  assert.deepEqual([me.id, me.is_bot, me.username], [bot.id, true, 'weather_info_bot']);
  await bots.callMethod(token, 'commands.set', { commands: [{ command: 'start', description: 'Start' }, { command: '/today', description: 'Today\'s weather' }] });
  assert.deepEqual((await bots.callMethod(token, 'commands.get')).map((c) => c.command), ['start', 'today']);

  // the bot can't write to someone who never opened it
  const chatAB = await chats.getOrCreatePrivate(A.id, B.id);
  await rejects(bots.callMethod(token, 'messages.send', { chat_id: chatAB.id, text: 'spam' }), 'chat_not_found');

  const chat = await chats.getOrCreatePrivate(B.id, bot.id);
  assert.equal(chat.is_bot, true);
  assert.deepEqual(chat.bot.commands.map((c) => c.command), ['start', 'today']);
  await messages.sendMessage(B.id, chat.id, { text: '/start' });
  await flush();
  const ups = await bots.callMethod(token, 'updates', {});
  assert.equal(ups.length, 1);
  assert.equal(ups[0].message.text, '/start');
  assert.equal(ups[0].message.from.username, 'bilal_b');
  assert.equal(ups[0].message.chat.id, chat.id);

  const sent = await bots.callMethod(token, 'messages.send', {
    chat_id: chat.id,
    text: 'Kaun sa shehar?',
    reply_markup: JSON.stringify({ inline_keyboard: [[{ text: 'Lahore', callback_data: 'city:lhr' }, { text: 'Karachi', callback_data: 'city:khi' }], [{ text: 'Open app', web_app: { url: 'https://example.com/app' } }]] }),
  });
  await rejects(
    bots.callMethod(token, 'messages.send', { chat_id: chat.id, text: 'x', reply_markup: { inline_keyboard: [[{ text: 'bad', callback_data: 'x'.repeat(70) }]] } }),
    'invalid_markup',
  );
  const list = await messages.listMessages(B.id, chat.id, {});
  const botMsg = list.messages.find((m) => m.id === sent.message_id);
  assert.equal(botMsg.sender.is_bot, true);
  assert.equal(botMsg.reply_markup.inline_keyboard[0][1].callback_data, 'city:khi');

  // offset confirms the first update
  await bots.callMethod(token, 'updates', { offset: ups[0].update_id + 1 });
  assert.equal((await db.one('SELECT count(*)::int AS n FROM bot_updates WHERE bot_id = $1', [bot.id])).n, 0);

  await rejects(bots.pressButton(B.id, sent.message_id, { data: 'city:isb' }), 'invalid_button');
  const press = await bots.pressButton(B.id, sent.message_id, { data: 'city:lhr' });
  const ups2 = await bots.callMethod(token, 'updates', {});
  assert.equal(ups2[0].callback_query.data, 'city:lhr');
  assert.equal(ups2[0].callback_query.id, press.callback_query_id);
  assert.equal(ups2[0].callback_query.message.message_id, sent.message_id);
  await bots.callMethod(token, 'buttons.answer', { callback_query_id: press.callback_query_id, text: 'Lahore: 31°C ☀️' });
  const ans = events.find((e) => e.event === 'bot:callback_answer');
  assert.deepEqual(ans.userIds, [B.id]);
  assert.equal(ans.payload.text, 'Lahore: 31°C ☀️');

  const edited = await bots.callMethod(token, 'messages.edit', { chat_id: chat.id, message_id: sent.message_id, text: 'Lahore: 31°C ☀️', reply_markup: '' });
  assert.equal(edited.text, 'Lahore: 31°C ☀️');
  const after = (await messages.listMessages(B.id, chat.id, {})).messages.find((m) => m.id === sent.message_id);
  assert.equal(after.reply_markup, null);
  await bots.callMethod(token, 'messages.delete', { chat_id: chat.id, message_id: sent.message_id });

  // long polling returns as soon as something arrives
  const waiting = bots.callMethod(token, 'updates', { offset: ups2[0].update_id + 1, timeout: 5 });
  await new Promise((r) => setTimeout(r, 100));
  const t0 = Date.now();
  await messages.sendMessage(B.id, chat.id, { text: 'hello?' });
  const got = await waiting;
  assert.equal(got[0].message.text, 'hello?');
  assert.ok(Date.now() - t0 < 3000);
});

test('advanced bot API: reply keyboards, chat actions, locations, pin, members, profile', async () => {
  rateLimit.reset();
  const chat = await chats.getOrCreatePrivate(B.id, bot.id);
  const kb = await bots.callMethod(token, 'messages.send', {
    chat_id: chat.id,
    text: 'Choose a city',
    reply_markup: { keyboard: [['Lahore', 'Karachi'], [{ text: 'Send my location', request_location: true }]], one_time_keyboard: true },
  });
  const row = await db.one('SELECT reply_markup FROM messages WHERE id = $1', [kb.message_id]);
  assert.equal(row.reply_markup.keyboard[0][1].text, 'Karachi');
  assert.equal(row.reply_markup.keyboard[1][0].request_location, true);
  assert.equal(row.reply_markup.one_time_keyboard, true);
  const rm = await bots.callMethod(token, 'messages.send', { chat_id: chat.id, text: 'ok', reply_markup: { remove_keyboard: true } });
  assert.equal((await db.one('SELECT reply_markup FROM messages WHERE id = $1', [rm.message_id])).reply_markup.remove_keyboard, true);
  await rejects(bots.callMethod(token, 'messages.send', { chat_id: chat.id, text: 'x', reply_markup: { keyboard: [] } }), 'invalid_markup');

  const typing = [];
  const on = (e) => e.event === 'typing' && typing.push(e);
  bus.on('rt:emit', on);
  assert.equal(await bots.callMethod(token, 'chat.action', { chat_id: chat.id, action: 'uploading_photo' }), true);
  bus.removeListener('rt:emit', on);
  assert.equal(typing[0].payload.action, 'uploading_photo');
  assert.deepEqual(typing[0].userIds, [B.id]);

  const loc = await bots.callMethod(token, 'locations.send', { chat_id: chat.id, latitude: 31.5204, longitude: 74.3587 });
  assert.equal((await db.one('SELECT type FROM messages WHERE id = $1', [loc.message_id])).type, 'location');
  assert.equal(await bots.callMethod(token, 'messages.pin', { chat_id: chat.id, message_id: loc.message_id }), true);
  assert.equal((await bots.callMethod(token, 'chats.member', { chat_id: chat.id, user_id: B.id })).user.id, B.id);
  assert.equal(await bots.callMethod(token, 'chats.member-count', { chat_id: chat.id }), 2);
  await bots.callMethod(token, 'me.set', { name: 'Weather Pro', description: 'Forecasts for every city' });
  const u = await db.one('SELECT u.first_name, b.about FROM users u JOIN bots b ON b.user_id = u.id WHERE u.id = $1', [bot.id]);
  assert.equal(u.first_name, 'Weather Pro');
  assert.equal(u.about, 'Forecasts for every city');
});

test('groups: privacy mode delivers only commands, mentions and replies', async () => {
  const g = (await chats.createGroup(A.id, { title: 'Dev', member_ids: [B.id, bot.id] })).chat;
  await bots.callMethod(token, 'updates', { offset: 1e12 }); // clear
  await messages.sendMessage(B.id, g.id, { text: 'normal chat message' });
  await messages.sendMessage(B.id, g.id, { text: '/today@weather_info_bot' });
  await messages.sendMessage(A.id, g.id, { text: 'hey @weather_info_bot how are you' });
  await flush();
  const ups = await bots.callMethod(token, 'updates', {});
  assert.deepEqual(ups.map((u) => u.message.text), ['/today@weather_info_bot', 'hey @weather_info_bot how are you']);
  assert.equal(ups[0].message.chat.type, 'group');
  assert.equal(ups[0].message.chat.title, 'Dev');

  await bots.updateBot(A.id, bot.id, { group_privacy: false });
  await bots.callMethod(token, 'updates', { offset: ups[1].update_id + 1 });
  await messages.sendMessage(B.id, g.id, { text: 'now the bot sees everything' });
  await flush();
  assert.equal((await bots.callMethod(token, 'updates', {}))[0].message.text, 'now the bot sees everything');
});

test('webhook delivery with secret header; getUpdates refused while a webhook is set', async () => {
  const received = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      received.push({ secret: req.headers['x-talvio-webhook-secret'], body: JSON.parse(body) });
      res.end('ok');
    });
  });
  await new Promise((r) => server.listen(0, r));
  const url = `http://127.0.0.1:${server.address().port}/hook`;
  await bots.callMethod(token, 'updates', { offset: 1e12 });
  await bots.callMethod(token, 'webhook.set', { url, secret_token: 'shh_123' });
  await rejects(bots.callMethod(token, 'updates', {}), 'webhook_active');
  const chat = await chats.getOrCreatePrivate(B.id, bot.id);
  await messages.sendMessage(B.id, chat.id, { text: 'via webhook' });
  for (let i = 0; i < 30 && !received.length; i++) await new Promise((r) => setTimeout(r, 50));
  assert.equal(received[0].secret, 'shh_123');
  assert.equal(received[0].body.message.text, 'via webhook');
  assert.ok(received[0].body.update_id > 0);
  assert.equal((await bots.callMethod(token, 'webhook.info')).pending_update_count, 0);
  server.close();
  await bots.callMethod(token, 'webhook.delete', { drop_pending_updates: true });
});

test('mini app init data is signed so the bot server can verify it; web_app_data reaches the bot', async () => {
  const init = await bots.webAppInit(B.id, bot.id, {});
  assert.equal(bots.verifyInitData(init.init_data, token), true);
  assert.equal(bots.verifyInitData(init.init_data, `${bot.id}:someoneelsestokenxxxxxxxx`), false);
  const tampered = init.init_data.replace('Bilal', 'Mallory');
  assert.equal(bots.verifyInitData(tampered, token), false);
  assert.equal(JSON.parse(new URLSearchParams(init.init_data).get('user')).id, B.id);

  await bots.webAppData(B.id, bot.id, { data: '{"order":42}', button_text: 'Order' });
  const ups = await bots.callMethod(token, 'updates', {});
  assert.equal(ups.at(-1).message.web_app_data.data, '{"order":42}');
});

test('admin can disable a bot; regenerating the token kills the old one; deleting frees the username', async () => {
  await bots.adminSetStatus(bot.id, false, 'spam');
  await rejects(bots.callMethod(token, 'me'), 'bot_disabled');
  await bots.adminSetStatus(bot.id, true);
  const { token: t2 } = await bots.regenerateToken(A.id, bot.id);
  await rejects(bots.callMethod(token, 'me'), 'invalid_token');
  assert.equal((await bots.callMethod(t2, 'me')).id, bot.id);
  const listed = await bots.adminList({ q: 'weather' });
  assert.equal(listed.bots[0].owner.username, 'asad_dev');
  await rejects(bots.deleteBot(B.id, bot.id), 'bot_not_found');
  await bots.deleteBot(A.id, bot.id);
  await rejects(bots.callMethod(t2, 'me'), 'invalid_token');
  assert.equal((await bots.createBot(B.id, { name: 'W2', username: 'weather_info_bot' })).bot.username, 'weather_info_bot');
});

test('channel comments: subscribers comment under posts; timeline, unread and last message ignore comments', async () => {
  const ch = await chats.createChannel(A.id, { title: 'News' });
  const chId = ch.id || ch.chat.id;
  await chats.addMembers(A.id, chId, [B.id]);
  const post = await messages.sendMessage(A.id, chId, { text: 'Breaking: release ho gaya' });
  await rejects(messages.sendMessage(B.id, chId, { text: 'nice', thread_id: post.id }), 'comments_disabled');
  await chats.updateGroup(A.id, chId, { comments_enabled: true });
  await rejects(messages.sendMessage(B.id, chId, { text: 'not a comment' }), 'not_admin');
  const c1 = await messages.sendMessage(B.id, chId, { text: 'Mubarak ho!', thread_id: post.id });
  assert.equal(c1.thread_id, post.id);
  assert.equal(c1.sender.id, B.id, 'comments show the real author');
  await rejects(messages.sendMessage(B.id, chId, { text: 'reply to comment as root', thread_id: c1.id }), 'post_not_found');

  const timeline = await messages.listMessages(B.id, chId, {});
  assert.ok(!timeline.messages.some((m) => m.id === c1.id), 'comments are not in the channel timeline');
  assert.equal(timeline.messages.find((m) => m.id === post.id).comments_count, 1);
  const thread = await messages.listMessages(A.id, chId, { thread_id: post.id });
  assert.deepEqual(thread.messages.map((m) => m.id), [c1.id]);

  const chatA = await chats.getChat(A.id, chId);
  assert.equal(chatA.comments_enabled, true);
  assert.equal(chatA.unread_count, 0, 'a comment does not make the channel unread');
  assert.equal(chatA.last_message.id, post.id);

  await settings.update({ feature_channel_comments: false });
  await rejects(chats.updateGroup(A.id, chId, { comments_enabled: true }), 'feature_disabled');
  await settings.update({ feature_channel_comments: true });
});

test('topics: forum groups, per-topic messages, closed topics, delete topic', async () => {
  const g = (await chats.createGroup(A.id, { title: 'Community', member_ids: [B.id] })).chat;
  await rejects(topics.list(A.id, g.id), 'not_a_forum');
  await chats.updateGroup(A.id, g.id, { is_forum: true });
  assert.equal((await chats.getChat(B.id, g.id)).is_forum, true);
  await rejects(topics.create(B.id, g.id, { title: 'Mine' }), 'not_admin');
  const help = await topics.create(A.id, g.id, { title: 'Help', icon_color: 3 });
  const off = await topics.create(A.id, g.id, { title: 'Off-topic' });

  const h1 = await messages.sendMessage(B.id, g.id, { text: 'App crash ho rahi hai', topic_id: help.id });
  assert.equal(h1.topic_id, help.id);
  await messages.sendMessage(B.id, g.id, { text: 'Salam sab ko' }); // General
  const inHelp = await messages.listMessages(A.id, g.id, { topic_id: String(help.id) });
  assert.deepEqual(inHelp.messages.map((m) => m.text), ['App crash ho rahi hai']);
  const general = await messages.listMessages(A.id, g.id, { topic_id: 'general' });
  assert.ok(general.messages.some((m) => m.text === 'Salam sab ko'));
  assert.ok(!general.messages.some((m) => m.text === 'App crash ho rahi hai'));

  const l = await topics.list(B.id, g.id);
  assert.equal(l.topics[0].title, 'Help', 'most recent activity first');
  assert.equal(l.topics[0].message_count, 1);
  assert.equal(l.general.last_message.text, 'Salam sab ko');

  await topics.update(A.id, g.id, off.id, { is_closed: true });
  await rejects(messages.sendMessage(B.id, g.id, { text: 'x', topic_id: off.id }), 'topic_closed');
  await messages.sendMessage(A.id, g.id, { text: 'admins can still post', topic_id: off.id });

  const r = await topics.remove(A.id, g.id, help.id);
  assert.equal(r.deleted_messages, 1);
  assert.equal((await topics.list(A.id, g.id)).topics.length, 1);
});
