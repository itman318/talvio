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
  assert.equal((await db.one('SELECT status FROM payment_orders WHERE id = $1', [co.order.id])).status, 'pending', 'an unsigned message changes nothing — it cannot even fail the order');

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
    // money may be on its way: the order can't be cancelled now
    await rejects(payments.cancelOrder(B.id, b6.order.id), 'order_busy');
    // the network was slow for hours: the order goes to "review", but a late confirmation still pays it by itself
    await db.query(`UPDATE payment_orders SET crypto_submitted_at = now() - interval '3 hours' WHERE id = $1`, [b6.order.id]);
    await payments.sweep();
    assert.equal((await payments.getOrder(B.id, b6.order.id)).status, 'review');
    await db.query(`UPDATE payment_orders SET crypto_checked_at = now() - interval '1 hour' WHERE id = $1`, [b6.order.id]);
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
    await rejects(coins.buyPlus(A.id, { plan_id: plans[0].id }), 'just_bought'); // a second tap is not a second purchase
    assert.equal((await users.getMe(A.id)).coins, 701);

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
  await rejects(plus.tip(G.id, { message_id: post.id, amount: 5 }), 'not_monetized');
  await rejects(plus.setPrice(H.id, chId, { price: 300 }), 'not_monetized');
  const mon = require('../src/services/monetize.service');
  const st0 = await mon.status(H.id, chId);
  assert.equal(st0.eligible, false);
  await rejects(mon.enable(H.id, chId), 'not_eligible');
  await rejects(mon.status(G.id, chId), 'forbidden');
  // meet the bar (smaller in this test), then turn it on
  await settings.update({ monetize_min_subscribers: 2, monetize_min_days: 0, monetize_min_posts: 1, monetize_require_2fa: false, monetize_min_avg_views: 1 });
  // brand-new accounts that never opened the app are not "real" subscribers, and nobody has seen the post yet
  const st1 = await mon.status(H.id, chId);
  assert.deepEqual(st1.checks.filter((c) => !c.ok).map((c) => c.key).sort(), ['subscribers', 'views']);
  await db.query(`UPDATE users SET created_at = now() - interval '10 days', last_seen_at = now() WHERE id = ANY($1::bigint[])`, [[G.id, H.id]]);
  await messages.recordViews(G.id, chId, [post.id]);
  assert.equal((await mon.status(H.id, chId)).eligible, true);
  assert.equal((await mon.enable(H.id, chId)).monetized, true);
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
  // leaving and coming back inside the paid month costs nothing
  await chats.leaveChat(I.id, chId);
  await chats.joinPublic(I.id, chId);
  assert.equal(await bal(I), 400);
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

  // a chat deleted while a giveaway is running: the coins held for it go back
  const hNow = await bal(H);
  await plus.createGiveaway(H.id, { chat_id: chId, coins_each: 50, winners: 2, hours: 1 });
  assert.equal(await bal(H), hNow - 100);
  await admin.deleteGroup({ id: null }, chId, '127.0.0.1').catch(async () => {
    // (the admin log needs a real admin row: do the same steps directly)
    await db.tx(async (c) => {
      await plus.refundForChat(c, chId);
      await c.query('DELETE FROM chats WHERE id = $1', [chId]);
    });
  });
  assert.equal(await bal(H), hNow, 'the giveaway money came back');

  // the books still add up
  const bad = await db.many(`SELECT u.id FROM users u WHERE u.coins <> (SELECT COALESCE(sum(delta), 0) FROM coin_tx t WHERE t.user_id = u.id)`);
  assert.equal(bad.length, 0);
});

