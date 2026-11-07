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
  // GIF (animated avatars): only the small still for lists — the original keeps its animation
  if (!sharp || !opt || !(PREVIEWABLE.includes(mime) || (mime === 'image/gif' && variant === 's'))) return null;
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

/** More than one frame (animated GIF / WebP)? */
async function isAnimated(abs) {
  if (!sharp) return false;
  try {
    const m = await sharp(abs, { failOn: 'none' }).metadata();
    return (m.pages || 1) > 1;
  } catch (_) {
    return false;
  }
}

function removePreview(abs) {
  for (const k of Object.keys(VARIANTS)) fs.unlink(previewPathFor(abs, k), () => {});
}

module.exports = { available, analyze, preview, previewPathFor, removePreview, isAnimated, PREVIEWABLE };

// ------------------------------------------------------------------ videos: poster frame (needs ffmpeg)
const { execFile } = require('child_process');

let ffmpegOk = null;
function hasFfmpeg() {
  if (ffmpegOk === null) {
    try {
      require('child_process').execFileSync('ffmpeg', ['-version'], { stdio: 'ignore', timeout: 5000 });
      ffmpegOk = true;
    } catch (_) {
      ffmpegOk = false;
    }
  }
  return ffmpegOk;
}

function run(cmd, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => (err ? reject(err) : resolve(stdout)));
  });
}

/** Size and length of a video via ffprobe (rotation applied). */
async function probeVideo(abs) {
  const out = await run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height:stream_side_data=rotation:stream_tags=rotate:format=duration', '-of', 'json', abs], 8000);
  const j = JSON.parse(out);
  const st = (j.streams || [])[0] || {};
  const rot = Math.abs(Number((st.tags && st.tags.rotate) || ((st.side_data_list || []).find((d) => d.rotation !== undefined) || {}).rotation || 0));
  const swap = rot === 90 || rot === 270;
  return {
    width: (swap ? st.height : st.width) || null,
    height: (swap ? st.width : st.height) || null,
    duration: j.format && j.format.duration ? Math.round(Number(j.format.duration)) : null,
  };
}

/**
 * Video poster: one frame (≈1 s in) as the bubble-size WebP next to the file, plus the tiny inline thumb.
 * Returns { width, height, duration, thumb } or null when ffmpeg/sharp are missing or the file is unreadable.
 */
async function videoPoster(abs) {
  if (!sharp || !hasFfmpeg()) return null;
  return queued(async () => {
    const meta = await probeVideo(abs).catch(() => ({}));
    const frame = `${abs}.frame.jpg`;
    const at = meta.duration && meta.duration >= 2 ? '1' : '0';
    try {
      await run('ffmpeg', ['-v', 'error', '-y', '-ss', at, '-i', abs, '-frames:v', '1', '-vf', "scale='min(1280,iw)':-2", '-q:v', '4', frame], 15000);
      const out = previewPathFor(abs, 'p');
      await sharp(frame).webp({ quality: 75, effort: 3 }).toFile(`${out}.tmp`);
      fs.renameSync(`${out}.tmp`, out);
      const buf = await sharp(frame).resize(THUMB_SIDE, THUMB_SIDE, { fit: 'inside' }).jpeg({ quality: 50 }).toBuffer();
      return { ...meta, thumb: buf.toString('base64') };
    } finally {
      fs.unlink(frame, () => {});
    }
  }).catch(() => null);
}

module.exports.videoPoster = videoPoster;
module.exports.hasFfmpeg = hasFfmpeg;
