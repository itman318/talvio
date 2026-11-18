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
  person: { label: 'Verified profile', icon: '✅', intro: 'For well-known people: artists, journalists, public figures, creators.' },
  business: { label: 'Verified business', icon: '🏪', intro: 'For real shops and companies that sell on Hushavia (needs Hushavia Business).' },
  chat: { label: 'Verified channel or group', icon: '📣', intro: 'For public channels and groups you own.' },
};

const URL_RE = /(https?:\/\/|www\.)\S+|\b[\w-]+\.(com|pk|net|org|io|co|me|app|shop|store|tv|ae)\b\S*/i;

/** The form, one question at a time. type: text | photo; optional fields can be skipped. */
const STEPS = {
  person: [
    { key: 'full_name', label: 'Full name', q: 'What is your full name, as on your ID card?', min: 3, max: 80 },
    { key: 'known_for', label: 'Known for', q: 'What are you known for? (e.g. singer, journalist at Dawn News, YouTube creator)', min: 3, max: 200 },
    { key: 'city', label: 'City & country', q: 'Which city and country are you in?', min: 2, max: 80 },
    { key: 'links', label: 'Links', q: 'Send links that prove who you are: official website, news articles, or your verified profiles on other apps (one or more links).', min: 5, max: 600, link: true },
    { key: 'id_photo', label: 'ID document', q: 'Send a photo of your CNIC, passport or another ID with your name. It is seen only by the Hushavia team.', type: 'photo' },
    { key: 'selfie', label: 'Selfie with ID', q: 'Optional: a selfie holding the same ID card. It makes approval faster.', type: 'photo', optional: true },
  ],
  business: [
    { key: 'business_name', label: 'Business name', q: 'What is the registered name of your business?', min: 2, max: 100 },
    { key: 'category', label: 'What you sell', q: 'What does the business sell or do? (e.g. mobile phones, clothing, restaurant)', min: 3, max: 200 },
    { key: 'address', label: 'Address', q: 'Business address (city and area, or full address).', min: 5, max: 200 },
    { key: 'reg_no', label: 'Registration / NTN', q: 'Registration, NTN or trade licence number. If you don’t have one, press Skip.', max: 60, optional: true },
    { key: 'links', label: 'Website / shop page', q: 'Your website, Google Maps listing or shop page on another app (one or more links).', min: 5, max: 600, link: true },
    { key: 'contact', label: 'Business contact', q: 'A business phone number or email where we can confirm it’s you.', min: 5, max: 120 },
    { key: 'doc_photo', label: 'Business document', q: 'Send a photo of a document in the business name: registration, NTN certificate, trade licence or a utility bill.', type: 'photo' },
    { key: 'shop_photo', label: 'Shop / office photo', q: 'Optional: a photo of your shop front or office with the name visible.', type: 'photo', optional: true },
  ],
  chat: [
    { key: 'username', label: 'Channel / group', q: 'Send the @username of the public channel or group you own (e.g. @MyChannel).', min: 5, max: 40, chat: true },
    { key: 'about', label: 'About', q: 'What is it about, and who runs it? (e.g. news from Lahore by City Media)', min: 10, max: 300 },
    { key: 'links', label: 'Same channel elsewhere', q: 'Links to the same channel or brand on other platforms (Telegram, YouTube, Facebook, website).', min: 5, max: 600, link: true },
    { key: 'proof_photo', label: 'Proof', q: 'Optional: a screenshot that shows you own the channel on another platform (e.g. its admin page).', type: 'photo', optional: true },
  ],
};

// in memory while someone fills in the form: userId → { kind, i (step), answers: {}, editing: bool }
const drafts = new Map();
const ref = (id) => `VR-${String(id).padStart(6, '0')}`;

async function home(userId, chatId) {
  const open = await db.one(`SELECT id, kind, created_at FROM verify_requests WHERE user_id = $1 AND status = 'open' ORDER BY id DESC LIMIT 1`, [userId]);
  const lines = [
    '🛡️ **Hushavia Verification**',
    '',
    'A verified badge tells people an account is really who it says it is. Our team checks every request by hand.',
    '',
  ];
  if (open) {
    lines.push(`⏳ Request ${ref(open.id)} (${KINDS[open.kind].label}) is being checked. We’ll message you here with the answer.`);
    return sys().say('verify', chatId, lines.join('\n'), [[btn('📄 My requests', 'status')]]);
  }
  lines.push('What would you like to verify?', '', ...Object.values(KINDS).map((k) => `${k.icon} **${k.label}** — ${k.intro}`));
  return sys().say('verify', chatId, lines.join('\n'), [
    [btn('✅ My profile', 'k:person')],
    [btn('🏪 My business', 'k:business')],
    [btn('📣 My channel or group', 'k:chat')],
    [btn('📄 My requests', 'status')],
  ]);
}

