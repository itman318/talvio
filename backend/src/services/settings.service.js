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

  // ---- moderation (Phase 2)
  banned_words: { type: 'string_list', default: [], maxItems: 500, maxLength: 60 },
  banned_words_action: { type: 'enum', default: 'block', values: ['block', 'flag'] },
  new_account_link_hours: { type: 'integer', default: 24, min: 0, max: 720 },
  spam_duplicate_threshold: { type: 'integer', default: 5, min: 0, max: 100 },
  spam_restrict_minutes: { type: 'integer', default: 60, min: 1, max: 10080 },
  auto_restrict_reports: { type: 'integer', default: 5, min: 0, max: 1000 },
  blocked_phone_prefixes: { type: 'string_list', default: [], maxItems: 200, maxLength: 16 },
  require_admin_2fa: { type: 'boolean', default: false },

  // ---- Batch A
  reserved_usernames: { type: 'string_list', default: ['admin', 'support', 'official', 'moderator', 'help'], maxItems: 2000, maxLength: 32 },
  blocked_ips: { type: 'string_list', default: [], maxItems: 1000, maxLength: 45 },
  feature_channels: { type: 'boolean', default: true },
  feature_stories: { type: 'boolean', default: true },
  feature_polls: { type: 'boolean', default: true },
  feature_voice_messages: { type: 'boolean', default: true },
  feature_location: { type: 'boolean', default: true },

  // ---- Batch B: calls
  feature_calls: { type: 'boolean', default: true },
  feature_video_calls: { type: 'boolean', default: true },
  call_ring_timeout_sec: { type: 'integer', default: 45, min: 15, max: 120 },
  call_max_minutes: { type: 'integer', default: 240, min: 5, max: 1440 },
  stun_urls: { type: 'string_list', default: ['stun:stun.l.google.com:19302'], maxItems: 10, maxLength: 200 },
  turn_urls: { type: 'string_list', default: [], maxItems: 10, maxLength: 200 },

  // ---- Batch C: secret chats
  feature_secret_chats: { type: 'boolean', default: true },

  // ---- Batch D1
  feature_bots: { type: 'boolean', default: true },
  max_bots_per_user: { type: 'integer', default: 20, min: 0, max: 1000 },
  feature_channel_comments: { type: 'boolean', default: true },
  feature_topics: { type: 'boolean', default: true },

  // ---- Batch D2
  feature_premium: { type: 'boolean', default: true },
  premium_upload_mb: { type: 'integer', default: 500, min: 1, max: 2048 },
  payment_manual_enabled: { type: 'boolean', default: true },
  payment_manual_instructions: {
    type: 'string',
    default: 'Send the amount to our JazzCash / Easypaisa account 03XX-XXXXXXX (Account title: Your Company), then upload the screenshot and transaction ID.',
    max: 1000,
  },
  feature_ads: { type: 'boolean', default: false },
  ads_min_subscribers: { type: 'integer', default: 1000, min: 0, max: 100000000 },
};

const FEATURE_KEYS = [
  'feature_channels',
  'feature_stories',
  'feature_polls',
  'feature_voice_messages',
  'feature_location',
  'feature_calls',
  'feature_video_calls',
  'feature_secret_chats',
  'feature_bots',
  'feature_channel_comments',
  'feature_topics',
  'feature_premium',
  'feature_ads',
];

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
  if (d.type === 'enum' && !d.values.includes(value)) {
    throw badRequest('invalid_setting', `${key} must be one of: ${d.values.join(', ')}`);
  }
  if (d.type === 'string_list') {
    if (!Array.isArray(value) || value.length > d.maxItems) {
      throw badRequest('invalid_setting', `${key} must be a list of at most ${d.maxItems} items`);
    }
    const cleaned = [...new Set(value.map((x) => String(x).trim().toLowerCase()).filter(Boolean))];
    if (cleaned.some((x) => x.length > d.maxLength)) {
      throw badRequest('invalid_setting', `Each item in ${key} can be at most ${d.maxLength} characters`);
    }
    return cleaned;
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
    features: {
      channels: s.feature_channels,
      stories: s.feature_stories,
      polls: s.feature_polls,
      voice_messages: s.feature_voice_messages,
      location: s.feature_location,
      calls: s.feature_calls,
      video_calls: s.feature_calls && s.feature_video_calls,
      secret_chats: s.feature_secret_chats,
      bots: s.feature_bots,
      channel_comments: s.feature_channel_comments,
      topics: s.feature_topics,
      premium: s.feature_premium,
    },
    call_ring_timeout_sec: s.call_ring_timeout_sec,
  };
}

/** Throws 403 feature_disabled when an admin switched a feature off. */
async function requireFeature(key, label) {
  if (!(await get(key))) {
    const { forbidden } = require('../utils/errors');
    throw forbidden('feature_disabled', `${label} are turned off right now`);
  }
}

module.exports = { DEFINITIONS, FEATURE_KEYS, getAll, get, update, clearCache, publicConfig, requireFeature };
