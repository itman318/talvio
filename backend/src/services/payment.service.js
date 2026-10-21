'use strict';

/**
 * Premium subscriptions and payments.
 *
 * Providers:
 *   jazzcash  — hosted page (needs JAZZCASH_* env)        → instant activation after the signed callback
 *   easypaisa — hosted page (needs EASYPAISA_* env)       → activation after the Inquire API says PAID
 *   manual    — user sends money to your account and uploads a screenshot + transaction ID → admin approves
 *   admin     — premium given by an admin (no money)
 */
const crypto = require('crypto');
const config = require('../config');
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const jazzcash = require('./payments/jazzcash');
const easypaisa = require('./payments/easypaisa');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const FREE_FOLDERS = 10;
const PREMIUM_FOLDERS = 30;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

// ------------------------------------------------------------------ premium status & perks
function isPremiumRow(u) {
  return !!(u && u.premium_until && new Date(u.premium_until) > new Date());
}

async function isPremium(userId) {
  return isPremiumRow(await db.one('SELECT premium_until FROM users WHERE id = $1', [userId]));
}

async function limitsFor(userId) {
  const s = await settings.getAll();
  const premium = s.feature_premium && (await isPremium(userId));
  return {
    premium,
    upload_mb: Math.min(premium ? Math.max(s.premium_upload_mb, s.max_upload_mb) : s.max_upload_mb, config.uploadHardLimitMb),
    folders: premium ? PREMIUM_FOLDERS : FREE_FOLDERS,
    ads: !premium,
  };
}

async function perks() {
  const s = await settings.getAll();
  return [
    { key: 'badge', title: 'Premium badge', text: 'A ⭐ next to your name' },
    { key: 'uploads', title: `Upload files up to ${s.premium_upload_mb} MB`, text: `Instead of ${s.max_upload_mb} MB` },
    { key: 'folders', title: `${PREMIUM_FOLDERS} chat folders`, text: `Instead of ${FREE_FOLDERS}` },
    { key: 'no_ads', title: 'No sponsored messages', text: 'No ads in channels' },
  ];
}

function serializePlan(p) {
  return { id: p.id, name: p.name, months: p.months, price_pkr: p.price_pkr, per_month_pkr: Math.round(p.price_pkr / p.months), is_active: p.is_active };
}

function providers() {
  return [
    jazzcash.configured() && { id: 'jazzcash', name: 'JazzCash' },
    easypaisa.configured() && { id: 'easypaisa', name: 'Easypaisa' },
  ].filter(Boolean);
}

async function premiumInfo(userId) {
  await settings.requireFeature('feature_premium', 'Premium');
  const u = await db.one('SELECT premium_until FROM users WHERE id = $1', [userId]);
  const plans = await db.many('SELECT * FROM premium_plans WHERE is_active ORDER BY sort, months');
  const s = await settings.getAll();
  const methods = providers();
  if (s.payment_manual_enabled) methods.push({ id: 'manual', name: 'Bank / wallet transfer (manual)' });
  return {
    is_premium: isPremiumRow(u),
    premium_until: iso(u && u.premium_until),
    plans: plans.map(serializePlan),
    perks: await perks(),
    methods,
    manual_instructions: s.payment_manual_enabled ? s.payment_manual_instructions : null,
  };
}

// ------------------------------------------------------------------ orders
function serializeOrder(o) {
  return {
    id: o.id,
    plan_id: o.plan_id,
    months: o.months,
    amount_pkr: o.amount_pkr,
    provider: o.provider,
    status: o.status,
    txn_ref: o.txn_ref,
    provider_message: o.provider_message,
    review_note: o.review_note,
    has_proof: !!o.proof_media_id,
    created_at: iso(o.created_at),
    paid_at: iso(o.paid_at),
  };
}

function newTxnRef() {
  // ≤ 20 alphanumeric characters (JazzCash / Easypaisa limits)
  return `CA${Date.now().toString(36).toUpperCase()}${crypto.randomBytes(3).toString('hex').toUpperCase()}`.slice(0, 20);
}

