'use strict';

/** Link previews: parsing and the SSRF guard (no network needed). */
const test = require('node:test');
const assert = require('node:assert/strict');
const link = require('../src/services/link.service');

test('first link in a message', () => {
  assert.equal(link.firstUrl('dekho https://talvio.app/download, mast hai!'), 'https://talvio.app/download');
  assert.equal(link.firstUrl('no link here'), null);
});

test('Open Graph and <title> parsing', () => {
  const html = `<html><head><title>Fallback title</title>
    <meta property="og:title" content="Talvio &amp; friends">
    <meta name="description" content="Fast chats">
    <meta property="og:image" content="/img/cover.jpg"><meta property="og:site_name" content="Talvio"></head></html>`;
  const p = link.parse('https://talvio.app/x', html);
  assert.equal(p.title, 'Talvio & friends');
  assert.equal(p.description, 'Fast chats');
  assert.equal(p.image, 'https://talvio.app/img/cover.jpg');
  assert.equal(p.site, 'Talvio');
  assert.equal(link.parse('http://plain.example/', '<html><title>Only title</title></html>').image, null);
  assert.equal(link.parse('https://e.example/', '<html></html>'), null);
});

test('private and internal addresses are refused', async () => {
  for (const ip of ['127.0.0.1', '10.1.2.3', '192.168.1.1', '172.20.0.1', '169.254.169.254', '100.64.0.1', '::1', 'fd00::1', '::ffff:127.0.0.1']) {
    assert.equal(link.isPrivateIp(ip), true, ip);
  }
  assert.equal(link.isPrivateIp('8.8.8.8'), false);
  for (const u of ['http://127.0.0.1/', 'http://localhost/', 'http://[::1]/', 'https://169.254.169.254/latest/meta-data', 'ftp://example.com/', 'http://example.com:8080/', 'http://user:pw@example.com/']) {
    await assert.rejects(link.safeAddress(new URL(u)), u);
  }
});
