'use strict';

/**
 * Profile pictures for the official bots (BotForge, ID, Support, Account Status).
 * Pictures live in backend/assets/bots/<username>.png (sources: assets/bots/source/*.svg).
 * Bump VERSION after changing a picture: every server then installs the new one on start.
 * A picture someone set by hand (not one of ours) is never replaced.
 */
const fs = require('fs');
const path = require('path');
const db = require('../db');
const bus = require('../bus');
const config = require('../config');

const VERSION = 'v1';
const DIR = path.join(__dirname, '..', '..', 'assets', 'bots');

async function apply(userId, username) {
  const src = path.join(DIR, `${username}.png`);
  if (!fs.existsSync(src)) return;
  const name = `sysbot-${username}-${VERSION}.png`;
  const cur = await db.one('SELECT m.original_name FROM users u LEFT JOIN media m ON m.id = u.avatar_media_id WHERE u.id = $1', [userId]);
  if (!cur) return;
  if (cur.original_name === name) return; // already the latest
  const ours = !cur.original_name || String(cur.original_name).startsWith('sysbot-');
  if (!ours) return;
  const target = path.join(config.uploadDir, 'bots');
  fs.mkdirSync(target, { recursive: true });
  const dst = path.join(target, name);
  fs.copyFileSync(src, dst);
  const media = await db.one(
    `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name, width, height, is_public)
     VALUES ($1, 'avatar', 'image/png', $2, $3, $4, 512, 512, TRUE) RETURNING id`,
    [userId, fs.statSync(dst).size, path.relative(config.uploadDir, dst), name],
  );
  await db.query('UPDATE users SET avatar_media_id = $2, updated_at = now() WHERE id = $1', [userId, media.id]);
  bus.emit('user:updated', { userId });
}

/** Never lets a picture problem stop a bot from starting. */
async function ensureAvatar(userId, username) {
  try {
    await apply(userId, username);
  } catch (err) {
    console.error(`bot picture for @${username}:`, err.message); // eslint-disable-line no-console
  }
}

module.exports = { ensureAvatar, VERSION };
