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

require('./services/sticker.service').ensureOfficialPacks().catch((err) => console.error('sticker packs:', err.message)); // eslint-disable-line no-console

server.listen(config.port, () => {
  // eslint-disable-next-line no-console
  console.log(`Talvio API listening on http://localhost:${config.port}  (admin panel: /admin)`);
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
  messageService.sweepPolls().catch(() => {});
  secretSweepTick = (secretSweepTick + 1) % 240; // about once an hour
  if (secretSweepTick % 4 === 0) messageService.sweepExpired().catch((err) => console.error('disappearing sweep error', err)); // eslint-disable-line no-console
  require('./services/payment.service').sweep().catch(() => {});
  if (secretSweepTick % 20 === 2) require('./services/qr.service').sweep().catch(() => {});
  require('./services/bot.service').sweep().catch((err) => console.error('bot sweep error', err)); // eslint-disable-line no-console
  // birthday reminders: once a day, after 05:00 UTC
  if (secretSweepTick % 40 === 5 && new Date().getUTCHours() >= 5) require('./services/user.service').sendBirthdayReminders().catch(() => {});
  if (secretSweepTick === 1) secretService.sweep().catch((err) => console.error('secret sweep error', err)); // eslint-disable-line no-console
}, 15000);
scheduler.unref();

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
