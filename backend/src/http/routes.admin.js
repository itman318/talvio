'use strict';

/** Admin panel API. Mounted at /api/admin. */
const express = require('express');
const admin = require('../services/admin.service');
const support = require('../services/support.service');
const announcements = require('../services/announcement.service');
const appeals = require('../services/appeal.service');
const content = require('../services/content.service');
const calls = require('../services/call.service');
const bots = require('../services/bot.service');
const payments = require('../services/payment.service');
const ads = require('../services/ads.service');
const db = require('../db');
const v = require('../utils/validate');
const { notFound } = require('../utils/errors');
const { asyncHandler: h, requireAdmin } = require('./middleware');

const router = express.Router();

router.post('/login', h(async (req, res) => res.json(await admin.login(req.body.email, req.body.password, req.ip, req.body.code))));

router.get('/me', requireAdmin(), h(async (req, res) => res.json(admin.serializeAdmin(req.admin))));
router.post('/me/password', requireAdmin(), h(async (req, res) => res.json(await admin.changeOwnPassword(req.admin, req.body, req.ip))));
router.post('/me/2fa/setup', requireAdmin(), h(async (req, res) => res.json(await admin.twoFactorSetup(req.admin))));
router.post('/me/2fa/enable', requireAdmin(), h(async (req, res) => res.json(await admin.twoFactorEnable(req.admin, req.body.code, req.ip))));
router.post('/me/2fa/disable', requireAdmin(), h(async (req, res) => res.json(await admin.twoFactorDisable(req.admin, req.body, req.ip))));

// ---- money: payments, premium, plans, ads, revenue (super admins, or admins with the 'payments' permission)
router.get('/revenue', requireAdmin('payments'), h(async (req, res) => res.json(await ads.adminRevenue())));
router.get('/payments', requireAdmin('payments'), h(async (req, res) => res.json(await payments.adminListOrders(req.query))));
router.post('/payments/:id/approve', requireAdmin('payments'), h(async (req, res) => {
  const r = await payments.adminApprove(req.admin.id, req.params.id, req.body.note);
  await admin.log(req.admin.id, 'payment.approve', 'payment', r.id, { amount_pkr: r.amount_pkr }, req.ip);
  res.json(r);
}));
router.post('/payments/:id/reject', requireAdmin('payments'), h(async (req, res) => {
  const r = await payments.adminReject(req.admin.id, req.params.id, req.body.note);
  await admin.log(req.admin.id, 'payment.reject', 'payment', r.id, { note: req.body.note || null }, req.ip);
  res.json(r);
}));
router.post('/users/:id/premium', requireAdmin('payments'), h(async (req, res) => {
  const r = req.body.months === 0 ? await payments.adminRevoke(req.params.id) : await payments.adminGrant(req.admin.id, req.params.id, req.body.months);
  await admin.log(req.admin.id, req.body.months === 0 ? 'premium.revoke' : 'premium.grant', 'user', parseInt(req.params.id, 10), { months: req.body.months }, req.ip);
  res.json(r);
}));
router.get('/plans', requireAdmin('payments'), h(async (req, res) => res.json(await payments.adminPlans())));
router.post('/plans', requireAdmin('payments'), h(async (req, res) => res.json(await payments.adminSavePlan(null, req.body))));
router.put('/plans/:id', requireAdmin('payments'), h(async (req, res) => res.json(await payments.adminSavePlan(req.params.id, req.body))));
router.get('/ads', requireAdmin('payments'), h(async (req, res) => res.json(await ads.adminList())));
router.post('/ads', requireAdmin('payments'), h(async (req, res) => res.json(await ads.adminSave(req.admin.id, null, req.body))));
router.put('/ads/:id', requireAdmin('payments'), h(async (req, res) => res.json(await ads.adminSave(req.admin.id, req.params.id, req.body))));
router.delete('/ads/:id', requireAdmin('payments'), h(async (req, res) => res.json(await ads.adminDelete(req.params.id))));

