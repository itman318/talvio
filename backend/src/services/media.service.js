'use strict';

const fs = require('fs');
const path = require('path');
const config = require('../config');
const db = require('../db');
const settings = require('./settings.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, notFound } = require('../utils/errors');

const KINDS = ['image', 'video', 'voice', 'file', 'avatar', 'sticker'];
const SAFE_IMAGE_MIMES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/heic', 'image/heif'];
const VOICE_EXT = ['.m4a', '.aac', '.ogg', '.opus', '.mp3', '.wav', '.webm'];

function mimeAllowed(kind, mime, originalName) {
  const ext = path.extname(originalName || '').toLowerCase();
  switch (kind) {
    case 'image':
      return SAFE_IMAGE_MIMES.includes(mime);
    case 'avatar':
      return ['image/jpeg', 'image/png', 'image/webp'].includes(mime);
    case 'sticker':
      return ['image/png', 'image/webp', 'image/gif'].includes(mime);
    case 'video':
      return mime.startsWith('video/');
    case 'voice':
      return mime.startsWith('audio/') || (mime === 'application/octet-stream' && VOICE_EXT.includes(ext));
    case 'file':
      return true;
    default:
      return false;
  }
}

function optInt(value, max) {
  if (value === undefined || value === null || value === '') return null;
  const n = parseInt(value, 10);
  return Number.isFinite(n) && n >= 0 && n <= max ? n : null;
}

function serialize(m) {
  if (!m) return null;
  return {
    id: m.id,
    kind: m.kind,
    mime: m.mime,
    size: m.size_bytes,
    name: m.original_name,
    duration: m.duration_sec,
    width: m.width,
    height: m.height,
    url: m.is_public ? `/api/media/${m.id}/public` : `/api/media/${m.id}`,
  };
}

function removeFile(file) {
  if (file && file.path) fs.unlink(file.path, () => {});
}

/**
 * Registers a file that multer already wrote to disk.
 * `file` = multer file ({ path, size, mimetype, originalname }), `body` = form fields.
 */
async function registerUpload(userId, file, body) {
  if (!file) throw badRequest('file_required', 'No file uploaded (form field name must be "file")');
  try {
    rateLimit.enforce(`upload:${userId}`, 60, 10 * 60 * 1000, 'Too many uploads, please wait a bit');
    const kind = v.oneOf(body.kind || 'file', KINDS, 'kind');
    const mime = String(file.mimetype || 'application/octet-stream').toLowerCase();
    if (!mimeAllowed(kind, mime, file.originalname)) {
      throw badRequest('invalid_file_type', `This file type is not allowed for ${kind}`);
    }
    if (kind === 'sticker' && file.size > 1024 * 1024) throw badRequest('file_too_large', 'A sticker must be smaller than 1 MB');
    const maxMb = (await require('./payment.service').limitsFor(userId)).upload_mb; // lazy: avoids circular import
    if (file.size > maxMb * 1024 * 1024) {
      throw badRequest('file_too_large', `File is larger than ${maxMb} MB`);
    }
    const rel = path.relative(config.uploadDir, file.path);
    if (rel.startsWith('..') || path.isAbsolute(rel)) throw new Error('Upload stored outside upload dir');
    const name = String(file.originalname || '').replace(/[\r\n"\\/]/g, '_').slice(0, 255);
    const row = await db.one(
      `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name, duration_sec, width, height, is_public)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
      [
        userId,
        kind,
        mime,
        file.size,
        rel,
        name,
        optInt(body.duration, 86400),
        optInt(body.width, 100000),
        optInt(body.height, 100000),
        kind === 'avatar' || kind === 'sticker',
      ],
    );
    return serialize(row);
  } catch (err) {
    removeFile(file);
    throw err;
  }
}

/** Returns the media row if the user may download it, otherwise throws 404. */
async function getAccessible(userId, mediaIdRaw) {
  const mediaId = v.id(mediaIdRaw, 'media_id');
  const storyVisible = require('./story.service').visibleSql('$2'); // lazy: avoids circular import
  const m = await db.one(
    `SELECT m.* FROM media m
     WHERE m.id = $1 AND (
       m.is_public
       OR m.uploader_id = $2
       OR EXISTS (
         SELECT 1 FROM messages msg
         JOIN chat_members cm ON cm.chat_id = msg.chat_id AND cm.user_id = $2
         WHERE msg.media_id = m.id AND msg.deleted_at IS NULL AND msg.id > cm.cleared_before_id
       )
       OR EXISTS (SELECT 1 FROM stories s WHERE s.media_id = m.id AND ${storyVisible})
       OR EXISTS (
         SELECT 1 FROM secret_messages sm JOIN secret_chats sc ON sc.id = sm.secret_chat_id
         WHERE sm.media_id = m.id AND sc.status = 'active' AND (sc.initiator_id = $2 OR sc.peer_id = $2)
       )
     )`,
    [mediaId, userId],
  );
  if (!m) throw notFound('media_not_found', 'File not found');
  return m;
}

async function getPublic(mediaIdRaw) {
  const m = await db.one('SELECT * FROM media WHERE id = $1 AND is_public', [v.id(mediaIdRaw, 'media_id')]);
  if (!m) throw notFound('media_not_found', 'File not found');
  return m;
}

function absolutePath(m) {
  const abs = path.resolve(config.uploadDir, m.storage_path);
  if (!abs.startsWith(config.uploadDir + path.sep)) throw notFound('media_not_found', 'File not found');
  return abs;
}

/** Browsers may render these inline safely; everything else is served as a download. */
function isInlineSafe(m) {
  return SAFE_IMAGE_MIMES.includes(m.mime) || m.mime.startsWith('video/') || m.mime.startsWith('audio/');
}

module.exports = { KINDS, serialize, registerUpload, getAccessible, getPublic, absolutePath, isInlineSafe };
