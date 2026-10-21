'use strict';

/**
 * Phase 2 end-to-end tests (channels, polls, reactions, scheduled posts, folders, stories,
 * moderation, support tickets, announcements, admin 2FA) against a real PostgreSQL database.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'chatapp-p2-'));
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';
process.env.UPLOAD_DIR = path.join(TMP, 'uploads');

const db = require('../src/db');
const bus = require('../src/bus');
const crypto = require('../src/utils/crypto');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const media = require('../src/services/media.service');
const reports = require('../src/services/report.service');
const folders = require('../src/services/folder.service');
const stories = require('../src/services/story.service');
const support = require('../src/services/support.service');
const announcements = require('../src/services/announcement.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');

const events = [];
for (const name of ['message:new', 'message:poll', 'message:reactions', 'support:reply', 'chat:updated']) {
  bus.on(name, (e) => events.push({ name, ...e }));
}
const lastEvent = (name) => [...events].reverse().find((e) => e.name === name);

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.9.0.${(ip += 1)}`;
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: phone.startsWith('+92') ? 'android' : 'ios' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  return { id: s.user.id, phone };
}

/** Pretend the account is a few days old so the new-account link rule doesn't apply. */
async function age(user) {
  await db.query(`UPDATE users SET created_at = now() - interval '3 days' WHERE id = $1`, [user.id]);
}

function fakeUpload(name, mime) {
  const dir = path.join(process.env.UPLOAD_DIR, 'x');
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, crypto.randomToken(8) + path.extname(name));
  fs.writeFileSync(p, 'data');
  return { path: p, size: 4, mimetype: mime, originalname: name };
}

let A;
let B;
let C;
let D;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  A = await signup('+923110000001', 'Asad');
  B = await signup('+923110000002', 'Bano');
  C = await signup('+923110000003', 'Chaudhry');
  D = await signup('+447700900004', 'Daniel');
  for (const u of [A, B, C, D]) await age(u);
});

test.after(async () => {
  await db.close();
  fs.rmSync(TMP, { recursive: true, force: true });
});

let channel;

test('channels: create, public username, join, admin-only posting, anonymity, views, stats', async () => {
  await users.updateProfile(B.id, { username: 'bano_pk' });
  await rejects(chats.createChannel(A.id, { title: 'News', username: 'bano_pk' }), 'username_taken');
  channel = await chats.createChannel(A.id, { title: 'Daily News', description: 'Updates', username: 'dailynews_pk' });
  assert.equal(channel.type, 'channel');
  assert.equal(channel.username, 'dailynews_pk');
  assert.equal(channel.is_public, true);
  assert.equal(channel.can_post, true);
  await rejects(users.updateProfile(C.id, { username: 'DailyNews_PK' }), 'username_taken');

  const found = await chats.searchPublic(B.id, 'dailynews');
  assert.equal(found[0].chat_id, channel.id);
  const preview = await chats.publicPreview(B.id, '@dailynews_pk');
  assert.equal(preview.is_member, false);

  const joined = await chats.joinPublic(B.id, channel.id);
  assert.equal(joined.my_role, 'member');
  assert.equal(joined.can_post, false);
  await chats.joinPublic(C.id, channel.id);

  await rejects(messages.sendMessage(B.id, channel.id, { text: 'can I post?' }), 'not_admin');
  const post = await messages.sendMessage(A.id, channel.id, { text: 'Breaking: Phase 2 is live' });
  assert.equal(post.sender_id, null, 'channel posts hide the admin');
  assert.equal(post.author_signature, null);
  assert.ok(lastEvent('message:new').memberIds.includes(C.id));

  await chats.updateGroup(A.id, channel.id, { signatures: true });
  const signed = await messages.sendMessage(A.id, channel.id, { text: 'Signed post' });
  assert.equal(signed.author_signature, 'Asad');

  // subscribers only see admins in the member list; no join/leave service messages in channels
  const visible = await chats.getMembers(B.id, channel.id);
  assert.deepEqual(visible.map((m) => m.role), ['owner']);
  const sys = await db.one(`SELECT count(*) AS n FROM messages WHERE chat_id = $1 AND type = 'system'`, [channel.id]);
  assert.equal(sys.n, 1, 'only "channel created"');

  // views counted once per user
  await messages.recordViews(B.id, channel.id, [post.id, signed.id]);
  await messages.recordViews(B.id, channel.id, [post.id]);
  const v = await messages.recordViews(C.id, channel.id, [post.id]);
  assert.equal(v.views[post.id], 2);

  await rejects(messages.deleteMessages(B.id, channel.id, { message_ids: [post.id], for_everyone: true }), 'cannot_delete');
  const edited = await messages.editMessage(A.id, signed.id, { text: 'Signed post (edited)' });
  assert.ok(edited.edited_at);

  const stats = await chats.chatStats(A.id, channel.id);
  assert.equal(stats.members, 3);
  assert.equal(stats.views_total, 3);
  assert.equal(stats.top_posts[0].id, post.id);
  assert.equal(stats.joins_30d.length, 30);
  await rejects(chats.chatStats(B.id, channel.id), 'not_admin');

  await chats.leaveChat(C.id, channel.id);
  assert.equal((await chats.getChat(A.id, channel.id)).member_count, 2);

  await chats.setChatUsername(A.id, channel.id, null);
  await rejects(chats.publicPreview(B.id, 'dailynews_pk'), 'chat_not_found');
  await rejects(chats.joinPublic(C.id, channel.id), 'chat_not_found');
});

