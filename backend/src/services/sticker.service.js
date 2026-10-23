'use strict';

/**
 * Stickers: official packs (shipped in backend/assets/stickers/<slug>/ and installed for everyone)
 * plus packs users make from their own images. Sticker images are public media (PNG/WebP/GIF ≤ 1 MB).
 * GIFs: search through the Tenor API on the server, so the API key never reaches the apps.
 */
const fs = require('fs');
const path = require('path');
const config = require('../config');
const db = require('../db');
const settings = require('./settings.service');
const userService = require('./user.service');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { badRequest, forbidden, notFound } = require('../utils/errors');

const ASSETS = path.join(__dirname, '..', '..', 'assets', 'stickers');
const MAX_PER_PACK = 120;
const MAX_OWN_PACKS = 20;

function packJson(p, stickers, installed) {
  return {
    id: p.id,
    title: p.title,
    slug: p.slug,
    is_official: p.is_official,
    is_public: p.is_public,
    owner_id: p.owner_id,
    installs: p.installs,
    installed: !!installed,
    cover_url: stickers && stickers[0] ? stickers[0].url : null,
    stickers: stickers || undefined,
  };
}

const stickerJson = (s) => ({ id: s.id, pack_id: s.pack_id, emoji: s.emoji, media_id: s.media_id, url: userService.avatarUrl(s.media_id) });

async function stickersOf(packIds) {
  if (!packIds.length) return new Map();
  const rows = await db.many('SELECT * FROM stickers WHERE pack_id = ANY($1::bigint[]) ORDER BY pack_id, position, id', [packIds]);
  const map = new Map();
  for (const r of rows) {
    if (!map.has(r.pack_id)) map.set(r.pack_id, []);
    map.get(r.pack_id).push(stickerJson(r));
  }
  return map;
}

/** The user's packs: official ones first (always there), then installed and own packs. */
async function myPacks(userId) {
  await settings.requireFeature('feature_stickers', 'Stickers');
  const packs = await db.many(
    `SELECT p.*, (u.user_id IS NOT NULL) AS installed FROM sticker_packs p
     LEFT JOIN user_sticker_packs u ON u.pack_id = p.id AND u.user_id = $1
     WHERE p.is_official OR u.user_id IS NOT NULL OR p.owner_id = $1
     ORDER BY p.is_official DESC, u.added_at NULLS LAST, p.id`,
    [userId],
  );
  const map = await stickersOf(packs.map((p) => p.id));
  return packs.map((p) => packJson(p, map.get(p.id) || [], true));
}

async function getPack(userId, idRaw) {
  const p = await db.one('SELECT * FROM sticker_packs WHERE id = $1', [v.id(idRaw, 'pack_id')]);
  if (!p || (!p.is_public && !p.is_official && p.owner_id !== userId)) throw notFound('pack_not_found', 'Sticker pack not found');
  const installed = p.is_official || p.owner_id === userId
    || !!(await db.one('SELECT 1 FROM user_sticker_packs WHERE user_id = $1 AND pack_id = $2', [userId, p.id]));
  return packJson(p, (await stickersOf([p.id])).get(p.id) || [], installed);
}

async function searchPacks(userId, q) {
  const term = String(q || '').trim().slice(0, 64);
  const rows = await db.many(
    `SELECT * FROM sticker_packs WHERE (is_public OR is_official) AND ($1 = '' OR title ILIKE '%' || $1 || '%')
     ORDER BY is_official DESC, installs DESC, id DESC LIMIT 30`,
    [term.replace(/[\\%_]/g, (c) => `\\${c}`)],
  );
  const map = await stickersOf(rows.map((r) => r.id));
  return rows.map((p) => packJson(p, (map.get(p.id) || []).slice(0, 5), false));
}

