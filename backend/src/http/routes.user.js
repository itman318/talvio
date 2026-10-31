'use strict';

/**
 * Mobile-app REST API. Mounted at /api.
 * All responses are JSON. Errors: { error: { code, message, ...extra } }.
 */
const fs = require('fs');
const path = require('path');
const express = require('express');
const multer = require('multer');
const config = require('../config');
const passwordService = require('../services/password.service');
const passkeyService = require('../services/passkey.service');
const authService = require('../services/auth.service');
const userService = require('../services/user.service');
const chatService = require('../services/chat.service');
const messageService = require('../services/message.service');
const mediaService = require('../services/media.service');
const reportService = require('../services/report.service');
const folderService = require('../services/folder.service');
const storyService = require('../services/story.service');
const supportService = require('../services/support.service');
const announcementService = require('../services/announcement.service');
const appealService = require('../services/appeal.service');
const contentService = require('../services/content.service');
const callService = require('../services/call.service');
const secretService = require('../services/secret.service');
const botService = require('../services/bot.service');
const topicService = require('../services/topic.service');
const paymentService = require('../services/payment.service');
const qrService = require('../services/qr.service');
const adsService = require('../services/ads.service');
const settings = require('../services/settings.service');
const { randomToken } = require('../utils/crypto');
const { badRequest } = require('../utils/errors');
const { asyncHandler: h, requireUser, maintenanceGate, ipGate } = require('./middleware');

const router = express.Router();

// ------------------------------------------------------------------ public
router.get('/app-config', h(async (req, res) => res.json(await settings.publicConfig())));
router.get('/pages/:slug', h(async (req, res) => res.json(await contentService.get(req.params.slug))));

router.use(ipGate);
router.use(maintenanceGate);

router.post('/appeals', h(async (req, res) => res.json(await appealService.create(req.body))));

router.post('/auth/otp/request', h(async (req, res) => {
  res.json(await authService.requestOtp(req.body.phone, req.ip));
}));

router.post('/auth/otp/verify', h(async (req, res) => {
  res.json(await authService.verifyOtp(req.body.phone, req.body.code, req.body.device, req.ip));
}));

// Crash reports (login optional — the app may crash before or during login)
router.post('/client-errors', h(async (req, res) => {
  let userId = null;
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer ')) {
    try {
      userId = (await authService.authenticate(auth.slice(7))).user.id;
    } catch (_) {
      userId = null;
    }
  }
  res.json(await require('../services/crash.service').record(userId, req.body || {}, req.ip));
}));

router.post('/auth/email/request', h(async (req, res) => {
  res.json(await authService.requestEmailCode(req.body.email, req.ip));
}));

router.post('/auth/email/verify', h(async (req, res) => {
  res.json(await authService.verifyEmailCode(req.body.email, req.body.code, req.body.device, req.ip));
}));

router.post('/auth/password/verify', h(async (req, res) => {
  res.json(await passwordService.verifyLogin(req.body.login_token, req.body.password, req.body.device, req.ip));
}));
router.post('/auth/password/reset', h(async (req, res) => res.json(await passwordService.requestReset(req.body.login_token))));

// notification actions (the reply token in the push is the credential)
router.post('/notify/reply', h(async (req, res) => res.json(await require('../services/notify.service').reply(req.body))));
router.post('/notify/read', h(async (req, res) => res.json(await require('../services/notify.service').read(req.body))));

router.post('/auth/passkey/challenge', h(async (req, res) => res.json(await passkeyService.challenge(req.body, req.ip))));
router.post('/auth/passkey/verify', h(async (req, res) => res.json(await passkeyService.verify(req.body, req.ip))));

router.post('/auth/qr', h(async (req, res) => res.json(await qrService.create(req.body.device || {}, req.ip))));
router.get('/auth/qr/status', h(async (req, res) => res.json(await qrService.status(req.query.token, req.query.wait, req.ip))));

router.post('/auth/refresh', h(async (req, res) => {
  res.json(await authService.refresh(req.body.refresh_token, req.ip));
}));

router.get('/media/:id/public', h(async (req, res) => {
  sendMedia(res, await mediaService.getPublic(req.params.id), true);
}));

// ------------------------------------------------------------------ authenticated
router.use(requireUser);

