'use strict';

/**
 * Sponsored messages: short ads shown at the end of big public channels (never in private chats
 * or groups, never to Hushavia Plus members).
 *
 * Two kinds of campaign:
 *  - sold by the team in the admin panel (owner_id NULL): free to run, price_pkr only for the report;
 *  - self-service (owner_id = a member): paid in coins. The budget is held when the ad is made,
 *    each counted view costs cpm/1000 coins, the channel's owner earns a share, and whatever is
 *    not spent goes back when the ad ends. A new or edited ad waits for the team's review.
 *
 * A view counts once per person per ad per day, only for real (non-bot) members.
 * Money is counted in millis (1 coin = 1,000) so a single view can cost a fraction of a coin.
 */
const db = require('../db');
const settings = require('./settings.service');
const payments = require('./payment.service');
const coins = require('./coin.service');
const money = require('../utils/currency');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, notFound, forbidden, conflict } = require('../utils/errors');

const CATEGORIES = ['news', 'tech', 'sports', 'entertainment', 'education', 'business', 'religion', 'lifestyle', 'gaming', 'other'];
const notice = () => require('./notice.service'); // eslint-disable-line global-require
const iso = (d) => (d ? new Date(d).toISOString() : null);
const fmt = (n) => Number(n).toLocaleString('en-US');

function serialize(c, extra = {}) {
  const spent = Math.ceil(Number(c.spent_millis || 0) / 1000);
  return {
    id: c.id,
    advertiser: c.advertiser,
    text: c.text,
    button_text: c.button_text,
    url: c.url,
    target_chat_ids: c.target_chat_ids || [],
    categories: c.categories || [],
    countries: c.countries || [],
    min_subscribers: c.min_subscribers,
    status: c.status,
    review: c.review,
    reject_reason: c.reject_reason || null,
    starts_at: iso(c.starts_at),
    ends_at: iso(c.ends_at),
    max_impressions: c.max_impressions,
    impressions: c.impressions,
    clicks: c.clicks,
    ctr: c.impressions ? Math.round((c.clicks / c.impressions) * 1000) / 10 : 0,
    price_pkr: c.price_pkr,
    self_serve: !!c.owner_id,
    owner_id: c.owner_id || null,
    cpm_coins: c.cpm_coins,
    budget_coins: c.budget_coins,
    spent_coins: spent,
    left_coins: c.owner_id ? Math.max(0, c.budget_coins - spent - (c.refunded_coins || 0)) : null,
    daily_cap_coins: c.daily_cap_coins || null,
    created_at: iso(c.created_at),
    ...extra,
  };
}

// ------------------------------------------------------------------ showing ads
/** The ad to show under this channel for this user, or null. */
async function sponsoredFor(userId, chatIdRaw) {
  const s = await settings.getAll();
  if (!s.feature_ads) return { ad: null };
  const chatId = v.id(chatIdRaw, 'chat_id');
  const chat = await db.one(
    `SELECT c.id, c.type, c.is_public, c.category, c.ads_off, c.member_count AS n
     FROM chats c JOIN chat_members me ON me.chat_id = c.id AND me.user_id = $2 WHERE c.id = $1`,
    [chatId, userId],
  );
  if (!chat || chat.type !== 'channel' || !chat.is_public || chat.ads_off || chat.n < s.ads_min_subscribers) return { ad: null };
  if (!(await payments.limitsFor(userId)).ads) return { ad: null }; // Plus: no ads
  const me = await db.one('SELECT phone, is_bot FROM users WHERE id = $1', [userId]);
  if (!me || me.is_bot) return { ad: null };
  const country = money.countryFromPhone(me.phone) || null;
  const rows = await db.many(
    `SELECT c.* FROM ad_campaigns c
     WHERE c.status = 'active' AND c.review = 'approved'
       AND (c.starts_at IS NULL OR c.starts_at <= now()) AND (c.ends_at IS NULL OR c.ends_at > now())
       AND (c.max_impressions IS NULL OR c.impressions < c.max_impressions)
       AND c.min_subscribers <= $2
       AND (c.owner_id IS NULL OR c.spent_millis + c.cpm_coins <= (c.budget_coins - c.refunded_coins)::bigint * 1000)
       AND (c.owner_id IS NULL OR c.owner_id <> $3)
       AND (c.daily_cap_coins IS NULL OR COALESCE((SELECT d.millis FROM ad_daily d WHERE d.campaign_id = c.id AND d.day = current_date), 0) + c.cpm_coins <= c.daily_cap_coins::bigint * 1000)
       AND (jsonb_array_length(c.target_chat_ids) = 0 OR c.target_chat_ids @> to_jsonb($1::bigint))
       AND (jsonb_array_length(c.categories) = 0 OR ($4::text IS NOT NULL AND c.categories ? $4::text))
       AND (jsonb_array_length(c.countries) = 0 OR ($5::text IS NOT NULL AND c.countries ? $5::text))
     ORDER BY (SELECT count(*) FROM ad_views w WHERE w.campaign_id = c.id AND w.user_id = $3 AND w.day = current_date),
              c.cpm_coins DESC, c.impressions
     LIMIT 1`,
    [chatId, chat.n, userId, chat.category || null, country],
  );
  if (!rows.length) return { ad: null };
  const c = rows[0];
  return { ad: { id: c.id, advertiser: c.advertiser, text: c.text, button_text: c.button_text, url: c.url } };
}

