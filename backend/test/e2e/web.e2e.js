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
  await page.screenshot({ path: `${OUT}/web-2-chat.png` });

  const r = await call('GET', `/chats/${chat.id}/messages`, null, friend.token);
  const list = Array.isArray(r) ? r : r.messages || [];
  if (!list.some((m) => m.text === 'Haan, web se likh raha hoon')) throw new Error('message sent from web did not reach the other user');

  const usingSocket = await page.evaluate(() => !!(window.io && document.querySelector('script[src*="socket.io"]')));
  await browser.close();
  const bad = errors.filter((e) => !/favicon|ERR_ABORTED/.test(e));
  console.log(`PASS web client: QR login, open chat, send, live receive (socket.io client loaded: ${usingSocket})`);
  if (bad.length) {
    console.log('Browser errors:\n' + bad.join('\n'));
    process.exit(1);
  }
})().catch((e) => {
  console.log('FAIL web client:', e.message);
  process.exit(1);
});
