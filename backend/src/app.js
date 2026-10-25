'use strict';

const path = require('path');
const express = require('express');
const config = require('./config');
const db = require('./db');
const { securityHeaders, cors, notFoundHandler, errorHandler } = require('./http/middleware');
const userRoutes = require('./http/routes.user');
const adminRoutes = require('./http/routes.admin');

function createApp() {
  const app = express();
  app.set('trust proxy', config.trustProxy);
  app.disable('x-powered-by');
  app.use(securityHeaders);
  app.use(cors);
  app.use(express.json({ limit: '1mb' }));

  app.get('/health', async (req, res) => {
    try {
      await db.query('SELECT 1');
      res.json({ ok: true });
    } catch (_) {
      res.status(503).json({ ok: false });
    }
  });

  // Talvio Bot API: /api/bot/v1/<method>, token in "Authorization: Bearer <token>"
  app.all('/api/bot/v1/:method', express.urlencoded({ extended: false, limit: '1mb' }), require('./http/routes.botapi'));

  // Payment pages for JazzCash / Easypaisa hosted checkout
  app.use('/pay', require('./http/routes.pay'));

  app.use('/api/admin', adminRoutes.router);
  app.use('/api', userRoutes.router);

  // pages always load fresh (their css / js links carry a ?v= version, so those can be cached)
  const noCacheHtml = (res, file) => {
    if (file.endsWith('.html')) res.setHeader('Cache-Control', 'no-cache');
  };

  // Web / desktop app (installable PWA) at /web
  const webDir = path.join(__dirname, '..', 'web-client');
  app.use(
    '/web',
    (req, res, next) => {
      res.setHeader(
        'Content-Security-Policy',
        "default-src 'self'; img-src 'self' data: blob: https:; media-src 'self' blob: https:; style-src 'self' 'unsafe-inline'; script-src 'self'; " +
          "connect-src 'self' ws: wss:; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'",
      );
      res.setHeader('Service-Worker-Allowed', '/web/');
      next();
    },
    express.static(webDir, { index: 'index.html', maxAge: config.isProd ? '10m' : 0, setHeaders: noCacheHtml }),
  );

  // Admin panel (static single-page app)
  const adminDir = path.join(__dirname, '..', 'admin-panel');
  app.use(
    '/admin',
    (req, res, next) => {
      res.setHeader(
        'Content-Security-Policy',
        "default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
      );
      next();
    },
    express.static(adminDir, { index: 'index.html', maxAge: config.isProd ? '1h' : 0, setHeaders: noCacheHtml }),
  );
  app.get('/', (req, res) => res.redirect('/admin/'));
  // Public legal pages, e.g. https://chat.example.com/p/privacy (for Play Store / App Store listings)
  app.get('/p/:slug', async (req, res, next) => {
    try {
      // eslint-disable-next-line global-require
      const content = require('./services/content.service');
      const page = await content.get(req.params.slug);
      res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'");
      res.type('html').send(content.renderHtml(page));
    } catch (err) {
      next(err);
    }
  });

  // Shared links (open the app; like t.me links):
  //   /call/<code>  → call me     /c/<username> → public group / channel     /join/<code> → invite link
  const esc = (t) => String(t).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
  const landing = (res, { emoji, title, text, deep }) => {
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:");
    res.type('html').send(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Talvio</title><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(text)}">
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#0f1222;color:#fff;text-align:center}
.c{padding:32px 24px;max-width:380px}.e{font-size:54px}h1{margin:10px 0 6px;font-size:24px}a{display:inline-block;margin-top:22px;padding:14px 30px;border-radius:999px;color:#fff;text-decoration:none;font-weight:700;
background:linear-gradient(135deg,#ff7a59,#f0446e 55%,#8b5cf6)}p{color:#b8bdd6;line-height:1.5}small{display:block;margin-top:18px;color:#6d7393}</style></head>
<body><div class="c"><div class="e">${emoji}</div><h1>${esc(title)}</h1><p>${esc(text)}</p><a href="${esc(deep)}">Open in Talvio</a>
<small>Don’t have Talvio yet? Install the app, then open this link again.</small></div></body></html>`);
  };
  const clean = (v) => String(v).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
  app.get('/call/:code', (req, res) => {
    const code = clean(req.params.code);
    landing(res, { emoji: '📞', title: 'Talvio call', text: 'Someone shared a call link with you. Open it in the Talvio app to start the call.', deep: `talvio://call/${code}` });
  });
  app.get('/c/:username', async (req, res) => {
    const name = clean(req.params.username);
    let title = `@${name}`;
    let text = 'A public group or channel on Talvio.';
    try {
      // eslint-disable-next-line global-require
      const db = require('./db');
      const c = await db.one(
        `SELECT title, type, description, (SELECT count(*) FROM chat_members m WHERE m.chat_id = c.id) AS n
         FROM chats c WHERE lower(username) = lower($1) AND is_public AND NOT is_suspended`,
        [name],
      );
      if (c) {
        title = c.title;
        text = `${c.n} ${c.type === 'channel' ? 'subscribers' : 'members'}${c.description ? ` · ${String(c.description).slice(0, 140)}` : ''}`;
      }
      if (!c) {
        const b = await db.one(
          `SELECT u.first_name, b.about FROM users u JOIN bots b ON b.user_id = u.id WHERE lower(u.username) = lower($1) AND b.status = 'active'`,
          [name],
        );
        if (b) {
          title = b.first_name;
          text = `Bot · ${String(b.about || 'Open it in Talvio to start.').slice(0, 160)}`;
        }
      }
    } catch (_) {
      /* the page still works without the details */
    }
    const start = /^[A-Za-z0-9_-]{1,64}$/.test(String(req.query.start || '')) ? `?start=${req.query.start}` : '';
    landing(res, { emoji: '👥', title, text, deep: `talvio://c/${name}${start}` });
  });
  app.get('/join/:code', (req, res) => {
    const code = clean(req.params.code);
    landing(res, { emoji: '✉️', title: 'You’re invited', text: 'You have an invite to a private group or channel on Talvio.', deep: `talvio://join/${code}` });
  });

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

module.exports = { createApp };
