'use strict';

/**
 * Public-key-only BIP-32 for EVM addresses: from an "xpub" (the extended PUBLIC key of
 * m/44'/60'/0'/0) the server can make address number i — but can never spend from it.
 */
const crypto = require('crypto');

const P = 2n ** 256n - 2n ** 32n - 977n;
const N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

const mod = (a, m = P) => ((a % m) + m) % m;
function powmod(b, e, m = P) {
  let r = 1n;
  let x = mod(b, m);
  let k = e;
  while (k > 0n) {
    if (k & 1n) r = (r * x) % m;
    x = (x * x) % m;
    k >>= 1n;
  }
  return r;
}
const inv = (a) => powmod(a, P - 2n);
const big = (buf) => BigInt(`0x${Buffer.from(buf).toString('hex') || '0'}`);
const buf32 = (n) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex');

function add(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (a[0] === b[0] && mod(a[1] + b[1]) === 0n) return null;
  const l = a[0] === b[0] && a[1] === b[1] ? mod(3n * a[0] * a[0] * inv(2n * a[1])) : mod((b[1] - a[1]) * inv(b[0] - a[0]));
  const x = mod(l * l - a[0] - b[0]);
  return [x, mod(l * (a[0] - x) - a[1])];
}

function decompress(b) {
  const x = big(b.subarray(1));
  let y = powmod(mod(x * x * x + 7n), (P + 1n) / 4n);
  if (mod(y * y) !== mod(x * x * x + 7n)) throw new Error('not a point');
  if ((y & 1n) !== BigInt(b[0] & 1)) y = P - y;
  return [x, y];
}
const compress = (pt) => Buffer.concat([Buffer.from([2 + Number(pt[1] & 1n)]), buf32(pt[0])]);

/** k·G, done by OpenSSL. */
function baseMul(k) {
  const e = crypto.createECDH('secp256k1');
  e.setPrivateKey(buf32(k));
  const u = e.getPublicKey(null, 'uncompressed');
  return [big(u.subarray(1, 33)), big(u.subarray(33))];
}

// ------------------------------------------------------------------ keccak-256 (Ethereum's, not SHA3)
const RC = [0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n,
  0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
const ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]];
const M64 = (1n << 64n) - 1n;
const rol = (x, n) => (n ? ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64 : x);

function keccak256(data) {
  const rate = 136;
  const len = data.length + 1;
  const p = Buffer.alloc(Math.ceil(len / rate) * rate);
  Buffer.from(data).copy(p);
  p[data.length] = 1;
  p[p.length - 1] |= 0x80;
  let A = Array.from({ length: 5 }, () => Array(5).fill(0n));
  for (let off = 0; off < p.length; off += rate) {
    for (let i = 0; i < rate / 8; i += 1) A[i % 5][Math.floor(i / 5)] ^= p.readBigUInt64LE(off + i * 8);
    for (const rc of RC) {
      const C = A.map((col) => col[0] ^ col[1] ^ col[2] ^ col[3] ^ col[4]);
      const D = C.map((_, x) => C[(x + 4) % 5] ^ rol(C[(x + 1) % 5], 1));
      A = A.map((col, x) => col.map((v) => v ^ D[x]));
      const B = Array.from({ length: 5 }, () => Array(5).fill(0n));
      for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) B[y][(2 * x + 3 * y) % 5] = rol(A[x][y], ROT[x][y]);
      A = B.map((col, x) => col.map((v, y) => v ^ (~B[(x + 1) % 5][y] & M64 & B[(x + 2) % 5][y])));
      A[0][0] ^= rc;
    }
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i += 1) out.writeBigUInt64LE(A[i % 5][Math.floor(i / 5)], i * 8);
  return out;
}

function checksum(hex40) {
  const a = hex40.toLowerCase();
  const h = keccak256(Buffer.from(a)).toString('hex');
  return `0x${[...a].map((c, i) => (/[a-f]/.test(c) && parseInt(h[i], 16) >= 8 ? c.toUpperCase() : c)).join('')}`;
}

function base58check(s) {
  if (typeof s !== 'string' || !/^[1-9A-HJ-NP-Za-km-z]{100,120}$/.test(s)) return null;
  let n = 0n;
  for (const ch of s) n = n * 58n + BigInt(B58.indexOf(ch));
  let hex = n.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  const b = Buffer.concat([Buffer.alloc(s.match(/^1*/)[0].length), Buffer.from(hex, 'hex')]);
  if (b.length < 5) return null;
  const body = b.subarray(0, -4);
  const sum = crypto.createHash('sha256').update(crypto.createHash('sha256').update(body).digest()).digest().subarray(0, 4);
  return sum.equals(b.subarray(-4)) ? body : null;
}

/** Parses an xpub. Returns { chain, key } or null. */
function parseXpub(xpub) {
  const b = base58check(String(xpub || '').trim());
  if (!b || b.length !== 78 || b.readUInt32BE(0) !== 0x0488b21e) return null;
  const key = b.subarray(45, 78);
  if (key[0] !== 2 && key[0] !== 3) return null;
  try {
    decompress(key);
  } catch (_) {
    return null;
  }
  return { depth: b[4], chain: b.subarray(13, 45), key };
}

/** Address number `index` (non-hardened child) of an xpub, EIP-55 checksummed. */
function addressAt(xpub, index) {
  const x = typeof xpub === 'string' ? parseXpub(xpub) : xpub;
  if (!x) throw new Error('invalid xpub');
  if (!Number.isInteger(index) || index < 0 || index >= 0x80000000) throw new Error('invalid index');
  const data = Buffer.concat([x.key, Buffer.from([(index >>> 24) & 0xff, (index >>> 16) & 0xff, (index >>> 8) & 0xff, index & 0xff])]);
  const I = crypto.createHmac('sha512', x.chain).update(data).digest();
  const il = big(I.subarray(0, 32));
  if (il >= N) throw new Error('invalid child');
  const pt = add(baseMul(il), decompress(x.key));
  if (!pt) throw new Error('invalid child');
  const pub = Buffer.concat([buf32(pt[0]), buf32(pt[1])]);
  return checksum(keccak256(pub).subarray(12).toString('hex'));
}

module.exports = { parseXpub, addressAt, keccak256, checksum, compress };