function payToken(orderId) {
  return crypto.createHmac('sha256', config.jwtSecret).update(`pay:${orderId}`).digest('hex').slice(0, 32);
}

function checkPayToken(orderId, token) {
  const t = payToken(orderId);
  return typeof token === 'string' && token.length === t.length && crypto.timingSafeEqual(Buffer.from(token), Buffer.from(t));
}

async function checkout(userId, body = {}) {
  await settings.requireFeature('feature_premium', 'Premium');
  const plan = await db.one('SELECT * FROM premium_plans WHERE id = $1 AND is_active', [v.id(body.plan_id, 'plan_id')]);
  if (!plan) throw notFound('plan_not_found', 'This plan is not available');
  const provider = v.oneOf(body.provider, ['jazzcash', 'easypaisa', 'manual'], 'provider');
  if (provider === 'manual' && !(await settings.get('payment_manual_enabled'))) throw forbidden('provider_unavailable', 'Manual payments are turned off');
  if (provider !== 'manual' && !providers().some((p) => p.id === provider)) throw forbidden('provider_unavailable', 'This payment method is not available');
  rateLimit.enforce(`checkout:${userId}`, 10, 60 * 60 * 1000, 'Too many payment attempts. Try again later.');
  const open = await db.one(`SELECT count(*)::int AS n FROM payment_orders WHERE user_id = $1 AND status IN ('pending', 'review')`, [userId]);
  if (open.n >= 5) throw forbidden('too_many_orders', 'You have several unfinished payments. Finish or cancel them first.');
  const o = await db.one(
    `INSERT INTO payment_orders (user_id, plan_id, months, amount_pkr, provider, txn_ref) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [userId, plan.id, plan.months, plan.price_pkr, provider, newTxnRef()],
  );
  const out = { order: serializeOrder(o) };
  if (provider === 'manual') out.instructions = await settings.get('payment_manual_instructions');
  else out.pay_url = `${config.publicUrl}/pay/${o.id}?t=${payToken(o.id)}`;
  return out;
}

async function myOrder(userId, idRaw) {
  const o = await db.one('SELECT * FROM payment_orders WHERE id = $1 AND user_id = $2', [v.id(idRaw, 'order_id'), userId]);
  if (!o) throw notFound('order_not_found', 'Payment not found');
  return o;
}

async function getOrder(userId, idRaw) {
  return serializeOrder(await myOrder(userId, idRaw));
}

async function listMyOrders(userId) {
  const rows = await db.many('SELECT * FROM payment_orders WHERE user_id = $1 ORDER BY id DESC LIMIT 50', [userId]);
  return rows.map(serializeOrder);
}

async function cancelOrder(userId, idRaw) {
  const o = await myOrder(userId, idRaw);
  const r = await db.one(`UPDATE payment_orders SET status = 'cancelled' WHERE id = $1 AND status = 'pending' RETURNING *`, [o.id]);
  return serializeOrder(r || o);
}

/** Manual payment: user uploads the screenshot and transaction id → waits for an admin. */
async function submitProof(userId, idRaw, body = {}) {
  const o = await myOrder(userId, idRaw);
  if (o.provider !== 'manual') throw badRequest('invalid_input', 'Only manual payments need a screenshot');
  if (!['pending', 'review', 'rejected'].includes(o.status)) throw conflict('order_closed', 'This payment is already finished');
  const media = await db.one(`SELECT id FROM media WHERE id = $1 AND uploader_id = $2 AND kind IN ('image', 'file')`, [v.id(body.media_id, 'media_id'), userId]);
  if (!media) throw badRequest('invalid_media', 'Upload the payment screenshot first');
  const txn = v.str(body.txn_id, { field: 'txn_id', min: 4, max: 60, required: true });
  const sender = v.str(body.sender, { field: 'sender', max: 60 }) || null;
  const r = await db.one(
    `UPDATE payment_orders SET status = 'review', proof_media_id = $2, proof_txn_id = $3, proof_sender = $4, review_note = NULL WHERE id = $1 RETURNING *`,
    [o.id, media.id, txn, sender],
  );
  return serializeOrder(r);
}

/** Marks an order paid exactly once and extends the user's premium. */
async function markPaid(orderId, { providerRef = null, raw = null, message = null, adminId = null } = {}) {
  const r = await db.tx(async (c) => {
    const o = (await c.query(
      `UPDATE payment_orders SET status = 'paid', paid_at = now(), provider_ref = COALESCE($2, provider_ref),
         raw_response = COALESCE($3, raw_response), provider_message = COALESCE($4, provider_message), reviewed_by = COALESCE($5, reviewed_by)
       WHERE id = $1 AND status IN ('pending', 'review', 'failed', 'rejected') RETURNING *`,
      [orderId, providerRef, raw ? JSON.stringify(raw) : null, message, adminId],
    )).rows[0];
    if (!o) return null;
    await c.query(
      `UPDATE users SET premium_until = GREATEST(COALESCE(premium_until, now()), now()) + make_interval(months => $2), updated_at = now() WHERE id = $1`,
      [o.user_id, o.months],
    );
    return o;
  });
  if (r) {
    bus.emit('user:updated', { userId: r.user_id });
    bus.emit('rt:emit', { event: 'payment:updated', payload: { order_id: r.id, status: 'paid' }, userIds: [r.user_id] });
  }
  return r;
}

async function markFailed(orderId, { status = 'failed', message = null, raw = null } = {}) {
  const r = await db.one(
    `UPDATE payment_orders SET status = $2, provider_message = $3, raw_response = COALESCE($4, raw_response)
     WHERE id = $1 AND status IN ('pending', 'review') RETURNING *`,
    [orderId, status, message, raw ? JSON.stringify(raw) : null],
  );
  if (r) bus.emit('rt:emit', { event: 'payment:updated', payload: { order_id: r.id, status: r.status }, userIds: [r.user_id] });
  return r;
}

// ------------------------------------------------------------------ gateway pages (called from routes.pay.js)
async function gatewayForm(orderIdRaw, token) {
  const id = v.id(orderIdRaw, 'order_id');
  if (!checkPayToken(id, token)) throw notFound('order_not_found', 'Payment link is invalid');
  const o = await db.one('SELECT * FROM payment_orders WHERE id = $1', [id]);
  if (!o || o.status !== 'pending') throw conflict('order_closed', 'This payment is already finished');
  if (Date.now() - new Date(o.created_at).getTime() > 2 * 3600 * 1000) throw conflict('order_expired', 'This payment link has expired');
  if (o.provider === 'jazzcash') return jazzcash.buildRequest(o, `${config.publicUrl}/pay/jazzcash/return`);
  if (o.provider === 'easypaisa') return easypaisa.buildRequest(o, `${config.publicUrl}/pay/easypaisa/return?order=${o.id}&t=${payToken(o.id)}`);
  throw badRequest('invalid_input', 'This order has no payment page');
}

async function jazzcashReturn(body) {
  const r = jazzcash.parseResponse(body || {});
  const o = await db.one(`SELECT * FROM payment_orders WHERE txn_ref = $1 AND provider = 'jazzcash'`, [r.txnRef]);
  if (!o) return { ok: false, message: 'Payment not found' };
  if (!r.valid) {
    await markFailed(o.id, { message: 'Invalid signature from gateway', raw: body });
    return { ok: false, message: 'We could not verify this payment.', order: o };
  }
  if (r.paid && r.amountPkr === o.amount_pkr) {
    await markPaid(o.id, { providerRef: r.providerRef, raw: body, message: r.message });
    return { ok: true, message: 'Payment successful — Premium is active.', order: o };
  }
  await markFailed(o.id, { message: `${r.code} ${r.message}`.trim(), raw: body });
  return { ok: false, message: r.message || 'Payment was not completed.', order: o };
}

async function easypaisaConfirmForm(orderIdRaw, token, authToken) {
  const id = v.id(orderIdRaw, 'order_id');
  if (!checkPayToken(id, token)) throw notFound('order_not_found', 'Payment link is invalid');
  if (!authToken) throw badRequest('invalid_input', 'Missing auth token');
  return easypaisa.confirmRequest(String(authToken), `${config.publicUrl}/pay/easypaisa/done?order=${id}&t=${payToken(id)}`);
}

async function easypaisaDone(orderIdRaw, token, query = {}) {
  const id = v.id(orderIdRaw, 'order_id');
  if (!checkPayToken(id, token)) throw notFound('order_not_found', 'Payment link is invalid');
  const o = await db.one(`SELECT * FROM payment_orders WHERE id = $1 AND provider = 'easypaisa'`, [id]);
  if (!o) throw notFound('order_not_found', 'Payment not found');
  if (o.status === 'paid') return { ok: true, message: 'Payment successful — Premium is active.', order: o };
  if (easypaisa.canInquire()) {
    try {
      const q = await easypaisa.inquire(o.txn_ref);
      if (q.paid && q.amountPkr === o.amount_pkr) {
        await markPaid(o.id, { providerRef: q.providerRef, raw: q.raw, message: q.status });
        return { ok: true, message: 'Payment successful — Premium is active.', order: o };
      }
      if (String(query.status || '') !== '0000') {
        await markFailed(o.id, { message: String(query.desc || q.status || 'Not paid').slice(0, 300), raw: q.raw });
        return { ok: false, message: 'Payment was not completed.', order: o };
      }
    } catch (_) {
      /* fall through to review */
    }
  }
  // Can't confirm automatically → an admin checks it in the panel
  await db.query(`UPDATE payment_orders SET status = 'review', provider_message = $2 WHERE id = $1 AND status = 'pending'`, [
    o.id,
    `Easypaisa says: ${String(query.status || '?')} ${String(query.desc || '')}`.slice(0, 300),
  ]);
  return { ok: true, message: 'Thanks! We are confirming your payment — Premium will be activated shortly.', order: o };
}

/** Scheduler: abandoned hosted-checkout orders expire after 2 hours. */
async function sweep() {
  await db.query(
    `UPDATE payment_orders SET status = 'cancelled', provider_message = 'Expired'
     WHERE status = 'pending' AND provider IN ('jazzcash', 'easypaisa') AND created_at < now() - interval '2 hours'`,
  );
}

// ------------------------------------------------------------------ admin
async function adminListOrders(query = {}) {
  const limit = v.limit(query.limit, 25, 100);
  const page = Math.max(1, parseInt(query.page, 10) || 1);
  const params = [];
  const where = [];
  if (query.status && query.status !== 'all') {
    params.push(v.oneOf(query.status, ['pending', 'review', 'paid', 'failed', 'cancelled', 'rejected'], 'status'));
    where.push(`o.status = $${params.length}`);
  }
  if (query.provider) {
    params.push(v.oneOf(query.provider, ['jazzcash', 'easypaisa', 'manual', 'admin'], 'provider'));
    where.push(`o.provider = $${params.length}`);
  }
  if (query.user_id) {
    params.push(v.id(query.user_id, 'user_id'));
    where.push(`o.user_id = $${params.length}`);
  }
  const w = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = await db.one(`SELECT count(*)::int AS n FROM payment_orders o ${w}`, params);
  params.push(limit, (page - 1) * limit);
  const rows = await db.many(
    `SELECT o.*, u.first_name, u.last_name, u.username, u.phone, a.name AS reviewer
     FROM payment_orders o JOIN users u ON u.id = o.user_id LEFT JOIN admins a ON a.id = o.reviewed_by
     ${w} ORDER BY o.id DESC LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  return {
    total: total.n,
    page,
    limit,
    orders: rows.map((o) => ({
      ...serializeOrder(o),
      user: { id: o.user_id, name: `${o.first_name || ''} ${o.last_name || ''}`.trim(), username: o.username, phone: o.phone },
      proof_media_id: o.proof_media_id,
      proof_txn_id: o.proof_txn_id,
      proof_sender: o.proof_sender,
      provider_ref: o.provider_ref,
      reviewer: o.reviewer,
    })),
  };
}

async function adminApprove(adminId, idRaw, note) {
  const id = v.id(idRaw, 'order_id');
  const r = await markPaid(id, { adminId, message: note ? `Approved: ${String(note).slice(0, 200)}` : 'Approved by admin' });
  if (!r) throw conflict('order_closed', 'This payment can’t be approved');
  return serializeOrder(r);
}

async function adminReject(adminId, idRaw, note) {
  const id = v.id(idRaw, 'order_id');
  const r = await db.one(
    `UPDATE payment_orders SET status = 'rejected', review_note = $2, reviewed_by = $3 WHERE id = $1 AND status IN ('pending', 'review') RETURNING *`,
    [id, v.str(note, { field: 'note', max: 300 }) || 'Payment not found', adminId],
  );
  if (!r) throw conflict('order_closed', 'This payment can’t be rejected');
  bus.emit('rt:emit', { event: 'payment:updated', payload: { order_id: r.id, status: 'rejected' }, userIds: [r.user_id] });
  return serializeOrder(r);
}

/** Admin gift / compensation: a zero-amount 'admin' order keeps the history complete. */
async function adminGrant(adminId, userIdRaw, monthsRaw) {
  const userId = v.id(userIdRaw, 'user_id');
  const months = parseInt(monthsRaw, 10);
  if (!Number.isInteger(months) || months < 1 || months > 60) throw badRequest('invalid_input', 'months must be 1–60');
  const u = await db.one('SELECT id FROM users WHERE id = $1 AND status = $2', [userId, 'active']);
  if (!u) throw notFound('user_not_found', 'User not found');
  const o = await db.one(
    `INSERT INTO payment_orders (user_id, months, amount_pkr, provider, txn_ref, reviewed_by) VALUES ($1, $2, 0, 'admin', $3, $4) RETURNING *`,
    [userId, months, newTxnRef(), adminId],
  );
  await markPaid(o.id, { adminId, message: 'Given by admin' });
  return { ok: true };
}

async function adminRevoke(userIdRaw) {
  const userId = v.id(userIdRaw, 'user_id');
  await db.query('UPDATE users SET premium_until = NULL WHERE id = $1', [userId]);
  bus.emit('user:updated', { userId });
  return { ok: true };
}

async function adminPlans() {
  return (await db.many('SELECT * FROM premium_plans ORDER BY sort, months')).map(serializePlan);
}

async function adminSavePlan(idRaw, body = {}) {
  const name = v.str(body.name, { field: 'name', min: 1, max: 60, required: true });
  const months = parseInt(body.months, 10);
  const price = parseInt(body.price_pkr, 10);
  if (!Number.isInteger(months) || months < 1 || months > 60) throw badRequest('invalid_input', 'months must be 1–60');
  if (!Number.isInteger(price) || price < 0 || price > 10000000) throw badRequest('invalid_input', 'Invalid price');
  const active = body.is_active === undefined ? true : v.bool(body.is_active, 'is_active');
  const sort = parseInt(body.sort, 10) || 0;
  const r = idRaw
    ? await db.one('UPDATE premium_plans SET name = $2, months = $3, price_pkr = $4, is_active = $5, sort = $6 WHERE id = $1 RETURNING *', [
      v.id(idRaw, 'plan_id'), name, months, price, active, sort,
    ])
    : await db.one('INSERT INTO premium_plans (name, months, price_pkr, is_active, sort) VALUES ($1, $2, $3, $4, $5) RETURNING *', [name, months, price, active, sort]);
  if (!r) throw notFound('plan_not_found', 'Plan not found');
  return serializePlan(r);
}

module.exports = {
  FREE_FOLDERS,
  PREMIUM_FOLDERS,
  isPremium,
  isPremiumRow,
  limitsFor,
  providers,
  premiumInfo,
  checkout,
  getOrder,
  listMyOrders,
  cancelOrder,
  submitProof,
  markPaid,
  markFailed,
  gatewayForm,
  jazzcashReturn,
  easypaisaConfirmForm,
  easypaisaDone,
  payToken,
  sweep,
  adminListOrders,
  adminApprove,
  adminReject,
  adminGrant,
  adminRevoke,
  adminPlans,
  adminSavePlan,
};
