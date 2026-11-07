'use strict';

/**
 * Admin panel — full control of groups & channels (settings, Group Guard, admins, removed
 * people, admin log, notices, invite links) and of content (sticker packs, stories, media).
 * Every action is written to the admin activity log.
 */

const fs = require('fs');
const path = require('path');
const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const v = require('../utils/validate');
const { randomToken } = require('../utils/crypto');
const { badRequest, notFound, forbidden } = require('../utils/errors');

const chatService = () => require('./chat.service'); // eslint-disable-line global-require
const messageService = () => require('./message.service'); // eslint-disable-line global-require

async function log(adminId, action, targetType, targetId, details, ip) {
  await db.query(
    'INSERT INTO admin_logs (admin_id, action, target_type, target_id, details, ip) VALUES ($1, $2, $3, $4, $5, $6)',
    [adminId, action, targetType || null, targetId || null, details ? JSON.stringify(details) : null, ip || null],
  );
}

async function requireChat(chatIdRaw) {
  const c = await db.one("SELECT * FROM chats WHERE id = $1 AND type IN ('group', 'channel')", [v.id(chatIdRaw, 'chat_id')]);
  if (!c) throw notFound('chat_not_found', 'Group not found');
  return c;
}

async function emitUpdated(chatId) {
  const ids = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId])).map((r) => r.user_id);
  bus.emit('chat:updated', { chatId, memberIds: ids });
}

function userJson(r) {
  if (!r) return null;
  return { id: Number(r.id), name: `${r.first_name || ''} ${r.last_name || ''}`.trim() || 'User', username: r.username || null };
}

// ------------------------------------------------------------------ group / channel
const BOOL_SETTINGS = ['join_captcha', 'anti_flood', 'anti_links', 'anti_forward', 'anti_mentions', 'raid_shield', 'hide_service',
  'join_approval', 'protected_content', 'new_member_limits', 'signatures', 'comments_enabled'];
const GROUP_ONLY = ['join_captcha', 'anti_flood', 'anti_links', 'anti_forward', 'anti_mentions', 'raid_shield', 'hide_service', 'new_member_limits'];
const SLOW_MODES = [0, 10, 30, 60, 300, 900, 3600];

/** Everything about one group/channel: settings, counts, invite link, removed people, admin log. */
async function groupDetail(chatIdRaw) {
  const c = await requireChat(chatIdRaw);
  const counts = await db.one(
    `SELECT (SELECT count(*)::int FROM chat_members WHERE chat_id = $1) AS members,
            (SELECT count(*)::int FROM chat_members WHERE chat_id = $1 AND role IN ('owner', 'admin')) AS admins,
            (SELECT count(*)::int FROM messages WHERE chat_id = $1 AND deleted_at IS NULL) AS messages,
            (SELECT count(*)::int FROM chat_join_requests WHERE chat_id = $1) AS requests,
            (SELECT count(*)::int FROM messages WHERE chat_id = $1 AND created_at > now() - interval '1 day') AS messages_today`,
    [c.id],
  );
  const bans = await db.many(
    `SELECT b.user_id, b.reason, b.created_at, u.first_name, u.last_name, u.username,
            bu.id AS by_id, bu.first_name AS by_first, bu.last_name AS by_last, bu.username AS by_username
     FROM chat_bans b JOIN users u ON u.id = b.user_id LEFT JOIN users bu ON bu.id = b.banned_by
     WHERE b.chat_id = $1 ORDER BY b.created_at DESC LIMIT 200`,
    [c.id],
  );
  const events = await db.many(
    `SELECT e.id, e.action, e.details, e.created_at, a.id AS a_id, a.first_name AS a_first, a.last_name AS a_last, a.username AS a_username,
            t.id AS t_id, t.first_name AS t_first, t.last_name AS t_last, t.username AS t_username
     FROM chat_events e LEFT JOIN users a ON a.id = e.actor_id LEFT JOIN users t ON t.id = e.target_id
     WHERE e.chat_id = $1 ORDER BY e.id DESC LIMIT 100`,
    [c.id],
  );
  const settings = {};
  for (const k of BOOL_SETTINGS) settings[k] = !!c[k];
  settings.slow_mode_sec = c.slow_mode_sec || 0;
  settings.guard_penalty = c.guard_penalty || 'none';
  settings.banned_words = c.banned_words || [];
  return {
    id: Number(c.id),
    type: c.type,
    title: c.title,
    username: c.username,
    invite_code: c.invite_code,
    is_suspended: !!c.is_suspended,
    is_verified: !!c.is_verified,
    created_at: new Date(c.created_at).toISOString(),
    counts,
    settings,
    banned: bans.map((b) => ({
      user: userJson({ id: b.user_id, first_name: b.first_name, last_name: b.last_name, username: b.username }),
      by: b.by_id ? userJson({ id: b.by_id, first_name: b.by_first, last_name: b.by_last, username: b.by_username }) : null,
      reason: b.reason,
      created_at: new Date(b.created_at).toISOString(),
    })),
    events: events.map((e) => ({
      id: Number(e.id),
      action: e.action,
      details: e.details || null,
      actor: e.a_id ? userJson({ id: e.a_id, first_name: e.a_first, last_name: e.a_last, username: e.a_username }) : null,
      target: e.t_id ? userJson({ id: e.t_id, first_name: e.t_first, last_name: e.t_last, username: e.t_username }) : null,
      created_at: new Date(e.created_at).toISOString(),
    })),
  };
}