router.get('/me/passkeys', h(async (req, res) => res.json(await passkeyService.list(req.userId))));
router.post('/me/passkeys', h(async (req, res) => res.json(await passkeyService.register(req.userId, req.body))));
router.delete('/me/passkeys/:id', h(async (req, res) => res.json(await passkeyService.remove(req.userId, req.params.id))));
router.get('/me/password', h(async (req, res) => res.json(await passwordService.get(req.userId))));
router.put('/me/password', h(async (req, res) => res.json(await passwordService.set(req.userId, req.body))));
router.post('/me/password/remove', h(async (req, res) => res.json(await passwordService.remove(req.userId, req.body))));
router.post('/me/password/cancel-reset', h(async (req, res) => res.json(await passwordService.cancelReset(req.userId))));

router.post('/auth/logout', h(async (req, res) => res.json(await authService.logout(req.userId, req.sessionId))));
router.post('/auth/qr/scan', h(async (req, res) => res.json(await qrService.scan(req.userId, req.body.token))));
router.post('/auth/qr/approve', h(async (req, res) => res.json(await qrService.approve(req.userId, req.body.token))));
router.post('/auth/qr/decline', h(async (req, res) => res.json(await qrService.decline(req.userId, req.body.token))));

// --- me
router.get('/me', h(async (req, res) => res.json(await userService.getMe(req.userId))));
router.patch('/me', h(async (req, res) => res.json(await userService.updateProfile(req.userId, req.body))));
router.put('/me/privacy', h(async (req, res) => res.json(await userService.updatePrivacy(req.userId, req.body))));
router.get('/me/privacy/exceptions', h(async (req, res) => res.json(await userService.getPrivacyExceptions(req.userId))));
router.put('/me/privacy/exceptions/:setting', h(async (req, res) => res.json(await userService.setPrivacyExceptions(req.userId, req.params.setting, req.body))));
router.get('/me/birthdays', h(async (req, res) => res.json({ birthdays: await userService.upcomingBirthdays(req.userId) })));
const business = require('../services/business.service');
router.get('/me/business', h(async (req, res) => res.json(await business.get(req.userId))));
router.put('/me/business', h(async (req, res) => res.json(await business.set(req.userId, req.body))));
router.get('/me/quick-replies', h(async (req, res) => res.json(await business.listReplies(req.userId))));
router.post('/me/quick-replies', h(async (req, res) => res.json(await business.addReply(req.userId, req.body))));
router.put('/me/quick-replies/:id', h(async (req, res) => res.json(await business.updateReply(req.userId, req.params.id, req.body))));
router.delete('/me/quick-replies/:id', h(async (req, res) => res.json(await business.deleteReply(req.userId, req.params.id))));
router.get('/me/notifications', h(async (req, res) => res.json(await userService.getNotifySettings(req.userId))));
router.put('/me/notifications', h(async (req, res) => res.json(await userService.setNotifySettings(req.userId, req.body))));
router.put('/me/avatar', h(async (req, res) => res.json(await userService.setAvatar(req.userId, req.body.media_id))));
router.delete('/me/avatar', h(async (req, res) => res.json(await userService.removeAvatar(req.userId))));
router.get('/me/username-check', h(async (req, res) => res.json(await userService.checkUsername(req.userId, req.query.username))));
router.get('/me/login-activity', h(async (req, res) => res.json(await userService.loginActivity(req.userId, req.sessionId))));
router.post('/me/login-activity/:sessionId/not-me', h(async (req, res) => res.json(await userService.notMe(req.userId, req.sessionId, req.params.sessionId))));
router.get('/me/sessions', h(async (req, res) => res.json(await userService.listSessions(req.userId, req.sessionId))));
router.delete('/me/sessions/:id', h(async (req, res) => res.json(await userService.revokeSession(req.userId, req.params.id))));
router.post('/me/sessions/terminate-others', h(async (req, res) => {
  res.json(await userService.revokeOtherSessions(req.userId, req.sessionId));
}));
router.put('/me/push-token', h(async (req, res) => {
  res.json(await userService.setFcmToken(req.userId, req.sessionId, req.body.token === undefined ? null : req.body.token));
}));
router.get('/me/export', h(async (req, res) => {
  res.setHeader('Content-Disposition', 'attachment; filename="my-data.json"');
  res.json(await userService.exportData(req.userId));
}));
router.delete('/me', h(async (req, res) => {
  if (req.body.confirm !== 'DELETE') throw badRequest('confirm_required', 'Send {"confirm":"DELETE"} to delete your account');
  res.json(await userService.deleteAccount(req.userId));
}));

