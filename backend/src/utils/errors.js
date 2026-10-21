'use strict';

class AppError extends Error {
  constructor(status, code, message, extra) {
    super(message || code);
    this.status = status;
    this.code = code;
    this.extra = extra || undefined;
  }
}

const badRequest = (code, message, extra) => new AppError(400, code, message, extra);
const unauthorized = (code = 'unauthorized', message = 'Authentication required') =>
  new AppError(401, code, message);
const forbidden = (code = 'forbidden', message = 'Not allowed', extra) => new AppError(403, code, message, extra);
const notFound = (code = 'not_found', message = 'Not found') => new AppError(404, code, message);
const conflict = (code, message) => new AppError(409, code, message);
const tooMany = (retryAfterSec, message = 'Too many requests, slow down') =>
  new AppError(429, 'rate_limited', message, { retry_after: retryAfterSec });

module.exports = { AppError, badRequest, unauthorized, forbidden, notFound, conflict, tooMany };
