'use strict';

/** 24-hour stories (photo / video) shared with contacts and chat partners. */
const db = require('../db');
const userService = require('./user.service');
const mediaService = require('./media.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const STORY_HOURS = 24;

/**
 * SQL condition: story alias `s` is visible to viewer parameter `$P`.
 * Visible when: it's mine, or (I saved the author as a contact OR we have a private chat)
 * AND (privacy is everyone OR the author saved me as a contact) AND nobody blocked anybody.
 */
function visibleSql(p) {
  return `(s.deleted_at IS NULL AND s.expires_at > now() AND (
    s.user_id = ${p} OR (
      (EXISTS (SELECT 1 FROM contacts c1 WHERE c1.owner_id = ${p} AND c1.contact_id = s.user_id)
       OR EXISTS (SELECT 1 FROM chats pc WHERE pc.private_key = LEAST(${p}::bigint, s.user_id)::text || ':' || GREATEST(${p}::bigint, s.user_id)::text))
      AND (s.privacy = 'everyone' OR EXISTS (SELECT 1 FROM contacts c2 WHERE c2.owner_id = s.user_id AND c2.contact_id = ${p}))
      AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = s.user_id AND b.blocked_id = ${p})
                                              OR (b.blocker_id = ${p} AND b.blocked_id = s.user_id))
    )))`;
}

function serialize(s, media, { owner = false } = {}) {
  return {
    id: s.id,
    user_id: s.user_id,
    media: mediaService.serialize(media),
    caption: s.caption,
    privacy: s.privacy,
    created_at: new Date(s.created_at).toISOString(),
    expires_at: new Date(s.expires_at).toISOString(),
    viewed: !!s.viewed,
    ...(owner ? { views_count: s.views_count } : {}),
  };
}

async function create(userId, body = {}) {
  rateLimit.enforce(`story:${userId}`, 30, 24 * 3600 * 1000, 'You can post up to 30 stories a day');
  const media = await db.one('SELECT * FROM media WHERE id = $1 AND uploader_id = $2', [v.id(body.media_id, 'media_id'), userId]);
  if (!media) throw notFound('media_not_found', 'Upload the photo or video first');
  if (!['image', 'video'].includes(media.kind)) throw badRequest('invalid_media', 'Stories can be photos or videos');
  const caption = v.str(body.caption, { field: 'caption', max: 500 }) || '';
  const privacy = v.oneOf(body.privacy || 'contacts', ['everyone', 'contacts'], 'privacy');
  const s = await db.one(
    `INSERT INTO stories (user_id, media_id, caption, privacy, expires_at)
     VALUES ($1, $2, $3, $4, now() + make_interval(hours => $5)) RETURNING *`,
    [userId, media.id, caption, privacy, STORY_HOURS],
  );
  return serialize(s, media, { owner: true });
}

/** Stories grouped by author: me first, then authors with unseen stories, newest first. */
async function feed(userId) {
  const rows = await db.many(
    `SELECT s.*, EXISTS (SELECT 1 FROM story_views sv WHERE sv.story_id = s.id AND sv.viewer_id = $1) AS viewed
     FROM stories s WHERE ${visibleSql('$1')}
     ORDER BY s.user_id, s.id`,
    [userId],
  );
  if (!rows.length) return [];
  const medias = await db.many('SELECT * FROM media WHERE id = ANY($1::bigint[])', [rows.map((r) => r.media_id)]);
  const mediaMap = new Map(medias.map((m) => [m.id, m]));
  const users = await userService.getUsersMap(userId, [...new Set(rows.map((r) => r.user_id))]);
  const groups = new Map();
  for (const s of rows) {
    if (!groups.has(s.user_id)) groups.set(s.user_id, []);
    groups.get(s.user_id).push(serialize(s, mediaMap.get(s.media_id), { owner: s.user_id === userId }));
  }
  const out = [...groups.entries()]
    .filter(([uid]) => users.has(uid))
    .map(([uid, stories]) => ({
      user: users.get(uid),
      stories,
      has_unseen: uid !== userId && stories.some((x) => !x.viewed),
      latest: stories[stories.length - 1].created_at,
    }));
  out.sort((a, b) => {
    if (a.user.id === userId) return -1;
    if (b.user.id === userId) return 1;
    if (a.has_unseen !== b.has_unseen) return a.has_unseen ? -1 : 1;
    return b.latest.localeCompare(a.latest);
  });
  return out;
}

async function requireVisible(userId, storyIdRaw) {
  const s = await db.one(`SELECT s.* FROM stories s WHERE s.id = $2 AND ${visibleSql('$1')}`, [userId, v.id(storyIdRaw, 'story_id')]);
  if (!s) throw notFound('story_not_found', 'This story is no longer available');
  return s;
}

async function view(userId, storyIdRaw, body = {}) {
  const s = await requireVisible(userId, storyIdRaw);
  if (s.user_id === userId) return { ok: true };
  const emoji = body.emoji ? v.str(String(body.emoji), { field: 'emoji', max: 16 }) : null;
  const r = await db.one(
    `INSERT INTO story_views (story_id, viewer_id, emoji) VALUES ($1, $2, $3)
     ON CONFLICT (story_id, viewer_id) DO UPDATE SET emoji = COALESCE(EXCLUDED.emoji, story_views.emoji)
     RETURNING (xmax = 0) AS inserted`,
    [s.id, userId, emoji],
  );
  if (r && r.inserted) await db.query('UPDATE stories SET views_count = views_count + 1 WHERE id = $1', [s.id]);
  return { ok: true };
}

async function viewers(userId, storyIdRaw) {
  const s = await db.one('SELECT * FROM stories WHERE id = $1 AND user_id = $2', [v.id(storyIdRaw, 'story_id'), userId]);
  if (!s) throw notFound('story_not_found', 'Story not found');
  const rows = await db.many('SELECT viewer_id, emoji, viewed_at FROM story_views WHERE story_id = $1 ORDER BY viewed_at DESC LIMIT 500', [s.id]);
  const users = await userService.getUsersMap(userId, rows.map((r) => r.viewer_id));
  return rows
    .filter((r) => users.has(r.viewer_id))
    .map((r) => ({ user: users.get(r.viewer_id), emoji: r.emoji, viewed_at: new Date(r.viewed_at).toISOString() }));
}

async function remove(userId, storyIdRaw) {
  const r = await db.one(
    'UPDATE stories SET deleted_at = now() WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL RETURNING id',
    [v.id(storyIdRaw, 'story_id'), userId],
  );
  if (!r) throw notFound('story_not_found', 'Story not found');
  return { ok: true };
}

/** Replying to a story sends a private message to its author. */
async function reply(userId, storyIdRaw, body = {}) {
  const s = await requireVisible(userId, storyIdRaw);
  if (s.user_id === userId) throw forbidden('not_allowed', 'You can’t reply to your own story');
  const chatService = require('./chat.service'); // lazy to avoid circular imports
  const messageService = require('./message.service');
  const chat = await chatService.getOrCreatePrivate(userId, s.user_id);
  return messageService.sendMessage(userId, chat.id, { type: 'text', text: body.text }, { meta: { story_reply: s.id } });
}

module.exports = { STORY_HOURS, visibleSql, create, feed, view, viewers, remove, reply };
