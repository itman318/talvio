'use strict';

const config = require('../config');

/**
 * Sends an SMS through the configured provider.
 *  - console: prints to the server log (development)
 *  - http:    generic gateway — POST JSON {to, message} with "Authorization: Bearer <token>"
 *             (wrap your local Pakistani SMS gateway behind this, or edit sendHttp below)
 *  - twilio:  Twilio Messages API
 */
async function send(to, message) {
  const provider = config.sms.provider;
  if (provider === 'console') {
    // eslint-disable-next-line no-console
    console.log(`[SMS → ${to}] ${message}`);
    return;
  }
  if (provider === 'http') return sendHttp(to, message);
  if (provider === 'twilio') return sendTwilio(to, message);
  throw new Error(`Unknown SMS_PROVIDER: ${provider}`);
}

async function sendHttp(to, message) {
  if (!config.sms.httpUrl) throw new Error('SMS_HTTP_URL is not set');
  const res = await fetch(config.sms.httpUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(config.sms.httpToken ? { Authorization: `Bearer ${config.sms.httpToken}` } : {}),
    },
    body: JSON.stringify({ to, message }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`SMS gateway responded ${res.status}`);
}

async function sendTwilio(to, message) {
  const { twilioSid, twilioToken, twilioFrom } = config.sms;
  if (!twilioSid || !twilioToken || !twilioFrom) throw new Error('Twilio credentials are not set');
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${twilioSid}/Messages.json`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${Buffer.from(`${twilioSid}:${twilioToken}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ To: to, From: twilioFrom, Body: message }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`Twilio responded ${res.status}`);
}

module.exports = { send };
