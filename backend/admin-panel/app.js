/* Admin panel — dependency-free single page app. All user data is rendered with textContent (no innerHTML). */
(() => {
  'use strict';

  const PERMISSIONS = {
    super_admin: ['*'],
    moderator: ['dashboard', 'users.view', 'users.ban', 'users.logout', 'users.verify', 'reports', 'groups.view', 'groups.suspend', 'logs.view', 'media', 'support', 'users.export', 'calls.view', 'calls.manage'],
    support: ['dashboard', 'users.view', 'reports.view', 'groups.view', 'support', 'calls.view'],
  };
  const NAV = [
    { id: 'dashboard', label: 'Dashboard', perm: 'dashboard' },
    { id: 'users', label: 'Users', perm: 'users.view' },
    { id: 'reports', label: 'Reports', perm: 'reports.view' },
    { id: 'appeals', label: 'Ban appeals', perm: 'users.view' },
    { id: 'groups', label: 'Groups & channels', perm: 'groups.view' },
    { id: 'calls', label: 'Calls', perm: 'calls.view' },
    { id: 'bots', label: 'Bots', perm: 'users.view' },
    { id: 'revenue', label: 'Revenue', perm: 'payments' },
    { id: 'payments', label: 'Payments', perm: 'payments' },
    { id: 'plans', label: 'Premium plans', perm: 'payments' },
    { id: 'ads', label: 'Sponsored messages', perm: 'payments' },
    { id: 'support', label: 'Support', perm: 'support' },
    { id: 'broadcast', label: 'Broadcast', perm: 'broadcast' },
    { id: 'settings', label: 'Settings', perm: 'settings' },
    { id: 'pages', label: 'Pages & FAQ', perm: 'settings' },
    { id: 'admins', label: 'Admin team', perm: 'admins' },
    { id: 'logs', label: 'Activity log', perm: 'logs.view' },
  ];
  const REASONS = { spam: 'Spam', abuse: 'Abuse / harassment', scam: 'Scam / fraud', violence: 'Violence', sexual: 'Sexual content', illegal: 'Illegal', other: 'Other' };

  const state = {
    token: sessionStorage.getItem('adminToken'),
    admin: null,
    page: location.hash.slice(1) || 'dashboard',
    openReports: 0,
  };
  const root = document.getElementById('app');

  // ------------------------------------------------------------------ helpers
  function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'value') e.value = v;
      else if (k === 'checked') e.checked = !!v;
      else e.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat(Infinity)) {
      if (c === null || c === undefined || c === false) continue;
      e.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return e;
  }

  function svg(tag, attrs, ...children) {
    const e = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
    for (const c of children.flat()) e.append(c instanceof Node ? c : document.createTextNode(String(c)));
    return e;
  }

  function can(perm) {
    if (!state.admin) return false;
    const perms = PERMISSIONS[state.admin.role] || [];
    return perms.includes('*') || perms.includes(perm) || perms.includes(perm.split('.')[0]);
  }

  let toastTimer;
  function toast(message, isError) {
    const t = document.getElementById('toast');
    t.textContent = message;
    t.className = isError ? 'toast error' : 'toast';
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, 3500);
  }

  async function api(method, path, body) {
    const res = await fetch(`/api/admin${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data = null;
    try { data = await res.json(); } catch (_) { /* empty body */ }
    if (res.status === 401 && path !== '/login') {
      logout();
      throw new Error('Your session expired, please log in again');
    }
    if (!res.ok) {
      const err = new Error((data && data.error && data.error.message) || `Request failed (${res.status})`);
      err.code = data && data.error && data.error.code;
      if (err.code === 'two_factor_setup_required') setTimeout(() => securityModal(true), 0);
      throw err;
    }
    return data;
  }

  async function action(fn, okMessage) {
    try {
      const r = await fn();
      if (okMessage) toast(okMessage);
      return r;
    } catch (err) {
      toast(err.message, true);
      return undefined;
    }
  }

  const fmtDate = (d) => (d ? new Date(d).toLocaleString() : '—');
  const fmtNum = (n) => Number(n || 0).toLocaleString();
  function fmtBytes(b) {
    const n = Number(b || 0);
    if (n < 1024) return `${n} B`;
    const units = ['KB', 'MB', 'GB', 'TB'];
    let v = n / 1024;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return `${v.toFixed(1)} ${units[i]}`;
  }
  function ago(d) {
    if (!d) return 'never';
    const s = Math.round((Date.now() - new Date(d).getTime()) / 1000);
    if (s < 60) return 'just now';
    if (s < 3600) return `${Math.floor(s / 60)} min ago`;
    if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
    return `${Math.floor(s / 86400)} d ago`;
  }
  const fullName = (u) => [u.first_name, u.last_name].filter(Boolean).join(' ') || '(no name)';

  function statusChip(u) {
    if (u.status === 'active' && u.restricted_until && new Date(u.restricted_until) > new Date()) {
      return el('span', { class: 'chip warn' }, `Restricted until ${new Date(u.restricted_until).toLocaleString()}`);
    }
    if (u.status === 'banned') return el('span', { class: 'chip bad' }, u.banned_until ? `Banned until ${new Date(u.banned_until).toLocaleDateString()}` : 'Banned');
    if (u.status === 'deleted') return el('span', { class: 'chip' }, 'Deleted');
    return el('span', { class: 'chip ok' }, u.online ? 'Online' : 'Active');
  }

  function debounce(fn, ms) {
    let t;
    return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
  }

  function pager(data, onPage) {
    const pages = Math.max(1, Math.ceil(data.total / data.limit));
    return el('div', { class: 'pager' },
      `${fmtNum(data.total)} total · page ${data.page} of ${pages}`,
      el('button', { class: 'btn small', disabled: data.page <= 1, onclick: () => onPage(data.page - 1) }, '‹ Prev'),
      el('button', { class: 'btn small', disabled: data.page >= pages, onclick: () => onPage(data.page + 1) }, 'Next ›'));
  }

  function table(headers, rows, emptyText) {
    if (!rows.length) return el('div', { class: 'table-wrap' }, el('div', { class: 'empty' }, emptyText || 'Nothing here yet'));
    return el('div', { class: 'table-wrap' },
      el('table', {}, el('thead', {}, el('tr', {}, headers.map((h) => el('th', {}, h)))), el('tbody', {}, rows)));
  }

  // ------------------------------------------------------------------ overlays
  let drawerEls = [];
  function closeDrawer() { drawerEls.forEach((e) => e.remove()); drawerEls = []; }
  function openDrawer(content) {
    closeDrawer();
    const overlay = el('div', { class: 'overlay', onclick: closeDrawer });
    const drawer = el('div', { class: 'drawer', role: 'dialog' }, el('button', { class: 'btn small close', onclick: closeDrawer }, 'Close'), content);
    document.body.append(overlay, drawer);
    drawerEls = [overlay, drawer];
  }

  function modal(title, bodyNodes, confirmLabel, onConfirm, danger) {
    return new Promise((resolve) => {
      const overlay = el('div', { class: 'overlay top' });
      const close = (v) => { overlay.remove(); box.remove(); resolve(v); };
      const confirm = el('button', { class: danger ? 'btn danger' : 'btn primary' }, confirmLabel);
      confirm.addEventListener('click', async () => {
        confirm.disabled = true;
        const ok = await onConfirm();
        confirm.disabled = false;
        if (ok !== false) close(true);
      });
      const box = el('div', { class: 'modal', role: 'dialog' }, el('h3', {}, title), bodyNodes,
        el('div', { class: 'btn-row' }, confirm, el('button', { class: 'btn', onclick: () => close(false) }, 'Cancel')));
      overlay.addEventListener('click', () => close(false));
      document.body.append(overlay, box);
    });
  }

  function banModal(userId, defaultReason, onDone) {
    const reason = el('textarea', { placeholder: 'Reason (the user will see this)' }, defaultReason || '');
    const duration = el('select', {},
      el('option', { value: '24' }, '1 day'), el('option', { value: '168' }, '7 days'),
      el('option', { value: '720' }, '30 days'), el('option', { value: '' }, 'Permanent'));
    return modal('Ban user', [
      el('div', { class: 'field' }, el('label', {}, 'Reason'), reason),
      el('div', { class: 'field' }, el('label', {}, 'Duration'), duration),
    ], 'Ban user', async () => {
      if (!reason.value.trim()) { toast('Reason is required', true); return false; }
      const r = await action(() => api('POST', `/users/${userId}/ban`, {
        reason: reason.value.trim(), duration_hours: duration.value ? Number(duration.value) : null,
      }), 'User banned');
      if (r && onDone) onDone();
      return !!r;
    }, true);
  }

  async function mediaPreview(m) {
    try {
      const res = await fetch(m.admin_url, { headers: { Authorization: `Bearer ${state.token}` } });
      if (!res.ok) throw new Error();
      const url = URL.createObjectURL(await res.blob());
      if (m.mime.startsWith('image/')) return el('div', { class: 'preview-media' }, el('img', { src: url, alt: 'Reported image' }));
      if (m.mime.startsWith('video/')) return el('div', { class: 'preview-media' }, el('video', { src: url, controls: true }));
      if (m.mime.startsWith('audio/') || m.kind === 'voice') return el('audio', { src: url, controls: true });
      return el('a', { href: url, download: m.name || 'file' }, `Download ${m.name || 'file'} (${fmtBytes(m.size)})`);
    } catch (_) {
      return el('div', { class: 'muted' }, 'File is no longer available');
    }
  }

  // ------------------------------------------------------------------ login
  function renderLogin() {
    const email = el('input', { type: 'email', placeholder: 'admin@example.com', autocomplete: 'username', required: true });
    const password = el('input', { type: 'password', placeholder: 'Password', autocomplete: 'current-password', required: true });
    const code = el('input', { type: 'text', placeholder: '6-digit code or backup code', autocomplete: 'one-time-code', inputmode: 'numeric' });
    const codeField = el('div', { class: 'field', hidden: true }, el('label', {}, 'Authentication code'), code);
    const submit = el('button', { class: 'btn primary', type: 'submit' }, 'Log in');
    const form = el('form', { class: 'login' },
      el('h1', {}, 'Admin Panel'), el('p', {}, 'Sign in to manage users, reports and settings.'),
      el('div', { class: 'field' }, el('label', {}, 'Email'), email),
      el('div', { class: 'field' }, el('label', {}, 'Password'), password),
      codeField,
      submit);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      submit.disabled = true;
      let r;
      try {
        r = await api('POST', '/login', { email: email.value, password: password.value, code: code.value.trim() || undefined });
      } catch (err) {
        if (err.code === 'two_factor_required') {
          codeField.hidden = false;
          code.focus();
        } else toast(err.message, true);
      }
      submit.disabled = false;
      if (r) {
        state.token = r.token;
        state.admin = r.admin;
        sessionStorage.setItem('adminToken', r.token);
        render();
      }
    });
    root.replaceChildren(el('div', { class: 'login-wrap' }, form));
    email.focus();
  }

  function logout() {
    state.token = null;
    state.admin = null;
    sessionStorage.removeItem('adminToken');
    closeDrawer();
    renderLogin();
  }

  function changePassword() {
    const cur = el('input', { type: 'password', autocomplete: 'current-password' });
    const next = el('input', { type: 'password', autocomplete: 'new-password' });
    modal('Change password', [
      el('div', { class: 'field' }, el('label', {}, 'Current password'), cur),
      el('div', { class: 'field' }, el('label', {}, 'New password (min 10 characters)'), next),
    ], 'Change password', async () => {
      const r = await action(() => api('POST', '/me/password', { current_password: cur.value, new_password: next.value }));
      if (r) { toast('Password changed — please log in again'); logout(); }
      return !!r;
    });
  }

  let securityOpen = false;
  async function securityModal(forced) {
    if (securityOpen) return;
    securityOpen = true;
    try {
      const me = await api('GET', '/me');
      state.admin = me;
      if (me.two_factor) {
        const pw = el('input', { type: 'password', autocomplete: 'current-password' });
        const code = el('input', { type: 'text', inputmode: 'numeric', placeholder: '123456' });
        await modal('Two-factor authentication', [
          el('p', {}, el('span', { class: 'chip ok' }, 'On'), ' Your account asks for a code from your authenticator app at login.'),
          el('p', { class: 'muted' }, 'To turn it off, confirm your password and a current code.'),
          el('div', { class: 'field' }, el('label', {}, 'Password'), pw),
          el('div', { class: 'field' }, el('label', {}, 'Code'), code),
        ], 'Turn off 2FA', async () => !!(await action(() => api('POST', '/me/2fa/disable', { password: pw.value, code: code.value }), 'Two-factor authentication turned off')), true);
        return;
      }
      const setup = await action(() => api('POST', '/me/2fa/setup'));
      if (!setup) return;
      const code = el('input', { type: 'text', inputmode: 'numeric', placeholder: '123456', autocomplete: 'one-time-code' });
      let backup = null;
      await modal(forced ? 'Two-factor authentication is required' : 'Turn on two-factor authentication', [
        forced ? el('p', {}, 'The admin team requires 2FA. Set it up to continue.') : null,
        el('p', {}, '1. Open Google Authenticator, Microsoft Authenticator or Authy and choose “Enter a setup key”.'),
        el('div', { class: 'field' }, el('label', {}, 'Setup key'), el('input', { type: 'text', value: setup.secret, readonly: true, onclick: (e) => e.target.select() })),
        el('p', { class: 'muted', style: 'font-size:12px;word-break:break-all' }, setup.otpauth_url),
        el('p', {}, '2. Enter the 6-digit code the app shows.'),
        el('div', { class: 'field' }, code),
      ], 'Turn on', async () => {
        const r = await action(() => api('POST', '/me/2fa/enable', { code: code.value.trim() }), 'Two-factor authentication is on');
        if (r) backup = r.backup_codes;
        return !!r;
      });
      if (backup) {
        await modal('Save your backup codes', [
          el('p', {}, 'Each code works once if you lose your phone. Store them somewhere safe — they won’t be shown again.'),
          el('pre', { class: 'bubble', style: 'font-size:15px;letter-spacing:.05em' }, backup.join('\n')),
        ], 'I saved them', async () => true);
        if (forced) render();
      }
    } catch (err) {
      toast(err.message, true);
    } finally {
      securityOpen = false;
    }
  }

  // ------------------------------------------------------------------ layout
  let main;
  function renderLayout() {
    const allowed = NAV.filter((n) => can(n.perm));
    if (!allowed.some((n) => n.id === state.page)) state.page = allowed[0] ? allowed[0].id : 'dashboard';
    const side = el('nav', { class: 'side' },
      el('div', { class: 'brand' }, 'Chat Admin'),
      allowed.map((n) => el('button', {
        class: n.id === state.page ? 'active' : '',
        onclick: () => { state.page = n.id; location.hash = n.id; renderLayout(); },
      }, n.label, n.id === 'reports' && state.openReports ? el('span', { class: 'badge' }, state.openReports) : null)),
      el('div', { class: 'spacer' }),
      el('button', { onclick: () => securityModal(false) }, state.admin.two_factor ? 'Security (2FA on)' : 'Turn on 2FA'),
      el('button', { onclick: changePassword }, 'Change password'),
      el('button', { onclick: logout }, 'Log out'),
      el('div', { class: 'who' }, state.admin.name || state.admin.email, el('br'), state.admin.role.replace('_', ' ')));
    main = el('main', {});
    root.replaceChildren(el('div', { class: 'layout' }, side, main));
    PAGES[state.page]();
  }

  function head(title, ...right) {
    return el('div', { class: 'page-head' }, el('h2', {}, title), el('div', { class: 'btn-row' }, right));
  }

  // ------------------------------------------------------------------ dashboard
  function barChart(title, points) {
    const w = 600;
    const h = 180;
    const pad = 22;
    const max = Math.max(1, ...points.map((p) => Number(p.count)));
    const bw = (w - pad) / points.length;
    const bars = points.map((p, i) => {
      const bh = ((h - pad - 8) * Number(p.count)) / max;
      const rect = svg('rect', { class: 'bar', x: pad + i * bw + 1, y: h - pad - bh, width: Math.max(1, bw - 2), height: bh, rx: 2 });
      rect.append(svg('title', {}, `${p.day}: ${p.count}`));
      return rect;
    });
    const last = points.length - 1;
    const labels = [0, Math.floor(points.length / 2), last].map((i) => svg('text', {
      class: 'axis',
      x: i === 0 ? pad : i === last ? w : pad + i * bw + bw / 2,
      y: h - 6,
      'text-anchor': i === 0 ? 'start' : i === last ? 'end' : 'middle',
    }, points[i] ? points[i].day.slice(5) : ''));
    const maxLabel = svg('text', { class: 'axis', x: 0, y: 12 }, String(max));
    return el('div', { class: 'card chart' }, el('h3', {}, title),
      svg('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': title }, bars, labels, maxLabel));
  }

  async function pageDashboard() {
    main.replaceChildren(head('Dashboard', el('button', { class: 'btn', onclick: pageDashboard }, 'Refresh')), el('div', { class: 'muted' }, 'Loading…'));
    const d = await action(() => api('GET', '/dashboard'));
    if (!d) return;
    state.openReports = d.reports_open;
    const stat = (label, value) => el('div', { class: 'card stat' }, el('div', { class: 'label' }, label), el('div', { class: 'value' }, value));
    main.replaceChildren(
      head('Dashboard', el('button', { class: 'btn', onclick: pageDashboard }, 'Refresh')),
      el('div', { class: 'stats' },
        stat('Total users', fmtNum(d.users_total)),
        stat('Online now', fmtNum(d.online_now)),
        stat('Active (24h)', fmtNum(d.users_active_24h)),
        stat('Active (30d)', fmtNum(d.users_active_30d)),
        stat('Signups today', fmtNum(d.users_new_today)),
        stat('Signups (7 days)', fmtNum(d.users_new_7d)),
        stat('Messages today', fmtNum(d.messages_today)),
        stat('Calls today', fmtNum(d.calls_today)),
        stat('Calls right now', fmtNum(d.calls_active)),
        stat('Secret chats', fmtNum(d.secret_chats_active)),
        stat('Premium users', fmtNum(d.premium_users)),
        stat('Revenue this month', `Rs ${fmtNum(d.revenue_month_pkr)}`),
        stat('Payments to review', fmtNum(d.payments_to_review)),
        stat('Bots', fmtNum(d.bots_total)),
        stat('Secret messages today', fmtNum(d.secret_messages_today)),
        stat('Total messages', fmtNum(d.messages_total)),
        stat('Groups', fmtNum(d.groups_total)),
        stat('Channels', fmtNum(d.channels_total)),
        stat('Open tickets', fmtNum(d.tickets_open)),
        stat('Pending appeals', fmtNum(d.appeals_pending)),
        stat('Restricted users', fmtNum(d.users_restricted)),
        stat('Active stories', fmtNum(d.stories_active)),
        stat('Private chats', fmtNum(d.private_chats_total)),
        stat('Open reports', fmtNum(d.reports_open)),
        stat('Banned users', fmtNum(d.users_banned)),
        stat('Storage used', fmtBytes(d.storage_bytes))),
      el('div', { class: 'charts' }, barChart('New signups — last 30 days', d.signups_30d), barChart('Messages — last 14 days', d.messages_14d)));
  }

  // ------------------------------------------------------------------ users
  const usersState = { q: '', status: 'all', page: 1 };
  async function pageUsers() {
    const search = el('input', { type: 'text', placeholder: 'Search name, @username, phone or ID', value: usersState.q, style: 'flex:1;min-width:220px' });
    const status = el('select', {},
      ['all', 'active', 'restricted', 'banned', 'deleted'].map((s) => el('option', { value: s, selected: usersState.status === s ? true : null }, s[0].toUpperCase() + s.slice(1))));
    const listBox = el('div', {});
    main.replaceChildren(head('Users'), el('div', { class: 'toolbar' }, search, status), listBox);

    async function load() {
      const q = new URLSearchParams({ q: usersState.q, status: usersState.status, page: usersState.page });
      const data = await action(() => api('GET', `/users?${q}`));
      if (!data) return;
      const rows = data.users.map((u) => el('tr', { class: 'clickable', onclick: () => openUser(u.id, load) },
        el('td', { class: 'num' }, u.id),
        el('td', {}, fullName(u), u.is_verified ? el('span', { class: 'chip info', style: 'margin-left:6px' }, 'Verified') : null),
        el('td', {}, u.username ? `@${u.username}` : el('span', { class: 'muted' }, '—')),
        el('td', { class: 'num' }, u.phone),
        el('td', {}, statusChip(u)),
        el('td', { class: 'muted' }, u.online ? 'online' : ago(u.last_seen_at)),
        el('td', { class: 'muted' }, new Date(u.created_at).toLocaleDateString())));
      listBox.replaceChildren(
        table(['ID', 'Name', 'Username', 'Phone', 'Status', 'Last seen', 'Joined'], rows, 'No users match'),
        pager(data, (p) => { usersState.page = p; load(); }));
    }
    search.addEventListener('input', debounce(() => { usersState.q = search.value.trim(); usersState.page = 1; load(); }, 300));
    status.addEventListener('change', () => { usersState.status = status.value; usersState.page = 1; load(); });
    load();
  }

  async function openUser(id, refreshList) {
    const d = await action(() => api('GET', `/users/${id}`));
    if (!d) return;
    const u = d.user;
    const reload = () => { openUser(id, refreshList); if (refreshList) refreshList(); };
    const actions = [];
    if (u.status !== 'deleted') {
      if (can('users.ban')) {
        actions.push(u.status === 'banned'
          ? el('button', { class: 'btn', onclick: async () => { if (await action(() => api('POST', `/users/${id}/unban`), 'User unbanned')) reload(); } }, 'Unban')
          : el('button', { class: 'btn danger', onclick: () => banModal(id, '', reload) }, 'Ban'));
      }
      if (can('users.ban') && u.status === 'active') {
        const restricted = u.restricted_until && new Date(u.restricted_until) > new Date();
        actions.push(restricted
          ? el('button', { class: 'btn', onclick: async () => { if (await action(() => api('POST', `/users/${id}/unrestrict`), 'Restriction lifted')) reload(); } }, 'Lift restriction')
          : el('button', {
            class: 'btn',
            onclick: () => {
              const minutes = el('select', {}, el('option', { value: '60' }, '1 hour'), el('option', { value: '1440' }, '1 day'), el('option', { value: '10080' }, '7 days'));
              const reason = el('input', { type: 'text', placeholder: 'Reason (shown to the user)' });
              modal('Restrict user', [el('p', { class: 'muted' }, 'The user can read but cannot send messages until the time ends.'),
                el('div', { class: 'field' }, el('label', {}, 'Duration'), minutes), el('div', { class: 'field' }, el('label', {}, 'Reason'), reason)],
              'Restrict', async () => {
                const r = await action(() => api('POST', `/users/${id}/restrict`, { minutes: Number(minutes.value), reason: reason.value }), 'User restricted');
                if (r) reload();
                return !!r;
              }, true);
            },
          }, 'Restrict (mute)'));
      }
      if (can('users.logout')) {
        actions.push(el('button', { class: 'btn', onclick: async () => { if (await action(() => api('POST', `/users/${id}/logout-all`), 'Logged out from all devices')) reload(); } }, 'Log out all devices'));
      }
      if (can('users.verify')) {
        actions.push(el('button', { class: 'btn', onclick: async () => { if (await action(() => api('POST', `/users/${id}/verify`, { verified: !u.is_verified }), u.is_verified ? 'Badge removed' : 'Verified badge added')) reload(); } }, u.is_verified ? 'Remove verified badge' : 'Give verified badge'));
      }
      if (can('payments') && !u.is_bot && u.status === 'active') {
        const premium = u.premium_until && new Date(u.premium_until) > new Date();
        actions.push(el('button', {
          class: 'btn',
          onclick: () => {
            const months = el('select', {}, [1, 3, 6, 12].map((m) => el('option', { value: m }, `${m} month${m > 1 ? 's' : ''}`)));
            modal(premium ? 'Extend Premium' : 'Give Premium', [el('div', { class: 'field' }, el('label', {}, 'Length'), months)], 'Give', async () => {
              const r = await action(() => api('POST', `/users/${id}/premium`, { months: Number(months.value) }), 'Premium given');
              if (r) reload();
              return !!r;
            });
          },
        }, premium ? 'Extend Premium' : 'Give Premium'));
        if (premium) {
          actions.push(el('button', {
            class: 'btn',
            onclick: async () => { if (await action(() => api('POST', `/users/${id}/premium`, { months: 0 }), 'Premium removed')) reload(); },
          }, 'Remove Premium'));
        }
      }
      if (can('users.export')) {
        actions.push(el('button', {
          class: 'btn',
          onclick: async () => {
            const data = await action(() => api('GET', `/users/${id}/export`), 'Export ready');
            if (!data) return;
            const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
            el('a', { href: url, download: `user-${id}-data.json` }).click();
            setTimeout(() => URL.revokeObjectURL(url), 5000);
          },
        }, 'Export data'));
      }
      if (can('users.username')) {
        actions.push(el('button', {
          class: 'btn',
          onclick: () => {
            const input = el('input', { type: 'text', value: u.username || '', placeholder: 'username (empty = remove)' });
            modal('Set username', [el('p', { class: 'muted' }, 'Admins can assign reserved usernames such as “support”.'), el('div', { class: 'field' }, input)], 'Save', async () => {
              const r = await action(() => api('PUT', `/users/${id}/username`, { username: input.value.trim().replace(/^@/, '') || null }), 'Username updated');
              if (r) reload();
              return !!r;
            });
          },
        }, 'Set username'));
      }
      if (can('users.delete')) {
        actions.push(el('button', {
          class: 'btn danger',
          onclick: () => {
            const confirmInput = el('input', { type: 'text', placeholder: 'Type DELETE' });
            modal('Delete account', [el('p', {}, 'This removes the profile, frees the phone number and removes the user from all groups. Messages stay as "Deleted Account".'), confirmInput], 'Delete account', async () => {
              if (confirmInput.value !== 'DELETE') { toast('Type DELETE to confirm', true); return false; }
              const r = await action(() => api('DELETE', `/users/${id}`), 'Account deleted');
              if (r) reload();
              return !!r;
            }, true);
          },
        }, 'Delete account'));
      }
    }
    openDrawer([
      el('div', { style: 'display:flex;gap:14px;align-items:center' },
        u.avatar_url ? el('img', { class: 'avatar', src: u.avatar_url, alt: '' }) : el('div', { class: 'avatar' }),
        el('div', {}, el('h3', {}, fullName(u)), el('div', { class: 'muted' }, u.username ? `@${u.username}` : 'no username', ' · ID ', u.id), statusChip(u))),
      el('section', {}, el('div', { class: 'btn-row' }, actions)),
      el('section', {}, el('h4', {}, 'Profile'), el('div', { class: 'kv' },
        el('div', {}, 'Phone'), el('div', {}, u.phone),
        el('div', {}, 'Bio'), el('div', {}, u.bio || '—'),
        el('div', {}, 'Joined'), el('div', {}, fmtDate(u.created_at)),
        el('div', {}, 'Last seen'), el('div', {}, u.online ? 'Online now' : fmtDate(u.last_seen_at)),
        u.status === 'banned' ? [el('div', {}, 'Ban reason'), el('div', {}, u.ban_reason || '—')] : null,
        u.restricted_until && new Date(u.restricted_until) > new Date()
          ? [el('div', {}, 'Restricted'), el('div', {}, `until ${fmtDate(u.restricted_until)} — ${u.restrict_reason || ''}`)]
          : null)),
      el('section', {}, el('h4', {}, 'Activity'), el('div', { class: 'kv' },
        el('div', {}, 'Messages sent'), el('div', {}, fmtNum(d.stats.messages_sent)),
        el('div', {}, 'Calls'), el('div', {}, fmtNum(d.stats.calls || 0)),
        el('div', {}, 'Groups'), el('div', {}, fmtNum(d.stats.groups)),
        el('div', {}, 'Blocked by'), el('div', {}, `${fmtNum(d.stats.blocked_by_count)} users`),
        el('div', {}, 'Reports against'), el('div', {}, fmtNum(d.stats.reports_against)))),
      el('section', {}, el('h4', {}, `Active devices (${d.sessions.length})`),
        d.sessions.length ? d.sessions.map((s) => el('div', { class: 'bubble' },
          el('small', {}, [s.platform || 'unknown', s.app_version ? `v${s.app_version}` : null, `IP ${s.ip || '—'}`].filter(Boolean).join(' · ')),
          `${s.device_name || 'Unknown device'} — last active ${ago(s.last_active_at)}`)) : el('div', { class: 'muted' }, 'No active devices')),
      el('section', {}, el('h4', {}, 'Moderator notes'),
        (() => {
          const input = el('textarea', { rows: 2, placeholder: 'Private note for the admin team…' });
          const add = el('button', { class: 'btn small', onclick: async () => {
            if (!input.value.trim()) return;
            if (await action(() => api('POST', `/users/${id}/notes`, { text: input.value.trim() }), 'Note added')) reload();
          } }, 'Add note');
          return el('div', {}, el('div', { class: 'field' }, input), add);
        })(),
        d.notes.map((n) => el('div', { class: 'bubble', style: 'margin-top:6px' },
          el('small', {}, `${n.admin_name || 'Admin'} · ${fmtDate(n.created_at)} · `,
            el('a', { href: '#', onclick: async (e) => { e.preventDefault(); if (await action(() => api('DELETE', `/notes/${n.id}`), 'Note deleted')) reload(); } }, 'delete')),
          n.text))),
      d.appeals.length ? el('section', {}, el('h4', {}, 'Ban appeals'),
        d.appeals.map((a) => el('div', { class: 'bubble' }, el('small', {}, `${a.status} · ${fmtDate(a.created_at)}`), a.message,
          a.admin_reply ? el('div', { class: 'muted' }, `Reply: ${a.admin_reply}`) : null))) : null,
      el('section', {}, el('h4', {}, 'Admin history'),
        d.logs.length ? d.logs.map((l) => el('div', { class: 'bubble' },
          el('small', {}, `${fmtDate(l.created_at)} · ${l.admin_name || l.admin_email || 'system'}`),
          l.action, l.details && l.details.reason ? ` — ${l.details.reason}` : '')) : el('div', { class: 'muted' }, 'No admin actions yet')),
    ]);
  }

  // ------------------------------------------------------------------ reports
  const reportsState = { status: 'open', page: 1 };
  function reportSummary(r) {
    const s = r.snapshot || {};
    if (r.target_type === 'message' && s.message) return s.message.text || `[${s.message.type}]`;
    if (r.target_type === 'user' && s.user) return `${fullName(s.user)}${s.user.username ? ` (@${s.user.username})` : ''}`;
    if (r.target_type === 'chat' && s.chat) return s.chat.title || `Chat #${r.target_id}`;
    return `#${r.target_id}`;
  }

  async function pageReports() {
    const tabs = el('div', { class: 'tabs' }, ['open', 'resolved', 'dismissed', 'all'].map((s) => el('button', {
      class: reportsState.status === s ? 'active' : '',
      onclick: () => { reportsState.status = s; reportsState.page = 1; pageReports(); },
    }, s[0].toUpperCase() + s.slice(1))));
    const listBox = el('div', {}, el('div', { class: 'muted' }, 'Loading…'));
    main.replaceChildren(head('Reports'), tabs, listBox);
    const q = new URLSearchParams({ status: reportsState.status, page: reportsState.page });
    const data = await action(() => api('GET', `/reports?${q}`));
    if (!data) return;
    if (reportsState.status === 'open') { state.openReports = data.total; }
    const rows = data.reports.map((r) => el('tr', { class: 'clickable', onclick: () => openReport(r.id) },
      el('td', { class: 'num' }, r.id),
      el('td', {}, el('span', { class: 'chip warn' }, REASONS[r.reason] || r.reason), r.source === 'auto' ? el('span', { class: 'chip info', style: 'margin-left:4px' }, 'Auto') : null),
      el('td', {}, r.target_type),
      el('td', { style: 'max-width:340px' }, reportSummary(r).slice(0, 140)),
      el('td', {}, r.open_reports_on_target > 1 ? el('span', { class: 'chip bad' }, `${r.open_reports_on_target} reports`) : '1'),
      el('td', {}, r.source === 'auto' ? 'System' : (r.reporter_first_name || (r.reporter_username ? `@${r.reporter_username}` : '—'))),
      el('td', {}, r.status === 'open' ? el('span', { class: 'chip warn' }, 'Open') : el('span', { class: 'chip ok' }, `${r.status} · ${r.action_taken || ''}`)),
      el('td', { class: 'muted' }, ago(r.created_at))));
    listBox.replaceChildren(
      table(['#', 'Reason', 'Type', 'Content', 'Count', 'Reporter', 'Status', 'When'], rows, 'No reports here 🎉'),
      pager(data, (p) => { reportsState.page = p; pageReports(); }));
  }

  async function openReport(id) {
    const d = await action(() => api('GET', `/reports/${id}`));
    if (!d) return;
    const r = d.report;
    const s = r.snapshot || {};
    const done = () => { closeDrawer(); pageReports(); };
    const note = el('textarea', { placeholder: 'Internal note (optional)' });
    const banHours = el('select', {},
      el('option', { value: '24' }, 'Ban 1 day'), el('option', { value: '168' }, 'Ban 7 days'),
      el('option', { value: '720' }, 'Ban 30 days'), el('option', { value: '' }, 'Ban permanently'));
    const resolve = (act, label) => el('button', {
      class: act === 'dismiss' ? 'btn' : 'btn danger',
      onclick: async () => {
        const body = { action: act, note: note.value || undefined };
        if (act.includes('ban')) body.ban_hours = banHours.value ? Number(banHours.value) : null;
        if (await action(() => api('POST', `/reports/${id}/resolve`, body), 'Report handled')) done();
      },
    }, label);

    let evidence;
    if (r.target_type === 'message' && s.message) {
      evidence = [
        (s.context || []).map((m) => el('div', { class: m.id === s.message.id ? 'bubble hl' : 'bubble' },
          el('small', {}, `User #${m.sender_id} · ${fmtDate(m.created_at)}`), m.text || `[${m.type}]`)),
        d.media ? await mediaPreview(d.media) : null,
        d.target ? el('div', { class: 'kv', style: 'margin-top:10px' },
          el('div', {}, 'Sender'), el('div', {}, `${d.target.sender_first_name || ''} ${d.target.sender_username ? `@${d.target.sender_username}` : ''} (#${d.target.sender_id})`),
          el('div', {}, 'Message now'), el('div', {}, d.target.deleted_at ? 'Deleted' : 'Still visible')) : null,
      ];
    } else if (r.target_type === 'user' && s.user) {
      evidence = el('div', { class: 'kv' },
        el('div', {}, 'User'), el('div', {}, `${fullName(s.user)} (#${s.user.id})`),
        el('div', {}, 'Username'), el('div', {}, s.user.username ? `@${s.user.username}` : '—'),
        el('div', {}, 'Bio'), el('div', {}, s.user.bio || '—'),
        el('div', {}, 'Status now'), el('div', {}, d.target ? d.target.status : 'unknown'));
    } else {
      evidence = el('div', { class: 'kv' },
        el('div', {}, 'Group'), el('div', {}, (s.chat && s.chat.title) || `#${r.target_id}`),
        el('div', {}, 'Members'), el('div', {}, d.target ? fmtNum(d.target.member_count) : '—'),
        el('div', {}, 'Suspended'), el('div', {}, d.target && d.target.is_suspended ? 'Yes' : 'No'));
    }

    const canResolve = r.status === 'open' && can('reports.resolve');
    const buttons = [resolve('dismiss', 'Dismiss')];
    if (r.target_type === 'message') buttons.push(resolve('delete_message', 'Delete message'), resolve('delete_message_and_ban', 'Delete + ban sender'));
    if (r.target_type !== 'chat') buttons.push(resolve('restrict_user', 'Restrict 1 day'), resolve('ban_user', 'Ban user'));
    if (r.target_type === 'chat') buttons.push(resolve('suspend_chat', 'Suspend group/channel'));
    buttons.push(resolve('warn_only', 'Mark handled'));

    openDrawer([
      el('h3', {}, `Report #${r.id} — ${REASONS[r.reason] || r.reason}`),
      el('div', { class: 'muted' }, `${r.target_type} #${r.target_id} · reported ${fmtDate(r.created_at)} by ${r.source === 'auto' ? 'automatic moderation' : `${r.reporter_first_name || ''} ${r.reporter_username ? `@${r.reporter_username}` : ''}`}`),
      r.details ? el('section', {}, el('h4', {}, 'Reporter says'), el('div', { class: 'bubble' }, r.details)) : null,
      el('section', {}, el('h4', {}, 'Evidence (saved when reported)'), evidence),
      canResolve
        ? el('section', {}, el('h4', {}, 'Action'), el('div', { class: 'field' }, banHours), el('div', { class: 'field' }, note), el('div', { class: 'btn-row' }, buttons))
        : el('section', {}, el('h4', {}, 'Outcome'), el('div', { class: 'kv' },
          el('div', {}, 'Status'), el('div', {}, r.status),
          el('div', {}, 'Action'), el('div', {}, r.action_taken || '—'),
          el('div', {}, 'By'), el('div', {}, r.resolved_by_name || '—'),
          el('div', {}, 'Note'), el('div', {}, r.admin_note || '—'),
          el('div', {}, 'When'), el('div', {}, fmtDate(r.resolved_at)))),
    ]);
  }

  // ------------------------------------------------------------------ groups
  const groupsState = { q: '', status: 'all', type: 'all', page: 1 };
  async function pageGroups() {
    const search = el('input', { type: 'text', placeholder: 'Search title or @username', value: groupsState.q, style: 'flex:1;min-width:220px' });
    const type = el('select', {}, [['all', 'Groups & channels'], ['group', 'Groups'], ['channel', 'Channels']]
      .map(([v, l]) => el('option', { value: v, selected: groupsState.type === v ? true : null }, l)));
    const status = el('select', {}, el('option', { value: 'all' }, 'Any status'), el('option', { value: 'suspended', selected: groupsState.status === 'suspended' ? true : null }, 'Suspended'));
    const listBox = el('div', {});
    main.replaceChildren(head('Groups & channels'), el('div', { class: 'toolbar' }, search, type, status), listBox);

    async function load() {
      const q = new URLSearchParams({ q: groupsState.q, status: groupsState.status, type: groupsState.type, page: groupsState.page });
      const data = await action(() => api('GET', `/groups?${q}`));
      if (!data) return;
      const rows = data.groups.map((g) => {
        const acts = [];
        if (can('groups.suspend')) {
          acts.push(g.is_suspended
            ? el('button', { class: 'btn small', onclick: async () => { if (await action(() => api('POST', `/groups/${g.id}/unsuspend`), 'Group restored')) load(); } }, 'Unsuspend')
            : el('button', {
              class: 'btn small danger',
              onclick: () => {
                const reason = el('input', { type: 'text', placeholder: 'Reason' });
                modal(`Suspend “${g.title}”?`, [el('p', {}, 'Members can still read old messages but nobody can post.'), el('div', { class: 'field' }, reason)], 'Suspend', async () => {
                  const r = await action(() => api('POST', `/groups/${g.id}/suspend`, { reason: reason.value }), 'Group suspended');
                  if (r) load();
                  return !!r;
                }, true);
              },
            }, 'Suspend'));
        }
        if (can('groups.transfer')) {
          acts.push(el('button', {
            class: 'btn small',
            onclick: async () => {
              const members = await action(() => api('GET', `/groups/${g.id}/members?limit=500`));
              if (!members) return;
              if (!members.some((m) => m.role !== 'owner')) {
                toast('Nobody else is in this group yet', true);
                return;
              }
              const sel = el('select', {}, members.filter((m) => m.role !== 'owner').map((m) => el('option', { value: m.id },
                `${`${m.first_name || ''} ${m.last_name || ''}`.trim() || 'User'} ${m.username ? `@${m.username}` : ''} (#${m.id}) — ${m.role}`)));
              modal(`Transfer “${g.title}”`, [el('p', { class: 'muted' }, 'Use this for ownership disputes. The current owner becomes an admin.'),
                el('div', { class: 'field' }, el('label', {}, 'New owner'), sel)], 'Transfer', async () => {
                const r = await action(() => api('POST', `/groups/${g.id}/transfer`, { user_id: Number(sel.value) }), 'Ownership transferred');
                if (r) load();
                return !!r;
              }, true);
            },
          }, 'Transfer owner'));
        }
        if (can('groups.verify')) {
          acts.push(el('button', {
            class: 'btn small',
            onclick: async () => { if (await action(() => api('POST', `/groups/${g.id}/verify`, { verified: !g.is_verified }), g.is_verified ? 'Badge removed' : 'Verified badge added')) load(); },
          }, g.is_verified ? 'Unverify' : 'Verify'));
        }
        if (can('groups.delete')) {
          acts.push(el('button', {
            class: 'btn small danger',
            onclick: () => modal(`Delete “${g.title}”?`, [el('p', {}, 'The group and all its messages are deleted for everyone. This cannot be undone.')], 'Delete group', async () => {
              const r = await action(() => api('DELETE', `/groups/${g.id}`), 'Group deleted');
              if (r) load();
              return !!r;
            }, true),
          }, 'Delete'));
        }
        return el('tr', {},
          el('td', { class: 'num' }, g.id),
          el('td', {}, g.title,
            g.is_verified ? el('span', { class: 'chip info', style: 'margin-left:6px' }, 'Verified') : null,
            g.is_suspended ? el('span', { class: 'chip bad', style: 'margin-left:6px' }, 'Suspended') : null,
            g.username ? el('div', { class: 'muted' }, `@${g.username}`) : null),
          el('td', {}, el('span', { class: 'chip' }, g.type)),
          el('td', { class: 'num' }, fmtNum(g.member_count)),
          el('td', {}, g.owner_id ? `${g.owner_first_name || ''} ${g.owner_username ? `@${g.owner_username}` : ''} (#${g.owner_id})` : '—'),
          el('td', { class: 'muted' }, ago(g.last_message_at)),
          el('td', { class: 'muted' }, new Date(g.created_at).toLocaleDateString()),
          el('td', {}, el('div', { class: 'btn-row' }, acts)));
      });
      listBox.replaceChildren(
        table(['ID', 'Title', 'Type', 'Members', 'Owner', 'Last activity', 'Created', ''], rows, 'Nothing found'),
        pager(data, (p) => { groupsState.page = p; load(); }));
    }
    search.addEventListener('input', debounce(() => { groupsState.q = search.value.trim(); groupsState.page = 1; load(); }, 300));
    status.addEventListener('change', () => { groupsState.status = status.value; groupsState.page = 1; load(); });
    type.addEventListener('change', () => { groupsState.type = type.value; groupsState.page = 1; load(); });
    load();
  }

  // ------------------------------------------------------------------ settings
  const SETTING_LABELS = {
    registration_open: ['New registrations open', 'Turn off to stop new phone numbers from signing up.'],
    maintenance_mode: ['Maintenance mode', 'The app shows the maintenance message and stops working until turned off.'],
    maintenance_message: ['Maintenance message', ''],
    max_group_members: ['Max members per group', ''],
    max_upload_mb: ['Max upload size (MB)', 'Also limited by your server / Nginx upload limit.'],
    message_edit_window_hours: ['Edit window (hours)', '0 = messages can always be edited.'],
    min_app_version: ['Minimum app version', 'Older apps are asked to update.'],
    latest_app_version: ['Latest app version', 'Apps below this see an optional update notice.'],
    support_username: ['Support username', 'Shown in the app for help (without @).'],
    banned_words: ['Banned words & phrases', 'One per line. Matches whole words, any case (Urdu works too).'],
    banned_words_action: ['When a banned word is used', '“Block” stops the message. “Flag” sends it but opens an automatic report.'],
    new_account_link_hours: ['New accounts can send links after (hours)', '0 = no limit. Stops fresh spam accounts posting links.'],
    spam_duplicate_threshold: ['Copy-paste spam: same text to this many chats in 10 min', '0 = off. The sender is restricted automatically.'],
    spam_restrict_minutes: ['Automatic restriction length (minutes)', ''],
    auto_restrict_reports: ['Auto-restrict after reports from this many people (24h)', '0 = off. Restriction lasts 24h pending your review.'],
    blocked_phone_prefixes: ['Blocked phone prefixes', 'One per line, e.g. +1900. These numbers cannot sign up.'],
    require_admin_2fa: ['Require 2FA for all admins', 'Admins must turn on two-factor authentication before using the panel.'],
    reserved_usernames: ['Reserved usernames', 'One per line. Users can’t take these; admins can assign them from the user page.'],
    blocked_ips: ['Blocked IP addresses', 'One per line. Exact IP, or a prefix ending with "." such as 203.0.113.'],
    feature_channels: ['Channels', 'Allow users to create channels.'],
    feature_stories: ['Stories', 'Allow users to post stories.'],
    feature_polls: ['Polls & quizzes', ''],
    feature_voice_messages: ['Voice messages', ''],
    feature_location: ['Location sharing', ''],
    feature_calls: ['Voice calls', 'One-to-one calls between users.'],
    feature_video_calls: ['Video calls', 'Needs voice calls to be on.'],
    call_ring_timeout_sec: ['Ring for (seconds)', 'After this the call counts as missed.'],
    call_max_minutes: ['Longest call (minutes)', 'Calls are cut off after this.'],
    stun_urls: ['STUN servers', 'One per line, e.g. stun:stun.l.google.com:19302'],
    feature_bots: ['Bots & mini apps', 'Users can create bots with the Bot API.'],
    max_bots_per_user: ['Bots per user', ''],
    feature_channel_comments: ['Channel comments', 'Channel admins can turn on comments under posts.'],
    feature_topics: ['Topics in groups', 'Group admins can split a group into topics.'],
    feature_premium: ['Premium', 'Show Premium plans and accept payments.'],
    premium_upload_mb: ['Premium upload limit (MB)', 'Free users get “Max upload size”.'],
    payment_manual_enabled: ['Accept manual payments', 'User sends money to your account and uploads a screenshot; you approve it under Payments.'],
    payment_manual_instructions: ['Manual payment instructions', 'Shown to the user: account number, title, what to write in the note.'],
    feature_ads: ['Sponsored messages', 'Show ads from “Sponsored messages” in big public channels (never to Premium users).'],
    ads_min_subscribers: ['Minimum channel size for ads', 'Channels with fewer subscribers never show ads.'],
    feature_secret_chats: ['Secret chats', 'End-to-end encrypted chats. Their messages can’t be read by admins or the server — only counts are shown.'],
    turn_urls: ['TURN servers', 'One per line, e.g. turn:turn.yourdomain.com:3478 and turns:turn.yourdomain.com:5349. The secret is set on the server (TURN_SECRET).'],
  };
  const SETTING_SECTIONS = [
    ['General', ['registration_open', 'maintenance_mode', 'maintenance_message', 'max_group_members', 'max_upload_mb', 'message_edit_window_hours', 'min_app_version', 'latest_app_version', 'support_username']],
    ['Features', ['feature_channels', 'feature_stories', 'feature_polls', 'feature_voice_messages', 'feature_location', 'feature_secret_chats', 'feature_channel_comments', 'feature_topics']],
    ['Bots', ['feature_bots', 'max_bots_per_user']],
    ['Premium & payments', ['feature_premium', 'premium_upload_mb', 'payment_manual_enabled', 'payment_manual_instructions']],
    ['Sponsored messages', ['feature_ads', 'ads_min_subscribers']],
    ['Calls', ['feature_calls', 'feature_video_calls', 'call_ring_timeout_sec', 'call_max_minutes', 'stun_urls', 'turn_urls']],
    ['Moderation & spam', ['banned_words', 'banned_words_action', 'new_account_link_hours', 'spam_duplicate_threshold', 'spam_restrict_minutes', 'auto_restrict_reports', 'blocked_phone_prefixes', 'reserved_usernames']],
    ['Security', ['require_admin_2fa', 'blocked_ips']],
  ];

  async function pageSettings() {
    main.replaceChildren(head('Settings'), el('div', { class: 'muted' }, 'Loading…'));
    const d = await action(() => api('GET', '/settings'));
    if (!d) return;
    const inputs = {};
    const field = (key) => {
      const def = d.definitions[key];
      if (!def) return null;
      const [label, help] = SETTING_LABELS[key] || [key, ''];
      const value = d.settings[key];
      const helpEl = help ? el('div', { class: 'muted', style: 'font-size:12px' }, help) : null;
      if (def.type === 'boolean') {
        inputs[key] = el('input', { type: 'checkbox', checked: value, id: `s-${key}` });
        return el('div', {}, el('label', { class: 'check', for: `s-${key}` }, inputs[key], label), help ? el('div', { class: 'muted', style: 'margin:-8px 0 12px 26px;font-size:12px' }, help) : null);
      }
      if (def.type === 'enum') {
        inputs[key] = el('select', {}, def.values.map((x) => el('option', { value: x, selected: x === value ? true : null }, x[0].toUpperCase() + x.slice(1))));
      } else if (def.type === 'string_list') {
        inputs[key] = el('textarea', { rows: 5, placeholder: 'One per line' }, (value || []).join('\n'));
      } else {
        inputs[key] = el('input', { type: def.type === 'integer' ? 'number' : 'text', value: String(value), min: def.min, max: def.max, maxlength: def.max && def.type === 'string' ? def.max : null });
      }
      return el('div', { class: 'field' }, el('label', {}, label), inputs[key], helpEl);
    };
    const sections = SETTING_SECTIONS.map(([title, keys]) => el('div', { class: 'card', style: 'max-width:620px;margin-bottom:12px' },
      el('h3', { style: 'margin:0 0 12px;font-size:15px' }, title), keys.map(field)));
    const save = el('button', { class: 'btn primary' }, 'Save settings');
    save.addEventListener('click', async () => {
      const body = {};
      for (const [key, def] of Object.entries(d.definitions)) {
        const inp = inputs[key];
        if (!inp) continue;
        if (def.type === 'boolean') body[key] = inp.checked;
        else if (def.type === 'integer') body[key] = parseInt(inp.value, 10);
        else if (def.type === 'string_list') body[key] = inp.value.split('\n').map((x) => x.trim()).filter(Boolean);
        else body[key] = inp.value;
      }
      save.disabled = true;
      const r = await action(() => api('PUT', '/settings', body), 'Settings saved');
      save.disabled = false;
      if (r) pageSettings();
    });
    main.replaceChildren(head('Settings', save), ...sections);
  }

  // ------------------------------------------------------------------ ban appeals
  const appealsState = { status: 'pending', page: 1 };
  async function pageAppeals() {
    const tabs = el('div', { class: 'tabs' }, [['pending', 'Pending'], ['accepted', 'Accepted'], ['rejected', 'Rejected'], ['all', 'All']].map(([v, l]) => el('button', {
      class: appealsState.status === v ? 'active' : '',
      onclick: () => { appealsState.status = v; appealsState.page = 1; pageAppeals(); },
    }, l)));
    const box = el('div', {}, el('div', { class: 'muted' }, 'Loading…'));
    main.replaceChildren(head('Ban appeals'), tabs, box);
    const data = await action(() => api('GET', `/appeals?${new URLSearchParams({ status: appealsState.status, page: appealsState.page })}`));
    if (!data) return;
    const decide = (a, accept) => {
      const reply = el('textarea', { rows: 3, placeholder: accept ? 'Optional message, e.g. “Your account is restored.”' : 'Reason shown to the user' });
      modal(accept ? 'Accept appeal & unban' : 'Reject appeal', [el('div', { class: 'field' }, reply)], accept ? 'Unban user' : 'Reject', async () => {
        const r = await action(() => api('POST', `/appeals/${a.id}/resolve`, { accept, reply: reply.value.trim() || undefined }), accept ? 'User unbanned' : 'Appeal rejected');
        if (r) pageAppeals();
        return !!r;
      }, !accept);
    };
    const rows = data.appeals.map((a) => el('tr', {},
      el('td', { class: 'num' }, a.id),
      el('td', {}, `${`${a.first_name || ''} ${a.last_name || ''}`.trim() || '—'}`, el('div', { class: 'muted' }, a.username ? `@${a.username}` : a.phone),
        el('a', { href: '#', onclick: (e) => { e.preventDefault(); openUser(a.user_id); } }, 'Open user')),
      el('td', {}, el('div', { class: 'muted' }, `Ban: ${a.ban_reason || '—'}`), a.message),
      el('td', {}, el('span', { class: `chip ${a.status === 'pending' ? 'warn' : a.status === 'accepted' ? 'ok' : 'bad'}` }, a.status),
        a.admin_reply ? el('div', { class: 'muted' }, a.admin_reply) : null),
      el('td', { class: 'muted' }, ago(a.created_at)),
      el('td', {}, a.status === 'pending' && can('users.ban')
        ? el('div', { class: 'btn-row' }, el('button', { class: 'btn small primary', onclick: () => decide(a, true) }, 'Accept'), el('button', { class: 'btn small danger', onclick: () => decide(a, false) }, 'Reject'))
        : (a.resolved_by_name ? el('span', { class: 'muted' }, `by ${a.resolved_by_name}`) : null))));
    box.replaceChildren(table(['#', 'User', 'Appeal', 'Status', 'When', ''], rows, 'No appeals here'),
      pager(data, (p) => { appealsState.page = p; pageAppeals(); }));
  }

  // ------------------------------------------------------------------ content pages
  const PAGE_SLUGS = [['terms', 'Terms of Service'], ['privacy', 'Privacy Policy'], ['faq', 'Frequently Asked Questions'], ['about', 'About']];
  async function pagePages() {
    main.replaceChildren(head('Pages & FAQ'), el('div', { class: 'muted' }, 'Loading…'));
    const list = await action(() => api('GET', '/pages'));
    if (!list) return;
    const cards = PAGE_SLUGS.map(([slug, defaultTitle]) => {
      const existing = list.find((p) => p.slug === slug);
      const title = el('input', { type: 'text', value: existing ? existing.title : defaultTitle, maxlength: 120 });
      const body = el('textarea', { rows: 10, placeholder: 'Write the text here. Blank line = new paragraph. Start a line with "# " for a heading.' }, existing ? existing.body : '');
      const save = el('button', { class: 'btn primary small' }, 'Save');
      save.addEventListener('click', async () => {
        save.disabled = true;
        await action(() => api('PUT', `/pages/${slug}`, { title: title.value, body: body.value }), `${title.value} saved`);
        save.disabled = false;
      });
      return el('div', { class: 'card', style: 'max-width:760px;margin-bottom:12px' },
        el('div', { class: 'btn-row', style: 'justify-content:space-between;align-items:center;margin-bottom:8px' },
          el('strong', {}, defaultTitle),
          el('a', { href: `/p/${slug}`, target: '_blank', rel: 'noopener' }, `Public link: /p/${slug}`)),
        el('div', { class: 'field' }, el('label', {}, 'Title'), title),
        el('div', { class: 'field' }, el('label', {}, 'Text'), body),
        el('div', { class: 'muted', style: 'font-size:12px;margin-bottom:8px' }, existing ? `Last updated ${fmtDate(existing.updated_at)}` : 'Not written yet'),
        save);
    });
    main.replaceChildren(head('Pages & FAQ'), el('p', { class: 'muted' }, 'Shown in the app under Settings and as public web pages (use the Privacy link in your Play Store / App Store listing).'), ...cards);
  }

  // ------------------------------------------------------------------ broadcast
  async function pageBroadcast() {
    const title = el('input', { type: 'text', maxlength: 120, placeholder: 'e.g. Eid Mubarak!' });
    const body = el('textarea', { rows: 4, maxlength: 1000, placeholder: 'Message shown to users' });
    const prefix = el('input', { type: 'text', placeholder: 'All countries (or e.g. +92)' });
    const platform = el('select', {}, el('option', { value: '' }, 'All platforms'), el('option', { value: 'android' }, 'Android only'), el('option', { value: 'ios' }, 'iOS only'));
    const versionBelow = el('input', { type: 'text', placeholder: 'Any version (or e.g. 1.2.0)' });
    const inApp = el('input', { type: 'checkbox', checked: true, id: 'b-inapp' });
    const push = el('input', { type: 'checkbox', id: 'b-push' });
    const hours = el('select', {}, el('option', { value: '24' }, '1 day'), el('option', { value: '168' }, '7 days'), el('option', { value: '720' }, '30 days'), el('option', { value: '' }, 'Until I expire it'));
    const send = el('button', { class: 'btn primary' }, 'Send broadcast');
    const history = el('div', {});
    send.addEventListener('click', async () => {
      if (!title.value.trim() || !body.value.trim()) return toast('Title and message are required', true);
      const ok = await modal('Send broadcast?', [el('p', {}, `“${title.value.trim()}” will be ${push.checked ? 'pushed and ' : ''}shown to every matching user.`)], 'Send', async () => {
        const r = await action(() => api('POST', '/announcements', {
          title: title.value.trim(),
          body: body.value.trim(),
          target: { phone_prefix: prefix.value.trim() || undefined, platform: platform.value || undefined, app_version_below: versionBelow.value.trim() || undefined },
          in_app: inApp.checked,
          push: push.checked,
          expires_hours: hours.value ? Number(hours.value) : null,
        }));
        if (r) toast(`Sent to ${fmtNum(r.recipients)} users`);
        return !!r;
      });
      if (ok) { title.value = ''; body.value = ''; loadHistory(); }
      return undefined;
    });
    main.replaceChildren(head('Broadcast'),
      el('div', { class: 'card', style: 'max-width:620px;margin-bottom:16px' },
        el('div', { class: 'field' }, el('label', {}, 'Title'), title),
        el('div', { class: 'field' }, el('label', {}, 'Message'), body),
        el('div', { style: 'display:grid;grid-template-columns:1fr 1fr;gap:10px' },
          el('div', { class: 'field' }, el('label', {}, 'Phone prefix'), prefix),
          el('div', { class: 'field' }, el('label', {}, 'Platform'), platform)),
        el('div', { class: 'field' }, el('label', {}, 'Only users on an app version older than'), versionBelow),
        el('label', { class: 'check', for: 'b-inapp' }, inApp, 'Show as a banner in the app'),
        el('label', { class: 'check', for: 'b-push' }, push, 'Send a push notification'),
        el('div', { class: 'field' }, el('label', {}, 'Banner visible for'), hours),
        send),
      el('h3', { style: 'font-size:15px' }, 'History'), history);

    async function loadHistory() {
      const data = await action(() => api('GET', '/announcements'));
      if (!data) return;
      const active = (a) => a.in_app && (!a.expires_at || new Date(a.expires_at) > new Date());
      history.replaceChildren(table(['Sent', 'Title', 'Audience', 'Recipients', 'Dismissed', 'Status', ''], data.announcements.map((a) => el('tr', {},
        el('td', { class: 'muted' }, fmtDate(a.created_at)),
        el('td', {}, el('strong', {}, a.title), el('div', { class: 'muted', style: 'max-width:320px' }, a.body.slice(0, 120))),
        el('td', {}, [a.target.phone_prefix || 'All countries', a.target.platform || 'all platforms', a.target.app_version_below ? `app < ${a.target.app_version_below}` : null, a.push ? 'push' : null, a.in_app ? 'banner' : null].filter(Boolean).join(' · ')),
        el('td', { class: 'num' }, fmtNum(a.recipients)),
        el('td', { class: 'num' }, fmtNum(a.dismissed)),
        el('td', {}, active(a) ? el('span', { class: 'chip ok' }, 'Showing') : el('span', { class: 'chip' }, a.in_app ? 'Expired' : 'Push only')),
        el('td', {}, active(a) ? el('button', { class: 'btn small', onclick: async () => { if (await action(() => api('POST', `/announcements/${a.id}/expire`), 'Banner removed')) loadHistory(); } }, 'Stop showing') : null))), 'No broadcasts yet'));
    }
    loadHistory();
  }

  // ------------------------------------------------------------------ support tickets
  const supportState = { status: 'active', page: 1, mine: false, q: '' };
  const PRIORITY_CHIP = { urgent: 'bad', high: 'warn', normal: '', low: '' };
  async function pageSupport() {
    const tabs = el('div', { class: 'tabs' }, [['active', 'Open & waiting'], ['resolved', 'Resolved'], ['closed', 'Closed'], ['all', 'All']].map(([v, l]) => el('button', {
      class: supportState.status === v ? 'active' : '',
      onclick: () => { supportState.status = v; supportState.page = 1; pageSupport(); },
    }, l)));
    const mine = el('input', { type: 'checkbox', checked: supportState.mine, id: 'sp-mine' });
    const search = el('input', { type: 'text', placeholder: 'Search subject, phone, @username', value: supportState.q, style: 'flex:1;min-width:220px' });
    const listBox = el('div', {}, el('div', { class: 'muted' }, 'Loading…'));
    main.replaceChildren(head('Support'), tabs, el('div', { class: 'toolbar' }, search, el('label', { class: 'check', for: 'sp-mine', style: 'margin:0' }, mine, 'Assigned to me')), listBox);
    mine.addEventListener('change', () => { supportState.mine = mine.checked; pageSupport(); });
    search.addEventListener('input', debounce(() => { supportState.q = search.value.trim(); supportState.page = 1; load(); }, 300));

    async function load() {
      const q = new URLSearchParams({ status: supportState.status, page: supportState.page, mine: supportState.mine, q: supportState.q });
      const data = await action(() => api('GET', `/support?${q}`));
      if (!data) return;
      const rows = data.tickets.map((t) => el('tr', { class: 'clickable', onclick: () => openTicket(t.id) },
        el('td', { class: 'num' }, t.id),
        el('td', {}, el('strong', {}, t.subject), el('div', { class: 'muted' }, t.category)),
        el('td', {}, `${t.first_name || ''} ${t.last_name || ''}`.trim() || '—', el('div', { class: 'muted' }, t.username ? `@${t.username}` : t.phone)),
        el('td', {}, el('span', { class: `chip ${t.status === 'open' ? 'warn' : t.status === 'pending' ? 'info' : 'ok'}` }, t.status),
          t.awaiting_admin && ['open', 'pending'].includes(t.status) ? el('span', { class: 'chip bad', style: 'margin-left:4px' }, 'Needs reply') : null),
        el('td', {}, el('span', { class: `chip ${PRIORITY_CHIP[t.priority]}` }, t.priority)),
        el('td', {}, t.assigned_name || el('span', { class: 'muted' }, 'Unassigned')),
        el('td', { class: 'muted' }, ago(t.updated_at))));
      listBox.replaceChildren(table(['#', 'Subject', 'User', 'Status', 'Priority', 'Assigned', 'Updated'], rows, 'No tickets here'),
        pager(data, (p) => { supportState.page = p; load(); }));
    }
    load();
  }

  async function openTicket(id) {
    const d = await action(() => api('GET', `/support/${id}`));
    if (!d) return;
    const t = d.ticket;
    const reply = el('textarea', { rows: 4, placeholder: 'Write a reply to the user…' });
    const statusSel = el('select', {}, [['pending', 'Send & wait for user'], ['resolved', 'Send & mark resolved'], ['open', 'Send & keep open']]
      .map(([v, l]) => el('option', { value: v }, l)));
    const priority = el('select', {}, ['low', 'normal', 'high', 'urgent'].map((p) => el('option', { value: p, selected: p === t.priority ? true : null }, p)));
    priority.addEventListener('change', async () => { await action(() => api('PATCH', `/support/${id}`, { priority: priority.value }), 'Priority updated'); });
    const send = el('button', { class: 'btn primary' }, 'Send reply');
    send.addEventListener('click', async () => {
      if (!reply.value.trim()) return undefined;
      send.disabled = true;
      const r = await action(() => api('POST', `/support/${id}/reply`, { text: reply.value.trim(), status: statusSel.value }), 'Reply sent');
      send.disabled = false;
      if (r) { openTicket(id); if (state.page === 'support') pageSupport(); }
      return undefined;
    });
    const setStatus = (s) => el('button', { class: 'btn small', onclick: async () => { if (await action(() => api('PATCH', `/support/${id}`, { status: s }), `Marked ${s}`)) { openTicket(id); pageSupport(); } } }, s[0].toUpperCase() + s.slice(1));
    openDrawer([
      el('h3', {}, `#${t.id} — ${t.subject}`),
      el('div', { class: 'muted' }, `${t.category} · opened ${fmtDate(t.created_at)} by ${`${t.first_name || ''} ${t.last_name || ''}`.trim()} (${t.phone}${t.username ? `, @${t.username}` : ''})`),
      el('section', {}, el('div', { class: 'btn-row', style: 'align-items:center' },
        el('span', { class: 'chip' }, t.status), 'Priority', priority,
        t.assigned_to === state.admin.id ? null : el('button', { class: 'btn small', onclick: async () => { if (await action(() => api('PATCH', `/support/${id}`, { assigned_to: state.admin.id }), 'Assigned to you')) openTicket(id); } }, 'Assign to me'),
        setStatus('resolved'), setStatus('closed'))),
      el('section', {}, el('h4', {}, 'Conversation'), d.messages.map((m) => el('div', { class: m.from_user ? 'bubble' : 'bubble hl' },
        el('small', {}, `${m.from_user ? 'User' : (m.admin_name || 'Admin')} · ${fmtDate(m.created_at)}`), m.text))),
      t.status === 'closed' ? el('section', {}, el('div', { class: 'muted' }, 'This ticket is closed.'))
        : el('section', {}, el('h4', {}, 'Reply'), el('div', { class: 'field' }, reply), el('div', { class: 'btn-row' }, statusSel, send)),
    ]);
  }

  // ------------------------------------------------------------------ admins
  async function pageAdmins() {
    main.replaceChildren(head('Admin team'), el('div', { class: 'muted' }, 'Loading…'));
    const list = await action(() => api('GET', '/admins'));
    if (!list) return;
    const rows = list.map((a) => el('tr', {},
      el('td', {}, a.name || '—', a.id === state.admin.id ? el('span', { class: 'chip info', style: 'margin-left:6px' }, 'You') : null),
      el('td', {}, a.email),
      el('td', {}, a.role.replace('_', ' ')),
      el('td', {}, a.is_active ? el('span', { class: 'chip ok' }, 'Active') : el('span', { class: 'chip' }, 'Disabled')),
      el('td', {}, a.two_factor ? el('span', { class: 'chip ok' }, 'On') : el('span', { class: 'chip warn' }, 'Off')),
      el('td', { class: 'muted' }, ago(a.last_login_at)),
      el('td', {}, a.id === state.admin.id ? null : el('button', { class: 'btn small', onclick: () => editAdmin(a) }, 'Edit'))));
    main.replaceChildren(
      head('Admin team', el('button', { class: 'btn primary', onclick: () => editAdmin(null) }, 'Add admin')),
      table(['Name', 'Email', 'Role', 'Status', '2FA', 'Last login', ''], rows),
      el('div', { class: 'card', style: 'margin-top:12px' },
        el('strong', {}, 'Roles'), el('br'),
        'Super admin: everything. Moderator: users (ban, restrict, verify, log out), reports, groups & channels (suspend), support tickets, activity log. Support: support tickets plus read-only users, reports and groups.'));
  }

  function editAdmin(a) {
    const name = el('input', { type: 'text', value: a ? a.name : '' });
    const email = el('input', { type: 'email', value: a ? a.email : '', disabled: !!a });
    const role = el('select', {}, ['moderator', 'support', 'super_admin'].map((r) => el('option', { value: r, selected: a && a.role === r ? true : null }, r.replace('_', ' '))));
    const password = el('input', { type: 'password', placeholder: a ? 'Leave empty to keep current' : 'Min 10 characters', autocomplete: 'new-password' });
    const active = el('input', { type: 'checkbox', checked: a ? a.is_active : true, id: 'adm-active' });
    const reset2fa = el('input', { type: 'checkbox', id: 'adm-2fa' });
    modal(a ? `Edit ${a.email}` : 'Add admin', [
      el('div', { class: 'field' }, el('label', {}, 'Name'), name),
      el('div', { class: 'field' }, el('label', {}, 'Email'), email),
      el('div', { class: 'field' }, el('label', {}, 'Role'), role),
      el('div', { class: 'field' }, el('label', {}, a ? 'Reset password' : 'Password'), password),
      a ? el('label', { class: 'check', for: 'adm-active' }, active, 'Active') : null,
      a && a.two_factor ? el('label', { class: 'check', for: 'adm-2fa' }, reset2fa, 'Reset 2FA (lost phone)') : null,
    ], a ? 'Save' : 'Create admin', async () => {
      const r = a
        ? await action(() => api('PATCH', `/admins/${a.id}`, { name: name.value, role: role.value, is_active: active.checked, password: password.value || undefined, reset_2fa: reset2fa.checked || undefined }), 'Admin updated')
        : await action(() => api('POST', '/admins', { name: name.value, email: email.value, role: role.value, password: password.value }), 'Admin created');
      if (r) pageAdmins();
      return !!r;
    });
  }

  // ------------------------------------------------------------------ logs
  const logsState = { page: 1, action: '' };
  async function pageLogs() {
    const filter = el('select', {},
      [['', 'All actions'], ['user.', 'User actions'], ['report.', 'Reports'], ['group.', 'Groups'], ['settings.', 'Settings'], ['admin.', 'Admin team & logins']]
        .map(([v, l]) => el('option', { value: v, selected: logsState.action === v ? true : null }, l)));
    filter.addEventListener('change', () => { logsState.action = filter.value; logsState.page = 1; pageLogs(); });
    main.replaceChildren(head('Activity log'), el('div', { class: 'toolbar' }, filter), el('div', { class: 'muted' }, 'Loading…'));
    const q = new URLSearchParams({ page: logsState.page, action: logsState.action });
    const data = await action(() => api('GET', `/logs?${q}`));
    if (!data) return;
    const rows = data.logs.map((l) => el('tr', {},
      el('td', { class: 'muted' }, fmtDate(l.created_at)),
      el('td', {}, l.admin_name || l.admin_email || '—'),
      el('td', {}, el('span', { class: 'chip' }, l.action)),
      el('td', {}, l.target_type ? `${l.target_type} #${l.target_id || ''}` : '—'),
      el('td', { class: 'muted', style: 'max-width:320px;word-break:break-word' }, l.details ? JSON.stringify(l.details) : ''),
      el('td', { class: 'muted' }, l.ip || '')));
    main.replaceChildren(head('Activity log'), el('div', { class: 'toolbar' }, filter),
      table(['When', 'Admin', 'Action', 'Target', 'Details', 'IP'], rows),
      pager(data, (p) => { logsState.page = p; pageLogs(); }));
  }

  // ------------------------------------------------------------------ calls
  const CALL_STATUS = { ringing: ['Ringing', 'warn'], accepted: ['On call', 'ok'], ended: ['Ended', ''], missed: ['Missed', 'warn'], declined: ['Declined', ''], busy: ['Busy', ''], failed: ['Failed', 'bad'] };
  const callsState = { status: '', video: '', user: '', page: 1 };
  function fmtDur(sec) {
    const s = Number(sec) || 0;
    if (!s) return '—';
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const r = s % 60;
    return h ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`;
  }
  async function pageCalls() {
    main.replaceChildren(head('Calls'), el('div', { class: 'muted' }, 'Loading…'));
    const query = { page: callsState.page };
    if (callsState.status) query.status = callsState.status;
    if (callsState.video) query.video = callsState.video;
    if (callsState.user) query.user_id = callsState.user;
    const [st, data] = await Promise.all([
      action(() => api('GET', '/calls/stats')),
      action(() => api('GET', `/calls?${new URLSearchParams(query)}`)),
    ]);
    if (!st || !data) return;
    const stat = (label, value) => el('div', { class: 'card stat' }, el('div', { class: 'label' }, label), el('div', { class: 'value' }, value));
    const turnCard = st.turn.urls.length && st.turn.auth !== 'none'
      ? el('div', { class: 'card', style: 'margin-bottom:12px' }, el('b', {}, 'TURN relay: on'), el('div', { class: 'muted' }, `${st.turn.urls.join(', ')} · ${st.turn.auth === 'secret' ? 'time-limited credentials' : 'fixed username/password'}`))
      : el('div', { class: 'card', style: 'margin-bottom:12px;border-color:#f0b429;background:#fffbea' },
        el('b', {}, 'No TURN server configured'),
        el('div', {}, 'Calls connect directly (STUN only). On many mobile networks 10–20% of calls will fail to connect. Install coturn and set TURN_SECRET + TURN servers — see the backend README.'));
    const filters = el('div', { class: 'toolbar' },
      el('select', { onchange: (e) => { callsState.status = e.target.value; callsState.page = 1; pageCalls(); } },
        el('option', { value: '' }, 'All statuses'),
        Object.entries(CALL_STATUS).map(([k, [l]]) => el('option', { value: k, selected: callsState.status === k ? true : null }, l))),
      el('select', { onchange: (e) => { callsState.video = e.target.value; callsState.page = 1; pageCalls(); } },
        el('option', { value: '' }, 'Voice & video'),
        el('option', { value: 'false', selected: callsState.video === 'false' ? true : null }, 'Voice only'),
        el('option', { value: 'true', selected: callsState.video === 'true' ? true : null }, 'Video only')),
      el('input', { type: 'number', placeholder: 'User ID', value: callsState.user, style: 'width:110px',
        onchange: (e) => { callsState.user = e.target.value.trim(); callsState.page = 1; pageCalls(); } }));
    const who = (u) => el('div', {}, el('a', { href: '#', onclick: (e) => { e.preventDefault(); openUser(u.id); } }, u.name),
      u.username ? el('div', { class: 'muted' }, `@${u.username}`) : null);
    const rows = data.items.map((c) => {
      const [label, cls] = CALL_STATUS[c.status] || [c.status, ''];
      const live = c.status === 'ringing' || c.status === 'accepted';
      return el('tr', {},
        el('td', { class: 'num' }, c.id),
        el('td', {}, who(c.caller)),
        el('td', {}, who(c.callee)),
        el('td', {}, c.video ? 'Video' : 'Voice'),
        el('td', {}, el('span', { class: `chip ${cls}` }, label), c.end_reason && !['hangup', 'declined', c.status].includes(c.end_reason) ? el('div', { class: 'muted' }, c.end_reason.replace(/_/g, ' ')) : null),
        el('td', { class: 'num' }, fmtDur(c.duration_sec)),
        el('td', {}, c.rating ? `${'★'.repeat(c.rating.caller || c.rating.callee)}` : '—', c.rating && c.rating.comment ? el('div', { class: 'muted' }, c.rating.comment) : null),
        el('td', { class: 'muted' }, ago(c.created_at)),
        el('td', {}, live && can('calls.manage')
          ? el('button', { class: 'btn small danger', onclick: async () => { if (await action(() => api('POST', `/calls/${c.id}/end`), 'Call ended')) pageCalls(); } }, 'End')
          : null));
    });
    const days = (key) => st.days.map((d) => ({ day: d.day, count: d[key] }));
    main.replaceChildren(
      head('Calls', el('button', { class: 'btn', onclick: pageCalls }, 'Refresh')),
      turnCard,
      el('div', { class: 'stats' },
        stat('On calls now', fmtNum(st.active)),
        stat('Calls today', fmtNum(st.today)),
        stat('Calls (30 days)', fmtNum(st.last_30d)),
        stat('Answered', `${st.answer_rate}%`),
        stat('Avg. length', fmtDur(st.avg_duration_sec)),
        stat('Avg. rating', st.avg_rating ? `${st.avg_rating} ★` : '—'),
        stat('Failed (30 days)', fmtNum(st.failed_30d)),
        stat('Video (30 days)', fmtNum(st.video_30d))),
      el('div', { class: 'charts' }, barChart('Calls — last 14 days', days('calls')), barChart('Call minutes — last 14 days', days('minutes'))),
      filters,
      table(['#', 'Caller', 'Called', 'Type', 'Status', 'Length', 'Rating', 'When', ''], rows, 'No calls yet'),
      pager(data, (p) => { callsState.page = p; pageCalls(); }));
  }

  // ------------------------------------------------------------------ bots
  const botsState = { q: '', page: 1 };
  async function pageBots() {
    const search = el('input', { type: 'search', placeholder: 'Search bots…', value: botsState.q,
      oninput: debounce((e) => { botsState.q = e.target.value.trim(); botsState.page = 1; pageBots(); }, 350) });
    const box = el('div', {}, el('div', { class: 'muted' }, 'Loading…'));
    main.replaceChildren(head('Bots'), el('div', { class: 'toolbar' }, search), box);
    const data = await action(() => api('GET', `/bots?${new URLSearchParams({ q: botsState.q, page: botsState.page })}`));
    if (!data) return;
    const rows = data.bots.map((b) => el('tr', {},
      el('td', {}, el('b', {}, b.name), el('div', { class: 'muted' }, `@${b.username}`)),
      el('td', {}, el('a', { href: '#', onclick: (e) => { e.preventDefault(); openUser(b.owner.id); } }, b.owner.name || `#${b.owner.id}`),
        b.owner.username ? el('div', { class: 'muted' }, `@${b.owner.username}`) : null),
      el('td', { class: 'num' }, fmtNum(b.chats)),
      el('td', {}, b.webhook_url ? 'Webhook' : 'Polling', b.webhook_error ? el('div', { class: 'muted', style: 'color:#d93025' }, b.webhook_error) : null),
      el('td', { class: 'num' }, fmtNum(b.pending_updates)),
      el('td', {}, el('span', { class: `chip ${b.status === 'active' ? 'ok' : 'bad'}` }, b.status), b.disabled_reason ? el('div', { class: 'muted' }, b.disabled_reason) : null),
      el('td', { class: 'muted' }, b.last_used_at ? ago(b.last_used_at) : 'never'),
      el('td', {}, can('users.ban') ? el('button', {
        class: `btn small ${b.status === 'active' ? 'danger' : ''}`,
        onclick: () => {
          if (b.status !== 'active') {
            action(() => api('POST', `/bots/${b.id}/status`, { active: true }), 'Bot enabled').then((r) => { if (r) pageBots(); });
            return;
          }
          const reason = el('input', { type: 'text', placeholder: 'Reason (shown to the developer)' });
          modal(`Disable @${b.username}?`, [el('div', { class: 'field' }, reason)], 'Disable', async () => {
            const r = await action(() => api('POST', `/bots/${b.id}/status`, { active: false, reason: reason.value.trim() }), 'Bot disabled');
            if (r) pageBots();
            return !!r;
          }, true);
        },
      }, b.status === 'active' ? 'Disable' : 'Enable') : null)));
    box.replaceChildren(table(['Bot', 'Owner', 'Chats', 'Mode', 'Queue', 'Status', 'Last used', ''], rows, 'No bots yet'),
      pager(data, (p) => { botsState.page = p; pageBots(); }));
  }

  // ------------------------------------------------------------------ revenue
  const rs = (n) => `Rs ${fmtNum(n)}`;
  async function pageRevenue() {
    main.replaceChildren(head('Revenue'), el('div', { class: 'muted' }, 'Loading…'));
    const d = await action(() => api('GET', '/revenue'));
    if (!d) return;
    const stat = (label, value) => el('div', { class: 'card stat' }, el('div', { class: 'label' }, label), el('div', { class: 'value' }, value));
    const PROVIDERS = { jazzcash: 'JazzCash', easypaisa: 'Easypaisa', manual: 'Manual transfer', admin: 'Given by admin' };
    main.replaceChildren(
      head('Revenue', el('button', { class: 'btn', onclick: pageRevenue }, 'Refresh')),
      el('div', { class: 'stats' },
        stat('Total earned', rs(d.total)),
        stat('Premium this month', rs(d.premium_this_month)),
        stat('Premium (all time)', rs(d.premium_total)),
        stat('Ads (all time)', rs(d.ads_total)),
        stat('Premium users now', fmtNum(d.premium_users)),
        stat('Payments (30 days)', fmtNum(d.payments_30d)),
        stat('Waiting for review', fmtNum(d.to_review))),
      el('div', { class: 'charts' },
        barChart('Premium income by month (Rs)', d.months.map((m) => ({ day: `${m.month}-01`, count: m.premium_pkr }))),
        barChart('Ad income by month (Rs)', d.months.map((m) => ({ day: `${m.month}-01`, count: m.ads_pkr })))),
      el('h3', { style: 'margin:16px 0 8px;font-size:15px' }, 'By payment method'),
      table(['Method', 'Payments', 'Amount'], d.by_provider.map((p) => el('tr', {},
        el('td', {}, PROVIDERS[p.provider] || p.provider), el('td', { class: 'num' }, fmtNum(p.payments)), el('td', { class: 'num' }, rs(p.amount_pkr)))), 'No payments yet'));
  }

  // ------------------------------------------------------------------ payments
  const payState = { status: 'review', page: 1 };
  const PAY_STATUS = { pending: ['Waiting', 'warn'], review: ['To review', 'warn'], paid: ['Paid', 'ok'], failed: ['Failed', 'bad'], cancelled: ['Cancelled', ''], rejected: ['Rejected', 'bad'] };
  async function pagePayments() {
    const tabs = el('div', { class: 'tabs' }, [['review', 'To review'], ['paid', 'Paid'], ['pending', 'Waiting'], ['failed', 'Failed'], ['rejected', 'Rejected'], ['all', 'All']].map(([v, l]) => el('button', {
      class: payState.status === v ? 'active' : '',
      onclick: () => { payState.status = v; payState.page = 1; pagePayments(); },
    }, l)));
    const box = el('div', {}, el('div', { class: 'muted' }, 'Loading…'));
    main.replaceChildren(head('Payments'), tabs, box);
    const data = await action(() => api('GET', `/payments?${new URLSearchParams({ status: payState.status, page: payState.page })}`));
    if (!data) return;
    const review = (o) => {
      const proof = el('div', { class: 'muted' }, o.proof_media_id ? 'Loading screenshot…' : 'No screenshot');
      if (o.proof_media_id) mediaPreview({ admin_url: `/api/admin/media/${o.proof_media_id}`, mime: 'image/png', name: 'proof' }).then((n) => proof.replaceWith(n));
      const note = el('input', { type: 'text', placeholder: 'Note (reason if rejecting)' });
      const info = el('div', {},
        el('p', {}, `${o.user.name} · ${rs(o.amount_pkr)} · ${o.months} month(s) · ${o.provider}`),
        o.proof_txn_id ? el('p', {}, `Transaction ID: ${o.proof_txn_id}${o.proof_sender ? ` · from ${o.proof_sender}` : ''}`) : null,
        o.provider_message ? el('p', { class: 'muted' }, o.provider_message) : null,
        proof, el('div', { class: 'field', style: 'margin-top:10px' }, note));
      openDrawer(el('div', {}, el('h3', {}, `Payment #${o.id}`), info,
        el('div', { class: 'btn-row', style: 'margin-top:12px' },
          el('button', { class: 'btn primary', onclick: async () => { if (await action(() => api('POST', `/payments/${o.id}/approve`, { note: note.value.trim() }), 'Approved — Premium is active')) { closeDrawer(); pagePayments(); } } }, 'Approve'),
          el('button', { class: 'btn danger', onclick: async () => { if (await action(() => api('POST', `/payments/${o.id}/reject`, { note: note.value.trim() }), 'Rejected')) { closeDrawer(); pagePayments(); } } }, 'Reject'))));
    };
    const rows = data.orders.map((o) => {
      const [label, cls] = PAY_STATUS[o.status] || [o.status, ''];
      return el('tr', {},
        el('td', { class: 'num' }, o.id),
        el('td', {}, el('a', { href: '#', onclick: (e) => { e.preventDefault(); openUser(o.user.id); } }, o.user.name || `#${o.user.id}`), el('div', { class: 'muted' }, o.user.phone || '')),
        el('td', { class: 'num' }, rs(o.amount_pkr)),
        el('td', {}, `${o.months} mo`),
        el('td', {}, o.provider, el('div', { class: 'muted' }, o.txn_ref)),
        el('td', {}, el('span', { class: `chip ${cls}` }, label), o.provider_message ? el('div', { class: 'muted' }, o.provider_message) : null),
        el('td', { class: 'muted' }, ago(o.created_at)),
        el('td', {}, ['review', 'pending'].includes(o.status) ? el('button', { class: 'btn small primary', onclick: () => review(o) }, 'Review') : (o.reviewer ? el('span', { class: 'muted' }, `by ${o.reviewer}`) : null)));
    });
    box.replaceChildren(table(['#', 'User', 'Amount', 'Plan', 'Method', 'Status', 'When', ''], rows, 'Nothing here'),
      pager(data, (p) => { payState.page = p; pagePayments(); }));
  }

  // ------------------------------------------------------------------ premium plans
  async function pagePlans() {
    main.replaceChildren(head('Premium plans'), el('div', { class: 'muted' }, 'Loading…'));
    const plans = await action(() => api('GET', '/plans'));
    if (!plans) return;
    const edit = (p) => {
      const name = el('input', { type: 'text', value: p ? p.name : '', placeholder: 'e.g. 6 months' });
      const months = el('input', { type: 'number', min: 1, max: 60, value: p ? p.months : 1 });
      const price = el('input', { type: 'number', min: 0, value: p ? p.price_pkr : 299 });
      const active = el('input', { type: 'checkbox', checked: p ? p.is_active : true, id: 'plan-active' });
      modal(p ? 'Edit plan' : 'New plan', [
        el('div', { class: 'field' }, el('label', {}, 'Name'), name),
        el('div', { class: 'field' }, el('label', {}, 'Months'), months),
        el('div', { class: 'field' }, el('label', {}, 'Price (Rs)'), price),
        el('label', { class: 'check', for: 'plan-active' }, active, 'Available to buy'),
      ], 'Save', async () => {
        const body = { name: name.value.trim(), months: Number(months.value), price_pkr: Number(price.value), is_active: active.checked, sort: Number(months.value) };
        const r = await action(() => api(p ? 'PUT' : 'POST', p ? `/plans/${p.id}` : '/plans', body), 'Plan saved');
        if (r) pagePlans();
        return !!r;
      });
    };
    const rows = plans.map((p) => el('tr', {},
      el('td', {}, p.name), el('td', { class: 'num' }, p.months), el('td', { class: 'num' }, rs(p.price_pkr)), el('td', { class: 'num' }, rs(p.per_month_pkr)),
      el('td', {}, el('span', { class: `chip ${p.is_active ? 'ok' : ''}` }, p.is_active ? 'On sale' : 'Hidden')),
      el('td', {}, el('button', { class: 'btn small', onclick: () => edit(p) }, 'Edit'))));
    main.replaceChildren(head('Premium plans', el('button', { class: 'btn primary', onclick: () => edit(null) }, 'New plan')),
      el('p', { class: 'muted' }, 'Premium gives: ⭐ badge, bigger uploads (Settings → Premium & payments), 30 chat folders, no sponsored messages.'),
      table(['Plan', 'Months', 'Price', 'Per month', 'Status', ''], rows, 'No plans'));
  }

  // ------------------------------------------------------------------ sponsored messages
  async function pageAds() {
    main.replaceChildren(head('Sponsored messages'), el('div', { class: 'muted' }, 'Loading…'));
    const list = await action(() => api('GET', '/ads'));
    if (!list) return;
    const AD_STATUS = { active: ['Running', 'ok'], paused: ['Paused', 'warn'], ended: ['Ended', ''] };
    const edit = (c) => {
      const f = (label, input, help) => el('div', { class: 'field' }, el('label', {}, label), input, help ? el('div', { class: 'muted', style: 'font-size:12px' }, help) : null);
      const advertiser = el('input', { type: 'text', value: c ? c.advertiser : '', maxlength: 80 });
      const text = el('textarea', { rows: 3, maxlength: 300 }, c ? c.text : '');
      const btn = el('input', { type: 'text', value: c ? c.button_text : 'Open', maxlength: 30 });
      const url = el('input', { type: 'url', value: c ? c.url : 'https://' });
      const targets = el('input', { type: 'text', value: c ? c.target_chat_ids.join(', ') : '', placeholder: 'empty = all big public channels' });
      const minSubs = el('input', { type: 'number', min: 0, value: c ? c.min_subscribers : 0 });
      const maxImp = el('input', { type: 'number', min: 1, value: c && c.max_impressions ? c.max_impressions : '', placeholder: 'no limit' });
      const ends = el('input', { type: 'date', value: c && c.ends_at ? c.ends_at.slice(0, 10) : '' });
      const price = el('input', { type: 'number', min: 0, value: c ? c.price_pkr : 0 });
      const status = el('select', {}, Object.entries(AD_STATUS).map(([k, [l]]) => el('option', { value: k, selected: c && c.status === k ? true : null }, l)));
      modal(c ? 'Edit campaign' : 'New campaign', [
        f('Advertiser', advertiser), f('Text', text), f('Button text', btn), f('Link', url),
        f('Only these channel IDs', targets, 'Comma separated chat IDs (see Groups & channels)'), f('Minimum subscribers', minSubs),
        f('Stop after this many views', maxImp), f('End date', ends), f('Price paid by advertiser (Rs)', price, 'Counted in Revenue'), f('Status', status),
      ], 'Save', async () => {
        const body = {
          advertiser: advertiser.value.trim(), text: text.value.trim(), button_text: btn.value.trim(), url: url.value.trim(),
          target_chat_ids: targets.value.split(',').map((x) => x.trim()).filter(Boolean).map(Number),
          min_subscribers: Number(minSubs.value || 0), max_impressions: maxImp.value ? Number(maxImp.value) : null,
          ends_at: ends.value ? new Date(`${ends.value}T23:59:59`).toISOString() : null, price_pkr: Number(price.value || 0), status: status.value,
        };
        const r = await action(() => api(c ? 'PUT' : 'POST', c ? `/ads/${c.id}` : '/ads', body), 'Campaign saved');
        if (r) pageAds();
        return !!r;
      });
    };
    const rows = list.map((c) => {
      const [label, cls] = AD_STATUS[c.status] || [c.status, ''];
      return el('tr', {},
        el('td', {}, el('b', {}, c.advertiser), el('div', { class: 'muted' }, c.text)),
        el('td', {}, el('span', { class: `chip ${cls}` }, label), c.ends_at ? el('div', { class: 'muted' }, `until ${new Date(c.ends_at).toLocaleDateString()}`) : null),
        el('td', { class: 'num' }, `${fmtNum(c.impressions)}${c.max_impressions ? ` / ${fmtNum(c.max_impressions)}` : ''}`),
        el('td', { class: 'num' }, fmtNum(c.clicks)),
        el('td', { class: 'num' }, `${c.ctr}%`),
        el('td', { class: 'num' }, rs(c.price_pkr)),
        el('td', {}, el('div', { class: 'btn-row' },
          el('button', { class: 'btn small', onclick: () => edit(c) }, 'Edit'),
          el('button', { class: 'btn small danger', onclick: async () => { if (await action(() => api('DELETE', `/ads/${c.id}`), 'Deleted')) pageAds(); } }, 'Delete'))));
    });
    main.replaceChildren(head('Sponsored messages', el('button', { class: 'btn primary', onclick: () => edit(null) }, 'New campaign')),
      el('p', { class: 'muted' }, 'Shown at the end of big public channels, never to Premium users. Turn on in Settings → Sponsored messages.'),
      table(['Campaign', 'Status', 'Views', 'Clicks', 'CTR', 'Price', ''], rows, 'No campaigns yet'));
  }

  const PAGES = {
    dashboard: pageDashboard,
    users: pageUsers,
    reports: pageReports,
    groups: pageGroups,
    calls: pageCalls,
    bots: pageBots,
    revenue: pageRevenue,
    payments: pagePayments,
    plans: pagePlans,
    ads: pageAds,
    settings: pageSettings,
    broadcast: pageBroadcast,
    appeals: pageAppeals,
    pages: pagePages,
    support: pageSupport,
    admins: pageAdmins,
    logs: pageLogs,
  };

  // ------------------------------------------------------------------ boot
  async function render() {
    if (!state.token) return renderLogin();
    if (!state.admin) {
      state.admin = await action(() => api('GET', '/me'));
      if (!state.admin) return renderLogin();
    }
    renderLayout();
    if (can('reports.view') && state.page !== 'dashboard') {
      api('GET', '/reports?status=open&limit=1').then((r) => {
        state.openReports = r.total;
        const badgeHost = [...document.querySelectorAll('.side button')].find((b) => b.textContent.startsWith('Reports'));
        if (badgeHost && r.total && !badgeHost.querySelector('.badge')) badgeHost.append(el('span', { class: 'badge' }, r.total));
      }).catch(() => {});
    }
    return undefined;
  }

  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDrawer(); });
  render();
})();
