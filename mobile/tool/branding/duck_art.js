// Talvio duckling stickers: drawn from scratch as layered SVG (head, eyes, beak, cap, wings, props move
// separately), with a white sticker border, rendered to looping animated WebP for the app's screens.
// Usage: node mobile/tool/branding/duck_art.js                       → mobile/assets/mascot/*.webp
//        PREVIEW=/tmp/x.png ONLY=hide,wave PICKS=0,.3,.6 node ...     → a contact sheet to look at
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const OUT = process.env.OUT || path.resolve(__dirname, '../../assets/mascot');
const FRAMES = 36; // 3 s at 12 fps
const SIZE = 340;
const TAU = Math.PI * 2;
const { sin, cos, abs, max, min } = Math;
const ease = (x) => 0.5 - 0.5 * cos(Math.PI * max(0, min(1, x)));
const pulse = (t, a, b) => (t > a && t < b ? sin(((t - a) / (b - a)) * Math.PI) : 0);
const blinkAt = (t, at = 0.8) => pulse(t, at, at + 0.06);
const hop = (t, n = 2) => abs(sin(t * Math.PI * n));

const O = '#1E2470'; // outline (deep blue)
const W = 8;

const defs = `<defs>
<radialGradient id="head" cx="38%" cy="30%" r="78%"><stop offset="0" stop-color="#FFF7A8"/><stop offset=".45" stop-color="#FFDD3C"/><stop offset=".85" stop-color="#FFB800"/><stop offset="1" stop-color="#F59A00"/></radialGradient>
<radialGradient id="wing" cx="35%" cy="25%" r="85%"><stop offset="0" stop-color="#FFF19A"/><stop offset=".55" stop-color="#FFCF2A"/><stop offset="1" stop-color="#F29C00"/></radialGradient>
<linearGradient id="beak" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB55A"/><stop offset="1" stop-color="#F2651D"/></linearGradient>
<linearGradient id="cap" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6A5BFF"/><stop offset=".55" stop-color="#3C2FD6"/><stop offset="1" stop-color="#22198C"/></linearGradient>
<linearGradient id="brim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4334E0"/><stop offset="1" stop-color="#1F1782"/></linearGradient>
<linearGradient id="hood" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#D9DDF7"/></linearGradient>
<linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="violet" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8A5CFF"/><stop offset="1" stop-color="#4A22C8"/></linearGradient>
<linearGradient id="blueBtn" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5AB8FF"/><stop offset="1" stop-color="#2F6BF0"/></linearGradient>
<linearGradient id="metal" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8A92B8"/><stop offset=".5" stop-color="#4D5683"/><stop offset="1" stop-color="#2C3360"/></linearGradient>
<linearGradient id="can" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#5A6496"/><stop offset=".5" stop-color="#37406E"/><stop offset="1" stop-color="#232A52"/></linearGradient>
<radialGradient id="lens" cx="35%" cy="30%" r="75%"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".4" stop-color="#C9EEFF"/><stop offset="1" stop-color="#5DB6F0"/></radialGradient>
<linearGradient id="shield" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6FD0FF"/><stop offset=".5" stop-color="#2F86F0"/><stop offset="1" stop-color="#5B3FE0"/></linearGradient>
<linearGradient id="blanket" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5DA8FF"/><stop offset="1" stop-color="#2B4FD0"/></linearGradient>
<linearGradient id="shades" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A3F5C"/><stop offset="1" stop-color="#05060E"/></linearGradient>
<filter id="sticker" x="-20%" y="-20%" width="140%" height="140%">
  <feMorphology in="SourceAlpha" operator="dilate" radius="11" result="d"/>
  <feGaussianBlur in="d" stdDeviation="7" result="db"/>
  <feOffset in="db" dy="6" result="ds"/>
  <feFlood flood-color="#1A1F5A" flood-opacity=".22"/><feComposite in2="ds" operator="in" result="shadow"/>
  <feFlood flood-color="#FFFFFF"/><feComposite in2="d" operator="in" result="white"/>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="white"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="8"/></filter>
<filter id="b3" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter>
</defs>`;

// ------------------------------------------------------------------ parts
const HEAD = { cx: 256, cy: 238 };

