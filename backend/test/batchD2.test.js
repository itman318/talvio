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
  assert.deepEqual(info.plans.map((p) => p.price_pkr), [299, 2999]);
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
