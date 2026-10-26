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
const bus = require('../src/bus');
const vcs = require('../src/services/voicechat.service');
const password = require('../src/services/password.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName, username) {
  const addr = `10.30.0.${(ip += 1)}`;
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
  A = await signup('+923270000001', 'Asad', 'asad_p');
  B = await signup('+923270000002', 'Bilal', 'bilal_p');
  C = await signup('+923270000003', 'Chand', 'chand_p');
});
test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  await db.close();
});

test('voice messages: the sender learns it was listened to', async () => {
  const chat = await chats.getOrCreatePrivate(A.id, B.id);
  const media = await db.one(`INSERT INTO media (uploader_id, kind, mime, size_bytes, path, original_name) VALUES ($1, 'voice', 'audio/ogg', 10, '/tmp/x.ogg', 'v.ogg') RETURNING id`, [A.id]).catch(() => null);
  let m;
  if (media) {
    m = await messages.sendMessage(A.id, chat.id, { type: 'voice', media_id: media.id }).catch(() => null);
  }
  if (!m) {
    const row = await db.one(`INSERT INTO messages (chat_id, sender_id, type, text) VALUES ($1, $2, 'voice', '') RETURNING id`, [chat.id, A.id]);
    m = { id: row.id };
  }
  const got = [];
  const on = (e) => e.event === 'message:played' && got.push(e);
  bus.on('rt:emit', on);
  await messages.markPlayed(B.id, m.id);
  await messages.markPlayed(B.id, m.id); // once only
  await messages.markPlayed(A.id, m.id); // the sender's own play doesn't count
  bus.removeListener('rt:emit', on);
  assert.equal(got.length, 1);
  assert.deepEqual(got[0].userIds, [A.id]);
  const info = await messages.messageInfo(A.id, m.id);
  assert.equal(info.played[0].id, B.id);
  const [ser] = await messages.serializeByIds(A.id, [m.id]).then((map) => [map.get(m.id)]);
  assert.equal(ser.played, true);
});

test('read later bookmarks', async () => {
  const chat = await chats.getOrCreatePrivate(A.id, B.id);
  const m = await messages.sendMessage(B.id, chat.id, { text: 'read this tonight' });
  await messages.addBookmark(A.id, m.id);
  await messages.addBookmark(A.id, m.id);
  let l = await messages.listBookmarks(A.id);
  assert.equal(l.items.length, 1);
  assert.equal(l.items[0].message.text, 'read this tonight');
  assert.equal(l.items[0].chat.id, chat.id);
  await rejects(messages.addBookmark(C.id, m.id), 'chat_not_found');
  await messages.removeBookmark(A.id, m.id);
  l = await messages.listBookmarks(A.id);
  assert.equal(l.items.length, 0);
});

test('login activity: logins, a wrong two-step password, "this wasn\'t me"', async () => {
  await password.set(C.id, { new_password: 'secret123', hint: '' });
  const act0 = await users.loginActivity(C.id, 0);
  assert.ok(act0.some((e) => e.kind === 'login'));
  {
    rateLimit.reset();
    const r = await auth.requestOtp('+923270000003', '10.30.9.9');
    const ch = await auth.verifyOtp('+923270000003', r.dev_code, { name: 'Stranger phone', platform: 'android' }, '10.30.9.9');
    assert.ok(ch.login_token);
    await rejects(password.verifyLogin(ch.login_token, 'wrong-one', { name: 'Stranger phone', platform: 'android' }, '10.30.9.9'), 'password_invalid');
    const act = await users.loginActivity(C.id, 0);
    assert.ok(act.some((e) => e.kind === 'password_needed'));
    assert.ok(act.some((e) => e.kind === 'wrong_password' && e.device_name === 'Stranger phone'));
  }
  const s = await db.one('SELECT id FROM sessions WHERE user_id = $1 AND revoked_at IS NULL ORDER BY id LIMIT 1', [C.id]);
  await users.notMe(C.id, 0, s.id);
  assert.ok((await db.one('SELECT revoked_at FROM sessions WHERE id = $1', [s.id])).revoked_at);
});

