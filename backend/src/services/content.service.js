'use strict';

/** Admin-editable text pages: Terms, Privacy Policy, FAQ, About. */
const db = require('../db');
const v = require('../utils/validate');
const { notFound } = require('../utils/errors');

const SLUGS = ['terms', 'privacy', 'faq', 'about'];

function serialize(p) {
  return { slug: p.slug, title: p.title, body: p.body, updated_at: new Date(p.updated_at).toISOString() };
}

async function get(slugRaw) {
  const slug = String(slugRaw || '').toLowerCase();
  if (!SLUGS.includes(slug)) throw notFound('page_not_found', 'Page not found');
  const p = await db.one('SELECT * FROM content_pages WHERE slug = $1', [slug]);
  if (!p) throw notFound('page_not_found', 'Page not found');
  return serialize(p);
}

async function list() {
  const rows = await db.many('SELECT * FROM content_pages ORDER BY slug');
  return rows.map(serialize);
}

async function update(adminId, slugRaw, body = {}) {
  const slug = v.oneOf(String(slugRaw || '').toLowerCase(), SLUGS, 'slug');
  const title = v.str(body.title, { field: 'title', min: 1, max: 120, required: true });
  const text = v.str(body.body, { field: 'body', max: 100000, trim: false }) || '';
  const p = await db.one(
    `INSERT INTO content_pages (slug, title, body, updated_by, updated_at) VALUES ($1, $2, $3, $4, now())
     ON CONFLICT (slug) DO UPDATE SET title = EXCLUDED.title, body = EXCLUDED.body,
       updated_by = EXCLUDED.updated_by, updated_at = now()
     RETURNING *`,
    [slug, title, text, adminId],
  );
  return serialize(p);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** Plain HTML page for store listings / links (text paragraphs, "# " lines become headings). */
function renderHtml(page) {
  const blocks = page.body
    .split(/\n{2,}/)
    .map((b) => b.trim())
    .filter(Boolean)
    .map((b) => (b.startsWith('# ') ? `<h2>${escapeHtml(b.slice(2))}</h2>` : `<p>${escapeHtml(b).replace(/\n/g, '<br>')}</p>`))
    .join('\n');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(page.title)}</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;line-height:1.6;color:#17202b}h1{font-size:26px}h2{font-size:19px;margin-top:28px}.muted{color:#64748b;font-size:13px}</style>
</head><body><h1>${escapeHtml(page.title)}</h1><div class="muted">Last updated ${escapeHtml(page.updated_at.slice(0, 10))}</div>
${blocks || '<p class="muted">This page has not been written yet.</p>'}
</body></html>`;
}

module.exports = { SLUGS, get, list, update, renderHtml };
