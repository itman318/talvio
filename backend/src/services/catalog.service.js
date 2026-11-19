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
  await require('./tags.service').assertNotBlocked(userId, 'sell'); // eslint-disable-line global-require
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
async function buy(userId, idRaw, body = {}) {
  await require('./settings.service').requireFeature('feature_coins', 'Coins'); // eslint-disable-line global-require
  const item = await db.one('SELECT * FROM catalog_items WHERE id = $1 AND deleted_at IS NULL', [v.id(idRaw, 'item_id')]);
  if (!item) throw notFound('item_not_found', 'This product is no longer available');
  const sellerId = Number(item.owner_id);
  if (sellerId === userId) throw badRequest('invalid_input', 'This is your own product');
  if (item.sold_out) throw conflict('sold_out', 'This product is sold out');
  if (!item.price_coins) throw badRequest('invalid_input', 'This product can’t be bought with coins — order it in the chat');
  // the seller changed the price after the buyer opened the product: never charge a price they didn't see
  if (body.expected_coins !== undefined && Number(body.expected_coins) !== Number(item.price_coins)) {
    throw conflict('price_changed', `The price changed to ${Number(item.price_coins).toLocaleString('en-US')} coins — check it and try again`);
  }
  const seller = await db.one(`SELECT id, tags FROM users WHERE id = $1 AND status = 'active' AND NOT is_bot`, [sellerId]);
  if (!seller) throw notFound('user_not_found', 'This seller is no longer available');
  if ((seller.tags || []).some((t) => ['scam', 'fake'].includes(t))) throw forbidden('seller_flagged', 'This seller is flagged after confirmed scam reports — buying is turned off');
  await require('./tags.service').assertNotBlocked(userId, 'pay with coins'); // eslint-disable-line global-require
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
      `INSERT INTO catalog_orders (item_id, buyer_id, seller_id, coins, title, paid_with, price_text, chat_id, history)
       VALUES ($1, $2, $3, $4, $5, 'coins', $6, $7, $8) RETURNING id`,
      [item.id, userId, sellerId, price, item.title, item.price_text || null, chatIdOf(chat), JSON.stringify([{ status: 'received', at: new Date().toISOString() }])],
    )).rows[0];
    await c.query('UPDATE catalog_items SET sold = sold + 1 WHERE id = $1', [item.id]);
    return { mine, theirs, orderId: Number(o.id) };
  });
  coins.announce(userId, r.mine);
  coins.announce(sellerId, r.theirs);
  const chatId = chatIdOf(chat);
  await require('./message.service').sendMessage(userId, chatId, { // eslint-disable-line global-require
    text: `🛒 **Order #${r.orderId}**\n${item.title}\nPaid ${price.toLocaleString('en-US')} coins 🪙\nStatus: 📥 Received`,
    client_id: `order-${r.orderId}`,
  }).catch(() => null);
  await require('./notice.service').notify(sellerId, 'payment', `New order: ${item.title}`, `${price.toLocaleString('en-US')} coins were added to your balance.`, { chat_id: chatId, order_id: r.orderId }).catch(() => null); // eslint-disable-line global-require
  return { ok: true, order_id: r.orderId, balance: r.mine, chat_id: chatId };
}

const chatIdOf = (chat) => chat.id || (chat.chat && chat.chat.id);

// ------------------------------------------------------------------ order tracker
const STATUSES = ['received', 'packed', 'shipped', 'delivered', 'cancelled'];
const STATUS_LABEL = { received: '📥 Received', packed: '📦 Packed', shipped: '🚚 Shipped', delivered: '✅ Delivered', cancelled: '✖️ Cancelled' };

