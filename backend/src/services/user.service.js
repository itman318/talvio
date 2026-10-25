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
  const rel = { theyHaveMe: new Set(), iHaveThem: new Set(), blockedMe: new Set(), iBlocked: new Set(), exceptions: new Map() };
  const ids = userIds.filter((id) => id && id !== viewerId);
  if (!viewerId || ids.length === 0) return rel;
  // "always / never share with" lists the other users made about the viewer
  const exc = await db.many('SELECT owner_id, setting, allow FROM privacy_exceptions WHERE target_id = $1 AND owner_id = ANY($2::bigint[])', [viewerId, ids]);
  for (const e of exc) rel.exceptions.set(`${e.owner_id}:${e.setting}`, e.allow);
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

/** Privacy check with the owner's exceptions ("always share with" / "never share with"). */
function allowedFor(rel, ownerId, key, setting) {
  const e = rel.exceptions ? rel.exceptions.get(`${ownerId}:${key}`) : undefined;
  if (e === true) return true;
  if (e === false) return false;
  return allowedBy(setting, rel.theyHaveMe.has(ownerId));
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
  const r = rel || { theyHaveMe: new Set(), iHaveThem: new Set(), blockedMe: new Set(), iBlocked: new Set(), exceptions: new Map() };
  const blockedMe = r.blockedMe.has(u.id);
  const can = (key, setting) => self || (!blockedMe && allowedFor(r, u.id, key, setting));
  const canSeeSeen = can('last_seen', u.privacy_last_seen);
  const bday = u.birthday && can('birthday', u.privacy_birthday || 'contacts') ? String(u.birthday).split('-').map(Number) : null;

  const out = {
    id: u.id,
    first_name: u.first_name,
    last_name: u.last_name,
    username: u.username,
    bio: can('bio', u.privacy_bio || 'everyone') ? u.bio : '',
    is_verified: u.is_verified,
    is_bot: !!u.is_bot,
    is_premium: !!(u.premium_until && new Date(u.premium_until) > new Date()),
    avatar_url: can('avatar', u.privacy_avatar) ? avatarUrl(u.avatar_media_id) : null,
    phone: can('phone', u.privacy_phone) ? u.phone : null,
    birthday: bday ? { day: bday[2], month: bday[1], ...(self && bday[0] !== 1904 ? { year: bday[0] } : {}) } : null,
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
      calls: u.privacy_calls || 'everyone',
      message_requests: u.message_requests !== false ? 'on' : 'off',
      birthday: u.privacy_birthday || 'contacts',
      read_receipts: u.read_receipts !== false ? 'on' : 'off',
      bio: u.privacy_bio || 'everyone',
      forwards: u.privacy_forwards || 'everyone',
      messages: u.privacy_messages || 'everyone',
      phone_search: u.privacy_phone_search || 'everyone',
    };
    out.security = {
      default_disappear_sec: u.default_disappear_sec || 0,
      account_ttl_days: u.account_ttl_days || 365,
      session_ttl_days: u.session_ttl_days || 180,
      hide_from_search: !!u.hide_from_search,
    };
    out.email = u.email || null;
    out.has_password = !!u.password_hash;
    out.created_at = new Date(u.created_at).toISOString();
    out.premium_until = u.premium_until ? new Date(u.premium_until).toISOString() : null;
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
  const me = serialize(u, userId);
  me.limits = await require('./payment.service').limitsFor(userId); // lazy: avoids circular import
  return me;
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
  if (body.birthday !== undefined) add('birthday', parseBirthday(body.birthday));
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

/** "YYYY-MM-DD" or "MM-DD" (no year → stored as 1904, a leap year) or null. */
function parseBirthday(raw) {
  if (raw === null || raw === '') return null;
  const m = /^(?:(\d{4})-)?(\d{2})-(\d{2})$/.exec(String(raw));
  if (!m) throw badRequest('invalid_input', 'Birthday must look like 1995-08-21 or 08-21');
  const year = m[1] ? Number(m[1]) : 1904;
  const d = new Date(Date.UTC(year, Number(m[2]) - 1, Number(m[3])));
  if (d.getUTCMonth() !== Number(m[2]) - 1 || d.getUTCDate() !== Number(m[3])) throw badRequest('invalid_input', 'That date does not exist');
  if (m[1] && (year < 1900 || d > new Date())) throw badRequest('invalid_input', 'Check the year');
  return d.toISOString().slice(0, 10);
}

const EXCEPTION_SETTINGS = ['last_seen', 'avatar', 'phone', 'group_add', 'calls', 'birthday', 'bio', 'forwards', 'messages'];

/** { setting: { allow: [users], deny: [users] } } */
async function getPrivacyExceptions(userId) {
  const rows = await db.many('SELECT setting, target_id, allow FROM privacy_exceptions WHERE owner_id = $1', [userId]);
  const users = await getUsersMap(userId, [...new Set(rows.map((r) => r.target_id))]);
  const out = {};
  for (const k of EXCEPTION_SETTINGS) out[k] = { allow: [], deny: [] };
  for (const r of rows) {
    const u = users.get(r.target_id);
    if (u && out[r.setting]) out[r.setting][r.allow ? 'allow' : 'deny'].push(u);
  }
  return out;
}

/** Replaces the "always share with" / "never share with" lists of one setting. */
async function setPrivacyExceptions(userId, settingRaw, body = {}) {
  const setting = v.oneOf(settingRaw, EXCEPTION_SETTINGS, 'setting');
  const allow = v.idList(body.allow || [], 'allow', 300).filter((id) => id !== userId);
  const deny = v.idList(body.deny || [], 'deny', 300).filter((id) => id !== userId && !allow.includes(id));
  await db.tx(async (c) => {
    await c.query('DELETE FROM privacy_exceptions WHERE owner_id = $1 AND setting = $2', [userId, setting]);
    for (const [ids, ok] of [[allow, true], [deny, false]]) {
      if (ids.length) {
        await c.query(
          `INSERT INTO privacy_exceptions (owner_id, setting, target_id, allow)
           SELECT $1, $2, x, $3 FROM unnest($4::bigint[]) AS x JOIN users u ON u.id = x ON CONFLICT DO NOTHING`,
          [userId, setting, ok, ids],
        );
      }
    }
  });
  bus.emit('user:updated', { userId });
  return getPrivacyExceptions(userId);
}

/** Contacts whose birthday is today or in the next 7 days (when they share it with me). */
async function upcomingBirthdays(userId) {
  const rows = await db.many(
    `SELECT u.*
     FROM contacts ct JOIN users u ON u.id = ct.contact_id
     WHERE ct.owner_id = $1 AND u.birthday IS NOT NULL AND u.status = 'active'`,
    [userId],
  );
  const rel = await relations(userId, rows.map((r) => r.id));
  const today = new Date();
  const out = [];
  for (const u of rows) {
    if (rel.blockedMe.has(u.id) || !allowedFor(rel, u.id, 'birthday', u.privacy_birthday || 'contacts')) continue;
    const [, bm, bd] = String(u.birthday).split('-').map(Number);
    let next = new Date(Date.UTC(today.getUTCFullYear(), bm - 1, bd));
    const t0 = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
    if (next.getTime() < t0) next = new Date(Date.UTC(today.getUTCFullYear() + 1, bm - 1, bd));
    const days = Math.round((next.getTime() - t0) / 86400000);
    if (days <= 7) out.push({ user: serialize(u, userId, rel), in_days: days });
  }
  return out.sort((a, b) => a.in_days - b.in_days);
}

/** Once a day: "🎂 It's Sara's birthday today" to everyone who saved her and may see her birthday. */
async function sendBirthdayReminders() {
  const run = await db.one(`INSERT INTO job_runs (name, day) VALUES ('birthdays', current_date) ON CONFLICT DO NOTHING RETURNING day`);
  if (!run) return 0;
  const rows = await db.many(
    `SELECT u.id AS user_id, ct.owner_id FROM users u
     JOIN contacts ct ON ct.contact_id = u.id
     LEFT JOIN privacy_exceptions pe ON pe.owner_id = u.id AND pe.setting = 'birthday' AND pe.target_id = ct.owner_id
     WHERE u.status = 'active' AND u.birthday IS NOT NULL
       -- Feb 29 birthdays are remembered on Feb 28 in other years
       AND (to_char(u.birthday, 'MM-DD') = to_char(current_date, 'MM-DD')
            OR (to_char(u.birthday, 'MM-DD') = '02-29' AND to_char(current_date, 'MM-DD') = '02-28'
                AND to_char(current_date + 1, 'MM-DD') = '03-01'))
       AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = u.id AND b.blocked_id = ct.owner_id) OR (b.blocker_id = ct.owner_id AND b.blocked_id = u.id))
       AND (pe.allow IS TRUE OR (pe.allow IS NULL AND (u.privacy_birthday = 'everyone'
             OR (u.privacy_birthday = 'contacts' AND EXISTS (SELECT 1 FROM contacts c2 WHERE c2.owner_id = u.id AND c2.contact_id = ct.owner_id)))))
     LIMIT 50000`,
  );
  if (!rows.length) return 0;
  const users = new Map((await db.many('SELECT * FROM users WHERE id = ANY($1::bigint[])', [[...new Set(rows.map((r) => r.user_id))]])).map((u) => [u.id, u]));
  const push = require('./push.service');
  for (const r of rows) {
    const u = users.get(r.user_id);
    if (!u) continue;
    push
      .sendToUsers(
        [r.owner_id],
        { title: `🎂 ${displayName(u)}'s birthday`, body: 'It’s their birthday today. Send a wish!' },
        { type: 'birthday', user_id: u.id },
        { tag: `bday-${u.id}` },
      )
      .catch(() => {});
  }
  return rows.length;
}

async function updatePrivacy(userId, body) {
  const map = {
    last_seen: 'privacy_last_seen',
    avatar: 'privacy_avatar',
    phone: 'privacy_phone',
    group_add: 'privacy_group_add',
    calls: 'privacy_calls',
    birthday: 'privacy_birthday',
    bio: 'privacy_bio',
    forwards: 'privacy_forwards',
  };
  const sets = [];
  const params = [userId];
  for (const [key, col] of Object.entries(map)) {
    if (body[key] !== undefined) {
      params.push(v.oneOf(body[key], PRIVACY_VALUES, key));
      sets.push(`${col} = $${params.length}`);
    }
  }
  // only two choices for these (like Telegram): everybody or my contacts
  for (const [key, col] of [['messages', 'privacy_messages'], ['phone_search', 'privacy_phone_search']]) {
    if (body[key] !== undefined) {
      params.push(v.oneOf(body[key], ['everyone', 'contacts'], key));
      sets.push(`${col} = $${params.length}`);
    }
  }
  const pick = (key, col, allowed) => {
    if (body[key] === undefined) return;
    const n = Number(body[key]);
    if (!allowed.includes(n)) throw badRequest('invalid_input', `${key} must be one of ${allowed.join(', ')}`);
    params.push(n);
    sets.push(`${col} = $${params.length}`);
  };
  pick('default_disappear_sec', 'default_disappear_sec', [0, 86400, 7 * 86400, 30 * 86400]);
  pick('account_ttl_days', 'account_ttl_days', [30, 90, 180, 365, 730]);
  pick('session_ttl_days', 'session_ttl_days', [7, 30, 90, 180, 365]);
  if (body.hide_from_search !== undefined) {
    params.push(v.bool(body.hide_from_search, 'hide_from_search'));
    sets.push(`hide_from_search = $${params.length}`);
  }
  if (body.message_requests !== undefined) {
    params.push(v.bool(body.message_requests, 'message_requests'));
    sets.push(`message_requests = $${params.length}`);
  }
  if (body.read_receipts !== undefined) {
    params.push(v.bool(body.read_receipts, 'read_receipts'));
    sets.push(`read_receipts = $${params.length}`);
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
      `SELECT id FROM users WHERE phone = $1 AND status = 'active' AND id <> $2 AND privacy_phone <> 'nobody'
         AND (privacy_phone_search = 'everyone' OR EXISTS (SELECT 1 FROM contacts c WHERE c.owner_id = users.id AND c.contact_id = $2))`,
      [phone, viewerId],
    );
  } else {
    const term = escapeLike(q.replace(/^@/, ''));
    if (term.length < 2) return [];
    rows = await db.many(
      `SELECT id FROM users
       WHERE status = 'active' AND id <> $1 AND (
         (lower(username) LIKE lower($2) || '%'
           AND (NOT hide_from_search OR lower(username) = lower($2) OR EXISTS (SELECT 1 FROM contacts c WHERE c.owner_id = users.id AND c.contact_id = $1)))
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
    `SELECT id FROM users WHERE phone = ANY($1::text[]) AND status = 'active' AND id <> $2
       AND (privacy_phone_search = 'everyone' OR EXISTS (SELECT 1 FROM contacts c WHERE c.owner_id = users.id AND c.contact_id = $2))`,
    [normalized, userId],
  );
  const ids = found.map((r) => r.id);
  if (ids.length) {
    await db.query(
      `INSERT INTO contacts (owner_id, contact_id) SELECT $1, x FROM unnest($2::bigint[]) AS x ON CONFLICT DO NOTHING`,
      [userId, ids],
    );
    await require('./chat.service').clearRequestsFrom(userId, ids);
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
  await require('./chat.service').clearRequestsFrom(userId, [id]);
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
      `UPDATE users SET status = 'deleted', phone = 'deleted:' || id::text, email = NULL, username = NULL, password_hash = NULL, password_hint = NULL,
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
            privacy_last_seen, privacy_avatar, privacy_phone, privacy_group_add, privacy_calls
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

/**
 * Scheduler (hourly): logs out devices nobody used for the owner's chosen time, and deletes accounts
 * that were away longer than their "delete my account if away for" setting.
 */
async function sweepInactive() {
  const revoked = await db.many(
    `UPDATE sessions s SET revoked_at = now() FROM users u
     WHERE s.user_id = u.id AND s.revoked_at IS NULL AND s.last_active_at < now() - make_interval(days => u.session_ttl_days)
     RETURNING s.id, s.user_id`,
  );
  const byUser = new Map();
  for (const r of revoked) byUser.set(r.user_id, [...(byUser.get(r.user_id) || []), r.id]);
  for (const [userId, sessionIds] of byUser) bus.emit('sessions:revoked', { userId, sessionIds, reason: 'inactive' });
  const gone = await db.many(
    `SELECT u.id FROM users u
     WHERE u.status = 'active' AND NOT u.is_bot
       AND GREATEST(u.created_at, COALESCE(u.last_seen_at, u.created_at)) < now() - make_interval(days => u.account_ttl_days)
       AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.user_id = u.id AND s.last_active_at > now() - make_interval(days => u.account_ttl_days))
     LIMIT 50`,
  );
  for (const u of gone) await deleteAccount(u.id).catch(() => {});
  return { sessions: revoked.length, accounts: gone.length };
}

module.exports = {
  sweepInactive,
  EXCEPTION_SETTINGS,
  sendBirthdayReminders,
  allowedFor,
  getPrivacyExceptions,
  setPrivacyExceptions,
  upcomingBirthdays,
  parseBirthday,
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
