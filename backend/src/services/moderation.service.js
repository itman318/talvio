'use strict';

/**
 * Automatic moderation: banned words, link limits for new accounts, duplicate-message spam,
 * mass-report restrictions, phone-prefix blacklist. Thresholds are admin settings.
 */
const db = require('../db');
const bus = require('../bus');
const settings = require('./settings.service');
const { forbidden } = require('../utils/errors');

const LINK_RE = /(https?:\/\/|www\.|t\.me\/|wa\.me\/|\b[a-z0-9-]{2,}\.(com|net|org|pk|io|xyz|info|me|link|ly|co|app|site|online|top|biz)\b)/i;

let compiledKey = null;
let compiled = [];

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function bannedRegexes(words) {
  const key = words.join('\u0000');
  if (key !== compiledKey) {
    compiledKey = key;
    compiled = words.map((w) => ({
      word: w,
      // whole word / phrase, case-insensitive, unicode-aware boundaries (works for Urdu too)
      re: new RegExp(`(^|[^\\p{L}\\p{N}])${escapeRe(w)}($|[^\\p{L}\\p{N}])`, 'iu'),
    }));
  }
  return compiled;
}

/** Returns the first banned word found in any of the texts, or null. */
async function findBannedWord(texts) {
  const words = await settings.get('banned_words');
  if (!words || words.length === 0) return null;
  const regs = bannedRegexes(words);
  for (const t of texts) {
    if (!t) continue;
    for (const { word, re } of regs) if (re.test(t)) return word;
  }
  return null;
}

/**
 * Checks outgoing content. Throws when the message must be blocked.
 * Returns { flaggedWord } when it should be sent but reported automatically.
 */
async function checkOutgoing(sender, texts) {
  assertNotRestricted(sender);

  const hours = await settings.get('new_account_link_hours');
  if (hours > 0 && Date.now() - new Date(sender.created_at).getTime() < hours * 3600 * 1000) {
    if (texts.some((t) => t && LINK_RE.test(t))) {
      throw forbidden('links_restricted', `New accounts can send links after ${hours} hours`);
    }
  }

  const word = await findBannedWord(texts);
  if (!word) return {};
  if ((await settings.get('banned_words_action')) === 'block') {
    throw forbidden('message_blocked', 'Your message contains words that are not allowed');
  }
  return { flaggedWord: word };
}

function assertNotRestricted(user) {
  if (user.restricted_until && new Date(user.restricted_until) > new Date()) {
    throw forbidden('restricted', 'You are temporarily restricted from sending messages', {
      until: new Date(user.restricted_until).toISOString(),
      reason: user.restrict_reason || null,
    });
  }
}

async function restrictUser(userId, minutes, reason) {
  await db.query(
    `UPDATE users SET restricted_until = GREATEST(COALESCE(restricted_until, now()), now() + make_interval(mins => $2)),
       restrict_reason = $3 WHERE id = $1`,
    [userId, minutes, reason],
  );
  bus.emit('user:restricted', { userId, reason });
}

async function liftRestriction(userId) {
  await db.query('UPDATE users SET restricted_until = NULL, restrict_reason = NULL WHERE id = $1', [userId]);
}

/** Creates an automatic report (deduplicated per open target). */
async function autoReport(targetType, targetId, reason, details, snapshot) {
  const existing = await db.one(
    `SELECT id FROM reports WHERE source = 'auto' AND status = 'open' AND target_type = $1 AND target_id = $2`,
    [targetType, targetId],
  );
  if (existing) return existing.id;
  const r = await db.one(
    `INSERT INTO reports (reporter_id, target_type, target_id, reason, details, snapshot, source)
     VALUES (NULL, $1, $2, $3, $4, $5, 'auto') RETURNING id`,
    [targetType, targetId, reason, details.slice(0, 1000), JSON.stringify(snapshot || {})],
  );
  return r.id;
}

/** After a message is stored: flag banned words, detect copy-paste spam across chats. */
async function afterSend(sender, message, { flaggedWord } = {}) {
  if (flaggedWord) {
    await autoReport('message', message.id, 'other', `Automatic: contains banned word "${flaggedWord}"`, {
      message: {
        id: message.id,
        chat_id: message.chat_id,
        sender_id: sender.id,
        type: message.type,
        text: message.text,
        created_at: message.created_at,
      },
    });
  }

  const threshold = await settings.get('spam_duplicate_threshold');
  if (threshold > 0 && message.text && message.text.length >= 8 && message.type !== 'system') {
    const r = await db.one(
      `SELECT count(DISTINCT chat_id) AS n FROM messages
       WHERE sender_id = $1 AND text = $2 AND deleted_at IS NULL AND created_at > now() - interval '10 minutes'`,
      [sender.id, message.text],
    );
    if (r.n >= threshold) {
      const minutes = await settings.get('spam_restrict_minutes');
      await restrictUser(sender.id, minutes, 'Automatic: same message sent to many chats');
      await autoReport('user', sender.id, 'spam', `Automatic: sent the same message to ${r.n} chats in 10 minutes`, {
        user: { id: sender.id, username: sender.username, first_name: sender.first_name, last_name: sender.last_name },
        sample_text: message.text.slice(0, 500),
      });
    }
  }
}

/** After a user report: restrict the account if many different people reported it within 24h. */
async function afterReport(targetUserId) {
  if (!targetUserId) return;
  const threshold = await settings.get('auto_restrict_reports');
  if (threshold <= 0) return;
  const r = await db.one(
    `SELECT count(DISTINCT reporter_id) AS n FROM reports
     WHERE reporter_id IS NOT NULL AND created_at > now() - interval '24 hours' AND (
       (target_type = 'user' AND target_id = $1)
       OR (target_type = 'message' AND (snapshot->'message'->>'sender_id')::bigint = $1))`,
    [targetUserId],
  );
  if (r.n >= threshold) {
    const u = await db.one('SELECT restricted_until FROM users WHERE id = $1', [targetUserId]);
    if (!u || (u.restricted_until && new Date(u.restricted_until) > new Date())) return;
    await restrictUser(targetUserId, 24 * 60, `Automatic: reported by ${r.n} people in 24 hours (pending review)`);
  }
}

async function isPhoneBlocked(phone) {
  const prefixes = await settings.get('blocked_phone_prefixes');
  return (prefixes || []).some((p) => phone.startsWith(p.startsWith('+') ? p : `+${p}`));
}

module.exports = {
  LINK_RE,
  findBannedWord,
  checkOutgoing,
  assertNotRestricted,
  restrictUser,
  liftRestriction,
  autoReport,
  afterSend,
  afterReport,
  isPhoneBlocked,
};