async function myRequests(userId, chatId) {
  const rows = await db.many('SELECT id, kind, status, admin_note, created_at FROM verify_requests WHERE user_id = $1 ORDER BY id DESC LIMIT 5', [userId]);
  if (!rows.length) return sys().say('verify', chatId, 'You haven’t sent a request yet.', [[btn('⬅️ Back', 'home')]]);
  const icon = { open: '⏳ Being checked', approved: '✅ Approved', declined: '❌ Declined' };
  const text = ['📄 Your requests', '', ...rows.map((r) => `${ref(r.id)} · ${KINDS[r.kind].label}\n${icon[r.status]}${r.admin_note ? ` — ${r.admin_note}` : ''}`)].join('\n\n');
  return sys().say('verify', chatId, text, [[btn('⬅️ Back', 'home')]]);
}

async function start(userId, chatId, kind) {
  const open = await db.one(`SELECT id FROM verify_requests WHERE user_id = $1 AND status = 'open' LIMIT 1`, [userId]);
  if (open) return sys().say('verify', chatId, `⏳ Request ${ref(open.id)} is still being checked. Please wait for the answer.`);
  if (kind === 'business') {
    const plus = await require('./payment.service').isPremium(userId); // eslint-disable-line global-require
    if (!plus) return sys().say('verify', chatId, '🏪 Business verification comes with Hushavia Business (Hushavia Plus). Get Plus from @HushaviaPlusBot, then come back here.', [[btn('⬅️ Back', 'home')]]);
  }
  drafts.set(userId, { kind, i: 0, answers: {}, editing: false });
  const steps = STEPS[kind];
  await sys().say('verify', chatId,
    `${KINDS[kind].icon} **${KINDS[kind].label}**\n\nI’ll ask ${steps.length} short questions. You can go back, skip the optional ones, and check everything before you send.`);
  return ask(userId, chatId);
}

async function ask(userId, chatId) {
  const d = drafts.get(userId);
  const steps = STEPS[d.kind];
  if (d.i >= steps.length) return review(userId, chatId);
  const st = steps[d.i];
  const row = [];
  if (d.i > 0 && !d.editing) row.push(btn('⬅️ Back', 'back'));
  if (st.optional) row.push(btn('Skip ⏭', 'skip'));
  const kb = [];
  if (row.length) kb.push(row);
  kb.push([btn('✖ Cancel', 'cancel')]);
  const hint = st.type === 'photo' ? '📷 Send a photo' : '✍️ Type your answer';
  return sys().say('verify', chatId, `**Step ${d.i + 1} of ${steps.length} — ${st.label}**${st.optional ? ' (optional)' : ''}\n\n${st.q}\n\n${hint}`, kb);
}

function shown(st, val) {
  if (val === undefined || val === null || val === '') return '—';
  return st.type === 'photo' ? '📎 attached' : String(val);
}

async function review(userId, chatId) {
  const d = drafts.get(userId);
  const steps = STEPS[d.kind];
  const lines = [`📋 **Check your request** — ${KINDS[d.kind].label}`, ''];
  steps.forEach((st, n) => lines.push(`${n + 1}. **${st.label}:** ${shown(st, d.answers[st.key])}`));
  lines.push('', 'Is everything right? Documents are seen only by the Hushavia team.');
  const edit = steps.map((st, n) => btn(`✏️ ${n + 1}`, `e:${n}`));
  const rows = [];
  for (let n = 0; n < edit.length; n += 4) rows.push(edit.slice(n, n + 4));
  return sys().say('verify', chatId, lines.join('\n'), [[btn('✅ Send to Hushavia', 'send')], ...rows, [btn('✖ Cancel', 'cancel')]]);
}

async function answer(userId, chatId, row) {
  const d = drafts.get(userId);
  const st = STEPS[d.kind][d.i];
  if (!st) return review(userId, chatId);
  if (st.type === 'photo') {
    const own = row && row.media_id && row.type === 'image'
      && await db.one('SELECT id FROM media WHERE id = $1 AND uploader_id = $2', [row.media_id, userId]);
    if (!own) return sys().say('verify', chatId, '📷 Please send a photo for this step (not a file or text).');
    d.answers[st.key] = Number(own.id);
  } else {
    const t = String((row && row.text) || '').trim();
    if (!t) return sys().say('verify', chatId, '✍️ Please type your answer.');
    if (st.min && t.length < st.min) return sys().say('verify', chatId, `That looks too short — please write a bit more (at least ${st.min} characters).`);
    if (st.max && t.length > st.max) return sys().say('verify', chatId, `That’s too long — please keep it under ${st.max} characters.`);
    if (st.link && !URL_RE.test(t)) return sys().say('verify', chatId, '🔗 Please send at least one link (e.g. https://example.com).');
    if (st.chat) {
      const m = /@?([A-Za-z0-9_]{4,32})/.exec(t);
      const c = m && await db.one(
        `SELECT c.id, c.title FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2 AND cm.role = 'owner'
         WHERE lower(c.username) = lower($1) AND c.type <> 'private'`,
        [m[1], userId],
      );
      if (!c) return sys().say('verify', chatId, 'I couldn’t find a public channel or group with that @username that you own. Check the username and try again.');
      d.chatId = Number(c.id);
      d.answers[st.key] = `@${m[1]} (${c.title})`;
    } else {
      d.answers[st.key] = t;
    }
  }
  return next(userId, chatId);
}