async function createPack(userId, body = {}) {
  await settings.requireFeature('feature_stickers', 'Stickers');
  const title = v.str(body.title, { field: 'title', min: 1, max: 64, required: true });
  const n = await db.one('SELECT count(*)::int AS n FROM sticker_packs WHERE owner_id = $1', [userId]);
  if (n.n >= MAX_OWN_PACKS) throw forbidden('too_many_packs', `You can make up to ${MAX_OWN_PACKS} sticker packs`);
  const p = await db.one('INSERT INTO sticker_packs (title, owner_id, is_public) VALUES ($1, $2, $3) RETURNING *', [title, userId, body.is_public !== false]);
  await db.query('INSERT INTO user_sticker_packs (user_id, pack_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [userId, p.id]);
  return packJson(p, [], true);
}

async function ownPack(userId, idRaw) {
  const p = await db.one('SELECT * FROM sticker_packs WHERE id = $1', [v.id(idRaw, 'pack_id')]);
  if (!p) throw notFound('pack_not_found', 'Sticker pack not found');
  if (p.owner_id !== userId) throw forbidden('not_owner', 'Only the owner can change this pack');
  return p;
}

async function addSticker(userId, packIdRaw, body = {}) {
  const p = await ownPack(userId, packIdRaw);
  rateLimit.enforce(`sticker:add:${userId}`, 60, 10 * 60 * 1000, 'Slow down');
  const media = await db.one(`SELECT * FROM media WHERE id = $1 AND uploader_id = $2 AND kind = 'sticker'`, [v.id(body.media_id, 'media_id'), userId]);
  if (!media) throw badRequest('invalid_media', 'Upload the image as a sticker first (PNG, WebP or GIF up to 1 MB)');
  const count = await db.one('SELECT count(*)::int AS n FROM stickers WHERE pack_id = $1', [p.id]);
  if (count.n >= MAX_PER_PACK) throw forbidden('pack_full', `A pack can have up to ${MAX_PER_PACK} stickers`);
  const emoji = (v.str(body.emoji, { field: 'emoji', max: 16 }) || '🙂').slice(0, 16);
  const s = await db.one('INSERT INTO stickers (pack_id, media_id, emoji, position) VALUES ($1, $2, $3, $4) RETURNING *', [p.id, media.id, emoji, count.n]);
  return stickerJson(s);
}

async function removeSticker(userId, packIdRaw, stickerIdRaw) {
  const p = await ownPack(userId, packIdRaw);
  await db.query('DELETE FROM stickers WHERE id = $1 AND pack_id = $2', [v.id(stickerIdRaw, 'sticker_id'), p.id]);
  return { ok: true };
}

async function installPack(userId, idRaw) {
  const p = await getPack(userId, idRaw);
  const r = await db.one('INSERT INTO user_sticker_packs (user_id, pack_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING pack_id', [userId, p.id]);
  if (r) await db.query('UPDATE sticker_packs SET installs = installs + 1 WHERE id = $1', [p.id]);
  return { ok: true };
}

async function uninstallPack(userId, idRaw) {
  await db.query('DELETE FROM user_sticker_packs WHERE user_id = $1 AND pack_id = $2', [userId, v.id(idRaw, 'pack_id')]);
  return { ok: true };
}

async function deletePack(userId, idRaw) {
  const p = await ownPack(userId, idRaw);
  // stickers already sent stay visible: messages keep their media
  await db.query('DELETE FROM sticker_packs WHERE id = $1', [p.id]);
  return { ok: true };
}

/** For message sending: the sticker → its media and pack. */
async function stickerForSend(idRaw) {
  const s = await db.one(
    `SELECT s.*, p.title AS pack_title FROM stickers s JOIN sticker_packs p ON p.id = s.pack_id WHERE s.id = $1`,
    [v.id(idRaw, 'sticker_id')],
  );
  if (!s) throw notFound('sticker_not_found', 'This sticker is no longer available');
  return s;
}

/** Installs the official packs from backend/assets/stickers on start-up (idempotent). */
async function ensureOfficialPacks() {
  if (!fs.existsSync(ASSETS)) return;
  for (const slug of fs.readdirSync(ASSETS)) {
    const dir = path.join(ASSETS, slug);
    const manifestPath = path.join(dir, 'pack.json');
    if (!fs.existsSync(manifestPath)) continue;
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    let pack = await db.one('SELECT * FROM sticker_packs WHERE slug = $1', [slug]);
    if (pack) continue;
    pack = await db.one('INSERT INTO sticker_packs (title, slug, is_official, is_public) VALUES ($1, $2, TRUE, TRUE) RETURNING *', [manifest.title, slug]);
    const target = path.join(config.uploadDir, 'stickers', slug);
    fs.mkdirSync(target, { recursive: true });
    let pos = 0;
    for (const st of manifest.stickers) {
      const src = path.join(dir, st.file);
      if (!fs.existsSync(src)) continue;
      const dst = path.join(target, st.file);
      fs.copyFileSync(src, dst);
      const media = await db.one(
        `INSERT INTO media (uploader_id, kind, mime, size_bytes, storage_path, original_name, width, height, is_public)
         VALUES (NULL, 'sticker', 'image/png', $1, $2, $3, 512, 512, TRUE) RETURNING id`,
        [fs.statSync(dst).size, path.relative(config.uploadDir, dst), st.file],
      );
      await db.query('INSERT INTO stickers (pack_id, media_id, emoji, position) VALUES ($1, $2, $3, $4)', [pack.id, media.id, st.emoji || '', pos++]);
    }
  }
}

// ------------------------------------------------------------------ GIFs (Tenor)
function tenorItem(r) {
  const f = r.media_formats || {};
  const gif = f.gif || f.mediumgif || f.tinygif;
  const tiny = f.tinygif || f.nanogif || gif;
  if (!gif) return null;
  return {
    id: r.id,
    url: gif.url,
    preview: tiny.url,
    mp4: (f.tinymp4 || f.mp4 || {}).url || null,
    width: (gif.dims || [])[0] || null,
    height: (gif.dims || [])[1] || null,
    title: r.content_description || '',
  };
}

async function gifs(userId, query = {}) {
  await settings.requireFeature('feature_gifs', 'GIFs');
  const key = await settings.get('gif_api_key');
  if (!key) throw forbidden('feature_disabled', 'GIF search is not set up yet');
  rateLimit.enforce(`gif:${userId}`, 60, 60 * 1000, 'Slow down');
  const q = String(query.q || '').trim().slice(0, 80);
  const params = new URLSearchParams({ key, client_key: 'talvio', limit: '24', media_filter: 'gif,tinygif,tinymp4', contentfilter: 'medium', locale: 'en_PK' });
  if (query.pos) params.set('pos', String(query.pos).slice(0, 80));
  if (q) params.set('q', q);
  const res = await fetch(`https://tenor.googleapis.com/v2/${q ? 'search' : 'featured'}?${params}`, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw badRequest('gif_unavailable', 'GIF search is not available right now');
  const data = await res.json();
  return { results: (data.results || []).map(tenorItem).filter(Boolean), next: data.next || null };
}

/** Only GIFs served by Tenor can be sent (no arbitrary image links in chats). */
function validateGif(raw = {}) {
  const ok = (u) => typeof u === 'string' && /^https:\/\/(media\d*\.tenor\.com|c\.tenor\.com)\//.test(u) && u.length < 500;
  if (!ok(raw.url) || (raw.preview && !ok(raw.preview)) || (raw.mp4 && !ok(raw.mp4))) throw badRequest('invalid_gif', 'Invalid GIF');
  const dim = (n) => (Number.isFinite(Number(n)) && Number(n) > 0 && Number(n) < 5000 ? Math.round(Number(n)) : null);
  return { url: raw.url, preview: raw.preview || raw.url, mp4: raw.mp4 || null, width: dim(raw.width), height: dim(raw.height) };
}

module.exports = {
  myPacks, getPack, searchPacks, createPack, addSticker, removeSticker, installPack, uninstallPack, deletePack,
  stickerForSend, ensureOfficialPacks, gifs, validateGif,
};
