/* Web client against a running server, in a real browser (Playwright/Chromium):
 * QR login approved from "the phone" (API) → chat list → send → live message from the other user.
 *   BASE=http://localhost:4000 OUT=../ci-backend node test/e2e/web.e2e.js
 */
const { chromium } = require('playwright');

const BASE = process.env.BASE || 'http://localhost:4000';
const OUT = process.env.OUT || '.';

async function call(method, path, body, token) {
  const res = await fetch(BASE + '/api' + path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${JSON.stringify(data)}`);
  return data;
}

async function login(phone, first) {
  const r = await call('POST', '/auth/otp/request', { phone });
  const t = await call('POST', '/auth/otp/verify', { phone, code: r.dev_code, device: { name: 'web-e2e' } });
  await call('PATCH', '/me', { first_name: first }, t.access_token);
  const me = await call('GET', '/me', null, t.access_token);
  return { token: t.access_token, id: me.id };
}

(async () => {
  const me = await login('+923007770001', 'Web');
  const friend = await login('+923007770002', 'Hina');
  await call('POST', `/contacts/${friend.id}`, {}, me.token);
  const chat = await call('POST', '/chats/private', { user_id: me.id }, friend.token);
  await call('POST', `/chats/${chat.id}/messages`, { text: 'Web pe aa gaye?' }, friend.token);

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  let qrToken;
  page.on('response', async (r) => {
    if (r.url().endsWith('/api/auth/qr') && r.request().method() === 'POST') qrToken = (await r.json().catch(() => ({}))).token;
  });

  await page.goto(BASE + '/web/');
  await page.waitForFunction(() => document.querySelector('.qr-status')?.textContent.includes('Scan'), null, { timeout: 20000 });
  await page.screenshot({ path: `${OUT}/web-1-login.png` });
  if (!qrToken) throw new Error('QR token not captured');
  await call('POST', '/auth/qr/scan', { token: qrToken }, me.token);
  await call('POST', '/auth/qr/approve', { token: qrToken }, me.token);

  await page.waitForSelector('.tile:has-text("Hina")', { timeout: 30000 });
  await page.click('.tile:has-text("Hina")');
  await page.waitForSelector('.bubble:has-text("Web pe aa gaye?")', { timeout: 15000 });
  await page.fill('textarea', 'Haan, web se likh raha hoon');
  await page.keyboard.press('Enter');
  await page.waitForSelector('.row.mine .bubble:has-text("Haan, web se likh raha hoon")', { timeout: 15000 });

  // live delivery over the real Socket.IO connection
  await call('POST', `/chats/${chat.id}/messages`, { text: 'Live message 🔴' }, friend.token);
  await page.waitForSelector('.bubble:has-text("Live message")', { timeout: 15000 });
  // new message types: sticker, contact card, live location, disappearing-messages notice
  const packs = await call('GET', '/stickers/packs', null, friend.token);
  const sticker = packs[0] && packs[0].stickers[0];
  if (!sticker) throw new Error('no official sticker pack');
  await call('POST', `/chats/${chat.id}/messages`, { type: 'sticker', sticker_id: sticker.id }, friend.token);
  await call('POST', `/chats/${chat.id}/messages`, { type: 'contact', contact: { name: 'Ali Raza', phone: '+923001234567' } }, friend.token);
  await call('POST', `/chats/${chat.id}/messages`, { type: 'location', location: { lat: 30.4697, lng: 70.9669, live_minutes: 15 } }, friend.token);
  await call('POST', `/chats/${chat.id}/messages`, { text: 'Fox time \uE901' }, friend.token);
  await call('PUT', `/chats/${chat.id}/disappearing`, { seconds: 86400 }, friend.token);
  await page.waitForSelector('.bubble.bare img.sticker', { timeout: 15000 });
  await page.waitForSelector('.contact:has-text("Ali Raza")', { timeout: 15000 });
  await page.waitForSelector('.bubble img.tali[title="love"]', { timeout: 15000 });
  await page.waitForSelector('.loc:has-text("Live location")', { timeout: 15000 });
  await page.waitForSelector('.sys:has-text("disappearing messages (24 hours)")', { timeout: 15000 });
  await page.waitForFunction(() => { const i = document.querySelector('img.sticker'); return i && i.complete && i.naturalWidth > 0; }, null, { timeout: 15000 });
  await page.screenshot({ path: `${OUT}/web-2-chat.png` });

  // a stranger's message waits in "Message requests"
  const stranger = await login('+923007770003', 'Stranger');
  const sc = await call('POST', '/chats/private', { user_id: me.id }, stranger.token);
  await call('POST', `/chats/${sc.id}/messages`, { text: 'Hello from a stranger' }, stranger.token);
  await page.waitForSelector('.requests-row:has-text("Message requests")', { timeout: 15000 });
  if (await page.$('.tile:has-text("Stranger")')) throw new Error('request shown in the main chat list');
  await page.click('.requests-row');
  await page.click('.tile:has-text("Stranger")');
  await page.waitForSelector('.request-bar button:has-text("Accept")', { timeout: 15000 });
  await page.click('.request-bar button:has-text("Accept")');
  await page.waitForSelector('textarea', { timeout: 15000 });

  const r = await call('GET', `/chats/${chat.id}/messages`, null, friend.token);
  const list = Array.isArray(r) ? r : r.messages || [];
  if (!list.some((m) => m.text === 'Haan, web se likh raha hoon')) throw new Error('message sent from web did not reach the other user');

  // second browser: log in with an email code
  const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const p2 = await ctx2.newPage();
  p2.on('pageerror', (e) => errors.push(e.message));
  await p2.goto(BASE + '/web/');
  await p2.click('.tabs button:has-text("Email")');
  await p2.fill('input[type=email]', 'web.mail@talvio.test');
  await p2.click('button:visible:has-text("Send code")');
  await p2.waitForFunction(() => /code: \d{6}/.test(document.body.innerText), null, { timeout: 15000 });
  const devCode = (await p2.evaluate(() => document.body.innerText.match(/code: (\d{6})/)[1]));
  await p2.fill('input[inputmode=numeric]:visible', devCode);
  await p2.click('button:visible:has-text("Log in")');
  await p2.waitForSelector('input[placeholder="First name"]', { timeout: 15000 });
  await p2.fill('input[placeholder="First name"]', 'Mail');
  await p2.click('button:has-text("Continue")');
  await p2.waitForSelector('.chat-list', { timeout: 15000 });
  await p2.screenshot({ path: `${OUT}/web-3-email-login.png` });

  const usingSocket = await page.evaluate(() => !!(window.io && document.querySelector('script[src*="socket.io"]')));
  await browser.close();
  const bad = errors.filter((e) => !/favicon|ERR_ABORTED/.test(e));
  console.log(`PASS web client: QR login, open chat, send, live receive (socket.io: ${usingSocket}), sticker/contact/live location/disappearing, message requests, email-code login + profile`);
  if (bad.length) {
    console.log('Browser errors:\n' + bad.join('\n'));
    process.exit(1);
  }
})().catch((e) => {
  console.log('FAIL web client:', e.message);
  process.exit(1);
});