async function next(userId, chatId) {
  const d = drafts.get(userId);
  if (d.editing) {
    d.editing = false;
    d.i = STEPS[d.kind].length;
    return review(userId, chatId);
  }
  d.i += 1;
  return ask(userId, chatId);
}

async function submit(userId, chatId) {
  const d = drafts.get(userId);
  if (!d) return home(userId, chatId);
  const steps = STEPS[d.kind];
  const missing = steps.find((st) => !st.optional && (d.answers[st.key] === undefined || d.answers[st.key] === ''));
  if (missing) {
    d.i = steps.indexOf(missing);
    d.editing = true;
    await sys().say('verify', chatId, `“${missing.label}” is still missing.`);
    return ask(userId, chatId);
  }
  const fields = steps.filter((st) => st.type !== 'photo').map((st) => ({ label: st.label, value: d.answers[st.key] || '' })).filter((f) => f.value);
  const photos = steps.filter((st) => st.type === 'photo' && d.answers[st.key]).map((st) => ({ label: st.label, media_id: d.answers[st.key] }));
  const r = await db.one(
    `INSERT INTO verify_requests (user_id, kind, chat_id, details, media_ids, fields) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
    [userId, d.kind, d.chatId || null, fields.map((f) => `${f.label}: ${f.value}`).join('\n').slice(0, 4000),
      JSON.stringify(photos.map((p) => p.media_id)), JSON.stringify({ fields, photos })],
  );
  drafts.delete(userId);
  return sys().say('verify', chatId,
    `📨 **Request ${ref(r.id)} sent**\n\nThe Hushavia team checks requests by hand — usually within 3 working days. I’ll message you here with the answer.`,
    [[btn('📄 My requests', 'status')]]);
}

async function onMessage(userId, chatId, row) {
  const t = String((row && row.text) || '').trim();
  const d = drafts.get(userId);
  if (t === '/cancel') {
    drafts.delete(userId);
    return sys().say('verify', chatId, 'Cancelled. Nothing was sent.', [[btn('🛡️ Start again', 'home')]]);
  }
  if (t === '/status') return myRequests(userId, chatId);
  if (!d || t === '/start') return home(userId, chatId);
  return answer(userId, chatId, row);
}

async function onCallback(userId, chatId, data) {
  const s = String(data || '');
  const d = drafts.get(userId);
  if (s.startsWith('k:') && KINDS[s.slice(2)]) return start(userId, chatId, s.slice(2));
  if (s === 'status') return myRequests(userId, chatId);
  if (s === 'cancel') {
    drafts.delete(userId);
    return sys().say('verify', chatId, 'Cancelled. Nothing was sent.', [[btn('🛡️ Start again', 'home')]]);
  }
  if (!d) return home(userId, chatId);
  if (s === 'send') return submit(userId, chatId);
  if (s === 'back' && d.i > 0) {
    d.i -= 1;
    return ask(userId, chatId);
  }
  if (s === 'skip') {
    const st = STEPS[d.kind][d.i];
    if (st && st.optional) {
      delete d.answers[st.key];
      return next(userId, chatId);
    }
  }
  if (s.startsWith('e:')) {
    const n = parseInt(s.slice(2), 10);
    if (STEPS[d.kind][n]) {
      d.i = n;
      d.editing = true;
      return ask(userId, chatId);
    }
  }
  return ask(userId, chatId);
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
      ref: ref(r.id),
      details: r.details,
      fields: (r.fields && r.fields.fields) || null,
      photos: (r.fields && r.fields.photos) || (r.media_ids || []).map((m) => ({ label: 'Document', media_id: m })),
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
      ? `🎉 **Request ${ref(r.id)} approved**\n\nYour ${KINDS[r.kind].label.toLowerCase()} badge is on now.${note ? `\n\n${note}` : ''}`
      : `**Request ${ref(r.id)} was not approved**\n\nReason: ${note}\n\nYou can send a new request with more proof.`).catch(() => null);
  return { ok: true };
}

async function sysChat(userId) {
  const botId = await sys().ensureOne('verify');
  const c = await require('./chat.service').getOrCreatePrivate(userId, botId); // eslint-disable-line global-require
  return { chat: c.id };
}

module.exports = { onMessage, onCallback, adminList, adminDecide, KINDS };
