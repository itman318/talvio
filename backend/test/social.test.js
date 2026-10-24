'use strict';

/** Call links & waiting, login alerts, birthdays, highlights, story reactions, privacy exceptions, read receipts. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const bus = require('../src/bus');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const users = require('../src/services/user.service');
const calls = require('../src/services/call.service');
const stories = require('../src/services/story.service');
const mediaService = require('../src/services/media.service');
const settings = require('../src/services/settings.service');

let n = 0;
async function user() {
  rateLimit.reset();
  const phone = `+92378${String(1000000 + ++n)}`;
  const r = await auth.requestOtp(phone, '10.9.1.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name: 't' }, '10.9.1.1');
  await db.query("UPDATE users SET first_name = 'T', created_at = now() - interval '3 days' WHERE id = $1", [t.user.id]);
  return t.user.id;
}
async function story(owner, privacy = 'contacts') {
  const m = await db.one(
    `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name) VALUES ($1, 'image', 'image/jpeg', 100, $2, 'x') RETURNING id`,
    [owner, `t/${Math.random()}`],
  );
  return { ...(await stories.create(owner, { media_id: m.id, privacy })), media_id: m.id };
}
const contact = (owner, other) => db.query('INSERT INTO contacts (owner_id, contact_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [owner, other]);

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('call links skip calls privacy but not blocks; second call waits, third is busy', async () => {
  const a = await user();
  const b = await user();
  const c = await user();
  const d = await user();
  await users.updatePrivacy(a, { calls: 'nobody' });
  await assert.rejects(calls.startCall(b, null, { user_id: a }), (e) => e.code === 'privacy_calls');
  const { link } = await calls.createLink(a, { video: true });
  assert.equal(link.code.length, 12);
  const info = await calls.resolveLink(b, link.code);
  assert.equal(info.user.id, a);
  const r = await calls.startCall(b, null, { link: link.code });
  assert.equal(r.call.status, 'ringing');
  assert.equal(r.call.video, true);
  await calls.acceptCall(a, null, r.call.id);

  // c calls a (contacts/exception makes it allowed) while a talks to b → waiting
  await users.setPrivacyExceptions(a, 'calls', { allow: [c] });
  const w = await calls.startCall(c, null, { user_id: a });
  assert.equal(w.call.status, 'ringing');
  assert.equal(w.call.waiting, true);
  const act = await calls.getActive(a);
  assert.equal(act.call.id, r.call.id);
  assert.equal(act.waiting.id, w.call.id);
  // a third caller gets busy
  await users.setPrivacyExceptions(a, 'calls', { allow: [c, d] });
  const busy = await calls.startCall(d, null, { user_id: a });
  assert.equal(busy.call.status, 'busy');
  // end & answer: accepting the waiting call ends the first one
  await calls.acceptCall(a, null, w.call.id);
  const first = await db.one('SELECT status FROM calls WHERE id = $1', [r.call.id]);
  assert.equal(first.status, 'ended');
  await calls.hangup(a, w.call.id);

  // blocked users can't use the link
  await users.block(a, b);
  await assert.rejects(calls.startCall(b, null, { link: link.code }), (e) => e.code === 'blocked');
  await calls.deleteLink(a, link.code);
  await assert.rejects(calls.resolveLink(b, link.code), (e) => e.code === 'link_not_found');
});

test('new login tells the other devices', async () => {
  const a = await user();
  const seen = [];
  const on = (e) => seen.push(e);
  bus.on('rt:emit', on);
  rateLimit.reset();
  const phone = (await db.one('SELECT phone FROM users WHERE id = $1', [a])).phone;
  const r = await auth.requestOtp(phone, '10.9.1.2');
  await auth.verifyOtp(phone, r.dev_code, { name: 'Pixel 9' }, '10.9.1.2');
  await new Promise((res) => setTimeout(res, 50));
  bus.off('rt:emit', on);
  const ev = seen.find((e) => e.event === 'session:new');
  assert.ok(ev, 'session:new emitted');
  assert.equal(ev.sessionIds.length, 1);
});

test('birthday: shown by privacy + exceptions, upcoming list', async () => {
  const a = await user();
  const b = await user();
  const c = await user();
  const today = new Date();
  const mm = String(today.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(today.getUTCDate()).padStart(2, '0');
  await assert.rejects(users.updateProfile(a, { birthday: '1990-02-30' }));
  await assert.rejects(users.updateProfile(a, { birthday: '3000-01-01' }));
  const me = await users.updateProfile(a, { birthday: `1990-${mm}-${dd}` });
  assert.deepEqual(me.birthday, { day: Number(dd), month: Number(mm), year: 1990 });
  // b saved a, a saved b → contacts can see day + month, no year
  await contact(b, a);
  await contact(a, b);
  const seenByB = await users.getUser(b, a);
  assert.deepEqual(seenByB.birthday, { day: Number(dd), month: Number(mm) });
  // c saved a but a didn't save c
  await contact(c, a);
  assert.equal((await users.getUser(c, a)).birthday, null);
  await users.setPrivacyExceptions(a, 'birthday', { allow: [c] });
  assert.ok((await users.getUser(c, a)).birthday);
  await users.setPrivacyExceptions(a, 'birthday', { deny: [b] });
  assert.equal((await users.getUser(b, a)).birthday, null);
  await users.setPrivacyExceptions(a, 'birthday', {});
  const up = await users.upcomingBirthdays(b);
  assert.equal(up.length, 1);
  assert.equal(up[0].in_days, 0);
  // year-less birthday
  const me2 = await users.updateProfile(a, { birthday: `${mm}-${dd}` });
  assert.deepEqual(me2.birthday, { day: Number(dd), month: Number(mm) });
  assert.equal(await users.sendBirthdayReminders() >= 1, true);
  assert.equal(await users.sendBirthdayReminders(), 0); // once a day
});

test('last seen / avatar exceptions: never share with', async () => {
  const a = await user();
  const b = await user();
  await db.query("UPDATE users SET privacy_last_seen = 'everyone', privacy_avatar = 'everyone' WHERE id = $1", [a]);
  await chats.getOrCreatePrivate(a, b);
  assert.equal((await users.getUser(b, a)).last_seen_hidden, false);
  await users.setPrivacyExceptions(a, 'last_seen', { deny: [b] });
  assert.equal((await users.getUser(b, a)).last_seen_hidden, true);
  const ex = await users.getPrivacyExceptions(a);
  assert.equal(ex.last_seen.deny[0].id, b);
  await assert.rejects(users.setPrivacyExceptions(a, 'nonsense', {}));
  // group add exception
  await users.updatePrivacy(a, { group_add: 'nobody' });
  const f1 = await chats.filterAddable(b, [a]);
  assert.equal(f1.ok.length, 0);
  await users.setPrivacyExceptions(a, 'group_add', { allow: [b] });
  const f2 = await chats.filterAddable(b, [a]);
  assert.deepEqual(f2.ok, [a]);
});

test('read receipts off: no blue ticks either way in private chats', async () => {
  const a = await user();
  const b = await user();
  const chat = await chats.getOrCreatePrivate(a, b);
  const m = await messages.sendMessage(a, chat.id, { type: 'text', text: 'hi' });
  await users.updatePrivacy(b, { read_receipts: false });
  const events = [];
  const on = (e) => events.push('read');
  const on2 = (e) => events.push('delivered');
  bus.on('receipt:read', on);
  bus.on('receipt:delivered', on2);
  await messages.markRead(b, chat.id, m.id);
  bus.off('receipt:read', on);
  bus.off('receipt:delivered', on2);
  assert.deepEqual(events, ['delivered']);
  const list = await chats.listChats(a);
  const row = (list.chats || list).find((x) => x.id === chat.id);
  assert.equal(row.read_up_to, 0);
  const info = await messages.messageInfo(a, m.id);
  assert.equal(info.read.length, 0);
  assert.equal(info.delivered.length, 1);
  await users.updatePrivacy(b, { read_receipts: true });
  const row2 = ((await chats.listChats(a)).chats || (await chats.listChats(a))).find((x) => x.id === chat.id);
  assert.equal(row2.read_up_to, m.id);
  const me = await users.getMe(b);
  assert.equal(me.privacy.read_receipts, 'on');
});

test('story reactions go to the chat; highlights keep expired stories on the profile', async () => {
  const a = await user();
  const b = await user();
  const x = await user();
  await contact(a, b);
  await contact(b, a);
  const s = await story(a);
  await assert.rejects(stories.react(b, s.id, { emoji: '💩' }));
  const r = await stories.react(b, s.id, { emoji: '🔥' });
  assert.equal(r.message.text, '🔥');
  assert.equal(r.message.meta.story.reaction, '🔥');
  assert.equal(r.message.meta.story.id, s.id);
  const again = await stories.react(b, s.id, { emoji: '🔥' });
  assert.equal(again.message, undefined);
  const viewers = await stories.viewers(a, s.id);
  assert.equal(viewers[0].emoji, '🔥');
  const rep = await stories.reply(b, s.id, { text: 'nice' });
  assert.equal(rep.meta.story.reaction, undefined);

  const h = await stories.createHighlight(a, { title: 'Trip', story_ids: [s.id] });
  assert.equal(h.stories.length, 1);
  await db.query("UPDATE stories SET expires_at = now() - interval '1 day' WHERE id = $1", [s.id]);
  const list = await stories.listHighlights(b, a);
  assert.equal(list.highlights.length, 1);
  assert.equal(list.highlights[0].count, 1);
  assert.ok(await mediaService.getAccessible(b, s.media_id), 'highlight media reachable');
  // a stranger (not in a's contacts) can't see a contacts-only highlight
  assert.equal((await stories.listHighlights(x, a)).highlights.length, 0);
  await assert.rejects(mediaService.getAccessible(x, s.media_id));
  await assert.rejects(stories.createHighlight(b, { title: 'steal', story_ids: [s.id] }));
  const arch = await stories.archive(a);
  assert.equal(arch.stories.length, 1);
  const up = await stories.updateHighlight(a, h.id, { title: 'Summer' });
  assert.equal(up.title, 'Summer');
  await stories.deleteHighlight(a, h.id);
  assert.equal((await stories.listHighlights(b, a)).highlights.length, 0);
});
