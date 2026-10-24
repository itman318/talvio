'use strict';

const path = require('path');
const config = require('../config');
const db = require('../db');

/**
 * Firebase Cloud Messaging (Android + iOS via APNs through FCM).
 * Disabled automatically when FIREBASE_SERVICE_ACCOUNT_PATH is empty or firebase-admin is missing.
 */
let messaging = null;
let initialised = false;

function init() {
  if (initialised) return messaging;
  initialised = true;
  if (!config.firebaseServiceAccountPath) return null;
  try {
    // eslint-disable-next-line global-require, import/no-dynamic-require
    const admin = require('firebase-admin');
    // eslint-disable-next-line global-require, import/no-dynamic-require
    const serviceAccount = require(path.resolve(config.firebaseServiceAccountPath));
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    messaging = admin.messaging();
    // eslint-disable-next-line no-console
    console.log('Push notifications enabled (FCM)');
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn(`Push notifications disabled: ${err.message}`);
  }
  return messaging;
}

const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

/**
 * @param {number[]} userIds
 * @param {{title: string, body: string}} notification
 * @param {Record<string,string>} data  string values only
 * @param {{ttlSec?: number, tag?: string}} options  ttlSec: drop if not delivered in time (incoming calls)
 */
async function sendToUsers(userIds, notification, data = {}, options = {}) {
  const m = init();
  if (!m || userIds.length === 0) return;
  const rows = await db.many(
    `SELECT id, user_id, fcm_token FROM sessions
     WHERE user_id = ANY($1::bigint[]) AND revoked_at IS NULL AND expires_at > now() AND fcm_token IS NOT NULL`,
    [userIds],
  );
  if (rows.length === 0) return;
  const str = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => [k, String(v)]));
  const title = notification.title.slice(0, 100);
  const body = notification.body.slice(0, 240);
  const build = (row) => {
    const d = str({ ...data, ...(options.perSession ? options.perSession(row) : {}) });
    const msg = {
      token: row.fcm_token,
      data: options.dataOnlyAndroid ? { ...d, title, body } : d,
      android: {
        priority: 'high',
        ...(options.ttlSec ? { ttl: options.ttlSec * 1000 } : {}),
        // data-only on Android: the app draws the notification itself (with Reply / Mark as read buttons)
        ...(options.dataOnlyAndroid ? {} : { notification: { tag: options.tag || d.chat_id || undefined } }),
      },
      apns: {
        ...(options.ttlSec ? { headers: { 'apns-expiration': String(Math.floor(Date.now() / 1000) + options.ttlSec) } } : {}),
        payload: {
          aps: {
            sound: 'default',
            'thread-id': d.chat_id || '',
            ...(options.dataOnlyAndroid ? { alert: { title, body } } : {}),
            ...(options.category ? { category: options.category } : {}),
          },
        },
      },
    };
    if (!options.dataOnlyAndroid) msg.notification = { title, body };
    return msg;
  };
  for (let i = 0; i < rows.length; i += 500) {
    const batch = rows.slice(i, i + 500);
    try {
      const res = await m.sendEach(batch.map(build));
      const invalid = [];
      res.responses.forEach((r, idx) => {
        if (!r.success && r.error && INVALID_TOKEN_CODES.has(r.error.code)) invalid.push(batch[idx].id);
      });
      if (invalid.length) await db.query('UPDATE sessions SET fcm_token = NULL WHERE id = ANY($1::bigint[])', [invalid]);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error('Push send failed', err.message);
    }
  }
}

module.exports = { sendToUsers, init };
