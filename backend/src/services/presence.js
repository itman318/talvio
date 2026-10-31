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

// Sockets whose app is on screen. A phone app sent to the background keeps its socket for a while,
// but the person isn't looking — so pushes should still go out ("isActive" false).
const background = new Set(); // socket ids that said they're in the background
const activeCount = new Map(); // userId -> sockets in the foreground

function setForeground(socketId, userId, on) {
  const wasBg = background.has(socketId);
  if (on && wasBg) {
    background.delete(socketId);
    activeCount.set(userId, (activeCount.get(userId) || 0) + 1);
  } else if (!on && !wasBg) {
    background.add(socketId);
    const n = (activeCount.get(userId) || 0) - 1;
    if (n <= 0) activeCount.delete(userId);
    else activeCount.set(userId, n);
  }
}

/** A socket connected (it starts in the foreground). */
function socketUp(userId) {
  activeCount.set(userId, (activeCount.get(userId) || 0) + 1);
}

/** A socket went away. */
function socketDown(socketId, userId) {
  if (background.delete(socketId)) return;
  const n = (activeCount.get(userId) || 0) - 1;
  if (n <= 0) activeCount.delete(userId);
  else activeCount.set(userId, n);
}

/** Has the app open on screen somewhere (no need for a push notification). */
function isActive(userId) {
  return activeCount.has(userId);
}

function onlineCount() {
  return connections.size;
}

module.exports = { add, remove, isOnline, onlineCount, setForeground, socketUp, socketDown, isActive };
