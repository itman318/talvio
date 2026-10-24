'use strict';

/* "Reply" and "Mark as read" straight from a notification, without opening the app.
 * Each message push carries a reply token that only allows these two actions in that one chat,
 * for that device's session (logging the device out makes it useless). */
const config = require('../config');
const db = require('../db');
const rateLimit = require('../utils/rateLimit');
const { signJwt, verifyJwt } = require('../utils/crypto');
const { unauthorized } = require('../utils/errors');

const TTL_SEC = 7 * 24 * 3600;

function replyToken(userId, sessionId, chatId) {
  return signJwt({ typ: 'nr', sub: userId, sid: sessionId, cid: chatId }, config.jwtSecret, TTL_SEC);
}

async function check(token) {
  const p = verifyJwt(String(token || ''), config.jwtSecret);
  if (!p || p.typ !== 'nr') throw unauthorized('token_expired', 'Open the app to reply');
  const s = await db.one('SELECT id FROM sessions WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL AND expires_at > now()', [p.sid, p.sub]);
  if (!s) throw unauthorized('session_revoked', 'Open the app to reply');
  rateLimit.enforce(`notify:${p.sub}`, 60, 60 * 1000);
  return p;
}

async function reply(body = {}) {
  const p = await check(body.token);
  const messages = require('./message.service');
  const m = await messages.sendMessage(p.sub, p.cid, { text: body.text, client_id: body.client_id });
  await messages.markRead(p.sub, p.cid, m.id).catch(() => null);
  return { ok: true, message_id: m.id };
}

async function read(body = {}) {
  const p = await check(body.token);
  const messages = require('./message.service');
  const last = body.message_id || (await db.one('SELECT last_message_id FROM chats WHERE id = $1', [p.cid]) || {}).last_message_id;
  if (last) await messages.markRead(p.sub, p.cid, last);
  return { ok: true };
}

module.exports = { replyToken, reply, read };