// --- users, contacts, blocks
router.get('/users/search', h(async (req, res) => res.json(await userService.searchUsers(req.userId, req.query.q))));
router.get('/users/:id', h(async (req, res) => res.json(await userService.getUser(req.userId, parseIdParam(req.params.id)))));

router.get('/contacts', h(async (req, res) => res.json(await userService.listContacts(req.userId))));
router.post('/contacts/sync', h(async (req, res) => res.json(await userService.syncContacts(req.userId, req.body.phones))));
router.post('/contacts/:userId', h(async (req, res) => res.json(await userService.addContact(req.userId, req.params.userId))));
router.delete('/contacts/:userId', h(async (req, res) => res.json(await userService.removeContact(req.userId, req.params.userId))));

router.get('/blocks', h(async (req, res) => res.json(await userService.listBlocked(req.userId))));
router.post('/blocks/:userId', h(async (req, res) => res.json(await userService.block(req.userId, req.params.userId))));
router.delete('/blocks/:userId', h(async (req, res) => res.json(await userService.unblock(req.userId, req.params.userId))));

// --- chats
router.get('/chats', h(async (req, res) => {
  res.json(await chatService.listChats(req.userId, { archived: req.query.archived === 'true' }));
}));
router.post('/chats/private', h(async (req, res) => res.json(await chatService.getOrCreatePrivate(req.userId, req.body.user_id))));
router.post('/chats/group', h(async (req, res) => res.json(await chatService.createGroup(req.userId, req.body))));
router.post('/chats/channel', h(async (req, res) => res.json(await chatService.createChannel(req.userId, req.body))));
router.get('/chats/search', h(async (req, res) => res.json(await chatService.searchPublic(req.userId, req.query.q))));
router.get('/chats/public/:username', h(async (req, res) => res.json(await chatService.publicPreview(req.userId, req.params.username))));
router.get('/chats/invite/:code', h(async (req, res) => res.json(await chatService.invitePreview(req.userId, req.params.code))));
router.post('/chats/invite/:code/join', h(async (req, res) => res.json(await chatService.joinByInvite(req.userId, req.params.code))));
router.get('/chats/:id', h(async (req, res) => res.json(await chatService.getChat(req.userId, req.params.id))));
router.patch('/chats/:id', h(async (req, res) => res.json(await chatService.updateGroup(req.userId, req.params.id, req.body))));
router.put('/chats/:id/avatar', h(async (req, res) => {
  res.json(await chatService.setGroupAvatar(req.userId, req.params.id, req.body.media_id === undefined ? null : req.body.media_id));
}));
router.get('/chats/:id/members', h(async (req, res) => res.json(await chatService.getMembers(req.userId, req.params.id))));
router.post('/chats/:id/members', h(async (req, res) => res.json(await chatService.addMembers(req.userId, req.params.id, req.body.user_ids))));
router.delete('/chats/:id/members/:userId', h(async (req, res) => {
  res.json(await chatService.removeMember(req.userId, req.params.id, req.params.userId));
}));
router.put('/chats/:id/members/:userId/role', h(async (req, res) => {
  res.json(await chatService.setMemberRole(req.userId, req.params.id, req.params.userId, req.body.role, { rights: req.body.rights, title: req.body.title }));
}));
router.post('/chats/:id/members/:userId/restrict', h(async (req, res) => {
  res.json(await chatService.restrictMember(req.userId, req.params.id, req.params.userId, req.body.minutes));
}));
router.get('/chats/:id/events', h(async (req, res) => res.json(await chatService.listEvents(req.userId, req.params.id, req.query))));
router.put('/chats/:id/draft', h(async (req, res) => res.json(await chatService.setDraft(req.userId, req.params.id, req.body.text))));
router.get('/channels/directory', h(async (req, res) => res.json(await chatService.directory(req.userId, req.query))));
router.get('/messages/:id/info', h(async (req, res) => res.json(await messageService.messageInfo(req.userId, req.params.id))));
router.get('/chats/:id/queue', h(async (req, res) => res.json(await messageService.listQueue(req.userId, req.params.id))));
router.post('/chats/:id/queue/:qid/publish', h(async (req, res) => res.json(await messageService.publishQueued(req.userId, req.params.id, req.params.qid))));
router.delete('/chats/:id/queue/:qid', h(async (req, res) => res.json(await messageService.deleteQueued(req.userId, req.params.id, req.params.qid))));
router.post('/chats/:id/leave', h(async (req, res) => res.json(await chatService.leaveChat(req.userId, req.params.id))));
router.put('/chats/:id/members/:userId/tag', h(async (req, res) => res.json(await chatService.setMemberTag(req.userId, req.params.id, req.params.userId, req.body.tag))));
router.get('/chats/:id/similar', h(async (req, res) => res.json(await chatService.similarChannels(req.userId, req.params.id))));
router.get('/chats/:id/online', h(async (req, res) => res.json(await chatService.onlineCount(req.userId, req.params.id))));
router.post('/chats/:id/verify-human', h(async (req, res) => res.json(await chatService.verifyHuman(req.userId, req.params.id))));
router.post('/chats/:id/request/accept', h(async (req, res) => res.json(await chatService.acceptRequest(req.userId, req.params.id))));
router.post('/chats/:id/request/decline', h(async (req, res) => res.json(await chatService.declineRequest(req.userId, req.params.id, req.body))));
router.put('/chats/:id/disappearing', h(async (req, res) => res.json(await chatService.setDisappearing(req.userId, req.params.id, req.body.seconds))));
router.patch('/chats/:id/settings', h(async (req, res) => res.json(await chatService.updateMySettings(req.userId, req.params.id, req.body))));
router.post('/chats/:id/clear', h(async (req, res) => res.json(await chatService.clearHistory(req.userId, req.params.id, req.body || {}))));
router.post('/chats/:id/invite/regenerate', h(async (req, res) => res.json(await chatService.regenerateInvite(req.userId, req.params.id))));
router.post('/chats/:id/join', h(async (req, res) => res.json(await chatService.joinPublic(req.userId, req.params.id))));
router.get('/chats/:id/invites', h(async (req, res) => res.json(await chatService.listInvites(req.userId, req.params.id))));
router.post('/chats/:id/invites', h(async (req, res) => res.json(await chatService.createInvite(req.userId, req.params.id, req.body))));
router.delete('/chats/:id/invites/:code', h(async (req, res) => res.json(await chatService.revokeInvite(req.userId, req.params.id, req.params.code))));
router.get('/chats/:id/join-requests', h(async (req, res) => res.json(await chatService.listJoinRequests(req.userId, req.params.id))));
router.post('/chats/:id/join-requests/:userId/approve', h(async (req, res) => {
  res.json(await chatService.resolveJoinRequest(req.userId, req.params.id, req.params.userId, true));
}));
router.post('/chats/:id/join-requests/:userId/decline', h(async (req, res) => {
  res.json(await chatService.resolveJoinRequest(req.userId, req.params.id, req.params.userId, false));
}));
router.put('/chats/:id/owner', h(async (req, res) => res.json(await chatService.transferOwnershipByOwner(req.userId, req.params.id, req.body.user_id))));
router.get('/chats/:id/pins', h(async (req, res) => res.json(await messageService.listPins(req.userId, req.params.id))));
router.post('/chats/:id/pins', h(async (req, res) => res.json(await messageService.pinMessage(req.userId, req.params.id, req.body.message_id))));
router.delete('/chats/:id/pins/:messageId', h(async (req, res) => res.json(await messageService.unpinMessage(req.userId, req.params.id, req.params.messageId))));
// ---- calls (signaling itself runs over Socket.IO; these mirror it for the app's history & cold start)
router.get('/calls', h(async (req, res) => res.json(await callService.listCalls(req.userId, req.query))));
router.get('/calls/active', h(async (req, res) => res.json(await callService.getActive(req.userId))));
router.get('/calls/ice-servers', h(async (req, res) => res.json({ ice_servers: await callService.iceServers(req.userId) })));
router.post('/calls', h(async (req, res) => res.json(await callService.startCall(req.userId, req.sessionId, req.body))));
router.get('/calls/links', h(async (req, res) => res.json(await callService.listLinks(req.userId))));
router.post('/calls/links', h(async (req, res) => res.json(await callService.createLink(req.userId, req.body))));
router.get('/calls/links/:code', h(async (req, res) => res.json(await callService.resolveLink(req.userId, req.params.code))));
router.delete('/calls/links/:code', h(async (req, res) => res.json(await callService.deleteLink(req.userId, req.params.code))));
router.post('/calls/delete', h(async (req, res) => res.json(await callService.deleteCalls(req.userId, req.body))));
router.post('/calls/:id/accept', h(async (req, res) => res.json(await callService.acceptCall(req.userId, req.sessionId, req.params.id))));
router.post('/calls/:id/decline', h(async (req, res) => res.json(await callService.declineCall(req.userId, req.params.id))));
router.post('/calls/:id/hangup', h(async (req, res) => res.json(await callService.hangup(req.userId, req.params.id, req.body.reason))));
router.post('/calls/:id/rate', h(async (req, res) => res.json(await callService.rateCall(req.userId, req.params.id, req.body))));
// ---- premium & payments
router.get('/premium', h(async (req, res) => res.json(await paymentService.premiumInfo(req.userId, { country: req.get('x-country') || req.query.country, locale: req.get('accept-language') }))));
router.post('/payments/checkout', h(async (req, res) => res.json(await paymentService.checkout(req.userId, { ...req.body, country: req.body.country || req.get('x-country'), locale: req.get('accept-language') }))));
router.get('/payments/orders', h(async (req, res) => res.json(await paymentService.listMyOrders(req.userId))));
router.get('/payments/orders/:id', h(async (req, res) => res.json(await paymentService.getOrder(req.userId, req.params.id))));
router.post('/payments/orders/:id/cancel', h(async (req, res) => res.json(await paymentService.cancelOrder(req.userId, req.params.id))));
router.post('/payments/orders/:id/proof', h(async (req, res) => res.json(await paymentService.submitProof(req.userId, req.params.id, req.body))));