function eye(x, y, o = {}) {
  const { lid = 0, look = [0, 0], happy = false, closed = false, wink = false, big = 1 } = o;
  if (happy || wink) return `<path d="M${x - 17} ${y + 6} Q ${x} ${y - 16} ${x + 17} ${y + 6}" fill="none" stroke="${O}" stroke-width="8" stroke-linecap="round"/>`;
  if (closed || lid > 0.85) return `<path d="M${x - 17} ${y} Q ${x} ${y + 12} ${x + 17} ${y}" fill="none" stroke="${O}" stroke-width="8" stroke-linecap="round"/>`;
  const [lx, ly] = look;
  return `<g transform="translate(${x} ${y}) scale(1 ${1 - lid}) translate(${-x} ${-y})">
    <ellipse cx="${x + lx}" cy="${y + ly}" rx="${17 * big}" ry="${22 * big}" fill="#14123A"/>
    <ellipse cx="${x + lx - 5 * big}" cy="${y + ly - 8 * big}" rx="${7 * big}" ry="${8.5 * big}" fill="#fff"/>
    <circle cx="${x + lx + 6 * big}" cy="${y + ly + 9 * big}" r="${3.4 * big}" fill="#fff" opacity=".85"/></g>`;
}

function beak(kind = 'smile', t = 0) {
  const top = `<path d="M222 286 C 236 270 276 270 290 286 C 280 300 232 300 222 286 Z" fill="url(#beak)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <ellipse cx="246" cy="280" rx="10" ry="4" fill="#FFE0B0" opacity=".9"/>`;
  if (kind === 'open') {
    return `<path d="M228 292 C 240 326 272 326 284 292 Z" fill="#B8301E" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
      <ellipse cx="256" cy="312" rx="13" ry="7" fill="#FF7A8A"/>` + top;
  }
  if (kind === 'o') {
    const s = 1 + 0.12 * sin(t * TAU * 3);
    return `<ellipse cx="256" cy="304" rx="${11 * s}" ry="${14 * s}" fill="#B8301E" stroke="${O}" stroke-width="7"/>` + top;
  }
  if (kind === 'kiss') return top + `<path d="M246 300 Q 256 306 266 300" stroke="${O}" stroke-width="6" fill="none" stroke-linecap="round"/>`;
  return `<path d="M232 294 C 244 310 268 310 280 294" fill="#E8551F" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>` + top;
}

function cheeks(a = 0.7) {
  return `<ellipse cx="176" cy="292" rx="20" ry="11" fill="#FF6E8A" opacity="${a}" filter="url(#b3)"/>
    <ellipse cx="336" cy="292" rx="20" ry="11" fill="#FF6E8A" opacity="${a}" filter="url(#b3)"/>`;
}

function cap(t, wiggle = 0) {
  const tf = 4 * sin(t * TAU * 2 + 1) + wiggle;
  return `<g>
    <path d="M${246} 86 C ${226 + tf} 60 ${206 + tf} 66 ${210 + tf} 82 C ${216 + tf} 92 236 92 250 90 Z" fill="#FFC21A" stroke="${O}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M${262} 86 C ${282 + tf} 58 ${304 + tf} 64 ${300 + tf} 82 C ${294 + tf} 92 274 92 262 90 Z" fill="#FFC21A" stroke="${O}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M142 214 C 136 128 190 84 258 84 C 330 84 378 128 372 212 C 300 196 214 196 142 214 Z" fill="url(#cap)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <path d="M186 112 C 210 96 236 92 258 92" stroke="#9C92FF" stroke-width="8" stroke-linecap="round" fill="none" opacity=".75"/>
    <path d="M256 88 L 256 200" stroke="#2A20A8" stroke-width="3" opacity=".5"/>
    <path id="capText" d="M178 176 Q 258 140 340 172" fill="none"/>
    <text font-family="Jakarta" font-weight="800" font-size="46" fill="#fff" stroke="${O}" stroke-width="2.5" paint-order="stroke"><textPath href="#capText" startOffset="50%" text-anchor="middle">Talvio</textPath></text>
    <path d="M128 214 C 200 186 316 186 388 212 C 400 222 396 236 382 236 C 320 214 196 214 134 238 C 118 238 116 222 128 214 Z" fill="url(#brim)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
  </g>`;
}

function head(o, t) {
  const { rot = 0, dy = 0, dx = 0, face = '', capWiggle = 0 } = o;
  return `<g transform="translate(${dx} ${dy}) rotate(${rot} 256 340)">
    <ellipse cx="${HEAD.cx}" cy="${HEAD.cy}" rx="122" ry="112" fill="url(#head)" stroke="${O}" stroke-width="${W}"/>
    <ellipse cx="190" cy="226" rx="26" ry="14" fill="#fff" opacity=".55" transform="rotate(-30 190 226)"/>
    ${face}
    ${cap(t, capWiggle)}
  </g>`;
}

