'use strict';

const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const v = require('../utils/validate');
const { randomToken } = require('../utils/crypto');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const lazyMessages = () => require('./message.service'); // circular import guard

const ADMIN_ROLES = ['owner', 'admin'];
const MAX_PINNED = 5;

// ------------------------------------------------------------------ helpers
async function requireMember(chatIdRaw, userId) {
  const chatId = v.id(chatIdRaw, 'chat_id');
  const row = await db.one(
    `SELECT c.*, cm.role AS my_role, cm.cleared_before_id, cm.last_read_message_id
     FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2
     WHERE c.id = $1`,
    [chatId, userId],
  );
  if (!row) throw notFound('chat_not_found', 'Chat not found');
  return row;
}

function requireGroupAdmin(chat) {
  if (chat.type !== 'group') throw badRequest('not_a_group', 'This action is only for groups');
  if (!ADMIN_ROLES.includes(chat.my_role)) throw forbidden('not_admin', 'Only group admins can do this');
}

async function memberIds(chatId) {
  const rows = await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId]);
  return rows.map((r) => r.user_id);
}

/** The other member of a private chat (null for "Saved Messages"). */
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
       c.created_by, c.created_at, c.last_message_at,
       cm.role AS my_role, cm.last_read_message_id, cm.muted_until, cm.is_pinned, cm.is_archived,
       (SELECT count(*) FROM chat_members x WHERE x.chat_id = c.id) AS member_count,
       (SELECT count(*) FROM messages m
          WHERE m.chat_id = c.id
            AND m.id > GREATEST(cm.last_read_message_id, cm.cleared_before_id)
            AND m.deleted_at IS NULL
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
  WHERE m.chat_id = c.id AND m.id > cm.cleared_before_id AND m.deleted_at IS NULL
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
    rows.map((r) => r.last_visible_message_id).filter(Boolean),
  );
  const now = new Date();
  return rows.map((r) => {
    const isPrivate = r.type === 'private';
    const peer = isPrivate && r.peer_id ? peers.get(r.peer_id) || null : null;
    const isSaved = isPrivate && !r.peer_id;
    let title = r.title;
    if (isPrivate) title = isSaved ? 'Saved Messages' : userService.displayName(peer && { ...peer, status: peer.deleted ? 'deleted' : 'active' });
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
      invite_code: r.type === 'group' && ADMIN_ROLES.includes(r.my_role) ? r.invite_code : null,
      is_suspended: r.is_suspended,
      unread_count: r.unread_count,
      read_up_to: r.read_up_to,
      delivered_up_to: Math.max(r.delivered_up_to, r.read_up_to),
      muted_until: r.muted_until ? new Date(r.muted_until).toISOString() : null,
      is_muted: !!r.muted_until && new Date(r.muted_until) > now,
      is_pinned: r.is_pinned,
      is_archived: r.is_archived,
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
      await c.query(
        'INSERT INTO chat_members (chat_id, user_id, is_hidden) VALUES ($1, $2, TRUE) ON CONFLICT DO NOTHING',
        [id, peerId],
      );
    }
    return id;
  });
  return getChat(userId, chatId);
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

