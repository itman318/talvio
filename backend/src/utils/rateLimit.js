'use strict';

const { tooMany } = require('./errors');

/**
 * Simple in-memory fixed-window rate limiter.
 * NOTE: per-process. When running several Node instances, move this to Redis.
 */
const buckets = new Map();

function hit(key, limit, windowMs) {
  const now = Date.now();
  let b = buckets.get(key);
  if (!b || b.resetAt <= now) {
    b = { count: 0, resetAt: now + windowMs };
    buckets.set(key, b);
  }
  b.count += 1;
  return {
    allowed: b.count <= limit,
    retryAfterSec: Math.max(1, Math.ceil((b.resetAt - now) / 1000)),
  };
}

/** Throws 429 when the limit is exceeded. */
function enforce(key, limit, windowMs, message) {
  const r = hit(key, limit, windowMs);
  if (!r.allowed) throw tooMany(r.retryAfterSec, message);
}

function reset(prefix) {
  for (const k of buckets.keys()) if (!prefix || k.startsWith(prefix)) buckets.delete(k);
}

const sweeper = setInterval(() => {
  const now = Date.now();
  for (const [k, b] of buckets) if (b.resetAt <= now) buckets.delete(k);
}, 60 * 1000);
sweeper.unref();

module.exports = { hit, enforce, reset };