function body(t, breathe = 0) {
  const b = breathe;
  return `<path d="M170 330 C 140 360 138 432 150 452 L 362 452 C 374 432 372 360 342 330 Z" fill="url(#hood)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round" transform="translate(256 452) scale(${1 + b} ${1 - b}) translate(-256 -452)"/>
    <path d="M196 350 C 220 364 292 364 316 350" stroke="#B9BEE8" stroke-width="7" fill="none" stroke-linecap="round"/>
    <path d="M236 352 l -4 30 M276 352 l 4 30" stroke="#9EA4DA" stroke-width="5" stroke-linecap="round"/>
    <g transform="translate(256 410)"><rect x="-26" y="-20" width="52" height="12" rx="6" fill="url(#violet)"/><rect x="-6" y="-20" width="12" height="38" rx="6" fill="url(#violet)"/></g>`;
}

// wing: a plump feathered oval from shoulder s reaching to tip p (tip end is rounder, with feather lines)
function wing(sx, sy, px, py, w = 52, o = {}) {
  const dx = px - sx, dy = py - sy, L = Math.hypot(dx, dy) || 1;
  const ang = (Math.atan2(dy, dx) * 180) / Math.PI;
  const cx = sx + dx * 0.55, cy = sy + dy * 0.55;
  const rx = L * 0.5 + w * 0.22, ry = w * 0.72;
  const tipX = rx - 4;
  const feathers = o.feathers === false ? '' : `<path d="M${tipX - 26} ${-ry * 0.42} q 16 4 22 14 M${tipX - 30} ${0} q 18 0 26 6 M${tipX - 26} ${ry * 0.42} q 16 -4 22 -14" stroke="#D98200" stroke-width="4.5" fill="none" stroke-linecap="round"/>`;
  return `<g transform="translate(${cx} ${cy}) rotate(${ang})">
    <path d="M${-rx} 0 C ${-rx} ${-ry * 0.8} ${rx * 0.2} ${-ry * 1.15} ${rx} ${-ry * 0.25} C ${rx + ry * 0.35} 0 ${rx + ry * 0.35} 0 ${rx} ${ry * 0.25} C ${rx * 0.2} ${ry * 1.15} ${-rx} ${ry * 0.8} ${-rx} 0 Z"
      fill="url(#wing)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <path d="M${-rx * 0.4} ${-ry * 0.55} Q ${rx * 0.2} ${-ry * 0.85} ${rx * 0.6} ${-ry * 0.45}" stroke="#FFF6C0" stroke-width="6" fill="none" stroke-linecap="round" opacity=".8"/>
    ${feathers}</g>`;
}
const LS = [178, 372], RS = [334, 372];