// ---- sponsored messages
router.get('/chats/:id/sponsored', h(async (req, res) => res.json(await adsService.sponsoredFor(req.userId, req.params.id))));
router.post('/ads/:id/view', h(async (req, res) => res.json(await adsService.recordView(req.userId, req.params.id))));
router.post('/ads/:id/click', h(async (req, res) => res.json(await adsService.recordClick(req.userId, req.params.id))));

// ---- bots (my bots) & mini apps
router.get('/bots', h(async (req, res) => res.json(await botService.listMyBots(req.userId))));
router.post('/bots', h(async (req, res) => res.json(await botService.createBot(req.userId, req.body))));
router.patch('/bots/:id', h(async (req, res) => res.json(await botService.updateBot(req.userId, req.params.id, req.body))));
router.post('/bots/:id/token', h(async (req, res) => res.json(await botService.regenerateToken(req.userId, req.params.id))));
router.delete('/bots/:id', h(async (req, res) => res.json(await botService.deleteBot(req.userId, req.params.id))));
router.post('/bots/:id/web-app', h(async (req, res) => res.json(await botService.webAppInit(req.userId, req.params.id, req.body))));
router.post('/bots/:id/web-app-data', h(async (req, res) => res.json(await botService.webAppData(req.userId, req.params.id, req.body))));
router.post('/messages/:id/callback', h(async (req, res) => res.json(await botService.pressButton(req.userId, req.params.id, req.body))));

