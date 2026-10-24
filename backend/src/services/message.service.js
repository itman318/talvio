'use strict';

const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const userService = require('./user.service');
const chatService = require('./chat.service');
const mediaService = require('./media.service');
const moderation = require('./moderation.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const EFFECTS = ['confetti', 'hearts', 'balloons', 'fireworks'];
const SEND_TYPES = ['text', 'image', 'video', 'voice', 'video_note', 'file', 'poll', 'location', 'sticker', 'gif', 'contact'];
const SLOW_MODE_VALUES = [0, 10, 30, 60, 300, 900, 3600];
const MENTION_RE = /(^|[^A-Za-z0-9_@])@([A-Za-z][A-Za-z0-9_]{3,31})/g;
const MEDIA_KINDS_FOR_TYPE = {
  image: ['image'],
  video: ['video'],
  voice: ['voice'],
  video_note: ['video'],
  file: ['file', 'image', 'video', 'voice'],
};
const MAX_TEXT = 4096;
const MAX_CAPTION = 1024;
const BROADCAST_VIEWER = 0; // serialize as a stranger would see it (privacy-safe for fan-out)
const REACTIONS = ['👍', '❤️', '🔥', '😂', '😮', '😢', '👏', '🙏', '🎉', '👎'];

const VISIBLE_SQL = `m.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $USER AND h.message_id = m.id)`;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function minimalUser(u) {
  if (!u) return null;
  return {
    id: u.id,
    first_name: u.first_name,
    last_name: u.last_name,
    username: u.username,
    avatar_url: u.avatar_url,
    deleted: !!u.deleted,
    is_bot: !!u.is_bot,
  };
}

function nameOf(serializedUser) {
  if (!serializedUser) return 'Deleted Account';
  return userService.displayName({ ...serializedUser, status: serializedUser.deleted ? 'deleted' : 'active' });
}

// ------------------------------------------------------------------ polls & reactions (read side)
async function loadPolls(viewerId, messageIds) {
  const map = new Map();
  if (!messageIds.length) return map;
  const polls = await db.many('SELECT * FROM polls WHERE message_id = ANY($1::bigint[])', [messageIds]);
  if (!polls.length) return map;
  const pollIds = polls.map((p) => p.id);
  const options = await db.many('SELECT poll_id, idx, text FROM poll_options WHERE poll_id = ANY($1::bigint[]) ORDER BY idx', [pollIds]);
  const counts = await db.many(
    'SELECT poll_id, option_idx, count(*) AS n FROM poll_votes WHERE poll_id = ANY($1::bigint[]) GROUP BY poll_id, option_idx',
    [pollIds],
  );
  const voters = await db.many(
    'SELECT poll_id, count(DISTINCT user_id) AS n FROM poll_votes WHERE poll_id = ANY($1::bigint[]) GROUP BY poll_id',
    [pollIds],
  );
  const mine = viewerId
    ? await db.many('SELECT poll_id, option_idx FROM poll_votes WHERE poll_id = ANY($1::bigint[]) AND user_id = $2', [pollIds, viewerId])
    : [];
  for (const p of polls) {
    const myVotes = mine.filter((x) => x.poll_id === p.id).map((x) => x.option_idx);
    const closed = !!p.closed_at;
    const reveal = p.is_quiz && (closed || myVotes.length > 0);
    map.set(p.message_id, {
      id: p.id,
      question: p.question,
      options: options
        .filter((o) => o.poll_id === p.id)
        .map((o) => ({ text: o.text, votes: (counts.find((c) => c.poll_id === p.id && c.option_idx === o.idx) || { n: 0 }).n })),
      total_voters: (voters.find((x) => x.poll_id === p.id) || { n: 0 }).n,
      anonymous: p.is_anonymous,
      multiple: p.multiple,
      quiz: p.is_quiz,
      closed,
      my_votes: myVotes,
      correct_option: reveal ? p.correct_option : null,
      explanation: reveal ? p.explanation : null,
    });
  }
  return map;
}

async function loadReactions(viewerId, messageIds) {
  const map = new Map();
  if (!messageIds.length) return map;
  const rows = await db.many(
    `SELECT message_id, emoji, count(*) AS n FROM message_reactions WHERE message_id = ANY($1::bigint[])
     GROUP BY message_id, emoji ORDER BY n DESC`,
    [messageIds],
  );
  const mine = viewerId
    ? await db.many('SELECT message_id, emoji FROM message_reactions WHERE message_id = ANY($1::bigint[]) AND user_id = $2', [messageIds, viewerId])
    : [];
  for (const r of rows) {
    if (!map.has(r.message_id)) map.set(r.message_id, { list: [], mine: null });
    map.get(r.message_id).list.push({ emoji: r.emoji, count: r.n });
  }
  for (const r of mine) {
    if (!map.has(r.message_id)) map.set(r.message_id, { list: [], mine: null });
    map.get(r.message_id).mine = r.emoji;
  }
  return map;
}

/** Converts message rows to API objects (batched lookups for media, replies, senders, polls, reactions). */
async function serializeRows(viewerId, rows) {
  if (rows.length === 0) return [];
  const ids = rows.map((r) => r.id);
  const chatIds = [...new Set(rows.map((r) => r.chat_id))];
  const chats = await db.many('SELECT id, type, signatures, comments_enabled FROM chats WHERE id = ANY($1::bigint[])', [chatIds]);
  const chatMap = new Map(chats.map((c) => [c.id, c]));

  const replyIds = [...new Set(rows.map((r) => r.reply_to_id).filter(Boolean))];
  const replies = replyIds.length
    ? await db.many('SELECT id, sender_id, type, text, media_id, deleted_at FROM messages WHERE id = ANY($1::bigint[])', [replyIds])
    : [];
  const replyMap = new Map(replies.map((r) => [r.id, r]));

  const mediaIds = [...new Set(rows.map((r) => r.media_id).filter(Boolean))];
  const medias = mediaIds.length ? await db.many('SELECT * FROM media WHERE id = ANY($1::bigint[])', [mediaIds]) : [];
  const mediaMap = new Map(medias.map((m) => [m.id, m]));

  const userIds = [...rows.map((r) => r.sender_id), ...replies.map((r) => r.sender_id)].filter(Boolean);
  const users = await userService.getUsersMap(viewerId, userIds);
  const polls = await loadPolls(viewerId, rows.filter((r) => r.type === 'poll').map((r) => r.id));
  const reactions = await loadReactions(viewerId, ids);
  const mentionRows = await db.many('SELECT message_id, user_id FROM message_mentions WHERE message_id = ANY($1::bigint[])', [ids]);
  const postIds = rows.filter((r) => !r.thread_id && (chatMap.get(r.chat_id) || {}).type === 'channel').map((r) => r.id);
  const commentRows = postIds.length
    ? await db.many(
      `SELECT thread_id, count(*)::int AS n FROM messages WHERE thread_id = ANY($1::bigint[]) AND deleted_at IS NULL GROUP BY thread_id`,
      [postIds],
    )
    : [];
  const commentMap = new Map(commentRows.map((c) => [c.thread_id, c.n]));
  const onceIds = rows.filter((r) => r.meta && r.meta.view_once).map((r) => r.id);
  const onceRows = onceIds.length ? await db.many('SELECT message_id, user_id FROM message_once_views WHERE message_id = ANY($1::bigint[])', [onceIds]) : [];

  return rows.map((m) => {
    const chat = chatMap.get(m.chat_id) || { type: 'private' };
    // comments under a channel post are written by people, so they show the real sender
    const isChannel = chat.type === 'channel' && !m.thread_id;
    const r = m.reply_to_id ? replyMap.get(m.reply_to_id) : null;
    const replyUser = r && r.sender_id ? users.get(r.sender_id) : null;
    const sender = m.sender_id ? users.get(m.sender_id) : null;
    const react = reactions.get(m.id);
    return {
      id: m.id,
      chat_id: m.chat_id,
      // Channel posts are authored by the channel itself; admins stay anonymous unless signatures are on.
      sender_id: isChannel ? null : m.sender_id,
      sender: isChannel ? null : minimalUser(sender),
      author_signature: isChannel && chat.signatures && m.type !== 'system' ? nameOf(sender) : null,
      type: m.type,
      text: m.text,
      media: m.media_id ? mediaService.serialize(mediaMap.get(m.media_id)) : null,
      poll: m.type === 'poll' ? polls.get(m.id) || null : null,
      reply_to: r
        ? {
            id: r.id,
            sender_id: isChannel ? null : r.sender_id,
            sender_name: isChannel ? '' : nameOf(replyUser),
            type: r.type,
            text: r.deleted_at ? '' : String(r.text || '').slice(0, 120),
            deleted: !!r.deleted_at,
          }
        : null,
      forwarded_from: m.forwarded_from_name ? { user_id: m.forwarded_from_user_id, name: m.forwarded_from_name } : null,
      reactions: react ? react.list : [],
      my_reaction: react ? react.mine : null,
      views: m.views_count || 0,
      silent: !!m.silent,
      mentions: mentionRows.filter((x) => x.message_id === m.id).map((x) => x.user_id),
      meta: m.meta || null,
      view_once: !!(m.meta && m.meta.view_once),
      opened_by: m.meta && m.meta.view_once ? onceRows.filter((x) => x.message_id === m.id).map((x) => x.user_id).slice(0, 200) : undefined,
      thread_id: m.thread_id || null,
      album_id: m.album_id || null,
      topic_id: m.topic_id || null,
      comments_count: commentMap.get(m.id) || 0,
      reply_markup: m.reply_markup || null,
      link_preview: m.link_preview || null,
      expires_at: iso(m.expires_at),
      client_id: m.client_id || null,
      edited_at: iso(m.edited_at),
      created_at: iso(m.created_at),
    };
  });
}

async function serializeByIds(viewerId, ids) {
  const map = new Map();
  if (!ids.length) return map;
  const rows = await db.many('SELECT * FROM messages WHERE id = ANY($1::bigint[])', [ids]);
  for (const m of await serializeRows(viewerId, rows)) map.set(m.id, m);
  return map;
}

// ------------------------------------------------------------------ reading
// Shared media tabs (chat info → Media / Files / Links / Voice)
const FILTERS = {
  media: "m.type IN ('image', 'video', 'gif') AND NOT COALESCE((m.meta->>'view_once')::boolean, FALSE)",
  files: "m.type = 'file'",
  voice: "m.type IN ('voice', 'video_note') AND NOT COALESCE((m.meta->>'view_once')::boolean, FALSE)",
  links: "m.type = 'text' AND (m.link_preview IS NOT NULL OR m.text ~* 'https?://')",
};
function filterSql(f) {
  const sql = Object.prototype.hasOwnProperty.call(FILTERS, f) ? FILTERS[f] : null;
  if (!sql) throw badRequest('invalid_filter', 'Unknown filter');
  return sql;
}

/** How many photos/files/links/voice messages a chat has. */
async function mediaCounts(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const vis = VISIBLE_SQL.replace(/\$USER/g, '$3');
  const parts = Object.entries(FILTERS).map(([k, sql]) => `count(*) FILTER (WHERE ${sql}) AS ${k}`).join(', ');
  const r = await db.one(`SELECT ${parts} FROM messages m WHERE m.chat_id = $1 AND m.id > $2 AND ${vis}`, [chat.id, chat.cleared_before_id, userId]);
  return Object.fromEntries(Object.keys(FILTERS).map((k) => [k, Number(r[k])]));
}

async function listMessages(userId, chatIdRaw, query = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const lim = v.limit(query.limit, 50, 100);
  const params = [chat.id, chat.cleared_before_id, userId];
  let cond = `m.chat_id = $1 AND m.id > $2 AND ${VISIBLE_SQL.replace(/\$USER/g, '$3')}`;
  if (query.thread_id) {
    params.push(v.id(query.thread_id, 'thread_id'));
    cond += ` AND m.thread_id = $${params.length}`;
  } else {
    cond += ' AND m.thread_id IS NULL';
  }
  if (chat.is_forum && query.topic_id !== undefined && query.topic_id !== '') {
    if (query.topic_id === 'general' || query.topic_id === '0') {
      cond += ' AND m.topic_id IS NULL';
    } else {
      params.push(v.id(query.topic_id, 'topic_id'));
      cond += ` AND m.topic_id = $${params.length}`;
    }
  }
  if (query.filter) cond += ` AND ${filterSql(query.filter)}`;
  let order = 'DESC';
  if (query.before) {
    params.push(v.id(query.before, 'before'));
    cond += ` AND m.id < $${params.length}`;
  } else if (query.after) {
    params.push(v.id(query.after, 'after'));
    cond += ` AND m.id > $${params.length}`;
    order = 'ASC';
  }
  params.push(lim);
  const rows = await db.many(`SELECT m.* FROM messages m WHERE ${cond} ORDER BY m.id ${order} LIMIT $${params.length}`, params);
  if (order === 'ASC') rows.reverse();
  return { messages: await serializeRows(userId, rows), has_more: rows.length === lim };
}

async function getVisibleMessage(userId, messageIdRaw) {
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND deleted_at IS NULL', [v.id(messageIdRaw, 'message_id')]);
  if (!m) throw notFound('message_not_found', 'Message not found');
  const chat = await chatService.requireMember(m.chat_id, userId);
  if (m.id <= chat.cleared_before_id) throw notFound('message_not_found', 'Message not found');
  return { m, chat };
}

// ------------------------------------------------------------------ sending
/** Throws if `userId` may not post in `chat` (suspended, channel subscriber, blocked / deleted peer). */
async function assertCanSend(userId, chat, { comment = false } = {}) {
  if (chat.is_suspended) throw forbidden('chat_suspended', 'This group has been suspended');
  if (chat.type === 'channel' && comment) {
    if (!chat.comments_enabled) throw forbidden('comments_disabled', 'Comments are turned off in this channel');
  } else if (chat.type === 'channel' && !chatService.ADMIN_ROLES.includes(chat.my_role)) {
    throw forbidden('not_admin', 'Only channel admins can post');
  }
  if (chat.type === 'private') {
    const peerId = await chatService.privatePeerId(chat.id, userId);
    if (peerId) {
      const peer = await db.one('SELECT id, status FROM users WHERE id = $1', [peerId]);
      if (!peer || peer.status === 'deleted') throw forbidden('peer_deleted', 'You can’t message a deleted account');
      if (await userService.isBlockedEither(userId, peerId)) {
        throw forbidden('blocked', 'You can’t send messages to this user');
      }
    }
  }
}

function cleanText(text) {
  return typeof text === 'string' ? text.replace(/\r\n?/g, '\n').trim() : '';
}

function parsePoll(raw) {
  if (!raw || typeof raw !== 'object') throw badRequest('invalid_poll', 'Poll details are required');
  const question = v.str(raw.question, { field: 'question', min: 1, max: 300, required: true });
  if (!Array.isArray(raw.options) || raw.options.length < 2 || raw.options.length > 10) {
    throw badRequest('invalid_poll', 'A poll needs 2 to 10 options');
  }
  const options = raw.options.map((o) => v.str(String(o), { field: 'option', min: 1, max: 100 }));
  if (new Set(options.map((o) => o.toLowerCase())).size !== options.length) {
    throw badRequest('invalid_poll', 'Poll options must be different');
  }
  const quiz = raw.quiz === true;
  const poll = {
    question,
    options,
    anonymous: raw.anonymous !== false,
    multiple: !quiz && raw.multiple === true,
    quiz,
    correct_option: null,
    explanation: '',
  };
  if (quiz) {
    const c = Number(raw.correct_option);
    if (!Number.isInteger(c) || c < 0 || c >= options.length) {
      throw badRequest('invalid_poll', 'Choose the correct answer for the quiz');
    }
    poll.correct_option = c;
    poll.explanation = v.str(raw.explanation, { field: 'explanation', max: 200 }) || '';
  }
  return poll;
}

/**
 * Validates a send request and returns what to insert (no side effects).
 * Shared by direct sends and scheduled posts.
 */
async function prepareMessage(userId, chat, body) {
  const type = v.oneOf(body.type || 'text', SEND_TYPES, 'type');
  const text = cleanText(body.text);
  const out = { type, text, mediaId: null, replyToId: null, poll: null, meta: null };
  if (body.view_once === true && !['image', 'video', 'voice'].includes(type)) {
    throw badRequest('invalid_input', 'Only photos, videos and voice messages can be view once');
  }
  if (type === 'poll') await settings.requireFeature('feature_polls', 'Polls');
  if (type === 'voice' || type === 'video_note') await settings.requireFeature('feature_voice_messages', 'Voice messages');
  if (type === 'location') await settings.requireFeature('feature_location', 'Location sharing');

  if (type === 'text') {
    if (!text) throw badRequest('empty_message', 'Message is empty');
    if (text.length > MAX_TEXT) throw badRequest('message_too_long', `Messages can be at most ${MAX_TEXT} characters`);
    if (body.effect !== undefined && body.effect !== null) {
      // full-screen animation played when the message arrives
      out.meta = { effect: v.oneOf(body.effect, EFFECTS, 'effect') };
    }
  } else if (type === 'poll') {
    if (chat.type === 'private') throw badRequest('invalid_poll', 'Polls can be sent in groups and channels');
    out.poll = parsePoll(body.poll);
    out.text = out.poll.question;
  } else if (type === 'sticker') {
    await settings.requireFeature('feature_stickers', 'Stickers');
    const st = await require('./sticker.service').stickerForSend(body.sticker_id); // lazy: avoids circular import
    out.mediaId = st.media_id;
    out.meta = { sticker: { id: st.id, pack_id: st.pack_id, emoji: st.emoji, pack_title: st.pack_title } };
    out.text = '';
  } else if (type === 'contact') {
    const c = body.contact || {};
    const name = v.str(c.name, { field: 'name', min: 1, max: 64, required: true });
    const phone = c.phone ? v.tryNormalizePhone(String(c.phone)) : null;
    let email = null;
    if (c.email) {
      try {
        email = v.normalizeEmail(String(c.email));
      } catch (_) {
        email = null;
      }
    }
    if (!phone && !email && !c.user_id) throw badRequest('invalid_contact', 'A contact needs a phone number, an email or a Talvio account');
    // link it to a Talvio account when we can (only phone numbers people allow to be found)
    let userIdForCard = null;
    if (c.user_id) {
      const u = await db.one(`SELECT id FROM users WHERE id = $1 AND status = 'active'`, [v.id(c.user_id, 'user_id')]);
      userIdForCard = u ? u.id : null;
    } else if (phone) {
      const u = await db.one(`SELECT id FROM users WHERE phone = $1 AND status = 'active' AND privacy_phone <> 'nobody'`, [phone]);
      userIdForCard = u ? u.id : null;
    }
    out.meta = { contact: { name, phone, email, user_id: userIdForCard } };
    out.text = name;
  } else if (type === 'gif') {
    await settings.requireFeature('feature_gifs', 'GIFs');
    out.meta = { gif: require('./sticker.service').validateGif(body.gif) };
    if (text.length > MAX_CAPTION) throw badRequest('caption_too_long', `Captions can be at most ${MAX_CAPTION} characters`);
  } else if (type === 'location') {
    const loc = body.location || {};
    const lat = Number(loc.lat);
    const lng = Number(loc.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      throw badRequest('invalid_location', 'Invalid location');
    }
    const title = v.str(loc.title, { field: 'title', max: 120 }) || '';
    out.meta = { location: { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6, title } };
    out.text = title;
    if (loc.live_minutes !== undefined && loc.live_minutes !== null) {
      await settings.requireFeature('feature_live_location', 'Live location');
      const minutes = Number(loc.live_minutes);
      if (![15, 60, 480].includes(minutes)) throw badRequest('invalid_location', 'Live location lasts 15 minutes, 1 hour or 8 hours');
      const now = new Date();
      out.meta.live = { until: new Date(now.getTime() + minutes * 60000).toISOString(), updated_at: now.toISOString() };
    }
  } else {
    if (text.length > MAX_CAPTION) throw badRequest('caption_too_long', `Captions can be at most ${MAX_CAPTION} characters`);
    const media = await db.one('SELECT * FROM media WHERE id = $1 AND uploader_id = $2', [v.id(body.media_id, 'media_id'), userId]);
    if (!media) throw notFound('media_not_found', 'Upload the file first');
    if (!MEDIA_KINDS_FOR_TYPE[type].includes(media.kind)) throw badRequest('invalid_media', `This file can't be sent as ${type}`);
    if (type === 'video_note') {
      if (text) throw badRequest('invalid_input', 'Video messages have no caption');
      if (media.duration_sec && media.duration_sec > 60) throw badRequest('video_note_too_long', 'Video messages can be up to 60 seconds');
    }
    out.mediaId = media.id;
    if (type === 'voice' && Array.isArray(body.waveform)) {
      // loudness bars recorded on the phone (0–31 each), drawn by the voice player
      const wave = body.waveform.slice(0, 100).map((x) => Math.max(0, Math.min(31, Math.round(Number(x) || 0))));
      if (wave.length >= 8) out.meta = { waveform: wave };
    }
    if (body.view_once === true) {
      // view once: the other side can open it a single time; it can't be forwarded or saved
      if (chat.type === 'channel') throw badRequest('invalid_input', 'View once is not available in channels');
      out.meta = { ...(out.meta || {}), view_once: true };
    }
  }

  out.threadId = null;
  out.topicId = null;
  out.albumId = null;
  if (body.album_id !== undefined && body.album_id !== null && body.album_id !== '') {
    if (!['image', 'video'].includes(type)) throw badRequest('invalid_input', 'Only photos and videos can be grouped in an album');
    const a = String(body.album_id);
    if (!/^[A-Za-z0-9-]{8,36}$/.test(a)) throw badRequest('invalid_input', 'Invalid album_id');
    out.albumId = a;
  }
  if (body.thread_id) {
    if (chat.type !== 'channel') throw badRequest('invalid_input', 'Comments are only for channel posts');
    if (type === 'poll') throw badRequest('invalid_input', 'Polls can’t be sent as comments');
    const root = await db.one(
      `SELECT id FROM messages WHERE id = $1 AND chat_id = $2 AND thread_id IS NULL AND deleted_at IS NULL AND type <> 'system'`,
      [v.id(body.thread_id, 'thread_id'), chat.id],
    );
    if (!root) throw notFound('post_not_found', 'This post no longer exists');
    out.threadId = root.id;
  }
  if (chat.is_forum && body.topic_id) {
    const t = await db.one('SELECT id, is_closed FROM chat_topics WHERE id = $1 AND chat_id = $2', [v.id(body.topic_id, 'topic_id'), chat.id]);
    if (!t) throw notFound('topic_not_found', 'Topic not found');
    if (t.is_closed && !chatService.ADMIN_ROLES.includes(chat.my_role)) throw forbidden('topic_closed', 'This topic is closed');
    out.topicId = t.id;
  }

  if (body.reply_to_id) {
    const r = await db.one('SELECT id FROM messages WHERE id = $1 AND chat_id = $2 AND deleted_at IS NULL', [
      v.id(body.reply_to_id, 'reply_to_id'),
      chat.id,
    ]);
    if (!r) throw notFound('reply_not_found', 'The message you are replying to no longer exists');
    out.replyToId = r.id;
  }
  return out;
}

/** Low-level insert used by send / forward / system messages. Emits message:new. */
async function insertMessage({
  chatId,
  senderId = null,
  type,
  text = '',
  mediaId = null,
  replyToId = null,
  clientId = null,
  fwdUserId = null,
  fwdName = null,
  meta = null,
  poll = null,
  silent = false,
  mentionCandidates = null,
  threadId = null,
  topicId = null,
  replyMarkup = null,
  viaBotId = null,
  albumId = null,
}) {
  let row;
  try {
    row = await db.tx(async (c) => {
      const r = await c.query(
        `INSERT INTO messages (chat_id, sender_id, type, text, media_id, reply_to_id, client_id,
                               forwarded_from_user_id, forwarded_from_name, meta, silent, thread_id, topic_id, reply_markup, via_bot_id, album_id, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16,
                 CASE WHEN $17 THEN (SELECT CASE WHEN disappear_after_sec > 0 THEN now() + make_interval(secs => disappear_after_sec) END FROM chats WHERE id = $1) END)
         RETURNING *`,
        [chatId, senderId, type, text, mediaId, replyToId, clientId, fwdUserId, fwdName, meta ? JSON.stringify(meta) : null, !!silent,
          threadId, topicId, replyMarkup ? JSON.stringify(replyMarkup) : null, viaBotId, albumId, type !== 'system'],
      );
      const m = r.rows[0];
      if (mentionCandidates && senderId) {
        // @username mentions of chat members + the author of the replied-to message
        const usernames = [...new Set(mentionCandidates.usernames)];
        const found = usernames.length
          ? await c.query(
            `SELECT u.id FROM users u JOIN chat_members cm ON cm.chat_id = $1 AND cm.user_id = u.id
               WHERE lower(u.username) = ANY($2::text[]) AND u.id <> $3`,
            [chatId, usernames, senderId],
          )
          : { rows: [] };
        const ids = new Set(found.rows.map((x) => x.id));
        if (mentionCandidates.replyAuthor && mentionCandidates.replyAuthor !== senderId) ids.add(mentionCandidates.replyAuthor);
        for (const uid of ids) {
          await c.query(
            'INSERT INTO message_mentions (message_id, user_id, chat_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING',
            [m.id, uid, chatId],
          );
        }
      }
      if (poll) {
        const p = await c.query(
          `INSERT INTO polls (message_id, question, is_anonymous, multiple, is_quiz, correct_option, explanation)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
          [m.id, poll.question, poll.anonymous, poll.multiple, poll.quiz, poll.correct_option, poll.explanation],
        );
        for (let i = 0; i < poll.options.length; i += 1) {
          await c.query('INSERT INTO poll_options (poll_id, idx, text) VALUES ($1, $2, $3)', [p.rows[0].id, i, poll.options[i]]);
        }
      }
      if (!threadId) {
        await c.query('UPDATE chats SET last_message_id = $2, last_message_at = $3, updated_at = now() WHERE id = $1', [
          chatId,
          m.id,
          m.created_at,
        ]);
      }
      if (topicId) await c.query('UPDATE chat_topics SET last_message_at = $2 WHERE id = $1', [topicId, m.created_at]);
      await c.query('UPDATE chat_members SET is_hidden = FALSE WHERE chat_id = $1 AND is_hidden', [chatId]);
      if (senderId) {
        // replying to a message request accepts it
        await c.query('UPDATE chat_members SET is_request = FALSE WHERE chat_id = $1 AND user_id = $2 AND is_request', [chatId, senderId]);
        await c.query(
          `UPDATE chat_members SET last_read_message_id = GREATEST(last_read_message_id, $3),
             last_delivered_message_id = GREATEST(last_delivered_message_id, $3)
           WHERE chat_id = $1 AND user_id = $2`,
          [chatId, senderId, m.id],
        );
      }
      return m;
    });
  } catch (err) {
    if (err.code === '23505' && clientId && senderId) {
      // Same client_id sent twice (retry after a flaky connection) → return the original.
      const existing = await db.one('SELECT * FROM messages WHERE sender_id = $1 AND client_id = $2', [senderId, clientId]);
      if (existing) return (await serializeRows(BROADCAST_VIEWER, [existing]))[0];
    }
    throw err;
  }
  const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
  const memberIds = await chatService.memberIds(chatId);
  bus.emit('message:new', { chatId, message, memberIds, senderId });
  if (text && /https?:\/\//i.test(text) && type !== 'system') {
    // fetch the link preview in the background, then tell everyone the message changed
    setImmediate(() => require('./link.service').enrichMessage(row.id, text, async () => {
      const fresh = await db.one('SELECT * FROM messages WHERE id = $1', [row.id]);
      if (!fresh) return;
      const [updated] = await serializeRows(BROADCAST_VIEWER, [fresh]);
      bus.emit('message:edited', { chatId, message: updated, memberIds: await chatService.memberIds(chatId) });
    }));
  }
  return message;
}

/** Deletes messages whose disappearing timer ran out (called every minute by the server). */
async function sweepExpired() {
  const rows = await db.many(
    `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL, link_preview = NULL
     WHERE id IN (SELECT id FROM messages WHERE expires_at <= now() AND deleted_at IS NULL ORDER BY expires_at LIMIT 2000)
     RETURNING id, chat_id`,
  );
  const byChat = new Map();
  for (const r of rows) {
    if (!byChat.has(r.chat_id)) byChat.set(r.chat_id, []);
    byChat.get(r.chat_id).push(r.id);
  }
  for (const [chatId, ids] of byChat) {
    bus.emit('message:deleted', { chatId, messageIds: ids, userIds: await chatService.memberIds(chatId) });
  }
  return rows.length;
}

/** Live location: the sender's phone posts new coordinates (or stop) until the time runs out. */
async function updateLiveLocation(userId, messageIdRaw, body = {}) {
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND deleted_at IS NULL', [v.id(messageIdRaw, 'message_id')]);
  if (!m || m.type !== 'location' || !m.meta || !m.meta.live) throw notFound('message_not_found', 'Live location not found');
  if (m.sender_id !== userId) throw forbidden('not_allowed', 'Only the sender can update a live location');
  const meta = { ...m.meta, live: { ...m.meta.live } };
  const now = new Date();
  if (new Date(meta.live.until) <= now) return { ok: true, ended: true };
  rateLimit.enforce(`live:${m.id}`, 20, 60 * 1000, 'Too many updates');
  if (body.stop === true) {
    meta.live.until = now.toISOString();
    meta.live.stopped = true;
  } else {
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) throw badRequest('invalid_location', 'Invalid location');
    meta.location = { ...meta.location, lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6 };
    if (Number.isFinite(Number(body.accuracy))) meta.live.accuracy = Math.min(5000, Math.round(Number(body.accuracy)));
    if (Number.isFinite(Number(body.heading))) meta.live.heading = Math.round(Number(body.heading)) % 360;
  }
  meta.live.updated_at = now.toISOString();
  const row = await db.one('UPDATE messages SET meta = $2 WHERE id = $1 RETURNING *', [m.id, JSON.stringify(meta)]);
  const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
  bus.emit('message:edited', { chatId: m.chat_id, message, memberIds: await chatService.memberIds(m.chat_id) });
  return { ok: true, until: meta.live.until };
}

async function createSystemMessage(chatId, actorId, meta) {
  return insertMessage({ chatId, senderId: actorId, type: 'system', meta });
}

/** Call log entry in a private chat (sent "from" the caller; silent — calls have their own notifications). */
async function createCallMessage(chatId, callerId, meta) {
  return insertMessage({ chatId, senderId: callerId, type: 'call', meta, silent: true });
}

/**
 * Sends a message, or schedules it when body.schedule_at is given (returns { scheduled }).
 * internal: { meta, skipRateLimit } — only set by server code, never from request bodies.
 */
async function sendMessage(userId, chatIdRaw, body = {}, internal = {}) {
  if (!internal.skipRateLimit) rateLimit.enforce(`msg:${userId}`, 30, 10 * 1000, 'You are sending messages too fast');
  const chat = await chatService.requireMember(chatIdRaw, userId);
  await assertCanSend(userId, chat, { comment: !!body.thread_id });
  const sender = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
  if (chat.slow_mode_sec > 0 && chat.type === 'group' && !chatService.ADMIN_ROLES.includes(chat.my_role) && !body.schedule_at) {
    const last = await db.one(
      `SELECT created_at FROM messages WHERE chat_id = $1 AND sender_id = $2 AND type <> 'system' ORDER BY id DESC LIMIT 1`,
      [chat.id, userId],
    );
    if (last) {
      const wait = Math.ceil(chat.slow_mode_sec - (Date.now() - new Date(last.created_at).getTime()) / 1000);
      if (wait > 0) throw forbidden('slow_mode', `Slow mode is on. You can send another message in ${wait} s`, { retry_after: wait });
    }
  }

  const clientId = body.client_id ? v.str(String(body.client_id), { field: 'client_id', max: 64 }) : null;
  if (clientId) {
    const existing = await db.one('SELECT * FROM messages WHERE sender_id = $1 AND client_id = $2', [userId, clientId]);
    if (existing) return (await serializeRows(userId, [existing]))[0];
  }

  const prepared = await prepareMessage(userId, chat, body);
  const texts = [prepared.text, ...(prepared.poll ? prepared.poll.options : [])];
  const flags = await moderation.checkOutgoing(sender, texts);

  if (body.schedule_at) return { scheduled: await schedule(userId, chat, body) };

  let mentionCandidates = null;
  if (chat.type === 'group') {
    const usernames = [];
    for (const match of prepared.text.matchAll(MENTION_RE)) usernames.push(match[2].toLowerCase());
    let replyAuthor = null;
    if (prepared.replyToId) {
      const r = await db.one('SELECT sender_id FROM messages WHERE id = $1', [prepared.replyToId]);
      replyAuthor = r && r.sender_id;
    }
    if (usernames.length || replyAuthor) mentionCandidates = { usernames: usernames.slice(0, 50), replyAuthor };
  }

  const message = await insertMessage({
    chatId: chat.id,
    senderId: userId,
    type: prepared.type,
    text: prepared.text,
    mediaId: prepared.mediaId,
    replyToId: prepared.replyToId,
    clientId,
    poll: prepared.poll,
    meta: internal.meta || prepared.meta || null,
    silent: body.silent === true,
    mentionCandidates,
    threadId: prepared.threadId,
    topicId: prepared.topicId,
    albumId: prepared.albumId,
    replyMarkup: internal.replyMarkup || null,
  });
  moderation.afterSend(sender, message, flags).catch((err) => console.error('moderation error', err)); // eslint-disable-line no-console
  return message;
}

async function forwardMessages(userId, body = {}) {
  const from = await chatService.requireMember(body.from_chat_id, userId);
  const ids = v.idList(body.message_ids, 'message_ids', 100);
  const targets = v.idList(body.to_chat_ids, 'to_chat_ids', 10);
  if (!ids.length || !targets.length) throw badRequest('invalid_input', 'Nothing to forward');
  rateLimit.enforce(`fwd:${userId}`, 20, 60 * 1000, 'You are forwarding too fast');
  moderation.assertNotRestricted(await db.one('SELECT * FROM users WHERE id = $1', [userId]));

  const rows = await db.many(
    `SELECT m.* FROM messages m
     WHERE m.chat_id = $1 AND m.id = ANY($2::bigint[]) AND m.id > $3 AND m.type NOT IN ('system', 'poll', 'call')
       AND NOT COALESCE((m.meta->>'view_once')::boolean, FALSE)
       AND ${VISIBLE_SQL.replace(/\$USER/g, '$4')}
     ORDER BY m.id`,
    [from.id, ids, from.cleared_before_id, userId],
  );
  if (!rows.length) throw notFound('message_not_found', 'Messages not found');
  const senders = await db.many('SELECT * FROM users WHERE id = ANY($1::bigint[])', [
    rows.map((r) => r.sender_id).filter(Boolean),
  ]);
  const senderMap = new Map(senders.map((u) => [u.id, u]));

  const targetChats = [];
  for (const t of targets) {
    const chat = await chatService.requireMember(t, userId);
    await assertCanSend(userId, chat);
    targetChats.push(chat);
  }
  let count = 0;
  for (const chat of targetChats) {
    for (const r of rows) {
      // Forwarded channel posts show the channel's name, not the admin who posted.
      const fromName = from.type === 'channel' ? from.title : userService.displayName(senderMap.get(r.sender_id));
      await insertMessage({
        chatId: chat.id,
        senderId: userId,
        type: r.type,
        text: r.text,
        mediaId: r.media_id,
        fwdUserId: from.type === 'channel' ? null : r.forwarded_from_user_id || r.sender_id,
        fwdName: r.forwarded_from_name || fromName,
        meta: r.type === 'location' || r.type === 'voice' ? r.meta : null, // forwarded voice keeps its waveform
      });
      count += 1;
    }
  }
  return { forwarded: count };
}

// ------------------------------------------------------------------ view once
/** Opens a view-once message: allowed one time per person (the file can be fetched for a few minutes). */
async function openOnce(userId, messageIdRaw) {
  const { m, chat } = await getVisibleMessage(userId, messageIdRaw);
  if (!(m.meta && m.meta.view_once)) throw badRequest('invalid_input', 'This is not a view-once message');
  if (m.sender_id === userId) throw forbidden('own_view_once', 'You can’t open your own view-once message');
  const r = await db.one(
    'INSERT INTO message_once_views (message_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING opened_at',
    [m.id, userId],
  );
  if (!r) throw forbidden('already_opened', 'You already opened this');
  const [message] = await serializeRows(BROADCAST_VIEWER, [m]);
  bus.emit('message:edited', { chatId: chat.id, message, memberIds: await chatService.memberIds(chat.id) });
  return { ok: true, media: message.media };
}

// ------------------------------------------------------------------ editing / deleting
const uncheck = (t) => String(t || '').replace(/^(\s*)\[[xX]\] /gm, '$1[ ] ');

/** Earlier versions of an edited message, oldest first (plus the current text last). */
async function editHistory(userId, messageIdRaw) {
  const { m } = await getVisibleMessage(userId, messageIdRaw);
  const rows = await db.many('SELECT text, edited_at FROM message_edits WHERE message_id = $1 ORDER BY id', [m.id]);
  return {
    versions: [
      ...rows.map((r) => ({ text: r.text, at: new Date(r.edited_at).toISOString() })),
      { text: m.text, at: new Date(m.edited_at || m.created_at).toISOString(), current: true },
    ],
  };
}
async function editMessage(userId, messageIdRaw, body = {}) {
  const m = await db.one('SELECT * FROM messages WHERE id = $1 AND deleted_at IS NULL', [v.id(messageIdRaw, 'message_id')]);
  if (!m) throw notFound('message_not_found', 'Message not found');
  const chat = await chatService.requireMember(m.chat_id, userId);
  const channelAdmin = chat.type === 'channel' && chatService.ADMIN_ROLES.includes(chat.my_role);
  if ((m.sender_id !== userId && !channelAdmin) || ['system', 'poll', 'location', 'call'].includes(m.type) || m.forwarded_from_name) {
    throw forbidden('cannot_edit', 'You can only edit your own messages');
  }
  const text = cleanText(body.text);
  // ticking a checklist item ([ ] → [x]) is not an edit: no time limit, no "edited" label, no history
  const checkOnly = text !== m.text && uncheck(text) === uncheck(m.text) && /^\s*\[[ xX]\] /m.test(text);
  if (checkOnly) {
    const row = await db.one('UPDATE messages SET text = $2 WHERE id = $1 RETURNING *', [m.id, text]);
    const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
    bus.emit('message:edited', { chatId: m.chat_id, message, memberIds: await chatService.memberIds(m.chat_id) });
    return message;
  }
  const hours = await settings.get('message_edit_window_hours');
  if (hours > 0 && Date.now() - new Date(m.created_at).getTime() > hours * 3600 * 1000) {
    throw forbidden('edit_window_passed', 'This message is too old to edit');
  }
  if (m.type === 'text' && !text) throw badRequest('empty_message', 'Message is empty');
  const max = m.type === 'text' ? MAX_TEXT : MAX_CAPTION;
  if (text.length > max) throw badRequest('message_too_long', `At most ${max} characters`);
  if (text === m.text) return (await serializeRows(userId, [m]))[0];
  const flags = await moderation.checkOutgoing(await db.one('SELECT * FROM users WHERE id = $1', [userId]), [text]);

  await db.query('INSERT INTO message_edits (message_id, text, edited_at) VALUES ($1, $2, COALESCE($3::timestamptz, $4::timestamptz))', [m.id, m.text, m.edited_at, m.created_at]);
  const row = await db.one('UPDATE messages SET text = $2, edited_at = now(), link_preview = NULL WHERE id = $1 RETURNING *', [m.id, text]);
  const [message] = await serializeRows(BROADCAST_VIEWER, [row]);
  bus.emit('message:edited', { chatId: m.chat_id, message, memberIds: await chatService.memberIds(m.chat_id) });
  if (/https?:\/\//i.test(text)) {
    setImmediate(() => require('./link.service').enrichMessage(m.id, text, async () => {
      const fresh = await db.one('SELECT * FROM messages WHERE id = $1', [m.id]);
      const [updated] = await serializeRows(BROADCAST_VIEWER, [fresh]);
      bus.emit('message:edited', { chatId: m.chat_id, message: updated, memberIds: await chatService.memberIds(m.chat_id) });
    }));
  }
  if (flags.flaggedWord) {
    const sender = await db.one('SELECT * FROM users WHERE id = $1', [userId]);
    moderation.afterSend(sender, message, flags).catch(() => {});
  }
  return message;
}

/**
 * Deletes messages. forEveryone: own messages anywhere; in private chats both sides' messages;
 * in groups/channels admins may delete any message. Otherwise "delete for me".
 */
async function deleteMessages(userId, chatIdRaw, body = {}) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const ids = v.idList(body.message_ids, 'message_ids', 100);
  const forEveryone = body.for_everyone === true;
  const rows = await db.many(
    'SELECT id, sender_id, type, created_at FROM messages WHERE chat_id = $1 AND id = ANY($2::bigint[]) AND deleted_at IS NULL',
    [chat.id, ids],
  );
  if (!rows.length) return { deleted: 0 };
  const found = rows.map((r) => r.id);

  if (forEveryone) {
    const isAdmin = chatService.isMulti(chat) && chatService.ADMIN_ROLES.includes(chat.my_role);
    const hours = await settings.get('message_delete_window_hours');
    for (const r of rows) {
      const own = r.sender_id === userId && r.type !== 'system' && chat.type !== 'channel';
      const allowed = own || isAdmin || (chat.type === 'private' && r.type !== 'system');
      if (!allowed) throw forbidden('cannot_delete', 'You can only delete your own messages for everyone');
      // admins can always clean up; everyone else only within the window
      if (!isAdmin && hours > 0 && Date.now() - new Date(r.created_at).getTime() > hours * 3600 * 1000) {
        throw forbidden('delete_window_passed', `Messages can be deleted for everyone within ${hours} hours. You can still delete it for yourself.`);
      }
    }
    await db.query(
      `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL
       WHERE id = ANY($1::bigint[])`,
      [found],
    );
    bus.emit('message:deleted', { chatId: chat.id, messageIds: found, userIds: await chatService.memberIds(chat.id) });
  } else {
    await db.query(
      `INSERT INTO message_hidden (user_id, message_id) SELECT $1, x FROM unnest($2::bigint[]) AS x ON CONFLICT DO NOTHING`,
      [userId, found],
    );
    bus.emit('message:deleted', { chatId: chat.id, messageIds: found, userIds: [userId] });
  }
  return { deleted: found.length };
}

/** Admin moderation delete (no membership required). */
async function adminDeleteMessage(messageId) {
  const m = await db.one(
    `UPDATE messages SET deleted_at = now(), text = '', media_id = NULL, meta = NULL
     WHERE id = $1 AND deleted_at IS NULL RETURNING id, chat_id`,
    [messageId],
  );
  if (m) {
    bus.emit('message:deleted', { chatId: m.chat_id, messageIds: [m.id], userIds: await chatService.memberIds(m.chat_id) });
  }
  return !!m;
}

// ------------------------------------------------------------------ reactions, views, polls
async function react(userId, messageIdRaw, emoji) {
  const { m, chat } = await getVisibleMessage(userId, messageIdRaw);
  if (m.type === 'system') throw badRequest('invalid_input', 'You can’t react to this message');
  rateLimit.enforce(`react:${userId}`, 60, 60 * 1000, 'Slow down');
  if (emoji === null || emoji === undefined || emoji === '') {
    await db.query('DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2', [m.id, userId]);
  } else {
    v.oneOf(emoji, REACTIONS, 'emoji');
    await db.query(
      `INSERT INTO message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3)
       ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = EXCLUDED.emoji, created_at = now()`,
      [m.id, userId, emoji],
    );
  }
  const summary = (await loadReactions(userId, [m.id])).get(m.id) || { list: [], mine: null };
  bus.emit('message:reactions', {
    chatId: chat.id,
    messageId: m.id,
    reactions: summary.list,
    memberIds: await chatService.memberIds(chat.id),
    userId,
  });
  return { reactions: summary.list, my_reaction: summary.mine };
}

/** Counts a view once per user (used for channel post view counters). */
async function recordViews(userId, chatIdRaw, messageIdsRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const ids = v.idList(messageIdsRaw, 'message_ids', 100);
  if (!ids.length) return { views: {} };
  const fresh = await db.many(
    `INSERT INTO message_views (message_id, user_id)
     SELECT m.id, $2 FROM messages m WHERE m.chat_id = $1 AND m.id = ANY($3::bigint[]) AND m.deleted_at IS NULL
     ON CONFLICT DO NOTHING RETURNING message_id`,
    [chat.id, userId, ids],
  );
  if (fresh.length) {
    await db.query('UPDATE messages SET views_count = views_count + 1 WHERE id = ANY($1::bigint[])', [fresh.map((r) => r.message_id)]);
  }
  const rows = await db.many('SELECT id, views_count FROM messages WHERE chat_id = $1 AND id = ANY($2::bigint[])', [chat.id, ids]);
  return { views: Object.fromEntries(rows.map((r) => [r.id, r.views_count])) };
}

async function pollFor(userId, messageIdRaw) {
  const { m, chat } = await getVisibleMessage(userId, messageIdRaw);
  if (m.type !== 'poll') throw badRequest('not_a_poll', 'This message is not a poll');
  const poll = await db.one('SELECT * FROM polls WHERE message_id = $1', [m.id]);
  if (!poll) throw notFound('poll_not_found', 'Poll not found');
  return { m, chat, poll };
}

async function emitPoll(chat, messageId) {
  const summary = (await loadPolls(BROADCAST_VIEWER, [messageId])).get(messageId);
  bus.emit('message:poll', { chatId: chat.id, messageId, poll: summary, memberIds: await chatService.memberIds(chat.id) });
}

async function vote(userId, messageIdRaw, optionsRaw) {
  const { m, chat, poll } = await pollFor(userId, messageIdRaw);
  if (poll.closed_at) throw forbidden('poll_closed', 'This poll is closed');
  if (!Array.isArray(optionsRaw)) throw badRequest('invalid_input', 'options must be a list');
  const n = (await db.one('SELECT count(*) AS n FROM poll_options WHERE poll_id = $1', [poll.id])).n;
  const options = [...new Set(optionsRaw.map(Number))];
  if (options.some((o) => !Number.isInteger(o) || o < 0 || o >= n)) throw badRequest('invalid_input', 'Invalid option');
  if (!poll.multiple && options.length > 1) throw badRequest('invalid_input', 'Choose one option');
  const already = await db.one('SELECT count(*) AS n FROM poll_votes WHERE poll_id = $1 AND user_id = $2', [poll.id, userId]);
  if (poll.is_quiz) {
    if (already.n > 0) throw forbidden('already_voted', 'You already answered this quiz');
    if (options.length !== 1) throw badRequest('invalid_input', 'Choose one answer');
  }
  await db.tx(async (c) => {
    await c.query('DELETE FROM poll_votes WHERE poll_id = $1 AND user_id = $2', [poll.id, userId]);
    for (const o of options) {
      await c.query('INSERT INTO poll_votes (poll_id, user_id, option_idx) VALUES ($1, $2, $3)', [poll.id, userId, o]);
    }
  });
  await emitPoll(chat, m.id);
  return (await loadPolls(userId, [m.id])).get(m.id);
}

async function closePoll(userId, messageIdRaw) {
  const { m, chat, poll } = await pollFor(userId, messageIdRaw);
  const isAdmin = chatService.ADMIN_ROLES.includes(chat.my_role);
  if (m.sender_id !== userId && !isAdmin) throw forbidden('not_allowed', 'Only the poll creator or admins can close it');
  if (!poll.closed_at) {
    await db.query('UPDATE polls SET closed_at = now() WHERE id = $1', [poll.id]);
    await emitPoll(chat, m.id);
  }
  return (await loadPolls(userId, [m.id])).get(m.id);
}

async function pollVoters(userId, messageIdRaw, optionRaw) {
  const { poll } = await pollFor(userId, messageIdRaw);
  if (poll.is_anonymous) throw forbidden('anonymous_poll', 'Votes in this poll are anonymous');
  const option = Number(optionRaw);
  if (!Number.isInteger(option) || option < 0) throw badRequest('invalid_input', 'Invalid option');
  const rows = await db.many(
    'SELECT user_id FROM poll_votes WHERE poll_id = $1 AND option_idx = $2 ORDER BY created_at LIMIT 200',
    [poll.id, option],
  );
  const users = await userService.getUsersMap(userId, rows.map((r) => r.user_id));
  return rows.map((r) => users.get(r.user_id)).filter(Boolean);
}

// ------------------------------------------------------------------ scheduled messages
function serializeScheduled(s) {
  const p = s.payload || {};
  return {
    id: s.id,
    chat_id: s.chat_id,
    send_at: iso(s.send_at),
    status: s.status,
    error: s.error || null,
    type: p.type || 'text',
    text: p.type === 'poll' && p.poll ? p.poll.question : p.text || '',
    created_at: iso(s.created_at),
  };
}

async function schedule(userId, chat, body) {
  const at = new Date(body.schedule_at);
  if (Number.isNaN(at.getTime())) throw badRequest('invalid_input', 'schedule_at must be a date');
  if (at.getTime() < Date.now() + 30 * 1000) throw badRequest('invalid_input', 'Pick a time at least 1 minute from now');
  if (at.getTime() > Date.now() + 365 * 24 * 3600 * 1000) throw badRequest('invalid_input', 'You can schedule up to a year ahead');
  const pending = await db.one(`SELECT count(*) AS n FROM scheduled_messages WHERE sender_id = $1 AND status = 'pending'`, [userId]);
  if (pending.n >= 100) throw badRequest('too_many_scheduled', 'You can have at most 100 scheduled messages');
  const payload = {
    type: body.type || 'text',
    text: typeof body.text === 'string' ? body.text : '',
    media_id: body.media_id || null,
    reply_to_id: body.reply_to_id || null,
    poll: body.type === 'poll' ? body.poll : null,
    location: body.type === 'location' ? body.location : null,
    silent: body.silent === true,
  };
  const row = await db.one(
    'INSERT INTO scheduled_messages (chat_id, sender_id, payload, send_at) VALUES ($1, $2, $3, $4) RETURNING *',
    [chat.id, userId, JSON.stringify(payload), at.toISOString()],
  );
  return serializeScheduled(row);
}

async function listScheduled(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const rows = await db.many(
    `SELECT * FROM scheduled_messages WHERE chat_id = $1 AND sender_id = $2 AND status <> 'sent' ORDER BY send_at`,
    [chat.id, userId],
  );
  return rows.map(serializeScheduled);
}

async function cancelScheduled(userId, idRaw) {
  const r = await db.one(
    `DELETE FROM scheduled_messages WHERE id = $1 AND sender_id = $2 AND status <> 'sent' RETURNING id`,
    [v.id(idRaw, 'id'), userId],
  );
  if (!r) throw notFound('scheduled_not_found', 'Scheduled message not found');
  return { ok: true };
}

/** Publishes due scheduled messages. Called every few seconds by the server. */
async function runDueScheduled(limit = 50) {
  const due = await db.many(
    `UPDATE scheduled_messages SET status = 'sent'
     WHERE id IN (SELECT id FROM scheduled_messages WHERE status = 'pending' AND send_at <= now()
                  ORDER BY send_at LIMIT $1 FOR UPDATE SKIP LOCKED)
     RETURNING *`,
    [limit],
  );
  let sent = 0;
  for (const s of due) {
    try {
      const msg = await sendMessage(s.sender_id, s.chat_id, { ...s.payload, client_id: `sched-${s.id}` }, { skipRateLimit: true });
      await db.query('UPDATE scheduled_messages SET message_id = $2 WHERE id = $1', [s.id, msg.id]);
      sent += 1;
    } catch (err) {
      await db.query(`UPDATE scheduled_messages SET status = 'failed', error = $2 WHERE id = $1`, [s.id, String(err.message).slice(0, 300)]);
    }
  }
  return sent;
}


// ------------------------------------------------------------------ pinned messages
const MAX_PINS = 50;

function canPin(chat) {
  if (chat.type === 'private') return true;
  return chatService.ADMIN_ROLES.includes(chat.my_role);
}

async function pinMessage(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  if (!canPin(chat)) throw forbidden('not_admin', 'Only admins can pin messages');
  const m = await db.one(
    `SELECT id FROM messages WHERE id = $1 AND chat_id = $2 AND deleted_at IS NULL AND type <> 'system'`,
    [v.id(messageIdRaw, 'message_id'), chat.id],
  );
  if (!m) throw notFound('message_not_found', 'Message not found');
  const n = await db.one('SELECT count(*) AS n FROM pinned_messages WHERE chat_id = $1', [chat.id]);
  if (n.n >= MAX_PINS) throw badRequest('too_many_pins', `You can pin up to ${MAX_PINS} messages`);
  const r = await db.one(
    `INSERT INTO pinned_messages (chat_id, message_id, pinned_by) VALUES ($1, $2, $3)
     ON CONFLICT (chat_id, message_id) DO UPDATE SET pinned_at = now() RETURNING (xmax = 0) AS inserted`,
    [chat.id, m.id, userId],
  );
  if (r.inserted && chat.type === 'group') await createSystemMessage(chat.id, userId, { event: 'message_pinned', message_id: m.id });
  await chatService.emitUpdated(chat.id);
  return listPins(userId, chat.id);
}

async function unpinMessage(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  if (!canPin(chat)) throw forbidden('not_admin', 'Only admins can unpin messages');
  const all = messageIdRaw === 'all';
  await db.query(
    all ? 'DELETE FROM pinned_messages WHERE chat_id = $1' : 'DELETE FROM pinned_messages WHERE chat_id = $1 AND message_id = $2',
    all ? [chat.id] : [chat.id, v.id(messageIdRaw, 'message_id')],
  );
  await chatService.emitUpdated(chat.id);
  return listPins(userId, chat.id);
}

async function listPins(userId, chatIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const rows = await db.many(
    `SELECT m.* FROM pinned_messages p JOIN messages m ON m.id = p.message_id
     WHERE p.chat_id = $1 AND m.deleted_at IS NULL AND m.id > $2
       AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $3 AND h.message_id = m.id)
     ORDER BY p.pinned_at DESC`,
    [chat.id, chat.cleared_before_id, userId],
  );
  return serializeRows(userId, rows);
}

// ------------------------------------------------------------------ message search
/** Builds a prefix tsquery from user input: "ali kh" → "ali:* & kh:*" (letters/digits only, any script). */
function tsQuery(q) {
  const tokens = (String(q || '').toLowerCase().match(/[\p{L}\p{N}]+/gu) || []).slice(0, 8);
  return tokens.length ? tokens.map((t) => `${t}:*`).join(' & ') : null;
}

async function searchMessages(userId, query = {}) {
  const tq = tsQuery(query.q);
  if (!tq || String(query.q).trim().length < 2) return { results: [], has_more: false };
  rateLimit.enforce(`search:${userId}`, 30, 60 * 1000, 'Searching too fast, wait a moment');
  const lim = v.limit(query.limit, 30, 50);
  const params = [userId, tq];
  let extra = '';
  if (query.chat_id) {
    params.push(v.id(query.chat_id, 'chat_id'));
    extra += ` AND m.chat_id = $${params.length}`;
  }
  if (query.before) {
    params.push(v.id(query.before, 'before'));
    extra += ` AND m.id < $${params.length}`;
  }
  params.push(lim);
  const rows = await db.many(
    `SELECT m.* FROM messages m
     JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = $1
     WHERE to_tsvector('simple', m.text) @@ to_tsquery('simple', $2)
       AND m.deleted_at IS NULL AND m.type <> 'system' AND m.id > cm.cleared_before_id
       AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id = $1 AND h.message_id = m.id)
       ${extra}
     ORDER BY m.id DESC LIMIT $${params.length}`,
    params,
  );
  const messages = await serializeRows(userId, rows);
  const chats = await chatService.getChatsByIds(userId, [...new Set(rows.map((r) => r.chat_id))]);
  const chatMap = new Map(chats.map((c) => [c.id, { id: c.id, type: c.type, title: c.title, avatar_url: c.avatar_url }]));
  return {
    results: messages.map((m) => ({ chat: chatMap.get(m.chat_id), message: m })),
    has_more: rows.length === lim,
  };
}

// ------------------------------------------------------------------ receipts
async function chatMaxMessageId(chatId) {
  const r = await db.one('SELECT COALESCE(max(id), 0) AS id FROM messages WHERE chat_id = $1', [chatId]);
  return r.id;
}

async function markRead(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  await db.query('UPDATE chat_members SET marked_unread = FALSE WHERE chat_id = $1 AND user_id = $2 AND marked_unread', [chat.id, userId]);
  const target = Math.min(v.id(messageIdRaw, 'message_id'), await chatMaxMessageId(chat.id));
  const r = await db.one(
    `UPDATE chat_members SET last_read_message_id = $3,
       last_delivered_message_id = GREATEST(last_delivered_message_id, $3)
     WHERE chat_id = $1 AND user_id = $2 AND last_read_message_id < $3
     RETURNING last_read_message_id`,
    [chat.id, userId, target],
  );
  // Channels don't show read receipts, so skip the fan-out to every subscriber.
  if (r && chat.type !== 'channel') {
    bus.emit('receipt:read', { chatId: chat.id, userId, messageId: target, memberIds: await chatService.memberIds(chat.id) });
  }
  return { last_read_message_id: r ? r.last_read_message_id : chat.last_read_message_id };
}

async function markDelivered(userId, chatIdRaw, messageIdRaw) {
  const chat = await chatService.requireMember(chatIdRaw, userId);
  const target = Math.min(v.id(messageIdRaw, 'message_id'), await chatMaxMessageId(chat.id));
  const r = await db.one(
    `UPDATE chat_members SET last_delivered_message_id = $3
     WHERE chat_id = $1 AND user_id = $2 AND last_delivered_message_id < $3 RETURNING chat_id`,
    [chat.id, userId, target],
  );
  if (r && chat.type !== 'channel') {
    bus.emit('receipt:delivered', { chatId: chat.id, userId, messageId: target, memberIds: await chatService.memberIds(chat.id) });
  }
  return { ok: true };
}

/** Called when a user's device connects: everything up to now counts as delivered. */
async function markAllDelivered(userId) {
  const rows = await db.many(
    `UPDATE chat_members cm SET last_delivered_message_id = c.last_message_id
     FROM chats c
     WHERE c.id = cm.chat_id AND cm.user_id = $1 AND c.last_message_id > cm.last_delivered_message_id
     RETURNING cm.chat_id, cm.last_delivered_message_id, c.type`,
    [userId],
  );
  for (const r of rows) {
    if (r.type === 'channel') continue;
    bus.emit('receipt:delivered', {
      chatId: r.chat_id,
      userId,
      messageId: r.last_delivered_message_id,
      memberIds: await chatService.memberIds(r.chat_id),
    });
  }
  return rows.length;
}

module.exports = {
  openOnce,
  editHistory,
  mediaCounts,
  updateLiveLocation,
  sweepExpired,
  REACTIONS,
  SLOW_MODE_VALUES,
  pinMessage,
  unpinMessage,
  listPins,
  searchMessages,
  serializeRows,
  serializeByIds,
  listMessages,
  sendMessage,
  forwardMessages,
  editMessage,
  deleteMessages,
  adminDeleteMessage,
  createSystemMessage,
  createCallMessage,
  insertMessage,
  assertCanSend,
  prepareMessage,
  react,
  recordViews,
  vote,
  closePoll,
  pollVoters,
  listScheduled,
  cancelScheduled,
  runDueScheduled,
  markRead,
  markDelivered,
  markAllDelivered,
};