/** A person saw the ad. Counted (and paid for) once per person per ad per day. */
async function recordView(userId, idRaw, body = {}) {
  const id = v.id(idRaw, 'ad_id');
  if (!rateLimit.hit(`adview:${userId}`, 60, 60 * 1000).allowed) return { ok: true };
  const chatId = body && body.chat_id ? v.id(body.chat_id, 'chat_id') : null;
  const s = await settings.getAll();
  await db.tx(async (c) => {
    const camp = (await c.query('SELECT * FROM ad_campaigns WHERE id = $1 FOR UPDATE', [id])).rows[0];
    if (!camp || camp.status !== 'active' || camp.review !== 'approved') return;
    const real = (await c.query('SELECT 1 FROM users WHERE id = $1 AND NOT is_bot', [userId])).rows[0];
    if (!real || camp.owner_id === userId) return;
    const paid = !!camp.owner_id;
    const cost = paid ? camp.cpm_coins : 0;
    if (paid && Number(camp.spent_millis) + cost > (camp.budget_coins - camp.refunded_coins) * 1000) return;
    // the channel must really be one this person is in (no paying a stranger's channel)
    let channel = null;
    if (chatId) {
      channel = (await c.query(
        `SELECT ch.id, (ch.monetized AND NOT ch.is_suspended) AS monetized, (SELECT o.user_id FROM chat_members o WHERE o.chat_id = ch.id AND o.role = 'owner' LIMIT 1) AS owner
         FROM chats ch JOIN chat_members m ON m.chat_id = ch.id AND m.user_id = $2 WHERE ch.id = $1 AND ch.type = 'channel' AND NOT ch.ads_off`,
        [chatId, userId],
      )).rows[0] || null;
    }
    const added = (await c.query(
      'INSERT INTO ad_views (campaign_id, user_id, chat_id, cost_millis) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING RETURNING campaign_id',
      [id, userId, channel ? channel.id : null, cost],
    )).rows[0];
    if (!added) return;
    await c.query('UPDATE ad_campaigns SET impressions = impressions + 1, spent_millis = spent_millis + $2 WHERE id = $1', [id, cost]);
    await c.query(
      `INSERT INTO ad_daily (campaign_id, views, millis) VALUES ($1, 1, $2)
       ON CONFLICT (campaign_id, day) DO UPDATE SET views = ad_daily.views + 1, millis = ad_daily.millis + $2`,
      [id, cost],
    );
    // the owner's share only for monetized channels (the view still counts for the advertiser)
    if (paid && channel && channel.owner && channel.owner !== camp.owner_id && channel.monetized) {
      const share = Math.floor((cost * s.ads_owner_percent) / 100);
      if (share > 0) {
        await c.query(
          `INSERT INTO ad_owner_earnings (owner_id, pending_millis, views) VALUES ($1, $2, 1)
           ON CONFLICT (owner_id) DO UPDATE SET pending_millis = ad_owner_earnings.pending_millis + $2, views = ad_owner_earnings.views + 1`,
          [channel.owner, share],
        );
      }
    }
  });
  return { ok: true };
}