// ---- group topics
router.get('/chats/:id/topics', h(async (req, res) => res.json(await topicService.list(req.userId, req.params.id))));
router.post('/chats/:id/topics', h(async (req, res) => res.json(await topicService.create(req.userId, req.params.id, req.body))));
router.patch('/chats/:id/topics/:topicId', h(async (req, res) => res.json(await topicService.update(req.userId, req.params.id, req.params.topicId, req.body))));
router.delete('/chats/:id/topics/:topicId', h(async (req, res) => res.json(await topicService.remove(req.userId, req.params.id, req.params.topicId))));

// ---- secret chats (also available over Socket.IO; ciphertext only)
router.get('/secret-chats', h(async (req, res) => res.json(await secretService.list(req.userId, req.sessionId))));
router.get('/secret-chats/pending', h(async (req, res) => res.json(await secretService.pending(req.userId, req.sessionId))));
router.post('/secret-chats', h(async (req, res) => res.json(await secretService.create(req.userId, req.sessionId, req.body))));
router.post('/secret-chats/:id/accept', h(async (req, res) => res.json(await secretService.accept(req.userId, req.sessionId, req.params.id, req.body))));
router.post('/secret-chats/:id/close', h(async (req, res) => res.json(await secretService.close(req.userId, req.sessionId, req.params.id))));
router.post('/secret-chats/:id/messages', h(async (req, res) => {
  res.json(await secretService.send(req.userId, req.sessionId, { ...req.body, secret_chat_id: req.params.id }));
}));
router.post('/secret-chats/:id/ack', h(async (req, res) => res.json(await secretService.ack(req.userId, req.sessionId, { ...req.body, secret_chat_id: req.params.id }))));
router.post('/secret-chats/:id/read', h(async (req, res) => res.json(await secretService.markRead(req.userId, req.sessionId, { ...req.body, secret_chat_id: req.params.id }))));
router.get('/search', h(async (req, res) => res.json(await require('../services/search.service').search(req.userId, req.query)))); // eslint-disable-line global-require
router.get('/search/messages', h(async (req, res) => res.json(await messageService.searchMessages(req.userId, req.query))));
router.put('/chats/:id/username', h(async (req, res) => res.json(await chatService.setChatUsername(req.userId, req.params.id, req.body.username))));
router.get('/chats/:id/stats', h(async (req, res) => res.json(await chatService.chatStats(req.userId, req.params.id))));
router.post('/chats/:id/views', h(async (req, res) => res.json(await messageService.recordViews(req.userId, req.params.id, req.body.message_ids))));
router.get('/chats/:id/scheduled', h(async (req, res) => res.json(await messageService.listScheduled(req.userId, req.params.id))));
router.delete('/scheduled/:id', h(async (req, res) => res.json(await messageService.cancelScheduled(req.userId, req.params.id))));

