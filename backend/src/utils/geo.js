'use strict';

/**
 * Where an IP address is (city, country, time zone) — looked up on the server itself from the free
 * GeoLite data in the geoip-lite package: no outside service, nothing about the person leaves the server.
 * Used to show "Lahore, Pakistan" in login codes and new-login alerts. Unknown → nulls.
 */
let geoip = null;
try {
  geoip = require('geoip-lite'); // eslint-disable-line global-require
} catch (_) {
  geoip = null;
}

const regionNames = (() => {
  try {
    return new Intl.DisplayNames(['en'], { type: 'region' });
  } catch (_) {
    return null;
  }
})();

function clean(ip) {
  return String(ip || '').replace(/^::ffff:/, '').trim();
}

/** { ip, city, country, countryCode, timezone, label: "Lahore, Pakistan" } */
function lookup(rawIp) {
  const ip = clean(rawIp);
  const out = { ip: ip || null, city: null, country: null, countryCode: null, timezone: null, label: null };
  if (!ip || !geoip) return out;
  try {
    const g = geoip.lookup(ip);
    if (!g) return out;
    out.city = g.city || null;
    out.countryCode = g.country || null;
    out.country = (g.country && regionNames && regionNames.of(g.country)) || g.country || null;
    out.timezone = g.timezone || null;
    out.label = [out.city, out.country].filter(Boolean).join(', ') || null;
  } catch (_) {
    /* unknown */
  }
  return out;
}

/** "6 Nov, 15:17" in that place's time (or UTC when unknown) + the zone name. */
function localTime(date, timezone) {
  const tz = timezone || 'UTC';
  try {
    const t = new Date(date).toLocaleString('en-GB', { timeZone: tz, day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
    return `${t} (${tz === 'UTC' ? 'UTC' : tz.split('/').pop().replace(/_/g, ' ')} time)`;
  } catch (_) {
    return new Date(date).toISOString().slice(0, 16).replace('T', ' ');
  }
}

/** "Infinix HOT 60 Pro · Android · Hushavia 1.0.0" from what the app sent. */
function deviceLabel(d) {
  if (!d || typeof d !== 'object') return null;
  const platform = { android: 'Android', ios: 'iPhone', web: 'Web', windows: 'Windows', macos: 'Mac', linux: 'Linux' }[d.platform] || null;
  const name = String(d.name || '').trim().slice(0, 60);
  const app = d.app_version || d.appVersion ? `Hushavia ${String(d.app_version || d.appVersion).slice(0, 20)}` : null;
  return [name || null, platform, app].filter(Boolean).join(' · ') || null;
}

module.exports = { lookup, localTime, deviceLabel };
