'use strict';

const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const v = require('../utils/validate');
const { randomToken } = require('../utils/crypto');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const lazyMessages = () => require('./message.service'); // circular import guard

const ADMIN_ROLES = ['owner', 'admin'];
const MULTI_TYPES = ['group', 'channel'];
const MAX_PINNED = 5;

const isMulti = (chat) => MULTI_TYPES.includes(chat.type);

// ------------------------------------------------------------------ helpers
async function requireMember(chatIdRaw, userId) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const row = await db.one(
    `SELECT c.*, cm.role AS my_role, cm.cleared_before_id, cm.last_read_message_id,
            cm.admin_rights AS my_rights, cm.restricted_until AS my_restricted_until, cm.joined_at AS my_joined_at
     FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2
     WHERE c.id = $1`,
    [chatId, userId],
  );
  if (!row) throw notFound('chat_not_found', 'Chat not found');
  return row;
}

function requireGroupAdmin(chat) {
  if (!isMulti(chat)) throw badRequest('not_a_group', 'This action is only for groups and channels');
  if (!ADMIN_ROLES.includes(chat.my_role)) throw forbidden('not_admin', 'Only admins can do this');
}

/** What an admin may do (the owner can do everything). Missing = allowed, so older admins keep their powers. */
const RIGHTS = ['change_info', 'delete_messages', 'ban_users', 'invite_users', 'pin_messages', 'post_messages'];
const RIGHT_LABELS = {
  change_info: 'change the info',
  delete_messages: 'delete messages',
  ban_users: 'remove or restrict members',
  invite_users: 'add members and manage invite links',
  pin_messages: 'pin messages',
  post_messages: 'publish posts',
};

function rightsOf(role, raw) {
  const out = {};
  for (const r of RIGHTS) out[r] = role === 'owner' || (role === 'admin' && !(raw && raw[r] === false));
  return out;
}

function hasRight(chat, right) {
  return rightsOf(chat.my_role, chat.my_rights)[right];
}

function requireRight(chat, right) {
  requireGroupAdmin(chat);
  if (!hasRight(chat, right)) throw forbidden('no_right', `You don't have permission to ${RIGHT_LABELS[right] || 'do this'}`);
}

/** Admin log ("Recent actions"). Never fails the action itself. */
async function logEvent(chatId, actorId, action, targetId = null, details = null) {
  try {
    await db.query('INSERT INTO chat_events (chat_id, actor_id, target_id, action, details) VALUES ($1, $2, $3, $4, $5)', [
      chatId, actorId || null, targetId || null, action, details ? JSON.stringify(details) : null,
    ]);
  } catch (_) {
    /* ignore */
  }
}

/** "👋 Welcome …" in groups that have a welcome text. */
async function sendWelcome(chat, userIds) {
  if (chat.type !== 'group' || !chat.welcome_text || !userIds.length) return;
  await lazyMessages().createSystemMessage(chat.id, userIds[0], { event: 'welcome', user_ids: userIds.slice(0, 50), text: chat.welcome_text });
}

async function memberIds(chatId) {
  const rows = await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId]);
  return rows.map((r) => r.user_id);
}

/** The other member of a private chat (null for "My Notes"). */
async function privatePeerId(chatId, userId) {
  const r = await db.one('SELECT user_id FROM chat_members WHERE chat_id = $1 AND user_id <> $2 LIMIT 1', [chatId, userId]);
  return r ? r.user_id : null;
}

async function emitUpdated(chatId, extraUserIds = []) {
  const ids = await memberIds(chatId);
  bus.emit('chat:updated', { chatId, memberIds: [...new Set([...ids, ...extraUserIds])] });
}

const CHAT_ROWS_SQL = `
SELECT c.id, c.type, c.title, c.description, c.avatar_media_id, c.invite_code, c.is_suspended,
       c.created_by, c.created_at, c.last_message_at, c.username, c.is_public, c.signatures, c.is_verified,
       c.slow_mode_sec, c.join_approval, c.comments_enabled, c.is_forum, c.disappear_after_sec,
       c.welcome_text, c.rules, c.new_member_limits, c.protected_content, c.allowed_reactions, c.category, c.linked_chat_id,
       cm.admin_rights AS my_rights, cm.admin_title AS my_title, cm.restricted_until AS my_restricted_until, cm.draft, cm.draft_at,
       (SELECT l.title FROM chats l WHERE l.id = c.linked_chat_id) AS linked_title,
       (SELECT ch.id FROM chats ch WHERE ch.linked_chat_id = c.id LIMIT 1) AS linked_channel_id,
       CASE WHEN c.type = 'channel' AND cm.role IN ('owner', 'admin') THEN (SELECT count(*) FROM post_queue q WHERE q.chat_id = c.id) ELSE 0 END AS queue_count,
       cm.role AS my_role, cm.last_read_message_id, cm.muted_until, cm.is_pinned, cm.is_archived, cm.marked_unread, cm.is_request, cm.is_locked,
       (SELECT count(*) FROM message_mentions mm JOIN messages mmsg ON mmsg.id = mm.message_id
          WHERE mm.user_id = $1 AND mm.chat_id = c.id AND mmsg.deleted_at IS NULL
            AND mm.message_id > GREATEST(cm.last_read_message_id, cm.cleared_before_id)) AS unread_mentions,
       (SELECT p.message_id FROM pinned_messages p JOIN messages pm ON pm.id = p.message_id AND pm.deleted_at IS NULL
          WHERE p.chat_id = c.id AND p.message_id > cm.cleared_before_id ORDER BY p.pinned_at DESC LIMIT 1) AS pinned_message_id,
       (SELECT count(*) FROM pinned_messages p WHERE p.chat_id = c.id) AS pinned_count,
       CASE WHEN cm.role IN ('owner', 'admin') THEN (SELECT count(*) FROM chat_join_requests jr WHERE jr.chat_id = c.id) ELSE 0 END AS pending_requests,
       (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id) AS member_count,
       (SELECT count(*) FROM messages m
          WHERE m.chat_id = c.id
            AND m.id > GREATEST(cm.last_read_message_id, cm.cleared_before_id)
            AND m.deleted_at IS NULL
            AND m.thread_id IS NULL
            AND m.sender_id IS DISTINCT FROM $1
            AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $1 AND h.message_id = m.id)
       ) AS unread_count,
       COALESCE((SELECT max(o.last_read_message_id) FROM chat_members o
                 WHERE o.chat_id = c.id AND o.user_id <> $1), 0) AS read_up_to,
       COALESCE((SELECT max(o.last_delivered_message_id) FROM chat_members o
                 WHERE o.chat_id = c.id AND o.user_id <> $1), 0) AS delivered_up_to,
       (SELECT o.user_id FROM chat_members o WHERE o.chat_id = c.id AND o.user_id <> $1 LIMIT 1) AS peer_id,
       lm.id AS last_visible_message_id
FROM chat_members cm
JOIN chats c ON c.id = cm.chat_id
LEFT JOIN LATERAL (
  SELECT m.id FROM messages m
  WHERE m.chat_id = c.id AND m.id > cm.cleared_before_id AND m.deleted_at IS NULL AND m.thread_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $1 AND h.message_id = m.id)
  ORDER BY m.id DESC LIMIT 1
) lm ON TRUE
WHERE cm.user_id = $1`;

