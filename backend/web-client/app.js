/* Talvio Web / Desktop — dependency-free single page app.
 * Login with a QR code (scan with the phone) or phone number + code. Realtime via Socket.IO
 * (falls back to polling). All user content is rendered with textContent — never innerHTML. */
(() => {
  'use strict';

  // ------------------------------------------------------------------ helpers
  const $app = document.getElementById('app');
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { /* private mode */ } },
  };

  function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'style') e.style.cssText = v;
      else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
      else if (k === 'text') e.textContent = v;
      else e.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat(Infinity)) {
      if (c === null || c === undefined || c === false) continue;
      e.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return e;
  }
  const svgIcon = (d) => {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', '0 0 24 24');
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', d);
    s.append(p);
    return s;
  };
  // Crash reports → our own server (Admin → App crashes). Once per distinct error per page load.
  const sentErrors = new Set();
  function reportError(message, stack) {
    try {
      const key = `${message}|${String(stack || '').split('\n').slice(0, 3).join('|')}`;
      if (sentErrors.has(key) || sentErrors.size > 30) return;
      sentErrors.add(key);
      const headers = { 'content-type': 'application/json' };
      const token = (() => { try { return localStorage.getItem('wc_access'); } catch (_) { return null; } })();
      if (token) headers.authorization = `Bearer ${token}`;
      fetch('/api/client-errors', { method: 'POST', headers, body: JSON.stringify({
        platform: window.matchMedia('(display-mode: standalone)').matches ? 'desktop' : 'web',
        app_version: 'web', device: navigator.userAgent.slice(0, 100), message: String(message).slice(0, 2000), stack: String(stack || '').slice(0, 12000),
      }) }).catch(() => {});
    } catch (_) { /* never throw from the reporter */ }
  }
  window.addEventListener('error', (e) => reportError(e.message || 'Script error', e.error && e.error.stack));
  window.addEventListener('unhandledrejection', (e) => reportError(`Unhandled promise: ${e.reason && e.reason.message ? e.reason.message : e.reason}`, e.reason && e.reason.stack));

  const ICONS = {
    send: 'M12 4.5 5 11.5l1.6 1.6 4.3-4.3V20h2.2V8.8l4.3 4.3 1.6-1.6z',
    attach: 'M16.5 6v11.5c0 2.21-1.79 4-4 4s-4-1.79-4-4V5a2.5 2.5 0 0 1 5 0v10.5c0 .55-.45 1-1 1s-1-.45-1-1V6H10v9.5a2.5 2.5 0 0 0 5 0V5c0-2.21-1.79-4-4-4S7 2.79 7 5v12.5c0 3.04 2.46 5.5 5.5 5.5s5.5-2.46 5.5-5.5V6h-1.5z',
    menu: 'M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z',
    back: 'M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z',
    bell: 'M12 22c1.1 0 2-.9 2-2h-4a2 2 0 0 0 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4a1.5 1.5 0 0 0-3 0v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z',
  };

  let toastTimer;
  function toast(text) {
    const t = document.getElementById('toast');
    t.textContent = text;
    t.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 2600);
  }

  // Ember avatar gradients (match the mobile app's Brand.avatarGradients).
  const GRADS = [['#FF8A6E', '#E2553A'], ['#EE6A9A', '#C8366E'], ['#8E7CF0', '#5B49D6'], ['#34CDB6', '#0E9A86'],
    ['#F7C56B', '#E29A2E'], ['#5DA9F0', '#2F6FD0'], ['#6FCB8C', '#2F9D5A'], ['#8A93B4', '#4E5675']];
  const brandMark = (size = 40) => {
    const box = el('span', { class: 'brand-mark', style: `width:${size}px;height:${size}px` });
    box.innerHTML = '<svg viewBox="0 0 64 64" aria-hidden="true"><defs><linearGradient id="tvg" x1="0" x2="1"><stop offset="0" stop-color="#FF8A6E"/><stop offset=".5" stop-color="#EF5A3C"/><stop offset="1" stop-color="#E0417A"/></linearGradient></defs><rect x="23" y="12.8" width="28.2" height="23" rx="11.5" fill="url(#tvg)"/><rect x="11.5" y="24.3" width="30.7" height="24.3" rx="12" fill="#fff"/><circle cx="19.8" cy="36.5" r="2.2" fill="#151A2E"/><circle cx="26.9" cy="36.5" r="2.2" fill="#151A2E"/><circle cx="33.9" cy="36.5" r="2.2" fill="#151A2E"/></svg>';
    return box;
  };
  const initials = (name) => (name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || '?';
  function avatar(id, name, url, size = 48) {
    const style = `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.38)}px;border-radius:${Math.round(size * 0.34)}px;background:linear-gradient(135deg,${GRADS[Math.abs(Number(id) || 0) % GRADS.length].join(',')})`;
    if (url) {
      const img = el('img', { class: 'avatar', style, alt: '' });
      mediaUrl(url).then((u) => { if (u) img.src = u; }).catch(() => {});
      return img;
    }
    return el('span', { class: 'avatar', style }, initials(name));
  }

  const pad = (n) => String(n).padStart(2, '0');
  function timeOf(iso) {
    const d = new Date(iso);
    return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  function listTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    const now = new Date();
    if (d.toDateString() === now.toDateString()) return timeOf(iso);
    const diff = (now - d) / 86400000;
    if (diff < 7) return d.toLocaleDateString(undefined, { weekday: 'short' });
    return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }
  function dayLabel(d) {
    const now = new Date();
    if (d.toDateString() === now.toDateString()) return 'Today';
    const y = new Date(now.getTime() - 86400000);
    if (d.toDateString() === y.toDateString()) return 'Yesterday';
    return d.toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' });
  }
  const fmtSize = (b) => (b < 1024 ? `${b} B` : b < 1048576 ? `${(b / 1024).toFixed(1)} KB` : `${(b / 1048576).toFixed(1)} MB`);
  const dur = (s) => `${Math.floor(s / 60)}:${pad(s % 60)}`;
  const userName = (u) => (!u ? 'Deleted Account' : u.deleted ? 'Deleted Account' : (`${u.first_name || ''} ${u.last_name || ''}`.trim() || (u.username ? `@${u.username}` : 'User')));

  function lastSeen(u) {
    if (!u) return '';
    if (u.is_bot) return 'bot';
    if (u.online) return 'online';
    if (u.last_seen_hidden || !u.last_seen) return 'last seen recently';
    const d = new Date(u.last_seen);
    const mins = Math.round((Date.now() - d) / 60000);
    if (mins < 1) return 'last seen just now';
    if (mins < 60) return `last seen ${mins} min ago`;
    if (d.toDateString() === new Date().toDateString()) return `last seen at ${timeOf(d)}`;
    return `last seen ${listTime(d.toISOString())}`;
  }

  function preview(m) {
    if (!m) return '';
    if (m.view_once) return m.type === 'voice' ? '🎤 View once voice message' : m.type === 'video' ? '🎬 View once video' : '📷 View once photo';
    switch (m.type) {
      case 'image': return m.text ? `🖼 ${m.text}` : '🖼 Photo';
      case 'video': return m.text ? `🎬 ${m.text}` : '🎬 Video';
      case 'voice': return '🎤 Voice message';
      case 'video_note': return '📹 Video message';
      case 'file': return `📎 ${(m.media && m.media.name) || 'File'}`;
      case 'poll': return `📊 ${m.text}`;
      case 'location': return m.meta && m.meta.live ? '📍 Live location' : '📍 Location';
      case 'sticker': return `${(m.meta && m.meta.sticker && m.meta.sticker.emoji) || '🙂'} Sticker`;
      case 'gif': return m.text ? `GIF · ${m.text}` : 'GIF';
      case 'contact': return `👤 ${m.text || 'Contact'}`;
      case 'call': {
        const c = (m.meta && m.meta.call) || {};
        if (c.status === 'missed' || c.status === 'busy') return '📞 Missed call';
        return c.duration_sec ? `📞 Call (${dur(c.duration_sec)})` : '📞 Call';
      }
      case 'system': return systemText(m);
      default: return (m.text || '').replace(FMT_RE, (x, b, i, st, code, sp) => (sp !== undefined ? '▒▒▒▒' : (b || i || st || code || ''))).replace(TALI_RE, '🦊');
    }
  }

  // ------------------------------------------------------------------ API
  const auth = {
    access: store.get('wc_access'),
    refresh: store.get('wc_refresh'),
    me: (() => { try { return JSON.parse(store.get('wc_me') || 'null'); } catch (_) { return null; } })(),
  };
  function saveAuth(data) {
    if (data.access_token) auth.access = data.access_token;
    if (data.refresh_token) auth.refresh = data.refresh_token;
    if (data.user) auth.me = data.user;
    store.set('wc_access', auth.access);
    store.set('wc_refresh', auth.refresh);
    store.set('wc_me', auth.me ? JSON.stringify(auth.me) : null);
  }
  function clearAuth() {
    auth.access = null;
    auth.refresh = null;
    auth.me = null;
    ['wc_access', 'wc_refresh', 'wc_me'].forEach((k) => store.set(k, null));
  }

  class ApiError extends Error {
    constructor(status, code, message, extra) { super(message); this.status = status; this.code = code; this.extra = extra || {}; }
  }

  let refreshing = null;
  async function refreshTokens() {
    if (!auth.refresh) throw new ApiError(401, 'invalid_refresh_token', 'Please log in again');
    if (!refreshing) {
      refreshing = fetch('/api/auth/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: auth.refresh }) })
        .then(async (r) => {
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new ApiError(r.status, (j.error && j.error.code) || 'error', (j.error && j.error.message) || 'Please log in again');
          saveAuth(j);
          return j;
        })
        .finally(() => { refreshing = null; });
    }
    return refreshing;
  }

  async function api(method, path, body, { retry = true, raw = false } = {}) {
    const headers = {};
    if (auth.access) headers.Authorization = `Bearer ${auth.access}`;
    if (body !== undefined && !(body instanceof FormData)) headers['Content-Type'] = 'application/json';
    let res;
    try {
      res = await fetch(`/api${path}`, { method, headers, body: body === undefined ? undefined : body instanceof FormData ? body : JSON.stringify(body) });
    } catch (_) {
      throw new ApiError(0, 'network', 'No connection');
    }
    if (res.status === 401 && retry && auth.refresh) {
      const j = await res.clone().json().catch(() => ({}));
      if (j.error && ['invalid_token', 'token_expired', 'unauthorized'].includes(j.error.code)) {
        try {
          await refreshTokens();
        } catch (e) {
          logout('Your session ended. Please log in again.');
          throw e;
        }
        return api(method, path, body, { retry: false, raw });
      }
    }
    if (raw) {
      if (!res.ok) throw new ApiError(res.status, 'error', 'Download failed');
      return res;
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const e = data.error || {};
      const err = new ApiError(res.status, e.code || 'error', e.message || `Error ${res.status}`, e);
      if (['session_revoked', 'account_banned', 'account_deleted'].includes(err.code)) logout(err.message);
      throw err;
    }
    return data;
  }

  // protected media → blob URLs (cached)
  const blobCache = new Map();
  function mediaUrl(url) {
    if (!url) return Promise.resolve(null);
    if (url.endsWith('/public')) return Promise.resolve(url);
    if (!blobCache.has(url)) {
      blobCache.set(url, api('GET', url.replace(/^\/api/, ''), undefined, { raw: true })
        .then((r) => r.blob())
        .then((b) => URL.createObjectURL(b))
        .catch((e) => { blobCache.delete(url); throw e; }));
    }
    return blobCache.get(url);
  }

  function upload(file, kind, onProgress) {
    return new Promise((resolve, reject) => {
      const send = (again) => {
        const fd = new FormData();
        fd.append('kind', kind);
        fd.append('file', file, file.name || 'file');
        const xhr = new XMLHttpRequest();
        xhr.open('POST', '/api/media');
        xhr.setRequestHeader('Authorization', `Bearer ${auth.access}`);
        xhr.upload.onprogress = (e) => { if (e.lengthComputable && onProgress) onProgress(e.loaded / e.total); };
        xhr.onload = async () => {
          let j = {};
          try { j = JSON.parse(xhr.responseText); } catch (_) { /* */ }
          if (xhr.status === 401 && !again) {
            try { await refreshTokens(); send(true); } catch (e) { reject(e); }
            return;
          }
          if (xhr.status >= 200 && xhr.status < 300) resolve(j);
          else reject(new ApiError(xhr.status, (j.error && j.error.code) || 'error', (j.error && j.error.message) || 'Upload failed'));
        };
        xhr.onerror = () => reject(new ApiError(0, 'network', 'Upload failed'));
        xhr.send(fd);
      };
      send(false);
    });
  }

  // ------------------------------------------------------------------ app state
  const S = {
    chats: [],
    chatsLoaded: false,
    open: null, // chat id
    messages: new Map(), // chatId -> [] oldest → newest
    hasMore: new Map(),
    typing: new Map(), // chatId -> {userId: until}
    typingAction: new Map(), // "chatId:userId" -> typing | recording_voice | uploading_photo…
    users: new Map(),
    reply: null,
    editing: null,
    search: '',
    found: [],
    socket: null,
    connected: false,
    config: {},
  };
  const chatById = (id) => S.chats.find((c) => c.id === id);

  function remember(users) {
    for (const u of users) if (u && u.id) S.users.set(u.id, { ...(S.users.get(u.id) || {}), ...u });
  }
  function disappearLabel(sec) {
    if (sec % 86400 === 0) { const d = sec / 86400; return d === 1 ? '24 hours' : d === 7 ? '1 week' : d === 90 ? '90 days' : `${d} days`; }
    if (sec % 3600 === 0) { const h = sec / 3600; return h === 1 ? '1 hour' : `${h} hours`; }
    return `${Math.round(sec / 60)} min`;
  }
  function systemText(m) {
    const meta = m.meta || {};
    const actor = userName(S.users.get(m.sender_id) || m.sender);
    const who = (id) => userName(S.users.get(id));
    switch (meta.event) {
      case 'group_created': return `${actor} created the group “${meta.title || ''}”`;
      case 'channel_created': return `Channel “${meta.title || ''}” created`;
      case 'title_changed': return `${actor} changed the group name to “${meta.title || ''}”`;
      case 'photo_changed': return `${actor} changed the group photo`;
      case 'welcome': return `👋 Welcome ${(meta.user_ids || []).slice(0, 3).map(who).join(', ')}!${meta.text ? `\n${meta.text}` : ''}`;
      case 'members_added': return (meta.user_ids || []).length === 1 ? `${actor} added ${who(meta.user_ids[0])}` : `${actor} added ${(meta.user_ids || []).length} members`;
      case 'member_removed': return `${actor} removed ${who(meta.user_id)}`;
      case 'member_left': return `${who(meta.user_id)} left the group`;
      case 'member_joined': return `${who(meta.user_id)} joined the group`;
      case 'message_pinned': return `${actor} pinned a message`;
      case 'topic_created': return `${actor} created the topic “${meta.title || ''}”`;
      case 'disappearing_changed': return meta.seconds ? `${actor} turned on disappearing messages (${disappearLabel(meta.seconds)})` : `${actor} turned off disappearing messages`;
      default: return 'Group updated';
    }
  }

  // ------------------------------------------------------------------ login
  let qrLoop = 0;
  function renderLogin(message) {
    qrLoop += 1;
    const myLoop = qrLoop;
    const canvas = el('canvas', { width: 240, height: 240, 'aria-label': 'Login QR code' });
    const status = el('div', { class: 'qr-status muted' }, 'Loading…');
    const qrPane = el('div', { class: 'qr-box' }, canvas, status);
    const phonePane = el('div', { class: 'hidden', style: 'flex:0 0 300px' });
    const emailPane = el('div', { class: 'hidden', style: 'flex:0 0 300px' });
    const tabs = el('div', { class: 'tabs' },
      el('button', { class: 'active', onclick: (e) => switchTab(e, 'qr') }, 'QR code'),
      el('button', { onclick: (e) => switchTab(e, 'email') }, 'Email'),
      el('button', { onclick: (e) => switchTab(e, 'phone') }, 'Phone number'));
    function switchTab(e, which) {
      [...tabs.children].forEach((b) => b.classList.toggle('active', b === e.currentTarget));
      qrPane.classList.toggle('hidden', which !== 'qr');
      phonePane.classList.toggle('hidden', which !== 'phone');
      emailPane.classList.toggle('hidden', which !== 'email');
    }
    $app.replaceChildren(el('div', { class: 'login' }, el('div', { class: 'login-card' },
      el('div', { class: 'login-steps' },
        brandMark(56),
        el('h1', {}, 'Use Talvio on your computer'),
        message ? el('p', { style: 'color:var(--danger)' }, message) : null,
        el('ol', {},
          el('li', {}, 'Open Talvio on your phone'),
          el('li', {}, 'Go to Settings → Devices → Link a device'),
          el('li', {}, 'Point your phone at this screen')),
        tabs,
        el('p', { class: 'muted' }, 'Tip: install it as a desktop app from your browser menu (“Install Talvio”).')),
      qrPane, emailPane, phonePane)));
    buildPhoneLogin(phonePane);
    buildCodeLogin(emailPane, 'email');

    const device = { platform: window.matchMedia('(display-mode: standalone)').matches ? 'desktop' : 'web', name: browserName() };
    (async function loop() {
      while (myLoop === qrLoop && !auth.access) {
        let code;
        try {
          code = await api('POST', '/auth/qr', { device });
        } catch (e) {
          status.textContent = e.message;
          await new Promise((r) => setTimeout(r, 5000));
          continue;
        }
        QR.draw(canvas, code.qr, { scale: 6, border: 3 });
        status.textContent = 'Scan with your phone';
        const until = Date.now() + code.expires_in * 1000;
        while (myLoop === qrLoop && Date.now() < until) {
          let r;
          try {
            r = await api('GET', `/auth/qr/status?token=${encodeURIComponent(code.token)}&wait=25`);
          } catch (_) {
            await new Promise((res) => setTimeout(res, 3000));
            continue;
          }
          if (myLoop !== qrLoop) return;
          if (r.status === 'scanned') status.textContent = 'Confirm on your phone…';
          if (r.status === 'approved') {
            saveAuth(r);
            start();
            return;
          }
          if (r.status === 'declined') { status.textContent = 'Declined on the phone — new code…'; break; }
          if (r.status === 'expired' || r.status === 'used') break;
        }
      }
    }());
  }

  function browserName() {
    const ua = navigator.userAgent;
    const b = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
    const os = /Windows/.test(ua) ? 'Windows' : /Mac OS/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : '';
    return `${b}${os ? ` on ${os}` : ''}`;
  }

  function buildPhoneLogin(box) {
    buildCodeLogin(box, 'phone');
  }

  /** Login with a one-time code sent by email (free) or SMS. */
  function buildCodeLogin(box, kind) {
    const isEmail = kind === 'email';
    const phone = isEmail
      ? el('input', { type: 'email', placeholder: 'name@gmail.com', autocomplete: 'email' })
      : el('input', { type: 'tel', placeholder: '+92 300 1234567', autocomplete: 'tel' });
    const code = el('input', { type: 'text', inputmode: 'numeric', placeholder: '6-digit code', maxlength: 8 });
    const hint = el('div', { class: 'muted' });
    const step2 = el('div', { class: 'hidden' }, el('div', { class: 'field' }, el('label', {}, 'Code'), code), hint);
    const btn = el('button', { class: 'btn' }, 'Send code');
    let sent = null;
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      try {
        if (!sent) {
          const r = isEmail
            ? await api('POST', '/auth/email/request', { email: phone.value.trim() })
            : await api('POST', '/auth/otp/request', { phone: phone.value.trim() });
          sent = isEmail ? r.email : r.phone;
          step2.classList.remove('hidden');
          hint.textContent = r.dev_code ? `Development mode code: ${r.dev_code}` : isEmail ? 'We emailed you the code (check Spam too).' : 'We sent the code by SMS.';
          btn.textContent = 'Log in';
          code.focus();
        } else {
          const device = { platform: 'web', name: browserName(), app_version: 'web' };
          const r = isEmail
            ? await api('POST', '/auth/email/verify', { email: sent, code: code.value.trim(), device })
            : await api('POST', '/auth/otp/verify', { phone: sent, code: code.value.trim(), device });
          if (r.needs_password) return renderPasswordStep(r, device);
          saveAuth(r);
          if (r.needs_profile) return renderProfileSetup();
          start();
        }
      } catch (e) {
        toast(e.message);
      } finally {
        btn.disabled = false;
      }
      return undefined;
    });
    box.append(el('h3', { style: 'margin-top:0' }, isEmail ? 'Log in with email' : 'Log in with phone'),
      el('div', { class: 'field' }, el('label', {}, isEmail ? 'Email address' : 'Phone number'), phone), step2, btn);
  }

  /** Two-step verification: the account password after the code. */
  function renderPasswordStep(ch, device) {
    const pw = el('input', { type: 'password', placeholder: 'Password', autocomplete: 'current-password' });
    const btn = el('button', { class: 'btn' }, 'Log in');
    const forgot = el('button', { class: 'btn ghost', type: 'button' }, 'Forgot password?');
    const note = el('div', { class: 'muted' }, ch.reset_pending_until ? `Reset requested — the password will be removed on ${new Date(ch.reset_pending_until).toLocaleDateString()}.` : '');
    const go = async () => {
      if (!pw.value) return;
      btn.disabled = true;
      try {
        const r = await api('POST', '/auth/password/verify', { login_token: ch.login_token, password: pw.value, device });
        saveAuth(r);
        if (r.needs_profile) { renderProfileSetup(); return; }
        start();
      } catch (e) {
        toast(e.message);
        pw.value = '';
      } finally {
        btn.disabled = false;
      }
    };
    btn.addEventListener('click', go);
    pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    forgot.addEventListener('click', async () => {
      if (!confirm('Reset the password? For your security it is removed after 7 days, unless you cancel it from a logged-in device.')) return;
      try {
        const r = await api('POST', '/auth/password/reset', { login_token: ch.login_token });
        note.textContent = `Reset requested — you can log in without the password after ${new Date(r.reset_pending_until).toLocaleDateString()}.`;
      } catch (e) { toast(e.message); }
    });
    $app.replaceChildren(el('div', { class: 'login' }, el('div', { class: 'login-card', style: 'max-width:420px;display:block' },
      el('h1', {}, 'Two-step verification'),
      el('p', { class: 'muted' }, 'Your account has an extra password.'),
      el('div', { class: 'field' }, pw), ch.hint ? el('div', { class: 'muted' }, `Hint: ${ch.hint}`) : null, btn, ch.reset_pending_until ? null : forgot, note)));
    pw.focus();
  }

  function renderProfileSetup() {
    const first = el('input', { type: 'text', placeholder: 'First name', maxlength: 64 });
    const last = el('input', { type: 'text', placeholder: 'Last name (optional)', maxlength: 64 });
    const btn = el('button', { class: 'btn' }, 'Continue');
    btn.addEventListener('click', async () => {
      if (!first.value.trim()) return toast('Enter your name');
      try {
        saveAuth({ user: await api('PATCH', '/me', { first_name: first.value.trim(), last_name: last.value.trim() }) });
        start();
      } catch (e) { toast(e.message); }
      return undefined;
    });
    $app.replaceChildren(el('div', { class: 'login' }, el('div', { class: 'login-card', style: 'max-width:420px;display:block' },
      el('h1', {}, 'Your name'), el('div', { class: 'field' }, first), el('div', { class: 'field' }, last), btn)));
  }

  async function logout(reason) {
    if (auth.access && !reason) await api('POST', '/auth/logout', {}).catch(() => {});
    if (S.socket) { S.socket.disconnect(); S.socket = null; }
    clearAuth();
    S.chats = []; S.messages.clear(); S.open = null; S.chatsLoaded = false;
    renderLogin(reason);
  }

  // ------------------------------------------------------------------ boot
  let layout; let sideList; let mainPane; let searchInput;
  async function start() {
    qrLoop += 1;
    if (!auth.access) return renderLogin();
    try {
      S.config = await api('GET', '/app-config').catch(() => ({}));
      saveAuth({ user: await api('GET', '/me') });
    } catch (e) {
      if (e.status === 401) return logout('Please log in again.');
    }
    remember([auth.me]);
    buildLayout();
    await loadChats();
    connectRealtime();
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js', { scope: './' }).catch(() => {});
    const hash = parseInt(location.hash.slice(1), 10);
    if (hash && chatById(hash)) openChat(hash);
    return undefined;
  }

  function buildLayout() {
    searchInput = el('input', { class: 'search', type: 'search', placeholder: 'Search', oninput: onSearch });
    const menuBtn = el('button', { class: 'icon-btn', title: 'Menu', onclick: (e) => openMenu(e, [
      ['Enable notifications', askNotifications],
      ['Log out', () => logout()],
    ]) }, svgIcon(ICONS.menu));
    sideList = el('div', { class: 'chat-list' });
    mainPane = el('div', { class: 'main' }, el('div', { class: 'empty-main' }, 'Select a chat to start messaging'));
    layout = el('div', { class: 'layout' },
      el('aside', { class: 'side' }, el('div', { class: 'side-head' }, menuBtn, brandMark(32), searchInput), sideList),
      mainPane);
    $app.replaceChildren(layout);
  }

  async function loadChats() {
    try {
      S.chats = await api('GET', '/chats');
      S.chatsLoaded = true;
      for (const c of S.chats) {
        if (c.peer) remember([c.peer]);
        if (c.last_message && c.last_message.sender) remember([c.last_message.sender]);
      }
      sortChats();
      renderChatList();
      updateTitle();
    } catch (e) {
      toast(e.message);
    }
  }
  function sortChats() {
    S.chats.sort((a, b) => (b.is_pinned - a.is_pinned) || (new Date(b.last_message_at || b.created_at) - new Date(a.last_message_at || a.created_at)));
  }
  function updateTitle() {
    const n = S.chats.reduce((s, c) => s + (c.is_muted || c.is_request ? 0 : c.unread_count || 0), 0);
    document.title = n ? `(${n}) Talvio` : 'Talvio';
  }

  // ------------------------------------------------------------------ chat list
  let searchTimer;
  function onSearch() {
    S.search = searchInput.value.trim();
    clearTimeout(searchTimer);
    renderChatList();
    if (S.search.length >= 2) {
      searchTimer = setTimeout(async () => {
        try {
          S.found = await api('GET', `/users/search?q=${encodeURIComponent(S.search)}`);
          remember(S.found);
          renderChatList();
        } catch (_) { /* */ }
      }, 300);
    } else S.found = [];
  }

  function chatTile(c) {
    const last = c.last_message;
    const typingNow = typingText(c);
    const senderPrefix = last && last.sender && c.type !== 'private' && !last.type.includes('system') ? `${last.sender.first_name}: ` : '';
    return el('div', { class: `tile${S.open === c.id ? ' active' : ''}`, onclick: () => openChat(c.id) },
      avatar(c.type === 'private' && c.peer ? c.peer.id : c.id, c.title, c.avatar_url, 52),
      el('div', { class: 'mid' },
        el('div', { class: 'title' },
          c.type === 'channel' ? '📢 ' : c.type === 'group' ? '👥 ' : '',
          el('span', { style: 'overflow:hidden;text-overflow:ellipsis' }, c.title),
          c.is_verified ? el('span', { class: 'verified', title: 'Verified' }, '✔') : null,
          c.peer && c.peer.is_premium ? el('span', { class: 'star' }, '★') : null,
          c.is_muted ? el('span', { class: 'muted' }, '🔕') : null),
        el('div', { class: 'sub' }, typingNow || (last ? senderPrefix + preview(last) : ''))),
      el('div', { class: 'right' },
        el('span', { class: 'time' }, listTime(c.last_message_at)),
        c.unread_count ? el('span', { class: `badge${c.is_muted ? ' muted-badge' : ''}` }, c.unread_count > 999 ? '999+' : c.unread_count) : c.is_pinned ? el('span', { class: 'muted' }, '📌') : null));
  }

  function renderChatList() {
    if (!sideList) return;
    const q = S.search.toLowerCase();
    const requests = S.chats.filter((c) => c.is_request && !c.is_archived);
    const chats = q ? S.chats.filter((c) => c.title.toLowerCase().includes(q))
      : S.chats.filter((c) => !c.is_archived && (S.showRequests ? c.is_request : !c.is_request));
    const nodes = [];
    if (!S.chatsLoaded) nodes.push(el('div', { class: 'section-title' }, 'Loading…'));
    if (!q && (requests.length || S.showRequests)) {
      nodes.push(el('div', { class: 'tile requests-row', onclick: () => { S.showRequests = !S.showRequests; renderChatList(); } },
        el('div', { class: 'req-ic' }, S.showRequests ? '←' : '✉'),
        el('div', { class: 'mid' },
          el('div', { class: 'title' }, S.showRequests ? 'Back to chats' : 'Message requests'),
          el('div', { class: 'sub' }, S.showRequests ? 'People who are not in your contacts' : `${requests.length} waiting`))));
    }
    if (q && chats.length) nodes.push(el('div', { class: 'section-title' }, 'Chats'));
    nodes.push(...chats.map(chatTile));
    if (q && S.found.length) {
      nodes.push(el('div', { class: 'section-title' }, 'People'));
      for (const u of S.found) {
        nodes.push(el('div', { class: 'tile', onclick: () => openPrivate(u.id) },
          avatar(u.id, userName(u), u.avatar_url, 44),
          el('div', { class: 'mid' }, el('div', { class: 'title' }, userName(u)), el('div', { class: 'sub' }, u.username ? `@${u.username}` : lastSeen(u)))));
      }
    }
    if (S.chatsLoaded && !nodes.length) nodes.push(el('div', { class: 'section-title' }, q ? 'Nothing found' : 'No chats yet — search for someone by @username'));
    sideList.replaceChildren(...nodes);
  }

  async function openPrivate(userId) {
    try {
      const c = await api('POST', '/chats/private', { user_id: userId });
      upsertChat(c);
      searchInput.value = '';
      S.search = '';
      S.found = [];
      openChat(c.id);
    } catch (e) { toast(e.message); }
  }

  function upsertChat(c) {
    const i = S.chats.findIndex((x) => x.id === c.id);
    if (i >= 0) S.chats[i] = c; else S.chats.push(c);
    if (c.peer) remember([c.peer]);
    sortChats();
  }
  async function refreshChat(id) {
    try { upsertChat(await api('GET', `/chats/${id}`)); } catch (e) { if (e.status === 404) S.chats = S.chats.filter((c) => c.id !== id); }
    renderChatList();
    if (S.open === id) renderHeader();
    updateTitle();
  }

  // ------------------------------------------------------------------ chat view
  let msgBox; let headBox; let composerBox; let textarea; let progressBar; let loadingOlder = false;

  async function openChat(id) {
    S.open = id;
    S.reply = null;
    S.editing = null;
    history.replaceState(null, '', `#${id}`);
    layout.classList.add('chat-open');
    renderChatList();
    const c = chatById(id);
    if (!c) return;
    headBox = el('div', { class: 'chat-head' });
    msgBox = el('div', { class: 'messages', onscroll: onScroll });
    composerBox = el('div');
    progressBar = el('div', { class: 'progress', style: 'width:0' });
    mainPane.replaceChildren(headBox, progressBar, msgBox, composerBox);
    mainPane.ondragover = (e) => { e.preventDefault(); };
    mainPane.ondrop = (e) => { e.preventDefault(); if (e.dataTransfer.files.length) sendFiles([...e.dataTransfer.files]); };
    renderHeader();
    renderComposer();
    if (!S.messages.has(id)) {
      msgBox.append(el('div', { class: 'sys' }, 'Loading…'));
      await loadMessages(id);
    }
    if (S.open !== id) return;
    renderMessages(true);
    markRead();
    if (c.type === 'channel' && c.is_public) loadAd(id);
  }

  function renderHeader() {
    const c = chatById(S.open);
    if (!c || !headBox) return;
    let sub = '';
    let online = false;
    const t = typingText(c);
    if (t) { sub = t; online = true; } else if (c.type === 'private' && c.peer) { sub = c.is_saved_messages ? '' : lastSeen(S.users.get(c.peer.id) || c.peer); online = sub === 'online'; } else if (c.type === 'channel') sub = `${c.member_count} subscribers`; else sub = `${c.member_count} members`;
    headBox.replaceChildren(
      el('button', { class: 'icon-btn', title: 'Back', style: window.innerWidth > 760 ? 'display:none' : '', onclick: () => { layout.classList.remove('chat-open'); S.open = null; renderChatList(); } }, svgIcon(ICONS.back)),
      avatar(c.type === 'private' && c.peer ? c.peer.id : c.id, c.title, c.avatar_url, 42),
      el('div', {}, el('div', { class: 't' }, c.title, c.peer && c.peer.is_premium ? el('span', { class: 'star' }, ' ★') : null), el('div', { class: `s${online ? ' online' : ''}` }, sub)));
  }

  async function loadMessages(id, before) {
    const q = new URLSearchParams({ limit: '50' });
    if (before) q.set('before', before);
    const r = await api('GET', `/chats/${id}/messages?${q}`);
    const list = r.messages.slice().reverse();
    remember(list.map((m) => m.sender).filter(Boolean));
    const cur = S.messages.get(id) || [];
    S.messages.set(id, before ? [...list, ...cur] : mergeNew(cur, list));
    S.hasMore.set(id, r.has_more);
  }
  function mergeNew(cur, list) {
    const ids = new Set(list.map((m) => m.id));
    return [...cur.filter((m) => !ids.has(m.id) && m.id > (list.length ? list[list.length - 1].id : 0)), ...list].sort((a, b) => a.id - b.id);
  }

  async function onScroll() {
    if (msgBox.scrollTop > 80 || loadingOlder || !S.hasMore.get(S.open)) return;
    const list = S.messages.get(S.open) || [];
    const first = list.find((m) => m.id > 0);
    if (!first) return;
    loadingOlder = true;
    const h = msgBox.scrollHeight;
    try {
      await loadMessages(S.open, first.id);
      renderMessages(false);
      msgBox.scrollTop = msgBox.scrollHeight - h;
    } catch (_) { /* */ }
    loadingOlder = false;
  }

  function nearBottom() {
    return !msgBox || msgBox.scrollHeight - msgBox.scrollTop - msgBox.clientHeight < 120;
  }

  let adNode = null;
  async function loadAd(chatId) {
    try {
      const r = await api('GET', `/chats/${chatId}/sponsored`);
      if (!r.ad || S.open !== chatId) return;
      const ad = r.ad;
      adNode = el('div', { class: 'ad' }, el('small', {}, `Sponsored · ${ad.advertiser}`), el('div', {}, ad.text),
        el('button', { class: 'btn', style: 'margin-top:8px;width:100%', onclick: async () => {
          const c = await api('POST', `/ads/${ad.id}/click`, {}).catch(() => ({ url: ad.url }));
          window.open(c.url || ad.url, '_blank', 'noopener');
        } }, ad.button_text));
      api('POST', `/ads/${ad.id}/view`, {}).catch(() => {});
      renderMessages(nearBottom());
    } catch (_) { /* */ }
  }

  function renderMessages(scrollToEnd) {
    const c = chatById(S.open);
    if (!c || !msgBox) return;
    const list = S.messages.get(S.open) || [];
    const nodes = [];
    if (S.hasMore.get(S.open)) nodes.push(el('div', { class: 'sys' }, 'Scroll up for older messages'));
    let lastDay = '';
    for (let i = 0; i < list.length; i++) {
      const m = list[i];
      const d = new Date(m.created_at);
      if (d.toDateString() !== lastDay) { lastDay = d.toDateString(); nodes.push(el('div', { class: 'day' }, dayLabel(d))); }
      if (m.type === 'system') { nodes.push(el('div', { class: 'sys' }, systemText(m))); continue; }
      if (m.album_id) {
        const group = [m];
        while (i + 1 < list.length && list[i + 1].album_id === m.album_id) group.push(list[++i]);
        nodes.push(bubble(c, group[group.length - 1], list[i - group.length], group));
        continue;
      }
      nodes.push(bubble(c, m, list[i - 1]));
    }
    if (adNode && c.type === 'channel') nodes.push(adNode);
    if (!list.length) nodes.push(el('div', { class: 'sys', style: 'margin:auto' }, c.is_bot ? 'Send /start to begin' : 'No messages here yet. Say hi! 👋'));
    msgBox.replaceChildren(...nodes);
    if (scrollToEnd) msgBox.scrollTop = msgBox.scrollHeight;
  }

  function isMine(c, m) {
    if (m.pending) return true;
    if (c.type === 'channel') return false;
    return auth.me && m.sender_id === auth.me.id;
  }

  function bubble(c, m, prev, album) {
    const mine = isMine(c, m);
    const showSender = c.type === 'group' && !mine && (!prev || prev.sender_id !== m.sender_id || prev.type === 'system');
    const body = [];
    if (c.type === 'channel' && !m.thread_id) body.push(el('div', { class: 'who', style: 'color:var(--accent-dark)' }, c.title));
    else if (showSender) body.push(el('div', { class: 'who', style: `color:${GRADS[(m.sender_id || 0) % GRADS.length][1]}` }, userName(m.sender)));
    if (m.forwarded_from) body.push(el('div', { class: 'fwd' }, `Forwarded from ${m.forwarded_from.name}`));
    if (m.reply_to) {
      body.push(el('div', { class: 'reply', onclick: () => scrollToMessage(m.reply_to.id) },
        el('b', {}, m.reply_to.sender_name || c.title), m.reply_to.deleted ? 'Deleted message' : (m.reply_to.text || m.reply_to.type)));
    }
    if (m.meta && m.meta.quote) {
      const q = m.meta.quote;
      body.push(el('div', { class: 'reply' }, el('b', {}, `↩ ${q.sender_name || ''}${q.chat_title ? ` · ${q.chat_title}` : ''}`), q.text || q.type || ''));
    }
    if (album) body.push(albumView(album));
    else body.push(...mediaView(m));
    const text = album ? album.map((x) => x.text).filter(Boolean).join('\n') : ['poll', 'location', 'call', 'sticker', 'contact'].includes(m.type) ? '' : m.text;
    const shown = text ? text.replace(/^(\s*)\[ \] /gm, '$1☐ ').replace(/^(\s*)\[[xX]\] /gm, '$1☑ ') : text;
    if (text) body.push(el('div', { class: `text${onlyTali(text) ? ' big-tali' : ''}` }, linkify(shown)));
    if (m.link_preview && m.type === 'text') {
      const lp = m.link_preview;
      const card = el('a', { class: 'lp', href: lp.url, target: '_blank', rel: 'noopener noreferrer' },
        lp.image ? el('img', { src: lp.image, alt: '', loading: 'lazy', referrerpolicy: 'no-referrer' }) : null,
        el('div', { class: 'lp-body' },
          lp.site ? el('b', {}, lp.site) : null,
          lp.title ? el('div', { class: 'lp-title' }, lp.title) : null,
          lp.description ? el('div', { class: 'lp-desc' }, lp.description) : null));
      body.push(card);
    }
    if (m.reactions && m.reactions.length) {
      body.push(el('div', { class: 'reacts' }, m.reactions.map((r) => el('span', { class: r.emoji === m.my_reaction ? 'mine' : '' }, `${r.emoji} ${r.count}`))));
    }
    if (m.reply_markup && m.reply_markup.inline_keyboard) body.push(keyboard(m));
    const ticks = mine && c.type !== 'channel' && !c.is_saved_messages
      ? el('span', { class: `ticks${m.id <= (c.read_up_to || 0) ? '' : ' gray'}` }, m.pending ? '🕓' : m.id <= (c.read_up_to || 0) || m.id <= (c.delivered_up_to || 0) ? '✓✓' : '✓')
      : null;
    body.push(el('div', { class: 'meta' },
      c.type === 'channel' && m.views ? `👁 ${m.views}` : null,
      m.author_signature ? `${m.author_signature} ·` : null,
      m.edited_at ? 'edited' : null,
      timeOf(m.created_at), ticks));
    if (c.type === 'channel' && c.comments_enabled && !m.thread_id) {
      body.push(el('div', { class: 'muted', style: 'font-size:12px;margin-top:4px' }, `💬 ${m.comments_count || 0} comments — open on your phone to reply`));
    }
    const b = el('div', { class: `bubble${m.pending ? ' pending' : ''}${m.type === 'sticker' || m.type === 'video_note' ? ' bare' : ''}`, 'data-id': m.id, oncontextmenu: (e) => messageMenu(e, c, m) }, body);
    return el('div', { class: `row${mine ? ' mine' : ''}` }, b);
  }

  // Talvio custom emoji: one Private Use Area character each (U+E900 + index)
  const TALI = ['hello', 'love', 'laugh', 'thanks', 'like', 'wow', 'cry', 'angry', 'sleepy', 'cool',
    'party', 'think', 'coffee', 'kiss', 'shy', 'starstruck', 'gift', 'please', 'busy', 'king'];
  const TALI_RE = /[\uE900-\uE9FF]/g;
  function withTali(text) {
    const out = [];
    let last = 0;
    for (const m of text.matchAll(TALI_RE)) {
      if (m.index > last) out.push(text.slice(last, m.index));
      const name = TALI[m[0].charCodeAt(0) - 0xE900];
      out.push(name ? el('img', { class: 'tali', src: `emoji/tali/${name}.png`, alt: '🦊', title: name }) : '🦊');
      last = m.index + m[0].length;
    }
    if (last < text.length) out.push(text.slice(last));
    return out;
  }
  const onlyTali = (t) => { const s = String(t || '').replace(/\s/g, ''); return s.length > 0 && s.length <= 3 && /^[\uE900-\uE9FF]+$/.test(s); };

  // **bold** _italic_ ~strike~ `code` ||spoiler||
  const FMT_RE = /\*\*([^\n]+?)\*\*|(?<![\w\\])_([^\n_]+?)_(?!\w)|(?<![\w~])~([^\n~]+?)~(?![\w~])|`([^`\n]+)`|\|\|([^\n]+?)\|\|/g;
  function formatted(text) {
    const out = [];
    let last = 0;
    for (const m of text.matchAll(FMT_RE)) {
      if (m.index > last) out.push(...linkifyPlain(text.slice(last, m.index)));
      if (m[1] !== undefined) out.push(el('b', {}, ...linkifyPlain(m[1])));
      else if (m[2] !== undefined) out.push(el('i', {}, ...linkifyPlain(m[2])));
      else if (m[3] !== undefined) out.push(el('s', {}, ...linkifyPlain(m[3])));
      else if (m[4] !== undefined) out.push(el('code', {}, m[4]));
      else {
        const sp = el('span', { class: 'spoiler', title: 'Tap to reveal' }, m[5]);
        sp.addEventListener('click', () => sp.classList.add('shown'));
        out.push(sp);
      }
      last = m.index + m[0].length;
    }
    if (last < text.length) out.push(...linkifyPlain(text.slice(last)));
    return out;
  }
  function linkify(text) {
    return formatted(text);
  }

  function linkifyPlain(text) {
    const out = [];
    const re = /(https?:\/\/[^\s<]+)/g;
    let last = 0;
    let mm;
    while ((mm = re.exec(text))) {
      if (mm.index > last) out.push(...withTali(text.slice(last, mm.index)));
      out.push(el('a', { href: mm[1], target: '_blank', rel: 'noopener noreferrer' }, mm[1]));
      last = mm.index + mm[1].length;
    }
    if (last < text.length) out.push(...withTali(text.slice(last)));
    return out;
  }

  function imageNode(url, cls) {
    const img = el('img', { class: cls || '', alt: 'Photo', loading: 'lazy' });
    mediaUrl(url).then((u) => { img.src = u; }).catch(() => { img.alt = 'Photo not available'; });
    img.addEventListener('click', () => {
      const v = el('div', { class: 'viewer', onclick: () => v.remove() }, el('img', { src: img.src, alt: '' }));
      document.body.append(v);
    });
    return img;
  }

  function albumView(group) {
    return el('div', { class: 'album media' }, group.map((x) => (x.media && x.type === 'image' ? imageNode(x.media.url) : el('div', {}, ...mediaView(x)))));
  }

  function mediaView(m) {
    const md = m.media;
    if (m.view_once) {
      const what = m.type === 'voice' ? 'Voice message' : m.type === 'video' ? 'Video' : 'Photo';
      return [el('div', { class: 'once' }, el('span', { class: 'once-ico' }, '1'), el('div', {}, el('b', {}, `${what} · view once`), el('div', { class: 'muted' }, 'Open it in the Talvio app')))];
    }
    switch (m.type) {
      case 'image':
        return md ? [el('div', { class: 'media' }, imageNode(md.url))] : [];
      case 'video': {
        const v = el('video', { controls: true, preload: 'none', style: 'max-width:100%' });
        const btn = el('button', { class: 'btn', onclick: async () => { btn.disabled = true; v.src = await mediaUrl(md.url); btn.remove(); v.play().catch(() => {}); } }, `▶ Play video${md && md.size ? ` (${fmtSize(md.size)})` : ''}`);
        return [el('div', { class: 'media' }, v, btn)];
      }
      case 'voice': {
        const a = el('audio', { controls: true, preload: 'none' });
        mediaUrl(md && md.url).then((u) => { a.src = u; }).catch(() => {});
        return [a];
      }
      case 'file':
        return [el('a', { class: 'file', href: '#', onclick: async (e) => {
          e.preventDefault();
          try {
            const u = await mediaUrl(md.url);
            el('a', { href: u, download: md.name || 'file' }).click();
          } catch (err) { toast(err.message); }
        } }, el('span', { class: 'ic' }, '📎'), el('span', {}, el('div', {}, md ? md.name : 'File'), el('div', { class: 'muted', style: 'font-size:12px' }, md ? fmtSize(md.size) : '')))];
      case 'poll': return [pollView(m)];
      case 'location': {
        const loc = (m.meta && m.meta.location) || {};
        const live = m.meta && m.meta.live;
        const on = live && !live.stopped && new Date(live.until) > new Date();
        const lat = Number(loc.lat).toFixed(5);
        const lng = Number(loc.lng).toFixed(5);
        return [el('a', { class: 'loc', href: `https://www.openstreetmap.org/?mlat=${lat}&mlon=${lng}#map=16/${lat}/${lng}`, target: '_blank', rel: 'noopener noreferrer' },
          el('span', { class: 'ic' }, '📍'),
          el('span', {},
            el('div', {}, live ? (on ? 'Live location' : 'Live location ended') : (loc.title || 'Location')),
            el('div', { class: 'muted', style: 'font-size:12px' }, on ? `Until ${timeOf(live.until)} · updated ${timeOf(live.updated_at)}` : `${lat}, ${lng}`)))];
      }
      case 'video_note': {
        const v = el('video', { class: 'vnote', preload: 'none', playsinline: true, loop: false });
        const wrap = el('div', { class: 'vnote-wrap', title: 'Play' }, v, el('span', { class: 'vnote-play' }, '▶'));
        wrap.addEventListener('click', async () => {
          if (!v.src) { try { v.src = await mediaUrl(md.url); } catch (e) { toast(e.message); return; } }
          if (v.paused) { v.play().catch(() => {}); wrap.classList.add('playing'); } else { v.pause(); wrap.classList.remove('playing'); }
        });
        v.addEventListener('ended', () => wrap.classList.remove('playing'));
        return [wrap];
      }
      case 'sticker': {
        if (!md) return [el('div', { class: 'sticker-emoji' }, (m.meta && m.meta.sticker && m.meta.sticker.emoji) || '🙂')];
        const img = el('img', { class: 'sticker', alt: (m.meta && m.meta.sticker && m.meta.sticker.emoji) || 'Sticker', loading: 'lazy' });
        mediaUrl(md.url).then((u) => { img.src = u; }).catch(() => {});
        return [img];
      }
      case 'gif': {
        const g = (m.meta && m.meta.gif) || {};
        if (g.mp4) return [el('div', { class: 'media' }, el('video', { class: 'gif', src: g.mp4, autoplay: true, loop: true, muted: true, playsinline: true }))];
        return [el('div', { class: 'media' }, el('img', { class: 'gif', src: g.url, alt: 'GIF', loading: 'lazy', referrerpolicy: 'no-referrer' }))];
      }
      case 'contact': {
        const ct = (m.meta && m.meta.contact) || {};
        return [el('div', { class: 'contact' },
          el('span', { class: 'ic' }, '👤'),
          el('span', {},
            el('div', { style: 'font-weight:700' }, ct.name || 'Contact'),
            ct.phone ? el('div', { class: 'muted', style: 'font-size:12px' }, ct.phone) : null,
            ct.email ? el('div', { class: 'muted', style: 'font-size:12px' }, ct.email) : null))];
      }
      case 'call': {
        const call = (m.meta && m.meta.call) || {};
        const missed = call.status === 'missed' || call.status === 'busy';
        return [el('div', {}, `${call.video ? '📹' : '📞'} ${missed ? 'Missed call' : call.status === 'declined' ? 'Declined call' : 'Call'}${call.duration_sec ? ` · ${dur(call.duration_sec)}` : ''}`)];
      }
      default: return [];
    }
  }

  function pollView(m) {
    const p = m.poll;
    if (!p) return el('div', {}, m.text);
    const total = p.options.reduce((s, o) => s + Number(o.votes), 0);
    const voted = p.my_votes && p.my_votes.length > 0;
    return el('div', { class: 'poll' },
      el('b', {}, p.question),
      el('div', { class: 'muted', style: 'font-size:12px' }, `${p.quiz ? 'Quiz' : p.anonymous ? 'Anonymous poll' : 'Poll'} · ${p.total_voters} votes${p.closed ? ' · closed' : ''}`),
      p.options.map((o, idx) => {
        const pct = total ? Math.round((Number(o.votes) / total) * 100) : 0;
        return el('div', { class: 'opt', onclick: async () => {
          if (voted || p.closed) return;
          try { await api('POST', `/messages/${m.id}/vote`, { options: [idx] }); } catch (e) { toast(e.message); }
        } },
        el('div', { style: 'display:flex;justify-content:space-between' }, el('span', {}, `${(p.my_votes || []).includes(idx) ? '✓ ' : ''}${o.text}`), voted || p.closed ? el('b', {}, `${pct}%`) : null),
        voted || p.closed ? el('div', { class: 'bar' }, el('i', { style: `width:${pct}%` })) : null);
      }));
  }

  function keyboard(m) {
    return el('div', { class: 'kb' }, m.reply_markup.inline_keyboard.map((row) => el('div', { class: 'kbrow' }, row.map((b) => el('button', { onclick: async () => {
      if (b.url) { window.open(b.url, '_blank', 'noopener'); return; }
      if (b.web_app) { toast('Open this mini app on your phone'); return; }
      try {
        const r = await api('POST', `/messages/${m.id}/callback`, { data: b.callback_data });
        pendingCallbacks.add(r.callback_query_id);
      } catch (e) { toast(e.message); }
    } }, b.text)))));
  }
  const pendingCallbacks = new Set();

  function scrollToMessage(id) {
    const n = msgBox && msgBox.querySelector(`[data-id="${id}"]`);
    if (n) { n.scrollIntoView({ block: 'center', behavior: 'smooth' }); n.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 700 }); }
  }

  // ------------------------------------------------------------------ context menu
  let menuEl = null;
  function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
  document.addEventListener('click', closeMenu);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeMenu(); const v = document.querySelector('.viewer'); if (v) v.remove(); } });
  function openMenu(e, items) {
    e.preventDefault();
    e.stopPropagation();
    closeMenu();
    menuEl = el('div', { class: 'menu' }, items.map(([label, fn, danger]) => el('button', { class: danger ? 'danger' : '', onclick: (ev) => { ev.stopPropagation(); closeMenu(); fn(); } }, label)));
    document.body.append(menuEl);
    const r = menuEl.getBoundingClientRect();
    menuEl.style.left = `${Math.min(e.clientX, window.innerWidth - r.width - 8)}px`;
    menuEl.style.top = `${Math.min(e.clientY, window.innerHeight - r.height - 8)}px`;
  }
  function messageMenu(e, c, m) {
    if (m.pending) return;
    const mine = isMine(c, m);
    const items = [];
    if (c.can_post !== false || c.type !== 'channel') items.push(['Reply', () => { S.reply = m; S.editing = null; renderComposer(); textarea.focus(); }]);
    if (m.text) items.push(['Copy text', () => navigator.clipboard.writeText(m.text).then(() => toast('Copied')).catch(() => {})]);
    if (mine && m.type === 'text' && !m.forwarded_from) items.push(['Edit', () => { S.editing = m; S.reply = null; renderComposer(); textarea.value = m.text; textarea.focus(); }]);
    items.push(['Delete for me', () => deleteMessages(c, [m.id], false), true]);
    if (mine || (c.type !== 'private' && ['owner', 'admin'].includes(c.my_role))) items.push(['Delete for everyone', () => deleteMessages(c, [m.id], true), true]);
    openMenu(e, items);
  }
  async function deleteMessages(c, ids, forEveryone) {
    try {
      await api('POST', `/chats/${c.id}/messages/delete`, { message_ids: ids, for_everyone: forEveryone });
      removeMessages(c.id, ids);
    } catch (err) { toast(err.message); }
  }

  // ------------------------------------------------------------------ composer
  function renderComposer() {
    const c = chatById(S.open);
    if (!c || !composerBox) return;
    if (c.type === 'channel' && !c.can_post) {
      composerBox.replaceChildren(el('div', { class: 'notice' }, c.is_muted ? 'Notifications are off for this channel' : 'Only admins can post here'));
      return;
    }
    if (c.is_suspended || (c.peer && (c.peer.deleted || c.peer.blocked))) {
      composerBox.replaceChildren(el('div', { class: 'notice' }, c.is_suspended ? 'This group was suspended' : c.peer.deleted ? 'This account was deleted' : 'You blocked this user'));
      return;
    }
    if (c.is_request) {
      const act = async (path, body) => {
        try {
          const r = await api('POST', `/chats/${c.id}/request/${path}`, body || {});
          if (path === 'accept') { upsertChat(r); renderComposer(); renderChatList(); } else {
            S.chats = S.chats.filter((x) => x.id !== c.id);
            S.open = null;
            mainPane.replaceChildren(el('div', { class: 'empty-main' }, 'Select a chat to start messaging'));
            renderChatList();
          }
        } catch (e) { toast(e.message); }
      };
      composerBox.replaceChildren(el('div', { class: 'notice request-bar' },
        el('div', {}, el('b', {}, `${c.title} is not in your contacts`), el('div', { class: 'muted' }, 'Accept to reply and get notifications from this chat.')),
        el('div', { class: 'req-actions' },
          el('button', { class: 'btn ghost danger', onclick: () => { if (confirm(`Block ${c.title} and report as spam?`)) act('decline', { block: true, report: true }); } }, 'Block'),
          el('button', { class: 'btn ghost', onclick: () => act('decline') }, 'Delete'),
          el('button', { class: 'btn', onclick: () => act('accept') }, 'Accept'))));
      return;
    }
    const fileInput = el('input', { type: 'file', multiple: true, class: 'hidden', onchange: () => { sendFiles([...fileInput.files]); fileInput.value = ''; } });
    textarea = el('textarea', { rows: 1, placeholder: c.slow_mode_sec && !['owner', 'admin'].includes(c.my_role) ? `Message (slow mode ${c.slow_mode_sec}s)` : 'Message', maxlength: 4096 });
    textarea.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendText(); }
    });
    textarea.addEventListener('input', () => {
      textarea.style.height = 'auto';
      textarea.style.height = `${Math.min(180, textarea.scrollHeight)}px`;
      sendTyping();
    });
    textarea.addEventListener('paste', (e) => {
      const files = [...(e.clipboardData ? e.clipboardData.files : [])];
      if (files.length) { e.preventDefault(); sendFiles(files); }
    });
    const bar = S.reply || S.editing
      ? el('div', { class: 'reply-bar' },
        el('b', { style: 'color:var(--accent-dark)' }, S.editing ? 'Edit message' : `Reply to ${userName(S.reply.sender) === 'Deleted Account' ? c.title : userName(S.reply.sender)}`),
        el('span', { class: 'muted', style: 'overflow:hidden;white-space:nowrap;text-overflow:ellipsis' }, preview(S.editing || S.reply)),
        el('button', { class: 'icon-btn x', title: 'Cancel', onclick: () => { S.reply = null; if (S.editing) textarea.value = ''; S.editing = null; renderComposer(); } }, '✕'))
      : null;
    composerBox.replaceChildren(el('div', { class: 'composer' },
      el('button', { class: 'send attach', title: 'Attach file', onclick: () => fileInput.click() }, svgIcon(ICONS.attach)),
      el('div', { class: 'box' }, bar, textarea),
      el('button', { class: 'send', title: 'Send', onclick: sendText }, svgIcon(ICONS.send)),
      fileInput));
    if (S.editing) textarea.value = S.editing.text;
  }

  let typingSentAt = 0;
  function sendTyping() {
    if (!S.connected || Date.now() - typingSentAt < 3000) return;
    typingSentAt = Date.now();
    S.socket.emit('typing', { chat_id: S.open });
  }

  async function sendRaw(chatId, body) {
    if (S.connected) {
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new ApiError(0, 'network', 'The server did not respond')), 20000);
        S.socket.emit('message:send', { chat_id: chatId, ...body }, (ack) => {
          clearTimeout(t);
          if (ack && ack.ok) resolve(ack.message);
          else reject(new ApiError(400, (ack && ack.error) || 'error', (ack && ack.message) || 'Could not send', ack));
        });
      });
    }
    return api('POST', `/chats/${chatId}/messages`, body);
  }

  async function sendText() {
    const c = chatById(S.open);
    const text = textarea.value.trim();
    if (!c || !text) return;
    if (S.editing) {
      const m = S.editing;
      S.editing = null;
      textarea.value = '';
      renderComposer();
      try {
        const updated = await api('PATCH', `/messages/${m.id}`, { text });
        replaceMessage(updated);
      } catch (e) { toast(e.message); }
      return;
    }
    const clientId = `w${Date.now()}${Math.random().toString(36).slice(2, 7)}`;
    const reply = S.reply;
    S.reply = null;
    textarea.value = '';
    textarea.style.height = 'auto';
    renderComposer();
    textarea.focus();
    const local = { id: -Date.now(), chat_id: c.id, type: 'text', text, pending: true, client_id: clientId, created_at: new Date().toISOString(), sender_id: auth.me.id, reactions: [] };
    pushMessage(c.id, local);
    try {
      const m = await sendRaw(c.id, { type: 'text', text, client_id: clientId, ...(reply ? { reply_to_id: reply.id } : {}) });
      replaceLocal(c.id, clientId, m);
    } catch (e) {
      removeLocal(c.id, clientId);
      toast(e.message);
      textarea.value = text;
    }
  }

  async function sendFiles(files) {
    const c = chatById(S.open);
    if (!c || !files.length) return;
    const images = files.filter((f) => /^image\/(jpeg|png|webp|gif)$/.test(f.type));
    const albumId = images.length > 1 && images.length === files.length ? crypto.randomUUID() : null;
    let done = 0;
    for (const f of files) {
      const kind = /^image\/(jpeg|png|webp|gif)$/.test(f.type) ? 'image' : f.type.startsWith('video/') ? 'video' : f.type.startsWith('audio/') ? 'voice' : 'file';
      const sendType = kind === 'voice' ? 'file' : kind;
      try {
        const m = await upload(f, kind === 'voice' ? 'file' : kind, (p) => { progressBar.style.width = `${((done + p) / files.length) * 100}%`; });
        const msg = await sendRaw(c.id, { type: sendType, media_id: m.id, client_id: `w${Date.now()}${done}`, ...(albumId && sendType === 'image' ? { album_id: albumId } : {}) });
        pushMessage(c.id, msg);
      } catch (e) {
        toast(`${f.name}: ${e.message}`);
      }
      done++;
    }
    progressBar.style.width = '0';
  }

  // ------------------------------------------------------------------ message store ops
  function pushMessage(chatId, m) {
    const list = S.messages.get(chatId);
    if (!list) return;
    if (m.id > 0 && list.some((x) => x.id === m.id)) return;
    if (m.client_id && list.some((x) => x.pending && x.client_id === m.client_id)) return replaceLocal(chatId, m.client_id, m);
    const stick = nearBottom();
    list.push(m);
    list.sort((a, b) => (a.pending ? Infinity : a.id) - (b.pending ? Infinity : b.id));
    if (chatId === S.open) renderMessages(stick);
    return undefined;
  }
  function replaceLocal(chatId, clientId, m) {
    const list = S.messages.get(chatId);
    if (!list) return;
    const i = list.findIndex((x) => x.pending && x.client_id === clientId);
    if (i >= 0) list.splice(i, 1);
    if (!list.some((x) => x.id === m.id)) list.push(m);
    list.sort((a, b) => (a.pending ? Infinity : a.id) - (b.pending ? Infinity : b.id));
    if (chatId === S.open) renderMessages(nearBottom());
  }
  function removeLocal(chatId, clientId) {
    const list = S.messages.get(chatId);
    if (!list) return;
    S.messages.set(chatId, list.filter((x) => !(x.pending && x.client_id === clientId)));
    if (chatId === S.open) renderMessages(false);
  }
  function replaceMessage(m) {
    const list = S.messages.get(m.chat_id);
    if (!list) return;
    const i = list.findIndex((x) => x.id === m.id);
    if (i >= 0) { list[i] = m; if (m.chat_id === S.open) renderMessages(false); }
  }
  function removeMessages(chatId, ids) {
    const list = S.messages.get(chatId);
    if (list) {
      S.messages.set(chatId, list.filter((x) => !ids.includes(x.id)));
      if (chatId === S.open) renderMessages(false);
    }
    refreshChat(chatId);
  }

  function markRead() {
    const c = chatById(S.open);
    if (!c || document.hidden) return;
    const list = S.messages.get(c.id) || [];
    const last = [...list].reverse().find((m) => m.id > 0);
    if (!last) return;
    if (c.unread_count || c.marked_unread) {
      c.unread_count = 0;
      c.unread_mentions = 0;
      if (S.connected) S.socket.emit('message:read', { chat_id: c.id, message_id: last.id });
      else api('POST', `/chats/${c.id}/read`, { message_id: last.id }).catch(() => {});
      renderChatList();
      updateTitle();
    }
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) markRead(); });
  window.addEventListener('focus', markRead);

  function typingText(c) {
    const t = S.typing.get(c.id);
    if (!t) return '';
    const now = Date.now();
    const who = Object.entries(t).filter(([, until]) => until > now).map(([id]) => S.users.get(Number(id)));
    if (!who.length) return '';
    const ACTIONS = { typing: 'typing', recording_voice: 'recording a voice message', recording_video: 'recording a video message', uploading_photo: 'sending a photo', uploading_video: 'sending a video', uploading_file: 'sending a file', choosing_sticker: 'choosing a sticker' };
    const firstId = Object.entries(t).find(([, until]) => until > now)[0];
    const what = ACTIONS[S.typingAction.get(`${c.id}:${firstId}`)] || 'typing';
    if (c.type === 'private') return `${what}…`;
    if (who.length === 1) return `${who[0] ? who[0].first_name : 'Someone'} is ${what}…`;
    return `${who.map((u) => (u ? u.first_name : 'Someone')).join(', ')} typing…`;
  }

  // ------------------------------------------------------------------ notifications
  function askNotifications() {
    if (!('Notification' in window)) return toast('Notifications are not supported in this browser');
    Notification.requestPermission().then((p) => toast(p === 'granted' ? 'Notifications on' : 'Notifications blocked'));
    return undefined;
  }
  function notify(c, m) {
    if (!('Notification' in window) || Notification.permission !== 'granted' || c.is_muted || c.is_request) return; // requests arrive silently
    if (!document.hidden && S.open === c.id) return;
    const n = new Notification(c.type === 'group' && m.sender ? `${userName(m.sender)} · ${c.title}` : c.title, { body: preview(m), tag: `chat-${c.id}`, silent: !!m.silent });
    n.onclick = () => { window.focus(); openChat(c.id); n.close(); };
  }

  // ------------------------------------------------------------------ realtime
  let pollTimer = null;
  function connectRealtime() {
    if (typeof window.io !== 'function') {
      // no Socket.IO client (e.g. behind a proxy that blocks it) → poll every 5 s
      if (!pollTimer) pollTimer = setInterval(poll, 5000);
      return;
    }
    const s = window.io(location.origin, { transports: ['websocket'], auth: (cb) => cb({ token: auth.access }), reconnection: true });
    S.socket = s;
    s.on('connect', () => { S.connected = true; loadChats(); if (S.open) loadMessages(S.open).then(() => renderMessages(nearBottom())).catch(() => {}); });
    s.on('disconnect', () => { S.connected = false; });
    s.on('connect_error', async (err) => {
      S.connected = false;
      const code = (err && err.message) || '';
      if (code === 'invalid_token' || code === 'unauthorized') {
        try { await refreshTokens(); s.connect(); } catch (_) { logout('Please log in again.'); }
      } else if (['session_revoked', 'account_banned', 'account_deleted'].includes(code)) logout('You were logged out.');
    });
    s.on('message:new', ({ chat_id: chatId, message: m }) => {
      if (m.thread_id) return;
      remember([m.sender].filter(Boolean));
      const c = chatById(chatId);
      if (!c) { refreshChat(chatId); return; }
      c.last_message = m;
      c.last_message_at = m.created_at;
      const mine = auth.me && m.sender_id === auth.me.id;
      if (mine && c.is_request) { c.is_request = false; if (S.open === chatId) renderComposer(); } // replied from another device
      if (!mine && m.type !== 'system') {
        if (S.open !== chatId || document.hidden) c.unread_count = (c.unread_count || 0) + 1;
        const t = S.typing.get(chatId);
        if (t) delete t[m.sender_id];
        notify(c, m);
        s.emit('message:delivered', { chat_id: chatId, message_id: m.id });
      }
      sortChats();
      renderChatList();
      updateTitle();
      pushMessage(chatId, m);
      if (S.open === chatId) markRead();
    });
    s.on('message:edited', ({ message }) => replaceMessage(message));
    s.on('message:deleted', ({ chat_id: chatId, message_ids: ids }) => removeMessages(chatId, ids));
    s.on('message:reactions', ({ chat_id: chatId, message_id: id, reactions, user_id: uid, emoji }) => {
      const m = (S.messages.get(chatId) || []).find((x) => x.id === id);
      if (!m) return;
      m.reactions = reactions;
      if (auth.me && uid === auth.me.id) m.my_reaction = emoji || null;
      if (chatId === S.open) renderMessages(false);
    });
    s.on('message:poll', ({ chat_id: chatId, message_id: id, poll }) => {
      const m = (S.messages.get(chatId) || []).find((x) => x.id === id);
      if (m && m.poll) { m.poll = { ...poll, my_votes: m.poll.my_votes }; if (chatId === S.open) renderMessages(false); }
      if (chatId === S.open) loadMessages(chatId).then(() => renderMessages(false)).catch(() => {});
    });
    s.on('receipt:read', ({ chat_id: chatId, message_id: id }) => {
      const c = chatById(chatId);
      if (c) { c.read_up_to = Math.max(c.read_up_to || 0, id); if (chatId === S.open) renderMessages(false); }
    });
    s.on('receipt:delivered', ({ chat_id: chatId, message_id: id }) => {
      const c = chatById(chatId);
      if (c) { c.delivered_up_to = Math.max(c.delivered_up_to || 0, id); if (chatId === S.open) renderMessages(false); }
    });
    s.on('typing', ({ chat_id: chatId, user_id: uid, action }) => {
      const t = S.typing.get(chatId) || {};
      if (action === 'cancel') delete t[uid]; else t[uid] = Date.now() + 6000;
      S.typingAction.set(`${chatId}:${uid}`, action || 'typing');
      S.typing.set(chatId, t);
      renderChatList();
      if (chatId === S.open) renderHeader();
      setTimeout(() => { renderChatList(); if (chatId === S.open) renderHeader(); }, 6200);
    });
    s.on('presence', ({ user_id: uid, online, last_seen: ls }) => {
      remember([{ id: uid, online, ...(ls ? { last_seen: ls } : {}) }]);
      for (const c of S.chats) if (c.peer && c.peer.id === uid) { c.peer.online = online; if (ls) c.peer.last_seen = ls; }
      if (S.open) renderHeader();
    });
    s.on('chat:updated', ({ chat_id: chatId }) => refreshChat(chatId));
    s.on('chat:removed', ({ chat_id: chatId }) => {
      S.chats = S.chats.filter((c) => c.id !== chatId);
      if (S.open === chatId) { S.open = null; mainPane.replaceChildren(el('div', { class: 'empty-main' }, 'Select a chat to start messaging')); }
      renderChatList();
    });
    s.on('user:updated', ({ user_id: uid }) => {
      for (const c of S.chats) if (c.peer && c.peer.id === uid) refreshChat(c.id);
    });
    s.on('bot:callback_answer', (a) => {
      if (!pendingCallbacks.has(a.callback_query_id)) return;
      pendingCallbacks.delete(a.callback_query_id);
      if (a.url) window.open(a.url, '_blank', 'noopener');
      if (a.text) { if (a.show_alert) window.alert(a.text); else toast(a.text); }
    });
    s.on('session:revoked', () => logout('This device was logged out.'));
  }

  async function poll() {
    if (!auth.access) return;
    const before = new Map(S.chats.map((c) => [c.id, c.last_message && c.last_message.id]));
    await loadChats();
    if (S.open) {
      const c = chatById(S.open);
      if (c && c.last_message && before.get(c.id) !== c.last_message.id) {
        await loadMessages(S.open).catch(() => {});
        renderMessages(nearBottom());
        markRead();
      }
    }
  }

  window.addEventListener('resize', () => { if (S.open) renderHeader(); });
  start();
})();