// --- messages
router.get('/chats/:id/media-counts', h(async (req, res) => res.json(await messageService.mediaCounts(req.userId, req.params.id))));
router.get('/chats/:id/live-locations', h(async (req, res) => res.json(await messageService.liveLocations(req.userId, req.params.id))));
router.get('/chats/:id/messages', h(async (req, res) => res.json(await messageService.listMessages(req.userId, req.params.id, req.query))));
router.post('/chats/:id/messages', h(async (req, res) => res.json(await messageService.sendMessage(req.userId, req.params.id, req.body))));
router.post('/chats/:id/messages/delete', h(async (req, res) => res.json(await messageService.deleteMessages(req.userId, req.params.id, req.body))));
router.post('/chats/:id/read', h(async (req, res) => res.json(await messageService.markRead(req.userId, req.params.id, req.body.message_id))));
router.post('/messages/:id/live', h(async (req, res) => res.json(await messageService.updateLiveLocation(req.userId, req.params.id, req.body))));
router.patch('/messages/:id', h(async (req, res) => res.json(await messageService.editMessage(req.userId, req.params.id, req.body))));
router.post('/messages/forward', h(async (req, res) => res.json(await messageService.forwardMessages(req.userId, req.body))));
// ---- live voice chats
const voiceChats = require('../services/voicechat.service');
router.get('/chats/:id/voice-chat', h(async (req, res) => res.json(await voiceChats.get(req.userId, req.params.id))));
router.post('/chats/:id/voice-chat', h(async (req, res) => res.json(await voiceChats.start(req.userId, req.params.id, { ...req.body, session_id: req.sessionId }))));
router.post('/chats/:id/voice-chat/join', h(async (req, res) => res.json(await voiceChats.join(req.userId, req.params.id, req.body, req.sessionId))));
router.post('/chats/:id/voice-chat/leave', h(async (req, res) => res.json(await voiceChats.leave(req.userId, req.params.id))));
router.post('/chats/:id/voice-chat/end', h(async (req, res) => res.json(await voiceChats.end(req.userId, req.params.id))));
router.patch('/chats/:id/voice-chat', h(async (req, res) => res.json(await voiceChats.update(req.userId, req.params.id, req.body))));
router.get('/bots/inline', h(async (req, res) => res.json(await require('../services/bot.service').inlineQuery(req.userId, req.query)))); // eslint-disable-line global-require
router.post('/bots/inline/send', h(async (req, res) => res.json(await require('../services/bot.service').sendInlineResult(req.userId, req.body)))); // eslint-disable-line global-require
router.get('/bookmarks', h(async (req, res) => res.json(await messageService.listBookmarks(req.userId))));
router.post('/messages/:id/bookmark', h(async (req, res) => res.json(await messageService.addBookmark(req.userId, req.params.id))));
router.delete('/messages/:id/bookmark', h(async (req, res) => res.json(await messageService.removeBookmark(req.userId, req.params.id))));
router.post('/messages/:id/played', h(async (req, res) => res.json(await messageService.markPlayed(req.userId, req.params.id))));
router.post('/messages/:id/open-once', h(async (req, res) => res.json(await messageService.openOnce(req.userId, req.params.id))));
router.get('/messages/:id/edits', h(async (req, res) => res.json(await messageService.editHistory(req.userId, req.params.id))));
router.put('/messages/:id/reaction', h(async (req, res) => res.json(await messageService.react(req.userId, req.params.id, req.body.emoji))));
router.post('/messages/:id/vote', h(async (req, res) => res.json(await messageService.vote(req.userId, req.params.id, req.body.options))));
router.post('/messages/:id/poll/close', h(async (req, res) => res.json(await messageService.closePoll(req.userId, req.params.id))));
router.get('/messages/:id/poll/voters', h(async (req, res) => res.json(await messageService.pollVoters(req.userId, req.params.id, req.query.option))));

