'use strict';

/**
 * Creates (or resets) a super admin.
 * Usage: node scripts/create-admin.js admin@example.com "StrongPassword123" "Your Name"
 */
const db = require('../src/db');
const { hashPassword } = require('../src/utils/crypto');

(async () => {
  const [email, password, name = 'Super Admin'] = process.argv.slice(2);
  if (!email || !password) {
    console.error('Usage: node scripts/create-admin.js <email> <password> [name]'); // eslint-disable-line no-console
    process.exit(1);
  }
  if (password.length < 10) {
    console.error('Password must be at least 10 characters'); // eslint-disable-line no-console
    process.exit(1);
  }
  const row = await db.one(
    `INSERT INTO admins (email, password_hash, name, role) VALUES (lower($1), $2, $3, 'super_admin')
     ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, name = EXCLUDED.name,
       role = 'super_admin', is_active = TRUE, token_version = admins.token_version + 1
     RETURNING id, email`,
    [email, hashPassword(password), name],
  );
  console.log(`Super admin ready: #${row.id} ${row.email}`); // eslint-disable-line no-console
  await db.close();
})().catch((err) => {
  console.error(err.message); // eslint-disable-line no-console
  process.exit(1);
});
