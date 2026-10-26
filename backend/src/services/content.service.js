'use strict';

/** Admin-editable text pages: Terms, Privacy Policy, FAQ, About. */
const db = require('../db');
const v = require('../utils/validate');
const { notFound } = require('../utils/errors');

const SLUGS = ['terms', 'privacy', 'faq', 'about'];

/**
 * Built-in starting texts, shown until an admin edits the page (Admin → Pages & FAQ).
 * Written for a messaging app that stores normal chats on the server and vault chats only end-to-end encrypted.
 */
const DEFAULTS = require('./content_defaults');

function serialize(p) {
  return { slug: p.slug, title: p.title, body: p.body, updated_at: new Date(p.updated_at).toISOString() };
}

async function get(slugRaw) {
  const slug = String(slugRaw || '').toLowerCase();
  if (!SLUGS.includes(slug)) throw notFound('page_not_found', 'Page not found');
  const p = await db.one('SELECT * FROM content_pages WHERE slug = $1', [slug]);
  if (!p || (!String(p.body || '').trim() && DEFAULTS[slug])) {
    if (DEFAULTS[slug]) return { slug, ...DEFAULTS[slug], updated_at: p ? new Date(p.updated_at).toISOString() : null, is_default: true };
    throw notFound('page_not_found', 'Page not found');
  }
  return serialize(p);
}

async function list() {
  const rows = await db.many('SELECT * FROM content_pages ORDER BY slug');
  // show the built-in texts in the admin editor until they are customised
  return rows.map((r) => (!String(r.body || '').trim() && DEFAULTS[r.slug] ? { ...serialize(r), ...DEFAULTS[r.slug], is_default: true } : serialize(r)));
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
  // line-based: "# h2", "## h3", "• list", "Q:"/"A:" (FAQ), blank line = paragraph
  const out = [];
  let para = [];
  let list = [];
  let updated = null;
  const flushPara = () => {
    if (para.length) out.push(`<p>${para.map(escapeHtml).join('<br>')}</p>`);
    para = [];
  };
  const flushList = () => {
    if (list.length) out.push(`<ul>${list.map((x) => `<li>${escapeHtml(x)}</li>`).join('')}</ul>`);
    list = [];
  };
  const flush = () => {
    flushPara();
    flushList();
  };
  for (const raw of String(page.body || '').replace(/\r/g, '').split('\n')) {
    const t = raw.trim();
    if (!t) {
      flush();
    } else if (t.startsWith('Last updated:')) {
      updated = t;
    } else if (t.startsWith('## ')) {
      flush();
      out.push(`<h3>${escapeHtml(t.slice(3))}</h3>`);
    } else if (t.startsWith('# ')) {
      flush();
      out.push(`<h2>${escapeHtml(t.slice(2))}</h2>`);
    } else if (t.startsWith('• ')) {
      flushPara();
      list.push(t.slice(2));
    } else if (t.startsWith('Q: ')) {
      flush();
      out.push(`<h4>${escapeHtml(t.slice(3))}</h4>`);
    } else if (t.startsWith('A: ')) {
      flush();
      out.push(`<p>${escapeHtml(t.slice(3))}</p>`);
    } else {
      flushList();
      para.push(t);
    }
  }
  flush();
  const blocks = out.join('\n');
  const when = updated ? escapeHtml(updated) : `Last updated ${escapeHtml((page.updated_at || new Date().toISOString()).slice(0, 10))}`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(page.title)} · Talvio</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:760px;margin:0 auto;padding:28px 18px 60px;line-height:1.65;color:#17202b;background:#fafbff}
h1{font-size:28px;margin:0 0 4px;letter-spacing:-.4px}h2{font-size:20px;margin-top:30px;padding-left:10px;border-left:4px solid #7b4fe0}h3{font-size:16px;margin:18px 0 6px}
h4{font-size:15.5px;margin:22px 0 4px;color:#3b2fa8}ul{padding-left:22px}li{margin:5px 0}.muted{color:#64748b;font-size:13px}
@media (prefers-color-scheme:dark){body{background:#0d1122;color:#e7e9f3}h4{color:#a99cff}.muted{color:#8a93b4}}</style>
</head><body><h1>${escapeHtml(page.title)}</h1><div class="muted">${when}</div>
${blocks || '<p class="muted">This page has not been written yet.</p>'}
</body></html>`;
}

module.exports = { SLUGS, get, list, update, renderHtml };