// --- folders
// stickers & GIFs
const stickerService = require('../services/sticker.service');
router.get('/stickers/packs', h(async (req, res) => res.json(await stickerService.myPacks(req.userId))));
router.get('/stickers/search', h(async (req, res) => res.json(await stickerService.searchPacks(req.userId, req.query.q))));
router.post('/stickers/packs', h(async (req, res) => res.json(await stickerService.createPack(req.userId, req.body))));
router.get('/stickers/packs/:id', h(async (req, res) => res.json(await stickerService.getPack(req.userId, req.params.id))));
router.delete('/stickers/packs/:id', h(async (req, res) => res.json(await stickerService.deletePack(req.userId, req.params.id))));
router.post('/stickers/packs/:id/install', h(async (req, res) => res.json(await stickerService.installPack(req.userId, req.params.id))));
router.post('/stickers/packs/:id/uninstall', h(async (req, res) => res.json(await stickerService.uninstallPack(req.userId, req.params.id))));
router.post('/stickers/packs/:id/stickers', h(async (req, res) => res.json(await stickerService.addSticker(req.userId, req.params.id, req.body))));
router.delete('/stickers/packs/:id/stickers/:stickerId', h(async (req, res) => res.json(await stickerService.removeSticker(req.userId, req.params.id, req.params.stickerId))));
router.get('/gifs', h(async (req, res) => res.json(await stickerService.gifs(req.userId, req.query))));

router.get('/folders', h(async (req, res) => res.json(await folderService.list(req.userId))));
router.post('/folders', h(async (req, res) => res.json(await folderService.create(req.userId, req.body))));
router.put('/folders/order', h(async (req, res) => res.json(await folderService.reorder(req.userId, req.body.folder_ids))));
router.patch('/folders/:id', h(async (req, res) => res.json(await folderService.update(req.userId, req.params.id, req.body))));
router.delete('/folders/:id', h(async (req, res) => res.json(await folderService.remove(req.userId, req.params.id))));

// --- stories
router.get('/stories', h(async (req, res) => res.json(await storyService.feed(req.userId))));
router.post('/stories', h(async (req, res) => res.json(await storyService.create(req.userId, req.body))));
router.post('/stories/:id/view', h(async (req, res) => res.json(await storyService.view(req.userId, req.params.id, req.body))));
router.get('/stories/:id/viewers', h(async (req, res) => res.json(await storyService.viewers(req.userId, req.params.id))));
router.post('/stories/:id/reply', h(async (req, res) => res.json(await storyService.reply(req.userId, req.params.id, req.body))));
router.delete('/stories/:id', h(async (req, res) => res.json(await storyService.remove(req.userId, req.params.id))));
router.post('/stories/:id/react', h(async (req, res) => res.json(await storyService.react(req.userId, req.params.id, req.body))));
router.get('/me/stories/archive', h(async (req, res) => res.json(await storyService.archive(req.userId, req.query))));
router.get('/users/:id/highlights', h(async (req, res) => res.json(await storyService.listHighlights(req.userId, req.params.id))));
router.get('/highlights/:id', h(async (req, res) => res.json(await storyService.getHighlight(req.userId, req.params.id))));
router.post('/highlights', h(async (req, res) => res.json(await storyService.createHighlight(req.userId, req.body))));
router.patch('/highlights/:id', h(async (req, res) => res.json(await storyService.updateHighlight(req.userId, req.params.id, req.body))));
router.delete('/highlights/:id', h(async (req, res) => res.json(await storyService.deleteHighlight(req.userId, req.params.id))));

