'use strict';

/**
 * Photo helpers (Telegram-style fast photos):
 *  - thumb: a tiny (≤ 40 px) JPEG as base64, sent inside the message itself so a blurred
 *    picture shows the very moment the message appears — before any download;
 *  - preview: a ≤ 1280 px WebP next to the original, served for chat bubbles
 *    (usually 5–10× smaller than the photo the phone uploaded).
 * Uses `sharp` when it is installed (optional dependency); without it everything falls back
 * to the original file, so nothing breaks.
 */

const fs = require('fs');

let sharp = null;
try {
  sharp = require('sharp'); // eslint-disable-line global-require
  sharp.cache(false);
  sharp.concurrency(1); // small server: one core per photo is plenty
} catch (_) {
  sharp = null;
}

const PREVIEW_SIDE = 1280;
const THUMB_SIDE = 40;
const PREVIEWABLE = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'];

// one photo at a time, so a burst of uploads never starves the API of CPU
let chain = Promise.resolve();
function queued(fn) {
  const run = chain.then(fn, fn);
  chain = run.catch(() => {});
  return run;
}

function available() {
  return !!sharp;
}

const noGain = new Set(); // photos whose WebP was not smaller: the original is served

// p = chat bubble / story (≤ 1280 px), s = avatar in lists (≤ 256 px)
const VARIANTS = { p: { side: PREVIEW_SIDE, quality: 78, minBytes: 120 * 1024 }, s: { side: 256, quality: 80, minBytes: 24 * 1024 } };

function previewPathFor(abs, variant = 'p') {
  return `${abs}.${variant}.webp`;
}

/** { width, height, thumb } for a photo (orientation applied), or null. */
async function analyze(abs, mime) {
  if (!sharp || !PREVIEWABLE.includes(mime)) return null;
  return queued(async () => {
    const img = sharp(abs, { failOn: 'none', limitInputPixels: 80e6 });
    const meta = await img.metadata();
    const swap = (meta.orientation || 1) >= 5;
    const width = swap ? meta.height : meta.width;
    const height = swap ? meta.width : meta.height;
    const buf = await sharp(abs, { failOn: 'none', limitInputPixels: 80e6 })
      .rotate()
      .resize(THUMB_SIDE, THUMB_SIDE, { fit: 'inside' })
      .jpeg({ quality: 50 })
      .toBuffer();
    return { width: width || null, height: height || null, thumb: buf.toString('base64') };
  });
}

/** Path of the bubble-size WebP, made on first use; null → serve the original. */
async function preview(abs, mime, size, variant = 'p') {
  const opt = VARIANTS[variant];
  if (!sharp || !opt || !PREVIEWABLE.includes(mime)) return null;
  const out = previewPathFor(abs, variant);
  if (noGain.has(out)) return null;
  if (fs.existsSync(out)) return out;
  if (size && size < opt.minBytes && mime !== 'image/heic' && mime !== 'image/heif') return null; // already small
  return queued(async () => {
    if (fs.existsSync(out)) return out;
    const tmp = `${out}.${process.pid}.tmp`;
    await sharp(abs, { failOn: 'none', limitInputPixels: 80e6 })
      .rotate()
      .resize(opt.side, opt.side, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: opt.quality, effort: 3 })
      .toFile(tmp);
    // keep the preview only when it really is smaller
    const small = fs.statSync(tmp).size;
    if (size && small >= size) {
      fs.unlink(tmp, () => {});
      if (noGain.size > 5000) noGain.clear();
      noGain.add(out); // don't try again for this file
      return null;
    }
    fs.renameSync(tmp, out);
    return out;
  }).catch(() => null);
}

function removePreview(abs) {
  for (const k of Object.keys(VARIANTS)) fs.unlink(previewPathFor(abs, k), () => {});
}

module.exports = { available, analyze, preview, previewPathFor, removePreview, PREVIEWABLE };
