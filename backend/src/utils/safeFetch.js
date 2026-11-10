'use strict';

/**
 * HTTP requests to addresses that OUTSIDERS choose (bot webhooks, files a bot sends by URL).
 * Without care such a request can be pointed at the server itself or its private network
 * ("SSRF"): the database port, the admin API on localhost, the cloud provider's metadata address.
 *
 *  - every host name is resolved here and refused when ANY of its addresses is private;
 *  - the connection is made to exactly the address that was checked (no second DNS answer);
 *  - redirects are followed by hand, each hop checked again;
 *  - the answer is read up to a byte limit, never whole into memory.
 */
const dns = require('dns');
const http = require('http');
const https = require('https');
const net = require('net');
const config = require('../config');

function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const [a, b, c] = ip.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || (a === 192 && b === 0 && c === 0)
      || (a === 198 && (b === 18 || b === 19)) || a >= 224;
  }
  const v = String(ip).toLowerCase();
  if (v.startsWith('::ffff:')) {
    const tail = v.slice(7);
    if (net.isIPv4(tail)) return isPrivateIp(tail);
    return true; // hex form of a mapped IPv4 address: never needed for a public site
  }
  return v === '::1' || v === '::' || v.startsWith('fc') || v.startsWith('fd') || v.startsWith('fe8') || v.startsWith('fe9')
    || v.startsWith('fea') || v.startsWith('feb') || v.startsWith('64:ff9b:') || v.startsWith('2002:') || !net.isIPv6(v);
}

/** Private addresses are allowed only outside production (tests talk to a local server). */
const allowPrivate = () => !config.isProd && process.env.SAFE_FETCH_STRICT !== 'true';

async function resolvePublic(hostname) {
  const host = String(hostname).replace(/^\[|\]$/g, '');
  const addrs = net.isIP(host) ? [{ address: host, family: net.isIPv6(host) ? 6 : 4 }] : await dns.promises.lookup(host, { all: true, verbatim: true });
  if (!addrs.length) throw new Error('host not found');
  if (!allowPrivate() && addrs.some((a) => isPrivateIp(a.address))) throw new Error('address not allowed');
  return addrs[0];
}

/**
 * @returns {Promise<{status:number, headers:object, body:Buffer, url:string}>}
 * opts: method, headers, body (string|Buffer), timeoutMs, maxBytes, redirects (how many to follow), httpsOnly
 */
async function safeFetch(rawUrl, opts = {}, depth = 0) {
  const u = new URL(String(rawUrl));
  if (!['http:', 'https:'].includes(u.protocol)) throw new Error('only http(s) addresses');
  if (opts.httpsOnly && u.protocol !== 'https:' && !allowPrivate()) throw new Error('only https addresses');
  if (u.username || u.password) throw new Error('credentials in the address are not allowed');
  const addr = await resolvePublic(u.hostname);
  const lib = u.protocol === 'https:' ? https : http;
  const maxBytes = opts.maxBytes || 1024 * 1024;
  const timeoutMs = opts.timeoutMs || 10000;
  const body = opts.body === undefined || opts.body === null ? null : Buffer.from(opts.body);
  return new Promise((resolve, reject) => {
    let done = false;
    const finish = (fn, x) => {
      if (done) return;
      done = true;
      clearTimeout(timer); // eslint-disable-line no-use-before-define
      fn(x);
    };
    const req = lib.request({
      method: opts.method || 'GET',
      host: addr.address,
      family: addr.family,
      servername: net.isIP(u.hostname.replace(/^\[|\]$/g, '')) ? undefined : u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: `${u.pathname}${u.search}`,
      headers: { host: u.host, 'user-agent': 'HushaviaBot/1.0', ...(opts.headers || {}), ...(body ? { 'content-length': body.length } : {}) },
    }, (res) => {
      const follow = opts.redirects || 0;
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && depth < follow) {
        res.resume();
        let next;
        try {
          next = new URL(res.headers.location, u).toString();
        } catch (e) {
          finish(reject, new Error('bad redirect'));
          return;
        }
        finish(resolve, safeFetch(next, { ...opts, method: 'GET', body: undefined }, depth + 1));
        return;
      }
      if (Number(res.headers['content-length'] || 0) > maxBytes) {
        res.destroy();
        finish(reject, Object.assign(new Error('too big'), { code: 'too_big' }));
        return;
      }
      let size = 0;
      const chunks = [];
      res.on('data', (c) => {
        size += c.length;
        if (size > maxBytes) {
          res.destroy();
          finish(reject, Object.assign(new Error('too big'), { code: 'too_big' }));
          return;
        }
        chunks.push(c);
      });
      res.on('end', () => finish(resolve, { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks), url: u.toString() }));
      res.on('error', (e) => finish(reject, e));
    });
    const timer = setTimeout(() => {
      req.destroy();
      finish(reject, new Error('timeout'));
    }, timeoutMs);
    req.on('error', (e) => finish(reject, e));
    if (body) req.write(body);
    req.end();
  });
}

module.exports = { safeFetch, isPrivateIp, resolvePublic };