let group;
let poll;

test('polls: create, vote, quiz reveal, close, voters, realtime counts', async () => {
  group = (await chats.createGroup(A.id, { title: 'Friends', member_ids: [B.id, C.id] })).chat;
  const priv = await chats.getOrCreatePrivate(A.id, B.id);
  await rejects(messages.sendMessage(A.id, priv.id, { type: 'poll', poll: { question: 'Q?', options: ['a', 'b'] } }), 'invalid_poll');
  await rejects(messages.sendMessage(A.id, group.id, { type: 'poll', poll: { question: 'Q?', options: ['a'] } }), 'invalid_poll');
  await rejects(messages.sendMessage(A.id, group.id, { type: 'poll', poll: { question: 'Q?', options: ['a', 'A'] } }), 'invalid_poll');

  poll = await messages.sendMessage(A.id, group.id, {
    type: 'poll',
    poll: { question: 'Dinner?', options: ['Biryani', 'Karahi', 'Pizza'], anonymous: false, multiple: true },
  });
  assert.equal(poll.type, 'poll');
  assert.equal(poll.text, 'Dinner?');
  assert.equal(poll.poll.options.length, 3);

  let r = await messages.vote(B.id, poll.id, [0, 1]);
  assert.deepEqual(r.my_votes.sort(), [0, 1]);
  r = await messages.vote(C.id, poll.id, [0]);
  assert.equal(r.total_voters, 2);
  assert.equal(r.options[0].votes, 2);
  const ev = lastEvent('message:poll');
  assert.equal(ev.poll.options[0].votes, 2);
  assert.deepEqual(ev.poll.my_votes, [], 'broadcast never leaks individual votes');
  const voters = await messages.pollVoters(A.id, poll.id, 0);
  assert.deepEqual(voters.map((u) => u.id).sort(), [B.id, C.id].sort());
  r = await messages.vote(B.id, poll.id, []); // retract
  assert.equal(r.total_voters, 1);

  await rejects(messages.closePoll(B.id, poll.id), 'not_allowed');
  await messages.closePoll(A.id, poll.id);
  await rejects(messages.vote(B.id, poll.id, [2]), 'poll_closed');

  const quiz = await messages.sendMessage(A.id, group.id, {
    type: 'poll',
    poll: { question: 'Capital of Pakistan?', options: ['Lahore', 'Islamabad'], quiz: true, correct_option: 1, explanation: 'Since 1967' },
  });
  assert.equal(quiz.poll.correct_option, null, 'answer hidden before voting');
  await rejects(messages.vote(B.id, quiz.id, [0, 1]), 'invalid_input');
  const answered = await messages.vote(B.id, quiz.id, [0]);
  assert.equal(answered.correct_option, 1);
  assert.equal(answered.explanation, 'Since 1967');
  await rejects(messages.vote(B.id, quiz.id, [1]), 'already_voted');
  await rejects(messages.pollVoters(A.id, quiz.id, 0), 'anonymous_poll');
});