function pill(inner, o = {}) {
  const { x = 96, y = 438, w = 320, h = 64, fill = '#fff', stroke = '#3B5BF5' } = o;
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${h / 2}" fill="${fill}" stroke="${O}" stroke-width="${W}"/>
    <rect x="${x + 7}" y="${y + 7}" width="${w - 14}" height="${h - 14}" rx="${(h - 14) / 2}" fill="none" stroke="${stroke}" stroke-width="4" opacity=".8"/>${inner}`;
}

function sparkle(x, y, r, color = '#FFC21A') {
  if (r < 1.5) return '';
  return `<path d="M${x} ${y - r} Q ${x} ${y} ${x + r} ${y} Q ${x} ${y} ${x} ${y + r} Q ${x} ${y} ${x - r} ${y} Q ${x} ${y} ${x} ${y - r} Z" fill="${color}" stroke="${O}" stroke-width="3.5"/>`;
}
const dash = (x1, y1, x2, y2, c = '#7B4BE0', a = 1) => `<path d="M${x1} ${y1} L ${x2} ${y2}" stroke="${c}" stroke-width="9" stroke-linecap="round" opacity="${a}"/>`;

// the Talvio speech-bubble mark (our own logo — never anyone else's)
const talvioMark = (x, y, s = 1) => `<g transform="translate(${x} ${y}) scale(${s})">
  <path d="M0 -20 c -14 0 -24 9 -24 21 c 0 6 3 11 7 15 l -3 10 c 0 1.4 1 2.2 2 1.5 l 11 -6 c 2 .6 4.4 1 7 1 c 14 0 24 -9 24 -22 s -10 -20.5 -24 -20.5 z" fill="#fff"/>
  <rect x="-11" y="-11" width="22" height="6" rx="3" fill="url(#violet)"/><rect x="-3" y="-11" width="6" height="21" rx="3" fill="url(#violet)"/></g>`;

const face = (o = {}) => cheeks(o.cheeks ?? 0.7) + eye(212, 256, { ...o, ...(o.l || {}) }) + eye(300, 256, { ...o, ...(o.r || {}) }) + beak(o.beak || 'smile', o.t || 0);

// ------------------------------------------------------------------ scenes
const SCENES = {
  // password: wings over the eyes, dots typing into the field, lock wiggles; peeks once
  hide(t) {
    const w = 3 * sin(t * TAU * 2);
    const peek = pulse(t, 0.55, 0.85);
    const dots = Math.min(6, Math.floor(((t * 1.4) % 1) * 8));
    const lock = 6 * sin(t * TAU * 4) * (dots >= 6 ? 1 : 0);
    let d = '';
    for (let i = 0; i < 6; i++) d += `<text x="${140 + i * 30}" y="${488}" font-family="Jakarta" font-weight="800" font-size="40" fill="#3047D8" opacity="${i < dots ? 1 : 0.15}">*</text>`;
    return {
      head: { rot: w * 0.6, face: face({ t, beak: 'open', cheeks: 0.95 }) },
      front: wing(...LS, 214, 252 + w, 64) + wing(...RS, 300 + 26 * peek, 252 - w + 46 * peek, 64),
      pill: pill(d + `<g transform="translate(372 470) rotate(${lock})"><path d="M-12 -8 v -8 a 12 12 0 0 1 24 0 v 8" stroke="#3047D8" stroke-width="6" fill="none"/><rect x="-17" y="-8" width="34" height="27" rx="7" fill="#3047D8"/><circle cx="0" cy="4" r="4" fill="#fff"/></g>`),
      fx: dash(100, 140, 82, 120, '#7B4BE0', 0.6 + 0.4 * sin(t * TAU * 2)) + dash(118, 116, 108, 92, '#7B4BE0', 0.6 + 0.4 * sin(t * TAU * 2)),
    };
  },
  // hello: big wave with a wink; "Message" pill with the Talvio send button pulsing
  wave(t) {
    const w = sin(t * TAU * 3);
    const press = pulse(t, 0.7, 0.85);
    return {
      head: { rot: 4 * sin(t * TAU), face: face({ t, r: { wink: true }, l: { lid: 0 }, beak: 'open' }) },
      front: wing(...LS, 160, 432, 54) + wing(...RS, 392 + 18 * w, 252 - 8 * abs(w), 64),
      pill: pill(`<text x="150" y="483" font-family="Jakarta" font-weight="800" font-size="36" fill="#fff">Message</text>`, { x: 96, w: 270, fill: 'url(#violet)', stroke: '#B79BFF' })
        + `<g transform="translate(372 470) scale(${1 - 0.1 * press})"><circle r="42" fill="url(#blueBtn)" stroke="${O}" stroke-width="${W}"/>${talvioMark(0, 0, 1.25)}</g>`,
      fx: `<path d="M440 160 q 14 14 8 32 M458 142 q 24 22 16 52" stroke="${O}" stroke-width="7" fill="none" stroke-linecap="round" opacity="${0.3 + 0.6 * abs(w)}"/>`,
    };
  },
  // no contacts: magnifier over one eye (it looks huge), "no contacts" badge shakes
  nocontacts(t) {
    const a = sin(t * TAU);
    const shake = 8 * sin(t * TAU * 6) * pulse(t, 0.3, 0.55);
    const mx = 312 + 8 * a, my = 252 + 4 * a;
    return {
      head: { rot: 3 * a, face: face({ t, l: { wink: true }, r: { big: 1.35, look: [2 * a, 0] }, beak: 'smile' }) },
      front: `<g transform="translate(${mx} ${my}) rotate(${-30 + 6 * a})"><rect x="-10" y="44" width="20" height="78" rx="10" fill="#2A2F5C" stroke="${O}" stroke-width="6"/>
          <circle r="50" fill="url(#lens)" opacity=".55"/><circle r="50" fill="none" stroke="#2A2F5C" stroke-width="14"/><circle r="50" fill="none" stroke="${O}" stroke-width="4"/>
          <path d="M-28 -16 a 30 30 0 0 1 16 -20" stroke="#fff" stroke-width="7" stroke-linecap="round" fill="none"/></g>`
        + wing(...RS, mx - 6, my + 104, 54) + wing(...LS, 162, 430, 54)
        + `<g transform="translate(${372 + shake} 362)"><circle r="46" fill="#fff" stroke="${O}" stroke-width="${W}"/>
          <circle cx="-12" cy="-10" r="11" fill="#6C4BE0"/><path d="M-30 18 c 2 -18 34 -18 36 0 z" fill="#6C4BE0"/><circle cx="12" cy="-6" r="9" fill="#9B7BFF"/><path d="M0 20 c 2 -14 26 -14 28 0 z" fill="#9B7BFF"/>
          <circle r="38" fill="none" stroke="#F0334F" stroke-width="9"/><path d="M-27 -27 L 27 27" stroke="#F0334F" stroke-width="9" stroke-linecap="round"/></g>`,
      pill: pill(`<text x="256" y="483" text-anchor="middle" font-family="Jakarta" font-weight="800" font-size="34" fill="${O}">No contacts</text>`, { x: 126, w: 260 }),
      fx: dash(430, 300, 452, 286, '#7B4BE0', 0.4 + 0.6 * pulse(t, 0.3, 0.6)) + dash(434, 330, 460, 330, '#7B4BE0', 0.4 + 0.6 * pulse(t, 0.3, 0.6)),
    };
  },
  // search: magnifier sweeps, the field types "Search…" with a blinking cursor
  search(t) {
    const a = sin(t * TAU);
    const mx = 300 + 22 * a, my = 256 - 4 * abs(a);
    const word = 'Search…';
    const n = Math.min(word.length, Math.floor(((t * 1.2) % 1) * (word.length + 4)));
    const cursor = (Math.floor(t * 12) % 2 === 0) ? 1 : 0;
    return {
      head: { rot: 4 * a, face: face({ t, look: [6 * a, 0], lid: blinkAt(t, 0.2), r: { big: 1.3, look: [4 * a, 0] }, beak: 'o' }) },
      front: `<g transform="translate(${mx} ${my}) rotate(${-28 + 8 * a})"><rect x="-10" y="44" width="20" height="80" rx="10" fill="#2A2F5C" stroke="${O}" stroke-width="6"/>
          <circle r="50" fill="url(#lens)" opacity=".5"/><circle r="50" fill="none" stroke="#2A2F5C" stroke-width="14"/><circle r="50" fill="none" stroke="${O}" stroke-width="4"/>
          <path d="M-28 -16 a 30 30 0 0 1 16 -20" stroke="#fff" stroke-width="7" stroke-linecap="round" fill="none"/></g>`
        + wing(...RS, mx - 4, my + 106, 54) + wing(...LS, 162, 430, 54),
      pill: pill(`<circle cx="146" cy="466" r="15" fill="none" stroke="#3047D8" stroke-width="7"/><path d="M157 477 l 12 12" stroke="#3047D8" stroke-width="8" stroke-linecap="round"/>
          <text x="184" y="482" font-family="Jakarta" font-weight="800" font-size="32" fill="#5A66A8">${word.slice(0, n)}</text>
          <rect x="${186 + n * 17}" y="452" width="4" height="34" rx="2" fill="#3047D8" opacity="${cursor}"/>`),
      fx: `<path d="M400 112 l 14 -26 M428 126 l 26 -12 M386 96 l 0 -28" stroke="#FFC21A" stroke-width="8" stroke-linecap="round" opacity="${0.4 + 0.6 * abs(a)}"/>`,
    };
  },
  // success: shades, double thumbs-up nodding to a beat, "Talvio" pill shines
  cool(t) {
    const nod = abs(sin(t * TAU * 2));
    const g = (t * 1.1) % 1;
    const shadesFace = cheeks(0.6) + beak('open', t) + `
      <path d="M156 236 C 156 222 252 222 252 236 C 252 268 226 280 202 280 C 174 280 156 262 156 236 Z" fill="url(#shades)" stroke="${O}" stroke-width="6"/>
      <path d="M260 236 C 260 222 356 222 356 236 C 356 262 338 280 310 280 C 286 280 260 268 260 236 Z" fill="url(#shades)" stroke="${O}" stroke-width="6"/>
      <path d="M250 238 Q 256 232 262 238" stroke="${O}" stroke-width="8" fill="none"/>
      <path d="M178 240 l 22 -10 M282 240 l 22 -10" stroke="#fff" stroke-width="6" stroke-linecap="round" opacity="${0.5 + 0.5 * pulse(t, 0.2, 0.5)}"/>`;
    const thumb = (x, y, s) => `<g transform="translate(${x} ${y}) scale(${s} 1)"><rect x="-4" y="-66" width="26" height="48" rx="13" fill="url(#wing)" stroke="${O}" stroke-width="7"/><ellipse cx="0" cy="0" rx="40" ry="34" fill="url(#wing)" stroke="${O}" stroke-width="${W}"/><path d="M-20 -8 h 30 M-20 8 h 30" stroke="#D98200" stroke-width="4" stroke-linecap="round"/></g>`;
    return {
      head: { dy: 6 * nod, rot: 2 * sin(t * TAU), face: shadesFace },
      front: thumb(176, 396 - 6 * nod, -1) + thumb(336, 396 - 6 * nod, 1),
      pill: `<g transform="translate(0 ${-4 * nod})">${pill(`<text x="256" y="484" text-anchor="middle" font-family="Jakarta" font-weight="800" font-size="40" fill="#fff">Talvio</text>
          <path d="M196 494 Q 256 504 320 490" stroke="#FFC21A" stroke-width="5" fill="none" stroke-linecap="round"/>`, { x: 136, w: 240, fill: 'url(#violet)', stroke: '#B79BFF' })}
          <clipPath id="pc"><rect x="136" y="438" width="240" height="64" rx="32"/></clipPath><g clip-path="url(#pc)"><path d="M${100 + 340 * g} 510 L ${130 + 340 * g} 430" stroke="#fff" stroke-width="22" opacity=".35"/></g></g>`,
      fx: sparkle(110, 200, 16 * pulse(t, 0, 0.5)) + sparkle(412, 160, 18 * pulse(t, 0.3, 0.8)) + sparkle(430, 300, 12 * pulse(t, 0.55, 1)),
    };
  },
  // all quiet: tucked in a blanket hugging a Talvio pillow, breathing, z's float
  sleep(t) {
    const br = sin(t * TAU);
    const zs = [0, 1, 2].map((i) => { const p = (t + i / 3) % 1; return `<text x="${352 + 60 * p}" y="${150 - 90 * p}" font-family="Jakarta" font-weight="800" font-size="${30 + 30 * p}" fill="#3B5BF5" stroke="${O}" stroke-width="2.5" opacity="${(1 - p)}">z</text>`; }).join('');
    return {
      noBody: true,
      head: { rot: -10 + 2 * br, dy: 12 + 3 * br, face: face({ t, closed: true, beak: 'smile', cheeks: 0.85 }) },
      front: `<path d="M96 380 C 120 330 400 330 430 380 C 452 420 440 470 400 476 L 120 476 C 80 470 76 420 96 380 Z" fill="url(#blanket)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round" transform="translate(256 476) scale(${1 + 0.015 * br} ${1 - 0.02 * br}) translate(-256 -476)"/>
        <path d="M130 400 C 200 380 320 380 400 404" stroke="#9CCBFF" stroke-width="8" fill="none" stroke-linecap="round" opacity=".7"/>
        <g transform="translate(244 ${418 + 3 * br}) rotate(-10)"><ellipse rx="120" ry="52" fill="url(#violet)" stroke="${O}" stroke-width="${W}"/>
          <ellipse cx="-50" cy="-20" rx="40" ry="12" fill="#B79BFF" opacity=".6"/>
          <rect x="-28" y="-22" width="56" height="14" rx="7" fill="#fff"/><rect x="-7" y="-22" width="14" height="44" rx="7" fill="#fff"/></g>`,
      fx: zs,
    };
  },
  // clear history: shows a trash can, lid pops, a paper ball flies in
  delete(t) {
    const lid = pulse(t, 0.35, 0.75);
    const p = (t - 0.2) / 0.3;
    const ball = p > 0 && p < 1 ? `<g transform="translate(${140 + 200 * p} ${230 - 140 * sin(p * Math.PI) + 120 * p})"><circle r="16" fill="#fff" stroke="${O}" stroke-width="5"/><path d="M-8 -4 l 10 6 M-2 -10 l 4 14 M6 -6 l -10 10" stroke="#B9BEE8" stroke-width="3"/></g>` : '';
    return {
      head: { rot: -4 + 4 * lid, face: face({ t, r: { wink: lid > 0.4 }, look: [6, 2], beak: lid > 0.4 ? 'open' : 'smile' }) },
      front: ball + `<g transform="translate(330 380)">
          <path d="M-62 -40 L 62 -40 L 50 90 Q 48 102 36 102 L -36 102 Q -48 102 -50 90 Z" fill="url(#can)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M-26 -10 L -22 76 M0 -10 L 0 76 M26 -10 L 22 76" stroke="#8C95C8" stroke-width="9" stroke-linecap="round"/>
          <g transform="translate(-70 -40) rotate(${-40 * lid}) translate(70 40)"><rect x="-72" y="-58" width="144" height="22" rx="10" fill="url(#metal)" stroke="${O}" stroke-width="${W}"/>
          <rect x="-20" y="-72" width="40" height="18" rx="8" fill="url(#metal)" stroke="${O}" stroke-width="6"/></g></g>`
        + wing(...LS, 250, 418, 56) + wing(...RS, 300, 430, 56),
      fx: dash(430, 280, 452, 262, '#7B4BE0', lid) + dash(440, 310, 466, 304, '#7B4BE0', lid),
    };
  },
  // add contacts: hugs a big contacts badge; the + pops, hearts float up
  contacts(t) {
    const b = hop(t, 2);
    const plus = 1 + 0.2 * pulse((t * 2) % 1, 0, 0.3);
    const hearts = [0, 1].map((i) => { const p = (t * 1.2 + i / 2) % 1; return `<path transform="translate(${400 + 18 * i + 10 * sin(p * 6)} ${200 - 110 * p}) scale(${0.9 + 0.4 * p})" d="M0 10 c -16 -10 -18 -22 -9 -26 c 4 -2 7 0 9 3 c 2 -3 5 -5 9 -3 c 9 4 7 16 -9 26 z" fill="#FF4F7B" stroke="${O}" stroke-width="3" opacity="${1 - p}"/>`; }).join('');
    return {
      head: { dy: -6 * b, rot: 3 * sin(t * TAU), face: face({ t, happy: true, beak: 'open', cheeks: 0.95 }) },
      front: `<g transform="translate(256 ${396 - 6 * b})"><circle r="84" fill="url(#blueBtn)" stroke="${O}" stroke-width="${W}"/>
          <circle cx="-22" cy="-20" r="20" fill="#fff"/><path d="M-56 34 c 4 -34 64 -34 68 0 z" fill="#fff"/><circle cx="24" cy="-12" r="16" fill="#E2ECFF"/><path d="M4 36 c 3 -26 50 -26 52 0 z" fill="#E2ECFF"/>
          <path d="M-50 -50 a 70 70 0 0 1 40 -22" stroke="#fff" stroke-width="8" stroke-linecap="round" fill="none" opacity=".6"/>
          <g transform="translate(70 -54) scale(${plus})"><circle r="34" fill="#22C55E" stroke="${O}" stroke-width="${W}"/><path d="M-15 0 h 30 M0 -15 v 30" stroke="#fff" stroke-width="10" stroke-linecap="round"/></g></g>`
        + wing(...LS, 190, 448 - 6 * b, 56) + wing(...RS, 322, 454 - 6 * b, 56),
      fx: hearts,
    };
  },
  // settings / bots: turning a big gear, eyes follow it
  settings(t) {
    const r = t * 120;
    const a = sin(t * TAU);
    return {
      head: { rot: 4 + 2 * a, face: face({ t, look: [8, 4], lid: blinkAt(t, 0.5), beak: 'smile' }) },
      front: `<g transform="translate(334 404) rotate(${r})">${gear(76)}</g>` + wing(...LS, 200, 430, 56) + wing(...RS, 300 + 6 * a, 382 + 6 * a, 58),
      fx: dash(430, 300, 452, 286, '#3B5BF5', 0.5 + 0.5 * a) + dash(438, 330, 462, 330, '#3B5BF5', 0.5 - 0.5 * a),
    };
  },
  // secure: shades on, holds a shield; a glowing ring orbits, lock clicks
  secure(t) {
    const g = sin(t * TAU);
    const click = pulse(t, 0.6, 0.72);
    const shadesFace = cheeks(0.6) + beak('smile') + `
      <path d="M156 236 C 156 222 252 222 252 236 C 252 268 226 280 202 280 C 174 280 156 262 156 236 Z" fill="url(#shades)" stroke="${O}" stroke-width="6"/>
      <path d="M260 236 C 260 222 356 222 356 236 C 356 262 338 280 310 280 C 286 280 260 268 260 236 Z" fill="url(#shades)" stroke="${O}" stroke-width="6"/>
      <path d="M250 238 Q 256 232 262 238" stroke="${O}" stroke-width="8" fill="none"/>`;
    const ring = (k) => `<ellipse cx="256" cy="400" rx="${172}" ry="${42}" fill="none" stroke="#5CD0FF" stroke-width="${6 - k * 2}" opacity="${0.55 - k * 0.2}" transform="rotate(${-8 + 6 * g} 256 400)" stroke-dasharray="${180} ${90}" stroke-dashoffset="${-t * 1080 + k * 60}"/>`;
    return {
      behind: `<ellipse cx="320" cy="390" rx="110" ry="120" fill="#5CD0FF" opacity="${0.25 + 0.15 * g}" filter="url(#glow)"/>`,
      head: { rot: 2 * g, face: shadesFace },
      front: ring(1) + `<g transform="translate(330 400) scale(${1 + 0.03 * g})">
          <path d="M0 -92 C 34 -76 62 -72 82 -72 C 84 10 60 70 0 98 C -60 70 -84 10 -82 -72 C -62 -72 -34 -76 0 -92 Z" fill="url(#shield)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M-56 -56 C -36 -58 -18 -64 0 -74" stroke="#fff" stroke-width="8" stroke-linecap="round" fill="none" opacity=".6"/>
          <g transform="translate(0 ${6 - 4 * click})"><path d="M-17 -8 v -12 a 17 17 0 0 1 34 0 v ${12 - 8 * click}" stroke="#fff" stroke-width="9" fill="none"/></g>
          <rect x="-26" y="-6" width="52" height="42" rx="10" fill="#fff"/><circle cx="0" cy="12" r="6" fill="#3B5BF5"/><rect x="-3" y="12" width="6" height="12" rx="3" fill="#3B5BF5"/></g>`
        + wing(...LS, 250, 420, 56) + ring(0),
      fx: sparkle(408, 250, 14 * pulse(t, 0.6, 0.9), '#5CD0FF') + sparkle(120, 230, 12 * pulse(t, 0.1, 0.4), '#5CD0FF'),
    };
  },
};

function gear(R) {
  let d = '';
  const teeth = 9;
  for (let i = 0; i < teeth * 2; i++) {
    const a0 = (i / (teeth * 2)) * TAU, a1 = ((i + 1) / (teeth * 2)) * TAU;
    const r = i % 2 === 0 ? R : R * 0.8;
    d += `${i === 0 ? 'M' : 'L'} ${r * cos(a0)} ${r * sin(a0)} L ${r * cos(a1)} ${r * sin(a1)} `;
  }
  return `<path d="${d} Z" fill="url(#metal)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <circle r="${R * 0.36}" fill="#1E2470" stroke="${O}" stroke-width="6"/><circle r="${R * 0.2}" fill="#8A92B8"/>
    <path d="M${-R * 0.55} ${-R * 0.3} a ${R * 0.6} ${R * 0.6} 0 0 1 ${R * 0.3} ${-R * 0.3}" stroke="#C5CBEA" stroke-width="7" stroke-linecap="round" fill="none"/>`;
}

function frame(name, t) {
  const s = SCENES[name](t);
  const h = s.head || {};
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 520" width="${SIZE}" height="${Math.round(SIZE * 520 / 512)}">${defs}
  <g transform="translate(256 260) scale(.9) translate(-256 -260)">
  ${s.behind || ''}
  <g filter="url(#sticker)">
    ${s.noBody ? '' : body(t)}
    ${head(h, t)}
    ${s.front || ''}
    ${s.pill || ''}
  </g>
  ${s.fx || ''}
  </g>
</svg>`;
}

