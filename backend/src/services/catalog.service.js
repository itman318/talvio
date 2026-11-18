'use strict';

/**
 * Business catalog: a Hushavia Plus business lists its products (photo, name, price, description).
 * Customers open the catalog from the profile and either order in the chat, or buy right away
 * with Hushavia Coins (coins go from buyer to seller; the order lands in their chat).
 */
const db = require('../db');
const v = require('../utils/validate');
const rateLimit = require('../utils/rateLimit');
const { badRequest, forbidden, notFound, conflict } = require('../utils/errors');

const MAX_ITEMS = 200;
const MAX_COINS = 1000000;

async function requirePlus(userId) {
  const ok = await require('./payment.service').isPremium(userId); // eslint-disable-line global-require
  if (!ok) throw forbidden('premium_required', 'A catalog comes with Hushavia Business (Hushavia Plus)');
}

function serialize(r) {
  return {
    id: Number(r.id),
    owner_id: Number(r.owner_id),
    title: r.title,
    description: r.description,
    price_text: r.price_text || null,
    price_coins: r.price_coins ? Number(r.price_coins) : null,
    photo_url: r.photo_media_id ? `/api/media/${r.photo_media_id}/public` : null,
    sold_out: !!r.sold_out,
    sold: Number(r.sold || 0),
  };
}

async function list(viewerId, ownerIdRaw) {
  const ownerId = v.id(ownerIdRaw, 'user_id');
  const rows = await db.many(
    `SELECT * FROM catalog_items WHERE owner_id = $1 AND deleted_at IS NULL ORDER BY position, id DESC LIMIT ${MAX_ITEMS}`,
    [ownerId],
  );
  return { items: rows.map(serialize), mine: ownerId === viewerId };
}

async function fields(userId, body, partial) {
  const out = {};
  if (!partial || body.title !== undefined) out.title = v.str(body.title, { field: 'title', min: 1, max: 80 });
  if (!partial || body.description !== undefined) out.description = v.str(body.description, { field: 'description', max: 1000 }) || '';
  if (!partial || body.price_text !== undefined) out.price_text = v.str(body.price_text, { field: 'price_text', max: 40 }) || null;
  if (!partial || body.price_coins !== undefined) {
    const n = body.price_coins === null || body.price_coins === '' || body.price_coins === undefined ? null : Number(body.price_coins);
    if (n !== null && (!Number.isInteger(n) || n < 1 || n > MAX_COINS)) throw badRequest('invalid_input', `Coins price must be 1–${MAX_COINS.toLocaleString('en-US')}`);
    out.price_coins = n;
  }
  if (body.sold_out !== undefined) out.sold_out = !!body.sold_out;
  if (body.photo_media_id !== undefined) {
    if (body.photo_media_id === null) {
      out.photo_media_id = null;
    } else {
      const m = await db.one(`SELECT id FROM media WHERE id = $1 AND uploader_id = $2 AND kind = 'image'`, [v.id(body.photo_media_id, 'photo_media_id'), userId]);
      if (!m) throw badRequest('invalid_input', 'Photo not found');
      await db.query('UPDATE media SET is_public = TRUE WHERE id = $1', [m.id]); // shown to anyone who opens the catalog
      out.photo_media_id = m.id;
    }
  }
  return out;
}

async function add(userId, body = {}) {
  await requirePlus(userId);
  const n = await db.one('SELECT count(*)::int AS n FROM catalog_items WHERE owner_id = $1 AND deleted_at IS NULL', [userId]);
  if (n.n >= MAX_ITEMS) throw forbidden('catalog_full', `A catalog can have up to ${MAX_ITEMS} products`);
  const f = await fields(userId, body, false);
  const r = await db.one(
    `INSERT INTO catalog_items (owner_id, title, description, price_text, price_coins, photo_media_id, sold_out, position)
     VALUES ($1, $2, $3, $4, $5, $6, $7, (SELECT COALESCE(min(position), 0) - 1 FROM catalog_items WHERE owner_id = $1)) RETURNING *`,
    [userId, f.title, f.description, f.price_text, f.price_coins, f.photo_media_id || null, !!f.sold_out],
  );
  return serialize(r);
}

