'use strict';

const http = require('http');
const fs = require('fs');
const config = require('./config');
const db = require('./db');
const { createApp } = require('./app');
const socket = require('./realtime/socket');
const push = require('./services/push.service');

fs.mkdirSync(config.uploadDir, { recursive: true });

const app = createApp();
const server = http.createServer(app);
socket.init(server);
push.init();

server.listen(config.port, () => {
  // eslint-disable-next-line no-console
  console.log(`ChatApp API listening on http://localhost:${config.port}  (admin panel: /admin)`);
  if (config.otp.devMode) console.log('OTP dev mode is ON — codes are returned in the API response'); // eslint-disable-line no-console
});

function shutdown(signal) {
  // eslint-disable-next-line no-console
  console.log(`${signal} received, shutting down...`);
  server.close(() => {
    db.close().finally(() => process.exit(0));
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
