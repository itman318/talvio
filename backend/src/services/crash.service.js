'use strict';

/**
 * Crash reports from the Android/iOS app and the web app — kept on our own server (no third party).
 * Identical errors (same message + top of stack + version) are grouped into one row with a counter.
 */
const crypto = require('crypto');
const db = require('../db');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { notFound } = require('../utils/errors');

const PLATFORMS = ['android', 'ios', 'web', 'desktop', 'other'];

function clean(s, max) {
  return String(s == null ? '' : s).replace(/\u0000/g, '').slice(0, max);
}

/** Strips things that change on every run (addresses, line/col in minified code) so duplicates group. */
function normalizeStack(stack) {
  return stack
    .split('\n')
    .slice(0, 8)
    .map((l) => l.replace(/0x[0-9a-f]+/gi, '0x?').replace(/:\d+:\d+/g, ':?').trim())
    .join('\n');
}

async function record(userId, body = {}, ip = '') {
  rateLimit.enforce(`crash:${userId || ip}`, 30, 60 * 60 * 1000, 'Too many reports');
  const message = clean(body.message, 2000).trim() || 'Unknown error';
  const stack = clean(body.stack, 12000);
  const platform = PLATFORMS.includes(body.platform) ? body.platform : 'other';
  const appVersion = clean(body.app_version, 20);
  const device = clean(body.device, 100);
  const fingerprint = crypto.createHash('sha256').update(`${platform}|${appVersion}|${message.slice(0, 300)}|${normalizeStack(stack)}`).digest('hex');
  const row = await db.one(
    `INSERT INTO client_errors (fingerprint, platform, app_version, message, stack, last_device, last_user_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (fingerprint) DO UPDATE SET count = client_errors.count + 1, last_seen = now(),
       last_device = EXCLUDED.last_device, last_user_id = COALESCE(EXCLUDED.last_user_id, client_errors.last_user_id),
       resolved_at = NULL
     RETURNING id`,
    [fingerprint, platform, appVersion, message, stack, device, userId || null],
  );
  if (userId) {
    const added = await db.one('INSERT INTO client_error_users (error_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING error_id', [row.id, userId]);
    if (added) await db.query('UPDATE client_errors SET users_count = (SELECT count(*) FROM client_error_users WHERE error_id = $1) WHERE id = $1', [row.id]);
  }
  return { ok: true };
}

async function list(query = {}) {
  const limit = v.limit(query.limit, 50, 200);
  const where = [];
  const params = [];
  if (query.status === 'resolved') where.push('resolved_at IS NOT NULL');
  else if (query.status !== 'all') where.push('resolved_at IS NULL');
  if (query.platform && PLATFORMS.includes(query.platform)) {
    params.push(query.platform);
    where.push(`platform = $${params.length}`);
  }
  const rows = await db.many(
    `SELECT id, platform, app_version, message, stack, last_device, last_user_id, count, users_count,
            resolved_at, first_seen, last_seen
     FROM client_errors ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY last_seen DESC LIMIT ${limit}`,
    params,
  );
  const totals = await db.one(
    `SELECT count(*) FILTER (WHERE resolved_at IS NULL) AS open,
            COALESCE(sum(count) FILTER (WHERE last_seen > now() - interval '24 hours'), 0)::int AS last_24h
     FROM client_errors`,
  );
  return { totals, crashes: rows };
}

async function resolve(idRaw, resolved = true) {
  const r = await db.one('UPDATE client_errors SET resolved_at = CASE WHEN $2 THEN now() ELSE NULL END WHERE id = $1 RETURNING id', [v.id(idRaw, 'id'), !!resolved]);
  if (!r) throw notFound('not_found', 'Crash report not found');
  return { ok: true };
}

module.exports = { record, list, resolve, normalizeStack };
