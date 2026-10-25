'use strict';

/**
 * Talvio Bot API v2: GET/POST /api/bots/v2/<method>, key in "X-Bot-Key" (or "Authorization: Bearer", or ?key=).
 * JSON, form or multipart (one file in the field "file"). → { ok: true, data } | { ok: false, error: { code, message } }
 */
const multer = require('multer');
const config = require('../config');
const settings = require('../services/settings.service');
const v2 = require('../services/botv2.service');
const { storage } = require('./routes.user');
const { AppError } = require('../utils/errors');

async function parseMultipart(req, res) {
  if (!req.is('multipart/form-data')) return null;
  const maxMb = Math.min(await settings.get('max_upload_mb'), config.uploadHardLimitMb);
  return new Promise((resolve, reject) => {
    multer({ storage, limits: { fileSize: maxMb * 1024 * 1024, files: 1, fields: 30 } }).single('file')(req, res, (err) => (err ? reject(err) : resolve(req.file || null)));
  });
}

module.exports = async function botApiV2(req, res) {
  try {
    const file = await parseMultipart(req, res);
    const params = { ...req.query, ...(req.body && typeof req.body === 'object' ? req.body : {}) };
    const auth = req.headers.authorization || '';
    const key = req.get('x-bot-key') || (auth.startsWith('Bearer ') ? auth.slice(7).trim() : String(params.key || ''));
    delete params.key;
    const data = await v2.call(key, req.params.method, params, file);
    res.json({ ok: true, data });
  } catch (err) {
    const status = err instanceof AppError ? err.status : err.code === 'LIMIT_FILE_SIZE' ? 413 : 500;
    if (status === 500) console.error('bot api v2 error', err); // eslint-disable-line no-console
    const error = { code: status === 500 ? 'internal_error' : err.code || 'bad_request', message: status === 500 ? 'Internal Server Error' : err.message };
    if (err.extra && err.extra.retry_after) error.retry_after = err.extra.retry_after;
    res.status(status).json({ ok: false, error });
  }
};
