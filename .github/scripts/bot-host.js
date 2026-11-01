'use strict';

/**
 * On the server: makes (or re-keys) the Talvio bot account for a hosted bot and writes its env file.
 *   cd /opt/talvio/app && node /root/bot-host.js <bot_username> <bot_name> <env_file>
 * Owner = the first person who signed up (the app owner). Prints who that is — never the token.
 */
const path = require('path');
const fs = require('fs');

const req = (p) => require(path.join(process.cwd(), p)); // eslint-disable-line global-require, import/no-dynamic-require
const db = req('src/db');
const bots = req('src/services/bot.service');

(async () => {
  const [username, name, envFile] = process.argv.slice(2);
  const owner = await db.one(
    `SELECT u.id, u.first_name, u.last_name, u.username FROM users u
     WHERE u.status = 'active' AND NOT COALESCE(u.is_bot, FALSE) AND u.first_name <> ''
     ORDER BY u.created_at, u.id LIMIT 1`,
  );
  if (!owner) throw new Error('no owner account');
  const existing = await db.one(
    `SELECT b.user_id, b.owner_id FROM bots b JOIN users u ON u.id = b.user_id WHERE lower(u.username) = lower($1) AND b.status = 'active'`,
    [username],
  );
  let token;
  let botId;
  if (existing) {
    const r = await bots.regenerateToken(existing.owner_id, existing.user_id);
    token = r.classic_token;
    botId = existing.user_id;
  } else {
    const r = await bots.createBot(owner.id, { name, username });
    token = r.classic_token;
    botId = r.bot.id;
  }
  fs.writeFileSync(envFile, `BOT_TOKEN=${token}\nADMIN_ID=${owner.id}\n`, { mode: 0o600 });
  console.log(`owner: ${owner.first_name} ${owner.last_name || ''} @${owner.username || '-'} id=${owner.id}`); // eslint-disable-line no-console
  console.log(`bot: @${username} id=${botId} (${existing ? 'existing, new key' : 'created'})`); // eslint-disable-line no-console
  await db.close();
})().catch(async (e) => {
  console.error('bot-host failed:', e.message); // eslint-disable-line no-console
  process.exit(1);
});
