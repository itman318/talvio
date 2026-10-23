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
    express.static(webDir, { index: 'index.html', maxAge: config.isProd ? '10m' : 0 }),
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
    express.static(adminDir, { index: 'index.html', maxAge: config.isProd ? '1h' : 0 }),
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

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

module.exports = { createApp };
