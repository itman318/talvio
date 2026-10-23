'use strict';

/**
 * Talvio Bot API endpoint: GET/POST /api/bot/v1/<method> with "Authorization: Bearer <bot token>"
 * (or ?token=…), JSON / form / multipart (photo, document).
 *   → { ok: true, data } | { ok: false, error: { code, message, retry_after? } }
 */
const multer = require('multer');
const config = require('../config');
const settings = require('../services/settings.service');
const botService = require('../services/bot.service');
const { storage } = require('./routes.user');
const { AppError } = require('../utils/errors');

async function parseMultipart(req, res) {
  if (!req.is('multipart/form-data')) return null;
  const maxMb = Math.min(await settings.get('max_upload_mb'), config.uploadHardLimitMb); // bots: the normal limit
  return new Promise((resolve, reject) => {
    multer({ storage, limits: { fileSize: maxMb * 1024 * 1024, files: 1, fields: 30 } }).fields([
      { name: 'photo', maxCount: 1 },
      { name: 'document', maxCount: 1 },
    ])(req, res, (err) => {
      if (err) return reject(err);
      const f = req.files || {};
      return resolve((f.photo && f.photo[0]) || (f.document && f.document[0]) || null);
    });
  });
}

module.exports = async function botApi(req, res) {
  try {
    const file = await parseMultipart(req, res);
    const params = { ...req.query, ...(req.body && typeof req.body === 'object' ? req.body : {}) };
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : String(params.token || '');
    delete params.token;
    const data = await botService.callMethod(token, req.params.method, params, file);
    res.json({ ok: true, data });
  } catch (err) {
    const status = err instanceof AppError ? err.status : err.code === 'LIMIT_FILE_SIZE' ? 413 : 500;
    if (status === 500) console.error('bot api error', err); // eslint-disable-line no-console
    const error = { code: status === 500 ? 'internal_error' : err.code || 'bad_request', message: status === 500 ? 'Internal Server Error' : err.message };
    if (err.extra && err.extra.retry_after) error.retry_after = err.extra.retry_after;
    res.status(status).json({ ok: false, error });
  }
};