async function update(userId, idRaw, body = {}) {
  await requirePlus(userId);
  const f = await fields(userId, body, true);
  const keys = Object.keys(f);
  if (!keys.length) throw badRequest('invalid_input', 'Nothing to change');
  const sets = keys.map((k, i) => `${k} = $${i + 3}`).join(', ');
  const r = await db.one(
    `UPDATE catalog_items SET ${sets}, updated_at = now() WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL RETURNING *`,
    [v.id(idRaw, 'item_id'), userId, ...keys.map((k) => f[k])],
  );
  if (!r) throw notFound('item_not_found', 'Product not found');
  return serialize(r);
}

async function remove(userId, idRaw) {
  const r = await db.one('UPDATE catalog_items SET deleted_at = now() WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL RETURNING id', [v.id(idRaw, 'item_id'), userId]);
  if (!r) throw notFound('item_not_found', 'Product not found');
  return { ok: true };
}

/** Buy with coins: coins move buyer → seller, the order is written in their private chat. */
async function buy(userId, idRaw) {
  await require('./settings.service').requireFeature('feature_coins', 'Coins'); // eslint-disable-line global-require
  const item = await db.one('SELECT * FROM catalog_items WHERE id = $1 AND deleted_at IS NULL', [v.id(idRaw, 'item_id')]);
  if (!item) throw notFound('item_not_found', 'This product is no longer available');
  const sellerId = Number(item.owner_id);
  if (sellerId === userId) throw badRequest('invalid_input', 'This is your own product');
  if (item.sold_out) throw conflict('sold_out', 'This product is sold out');
  if (!item.price_coins) throw badRequest('invalid_input', 'This product can’t be bought with coins — order it in the chat');
  const users = require('./user.service'); // eslint-disable-line global-require
  if (await users.isBlockedEither(userId, sellerId)) throw forbidden('blocked', 'You can’t buy from this seller');
  rateLimit.enforce(`catalog:buy:${userId}`, 20, 60 * 60 * 1000, 'Too many orders. Try again later.');
  const chat = await require('./chat.service').getOrCreatePrivate(userId, sellerId); // eslint-disable-line global-require
  const coins = require('./coin.service'); // eslint-disable-line global-require
  const price = Number(item.price_coins);
  const r = await db.tx(async (c) => {
    await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [userId, sellerId]);
    // a double tap: the same product a moment ago
    const twice = (await c.query(
      `SELECT 1 FROM catalog_orders WHERE buyer_id = $1 AND item_id = $2 AND created_at > now() - interval '10 seconds' LIMIT 1`,
      [userId, item.id],
    )).rows[0];
    if (twice) throw conflict('just_bought', 'You bought this a moment ago — check your coin history first');
    const note = `Bought: ${item.title}`.slice(0, 120);
    const mine = await coins.change(c, userId, -price, 'shop_paid', { peerId: sellerId, note });
    const theirs = await coins.change(c, sellerId, price, 'shop_income', { peerId: userId, note });
    const o = (await c.query(
      'INSERT INTO catalog_orders (item_id, buyer_id, seller_id, coins, title) VALUES ($1, $2, $3, $4, $5) RETURNING id',
      [item.id, userId, sellerId, price, item.title],
    )).rows[0];
    await c.query('UPDATE catalog_items SET sold = sold + 1 WHERE id = $1', [item.id]);
    return { mine, theirs, orderId: Number(o.id) };
  });
  coins.announce(userId, r.mine);
  coins.announce(sellerId, r.theirs);
  const chatId = chat.id || (chat.chat && chat.chat.id);
  await require('./message.service').sendMessage(userId, chatId, { // eslint-disable-line global-require
    text: `🛒 Order #${r.orderId}\n${item.title}\nPaid ${price.toLocaleString('en-US')} coins 🪙`,
    client_id: `order-${r.orderId}`,
  }).catch(() => null);
  await require('./notice.service').notify(sellerId, 'payment', `New order: ${item.title}`, `${price.toLocaleString('en-US')} coins were added to your balance.`, { chat_id: chatId, order_id: r.orderId }).catch(() => null); // eslint-disable-line global-require
  return { ok: true, order_id: r.orderId, balance: r.mine, chat_id: chatId };
}

module.exports = { list, add, update, remove, buy, MAX_ITEMS };