/** Changes protection / Group Guard / posting settings of any group or channel. */
async function setGroupSettings(admin, chatIdRaw, body = {}, ip) {
  const c = await requireChat(chatIdRaw);
  const sets = [];
  const params = [c.id];
  const add = (col, val) => {
    params.push(val);
    sets.push(`${col} = $${params.length}`);
  };
  for (const k of BOOL_SETTINGS) {
    if (body[k] === undefined) continue;
    if (GROUP_ONLY.includes(k) && c.type !== 'group') throw badRequest('invalid_input', `${k} is for groups`);
    if (['signatures', 'comments_enabled'].includes(k) && c.type !== 'channel') throw badRequest('invalid_input', `${k} is for channels`);
    add(k, v.bool(body[k], k));
  }
  if (body.slow_mode_sec !== undefined) {
    const n = Number(body.slow_mode_sec);
    if (!SLOW_MODES.includes(n)) throw badRequest('invalid_input', 'Slow mode: 0, 10, 30, 60, 300, 900 or 3600 seconds');
    add('slow_mode_sec', n);
  }
  if (body.guard_penalty !== undefined) add('guard_penalty', v.oneOf(body.guard_penalty, ['none', 'mute', 'remove'], 'guard_penalty'));
  if (body.banned_words !== undefined) {
    if (!Array.isArray(body.banned_words) || body.banned_words.length > 200) throw badRequest('invalid_input', 'banned_words: up to 200 words');
    add('banned_words', JSON.stringify([...new Set(body.banned_words.map((w) => String(w).trim().toLowerCase()).filter((w) => w.length >= 2 && w.length <= 40))]));
  }
  if (!sets.length) return { ok: true };
  await db.query(`UPDATE chats SET ${sets.join(', ')} WHERE id = $1`, params);
  if (body.join_approval === false) await db.query('DELETE FROM chat_join_requests WHERE chat_id = $1', [c.id]);
  await emitUpdated(c.id);
  await log(admin.id, 'group.settings', 'chat', c.id, body, ip);
  return { ok: true };
}