test('reactions: add, change, remove, validation, event', async () => {
  const m = await messages.sendMessage(B.id, group.id, { text: 'Hello friends' });
  let r = await messages.react(A.id, m.id, '👍');
  r = await messages.react(C.id, m.id, '👍');
  assert.deepEqual(r.reactions, [{ emoji: '👍', count: 2 }]);
  r = await messages.react(C.id, m.id, '❤️');
  assert.equal(r.my_reaction, '❤️');
  assert.equal(r.reactions.length, 2);
  await rejects(messages.react(C.id, m.id, '💩'), 'invalid_input');
  r = await messages.react(A.id, m.id, null);
  assert.deepEqual(r.reactions, [{ emoji: '❤️', count: 1 }]);
  assert.equal(lastEvent('message:reactions').messageId, m.id);
  const list = await messages.listMessages(C.id, group.id, { limit: 1 });
  assert.equal(list.messages[0].my_reaction, '❤️');
  await rejects(messages.react(D.id, m.id, '👍'), 'chat_not_found');
});

test('scheduled posts: validation, publish when due, cancel', async () => {
  const soon = new Date(Date.now() + 5 * 60 * 1000).toISOString();
  await rejects(messages.sendMessage(A.id, channel.id, { text: 'past', schedule_at: new Date().toISOString() }), 'invalid_input');
  await rejects(messages.sendMessage(B.id, channel.id, { text: 'not admin', schedule_at: soon }), 'not_admin');
  const s1 = await messages.sendMessage(A.id, channel.id, { text: 'Good morning subscribers', schedule_at: soon });
  const s2 = await messages.sendMessage(A.id, channel.id, { text: 'Cancel me', schedule_at: soon });
  assert.ok(s1.scheduled.id);
  assert.equal((await messages.listScheduled(A.id, channel.id)).length, 2);
  await messages.cancelScheduled(A.id, s2.scheduled.id);

  assert.equal(await messages.runDueScheduled(), 0, 'nothing due yet');
  await db.query(`UPDATE scheduled_messages SET send_at = now() - interval '1 second' WHERE id = $1`, [s1.scheduled.id]);
  assert.equal(await messages.runDueScheduled(), 1);
  const last = (await messages.listMessages(B.id, channel.id, { limit: 1 })).messages[0];
  assert.equal(last.text, 'Good morning subscribers');
  assert.equal((await messages.listScheduled(A.id, channel.id)).length, 0);
});

test('folders: create with own chats only, update, reorder, delete', async () => {
  const other = (await chats.createGroup(C.id, { title: 'Not yours' })).chat;
  const f = await folders.create(A.id, { name: 'Work', chat_ids: [group.id, other.id], include_channels: true });
  assert.deepEqual(f.chat_ids, [group.id], 'chats you are not in are dropped');
  assert.equal(f.include_channels, true);
  await rejects(folders.create(A.id, { name: 'Empty' }), 'empty_folder');
  const f2 = await folders.create(A.id, { name: 'Unread', include_private: true, include_unread_only: true });
  const updated = await folders.update(A.id, f.id, { name: 'Office', include_groups: true });
  assert.equal(updated.name, 'Office');
  const ordered = await folders.reorder(A.id, [f2.id, f.id]);
  assert.deepEqual(ordered.map((x) => x.id), [f2.id, f.id]);
  await rejects(folders.update(B.id, f.id, { name: 'hack' }), 'folder_not_found');
  await folders.remove(A.id, f2.id);
  assert.equal((await folders.list(A.id)).length, 1);
});

test('stories: privacy, media access, views, viewers, reply, delete', async () => {
  // A ↔ B are contacts both ways; C has no relation with A
  await users.addContact(A.id, B.id);
  await users.addContact(B.id, A.id);
  const img = await media.registerUpload(A.id, fakeUpload('s.jpg', 'image/jpeg'), { kind: 'image' });
  await rejects(stories.create(A.id, { media_id: 999999 }), 'media_not_found');
  const s = await stories.create(A.id, { media_id: img.id, caption: 'Sunset', privacy: 'contacts' });

  const bFeed = await stories.feed(B.id);
  assert.equal(bFeed[0].user.id, A.id);
  assert.equal(bFeed[0].has_unseen, true);
  assert.equal((await stories.feed(C.id)).length, 0);
  assert.ok(await media.getAccessible(B.id, img.id));
  await rejects(media.getAccessible(C.id, img.id), 'media_not_found');

  await stories.view(B.id, s.id);
  await stories.view(B.id, s.id, { emoji: '❤️' });
  await rejects(stories.view(C.id, s.id), 'story_not_found');
  const viewers = await stories.viewers(A.id, s.id);
  assert.equal(viewers.length, 1);
  assert.equal(viewers[0].emoji, '❤️');
  assert.equal((await stories.feed(A.id))[0].stories[0].views_count, 1);
  assert.equal((await stories.feed(B.id))[0].has_unseen, false);

  const reply = await stories.reply(B.id, s.id, { text: 'Beautiful!' });
  assert.deepEqual(reply.meta, { story_reply: s.id });

  await stories.remove(A.id, s.id);
  assert.equal((await stories.feed(B.id)).length, 0);
});