function serializeOrder(o, users) {
  return {
    id: Number(o.id),
    item_id: o.item_id ? Number(o.item_id) : null,
    title: o.title,
    qty: Number(o.qty || 1),
    note: o.note || '',
    coins: Number(o.coins || 0),
    price_text: o.price_text || null,
    paid_with: o.paid_with,
    status: o.status,
    history: o.history || [],
    chat_id: o.chat_id ? Number(o.chat_id) : null,
    buyer: users && o.buyer_id ? users.get(Number(o.buyer_id)) || null : null,
    seller: users && o.seller_id ? users.get(Number(o.seller_id)) || null : null,
    buyer_id: o.buyer_id ? Number(o.buyer_id) : null,
    seller_id: o.seller_id ? Number(o.seller_id) : null,
    created_at: new Date(o.created_at).toISOString(),
    updated_at: new Date(o.updated_at || o.created_at).toISOString(),
  };
}

/** "Order in chat": no coins move — the order is written in the chat and the seller can track it. */
async function order(userId, idRaw, body = {}) {
  const item = await db.one('SELECT * FROM catalog_items WHERE id = $1 AND deleted_at IS NULL', [v.id(idRaw, 'item_id')]);
  if (!item) throw notFound('item_not_found', 'This product is no longer available');
  const sellerId = Number(item.owner_id);
  if (sellerId === userId) throw badRequest('invalid_input', 'This is your own product');
  if (item.sold_out) throw conflict('sold_out', 'This product is sold out');
  const qty = body.qty === undefined ? 1 : Number(body.qty);
  if (!Number.isInteger(qty) || qty < 1 || qty > 99) throw badRequest('invalid_input', 'Quantity must be 1–99');
  const note = v.str(body.note, { field: 'note', max: 300 }) || '';
  const users = require('./user.service'); // eslint-disable-line global-require
  if (await users.isBlockedEither(userId, sellerId)) throw forbidden('blocked', 'You can’t order from this seller');
  const seller = await db.one(`SELECT id, tags FROM users WHERE id = $1 AND status = 'active' AND NOT is_bot`, [sellerId]);
  if (!seller) throw notFound('user_not_found', 'This seller is no longer available');
  rateLimit.enforce(`catalog:order:${userId}`, 30, 60 * 60 * 1000, 'Too many orders. Try again later.');
  const chat = await require('./chat.service').getOrCreatePrivate(userId, sellerId); // eslint-disable-line global-require
  const chatId = chatIdOf(chat);
  const o = await db.one(
    `INSERT INTO catalog_orders (item_id, buyer_id, seller_id, coins, title, paid_with, price_text, qty, note, chat_id, history)
     VALUES ($1, $2, $3, 0, $4, 'chat', $5, $6, $7, $8, $9) RETURNING *`,
    [item.id, userId, sellerId, item.title, item.price_text || null, qty, note, chatId, JSON.stringify([{ status: 'received', at: new Date().toISOString() }])],
  );
  const price = item.price_text ? `\nPrice: ${item.price_text}` : '';
  await require('./message.service').sendMessage(userId, chatId, { // eslint-disable-line global-require
    text: `🧾 **Order #${o.id}**\n${item.title}${qty > 1 ? ` × ${qty}` : ''}${price}${note ? `\nNote: ${note}` : ''}\nStatus: 📥 Received`,
    client_id: `order-${o.id}`,
  }).catch(() => null);
  await require('./notice.service').notify(sellerId, 'payment', `New order: ${item.title}`, 'Open Orders to update its status.', { chat_id: chatId, order_id: Number(o.id) }).catch(() => null); // eslint-disable-line global-require
  return { ok: true, order_id: Number(o.id), chat_id: chatId };
}

async function orders(userId, query = {}) {
  const role = query.role === 'seller' ? 'seller' : 'buyer';
  const rows = await db.many(
    `SELECT * FROM catalog_orders WHERE ${role}_id = $1 ${query.open === '1' ? `AND status NOT IN ('delivered', 'cancelled')` : ''} ORDER BY id DESC LIMIT 200`,
    [userId],
  );
  const ids = [...new Set(rows.flatMap((r) => [r.buyer_id, r.seller_id]).filter(Boolean).map(Number))];
  const users = await require('./user.service').getUsersMap(userId, ids); // eslint-disable-line global-require
  return { role, orders: rows.map((o) => serializeOrder(o, users)) };
}

