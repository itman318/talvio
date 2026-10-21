'use strict';

/**
 * Easypaisa "Easypay" hosted checkout.
 *
 * 1. Browser POSTs to Index.jsf: amount, orderRefNum, paymentMethod, postBackURL, storeId, timeStamp,
 *    merchantHashedReq = BASE64(AES-128-ECB/PKCS5(key = hash key,
 *                        "amount=..&orderRefNum=..&paymentMethod=..&postBackURL=..&storeId=..&timeStamp=..")).
 * 2. Easypaisa redirects to postBackURL?auth_token=… → we POST auth_token + a second postBackURL to Confirm.jsf.
 * 3. Easypaisa redirects to the second URL with status / orderRefNumber.
 * 4. We confirm with the Inquire Transaction API (status "PAID") — the redirect itself is not signed.
 *
 * Test in the Easypaisa staging environment with your merchant credentials before going live.
 */
const crypto = require('crypto');
const config = require('../../config');

const HOSTS = { sandbox: 'https://easypaystg.easypaisa.com.pk', live: 'https://easypay.easypaisa.com.pk' };
const host = () => (config.easypaisa.sandbox ? HOSTS.sandbox : HOSTS.live);

function configured() {
  const c = config.easypaisa;
  return !!(c.storeId && c.hashKey);
}

function canInquire() {
  const c = config.easypaisa;
  return !!(c.username && c.password && c.accountNum);
}

function pkStamp(date) {
  const d = new Date(date.getTime() + 5 * 3600 * 1000);
  return d.toISOString().slice(0, 19); // yyyy-MM-ddTHH:mm:ss (PKT)
}

function hashRequest(fields, key = config.easypaisa.hashKey) {
  const text = Object.keys(fields).sort().map((k) => `${k}=${fields[k]}`).join('&');
  const k = Buffer.from(key, 'utf8');
  const algo = k.length === 32 ? 'aes-256-ecb' : k.length === 24 ? 'aes-192-ecb' : 'aes-128-ecb';
  const cipher = crypto.createCipheriv(algo, k.length >= 16 ? k : Buffer.concat([k, Buffer.alloc(16 - k.length)]), null);
  return Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]).toString('base64');
}

function buildRequest(order, postBackUrl, now = new Date()) {
  const signed = {
    amount: `${order.amount_pkr}.0`,
    orderRefNum: order.txn_ref,
    paymentMethod: 'MA_PAYMENT_METHOD',
    postBackURL: postBackUrl,
    storeId: config.easypaisa.storeId,
    timeStamp: pkStamp(now),
  };
  return {
    action: `${host()}/easypay/Index.jsf`,
    fields: { ...signed, autoRedirect: '1', merchantHashedReq: hashRequest(signed) },
  };
}

function confirmRequest(authToken, finalUrl) {
  return { action: `${host()}/easypay/Confirm.jsf`, fields: { auth_token: authToken, postBackURL: finalUrl } };
}

/** Asks Easypaisa whether the order was really paid. Returns { paid, status, amountPkr, raw }. */
async function inquire(txnRef) {
  const c = config.easypaisa;
  const res = await fetch(`${host()}/easypay-service/rest/v4/inquire-transaction`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Credentials: Buffer.from(`${c.username}:${c.password}`).toString('base64'),
    },
    body: JSON.stringify({ orderId: txnRef, storeId: c.storeId, accountNum: c.accountNum }),
    signal: AbortSignal.timeout(15000),
  });
  const raw = await res.json().catch(() => ({}));
  const status = String(raw.transactionStatus || '');
  return {
    paid: raw.responseCode === '0000' && status === 'PAID',
    status,
    amountPkr: Math.round(Number(raw.transactionAmount || 0)),
    providerRef: raw.transactionId ? String(raw.transactionId) : null,
    raw,
  };
}

module.exports = { configured, canInquire, buildRequest, confirmRequest, inquire, hashRequest, pkStamp };
