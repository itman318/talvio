'use strict';

/**
 * End-to-end service tests against a real PostgreSQL database.
 *   TEST_DATABASE_URL=postgres://user:pass@127.0.0.1:5432/chatapp_test npm test
 * WARNING: the test database is wiped (DROP SCHEMA public CASCADE) before the run.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'chatapp-test-'));
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';
process.env.UPLOAD_DIR = path.join(TMP, 'uploads');

const db = require('../src/db');
const bus = require('../src/bus');
const crypto = require('../src/utils/crypto');
const v = require('../src/utils/validate');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const media = require('../src/services/media.service');
const reports = require('../src/services/report.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');

const events = [];
for (const name of [
  'message:new', 'message:edited', 'message:deleted', 'chat:updated', 'chat:removed',
  'receipt:read', 'receipt:delivered', 'sessions:revoked', 'user:updated',
]) bus.on(name, (e) => events.push({ name, ...e }));
const lastEvent = (name) => [...events].reverse().find((e) => e.name === name);

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ipCounter = 0;
async function signup(phone, firstName) {
  const ip = `10.0.0.${(ipCounter += 1)}`;
  const r = await auth.requestOtp(phone, ip);
  const s = await auth.verifyOtp(phone, r.dev_code, { name: 'Test phone', platform: 'android' }, ip);
  if (firstName) await users.updateProfile(s.user.id, { first_name: firstName });
  return { id: s.user.id, tokens: s, phone };
}

function fakeUpload(name, mime, content = 'hello') {
  const dir = path.join(process.env.UPLOAD_DIR, '2026', '10');
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, crypto.randomToken(8) + path.extname(name));
  fs.writeFileSync(p, content);
  return { path: p, size: Buffer.byteLength(content), mimetype: mime, originalname: name };
}

let A;
let B;
let C;
let D;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});

test.after(async () => {
  await db.close();
  fs.rmSync(TMP, { recursive: true, force: true });
});

test('crypto: JWT sign/verify, tamper and expiry', () => {
  const t = crypto.signJwt({ sub: 1 }, 'secret', 60);
  assert.equal(crypto.verifyJwt(t, 'secret').sub, 1);
  assert.equal(crypto.verifyJwt(t, 'other'), null);
  const [h, , s] = t.split('.');
  const forged = `${h}.${Buffer.from(JSON.stringify({ sub: 2, exp: 9999999999 })).toString('base64url')}.${s}`;
  assert.equal(crypto.verifyJwt(forged, 'secret'), null);
  assert.equal(crypto.verifyJwt(crypto.signJwt({ sub: 1 }, 'secret', -1), 'secret'), null);
  const hash = crypto.hashPassword('correct horse');
  assert.ok(crypto.verifyPassword('correct horse', hash));
  assert.ok(!crypto.verifyPassword('wrong', hash));
});

test('validate: phone and username', () => {
  assert.equal(v.normalizePhone(' +92 300-1234567 '), '+923001234567');
  assert.equal(v.normalizePhone('00923001234567'), '+923001234567');
  assert.throws(() => v.normalizePhone('03001234567'), /international/);
  assert.equal(v.validateUsername('shareef_92'), 'shareef_92');
  assert.throws(() => v.validateUsername('ab'));
  assert.throws(() => v.validateUsername('1abcde'));
  assert.throws(() => v.validateUsername('abcde_'));
});

test('auth: OTP flow, wrong code, refresh rotation, logout', async () => {
  const phone = '+923001110001';
  const r = await auth.requestOtp(phone, '1.1.1.1');
  assert.match(r.dev_code, /^\d{6}$/);
  await rejects(auth.requestOtp(phone, '1.1.1.1'), 'rate_limited');

  const wrong = r.dev_code === '000000' ? '111111' : '000000';
  await assert.rejects(auth.verifyOtp(phone, wrong, {}, '1.1.1.1'), (e) => e.code === 'otp_invalid' && e.extra.attempts_left === 4);

  const s = await auth.verifyOtp(phone, r.dev_code, { name: 'Pixel', platform: 'android', app_version: '1.0.0' }, '1.1.1.1');
  assert.ok(s.access_token && s.refresh_token);
  assert.equal(s.needs_profile, true);
  await rejects(auth.verifyOtp(phone, r.dev_code, {}, '1.1.1.1'), 'otp_expired'); // single use

  const ctx = await auth.authenticate(s.access_token);
  assert.equal(ctx.user.phone, phone);

  const r2 = await auth.refresh(s.refresh_token, '1.1.1.1');
  assert.notEqual(r2.refresh_token, s.refresh_token);
  await rejects(auth.refresh(s.refresh_token, '1.1.1.1'), 'invalid_refresh_token');

  await auth.logout(ctx.user.id, ctx.sessionId);
  await rejects(auth.authenticate(r2.access_token), 'session_revoked');
  assert.equal(lastEvent('sessions:revoked').reason, 'logout');
  rateLimit.reset('otp:');
});

test('users: profile, username, privacy, search', async () => {
  A = await signup('+923001000001', 'Ali');
  B = await signup('+923001000002', 'Bilal');
  C = await signup('+923001000003', 'Chand');
  D = await signup('+923001000004', 'Dua');

  const me = await users.updateProfile(A.id, { last_name: 'Khan', username: '@ali_khan', bio: 'Hello' });
  assert.equal(me.username, 'ali_khan');
  assert.equal(me.privacy.phone, 'contacts');
  await rejects(users.updateProfile(B.id, { username: 'ALI_KHAN' }), 'username_taken');
  assert.equal((await users.checkUsername(B.id, 'ali_khan')).available, false);
  assert.equal((await users.checkUsername(A.id, 'ali_khan')).available, true);

  // phone hidden from non-contacts by default, visible once A saves B as contact
  let seen = await users.getUser(B.id, A.id);
  assert.equal(seen.phone, null);
  await users.addContact(A.id, B.id);
  seen = await users.getUser(B.id, A.id);
  assert.equal(seen.phone, A.phone);

  await users.updatePrivacy(A.id, { last_seen: 'nobody' });
  seen = await users.getUser(B.id, A.id);
  assert.equal(seen.last_seen_hidden, true);
  await users.updatePrivacy(A.id, { last_seen: 'everyone' });

  const found = await users.searchUsers(B.id, 'ali_');
  assert.deepEqual(found.map((u) => u.id), [A.id]);
  const byPhone = await users.searchUsers(B.id, A.phone);
  assert.deepEqual(byPhone.map((u) => u.id), [A.id]);
  // name search only within contacts
  assert.equal((await users.searchUsers(A.id, 'Bil')).length, 1);
  assert.equal((await users.searchUsers(C.id, 'Bil')).length, 0);
});

let privateChat;
let firstMsg;

test('private chat: hidden until first message, unread, receipts, dedupe', async () => {
  privateChat = await chats.getOrCreatePrivate(A.id, B.id);
  assert.equal(privateChat.type, 'private');
  assert.equal(privateChat.title, 'Bilal');
  assert.equal((await chats.listChats(B.id)).length, 0, 'peer should not see an empty chat');

  firstMsg = await messages.sendMessage(A.id, privateChat.id, { text: '  Assalam o Alaikum  ', client_id: 'c-1' });
  assert.equal(firstMsg.text, 'Assalam o Alaikum');
  const ev = lastEvent('message:new');
  assert.deepEqual(ev.memberIds.sort(), [A.id, B.id].sort());

  const again = await messages.sendMessage(A.id, privateChat.id, { text: 'Assalam o Alaikum', client_id: 'c-1' });
  assert.equal(again.id, firstMsg.id, 'same client_id must not create a duplicate');

  let bList = await chats.listChats(B.id);
  assert.equal(bList.length, 1);
  assert.equal(bList[0].unread_count, 1);
  assert.equal(bList[0].title, 'Ali Khan');
  assert.equal(bList[0].last_message.id, firstMsg.id);

  await messages.markDelivered(B.id, privateChat.id, firstMsg.id);
  let aView = await chats.getChat(A.id, privateChat.id);
  assert.equal(aView.delivered_up_to, firstMsg.id);
  assert.equal(aView.read_up_to, 0);

  await messages.markRead(B.id, privateChat.id, firstMsg.id + 1000);
  aView = await chats.getChat(A.id, privateChat.id);
  assert.equal(aView.read_up_to, firstMsg.id, 'read pointer is clamped to the last message');
  bList = await chats.listChats(B.id);
  assert.equal(bList[0].unread_count, 0);
  assert.equal(lastEvent('receipt:read').userId, B.id);

  const reply = await messages.sendMessage(B.id, privateChat.id, { text: 'Walaikum Assalam', reply_to_id: firstMsg.id });
  assert.equal(reply.reply_to.id, firstMsg.id);
  assert.equal(reply.reply_to.sender_name, 'Ali Khan');

  await rejects(messages.sendMessage(C.id, privateChat.id, { text: 'hi' }), 'chat_not_found');
  await rejects(messages.sendMessage(A.id, privateChat.id, { text: '   ' }), 'empty_message');
  await rejects(messages.sendMessage(A.id, privateChat.id, { text: 'x'.repeat(4097) }), 'message_too_long');
});

test('messages: pagination, edit, delete for me / everyone', async () => {
  for (let i = 0; i < 5; i += 1) await messages.sendMessage(A.id, privateChat.id, { text: `msg ${i}` });
  const page1 = await messages.listMessages(B.id, privateChat.id, { limit: 3 });
  assert.equal(page1.messages.length, 3);
  assert.equal(page1.has_more, true);
  assert.equal(page1.messages[0].text, 'msg 4', 'newest first');
  const page2 = await messages.listMessages(B.id, privateChat.id, { before: page1.messages[2].id, limit: 50 });
  assert.equal(page2.messages.length, 4);
  const after = await messages.listMessages(B.id, privateChat.id, { after: firstMsg.id, limit: 2 });
  assert.equal(after.messages.length, 2);
  assert.ok(after.messages[0].id > after.messages[1].id);

  const target = page1.messages[0];
  const edited = await messages.editMessage(A.id, target.id, { text: 'msg 4 (edited)' });
  assert.ok(edited.edited_at);
  await rejects(messages.editMessage(B.id, target.id, { text: 'hack' }), 'cannot_edit');

  await messages.deleteMessages(B.id, privateChat.id, { message_ids: [target.id] });
  const bMsgs = await messages.listMessages(B.id, privateChat.id, { limit: 1 });
  assert.notEqual(bMsgs.messages[0].id, target.id, 'hidden for B');
  const aMsgs = await messages.listMessages(A.id, privateChat.id, { limit: 1 });
  assert.equal(aMsgs.messages[0].id, target.id, 'still visible for A');

  await messages.deleteMessages(A.id, privateChat.id, { message_ids: [target.id], for_everyone: true });
  const aAfter = await messages.listMessages(A.id, privateChat.id, { limit: 1 });
  assert.notEqual(aAfter.messages[0].id, target.id);
  assert.deepEqual(lastEvent('message:deleted').messageIds, [target.id]);
});

test('blocking prevents messages in private chats', async () => {
  await users.block(B.id, A.id);
  await rejects(messages.sendMessage(A.id, privateChat.id, { text: 'are you there?' }), 'blocked');
  await rejects(messages.sendMessage(B.id, privateChat.id, { text: 'nope' }), 'blocked');
  assert.equal((await users.listBlocked(B.id))[0].id, A.id);
  assert.equal((await users.getUser(A.id, B.id)).avatar_url, null);
  await users.unblock(B.id, A.id);
  await messages.sendMessage(A.id, privateChat.id, { text: 'back' });
});

let group;

test('groups: create, privacy skip, roles, ownership transfer, invites', async () => {
  await users.updatePrivacy(C.id, { group_add: 'nobody' });
  const created = await chats.createGroup(A.id, { title: 'Family', member_ids: [B.id, C.id] });
  group = created.chat;
  assert.deepEqual(created.skipped, [{ user_id: C.id, reason: 'privacy' }]);
  assert.equal(group.member_count, 2);
  assert.equal(group.my_role, 'owner');
  assert.ok(group.invite_code);
  assert.equal(group.last_message.type, 'system');

  const bView = await chats.getChat(B.id, group.id);
  assert.equal(bView.invite_code, null, 'members do not see the invite code');
  await rejects(chats.addMembers(B.id, group.id, [D.id]), 'not_admin');

  await chats.setMemberRole(A.id, group.id, B.id, 'admin');
  const add = await chats.addMembers(B.id, group.id, [D.id]);
  assert.deepEqual(add.added, [D.id]);
  await rejects(chats.removeMember(B.id, group.id, A.id), 'not_allowed');

  const gm = await messages.sendMessage(D.id, group.id, { text: 'Hi everyone' });
  assert.equal(lastEvent('message:new').memberIds.length, 3);
  // admin can delete others' messages in groups; plain members cannot
  const gm2 = await messages.sendMessage(B.id, group.id, { text: 'admin msg' });
  await rejects(messages.deleteMessages(D.id, group.id, { message_ids: [gm2.id], for_everyone: true }), 'cannot_delete');
  await messages.deleteMessages(B.id, group.id, { message_ids: [gm.id], for_everyone: true });

  await chats.leaveChat(A.id, group.id);
  const members = await chats.getMembers(B.id, group.id);
  assert.equal(members.find((m) => m.user.id === B.id).role, 'owner', 'admin becomes owner');
  assert.ok(lastEvent('chat:removed').userIds.includes(A.id));

  const preview = await chats.invitePreview(C.id, bView.invite_code || (await chats.getChat(B.id, group.id)).invite_code);
  assert.equal(preview.title, 'Family');
  assert.equal(preview.is_member, false);
  const code = (await chats.getChat(B.id, group.id)).invite_code;
  const joined = await chats.joinByInvite(C.id, code);
  assert.equal(joined.member_count, 3);

  const newCode = await chats.regenerateInvite(B.id, group.id);
  await rejects(chats.invitePreview(A.id, code), 'invite_invalid');
  assert.notEqual(newCode.invite_code, code);

  await settings.update({ max_group_members: 3 });
  await rejects(chats.joinByInvite(A.id, newCode.invite_code), 'group_full');
  await settings.update({ max_group_members: 1000 });

  const renamed = await chats.updateGroup(B.id, group.id, { title: 'Family 2' });
  assert.equal(renamed.title, 'Family 2');
});

test('per-user chat settings: mute, pin limit, archive, clear', async () => {
  const muted = await chats.updateMySettings(B.id, group.id, { muted_until: 'forever', is_pinned: true });
  assert.equal(muted.is_muted, true);
  assert.equal(muted.is_pinned, true);
  const archived = await chats.updateMySettings(B.id, privateChat.id, { is_archived: true });
  assert.equal(archived.is_archived, true);
  assert.equal((await chats.listChats(B.id)).some((c) => c.id === privateChat.id), false);
  assert.equal((await chats.listChats(B.id, { archived: true }))[0].id, privateChat.id);
  await chats.updateMySettings(B.id, privateChat.id, { is_archived: false });

  await chats.clearHistory(B.id, privateChat.id);
  assert.equal((await messages.listMessages(B.id, privateChat.id)).messages.length, 0);
  assert.ok((await messages.listMessages(A.id, privateChat.id)).messages.length > 0);
});

test('media: upload rules, access control, image message, forward', async () => {
  await rejects(media.registerUpload(A.id, fakeUpload('x.svg', 'image/svg+xml'), { kind: 'image' }), 'invalid_file_type');
  const img = await media.registerUpload(A.id, fakeUpload('photo.jpg', 'image/jpeg'), { kind: 'image', width: '800', height: '600' });
  assert.equal(img.url, `/api/media/${img.id}`);
  assert.equal(img.width, 800);

  await rejects(messages.sendMessage(B.id, privateChat.id, { type: 'image', media_id: img.id }), 'media_not_found');
  const m = await messages.sendMessage(A.id, privateChat.id, { type: 'image', media_id: img.id, text: 'look' });
  assert.equal(m.media.id, img.id);

  assert.ok(await media.getAccessible(B.id, img.id));
  await rejects(media.getAccessible(C.id, img.id), 'media_not_found');

  const voice = await media.registerUpload(A.id, fakeUpload('note.m4a', 'application/octet-stream'), { kind: 'voice', duration: '7' });
  const vm = await messages.sendMessage(A.id, privateChat.id, { type: 'voice', media_id: voice.id });
  assert.equal(vm.media.duration, 7);

  // B forwards A's photo into the group → group members (C) can now open it
  const fwd = await messages.forwardMessages(B.id, { from_chat_id: privateChat.id, message_ids: [m.id], to_chat_ids: [group.id] });
  assert.equal(fwd.forwarded, 1);
  const last = (await messages.listMessages(C.id, group.id, { limit: 1 })).messages[0];
  assert.equal(last.forwarded_from.name, 'Ali Khan');
  assert.ok(await media.getAccessible(C.id, img.id));

  const avatar = await media.registerUpload(A.id, fakeUpload('me.png', 'image/png'), { kind: 'avatar' });
  const me = await users.setAvatar(A.id, avatar.id);
  assert.equal(me.avatar_url, `/api/media/${avatar.id}/public`);
  assert.ok(await media.getPublic(avatar.id));
});

let reportId;

test('reports: create with snapshot, dedupe', async () => {
  const bad = await messages.sendMessage(A.id, privateChat.id, { text: 'buy cheap followers!!!' });
  const r = await reports.createReport(B.id, { target_type: 'message', target_id: bad.id, reason: 'spam', details: 'spam' });
  reportId = r.report_id;
  await rejects(reports.createReport(B.id, { target_type: 'message', target_id: bad.id, reason: 'spam' }), 'already_reported');
  await rejects(reports.createReport(C.id, { target_type: 'message', target_id: bad.id, reason: 'spam' }), 'message_not_found');
  const row = await db.one('SELECT snapshot FROM reports WHERE id = $1', [reportId]);
  assert.equal(row.snapshot.message.text, 'buy cheap followers!!!');
});

test('admin: login, dashboard, users, ban, reports, settings, logs', async () => {
  await db.query(`INSERT INTO admins (email, password_hash, name, role) VALUES ('boss@example.com', $1, 'Boss', 'super_admin')`, [
    crypto.hashPassword('SuperSecret123'),
  ]);
  await rejects(admin.login('boss@example.com', 'wrong', '9.9.9.9'), 'invalid_credentials');
  const { token } = await admin.login('BOSS@example.com', 'SuperSecret123', '9.9.9.9');
  const boss = await admin.authenticate(token);
  assert.equal(boss.role, 'super_admin');

  const dash = await admin.dashboard();
  assert.equal(dash.users_total, 5);
  assert.equal(dash.groups_total, 1);
  assert.equal(dash.reports_open, 1);
  assert.equal(dash.signups_30d.length, 30);
  assert.equal(dash.signups_30d[29].count, 5);

  const list = await admin.listUsers({ q: 'ali' });
  assert.equal(list.total, 1);

  // resolve report: delete message + 24h ban
  const detail = await admin.reportDetail(reportId);
  assert.equal(detail.report.reason, 'spam');
  const res = await admin.resolveReport(boss, reportId, { action: 'delete_message_and_ban', ban_hours: 24, note: 'spam' }, '9.9.9.9');
  assert.equal(res.closed_reports, 1);
  await rejects(auth.authenticate(A.tokens.access_token), 'session_revoked');
  const aRow = await db.one('SELECT status, banned_until FROM users WHERE id = $1', [A.id]);
  assert.equal(aRow.status, 'banned');
  assert.ok(new Date(aRow.banned_until) > new Date());

  // banned user cannot log in again
  rateLimit.reset('otp:');
  const otp = await auth.requestOtp(A.phone, '5.5.5.5');
  await rejects(auth.verifyOtp(A.phone, otp.dev_code, {}, '5.5.5.5'), 'account_banned');

  await admin.unbanUser(boss, A.id, '9.9.9.9');
  rateLimit.reset('otp:');
  const otp2 = await auth.requestOtp(A.phone, '5.5.5.5');
  A.tokens = await auth.verifyOtp(A.phone, otp2.dev_code, {}, '5.5.5.5');
  assert.equal(A.tokens.needs_profile, false);

  // moderators cannot manage settings or delete users
  await admin.createAdmin(boss, { email: 'mod@example.com', password: 'ModPassword123', role: 'moderator' }, '9.9.9.9');
  const mod = await admin.authenticate((await admin.login('mod@example.com', 'ModPassword123', '9.9.9.8')).token);
  assert.equal(admin.can(mod, 'users.ban'), true);
  assert.equal(admin.can(mod, 'users.delete'), false);
  assert.equal(admin.can(mod, 'settings'), false);
  assert.equal(admin.can(mod, 'reports.resolve'), true);

  await rejects(settings.update({ max_upload_mb: 0 }), 'invalid_setting');
  await rejects(settings.update({ nope: 1 }), 'invalid_setting');
  const s = await admin.updateSettings(boss, { registration_open: false }, '9.9.9.9');
  assert.equal(s.settings.registration_open, false);
  rateLimit.reset('otp:');
  await rejects(auth.requestOtp('+923009999999', '7.7.7.7'), 'registration_closed');
  await admin.updateSettings(boss, { registration_open: true }, '9.9.9.9');

  await admin.setGroupSuspended(boss, group.id, true, 'test', '9.9.9.9');
  await rejects(messages.sendMessage(B.id, group.id, { text: 'hello?' }), 'chat_suspended');
  await admin.setGroupSuspended(boss, group.id, false, null, '9.9.9.9');

  const logs = await admin.listLogs({});
  assert.ok(logs.logs.some((l) => l.action === 'report.resolve'));
  assert.ok(logs.logs.some((l) => l.action === 'user.ban'));

  // disabling an admin invalidates their existing token and blocks new logins
  const modToken = (await admin.login('mod@example.com', 'ModPassword123', '9.9.9.6')).token;
  await admin.updateAdmin(boss, mod.id, { is_active: false }, '9.9.9.9');
  await rejects(admin.authenticate(modToken), 'invalid_token');
  await rejects(admin.login('mod@example.com', 'ModPassword123', '9.9.9.5'), 'admin_disabled');
  await rejects(admin.updateAdmin(boss, boss.id, { role: 'moderator' }, '9.9.9.9'), 'invalid_input');
});

test('account deletion frees phone, leaves groups, keeps history as Deleted Account', async () => {
  await users.deleteAccount(D.id);
  const row = await db.one('SELECT status, phone FROM users WHERE id = $1', [D.id]);
  assert.equal(row.status, 'deleted');
  assert.equal(row.phone, `deleted:${D.id}`);
  const members = await chats.getMembers(B.id, group.id);
  assert.equal(members.some((m) => m.user.id === D.id), false);
  await rejects(chats.getOrCreatePrivate(B.id, D.id), 'user_not_found');

  rateLimit.reset('otp:');
  const again = await signup('+923001000004', 'Dua 2');
  assert.notEqual(again.id, D.id, 'same phone can register a fresh account');
});

test('saved messages (chat with yourself)', async () => {
  const saved = await chats.getOrCreatePrivate(B.id, B.id);
  assert.equal(saved.is_saved_messages, true);
  assert.equal(saved.title, 'Saved Messages');
  await messages.sendMessage(B.id, saved.id, { text: 'note to self' });
  const list = await chats.listChats(B.id);
  assert.ok(list.find((c) => c.id === saved.id).last_message.text === 'note to self');
});

test('markAllDelivered on reconnect', async () => {
  const chat = await chats.getOrCreatePrivate(A.id, C.id);
  const m = await messages.sendMessage(A.id, chat.id, { text: 'ping' });
  const n = await messages.markAllDelivered(C.id);
  assert.ok(n >= 1);
  const view = await chats.getChat(A.id, chat.id);
  assert.equal(view.delivered_up_to, m.id);
});
