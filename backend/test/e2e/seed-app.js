/* Seeds a running server for the app e2e test, or verifies what the app did.
 *   node test/e2e/seed-app.js seed     → users, chats, messages, group with poll, channel
 *   node test/e2e/seed-app.js verify   → checks the message the app sent reached the other user
 */
const fs = require('fs');

const BASE = process.env.BASE || 'http://localhost:4000';
const STATE = process.env.SEED_STATE || '/tmp/seed-app.json';

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

async function login(phone, first, last) {
  const r = await call('POST', '/auth/otp/request', { phone });
  const t = await call('POST', '/auth/otp/verify', { phone, code: r.dev_code, device: { name: 'seed' } });
  if (first) await call('PATCH', '/me', { first_name: first, last_name: last || '' }, t.access_token);
  const me = await call('GET', '/me', null, t.access_token);
  return { token: t.access_token, refresh: t.refresh_token, id: me.id };
}

async function loginEmail(email) {
  const r = await call('POST', '/auth/email/request', { email });
  const t = await call('POST', '/auth/email/verify', { email, code: r.dev_code, device: { name: 'seed' } });
  const me = await call('GET', '/me', null, t.access_token);
  return { token: t.access_token, id: me.id };
}

async function seed() {
  // the app logs in with the email code as muhammad@talvio.test; create it now (no profile) so others can message it
  const me = await loginEmail('muhammad@talvio.test');
  const sana = await login('+923005550002', 'Sana', 'Ahmed');
  const ali = await login('+923005550003', 'Ali', 'Raza');

  // the app user knows these people (otherwise their messages would wait in "Message requests")
  await call('POST', `/contacts/${sana.id}`, {}, me.token);
  await call('POST', `/contacts/${ali.id}`, {}, me.token);

  const pc = await call('POST', '/chats/private', { user_id: me.id }, sana.token);
  await call('POST', `/chats/${pc.id}/messages`, { text: 'Hello! How is the app working for you?' }, sana.token);
  await call('POST', `/chats/${pc.id}/messages`, { text: 'Have you seen the new design? 🔥' }, sana.token);

  const pc2 = await call('POST', '/chats/private', { user_id: me.id }, ali.token);
  await call('POST', `/chats/${pc2.id}/messages`, { text: 'Meeting tomorrow at 11 am' }, ali.token);

  const g = (await call('POST', '/chats/group', { title: 'Dev Team', member_ids: [me.id, sana.id] }, ali.token)).chat;
  await call('POST', `/chats/${g.id}/messages`, { text: 'The build passed ✅' }, sana.token);
  await call('POST', `/chats/${g.id}/messages`, { type: 'poll', poll: { question: 'When should we launch?', options: ['Today', 'Tomorrow', 'Next week'] } }, ali.token);

  const ch = await call('POST', '/chats/channel', { title: 'Talvio News', username: 'talvio_news' }, ali.token);
  await call('POST', `/chats/${ch.id}/messages`, { text: 'The first Talvio test build is here 🚀' }, ali.token);
  await call('POST', `/chats/${ch.id}/join`, {}, me.token);

  fs.writeFileSync(STATE, JSON.stringify({ sana, privateChatId: pc.id }));
  console.log('seeded', { me: me.id, sana: sana.id, ali: ali.id, chat: pc.id, group: g.id, channel: ch.id });
}

async function verify() {
  const { sana, privateChatId } = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  // the access token from seeding has expired by now (the emulator run takes longer than its 15 min)
  const fresh = await call('POST', '/auth/refresh', { refresh_token: sana.refresh });
  const r = await call('GET', `/chats/${privateChatId}/messages`, null, fresh.access_token);
  const list = Array.isArray(r) ? r : r.messages || [];
  const got = list.find((m) => m.text === 'Hello from the app ✅');
  if (!got) {
    console.log('FAIL: the message sent from the app did not reach the other user. Last:', list.slice(0, 3).map((m) => m.text));
    process.exit(1);
  }
  console.log('PASS: message from the app reached Sana (id', got.id + ')');
}

(process.argv[2] === 'verify' ? verify() : seed()).catch((e) => {
  console.error(e.message);
  process.exit(1);
});
