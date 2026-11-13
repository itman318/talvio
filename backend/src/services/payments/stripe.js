'use strict';

/**
 * Card payments through Stripe Checkout (a page hosted by Stripe — card numbers never touch Hushavia).
 * Keys come from the server's environment (GitHub secrets STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET);
 * the admin panel only switches it on and off.
 */
const crypto = require('crypto');

const API = 'https://api.stripe.com/v1';

const secret = () => String(process.env.STRIPE_SECRET_KEY || '').trim();
const webhookSecret = () => String(process.env.STRIPE_WEBHOOK_SECRET || '').trim();
const configured = () => /^sk_(live|test)_/.test(secret());

const httpTransport = async (method, path, form) => {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${secret()}`, 'content-type': 'application/x-www-form-urlencoded', 'stripe-version': '2024-06-20' },
    body: form ? new URLSearchParams(form).toString() : undefined,
    signal: AbortSignal.timeout(15000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((j.error && j.error.message) || `Stripe answered ${r.status}`);
  return j;
};
let transport = httpTransport;
function setTransport(fn) {
  transport = fn || httpTransport;
}

/** A Checkout Session for one order; returns { id, url }. */
async function createSession({ orderId, cents, name, successUrl, cancelUrl, email }) {
  const form = {
    mode: 'payment',
    'line_items[0][quantity]': '1',
    'line_items[0][price_data][currency]': 'usd',
    'line_items[0][price_data][unit_amount]': String(cents),
    'line_items[0][price_data][product_data][name]': name,
    client_reference_id: String(orderId),
    'metadata[order_id]': String(orderId),
    'payment_intent_data[metadata][order_id]': String(orderId),
    success_url: successUrl,
    cancel_url: cancelUrl,
  };
  if (email) form.customer_email = email;
  const s = await transport('POST', '/checkout/sessions', form);
  return { id: s.id, url: s.url };
}

async function getSession(id) {
  return transport('GET', `/checkout/sessions/${encodeURIComponent(id)}`);
}

/** Checks the Stripe-Signature header (HMAC-SHA256 of "t.body"), within 5 minutes. */
function verify(rawBody, header, now = Date.now()) {
  const key = webhookSecret();
  if (!key || !rawBody || !header) return false;
  const parts = Object.fromEntries(String(header).split(',').map((p) => p.split('=')).filter((p) => p.length === 2).map(([k, v]) => [k.trim(), v.trim()]));
  const t = Number(parts.t);
  if (!t || Math.abs(now / 1000 - t) > 300) return false;
  const want = crypto.createHmac('sha256', key).update(`${t}.${rawBody}`).digest('hex');
  const sigs = String(header).split(',').filter((p) => p.trim().startsWith('v1=')).map((p) => p.trim().slice(3));
  return sigs.some((s) => s.length === want.length && crypto.timingSafeEqual(Buffer.from(s), Buffer.from(want)));
}

module.exports = { configured, createSession, getSession, verify, setTransport };
