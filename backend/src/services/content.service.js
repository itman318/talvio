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
const DEFAULTS = {
  privacy: {
    title: 'Privacy Policy',
    body: `Talvio ("we") runs the Talvio messaging app, web app and website. This policy explains what we collect and why.

WHAT WE COLLECT
• Account: your email address or phone number (used to log in with a one-time code), name, optional username, bio and profile photo.
• Messages and media: normal chats, groups and channels are stored on our servers so they sync to all your devices. Vault chats are end-to-end encrypted: the server only relays encrypted data it cannot read, and deletes it after delivery.
• Contacts (optional): if you allow it, phone numbers from your address book are compared with Talvio accounts to show which friends use Talvio. We do not keep your address book.
• Location (optional): only when you choose to share a location or live location in a chat.
• Device and usage data: device model, app version, IP address, login sessions, push-notification token, and crash reports that help us fix bugs.
• Payments: for Talvio Plus we keep the order, amount and status. Card/wallet details are handled by the payment provider (e.g. JazzCash, Easypaisa); we do not store them.

HOW WE USE IT
To provide and secure the service, deliver messages and notifications, prevent spam and abuse, handle reports, provide support, and improve the app. We do not sell your personal data. We do not use the content of your messages for advertising.

SHARING
Only with service providers that help us run Talvio (hosting, email/SMS delivery, push notifications, payments), when required by law, or to protect users from harm. Sponsored messages in public channels never use your private messages.

YOUR CHOICES
You can edit your profile, control who sees your last seen, photo and phone number (Settings → Privacy), log out other devices (Settings → Devices), download your data, and delete your account at any time (Settings → Privacy → Delete account). Deleting your account removes your profile and messages from our servers, except where the law requires us to keep records for a limited time.

CHILDREN
Talvio is not intended for children under 13.

SECURITY
We use encrypted connections (HTTPS), hashed login codes, and end-to-end encryption for vault chats. No system is 100% secure, so please keep your devices protected.

CHANGES AND CONTACT
We will post changes to this page. Questions: contact us from Settings → Help & support in the app.`,
  },
  terms: {
    title: 'Terms of Service',
    body: `By using Talvio you agree to these terms.

1. Your account. You must give a valid email address or phone number, keep your login codes private, and be at least 13 years old.
2. Acceptable use. Do not use Talvio to send spam, scams or malware; harass, threaten or impersonate others; share illegal content or content that sexualises minors; or break the law. We may remove content, limit features or ban accounts that break these rules, and report illegal activity to the authorities.
3. Your content. You keep the rights to what you send. You give us the permission needed to store and deliver it to the people you send it to.
4. Channels, groups and bots. Owners and admins are responsible for what they publish and for the bots they create.
5. Talvio Plus. Paid features are described in the app. Payments are processed by the listed providers; unless the law says otherwise, payments are not refundable once the subscription has started.
6. Availability. We work hard to keep Talvio running but cannot promise it will always be available or error-free. To the extent allowed by law, Talvio is provided "as is".
7. Ending. You can delete your account any time. We may suspend accounts that break these terms.
8. Changes. We may update these terms and will post the new version here; continuing to use Talvio means you accept it.

Questions: contact us from Settings → Help & support in the app.`,
  },
};

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
  const blocks = page.body
    .split(/\n{2,}/)
    .map((b) => b.trim())
    .filter(Boolean)
    .map((b) => (b.startsWith('# ') ? `<h2>${escapeHtml(b.slice(2))}</h2>` : `<p>${escapeHtml(b).replace(/\n/g, '<br>')}</p>`))
    .join('\n');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(page.title)}</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;line-height:1.6;color:#17202b}h1{font-size:26px}h2{font-size:19px;margin-top:28px}.muted{color:#64748b;font-size:13px}</style>
</head><body><h1>${escapeHtml(page.title)}</h1><div class="muted">Last updated ${escapeHtml((page.updated_at || new Date().toISOString()).slice(0, 10))}</div>
${blocks || '<p class="muted">This page has not been written yet.</p>'}
</body></html>`;
}

module.exports = { SLUGS, get, list, update, renderHtml };