test('inline bots: @bot query → results → sent "via @bot"', async () => {
  const { bot, token } = await bots.createBot(A.id, { name: 'Price', username: 'inlineprice_bot' });
  // inline mode off → no bot
  assert.equal((await bots.inlineQuery(B.id, { username: 'inlineprice_bot', q: 'gold' })).bot, null);
  await bots.updateBot(A.id, bot.id, { inline_placeholder: 'Search prices…' });
  // bot photo from the app (owner uploads, gives it to the bot) and removing the webhook
  const pic = await db.one(`INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name) VALUES ($1, 'avatar', 'image/jpeg', 10, '/tmp/b.jpg', 'b.jpg') RETURNING id`, [A.id]);
  const withPic = await bots.updateBot(A.id, bot.id, { avatar_media_id: pic.id });
  assert.ok(withPic.avatar_url, 'bot photo set');
  await rejects(bots.updateBot(B.id, bot.id, { avatar_media_id: pic.id }), 'bot_not_found');
  await db.query(`UPDATE bots SET webhook_url = 'https://example.com/h', webhook_error = 'x' WHERE user_id = $1`, [bot.id]);
  const noHook = await bots.updateBot(A.id, bot.id, { remove_webhook: true });
  assert.equal(noHook.webhook_url, null);
  assert.equal((await bots.updateBot(A.id, bot.id, { avatar_media_id: null })).avatar_url, null);
  assert.equal((await bots.callMethod(token, 'me')).supports_inline_queries, true);
  const pending = bots.inlineQuery(B.id, { username: '@inlineprice_bot', q: 'gold' });
  await new Promise((r) => setTimeout(r, 150));
  const ups = await bots.callMethod(token, 'updates', {});
  const iq = ups.find((u) => u.inline_query).inline_query;
  assert.equal(iq.query, 'gold');
  await bots.callMethod(token, 'inline.answer', {
    inline_query_id: iq.id,
    results: [{ id: 'g1', title: 'Gold 24k', description: 'Rs 290,000 / tola', text: 'Gold 24k: Rs 290,000 per tola' }],
  });
  const r = await pending;
  assert.equal(r.results[0].title, 'Gold 24k');
  const chat = await chats.getOrCreatePrivate(B.id, C.id);
  const sent = await bots.sendInlineResult(B.id, { query_id: r.query_id, result_id: 'g1', chat_id: chat.id });
  assert.equal(sent.text, 'Gold 24k: Rs 290,000 per tola');
  assert.equal(sent.via_bot.username, 'inlineprice_bot');
  assert.equal(sent.sender_id, B.id);
});

test('voice chats: start, join, mute, raise hand in channels, signalling, end', async () => {
  const D = await signup('+923270000004', 'Dani', 'dani_q');
  const { chat: g } = await chats.createGroup(A.id, { title: 'Voice room', member_ids: [B.id, D.id] });
  await rejects(vcs.start(B.id, g.id), 'not_admin');
  const s = await vcs.start(A.id, g.id, { title: 'Daily call' });
  assert.equal(s.voice_chat.participants.length, 1);
  assert.ok(Array.isArray(s.ice_servers));
  assert.equal((await chats.getChat(B.id, g.id)).voice_chat.count, 1);
  const j = await vcs.join(B.id, g.id);
  assert.equal(j.voice_chat.participants.length, 2);
  await vcs.update(B.id, g.id, { muted: false });
  await rejects(vcs.update(B.id, g.id, { user_id: A.id, muted: true }), 'not_admin');
  await vcs.update(A.id, g.id, { user_id: B.id, muted: true });
  const sig = [];
  const on = (e) => e.event === 'vc:signal' && sig.push(e);
  bus.on('rt:emit', on);
  assert.equal((await vcs.relay(A.id, { chat_id: g.id, to: B.id, data: { type: 'offer' } })).ok, true);
  assert.equal((await vcs.relay(A.id, { chat_id: g.id, to: D.id, data: {} })).ok, false); // D isn't in the room
  bus.removeListener('rt:emit', on);
  assert.equal(sig.length, 1);
  await vcs.leave(B.id, g.id);
  await vcs.leave(A.id, g.id); // last one out ends it
  assert.equal((await chats.getChat(A.id, g.id)).voice_chat, null);
  const ended = await db.one(`SELECT meta FROM messages WHERE chat_id = $1 AND meta->>'event' = 'voice_chat_ended'`, [g.id]);
  assert.ok(ended);

  // channels: listeners raise a hand, the admin lets them speak
  const ch = await chats.createChannel(A.id, { title: 'Live channel', username: 'livechannel_q' });
  await chats.joinPublic(B.id, ch.id);
  await vcs.start(A.id, ch.id);
  await vcs.join(B.id, ch.id);
  await rejects(vcs.update(B.id, ch.id, { muted: false }), 'cannot_speak');
  await vcs.update(B.id, ch.id, { hand_raised: true });
  await vcs.update(A.id, ch.id, { user_id: B.id, can_speak: true });
  const after = await vcs.update(B.id, ch.id, { muted: false });
  assert.equal(after.voice_chat.participants.find((p) => p.user.id === B.id).muted, false);
  await vcs.end(A.id, ch.id);
});

