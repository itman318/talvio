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

/** SQL condition: a highlighted (possibly expired) story `s` may be seen by viewer `$P` on the author's profile. */
function highlightVisibleSql(p) {
  return `(s.deleted_at IS NULL AND (
    s.user_id = ${p} OR (
      (s.privacy = 'everyone' OR EXISTS (SELECT 1 FROM contacts c2 WHERE c2.owner_id = s.user_id AND c2.contact_id = ${p}))
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
  await require('./settings.service').requireFeature('feature_stories', 'Stories');
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

const STORY_REACTIONS = ['❤️', '😂', '😮', '😢', '👏', '🔥', '😍', '🎉'];

/** What a reply / reaction message shows about the story (a small preview). */
async function storyRef(s, reaction) {
  const media = await db.one('SELECT * FROM media WHERE id = $1', [s.media_id]);
  return {
    id: s.id,
    owner_id: s.user_id,
    kind: media ? media.kind : 'image',
    media: media ? mediaService.serialize(media) : null,
    caption: (s.caption || '').slice(0, 80),
    ...(reaction ? { reaction } : {}),
  };
}

async function sendToAuthor(userId, s, text, reaction) {
  const chatService = require('./chat.service'); // lazy to avoid circular imports
  const messageService = require('./message.service');
  const chat = await chatService.getOrCreatePrivate(userId, s.user_id);
  return messageService.sendMessage(userId, chat.id, { type: 'text', text }, { meta: { story_reply: s.id, story: await storyRef(s, reaction) } });
}

/** Replying to a story sends a private message to its author. */
async function reply(userId, storyIdRaw, body = {}) {
  const s = await requireVisible(userId, storyIdRaw);
  if (s.user_id === userId) throw forbidden('not_allowed', 'You can’t reply to your own story');
  return sendToAuthor(userId, s, body.text, null);
}

/** Quick reaction: marks the story with the emoji and sends it to the author's chat ("Reacted to your story"). */
async function react(userId, storyIdRaw, body = {}) {
  const s = await requireVisible(userId, storyIdRaw);
  if (s.user_id === userId) throw forbidden('not_allowed', 'You can’t react to your own story');
  const emoji = v.oneOf(body.emoji, STORY_REACTIONS, 'emoji');
  const prev = await db.one('SELECT emoji FROM story_views WHERE story_id = $1 AND viewer_id = $2', [s.id, userId]);
  await view(userId, s.id, { emoji });
  if (prev && prev.emoji === emoji) return { ok: true }; // same reaction again: no new message
  rateLimit.enforce(`story-react:${userId}`, 60, 3600 * 1000, 'Too many reactions. Try again later.');
  const msg = await sendToAuthor(userId, s, emoji, emoji);
  return { ok: true, message: msg };
}

// ------------------------------------------------------------------ archive & highlights
/** My stories, also the expired ones (for picking highlights). */
async function archive(userId, query = {}) {
  const before = query.before ? v.id(query.before, 'before') : null;
  const rows = await db.many(
    `SELECT s.* FROM stories s WHERE s.user_id = $1 AND s.deleted_at IS NULL ${before ? 'AND s.id < $2' : ''}
     ORDER BY s.id DESC LIMIT 60`,
    before ? [userId, before] : [userId],
  );
  return { stories: await withMedia(rows, true) };
}

async function withMedia(rows, owner) {
  if (!rows.length) return [];
  const medias = await db.many('SELECT * FROM media WHERE id = ANY($1::bigint[])', [rows.map((r) => r.media_id)]);
  const mediaMap = new Map(medias.map((m) => [m.id, m]));
  return rows.filter((r) => mediaMap.has(r.media_id)).map((r) => serialize(r, mediaMap.get(r.media_id), { owner }));
}

const MAX_HIGHLIGHTS = 20;
const MAX_HIGHLIGHT_ITEMS = 50;

async function myStoryIds(userId, raw) {
  const ids = v.idList(raw || [], 'story_ids', MAX_HIGHLIGHT_ITEMS);
  if (!ids.length) throw badRequest('invalid_input', 'Pick at least one story');
  const rows = await db.many('SELECT id FROM stories WHERE user_id = $1 AND deleted_at IS NULL AND id = ANY($2::bigint[])', [userId, ids]);
  if (!rows.length) throw badRequest('invalid_input', 'Those stories are not available');
  return rows.map((r) => r.id);
}

function highlightTitle(raw) {
  return v.str(raw, { field: 'title', max: 32 }) || 'Highlights';
}

/** Highlights shown on a profile: title, cover and how many stories each has. */
async function listHighlights(viewerId, ownerIdRaw) {
  const ownerId = v.id(ownerIdRaw, 'user_id');
  const rows = await db.many(
    `SELECT h.id, h.title, h.created_at,
            count(s.id)::int AS count,
            (array_agg(s.media_id ORDER BY s.id DESC))[1] AS cover_media_id,
            (array_agg(s.id ORDER BY s.id DESC))[1] AS cover_story_id
     FROM story_highlights h
     JOIN story_highlight_items hi ON hi.highlight_id = h.id
     JOIN stories s ON s.id = hi.story_id AND ${highlightVisibleSql('$2')}
     WHERE h.user_id = $1
     GROUP BY h.id ORDER BY h.created_at DESC`,
    [ownerId, viewerId],
  );
  const medias = rows.length ? await db.many('SELECT * FROM media WHERE id = ANY($1::bigint[])', [rows.map((r) => r.cover_media_id)]) : [];
  const mediaMap = new Map(medias.map((m) => [m.id, m]));
  return {
    highlights: rows.map((r) => ({
      id: r.id,
      title: r.title,
      count: r.count,
      cover: mediaService.serialize(mediaMap.get(r.cover_media_id)),
      created_at: new Date(r.created_at).toISOString(),
    })),
  };
}

async function getHighlight(viewerId, idRaw) {
  const h = await db.one('SELECT * FROM story_highlights WHERE id = $1', [v.id(idRaw, 'highlight_id')]);
  if (!h) throw notFound('highlight_not_found', 'Highlight not found');
  const rows = await db.many(
    `SELECT s.* FROM story_highlight_items hi JOIN stories s ON s.id = hi.story_id
     WHERE hi.highlight_id = $1 AND ${highlightVisibleSql('$2')} ORDER BY s.id`,
    [h.id, viewerId],
  );
  if (!rows.length && h.user_id !== viewerId) throw notFound('highlight_not_found', 'Highlight not found');
  const user = await userService.getUser(viewerId, h.user_id);
  return { id: h.id, title: h.title, user, mine: h.user_id === viewerId, stories: await withMedia(rows, h.user_id === viewerId) };
}

async function createHighlight(userId, body = {}) {
  const n = await db.one('SELECT count(*)::int AS n FROM story_highlights WHERE user_id = $1', [userId]);
  if (n.n >= MAX_HIGHLIGHTS) throw badRequest('too_many', `You can have up to ${MAX_HIGHLIGHTS} highlights`);
  const ids = await myStoryIds(userId, body.story_ids);
  const id = await db.tx(async (c) => {
    const h = (await c.query('INSERT INTO story_highlights (user_id, title) VALUES ($1, $2) RETURNING id', [userId, highlightTitle(body.title)])).rows[0];
    await c.query('INSERT INTO story_highlight_items (highlight_id, story_id) SELECT $1, x FROM unnest($2::bigint[]) x ON CONFLICT DO NOTHING', [h.id, ids]);
    return h.id;
  });
  return getHighlight(userId, id);
}

async function updateHighlight(userId, idRaw, body = {}) {
  const h = await db.one('SELECT * FROM story_highlights WHERE id = $1 AND user_id = $2', [v.id(idRaw, 'highlight_id'), userId]);
  if (!h) throw notFound('highlight_not_found', 'Highlight not found');
  const ids = body.story_ids !== undefined ? await myStoryIds(userId, body.story_ids) : null;
  await db.tx(async (c) => {
    if (body.title !== undefined) await c.query('UPDATE story_highlights SET title = $2 WHERE id = $1', [h.id, highlightTitle(body.title)]);
    if (ids) {
      await c.query('DELETE FROM story_highlight_items WHERE highlight_id = $1', [h.id]);
      await c.query('INSERT INTO story_highlight_items (highlight_id, story_id) SELECT $1, x FROM unnest($2::bigint[]) x ON CONFLICT DO NOTHING', [h.id, ids]);
    }
  });
  return getHighlight(userId, h.id);
}

async function deleteHighlight(userId, idRaw) {
  const r = await db.one('DELETE FROM story_highlights WHERE id = $1 AND user_id = $2 RETURNING id', [v.id(idRaw, 'highlight_id'), userId]);
  if (!r) throw notFound('highlight_not_found', 'Highlight not found');
  return { ok: true };
}

module.exports = {
  STORY_HOURS,
  STORY_REACTIONS,
  visibleSql,
  highlightVisibleSql,
  create,
  feed,
  view,
  viewers,
  remove,
  reply,
  react,
  archive,
  listHighlights,
  getHighlight,
  createHighlight,
  updateHighlight,
  deleteHighlight,
};
