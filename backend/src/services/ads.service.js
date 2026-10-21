'use strict';

/**
 * Sponsored messages: short text ads shown at the bottom of big public channels
 * (never in private chats or groups, never to Premium users). Sold by the admin team;
 * price_pkr is recorded for the revenue report. One impression per user per campaign per day.
 */
const db = require('../db');
const settings = require('./settings.service');
const payments = require('./payment.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, notFound } = require('../utils/errors');

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function serialize(c) {
  return {
    id: c.id,
    advertiser: c.advertiser,
    text: c.text,
    button_text: c.button_text,
    url: c.url,
    target_chat_ids: c.target_chat_ids || [],
    min_subscribers: c.min_subscribers,
    status: c.status,
    starts_at: iso(c.starts_at),
    ends_at: iso(c.ends_at),
    max_impressions: c.max_impressions,
    impressions: c.impressions,
    clicks: c.clicks,
    ctr: c.impressions ? Math.round((c.clicks / c.impressions) * 1000) / 10 : 0,
    price_pkr: c.price_pkr,
    created_at: iso(c.created_at),
  };
}

/** The ad to show under this channel for this user, or null. */
async function sponsoredFor(userId, chatIdRaw) {
  const s = await settings.getAll();
  if (!s.feature_ads) return { ad: null };
  const chatId = v.id(chatIdRaw, 'chat_id');
  const chat = await db.one(
    `SELECT c.id, c.type, c.is_public, (SELECT count(*)::int FROM chat_members m WHERE m.chat_id = c.id) AS n
     FROM chats c JOIN chat_members me ON me.chat_id = c.id AND me.user_id = $2 WHERE c.id = $1`,
    [chatId, userId],
  );
  if (!chat || chat.type !== 'channel' || !chat.is_public || chat.n < s.ads_min_subscribers) return { ad: null };
  if (!(await payments.limitsFor(userId)).ads) return { ad: null }; // Premium: no ads
  const rows = await db.many(
    `SELECT c.* FROM ad_campaigns c
     WHERE c.status = 'active'
       AND (c.starts_at IS NULL OR c.starts_at <= now()) AND (c.ends_at IS NULL OR c.ends_at > now())
       AND (c.max_impressions IS NULL OR c.impressions < c.max_impressions)
       AND c.min_subscribers <= $2
       AND (jsonb_array_length(c.target_chat_ids) = 0 OR c.target_chat_ids @> to_jsonb($1::bigint))
     ORDER BY (SELECT count(*) FROM ad_views w WHERE w.campaign_id = c.id AND w.user_id = $3 AND w.day = current_date), c.impressions
     LIMIT 1`,
    [chatId, chat.n, userId],
  );
  if (!rows.length) return { ad: null };
  const c = rows[0];
  return { ad: { id: c.id, advertiser: c.advertiser, text: c.text, button_text: c.button_text, url: c.url } };
}

async function recordView(userId, idRaw) {
  const id = v.id(idRaw, 'ad_id');
  if (!rateLimit.hit(`adview:${userId}`, 60, 60 * 1000).allowed) return { ok: true };
  const r = await db.many('INSERT INTO ad_views (campaign_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING campaign_id', [id, userId]);
  if (r.length) await db.query('UPDATE ad_campaigns SET impressions = impressions + 1 WHERE id = $1', [id]);
  return { ok: true };
}

async function recordClick(userId, idRaw) {
  const id = v.id(idRaw, 'ad_id');
  await db.query('INSERT INTO ad_views (campaign_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [id, userId]);
  const r = await db.many(
    `UPDATE ad_views SET clicked = TRUE WHERE campaign_id = $1 AND user_id = $2 AND day = current_date AND NOT clicked RETURNING campaign_id`,
    [id, userId],
  );
  if (r.length) await db.query('UPDATE ad_campaigns SET clicks = clicks + 1 WHERE id = $1', [id]);
  const c = await db.one('SELECT url FROM ad_campaigns WHERE id = $1', [id]);
  return { url: c ? c.url : null };
}

// ------------------------------------------------------------------ admin
function readCampaign(body) {
  const url = String(body.url || '').trim();
  try {
    if (!/^https?:$/.test(new URL(url).protocol)) throw new Error('x');
  } catch (_) {
    throw badRequest('invalid_url', 'Link must start with http:// or https://');
  }
  const ids = Array.isArray(body.target_chat_ids) ? body.target_chat_ids.map((x) => v.id(x, 'target_chat_ids')) : [];
  const date = (x, f) => {
    if (!x) return null;
    const d = new Date(x);
    if (Number.isNaN(d.getTime())) throw badRequest('invalid_input', `Invalid ${f}`);
    return d.toISOString();
  };
  const maxImp = body.max_impressions === undefined || body.max_impressions === null || body.max_impressions === '' ? null : parseInt(body.max_impressions, 10);
  if (maxImp !== null && (!Number.isInteger(maxImp) || maxImp < 1)) throw badRequest('invalid_input', 'Invalid impression limit');
  const price = parseInt(body.price_pkr || 0, 10);
  if (!Number.isInteger(price) || price < 0) throw badRequest('invalid_input', 'Invalid price');
  return {
    advertiser: v.str(body.advertiser, { field: 'advertiser', min: 1, max: 80, required: true }),
    text: v.str(body.text, { field: 'text', min: 1, max: 300, required: true }),
    button_text: v.str(body.button_text, { field: 'button_text', max: 30 }) || 'Open',
    url,
    target_chat_ids: JSON.stringify([...new Set(ids)].slice(0, 500)),
    min_subscribers: Math.max(0, parseInt(body.min_subscribers || 0, 10) || 0),
    status: v.oneOf(body.status || 'active', ['active', 'paused', 'ended'], 'status'),
    starts_at: date(body.starts_at, 'start date'),
    ends_at: date(body.ends_at, 'end date'),
    max_impressions: maxImp,
    price_pkr: price,
  };
}

async function adminList() {
  return (await db.many('SELECT * FROM ad_campaigns ORDER BY id DESC LIMIT 500')).map(serialize);
}

async function adminSave(adminId, idRaw, body = {}) {
  const c = readCampaign(body);
  const vals = [c.advertiser, c.text, c.button_text, c.url, c.target_chat_ids, c.min_subscribers, c.status, c.starts_at, c.ends_at, c.max_impressions, c.price_pkr];
  const r = idRaw
    ? await db.one(
      `UPDATE ad_campaigns SET advertiser = $2, text = $3, button_text = $4, url = $5, target_chat_ids = $6::jsonb, min_subscribers = $7,
         status = $8, starts_at = $9, ends_at = $10, max_impressions = $11, price_pkr = $12 WHERE id = $1 RETURNING *`,
      [v.id(idRaw, 'ad_id'), ...vals],
    )
    : await db.one(
      `INSERT INTO ad_campaigns (advertiser, text, button_text, url, target_chat_ids, min_subscribers, status, starts_at, ends_at, max_impressions, price_pkr, created_by)
       VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9, $10, $11, $12) RETURNING *`,
      [...vals, adminId],
    );
  if (!r) throw notFound('ad_not_found', 'Campaign not found');
  return serialize(r);
}

async function adminDelete(idRaw) {
  await db.query('DELETE FROM ad_campaigns WHERE id = $1', [v.id(idRaw, 'ad_id')]);
  return { ok: true };
}

/** Revenue report: Premium payments + sold ad campaigns, last 12 months. */
async function adminRevenue() {
  const months = await db.many(
    `SELECT to_char(m, 'YYYY-MM') AS month,
            COALESCE((SELECT sum(amount_pkr) FROM payment_orders WHERE status = 'paid' AND paid_at >= m AND paid_at < m + interval '1 month'), 0)::int AS premium_pkr,
            COALESCE((SELECT sum(price_pkr) FROM ad_campaigns WHERE created_at >= m AND created_at < m + interval '1 month'), 0)::int AS ads_pkr
     FROM generate_series(date_trunc('month', now()) - interval '11 months', date_trunc('month', now()), interval '1 month') m ORDER BY m`,
  );
  const byProvider = await db.many(
    `SELECT provider, count(*)::int AS payments, COALESCE(sum(amount_pkr), 0)::int AS amount_pkr
     FROM payment_orders WHERE status = 'paid' GROUP BY provider ORDER BY amount_pkr DESC`,
  );
  const t = await db.one(
    `SELECT
       COALESCE((SELECT sum(amount_pkr) FROM payment_orders WHERE status = 'paid'), 0)::int AS premium_total,
       COALESCE((SELECT sum(amount_pkr) FROM payment_orders WHERE status = 'paid' AND paid_at >= date_trunc('month', now())), 0)::int AS premium_this_month,
       COALESCE((SELECT sum(price_pkr) FROM ad_campaigns), 0)::int AS ads_total,
       (SELECT count(*)::int FROM users WHERE premium_until > now()) AS premium_users,
       (SELECT count(*)::int FROM payment_orders WHERE status = 'review') AS to_review,
       (SELECT count(*)::int FROM payment_orders WHERE status = 'paid' AND paid_at > now() - interval '30 days') AS payments_30d`,
  );
  return { ...t, total: t.premium_total + t.ads_total, months, by_provider: byProvider };
}

module.exports = { sponsoredFor, recordView, recordClick, adminList, adminSave, adminDelete, adminRevenue };