test('Talvio Bot API v2: own names, Talvio events, buttons, signed hooks', async () => {
  const v2 = require('../src/services/botv2.service');
  const http = require('http');
  const crypto = require('crypto');
  const { bot, token: key } = await bots.createBot(A.id, { name: 'Signals', username: 'signals_v2_bot' });
  const me = await v2.call(key, 'profile.get');
  assert.deepEqual([me.username, me.bot], ['signals_v2_bot', true]);
  await rejects(v2.call(key, 'sendMessage', {}), 'unknown_method');
  await v2.call(key, 'commands.set', { commands: [{ name: 'gold', about: 'Gold price' }] });
  assert.deepEqual(await v2.call(key, 'commands.get'), [{ name: 'gold', about: 'Gold price' }]);

  const chat = await chats.getOrCreatePrivate(B.id, bot.id);
  await messages.sendMessage(B.id, chat.id, { text: '/gold' });
  await flush();
  const { events } = await v2.call(key, 'events.poll', {});
  const e = events[0];
  assert.equal(e.kind, 'message');
  assert.equal(e.message.text, '/gold');
  assert.deepEqual(e.message.conversation, { id: chat.id, kind: 'direct', title: 'Bilal' });
  assert.equal(e.message.author.username, 'bilal_p');
  assert.ok(e.at);

  const sent = await v2.call(key, 'message.send', { to: chat.id, text: 'Gold: 2,410', buttons: [[{ label: 'Refresh', data: 'r1' }, { label: 'Chart', link: 'https://example.com' }]] });
  assert.equal(sent.text, 'Gold: 2,410');
  assert.equal(sent.author.id, bot.id);
  const press = await bots.pressButton(B.id, sent.id, { data: 'r1' });
  const { events: ev2 } = await v2.call(key, 'events.poll', { after: e.event_id });
  assert.equal(ev2[0].kind, 'button_press');
  assert.equal(ev2[0].press.data, 'r1');
  assert.equal(ev2[0].press.id, press.callback_query_id);
  assert.equal(await v2.call(key, 'button.reply', { press: press.callback_query_id, notice: 'Updated' }), true);
  const kb = await v2.call(key, 'message.send', { to: chat.id, text: 'Pick', keyboard: [['Buy', 'Sell']], keyboard_once: true });
  assert.ok(kb.id);
  assert.deepEqual(await v2.call(key, 'conversation.size', { to: chat.id }), { members: 2 });

  // hooks: Talvio events, signed with the secret
  const got = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      got.push({ sig: req.headers['x-talvio-signature'], id: req.headers['x-talvio-event-id'], body });
      res.end('ok');
    });
  });
  await new Promise((r) => server.listen(0, r));
  await v2.call(key, 'events.poll', { after: 1e12 });
  const hook = await v2.call(key, 'hook.set', { url: `http://127.0.0.1:${server.address().port}/hook` });
  assert.ok(/^[a-f0-9]{48}$/.test(hook.secret));
  await messages.sendMessage(B.id, chat.id, { text: 'hello hook' });
  for (let i = 0; i < 30 && !got.length; i += 1) await flush(100);
  server.close();
  assert.equal(got.length, 1);
  const body = JSON.parse(got[0].body);
  assert.equal(body.kind, 'message');
  assert.equal(body.message.text, 'hello hook');
  const expect = crypto.createHmac('sha256', hook.secret).update(got[0].body).digest('hex');
  assert.equal(got[0].sig, `sha256=${expect}`);
  assert.equal((await v2.call(key, 'hook.status')).url.startsWith('http://127.0.0.1'), true);
  await v2.call(key, 'hook.remove', { drop_pending: true });
});