test('coins by deposit: own address per member from an xpub, booked once, too-small deposits, sweep list', async () => {
  const dep = require('../src/services/deposit.service');
  const cryptopay = require('../src/services/payments/cryptopay');
  const keys = require('../src/utils/evmkeys');
  const XPUB = 'xpub6EF8jXqFeFEW5bwMU7RpQtHkzE4KJxcqJtvkCjJumzW8CPpacXkb92ek4WzLQXjL93HycJwTPUAcuNxCqFPKKU5m5Z2Vq4nCyh5CyPeBFFr';
  // the "abandon … about" test phrase, m/44'/60'/0'/0/i (checked against an independent implementation)
  assert.equal(keys.addressAt(XPUB, 0), '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
  assert.equal(keys.addressAt(XPUB, 1), '0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0');
  assert.equal(keys.addressAt(XPUB, 1000), '0xaC2Dbb7Dc8Fa82F47021e01255fBD767a2Ec4EaD');
  assert.equal(keys.parseXpub('xpub123'), null);

  const J = await signup('+923260000021', 'Jamil');
  const K = await signup('+923260000022', 'Kiran');
  await rejects(dep.myAddress(J.id), 'deposits_off');
  await rejects(settings.update({ coins_deposit_xpub: 'abandon abandon abandon' }), 'invalid_setting');
  await settings.update({ coins_deposit_xpub: XPUB });
  const a1 = await dep.myAddress(J.id);
  const a2 = await dep.myAddress(K.id);
  assert.equal(a1.address, keys.addressAt(XPUB, 1), 'members start at number 1 (0 is the owner’s)');
  assert.equal(a2.address, keys.addressAt(XPUB, 2));
  assert.equal((await dep.myAddress(J.id)).address, a1.address, 'the same address every time');
  assert.equal((await require('../src/services/coin.service').info(J.id)).deposit.coins_per_usdt, 100);

  const pad = (h) => String(h).replace(/^0x/, '').toLowerCase().padStart(64, '0');
  const U = 10n ** 18n;
  let head = 1000;
  const logs = [];
  const log = (to, amount, block, tx, i = 0) => logs.push({
    address: cryptopay.NETWORKS.bsc.contract, topics: [`0x${cryptopay.TRANSFER}`, `0x${pad('55'.repeat(20))}`, `0x${pad(to)}`],
    data: `0x${pad(amount.toString(16))}`, blockNumber: `0x${block.toString(16)}`, transactionHash: `0x${tx.repeat(64).slice(0, 64)}`, logIndex: `0x${i.toString(16)}`,
  });
  cryptopay.setTransport(async (url, body) => {
    if (body.method === 'eth_blockNumber') return { result: `0x${head.toString(16)}` };
    if (body.method === 'eth_getLogs') {
      const f = body.params[0];
      const from = parseInt(f.fromBlock, 16);
      const to = parseInt(f.toBlock, 16);
      assert.equal(f.address, cryptopay.NETWORKS.bsc.contract, 'only real USDT counts');
      const want = f.topics[2];
      return { result: logs.filter((l) => { const b = parseInt(l.blockNumber, 16); return b >= from && b <= to && want.includes(l.topics[2]); }) };
    }
    throw new Error('unexpected');
  });
  try {
    log(a1.address, 5n * U + U / 2n, 900, 'a'); // 5.5 USDT
    log(a2.address, U / 2n, 950, 'b'); // 0.5 USDT: below the $1 minimum
    log(a1.address, 3n * U, 990, 'c'); // not deep enough yet (head 1000 − 15)
    await dep.scan();
    assert.equal((await users.getMe(J.id)).coins, 550);
    assert.equal((await users.getMe(K.id)).coins, 0);
    head = 1010;
    await dep.scan();
    await dep.scan();
    assert.equal((await users.getMe(J.id)).coins, 850, 'confirmed later, booked once');
    const mine = await dep.myAddress(J.id);
    assert.deepEqual(mine.deposits.map((d) => [d.usdt, d.coins, d.status]), [[3, 300, 'credited'], [5.5, 550, 'credited']]);
    assert.equal((await dep.myAddress(K.id)).deposits[0].status, 'too_small');

    // "check now" looks back and books what the scanner already booked only once
    const chk = await dep.checkMine(J.id);
    assert.deepEqual([chk.added, chk.balance], [0, 850]);

    // the owner's phone gets the list to collect from — only with the right key
    await rejects(dep.sweepList('xpubWRONG'), 'forbidden');
    const sw = await dep.sweepList(XPUB);
    assert.deepEqual(sw.addresses.map((x) => x.index), [1, 2]);

    const bad = await db.many(`SELECT u.id FROM users u WHERE u.coins <> (SELECT COALESCE(sum(delta), 0) FROM coin_tx t WHERE t.user_id = u.id)`);
    assert.equal(bad.length, 0);
  } finally {
    cryptopay.setTransport(null);
    await settings.update({ coins_deposit_xpub: '' });
  }
});

test('@HushaviaWalletBot: money news in a chat, balance, history, prices', async () => {
  require('../src/services/bot.service'); // routes messages sent to bots
  const sysbots = require('../src/services/sysbots.service');
  const walletbot = require('../src/services/walletbot.service');
  const coins = require('../src/services/coin.service');
  const messages = require('../src/services/message.service');
  const ids = await sysbots.ensure();
  const W = await signup('+923260000031', 'Waqar');
  const chat = await chats.getOrCreatePrivate(W.id, ids.wallet);
  const chatId = chat.id || chat.chat.id;
  const last = async () => (await db.one('SELECT text FROM messages WHERE chat_id = $1 AND sender_id = $2 ORDER BY id DESC LIMIT 1', [chatId, ids.wallet]) || {}).text || '';
  const ask = async (text, want) => {
    await messages.sendMessage(W.id, chatId, { text });
    let r = '';
    for (let i = 0; i < 40 && !want.test(r); i += 1) {
      await new Promise((ok) => setTimeout(ok, 100));
      r = await last();
    }
    assert.match(r, want);
  };
  walletbot.setFetcher(async () => ({ bitcoin: { usd: 101234.5, pkr: 28300000, usd_24h_change: 2.345 }, ethereum: { usd: 3500, pkr: 980000, usd_24h_change: -1.2 } }));

  await ask('/start', /Wallet assistant/);
  // coins that arrive come as a message from the bot
  await coins.adminAdjust(boss.id, W.id, { amount: 250, note: 'Welcome' });
  assert.match(await last(), /You received 250 coins/);
  await ask('/balance', /250 coins/);
  await ask('/history', /250 · From Hushavia/);
  await ask('/price btc', /Bitcoin\*\* \(BTC\): \$101,235 · Rs 28,300,000 🟢 \+2\.3%/);
  await ask('/eth', /Ethereum\*\* \(ETH\): \$3,500.*🔴 -1\.2%/);
  await ask('/price shiba', /Which coin/);
  await ask('/deposit', /not open yet/);
  walletbot.setFetcher(async () => { throw new Error('down'); });
  await ask('/prices', /not available/);
});

test('self-service ads: budget held, review, paid views, owner share, daily cap, refund', async () => {
  const ads = require('../src/services/ads.service');
  const coins = require('../src/services/coin.service');
  const A1 = await signup('+923260000041', 'Adeel'); // advertiser
  const O1 = await signup('+923260000042', 'Owais'); // channel owner
  const V1 = await signup('+923260000043', 'Vania');
  const V2 = await signup('+923260000044', 'Wasim');
  const V3 = await signup('+923260000045', 'Yasir');
  const bal = async (u) => (await users.getMe(u.id)).coins;
  await settings.update({ feature_ads: true, ads_min_subscribers: 3, ads_min_cpm: 50, ads_min_budget: 100 });
  const ch = await chats.createChannel(O1.id, { title: 'Tech Daily', username: 'tech_daily_pk', is_public: true });
  const chId = ch.id || ch.chat.id;
  await db.query(`UPDATE chats SET category = 'tech', monetized = TRUE WHERE id = $1`, [chId]);
  for (const u of [V1, V2, V3]) await chats.joinPublic(u.id, chId);

  await rejects(ads.create(A1.id, { advertiser: 'Shop', text: 'Best phones', url: 'https://shop.example', cpm_coins: 100, budget_coins: 200 }), 'not_enough_coins');
  await coins.adminAdjust(boss.id, A1.id, { amount: 1000 });
  await rejects(ads.create(A1.id, { advertiser: 'Shop', text: 'Best phones', url: 'https://shop.example', cpm_coins: 10, budget_coins: 200 }), 'invalid_input');
  await rejects(ads.create(A1.id, { advertiser: 'Shop', text: 'Best phones', url: 'javascript:alert(1)', cpm_coins: 100, budget_coins: 200 }), 'invalid_url');
  // 100 coins for 1,000 views = 0.1 coin a view; budget 200 coins
  const ad = await ads.create(A1.id, { advertiser: 'Shop', text: 'Best phones in town', url: '@tech_daily_pk', categories: ['tech'], cpm_coins: 50000, budget_coins: 200 });
  assert.equal(ad.balance, 800, 'the budget is held at once');
  assert.equal(ad.ad.review, 'pending');
  assert.match(ad.ad.url, /\/c\/tech_daily_pk$/);
  assert.equal((await ads.sponsoredFor(V1.id, chId)).ad, null, 'not before review');

  await ads.adminReview(ad.ad.id, { decision: 'approve' });
  const shown = await ads.sponsoredFor(V1.id, chId);
  assert.equal(shown.ad.id, ad.ad.id);
  assert.equal((await ads.sponsoredFor(A1.id, chId)).ad, null, 'never your own ad');
  // 50,000 coins per 1,000 views = 50 coins a view; owner gets 50%
  await ads.recordView(V1.id, ad.ad.id, { chat_id: chId });
  await ads.recordView(V1.id, ad.ad.id, { chat_id: chId }); // same day, same person: once
  await ads.recordView(V2.id, ad.ad.id, { chat_id: chId });
  let st = await ads.stats(A1.id, ad.ad.id);
  assert.deepEqual([st.impressions, st.spent_coins, st.left_coins], [2, 100, 100]);
  assert.equal(st.days[st.days.length - 1].views, 2);
  assert.equal(st.top_channels[0].title, 'Tech Daily');
  await ads.sweep();
  assert.equal(await bal(O1), 50, 'the owner is paid in whole coins');

  // a category that doesn't match: not shown
  const other = await ads.create(A1.id, { advertiser: 'Game', text: 'Play now free', url: 'https://g.example', categories: ['gaming'], cpm_coins: 100, budget_coins: 100 });
  await ads.adminReview(other.ad.id, { decision: 'approve' });
  assert.notEqual((await ads.sponsoredFor(V3.id, chId)).ad && (await ads.sponsoredFor(V3.id, chId)).ad.id, other.ad.id);
  // rejected: the whole budget comes back
  const before = await bal(A1);
  await ads.adminReview(other.ad.id, { decision: 'reject', reason: 'Gambling' });
  assert.equal(await bal(A1), before + 100);

  // pause hides it; top-up; stop gives back the rest
  await ads.setState(A1.id, ad.ad.id, 'pause');
  assert.equal((await ads.sponsoredFor(V3.id, chId)).ad, null);
  await ads.setState(A1.id, ad.ad.id, 'resume');
  await ads.recordView(V3.id, ad.ad.id, { chat_id: chId });
  // budget used up (3 views × 50 = 150 of 200 … one more would pass it? 200 left 50) → a 4th person
  const V4 = await signup('+923260000046', 'Zara');
  await chats.joinPublic(V4.id, chId);
  await ads.recordView(V4.id, ad.ad.id, { chat_id: chId });
  st = await ads.stats(A1.id, ad.ad.id);
  assert.equal(st.spent_coins, 200);
  await ads.sweep();
  st = await ads.stats(A1.id, ad.ad.id);
  assert.equal(st.status, 'ended', 'ends when the budget is used up');
  assert.equal(await bal(O1), 100);

  // the owner can turn ads off on the channel
  await rejects(ads.setChannelAds(V1.id, chId, { off: true }), 'forbidden');
  await ads.setChannelAds(O1.id, chId, { off: true });
  const third = await ads.create(A1.id, { advertiser: 'Shop2', text: 'Another good offer', url: 'https://s.example', cpm_coins: 100, budget_coins: 100 });
  await ads.adminReview(third.ad.id, { decision: 'approve' });
  assert.equal((await ads.sponsoredFor(V1.id, chId)).ad, null);
  const b2 = await bal(A1);
  await ads.setState(A1.id, third.ad.id, 'stop');
  assert.equal(await bal(A1), b2 + 100);

  const bad = await db.many(`SELECT u.id FROM users u WHERE u.coins <> (SELECT COALESCE(sum(delta), 0) FROM coin_tx t WHERE t.user_id = u.id)`);
  assert.equal(bad.length, 0);
  await settings.update({ feature_ads: false, ads_min_subscribers: 3 });
});

test('card payments (Stripe): off by default, signed webhook only, amount checked, coins once', async () => {
  const stripe = require('../src/services/payments/stripe');
  const coins = require('../src/services/coin.service');
  const crypto = require('crypto');
  const S = await signup('+923260000051', 'Sana');
  await rejects(payments.checkoutCard(S.id, { coin_pack_id: 1 }), 'provider_unavailable');
  process.env.STRIPE_SECRET_KEY = 'sk_test_x';
  process.env.STRIPE_WEBHOOK_SECRET = 'whsec_test';
  await rejects(payments.checkoutCard(S.id, { coin_pack_id: 1 }), 'provider_unavailable'); // still off in the admin panel
  await settings.update({ stripe_enabled: true });
  const sessions = {};
  stripe.setTransport(async (method, path, form) => {
    if (method === 'POST') {
      const id = `cs_test_${Object.keys(sessions).length + 1}`;
      sessions[id] = { id, url: `https://checkout.stripe.com/c/pay/${id}`, client_reference_id: form.client_reference_id, amount_total: Number(form['line_items[0][price_data][unit_amount]']), currency: 'usd', payment_status: 'unpaid', status: 'open' };
      return sessions[id];
    }
    return sessions[path.split('/').pop()];
  });
  try {
    assert.ok((await coins.info(S.id)).card.packs.length >= 1);
    const pack = (await db.one('SELECT * FROM coin_packs WHERE is_active ORDER BY coins LIMIT 1'));
    const co = await payments.checkoutCard(S.id, { coin_pack_id: pack.id });
    assert.match(co.pay_url, /^https:\/\/checkout\.stripe\.com\//);
    const sid = Object.keys(sessions)[0];
    // a forged webhook does nothing
    const body = JSON.stringify({ type: 'checkout.session.completed', data: { object: { id: sid } } });
    assert.equal((await payments.stripeWebhook(body, 't=1,v1=abc')).status, 400);
    assert.equal((await payments.getOrder(S.id, co.order.id)).status, 'pending', 'not paid yet');
    // paid, but a different amount: no coins
    sessions[sid].payment_status = 'paid';
    sessions[sid].amount_total += 1;
    const t = Math.floor(Date.now() / 1000);
    const sig = `t=${t},v1=${crypto.createHmac('sha256', 'whsec_test').update(`${t}.${body}`).digest('hex')}`;
    await payments.stripeWebhook(body, sig);
    assert.equal((await users.getMe(S.id)).coins, 0);
    sessions[sid].amount_total -= 1;
    assert.equal((await payments.stripeWebhook(body, sig)).status, 200);
    await payments.stripeWebhook(body, sig); // Stripe sends it again: once only
    assert.equal((await users.getMe(S.id)).coins, pack.coins + pack.bonus);
    assert.equal((await payments.getOrder(S.id, co.order.id)).status, 'paid');

    // cancelled in the app, but the card page was still open and the money was taken: the coins come all the same
    const had = (await users.getMe(S.id)).coins;
    const co2 = await payments.checkoutCard(S.id, { coin_pack_id: pack.id });
    const sid2 = Object.keys(sessions)[1];
    assert.equal((await payments.cancelOrder(S.id, co2.order.id)).status, 'cancelled');
    sessions[sid2].payment_status = 'paid';
    const body2 = JSON.stringify({ type: 'checkout.session.completed', data: { object: { id: sid2 } } });
    const t2 = Math.floor(Date.now() / 1000);
    await payments.stripeWebhook(body2, `t=${t2},v1=${crypto.createHmac('sha256', 'whsec_test').update(`${t2}.${body2}`).digest('hex')}`);
    assert.equal((await payments.getOrder(S.id, co2.order.id)).status, 'paid');
    assert.equal((await users.getMe(S.id)).coins, had + pack.coins + pack.bonus);
    // a refund at Stripe marks the order for a person to look at
    const paidRef = (await db.one('SELECT provider_ref FROM payment_orders WHERE id = $1', [co2.order.id])).provider_ref;
    const body3 = JSON.stringify({ type: 'charge.refunded', data: { object: { id: 'ch_1', payment_intent: paidRef } } });
    await payments.stripeWebhook(body3, `t=${t2},v1=${crypto.createHmac('sha256', 'whsec_test').update(`${t2}.${body3}`).digest('hex')}`);
    assert.match((await payments.getOrder(S.id, co2.order.id)).review_note, /REFUNDED/);
    // the card page could not be made: no order is left waiting
    stripe.setTransport(async () => { throw new Error('Stripe is down'); });
    await rejects(payments.checkoutCard(S.id, { coin_pack_id: pack.id }), 'card_unavailable');
    assert.equal((await db.one(`SELECT count(*)::int AS n FROM payment_orders WHERE user_id = $1 AND status = 'pending'`, [S.id])).n, 0);
  } finally {
    stripe.setTransport(null);
    delete process.env.STRIPE_SECRET_KEY;
    await settings.update({ stripe_enabled: false });
  }
});

test('the database update runs again over real data (deposits, gifts, giveaways, card and coin orders)', async () => {
  // every deploy re-runs schema.sql: an older, shorter list of allowed values must never reject rows already stored
  const kinds = (await db.many('SELECT DISTINCT kind FROM coin_tx')).map((r) => r.kind);
  assert.ok(kinds.includes('deposit') && kinds.includes('gift_sent'), `rows of the newer kinds exist: ${kinds}`);
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
  await db.query(fs.readFileSync(path.join(__dirname, '..', 'src', 'db', 'schema.sql'), 'utf8'));
});

test('fake members: new accounts are limited, suspicious accounts are listed for the admins', async () => {
  const guard = require('../src/services/fakeguard.service');
  guard.setEnforced(true);
  try {
    const N = await signup('+923251110001', 'Newbie', 'newbie_one');
    const owner = await signup('+923251110002', 'Owner', 'owner_two');
    await db.query(`UPDATE users SET created_at = now() - interval '30 days' WHERE id = $1`, [owner.id]);
    // joins: 5 a day, then "wait"
    const ids = [];
    for (let i = 0; i < 6; i += 1) {
      const c = await chats.createChannel(owner.id, { title: `C${i}`, username: `fakecheck_${i}` });
      ids.push(c.id);
    }
    for (let i = 0; i < 5; i += 1) await chats.joinPublic(N.id, ids[i]);
    await rejects(chats.joinPublic(N.id, ids[5]), 'new_account_limit');
    // can't add people yet
    await rejects(chats.createGroup(N.id, { title: 'Farm', member_ids: [owner.id] }), 'new_account_limit');
    // an older account has none of these limits
    await db.query(`UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1`, [N.id]);
    await chats.joinPublic(N.id, ids[5]);
    // the admin list: an account that only joins, never writes, no photo, no contacts
    await db.query(`UPDATE users SET created_at = now() - interval '1 day' WHERE id = $1`, [N.id]);
    const list = await guard.suspicious({ min_score: 3 });
    const me = list.users.find((u) => u.user.id === N.id);
    assert.ok(me, 'listed');
    assert.ok(me.reasons.some((r) => /never wrote/.test(r)));
  } finally {
    guard.setEnforced(false);
  }
});
