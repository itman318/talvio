'use strict';

/**
 * Hosted-checkout pages (opened in the phone's browser):
 *   GET  /pay/:orderId?t=…            → auto-submitting form to JazzCash / Easypaisa
 *   POST /pay/jazzcash/return          → JazzCash posts the signed result here
 *   GET  /pay/easypaisa/return         → step 2 (auth_token) → auto-submit to Confirm.jsf
 *   GET  /pay/easypaisa/done           → final result, confirmed with the Inquire API
 */
const crypto = require('crypto');
const express = require('express');
const config = require('../config');
const payments = require('../services/payment.service');

const router = express.Router();
router.use(express.urlencoded({ extended: false, limit: '64kb' }));

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function page(res, title, bodyHtml, { nonce, formAction } = {}) {
  const csp = [
    "default-src 'none'",
    "style-src 'unsafe-inline'",
    nonce ? `script-src 'nonce-${nonce}'` : '',
    `form-action ${formAction ? new URL(formAction).origin : "'none'"}`,
  ].filter(Boolean).join('; ');
  res.setHeader('Content-Security-Policy', csp);
  res.setHeader('Cache-Control', 'no-store');
  res.type('html').send(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>body{font-family:system-ui,sans-serif;max-width:420px;margin:15vh auto;padding:0 20px;text-align:center;color:#1a1c1e}
h1{font-size:22px}p{color:#555;line-height:1.5}button,a.btn{background:#2AABEE;color:#fff;border:0;border-radius:10px;padding:12px 22px;font-size:16px;text-decoration:none;display:inline-block}
.ok{color:#1e8e3e}.bad{color:#d93025}</style></head><body>${bodyHtml}</body></html>`);
}

function autoSubmit(res, { action, fields }, label) {
  const nonce = crypto.randomBytes(12).toString('base64');
  const inputs = Object.entries(fields).map(([k, v]) => `<input type="hidden" name="${esc(k)}" value="${esc(v)}">`).join('');
  page(
    res,
    label,
    `<h1>${esc(label)}</h1><p>Taking you to the secure payment page…</p>
<form id="f" method="POST" action="${esc(action)}">${inputs}<button type="submit">Continue</button></form>
<script nonce="${nonce}">document.getElementById('f').submit();</script>`,
    { nonce, formAction: action },
  );
}

function result(res, r) {
  page(
    res,
    r.ok ? 'Payment received' : 'Payment not completed',
    `<h1 class="${r.ok ? 'ok' : 'bad'}">${r.ok ? '✓' : '✕'} ${esc(r.ok ? 'Thank you!' : 'Payment not completed')}</h1>
<p>${esc(r.message)}</p><p>You can close this page and go back to the app.</p>
<a class="btn" href="talvio://payment${r.order ? `?order=${r.order.id}` : ''}">Back to the app</a>`,
  );
}

const fail = (res, err) => {
  res.status(err.status || 400);
  page(res, 'Payment', `<h1 class="bad">Payment</h1><p>${esc(err.status ? err.message : 'Something went wrong')}</p>`);
};

router.post('/jazzcash/return', async (req, res) => {
  try {
    result(res, await payments.jazzcashReturn(req.body));
  } catch (err) {
    fail(res, err);
  }
});

router.get('/easypaisa/return', async (req, res) => {
  try {
    autoSubmit(res, await payments.easypaisaConfirmForm(req.query.order, req.query.t, req.query.auth_token), 'Easypaisa');
  } catch (err) {
    fail(res, err);
  }
});

router.get('/easypaisa/done', async (req, res) => {
  try {
    result(res, await payments.easypaisaDone(req.query.order, req.query.t, req.query));
  } catch (err) {
    fail(res, err);
  }
});

router.get('/:orderId', async (req, res) => {
  try {
    const form = await payments.gatewayForm(req.params.orderId, req.query.t);
    autoSubmit(res, form, form.action.includes('jazzcash') ? 'JazzCash' : 'Easypaisa');
  } catch (err) {
    fail(res, err);
  }
});

module.exports = router;
module.exports.publicUrl = config.publicUrl;
