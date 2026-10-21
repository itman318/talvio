'use strict';

/**
 * Tracks which users currently have at least one connected socket.
 * NOTE: per-process. For multiple instances use the Socket.IO Redis adapter
 * and move this map to Redis.
 */
const connections = new Map(); // userId -> number of sockets

function add(userId) {
  const n = (connections.get(userId) || 0) + 1;
  connections.set(userId, n);
  return n === 1; // became online
}

function remove(userId) {
  const n = (connections.get(userId) || 0) - 1;
  if (n <= 0) {
    connections.delete(userId);
    return true; // became offline
  }
  connections.set(userId, n);
  return false;
}

function isOnline(userId) {
  return connections.has(userId);
}

function onlineCount() {
  return connections.size;
}

module.exports = { add, remove, isOnline, onlineCount };