async function recordClick(userId, idRaw) {
  const id = v.id(idRaw, 'ad_id');
  await db.query('INSERT INTO ad_views (campaign_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [id, userId]);
  const r = await db.many(
    `UPDATE ad_views SET clicked = TRUE WHERE campaign_id = $1 AND user_id = $2 AND day = current_date AND NOT clicked RETURNING campaign_id`,
    [id, userId],
  );
  if (r.length) {
    await db.query('UPDATE ad_campaigns SET clicks = clicks + 1 WHERE id = $1', [id]);
    await db.query(
      `INSERT INTO ad_daily (campaign_id, clicks) VALUES ($1, 1) ON CONFLICT (campaign_id, day) DO UPDATE SET clicks = ad_daily.clicks + 1`,
      [id],
    );
  }
  const c = await db.one('SELECT url FROM ad_campaigns WHERE id = $1', [id]);
  return { url: c ? c.url : null };
}

// ------------------------------------------------------------------ self-service
function readUrl(raw) {
  const url = String(raw || '').trim();
  const at = /^@([A-Za-z][A-Za-z0-9_]{3,31})$/.exec(url);
  if (at) return `${require('../config').publicUrl}/c/${at[1]}`; // eslint-disable-line global-require
  try {
    if (!/^https?:$/.test(new URL(url).protocol)) throw new Error('x');
  } catch (_) {
    throw badRequest('invalid_url', 'The link must start with https:// — or be a @username of a channel, group or bot');
  }
  if (url.length > 500) throw badRequest('invalid_url', 'The link is too long');
  return url;
}

const list = (x, ok, max, f) => {
  if (x === undefined || x === null) return [];
  if (!Array.isArray(x)) throw badRequest('invalid_input', `${f} must be a list`);
  const out = [...new Set(x.map((y) => String(y).trim()).filter(Boolean))];
  for (const y of out) if (ok && !ok(y)) throw badRequest('invalid_input', `Unknown ${f}: ${y}`);
  return out.slice(0, max);
};

async function meta(userId) {
  const s = await settings.getAll();
  const u = await db.one('SELECT coins FROM users WHERE id = $1', [userId]);
  const reach = await db.one(
    `SELECT count(*)::int AS channels, COALESCE(sum(member_count), 0)::bigint AS subscribers FROM chats
     WHERE type = 'channel' AND is_public AND NOT is_suspended AND NOT ads_off AND member_count >= $1`,
    [s.ads_min_subscribers],
  );
  return {
    open: !!(s.feature_ads && s.ads_self_serve && s.feature_coins),
    categories: CATEGORIES,
    min_cpm: s.ads_min_cpm,
    min_budget: s.ads_min_budget,
    owner_percent: s.ads_owner_percent,
    min_subscribers: s.ads_min_subscribers,
    balance: Number(u ? u.coins : 0),
    reach: { channels: reach.channels, subscribers: Number(reach.subscribers) },
  };
}

async function requireOpen() {
  const s = await settings.getAll();
  if (!s.feature_ads || !s.ads_self_serve) throw forbidden('ads_off', 'Advertising is not open right now');
  await settings.requireFeature('feature_coins', 'Coins');
  return s;
}

/** A new self-service ad: the budget is held now, the ad waits for review. */
async function create(userId, body = {}) {
  const s = await requireOpen();
  const cpm = Number(body.cpm_coins);
  const budget = Number(body.budget_coins);
  const cap = body.daily_cap_coins === undefined || body.daily_cap_coins === null || body.daily_cap_coins === '' ? null : Number(body.daily_cap_coins);
  if (!Number.isInteger(cpm) || cpm < s.ads_min_cpm || cpm > 100000) throw badRequest('invalid_input', `The price for 1,000 views must be at least ${fmt(s.ads_min_cpm)} coins`);
  if (!Number.isInteger(budget) || budget < s.ads_min_budget || budget > 10000000) throw badRequest('invalid_input', `The budget must be at least ${fmt(s.ads_min_budget)} coins`);
  if (cap !== null && (!Number.isInteger(cap) || cap < cpm)) throw badRequest('invalid_input', 'The daily limit must be at least the price of 1,000 views');
  const row = {
    advertiser: v.str(body.advertiser, { field: 'advertiser', min: 1, max: 40, required: true }),
    text: v.str(body.text, { field: 'text', min: 5, max: 160, required: true }),
    button_text: v.str(body.button_text, { field: 'button_text', max: 24 }) || 'Open',
    url: readUrl(body.url),
    categories: list(body.categories, (x) => CATEGORIES.includes(x), 10, 'category'),
    countries: list(body.countries, (x) => /^[A-Z]{2}$/.test(x), 30, 'country'),
  };
  const open = await db.one(`SELECT count(*)::int AS n FROM ad_campaigns WHERE owner_id = $1 AND status <> 'ended'`, [userId]);
  if (open.n >= 20) throw conflict('too_many', 'You have 20 ads running. Stop one first.');
  rateLimit.enforce(`ads:new:${userId}`, 20, 24 * 3600 * 1000, 'Too many new ads today. Try again tomorrow.');
  const r = await db.tx(async (c) => {
    const a = (await c.query(
      `INSERT INTO ad_campaigns (advertiser, text, button_text, url, categories, countries, owner_id, review, status, cpm_coins, budget_coins, daily_cap_coins)
       VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7, 'pending', 'active', $8, $9, $10) RETURNING *`,
      [row.advertiser, row.text, row.button_text, row.url, JSON.stringify(row.categories), JSON.stringify(row.countries), userId, cpm, budget, cap],
    )).rows[0];
    a.balance = await coins.change(c, userId, -budget, 'ad_budget', { note: row.advertiser });
    return a;
  });
  coins.announce(userId, r.balance);
  return { balance: r.balance, ad: serialize(r) };
}

async function mine(userId) {
  const rows = await db.many('SELECT * FROM ad_campaigns WHERE owner_id = $1 ORDER BY id DESC LIMIT 100', [userId]);
  return rows.map((c) => serialize(c));
}

async function myAd(userId, idRaw) {
  const c = await db.one('SELECT * FROM ad_campaigns WHERE id = $1 AND owner_id = $2', [v.id(idRaw, 'ad_id'), userId]);
  if (!c) throw notFound('ad_not_found', 'Ad not found');
  return c;
}

async function stats(userId, idRaw) {
  const c = await myAd(userId, idRaw);
  const days = await db.many(
    `SELECT to_char(d, 'YYYY-MM-DD') AS day, COALESCE(a.views, 0) AS views, COALESCE(a.clicks, 0) AS clicks, COALESCE(a.millis, 0)::bigint AS millis
     FROM generate_series(current_date - 13, current_date, interval '1 day') d LEFT JOIN ad_daily a ON a.campaign_id = $1 AND a.day = d::date ORDER BY d`,
    [c.id],
  );
  const top = await db.many(
    `SELECT ch.title, ch.username, count(*)::int AS views FROM ad_views w JOIN chats ch ON ch.id = w.chat_id
     WHERE w.campaign_id = $1 GROUP BY ch.id ORDER BY views DESC LIMIT 5`,
    [c.id],
  );
  return serialize(c, {
    days: days.map((d) => ({ day: d.day, views: d.views, clicks: d.clicks, coins: Math.round(Number(d.millis) / 100) / 10 })),
    top_channels: top,
  });
}

/** Hands back what is not spent (once), and ends the ad. */
async function finish(c, reason) {
  const spent = Math.ceil(Number(c.spent_millis) / 1000);
  const back = Math.max(0, c.budget_coins - c.refunded_coins - spent);
  const r = await db.tx(async (t) => {
    const a = (await t.query(`UPDATE ad_campaigns SET status = 'ended', refunded_coins = refunded_coins + $2, updated_at = now() WHERE id = $1 AND status <> 'ended' RETURNING *`, [c.id, back])).rows[0];
    if (!a) return null;
    const balance = back > 0 ? await coins.change(t, c.owner_id, back, 'ad_refund', { note: c.advertiser }) : null;
    return { a, balance };
  });
  if (r && r.balance !== null) coins.announce(c.owner_id, r.balance);
  if (r && reason) await notice().notify(c.owner_id, 'payment', `Your ad “${c.advertiser}” ended`, `${reason}${back > 0 ? ` ${fmt(back)} unspent coins are back in your balance.` : ''}`, { ad_id: c.id });
  return r ? r.a : null;
}

async function setState(userId, idRaw, action, body = {}) {
  await settings.requireFeature('feature_coins', 'Coins');
  const c = await myAd(userId, idRaw);
  if (c.status === 'ended') throw conflict('ad_ended', 'This ad has ended');
  if (action === 'pause' || action === 'resume') {
    const r = await db.one('UPDATE ad_campaigns SET status = $2, updated_at = now() WHERE id = $1 RETURNING *', [c.id, action === 'pause' ? 'paused' : 'active']);
    return serialize(r);
  }
  if (action === 'stop') return serialize(await finish(c, null) || c);
  if (action === 'topup') {
    const more = Number(body.coins);
    if (!Number.isInteger(more) || more < 1 || more > 10000000) throw badRequest('invalid_input', 'Add between 1 and 10,000,000 coins');
    const r = await db.tx(async (t) => {
      const a = (await t.query(`UPDATE ad_campaigns SET budget_coins = budget_coins + $2, updated_at = now() WHERE id = $1 AND status <> 'ended' RETURNING *`, [c.id, more])).rows[0];
      if (!a) throw conflict('ad_ended', 'This ad has ended');
      a.balance = await coins.change(t, userId, -more, 'ad_budget', { note: c.advertiser });
      return a;
    });
    coins.announce(userId, r.balance);
    return { ...serialize(r), balance: r.balance };
  }
  throw badRequest('invalid_input', 'Unknown action');
}

/** A channel owner turns ads on their channel off (or on). */
async function setChannelAds(userId, chatIdRaw, body = {}) {
  const chat = await require('./chat.service').requireMember(chatIdRaw, userId); // eslint-disable-line global-require
  if (chat.type !== 'channel' || chat.my_role !== 'owner') throw forbidden('forbidden', 'Only the channel’s owner can change this');
  const off = v.bool(body.off, 'off');
  await db.query('UPDATE chats SET ads_off = $2 WHERE id = $1', [chat.id, off]);
  const e = await db.one('SELECT paid_coins, views FROM ad_owner_earnings WHERE owner_id = $1', [userId]);
  return { ads_off: off, earned_coins: e ? Number(e.paid_coins) : 0 };
}

/** Scheduler: pays channel owners in whole coins, ends ads whose budget is used up. */
async function sweep() {
  const due = await db.many('SELECT owner_id FROM ad_owner_earnings WHERE pending_millis >= 1000 LIMIT 200');
  for (const d of due) {
    try {
      const r = await db.tx(async (c) => {
        const row = (await c.query('SELECT pending_millis FROM ad_owner_earnings WHERE owner_id = $1 FOR UPDATE', [d.owner_id])).rows[0];
        const whole = Math.floor(Number(row.pending_millis) / 1000);
        if (whole < 1) return null;
        await c.query('UPDATE ad_owner_earnings SET pending_millis = pending_millis - $2, paid_coins = paid_coins + $3 WHERE owner_id = $1', [d.owner_id, whole * 1000, whole]);
        return { whole, balance: await coins.change(c, d.owner_id, whole, 'ad_income', { note: 'Sponsored messages' }) };
      });
      if (r) coins.announce(d.owner_id, r.balance);
    } catch (_) {
      /* the next round tries again */
    }
  }
  const done = await db.many(
    `SELECT * FROM ad_campaigns WHERE owner_id IS NOT NULL AND status <> 'ended' AND review = 'approved'
       AND spent_millis + GREATEST(cpm_coins, 1) > (budget_coins - refunded_coins)::bigint * 1000 LIMIT 50`,
  );
  for (const c of done) await finish(c, 'Its budget is used up.').catch(() => {});
}

// ------------------------------------------------------------------ admin
function readCampaign(body) {
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
    url: readUrl(body.url),
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
  const rows = await db.many(
    `SELECT c.*, u.first_name, u.username FROM ad_campaigns c LEFT JOIN users u ON u.id = c.owner_id
     ORDER BY (c.review = 'pending') DESC, c.id DESC LIMIT 500`,
  );
  return rows.map((c) => serialize(c, { owner: c.owner_id ? { id: c.owner_id, name: c.first_name, username: c.username } : null }));
}

async function adminSave(adminId, idRaw, body = {}) {
  if (idRaw) {
    const cur = await db.one('SELECT owner_id FROM ad_campaigns WHERE id = $1', [v.id(idRaw, 'ad_id')]);
    if (cur && cur.owner_id) throw badRequest('invalid_input', 'A member’s own ad can only be approved, rejected or stopped');
  }
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

/** The team's decision on a member's ad. Rejecting returns the whole unspent budget. */
async function adminReview(idRaw, body = {}) {
  const c = await db.one('SELECT * FROM ad_campaigns WHERE id = $1 AND owner_id IS NOT NULL', [v.id(idRaw, 'ad_id')]);
  if (!c) throw notFound('ad_not_found', 'Ad not found');
  const decision = v.oneOf(body.decision, ['approve', 'reject'], 'decision');
  if (decision === 'approve') {
    const r = await db.one(`UPDATE ad_campaigns SET review = 'approved', reject_reason = NULL, updated_at = now() WHERE id = $1 RETURNING *`, [c.id]);
    await notice().notify(c.owner_id, 'payment', `Your ad “${c.advertiser}” is running`, 'It was approved and is now shown in channels. Watch its results in Settings → Advertise.', { ad_id: c.id });
    return serialize(r);
  }
  const reason = v.str(body.reason, { field: 'reason', max: 300 }) || 'It doesn’t follow the advertising rules.';
  await db.query(`UPDATE ad_campaigns SET review = 'rejected', reject_reason = $2, updated_at = now() WHERE id = $1`, [c.id, reason]);
  const r = await finish({ ...c, review: 'rejected' }, `It was not approved: ${reason}`);
  return serialize(r || c);
}

async function adminDelete(idRaw) {
  const c = await db.one('SELECT * FROM ad_campaigns WHERE id = $1', [v.id(idRaw, 'ad_id')]);
  if (c && c.owner_id && c.status !== 'ended') await finish(c, 'It was removed by the Hushavia team.');
  await db.query('DELETE FROM ad_campaigns WHERE id = $1', [v.id(idRaw, 'ad_id')]);
  return { ok: true };
}

/** Revenue report: Plus payments, sold campaigns and coin-paid ads, last 12 months. */
async function adminRevenue() {
  const months = await db.many(
    `SELECT to_char(m, 'YYYY-MM') AS month,
            COALESCE((SELECT sum(amount_pkr) FROM payment_orders WHERE status = 'paid' AND paid_at >= m AND paid_at < m + interval '1 month'), 0)::int AS premium_pkr,
            COALESCE((SELECT sum(price_pkr) FROM ad_campaigns WHERE created_at >= m AND created_at < m + interval '1 month'), 0)::int AS ads_pkr,
            COALESCE((SELECT sum(millis) FROM ad_daily WHERE day >= m AND day < m + interval '1 month'), 0)::bigint / 1000 AS ads_coins
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
       (COALESCE((SELECT sum(spent_millis) FROM ad_campaigns WHERE owner_id IS NOT NULL), 0) / 1000)::bigint AS ads_coins_spent,
       COALESCE((SELECT sum(paid_coins) FROM ad_owner_earnings), 0)::bigint AS ads_coins_to_owners,
       (SELECT count(*)::int FROM ad_campaigns WHERE review = 'pending' AND status <> 'ended') AS ads_to_review,
       (SELECT count(*)::int FROM users WHERE premium_until > now()) AS premium_users,
       (SELECT count(*)::int FROM payment_orders WHERE status = 'review') AS to_review,
       (SELECT count(*)::int FROM payment_orders WHERE status = 'paid' AND paid_at > now() - interval '30 days') AS payments_30d`,
  );
  return { ...t, ads_coins_spent: Number(t.ads_coins_spent), ads_coins_to_owners: Number(t.ads_coins_to_owners), total: t.premium_total + t.ads_total, months, by_provider: byProvider };
}

module.exports = {
  CATEGORIES, sponsoredFor, recordView, recordClick, meta, create, mine, stats, setState, setChannelAds, sweep,
  adminList, adminSave, adminReview, adminDelete, adminRevenue,
};
