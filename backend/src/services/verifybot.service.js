'use strict';

/**
 * @HushaviaVerifyBot — ask for a verified badge in one chat:
 *   ✅ my profile (a known person) · 🏪 my business ("Verified business" tag) · 📣 my channel or group.
 * The person writes who they are, adds links and photos of documents, presses "Send to Hushavia".
 * Admins check it in the panel (Verification) and approve or decline; the bot tells the person.
 */
const db = require('../db');
const v = require('../utils/validate');
const { badRequest, notFound, conflict } = require('../utils/errors');

const sys = () => require('./sysbots.service'); // eslint-disable-line global-require
const btn = (text, data) => ({ text, callback_data: data });

const KINDS = {
  person: { label: 'Verified profile', icon: '✅', ask: 'Write who you are (your full name and what you’re known for) and add links that prove it: your website, news articles, other social profiles. Then send a photo of an ID card or a document with your name.' },
  business: { label: 'Verified business', icon: '🏪', ask: 'Write your business name, what you sell, your city and your website or shop page. Then send photos of a business document (registration, NTN, trade licence or a utility bill in the business name).' },
  chat: { label: 'Verified channel or group', icon: '📣', ask: 'Write the @username of the channel or group (you must be its owner), what it is about and links to the same channel elsewhere (Telegram, YouTube, website).' },
};

// in memory while someone fills in a request: userId → { kind, text: [], media: [] }
const drafts = new Map();

async function home(userId, chatId) {
  const open = await db.one(`SELECT kind, created_at FROM verify_requests WHERE user_id = $1 AND status = 'open' ORDER BY id DESC LIMIT 1`, [userId]);
  const lines = ['🛡️ Hushavia Verification', '', 'A verified badge shows people that an account is really who it says it is.', ''];
  if (open) lines.push(`⏳ Your request (${KINDS[open.kind].label}) is with the team. We’ll write here when it’s checked.`, '');
  lines.push('What would you like to verify?');
  return sys().say('verify', chatId, lines.join('\n'), [
    [btn('✅ My profile', 'k:person')],
    [btn('🏪 My business', 'k:business')],
    [btn('📣 My channel or group', 'k:chat')],
  ]);
}

async function start(userId, chatId, kind) {
  const open = await db.one(`SELECT 1 AS x FROM verify_requests WHERE user_id = $1 AND status = 'open' LIMIT 1`, [userId]);
  if (open) return sys().say('verify', chatId, '⏳ You already have a request waiting. Please wait for the team’s answer.');
  if (kind === 'business') {
    const plus = await require('./payment.service').isPremium(userId); // eslint-disable-line global-require
    if (!plus) return sys().say('verify', chatId, '🏪 Business verification is part of Hushavia Business (Hushavia Plus). Get Plus from @HushaviaPlusBot, then come back.');
  }
  drafts.set(userId, { kind, text: [], media: [] });
  return sys().say('verify', chatId, `${KINDS[kind].icon} ${KINDS[kind].label}\n\n${KINDS[kind].ask}\n\nSend as many messages and photos as you need, then press “Send to Hushavia”.`,
    [[btn('📨 Send to Hushavia', 'send')], [btn('Cancel', 'cancel')]]);
}

async function submit(userId, chatId) {
  const d = drafts.get(userId);
  if (!d) return home(userId, chatId);
  const text = d.text.join('\n').trim();
  if (text.length < 20) return sys().say('verify', chatId, 'Please write a bit more about who you are (at least a sentence or two), then press “Send to Hushavia” again.', [[btn('📨 Send to Hushavia', 'send')]]);
  if (d.kind !== 'chat' && !d.media.length) return sys().say('verify', chatId, 'Please send at least one photo of a document first.', [[btn('📨 Send to Hushavia', 'send')]]);
  let targetChat = null;
  if (d.kind === 'chat') {
    const m = /@([A-Za-z0-9_]{4,32})/.exec(text);
    const c = m && await db.one(
      `SELECT c.id FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2 AND cm.role = 'owner'
       WHERE lower(c.username) = lower($1) AND c.type <> 'private'`,
      [m[1], userId],
    );
    if (!c) return sys().say('verify', chatId, 'Write the @username of a public channel or group that you own (e.g. @MyChannel), then press “Send to Hushavia” again.', [[btn('📨 Send to Hushavia', 'send')]]);
    targetChat = c.id;
  }
  await db.query(
    `INSERT INTO verify_requests (user_id, kind, chat_id, details, media_ids) VALUES ($1, $2, $3, $4, $5)`,
    [userId, d.kind, targetChat, text.slice(0, 4000), JSON.stringify(d.media.slice(0, 10))],
  );
  drafts.delete(userId);
  return sys().say('verify', chatId, '📨 Sent! The Hushavia team will check it — usually within a few days. I’ll write here with the answer.');
}

