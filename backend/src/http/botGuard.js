'use strict';

/**
 * Shared by the three Bot API doors (v1, v2, classic):
 *  • an address that keeps sending wrong tokens is slowed down (30 wrong tries a minute), before any database work;
 *  • when the token comes in the header or the address, it is checked BEFORE a file upload is read, so nobody
 *    without a valid token can make the server store files;
 *  • a file uploaded with a request that failed is deleted at once.
 */
const fs = require('fs');
const rateLimit = require('../utils/rateLimit');
const { tooMany } = require('../utils/errors');

const LIMIT = 30;
const key = (req) => `botauth:${req.ip}`;

function checkIp(req) {
  if (rateLimit.blocked(key(req), LIMIT)) throw tooMany(60, 'Too many wrong bot tokens from this address — wait a minute');
}

function noteFailure(req, err) {
  if (err && (err.code === 'invalid_token' || err.status === 401)) rateLimit.hit(key(req), LIMIT, 60 * 1000);
}

function dropFiles(files) {
  for (const f of [].concat(files || [])) if (f && f.path) fs.promises.unlink(f.path).catch(() => {});
}

module.exports = { checkIp, noteFailure, dropFiles };
