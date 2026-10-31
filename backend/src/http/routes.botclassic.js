'use strict';

/**
 * Talvio Bot API — Classic (see services/botclassic.service.js):
 *   {base}/bot<token>/<method>  and  {base}/file/bot<token>/<file_path>,  base = /api/classic
 * Accepts JSON, urlencoded and multipart (files in any field).
 */
const fs = require('fs');
const multer = require('multer');
const config = require('../config');
const settings = require('../services/settings.service');
const classic = require('../services/botclassic.service');
const media = require('../services/media.service');
const { storage } = require('./routes.user');

async function parseMultipart(req, res) {
  if (!req.is('multipart/form-data')) return {};
  const maxMb = Math.min(await settings.get('max_upload_mb'), config.uploadHardLimitMb);
  return new Promise((resolve, reject) => {
    multer({ storage, limits: { fileSize: maxMb * 1024 * 1024, files: 3, fields: 60 } }).any()(req, res, (err) => {
      if (err) return reject(err);
      const files = {};
      for (const f of req.files || []) files[f.fieldname] = f;
      return resolve(files);
    });
  });
}

async function method(req, res) {
  let files = {};
  try {
    files = await parseMultipart(req, res);
    const params = { ...req.query, ...(req.body && typeof req.body === 'object' ? req.body : {}) };
    const result = await classic.call(req.params[0], req.params[1], params, files);
    res.json({ ok: true, result });
  } catch (err) {
    for (const f of Object.values(files)) fs.promises.unlink(f.path).catch(() => {});
    const { status, body } = classic.errorBody(err);
    if (status === 500) console.error('classic bot api error', err); // eslint-disable-line no-console
    res.status(status).json(body);
  }
}

async function file(req, res) {
  try {
    const m = await classic.fileFor(req.params[0], req.params[1]);
    res.type(m.mime);
    res.sendFile(media.absolutePath(m));
  } catch (err) {
    const { status, body } = classic.errorBody(err);
    res.status(status).json(body);
  }
}

module.exports = { method, file };
