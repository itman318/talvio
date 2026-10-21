'use strict';

/**
 * TEST-ONLY minimal PostgreSQL client exposing the subset of the `pg` API this app uses
 * (Pool#query, Pool#connect → client.query/release, types.setTypeParser).
 * Used because the sandbox that built this project had no npm registry access.
 * In production the real `pg` package (node_modules) is used instead.
 */
const net = require('net');
const crypto = require('crypto');

const parsers = new Map();
const types = {
  setTypeParser(oid, fn) {
    parsers.set(oid, fn);
  },
};

function parseValue(oid, text) {
  if (text === null) return null;
  if (parsers.has(oid)) return parsers.get(oid)(text);
  switch (oid) {
    case 16:
      return text === 't';
    case 21:
    case 23:
    case 26:
      return parseInt(text, 10);
    case 700:
    case 701:
      return parseFloat(text);
    case 114:
    case 3802:
      return JSON.parse(text);
    case 1114:
    case 1184:
      return new Date(text.replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00'));
    default:
      return text;
  }
}

function serializeParam(v) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return v.toISOString();
  if (Array.isArray(v)) {
    return `{${v
      .map((x) => (x === null ? 'NULL' : `"${String(x).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`))
      .join(',')}}`;
  }
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function cstr(s) {
  return Buffer.concat([Buffer.from(s, 'utf8'), Buffer.from([0])]);
}

function msg(type, body) {
  const len = Buffer.alloc(4);
  len.writeInt32BE(body.length + 4);
  return Buffer.concat([Buffer.from(type), len, body]);
}

function int16(n) {
  const b = Buffer.alloc(2);
  b.writeInt16BE(n);
  return b;
}

function int32(n) {
  const b = Buffer.alloc(4);
  b.writeInt32BE(n);
  return b;
}

class Connection {
  constructor(opts) {
    this.opts = opts;
    this.buf = Buffer.alloc(0);
    this.queue = [];
    this.current = null;
    this.ready = null;
  }

  connect() {
    if (this.ready) return this.ready;
    this.ready = new Promise((resolve, reject) => {
      this.onReady = resolve;
      this.onFail = reject;
      this.sock = net.connect(this.opts.port, this.opts.host);
      this.sock.on('data', (d) => this.onData(d));
      this.sock.on('error', (e) => this.fail(e));
      this.sock.on('connect', () => {
        const params = Buffer.concat([
          cstr('user'), cstr(this.opts.user), cstr('database'), cstr(this.opts.database), Buffer.from([0]),
        ]);
        const body = Buffer.concat([int32(196608), params]);
        this.sock.write(Buffer.concat([int32(body.length + 4), body]));
      });
    });
    return this.ready;
  }

  fail(e) {
    if (this.onFail) this.onFail(e);
    if (this.current) this.current.reject(e);
  }

  onData(d) {
    this.buf = Buffer.concat([this.buf, d]);
    while (this.buf.length >= 5) {
      const type = String.fromCharCode(this.buf[0]);
      const len = this.buf.readInt32BE(1);
      if (this.buf.length < len + 1) break;
      const body = this.buf.subarray(5, len + 1);
      this.buf = this.buf.subarray(len + 1);
      this.handle(type, body);
    }
  }

  handle(type, body) {
    if (type === 'R') return this.auth(body);
    if (type === 'Z') {
      if (this.onReady) {
        const r = this.onReady;
        this.onReady = null;
        r();
      }
      if (this.current) {
        const c = this.current;
        this.current = null;
        if (c.error) c.reject(c.error);
        else c.resolve(c.result);
      }
      this.next();
      return undefined;
    }
    if (type === 'E') {
      const err = new Error('postgres error');
      let i = 0;
      while (i < body.length && body[i] !== 0) {
        const f = String.fromCharCode(body[i]);
        const end = body.indexOf(0, i + 1);
        const val = body.toString('utf8', i + 1, end);
        if (f === 'M') err.message = val;
        if (f === 'C') err.code = val;
        if (f === 'D') err.detail = val;
        if (f === 'n') err.constraint = val;
        i = end + 1;
      }
      if (this.current) this.current.error = err;
      else this.fail(err);
      return undefined;
    }
    if (!this.current) return undefined;
    const res = this.current.result;
    if (type === 'T') {
      const n = body.readInt16BE(0);
      let o = 2;
      res.fields = [];
      for (let k = 0; k < n; k += 1) {
        const end = body.indexOf(0, o);
        const name = body.toString('utf8', o, end);
        o = end + 1;
        const oid = body.readInt32BE(o + 6);
        o += 18;
        res.fields.push({ name, dataTypeID: oid });
      }
    } else if (type === 'D') {
      const n = body.readInt16BE(0);
      let o = 2;
      const row = {};
      for (let k = 0; k < n; k += 1) {
        const l = body.readInt32BE(o);
        o += 4;
        let text = null;
        if (l >= 0) {
          text = body.toString('utf8', o, o + l);
          o += l;
        }
        const f = res.fields[k];
        row[f.name] = parseValue(f.dataTypeID, text);
      }
      res.rows.push(row);
    } else if (type === 'C') {
      const tag = body.toString('utf8', 0, body.length - 1);
      const m = tag.match(/(\d+)$/);
      res.rowCount = m ? parseInt(m[1], 10) : 0;
      res.command = tag.split(' ')[0];
    }
    return undefined;
  }

  auth(body) {
    const code = body.readInt32BE(0);
    if (code === 0) return;
    if (code === 3) {
      this.sock.write(msg('p', cstr(this.opts.password)));
      return;
    }
    if (code === 10) {
      this.nonce = crypto.randomBytes(18).toString('base64');
      this.clientFirstBare = `n=*,r=${this.nonce}`;
      const first = Buffer.from(`n,,${this.clientFirstBare}`);
      this.sock.write(msg('p', Buffer.concat([cstr('SCRAM-SHA-256'), int32(first.length), first])));
      return;
    }
    if (code === 11) {
      const serverFirst = body.toString('utf8', 4);
      const attrs = Object.fromEntries(serverFirst.split(',').map((p) => [p[0], p.slice(2)]));
      const salted = crypto.pbkdf2Sync(this.opts.password, Buffer.from(attrs.s, 'base64'), parseInt(attrs.i, 10), 32, 'sha256');
      const clientKey = crypto.createHmac('sha256', salted).update('Client Key').digest();
      const storedKey = crypto.createHash('sha256').update(clientKey).digest();
      const finalNoProof = `c=biws,r=${attrs.r}`;
      const authMessage = `${this.clientFirstBare},${serverFirst},${finalNoProof}`;
      const sig = crypto.createHmac('sha256', storedKey).update(authMessage).digest();
      const proof = Buffer.from(clientKey.map((b, i) => b ^ sig[i]));
      this.sock.write(msg('p', Buffer.from(`${finalNoProof},p=${proof.toString('base64')}`)));
      return;
    }
    if (code === 12) return;
    this.fail(new Error(`Unsupported auth method ${code}`));
  }

  query(text, params = []) {
    return this.connect().then(
      () =>
        new Promise((resolve, reject) => {
          this.queue.push({ text, params, resolve, reject });
          if (!this.current) this.next();
        }),
    );
  }

  next() {
    if (this.current || this.queue.length === 0) return;
    const q = this.queue.shift();
    q.result = { rows: [], fields: [], rowCount: 0 };
    this.current = q;
    if (!q.params || q.params.length === 0) {
      // simple query protocol supports multiple statements (used by migrations)
      if (/;\s*\S/.test(q.text.trim().replace(/;\s*$/, ''))) {
        this.sock.write(msg('Q', cstr(q.text)));
        return;
      }
    }
    const values = q.params.map(serializeParam);
    const bindParts = [cstr(''), cstr(''), int16(0), int16(values.length)];
    for (const v of values) {
      if (v === null) bindParts.push(int32(-1));
      else {
        const b = Buffer.from(v, 'utf8');
        bindParts.push(int32(b.length), b);
      }
    }
    bindParts.push(int16(0));
    this.sock.write(
      Buffer.concat([
        msg('P', Buffer.concat([cstr(''), cstr(q.text), int16(0)])),
        msg('B', Buffer.concat(bindParts)),
        msg('D', Buffer.concat([Buffer.from('P'), cstr('')])),
        msg('E', Buffer.concat([cstr(''), int32(0)])),
        msg('S', Buffer.alloc(0)),
      ]),
    );
  }

  end() {
    try {
      this.sock.write(msg('X', Buffer.alloc(0)));
      this.sock.end();
    } catch (_) {
      /* ignore */
    }
  }
}

function parseUrl(url) {
  const u = new URL(url);
  return {
    host: u.hostname,
    port: parseInt(u.port || '5432', 10),
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    database: u.pathname.slice(1),
  };
}

class Pool {
  constructor(opts) {
    this.opts = parseUrl(opts.connectionString);
    this.main = new Connection(this.opts);
    this.all = [this.main];
  }

  on() {}

  query(text, params) {
    return this.main.query(text, params);
  }

  async connect() {
    const c = new Connection(this.opts);
    this.all.push(c);
    await c.connect();
    return {
      query: (t, p) => c.query(t, p),
      release: () => {
        c.end();
        this.all = this.all.filter((x) => x !== c);
      },
    };
  }

  async end() {
    for (const c of this.all) c.end();
  }
}

module.exports = { Pool, types };
