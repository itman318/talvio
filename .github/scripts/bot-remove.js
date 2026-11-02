'use strict';

/** On the server: deletes a hosted bot's Hushavia account.  cd /opt/hushavia/app && node /root/bot-remove.js <bot_username> */
const path = require('path');

const req = (p) => require(path.join(process.cwd(), p)); // eslint-disable-line global-require, import/no-dynamic-require
const db = req('src/db');
const bots = req('src/services/bot.service');

(async () => {
  const username = process.argv[2];
  const b = await db.one(
    `SELECT b.user_id, b.owner_id FROM bots b JOIN users u ON u.id = b.user_id WHERE lower(u.username) = lower($1) AND b.status = 'active'`,
    [username],
  );
  if (!b) console.log(`bot @${username}: not found (already deleted)`); // eslint-disable-line no-console
  else {
    await bots.deleteBot(b.owner_id, b.user_id);
    console.log(`bot @${username}: deleted`); // eslint-disable-line no-console
  }
  await db.close();
})().catch((e) => {
  console.error('bot-remove failed:', e.message); // eslint-disable-line no-console
  process.exit(1);
});
