// Runs ON THE SERVER: logs in a throwaway test account and times every simple GET endpoint.
const fs = require('fs');
const BASE = 'http://127.0.0.1:4000/api';
const routes = fs.readFileSync('/opt/talvio/app/src/http/routes.user.js', 'utf8');
const paths = [...routes.matchAll(/router\.get\('([^']+)'/g)].map((m) => m[1]).filter((p) => !p.includes(':'));
async function call(method, path, body, token) {
  const t = Date.now();
  try {
    const r = await fetch(BASE + path, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(40000),
    });
    const text = await r.text();
    return { ms: Date.now() - t, status: r.status, text };
  } catch (e) {
    return { ms: Date.now() - t, status: 'ERR ' + e.name, text: '' };
  }
}
(async () => {
  const email = `diag${Date.now()}@example.com`;
  const req = await call('POST', '/auth/email/request', { email });
  console.log(`auth/email/request ${req.status} ${req.ms}ms`);
  const code = (JSON.parse(req.text || '{}').dev_code) || '';
  const ver = await call('POST', '/auth/email/verify', { email, code, device: { name: 'diag' } });
  console.log(`auth/email/verify ${ver.status} ${ver.ms}ms`);
  const token = (JSON.parse(ver.text || '{}').access_token) || '';
  if (!token) { console.log('no token: ' + ver.text.slice(0, 200)); return; }
  await call('PATCH', '/me', { first_name: 'Diag' }, token);
  const rows = [];
  for (const p of paths) {
    const r = await call('GET', p, null, token);
    rows.push([r.ms, p, r.status]);
  }
  rows.sort((a, b) => b[0] - a[0]);
  console.log('--- slowest GET endpoints');
  for (const [ms, p, st] of rows.slice(0, 15)) console.log(`${String(ms).padStart(6)}ms  ${st}  ${p}`);
  await call('DELETE', '/me', { confirm: 'DELETE' }, token);
})();
