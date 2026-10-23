'use strict';

/**
 * Link previews: the server fetches the first link in a message (title, description, image, site)
 * and attaches it to the message. Safe by design — only http(s) on ports 80/443, public IP addresses
 * only (no localhost / private networks / cloud metadata), 5 s timeout, at most 512 KB read,
 * results cached for 7 days.
 */
const crypto = require('crypto');
const dns = require('dns').promises;
const net = require('net');
const http = require('http');
const https = require('https');
const db = require('../db');
const settings = require('./settings.service');

const URL_RE = /\bhttps?:\/\/[^\s<>"'`]+/i;
const MAX_BYTES = 512 * 1024;
const TIMEOUT_MS = 5000;

function firstUrl(text) {
  const m = URL_RE.exec(String(text || ''));
  if (!m) return null;
  return m[0].replace(/[),.!?:;]+$/, '');
}

function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  const v = ip.toLowerCase();
  if (v.startsWith('::ffff:')) return isPrivateIp(v.slice(7));
  return v === '::1' || v === '::' || v.startsWith('fc') || v.startsWith('fd') || v.startsWith('fe80');
}

/** Resolves the host and refuses non-public addresses. Returns the IP to connect to. */
async function safeAddress(u) {
  if (!['http:', 'https:'].includes(u.protocol)) throw new Error('scheme');
  if (u.port && !['80', '443'].includes(u.port)) throw new Error('port');
  if (u.username || u.password) throw new Error('credentials');
  const host = u.hostname.replace(/^\[|\]$/g, '');
  const addrs = net.isIP(host) ? [{ address: host }] : await dns.lookup(host, { all: true, verbatim: true });
  if (!addrs.length || addrs.some((a) => isPrivateIp(a.address))) throw new Error('private address');
  return addrs[0].address;
}

/** GET with redirects (max 3), pinned to the checked IP, reading at most MAX_BYTES. */
async function fetchHtml(rawUrl, depth = 0) {
  const u = new URL(rawUrl);
  const ip = await safeAddress(u);
  const lib = u.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const req = lib.get({
      host: ip, servername: u.hostname, path: `${u.pathname}${u.search}`, port: u.port || (u.protocol === 'https:' ? 443 : 80),
      headers: { host: u.host, 'user-agent': 'TalvioBot/1.0 (link preview)', accept: 'text/html,application/xhtml+xml', 'accept-language': 'en,ur;q=0.8' },
      timeout: TIMEOUT_MS,
    }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && depth < 3) {
        res.resume();
        resolve(fetchHtml(new URL(res.headers.location, u).toString(), depth + 1));
        return;
      }
      const type = String(res.headers['content-type'] || '');
      if (res.statusCode !== 200) { res.resume(); reject(new Error(`status ${res.statusCode}`)); return; }
      if (/^image\//.test(type)) { res.resume(); resolve({ url: u.toString(), image: true }); return; }
      if (!/html/.test(type)) { res.resume(); reject(new Error('not html')); return; }
      let size = 0;
      const chunks = [];
      res.on('data', (c) => {
        size += c.length;
        if (size > MAX_BYTES) { res.destroy(); return; }
        chunks.push(c);
      });
      res.on('close', () => resolve({ url: u.toString(), html: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

function decode(s) {
  return String(s || '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).replace(/\s+/g, ' ').trim();
}

function meta(html, names) {
  for (const n of names) {
    const re = new RegExp(`<meta[^>]+(?:property|name)=["']${n}["'][^>]*>`, 'i');
    const tag = re.exec(html);
    if (tag) {
      const c = /content=["']([^"']*)["']/i.exec(tag[0]);
      if (c && c[1].trim()) return decode(c[1]);
    }
  }
  return null;
}

function parse(pageUrl, html) {
  const title = meta(html, ['og:title', 'twitter:title']) || decode((/<title[^>]*>([^<]{1,300})<\/title>/i.exec(html) || [])[1]);
  const description = meta(html, ['og:description', 'twitter:description', 'description']);
  let image = meta(html, ['og:image', 'og:image:url', 'twitter:image']);
  if (image) {
    try {
      image = new URL(image, pageUrl).toString();
      if (!/^https:\/\//.test(image)) image = null;
    } catch (_) {
      image = null;
    }
  }
  const site = meta(html, ['og:site_name']) || new URL(pageUrl).hostname.replace(/^www\./, '');
  if (!title && !description) return null;
  return {
    url: pageUrl,
    site: site.slice(0, 80),
    title: title ? title.slice(0, 200) : null,
    description: description ? description.slice(0, 300) : null,
    image,
  };
}

async function previewFor(rawUrl) {
  const hash = crypto.createHash('sha256').update(rawUrl).digest('hex');
  const cached = await db.one(`SELECT data FROM link_previews WHERE url_hash = $1 AND fetched_at > now() - interval '7 days'`, [hash]);
  if (cached) return cached.data;
  let data = null;
  try {
    const r = await fetchHtml(rawUrl);
    data = r.image ? { url: r.url, site: new URL(r.url).hostname, title: null, description: null, image: r.url } : parse(r.url, r.html || '');
  } catch (_) {
    data = null;
  }
  await db.query(
    `INSERT INTO link_previews (url_hash, url, data) VALUES ($1, $2, $3)
     ON CONFLICT (url_hash) DO UPDATE SET data = EXCLUDED.data, fetched_at = now()`,
    [hash, rawUrl.slice(0, 2000), data ? JSON.stringify(data) : null],
  );
  return data;
}

/** After a text message is sent: attach a preview of its first link (runs in the background). */
async function enrichMessage(messageId, text, onDone) {
  try {
    if (!(await settings.get('feature_link_previews'))) return;
    const url = firstUrl(text);
    if (!url) return;
    const data = await previewFor(url);
    if (!data) return;
    const r = await db.one('UPDATE messages SET link_preview = $2 WHERE id = $1 AND deleted_at IS NULL RETURNING id', [messageId, JSON.stringify(data)]);
    if (r && onDone) await onDone();
  } catch (_) {
    // previews are best-effort
  }
}

module.exports = { firstUrl, isPrivateIp, parse, previewFor, enrichMessage, safeAddress };