async function serializeChats(userId, rows) {
  if (rows.length === 0) return [];
  const peers = await userService.getUsersMap(
    userId,
    rows.filter((r) => r.type === 'private' && r.peer_id).map((r) => r.peer_id),
  );
  const lastMsgs = await lazyMessages().serializeByIds(
    userId,
    [...new Set([...rows.map((r) => r.last_visible_message_id), ...rows.map((r) => r.pinned_message_id)].filter(Boolean))],
  );
  const botIds = [...peers.values()].filter((u) => u && u.is_bot).map((u) => u.id);
  const botRows = botIds.length
    ? await db.many('SELECT user_id, about, commands, menu_url FROM bots WHERE user_id = ANY($1::bigint[]) AND status = $2', [botIds, 'active'])
    : [];
  const botInfo = new Map(botRows.map((b) => [b.user_id, { about: b.about, commands: b.commands || [], menu_url: b.menu_url || null }]));
  const now = new Date();
  return rows.map((r) => {
    const isPrivate = r.type === 'private';
    const peer = isPrivate && r.peer_id ? peers.get(r.peer_id) || null : null;
    const isSaved = isPrivate && !r.peer_id;
    let title = r.title;
    if (isPrivate) title = isSaved ? 'My Notes' : userService.displayName(peer && { ...peer, status: peer.deleted ? 'deleted' : 'active' });
    return {
      id: r.id,
      type: r.type,
      title,
      description: r.description,
      avatar_url: isPrivate ? (peer ? peer.avatar_url : null) : userService.avatarUrl(r.avatar_media_id),
      peer,
      is_saved_messages: isSaved,
      member_count: r.member_count,
      my_role: r.my_role,
      invite_code: isMulti(r) && ADMIN_ROLES.includes(r.my_role) ? r.invite_code : null,
      username: isPrivate ? null : r.username,
      is_public: r.is_public,
      signatures: r.signatures,
      is_verified: isPrivate ? !!(peer && peer.is_verified) : r.is_verified,
      can_post: !r.is_suspended && (r.type !== 'channel' || ADMIN_ROLES.includes(r.my_role)),
      my_rights: isMulti(r) ? rightsOf(r.my_role, r.my_rights) : null,
      my_title: r.my_title || null,
      restricted_until: r.my_restricted_until && new Date(r.my_restricted_until) > now ? new Date(r.my_restricted_until).toISOString() : null,
      welcome_text: r.welcome_text || '',
      rules: r.rules || '',
      new_member_limits: !!r.new_member_limits,
      protected_content: !!r.protected_content,
      allowed_reactions: r.allowed_reactions || null,
      category: r.category || null,
      linked_chat: r.linked_chat_id ? { id: r.linked_chat_id, title: r.linked_title } : null,
      linked_channel_id: r.linked_channel_id || null,
      queue_count: Number(r.queue_count || 0),
      draft: r.draft || '',
      draft_at: r.draft_at ? new Date(r.draft_at).toISOString() : null,
      slow_mode_sec: r.slow_mode_sec,
      disappear_after_sec: r.disappear_after_sec || 0,
      join_approval: r.join_approval,
      comments_enabled: r.type === 'channel' && !!r.comments_enabled,
      is_forum: r.type === 'group' && !!r.is_forum,
      is_bot: isPrivate && !!(peer && peer.is_bot),
      bot: isPrivate && peer && peer.is_bot ? botInfo.get(peer.id) || null : null,
      pending_requests: r.pending_requests,
      marked_unread: r.marked_unread,
      unread_mentions: r.unread_mentions,
      pinned_message: r.pinned_message_id ? lastMsgs.get(r.pinned_message_id) || null : null,
      pinned_count: r.pinned_count,
      is_suspended: r.is_suspended,
      unread_count: r.unread_count,
      read_up_to: r.read_up_to,
      delivered_up_to: Math.max(r.delivered_up_to, r.read_up_to),
      muted_until: r.muted_until ? new Date(r.muted_until).toISOString() : null,
      is_muted: !!r.muted_until && new Date(r.muted_until) > now,
      is_pinned: r.is_pinned,
      is_archived: r.is_archived,
      is_request: !!r.is_request,
      is_locked: !!r.is_locked,
      last_message: r.last_visible_message_id ? lastMsgs.get(r.last_visible_message_id) || null : null,
      last_message_at: r.last_message_at ? new Date(r.last_message_at).toISOString() : null,
      created_at: new Date(r.created_at).toISOString(),
    };
  });
}

async function listChats(userId, { archived = false } = {}) {
  const rows = await db.many(
    `${CHAT_ROWS_SQL} AND cm.is_hidden = FALSE AND cm.is_archived = $2
     ORDER BY cm.is_pinned DESC, COALESCE(c.last_message_at, c.created_at) DESC
     LIMIT 500`,
    [userId, !!archived],
  );
  return serializeChats(userId, rows);
}

async function getChatsByIds(userId, ids) {
  if (!ids.length) return [];
  const rows = await db.many(`${CHAT_ROWS_SQL} AND c.id = ANY($2::bigint[])`, [userId, ids]);
  return serializeChats(userId, rows);
}

async function getChat(userId, chatIdRaw) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const rows = await db.many(`${CHAT_ROWS_SQL} AND c.id = $2`, [userId, chatId]);
  if (rows.length === 0) throw notFound('chat_not_found', 'Chat not found');
  return (await serializeChats(userId, rows))[0];
}

// ------------------------------------------------------------------ private chats
async function getOrCreatePrivate(userId, peerIdRaw) {
  const peerId = v.id(peerIdRaw, 'user_id');
  if (peerId !== userId) {
    const peer = await db.one('SELECT id, status FROM users WHERE id = $1', [peerId]);
    if (!peer || peer.status === 'deleted') throw notFound('user_not_found', 'User not found');
  }
  const key = `${Math.min(userId, peerId)}:${Math.max(userId, peerId)}`;
  const chatId = await db.tx(async (c) => {
    let r = await c.query(
      `INSERT INTO chats (type, private_key, created_by) VALUES ('private', $1, $2)
       ON CONFLICT (private_key) DO NOTHING RETURNING id`,
      [key, userId],
    );
    let id = r.rows[0] && r.rows[0].id;
    if (!id) {
      r = await c.query('SELECT id FROM chats WHERE private_key = $1', [key]);
      id = r.rows[0].id;
    }
    // The peer only sees the chat once a message arrives (is_hidden = TRUE).
    await c.query(
      `INSERT INTO chat_members (chat_id, user_id, is_hidden) VALUES ($1, $2, FALSE)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET is_hidden = FALSE`,
      [id, userId],
    );
    if (peerId !== userId) {
      // Message requests: someone who isn't in the peer's contacts lands in their "Requests"
      // (no notification) until the peer replies, accepts or adds them as a contact.
      await c.query(
        `INSERT INTO chat_members (chat_id, user_id, is_hidden, is_request)
         SELECT $1, $2, TRUE,
                u.message_requests AND NOT u.is_bot
                AND NOT EXISTS (SELECT 1 FROM contacts ct WHERE ct.owner_id = $2 AND ct.contact_id = $3)
                AND NOT EXISTS (SELECT 1 FROM users me WHERE me.id = $3 AND me.is_bot)
         FROM users u WHERE u.id = $2
         ON CONFLICT DO NOTHING`,
        [id, peerId, userId],
      );
    }
    return id;
  });
  return getChat(userId, chatId);
}