router.get('/bots', requireAdmin('users.view'), h(async (req, res) => res.json(await bots.adminList(req.query))));
router.post('/bots/:id/status', requireAdmin('users.ban'), h(async (req, res) => {
  const r = await bots.adminSetStatus(req.params.id, req.body.active === true, req.body.reason);
  await admin.log(req.admin.id, req.body.active === true ? 'bot.enable' : 'bot.disable', 'user', parseInt(req.params.id, 10), { reason: req.body.reason || null }, req.ip);
  res.json(r);
}));
router.get('/calls', requireAdmin('calls.view'), h(async (req, res) => res.json(await calls.adminList(req.query))));
router.get('/calls/stats', requireAdmin('calls.view'), h(async (req, res) => res.json(await calls.adminStats())));
router.post('/calls/:id/end', requireAdmin('calls.manage'), h(async (req, res) => {
  const r = await calls.adminEnd(req.params.id);
  await admin.log(req.admin.id, 'call.end', 'call', parseInt(req.params.id, 10), null, req.ip);
  res.json(r);
}));
router.get('/dashboard', requireAdmin('dashboard'), h(async (req, res) => res.json(await admin.dashboard())));

// users
router.get('/users', requireAdmin('users.view'), h(async (req, res) => res.json(await admin.listUsers(req.query))));
router.get('/users/:id', requireAdmin('users.view'), h(async (req, res) => res.json(await admin.userDetail(req.params.id))));
router.post('/users/:id/ban', requireAdmin('users.ban'), h(async (req, res) => res.json(await admin.banUser(req.admin, req.params.id, req.body, req.ip))));
router.post('/users/:id/unban', requireAdmin('users.ban'), h(async (req, res) => res.json(await admin.unbanUser(req.admin, req.params.id, req.ip))));
router.post('/users/:id/logout-all', requireAdmin('users.logout'), h(async (req, res) => res.json(await admin.logoutAll(req.admin, req.params.id, req.ip))));
router.post('/users/:id/verify', requireAdmin('users.verify'), h(async (req, res) => {
  res.json(await admin.setVerified(req.admin, req.params.id, req.body.verified, req.ip));
}));
router.post('/users/:id/restrict', requireAdmin('users.ban'), h(async (req, res) => res.json(await admin.restrictUser(req.admin, req.params.id, req.body, req.ip))));
router.post('/users/:id/unrestrict', requireAdmin('users.ban'), h(async (req, res) => res.json(await admin.unrestrictUser(req.admin, req.params.id, req.ip))));
router.post('/users/:id/notes', requireAdmin('users.view'), h(async (req, res) => res.json(await admin.addNote(req.admin, req.params.id, req.body, req.ip))));
router.delete('/notes/:id', requireAdmin('users.view'), h(async (req, res) => res.json(await admin.deleteNote(req.admin, req.params.id))));
router.get('/users/:id/export', requireAdmin('users.export'), h(async (req, res) => {
  const data = await admin.exportUser(req.admin, req.params.id, req.ip);
  res.setHeader('Content-Disposition', `attachment; filename="user-${data.profile.id}-data.json"`);
  res.json(data);
}));
router.put('/users/:id/username', requireAdmin('users.username'), h(async (req, res) => {
  res.json(await admin.setUsername(req.admin, req.params.id, req.body.username, req.ip));
}));
router.delete('/users/:id', requireAdmin('users.delete'), h(async (req, res) => res.json(await admin.deleteUser(req.admin, req.params.id, req.ip))));

// reports
router.get('/reports', requireAdmin('reports.view'), h(async (req, res) => res.json(await admin.listReports(req.query))));
router.get('/reports/:id', requireAdmin('reports.view'), h(async (req, res) => res.json(await admin.reportDetail(req.params.id))));
router.post('/reports/:id/resolve', requireAdmin('reports.resolve'), h(async (req, res) => {
  res.json(await admin.resolveReport(req.admin, req.params.id, req.body, req.ip));
}));

// groups
router.get('/groups', requireAdmin('groups.view'), h(async (req, res) => res.json(await admin.listGroups(req.query))));
router.post('/groups/:id/suspend', requireAdmin('groups.suspend'), h(async (req, res) => {
  res.json(await admin.setGroupSuspended(req.admin, req.params.id, true, req.body.reason, req.ip));
}));
router.post('/groups/:id/unsuspend', requireAdmin('groups.suspend'), h(async (req, res) => {
  res.json(await admin.setGroupSuspended(req.admin, req.params.id, false, null, req.ip));
}));
router.post('/groups/:id/verify', requireAdmin('groups.verify'), h(async (req, res) => {
  res.json(await admin.setChatVerified(req.admin, req.params.id, req.body.verified, req.ip));
}));
router.get('/groups/:id/members', requireAdmin('groups.view'), h(async (req, res) => res.json(await admin.groupMembers(req.params.id, req.query))));
router.post('/groups/:id/transfer', requireAdmin('groups.transfer'), h(async (req, res) => {
  res.json(await admin.transferGroupOwner(req.admin, req.params.id, req.body, req.ip));
}));
router.delete('/groups/:id', requireAdmin('groups.delete'), h(async (req, res) => res.json(await admin.deleteGroup(req.admin, req.params.id, req.ip))));

