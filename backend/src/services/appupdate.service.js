'use strict';

/**
 * In-app updates: the newest Android build comes from the project's GitHub release
 * ("android-latest", published by CI). The app asks the server — not GitHub — so it
 * works the same for everyone and GitHub's rate limits never reach the phones.
 */

const settings = require('./settings.service');

const REPO = process.env.APP_RELEASE_REPO || 'itman318/talvio';
const TAG = process.env.APP_RELEASE_TAG || 'android-latest';
const TTL_MS = 10 * 60 * 1000;

let cache = { at: 0, data: null };

/** Turns a GitHub release into { build, version, published_at, assets: { name: { url, size, sha256 } } }. */
function parseRelease(r) {
  const m = /#(\d+)/.exec(r.name || '') || /Hushavia \d+\.\d+\.(\d+)/.exec(r.body || '');
  if (!m) return null;
  const build = Number(m[1]);
  const assets = {};
  for (const a of r.assets || []) {
    if (!/\.apk$/.test(a.name)) continue;
    const sha = typeof a.digest === 'string' && a.digest.startsWith('sha256:') ? a.digest.slice(7) : null;
    assets[a.name] = { url: a.browser_download_url, size: a.size, sha256: sha };
  }
  return { build, version: `1.1.${build}`, published_at: r.published_at || r.created_at || null, assets };
}

async function latest() {
  if (cache.data && Date.now() - cache.at < TTL_MS) return cache.data;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/tags/${TAG}`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'hushavia-server' },
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`github ${res.status}`);
    const data = parseRelease(await res.json());
    if (data) cache = { at: Date.now(), data };
  } catch (_) {
    cache.at = Date.now() - TTL_MS + 60 * 1000; // GitHub down: try again in a minute, keep the last answer
  }
  return cache.data;
}

const ABI_FILES = { 'armeabi-v7a': 'hushavia-arm32.apk', x86_64: 'hushavia-x86_64-emulator.apk' };

function olderThan(a, b) {
  const pa = String(a || '0').split('.').map((x) => parseInt(x, 10) || 0);
  const pb = String(b || '0').split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0);
  }
  return false;
}

/** What the phone (build N, CPU type abi) should do. */
async function check({ build, abi } = {}) {
  const current = Math.max(0, parseInt(build, 10) || 0);
  const l = await latest();
  const notes = String((await settings.get('app_update_notes')) || '');
  const minVersion = await settings.get('min_app_version');
  const force = olderThan(`1.1.${current}`, minVersion);
  if (!l || !current) return { update: false, force, current_build: current };
  const asset = l.assets[ABI_FILES[abi] || 'hushavia.apk'] || l.assets['hushavia.apk'];
  if (!asset || l.build <= current) return { update: false, force, current_build: current, latest_build: l.build };
  return {
    update: true,
    force,
    current_build: current,
    latest_build: l.build,
    version: l.version,
    url: asset.url,
    size: asset.size,
    sha256: asset.sha256,
    notes,
    published_at: l.published_at,
  };
}

/** Tests: pretend this is what GitHub said. */
function _setRelease(release) {
  cache = { at: Date.now(), data: release ? parseRelease(release) : null };
}

module.exports = { check, latest, parseRelease, _setRelease };
