'use strict';

/**
 * Talvio Bot API v2 — Talvio's own bot interface.
 *
 *   POST https://<server>/api/bots/v2/<method>        header  X-Bot-Key: <key>   (or Authorization: Bearer <key>)
 *   JSON, form or multipart (field "file")             →  { ok: true, data } | { ok: false, error: { code, message } }
 *
 * Words used everywhere: conversation (`to`), person, message, event, buttons (under a message),
 * keyboard (instead of the phone keyboard), press (a button was tapped), search (inline mode), hook (webhook).
 *
 * Methods
 *   profile.get · profile.update {name, description, app_url}
 *   events.poll {after, wait, max} · hook.set {url, secret?} · hook.remove {drop_pending} · hook.status
 *   message.send {to, text, reply_to, topic, silent, buttons, keyboard, keyboard_once, keyboard_hint, hide_keyboard}
 *   message.photo / message.file (multipart "file", text = caption) · message.edit {to, message, text, buttons}
 *   message.buttons {to, message, buttons} · message.delete · message.pin · message.unpin {to, message}
 *   message.forward {to, from, message} · poll.send {to, question, options, anonymous, multiple, quiz, closes_in}
 *   place.send {to, lat, lng, title} · activity.show {to, activity: typing|photo|video|file|voice|sticker}
 *   button.reply {press, notice, alert, link} · commands.set {commands: [{name, about}]} · commands.get · commands.clear
 *   conversation.get {to} · conversation.member {to, person} · conversation.size {to}
 *   inline.reply {search, results: [{id, title, subtitle, text, image, buttons}]}
 *
 * Events (events.poll / hook): { event_id, kind, at, … }
 *   message      → message: { id, conversation, author, sent_at, text, reply_to, topic, attachment, place }
 *   button_press → press: { id, data, message_id, conversation, author }
 *   inline_search→ search: { id, query, author }
 *   app_data     → app_data: { data, button, conversation, author }
 * Hooks are signed: X-Talvio-Signature: sha256=HEX(HMAC_SHA256(secret, raw body)), plus X-Talvio-Event-Id.
 */
const crypto = require('crypto');
const db = require('../db');
const botService = require('./bot.service');
const { AppError, badRequest } = require('../utils/errors');

// ------------------------------------------------------------------ v1 → v2 shapes
function person(u) {
  if (!u) return null;
  return { id: u.id, name: `${u.first_name || ''} ${u.last_name || ''}`.trim(), username: u.username || null, bot: !!u.is_bot };
}

function conversation(c) {
  if (!c) return null;
  const kind = c.type === 'private' ? 'direct' : c.type;
  return { id: c.id, kind, title: c.title || `${c.first_name || ''} ${c.last_name || ''}`.trim() || (c.username ? `@${c.username}` : '') };
}

const iso = (unixSec) => (unixSec ? new Date(unixSec * 1000).toISOString() : null);

function message(m) {
  if (!m || typeof m !== 'object') return m;
  const file = m.photo || m.video || m.voice || m.document;
  const kind = m.photo ? 'photo' : m.video ? 'video' : m.voice ? 'voice' : m.document ? 'file' : null;
  return {
    id: m.message_id,
    conversation: conversation(m.chat),
    author: person(m.from),
    sent_at: iso(m.date),
    text: m.text || m.caption || '',
    reply_to: m.reply_to_message ? m.reply_to_message.message_id : null,
    topic: m.message_thread_id || null,
    attachment: file ? { kind, file_id: file.file_id, size: file.file_size, mime: file.mime_type, name: file.file_name || null } : null,
    place: m.location ? { lat: m.location.latitude, lng: m.location.longitude } : null,
  };
}

/** A stored update (v1 shape) as a v2 event. */
function event(update, at) {
  const base = { event_id: Number(update.update_id), at: at ? new Date(at).toISOString() : new Date().toISOString() };
  if (update.callback_query) {
    const q = update.callback_query;
    return {
      ...base,
      kind: 'button_press',
      press: { id: q.id, data: q.data, message_id: q.message ? q.message.message_id : null, conversation: q.message ? conversation(q.message.chat) : null, author: person(q.from) },
    };
  }
  if (update.inline_query) {
    const q = update.inline_query;
    return { ...base, kind: 'inline_search', search: { id: q.id, query: q.query, author: person(q.from) } };
  }
  if (update.message && update.message.web_app_data) {
    const m = update.message;
    return { ...base, kind: 'app_data', app_data: { data: m.web_app_data.data, button: m.web_app_data.button_text || '', conversation: conversation(m.chat), author: person(m.from) } };
  }
  if (update.message) return { ...base, kind: 'message', message: message(update.message) };
  return { ...base, kind: 'unknown' };
}