// --- support tickets & announcements
// --- in-app notifications
router.get('/notices', h(async (req, res) => res.json(await require('../services/notice.service').list(req.userId, req.query)))); // eslint-disable-line global-require
router.get('/notices/unread', h(async (req, res) => res.json(await require('../services/notice.service').unreadCount(req.userId)))); // eslint-disable-line global-require
router.post('/notices/read', h(async (req, res) => res.json(await require('../services/notice.service').markAllRead(req.userId)))); // eslint-disable-line global-require
router.delete('/notices', h(async (req, res) => res.json(await require('../services/notice.service').clear(req.userId)))); // eslint-disable-line global-require
router.delete('/notices/:id', h(async (req, res) => res.json(await require('../services/notice.service').remove(req.userId, req.params.id)))); // eslint-disable-line global-require
router.get('/support/tickets', h(async (req, res) => res.json(await supportService.listMine(req.userId))));
router.post('/support/tickets', h(async (req, res) => res.json(await supportService.createTicket(req.userId, req.body))));
router.get('/support/tickets/:id', h(async (req, res) => res.json(await supportService.getMine(req.userId, req.params.id))));
router.post('/support/tickets/:id/messages', h(async (req, res) => res.json(await supportService.userReply(req.userId, req.params.id, req.body))));
router.post('/support/tickets/:id/rate', h(async (req, res) => res.json(await supportService.rateTicket(req.userId, req.params.id, req.body))));
router.post('/support/tickets/:id/close', h(async (req, res) => res.json(await supportService.userClose(req.userId, req.params.id))));
router.get('/announcements', h(async (req, res) => res.json(await announcementService.forUser(req.userId))));
router.post('/announcements/:id/dismiss', h(async (req, res) => res.json(await announcementService.dismiss(req.userId, req.params.id))));

// --- reports
router.post('/reports', h(async (req, res) => res.json(await reportService.createReport(req.userId, req.body))));

// --- media
const storage = multer.diskStorage({
  destination(req, file, cb) {
    const d = new Date();
    const dir = path.join(config.uploadDir, String(d.getUTCFullYear()), String(d.getUTCMonth() + 1).padStart(2, '0'));
    fs.mkdir(dir, { recursive: true }, (err) => cb(err, dir));
  },
  filename(req, file, cb) {
    const ext = path.extname(file.originalname || '').toLowerCase();
    cb(null, randomToken(16) + (/^\.[a-z0-9]{1,8}$/.test(ext) ? ext : ''));
  },
});

router.post('/media', h(async (req, res, next) => {
  const maxMb = (await paymentService.limitsFor(req.userId)).upload_mb;
  multer({ storage, limits: { fileSize: maxMb * 1024 * 1024, files: 1, fields: 10 } }).single('file')(req, res, (err) => {
    if (err) return next(err);
    return mediaService
      .registerUpload(req.userId, req.file, req.body || {})
      .then((m) => res.json(m))
      .catch(next);
  });
}));

router.get('/media/:id', h(async (req, res) => {
  sendMedia(res, await mediaService.getAccessible(req.userId, req.params.id), false);
}));

// ------------------------------------------------------------------ helpers
function parseIdParam(value) {
  const n = parseInt(value, 10);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(n)) throw badRequest('invalid_input', 'Invalid id');
  return n;
}

function sendMedia(res, m, isPublic) {
  const abs = mediaService.absolutePath(m);
  const inline = mediaService.isInlineSafe(m);
  const filename = encodeURIComponent(m.original_name || `file-${m.id}`);
  res.sendFile(
    abs,
    {
      dotfiles: 'deny',
      headers: {
        'Content-Type': inline ? m.mime : 'application/octet-stream',
        'Content-Disposition': `${inline ? 'inline' : 'attachment'}; filename*=UTF-8''${filename}`,
        'Cache-Control': isPublic ? 'public, max-age=86400' : 'private, max-age=86400',
        'X-Content-Type-Options': 'nosniff',
      },
    },
    (err) => {
      if (err && !res.headersSent) res.status(404).json({ error: { code: 'media_not_found', message: 'File not found' } });
    },
  );
}

module.exports = { router, sendMedia, storage };