async function onMessage(userId, chatId, row) {
  const t = String((row && row.text) || '').trim();
  const d = drafts.get(userId);
  if (!d || t === '/start') return home(userId, chatId);
  if (t === '/cancel') {
    drafts.delete(userId);
    return sys().say('verify', chatId, 'Cancelled.');
  }
  if (t) d.text.push(t);
  if (row && row.media_id && row.type === 'image') {
    const own = await db.one(`SELECT id FROM media WHERE id = $1 AND uploader_id = $2`, [row.media_id, userId]);
    if (own && d.media.length < 10) d.media.push(Number(own.id));
  }
  const got = [d.text.length ? `${d.text.length} message${d.text.length > 1 ? 's' : ''}` : null, d.media.length ? `${d.media.length} photo${d.media.length > 1 ? 's' : ''}` : null].filter(Boolean).join(' and ');
  return sys().say('verify', chatId, `👍 Got it (${got}). Add more, or press “Send to Hushavia”.`, [[btn('📨 Send to Hushavia', 'send')], [btn('Cancel', 'cancel')]]);
}

async function onCallback(userId, chatId, data) {
  const s = String(data || '');
  if (s.startsWith('k:') && KINDS[s.slice(2)]) return start(userId, chatId, s.slice(2));
  if (s === 'send') return submit(userId, chatId);
  if (s === 'cancel') {
    drafts.delete(userId);
    return sys().say('verify', chatId, 'Cancelled. Write anything to start again.');
  }
  return home(userId, chatId);
}

// ------------------------------------------------------------------ admin panel
async function adminList(query = {}) {
  const status = ['open', 'approved', 'declined'].includes(query.status) ? query.status : 'open';
  const rows = await db.many(
    `SELECT r.*, u.first_name, u.last_name, u.username, u.phone, u.created_at AS user_created, u.is_verified, u.tags,
            c.title AS chat_title, c.username AS chat_username, c.member_count, a.name AS admin_name
     FROM verify_requests r JOIN users u ON u.id = r.user_id LEFT JOIN chats c ON c.id = r.chat_id LEFT JOIN admins a ON a.id = r.decided_by
     WHERE r.status = $1 ORDER BY r.id ${status === 'open' ? 'ASC' : 'DESC'} LIMIT 200`,
    [status],
  );
  return {
    items: rows.map((r) => ({
      id: Number(r.id),
      kind: r.kind,
      label: KINDS[r.kind].label,
      details: r.details,
      media_ids: r.media_ids || [],
      user: { id: Number(r.user_id), name: `${r.first_name || ''} ${r.last_name || ''}`.trim(), username: r.username, phone: r.phone, since: r.user_created, verified: r.is_verified, tags: r.tags || [] },
      chat: r.chat_id ? { id: Number(r.chat_id), title: r.chat_title, username: r.chat_username, members: Number(r.member_count || 0) } : null,
      status: r.status,
      note: r.admin_note,
      by: r.admin_name,
      created_at: new Date(r.created_at).toISOString(),
    })),
  };
}

async function adminDecide(admin, idRaw, body = {}, ip) {
  const id = v.id(idRaw, 'request_id');
  const approve = body.approve === true;
  const note = v.str(body.note, { field: 'note', max: 500 }) || '';
  if (!approve && note.length < 3) throw badRequest('invalid_input', 'Write why it is declined — the person will see it');
  const r = await db.one(`UPDATE verify_requests SET status = $2, admin_note = $3, decided_by = $4, decided_at = now() WHERE id = $1 AND status = 'open' RETURNING *`,
    [id, approve ? 'approved' : 'declined', note, admin.id]);
  if (!r) throw (await db.one('SELECT 1 AS x FROM verify_requests WHERE id = $1', [id])) ? conflict('already_decided', 'Already decided') : notFound('request_not_found', 'Request not found');
  const adminService = require('./admin.service'); // eslint-disable-line global-require
  if (approve) {
    if (r.kind === 'person') await adminService.setVerified(admin, r.user_id, true, ip);
    if (r.kind === 'chat' && r.chat_id) await adminService.setChatVerified(admin, r.chat_id, true, ip);
    if (r.kind === 'business') await require('./tags.service').add(admin.id, r.user_id, { tag: 'verified_business', reason: note || 'Business documents checked' }); // eslint-disable-line global-require
  }
  const { chat } = await sysChat(r.user_id);
  await sys().say('verify', chat,
    approve
      ? `🎉 Approved! Your ${KINDS[r.kind].label.toLowerCase()} badge is on now.${note ? `\n\n${note}` : ''}`
      : `We couldn’t verify this request.\n\nReason: ${note}\n\nYou can send a new request with more proof.`).catch(() => null);
  return { ok: true };
}

async function sysChat(userId) {
  const botId = await sys().ensureOne('verify');
  const c = await require('./chat.service').getOrCreatePrivate(userId, botId); // eslint-disable-line global-require
  return { chat: c.id };
}

module.exports = { onMessage, onCallback, adminList, adminDecide, KINDS };
