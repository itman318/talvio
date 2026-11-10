'use strict';

/** Security guards that need no database: outgoing requests and the client address. */
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { safeFetch, isPrivateIp } = require('../src/utils/safeFetch');

test('outgoing requests: private, loopback and metadata addresses are refused', async () => {
  for (const ip of ['127.0.0.1', '10.1.2.3', '172.16.0.9', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', 'fd00::1', 'fe80::1', '::ffff:127.0.0.1', '::ffff:7f00:1', '224.0.0.1']) {
    assert.equal(isPrivateIp(ip), true, ip);
  }
  for (const ip of ['8.8.8.8', '37.27.154.66', '1.1.1.1', '2606:4700:4700::1111']) assert.equal(isPrivateIp(ip), false, ip);

  const srv = http.createServer((req, res) => (req.url === '/hop' ? res.writeHead(302, { location: 'http://127.0.0.1:1/' }).end() : res.end('secret'))).listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  const base = `http://127.0.0.1:${srv.address().port}`;
  try {
    assert.equal((await safeFetch(`${base}/x`)).body.toString(), 'secret', 'tests may talk to a local server');
    process.env.SAFE_FETCH_STRICT = 'true'; // what production does
    await assert.rejects(safeFetch(`${base}/x`), /not allowed/);
    await assert.rejects(safeFetch('http://localhost:5432/'), /not allowed/);
    await assert.rejects(safeFetch('http://[::1]/'), /not allowed/);
    await assert.rejects(safeFetch('http://2130706433/'), /not allowed/); // 127.0.0.1 written as one number
    await assert.rejects(safeFetch('file:///etc/passwd'), /only http/);
    await assert.rejects(safeFetch('http://user:pw@example.com/'), /credentials/);
    delete process.env.SAFE_FETCH_STRICT;
    await assert.rejects(safeFetch(`${base}/big`, { maxBytes: 3 }), /too big/);
  } finally {
    delete process.env.SAFE_FETCH_STRICT;
    srv.close();
  }
});

test('client address: a forged X-Forwarded-For does not change who we think is calling', async () => {
  const config = require('../src/config');
  const before = config.trustProxy;
  config.trustProxy = true;
  const express = require('express');
  const app = express();
  app.set('trust proxy', config.trustProxy ? 1 : false);
  app.get('/ip', (req, res) => res.json({ ip: req.ip }));
  const srv = app.listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  try {
    // nginx appends the real address at the END; whatever the client wrote before it is ignored
    const r = await fetch(`http://127.0.0.1:${srv.address().port}/ip`, { headers: { 'X-Forwarded-For': '1.2.3.4, 203.0.113.9' } });
    assert.equal((await r.json()).ip, '203.0.113.9');
    assert.match(require('fs').readFileSync(require('path').join(__dirname, '../src/app.js'), 'utf8'), /trust proxy', config\.trustProxy \? 1 : false/);
  } finally {
    config.trustProxy = before;
    srv.close();
  }
});