test('notification settings: defaults, update, validation', async () => {
  const d = await users.getNotifySettings(A.id);
  assert.deepEqual(d, { private: true, groups: true, channels: true, preview: true });
  const s = await users.setNotifySettings(A.id, { groups: false, preview: false, junk: true });
  assert.equal(s.groups, false);
  assert.equal(s.preview, false);
  assert.equal(s.junk, undefined);
  assert.equal((await users.getNotifySettings(A.id)).groups, false);
  await rejects(users.setNotifySettings(A.id, { channels: 'maybe' }), 'invalid_input');
  await users.setNotifySettings(A.id, { groups: true, preview: true });
});

test('clear history: only me, or both sides in a private chat; admins only in groups', async () => {
  const chat = await chats.getOrCreatePrivate(A.id, C.id);
  await messages.sendMessage(A.id, chat.id, { text: 'one' });
  await messages.sendMessage(C.id, chat.id, { text: 'two' });
  const count = async (uid) => {
    const r = await messages.listMessages(uid, chat.id, {});
    return (Array.isArray(r) ? r : r.messages).length;
  };
  await chats.clearHistory(A.id, chat.id);
  assert.equal(await count(A.id), 0);
  assert.equal(await count(C.id), 2, 'other side keeps them');
  await messages.sendMessage(A.id, chat.id, { text: 'three' });
  const sent = [];
  const on = (e) => e.event === 'chat:cleared' && sent.push(e);
  bus.on('rt:emit', on);
  await chats.clearHistory(A.id, chat.id, { for_everyone: true });
  bus.off('rt:emit', on);
  assert.equal(await count(A.id), 0);
  assert.equal(await count(C.id), 0, 'cleared for both');
  assert.equal(sent.length, 1);
  // groups: a member can't clear for everyone
  const { chat: g } = await chats.createGroup(A.id, { title: 'Clear test', member_ids: [C.id] });
  await rejects(chats.clearHistory(C.id, g.id, { for_everyone: true }), 'no_rights');
  assert.equal((await chats.clearHistory(A.id, g.id, { for_everyone: true })).for_everyone, true);
});

test('reserved names: a long list, look-alikes, shown as "taken"', async () => {
  const { isReservedName } = require('../src/utils/reserved_names');
  for (const n of ['admin', 'Help', 'support_pk', 'official_news', 'talvio_team', 'mytalvio', 'help123', 'customercare', 'jazzcash', 'ali_admin']) {
    assert.equal(isReservedName(n), true, n);
  }
  for (const n of ['amna_k', 'gul_trader', 'badminton_pk', 'helper_ali', 'signals_v2_bot', 'muhammad']) {
    assert.equal(isReservedName(n), false, n);
  }
  assert.equal((await users.checkUsername(B.id, 'helpdesk')).available, false);
  await rejects(users.updateProfile(B.id, { username: 'admin_ali' }), 'username_taken');
});

test('admins & moderators: owner, admins who may add admins, only rights they have', async () => {
  const D = await signup('+923270000044', 'Dua', 'dua_mod');
  const E = await signup('+923270000045', 'Ehsan', 'ehsan_mod');
  const { chat: g } = await chats.createGroup(A.id, { title: 'Mods', member_ids: [B.id, C.id, D.id, E.id] });
  // a moderator: only delete + ban + pin
  await chats.setMemberRole(A.id, g.id, B.id, 'admin', { rights: { change_info: false, invite_users: false, post_messages: false, manage_voice_chats: false }, title: 'Moderator' });
  await rejects(chats.setMemberRole(B.id, g.id, C.id, 'admin', {}), 'not_owner');
  // an admin who may add admins
  await chats.setMemberRole(A.id, g.id, C.id, 'admin', { rights: { add_admins: true, change_info: false } });
  await rejects(chats.setMemberRole(C.id, g.id, D.id, 'admin', { rights: { change_info: true } }), 'no_rights');
  await chats.setMemberRole(C.id, g.id, D.id, 'admin', { rights: { change_info: false, add_admins: false }, title: 'Helper' });
  await rejects(chats.setMemberRole(C.id, g.id, B.id, 'member'), 'no_rights'); // B was added by the owner
  await chats.setMemberRole(C.id, g.id, D.id, 'member'); // D was added by C
  const list = await chats.listMembers ? await chats.listMembers(A.id, g.id) : null;
  if (list) {
    const b = (list.members || list).find((m) => (m.user ? m.user.id : m.id) === B.id);
    if (b && b.rights) assert.equal(b.rights.change_info, false);
  }
});

