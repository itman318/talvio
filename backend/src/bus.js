'use strict';

/**
 * Internal event bus. Services emit domain events; the realtime layer
 * (Socket.IO + push notifications) listens and fans them out to clients.
 *
 * Events:
 *  message:new       { chatId, message, memberIds, senderId }
 *  message:edited    { chatId, message, memberIds }
 *  message:deleted   { chatId, messageIds, userIds }        (userIds = who should drop them)
 *  chat:updated      { chatId, memberIds }                  (clients refetch the chat)
 *  chat:removed      { chatId, userIds }                    (user no longer a member)
 *  receipt:read      { chatId, userId, messageId, memberIds }
 *  receipt:delivered { chatId, userId, messageId, memberIds }
 *  user:updated      { userId }                             (profile changed)
 *  sessions:revoked  { userId, sessionIds|null, reason }    (null = all sessions)
 */
const { EventEmitter } = require('events');

const bus = new EventEmitter();
bus.setMaxListeners(50);

module.exports = bus;