// settings
router.get('/settings', requireAdmin('settings'), h(async (req, res) => res.json(await admin.getSettings())));
router.put('/settings', requireAdmin('settings'), h(async (req, res) => res.json(await admin.updateSettings(req.admin, req.body, req.ip))));

// admin team
router.get('/admins', requireAdmin('admins'), h(async (req, res) => res.json(await admin.listAdmins())));
router.post('/admins', requireAdmin('admins'), h(async (req, res) => res.json(await admin.createAdmin(req.admin, req.body, req.ip))));
router.patch('/admins/:id', requireAdmin('admins'), h(async (req, res) => res.json(await admin.updateAdmin(req.admin, req.params.id, req.body, req.ip))));

// broadcast announcements (super admin)
router.get('/announcements', requireAdmin('broadcast'), h(async (req, res) => res.json(await announcements.list(req.query))));
router.post('/announcements', requireAdmin('broadcast'), h(async (req, res) => {
  const a = await announcements.create(req.admin.id, req.body);
  await require('../db').query(
    `INSERT INTO admin_logs (admin_id, action, target_type, target_id, details, ip) VALUES ($1, 'broadcast.send', 'announcement', $2, $3, $4)`,
    [req.admin.id, a.id, JSON.stringify({ title: a.title, recipients: a.recipients, push: a.push }), req.ip],
  );
  res.json(a);
}));
router.post('/announcements/:id/expire', requireAdmin('broadcast'), h(async (req, res) => res.json(await announcements.expire(req.params.id))));

// support tickets
router.get('/support', requireAdmin('support'), h(async (req, res) => {
  res.json(await support.adminList({ ...req.query, admin_id: req.query.mine === 'true' ? req.admin.id : undefined }));
}));
router.get('/support/:id', requireAdmin('support'), h(async (req, res) => res.json(await support.adminGet(req.params.id))));
router.post('/support/:id/reply', requireAdmin('support'), h(async (req, res) => res.json(await support.adminReply(req.admin, req.params.id, req.body))));
router.patch('/support/:id', requireAdmin('support'), h(async (req, res) => res.json(await support.adminUpdate(req.params.id, req.body))));

// ban appeals
router.get('/appeals', requireAdmin('users.view'), h(async (req, res) => res.json(await appeals.list(req.query))));
router.post('/appeals/:id/resolve', requireAdmin('users.ban'), h(async (req, res) => res.json(await appeals.resolve(req.admin, req.params.id, req.body, req.ip))));

// content pages (terms, privacy, faq, about)
router.get('/pages', requireAdmin('settings'), h(async (req, res) => res.json(await content.list())));
router.put('/pages/:slug', requireAdmin('settings'), h(async (req, res) => {
  const page = await content.update(req.admin.id, req.params.slug, req.body);
  await require('../db').query(
    `INSERT INTO admin_logs (admin_id, action, target_type, details, ip) VALUES ($1, 'page.update', 'page', $2, $3)`,
    [req.admin.id, JSON.stringify({ slug: page.slug }), req.ip],
  );
  res.json(page);
}));

// audit log
router.get('/crashes', requireAdmin('logs.view'), h(async (req, res) => res.json(await require('../services/crash.service').list(req.query))));
router.post('/crashes/:id/resolve', requireAdmin('logs.view'), h(async (req, res) => res.json(await require('../services/crash.service').resolve(req.params.id, req.body.resolved !== false))));
router.get('/logs', requireAdmin('logs.view'), h(async (req, res) => res.json(await admin.listLogs(req.query))));

// media (for reviewing reported content)
router.get('/media/:id', requireAdmin('media'), h(async (req, res) => {
  const m = await db.one('SELECT * FROM media WHERE id = $1', [v.id(req.params.id, 'media_id')]);
  if (!m) throw notFound('media_not_found', 'File not found');
  // eslint-disable-next-line global-require
  require('./routes.user').sendMedia(res, m, false);
}));

module.exports = { router };
