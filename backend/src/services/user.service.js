'use strict';

const db = require('../db');
const bus = require('../bus');
const presence = require('./presence');
const v = require('../utils/validate');
const { badRequest, notFound, conflict, forbidden } = require('../utils/errors');

const PRIVACY_VALUES = ['everyone', 'contacts', 'nobody'];

function displayName(u) {
  if (!u || u.status === 'deleted') return 'Deleted Account';
  const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim();
  return name || (u.username ? `@${u.username}` : 'User');
}

function avatarUrl(mediaId) {
  return mediaId ? `/api/media/${mediaId}/public` : null;
}

function isBanned(u) {
  return u.status === 'banned' && (!u.banned_until || new Date(u.banned_until) > new Date());
}

/**
 * Relationship sets between a viewer and a list of users, used for privacy rules.
 *  theyHaveMe: users who saved the viewer as a contact ("My contacts" privacy)
 *  iHaveThem:  users the viewer saved as contacts
 *  blockedMe:  users who blocked the viewer
 *  iBlocked:   users the viewer blocked
 */
async function relations(viewerId, userIds) {
  const rel = { theyHaveMe: new Set(), iHaveThem: new Set(), blockedMe: new Set(), iBlocked: new Set() };
  const ids = userIds.filter((id) => id && id !== viewerId);
  if (!viewerId || ids.length === 0) return rel;
  const contacts = await db.many(
    `SELECT owner_id, contact_id FROM contacts
     WHERE (owner_id = ANY($2::bigint[]) AND contact_id = $1) OR (owner_id = $1 AND contact_id = ANY($2::bigint[]))`,
    [viewerId, ids],
  );
  for (const c of contacts) {
    if (c.contact_id === viewerId) rel.theyHaveMe.add(c.owner_id);
    else rel.iHaveThem.add(c.contact_id);
  }
  const blocks = await db.many(
    `SELECT blocker_id, blocked_id FROM blocks
     WHERE (blocker_id = ANY($2::bigint[]) AND blocked_id = $1) OR (blocker_id = $1 AND blocked_id = ANY($2::bigint[]))`,
    [viewerId, ids],
  );
  for (const b of blocks) {
    if (b.blocked_id === viewerId) rel.blockedMe.add(b.blocker_id);
    else rel.iBlocked.add(b.blocked_id);
  }
  return rel;
}

function allowedBy(setting, theyHaveMe) {
  return setting === 'everyone' || (setting === 'contacts' && theyHaveMe);
}

/** Public representation of a user, as seen by `viewerId`. */
function serialize(u, viewerId, rel) {
  const self = u.id === viewerId;
  if (u.status === 'deleted') {
    return {
      id: u.id,
      deleted: true,
      first_name: 'Deleted Account',
      last_name: '',
      username: null,
      bio: '',
      avatar_url: null,
      is_verified: false,
      phone: null,
      online: false,
      last_seen: null,
      last_seen_hidden: true,
    };
  }
  const r = rel || { theyHaveMe: new Set(), iHaveThem: new Set(), blockedMe: new Set(), iBlocked: new Set() };
  const theyHaveMe = r.theyHaveMe.has(u.id);
  const blockedMe = r.blockedMe.has(u.id);
  const can = (setting) => self || (!blockedMe && allowedBy(setting, theyHaveMe));
  const canSeeSeen = can(u.privacy_last_seen);

  const out = {
    id: u.id,
    first_name: u.first_name,
    last_name: u.last_name,
    username: u.username,
    bio: u.bio,
    is_verified: u.is_verified,
    avatar_url: can(u.privacy_avatar) ? avatarUrl(u.avatar_media_id) : null,
    phone: can(u.privacy_phone) ? u.phone : null,
    online: canSeeSeen && presence.isOnline(u.id),
    last_seen: canSeeSeen && u.last_seen_at ? new Date(u.last_seen_at).toISOString() : null,
    last_seen_hidden: !canSeeSeen,
  };
  if (self) {
    out.privacy = {
      last_seen: u.privacy_last_seen,
      avatar: u.privacy_avatar,
      phone: u.privacy_phone,
      group_add: u.privacy_group_add,
    };
    out.created_at = new Date(u.created_at).toISOString();
  } else {
    out.is_contact = r.iHaveThem.has(u.id);
    out.blocked = r.iBlocked.has(u.id);
  }
  return out;
}

/** Map<userId, serializedUser> for the given ids, from the viewer's point of view. */
async function getUsersMap(viewerId, ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  const map = new Map();
  if (unique.length === 0) return map;
  const rows = await db.many('SELECT * FROM users WHERE id = ANY($1::bigint[])', [unique]);
  const rel = await relations(viewerId, unique);
  for (const u of rows) map.set(u.id, serialize(u, viewerId, rel));
  return map;
}

