'use strict';

const config = require('../config');
const authService = require('../services/auth.service');
const adminService = require('../services/admin.service');
const settings = require('../services/settings.service');
const { AppError, unauthorized } = require('../utils/errors');

const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function bearer(req) {
  const h = req.headers.authorization || '';
  return h.startsWith('Bearer ') ? h.slice(7).trim() : null;
}

/** Mobile app user authentication. Sets req.user, req.userId, req.sessionId. */
const requireUser = asyncHandler(async (req, res, next) => {
  const token = bearer(req);
  if (!token) throw unauthorized();
  const { user, sessionId } = await authService.authenticate(token);
  req.user = user;
  req.userId = user.id;
  req.sessionId = sessionId;
  next();
});

/** Admin panel authentication, optionally requiring a permission. */
function requireAdmin(perm) {
  return asyncHandler(async (req, res, next) => {
    const token = bearer(req);
    if (!token) throw unauthorized();
    req.admin = await adminService.authenticate(token);
    // Policy: every admin must turn on 2FA before using the panel (only /me routes stay open).
    if (!req.admin.totp_enabled && !req.path.startsWith('/me') && (await settings.get('require_admin_2fa'))) {
      throw new AppError(403, 'two_factor_setup_required', 'Turn on two-factor authentication to continue');
    }
    if (perm) adminService.requirePerm(req.admin, perm);
    next();
  });
}

const maintenanceGate = asyncHandler(async (req, res, next) => {
  const s = await settings.getAll();
  if (s.maintenance_mode) {
    res.status(503).json({ error: { code: 'maintenance', message: s.maintenance_message } });
    return;
  }
  next();
});

function securityHeaders(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  if (config.isProd) res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  next();
}

function cors(req, res, next) {
  const origin = req.headers.origin;
  if (origin) {
    if (config.corsOrigins.includes('*')) res.setHeader('Access-Control-Allow-Origin', '*');
    else if (config.corsOrigins.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
    }
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    res.setHeader('Access-Control-Max-Age', '600');
  }
  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }
  next();
}

function notFoundHandler(req, res) {
  res.status(404).json({ error: { code: 'not_found', message: 'Route not found' } });
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (err instanceof AppError) {
    if (err.status === 429 && err.extra && err.extra.retry_after) res.setHeader('Retry-After', String(err.extra.retry_after));
    res.status(err.status).json({ error: { code: err.code, message: err.message, ...(err.extra || {}) } });
    return;
  }
  if (err && err.name === 'MulterError') {
    const code = err.code === 'LIMIT_FILE_SIZE' ? 'file_too_large' : 'upload_error';
    res.status(400).json({ error: { code, message: code === 'file_too_large' ? 'File is too large' : err.message } });
    return;
  }
  if (err && err.type === 'entity.parse.failed') {
    res.status(400).json({ error: { code: 'invalid_json', message: 'Request body is not valid JSON' } });
    return;
  }
  if (err && err.type === 'entity.too.large') {
    res.status(413).json({ error: { code: 'payload_too_large', message: 'Request body is too large' } });
    return;
  }
  // eslint-disable-next-line no-console
  console.error(err);
  res.status(500).json({ error: { code: 'server_error', message: 'Something went wrong' } });
}

module.exports = {
  asyncHandler,
  requireUser,
  requireAdmin,
  maintenanceGate,
  securityHeaders,
  cors,
  notFoundHandler,
  errorHandler,
};
