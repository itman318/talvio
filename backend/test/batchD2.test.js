'use strict';

/**
 * Batch D2 end-to-end tests: Premium plans & perks, payments (manual proof + admin approval,
 * JazzCash signed callback, Easypaisa request encryption + review fallback), admin grant/revoke,
 * sponsored messages (targeting, Premium = no ads, unique daily impressions/clicks), revenue report.
 * WARNING: the test database is wiped first.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://chat:chat@127.0.0.1:5432/chatapp_test';
process.env.OTP_DEV_MODE = 'true';

const config = require('../src/config');
const db = require('../src/db');
const rateLimit = require('../src/utils/rateLimit');
const cryptoUtil = require('../src/utils/crypto');
const auth = require('../src/services/auth.service');
const users = require('../src/services/user.service');
const chats = require('../src/services/chat.service');
const folders = require('../src/services/folder.service');
const media = require('../src/services/media.service');
const payments = require('../src/services/payment.service');
const jazzcash = require('../src/services/payments/jazzcash');
const easypaisa = require('../src/services/payments/easypaisa');
const ads = require('../src/services/ads.service');
const admin = require('../src/services/admin.service');
const settings = require('../src/services/settings.service');

async function rejects(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

let ip = 0;
async function signup(phone, firstName) {
  const addr = `10.11.0.${(ip += 1)}`;
  rateLimit.reset();
  const r = await auth.requestOtp(phone, addr);
  const s = await auth.verifyOtp(phone, r.dev_code, { platform: 'android', app_version: '1.0.0' }, addr);
  await users.updateProfile(s.user.id, { first_name: firstName });
  return { id: s.user.id };
}

function fakeUpload(userId, size = 1000, kind = 'image') {
  fs.mkdirSync(config.uploadDir, { recursive: true });
  const file = path.join(config.uploadDir, `test-d2-${Date.now()}-${Math.random().toString(36).slice(2)}.png`);
  fs.writeFileSync(file, Buffer.alloc(10));
  return media.registerUpload(userId, { path: file, size, mimetype: kind === 'image' ? 'image/png' : 'application/pdf', originalname: 'proof.png' }, { kind });
}

let A;
let B;
let C;
let boss;
let plan1;

test.before(async () => {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  settings.clearCache();
  await settings.update({ plus_usd_only: false }); // the rest of this file tests the local (PKR) gateways
  A = await signup('+923260000001', 'Asad');
  B = await signup('+923260000002', 'Bilal');
  C = await signup('+923260000003', 'Chand');
  boss = await db.one(`INSERT INTO admins (email, password_hash, name, role) VALUES ('root@example.com', $1, 'Root', 'super_admin') RETURNING *`, [
    cryptoUtil.hashPassword('RootPassword1'),
  ]);
});

test.beforeEach(() => rateLimit.reset());
test.after(async () => {
  for (const f of fs.readdirSync(config.uploadDir)) if (f.startsWith('test-d2-')) fs.rmSync(path.join(config.uploadDir, f), { force: true });
  await db.close();
});

test('premium info, manual payment with screenshot → admin approves → perks unlocked', async () => {
  const info = await payments.premiumInfo(A.id);
  assert.equal(info.is_premium, false);
  assert.deepEqual(info.plans.map((p) => [p.months, p.price_pkr]), [[1, 299], [3, 799], [6, 1499], [12, 2699]]);
  assert.deepEqual(info.plans.map((p) => p.save_percent), [0, 11, 16, 25]);
  assert.deepEqual(info.plans.map((p) => p.badge), [null, 'Popular', null, 'Best value']);
  assert.deepEqual(info.methods.map((m) => m.id), ['manual'], 'gateways hidden until configured');
  plan1 = info.plans[0];

  // free limits
  const free = await payments.limitsFor(A.id);
  assert.deepEqual([free.premium, free.upload_mb, free.folders], [false, 50, 10]);
  await rejects(fakeUpload(A.id, 60 * 1024 * 1024, 'file'), 'file_too_large');

  // Plus is "coming soon" until the admin opens sales
  await rejects(payments.checkout(A.id, { plan_id: plan1.id, provider: 'manual' }), 'coming_soon');
  assert.equal((await settings.publicConfig()).plus_available, false);
  await settings.update({ plus_sales_open: true });
  assert.equal((await settings.publicConfig()).plus_available, true);
  await rejects(payments.checkout(A.id, { plan_id: plan1.id, provider: 'jazzcash' }), 'provider_unavailable');
  const co = await payments.checkout(A.id, { plan_id: plan1.id, provider: 'manual' });
  assert.equal(co.order.status, 'pending');
  assert.match(co.instructions, /JazzCash/);
  assert.ok(co.order.txn_ref.length <= 20);

  const shot = await fakeUpload(A.id);
  await rejects(payments.submitProof(B.id, co.order.id, { media_id: shot.id, txn_id: '123456' }), 'order_not_found');
  const sub = await payments.submitProof(A.id, co.order.id, { media_id: shot.id, txn_id: 'TID778899', sender: '0300-1112223' });
  assert.equal(sub.status, 'review');
  assert.equal(Number((await admin.dashboard()).payments_to_review), 1);

  const list = await payments.adminListOrders({ status: 'review' });
  assert.equal(list.orders[0].proof_txn_id, 'TID778899');
  await payments.adminApprove(boss.id, co.order.id, 'checked JazzCash app');
  await rejects(payments.adminApprove(boss.id, co.order.id), 'order_closed');

  const me = await users.getMe(A.id);
  assert.ok(new Date(me.premium_until) > new Date(Date.now() + 27 * 86400e3));
  assert.equal(me.is_premium, true);
  assert.equal(me.limits.upload_mb, 500);
  assert.equal((await users.getUser(B.id, A.id)).is_premium, true, 'others see the badge');
  const prem = await payments.limitsFor(A.id);
  assert.deepEqual([prem.premium, prem.folders, prem.ads], [true, 30, false]);
  assert.ok(await fakeUpload(A.id, 60 * 1024 * 1024, 'file'), 'bigger uploads allowed');
  for (let i = 0; i < 11; i++) await folders.create(A.id, { name: `F${i}`, include_private: true });

  // buying again extends from the current end date
  const before = new Date(me.premium_until);
  const co2 = await payments.checkout(A.id, { plan_id: plan1.id, provider: 'manual' });
  await payments.markPaid(co2.order.id);
  assert.ok(new Date((await users.getMe(A.id)).premium_until) > new Date(before.getTime() + 27 * 86400e3));
});

test('JazzCash: signed request, verified callback activates Premium; tampered or failed callbacks do not', async () => {
  Object.assign(config.jazzcash, { merchantId: 'MC12345', password: 'pw123', integritySalt: 'salt987', sandbox: true });
  assert.ok((await payments.premiumInfo(B.id)).methods.some((m) => m.id === 'jazzcash'));
  const co = await payments.checkout(B.id, { plan_id: plan1.id, provider: 'jazzcash' });
  assert.match(co.pay_url, /\/pay\/\d+\?t=[0-9a-f]{32}$/);
  const t = new URL(co.pay_url).searchParams.get('t');
  await rejects(payments.gatewayForm(co.order.id, 'x'.repeat(32)), 'order_not_found');
  const form = await payments.gatewayForm(co.order.id, t);
  assert.match(form.action, /sandbox\.jazzcash\.com\.pk/);
  assert.equal(form.fields.pp_Amount, '29900');
  assert.equal(form.fields.pp_TxnRefNo, co.order.txn_ref);
  // independent re-computation of the documented hash rule
  const vals = Object.keys(form.fields).filter((k) => k.startsWith('pp') && k !== 'pp_SecureHash' && form.fields[k] !== '').sort().map((k) => form.fields[k]);
  assert.equal(form.fields.pp_SecureHash, crypto.createHmac('sha256', 'salt987').update(['salt987', ...vals].join('&')).digest('hex').toUpperCase());

  const reply = (over) => {
    const b = { pp_TxnRefNo: co.order.txn_ref, pp_Amount: '29900', pp_ResponseCode: '000', pp_ResponseMessage: 'Thank you', pp_RetreivalReferenceNo: '998877', pp_MerchantID: 'MC12345', ...over };
    b.pp_SecureHash = jazzcash.secureHash(b, 'salt987');
    return b;
  };
  const forged = { ...reply({}), pp_Amount: '100' }; // changed after signing
  assert.equal((await payments.jazzcashReturn(forged)).ok, false);
  assert.equal((await db.one('SELECT status FROM payment_orders WHERE id = $1', [co.order.id])).status, 'failed');

  const co2 = await payments.checkout(B.id, { plan_id: plan1.id, provider: 'jazzcash' });
  const declined = { pp_TxnRefNo: co2.order.txn_ref, pp_Amount: '29900', pp_ResponseCode: '124', pp_ResponseMessage: 'Insufficient balance' };
  declined.pp_SecureHash = jazzcash.secureHash(declined, 'salt987');
  const r2 = await payments.jazzcashReturn(declined);
  assert.equal(r2.ok, false);
  assert.equal(r2.message, 'Insufficient balance');

  const co3 = await payments.checkout(B.id, { plan_id: plan1.id, provider: 'jazzcash' });
  const good = { pp_TxnRefNo: co3.order.txn_ref, pp_Amount: '29900', pp_ResponseCode: '000', pp_ResponseMessage: 'Thank you', pp_RetreivalReferenceNo: '55555' };
  good.pp_SecureHash = jazzcash.secureHash(good, 'salt987');
  assert.equal((await payments.jazzcashReturn(good)).ok, true);
  assert.equal((await payments.jazzcashReturn(good)).ok, true, 'a repeated callback is harmless');
  const o = await payments.getOrder(B.id, co3.order.id);
  assert.equal(o.status, 'paid');
  assert.equal((await users.getMe(B.id)).is_premium, true);
  Object.assign(config.jazzcash, { merchantId: '', password: '', integritySalt: '' });
});

test('Easypaisa: encrypted request; without the inquiry API the payment goes to admin review', async () => {
  Object.assign(config.easypaisa, { storeId: '4321', hashKey: '0123456789ABCDEF', sandbox: true, username: '', password: '', accountNum: '' });
  const co = await payments.checkout(C.id, { plan_id: plan1.id, provider: 'easypaisa' });
  const t = new URL(co.pay_url).searchParams.get('t');
  const form = await payments.gatewayForm(co.order.id, t);
  assert.match(form.action, /easypaystg\.easypaisa\.com\.pk\/easypay\/Index\.jsf$/);
  const d = crypto.createDecipheriv('aes-128-ecb', Buffer.from('0123456789ABCDEF'), null);
  const plain = Buffer.concat([d.update(Buffer.from(form.fields.merchantHashedReq, 'base64')), d.final()]).toString();
  assert.ok(plain.startsWith(`amount=299.0&orderRefNum=${co.order.txn_ref}&paymentMethod=MA_PAYMENT_METHOD&postBackURL=`));
  assert.ok(plain.includes('&storeId=4321&timeStamp='));

  const confirm = await payments.easypaisaConfirmForm(co.order.id, t, 'AUTH123');
  assert.match(confirm.action, /Confirm\.jsf$/);
  assert.equal(confirm.fields.auth_token, 'AUTH123');
  const done = await payments.easypaisaDone(co.order.id, t, { status: '0000', desc: 'Success' });
  assert.equal(done.ok, true);
  assert.equal((await payments.getOrder(C.id, co.order.id)).status, 'review');
  assert.equal((await users.getMe(C.id)).is_premium, false, 'not active until confirmed');
  await payments.adminReject(boss.id, co.order.id, 'Not received in Easypaisa portal');
  assert.equal((await payments.getOrder(C.id, co.order.id)).status, 'rejected');
  Object.assign(config.easypaisa, { storeId: '', hashKey: '' });
});

test('admin grant / revoke, plans editor, order expiry', async () => {
  await payments.adminGrant(boss.id, C.id, 3);
  assert.equal((await users.getMe(C.id)).is_premium, true);
  await payments.adminRevoke(C.id);
  assert.equal((await users.getMe(C.id)).is_premium, false);
  const p = await payments.adminSavePlan(null, { name: '3 months', months: 3, price_pkr: 799, sort: 2 });
  await payments.adminSavePlan(p.id, { name: '3 months', months: 3, price_pkr: 749, is_active: false });
  assert.ok(!(await payments.premiumInfo(C.id)).plans.some((x) => x.id === p.id), 'inactive plans hidden');
  await rejects(payments.checkout(C.id, { plan_id: p.id, provider: 'manual' }), 'plan_not_found');

  Object.assign(config.jazzcash, { merchantId: 'M', password: 'P', integritySalt: 'S' });
  const co = await payments.checkout(C.id, { plan_id: plan1.id, provider: 'jazzcash' });
  await db.query(`UPDATE payment_orders SET created_at = now() - interval '3 hours' WHERE id = $1`, [co.order.id]);
  await payments.sweep();
  assert.equal((await payments.getOrder(C.id, co.order.id)).status, 'cancelled');
  Object.assign(config.jazzcash, { merchantId: '', password: '', integritySalt: '' });
});

test('sponsored messages: big public channels only, never for Premium, unique daily views & clicks, revenue', async () => {
  const ch = await chats.createChannel(B.id, { title: 'Cricket', username: 'cricket_news' });
  const chId = ch.id || ch.chat.id;
  await chats.addMembers(B.id, chId, [A.id, C.id]);
  await settings.update({ feature_ads: true, ads_min_subscribers: 3 });
  assert.equal((await ads.sponsoredFor(C.id, chId)).ad, null, 'no campaigns yet');
  const camp = await ads.adminSave(boss.id, null, { advertiser: 'Daraz', text: '11.11 sale — 70% off', button_text: 'Shop', url: 'https://example.com/sale', price_pkr: 15000 });
  await rejects(ads.adminSave(boss.id, null, { advertiser: 'x', text: 'y', url: 'javascript:alert(1)' }), 'invalid_url');

  const shown = await ads.sponsoredFor(C.id, chId);
  assert.equal(shown.ad.advertiser, 'Daraz');
  assert.equal((await ads.sponsoredFor(A.id, chId)).ad, null, 'Premium users see no ads');
  await settings.update({ ads_min_subscribers: 50 });
  assert.equal((await ads.sponsoredFor(C.id, chId)).ad, null, 'small channels get no ads');
  await settings.update({ ads_min_subscribers: 3 });
  const g = (await chats.createGroup(B.id, { title: 'G', member_ids: [C.id] })).chat;
  assert.equal((await ads.sponsoredFor(C.id, g.id)).ad, null, 'never in groups');

  await ads.recordView(C.id, camp.id);
  await ads.recordView(C.id, camp.id);
  await ads.recordView(B.id, camp.id);
  const click = await ads.recordClick(C.id, camp.id);
  await ads.recordClick(C.id, camp.id);
  assert.equal(click.url, 'https://example.com/sale');
  const st = (await ads.adminList())[0];
  assert.deepEqual([st.impressions, st.clicks, st.ctr], [2, 1, 50]);

  await ads.adminSave(boss.id, camp.id, { advertiser: 'Daraz', text: 'Ended', url: 'https://example.com', status: 'paused', price_pkr: 15000 });
  assert.equal((await ads.sponsoredFor(C.id, chId)).ad, null, 'paused');

  const rev = await ads.adminRevenue();
  assert.equal(rev.ads_total, 15000);
  assert.equal(rev.premium_total, 299 * 3, 'manual + extension + JazzCash (admin grants are free)');
  assert.equal(rev.total, 15000 + 897);
  assert.equal(rev.months.length, 12);
  assert.ok(rev.by_provider.some((p) => p.provider === 'jazzcash' && p.amount_pkr === 299));
  assert.ok(rev.premium_users >= 2);
  await settings.update({ feature_ads: false });
});

test('Plus with USDT from the wallet: unique amount, checked on the network, one transaction pays one order', async () => {
  const cryptopay = require('../src/services/payments/cryptopay');
  const BSC = `0x${'1a'.repeat(20)}`;
  const TRON = 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH';
  assert.equal(cryptopay.tronHex(cryptopay.NETWORKS.tron.contract), 'a614f803b6fd780986a42c78ec9c7f77e6ded13c', 'the real USDT contract');
  assert.ok(!(await payments.premiumInfo(C.id)).methods.some((m) => m.id === 'crypto'), 'hidden until our address is set');
  await rejects(settings.update({ crypto_pay_bsc_address: '0x123' }), 'invalid_setting');
  await rejects(settings.update({ crypto_pay_tron_address: 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdJ' }), 'invalid_setting');
  await settings.update({ crypto_pay_bsc_address: BSC, crypto_pay_tron_address: TRON });
  const info = await payments.premiumInfo(C.id);
  assert.equal(info.methods[0].id, 'crypto');
  assert.deepEqual(info.crypto_networks.map((n) => n.id), ['bsc', 'tron']);
  assert.ok(!JSON.stringify(info.crypto_networks).includes(BSC.slice(4)), 'the address is given only with an order');
  const plan3 = info.plans.find((p) => p.months === 3);
  assert.equal(plan3.usdt, 10.49);

  // a pretend network
  const pad = (h) => String(h).replace(/^0x/, '').toLowerCase().padStart(64, '0');
  const chain = {};
  const tron = {};
  let head = 1000;
  let blockTime = Date.now();
  cryptopay.setTransport(async (url, body) => {
    if (url.includes('walletsolidity')) return tron[body.value] || {};
    if (body.method === 'eth_blockNumber') return { result: `0x${head.toString(16)}` };
    if (body.method === 'eth_getTransactionReceipt') return { result: chain[body.params[0]] || null };
    if (body.method === 'eth_getBlockByNumber') return { result: { timestamp: `0x${Math.floor(blockTime / 1000).toString(16)}` } };
    throw new Error(`unexpected call ${url}`);
  });
  const usdt = cryptopay.NETWORKS.bsc.contract;
  const receipt = (tx, { contract = usdt, to = BSC, amount, status = '0x1', block = 900 }) => ({
    transactionHash: tx, blockNumber: `0x${block.toString(16)}`, status,
    logs: [{ address: contract, topics: [`0x${cryptopay.TRANSFER}`, `0x${pad('22'.repeat(20))}`, `0x${pad(to)}`], data: `0x${pad(BigInt(amount).toString(16))}` }],
  });
  const txid = (n) => `0x${String(n).repeat(64).slice(0, 64)}`;

  try {
    await rejects(payments.checkout(C.id, { plan_id: plan3.id, provider: 'crypto', network: 'eth' }), 'provider_unavailable');
    const co = await payments.checkout(C.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    assert.equal(co.crypto.to, BSC);
    assert.equal(co.crypto.contract, usdt);
    const amount = BigInt(co.crypto.amount);
    assert.ok(amount > 10490000n * 10n ** 12n && amount < 10500000n * 10n ** 12n, 'price plus a fraction of a cent');
    assert.match(co.crypto.amount_text, /^10\.49\d{4} USDT$/);

    await rejects(payments.submitCryptoTx(C.id, co.order.id, { tx: 'hello' }), 'invalid_input');
    await rejects(payments.submitCryptoTx(B.id, co.order.id, { tx: txid(1) }), 'order_not_found');
    // not on the network yet
    assert.equal((await payments.submitCryptoTx(C.id, co.order.id, { tx: txid(1).toUpperCase().replace('0X', '0x') })).status, 'pending');
    // there, but not final yet
    chain[txid(1)] = receipt(txid(1), { amount, block: 995 });
    assert.equal(await payments.verifyCrypto(co.order.id), 'pending');
    assert.equal((await users.getMe(C.id)).is_premium, false);
    head = 1100;
    assert.equal(await payments.verifyCrypto(co.order.id), 'paid');
    assert.ok(new Date((await users.getMe(C.id)).premium_until) > new Date(Date.now() + 85 * 86400e3), '3 months added');
    const paid = await payments.getOrder(C.id, co.order.id);
    assert.equal(paid.status, 'paid');
    assert.match(paid.crypto.tx_url, /bscscan\.com\/tx\/0x1111/);
    assert.equal(await payments.verifyCrypto(co.order.id), null, 'never paid twice');

    // somebody else can't use the same transaction
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    const b1 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    assert.notEqual(b1.crypto.amount, co.crypto.amount);
    await rejects(payments.submitCryptoTx(B.id, b1.order.id, { tx: txid(1) }), 'tx_used');
    // a look-alike token is not USDT
    chain[txid(2)] = receipt(txid(2), { amount: b1.crypto.amount, contract: `0x${'99'.repeat(20)}` });
    assert.equal((await payments.submitCryptoTx(B.id, b1.order.id, { tx: txid(2) })).status, 'review');
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    // a different amount
    const b2 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    chain[txid(3)] = receipt(txid(3), { amount: 10490000n * 10n ** 12n });
    const r2 = await payments.submitCryptoTx(B.id, b2.order.id, { tx: txid(3) });
    assert.equal(r2.status, 'review');
    assert.match(r2.provider_message, /different amount/);
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    // sent to somebody else
    const b3 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    chain[txid(4)] = receipt(txid(4), { amount: b3.crypto.amount, to: `0x${'77'.repeat(20)}` });
    assert.equal((await payments.submitCryptoTx(B.id, b3.order.id, { tx: txid(4) })).status, 'review');
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    // a failed transaction
    const b4 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    chain[txid(5)] = receipt(txid(5), { amount: b4.crypto.amount, status: '0x0' });
    assert.equal((await payments.submitCryptoTx(B.id, b4.order.id, { tx: txid(5) })).status, 'failed');
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);

    // an old payment can't pay a new order
    const b5 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    blockTime = Date.now() - 3600e3;
    chain[txid(6)] = receipt(txid(6), { amount: b5.crypto.amount });
    assert.equal((await payments.submitCryptoTx(B.id, b5.order.id, { tx: txid(6) })).status, 'review');
    blockTime = Date.now();
    // …and a payment made days later can't either (the amount may belong to someone else's order by then)
    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    const b5b = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' });
    blockTime = Date.now() + 2 * 86400e3;
    chain[txid(7)] = receipt(txid(7), { amount: b5b.crypto.amount });
    const late = await payments.submitCryptoTx(B.id, b5b.order.id, { tx: txid(7) });
    assert.equal(late.status, 'review');
    assert.match(late.provider_message, /long after/);
    blockTime = Date.now();

    await db.query(`UPDATE payment_orders SET status = 'rejected' WHERE user_id = $1 AND status IN ('review', 'pending')`, [B.id]);
    // a new order replaces an unpaid one; an expired order that WAS paid still counts
    const b6 = await payments.checkout(B.id, { plan_id: plan3.id, provider: 'crypto', network: 'tron' });
    assert.equal(b6.crypto.decimals, 6);
    assert.ok(BigInt(b6.crypto.amount) > 10490000n && BigInt(b6.crypto.amount) < 10500000n);
    await db.query(`UPDATE payment_orders SET created_at = now() - interval '3 hours' WHERE id = $1`, [b6.order.id]);
    await payments.sweep();
    assert.equal((await payments.getOrder(B.id, b6.order.id)).status, 'cancelled');
    await db.query(`UPDATE payment_orders SET created_at = now() WHERE id = $1`, [b6.order.id]);
    const t = 'ab'.repeat(32);
    assert.equal((await payments.submitCryptoTx(B.id, b6.order.id, { tx: t })).status, 'pending');
    tron[t] = {
      id: t, blockNumber: 5, blockTimeStamp: Date.now(), receipt: { result: 'SUCCESS' },
      log: [{ address: 'a614f803b6fd780986a42c78ec9c7f77e6ded13c', topics: [cryptopay.TRANSFER, pad('33'.repeat(20)), pad(cryptopay.tronHex(TRON))], data: pad(BigInt(b6.crypto.amount).toString(16)) }],
    };
    await db.query('UPDATE payment_orders SET crypto_checked_at = NULL WHERE id = $1', [b6.order.id]);
    await payments.sweep();
    assert.equal((await payments.getOrder(B.id, b6.order.id)).status, 'paid');

    // USD only (the default): one price for everyone, no local gateways
    await settings.update({ plus_usd_only: true });
    const world = await payments.premiumInfo(C.id);
    assert.equal(world.currency, 'USD');
    assert.deepEqual(world.plans.map((p) => p.price_text), ['$3.99', '$10.49', '$19.99', '$35.99']);
    assert.deepEqual(world.plans.map((p) => p.save_percent), [0, 12, 16, 25]);
    assert.deepEqual(world.methods.map((m) => m.id), ['crypto']);
    await rejects(payments.checkout(C.id, { plan_id: plan3.id, provider: 'manual' }), 'provider_unavailable');
    await settings.update({ plus_usd_only: false });

    // the wallet switched off → no crypto payments
    await settings.update({ feature_wallet: false });
    assert.ok(!(await payments.premiumInfo(C.id)).methods.some((m) => m.id === 'crypto'));
    await rejects(payments.checkout(C.id, { plan_id: plan3.id, provider: 'crypto', network: 'bsc' }), 'provider_unavailable');
  } finally {
    cryptopay.setTransport(null);
    await settings.update({ feature_wallet: true, crypto_pay_bsc_address: '', crypto_pay_tron_address: '' });
  }
});

test('Hushavia Coins: bought with USDT, spent on Plus, sent to a friend, never below zero', async () => {
  const coins = require('../src/services/coin.service');
  const cryptopay = require('../src/services/payments/cryptopay');
  const BSC = `0x${'2b'.repeat(20)}`;
  const first = await coins.info(A.id);
  assert.equal(first.balance, 0);
  assert.deepEqual(first.packs, [], 'nothing to buy until our address is set');
  assert.ok(first.buy_note);
  await settings.update({ crypto_pay_bsc_address: BSC });
  const info = await coins.info(A.id);
  assert.deepEqual(info.packs.map((p) => p.total), [100, 525, 1100, 2900, 6000]);
  assert.deepEqual(info.plus.map((p) => p.coins), [399, 1049, 1999, 3599]);
  assert.ok(!JSON.stringify(info).includes(BSC.slice(4)));

  const pad = (h) => String(h).replace(/^0x/, '').toLowerCase().padStart(64, '0');
  const chain = {};
  cryptopay.setTransport(async (url, body) => {
    if (body.method === 'eth_blockNumber') return { result: '0x3e8' };
    if (body.method === 'eth_getTransactionReceipt') return { result: chain[body.params[0]] || null };
    if (body.method === 'eth_getBlockByNumber') return { result: { timestamp: `0x${Math.floor(Date.now() / 1000).toString(16)}` } };
    throw new Error('unexpected call');
  });
  try {
    const before = (await users.getMe(A.id)).premium_until;
    const pack = info.packs[2];
    await rejects(payments.checkout(A.id, { coin_pack_id: pack.id, provider: 'manual' }), 'invalid_input');
    const co = await payments.checkout(A.id, { coin_pack_id: pack.id, provider: 'crypto', network: 'bsc' });
    assert.equal(co.order.coins, 1100);
    assert.match(co.crypto.amount_text, /^9\.99\d{4} USDT$/);
    const tx = `0x${'c0'.repeat(32)}`;
    chain[tx] = {
      transactionHash: tx, blockNumber: '0x64', status: '0x1',
      logs: [{ address: cryptopay.NETWORKS.bsc.contract, topics: [`0x${cryptopay.TRANSFER}`, `0x${pad('44'.repeat(20))}`, `0x${pad(BSC)}`], data: `0x${pad(BigInt(co.crypto.amount).toString(16))}` }],
    };
    assert.equal((await payments.submitCryptoTx(A.id, co.order.id, { tx })).status, 'paid');
    assert.equal((await payments.submitCryptoTx(A.id, co.order.id, { tx })).status, 'paid', 'asking twice changes nothing');
    let me = await users.getMe(A.id);
    assert.equal(me.coins, 1100);
    assert.equal(me.premium_until, before, 'a pack of coins is not Plus');

    // Plus paid with coins
    const plans = (await payments.premiumInfo(A.id)).plans;
    assert.equal((await payments.premiumInfo(A.id)).coins.balance, 1100);
    await rejects(coins.buyPlus(A.id, { plan_id: plans[3].id }), 'not_enough_coins');
    assert.equal((await db.one(`SELECT count(*)::int AS n FROM payment_orders WHERE user_id = $1 AND provider = 'coins'`, [A.id])).n, 0, 'nothing is left behind when it fails');
    const got = await coins.buyPlus(A.id, { plan_id: plans[0].id });
    assert.deepEqual([got.spent, got.balance], [399, 701]);
    assert.ok(new Date(got.premium_until) > new Date(new Date(before || Date.now()).getTime() + 27 * 86400e3));

    // a gift
    await rejects(coins.send(A.id, { user_id: A.id, amount: 5 }), 'invalid_input');
    await rejects(coins.send(A.id, { user_id: B.id, amount: 0 }), 'invalid_input');
    await rejects(coins.send(A.id, { user_id: B.id, amount: 1.5 }), 'invalid_input');
    await rejects(coins.send(A.id, { user_id: B.id, amount: -50 }), 'invalid_input');
    await rejects(coins.send(A.id, { user_id: B.id, amount: 702 }), 'not_enough_coins');
    const sent = await coins.send(A.id, { user_id: B.id, amount: 200, note: 'Eid Mubarak' });
    assert.equal(sent.balance, 501);
    assert.equal((await users.getMe(B.id)).coins, 200);
    const hb = await coins.history(B.id);
    assert.deepEqual([hb[0].kind, hb[0].delta, hb[0].peer.id, hb[0].note], ['gift_received', 200, A.id, 'Eid Mubarak']);
    assert.deepEqual((await coins.history(A.id)).map((h) => [h.kind, h.delta]), [['gift_sent', -200], ['plus', -399], ['purchase', 1100]]);
    // two gifts at the same moment can't spend the same coins
    const both = await Promise.allSettled([coins.send(A.id, { user_id: B.id, amount: 400 }), coins.send(A.id, { user_id: C.id, amount: 400 })]);
    assert.equal(both.filter((r) => r.status === 'fulfilled').length, 1);
    assert.equal((await users.getMe(A.id)).coins, 101);

    // admin
    await rejects(coins.adminAdjust(boss.id, A.id, { amount: -5000 }), 'not_enough_coins');
    assert.equal((await coins.adminAdjust(boss.id, A.id, { amount: 49, note: 'Sorry for the trouble' })).balance, 150);
    const packs = await coins.adminPacks();
    assert.equal(packs.stats.bought, 1100);
    assert.equal(packs.stats.in_wallets, 750);
    const np = await coins.adminSavePack(null, { coins: 50, bonus: 0, price_usd: 0.5 });
    await coins.adminSavePack(np.id, { coins: 50, bonus: 0, price_usd: 0.5, is_active: false });
    assert.equal((await coins.info(A.id)).packs.length, 5);

    // the books always add up
    const bad = await db.many(`SELECT u.id FROM users u WHERE u.coins <> (SELECT COALESCE(sum(delta), 0) FROM coin_tx t WHERE t.user_id = u.id)`);
    assert.equal(bad.length, 0);

    await settings.update({ feature_coins: false });
    await assert.rejects(coins.info(A.id));
    await assert.rejects(coins.send(A.id, { user_id: B.id, amount: 1 }));
    assert.equal((await payments.premiumInfo(A.id)).coins, null);
  } finally {
    cryptopay.setTransport(null);
    await settings.update({ feature_coins: true, crypto_pay_bsc_address: '' });
  }
});

test('coins at work: gifts in chats, tips on posts, paid channels, giveaways', async () => {
  const coins = require('../src/services/coin.service');
  const plus = require('../src/services/coinplus.service');
  const messages = require('../src/services/message.service');
  const G = await signup('+923260000011', 'Gul');
  const H = await signup('+923260000012', 'Hina');
  const I = await signup('+923260000013', 'Irfan');
  const bal = async (u) => (await users.getMe(u.id)).coins;
  await coins.adminAdjust(boss.id, G.id, { amount: 5000 });

  // ---- a gift in a private chat
  const pc = await chats.getOrCreatePrivate(G.id, H.id);
  const pcId = pc.id || pc.chat.id;
  await rejects(messages.sendMessage(G.id, pcId, { type: 'gift' }), 'invalid_input'); // an app can't make a gift card up
  await rejects(plus.sendGift(H.id, { chat_id: pcId, gift_id: 'rose' }), 'not_enough_coins');
  await rejects(plus.sendGift(G.id, { chat_id: pcId, gift_id: 'unicorn' }), 'invalid_input');
  const gift = await plus.sendGift(G.id, { chat_id: pcId, gift_id: 'cake', note: 'Happy birthday' });
  assert.equal(gift.balance, 4950);
  assert.deepEqual([gift.message.type, gift.message.meta.gift.coins, gift.message.meta.gift.note], ['gift', 50, 'Happy birthday']);
  assert.equal(await bal(H), 50);

  // ---- tips on a channel post (the owner gets 90%)
  const ch = await chats.createChannel(H.id, { title: 'Hina Daily', username: 'hina_daily', is_public: true });
  const chId = ch.id || ch.chat.id;
  await chats.joinPublic(G.id, chId);
  const post = await messages.sendMessage(H.id, chId, { text: 'Recipe of the day' });
  await rejects(plus.tip(H.id, { message_id: post.id, amount: 10 }), 'invalid_input'); // her own channel
  await rejects(plus.tip(I.id, { message_id: post.id, amount: 10 }), 'chat_not_found');
  await rejects(plus.tip(G.id, { message_id: post.id, amount: 0 }), 'invalid_input');
  const tipped = await plus.tip(G.id, { message_id: post.id, amount: 100 });
  assert.deepEqual([tipped.balance, tipped.tips], [4850, 100]);
  assert.equal(await bal(H), 140);
  assert.equal((await messages.listMessages(G.id, chId, {})).messages.find((m) => m.id === post.id).tips, 100);

  // ---- a paid channel
  await rejects(plus.setPrice(G.id, chId, { price: 300 }), 'forbidden');
  await plus.setPrice(H.id, chId, { price: 300 });
  assert.equal((await chats.publicPreview(I.id, 'hina_daily')).sub_price, 300);
  let err = null;
  await chats.joinPublic(I.id, chId).catch((e) => { err = e; });
  assert.deepEqual([err.code, err.extra.price], ['subscription_required', 300]);
  await rejects(plus.subscribe(I.id, chId, {}), 'not_enough_coins');
  await rejects(messages.listMessages(I.id, chId, {}), 'chat_not_found');
  await coins.adminAdjust(boss.id, I.id, { amount: 700 });
  const sub = await plus.subscribe(I.id, chId, {});
  assert.equal(sub.balance, 400);
  assert.ok(new Date(sub.expires_at) > new Date(Date.now() + 29 * 86400e3));
  assert.equal(await bal(H), 410); // 140 + 90% of 300
  assert.ok((await messages.listMessages(I.id, chId, {})).messages.length >= 1);
  assert.equal((await plus.mySubscription(G.id, chId)), null, 'people who were already in stay for free');
  // the month runs out: renewed from the balance…
  await db.query(`UPDATE channel_subs SET expires_at = now() - interval '1 minute' WHERE user_id = $1`, [I.id]);
  await plus.sweepSubs();
  assert.equal(await bal(I), 100);
  assert.ok(new Date((await plus.mySubscription(I.id, chId)).expires_at) > new Date(Date.now() + 29 * 86400e3));
  // …and when there is not enough, the member leaves
  await db.query(`UPDATE channel_subs SET expires_at = now() - interval '1 minute' WHERE user_id = $1`, [I.id]);
  await plus.sweepSubs();
  assert.equal(await bal(I), 100);
  await rejects(messages.listMessages(I.id, chId, {}), 'chat_not_found');
  assert.equal(await plus.mySubscription(I.id, chId), null);
  await plus.setPrice(H.id, chId, { price: 0 });
  await chats.joinPublic(I.id, chId);

  // ---- a giveaway: 2 winners × 200 coins, held from the start
  await rejects(plus.createGiveaway(G.id, { chat_id: chId, coins_each: 200, winners: 2, hours: 1 }), 'forbidden');
  await rejects(plus.createGiveaway(H.id, { chat_id: chId, coins_each: 400, winners: 2, hours: 1 }), 'not_enough_coins');
  assert.equal((await db.one('SELECT count(*)::int AS n FROM giveaways')).n, 0);
  await coins.adminAdjust(boss.id, H.id, { amount: 90 }); // 680 now
  const before = await bal(H);
  const ga = await plus.createGiveaway(H.id, { chat_id: chId, coins_each: 200, winners: 2, hours: 1 });
  assert.equal(ga.balance, before - 400);
  assert.equal(ga.message.meta.giveaway.id, ga.giveaway.id);
  await rejects(plus.joinGiveaway(H.id, ga.giveaway.id), 'invalid_input');
  assert.deepEqual([(await plus.joinGiveaway(G.id, ga.giveaway.id)).entries, (await plus.joinGiveaway(G.id, ga.giveaway.id)).entries], [1, 1]);
  await plus.sweepGiveaways();
  assert.equal((await plus.getGiveaway(G.id, ga.giveaway.id)).status, 'open', 'not before its time');
  await db.query(`UPDATE giveaways SET ends_at = now() - interval '1 second' WHERE id = $1`, [ga.giveaway.id]);
  const gBefore = await bal(G);
  await plus.sweepGiveaways();
  await plus.sweepGiveaways(); // a second draw changes nothing
  const done = await plus.getGiveaway(G.id, ga.giveaway.id);
  assert.deepEqual([done.status, done.winner_list.map((w) => w.id)], ['done', [G.id]]);
  assert.equal(await bal(G), gBefore + 200);
  assert.equal(await bal(H), before - 200, 'the prize nobody could win came back');
  await rejects(plus.joinGiveaway(I.id, ga.giveaway.id), 'giveaway_over');
  const last = (await messages.listMessages(G.id, chId, {})).messages[0];
  assert.match(last.text, /Giveaway finished/);

  // the books still add up
  const bad = await db.many(`SELECT u.id FROM users u WHERE u.coins <> (SELECT COALESCE(sum(delta), 0) FROM coin_tx t WHERE t.user_id = u.id)`);
  assert.equal(bad.length, 0);
});
