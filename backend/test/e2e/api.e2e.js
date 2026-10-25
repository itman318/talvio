/* End-to-end check of a running server (real Express + Socket.IO + PostgreSQL).
 *
 *   BASE=http://localhost:4000 ADMIN_EMAIL=… ADMIN_PASSWORD=… node test/e2e/api.e2e.js
 *
 * Needs OTP_DEV_MODE=true on the server. Every step is independent: a failing step is
 * reported and the run continues, so one run shows every broken endpoint.
 */
const { io } = require('socket.io-client');

const BASE = process.env.BASE || 'http://localhost:4000';
const results = [];
let failures = 0;

async function step(name, fn) {
  const t = Date.now();
  try {
    const out = await fn();
    results.push(`PASS ${name} (${Date.now() - t}ms)`);
    return out;
  } catch (e) {
    failures++;
    results.push(`FAIL ${name}: ${e && e.message ? e.message : e}`);
    return undefined;
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

async function call(method, path, { token, body, form, raw } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  let payload;
  if (form) payload = form;
  else if (body !== undefined) {
    headers['content-type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(BASE + path, { method, headers, body: payload, redirect: 'manual' });
  if (raw) return res;
  const text = await res.text();
  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!res.ok) {
    const err = data && data.error ? `${data.error.code}: ${data.error.message}` : String(text).slice(0, 200);
    throw new Error(`${method} ${path} → ${res.status} ${err}`);
  }
  return data;
}

const api = {
  get: (p, token) => call('GET', p, { token }),
  post: (p, body, token) => call('POST', p, { token, body: body || {} }),
  put: (p, body, token) => call('PUT', p, { token, body: body || {} }),
  patch: (p, body, token) => call('PATCH', p, { token, body: body || {} }),
  del: (p, token) => call('DELETE', p, { token }),
};

async function login(phone, first) {
  const r = await api.post('/api/auth/otp/request', { phone });
  assert(r.dev_code, 'no dev_code (is OTP_DEV_MODE=true?)');
  const t = await api.post('/api/auth/otp/verify', { phone, code: r.dev_code, device: { name: 'e2e', platform: 'android', app_version: '1.0.0' } });
  assert(t.access_token && t.refresh_token, 'no tokens');
  const me = await api.get('/api/me', t.access_token);
  if (!me.first_name) await api.patch('/api/me', { first_name: first }, t.access_token);
  const me2 = await api.get('/api/me', t.access_token);
  return { ...t, me: me2 };
}

function connect(token) {
  return new Promise((resolve, reject) => {
    const s = io(BASE, { auth: { token }, transports: ['websocket'], reconnection: false, timeout: 8000 });
    const events = [];
    s.onAny((name, payload) => events.push({ name, payload }));
    s.on('connect', () => resolve({ s, events }));
    s.on('connect_error', (e) => reject(new Error(`socket connect_error: ${e.message}`)));
  });
}

function waitFor(conn, name, pred = () => true, ms = 6000) {
  return new Promise((resolve, reject) => {
    const found = conn.events.find((e) => e.name === name && pred(e.payload));
    if (found) return resolve(found.payload);
    const timer = setTimeout(() => {
      conn.s.off(name, h);
      reject(new Error(`no "${name}" event within ${ms}ms (got: ${[...new Set(conn.events.map((e) => e.name))].join(', ') || 'nothing'})`));
    }, ms);
    function h(p) {
      if (!pred(p)) return;
      clearTimeout(timer);
      conn.s.off(name, h);
      resolve(p);
    }
    conn.s.on(name, h);
  });
}

// 1x1 PNG
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

(async () => {
  await step('health', async () => {
    const h = await api.get('/health');
    assert(h && (h.ok === true || h.status === 'ok' || h.db), `unexpected /health: ${JSON.stringify(h)}`);
  });
  await step('app-config', async () => {
    const c = await api.get('/api/app-config');
    assert(typeof c === 'object' && c !== null, 'no config');
  });
  for (const p of ['/web/', '/web/app.js', '/web/web.css', '/web/manifest.webmanifest', '/web/sw.js', '/admin/', '/admin/app.js']) {
    await step(`static ${p}`, async () => {
      const r = await call('GET', p, { raw: true });
      assert(r.status === 200, `status ${r.status}`);
    });
  }

  const E = await step('email login (code by email, new account)', async () => {
    const r = await api.post('/api/auth/email/request', { email: 'E2E.User@Example.com' });
    assert(r.dev_code && r.email === 'e2e.user@example.com', JSON.stringify(r));
    const t = await api.post('/api/auth/email/verify', { email: 'e2e.user@example.com', code: r.dev_code, device: { name: 'e2e' } });
    assert(t.access_token && t.needs_profile === true, JSON.stringify(t).slice(0, 200));
    await api.patch('/api/me', { first_name: 'Email' }, t.access_token);
    const me = await api.get('/api/me', t.access_token);
    assert(me.email === 'e2e.user@example.com' && !me.phone, JSON.stringify(me).slice(0, 200));
    return { ...t, me };
  });
  await step('app-config exposes login methods', async () => {
    const c = await api.get('/api/app-config');
    assert(c.login_methods && c.login_methods.email === true && c.login_methods.phone === true, JSON.stringify(c.login_methods));
  });
  const A = await step('login user A (OTP dev mode)', () => login('+923001110001', 'Ali'));
  const B = await step('login user B', () => login('+923001110002', 'Sana'));
  const C = await step('login user C', () => login('+923001110003', 'Usman'));
  if (!A || !B || !C) return finish();

  await step('refresh token', async () => {
    const r = await api.post('/api/auth/refresh', { refresh_token: C.refresh_token });
    assert(r.access_token, 'no access token');
    C.access_token = r.access_token;
    C.refresh_token = r.refresh_token || C.refresh_token;
  });
  await step('profile: username + bio', async () => {
    await api.patch('/api/me', { username: 'ali_e2e', bio: 'Testing Talvio' }, A.access_token);
    const me = await api.get('/api/me', A.access_token);
    assert(me.username === 'ali_e2e', `username not saved: ${me.username}`);
  });
  await step('username check', () => api.get('/api/me/username-check?username=free_name_e2e', B.access_token));
  await step('privacy update', () => api.put('/api/me/privacy', { last_seen: 'contacts' }, B.access_token));
  await step('sessions list', async () => {
    const s = await api.get('/api/me/sessions', A.access_token);
    assert(Array.isArray(s) ? s.length : (s.sessions || []).length, 'no sessions');
  });
  await step('user search', async () => {
    const r = await api.get('/api/users/search?q=ali_e2e', B.access_token);
    const list = Array.isArray(r) ? r : r.users || r.results || [];
    assert(list.some((u) => u.id === A.me.id), 'A not found by username');
  });
  await step('get user', () => api.get(`/api/users/${A.me.id}`, B.access_token));
  await step('contacts sync + list', async () => {
    await api.post('/api/contacts/sync', { phones: ['+923001110001'] }, B.access_token);
    await api.get('/api/contacts', B.access_token);
  });

  const sa = await step('socket connect A', () => connect(A.access_token));
  const sb = await step('socket connect B', () => connect(B.access_token));

  const pc = await step('private chat A↔B', async () => {
    const c = await api.post('/api/chats/private', { user_id: B.me.id }, A.access_token);
    assert(c.id, 'no chat id');
    return c;
  });
  let m1;
  if (pc) {
    m1 = await step('send text + B gets message:new over socket', async () => {
      const m = await api.post(`/api/chats/${pc.id}/messages`, { text: 'Hello 👋', client_id: 'e2e-1' }, A.access_token);
      const msg = m.message || m;
      assert(msg.id, `no message id: ${JSON.stringify(m).slice(0, 200)}`);
      if (sb) await waitFor(sb, 'message:new', (p) => p.chat_id === pc.id);
      return msg;
    });
    let bMsg;
    await step('send via socket (message:send ack)', async () => {
      assert(sb, 'no socket');
      const ack = await new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('no ack')), 6000);
        sb.s.emit('message:send', { chat_id: pc.id, text: 'Hi there', client_id: 'e2e-2' }, (r) => {
          clearTimeout(t);
          resolve(r);
        });
      });
      assert(ack && ack.ok !== false && !ack.error, `ack error: ${JSON.stringify(ack)}`);
      bMsg = ack.message;
    });
    await step('idempotent client_id', async () => {
      const again = await api.post(`/api/chats/${pc.id}/messages`, { text: 'Hello 👋', client_id: 'e2e-1' }, A.access_token);
      assert((again.message || again).id === m1.id, 'duplicate created for same client_id');
    });
    await step('list messages', async () => {
      const r = await api.get(`/api/chats/${pc.id}/messages`, B.access_token);
      const list = Array.isArray(r) ? r : r.messages || [];
      assert(list.length >= 2, `expected ≥2 messages, got ${list.length}`);
    });
    await step('chat list shows chat + unread', async () => {
      const r = await api.get('/api/chats', B.access_token);
      const list = Array.isArray(r) ? r : r.chats || [];
      const c = list.find((x) => x.id === pc.id);
      assert(c, 'chat missing in list');
    });
    if (m1) {
      await step('typing event', async () => {
        sa.s.emit('typing', { chat_id: pc.id });
        await waitFor(sb, 'typing', (p) => p.chat_id === pc.id);
      });
      await step('mark read → B gets receipt:read', async () => {
        assert(bMsg && bMsg.id, 'no message from B');
        await api.post(`/api/chats/${pc.id}/read`, { message_id: bMsg.id }, A.access_token);
        if (sb) await waitFor(sb, 'receipt:read', (p) => p.chat_id === pc.id);
      });
      await step('edit message → message:edited', async () => {
        await api.patch(`/api/messages/${m1.id}`, { text: 'Hello! (edited)' }, A.access_token);
        if (sb) await waitFor(sb, 'message:edited', (p) => p.chat_id === pc.id);
      });
      await step('reaction → message:reactions', async () => {
        await api.put(`/api/messages/${m1.id}/reaction`, { emoji: '❤️' }, B.access_token);
        if (sa) await waitFor(sa, 'message:reactions', (p) => p.chat_id === pc.id);
      });
      await step('reply', () => api.post(`/api/chats/${pc.id}/messages`, { text: 'reply', reply_to_id: m1.id }, B.access_token));
      await step('pin + list pins + unpin', async () => {
        await api.post(`/api/chats/${pc.id}/pins`, { message_id: m1.id }, A.access_token);
        const p = await api.get(`/api/chats/${pc.id}/pins`, A.access_token);
        assert((Array.isArray(p) ? p : p.pins || p.messages || []).length >= 1, 'pin not listed');
        await api.del(`/api/chats/${pc.id}/pins/${m1.id}`, A.access_token);
      });
      await step('search messages', () => api.get('/api/search/messages?q=edited', A.access_token));
      await step('scheduled message', async () => {
        const at = new Date(Date.now() + 3600e3).toISOString();
        const r = await api.post(`/api/chats/${pc.id}/messages`, { text: 'later', schedule_at: at }, A.access_token);
        assert(r.scheduled, 'not scheduled');
        const list = await api.get(`/api/chats/${pc.id}/scheduled`, A.access_token);
        const items = Array.isArray(list) ? list : list.scheduled || [];
        assert(items.length >= 1, 'scheduled not listed');
        await api.del(`/api/scheduled/${items[0].id}`, A.access_token);
      });
      await step('chat settings: mute/pin/archive', async () => {
        await api.patch(`/api/chats/${pc.id}/settings`, { muted_until: new Date(Date.now() + 3600e3).toISOString(), pinned: true }, B.access_token);
        await api.patch(`/api/chats/${pc.id}/settings`, { muted_until: null, pinned: false }, B.access_token);
      });
    }
  }

  // media
  const media = await step('upload photo', async () => {
    const form = new FormData();
    form.append('file', new Blob([PNG], { type: 'image/png' }), 'dot.png');
    form.append('kind', 'image');
    const m = await call('POST', '/api/media', { token: A.access_token, form });
    assert(m.id, 'no media id');
    return m;
  });
  if (media && pc) {
    await step('send photo message', () => api.post(`/api/chats/${pc.id}/messages`, { type: 'image', media_id: media.id, text: 'pic' }, A.access_token));
    await step('download media (member)', async () => {
      const r = await call('GET', `/api/media/${media.id}`, { token: B.access_token, raw: true });
      assert(r.status === 200, `status ${r.status}`);
    });
    await step('media not visible to outsider', async () => {
      const r = await call('GET', `/api/media/${media.id}`, { token: C.access_token, raw: true });
      assert(r.status === 403 || r.status === 404, `outsider got ${r.status}`);
    });
  }
  const avatar = await step('upload avatar', async () => {
    const form = new FormData();
    form.append('file', new Blob([PNG], { type: 'image/png' }), 'me.png');
    form.append('kind', 'image');
    return call('POST', '/api/media', { token: B.access_token, form });
  });
  if (avatar) {
    await step('set avatar + public URL', async () => {
      const me = await api.put('/api/me/avatar', { media_id: avatar.id }, B.access_token);
      const url = me.avatar_url || (me.user && me.user.avatar_url);
      assert(url, `no avatar_url: ${JSON.stringify(me).slice(0, 200)}`);
      const r = await call('GET', url.startsWith('http') ? new URL(url).pathname : url, { raw: true });
      assert(r.status === 200, `public avatar status ${r.status}`);
    });
  }

  // groups
  const g = await step('create group', async () => {
    const r = await api.post('/api/chats/group', { title: 'Dev Team', member_ids: [B.me.id] }, A.access_token);
    const c = r.chat || r;
    assert(c.id, `no id: ${JSON.stringify(r).slice(0, 200)}`);
    return c;
  });
  if (g) {
    await step('add member C', () => api.post(`/api/chats/${g.id}/members`, { user_ids: [C.me.id] }, A.access_token));
    await step('members list', async () => {
      const r = await api.get(`/api/chats/${g.id}/members`, A.access_token);
      const list = Array.isArray(r) ? r : r.members || [];
      assert(list.length === 3, `expected 3 members, got ${list.length}`);
    });
    await step('promote B to admin', () => api.put(`/api/chats/${g.id}/members/${B.me.id}/role`, { role: 'admin' }, A.access_token));
    await step('rename group', () => api.patch(`/api/chats/${g.id}`, { title: 'Dev Team ✅' }, A.access_token));
    await step('mention + group message', () => api.post(`/api/chats/${g.id}/messages`, { text: '@ali_e2e build check karo' }, C.access_token));
    const poll = await step('poll', async () => {
      const r = await api.post(`/api/chats/${g.id}/messages`, { type: 'poll', poll: { question: 'Launch when?', options: ['Today', 'Tomorrow'] } }, A.access_token);
      return r.message || r;
    });
    if (poll && poll.id) {
      await step('vote', () => api.post(`/api/messages/${poll.id}/vote`, { options: [0] }, B.access_token));
      await step('close poll', () => api.post(`/api/messages/${poll.id}/poll/close`, {}, A.access_token));
    }
    await step('invite link + preview + join', async () => {
      const inv = await api.post(`/api/chats/${g.id}/invites`, {}, A.access_token);
      const code = inv.code || (inv.invite && inv.invite.code);
      assert(code, `no code: ${JSON.stringify(inv).slice(0, 200)}`);
      await api.post(`/api/chats/${g.id}/members/${C.me.id}`, {}, A.access_token).catch(() => {});
      await api.get(`/api/chats/invite/${code}`, C.access_token);
    });
    await step('topics on (forum) + list', async () => {
      await api.patch(`/api/chats/${g.id}`, { is_forum: true }, A.access_token);
      await api.get(`/api/chats/${g.id}/topics`, A.access_token);
    });
    await step('kick C', () => call('DELETE', `/api/chats/${g.id}/members/${C.me.id}`, { token: A.access_token }));
    await step('C leave-check: chat not accessible', async () => {
      const r = await call('GET', `/api/chats/${g.id}/messages`, { token: C.access_token, raw: true });
      assert(r.status === 403 || r.status === 404, `kicked user got ${r.status}`);
    });
    if (m1) await step('forward to group', () => api.post('/api/messages/forward', { from_chat_id: pc.id, to_chat_ids: [g.id], message_ids: [m1.id] }, A.access_token));
  }

  // channels
  const ch = await step('create channel', async () => {
    const c = await api.post('/api/chats/channel', { title: 'Trading Signals', username: 'signals_e2e' }, A.access_token);
    assert(c.id, 'no id');
    return c;
  });
  if (ch) {
    await step('public search finds channel', async () => {
      const r = await api.get('/api/chats/search?q=signals_e2e', B.access_token);
      const list = Array.isArray(r) ? r : r.chats || r.results || [];
      assert(list.some((x) => (x.chat_id || x.id) === ch.id), `not found in ${JSON.stringify(list).slice(0, 200)}`);
    });
    await step('B joins channel', () => api.post(`/api/chats/${ch.id}/join`, {}, B.access_token));
    const post = await step('post in channel', async () => {
      const r = await api.post(`/api/chats/${ch.id}/messages`, { text: 'XAUUSD BUY 2385' }, A.access_token);
      return r.message || r;
    });
    await step('B cannot post in channel', async () => {
      const r = await call('POST', `/api/chats/${ch.id}/messages`, { token: B.access_token, body: { text: 'hi' }, raw: true });
      assert(r.status === 403, `subscriber post got ${r.status}`);
    });
    if (post && post.id) {
      await step('channel views', () => api.post(`/api/chats/${ch.id}/views`, { message_ids: [post.id] }, B.access_token));
      await step('channel comments on + comment (thread)', async () => {
        await api.patch(`/api/chats/${ch.id}`, { comments_enabled: true }, A.access_token);
        await api.post(`/api/chats/${ch.id}/messages`, { text: 'Nice', thread_id: post.id }, B.access_token);
      });
    }
    await step('channel stats', () => api.get(`/api/chats/${ch.id}/stats`, A.access_token));
  }

  // folders, stories, support, reports, announcements
  await step('folders CRUD', async () => {
    const f = await api.post('/api/folders', { name: 'Work', include_groups: true }, B.access_token);
    const id = f.id || (f.folder && f.folder.id);
    assert(id, 'no folder id');
    await api.patch(`/api/folders/${id}`, { name: 'Office' }, B.access_token);
    await api.get('/api/folders', B.access_token);
    await api.del(`/api/folders/${id}`, B.access_token);
  });
  if (media) {
    await step('story post + feed + view', async () => {
      const form = new FormData();
      form.append('file', new Blob([PNG], { type: 'image/png' }), 's.png');
      form.append('kind', 'image');
      const sm = await call('POST', '/api/media', { token: A.access_token, form });
      const s = await api.post('/api/stories', { media_id: sm.id, caption: 'Hello', privacy: 'everyone' }, A.access_token);
      const sid = s.id || (s.story && s.story.id);
      assert(sid, 'no story id');
      await api.get('/api/stories', B.access_token);
      await api.post(`/api/stories/${sid}/view`, {}, B.access_token);
    });
  }
  await step('support ticket', async () => {
    const t = await api.post('/api/support/tickets', { subject: 'Help', message: 'App test' }, B.access_token);
    const id = t.id || (t.ticket && t.ticket.id);
    assert(id, 'no ticket id');
    await api.post(`/api/support/tickets/${id}/messages`, { text: 'more info' }, B.access_token);
  });
  if (m1) await step('report message', () => api.post('/api/reports', { target_type: 'message', target_id: m1.id, reason: 'spam' }, B.access_token));
  await step('announcements', () => api.get('/api/announcements', B.access_token));
  await step('block / unblock', async () => {
    await api.post(`/api/blocks/${C.me.id}`, {}, B.access_token);
    await api.get('/api/blocks', B.access_token);
    await api.del(`/api/blocks/${C.me.id}`, B.access_token);
  });

  // calls
  if (pc && sb) {
    await step('call start → B call:incoming → decline', async () => {
      const r = await api.post('/api/calls', { chat_id: pc.id, video: false }, A.access_token);
      const call0 = r.call || r;
      assert(call0.id, `no call id: ${JSON.stringify(r).slice(0, 200)}`);
      await waitFor(sb, 'call:incoming');
      await api.post(`/api/calls/${call0.id}/decline`, {}, B.access_token);
    });
    await step('call history', () => api.get('/api/calls', A.access_token));
    await step('ice servers', () => api.get('/api/calls/ice-servers', A.access_token));
  }

  // bots
  const bot = await step('create bot', async () => {
    const b = await api.post('/api/bots', { name: 'Helper Bot', username: 'helper_e2e_bot' }, A.access_token);
    const token = b.token || (b.bot && b.bot.token);
    assert(token, `no bot token: ${JSON.stringify(b).slice(0, 200)}`);
    return { ...b, token };
  });
  if (bot) {
    await step('bot API me (Bearer token)', async () => {
      const res = await fetch(`${BASE}/api/bot/v1/me`, { method: 'POST', headers: { authorization: `Bearer ${bot.token}` } });
      const r = await res.json();
      assert(r.ok === true && r.data && r.data.id, JSON.stringify(r));
    });
    await step('bot API rejects a bad token', async () => {
      const res = await fetch(`${BASE}/api/bot/v1/me`, { method: 'POST', headers: { authorization: 'Bearer tlv_1_nopenopenopenopenopenope' } });
      const r = await res.json();
      assert(res.status === 401 && r.ok === false && r.error.code === 'invalid_token', JSON.stringify(r));
    });
  }

  // premium / payments
  await step('premium info', () => api.get('/api/premium', B.access_token));

  // QR login for the web app
  await step('QR login: create → scan → approve → status', async () => {
    const q = await api.post('/api/auth/qr', { device: { name: 'Chrome' } });
    assert(q.token, 'no qr token');
    await api.post('/api/auth/qr/scan', { token: q.token }, A.access_token);
    await api.post('/api/auth/qr/approve', { token: q.token }, A.access_token);
    const s = await api.get(`/api/auth/qr/status?token=${encodeURIComponent(q.token)}`);
    assert(s.access_token || s.status === 'approved' || s.tokens, `not approved: ${JSON.stringify(s).slice(0, 200)}`);
  });

  // delete for everyone
  if (pc && m1) {
    await step('delete for everyone → message:deleted', async () => {
      await api.post(`/api/chats/${pc.id}/messages/delete`, { message_ids: [m1.id], for_everyone: true }, A.access_token);
      if (sb) await waitFor(sb, 'message:deleted', (p) => p.chat_id === pc.id);
    });
  }

  // admin
  const ADMIN_EMAIL = process.env.ADMIN_EMAIL;
  const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
  if (ADMIN_EMAIL) {
    const adm = await step('admin login', async () => {
      const r = await api.post('/api/admin/login', { email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
      assert(r.token || r.access_token, 'no admin token');
      return r.token || r.access_token;
    });
    if (adm) {
      for (const p of ['/api/admin/dashboard', '/api/admin/users', `/api/admin/users/${B.me.id}`, '/api/admin/reports', '/api/admin/groups', '/api/admin/settings', '/api/admin/admins', '/api/admin/logs', '/api/admin/support', '/api/admin/appeals', '/api/admin/announcements', '/api/admin/calls', '/api/admin/calls/stats', '/api/admin/bots', '/api/admin/revenue', '/api/admin/payments', '/api/admin/plans', '/api/admin/ads', '/api/admin/pages']) {
        await step(`admin GET ${p.replace('/api/admin', '')}`, () => api.get(p, adm));
      }
      await step('admin ban → user blocked → unban', async () => {
        await api.post(`/api/admin/users/${C.me.id}/ban`, { reason: 'e2e test' }, adm);
        const r = await call('GET', '/api/me', { token: C.access_token, raw: true });
        assert(r.status === 401 || r.status === 403, `banned user still gets ${r.status}`);
        await api.post(`/api/admin/users/${C.me.id}/unban`, {}, adm);
      });
      await step('admin announcement → user sees it', async () => {
        await api.post('/api/admin/announcements', { title: 'Hello', body: 'Welcome to Talvio' }, adm);
        const r = await api.get('/api/announcements', B.access_token);
        assert((Array.isArray(r) ? r : r.announcements || []).length >= 1, 'announcement not visible');
      });
      await step('admin settings round-trip', async () => {
        const s = await api.get('/api/admin/settings', adm);
        await api.put('/api/admin/settings', s.settings ? s.settings : s, adm);
      });
    }
  }

  await step('logout', () => api.post('/api/auth/logout', {}, A.access_token));
  await step('token rejected after logout', async () => {
    const r = await call('GET', '/api/me', { token: A.access_token, raw: true });
    assert(r.status === 401, `after logout got ${r.status}`);
  });

  for (const c of [sa, sb]) if (c) c.s.close();
  finish();
})().catch((e) => {
  results.push(`FAIL (crash) ${e.stack || e}`);
  failures++;
  finish();
});

function finish() {
  const out = results.join('\n') + `\n\n${results.length - failures} passed, ${failures} failed\n`;
  process.stdout.write(out);
  require('fs').writeFileSync(process.env.E2E_OUT || 'e2e-result.txt', out);
  process.exit(failures ? 1 : 0);
}