/**
 * The seller moves an order along: received → packed → shipped → delivered (or cancels it).
 * A buyer can cancel only while it is still "received". Cancelling an order paid with coins refunds them.
 */
async function setStatus(userId, idRaw, body = {}) {
  const status = v.oneOf(body.status, STATUSES.slice(1), 'status');
  const id = v.id(idRaw, 'order_id');
  const coins = require('./coin.service'); // eslint-disable-line global-require
  const r = await db.tx(async (c) => {
    const o = (await c.query('SELECT * FROM catalog_orders WHERE id = $1 FOR UPDATE', [id])).rows[0];
    if (!o || (Number(o.seller_id) !== userId && Number(o.buyer_id) !== userId)) throw notFound('order_not_found', 'Order not found');
    const seller = Number(o.seller_id) === userId;
    if (['delivered', 'cancelled'].includes(o.status)) throw conflict('order_closed', `This order is already ${o.status}`);
    if (!seller && !(status === 'cancelled' && o.status === 'received')) throw forbidden('not_allowed', 'Only the seller can update this order');
    if (status !== 'cancelled' && STATUSES.indexOf(status) <= STATUSES.indexOf(o.status)) throw conflict('invalid_status', 'An order only moves forward');
    const history = [...(o.history || []), { status, at: new Date().toISOString(), by: seller ? 'seller' : 'buyer' }];
    const u = (await c.query('UPDATE catalog_orders SET status = $2, history = $3, updated_at = now() WHERE id = $1 RETURNING *', [id, status, JSON.stringify(history)])).rows[0];
    let refund = null;
    if (status === 'cancelled' && o.paid_with === 'coins' && Number(o.coins) > 0 && o.buyer_id && o.seller_id) {
      await c.query('SELECT id FROM users WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [o.buyer_id, o.seller_id]);
      const note = `Refund: ${o.title}`.slice(0, 120);
      const back = await coins.change(c, Number(o.seller_id), -Number(o.coins), 'shop_refund', { peerId: Number(o.buyer_id), note });
      const got = await coins.change(c, Number(o.buyer_id), Number(o.coins), 'shop_refund', { peerId: Number(o.seller_id), note });
      refund = { back, got };
    }
    return { o: u, seller, refund };
  });
  if (r.refund) {
    coins.announce(Number(r.o.seller_id), r.refund.back);
    coins.announce(Number(r.o.buyer_id), r.refund.got);
  }
  const other = r.seller ? Number(r.o.buyer_id) : Number(r.o.seller_id);
  const refundLine = r.refund ? `\n${Number(r.o.coins).toLocaleString('en-US')} coins refunded 🪙` : '';
  if (r.o.chat_id) {
    await require('./message.service').sendMessage(userId, Number(r.o.chat_id), { // eslint-disable-line global-require
      text: `${status === 'cancelled' ? '✖️' : '📦'} **Order #${r.o.id}** · ${r.o.title}\nStatus: ${STATUS_LABEL[status]}${refundLine}`,
      client_id: `order-${r.o.id}-${status}`,
    }).catch(() => null);
  }
  if (other) {
    await require('./notice.service').notify(other, 'payment', `Order #${r.o.id}: ${STATUS_LABEL[status].replace(/^\S+ /, '')}`, r.o.title, { chat_id: r.o.chat_id ? Number(r.o.chat_id) : null, order_id: Number(r.o.id) }).catch(() => null); // eslint-disable-line global-require
  }
  return { ok: true, order: serializeOrder(r.o) };
}

module.exports = { list, add, update, remove, buy, order, orders, setStatus, STATUSES, MAX_ITEMS };
