'use strict';

/** Chat folders: named tabs that group chats (explicit chats + type filters). */
const db = require('../db');
const v = require('../utils/validate');
const { badRequest, notFound } = require('../utils/errors');

const MAX_FOLDERS = 10;

function serialize(f) {
  return {
    id: f.id,
    name: f.name,
    chat_ids: f.chat_ids || [],
    include_private: f.include_private,
    include_groups: f.include_groups,
    include_channels: f.include_channels,
    include_unread_only: f.include_unread_only,
    position: f.position,
  };
}

/** Keeps only chats the user is actually in. */
async function ownChatIds(userId, raw) {
  const ids = v.idList(raw || [], 'chat_ids', 200);
  if (!ids.length) return [];
  const rows = await db.many('SELECT chat_id FROM chat_members WHERE user_id = $1 AND chat_id = ANY($2::bigint[])', [userId, ids]);
  const allowed = new Set(rows.map((r) => r.chat_id));
  return ids.filter((id) => allowed.has(id));
}

function readFlags(body, base = {}) {
  const out = { ...base };
  for (const k of ['include_private', 'include_groups', 'include_channels', 'include_unread_only']) {
    if (body[k] !== undefined) out[k] = v.bool(body[k], k);
  }
  return out;
}

async function list(userId) {
  const rows = await db.many('SELECT * FROM chat_folders WHERE user_id = $1 ORDER BY position, id', [userId]);
  return rows.map(serialize);
}

async function create(userId, body = {}) {
  const name = v.str(body.name, { field: 'name', min: 1, max: 24, required: true });
  const n = await db.one('SELECT count(*) AS n FROM chat_folders WHERE user_id = $1', [userId]);
  const max = (await require('./payment.service').limitsFor(userId)).folders;
  if (Number(n.n) >= max) {
    throw badRequest('too_many_folders', `You can have up to ${max} folders${max === MAX_FOLDERS ? ' (Talvio Plus: more)' : ''}`);
  }
  const flags = readFlags(body, { include_private: false, include_groups: false, include_channels: false, include_unread_only: false });
  const chatIds = await ownChatIds(userId, body.chat_ids);
  if (!chatIds.length && !flags.include_private && !flags.include_groups && !flags.include_channels) {
    throw badRequest('empty_folder', 'Add some chats or chat types to the folder');
  }
  const row = await db.one(
    `INSERT INTO chat_folders (user_id, name, chat_ids, include_private, include_groups, include_channels, include_unread_only, position)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *`,
    [userId, name, JSON.stringify(chatIds), flags.include_private, flags.include_groups, flags.include_channels, flags.include_unread_only, n.n],
  );
  return serialize(row);
}

async function update(userId, folderIdRaw, body = {}) {
  const f = await db.one('SELECT * FROM chat_folders WHERE id = $1 AND user_id = $2', [v.id(folderIdRaw, 'folder_id'), userId]);
  if (!f) throw notFound('folder_not_found', 'Folder not found');
  const name = body.name === undefined ? f.name : v.str(body.name, { field: 'name', min: 1, max: 24 });
  const flags = readFlags(body, f);
  const chatIds = body.chat_ids === undefined ? f.chat_ids : await ownChatIds(userId, body.chat_ids);
  const row = await db.one(
    `UPDATE chat_folders SET name = $2, chat_ids = $3, include_private = $4, include_groups = $5,
       include_channels = $6, include_unread_only = $7 WHERE id = $1 RETURNING *`,
    [f.id, name, JSON.stringify(chatIds), flags.include_private, flags.include_groups, flags.include_channels, flags.include_unread_only],
  );
  return serialize(row);
}

async function remove(userId, folderIdRaw) {
  const r = await db.one('DELETE FROM chat_folders WHERE id = $1 AND user_id = $2 RETURNING id', [v.id(folderIdRaw, 'folder_id'), userId]);
  if (!r) throw notFound('folder_not_found', 'Folder not found');
  return { ok: true };
}

async function reorder(userId, idsRaw) {
  const ids = v.idList(idsRaw, 'folder_ids', MAX_FOLDERS);
  await db.tx(async (c) => {
    for (let i = 0; i < ids.length; i += 1) {
      await c.query('UPDATE chat_folders SET position = $3 WHERE id = $1 AND user_id = $2', [ids[i], userId, i]);
    }
  });
  return list(userId);
}

module.exports = { list, create, update, remove, reorder };
