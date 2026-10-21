'use strict';

/** Admin panel API. Mounted at /api/admin. */
const express = require('express');
const admin = require('../services/admin.service');
const support = require('../services/support.service');
const announcements = require('../services/announcement.service');
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

// audit log
router.get('/logs', requireAdmin('logs.view'), h(async (req, res) => res.json(await admin.listLogs(req.query))));

// media (for reviewing reported content)
router.get('/media/:id', requireAdmin('media'), h(async (req, res) => {
  const m = await db.one('SELECT * FROM media WHERE id = $1', [v.id(req.params.id, 'media_id')]);
  if (!m) throw notFound('media_not_found', 'File not found');
  // eslint-disable-next-line global-require
  require('./routes.user').sendMedia(res, m, false);
}));

module.exports = { router };