/** Body + headers for a v2 hook delivery. */
function hookRequest(update, secret) {
  const body = JSON.stringify(event(update));
  const sig = crypto.createHmac('sha256', String(secret || '')).update(body).digest('hex');
  return { body, headers: { 'X-Talvio-Signature': `sha256=${sig}`, 'X-Talvio-Event-Id': String(update.update_id) } };
}

// ------------------------------------------------------------------ v2 → v1 params
function parseJson(x) {
  if (typeof x !== 'string') return x;
  try {
    return JSON.parse(x);
  } catch (_) {
    throw badRequest('invalid_input', 'buttons / keyboard / results must be JSON');
  }
}

/** [[{label, data | link | app | copy}]] → inline keyboard */
function buttons(raw) {
  const rows = parseJson(raw);
  if (rows === null || rows === undefined) return undefined;
  if (!Array.isArray(rows)) throw badRequest('invalid_buttons', 'buttons must be rows: [[{label, data}]]');
  return {
    inline_keyboard: rows.map((row) => (Array.isArray(row) ? row : [row]).map((b) => {
      const out = { text: b && b.label };
      if (b && b.data !== undefined) out.callback_data = String(b.data);
      else if (b && b.link) out.url = b.link;
      else if (b && b.app) out.web_app = { url: b.app };
      else if (b && b.copy !== undefined) out.copy_text = { text: String(b.copy) };
      return out;
    })),
  };
}

/** [["Yes", "No"], [{label: "Send my place", share_location: true}]] → reply keyboard */
function keyboard(raw, p) {
  const rows = parseJson(raw);
  if (!Array.isArray(rows)) throw badRequest('invalid_keyboard', 'keyboard must be rows of labels');
  return {
    keyboard: rows.map((row) => (Array.isArray(row) ? row : [row]).map((b) => (typeof b === 'string' ? { text: b } : { text: b && b.label, request_location: !!(b && b.share_location) }))),
    one_time_keyboard: p.keyboard_once === true || p.keyboard_once === 'true',
    ...(p.keyboard_hint ? { input_field_placeholder: p.keyboard_hint } : {}),
  };
}

function markup(p) {
  if (p.hide_keyboard === true || p.hide_keyboard === 'true') return { remove_keyboard: true };
  if (p.keyboard !== undefined) return keyboard(p.keyboard, p);
  return buttons(p.buttons);
}

const ACTIVITIES = { typing: 'typing', photo: 'uploading_photo', video: 'uploading_video', file: 'uploading_file', voice: 'recording_voice', sticker: 'choosing_sticker' };

const yes = (x) => x === true || x === 'true';