test('moderation: banned words, links from new accounts, copy-paste spam, report threshold, phone blacklist', async () => {
  await settings.update({ banned_words: ['scamword', 'جعلی'], banned_words_action: 'block' });
  await rejects(messages.sendMessage(B.id, group.id, { text: 'this is a SCAMWORD offer' }), 'message_blocked');
  await rejects(messages.sendMessage(B.id, group.id, { text: 'یہ جعلی ہے' }), 'message_blocked');
  await messages.sendMessage(B.id, group.id, { text: 'scamwords is a different word' });

  await settings.update({ banned_words_action: 'flag' });
  const flagged = await messages.sendMessage(B.id, group.id, { text: 'buy scamword now' });
  await new Promise((r) => setTimeout(r, 100));
  const auto = await db.one(`SELECT * FROM reports WHERE source = 'auto' AND target_type = 'message' AND target_id = $1`, [flagged.id]);
  assert.ok(auto, 'flagged message gets an automatic report');
  await settings.update({ banned_words: [] });

  const fresh = await signup('+923110000099', 'Newbie');
  const freshChat = await chats.getOrCreatePrivate(fresh.id, A.id);
  await rejects(messages.sendMessage(fresh.id, freshChat.id, { text: 'visit www.example.com now' }), 'links_restricted');
  await messages.sendMessage(fresh.id, freshChat.id, { text: 'hello without links' });

  // same text to 3 different chats within 10 minutes → restricted
  await settings.update({ spam_duplicate_threshold: 3, spam_restrict_minutes: 30 });
  const spamText = 'Earn 50000 daily, message me';
  for (const target of [A, B, D]) {
    const ch = await chats.getOrCreatePrivate(C.id, target.id);
    await messages.sendMessage(C.id, ch.id, { text: spamText });
  }
  await new Promise((r) => setTimeout(r, 150));
  const cRow = await db.one('SELECT restricted_until FROM users WHERE id = $1', [C.id]);
  assert.ok(new Date(cRow.restricted_until) > new Date(), 'spammer is restricted');
  await rejects(messages.sendMessage(C.id, group.id, { text: 'anything' }), 'restricted');
  const boss = await db.one(`INSERT INTO admins (email, password_hash, name, role) VALUES ('mod2@example.com', $1, 'Mod', 'super_admin') RETURNING *`, [
    crypto.hashPassword('ModeratorPass1'),
  ]);
  await admin.unrestrictUser(boss, C.id, '1.1.1.1');
  await messages.sendMessage(C.id, group.id, { text: 'free again' });

  // many different people reporting one user → restricted pending review
  await settings.update({ auto_restrict_reports: 2 });
  await reports.createReport(A.id, { target_type: 'user', target_id: D.id, reason: 'abuse' });
  assert.equal((await db.one('SELECT restricted_until FROM users WHERE id = $1', [D.id])).restricted_until, null);
  await reports.createReport(B.id, { target_type: 'user', target_id: D.id, reason: 'abuse' });
  assert.ok((await db.one('SELECT restricted_until FROM users WHERE id = $1', [D.id])).restricted_until);

  await settings.update({ blocked_phone_prefixes: ['+1900'] });
  rateLimit.reset('otp:');
  await rejects(auth.requestOtp('+19005550100', '3.3.3.3'), 'phone_not_allowed');
  await settings.update({ blocked_phone_prefixes: [], spam_duplicate_threshold: 5, auto_restrict_reports: 5 });
});

test('support tickets: user opens, admin replies, statuses', async () => {
  const t = await support.createTicket(B.id, { subject: 'Cannot upload video', category: 'bug', message: 'It fails at 90%' });
  assert.equal(t.ticket.status, 'open');
  const boss = await db.one(`SELECT * FROM admins WHERE email = 'mod2@example.com'`);
  const list = await support.adminList({});
  assert.equal(list.tickets[0].id, t.ticket.id);
  assert.equal(list.tickets[0].awaiting_admin, true);

  await support.adminReply(boss, t.ticket.id, { text: 'Please update the app and try again' });
  assert.equal(lastEvent('support:reply').userId, B.id);
  let mine = await support.listMine(B.id);
  assert.equal(mine[0].status, 'pending');
  assert.equal(mine[0].unread, true);
  const opened = await support.getMine(B.id, t.ticket.id);
  assert.equal(opened.messages.length, 2);
  mine = await support.listMine(B.id);
  assert.equal(mine[0].unread, false);

  await support.userReply(B.id, t.ticket.id, { text: 'Still failing' });
  assert.equal((await support.adminGet(t.ticket.id)).ticket.status, 'open');
  await support.adminUpdate(t.ticket.id, { priority: 'high', status: 'resolved' });
  await support.userClose(B.id, t.ticket.id);
  await rejects(support.userReply(B.id, t.ticket.id, { text: 'again' }), 'ticket_closed');
  await rejects(support.getMine(C.id, t.ticket.id), 'ticket_not_found');
});