/** Makes a member an admin (all rights) or a plain member again. */
async function setGroupRole(admin, chatIdRaw, userIdRaw, roleRaw, ip) {
  const c = await requireChat(chatIdRaw);
  const userId = v.id(userIdRaw, 'user_id');
  const role = v.oneOf(roleRaw, ['admin', 'member'], 'role');
  const m = await db.one('SELECT role FROM chat_members WHERE chat_id = $1 AND user_id = $2', [c.id, userId]);
  if (!m) throw notFound('member_not_found', 'Not a member');
  if (m.role === 'owner') throw forbidden('no_rights', 'The owner’s role can’t be changed — transfer ownership instead');
  await db.query(
    "UPDATE chat_members SET role = $3, admin_rights = NULL, admin_title = NULL, promoted_by = NULL WHERE chat_id = $1 AND user_id = $2",
    [c.id, userId, role],
  );
  await chatService().logEvent(c.id, null, role === 'admin' ? 'admin_set' : 'admin_removed', userId, { by: 'Hushavia team' });
  await require('./notice.service').notify(userId, 'admin', // eslint-disable-line global-require
    role === 'admin' ? `You are now an admin in ${c.title}` : `You are no longer an admin in ${c.title}`,
    'Changed by the Hushavia team.', { chat_id: Number(c.id) }).catch(() => {});
  await emitUpdated(c.id);
  await log(admin.id, role === 'admin' ? 'group.admin_set' : 'group.admin_removed', 'chat', c.id, { user_id: userId }, ip);
  return { ok: true };
}

async function unbanGroupMember(admin, chatIdRaw, userIdRaw, ip) {
  const c = await requireChat(chatIdRaw);
  const userId = v.id(userIdRaw, 'user_id');
  const r = await db.one('DELETE FROM chat_bans WHERE chat_id = $1 AND user_id = $2 RETURNING user_id', [c.id, userId]);
  if (!r) throw notFound('not_banned', 'This person isn’t removed from here');
  await chatService().logEvent(c.id, null, 'member_unbanned', userId, { by: 'Hushavia team' });
  await log(admin.id, 'group.unban', 'chat', c.id, { user_id: userId }, ip);
  return { ok: true };
}

/** New invite link — the old one stops working (leaked link, spam raids). */
async function resetInvite(admin, chatIdRaw, ip) {
  const c = await requireChat(chatIdRaw);
  const code = randomToken(12);
  await db.query('UPDATE chats SET invite_code = $2 WHERE id = $1', [c.id, code]);
  await db.query('UPDATE chat_invites SET revoked = TRUE WHERE chat_id = $1', [c.id]);
  await emitUpdated(c.id);
  await log(admin.id, 'group.invite_reset', 'chat', c.id, null, ip);
  return { invite_code: code };
}