/** Accepts a message request (the chat moves to the normal list, notifications start). */
async function acceptRequest(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  await db.query('UPDATE chat_members SET is_request = FALSE WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  bus.emit('chat:updated', { chatId: chat.id, memberIds: [userId] });
  return getChat(userId, chat.id);
}

/** Deletes a message request; optionally blocks (and reports) the sender. */
async function declineRequest(userId, chatIdRaw, body = {}) {
  const chat = await requireMember(chatIdRaw, userId);
  if (chat.type !== 'private') throw badRequest('invalid_input', 'Only private chats can be requests');
  const peerId = await privatePeerId(chat.id, userId);
  await db.query(
    // stays a request: if they write again it comes back to Requests (silently), not to the chat list
    `UPDATE chat_members SET is_request = TRUE, is_hidden = TRUE,
       cleared_before_id = COALESCE((SELECT last_message_id FROM chats WHERE id = $1), cleared_before_id)
     WHERE chat_id = $1 AND user_id = $2`,
    [chat.id, userId],
  );
  if (peerId && body.block) await userService.block(userId, peerId).catch(() => null);
  if (peerId && body.report) {
    await require('./report.service') // lazy: avoids a require cycle
      .createReport(userId, { target_type: 'user', target_id: peerId, reason: 'spam', details: 'Reported from message requests' })
      .catch(() => null);
  }
  bus.emit('chat:removed', { chatId: chat.id, userIds: [userId] });
  return { ok: true };
}

/** Called when [ownerId] adds people as contacts: their pending requests become normal chats. */
async function clearRequestsFrom(ownerId, contactIds) {
  if (!contactIds.length) return;
  await db.query(
    `UPDATE chat_members cm SET is_request = FALSE
     FROM chats c
     WHERE cm.chat_id = c.id AND c.type = 'private' AND cm.user_id = $1 AND cm.is_request
       AND EXISTS (SELECT 1 FROM chat_members o WHERE o.chat_id = c.id AND o.user_id = ANY($2::bigint[]))`,
    [ownerId, contactIds],
  );
}

// ------------------------------------------------------------------ groups
/**
 * Splits candidate user ids into those `adderId` may add to a group, and skipped ones
 * (deleted/banned users, blocks, "who can add me to groups" privacy).
 */
async function filterAddable(adderId, ids) {
  const result = { ok: [], skipped: [] };
  if (ids.length === 0) return result;
  const users = await db.many('SELECT * FROM users WHERE id = ANY($1::bigint[])', [ids]);
  const byId = new Map(users.map((u) => [u.id, u]));
  const rel = await userService.relations(adderId, ids);
  for (const id of ids) {
    const u = byId.get(id);
    if (!u || u.status === 'deleted' || userService.isBanned(u)) {
      result.skipped.push({ user_id: id, reason: 'not_found' });
    } else if (rel.blockedMe.has(id) || rel.iBlocked.has(id)) {
      result.skipped.push({ user_id: id, reason: 'privacy' });
    } else if (u.privacy_group_add === 'nobody' || (u.privacy_group_add === 'contacts' && !rel.theyHaveMe.has(id))) {
      result.skipped.push({ user_id: id, reason: 'privacy' });
    } else {
      result.ok.push(id);
    }
  }
  return result;
}

async function createGroup(ownerId, body) {
  const title = v.str(body.title, { field: 'title', min: 1, max: 128, required: true });
  const description = v.str(body.description, { field: 'description', max: 255 }) || '';
  const candidates = v.idList(body.member_ids || [], 'member_ids', 200).filter((id) => id !== ownerId);
  const { ok, skipped } = await filterAddable(ownerId, candidates);
  const max = await settings.get('max_group_members');
  if (ok.length + 1 > max) throw badRequest('group_full', `A group can have at most ${max} members`);

  const chatId = await db.tx(async (c) => {
    const r = await c.query(
      `INSERT INTO chats (type, title, description, created_by, invite_code)
       VALUES ('group', $1, $2, $3, $4) RETURNING id`,
      [title, description, ownerId, randomToken(12)],
    );
    const id = r.rows[0].id;
    await c.query(`INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'owner')`, [id, ownerId]);
    if (ok.length) {
      await c.query(
        `INSERT INTO chat_members (chat_id, user_id, role) SELECT $1, x, 'member' FROM unnest($2::bigint[]) AS x`,
        [id, ok],
      );
    }
    return id;
  });
  await lazyMessages().createSystemMessage(chatId, ownerId, { event: 'group_created', title });
  await emitUpdated(chatId);
  return { chat: await getChat(ownerId, chatId), skipped };
}

/** Disappearing messages: new messages delete themselves after the chosen time (0 = off). */
const DISAPPEAR_OPTIONS = [0, 3600, 86400, 604800, 7776000]; // off, 1 h, 24 h, 7 days, 90 days
async function setDisappearing(userId, chatIdRaw, secondsRaw) {
  await settings.requireFeature('feature_disappearing', 'Disappearing messages');
  const chat = await requireMember(chatIdRaw, userId);
  const seconds = Number(secondsRaw);
  if (!DISAPPEAR_OPTIONS.includes(seconds)) throw badRequest('invalid_input', 'Choose off, 1 hour, 24 hours, 7 days or 90 days');
  if (chat.type !== 'private') requireRight(chat, 'change_info');
  if ((chat.disappear_after_sec || 0) === seconds) return getChat(userId, chat.id);
  await db.query('UPDATE chats SET disappear_after_sec = $2, updated_at = now() WHERE id = $1', [chat.id, seconds]);
  await lazyMessages().createSystemMessage(chat.id, userId, { event: 'disappearing_changed', seconds });
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

const CATEGORIES = ['news', 'tech', 'sports', 'entertainment', 'education', 'business', 'religion', 'lifestyle', 'gaming', 'other'];

async function updateGroup(userId, chatIdRaw, body) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'change_info');
  await updateExtras(userId, chat, body);
  const title = v.str(body.title, { field: 'title', min: 1, max: 128 });
  const description = v.str(body.description, { field: 'description', max: 255 });
  const signatures = body.signatures === undefined ? null : v.bool(body.signatures, 'signatures');
  let slow = null;
  if (body.slow_mode_sec !== undefined) {
    slow = Number(body.slow_mode_sec);
    if (!lazyMessages().SLOW_MODE_VALUES.includes(slow)) throw badRequest('invalid_input', 'Invalid slow mode interval');
    if (chat.type !== 'group') throw badRequest('invalid_input', 'Slow mode is for groups');
  }
  const approval = body.join_approval === undefined ? null : v.bool(body.join_approval, 'join_approval');
  const comments = body.comments_enabled === undefined ? null : v.bool(body.comments_enabled, 'comments_enabled');
  if (comments) await settings.requireFeature('feature_channel_comments', 'Channel comments');
  if (comments !== null && chat.type !== 'channel') throw badRequest('invalid_input', 'Comments are for channels');
  const forum = body.is_forum === undefined ? null : v.bool(body.is_forum, 'is_forum');
  if (forum) await settings.requireFeature('feature_topics', 'Topics');
  if (forum !== null && chat.type !== 'group') throw badRequest('invalid_input', 'Topics are for groups');
  await db.query(
    `UPDATE chats SET title = COALESCE($2, title), description = COALESCE($3, description),
       signatures = COALESCE($4, signatures), slow_mode_sec = COALESCE($5, slow_mode_sec),
       join_approval = COALESCE($6, join_approval), comments_enabled = COALESCE($7, comments_enabled),
       is_forum = COALESCE($8, is_forum), updated_at = now()
     WHERE id = $1`,
    [chat.id, title === undefined ? null : title, description === undefined ? null : description, signatures, slow, approval, comments, forum],
  );
  if (approval === false) await db.query('DELETE FROM chat_join_requests WHERE chat_id = $1', [chat.id]);
  const changed = Object.keys(body).filter((k) => !['welcome_text', 'rules', 'new_member_limits', 'protected_content', 'allowed_reactions', 'category', 'linked_chat_id'].includes(k));
  if (changed.length) await logEvent(chat.id, userId, 'info_changed', null, { fields: changed, title: title || undefined });
  if (title !== undefined && title !== chat.title) {
    await lazyMessages().createSystemMessage(chat.id, userId, { event: 'title_changed', title });
  }
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

/** Welcome text, rules, member limits, protected content, reactions, category, discussion group. */
async function updateExtras(userId, chat, body) {
  const sets = [];
  const params = [chat.id];
  const set = (col, val) => {
    params.push(val);
    sets.push(`${col} = $${params.length}`);
  };
  if (body.welcome_text !== undefined) {
    if (chat.type !== 'group') throw badRequest('invalid_input', 'Welcome messages are for groups');
    set('welcome_text', v.str(body.welcome_text, { field: 'welcome_text', max: 500 }) || null);
  }
  if (body.rules !== undefined) set('rules', v.str(body.rules, { field: 'rules', max: 2000 }) || null);
  if (body.new_member_limits !== undefined) {
    if (chat.type !== 'group') throw badRequest('invalid_input', 'This is for groups');
    set('new_member_limits', v.bool(body.new_member_limits, 'new_member_limits'));
  }
  if (body.protected_content !== undefined) set('protected_content', v.bool(body.protected_content, 'protected_content'));
  if (body.allowed_reactions !== undefined) {
    let list = null;
    if (body.allowed_reactions !== null) {
      if (!Array.isArray(body.allowed_reactions)) throw badRequest('invalid_input', 'allowed_reactions must be a list or null');
      const all = lazyMessages().REACTIONS;
      list = [...new Set(body.allowed_reactions.map(String))].filter((e) => all.includes(e));
    }
    set('allowed_reactions', list === null ? null : JSON.stringify(list));
  }
  if (body.category !== undefined) {
    if (chat.type !== 'channel') throw badRequest('invalid_input', 'Categories are for channels');
    set('category', body.category === null ? null : v.oneOf(body.category, CATEGORIES, 'category'));
  }
  if (body.linked_chat_id !== undefined) {
    if (chat.type !== 'channel') throw badRequest('invalid_input', 'Only channels have a discussion group');
    let linked = null;
    if (body.linked_chat_id !== null) {
      const g = await requireMember(body.linked_chat_id, userId);
      if (g.type !== 'group') throw badRequest('invalid_input', 'The discussion must be a group');
      if (!ADMIN_ROLES.includes(g.my_role)) throw forbidden('not_admin', 'You must be an admin of that group');
      linked = g.id;
    }
    set('linked_chat_id', linked);
  }
  if (!sets.length) return;
  await db.query(`UPDATE chats SET ${sets.join(', ')}, updated_at = now() WHERE id = $1`, params);
  await logEvent(chat.id, userId, 'settings_changed', null, {
    fields: Object.keys(body).filter((k) => ['welcome_text', 'rules', 'new_member_limits', 'protected_content', 'allowed_reactions', 'category', 'linked_chat_id'].includes(k)),
  });
}

async function setGroupAvatar(userId, chatIdRaw, mediaIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'change_info');
  let mediaId = null;
  if (mediaIdRaw !== null && mediaIdRaw !== undefined) {
    const media = await db.one('SELECT * FROM media WHERE id = $1', [v.id(mediaIdRaw, 'media_id')]);
    if (!media || media.uploader_id !== userId) throw notFound('media_not_found', 'Media not found');
    if (!['avatar', 'image'].includes(media.kind)) throw badRequest('invalid_media', 'Group photo must be an image');
    await db.query('UPDATE media SET is_public = TRUE WHERE id = $1', [media.id]);
    mediaId = media.id;
  }
  await db.query('UPDATE chats SET avatar_media_id = $2, updated_at = now() WHERE id = $1', [chat.id, mediaId]);
  await logEvent(chat.id, userId, mediaId ? 'photo_changed' : 'photo_removed');
  await lazyMessages().createSystemMessage(chat.id, userId, { event: mediaId ? 'photo_changed' : 'photo_removed' });
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

async function addMembers(userId, chatIdRaw, userIdsRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  if (chat.is_suspended) throw forbidden('chat_suspended', 'This group has been suspended');
  const existing = new Set(await memberIds(chat.id));
  const candidates = v.idList(userIdsRaw, 'user_ids', 200).filter((id) => !existing.has(id));
  const { ok, skipped } = await filterAddable(userId, candidates);
  const max = await settings.get('max_group_members');
  if (chat.type === 'group' && existing.size + ok.length > max) {
    throw badRequest('group_full', `A group can have at most ${max} members`);
  }
  if (ok.length) {
    await db.query(
      `INSERT INTO chat_members (chat_id, user_id, role) SELECT $1, x, 'member' FROM unnest($2::bigint[]) AS x
       ON CONFLICT DO NOTHING`,
      [chat.id, ok],
    );
    if (chat.type === 'group') {
      await lazyMessages().createSystemMessage(chat.id, userId, { event: 'members_added', user_ids: ok });
    }
    for (const id of ok) await logEvent(chat.id, userId, 'member_added', id);
    await sendWelcome(chat, ok);
    await emitUpdated(chat.id);
  }
  return { added: ok, skipped };
}

/**
 * Removes a user from a group (leave / kick / account deletion).
 * Transfers ownership if the owner leaves; deletes the group if nobody is left.
 */
async function removeUserFromGroup(chatId, userId, { by = null, reason = 'left' } = {}) {
  const outcome = await db.tx(async (c) => {
    const locked = await c.query('SELECT id, type FROM chats WHERE id = $1 FOR UPDATE', [chatId]);
    const chatType = locked.rows[0] ? locked.rows[0].type : 'group';
    const del = await c.query('DELETE FROM chat_members WHERE chat_id = $1 AND user_id = $2 RETURNING role', [chatId, userId]);
    if (del.rows.length === 0) return { removed: false };
    const left = await c.query('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chatId]);
    if (left.rows[0].n === 0) {
      await c.query('DELETE FROM chats WHERE id = $1', [chatId]);
      return { removed: true, chatDeleted: true, chatType };
    }
    let newOwner = null;
    if (del.rows[0].role === 'owner') {
      const next = await c.query(
        `SELECT user_id FROM chat_members WHERE chat_id = $1
         ORDER BY (role = 'admin') DESC, joined_at ASC LIMIT 1`,
        [chatId],
      );
      newOwner = next.rows[0].user_id;
      await c.query(`UPDATE chat_members SET role = 'owner' WHERE chat_id = $1 AND user_id = $2`, [chatId, newOwner]);
    }
    return { removed: true, chatDeleted: false, newOwner, chatType };
  });
  if (!outcome.removed) return outcome;
  if (!outcome.chatDeleted) await logEvent(chatId, by || userId, reason === 'removed' ? 'member_removed' : 'member_left', userId);
  bus.emit('chat:removed', { chatId, userIds: [userId] });
  if (!outcome.chatDeleted) {
    const event = reason === 'removed' ? 'member_removed' : 'member_left';
    if (outcome.chatType === 'group') {
      await lazyMessages().createSystemMessage(chatId, by || userId, { event, user_id: userId });
    }
    if (outcome.newOwner) {
      await lazyMessages().createSystemMessage(chatId, outcome.newOwner, { event: 'owner_changed', user_id: outcome.newOwner });
    }
    await emitUpdated(chatId);
  }
  return outcome;
}

async function removeMember(actorId, chatIdRaw, targetIdRaw) {
  const chat = await requireMember(chatIdRaw, actorId);
  const targetId = v.id(targetIdRaw, 'user_id');
  if (targetId === actorId) return leaveChat(actorId, chat.id);
  requireRight(chat, 'ban_users');
  const target = await db.one('SELECT role FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, targetId]);
  if (!target) throw notFound('member_not_found', 'This user is not in the group');
  if (target.role === 'owner' || (target.role === 'admin' && chat.my_role !== 'owner')) {
    throw forbidden('not_allowed', 'You cannot remove this member');
  }
  await removeUserFromGroup(chat.id, targetId, { by: actorId, reason: 'removed' });
  return { ok: true };
}

async function leaveChat(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  if (isMulti(chat)) {
    await removeUserFromGroup(chat.id, userId, { reason: 'left' });
  } else {
    // "Delete chat" for a private chat: hide it and clear my history.
    await db.query(
      `UPDATE chat_members SET is_hidden = TRUE, is_pinned = FALSE,
         cleared_before_id = COALESCE((SELECT max(id) FROM messages WHERE chat_id = $1), 0)
       WHERE chat_id = $1 AND user_id = $2`,
      [chat.id, userId],
    );
    bus.emit('chat:removed', { chatId: chat.id, userIds: [userId] });
  }
  return { ok: true };
}

async function setMemberRole(actorId, chatIdRaw, targetIdRaw, role, extra = {}) {
  const chat = await requireMember(chatIdRaw, actorId);
  if (!isMulti(chat)) throw badRequest('not_a_group', 'This action is only for groups and channels');
  if (chat.my_role !== 'owner') throw forbidden('not_owner', 'Only the owner can change admins');
  const newRole = v.oneOf(role, ['admin', 'member'], 'role');
  const targetId = v.id(targetIdRaw, 'user_id');
  let rights = null;
  let title = null;
  if (newRole === 'admin') {
    if (extra.rights && typeof extra.rights === 'object') {
      rights = {};
      for (const k of RIGHTS) rights[k] = extra.rights[k] !== false;
    }
    title = v.str(extra.title, { field: 'title', max: 24 }) || null;
  }
  const r = await db.one(
    `UPDATE chat_members SET role = $3, admin_rights = $4, admin_title = $5
     WHERE chat_id = $1 AND user_id = $2 AND role <> 'owner' RETURNING user_id`,
    [chat.id, targetId, newRole, rights ? JSON.stringify(rights) : null, title],
  );
  if (!r) throw notFound('member_not_found', 'This user is not in the group');
  await logEvent(chat.id, actorId, newRole === 'admin' ? 'admin_set' : 'admin_removed', targetId, newRole === 'admin' ? { rights: rightsOf('admin', rights), title } : null);
  await emitUpdated(chat.id);
  return { ok: true };
}

/** Mutes a member for a while (minutes = 0 or null lifts it). Admins with "remove or restrict members". */
async function restrictMember(actorId, chatIdRaw, targetIdRaw, minutesRaw) {
  const chat = await requireMember(chatIdRaw, actorId);
  requireRight(chat, 'ban_users');
  if (chat.type !== 'group') throw badRequest('invalid_input', 'Restrictions are for groups');
  const targetId = v.id(targetIdRaw, 'user_id');
  const minutes = minutesRaw === null || minutesRaw === undefined ? 0 : Number(minutesRaw);
  if (![0, 60, 1440, 10080, 525600].includes(minutes)) throw badRequest('invalid_input', 'Mute for 1 hour, 1 day, 1 week or 1 year');
  const target = await db.one('SELECT role FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, targetId]);
  if (!target) throw notFound('member_not_found', 'This user is not in the group');
  if (target.role !== 'member') throw forbidden('not_allowed', 'Admins can’t be restricted');
  await db.query(
    `UPDATE chat_members SET restricted_until = CASE WHEN $3::int > 0 THEN now() + make_interval(mins => $3::int) END
     WHERE chat_id = $1 AND user_id = $2`,
    [chat.id, targetId, minutes],
  );
  await logEvent(chat.id, actorId, minutes ? 'member_restricted' : 'member_unrestricted', targetId, minutes ? { minutes } : null);
  bus.emit('chat:updated', { chatId: chat.id, memberIds: [targetId] });
  return { ok: true };
}

/** Admin log: who did what (newest first). */
async function listEvents(userId, chatIdRaw, query = {}) {
  const chat = await requireMember(chatIdRaw, userId);
  requireGroupAdmin(chat);
  const before = query.before ? v.id(query.before, 'before') : null;
  const rows = await db.many(
    `SELECT * FROM chat_events WHERE chat_id = $1 ${before ? 'AND id < $2' : ''} ORDER BY id DESC LIMIT 100`,
    before ? [chat.id, before] : [chat.id],
  );
  const users = await userService.getUsersMap(userId, [...new Set(rows.flatMap((r) => [r.actor_id, r.target_id]).filter(Boolean))]);
  return rows.map((r) => ({
    id: r.id,
    action: r.action,
    actor: r.actor_id ? users.get(r.actor_id) || null : null,
    target: r.target_id ? users.get(r.target_id) || null : null,
    details: r.details || null,
    created_at: new Date(r.created_at).toISOString(),
  }));
}

/** My draft in a chat (synced to my other devices). */
async function setDraft(userId, chatIdRaw, textRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  const text = String(textRaw || '').slice(0, 4096);
  await db.query('UPDATE chat_members SET draft = $3, draft_at = now() WHERE chat_id = $1 AND user_id = $2', [chat.id, userId, text || null]);
  bus.emit('draft:updated', { userId, chatId: chat.id, text, at: new Date().toISOString() });
  return { ok: true };
}

/** Public channels by category (or trending = most new subscribers this week). */
async function directory(userId, query = {}) {
  const category = query.category && query.category !== 'trending' ? v.oneOf(query.category, CATEGORIES, 'category') : null;
  const q = String(query.q || '').trim().slice(0, 64);
  const params = [userId];
  const where = [`c.type = 'channel'`, 'c.username IS NOT NULL', 'NOT c.is_suspended'];
  if (category) {
    params.push(category);
    where.push(`c.category = $${params.length}`);
  }
  if (q) {
    params.push(`%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    where.push(`(c.title ILIKE $${params.length} OR c.username ILIKE $${params.length} OR c.description ILIKE $${params.length})`);
  }
  const rows = await db.many(
    `SELECT c.*, (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id) AS n,
            (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id AND x.joined_at > now() - interval '7 days') AS n7,
            EXISTS (SELECT 1 FROM chat_members me WHERE me.chat_id = c.id AND me.user_id = $1) AS me
     FROM chats c WHERE ${where.join(' AND ')}
     ORDER BY ${query.category === 'trending' ? 'n7 DESC, n DESC' : 'c.is_verified DESC, n DESC'} LIMIT 60`,
    params,
  );
  return {
    categories: CATEGORIES,
    channels: rows.map((c) => ({ ...publicSummary(c, Number(c.n), c.me), id: c.id, category: c.category || null, new_this_week: Number(c.n7) })),
  };
}

async function getMembers(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  const adminsOnly = chat.type === 'channel' && !ADMIN_ROLES.includes(chat.my_role);
  const rows = await db.many(
    `SELECT user_id, role, joined_at, admin_rights, admin_title, restricted_until FROM chat_members WHERE chat_id = $1 ${adminsOnly ? "AND role <> 'member'" : ''}
     ORDER BY CASE role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, joined_at
     LIMIT 5000`,
    [chat.id],
  );
  const users = await userService.getUsersMap(userId, rows.map((r) => r.user_id));
  return rows
    .filter((r) => users.has(r.user_id))
    .map((r) => ({
      user: users.get(r.user_id),
      role: r.role,
      title: r.admin_title || null,
      rights: r.role === 'member' ? null : rightsOf(r.role, r.admin_rights),
      restricted_until: r.restricted_until && new Date(r.restricted_until) > new Date() ? new Date(r.restricted_until).toISOString() : null,
      joined_at: new Date(r.joined_at).toISOString(),
    }));
}

// ------------------------------------------------------------------ per-user chat settings
async function updateMySettings(userId, chatIdRaw, body) {
  const chat = await requireMember(chatIdRaw, userId);
  const sets = [];
  const params = [chat.id, userId];
  if (body.muted_until !== undefined) {
    let until = null;
    if (body.muted_until === 'forever') until = '2100-01-01T00:00:00Z';
    else if (body.muted_until !== null) {
      const d = new Date(body.muted_until);
      if (Number.isNaN(d.getTime())) throw badRequest('invalid_input', 'muted_until must be an ISO date, "forever" or null');
      until = d.toISOString();
    }
    params.push(until);
    sets.push(`muted_until = $${params.length}`);
  }
  if (body.is_pinned !== undefined) {
    const pin = v.bool(body.is_pinned, 'is_pinned');
    if (pin) {
      const n = await db.one(
        'SELECT count(*) AS n FROM chat_members WHERE user_id = $1 AND is_pinned AND chat_id <> $2',
        [userId, chat.id],
      );
      if (n.n >= MAX_PINNED) throw badRequest('too_many_pinned', `You can pin up to ${MAX_PINNED} chats`);
    }
    params.push(pin);
    sets.push(`is_pinned = $${params.length}`);
  }
  if (body.is_archived !== undefined) {
    params.push(v.bool(body.is_archived, 'is_archived'));
    sets.push(`is_archived = $${params.length}`);
  }
  if (body.marked_unread !== undefined) {
    params.push(v.bool(body.marked_unread, 'marked_unread'));
    sets.push(`marked_unread = $${params.length}`);
  }
  if (body.is_locked !== undefined) {
    // locked chats: hidden behind the phone's fingerprint, and notifications don't show who or what
    params.push(v.bool(body.is_locked, 'is_locked'));
    sets.push(`is_locked = $${params.length}`);
  }
  if (sets.length) {
    await db.query(`UPDATE chat_members SET ${sets.join(', ')} WHERE chat_id = $1 AND user_id = $2`, params);
  }
  bus.emit('chat:updated', { chatId: chat.id, memberIds: [userId] });
  return getChat(userId, chat.id);
}

async function clearHistory(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  await db.query(
    `UPDATE chat_members SET cleared_before_id = COALESCE((SELECT max(id) FROM messages WHERE chat_id = $1), 0)
     WHERE chat_id = $1 AND user_id = $2`,
    [chat.id, userId],
  );
  bus.emit('chat:updated', { chatId: chat.id, memberIds: [userId] });
  return { ok: true };
}

// ------------------------------------------------------------------ invite links
async function regenerateInvite(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const code = randomToken(12);
  await db.query('UPDATE chats SET invite_code = $2 WHERE id = $1', [chat.id, code]);
  return { invite_code: code };
}

async function findByInvite(code) {
  if (typeof code !== 'string' || !/^[A-Za-z0-9_-]{8,32}$/.test(code)) {
    throw notFound('invite_invalid', 'This invite link is invalid or expired');
  }
  let chat = await db.one(`SELECT * FROM chats WHERE invite_code = $1 AND type IN ('group', 'channel')`, [code]);
  if (!chat) {
    // additional links created by admins (expiry / usage limit / revocable)
    chat = await db.one(
      `SELECT c.*, i.code AS via_invite FROM chat_invites i JOIN chats c ON c.id = i.chat_id
       WHERE i.code = $1 AND NOT i.revoked AND (i.expires_at IS NULL OR i.expires_at > now())
         AND (i.usage_limit IS NULL OR i.usage_count < i.usage_limit)`,
      [code],
    );
  }
  if (!chat || chat.is_suspended) throw notFound('invite_invalid', 'This invite link is invalid or expired');
  return chat;
}

async function invitePreview(userId, code) {
  const chat = await findByInvite(code);
  const n = await db.one('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chat.id]);
  const me = await db.one('SELECT 1 AS x FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  return {
    chat_id: chat.id,
    type: chat.type,
    username: chat.username,
    is_verified: chat.is_verified,
    join_approval: chat.join_approval,
    title: chat.title,
    description: chat.description,
    avatar_url: userService.avatarUrl(chat.avatar_media_id),
    member_count: n.n,
    is_member: !!me,
  };
}

async function joinByInvite(userId, code) {
  return joinChat(userId, await findByInvite(code));
}

async function joinChat(userId, chat) {
  const existing = await db.one('SELECT 1 AS x FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  if (!existing && chat.join_approval) {
    await db.query(
      'INSERT INTO chat_join_requests (chat_id, user_id, invite_code) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING',
      [chat.id, userId, chat.via_invite || null],
    );
    const admins = await db.many(`SELECT user_id FROM chat_members WHERE chat_id = $1 AND role IN ('owner', 'admin')`, [chat.id]);
    bus.emit('chat:updated', { chatId: chat.id, memberIds: admins.map((a) => a.user_id) });
    return { requested: true, chat_id: chat.id, title: chat.title };
  }
  if (!existing) {
    if (chat.via_invite) await db.query('UPDATE chat_invites SET usage_count = usage_count + 1 WHERE code = $1', [chat.via_invite]);
    if (chat.type === 'group') {
      const n = await db.one('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chat.id]);
      const max = await settings.get('max_group_members');
      if (n.n >= max) throw badRequest('group_full', 'This group is full');
    }
    await db.query(
      `INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING`,
      [chat.id, userId],
    );
    await logEvent(chat.id, userId, 'member_joined', userId);
    if (chat.type === 'group') {
      await lazyMessages().createSystemMessage(chat.id, userId, { event: 'member_joined', user_id: userId });
      await sendWelcome(chat, [userId]);
      await emitUpdated(chat.id);
    } else {
      bus.emit('chat:updated', { chatId: chat.id, memberIds: [userId] });
    }
  }
  return getChat(userId, chat.id);
}

// ------------------------------------------------------------------ invite links & join requests
async function listInvites(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const rows = await db.many(
    `SELECT code, name, expires_at, usage_limit, usage_count, revoked, created_at,
            (revoked OR (expires_at IS NOT NULL AND expires_at <= now()) OR (usage_limit IS NOT NULL AND usage_count >= usage_limit)) AS expired
     FROM chat_invites WHERE chat_id = $1 ORDER BY created_at DESC LIMIT 100`,
    [chat.id],
  );
  return { primary: chat.invite_code, links: rows };
}

async function createInvite(userId, chatIdRaw, body = {}) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const name = v.str(body.name, { field: 'name', max: 32 }) || '';
  let hours = null;
  if (body.expire_hours !== undefined && body.expire_hours !== null && body.expire_hours !== '') {
    hours = parseInt(body.expire_hours, 10);
    if (!Number.isInteger(hours) || hours < 1 || hours > 24 * 365) throw badRequest('invalid_input', 'expire_hours must be 1–8760');
  }
  let limit = null;
  if (body.usage_limit !== undefined && body.usage_limit !== null && body.usage_limit !== '') {
    limit = parseInt(body.usage_limit, 10);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100000) throw badRequest('invalid_input', 'usage_limit must be 1–100000');
  }
  const n = await db.one('SELECT count(*) AS n FROM chat_invites WHERE chat_id = $1 AND NOT revoked', [chat.id]);
  if (n.n >= 50) throw badRequest('too_many_invites', 'Revoke some links first (max 50)');
  const row = await db.one(
    `INSERT INTO chat_invites (code, chat_id, created_by, name, expires_at, usage_limit)
     VALUES ($1, $2, $3, $4, CASE WHEN $5::int IS NULL THEN NULL ELSE now() + make_interval(hours => $5::int) END, $6)
     RETURNING code, name, expires_at, usage_limit, usage_count, revoked, created_at`,
    [randomToken(12), chat.id, userId, name, hours, limit],
  );
  return row;
}

async function revokeInvite(userId, chatIdRaw, code) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const r = await db.one('UPDATE chat_invites SET revoked = TRUE WHERE chat_id = $1 AND code = $2 RETURNING code', [chat.id, String(code)]);
  if (!r) throw notFound('invite_not_found', 'Invite link not found');
  return { ok: true };
}

async function listJoinRequests(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const rows = await db.many('SELECT user_id, created_at FROM chat_join_requests WHERE chat_id = $1 ORDER BY created_at LIMIT 500', [chat.id]);
  const users = await userService.getUsersMap(userId, rows.map((r) => r.user_id));
  return rows.filter((r) => users.has(r.user_id)).map((r) => ({ user: users.get(r.user_id), requested_at: new Date(r.created_at).toISOString() }));
}

async function resolveJoinRequest(userId, chatIdRaw, targetIdRaw, approve) {
  const chat = await requireMember(chatIdRaw, userId);
  requireRight(chat, 'invite_users');
  const targetId = v.id(targetIdRaw, 'user_id');
  const req = await db.one('DELETE FROM chat_join_requests WHERE chat_id = $1 AND user_id = $2 RETURNING invite_code', [chat.id, targetId]);
  if (!req) throw notFound('request_not_found', 'This join request no longer exists');
  if (approve) {
    const full = await db.one('SELECT * FROM chats WHERE id = $1', [chat.id]);
    await joinChat(targetId, { ...full, join_approval: false, via_invite: req.invite_code || null });
  }
  await emitUpdated(chat.id);
  return { ok: true };
}

/** Owner hands the group/channel to another member (old owner becomes admin). */
async function transferOwnership(chatId, fromUserId, toUserIdRaw, { byAdmin = false } = {}) {
  const toUserId = v.id(toUserIdRaw, 'user_id');
  const outcome = await db.tx(async (c) => {
    const target = await c.query('SELECT role FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chatId, toUserId]);
    if (!target.rows[0]) throw notFound('member_not_found', 'This user is not a member');
    if (target.rows[0].role === 'owner') return { changed: false };
    const old = await c.query(`UPDATE chat_members SET role = 'admin' WHERE chat_id = $1 AND role = 'owner' RETURNING user_id`, [chatId]);
    await c.query(`UPDATE chat_members SET role = 'owner' WHERE chat_id = $1 AND user_id = $2`, [chatId, toUserId]);
    return { changed: true, oldOwner: old.rows[0] ? old.rows[0].user_id : null };
  });
  if (outcome.changed) {
    const chat = await db.one('SELECT type FROM chats WHERE id = $1', [chatId]);
    if (chat.type === 'group') {
      await lazyMessages().createSystemMessage(chatId, byAdmin ? null : fromUserId, { event: 'owner_changed', user_id: toUserId });
    }
    await emitUpdated(chatId);
  }
  return { ok: true };
}

async function transferOwnershipByOwner(userId, chatIdRaw, toUserIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  if (!isMulti(chat)) throw badRequest('not_a_group', 'Only groups and channels have owners');
  if (chat.my_role !== 'owner') throw forbidden('not_owner', 'Only the owner can transfer ownership');
  return transferOwnership(chat.id, userId, toUserIdRaw);
}

// ------------------------------------------------------------------ channels & public usernames
/** Usernames are shared between users, groups and channels. */
/** Throws if the username is on the admin "reserved" list (admins can still assign it). */
async function assertNotReserved(name) {
  const reserved = await settings.get('reserved_usernames');
  if ((reserved || []).includes(String(name).toLowerCase())) {
    throw conflict('username_reserved', 'This username is reserved');
  }
}

async function usernameTaken(name, { exceptUserId = 0, exceptChatId = 0 } = {}) {
  const r = await db.one(
    `SELECT (EXISTS (SELECT 1 FROM users WHERE lower(username) = lower($1) AND id <> $2)
          OR EXISTS (SELECT 1 FROM chats WHERE lower(username) = lower($1) AND id <> $3)) AS taken`,
    [name, exceptUserId, exceptChatId],
  );
  return r.taken;
}

async function createChannel(ownerId, body) {
  await settings.requireFeature('feature_channels', 'Channels');
  const title = v.str(body.title, { field: 'title', min: 1, max: 128, required: true });
  const description = v.str(body.description, { field: 'description', max: 255 }) || '';
  const signatures = body.signatures === true;
  let username = null;
  if (body.username) {
    username = v.validateUsername(String(body.username).trim().replace(/^@/, ''));
    await assertNotReserved(username);
    if (await usernameTaken(username)) throw conflict('username_taken', 'This username is already taken');
  }
  let chatId;
  try {
    chatId = await db.tx(async (c) => {
      const r = await c.query(
        `INSERT INTO chats (type, title, description, created_by, invite_code, username, is_public, signatures)
         VALUES ('channel', $1, $2, $3, $4, $5, $6, $7) RETURNING id`,
        [title, description, ownerId, randomToken(12), username, !!username, signatures],
      );
      const id = r.rows[0].id;
      await c.query(`INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'owner')`, [id, ownerId]);
      return id;
    });
  } catch (err) {
    if (err.code === '23505') throw conflict('username_taken', 'This username is already taken');
    throw err;
  }
  await lazyMessages().createSystemMessage(chatId, ownerId, { event: 'channel_created', title });
  return getChat(ownerId, chatId);
}

/** Set (public) or remove (private) the @username of a group or channel. Owner only. */
async function setChatUsername(userId, chatIdRaw, raw) {
  const chat = await requireMember(chatIdRaw, userId);
  if (!isMulti(chat)) throw badRequest('not_a_group', 'Only groups and channels can have a public link');
  if (chat.my_role !== 'owner') throw forbidden('not_owner', 'Only the owner can change the public link');
  let username = null;
  if (raw !== null && raw !== undefined && raw !== '') {
    username = v.validateUsername(String(raw).trim().replace(/^@/, ''));
    if (username.toLowerCase() !== String(chat.username || '').toLowerCase()) await assertNotReserved(username);
    if (await usernameTaken(username, { exceptChatId: chat.id })) throw conflict('username_taken', 'This username is already taken');
  }
  try {
    await db.query('UPDATE chats SET username = $2, is_public = $3, updated_at = now() WHERE id = $1', [chat.id, username, !!username]);
  } catch (err) {
    if (err.code === '23505') throw conflict('username_taken', 'This username is already taken');
    throw err;
  }
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

function publicSummary(c, memberCount, isMember) {
  return {
    chat_id: c.id,
    type: c.type,
    title: c.title,
    description: c.description,
    username: c.username,
    is_verified: c.is_verified,
    avatar_url: userService.avatarUrl(c.avatar_media_id),
    member_count: memberCount,
    is_member: isMember,
    join_approval: c.type === 'group' && !!c.join_approval,
  };
}

async function publicPreview(userId, usernameRaw) {
  const name = String(usernameRaw || '').trim().replace(/^@/, '');
  const c = await db.one(
    `SELECT c.*, (SELECT count(*) FROM chat_members WHERE chat_id = c.id) AS n,
            EXISTS (SELECT 1 FROM chat_members WHERE chat_id = c.id AND user_id = $2) AS me
     FROM chats c WHERE lower(c.username) = lower($1) AND c.is_public AND NOT c.is_suspended`,
    [name, userId],
  );
  if (!c) throw notFound('chat_not_found', 'No public group or channel with this username');
  return publicSummary(c, c.n, c.me);
}

async function joinPublic(userId, chatIdRaw) {
  const chat = await db.one('SELECT * FROM chats WHERE id = $1 AND is_public AND NOT is_suspended', [v.id(chatIdRaw, 'chat_id')]);
  if (!chat) throw notFound('chat_not_found', 'This group or channel is not public');
  return joinChat(userId, chat);
}

async function searchPublic(userId, rawQuery) {
  const q = String(rawQuery || '').trim().replace(/^@/, '');
  if (q.length < 2) return [];
  const term = q.replace(/[\\%_]/g, (ch) => `\\${ch}`);
  const rows = await db.many(
    `SELECT c.*, (SELECT count(*) FROM chat_members WHERE chat_id = c.id) AS n,
            EXISTS (SELECT 1 FROM chat_members WHERE chat_id = c.id AND user_id = $2) AS me
     FROM chats c
     WHERE c.is_public AND NOT c.is_suspended
       AND (lower(c.username) LIKE lower($1) || '%' OR c.title ILIKE '%' || $1 || '%')
     ORDER BY (lower(c.username) = lower($1)) DESC, n DESC
     LIMIT 20`,
    [term, userId],
  );
  return rows.map((c) => publicSummary(c, c.n, c.me));
}

/** Channel/group statistics for admins. */
async function chatStats(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireGroupAdmin(chat);
  const totals = await db.one(
    `SELECT
       (SELECT count(*) FROM chat_members WHERE chat_id = $1) AS members,
       (SELECT count(*) FROM chat_members WHERE chat_id = $1 AND joined_at > now() - interval '7 days') AS joined_7d,
       (SELECT count(*) FROM messages WHERE chat_id = $1 AND type <> 'system' AND deleted_at IS NULL
          AND created_at > now() - interval '30 days') AS posts_30d,
       (SELECT COALESCE(sum(views_count), 0)::bigint FROM messages WHERE chat_id = $1 AND deleted_at IS NULL) AS views_total,
       (SELECT COALESCE(round(avg(views_count)), 0)::bigint FROM messages WHERE chat_id = $1 AND type <> 'system'
          AND deleted_at IS NULL AND created_at > now() - interval '30 days') AS avg_views_30d,
       (SELECT count(*) FROM message_reactions r JOIN messages m ON m.id = r.message_id
          WHERE m.chat_id = $1 AND m.created_at > now() - interval '30 days') AS reactions_30d,
       (SELECT count(*) FROM messages f JOIN messages m ON m.id = f.forward_source_id
          WHERE m.chat_id = $1 AND f.created_at > now() - interval '30 days') AS shares_30d,
       (SELECT count(*) FROM chat_events e WHERE e.chat_id = $1 AND e.action IN ('member_left', 'member_removed')
          AND e.created_at > now() - interval '7 days') AS left_7d`,
    [chat.id],
  );
  const growth = await db.many(
    `SELECT to_char(d, 'YYYY-MM-DD') AS day, count(cm.user_id) AS count
     FROM generate_series(current_date - 29, current_date, interval '1 day') AS d
     LEFT JOIN chat_members cm ON cm.chat_id = $1 AND cm.joined_at >= d AND cm.joined_at < d + interval '1 day'
     GROUP BY d ORDER BY d`,
    [chat.id],
  );
  const top = await db.many(
    `SELECT m.id, m.type, left(m.text, 120) AS text, m.views_count AS views, m.created_at,
            (SELECT count(*) FROM message_reactions r WHERE r.message_id = m.id)::int AS reactions,
            (SELECT count(*) FROM messages f WHERE f.forward_source_id = m.id)::int AS shares
     FROM messages m
     WHERE m.chat_id = $1 AND m.type <> 'system' AND m.deleted_at IS NULL AND m.created_at > now() - interval '30 days'
     ORDER BY m.views_count DESC, m.id DESC LIMIT 10`,
    [chat.id],
  );
  return { ...totals, joins_30d: growth, top_posts: top };
}

module.exports = {
  RIGHTS,
  CATEGORIES,
  hasRight,
  requireRight,
  logEvent,
  restrictMember,
  listEvents,
  setDraft,
  directory,
  acceptRequest,
  declineRequest,
  clearRequestsFrom,
  setDisappearing,
  DISAPPEAR_OPTIONS,
  ADMIN_ROLES,
  MULTI_TYPES,
  isMulti,
  usernameTaken,
  assertNotReserved,
  getChatsByIds,
  listInvites,
  createInvite,
  revokeInvite,
  listJoinRequests,
  resolveJoinRequest,
  transferOwnership,
  transferOwnershipByOwner,
  createChannel,
  setChatUsername,
  publicPreview,
  joinPublic,
  searchPublic,
  chatStats,
  requireMember,
  requireGroupAdmin,
  memberIds,
  privatePeerId,
  listChats,
  getChat,
  getOrCreatePrivate,
  createGroup,
  updateGroup,
  setGroupAvatar,
  addMembers,
  removeUserFromGroup,
  removeMember,
  leaveChat,
  setMemberRole,
  getMembers,
  updateMySettings,
  clearHistory,
  regenerateInvite,
  invitePreview,
  joinByInvite,
  emitUpdated,
};
