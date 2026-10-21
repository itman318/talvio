'use strict';

/**
 * Batch A end-to-end tests: pins, mentions, mark-unread, silent & location messages, message search,
 * slow mode, join requests, invite links, ownership transfer, reserved usernames, feature flags,
 * ban appeals, admin notes, data export, content pages, version-targeted broadcasts, IP blacklist.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const crypto = require('../src/utils/crypto');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const stories = require('../src/services/story.service');
const appeals = require('../src/services/appeal.service');
const content = require('../src/services/content.service');
const announcements = require('../src/services/announcement.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');
const { isIpBlocked } = require('../src/http/middleware');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName, username, appVersion = '1.0.0') {
  const addr = `10.7.0.${(ip += 1)}`;
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: appVersion }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName, ...(username ? { username } : {}) });
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [s.user.id]);
  return { id: s.user.id, phone };
}

let A;
let B;
let C;
let boss;
let group;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923220000001', 'Amna', 'amna_k');
  B = await signup('+923220000002', 'Babar', 'babar_a');
  C = await signup('+923220000003', 'Celine', 'celine_x', '0.9.0');
  boss = await db.one(`INSERT INTO admins (email, password_hash, name, role) VALUES ('root@example.com', $1, 'Root', 'super_admin') RETURNING *`, [
    crypto.hashPassword('RootPassword1'),
  ]);
  group = (await chats.createGroup(A.id, { title: 'Team', member_ids: [B.id, C.id] })).chat;
});

test.after(async () => {
  await db.close();
});

test('mentions: @username and replies count; unread mention badge clears on read', async () => {
  const m1 = await messages.sendMessage(B.id, group.id, { text: 'Hey @amna_k and @CELINE_X, also @nobody_here' });
  assert.deepEqual(m1.mentions.sort(), [A.id, C.id].sort());
  const r = await messages.sendMessage(C.id, group.id, { text: 'agreed', reply_to_id: m1.id });
  assert.deepEqual(r.mentions, [B.id], 'replying mentions the original author');
  let chatA = await chats.getChat(A.id, group.id);
  assert.equal(chatA.unread_mentions, 1);
  await messages.markRead(A.id, group.id, r.id);
  chatA = await chats.getChat(A.id, group.id);
  assert.equal(chatA.unread_mentions, 0);
  const priv = await chats.getOrCreatePrivate(A.id, B.id);
  const pm = await messages.sendMessage(A.id, priv.id, { text: 'hi @babar_a' });
  assert.deepEqual(pm.mentions, [], 'no mentions in private chats');
});

test('pins: admins pin in groups, anyone in private chats, list & unpin', async () => {
  const m = await messages.sendMessage(A.id, group.id, { text: 'Meeting at 5 pm' });
  await rejects(messages.pinMessage(B.id, group.id, m.id), 'not_admin');
  const pins = await messages.pinMessage(A.id, group.id, m.id);
  assert.equal(pins[0].id, m.id);
  const chatB = await chats.getChat(B.id, group.id);
  assert.equal(chatB.pinned_message.id, m.id);
  assert.equal(chatB.pinned_count, 1);
  const last = (await messages.listMessages(B.id, group.id, { limit: 1 })).messages[0];
  assert.equal(last.meta.event, 'message_pinned');

  const priv = await chats.getOrCreatePrivate(A.id, B.id);
  const pm = await messages.sendMessage(A.id, priv.id, { text: 'my address' });
  await messages.pinMessage(B.id, priv.id, pm.id);
  assert.equal((await messages.listPins(A.id, priv.id)).length, 1);
  await messages.unpinMessage(A.id, group.id, m.id);
  assert.equal((await chats.getChat(B.id, group.id)).pinned_message, null);
});

test('mark as unread, silent and location messages', async () => {
  await chats.updateMySettings(C.id, group.id, { marked_unread: true });
  assert.equal((await chats.getChat(C.id, group.id)).marked_unread, true);
  const lastId = (await messages.listMessages(C.id, group.id, { limit: 1 })).messages[0].id;
  await messages.markRead(C.id, group.id, lastId);
  assert.equal((await chats.getChat(C.id, group.id)).marked_unread, false);

  const quiet = await messages.sendMessage(A.id, group.id, { text: 'good night', silent: true });
  assert.equal(quiet.silent, true);

  const loc = await messages.sendMessage(A.id, group.id, { type: 'location', location: { lat: 31.5204, lng: 74.3587, title: 'Lahore' } });
  assert.deepEqual(loc.meta.location, { lat: 31.5204, lng: 74.3587, title: 'Lahore' });
  assert.equal(loc.text, 'Lahore');
  await rejects(messages.sendMessage(A.id, group.id, { type: 'location', location: { lat: 200, lng: 0 } }), 'invalid_location');
  await rejects(messages.editMessage(A.id, loc.id, { text: 'x' }), 'cannot_edit');
});

test('message search: prefix, Urdu text, only my chats, per-chat filter', async () => {
  await messages.sendMessage(A.id, group.id, { text: 'Quarterly report is ready for review' });
  await messages.sendMessage(B.id, group.id, { text: 'رپورٹ مکمل ہو گئی' });
  const other = (await chats.createGroup(C.id, { title: 'Secret' })).chat;
  await messages.sendMessage(C.id, other.id, { text: 'quarterly numbers, private' });

  const r = await messages.searchMessages(A.id, { q: 'quart rep' });
  assert.equal(r.results.length, 1);
  assert.equal(r.results[0].chat.title, 'Team');
  assert.match(r.results[0].message.text, /Quarterly/);
  assert.equal((await messages.searchMessages(A.id, { q: 'رپورٹ' })).results.length, 1);
  assert.equal((await messages.searchMessages(C.id, { q: 'quarterly' })).results.length, 2);
  assert.equal((await messages.searchMessages(C.id, { q: 'quarterly', chat_id: other.id })).results.length, 1);
  assert.equal((await messages.searchMessages(A.id, { q: '!!' })).results.length, 0);
});

test('slow mode: members wait, admins exempt', async () => {
  await rejects(chats.updateGroup(B.id, group.id, { slow_mode_sec: 30 }), 'not_admin');
  await rejects(chats.updateGroup(A.id, group.id, { slow_mode_sec: 7 }), 'invalid_input');
  const g = await chats.updateGroup(A.id, group.id, { slow_mode_sec: 30 });
  assert.equal(g.slow_mode_sec, 30);
  // B's earlier messages are older than the slow-mode window
  await db.query(`UPDATE messages SET created_at = now() - interval '2 minutes' WHERE sender_id = $1`, [B.id]);
  await messages.sendMessage(B.id, group.id, { text: 'first' });
  await assert.rejects(messages.sendMessage(B.id, group.id, { text: 'second' }), (e) => e.code === 'slow_mode' && e.extra.retry_after > 0);
  await messages.sendMessage(A.id, group.id, { text: 'admin 1' });
  await messages.sendMessage(A.id, group.id, { text: 'admin 2' });
  await chats.updateGroup(A.id, group.id, { slow_mode_sec: 0 });
  await messages.sendMessage(B.id, group.id, { text: 'free again' });
});

test('invite links with limits/expiry and join requests', async () => {
  const D = await signup('+923220000004', 'Dawood');
  const E = await signup('+923220000005', 'Erum');
  const link = await chats.createInvite(A.id, group.id, { name: 'Once', usage_limit: 1 });
  await rejects(chats.createInvite(B.id, group.id, {}), 'not_admin');
  const preview = await chats.invitePreview(D.id, link.code);
  assert.equal(preview.title, 'Team');
  await chats.joinByInvite(D.id, link.code);
  await rejects(chats.invitePreview(E.id, link.code), 'invite_invalid');
  const list = await chats.listInvites(A.id, group.id);
  assert.equal(list.links[0].usage_count, 1);
  assert.equal(list.links[0].expired, true);

  const revoked = await chats.createInvite(A.id, group.id, { expire_hours: 24 });
  await chats.revokeInvite(A.id, group.id, revoked.code);
  await rejects(chats.joinByInvite(E.id, revoked.code), 'invite_invalid');

  // approval required
  await chats.updateGroup(A.id, group.id, { join_approval: true });
  const open = await chats.createInvite(A.id, group.id, {});
  const res = await chats.joinByInvite(E.id, open.code);
  assert.equal(res.requested, true);
  assert.equal((await chats.getChat(A.id, group.id)).pending_requests, 1);
  const reqs = await chats.listJoinRequests(A.id, group.id);
  assert.equal(reqs[0].user.id, E.id);
  await chats.resolveJoinRequest(A.id, group.id, E.id, true);
  const members = await chats.getMembers(A.id, group.id);
  assert.ok(members.some((m) => m.user.id === E.id));
  assert.equal((await chats.listInvites(A.id, group.id)).links.find((l) => l.code === open.code).usage_count, 1);
  await chats.updateGroup(A.id, group.id, { join_approval: false });
});

test('ownership transfer by owner and by admin panel', async () => {
  await rejects(chats.transferOwnershipByOwner(B.id, group.id, C.id), 'not_owner');
  await chats.transferOwnershipByOwner(A.id, group.id, B.id);
  let m = await chats.getMembers(A.id, group.id);
  assert.equal(m.find((x) => x.role === 'owner').user.id, B.id);
  assert.equal(m.find((x) => x.user.id === A.id).role, 'admin');
  await admin.transferGroupOwner(boss, group.id, { user_id: C.id }, '1.1.1.1');
  m = await chats.getMembers(A.id, group.id);
  assert.equal(m.find((x) => x.role === 'owner').user.id, C.id);
  assert.equal(m.filter((x) => x.role === 'owner').length, 1);
});

test('reserved usernames and feature flags', async () => {
  await rejects(users.updateProfile(B.id, { username: 'Support' }), 'username_reserved');
  await rejects(chats.createChannel(A.id, { title: 'x', username: 'official' }), 'username_reserved');
  await admin.setUsername(boss, B.id, 'support', '1.1.1.1');
  assert.equal((await users.getMe(B.id)).username, 'support');
  await users.updateProfile(B.id, { bio: 'help desk' }); // keeping a reserved name that was assigned is fine

  await settings.update({ feature_channels: false, feature_polls: false, feature_stories: false, feature_location: false });
  await rejects(chats.createChannel(A.id, { title: 'News' }), 'feature_disabled');
  await rejects(messages.sendMessage(A.id, group.id, { type: 'poll', poll: { question: 'q', options: ['a', 'b'] } }), 'feature_disabled');
  await rejects(stories.create(A.id, { media_id: 1 }), 'feature_disabled');
  await rejects(messages.sendMessage(A.id, group.id, { type: 'location', location: { lat: 1, lng: 1 } }), 'feature_disabled');
  const cfg = await settings.publicConfig();
  assert.equal(cfg.features.channels, false);
  await settings.update({ feature_channels: true, feature_polls: true, feature_stories: true, feature_location: true });
});

test('ban appeals: token after OTP, one pending at a time, accept unbans', async () => {
  await admin.banUser(boss, C.id, { reason: 'spam' }, '1.1.1.1');
  rateLimit.reset('otp:');
  const otp = await auth.requestOtp(C.phone, '8.8.8.8');
  let token;
  await assert.rejects(auth.verifyOtp(C.phone, otp.dev_code, {}, '8.8.8.8'), (e) => {
    assert.equal(e.code, 'account_banned');
    assert.ok(e.extra.appeal_token);
    assert.equal(e.extra.appeal, null);
    token = e.extra.appeal_token;
    return true;
  });
  await rejects(appeals.create({ appeal_token: 'bad', message: 'please review my account' }), 'invalid_token');
  await appeals.create({ appeal_token: token, message: 'It was a misunderstanding, please review' });
  await rejects(appeals.create({ appeal_token: token, message: 'again please review this' }), 'appeal_pending');
  const list = await appeals.list({});
  assert.equal(list.appeals[0].user_id, C.id);
  await appeals.resolve(boss, list.appeals[0].id, { accept: true, reply: 'Unbanned, sorry' }, '1.1.1.1');
  const row = await db.one('SELECT status FROM users WHERE id = $1', [C.id]);
  assert.equal(row.status, 'active');
  await rejects(appeals.resolve(boss, list.appeals[0].id, { accept: false }, '1.1.1.1'), 'appeal_not_found');
});

test('admin notes, user detail, data export', async () => {
  await admin.addNote(boss, B.id, { text: 'Called about spam complaints, warned.' }, '1.1.1.1');
  const d = await admin.userDetail(B.id);
  assert.equal(d.notes[0].text, 'Called about spam complaints, warned.');
  const data = await admin.exportUser(boss, A.id, '1.1.1.1');
  assert.equal(data.profile.id, A.id);
  assert.ok(data.messages_sent.length > 3);
  assert.ok(data.chats.some((c) => c.title === 'Team'));
  await admin.deleteNote(boss, d.notes[0].id);
  assert.equal((await admin.userDetail(B.id)).notes.length, 0);
});

test('content pages and HTML rendering', async () => {
  assert.equal((await content.get('privacy')).body, '');
  await content.update(boss.id, 'privacy', { title: 'Privacy Policy', body: '# Data we keep\n\nYour phone number <and> messages.' });
  const p = await content.get('privacy');
  const html = content.renderHtml(p);
  assert.match(html, /<h2>Data we keep<\/h2>/);
  assert.match(html, /&lt;and&gt;/, 'html is escaped');
  await rejects(content.get('secret'), 'page_not_found');
  await rejects(content.update(boss.id, 'secret', { title: 'x' }), 'invalid_input');
});

test('broadcast targeted at old app versions; IP blacklist', async () => {
  const old = await signup('+923220000009', 'Old Phone', null, '0.9.0');
  const a = await announcements.create(boss.id, { title: 'Please update', body: 'New version out', target: { app_version_below: '1.0.0' } });
  assert.equal(a.recipients, 1, 'only the 0.9.0 device');
  assert.equal((await announcements.forUser(old.id)).length, 1);
  assert.equal((await announcements.forUser(A.id)).length, 0);
  await rejects(announcements.create(boss.id, { title: 't', body: 'b', target: { app_version_below: 'v2' } }), 'invalid_input');

  await settings.update({ blocked_ips: ['203.0.113.', '198.51.100.7'] });
  assert.equal(await isIpBlocked('203.0.113.55'), true);
  assert.equal(await isIpBlocked('::ffff:198.51.100.7'), true);
  assert.equal(await isIpBlocked('198.51.100.70'), false);
  await settings.update({ blocked_ips: [] });
});