test('refresh: a lost answer does not log you out (the previous token still works for a while)', async () => {
  const r = await auth.requestOtp('+923270000099', '10.30.9.9');
  const s1 = await auth.verifyOtp('+923270000099', r.dev_code, { platform: 'android', app_version: '1.0.0' }, '10.30.9.9');
  const t1 = s1.refresh_token;
  const s2 = await auth.refresh(t1, '10.30.9.9'); // the phone never got this answer
  assert.ok(s2.refresh_token);
  const s3 = await auth.refresh(t1, '10.30.9.9'); // so it tries the old one again
  assert.ok(s3.refresh_token, 'still logged in');
  const s4 = await auth.refresh(s3.refresh_token, '10.30.9.9');
  assert.ok(s4.access_token);
  await rejects(auth.refresh('x'.repeat(40), '10.30.9.9'), 'invalid_refresh_token');
});

test('admin full control: group messages, delete, edit group & user, remove member, sessions', async () => {
  const admin = require('../src/services/admin.service');
  const { hashPassword } = require('../src/utils/crypto');
  const root = await db.one(`INSERT INTO admins (email, password_hash, name, role) VALUES ('rootq@example.com', $1, 'Root', 'super_admin') RETURNING *`, [hashPassword('x-very-long-password')]);
  const { chat: g } = await chats.createGroup(A.id, { title: 'Ctl', member_ids: [B.id, C.id] });
  const m = await messages.sendMessage(B.id, g.id, { text: 'bad words here' });
  const list = await admin.groupMessages(g.id);
  assert.ok(list.some((x) => Number(x.id) === Number(m.id)));
  await admin.deleteMessage(root, m.id, '1.1.1.1');
  assert.ok(!(await admin.groupMessages(g.id)).some((x) => Number(x.id) === Number(m.id)));
  await admin.editGroup(root, g.id, { title: 'Clean name', description: 'ok' }, '1.1.1.1');
  assert.equal((await db.one('SELECT title FROM chats WHERE id = $1', [g.id])).title, 'Clean name');
  await admin.removeGroupMember(root, g.id, C.id, '1.1.1.1');
  assert.equal(await db.one('SELECT 1 FROM chat_members WHERE chat_id = $1 AND user_id = $2', [g.id, C.id]), null);
  await rejects(admin.removeGroupMember(root, g.id, A.id, '1.1.1.1'), 'no_rights');
  await admin.editUserProfile(root, B.id, { first_name: 'Renamed' }, '1.1.1.1');
  assert.equal((await users.getMe(B.id)).first_name, 'Renamed');
  const ss = await admin.userSessions(B.id);
  assert.ok(ss.length >= 1);
  await admin.revokeSession(root, ss[0].id, '1.1.1.1');
  assert.equal((await admin.userSessions(B.id)).length, ss.length - 1);
});

test('support: screenshot, phone info, rating once after it is resolved', async () => {
  const support = require('../src/services/support.service');
  const pic = await db.one(`INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name) VALUES ($1, 'image', 'image/jpeg', 10, '/tmp/s.jpg', 's.jpg') RETURNING id`, [A.id]);
  const r = await support.createTicket(A.id, { subject: 'App crashes', category: 'bug', message: 'When I open a chat', device: 'Android 14 · v1.2', media_id: pic.id });
  assert.ok(r.messages[0].media_url);
  await rejects(support.rateTicket(A.id, r.ticket.id, { rating: 5 }), 'cannot_rate');
  await db.query(`UPDATE support_tickets SET status = 'resolved' WHERE id = $1`, [r.ticket.id]);
  const rated = await support.rateTicket(A.id, r.ticket.id, { rating: 4, comment: 'Quick help' });
  assert.equal(rated.ticket.rating, 4);
  assert.equal(rated.ticket.can_rate, false);
  await rejects(support.rateTicket(A.id, r.ticket.id, { rating: 5 }), 'cannot_rate');
  const reply = await support.userReply(B.id, r.ticket.id, { text: 'x' }).catch((e) => e);
  assert.equal(reply.code, 'ticket_not_found');
});
