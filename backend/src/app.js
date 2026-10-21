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

  app.use('/api/admin', adminRoutes.router);
  app.use('/api', userRoutes.router);

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

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

module.exports = { createApp };
