'use strict';

/** Admin rights, restrictions, admin log, @all, welcome, info, private reply, drafts, directory,
 *  protected content, discussion group, stats, reactions, post queue. WARNING: wipes the test database. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const auth = require('../src/services/auth.service');
const chats = require('../src/services/chat.service');
const messages = require('../src/services/message.service');
const settings = require('../src/services/settings.service');

let n = 0;
async function user(name = 'T') {
  rateLimit.reset();
  n += 1;
  const phone = `+92388${String(1000000 + n)}`;
  const r = await auth.requestOtp(phone, '10.7.0.1');
  const t = await auth.verifyOtp(phone, r.dev_code, { name }, '10.7.0.1');
  await db.query("UPDATE users SET first_name = $2, created_at = now() - interval '3 days' WHERE id = $1", [t.user.id, name]);
  return t.user.id;
}
const mine = async (u, id) => (await chats.listChats(u)).find((c) => c.id === id);

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
});
test.after(() => db.close());

test('admin rights, restrictions, admin log, @all, welcome, message info', async () => {
  const owner = await user('Owner');
  const adm = await user('Adm');
  const m1 = await user('Mem');
  const m2 = await user('Mem2');
  const g = await chats.createGroup(owner, { title: 'G', member_ids: [adm, m1] });
  const gid = g.chat ? g.chat.id : g.id;
  // limited admin: may pin, may not remove members or change info
  await chats.setMemberRole(owner, gid, adm, 'admin', { rights: { ban_users: false, change_info: false }, title: 'Moderator' });
  const members = await chats.getMembers(owner, gid);
  const a = members.find((x) => x.user.id === adm);
  assert.equal(a.title, 'Moderator');
  assert.equal(a.rights.ban_users, false);
  assert.equal(a.rights.pin_messages, true);
  await assert.rejects(chats.removeMember(adm, gid, m1), (e) => e.code === 'no_right');
  await assert.rejects(chats.updateGroup(adm, gid, { title: 'X' }), (e) => e.code === 'no_right');
  assert.equal((await mine(adm, gid)).my_rights.ban_users, false);

  // welcome text for new members
  await chats.updateGroup(owner, gid, { welcome_text: 'Read the rules please', rules: '1. Be nice' });
  await chats.addMembers(owner, gid, [m2]);
  const list = await messages.listMessages(owner, gid, {});
  assert.ok(list.messages.some((x) => x.type === 'system' && x.meta && x.meta.event === 'welcome' && x.meta.text === 'Read the rules please'));
  assert.equal((await mine(m2, gid)).rules, '1. Be nice');

  // restrict a member for an hour
  await chats.restrictMember(owner, gid, m1, 60);
  await assert.rejects(messages.sendMessage(m1, gid, { text: 'hi' }), (e) => e.code === 'restricted');
  await chats.restrictMember(owner, gid, m1, 0);
  await messages.sendMessage(m1, gid, { text: 'hi again' });

  // new members: no links for 24 h
  await chats.updateGroup(owner, gid, { new_member_limits: true });
  await assert.rejects(messages.sendMessage(m2, gid, { text: 'buy at https://spam.example' }), (e) => e.code === 'new_member_limits');
  await messages.sendMessage(m2, gid, { text: 'just text' });

  // @all by an admin mentions everyone; by a member it does nothing
  const all = await messages.sendMessage(owner, gid, { text: 'meeting now @all' });
  assert.deepEqual([...all.mentions].sort(), [adm, m1, m2].sort());
  const notAll = await messages.sendMessage(m1, gid, { text: 'hey @all' });
  assert.equal(notAll.mentions.length, 0);

  // message info: who read it
  await messages.markRead(adm, gid, all.id);
  const info = await messages.messageInfo(owner, all.id);
  // adm read it; m1 wrote after it (sending marks the chat read)
  assert.deepEqual(info.read.map((u) => u.id).sort(), [adm, m1].sort());
  assert.deepEqual(info.waiting.map((u) => u.id), [m2]);
  await assert.rejects(messages.messageInfo(adm, all.id));

  // admin log
  await messages.deleteMessages(owner, gid, { message_ids: [notAll.id], for_everyone: true });
  const log = await chats.listEvents(owner, gid);
  const actions = log.map((e) => e.action);
  for (const want of ['admin_set', 'member_added', 'member_restricted', 'member_unrestricted', 'message_deleted', 'settings_changed']) {
    assert.ok(actions.includes(want), `log has ${want}`);
  }
  await assert.rejects(chats.listEvents(m1, gid));
});

test('private reply, drafts, reactions setting, protected content', async () => {
  const a = await user('A');
  const b = await user('B');
  const g = await chats.createGroup(a, { title: 'Club', member_ids: [b] });
  const gid = g.chat ? g.chat.id : g.id;
  const gm = await messages.sendMessage(b, gid, { text: 'Who has the notes?' });
  const pc = await chats.getOrCreatePrivate(a, b);
  const reply = await messages.sendMessage(a, pc.id, { text: 'I do', quote_message_id: gm.id });
  assert.equal(reply.meta.quote.text, 'Who has the notes?');
  assert.equal(reply.meta.quote.chat_title, 'Club');

  await chats.setDraft(a, gid, 'half written');
  assert.equal((await mine(a, gid)).draft, 'half written');
  assert.equal((await mine(b, gid)).draft, '', 'drafts are personal');

  await chats.updateGroup(a, gid, { allowed_reactions: ['👍'] });
  await messages.react(b, gm.id, '👍');
  await assert.rejects(messages.react(b, gm.id, '🔥'), (e) => e.code === 'reaction_not_allowed');

  await chats.updateGroup(a, gid, { protected_content: true });
  await assert.rejects(messages.forwardMessages(b, { from_chat_id: gid, message_ids: [gm.id], to_chat_ids: [pc.id] }), (e) => e.code === 'protected_content');
});

test('channels: directory, discussion group, stats, post queue', async () => {
  const owner = await user('Boss');
  const writer = await user('Writer');
  const reader = await user('Reader');
  const ch = await chats.createChannel(owner, { title: 'Tech Daily', username: 'techdaily_test' });
  const cid = ch.id;
  await chats.updateGroup(owner, cid, { category: 'tech' });
  await chats.joinPublic(reader, cid);
  const dir = await chats.directory(reader, { category: 'tech' });
  assert.ok(dir.channels.some((c) => c.id === cid));
  assert.ok((await chats.directory(reader, { q: 'Tech Dai' })).channels.some((c) => c.id === cid));

  // discussion group: posts are copied there
  const grp = await chats.createGroup(owner, { title: 'Tech talk', member_ids: [reader] });
  const gid = grp.chat ? grp.chat.id : grp.id;
  await chats.updateGroup(owner, cid, { linked_chat_id: gid });
  const post = await messages.sendMessage(owner, cid, { text: 'New phone launched' });
  await new Promise((r) => setTimeout(r, 200));
  const inGroup = (await messages.listMessages(reader, gid, {})).messages.find((m) => m.meta && m.meta.channel_post);
  assert.ok(inGroup, 'post copied to the discussion group');
  assert.equal(inGroup.meta.channel_post.message_id, post.id);
  assert.equal((await mine(owner, cid)).linked_chat.id, gid);

  // a writer admin without "publish" right → the post waits for approval
  await chats.joinPublic(writer, cid);
  await chats.setMemberRole(owner, cid, writer, 'admin', { rights: { post_messages: false } });
  const q = await messages.sendMessage(writer, cid, { text: 'Draft review please' });
  assert.ok(q.queued && q.queued.id);
  assert.equal((await mine(owner, cid)).queue_count, 1);
  const queue = await messages.listQueue(owner, cid);
  assert.equal(queue.posts[0].text, 'Draft review please');
  await assert.rejects(messages.publishQueued(writer, cid, q.queued.id), (e) => e.code === 'no_right');
  const published = await messages.publishQueued(owner, cid, q.queued.id);
  assert.equal(published.text, 'Draft review please');
  assert.equal((await messages.listQueue(owner, cid)).posts.length, 0);
  // …and can't get around the review: no scheduling, no forwarding in, no editing
  await assert.rejects(messages.sendMessage(writer, cid, { text: 'sneaky', schedule_at: new Date(Date.now() + 3600e3).toISOString() }), (e) => e.code === 'no_right');
  const wpc = await chats.getOrCreatePrivate(writer, owner);
  const wm = await messages.sendMessage(writer, wpc.id, { text: 'to forward' });
  await assert.rejects(messages.forwardMessages(writer, { from_chat_id: wpc.id, message_ids: [wm.id], to_chat_ids: [cid] }), (e) => e.code === 'no_right');
  await assert.rejects(messages.editMessage(writer, published.id, { text: 'changed after approval' }), (e) => e.code === 'no_right');
  // drafts on purpose
  const d = await messages.sendMessage(owner, cid, { text: 'later', as_draft: true });
  await messages.deleteQueued(owner, cid, d.queued.id);

  // stats: shares are counted
  const pc = await chats.getOrCreatePrivate(reader, owner);
  await messages.forwardMessages(reader, { from_chat_id: cid, message_ids: [post.id], to_chat_ids: [pc.id] });
  const st = await chats.chatStats(owner, cid);
  assert.equal(Number(st.shares_30d), 1);
  assert.equal(st.top_posts.find((p) => p.id === post.id).shares, 1);
});