/** A notice from the Hushavia team inside a group/channel (shown as a service message). */
async function postNotice(admin, chatIdRaw, body = {}, ip) {
  const c = await requireChat(chatIdRaw);
  const text = v.str(body.text, { field: 'text', min: 1, max: 1000 });
  await messageService().createSystemMessage(c.id, null, { event: 'team_notice', text });
  await log(admin.id, 'group.notice', 'chat', c.id, { text }, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ users
/** A notification in the user's app (bell) from the Hushavia team. */
async function noticeUser(admin, userIdRaw, body = {}, ip) {
  const userId = v.id(userIdRaw, 'user_id');
  const u = await db.one('SELECT id FROM users WHERE id = $1', [userId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  const title = v.str(body.title, { field: 'title', min: 1, max: 120 });
  const text = v.str(body.text, { field: 'text', max: 500 }) || '';
  await require('./notice.service').notify(userId, 'system', title, text); // eslint-disable-line global-require
  await log(admin.id, 'user.notice', 'user', userId, { title }, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ sticker packs
async function listStickerPacks(query = {}) {
  const q = String(query.q || '').trim().slice(0, 64);
  const rows = await db.many(
    `SELECT p.*, u.first_name, u.last_name, u.username,
            (SELECT count(*)::int FROM stickers s WHERE s.pack_id = p.id) AS sticker_count,
            (SELECT s.media_id FROM stickers s WHERE s.pack_id = p.id ORDER BY s.id LIMIT 1) AS cover_media_id
     FROM sticker_packs p LEFT JOIN users u ON u.id = p.owner_id
     WHERE ($1 = '' OR p.title ILIKE '%' || $1 || '%' OR p.slug ILIKE '%' || $1 || '%')
     ORDER BY p.is_official DESC, p.installs DESC, p.id DESC LIMIT 200`,
    [q],
  );
  return rows.map((p) => ({
    id: Number(p.id),
    title: p.title,
    slug: p.slug,
    official: !!p.is_official,
    public: !!p.is_public,
    premium: !!p.is_premium,
    disabled: !!p.is_disabled,
    installs: p.installs,
    stickers: p.sticker_count,
    cover_url: p.cover_media_id ? `/api/media/${p.cover_media_id}/public` : null,
    owner: p.owner_id ? userJson({ id: p.owner_id, first_name: p.first_name, last_name: p.last_name, username: p.username }) : null,
    created_at: new Date(p.created_at).toISOString(),
  }));
}

async function updateStickerPack(admin, idRaw, body = {}, ip) {
  const id = v.id(idRaw, 'pack_id');
  const p = await db.one('SELECT id FROM sticker_packs WHERE id = $1', [id]);
  if (!p) throw notFound('pack_not_found', 'Sticker pack not found');
  if (body.disabled !== undefined) await db.query('UPDATE sticker_packs SET is_disabled = $2 WHERE id = $1', [id, v.bool(body.disabled, 'disabled')]);
  if (body.premium !== undefined) {
    await db.query('UPDATE sticker_packs SET is_premium = $2, premium_by_admin = TRUE WHERE id = $1', [id, v.bool(body.premium, 'premium')]);
  }
  if (body.title !== undefined) await db.query('UPDATE sticker_packs SET title = $2 WHERE id = $1', [id, v.str(body.title, { field: 'title', min: 1, max: 64 })]);
  await log(admin.id, 'stickers.edit', 'sticker_pack', id, body, ip);
  return { ok: true };
}

async function deleteStickerPack(admin, idRaw, ip) {
  const id = v.id(idRaw, 'pack_id');
  const p = await db.one('SELECT id, title, is_official FROM sticker_packs WHERE id = $1', [id]);
  if (!p) throw notFound('pack_not_found', 'Sticker pack not found');
  if (p.is_official) throw forbidden('official_pack', 'Official packs come back on restart — switch it off instead');
  await db.query('DELETE FROM sticker_packs WHERE id = $1', [id]);
  await log(admin.id, 'stickers.delete', 'sticker_pack', id, { title: p.title }, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ stories
async function listStories(query = {}) {
  const active = query.status !== 'all';
  const rows = await db.many(
    `SELECT s.id, s.caption, s.privacy, s.views_count, s.created_at, s.expires_at, s.deleted_at, s.media_id,
            m.kind, m.mime, u.id AS user_id, u.first_name, u.last_name, u.username
     FROM stories s JOIN users u ON u.id = s.user_id JOIN media m ON m.id = s.media_id
     WHERE ${active ? 's.deleted_at IS NULL AND s.expires_at > now()' : 'TRUE'}
     ORDER BY s.id DESC LIMIT 200`,
  );
  return rows.map((s) => ({
    id: Number(s.id),
    caption: s.caption,
    privacy: s.privacy,
    views: s.views_count,
    kind: s.kind,
    media_id: Number(s.media_id),
    user: userJson({ id: s.user_id, first_name: s.first_name, last_name: s.last_name, username: s.username }),
    created_at: new Date(s.created_at).toISOString(),
    expires_at: new Date(s.expires_at).toISOString(),
    deleted: !!s.deleted_at,
  }));
}

async function deleteStory(admin, idRaw, ip) {
  const id = v.id(idRaw, 'story_id');
  const s = await db.one('UPDATE stories SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING user_id', [id]);
  if (!s) throw notFound('story_not_found', 'Story not found');
  await log(admin.id, 'story.delete', 'story', id, { user_id: Number(s.user_id) }, ip);
  return { ok: true };
}

// ------------------------------------------------------------------ media
async function listMedia(query = {}) {
  const kind = ['image', 'video', 'voice', 'file', 'avatar', 'sticker'].includes(query.kind) ? query.kind : null;
  const limit = v.limit(query.limit, 60, 200);
  const before = query.before ? v.id(query.before, 'before') : null;
  const params = [limit];
  const where = [];
  if (kind) {
    params.push(kind);
    where.push(`m.kind = $${params.length}`);
  }
  if (before) {
    params.push(before);
    where.push(`m.id < $${params.length}`);
  }
  if (query.user_id) {
    params.push(v.id(query.user_id, 'user_id'));
    where.push(`m.uploader_id = $${params.length}`);
  }
  const rows = await db.many(
    `SELECT m.id, m.kind, m.mime, m.size_bytes, m.original_name, m.width, m.height, m.duration_sec, m.created_at, m.thumb,
            u.id AS user_id, u.first_name, u.last_name, u.username,
            (SELECT count(*)::int FROM messages x WHERE x.media_id = m.id AND x.deleted_at IS NULL) AS in_messages
     FROM media m LEFT JOIN users u ON u.id = m.uploader_id
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY m.id DESC LIMIT $1`,
    params,
  );
  return rows.map((m) => ({
    id: Number(m.id),
    kind: m.kind,
    mime: m.mime,
    size: Number(m.size_bytes),
    name: m.original_name,
    width: m.width,
    height: m.height,
    duration: m.duration_sec,
    thumb: m.thumb || null,
    in_messages: m.in_messages,
    user: m.user_id ? userJson({ id: m.user_id, first_name: m.first_name, last_name: m.last_name, username: m.username }) : null,
    created_at: new Date(m.created_at).toISOString(),
  }));
}

/**
 * Removes a file everywhere (illegal or abusive content): the messages that carry it are deleted
 * for everyone, profile photos and stories using it go, and the file is erased from the disk.
 */
async function deleteMedia(admin, idRaw, ip) {
  const id = v.id(idRaw, 'media_id');
  const m = await db.one('SELECT * FROM media WHERE id = $1', [id]);
  if (!m) throw notFound('media_not_found', 'File not found');
  const msgs = await db.many("UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL WHERE media_id = $1 AND deleted_at IS NULL RETURNING id, chat_id", [id]);
  const byChat = new Map();
  for (const r of msgs) {
    if (!byChat.has(r.chat_id)) byChat.set(r.chat_id, []);
    byChat.get(r.chat_id).push(r.id);
  }
  for (const [chatId, ids] of byChat) {
    const members = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId])).map((r) => r.user_id);
    bus.emit('message:deleted', { chatId, messageIds: ids, userIds: members });
  }
  const users = await db.many('UPDATE users SET avatar_media_id = NULL WHERE avatar_media_id = $1 RETURNING id', [id]);
  for (const u of users) bus.emit('user:updated', { userId: u.id });
  await db.query('UPDATE chats SET avatar_media_id = NULL WHERE avatar_media_id = $1', [id]);
  await db.query('UPDATE stories SET deleted_at = now() WHERE media_id = $1 AND deleted_at IS NULL', [id]);
  await db.query('DELETE FROM stickers WHERE media_id = $1', [id]).catch(() => {});
  // the file and its previews
  const abs = path.resolve(config.uploadDir, m.storage_path);
  if (abs.startsWith(config.uploadDir + path.sep)) {
    for (const f of [abs, `${abs}.p.webp`, `${abs}.s.webp`]) fs.unlink(f, () => {});
  }
  await db.query('UPDATE media SET thumb = NULL, thumb_failed = TRUE, size_bytes = 0 WHERE id = $1', [id]);
  await log(admin.id, 'media.delete', 'media', id, { kind: m.kind, messages: msgs.length, uploader_id: m.uploader_id }, ip);
  return { ok: true, messages_deleted: msgs.length };
}


// ------------------------------------------------------------------ system health
function dirSize(dir) {
  let total = 0;
  try {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) total += dirSize(p);
      else if (e.isFile()) total += fs.statSync(p).size;
    }
  } catch (_) { /* unreadable */ }
  return total;
}

/** Server health and the switches that matter before launch. */
async function systemStatus() {
  const os = require('os'); // eslint-disable-line global-require
  const images = require('../utils/images'); // eslint-disable-line global-require
  let disk = null;
  try {
    const st = fs.statfsSync(config.uploadDir);
    disk = { free: st.bavail * st.bsize, total: st.blocks * st.bsize };
  } catch (_) { /* old node */ }
  const dbSize = await db.one('SELECT pg_database_size(current_database())::bigint AS n').catch(() => ({ n: null }));
  const media = await db.one('SELECT count(*)::int AS files, COALESCE(sum(size_bytes), 0)::bigint AS bytes FROM media');
  let latest = null;
  try {
    latest = JSON.parse(fs.readFileSync(path.join(config.downloadDir, 'latest.json'), 'utf8'));
  } catch (_) { /* no build uploaded yet */ }
  const presence = require('./presence'); // eslint-disable-line global-require
  const mail = config.mail.provider;
  const mailReady = mail === 'brevo' ? !!config.mail.brevoKey : mail === 'resend' ? !!config.mail.resendKey : mail === 'smtp' ? !!config.mail.smtpHost : false;
  return {
    node: process.version,
    uptime_sec: Math.round(process.uptime()),
    memory: { rss: process.memoryUsage().rss, total: os.totalmem(), free: os.freemem() },
    load: os.loadavg(),
    cpus: os.cpus().length,
    disk,
    db_bytes: dbSize.n ? Number(dbSize.n) : null,
    media: { files: media.files, bytes: Number(media.bytes) },
    downloads_bytes: dirSize(config.downloadDir),
    online_users: presence.onlineCount(),
    tools: { sharp: images.available(), ffmpeg: images.hasFfmpeg() },
    mail: { provider: mail, ready: mailReady, from: config.mail.from },
    otp_dev_mode: !!config.otp.devMode,
    push_ready: !!config.firebaseServiceAccountPath && fs.existsSync(config.firebaseServiceAccountPath),
    latest_app: latest ? {
      build: latest.build,
      version: `1.1.${latest.build}`,
      published_at: latest.published_at || null,
      files: Object.entries(latest.files || {}).map(([name, f]) => ({ name, url: `/download/${f.file}`, size: f.size })),
    } : null,
  };
}

// ------------------------------------------------------------------ message search (groups & channels only)
/** Finds messages in groups and channels (private chats stay private). */
async function searchMessages(query = {}) {
  const q = String(query.q || '').trim();
  const userId = query.user_id ? v.id(query.user_id, 'user_id') : null;
  const chatId = query.chat_id ? v.id(query.chat_id, 'chat_id') : null;
  if (q.length < 2 && !userId && !chatId) throw badRequest('invalid_input', 'Type at least 2 letters, or pick a user or group');
  const params = [];
  const where = ["c.type IN ('group', 'channel')", 'm.deleted_at IS NULL', "m.type NOT IN ('system', 'call')"];
  if (q.length >= 2) {
    params.push(`%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`);
    where.push(`m.text ILIKE $${params.length}`);
  }
  if (userId) {
    params.push(userId);
    where.push(`m.sender_id = $${params.length}`);
  }
  if (chatId) {
    params.push(chatId);
    where.push(`m.chat_id = $${params.length}`);
  }
  if (query.before) {
    params.push(v.id(query.before, 'before'));
    where.push(`m.id < $${params.length}`);
  }
  const rows = await db.many(
    `SELECT m.id, m.chat_id, m.type, m.text, m.created_at, m.media_id, c.title, c.type AS chat_type,
            u.id AS user_id, u.first_name, u.last_name, u.username
     FROM messages m JOIN chats c ON c.id = m.chat_id LEFT JOIN users u ON u.id = m.sender_id
     WHERE ${where.join(' AND ')} ORDER BY m.id DESC LIMIT 100`,
    params,
  );
  return rows.map((m) => ({
    id: Number(m.id),
    chat: { id: Number(m.chat_id), title: m.title, type: m.chat_type },
    type: m.type,
    text: m.text || '',
    media_id: m.media_id ? Number(m.media_id) : null,
    user: m.user_id ? userJson({ id: m.user_id, first_name: m.first_name, last_name: m.last_name, username: m.username }) : null,
    created_at: new Date(m.created_at).toISOString(),
  }));
}

// ------------------------------------------------------------------ one user: groups, spam clean-up
async function userChats(userIdRaw) {
  const userId = v.id(userIdRaw, 'user_id');
  const rows = await db.many(
    `SELECT c.id, c.title, c.type, c.username, cm.role, cm.joined_at,
            (SELECT count(*)::int FROM chat_members x WHERE x.chat_id = c.id) AS members,
            (SELECT count(*)::int FROM messages m WHERE m.chat_id = c.id AND m.sender_id = $1 AND m.deleted_at IS NULL) AS sent
     FROM chat_members cm JOIN chats c ON c.id = cm.chat_id
     WHERE cm.user_id = $1 AND c.type IN ('group', 'channel') ORDER BY cm.joined_at DESC LIMIT 500`,
    [userId],
  );
  return rows.map((r) => ({
    id: Number(r.id), title: r.title, type: r.type, username: r.username, role: r.role,
    members: r.members, sent: r.sent, joined_at: new Date(r.joined_at).toISOString(),
  }));
}

/**
 * Spam clean-up: deletes everything a user wrote in groups and channels (for everyone),
 * and with remove_from_groups also takes them out of every group (where they aren't the owner).
 */
async function purgeUser(admin, userIdRaw, body = {}, ip) {
  const userId = v.id(userIdRaw, 'user_id');
  const u = await db.one('SELECT id FROM users WHERE id = $1', [userId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  const msgs = await db.many(
    `UPDATE messages m SET deleted_at = now(), text = '', media_id = NULL, meta = NULL
     FROM chats c WHERE c.id = m.chat_id AND c.type IN ('group', 'channel') AND m.sender_id = $1 AND m.deleted_at IS NULL
     RETURNING m.id, m.chat_id`,
    [userId],
  );
  const byChat = new Map();
  for (const r of msgs) {
    if (!byChat.has(r.chat_id)) byChat.set(r.chat_id, []);
    byChat.get(r.chat_id).push(r.id);
  }
  for (const [chatId, ids] of byChat) {
    const members = (await db.many('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId])).map((r) => r.user_id);
    bus.emit('message:deleted', { chatId, messageIds: ids, userIds: members });
  }
  let removed = 0;
  if (body.remove_from_groups === true) {
    const chats = await db.many(
      `SELECT cm.chat_id FROM chat_members cm JOIN chats c ON c.id = cm.chat_id
       WHERE cm.user_id = $1 AND c.type IN ('group', 'channel') AND cm.role <> 'owner'`,
      [userId],
    );
    for (const c of chats) {
      await chatService().removeUserFromGroup(c.chat_id, userId, { reason: 'removed' });
      await chatService().ban(c.chat_id, userId, null, 'admin_panel');
      removed += 1;
    }
  }
  await log(admin.id, 'user.purge', 'user', userId, { messages: msgs.length, removed_from: removed }, ip);
  return { ok: true, messages_deleted: msgs.length, removed_from: removed };
}

// ------------------------------------------------------------------ bots
const SYSTEM_BOTS = ['botforge', 'hushaviaidbot', 'hushaviasupportbot', 'hushaviaspambot', 'hushaviacodes', 'hushaviabuttonsbot'];

async function botDetail(botIdRaw) {
  const id = v.id(botIdRaw, 'bot_id');
  const b = await db.one(
    `SELECT b.*, u.username, u.first_name, u.bio, u.created_at AS user_created_at, u.status AS user_status,
            o.id AS o_id, o.first_name AS o_first, o.last_name AS o_last, o.username AS o_username,
            (SELECT count(*)::int FROM chat_members cm WHERE cm.user_id = b.user_id) AS chats,
            (SELECT count(*)::int FROM chat_members cm JOIN chats c ON c.id = cm.chat_id WHERE cm.user_id = b.user_id AND c.type = 'private') AS users,
            (SELECT count(*)::int FROM messages m WHERE m.sender_id = b.user_id AND m.created_at > now() - interval '1 day') AS sent_today,
            (SELECT count(*)::int FROM bot_updates x WHERE x.bot_id = b.user_id) AS pending
     FROM bots b JOIN users u ON u.id = b.user_id LEFT JOIN users o ON o.id = b.owner_id WHERE b.user_id = $1`,
    [id],
  );
  if (!b) throw notFound('bot_not_found', 'Bot not found');
  return {
    id: Number(b.user_id),
    username: b.username,
    name: b.first_name,
    about: b.bio || '',
    status: b.status,
    deleted: b.user_status === 'deleted',
    disabled_reason: b.disabled_reason || null,
    webhook: b.webhook_url ? b.webhook_url.replace(/\/\/([^/@]*@)/, '//***@') : null,
    system: SYSTEM_BOTS.includes(String(b.username || '').toLowerCase()),
    owner: b.o_id ? userJson({ id: b.o_id, first_name: b.o_first, last_name: b.o_last, username: b.o_username }) : null,
    chats: b.chats,
    users: b.users,
    sent_today: b.sent_today,
    pending_updates: b.pending,
    created_at: new Date(b.user_created_at).toISOString(),
  };
}

async function deleteBotAdmin(admin, botIdRaw, ip) {
  const d = await botDetail(botIdRaw);
  if (d.system) throw forbidden('system_bot', 'Hushavia’s own bots can’t be deleted — switch it off instead');
  if (d.deleted) return { ok: true };
  await db.tx(async (c) => {
    await c.query("UPDATE users SET status = 'deleted', username = NULL, first_name = 'Deleted Bot', updated_at = now() WHERE id = $1", [d.id]);
    await c.query("UPDATE bots SET status = 'disabled', token_hash = $2, webhook_url = NULL WHERE user_id = $1", [d.id, require('crypto').randomBytes(32).toString('hex')]); // eslint-disable-line global-require
    await c.query('DELETE FROM bot_updates WHERE bot_id = $1', [d.id]);
  });
  if (d.owner) {
    await require('./notice.service').notify(d.owner.id, 'system', `Your bot @${d.username} was removed`, // eslint-disable-line global-require
      'The Hushavia team removed it for breaking the rules.').catch(() => {});
  }
  await log(admin.id, 'bot.delete', 'user', d.id, { username: d.username }, ip);
  return { ok: true };
}

module.exports = {
  systemStatus,
  searchMessages,
  userChats,
  purgeUser,
  botDetail,
  deleteBotAdmin,
  groupDetail,
  setGroupSettings,
  setGroupRole,
  unbanGroupMember,
  resetInvite,
  postNotice,
  noticeUser,
  listStickerPacks,
  updateStickerPack,
  deleteStickerPack,
  listStories,
  deleteStory,
  listMedia,
  deleteMedia,
};
