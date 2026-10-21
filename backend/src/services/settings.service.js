'use strict';

const db = require('../db');
const { badRequest } = require('../utils/errors');

/** Admin-editable settings with defaults and type rules. */
const DEFINITIONS = {
  registration_open: { type: 'boolean', default: true },
  maintenance_mode: { type: 'boolean', default: false },
  maintenance_message: { type: 'string', default: 'We are doing maintenance. Please try again soon.', max: 300 },
  max_group_members: { type: 'integer', default: 1000, min: 2, max: 200000 },
  max_upload_mb: { type: 'integer', default: 50, min: 1, max: 2048 },
  message_edit_window_hours: { type: 'integer', default: 48, min: 0, max: 8760 },
  min_app_version: { type: 'string', default: '1.0.0', max: 20 },
  latest_app_version: { type: 'string', default: '1.0.0', max: 20 },
  support_username: { type: 'string', default: '', max: 32 },
};

let cache = null;
let cacheAt = 0;
const CACHE_MS = 15 * 1000;

function defaults() {
  const out = {};
  for (const [k, d] of Object.entries(DEFINITIONS)) out[k] = d.default;
  return out;
}

async function getAll() {
  if (cache && Date.now() - cacheAt < CACHE_MS) return cache;
  const rows = await db.many('SELECT key, value FROM app_settings');
  const out = defaults();
  for (const r of rows) if (r.key in DEFINITIONS) out[r.key] = r.value;
  cache = out;
  cacheAt = Date.now();
  return out;
}

async function get(key) {
  return (await getAll())[key];
}

function validateValue(key, value) {
  const d = DEFINITIONS[key];
  if (!d) throw badRequest('invalid_setting', `Unknown setting: ${key}`);
  if (d.type === 'boolean' && typeof value !== 'boolean') {
    throw badRequest('invalid_setting', `${key} must be true/false`);
  }
  if (d.type === 'integer') {
    if (!Number.isInteger(value) || value < d.min || value > d.max) {
      throw badRequest('invalid_setting', `${key} must be an integer between ${d.min} and ${d.max}`);
    }
  }
  if (d.type === 'string') {
    if (typeof value !== 'string' || value.length > d.max) {
      throw badRequest('invalid_setting', `${key} must be text (max ${d.max} characters)`);
    }
  }
  return value;
}

/** Update several settings at once. Returns the full settings object. */
async function update(changes, adminId) {
  if (!changes || typeof changes !== 'object') throw badRequest('invalid_setting', 'Settings object required');
  const entries = Object.entries(changes).map(([k, v]) => [k, validateValue(k, v)]);
  await db.tx(async (c) => {
    for (const [k, v] of entries) {
      await c.query(
        `INSERT INTO app_settings (key, value, updated_by, updated_at) VALUES ($1, $2, $3, now())
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [k, JSON.stringify(v), adminId || null],
      );
    }
  });
  cache = null;
  return getAll();
}

function clearCache() {
  cache = null;
}

/** Values safe to expose to the mobile app before login. */
async function publicConfig() {
  const s = await getAll();
  return {
    registration_open: s.registration_open,
    maintenance_mode: s.maintenance_mode,
    maintenance_message: s.maintenance_message,
    max_upload_mb: s.max_upload_mb,
    max_group_members: s.max_group_members,
    message_edit_window_hours: s.message_edit_window_hours,
    min_app_version: s.min_app_version,
    latest_app_version: s.latest_app_version,
    support_username: s.support_username,
  };
}

module.exports = { DEFINITIONS, getAll, get, update, clearCache, publicConfig };
