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

// What people SEE as "online": the app is on screen on at least one device (like Telegram).
// A phone app sent to the background keeps its socket for a while, but the person isn't looking — so it
// shows "last seen" a few seconds later, and pushes go out again ("isActive" false).
const background = new Set(); // socket ids that said they're in the background
const activeCount = new Map(); // userId -> sockets in the foreground
const HIDE_GRACE_MS = 3000; // quick app switches don't flicker the status
const pendingOff = new Map(); // userId -> timer that turns the status to "last seen"
let onChange = () => {}; // (userId, online) — set by the realtime layer

function setListener(fn) {
  onChange = fn;
}

function becameActive(userId) {
  const t = pendingOff.get(userId);
  if (t) {
    clearTimeout(t); // came back within the grace time: still shown online, nothing to tell anyone
    pendingOff.delete(userId);
    return;
  }
  onChange(userId, true);
}

function becameHidden(userId, { now = false } = {}) {
  if (pendingOff.has(userId)) return;
  if (now) {
    onChange(userId, false);
    return;
  }
  const t = setTimeout(() => {
    pendingOff.delete(userId);
    if (!activeCount.has(userId)) onChange(userId, false);
  }, HIDE_GRACE_MS);
  if (t.unref) t.unref();
  pendingOff.set(userId, t);
}

function inc(userId) {
  const n = (activeCount.get(userId) || 0) + 1;
  activeCount.set(userId, n);
  if (n === 1) becameActive(userId);
}

function dec(userId, opts) {
  const n = (activeCount.get(userId) || 0) - 1;
  if (n <= 0) {
    if (activeCount.delete(userId)) becameHidden(userId, opts);
  } else activeCount.set(userId, n);
}

function setForeground(socketId, userId, on) {
  const wasBg = background.has(socketId);
  if (on && wasBg) {
    background.delete(socketId);
    inc(userId);
  } else if (!on && !wasBg) {
    background.add(socketId);
    dec(userId);
  }
}

/** A socket connected. `foreground: false` = the app reconnected while hidden (stays "last seen"). */
function socketUp(socketId, userId, { foreground = true } = {}) {
  if (foreground) inc(userId);
  else background.add(socketId);
}

/** A socket went away (app closed, network lost). */
function socketDown(socketId, userId) {
  if (background.delete(socketId)) return;
  dec(userId);
}

/** Has the app open on screen somewhere (no need for a push notification). */
function isActive(userId) {
  return activeCount.has(userId);
}

/** Shown as "online" to others (on screen, or switched away less than a few seconds ago). */
function isShownOnline(userId) {
  return activeCount.has(userId) || pendingOff.has(userId);
}

function onlineCount() {
  return connections.size;
}

module.exports = { add, remove, isOnline, onlineCount, setForeground, socketUp, socketDown, isActive, isShownOnline, setListener, HIDE_GRACE_MS };
