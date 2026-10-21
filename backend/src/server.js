'use strict';

const http = require('http');
const fs = require('fs');
const config = require('./config');
const db = require('./db');
const { createApp } = require('./app');
const socket = require('./realtime/socket');
const push = require('./services/push.service');
const callService = require('./services/call.service');
const secretService = require('./services/secret.service');

let secretSweepTick = 0;
const messageService = require('./services/message.service');

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

// Publish scheduled messages every 15 seconds.
const scheduler = setInterval(() => {
  messageService.runDueScheduled().catch((err) => console.error('scheduler error', err)); // eslint-disable-line no-console
  callService.sweep().catch((err) => console.error('call sweep error', err)); // eslint-disable-line no-console
  secretSweepTick = (secretSweepTick + 1) % 240; // about once an hour
  require('./services/payment.service').sweep().catch(() => {});
  require('./services/bot.service').sweep().catch((err) => console.error('bot sweep error', err)); // eslint-disable-line no-console
  if (secretSweepTick === 1) secretService.sweep().catch((err) => console.error('secret sweep error', err)); // eslint-disable-line no-console
}, 15000);
scheduler.unref();

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