async function getUser(viewerId, userId) {
  const map = await getUsersMap(viewerId, [userId]);
  const u = map.get(userId);
  if (!u) throw notFound('user_not_found', 'User not found');
  return u;
}

async function getMe(userId) {
  const u = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  return serialize(u, userId);
}

async function updateProfile(userId, body) {
  const sets = [];
  const params = [userId];
  const add = (col, val) => {
    params.push(val);
    sets.push(`${col} = $${params.length}`);
  };
  if (body.first_name !== undefined) add('first_name', v.str(body.first_name, { field: 'first_name', min: 1, max: 64 }));
  if (body.last_name !== undefined) add('last_name', v.str(body.last_name, { field: 'last_name', max: 64 }));
  if (body.bio !== undefined) add('bio', v.str(body.bio, { field: 'bio', max: 140 }));
  if (body.username !== undefined) {
    const raw = typeof body.username === 'string' ? body.username.trim().replace(/^@/, '') : body.username;
    const name = v.validateUsername(raw);
    const current = await db.one('SELECT username FROM users WHERE id = $1', [userId]);
    if (name && name.toLowerCase() !== String((current && current.username) || '').toLowerCase()) {
      await require('./chat.service').assertNotReserved(name);
    }
    if (name && (await require('./chat.service').usernameTaken(name, { exceptUserId: userId }))) {
      throw conflict('username_taken', 'This username is already taken');
    }
    add('username', name);
  }
  if (sets.length === 0) return getMe(userId);
  try {
    await db.query(`UPDATE users SET ${sets.join(', ')}, updated_at = now() WHERE id = $1`, params);
  } catch (err) {
    if (err.code === '23505') throw conflict('username_taken', 'This username is already taken');
    throw err;
  }
  bus.emit('user:updated', { userId });
  return getMe(userId);
}

async function checkUsername(userId, username) {
  const name = v.validateUsername(String(username || '').trim().replace(/^@/, ''));
  if (!name) throw badRequest('invalid_username', 'Username is required');
  const taken = await require('./chat.service').usernameTaken(name, { exceptUserId: userId });
  return { username: name, available: !taken };
}

async function setAvatar(userId, mediaId) {
  const media = await db.one('SELECT * FROM media WHERE id = $1', [v.id(mediaId, 'media_id')]);
  if (!media || media.uploader_id !== userId) throw notFound('media_not_found', 'Media not found');
  if (!['avatar', 'image'].includes(media.kind)) throw badRequest('invalid_media', 'Avatar must be an image');
  await db.query('UPDATE media SET is_public = TRUE WHERE id = $1', [media.id]);
  await db.query('UPDATE users SET avatar_media_id = $2, updated_at = now() WHERE id = $1', [userId, media.id]);
  bus.emit('user:updated', { userId });
  return getMe(userId);
}

async function removeAvatar(userId) {
  await db.query('UPDATE users SET avatar_media_id = NULL, updated_at = now() WHERE id = $1', [userId]);
  bus.emit('user:updated', { userId });
  return getMe(userId);
}

async function updatePrivacy(userId, body) {
  const map = { last_seen: 'privacy_last_seen', avatar: 'privacy_avatar', phone: 'privacy_phone', group_add: 'privacy_group_add' };
  const sets = [];
  const params = [userId];
  for (const [key, col] of Object.entries(map)) {
    if (body[key] !== undefined) {
      params.push(v.oneOf(body[key], PRIVACY_VALUES, key));
      sets.push(`${col} = $${params.length}`);
    }
  }
  if (sets.length) await db.query(`UPDATE users SET ${sets.join(', ')}, updated_at = now() WHERE id = $1`, params);
  return getMe(userId);
}

