'use strict';

const path = require('path');

try {
  // dotenv is optional at runtime (env vars may come from the host)
  require('dotenv').config();
} catch (_) {
  /* ignore */
}

const env = process.env;
const isProd = env.NODE_ENV === 'production';

function required(name, devDefault) {
  const value = env[name];
  if (value) return value;
  if (isProd) throw new Error(`Missing required environment variable: ${name}`);
  return devDefault;
}

function int(name, def) {
  const n = parseInt(env[name] || '', 10);
  return Number.isFinite(n) ? n : def;
}

const config = {
  isProd,
  port: int('PORT', 4000),
  trustProxy: env.TRUST_PROXY === 'true',
  corsOrigins: (env.CORS_ORIGINS || '*')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  databaseUrl: required('DATABASE_URL', 'postgres://chat:chat@127.0.0.1:5432/chatapp'),

  jwtSecret: required('JWT_SECRET', 'dev-user-jwt-secret-change-me'),
  adminJwtSecret: required('ADMIN_JWT_SECRET', 'dev-admin-jwt-secret-change-me'),
  otpSecret: required('OTP_SECRET', 'dev-otp-secret-change-me'),

  accessTokenTtlSec: int('ACCESS_TOKEN_TTL_SEC', 900),
  refreshTokenTtlDays: int('REFRESH_TOKEN_TTL_DAYS', 60),
  adminTokenTtlSec: 12 * 60 * 60,

  otp: {
    devMode: env.OTP_DEV_MODE === 'true',
    ttlSec: 300,
    maxAttempts: 5,
    length: 6,
  },

  sms: {
    provider: env.SMS_PROVIDER || 'console',
    httpUrl: env.SMS_HTTP_URL || '',
    httpToken: env.SMS_HTTP_TOKEN || '',
    twilioSid: env.TWILIO_ACCOUNT_SID || '',
    twilioToken: env.TWILIO_AUTH_TOKEN || '',
    twilioFrom: env.TWILIO_FROM || '',
  },

  uploadDir: path.resolve(env.UPLOAD_DIR || path.join(__dirname, '..', 'uploads')),
  // Hard ceiling for a single upload; the admin "max_upload_mb" setting can only lower it.
  uploadHardLimitMb: 2048,

  firebaseServiceAccountPath: env.FIREBASE_SERVICE_ACCOUNT_PATH || '',
};

if (config.isProd && config.otp.devMode) {
  // eslint-disable-next-line no-console
  console.warn('WARNING: OTP_DEV_MODE=true in production — OTP codes are returned by the API!');
}

module.exports = config;
