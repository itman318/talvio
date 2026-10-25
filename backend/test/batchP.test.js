'use strict';

/**
 * Privacy & security plus, group protection and BotForge.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const bots = require('../src/services/bot.service');
const botfather = require('../src/services/botforge.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName, username) {
  const addr = `10.20.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName, ...(username ? { username } : {}) });
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [s.user.id]);
  return { id: s.user.id };
}
const flush = (ms = 200) => new Promise((r) => setTimeout(r, ms));

let A;
let B;
let C;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923260000001', 'Asad', 'asad_p');
  B = await signup('+923260000002', 'Bilal', 'bilal_p');
  C = await signup('+923260000003', 'Chand', 'chand_p');
});
test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  await db.close();
});

test('who can message me, bio, phone search, forwards, default timer', async () => {
  const me = await users.updatePrivacy(A.id, { messages: 'contacts', bio: 'nobody', phone_search: 'contacts', forwards: 'nobody', default_disappear_sec: 86400, session_ttl_days: 30, account_ttl_days: 180 });
  assert.equal(me.privacy.messages, 'contacts');
  assert.equal(me.security.default_disappear_sec, 86400);
  await rejects(users.updatePrivacy(A.id, { account_ttl_days: 5 }), 'invalid_input');
  await users.updateProfile(A.id, { bio: 'secret bio' });
  assert.equal((await users.getUser(B.id, A.id)).bio, '');

  // B is a stranger → can't start a chat with A
  const ab = await chats.getOrCreatePrivate(B.id, A.id);
  await rejects(messages.sendMessage(B.id, ab.id, { text: 'hi' }), 'privacy_messages');
  // after A writes first, B can reply
  await messages.sendMessage(A.id, ab.id, { text: 'hello B' });
  await messages.sendMessage(B.id, ab.id, { text: 'hi A' });
  // chats A starts get A's default timer
  assert.equal((await db.one('SELECT disappear_after_sec FROM chats WHERE id = $1', [ab.id])).disappear_after_sec, 0);
  const ac = await chats.getOrCreatePrivate(A.id, C.id);
  assert.equal((await db.one('SELECT disappear_after_sec FROM chats WHERE id = $1', [ac.id])).disappear_after_sec, 86400);

  // phone search: only A's contacts find A by number
  assert.equal((await users.searchUsers(C.id, '+923260000001')).length, 0);
  await users.addContact(A.id, C.id);
  assert.equal((await users.searchUsers(C.id, '+923260000001')).length, 1);

  // forwards: A's messages forwarded by B don't link to A
  const bc = await chats.getOrCreatePrivate(B.id, C.id);
  const msg = await db.one(`SELECT id FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id LIMIT 1`, [ab.id, A.id]);
  await messages.forwardMessages(B.id, { from_chat_id: ab.id, message_ids: [msg.id], to_chat_ids: [bc.id] });
  const f = await db.one('SELECT forwarded_from_user_id, forwarded_from_name FROM messages WHERE chat_id = $1 ORDER BY id DESC LIMIT 1', [bc.id]);
  assert.equal(f.forwarded_from_user_id, null);
  assert.equal(f.forwarded_from_name, 'Asad');
});

test('inactive devices are logged out; long-away accounts are deleted', async () => {
  await db.query(`UPDATE sessions SET last_active_at = now() - interval '40 days' WHERE user_id = $1`, [A.id]);
  await db.query(`UPDATE users SET last_seen_at = now() - interval '400 days', created_at = now() - interval '500 days' WHERE id = $1`, [C.id]);
  await db.query(`UPDATE sessions SET last_active_at = now() - interval '400 days' WHERE user_id = $1`, [C.id]);
  const r = await users.sweepInactive();
  assert.ok(r.sessions >= 1);
  assert.equal(r.accounts, 1);
  assert.equal((await db.one('SELECT status FROM users WHERE id = $1', [C.id])).status, 'deleted');
  assert.equal((await db.one('SELECT count(*)::int AS n FROM sessions WHERE user_id = $1 AND revoked_at IS NULL', [A.id])).n, 0);
});

test('group protection: human check, permissions, links, banned words, flood, quiet joins', async () => {
  const D = await signup('+923260000004', 'Dua', 'dua_p');
  const E = await signup('+923260000005', 'Ehsan', 'ehsan_p');
  const { chat: g } = await chats.createGroup(B.id, { title: 'Guarded', member_ids: [D.id] });
  await chats.updateGroup(B.id, g.id, {
    join_captcha: true, anti_flood: true, banned_words: ['scam', 'Casino'], member_perms: { polls: false, stickers: false }, hide_service: true,
  });
  const info = await chats.getChat(B.id, g.id);
  assert.deepEqual(info.banned_words, ['scam', 'casino']);
  assert.equal(info.member_perms.polls, false);
  assert.equal(info.member_perms.media, true);

  const joined = await chats.joinByInvite(E.id, info.invite_code);
  assert.equal(joined.needs_captcha, true);
  await rejects(messages.sendMessage(E.id, g.id, { text: 'hello' }), 'verify_first');
  const ok = await chats.verifyHuman(E.id, g.id);
  assert.equal(ok.needs_captcha, false);
  await messages.sendMessage(E.id, g.id, { text: 'hello all' });

  await rejects(messages.sendMessage(D.id, g.id, { text: 'join this SCAM now' }), 'banned_word');
  await rejects(messages.sendMessage(D.id, g.id, { type: 'poll', poll: { question: 'Q?', options: ['a', 'b'] } }), 'no_permission');
  await messages.sendMessage(B.id, g.id, { type: 'poll', poll: { question: 'Admins can?', options: ['a', 'b'] } }); // admins aren't limited
  for (let i = 0; i < 2; i += 1) await messages.sendMessage(D.id, g.id, { text: 'same' });
  await rejects(messages.sendMessage(D.id, g.id, { text: 'same' }), 'flood');
  await chats.updateGroup(B.id, g.id, { anti_links: true });
  await rejects(messages.sendMessage(D.id, g.id, { text: 'see example.com' }), 'no_links');

  // someone who never verifies is removed by the sweep
  const F = await signup('+923260000006', 'Faraz', 'faraz_p');
  await chats.joinByInvite(F.id, info.invite_code);
  await db.query(`UPDATE chat_members SET captcha_until = now() - interval '1 minute' WHERE chat_id = $1 AND user_id = $2`, [g.id, F.id]);
  await chats.sweepCaptcha();
  assert.equal((await db.one('SELECT count(*)::int AS n FROM chat_members WHERE chat_id = $1 AND user_id = $2', [g.id, F.id])).n, 0);
  // quiet group: no "joined" system messages
  assert.equal((await db.one(`SELECT count(*)::int AS n FROM messages WHERE chat_id = $1 AND meta->>'event' = 'member_joined'`, [g.id])).n, 0);
});

test('BotForge creates and manages bots from a chat', async () => {
  const bfId = await botfather.ensure();
  assert.equal(await botfather.ensure(), bfId);
  const chat = await chats.getOrCreatePrivate(B.id, bfId);
  const last = async () => db.one('SELECT * FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id DESC LIMIT 1', [chat.id, bfId]);
  const send = async (text) => {
    rateLimit.reset();
    await messages.sendMessage(B.id, chat.id, { text });
    await flush();
    return last();
  };
  assert.match((await send('/start')).text, /build and manage/);
  assert.match((await send('/newbot')).text, /choose a name/);
  assert.match((await send('Price Alert')).text, /username/);
  assert.match((await send('not valid')).text, /⚠️/);
  const done = await send('price_alert_bot');
  assert.match(done.text, /Congratulations/);
  const token = done.text.match(/tlv_\d+_[A-Za-z0-9]+/)[0];
  const me = await bots.callMethod(token, 'me');
  assert.equal(me.username, 'price_alert_bot');

  await send('/setcommands');
  const pick = await last();
  const choice = pick.reply_markup.inline_keyboard[0][0];
  assert.equal(choice.callback_data, `ecmd:${me.id}`);
  await bots.pressButton(B.id, pick.id, { data: choice.callback_data });
  await flush();
  assert.match((await last()).text, /one per line/);
  assert.match((await send('start - Begin\n/gold - Gold price')).text, /2 commands saved/);
  assert.deepEqual((await bots.callMethod(token, 'commands.get')).map((c) => c.command), ['start', 'gold']);

  const list = await send('/mybots');
  await bots.pressButton(B.id, list.id, { data: `bot:${me.id}` });
  await flush();
  const card = await db.one('SELECT text, reply_markup FROM messages WHERE id = $1', [list.id]);
  assert.match(card.text, /@price_alert_bot/);
  await bots.pressButton(B.id, list.id, { data: `priv:${me.id}` });
  await flush();
  assert.equal((await db.one('SELECT group_privacy FROM bots WHERE user_id = $1', [me.id])).group_privacy, false);
  await bots.pressButton(B.id, list.id, { data: `rev:${me.id}` });
  await flush();
  await bots.pressButton(B.id, list.id, { data: `revyes:${me.id}` });
  await flush();
  await rejects(bots.callMethod(token, 'me'), 'invalid_token');
  assert.match((await send('/cancel')).text, /Stopped|Nothing/);
});

test('Plus: prices in the buyer currency, perks enforced', async () => {
  const pay = require('../src/services/payment.service');
  const pk = await pay.premiumInfo(B.id); // +92 phone → PKR
  assert.equal(pk.currency, 'PKR');
  assert.match(pk.plans[0].price_text, /^Rs /);
  await db.query(`UPDATE users SET phone = '+15550001111' WHERE id = $1`, [B.id]);
  const us = await pay.premiumInfo(B.id);
  assert.equal(us.currency, 'USD');
  assert.equal(us.plans[0].price_text, '$3.99');
  assert.equal(us.methods.length, 0);
  assert.ok(us.payments_note);
  await db.query(`UPDATE users SET phone = NULL WHERE id = $1`, [B.id]);
  assert.equal((await pay.premiumInfo(B.id, { locale: 'en-GB,en;q=0.9' })).currency, 'GBP');
  assert.equal((await pay.premiumInfo(B.id, { country: 'de' })).plans[0].price_text, '€3.79');
  await rejects(pay.checkout(B.id, { plan_id: us.plans[0].id, provider: 'manual', country: 'US' }), 'provider_unavailable');

  const long = 'x'.repeat(200);
  await rejects(users.updateProfile(B.id, { bio: long }), 'invalid_input');
  await db.query(`UPDATE users SET premium_until = now() + interval '30 days' WHERE id = $1`, [B.id]);
  await users.updateProfile(B.id, { bio: long });
  const lim = await pay.limitsFor(B.id);
  assert.equal(lim.pinned_chats, 15);
  assert.equal(lim.exclusive_stickers, true);
});