(async () => {
  const only = process.env.ONLY ? process.env.ONLY.split(',') : Object.keys(SCENES);
  const fontDir = path.resolve(__dirname, '../../../backend/web-client/fonts');
  const b64 = fs.readFileSync(path.join(fontDir, 'PlusJakartaSans-ExtraBold.woff2')).toString('base64');
  const font = `@font-face{font-family:Jakarta;src:url(data:font/woff2;base64,${b64}) format('woff2');font-weight:800}`;
  const H = Math.round(SIZE * 520 / 512);
  const b = await chromium.launch();
  const COLS = 6;
  if (process.env.PREVIEW) {
    const picks = (process.env.PICKS || '0,0.25,0.5,0.75').split(',').map(Number);
    const html = `<html><head><style>${font}body{margin:0;background:#F3F4F9;width:${picks.length * SIZE}px}svg{float:left}</style></head><body>${only.map((n) => picks.map((t) => frame(n, t)).join('')).join('')}</body></html>`;
    const p = await b.newPage({ viewport: { width: picks.length * SIZE, height: only.length * H } });
    await p.setContent(html);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: process.env.PREVIEW });
    await b.close();
    return;
  }
  fs.mkdirSync(OUT, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'duck-'));
  const rows = Math.ceil(FRAMES / COLS);
  const p = await b.newPage({ viewport: { width: COLS * SIZE, height: rows * H } });
  for (const name of only) {
    const html = `<html><head><style>${font}html,body{margin:0;background:transparent;width:${COLS * SIZE}px}svg{display:block;float:left}</style></head><body>${
      Array.from({ length: FRAMES }, (_, i) => frame(name, i / FRAMES)).join('')}</body></html>`;
    await p.setContent(html);
    await p.evaluate(() => document.fonts.ready);
    const sheet = path.join(tmp, `${name}.png`);
    await p.screenshot({ path: sheet, omitBackground: true });
    execFileSync('python3', ['-c', `
import sys
from PIL import Image
sheet = Image.open(sys.argv[1]).convert('RGBA')
n, w, h, cols = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
frames = [sheet.crop(((i % cols) * w, (i // cols) * h, (i % cols + 1) * w, (i // cols + 1) * h)) for i in range(n)]
frames[0].save(sys.argv[2], save_all=True, append_images=frames[1:], duration=83, loop=0, quality=76, method=6, alpha_quality=85)
`, sheet, path.join(OUT, `${name}.webp`), String(FRAMES), String(SIZE), String(H), String(COLS)]);
    console.log('✓', name, (fs.statSync(path.join(OUT, `${name}.webp`)).size / 1024).toFixed(0) + ' KB');
  }
  await b.close();
})();
