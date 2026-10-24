/* Builds the offline demo for the app ("Try demo" on the login screen).
 * Seeds a realistic world on a running dev server, then records what the demo user's app would
 * receive from the API, plus the bytes of every photo/sticker it shows.
 *   BASE=http://localhost:4000 OUT=../mobile/assets/demo/demo.json node test/e2e/demo-record.js
 * The app replays this file when there is no server (no internet needed).
 */
const fs = require('fs');
const path = require('path');

const BASE = process.env.BASE || 'http://localhost:4000';
const OUT = process.env.OUT || path.join(__dirname, '../../../mobile/assets/demo/demo.json');
const ASSETS = path.join(__dirname, 'demo-assets');

async function call(method, p, body, token) {
  const res = await fetch(BASE + '/api' + p, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`${method} ${p} → ${res.status} ${JSON.stringify(data)}`);
  return data;
}

async function upload(file, kind, token) {
  const fd = new FormData();
  fd.append('kind', kind);
  fd.append('file', new Blob([fs.readFileSync(file)], { type: file.endsWith('.png') ? 'image/png' : 'image/jpeg' }), path.basename(file));
  const res = await fetch(BASE + '/api/media', { method: 'POST', headers: { authorization: `Bearer ${token}` }, body: fd });
  const data = await res.json();
  if (!res.ok) throw new Error(`upload → ${res.status} ${JSON.stringify(data)}`);
  return data;
}

