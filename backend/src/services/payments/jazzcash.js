'use strict';

/**
 * JazzCash "Page Redirection" (hosted checkout, API version 1.1).
 *
 * pp_SecureHash = UPPER(HEX(HMAC_SHA256(key = integrity salt,
 *                   msg = salt + "&" + values of all non-empty pp_* fields sorted by field name, joined with "&")))
 * The same rule verifies the response posted back to pp_ReturnURL. pp_ResponseCode "000" = paid.
 *
 * Test with your sandbox credentials from the JazzCash merchant portal before going live —
 * JazzCash sometimes changes required fields per merchant account.
 */
const crypto = require('crypto');
const config = require('../../config');

const URLS = {
  sandbox: 'https://sandbox.jazzcash.com.pk/CustomerPortal/transactionmanagement/merchantform/',
  live: 'https://payments.jazzcash.com.pk/CustomerPortal/transactionmanagement/merchantform/',
};

function configured() {
  const c = config.jazzcash;
  return !!(c.merchantId && c.password && c.integritySalt);
}

function actionUrl() {
  return config.jazzcash.sandbox ? URLS.sandbox : URLS.live;
}

/** yyyyMMddHHmmss in Pakistan time. */
function pkTime(date) {
  const d = new Date(date.getTime() + 5 * 3600 * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
}

function secureHash(fields, salt = config.jazzcash.integritySalt) {
  const values = Object.keys(fields)
    .filter((k) => k.startsWith('pp') && k !== 'pp_SecureHash' && fields[k] !== undefined && fields[k] !== null && String(fields[k]) !== '')
    .sort()
    .map((k) => String(fields[k]));
  return crypto.createHmac('sha256', salt).update([salt, ...values].join('&')).digest('hex').toUpperCase();
}

/** Form fields for the order; the pay page auto-submits them to actionUrl(). */
function buildRequest(order, returnUrl, now = new Date()) {
  const c = config.jazzcash;
  const fields = {
    pp_Version: '1.1',
    pp_TxnType: '',
    pp_Language: 'EN',
    pp_MerchantID: c.merchantId,
    pp_SubMerchantID: '',
    pp_Password: c.password,
    pp_BankID: '',
    pp_ProductID: '',
    pp_TxnRefNo: order.txn_ref,
    pp_Amount: String(order.amount_pkr * 100), // paisa
    pp_TxnCurrency: 'PKR',
    pp_TxnDateTime: pkTime(now),
    pp_BillReference: `order${order.id}`,
    pp_Description: `Premium ${order.months} month${order.months > 1 ? 's' : ''}`,
    pp_TxnExpiryDateTime: pkTime(new Date(now.getTime() + 60 * 60 * 1000)),
    pp_ReturnURL: returnUrl,
    ppmpf_1: String(order.id),
  };
  fields.pp_SecureHash = secureHash(fields, c.integritySalt);
  return { action: actionUrl(), fields };
}

/** Verifies the POST JazzCash sends back. Returns { valid, paid, txnRef, amountPkr, code, message, providerRef }. */
function parseResponse(body) {
  const given = String(body.pp_SecureHash || '').toUpperCase();
  const expected = secureHash(body);
  const valid = given.length === expected.length && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));
  return {
    valid,
    paid: valid && body.pp_ResponseCode === '000',
    txnRef: String(body.pp_TxnRefNo || ''),
    amountPkr: Math.round(Number(body.pp_Amount || 0) / 100),
    code: String(body.pp_ResponseCode || ''),
    message: String(body.pp_ResponseMessage || '').slice(0, 300),
    providerRef: String(body.pp_RetreivalReferenceNo || body.pp_AuthCode || '').slice(0, 100) || null,
  };
}

module.exports = { configured, actionUrl, buildRequest, parseResponse, secureHash, pkTime };
