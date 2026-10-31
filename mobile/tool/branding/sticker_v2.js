// Talvio duckling — premium sticker v2 (one scene at a time). Volumetric shading, layered parts and
// keyframed animation (anticipation, overshoot, follow-through), rendered at 24 fps to animated WebP.
// Usage: SCENE=hide PREVIEW=/tmp/p.png node sticker_v2.js     → key frames side by side
//        SCENE=hide OUT=/tmp/hide.webp node sticker_v2.js     → the animated sticker
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const FPS = 24;
const DUR = 3.0; // seconds per loop
const FRAMES = Math.round(FPS * DUR);
const SIZE = Number(process.env.SIZE || 512);
const TAU = Math.PI * 2;
const { sin, cos, max, min, abs } = Math;
const clamp = (x, a = 0, b = 1) => max(a, min(b, x));
const lerp = (a, b, t) => a + (b - a) * t;
const seg = (t, a, b) => clamp((t - a) / (b - a)); // 0..1 progress inside [a, b]
const easeInOut = (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
const easeOut = (x) => 1 - (1 - x) ** 3;
const backOut = (x, s = 1.9) => 1 + (s + 1) * (x - 1) ** 3 + s * (x - 1) ** 2;
const spring = (x, f = 3, d = 5) => 1 - Math.exp(-d * x) * cos(f * TAU * x); // settles at 1 with a wobble

const OL = '#2A1050'; // outline (deep purple, reads richer than black)
const OW = 6;

const defs = `<defs>
<radialGradient id="g-head" cx="36%" cy="26%" r="82%"><stop offset="0" stop-color="#FFFBD1"/><stop offset=".22" stop-color="#FFEC3D"/><stop offset=".62" stop-color="#FFCC00"/><stop offset=".9" stop-color="#FFA300"/><stop offset="1" stop-color="#FF8A00"/></radialGradient>
<radialGradient id="g-wing" cx="30%" cy="22%" r="92%"><stop offset="0" stop-color="#FFF8B8"/><stop offset=".45" stop-color="#FFDA1A"/><stop offset="1" stop-color="#FF9500"/></radialGradient>
<linearGradient id="g-beakTop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB86B"/><stop offset=".55" stop-color="#FF7A12"/><stop offset="1" stop-color="#F25500"/></linearGradient>
<linearGradient id="g-beakBot" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F0732A"/><stop offset="1" stop-color="#C9481A"/></linearGradient>
<radialGradient id="g-eye" cx="40%" cy="30%" r="75%"><stop offset="0" stop-color="#5B4A70"/><stop offset=".45" stop-color="#2A1F3D"/><stop offset="1" stop-color="#0D0818"/></radialGradient>
<linearGradient id="g-cap" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#B07CFF"/><stop offset=".4" stop-color="#8236FF"/><stop offset="1" stop-color="#5A0FD6"/></linearGradient>
<linearGradient id="g-capSide" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#4A169E" stop-opacity=".0"/><stop offset="1" stop-color="#2E0B70" stop-opacity=".55"/></linearGradient>
<linearGradient id="g-brim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9450FF"/><stop offset="1" stop-color="#5208C9"/></linearGradient>
<linearGradient id="g-brimUnder" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1A1060"/><stop offset="1" stop-color="#2C1E8A"/></linearGradient>
<linearGradient id="g-hood" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".55" stop-color="#F4EEFF"/><stop offset="1" stop-color="#D9C9FF"/></linearGradient>
<linearGradient id="g-brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="g-field" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#EEF0FB"/></linearGradient>
<linearGradient id="g-lock" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7C6CFF"/><stop offset="1" stop-color="#3A26C8"/></linearGradient>
<linearGradient id="g-handle" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#B0703F"/><stop offset=".5" stop-color="#8A4E26"/><stop offset="1" stop-color="#5E3216"/></linearGradient>
<radialGradient id="g-glass" cx="40%" cy="35%" r="75%"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".6" stop-color="#E4F6FF"/><stop offset="1" stop-color="#A8DDFB"/></radialGradient>
<radialGradient id="g-glassTint" cx="35%" cy="30%" r="80%"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".25"/><stop offset=".7" stop-color="#9AD7FF" stop-opacity=".18"/><stop offset="1" stop-color="#3C9BEA" stop-opacity=".35"/></radialGradient>
<linearGradient id="g-rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE7A0"/><stop offset=".5" stop-color="#F6B532"/><stop offset="1" stop-color="#C7861A"/></linearGradient>
<clipPath id="c-lens"><circle r="60"/></clipPath>
<filter id="f-blur2" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="2"/></filter>
<filter id="f-blur5" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
<filter id="f-blur10" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="10"/></filter>
<filter id="f-sticker" x="-25%" y="-25%" width="150%" height="150%">
  <feMorphology in="SourceAlpha" operator="dilate" radius="11" result="d"/>
  <feGaussianBlur in="d" stdDeviation="6" result="db"/><feOffset in="db" dy="5" result="ds"/>
  <feFlood flood-color="#24164A" flood-opacity=".28"/><feComposite in2="ds" operator="in" result="shadow"/>
  <feFlood flood-color="#FFFFFF"/><feComposite in2="d" operator="in" result="white"/>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="white"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<clipPath id="c-head"><ellipse cx="256" cy="234" rx="124" ry="114"/></clipPath>
<clipPath id="c-body"><path d="M168 318 C 140 346 136 418 150 446 L 362 446 C 376 418 372 346 344 318 Z"/></clipPath>
</defs>`;

// ------------------------------------------------------------------ character parts
function tuft(t, lag) {
  const a = 10 * sin(t * TAU * 2 - 1.2) * 0.4 + lag * 14;
  return `<g transform="translate(0 4) rotate(${a} 256 112)">
    <path d="M252 116 C 238 88 214 84 206 96 C 222 96 236 104 246 118 Z" fill="url(#g-wing)" stroke="${OL}" stroke-width="5" stroke-linejoin="round"/>
    <path d="M258 116 C 262 80 286 66 298 74 C 282 84 272 98 266 118 Z" fill="url(#g-wing)" stroke="${OL}" stroke-width="5" stroke-linejoin="round"/>
    <path d="M255 117 C 250 92 258 72 268 66 C 266 84 264 100 262 118 Z" fill="#FFE45C" stroke="${OL}" stroke-width="5" stroke-linejoin="round"/></g>`;
}

function cap(t, lag) {
  const btn = lag * 3;
  return `<g>
    <!-- crown -->
    <path d="M150 186 C 146 122 194 92 256 92 C 318 92 366 122 362 186 C 296 172 216 172 150 186 Z" fill="url(#g-cap)"/>
    <path d="M300 98 C 346 114 366 150 362 186 C 346 180 330 177 314 176 C 324 146 320 120 300 98 Z" fill="url(#g-capSide)"/>
    <path d="M256 94 C 253 124 253 150 256 176 M200 106 C 192 132 192 160 196 180 M312 106 C 320 132 320 160 316 180" stroke="#3E1290" stroke-width="3" fill="none" opacity=".55"/>
    <path d="M184 122 C 200 106 224 98 248 97" stroke="#D2B8FF" stroke-width="9" stroke-linecap="round" fill="none" opacity=".7"/>
    <path d="M150 186 C 146 122 194 92 256 92 C 318 92 366 122 362 186 C 296 172 216 172 150 186 Z" fill="none" stroke="${OL}" stroke-width="${OW}" stroke-linejoin="round"/>
    <ellipse cx="256" cy="${94 - btn}" rx="13" ry="6" fill="#8A4DFF" stroke="${OL}" stroke-width="4"/>
    <!-- front badge: Talvio T on a brand bubble -->
    <g transform="translate(256 138) scale(.78)">
      <path d="M0 -30 c -22 0 -36 14 -36 31 c 0 9 4 16 10 22 l -4 14 c -.6 2 1.4 3.4 3 2.4 l 16 -9 c 3.5 1 7 1.4 11 1.4 c 22 0 36 -13 36 -31 S 22 -30 0 -30 z" fill="url(#g-brand)" stroke="${OL}" stroke-width="4"/>
      <rect x="-15" y="-14" width="30" height="8" rx="4" fill="#fff"/><rect x="-4" y="-14" width="8" height="28" rx="4" fill="#fff"/>
      <path d="M-22 -18 q 8 -8 18 -9" stroke="#fff" stroke-width="4" stroke-linecap="round" fill="none" opacity=".6"/>
    </g>
    <!-- brim -->
    <path d="M136 184 C 200 162 312 162 376 182 C 390 188 392 204 378 206 C 318 190 196 190 134 208 C 120 206 122 190 136 184 Z" fill="url(#g-brim)" stroke="${OL}" stroke-width="${OW}" stroke-linejoin="round"/>
    <path d="M156 184 C 214 172 298 172 356 182" stroke="#C3A2FF" stroke-width="5" stroke-linecap="round" fill="none" opacity=".75"/>
  </g>`;
}

function eye(cx, cy, o = {}) {
  const { open = 1, look = [0, 0], scale = 1, squint = 0 } = o;
  if (open < 0.1) {
    return `<path d="M${cx - 18} ${cy + 2} Q ${cx} ${cy + 12} ${cx + 18} ${cy + 2}" stroke="${OL}" stroke-width="7" fill="none" stroke-linecap="round"/>`;
  }
  const rx = 19 * scale, ry = 24 * scale * open;
  const [lx, ly] = look;
  return `<g>
    <ellipse cx="${cx + lx}" cy="${cy + ly}" rx="${rx}" ry="${ry}" fill="url(#g-eye)"/>
    <ellipse cx="${cx + lx}" cy="${cy + ly + ry * 0.55}" rx="${rx * 0.6}" ry="${ry * 0.22}" fill="#6E5AA8" opacity=".55"/>
    <ellipse cx="${cx + lx - rx * 0.32}" cy="${cy + ly - ry * 0.38}" rx="${rx * 0.36}" ry="${ry * 0.33}" fill="#fff"/>
    <circle cx="${cx + lx + rx * 0.38}" cy="${cy + ly + ry * 0.3}" r="${rx * 0.16}" fill="#fff" opacity=".9"/>
    ${squint > 0 ? `<path d="M${cx - 22} ${cy - ry + squint * 10} Q ${cx} ${cy - ry - 4 + squint * 14} ${cx + 22} ${cy - ry + squint * 10}" stroke="#FFD232" stroke-width="12" fill="none"/>` : ''}
  </g>`;
}

function brow(cx, cy, raise = 0, angle = 0) {
  return `<path d="M${cx - 14} ${cy - raise} Q ${cx} ${cy - 8 - raise} ${cx + 14} ${cy - raise}" stroke="${OL}" stroke-width="6" fill="none" stroke-linecap="round" transform="rotate(${angle} ${cx} ${cy})" opacity=".85"/>`;
}

function beak(open = 0) {
  const o = open * 16;
  return `<g>
    <path d="M226 ${284} C 238 ${300 + o} 274 ${300 + o} 286 ${284} C 272 ${292 + o * 0.4} 240 ${292 + o * 0.4} 226 ${284} Z" fill="url(#g-beakBot)" stroke="${OL}" stroke-width="5" stroke-linejoin="round"/>
    ${open > 0.15 ? `<ellipse cx="256" cy="${290 + o * 0.6}" rx="${12 * open + 4}" ry="${5 * open + 2}" fill="#FF7E9C"/>` : ''}
    <path d="M220 280 C 230 262 282 262 292 280 C 280 292 232 292 220 280 Z" fill="url(#g-beakTop)" stroke="${OL}" stroke-width="5" stroke-linejoin="round"/>
    <ellipse cx="244" cy="272" rx="11" ry="4" fill="#FFE6C2" opacity=".95"/>
    <circle cx="246" cy="279" r="2" fill="#B8461A"/><circle cx="266" cy="279" r="2" fill="#B8461A"/>
  </g>`;
}

function head(p, t) {
  const { eyes = {}, beakOpen = 0, blush = 0.6, browRaise = 0, lag = 0, rot = 0, dx = 0, extra = '' } = p;
  return `<g transform="translate(${dx} 0) rotate(${rot} 256 330)">
    ${tuft(t, lag)}
    <ellipse cx="256" cy="234" rx="124" ry="114" fill="url(#g-head)"/>
    <g clip-path="url(#c-head)">
      <ellipse cx="320" cy="310" rx="120" ry="70" fill="#E07A00" opacity=".38" filter="url(#f-blur10)"/>
      <ellipse cx="256" cy="194" rx="130" ry="16" fill="#B85A00" opacity=".35" filter="url(#f-blur10)"/>
      <ellipse cx="166" cy="250" rx="22" ry="40" fill="#FFF8D0" opacity=".55" filter="url(#f-blur5)"/>
    </g>
    <ellipse cx="256" cy="234" rx="124" ry="114" fill="none" stroke="${OL}" stroke-width="${OW}"/>
    <ellipse cx="178" cy="276" rx="24" ry="14" fill="#FF4F86" opacity="${blush}" filter="url(#f-blur5)"/>
    <ellipse cx="334" cy="276" rx="24" ry="14" fill="#FF4F86" opacity="${blush}" filter="url(#f-blur5)"/>
    ${eye(210, 236, { scale: 1.12, ...(eyes.l || {}) })}${eye(302, 236, { scale: 1.12, ...(eyes.r || {}) })}
    ${brow(210, 198, browRaise, -6)}${brow(302, 198, browRaise, 6)}
    ${beak(beakOpen)}
    ${cap(t, lag)}
    ${extra}
  </g>`;
}

function body() {
  return `<g>
    <path d="M168 318 C 140 346 136 418 150 446 L 362 446 C 376 418 372 346 344 318 Z" fill="url(#g-hood)"/>
    <g clip-path="url(#c-body)">
      <ellipse cx="350" cy="420" rx="70" ry="110" fill="#B9B3E6" opacity=".55" filter="url(#f-blur10)"/>
      <path d="M200 404 C 220 390 292 390 312 404 L 318 446 L 194 446 Z" fill="#E6E3F8" stroke="#C7C2EC" stroke-width="3"/>
    </g>
    <path d="M168 318 C 140 346 136 418 150 446 L 362 446 C 376 418 372 346 344 318 Z" fill="none" stroke="${OL}" stroke-width="${OW}" stroke-linejoin="round"/>
    <path d="M180 326 C 210 352 302 352 332 326" stroke="#D0CCEE" stroke-width="10" fill="none" stroke-linecap="round"/>
    <path d="M180 326 C 210 352 302 352 332 326" stroke="${OL}" stroke-width="3" fill="none" opacity=".35"/>
    <path d="M236 344 q -4 18 -2 32 M276 344 q 4 18 2 32" stroke="#A9A3D8" stroke-width="5" stroke-linecap="round" fill="none"/>
    <circle cx="234" cy="378" r="5" fill="#C9C9D9" stroke="${OL}" stroke-width="2"/><circle cx="278" cy="378" r="5" fill="#C9C9D9" stroke="${OL}" stroke-width="2"/>
    <g transform="translate(256 372)"><rect x="-20" y="-6" width="40" height="11" rx="5.5" fill="url(#g-brand)"/><rect x="-5.5" y="-6" width="11" height="32" rx="5.5" fill="url(#g-brand)"/></g>
  </g>`;
}

// a plump wing (hand) from shoulder s to the paw position p, paw rotated by r°
function wing(sx, sy, px, py, r = 0, flip = 1) {
  const dx = px - sx, dy = py - sy, L = Math.hypot(dx, dy) || 1;
  const ux = dx / L, uy = dy / L, nx = -uy, ny = ux;
  const w = 30;
  const a1 = [sx + nx * w, sy + ny * w], a2 = [sx - nx * w, sy - ny * w];
  const b1 = [px + nx * 26, py + ny * 26], b2 = [px - nx * 26, py - ny * 26];
  const arm = `M${a1[0]} ${a1[1]} C ${a1[0] + dx * 0.5} ${a1[1] + dy * 0.5} ${b1[0] - dx * 0.2} ${b1[1] - dy * 0.2} ${b1[0]} ${b1[1]} L ${b2[0]} ${b2[1]} C ${b2[0] - dx * 0.2} ${b2[1] - dy * 0.2} ${a2[0] + dx * 0.5} ${a2[1] + dy * 0.5} ${a2[0]} ${a2[1]} Z`;
  const ang = (Math.atan2(dy, dx) * 180) / Math.PI;
  // the paw: a broad feathered fan (three rounded feather tips)
  const paw = `<g transform="translate(${px} ${py}) rotate(${ang - 90 + r}) scale(${flip} 1)">
      <path d="M-38 -8 C -46 18 -34 44 -18 50 C -14 58 -2 60 4 54 C 12 62 26 58 30 48 C 44 44 46 20 38 -6 C 24 -26 -24 -26 -38 -8 Z" fill="url(#g-wing)" stroke="${OL}" stroke-width="${OW}" stroke-linejoin="round"/>
      <path d="M-18 48 C -16 36 -14 28 -10 22 M4 52 C 4 40 4 32 4 24 M28 46 C 24 36 22 28 18 22" stroke="#E39410" stroke-width="4" fill="none" stroke-linecap="round"/>
      <path d="M-26 -6 C -14 -16 6 -18 20 -12" stroke="#FFF6C0" stroke-width="7" stroke-linecap="round" fill="none" opacity=".85"/>
    </g>`;
  const cuffX = px - ux * 30, cuffY = py - uy * 30;
  const sleeve = `<path d="M${sx} ${sy} Q ${(sx + px) / 2 + nx * 10 * flip} ${(sy + py) / 2 + ny * 10 * flip} ${cuffX} ${cuffY}" stroke="${OL}" stroke-width="58" stroke-linecap="round" fill="none"/>
    <path d="M${sx} ${sy} Q ${(sx + px) / 2 + nx * 10 * flip} ${(sy + py) / 2 + ny * 10 * flip} ${cuffX} ${cuffY}" stroke="url(#g-hood)" stroke-width="46" stroke-linecap="round" fill="none"/>
    <path d="M${sx + ux * 10} ${sy + uy * 10} Q ${(sx + px) / 2 + nx * 6} ${(sy + py) / 2 + ny * 6} ${cuffX - ux * 8} ${cuffY - uy * 8}" stroke="#C9C4EC" stroke-width="10" stroke-linecap="round" fill="none" opacity=".6" transform="translate(${-nx * 12} ${-ny * 12})"/>
    <g transform="translate(${cuffX} ${cuffY}) rotate(${ang})"><rect x="-10" y="-27" width="20" height="54" rx="9" fill="url(#g-brand)" stroke="${OL}" stroke-width="5"/></g>`;
  void arm;
  return sleeve + paw;
}

function sparkle(x, y, r, color = '#FFC21A', rot = 0) {
  if (r < 1.5) return '';
  return `<path transform="rotate(${rot} ${x} ${y})" d="M${x} ${y - r} C ${x + r * 0.12} ${y - r * 0.12} ${x + r * 0.12} ${y - r * 0.12} ${x + r} ${y} C ${x + r * 0.12} ${y + r * 0.12} ${x + r * 0.12} ${y + r * 0.12} ${x} ${y + r} C ${x - r * 0.12} ${y + r * 0.12} ${x - r * 0.12} ${y + r * 0.12} ${x - r} ${y} C ${x - r * 0.12} ${y - r * 0.12} ${x - r * 0.12} ${y - r * 0.12} ${x} ${y - r} Z" fill="${color}" stroke="${OL}" stroke-width="3"/>`;
}

// ------------------------------------------------------------------ scene: password (hide)
// timeline (t 0..1): idle+blink → notices (eyes widen, squash) → paws up with overshoot → shy wiggle
// → right paw slides down, peek + wink → covers again → paws drop back to rest → loop
const SCENES = {};
SCENES.hide = (t) => {
  const LS = [176, 360], RS = [336, 360];
  const restL = [168, 430], restR = [344, 430];
  const coverL = [206, 232], coverR = [306, 232];
  const peekR = [366, 356];

  const up = backOut(seg(t, 0.2, 0.32));          // paws rise
  const down = easeInOut(seg(t, 0.86, 0.98));      // paws back to rest
  const cover = clamp(up) * (1 - down);
  const peek = easeInOut(seg(t, 0.56, 0.64)) * (1 - easeInOut(seg(t, 0.74, 0.8)));

  const L = [lerp(restL[0], coverL[0], up * (1 - down)), lerp(restL[1], coverL[1], up * (1 - down))];
  let R = [lerp(restR[0], coverR[0], up * (1 - down)), lerp(restR[1], coverR[1], up * (1 - down))];
  R = [lerp(R[0], peekR[0], peek), lerp(R[1], peekR[1], peek)];

  // body: anticipation squash before the paws go up, stretch as they go, wiggle while hiding
  const antic = sin(seg(t, 0.12, 0.22) * Math.PI) * 0.06;
  const stretch = sin(seg(t, 0.2, 0.34) * Math.PI) * 0.05;
  const wig = cover * (1 - peek) * sin(seg(t, 0.32, 0.56) * TAU * 3) * 4;
  const sq = antic - stretch;
  const dy = -10 * sin(seg(t, 0.2, 0.36) * Math.PI);
  const lag = -sin(seg(t, 0.2, 0.4) * Math.PI) * 0.8 + wig * 0.08; // tuft / cap button follow-through

  // eyes: blink at the start, widen when noticing, peek eye looks at you, then a wink
  const blink = sin(seg(t, 0.04, 0.09) * Math.PI);
  const notice = sin(seg(t, 0.12, 0.24) * Math.PI);
  const wink = sin(seg(t, 0.67, 0.73) * Math.PI);
  const eyes = {
    l: { open: 1 - blink, scale: 1 + 0.15 * notice },
    r: { open: (1 - blink) * (1 - wink * 0.95), scale: 1 + 0.15 * notice, look: [peek * -3, peek * 2] },
  };
  const blush = 0.45 + 0.5 * cover;

  // typing dots in the field, then the lock clicks
  const typed = Math.floor(clamp(seg(t, 0.3, 0.7)) * 6.99);
  const click = sin(seg(t, 0.72, 0.8) * Math.PI);
  let dots = '';
  for (let i = 0; i < 6; i++) {
    const shown = i < typed;
    const pop = shown ? spring(clamp((seg(t, 0.3, 0.7) * 7 - i) / 1.2)) : 0;
    dots += `<circle cx="${150 + i * 34}" cy="474" r="${9 * (shown ? pop : 0.55)}" fill="${shown ? '#4C38E6' : '#C9C4F2'}"/>`;
  }
  const field = `<g>
      <rect x="110" y="440" width="292" height="68" rx="34" fill="url(#g-field)" stroke="${OL}" stroke-width="${OW}"/>
      <rect x="118" y="448" width="276" height="52" rx="26" fill="none" stroke="#8E80FF" stroke-width="3" opacity=".7"/>
      ${dots}
      <g transform="translate(366 474) rotate(${click * 10})">
        <path d="M-11 -4 v -8 a 11 11 0 0 1 22 0 v ${8 - click * 6}" stroke="url(#g-lock)" stroke-width="6" fill="none" stroke-linecap="round"/>
        <rect x="-16" y="-5" width="32" height="25" rx="7" fill="url(#g-lock)" stroke="${OL}" stroke-width="4"/>
        <circle cx="0" cy="6" r="3.5" fill="#fff"/></g>
    </g>`;

  // shy marks and sparkles
  const shy = cover * (0.5 + 0.5 * sin(t * TAU * 6));
  const fx = `<g opacity="${shy}">
      <path d="M98 150 l -16 -18 M118 128 l -8 -22 M380 128 l 8 -22 M402 150 l 16 -18" stroke="#8E5BFF" stroke-width="8" stroke-linecap="round"/></g>
      ${sparkle(426, 220, 16 * sin(seg(t, 0.62, 0.82) * Math.PI), '#FFD232', 10)}
      ${sparkle(86, 250, 12 * sin(seg(t, 0.36, 0.52) * Math.PI), '#FF8FB1', -8)}`;

  return {
    pose: { sq, dy, rot: wig },
    headP: { eyes, blush, beakOpen: 0.35 + 0.4 * cover + 0.3 * notice, browRaise: 6 * notice + 4 * peek, lag },
    front: wing(...LS, ...L, 0, 1) + wing(...RS, ...R, 0, -1),
    field,
    fx,
  };
};


// ------------------------------------------------------------------ scene: no contacts / search
// idle → lifts a big magnifier to one eye (it looks huge) → scans left and right → "?" pops → lowers it,
// shrugs with both paws out → the empty contact card shakes → back to idle
SCENES.search = (t) => {
  const LS = [176, 360], RS = [336, 360];
  const lift = backOut(seg(t, 0.08, 0.2));
  const lower = easeInOut(seg(t, 0.62, 0.72));
  const hold = clamp(lift) * (1 - lower);
  const scan = seg(t, 0.2, 0.56);
  const sweep = hold > 0.5 ? sin(scan * TAU * 1.5) : 0;            // −1..1 left/right
  const shrug = sin(seg(t, 0.7, 0.92) * Math.PI);
  const q = spring(seg(t, 0.56, 0.7)) * (1 - easeInOut(seg(t, 0.88, 0.96)));

  // magnifier: lens over the right eye while searching, resting at the side otherwise
  const lens = [lerp(394, 302 + sweep * 10, hold), lerp(318, 236, hold)];
  const lensRot = lerp(-14 + 10 * shrug, -24 + sweep * 6, hold);
  const handPos = [lens[0] + 18 + 22 * hold, lens[1] + 92 - 6 * hold];

  const headRot = sweep * 7 * hold - shrug * 4;
  const look = [sweep * 7 * hold, 0];
  const blink = sin(seg(t, 0.02, 0.07) * Math.PI) + sin(seg(t, 0.95, 1.0) * Math.PI);

  const glass = `<g transform="translate(${lens[0]} ${lens[1]}) rotate(${lensRot})">
      <rect x="-12" y="58" width="24" height="88" rx="12" fill="url(#g-handle)" stroke="${OL}" stroke-width="${OW}"/>
      <rect x="-6" y="66" width="6" height="70" rx="3" fill="#C98A5A" opacity=".7"/>
      <circle r="62" fill="url(#g-glass)"/>
      <g transform="rotate(${-lensRot})">${hold > 0.6 ? `<g clip-path="url(#c-lens)">${eye(0, 2, { scale: 1.9, look: [look[0] * 1.6, 0], open: 1 - clamp(blink) })}</g>` : ''}</g>
      <circle r="62" fill="url(#g-glassTint)"/>
      <circle r="62" fill="none" stroke="url(#g-rim)" stroke-width="16"/>
      <circle r="62" fill="none" stroke="${OL}" stroke-width="${OW}"/><circle r="70" fill="none" stroke="${OL}" stroke-width="3" opacity=".5"/>
      <path d="M-40 -18 A 44 44 0 0 1 -14 -42" stroke="#fff" stroke-width="9" stroke-linecap="round" fill="none" opacity=".9"/>
      <path d="M28 34 A 44 44 0 0 1 10 44" stroke="#fff" stroke-width="5" stroke-linecap="round" fill="none" opacity=".5"/>
    </g>`;

  // paws: right one holds the handle; both swing out for the shrug
  const shrugL = [lerp(150, 112, shrug), lerp(430, 318, shrug)];
  const shrugR = [lerp(344, 400, shrug), lerp(430, 318, shrug)];
  void shrugR;
  const front = wing(...LS, ...shrugL, shrug * 40, 1) + glass + wing(...RS, ...handPos, 0, -1);

  // empty contact card that shakes "no one here"
  const shake = 6 * sin(seg(t, 0.6, 0.78) * TAU * 3) * sin(seg(t, 0.6, 0.78) * Math.PI);
  const card = `<g transform="translate(${256 + shake} 476)">
      <rect x="-128" y="-34" width="256" height="68" rx="22" fill="url(#g-field)" stroke="${OL}" stroke-width="${OW}"/>
      <circle cx="-88" cy="0" r="20" fill="none" stroke="#B8A6F2" stroke-width="5" stroke-dasharray="7 6"/>
      <circle cx="-88" cy="-5" r="6" fill="#CFC3F7"/><path d="M-99 11 c 3 -10 19 -10 22 0" fill="#CFC3F7"/>
      <rect x="-52" y="-14" width="${110 - 40 * sin(seg(t, 0.2, 0.56) * Math.PI)}" height="10" rx="5" fill="#E0D8FA"/>
      <rect x="-52" y="6" width="${70 + 30 * sin(seg(t, 0.2, 0.56) * Math.PI)}" height="10" rx="5" fill="#EDE8FC"/>
      <g transform="translate(96 0) scale(${0.8 + 0.25 * q})"><circle r="17" fill="#FF5577" stroke="${OL}" stroke-width="4"/><path d="M-6 -6 L 6 6 M6 -6 L -6 6" stroke="#fff" stroke-width="5" stroke-linecap="round"/></g>
    </g>`;

  const qmark = q > 0.02 ? `<g transform="translate(${392} ${118 - 10 * q}) scale(${q}) rotate(${8 * sin(t * TAU * 4)})">
      <circle r="34" fill="url(#g-brand)" stroke="${OL}" stroke-width="${OW}"/>
      <text x="0" y="16" text-anchor="middle" font-family="Jakarta" font-weight="800" font-size="46" fill="#fff">?</text></g>` : '';
  const sweat = shrug > 0.3 ? `<path d="M${338} ${178 + 14 * shrug} q 10 14 0 22 q -10 -8 0 -22 z" fill="#7CCBFF" stroke="${OL}" stroke-width="3" opacity="${shrug}"/>` : '';
  const sparks = sparkle(110, 168, 14 * sin(seg(t, 0.25, 0.4) * Math.PI), '#FFD232', 12) + sparkle(418, 300, 12 * sin(seg(t, 0.4, 0.55) * Math.PI), '#A57BFF', -10);

  return {
    pose: { sq: 0.03 * sin(seg(t, 0.06, 0.14) * Math.PI) - 0.03 * shrug, dy: -6 * shrug, rot: sweep * 2 * hold },
    headP: {
      rot: headRot,
      eyes: { l: { open: 1 - clamp(blink), look, scale: 1 }, r: { open: 1 - clamp(blink), look } },
      blush: 0.55,
      beakOpen: hold > 0.5 ? 0.35 : 0.2 + 0.5 * shrug,
      browRaise: 8 * q + 6 * shrug,
      lag: -sweep * 0.6 * hold + shrug * 0.6,
      extra: sweat,
    },
    front,
    field: card,
    fx: qmark + sparks,
  };
};

function frame(name, t) {
  const s = SCENES[name](t);
  const { sq = 0, dy = 0, rot = 0 } = s.pose;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 520" width="${SIZE}" height="${Math.round((SIZE * 520) / 512)}">${defs}
  <g transform="translate(256 262) scale(.9) translate(-256 -262)">
    <g filter="url(#f-sticker)">
      <g transform="translate(256 446) rotate(${rot}) translate(0 ${dy}) scale(${1 + sq} ${1 - sq}) translate(-256 -446)">
        ${body()}
        ${head(s.headP, t)}
        ${s.front}
      </g>
      ${s.field || ''}
    </g>
    ${s.fx || ''}
  </g>
</svg>`;
}

(async () => {
  const name = process.env.SCENE || 'hide';
  const fontDir = path.resolve(__dirname, '../../../backend/web-client/fonts');
  const b64 = fs.readFileSync(path.join(fontDir, 'PlusJakartaSans-ExtraBold.woff2')).toString('base64');
  const font = `@font-face{font-family:Jakarta;src:url(data:font/woff2;base64,${b64}) format('woff2');font-weight:800}`;
  const H = Math.round((SIZE * 520) / 512);
  const b = await chromium.launch();
  if (process.env.PREVIEW) {
    const picks = (process.env.PICKS || '0,0.17,0.28,0.45,0.62,0.7,0.82,0.93').split(',').map(Number);
    const cols = Math.min(4, picks.length);
    const rows = Math.ceil(picks.length / cols);
    const html = `<html><head><style>${font}body{margin:0;background:#EEF0F8;width:${cols * SIZE}px}svg{float:left}</style></head><body>${picks.map((t) => frame(name, t)).join('')}</body></html>`;
    const p = await b.newPage({ viewport: { width: cols * SIZE, height: rows * H } });
    await p.setContent(html);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: process.env.PREVIEW });
    await b.close();
    return;
  }
  if (process.env.FRAMES_DIR) {
    // one screenshot per frame (for big sizes like 1080 px)
    fs.mkdirSync(process.env.FRAMES_DIR, { recursive: true });
    const p = await b.newPage({ viewport: { width: SIZE, height: H } });
    for (let i = 0; i < FRAMES; i++) {
      await p.setContent(`<html><head><style>${font}html,body{margin:0;background:${process.env.BG || 'transparent'}}svg{display:block}</style></head><body>${frame(name, i / FRAMES)}</body></html>`);
      if (i === 0) await p.evaluate(() => document.fonts.ready);
      await p.screenshot({ path: path.join(process.env.FRAMES_DIR, `f${String(i).padStart(3, '0')}.png`), omitBackground: !process.env.BG });
    }
    await b.close();
    console.log('✓ frames', FRAMES, SIZE);
    return;
  }
  const COLS = 8;
  const rows = Math.ceil(FRAMES / COLS);
  const p = await b.newPage({ viewport: { width: COLS * SIZE, height: rows * H } });
  const html = `<html><head><style>${font}html,body{margin:0;background:transparent;width:${COLS * SIZE}px}svg{display:block;float:left}</style></head><body>${
    Array.from({ length: FRAMES }, (_, i) => frame(name, i / FRAMES)).join('')}</body></html>`;
  await p.setContent(html);
  await p.evaluate(() => document.fonts.ready);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'stk-'));
  const sheet = path.join(tmp, 'sheet.png');
  await p.screenshot({ path: sheet, omitBackground: true });
  await b.close();
  const out = process.env.OUT || path.resolve(__dirname, `../../assets/mascot/${name}.webp`);
  execFileSync('python3', ['-c', `
import sys
from PIL import Image
sheet = Image.open(sys.argv[1]).convert('RGBA')
n, w, h, cols, ms = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
frames = [sheet.crop(((i % cols) * w, (i // cols) * h, (i % cols + 1) * w, (i // cols + 1) * h)) for i in range(n)]
frames[0].save(sys.argv[2], save_all=True, append_images=frames[1:], duration=ms, loop=0, quality=80, method=6, alpha_quality=90)
# a GIF too, so it can be watched anywhere
bg = [Image.alpha_composite(Image.new('RGBA', f.size, (255, 255, 255, 255)), f).convert('RGB') for f in frames]
bg[0].save(sys.argv[2].rsplit('.', 1)[0] + '.gif', save_all=True, append_images=bg[1:], duration=ms, loop=0, optimize=True)
`, sheet, out, String(FRAMES), String(SIZE), String(H), String(COLS), String(Math.round(1000 / FPS))]);
  console.log('✓', out, (fs.statSync(out).size / 1024).toFixed(0) + ' KB');
})();
