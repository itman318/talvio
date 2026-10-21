'use strict';

/** Creates / updates the database tables. Safe to run on every deploy. */
const fs = require('fs');
const path = require('path');
const db = require('../src/db');

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8');
  await db.query(sql);
  // eslint-disable-next-line no-console
  console.log('Database schema is up to date.');
  await db.close();
})().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('Migration failed:', err.message);
  process.exit(1);
});
