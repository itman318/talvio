'use strict';

/**
 * Profile tags.
 *  - warning tags (scam, fake, spam, harassment): only an admin sets them, after checking the reports,
 *    with a reason and the evidence; the person is told and can appeal through support.
 *    Scam / fake accounts also can't sell, send coins or start chats with strangers.
 *  - trust tags (verified_business, official): set by an admin.
 *  - automatic (computed, never stored): new_account (< 7 days), reported (many reports lately),
 *    trusted_seller (10+ catalog sales, no reports in 90 days).
 * The active admin tags are mirrored in users.tags, so every user card carries them without extra queries.
 */
const db = require('../db');
const bus = require('../bus');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const ADMIN_TAGS = {
  scam: { label: 'Scam reports confirmed', warning: true, days: null },
  fake: { label: 'Fake account', warning: true, days: null },
  spam: { label: 'Spam', warning: true, days: 90 },
  harassment: { label: 'Harassment', warning: true, days: 90 },
  verified_business: { label: 'Verified business', warning: false, days: null },
  official: { label: 'Official', warning: false, days: null },
};
const BLOCKING = ['scam', 'fake'];

async function refresh(userId) {
  await db.query(
    `UPDATE users SET tags = COALESCE((SELECT array_agg(DISTINCT tag ORDER BY tag) FROM user_tags
       WHERE user_id = $1 AND removed_at IS NULL AND (expires_at IS NULL OR expires_at > now())), '{}') WHERE id = $1`,
    [userId],
  );
  bus.emit('user:updated', { userId });
}

/** Admin: set a tag (again = renew it with the new reason). */
async function add(adminId, userIdRaw, body = {}) {
  const userId = v.id(userIdRaw, 'user_id');
  const tag = String(body.tag || '');
  const def = ADMIN_TAGS[tag];
  if (!def) throw badRequest('invalid_input', 'Unknown tag');
  const reason = v.str(body.reason, { field: 'reason', min: def.warning ? 5 : 0, max: 500 }) || '';
  const evidence = v.str(body.evidence, { field: 'evidence', max: 2000 }) || '';
  if (def.warning && !evidence) throw badRequest('invalid_input', 'Add the evidence (report numbers, screenshots, message links) for a warning tag');
  const days = body.days === undefined || body.days === null || body.days === '' ? def.days : parseInt(body.days, 10);
  if (days !== null && (!Number.isInteger(days) || days < 1 || days > 3650)) throw badRequest('invalid_input', 'Days must be 1–3650');
  const u = await db.one(`SELECT id FROM users WHERE id = $1 AND status <> 'deleted'`, [userId]);
  if (!u) throw notFound('user_not_found', 'User not found');
  await db.query('UPDATE user_tags SET removed_at = now(), removed_by = $3 WHERE user_id = $1 AND tag = $2 AND removed_at IS NULL', [userId, tag, adminId]);
  await db.query(
    `INSERT INTO user_tags (user_id, tag, reason, evidence, admin_id, expires_at)
     VALUES ($1, $2, $3, $4, $5, CASE WHEN $6::int IS NULL THEN NULL ELSE now() + make_interval(days => $6::int) END)`,
    [userId, tag, reason, evidence, adminId, days],
  );
  await refresh(userId);
  if (def.warning) {
    await require('./notice.service').notify(userId, 'account', `Your profile now shows: ${def.label}`, // eslint-disable-line global-require
      `Reason: ${reason.slice(0, 240)}${days ? ` · for ${days} days` : ''}. If you think this is a mistake, open Settings → Help & support and appeal — tell us what happened.`).catch(() => null);
  }
  return { ok: true };
}

async function remove(adminId, userIdRaw, tagRaw) {
  const userId = v.id(userIdRaw, 'user_id');
  const tag = String(tagRaw || '');
  const r = await db.many('UPDATE user_tags SET removed_at = now(), removed_by = $3 WHERE user_id = $1 AND tag = $2 AND removed_at IS NULL RETURNING id', [userId, tag, adminId]);
  if (!r.length) throw notFound('tag_not_found', 'This tag is not set');
  await refresh(userId);
  if (ADMIN_TAGS[tag] && ADMIN_TAGS[tag].warning) {
    await require('./notice.service').notify(userId, 'account', `“${ADMIN_TAGS[tag].label}” was removed from your profile`, 'Thank you for your patience.').catch(() => null); // eslint-disable-line global-require
  }
  return { ok: true };
}

/** Admin: every tag ever set on this person (who, why, evidence, until when). */
async function history(userIdRaw) {
  const userId = v.id(userIdRaw, 'user_id');
  const rows = await db.many(
    `SELECT t.*, a.name AS admin_name, b.name AS removed_by_name FROM user_tags t
     LEFT JOIN admins a ON a.id = t.admin_id LEFT JOIN admins b ON b.id = t.removed_by
     WHERE t.user_id = $1 ORDER BY t.id DESC LIMIT 100`,
    [userId],
  );
  return {
    tags: Object.entries(ADMIN_TAGS).map(([id, d]) => ({ id, ...d })),
    items: rows.map((r) => ({
      id: Number(r.id),
      tag: r.tag,
      label: (ADMIN_TAGS[r.tag] || {}).label || r.tag,
      reason: r.reason,
      evidence: r.evidence,
      by: r.admin_name,
      at: new Date(r.created_at).toISOString(),
      expires_at: r.expires_at ? new Date(r.expires_at).toISOString() : null,
      active: !r.removed_at && (!r.expires_at || new Date(r.expires_at) > new Date()),
      removed_by: r.removed_by_name || null,
    })),
  };
}

/** Hourly: warning tags whose time is up disappear from the profile. */
async function sweep() {
  const rows = await db.many(
    `SELECT DISTINCT user_id FROM user_tags u WHERE removed_at IS NULL AND expires_at IS NOT NULL AND expires_at <= now()
       AND EXISTS (SELECT 1 FROM users x WHERE x.id = u.user_id AND u.tag = ANY(x.tags))`,
  );
  for (const r of rows) await refresh(r.user_id);
}

/** Tags a card carries (from the users row: no extra query). */
function cardTags(u) {
  const out = [...(u.tags || [])];
  if (!u.is_bot && u.created_at && Date.now() - new Date(u.created_at).getTime() < 7 * 86400000) out.push('new_account');
  return out;
}

async function assertNotBlocked(userId, what) {
  const u = await db.one('SELECT tags FROM users WHERE id = $1', [userId]);
  if (u && (u.tags || []).some((t) => BLOCKING.includes(t))) {
    throw forbidden('account_flagged', `Your account is flagged after confirmed reports, so you can’t ${what}. You can appeal in Help & support.`);
  }
}

async function isFlagged(userId) {
  const u = await db.one('SELECT tags FROM users WHERE id = $1', [userId]);
  return !!(u && (u.tags || []).some((t) => BLOCKING.includes(t)));
}

module.exports = { ADMIN_TAGS, BLOCKING, add, remove, history, sweep, cardTags, assertNotBlocked, isFlagged, refresh };
