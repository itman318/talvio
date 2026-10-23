'use strict';

const config = require('../config');

/**
 * Sends an email through the configured provider (MAIL_PROVIDER):
 *  - console: prints to the server log (development)
 *  - brevo:   Brevo (Sendinblue) HTTP API — BREVO_API_KEY (free plan: a few hundred emails a day)
 *  - resend:  Resend HTTP API — RESEND_API_KEY
 *  - smtp:    any SMTP server (Gmail app password, Zoho, your host) — SMTP_HOST/PORT/USER/PASS,
 *             needs the optional "nodemailer" package
 */
async function send(to, subject, text, html) {
  const m = config.mail;
  if (m.provider === 'console') {
    // eslint-disable-next-line no-console
    console.log(`[MAIL → ${to}] ${subject}\n${text}`);
    return;
  }
  if (m.provider === 'brevo') return sendBrevo(to, subject, text, html);
  if (m.provider === 'resend') return sendResend(to, subject, text, html);
  if (m.provider === 'smtp') return sendSmtp(to, subject, text, html);
  throw new Error(`Unknown MAIL_PROVIDER: ${m.provider}`);
}

function parseFrom(from) {
  const match = /^\s*(.*?)\s*<([^>]+)>\s*$/.exec(from);
  return match ? { name: match[1] || undefined, email: match[2] } : { email: from.trim() };
}

async function sendBrevo(to, subject, text, html) {
  if (!config.mail.brevoKey) throw new Error('BREVO_API_KEY is not set');
  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': config.mail.brevoKey, 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ sender: parseFrom(config.mail.from), to: [{ email: to }], subject, textContent: text, htmlContent: html || undefined }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`Brevo responded ${res.status}: ${(await res.text()).slice(0, 200)}`);
}

async function sendResend(to, subject, text, html) {
  if (!config.mail.resendKey) throw new Error('RESEND_API_KEY is not set');
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { authorization: `Bearer ${config.mail.resendKey}`, 'content-type': 'application/json' },
    body: JSON.stringify({ from: config.mail.from, to: [to], subject, text, html: html || undefined }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`Resend responded ${res.status}: ${(await res.text()).slice(0, 200)}`);
}

let transport;
async function sendSmtp(to, subject, text, html) {
  const m = config.mail;
  if (!m.smtpHost) throw new Error('SMTP_HOST is not set');
  if (!transport) {
    let nodemailer;
    try {
      nodemailer = require('nodemailer'); // optional dependency
    } catch (_) {
      throw new Error('MAIL_PROVIDER=smtp needs the "nodemailer" package: npm install nodemailer');
    }
    transport = nodemailer.createTransport({
      host: m.smtpHost,
      port: m.smtpPort,
      secure: m.smtpPort === 465,
      auth: m.smtpUser ? { user: m.smtpUser, pass: m.smtpPass } : undefined,
    });
  }
  await transport.sendMail({ from: m.from, to, subject, text, html: html || undefined });
}

/** The login-code email. */
function codeEmail(code, appName = 'Talvio') {
  const subject = `${code} is your ${appName} code`;
  const text = `Your ${appName} login code is ${code}.\n\nIt expires in 5 minutes. If you didn't ask for it, ignore this email — nobody can log in without the code.`;
  const html = `<div style="font-family:system-ui,Segoe UI,Roboto,sans-serif;max-width:420px;margin:0 auto;padding:24px;color:#1d1b2f">
  <div style="width:48px;height:48px;border-radius:15px;background:linear-gradient(135deg,#F2603D,#E9447A)"></div>
  <h2 style="margin:18px 0 6px">Your ${appName} code</h2>
  <p style="color:#7d7589;margin:0 0 18px">Enter this code in the app to log in.</p>
  <div style="font-size:34px;letter-spacing:10px;font-weight:800;background:#fbf3ee;border-radius:14px;padding:14px 0;text-align:center">${code}</div>
  <p style="color:#7d7589;font-size:13px;margin-top:18px">It expires in 5 minutes. If you didn't ask for it, you can ignore this email.</p>
</div>`;
  return { subject, text, html };
}

module.exports = { send, codeEmail };