async function phoneUser(phone, first, last) {
  const r = await call('POST', '/auth/otp/request', { phone });
  const t = await call('POST', '/auth/otp/verify', { phone, code: r.dev_code, device: { name: 'demo' } });
  await call('PATCH', '/me', { first_name: first, last_name: last || '', bio: '' }, t.access_token);
  const me = await call('GET', '/me', null, t.access_token);
  return { token: t.access_token, id: me.id };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const say = (chatId, who, text, extra = {}) => call('POST', `/chats/${chatId}/messages`, { text, ...extra }, who.token);
const optional = async (label, fn) => {
  try {
    return await fn();
  } catch (e) {
    console.log(`  (skipped ${label}: ${e.message})`);
    return null;
  }
};

async function main() {
  // ---------------------------------------------------------------- people
  const er = await call('POST', '/auth/email/request', { email: 'demo@talvio.app' });
  const et = await call('POST', '/auth/email/verify', { email: 'demo@talvio.app', code: er.dev_code, device: { name: 'Demo phone' } });
  const me = { token: et.access_token };
  await call('PATCH', '/me', { first_name: 'Sam', last_name: 'Carter', bio: 'Building Talvio 🚀' }, me.token);
  await optional('username', () => call('PATCH', '/me', { username: 'sam_demo' }, me.token));
  me.id = (await call('GET', '/me', null, me.token)).id;

  const ayesha = await phoneUser('+447700900001', 'Sarah', 'Miller');
  const bilal = await phoneUser('+447700900002', 'Omar', 'Hassan');
  const sana = await phoneUser('+447700900003', 'Lina', 'Chen');
  const ali = await phoneUser('+447700900004', 'David', 'Brown');
  const ammi = await phoneUser('+447700900005', 'Mom', '');
  const usman = await phoneUser('+447700900006', 'Alex', 'Turner');

  // the demo user's contacts — Alex is not one, so his chat shows up as a message request
  for (const p of [ayesha, bilal, sana, ali, ammi]) await call('POST', `/contacts/${p.id}`, {}, me.token);

  // ---------------------------------------------------------------- my notes
  const saved = await optional('notes', () => call('POST', '/chats/private', { user_id: me.id }, me.token));
  if (saved) {
    await say(saved.id, me, 'To do: book the server ✅');
    await say(saved.id, me, 'Ideas: new wallpapers, more sticker packs, widgets');
  }

  // ---------------------------------------------------------------- private chats
  const a = await call('POST', '/chats/private', { user_id: me.id }, ayesha.token);
  await say(a.id, ayesha, 'Hey Sam! 👋');
  await say(a.id, me, 'Hi Sarah! How are you?');
  await say(a.id, ayesha, 'Great, thanks! The new Talvio design looks amazing 😍');
  const lake = await upload(path.join(ASSETS, 'lake.jpg'), 'image', ayesha.token);
  await call('POST', `/chats/${a.id}/messages`, { type: 'image', media_id: lake.id, text: 'From our mountain trip 🏔️' }, ayesha.token);
  await say(a.id, me, 'Wow, what a view 😮');
  await say(a.id, ayesha, 'Next time we all go together!');

  const b = await call('POST', '/chats/private', { user_id: me.id }, bilal.token);
  await say(b.id, bilal, 'Meeting tomorrow at 11, remember?');
  await say(b.id, me, 'Yes, I will be there on time');
  await call('POST', `/chats/${b.id}/messages`, { type: 'location', location: { lat: 25.0805, lng: 55.1403, title: 'Office' } }, bilal.token);
  await say(b.id, bilal, 'Here is the office location 📍');
  await call('POST', `/chats/${b.id}/messages`, { type: 'contact', contact: { name: 'Alex Turner', phone: '+447700900006' } }, bilal.token);
  await say(b.id, bilal, 'This is Alex, the designer I told you about 👍');

  const s = await call('POST', '/chats/private', { user_id: me.id }, sana.token);
  await say(s.id, sana, 'Got the Talvio app, installed it ✅');
  const packs = await optional('stickers', () => call('GET', '/stickers/packs', null, sana.token));
  const st = packs && packs[0] && packs[0].stickers;
  if (st && st.length) await call('POST', `/chats/${s.id}/messages`, { type: 'sticker', sticker_id: st[0].id }, sana.token);
  await say(s.id, me, 'Thanks! Let me know if anything breaks');
  await say(s.id, sana, 'The stickers are so cute 😄');
  if (st && st.length > 3) await call('POST', `/chats/${s.id}/messages`, { type: 'sticker', sticker_id: st[3].id }, me.token);

  const am = await call('POST', '/chats/private', { user_id: me.id }, ammi.token);
  await say(am.id, ammi, 'Did you have lunch?');
  await say(am.id, me, 'Yes Mom, I did ❤️');
  await say(am.id, ammi, 'Come home early, I am making tea ☕');

  const u = await call('POST', '/chats/private', { user_id: me.id }, usman.token);
  await say(u.id, usman, 'Hi! Omar gave me your number');
  await say(u.id, usman, 'I can design the app icons for you 🎨');

  // ---------------------------------------------------------------- groups
  const fam = (await call('POST', '/chats/group', { title: 'Family ❤️', member_ids: [me.id, ammi.id, ayesha.id] }, ammi.token)).chat;
  await say(fam.id, ammi, 'Everyone come over on Sunday');
  await say(fam.id, ayesha, 'Sure Mom, I will be there');
  await call('POST', `/chats/${fam.id}/messages`, { type: 'poll', poll: { question: 'What should we cook on Sunday?', options: ['Pasta 🍝', 'Curry 🍛', 'BBQ 🍢'] } }, ayesha.token);
  const sunset = await upload(path.join(ASSETS, 'sunset.jpg'), 'image', ammi.token);
  await call('POST', `/chats/${fam.id}/messages`, { type: 'image', media_id: sunset.id, text: 'Sunset today 🌅' }, ammi.token);

  const dev = (await call('POST', '/chats/group', { title: 'Talvio Dev Team', member_ids: [me.id, bilal.id, sana.id, ali.id, usman.id] }, me.token)).chat;
  await say(dev.id, ali, 'Android build passed ✅');
  await say(dev.id, sana, 'Tested the web version too, all good');
  await call('POST', `/chats/${dev.id}/messages`, { type: 'poll', poll: { question: 'When should we launch?', options: ['This week', 'Next week', 'Next month'] } }, me.token);
  await say(dev.id, bilal, 'Let us go live once the server is ready 🚀');
  await say(dev.id, usman, 'I will make the Play Store screenshots');

  // ---------------------------------------------------------------- channel
  const ch = await call('POST', '/chats/channel', { title: 'Talvio News', username: 'talvio_news', description: 'Talvio updates and new features' }, ali.token);
  await say(ch.id, ali, 'Welcome to Talvio! 🎉 New features are announced here.');
  await say(ch.id, ali, 'New: stickers, GIFs, disappearing messages and live location 📍');
  await say(ch.id, ali, 'New: prayer times, Qibla direction and Ramadan reminders 🕌');
  await call('POST', `/chats/${ch.id}/join`, {}, me.token);

  // ---------------------------------------------------------------- extras
  await optional('reaction', async () => {
    const r = await call('GET', `/chats/${a.id}/messages`, null, me.token);
    const m = (r.messages || []).find((x) => x.type === 'image');
    if (m) await call('PUT', `/messages/${m.id}/reaction`, { emoji: '❤️' }, me.token);
  });
  await optional('vote', async () => {
    const r = await call('GET', `/chats/${fam.id}/messages`, null, ayesha.token);
    const p = (r.messages || []).find((x) => x.type === 'poll');
    if (p) await call('POST', `/messages/${p.id}/vote`, { options: [0] }, ammi.token);
  });
  await optional('story', async () => {
    const m = await upload(path.join(ASSETS, 'sunset.jpg'), 'image', ayesha.token);
    await call('POST', '/stories', { media_id: m.id, caption: 'Golden hour ✨', privacy: 'everyone' }, ayesha.token);
  });
  await optional('folder', () => call('POST', '/folders', { name: 'Work', chat_ids: [dev.id, b.id, u.id] }, me.token));
  await optional('ticket', () => call('POST', '/support/tickets', { subject: 'App feedback', category: 'other', message: 'Great work, thank you!' }, me.token));
  await optional('calls', async () => {
    const { io } = require('socket.io-client');
    const sock = io(BASE, { transports: ['websocket'], auth: { token: bilal.token } });
    await new Promise((res, rej) => { sock.on('connect', res); sock.on('connect_error', rej); });
    const ask = (ev, d) => new Promise((res) => sock.emit(ev, d, res));
    const r = await ask('call:start', { user_id: me.id, video: false });
    await sleep(1500);
    if (r && r.call) await ask('call:hangup', { call_id: r.call.id, reason: 'cancel' });
    sock.close();
  });
  // read some chats so the list has a mix of read and unread
  for (const c of [s, am]) {
    await optional('read', async () => {
      const r = await call('GET', `/chats/${c.id}/messages`, null, me.token);
      const top = (r.messages || [])[0];
      if (top) await call('POST', `/chats/${c.id}/read`, { message_id: top.id }, me.token);
    });
  }

  // ---------------------------------------------------------------- record
  const responses = {};
  const rec = async (p) => {
    const v = await optional(`GET ${p}`, () => call('GET', p, null, me.token));
    if (v !== null) responses[p] = v;
    return v;
  };
  for (const p of ['/me', '/app-config', '/chats', '/folders', '/contacts', '/calls', '/stories', '/premium', '/announcements',
    '/me/sessions', '/blocks', '/bots', '/stickers/packs', '/secret-chats', '/secret-chats/pending', '/support/tickets',
    '/payments/orders', '/pages/privacy', '/pages/terms', '/calls/active']) {
    await rec(p);
  }
  const messages = {};
  const chats = responses['/chats'] || [];
  for (const c of chats) {
    await rec(`/chats/${c.id}`);
    const m = await optional('messages', () => call('GET', `/chats/${c.id}/messages?limit=100`, null, me.token));
    if (m) messages[c.id] = m.messages || [];
    if (c.type !== 'private') {
      await rec(`/chats/${c.id}/members`);
      await rec(`/chats/${c.id}/pins`);
    }
    if (c.peer) await rec(`/users/${c.peer.id}`);
  }
  for (const t of (responses['/support/tickets'] || [])) await rec(`/support/tickets/${t.id}`);

  // bytes of every protected file the demo shows (photos, stickers, story)
  const media = {};
  const urls = new Set();
  JSON.stringify({ responses, messages }).replace(/"(\/api\/media\/\d+[^"]*)"/g, (_, u) => urls.add(u));
  for (const url of urls) {
    const res = await fetch(BASE + url, { headers: { authorization: `Bearer ${me.token}` } });
    if (res.ok) media[url] = Buffer.from(await res.arrayBuffer()).toString('base64');
  }

  const out = { recorded_at: new Date().toISOString(), me_id: me.id, responses, messages, media };
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(out));
  console.log(`demo recorded: ${chats.length} chats, ${Object.keys(responses).length} responses, ${urls.size} files, ${(fs.statSync(OUT).size / 1024).toFixed(0)} KB → ${OUT}`);
  if (chats.length < 6) throw new Error('too few chats recorded');
}

main().catch((e) => {
  console.error('FAIL demo-record:', e.message);
  process.exit(1);
});