/** v2 method → [v1 method, v1 params, convert(result)] */
function translate(method, p) {
  const msg = (r) => message(r);
  const send = () => ({
    chat_id: p.to,
    text: p.text,
    caption: p.text,
    reply_to_message_id: p.reply_to,
    message_thread_id: p.topic,
    disable_notification: yes(p.silent),
    reply_markup: markup(p),
  });
  switch (method) {
    case 'profile.get':
      return ['me', {}, (r) => ({ ...person(r), groups: r.can_join_groups, sees_all_group_messages: r.can_read_all_group_messages, inline: r.supports_inline_queries })];
    case 'profile.update':
      return ['me.set', { name: p.name, description: p.description, menu_url: p.app_url }, () => true];
    case 'events.poll':
      return ['updates', { offset: p.after !== undefined ? Number(p.after) + 1 : undefined, timeout: p.wait, limit: p.max }, null];
    case 'hook.remove':
      return ['webhook.delete', { drop_pending_updates: yes(p.drop_pending) }, () => true];
    case 'hook.status':
      return ['webhook.info', {}, (r) => ({ url: r.url || null, pending: r.pending_update_count, last_error: r.last_error_message || null, last_error_at: iso(r.last_error_date) })];
    case 'message.send':
      return ['messages.send', send(), msg];
    case 'message.photo':
      return ['photos.send', send(), msg];
    case 'message.file':
      return ['files.send', send(), msg];
    case 'message.edit':
      return ['messages.edit', { chat_id: p.to, message_id: p.message, text: p.text, reply_markup: p.buttons === undefined ? undefined : buttons(p.buttons) || '' }, msg];
    case 'message.buttons':
      return ['messages.edit-buttons', { chat_id: p.to, message_id: p.message, reply_markup: buttons(p.buttons) || '' }, msg];
    case 'message.delete':
      return ['messages.delete', { chat_id: p.to, message_id: p.message }, () => true];
    case 'message.pin':
      return ['messages.pin', { chat_id: p.to, message_id: p.message }, () => true];
    case 'message.unpin':
      return ['messages.unpin', { chat_id: p.to, message_id: p.message }, () => true];
    case 'message.forward':
      return ['messages.forward', { chat_id: p.to, from_chat_id: p.from, message_id: p.message }, msg];
    case 'poll.send': {
      const quiz = parseJson(p.quiz);
      return ['polls.send', {
        chat_id: p.to,
        question: p.question,
        options: parseJson(p.options),
        is_anonymous: p.anonymous === undefined ? undefined : yes(p.anonymous),
        allows_multiple_answers: yes(p.multiple),
        type: quiz ? 'quiz' : undefined,
        correct_option_id: quiz ? quiz.correct : undefined,
        explanation: quiz ? quiz.explanation : undefined,
        open_period: p.closes_in,
        reply_markup: buttons(p.buttons),
      }, msg];
    }
    case 'place.send':
      return ['locations.send', { chat_id: p.to, latitude: p.lat, longitude: p.lng, title: p.title, reply_to_message_id: p.reply_to, reply_markup: markup(p) }, msg];
    case 'activity.show':
      return ['chat.action', { chat_id: p.to, action: ACTIVITIES[p.activity] || 'typing' }, () => true];
    case 'button.reply':
      return ['buttons.answer', { callback_query_id: p.press, text: p.notice, show_alert: yes(p.alert), url: p.link }, () => true];
    case 'commands.set': {
      const list = parseJson(p.commands);
      if (!Array.isArray(list)) throw badRequest('invalid_commands', 'commands: [{name, about}]');
      return ['commands.set', { commands: list.map((c) => ({ command: c && c.name, description: c && c.about })) }, () => true];
    }
    case 'commands.get':
      return ['commands.get', {}, (r) => r.map((c) => ({ name: c.command, about: c.description }))];
    case 'commands.clear':
      return ['commands.delete', {}, () => true];
    case 'conversation.get':
      return ['chats.get', { chat_id: p.to }, (r) => ({ ...conversation(r), description: r.description || '' })];
    case 'conversation.member':
      return ['chats.member', { chat_id: p.to, user_id: p.person }, (r) => ({ role: { creator: 'owner', administrator: 'admin', member: 'member' }[r.status] || 'not_member', person: person(r.user) })];
    case 'conversation.size':
      return ['chats.member-count', { chat_id: p.to }, (n) => ({ members: n })];
    case 'inline.reply': {
      const results = parseJson(p.results);
      if (!Array.isArray(results)) throw badRequest('invalid_results', 'results: [{id, title, text}]');
      return ['inline.answer', {
        inline_query_id: p.search,
        results: results.map((r) => ({ id: r && r.id, title: r && r.title, description: r && r.subtitle, text: r && r.text, thumb_url: r && r.image, reply_markup: r && r.buttons ? buttons(r.buttons) : undefined })),
      }, () => true];
    }
    default:
      return null;
  }
}

/** Runs a v2 method for the bot with this key. */
async function call(key, method, params = {}, file = null) {
  if (method === 'hook.set') {
    // own handling: v2 hooks are signed, so a secret always exists
    await botService.authenticate(key);
    const secret = params.secret ? String(params.secret) : crypto.randomBytes(24).toString('hex');
    await botService.callMethod(key, 'webhook.set', { url: params.url, secret_token: secret, api_version: 'v2' });
    return { url: params.url || null, secret };
  }
  const t = translate(method, params);
  if (!t) throw new AppError(404, 'unknown_method', `Unknown method "${method}" — see the Talvio Bot API v2 docs`);
  const [v1, p1, convert] = t;
  for (const k of Object.keys(p1)) if (p1[k] === undefined) delete p1[k];
  const result = await botService.callMethod(key, v1, p1, file);
  if (method === 'events.poll') {
    const rows = await db.many('SELECT id, created_at FROM bot_updates WHERE id = ANY($1::bigint[])', [result.map((u) => u.update_id)]);
    const at = new Map(rows.map((r) => [Number(r.id), r.created_at]));
    return { events: result.map((u) => event(u, at.get(Number(u.update_id)))) };
  }
  return convert ? convert(result) : result;
}

module.exports = { call, event, message, hookRequest };