function escapeLike(s) {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** Search by exact phone number, username prefix, or name among the viewer's contacts. */
async function searchUsers(viewerId, rawQuery) {
  const q = String(rawQuery || '').trim();
  if (q.length < 2) return [];
  const phone = v.tryNormalizePhone(q);
  let rows;
  if (phone) {
    rows = await db.many(
      `SELECT id FROM users WHERE phone = $1 AND status = 'active' AND id <> $2 AND privacy_phone <> 'nobody'`,
      [phone, viewerId],
    );
  } else {
    const term = escapeLike(q.replace(/^@/, ''));
    if (term.length < 2) return [];
    rows = await db.many(
      `SELECT id FROM users
       WHERE status = 'active' AND id <> $1 AND (
         lower(username) LIKE lower($2) || '%'
         OR (id IN (SELECT contact_id FROM contacts WHERE owner_id = $1)
             AND (first_name || ' ' || last_name) ILIKE '%' || $2 || '%')
       )
       ORDER BY (lower(username) = lower($2)) DESC NULLS LAST, username NULLS LAST
       LIMIT 20`,
      [viewerId, term],
    );
  }
  const map = await getUsersMap(viewerId, rows.map((r) => r.id));
  return rows.map((r) => map.get(r.id)).filter(Boolean);
}

// ------------------------------------------------------------------ sessions
async function listSessions(userId, currentSessionId) {
  const rows = await db.many(
    `SELECT id, device_name, platform, app_version, ip, created_at, last_active_at
     FROM sessions WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()
     ORDER BY last_active_at DESC`,
    [userId],
  );
  return rows.map((s) => ({ ...s, current: s.id === currentSessionId }));
}

async function revokeSession(userId, sessionId) {
  const row = await db.one(
    'UPDATE sessions SET revoked_at = now() WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL RETURNING id',
    [v.id(sessionId, 'session_id'), userId],
  );
  if (!row) throw notFound('session_not_found', 'Session not found');
  bus.emit('sessions:revoked', { userId, sessionIds: [row.id], reason: 'terminated' });
  return { ok: true };
}

async function revokeOtherSessions(userId, currentSessionId) {
  const rows = await db.many(
    'UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND id <> $2 AND revoked_at IS NULL RETURNING id',
    [userId, currentSessionId],
  );
  if (rows.length) bus.emit('sessions:revoked', { userId, sessionIds: rows.map((r) => r.id), reason: 'terminated' });
  return { ok: true, revoked: rows.length };
}

async function setFcmToken(userId, sessionId, token) {
  const t = token === null ? null : v.str(token, { field: 'token', min: 10, max: 4096, required: true });
  if (t) await db.query('UPDATE sessions SET fcm_token = NULL WHERE fcm_token = $1 AND id <> $2', [t, sessionId]);
  await db.query('UPDATE sessions SET fcm_token = $3 WHERE id = $1 AND user_id = $2', [sessionId, userId, t]);
  return { ok: true };
}

// ------------------------------------------------------------------ contacts
async function syncContacts(userId, phones) {
  if (!Array.isArray(phones)) throw badRequest('invalid_input', 'phones must be an array');
  if (phones.length > 2000) throw badRequest('invalid_input', 'At most 2000 phone numbers per request');
  const normalized = [...new Set(phones.map((p) => v.tryNormalizePhone(String(p))).filter(Boolean))];
  if (normalized.length === 0) return [];
  const found = await db.many(
    `SELECT id FROM users WHERE phone = ANY($1::text[]) AND status = 'active' AND id <> $2`,
    [normalized, userId],
  );
  const ids = found.map((r) => r.id);
  if (ids.length) {
    await db.query(
      `INSERT INTO contacts (owner_id, contact_id) SELECT $1, x FROM unnest($2::bigint[]) AS x ON CONFLICT DO NOTHING`,
      [userId, ids],
    );
  }
  const map = await getUsersMap(userId, ids);
  return ids.map((id) => map.get(id)).filter(Boolean);
}

async function addContact(userId, targetId) {
  const id = v.id(targetId, 'user_id');
  if (id === userId) throw badRequest('invalid_input', 'You cannot add yourself');
  const target = await db.one(`SELECT id FROM users WHERE id = $1 AND status <> 'deleted'`, [id]);
  if (!target) throw notFound('user_not_found', 'User not found');
  await db.query('INSERT INTO contacts (owner_id, contact_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [userId, id]);
  return getUser(userId, id);
}

async function removeContact(userId, targetId) {
  await db.query('DELETE FROM contacts WHERE owner_id = $1 AND contact_id = $2', [userId, v.id(targetId, 'user_id')]);
  return { ok: true };
}

async function listContacts(userId) {
  const rows = await db.many(
    `SELECT c.contact_id AS id FROM contacts c JOIN users u ON u.id = c.contact_id
     WHERE c.owner_id = $1 AND u.status <> 'deleted' ORDER BY u.first_name, u.last_name`,
    [userId],
  );
  const map = await getUsersMap(userId, rows.map((r) => r.id));
  return rows.map((r) => map.get(r.id)).filter(Boolean);
}

// ------------------------------------------------------------------ blocks
async function block(userId, targetId) {
  const id = v.id(targetId, 'user_id');
  if (id === userId) throw badRequest('invalid_input', 'You cannot block yourself');
  const target = await db.one('SELECT id FROM users WHERE id = $1', [id]);
  if (!target) throw notFound('user_not_found', 'User not found');
  await db.query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [userId, id]);
  return { ok: true };
}

async function unblock(userId, targetId) {
  await db.query('DELETE FROM blocks WHERE blocker_id = $1 AND blocked_id = $2', [userId, v.id(targetId, 'user_id')]);
  return { ok: true };
}

async function listBlocked(userId) {
  const rows = await db.many('SELECT blocked_id AS id FROM blocks WHERE blocker_id = $1 ORDER BY created_at DESC', [userId]);
  const map = await getUsersMap(userId, rows.map((r) => r.id));
  return rows.map((r) => map.get(r.id)).filter(Boolean);
}

async function isBlockedEither(a, b, client = db) {
  const r = await client.query(
    'SELECT 1 FROM blocks WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1) LIMIT 1',
    [a, b],
  );
  return r.rows.length > 0;
}

// ------------------------------------------------------------------ account deletion
/**
 * Soft-deletes the account: frees phone/username, wipes profile, leaves groups
 * (transferring ownership), revokes all sessions. Messages stay as "Deleted Account".
 */
async function deleteAccount(userId, { byAdmin = false } = {}) {
  const chatService = require('./chat.service'); // lazy: avoids circular import
  const user = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  if (!user) throw notFound('user_not_found', 'User not found');
  if (user.status === 'deleted') return { ok: true };

  const groups = await db.many(
    `SELECT cm.chat_id FROM chat_members cm JOIN chats c ON c.id = cm.chat_id
     WHERE cm.user_id = $1 AND c.type = 'group'`,
    [userId],
  );
  for (const g of groups) {
    await chatService.removeUserFromGroup(g.chat_id, userId, { reason: byAdmin ? 'deleted_by_admin' : 'left' });
  }

  await db.tx(async (c) => {
    await c.query(
      `UPDATE users SET status = 'deleted', phone = 'deleted:' || id::text, username = NULL,
         first_name = '', last_name = '', bio = '', avatar_media_id = NULL, updated_at = now()
       WHERE id = $1`,
      [userId],
    );
    await c.query('UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
    await c.query('DELETE FROM contacts WHERE owner_id = $1 OR contact_id = $1', [userId]);
  });
  bus.emit('sessions:revoked', { userId, sessionIds: null, reason: 'account_deleted' });
  bus.emit('user:updated', { userId });
  return { ok: true };
}

/** Data export for the user themself or an admin data request. */
async function exportData(userId) {
  const u = await db.one(
    `SELECT id, phone, username, first_name, last_name, bio, status, is_verified, created_at, last_seen_at,
            privacy_last_seen, privacy_avatar, privacy_phone, privacy_group_add
     FROM users WHERE id = $1`,
    [userId],
  );
  if (!u) throw notFound('user_not_found', 'User not found');
  const q = (sql) => db.many(sql, [userId]);
  return {
    exported_at: new Date().toISOString(),
    profile: u,
    sessions: await q('SELECT device_name, platform, app_version, ip, created_at, last_active_at, revoked_at FROM sessions WHERE user_id = $1 ORDER BY id'),
    contacts: await q(`SELECT u.id, u.first_name, u.last_name, u.username FROM contacts c JOIN users u ON u.id = c.contact_id WHERE c.owner_id = $1`),
    blocked: await q('SELECT blocked_id AS user_id, created_at FROM blocks WHERE blocker_id = $1'),
    chats: await q(
      `SELECT c.id, c.type, c.title, cm.role, cm.joined_at FROM chat_members cm JOIN chats c ON c.id = cm.chat_id WHERE cm.user_id = $1`,
    ),
    messages_sent: await q(
      `SELECT id, chat_id, type, text, created_at, edited_at FROM messages
       WHERE sender_id = $1 AND deleted_at IS NULL AND type <> 'system' ORDER BY id DESC LIMIT 10000`,
    ),
    uploads: await q('SELECT id, kind, mime, size_bytes, original_name, created_at FROM media WHERE uploader_id = $1 ORDER BY id DESC LIMIT 5000'),
    stories: await q('SELECT id, caption, privacy, created_at, expires_at, deleted_at FROM stories WHERE user_id = $1 ORDER BY id DESC'),
    reports_sent: await q('SELECT target_type, target_id, reason, details, status, created_at FROM reports WHERE reporter_id = $1'),
    support_tickets: await q('SELECT id, subject, category, status, created_at FROM support_tickets WHERE user_id = $1'),
  };
}

function assertActive(u) {
  if (!u || u.status === 'deleted') throw notFound('user_not_found', 'User not found');
  if (isBanned(u)) throw forbidden('user_unavailable', 'This user is unavailable');
}

module.exports = {
  PRIVACY_VALUES,
  displayName,
  avatarUrl,
  isBanned,
  relations,
  serialize,
  getUsersMap,
  getUser,
  getMe,
  updateProfile,
  checkUsername,
  setAvatar,
  removeAvatar,
  updatePrivacy,
  searchUsers,
  listSessions,
  revokeSession,
  revokeOtherSessions,
  setFcmToken,
  syncContacts,
  addContact,
  removeContact,
  listContacts,
  block,
  unblock,
  listBlocked,
  isBlockedEither,
  deleteAccount,
  exportData,
  assertActive,
};