test('announcements: targeting by phone prefix and platform, dismiss', async () => {
  const boss = await db.one(`SELECT * FROM admins WHERE email = 'mod2@example.com'`);
  const pk = await announcements.create(boss.id, { title: 'Eid Mubarak', body: 'From the team', target: { phone_prefix: '+92' } });
  assert.ok(pk.recipients >= 3);
  const ios = await announcements.create(boss.id, { title: 'iOS update', body: 'New version', target: { platform: 'ios' } });
  assert.equal(ios.recipients, 1);

  assert.deepEqual((await announcements.forUser(A.id)).map((x) => x.title), ['Eid Mubarak']);
  assert.deepEqual((await announcements.forUser(D.id)).map((x) => x.title), ['iOS update']);
  await announcements.dismiss(A.id, pk.id);
  assert.equal((await announcements.forUser(A.id)).length, 0);
  await announcements.expire(ios.id);
  assert.equal((await announcements.forUser(D.id)).length, 0);
  await rejects(announcements.create(boss.id, { title: 'x', body: 'y', target: { phone_prefix: '92abc' } }), 'invalid_input');
});

test('admin 2FA: setup, enable, login with code / backup code, disable, policy', async () => {
  await db.query(`INSERT INTO admins (email, password_hash, name, role) VALUES ('owner@example.com', $1, 'Owner', 'super_admin')`, [
    crypto.hashPassword('OwnerPassword1'),
  ]);
  let me = await admin.authenticate((await admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.1')).token);
  const { secret, otpauth_url: url } = await admin.twoFactorSetup(me);
  assert.match(url, /^otpauth:\/\/totp\//);
  await rejects(admin.twoFactorEnable(me, '000000', '7.7.7.1'), 'two_factor_invalid');
  const { backup_codes: codes } = await admin.twoFactorEnable(me, crypto.totp(secret), '7.7.7.1');
  assert.equal(codes.length, 8);

  await rejects(admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.2'), 'two_factor_required');
  await rejects(admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.2', '123456'), 'two_factor_invalid');
  const ok = await admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.2', crypto.totp(secret));
  assert.ok(ok.token);
  assert.equal(ok.admin.two_factor, true);
  await admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.3', codes[0]);
  await rejects(admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.3', codes[0]), 'two_factor_invalid');

  me = await admin.authenticate(ok.token);
  await settings.update({ require_admin_2fa: true });
  await rejects(admin.twoFactorDisable(me, { password: 'OwnerPassword1', code: crypto.totp(secret) }, '7.7.7.1'), 'two_factor_required_by_policy');
  await settings.update({ require_admin_2fa: false });
  await admin.twoFactorDisable(me, { password: 'OwnerPassword1', code: crypto.totp(secret) }, '7.7.7.1');
  assert.ok((await admin.login('owner@example.com', 'OwnerPassword1', '7.7.7.4')).token);
});

test('admin: channels in group list, verify badge, dashboard counters, restrict', async () => {
  const boss = await db.one(`SELECT * FROM admins WHERE email = 'mod2@example.com'`);
  const list = await admin.listGroups({ type: 'channel' });
  assert.equal(list.groups[0].id, channel.id);
  await admin.setChatVerified(boss, channel.id, true, '1.1.1.1');
  assert.equal((await chats.getChat(A.id, channel.id)).is_verified, true);
  const d = await admin.dashboard();
  assert.equal(d.channels_total, 1);
  assert.ok(d.tickets_open >= 0);
  await admin.restrictUser(boss, B.id, { minutes: 10, reason: 'cool down' }, '1.1.1.1');
  const r = await admin.listUsers({ status: 'restricted' });
  assert.ok(r.users.some((u) => u.id === B.id));
  await rejects(messages.sendMessage(B.id, group.id, { text: 'hi' }), 'restricted');
});
