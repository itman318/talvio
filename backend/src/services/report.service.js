'use strict';

const db = require('../db');
const rateLimit = require('../utils/rateLimit');
const v = require('../utils/validate');
const { notFound, conflict } = require('../utils/errors');

const TARGETS = ['user', 'message', 'chat'];
const REASONS = ['spam', 'abuse', 'scam', 'violence', 'sexual', 'illegal', 'other'];

/** Builds an evidence snapshot so moderators can still see content if it gets deleted later. */
async function buildSnapshot(reporterId, targetType, targetId) {
  if (targetType === 'user') {
    const u = await db.one('SELECT id, username, first_name, last_name, bio, status FROM users WHERE id = $1', [targetId]);
    if (!u || u.status === 'deleted') throw notFound('user_not_found', 'User not found');
    return { user: u };
  }
  if (targetType === 'message') {
    const m = await db.one(
      `SELECT m.id, m.chat_id, m.sender_id, m.type, m.text, m.media_id, m.created_at, m.forwarded_from_name
       FROM messages m JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = $2
       WHERE m.id = $1 AND m.deleted_at IS NULL`,
      [targetId, reporterId],
    );
    if (!m) throw notFound('message_not_found', 'Message not found');
    const context = await db.many(
      `SELECT id, sender_id, type, text, created_at FROM messages
       WHERE chat_id = $1 AND id BETWEEN $2 - 200 AND $2 + 200 AND deleted_at IS NULL
       ORDER BY abs(id - $2) LIMIT 7`,
      [m.chat_id, m.id],
    );
    return { message: m, context: context.sort((a, b) => a.id - b.id) };
  }
  const c = await db.one(
    `SELECT c.id, c.type, c.title, c.description, c.created_by FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = $2 WHERE c.id = $1`,
    [targetId, reporterId],
  );
  if (!c) throw notFound('chat_not_found', 'Chat not found');
  return { chat: c };
}

async function createReport(reporterId, body = {}) {
  const targetType = v.oneOf(body.target_type, TARGETS, 'target_type');
  const targetId = v.id(body.target_id, 'target_id');
  const reason = v.oneOf(body.reason, REASONS, 'reason');
  const details = v.str(body.details, { field: 'details', max: 1000 }) || '';
  rateLimit.enforce(`report:${reporterId}`, 15, 60 * 60 * 1000, 'You have sent too many reports. Try later.');

  const snapshot = await buildSnapshot(reporterId, targetType, targetId);
  try {
    const r = await db.one(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason, details, snapshot)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
      [reporterId, targetType, targetId, reason, details, JSON.stringify(snapshot)],
    );
    return { ok: true, report_id: r.id };
  } catch (err) {
    if (err.code === '23505') throw conflict('already_reported', 'You already reported this. Our team will review it.');
    throw err;
  }
}

module.exports = { TARGETS, REASONS, createReport };