async function updateGroup(userId, chatIdRaw, body) {
  const chat = await requireMember(chatIdRaw, userId);
  requireGroupAdmin(chat);
  const title = v.str(body.title, { field: 'title', min: 1, max: 128 });
  const description = v.str(body.description, { field: 'description', max: 255 });
  await db.query(
    `UPDATE chats SET title = COALESCE($2, title), description = COALESCE($3, description), updated_at = now()
     WHERE id = $1`,
    [chat.id, title === undefined ? null : title, description === undefined ? null : description],
  );
  if (title !== undefined && title !== chat.title) {
    await lazyMessages().createSystemMessage(chat.id, userId, { event: 'title_changed', title });
  }
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

async function setGroupAvatar(userId, chatIdRaw, mediaIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireGroupAdmin(chat);
  let mediaId = null;
  if (mediaIdRaw !== null && mediaIdRaw !== undefined) {
    const media = await db.one('SELECT * FROM media WHERE id = $1', [v.id(mediaIdRaw, 'media_id')]);
    if (!media || media.uploader_id !== userId) throw notFound('media_not_found', 'Media not found');
    if (!['avatar', 'image'].includes(media.kind)) throw badRequest('invalid_media', 'Group photo must be an image');
    await db.query('UPDATE media SET is_public = TRUE WHERE id = $1', [media.id]);
    mediaId = media.id;
  }
  await db.query('UPDATE chats SET avatar_media_id = $2, updated_at = now() WHERE id = $1', [chat.id, mediaId]);
  await lazyMessages().createSystemMessage(chat.id, userId, { event: mediaId ? 'photo_changed' : 'photo_removed' });
  await emitUpdated(chat.id);
  return getChat(userId, chat.id);
}

async function addMembers(userId, chatIdRaw, userIdsRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  requireGroupAdmin(chat);
  if (chat.is_suspended) throw forbidden('chat_suspended', 'This group has been suspended');
  const existing = new Set(await memberIds(chat.id));
  const candidates = v.idList(userIdsRaw, 'user_ids', 200).filter((id) => !existing.has(id));
  const { ok, skipped } = await filterAddable(userId, candidates);
  const max = await settings.get('max_group_members');
  if (existing.size + ok.length > max) throw badRequest('group_full', `A group can have at most ${max} members`);
  if (ok.length) {
    await db.query(
      `INSERT INTO chat_members (chat_id, user_id, role) SELECT $1, x, 'member' FROM unnest($2::bigint[]) AS x
       ON CONFLICT DO NOTHING`,
      [chat.id, ok],
    );
    await lazyMessages().createSystemMessage(chat.id, userId, { event: 'members_added', user_ids: ok });
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
    await c.query('SELECT id FROM chats WHERE id = $1 FOR UPDATE', [chatId]);
    const del = await c.query('DELETE FROM chat_members WHERE chat_id = $1 AND user_id = $2 RETURNING role', [chatId, userId]);
    if (del.rows.length === 0) return { removed: false };
    const left = await c.query('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chatId]);
    if (left.rows[0].n === 0) {
      await c.query('DELETE FROM chats WHERE id = $1', [chatId]);
      return { removed: true, chatDeleted: true };
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
    return { removed: true, chatDeleted: false, newOwner };
  });
  if (!outcome.removed) return outcome;
  bus.emit('chat:removed', { chatId, userIds: [userId] });
  if (!outcome.chatDeleted) {
    const event = reason === 'removed' ? 'member_removed' : 'member_left';
    await lazyMessages().createSystemMessage(chatId, by || userId, { event, user_id: userId });
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
  requireGroupAdmin(chat);
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
  if (chat.type === 'group') {
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

async function setMemberRole(actorId, chatIdRaw, targetIdRaw, role) {
  const chat = await requireMember(chatIdRaw, actorId);
  if (chat.type !== 'group') throw badRequest('not_a_group', 'This action is only for groups');
  if (chat.my_role !== 'owner') throw forbidden('not_owner', 'Only the group owner can change admins');
  const newRole = v.oneOf(role, ['admin', 'member'], 'role');
  const targetId = v.id(targetIdRaw, 'user_id');
  const r = await db.one(
    `UPDATE chat_members SET role = $3 WHERE chat_id = $1 AND user_id = $2 AND role <> 'owner' RETURNING user_id`,
    [chat.id, targetId, newRole],
  );
  if (!r) throw notFound('member_not_found', 'This user is not in the group');
  await emitUpdated(chat.id);
  return { ok: true };
}

async function getMembers(userId, chatIdRaw) {
  const chat = await requireMember(chatIdRaw, userId);
  const rows = await db.many(
    `SELECT user_id, role, joined_at FROM chat_members WHERE chat_id = $1
     ORDER BY CASE role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, joined_at
     LIMIT 5000`,
    [chat.id],
  );
  const users = await userService.getUsersMap(userId, rows.map((r) => r.user_id));
  return rows
    .filter((r) => users.has(r.user_id))
    .map((r) => ({ user: users.get(r.user_id), role: r.role, joined_at: new Date(r.joined_at).toISOString() }));
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
  requireGroupAdmin(chat);
  const code = randomToken(12);
  await db.query('UPDATE chats SET invite_code = $2 WHERE id = $1', [chat.id, code]);
  return { invite_code: code };
}

async function findByInvite(code) {
  if (typeof code !== 'string' || !/^[A-Za-z0-9_-]{8,32}$/.test(code)) {
    throw notFound('invite_invalid', 'This invite link is invalid or expired');
  }
  const chat = await db.one(`SELECT * FROM chats WHERE invite_code = $1 AND type = 'group'`, [code]);
  if (!chat || chat.is_suspended) throw notFound('invite_invalid', 'This invite link is invalid or expired');
  return chat;
}

async function invitePreview(userId, code) {
  const chat = await findByInvite(code);
  const n = await db.one('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chat.id]);
  const me = await db.one('SELECT 1 AS x FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  return {
    chat_id: chat.id,
    title: chat.title,
    description: chat.description,
    avatar_url: userService.avatarUrl(chat.avatar_media_id),
    member_count: n.n,
    is_member: !!me,
  };
}

async function joinByInvite(userId, code) {
  const chat = await findByInvite(code);
  const existing = await db.one('SELECT 1 AS x FROM chat_members WHERE chat_id = $1 AND user_id = $2', [chat.id, userId]);
  if (!existing) {
    const n = await db.one('SELECT count(*) AS n FROM chat_members WHERE chat_id = $1', [chat.id]);
    const max = await settings.get('max_group_members');
    if (n.n >= max) throw badRequest('group_full', 'This group is full');
    await db.query(
      `INSERT INTO chat_members (chat_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING`,
      [chat.id, userId],
    );
    await lazyMessages().createSystemMessage(chat.id, userId, { event: 'member_joined', user_id: userId });
    await emitUpdated(chat.id);
  }
  return getChat(userId, chat.id);
}

module.exports = {
  ADMIN_ROLES,
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
