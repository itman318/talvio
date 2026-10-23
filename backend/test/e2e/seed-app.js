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
  return { token: t.access_token, id: me.id };
}

async function seed() {
  // the app logs in as +923005550001; create it now (no profile) so others can message it
  const me = await login('+923005550001');
  const sana = await login('+923005550002', 'Sana', 'Ahmed');
  const ali = await login('+923005550003', 'Ali', 'Raza');

  const pc = await call('POST', '/chats/private', { user_id: me.id }, sana.token);
  await call('POST', `/chats/${pc.id}/messages`, { text: 'Assalam o alaikum! App kaisi chal rahi hai?' }, sana.token);
  await call('POST', `/chats/${pc.id}/messages`, { text: 'Naya design dekha? 🔥' }, sana.token);

  const pc2 = await call('POST', '/chats/private', { user_id: me.id }, ali.token);
  await call('POST', `/chats/${pc2.id}/messages`, { text: 'Kal meeting 11 baje hai' }, ali.token);

  const g = (await call('POST', '/chats/group', { title: 'Dev Team', member_ids: [me.id, sana.id] }, ali.token)).chat;
  await call('POST', `/chats/${g.id}/messages`, { text: 'Build pass ho gaya ✅' }, sana.token);
  await call('POST', `/chats/${g.id}/messages`, { type: 'poll', poll: { question: 'Launch kab karein?', options: ['Aaj', 'Kal', 'Agle hafte'] } }, ali.token);

  const ch = await call('POST', '/chats/channel', { title: 'Talvio News', username: 'talvio_news' }, ali.token);
  await call('POST', `/chats/${ch.id}/messages`, { text: 'Talvio ka pehla test build aa gaya 🚀' }, ali.token);
  await call('POST', `/chats/${ch.id}/join`, {}, me.token);

  fs.writeFileSync(STATE, JSON.stringify({ sana, privateChatId: pc.id }));
  console.log('seeded', { me: me.id, sana: sana.id, ali: ali.id, chat: pc.id, group: g.id, channel: ch.id });
}

async function verify() {
  const { sana, privateChatId } = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  const r = await call('GET', `/chats/${privateChatId}/messages`, null, sana.token);
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
