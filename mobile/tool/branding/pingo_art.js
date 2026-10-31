// Pingo — Talvio's mascot: a little penguin in a Talvio-gradient scarf. Original character, sticker-style
// art (bold outline, soft shading, props that tell a story), rendered to looping animated WebP.
// Usage: node mobile/tool/branding/pingo_art.js                    → mobile/assets/mascot/*.webp
//        PREVIEW=/tmp/x.png ONLY=hide,search node ...               → contact sheet to look at
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const OUT = process.env.OUT || path.resolve(__dirname, '../../assets/mascot');
const FRAMES = 30; // 2.5 s at 12 fps
const SIZE = 360;
const TAU = Math.PI * 2;
const sin = Math.sin;
const cos = Math.cos;
const ease = (x) => 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, x)));
const blinkAt = (t, at = 0.82) => (t > at && t < at + 0.07 ? sin(((t - at) / 0.07) * Math.PI) : 0);

const O = '#1D1A33'; // outline
const W = 10; // outline width

const defs = `<defs>
<linearGradient id="back" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4A5A8C"/><stop offset=".55" stop-color="#2C3762"/><stop offset="1" stop-color="#1B2244"/></linearGradient>
<radialGradient id="backHi" cx="30%" cy="20%" r="60%"><stop offset="0" stop-color="#7C8CC4" stop-opacity=".9"/><stop offset="1" stop-color="#7C8CC4" stop-opacity="0"/></radialGradient>
<radialGradient id="belly" cx="45%" cy="35%" r="75%"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".7" stop-color="#F4F2FB"/><stop offset="1" stop-color="#D9D6EA"/></radialGradient>
<linearGradient id="beak" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFC24D"/><stop offset="1" stop-color="#FF8A1F"/></linearGradient>
<linearGradient id="foot" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB040"/><stop offset="1" stop-color="#F27A12"/></linearGradient>
<linearGradient id="scarf" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#7B4BE0"/></linearGradient>
<linearGradient id="scarfTail" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2557E"/><stop offset="1" stop-color="#7B4BE0"/></linearGradient>
<linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6E9F6"/></linearGradient>
<linearGradient id="metal" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6A7392"/><stop offset="1" stop-color="#2E3450"/></linearGradient>
<radialGradient id="lens" cx="35%" cy="30%" r="75%"><stop offset="0" stop-color="#E6F7FF"/><stop offset=".45" stop-color="#6CC3F5"/><stop offset="1" stop-color="#1F5FA8"/></radialGradient>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE7A0"/><stop offset=".5" stop-color="#F6B532"/><stop offset="1" stop-color="#C7861A"/></linearGradient>
<linearGradient id="mug" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FF8AA6"/><stop offset="1" stop-color="#E0406A"/></linearGradient>
<linearGradient id="cap" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8E9BFF"/><stop offset="1" stop-color="#5563E0"/></linearGradient>
<linearGradient id="shades" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A3F5C"/><stop offset="1" stop-color="#0E1020"/></linearGradient>
<filter id="blur4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
<filter id="blur10" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="10"/></filter>
</defs>`;

// ------------------------------------------------------------------ the penguin
// body: an egg, head merges into it. Ground at y≈452.
const BODY = 'M256 92 C 356 92 404 176 404 272 C 404 380 352 440 256 440 C 160 440 108 380 108 272 C 108 176 156 92 256 92 Z';
// white face mask (two lobes around the eyes) flowing into the belly
const MASK = 'M256 168 C 280 140 344 140 356 196 C 366 240 346 262 340 280 C 368 330 360 412 256 424 C 152 412 144 330 172 280 C 166 262 146 240 156 196 C 168 140 232 140 256 168 Z';

function eye(x, y, o = {}) {
  const { lid = 0, look = [0, 0], happy = false, closed = false, big = 1 } = o;
  if (happy) return `<path d="M${x - 22} ${y + 8} Q ${x} ${y - 20} ${x + 22} ${y + 8}" fill="none" stroke="${O}" stroke-width="10" stroke-linecap="round"/>`;
  if (closed || lid > 0.88) return `<path d="M${x - 20} ${y + 2} Q ${x} ${y + 12} ${x + 20} ${y + 2}" fill="none" stroke="${O}" stroke-width="9" stroke-linecap="round"/>`;
  const open = 1 - lid;
  const [lx, ly] = look;
  return `<g transform="translate(${x} ${y}) scale(1 ${open}) translate(${-x} ${-y})">
    <ellipse cx="${x + lx}" cy="${y + ly}" rx="${19 * big}" ry="${25 * big}" fill="${O}"/>
    <ellipse cx="${x + lx - 6 * big}" cy="${y + ly - 9 * big}" rx="${7 * big}" ry="${9 * big}" fill="#fff"/>
    <circle cx="${x + lx + 7 * big}" cy="${y + ly + 9 * big}" r="${3.5 * big}" fill="#fff" opacity=".8"/>
  </g>`;
}

function beak(kind = 'smile', t = 0) {
  if (kind === 'open') {
    return `<path d="M232 262 Q 256 252 280 262 Q 274 274 256 276 Q 238 274 232 262 Z" fill="url(#beak)" stroke="${O}" stroke-width="7" stroke-linejoin="round"/>
      <path d="M238 274 Q 256 304 274 274 Z" fill="#E0582A" stroke="${O}" stroke-width="7" stroke-linejoin="round"/>
      <ellipse cx="256" cy="284" rx="9" ry="5" fill="#FF8AA6"/>`;
  }
  if (kind === 'o') {
    return `<path d="M236 258 Q 256 250 276 258 Q 270 268 256 270 Q 242 268 236 258 Z" fill="url(#beak)" stroke="${O}" stroke-width="7" stroke-linejoin="round"/>
      <ellipse cx="256" cy="282" rx="10" ry="${11 + 2 * sin(t * TAU * 2)}" fill="#E0582A" stroke="${O}" stroke-width="6"/>`;
  }
  // closed little beak with a smile crease
  return `<path d="M230 260 Q 256 248 282 260 Q 272 284 256 286 Q 240 284 230 260 Z" fill="url(#beak)" stroke="${O}" stroke-width="7" stroke-linejoin="round"/>
    <path d="M238 266 Q 256 274 274 266" fill="none" stroke="#C8621A" stroke-width="4" stroke-linecap="round"/>
    <ellipse cx="248" cy="258" rx="8" ry="3" fill="#FFE2A0" opacity=".9"/>`;
}

function cheeks(a = 0.6) {
  return `<ellipse cx="190" cy="270" rx="20" ry="11" fill="#FF7FA0" opacity="${a}" filter="url(#blur4)"/>
    <ellipse cx="322" cy="270" rx="20" ry="11" fill="#FF7FA0" opacity="${a}" filter="url(#blur4)"/>`;
}

function tuft(t) {
  const s = 5 * sin(t * TAU);
  return `<path d="M246 98 C 236 70 ${250 + s} 58 ${262 + s} 66 C ${254 + s} 76 258 88 266 96" fill="url(#back)" stroke="${O}" stroke-width="8" stroke-linejoin="round"/>`;
}

function feet() {
  const f = (x, r) => `<path d="M${x - 34} 446 C ${x - 34} 420 ${x + 34} 420 ${x + 34} 446 C ${x + 20} 452 ${x + 8} 446 ${x} 452 C ${x - 8} 446 ${x - 20} 452 ${x - 34} 446 Z" fill="url(#foot)" stroke="${O}" stroke-width="8" stroke-linejoin="round" transform="rotate(${r} ${x} 440)"/>`;
  return f(208, -6) + f(304, 6);
}

// flipper from shoulder (sx,sy) pointing at angle a (deg, 0 = straight down), length len
function flipper(sx, sy, a, len = 96, side = 1) {
  const r = (a * Math.PI) / 180;
  const dx = sin(r) * len, dy = cos(r) * len;
  const nx = cos(r) * 26 * side, ny = -sin(r) * 26 * side;
  const tipX = sx + dx, tipY = sy + dy;
  return `<path d="M${sx - nx * 0.6} ${sy - ny * 0.6} C ${sx + nx * 1.4 + dx * 0.3} ${sy + ny * 1.4 + dy * 0.3} ${tipX + nx * 0.6} ${tipY + ny * 0.6} ${tipX} ${tipY}
    C ${tipX - nx * 0.5} ${tipY - ny * 0.5} ${sx - nx * 0.9 + dx * 0.5} ${sy - ny * 0.9 + dy * 0.5} ${sx - nx * 0.6} ${sy - ny * 0.6} Z"
    fill="url(#back)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>`;
}

// broad flipper tip held flat over an eye
function paddle(x, y, rot) {
  return `<g transform="rotate(${rot} ${x} ${y})"><ellipse cx="${x}" cy="${y}" rx="46" ry="34" fill="url(#back)" stroke="${O}" stroke-width="${W}"/>
    <path d="M${x - 26} ${y - 14} q 14 -12 34 -10" stroke="#9AA8DA" stroke-width="6" stroke-linecap="round" fill="none" opacity=".75"/></g>`;
}

function scarf(t, wind = 0) {
  const sw = 6 * sin(t * TAU) + wind;
  return `<path d="M168 300 C 200 324 312 324 344 300 L 350 330 C 312 356 200 356 162 330 Z" fill="url(#scarf)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <path d="M190 318 L 196 340 M222 324 L 224 346 M256 326 L 256 348 M290 324 L 288 346 M322 318 L 316 340" stroke="#fff" stroke-opacity=".35" stroke-width="5" stroke-linecap="round"/>
    <path d="M318 330 C ${330 + sw} 360 ${336 + sw} 384 ${344 + sw * 1.4} 404 L ${312 + sw * 1.4} 410 C ${306 + sw} 388 300 362 292 336 Z" fill="url(#scarfTail)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <path d="M${318 + sw * 1.4} 410 l -4 14 M${330 + sw * 1.4} 408 l 0 15 M${341 + sw * 1.4} 405 l 4 14" stroke="#7B4BE0" stroke-width="6" stroke-linecap="round"/>`;
}

function penguin(s, t) {
  return `${s.behind || ''}
    ${s.noTuft ? '' : tuft(t)}
    ${s.backArms || ''}
    <path d="${BODY}" fill="url(#back)"/>
    <path d="${BODY}" fill="url(#backHi)"/>
    <path d="${MASK}" fill="url(#belly)"/>
    <ellipse cx="256" cy="396" rx="70" ry="22" fill="#C9C5E0" opacity=".45" filter="url(#blur4)"/>
    <path d="${BODY}" fill="none" stroke="${O}" stroke-width="${W}"/>
    <path d="M170 150 Q 196 116 236 110" stroke="#9AA8DA" stroke-width="8" stroke-linecap="round" fill="none" opacity=".7"/>
    ${feet()}
    ${s.scarf === false ? '' : scarf(t, s.wind || 0)}
    ${s.face}
    ${s.front || ''}`;
}

function sparkle(x, y, r, color = '#FFC94D', a = 1) {
  if (r < 1) return '';
  return `<path d="M${x} ${y - r} Q ${x} ${y} ${x + r} ${y} Q ${x} ${y} ${x} ${y + r} Q ${x} ${y} ${x - r} ${y} Q ${x} ${y} ${x} ${y - r} Z" fill="${color}" stroke="${O}" stroke-width="3" opacity="${a}"/>`;
}

const face = (o = {}) => eye(214, 214, { ...o, ...(o.l || {}) }) + eye(298, 214, { ...o, ...(o.r || {}) }) + cheeks(o.cheeks ?? 0.6) + beak(o.beak || 'smile', o.t || 0);

// ------------------------------------------------------------------ scenes
const SCENES = {
  // password: both flippers over the eyes, shy wiggle; one peeks for a moment
  hide(t) {
    const w = 2 * sin(t * TAU * 2);
    const peek = t > 0.55 && t < 0.8 ? ease((t - 0.55) / 0.08) * (1 - ease((t - 0.72) / 0.08)) : 0;
    return {
      pose: { sq: 0.012 * sin(t * TAU * 2), rot: w * 0.6 },
      face: face({ t, cheeks: 0.85 }),
      front: flipper(150, 300, 146 + w * 2, 84, -1) + paddle(212, 212 + w, -18) + flipper(362, 300, -146 + w * 2, 84, 1) + paddle(300 + peek * 18, 212 - w + peek * 40, 18)
        + sparkle(120, 140, 12 * (0.5 + 0.5 * sin(t * TAU * 2)), '#FF9AB8'),
    };
  },
  peek(t) {
    const w = 2 * sin(t * TAU);
    return {
      pose: { sq: 0.01 * sin(t * TAU), rot: 2 },
      face: face({ t, look: [7, -2], r: { lid: blinkAt(t) }, cheeks: 0.8 }),
      front: flipper(150, 300, 146 + w, 84, -1) + paddle(212, 212 + w, -18) + flipper(362, 300, 22 + w * 2, 96, 1),
    };
  },
  // nothing found: looking through binoculars, turning left and right
  search(t) {
    const a = sin(t * TAU);
    const bx = 256 + 18 * a;
    return {
      pose: { sq: 0.01, rot: 5 * a, dy: 2 * sin(t * TAU * 2) },
      face: beak('o', t) + cheeks(0.6),
      front: `<g transform="translate(${bx} 206) rotate(${4 * a})">
          <rect x="-16" y="-14" width="32" height="26" rx="8" fill="url(#metal)" stroke="${O}" stroke-width="8"/>
          <rect x="-82" y="-36" width="66" height="72" rx="22" fill="url(#metal)" stroke="${O}" stroke-width="${W}"/>
          <rect x="16" y="-36" width="66" height="72" rx="22" fill="url(#metal)" stroke="${O}" stroke-width="${W}"/>
          <circle cx="-49" cy="-2" r="24" fill="url(#lens)" stroke="${O}" stroke-width="7"/>
          <circle cx="49" cy="-2" r="24" fill="url(#lens)" stroke="${O}" stroke-width="7"/>
          <path d="M-62 -12 a 14 14 0 0 1 12 -10 M36 -12 a 14 14 0 0 1 12 -10" stroke="#fff" stroke-width="6" stroke-linecap="round" fill="none" opacity="${0.5 + 0.5 * Math.abs(a)}"/>
        </g>` + flipper(150, 300, 168 - 6 * a, 104, -1) + flipper(362, 300, -168 - 6 * a, 104, 1),
    };
  },
  // code sent: proudly holds up a sealed letter
  mail(t) {
    const b = 6 * sin(t * TAU * 2);
    const sp = [0, 1, 2].map((i) => { const p = (t * 1.5 + i / 3) % 1; return sparkle([112, 404, 410][i], [150, 120, 300][i] - 24 * p, 18 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: -6 * Math.max(0, sin(t * TAU * 2)), sq: 0.02 * sin(t * TAU * 2) },
      behind: sp,
      face: face({ t, look: [0, -3], lid: blinkAt(t), beak: 'open' }),
      front: `<g transform="translate(256 ${370 + b}) rotate(${3 * sin(t * TAU)})">
          <rect x="-92" y="-58" width="184" height="118" rx="14" fill="url(#paper)" stroke="${O}" stroke-width="${W}"/>
          <path d="M-86 -50 L 0 14 L 86 -50" fill="none" stroke="${O}" stroke-width="8" stroke-linejoin="round"/>
          <path d="M-86 54 L -28 4 M 86 54 L 28 4" stroke="#B9BFD8" stroke-width="6" stroke-linecap="round"/>
          <circle cx="0" cy="12" r="22" fill="url(#brand)" stroke="${O}" stroke-width="6"/>
          <path d="M0 22 c -12 -7 -14 -16 -7 -20 c 3.5 -1.8 6 0 7 2.4 c 1 -2.4 3.5 -4.2 7 -2.4 c 7 4 5 13 -7 20 z" fill="#fff"/>
        </g>` + flipper(150, 300, 34, 84, -1) + flipper(362, 300, -34, 84, 1),
    };
  },
  // hello: big wave, scarf flutters
  wave(t) {
    const w = sin(t * TAU * 2.5);
    return {
      pose: { sq: 0.02 * sin(t * TAU), rot: 2 * sin(t * TAU) },
      face: face({ t, look: [4, 0], lid: blinkAt(t), beak: 'open' }),
      front: flipper(150, 300, -18, 96, -1) + flipper(362, 292, 140 + 22 * w, 104, 1)
        + `<path d="M440 150 q 14 12 10 30 M456 132 q 22 20 16 48" stroke="${O}" stroke-width="7" fill="none" stroke-linecap="round" opacity="${0.35 + 0.5 * Math.abs(w)}"/>`,
      wind: 4 * w,
    };
  },
  // thinking: flipper at the chin, a bulb lights up
  think(t) {
    const on = t > 0.45 ? Math.min(1, (t - 0.45) / 0.12) : 0;
    const bob = 4 * sin(t * TAU * 2);
    return {
      pose: { rot: 5, sq: 0.01 * sin(t * TAU) },
      behind: `<g transform="translate(400 ${92 + bob})">
          <circle r="${46 + 12 * on}" fill="#FFE07A" opacity="${0.45 * on}" filter="url(#blur10)"/>
          <path d="M0 -38 C 24 -38 36 -21 36 -2 C 36 15 24 23 19 36 L -19 36 C -24 23 -36 15 -36 -2 C -36 -21 -24 -38 0 -38 Z" fill="${on > 0.5 ? '#FFE07A' : '#F2F4FA'}" stroke="${O}" stroke-width="8"/>
          <rect x="-17" y="36" width="34" height="20" rx="6" fill="url(#metal)" stroke="${O}" stroke-width="6"/>
          ${on > 0.5 ? '<path d="M-52 -40 l -12 -10 M 52 -40 l 12 -10 M 0 -52 l 0 -14 M-58 0 l -16 0 M58 0 l 16 0" stroke="#F6B532" stroke-width="7" stroke-linecap="round"/>' : ''}
        </g>`,
      face: face({ t, look: [8, -10], lid: blinkAt(t, 0.2), beak: on > 0.5 ? 'open' : 'smile', cheeks: 0.45 }),
      front: flipper(150, 300, -20, 96, -1) + flipper(360, 304, -128, 92, 1),
    };
  },
  // all quiet: asleep in a night cap, z's drift up
  sleep(t) {
    const br = sin(t * TAU);
    const zs = [0, 1, 2].map((i) => { const p = (t + i / 3) % 1; return `<text x="${360 + 70 * p}" y="${150 - 100 * p}" font-family="Jakarta" font-weight="800" font-size="${30 + 34 * p}" fill="#7B86F5" stroke="${O}" stroke-width="3" opacity="${(1 - p) * 0.95}">z</text>`; }).join('');
    return {
      pose: { sq: 0.035 * br, rot: -5 },
      noTuft: true,
      face: face({ t, closed: true, cheeks: 0.7 }) + `<circle cx="296" cy="${290 + 2 * br}" r="${10 + 6 * Math.max(0, br)}" fill="#D6F0FF" stroke="#6FA8D0" stroke-width="4" opacity=".9"/>`,
      front: `<path d="M150 150 C 180 70 320 56 368 120 C 400 120 430 140 438 182 C 412 160 386 152 366 160 C 320 132 210 130 150 150 Z" fill="url(#cap)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
        <path d="M150 150 C 220 124 312 126 366 160" stroke="#fff" stroke-width="22" stroke-linecap="round" fill="none"/>
        <path d="M150 150 C 220 124 312 126 366 160" stroke="${O}" stroke-width="4" fill="none" opacity=".25"/>
        <circle cx="440" cy="190" r="20" fill="#fff" stroke="${O}" stroke-width="7"/>` + flipper(150, 300, -20, 96, -1) + flipper(362, 300, 20, 96, 1) + zs,
    };
  },
  // success / Plus: hop with confetti and a party hat
  celebrate(t) {
    const j = sin(t * TAU * 2);
    const conf = Array.from({ length: 20 }, (_, i) => {
      const r = (k) => ((Math.sin(i * 12.9898 + k * 78.233) * 43758.5453) % 1 + 1) % 1;
      const p = (t * (0.8 + r(1) * 0.6) + r(2)) % 1;
      const x = 30 + r(3) * 452 + 14 * sin(p * 9 + i), y = -20 + 520 * p;
      const c = ['#FF5E8A', '#FFC94D', '#8E54E9', '#3CC8FF', '#2ED47A', '#FF8A3D'][i % 6];
      return `<rect x="-8" y="-4.5" width="16" height="9" rx="2" fill="${c}" stroke="${O}" stroke-width="2" transform="translate(${x} ${y}) rotate(${p * 720 + i * 40})"/>`;
    }).join('');
    return {
      pose: { dy: -28 * Math.max(0, j), sq: j < 0 ? -0.05 * j : -0.03 * j },
      noTuft: true,
      face: face({ t, happy: true, beak: 'open', cheeks: 0.8 }),
      front: flipper(150, 296, -146 + 14 * j, 104, -1) + flipper(362, 296, 146 - 14 * j, 104, 1)
        + `<g transform="rotate(-12 256 90)"><path d="M210 112 L 262 0 L 312 112 Z" fill="url(#brand)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M226 78 L 296 78 M240 46 L 282 46" stroke="#FFE07A" stroke-width="9" stroke-linecap="round"/>
          <circle cx="262" cy="0" r="16" fill="#FFE07A" stroke="${O}" stroke-width="7"/></g>`,
      over: conf,
    };
  },
  // cool / unlocked: shades with a glint, nodding to a beat
  cool(t) {
    const g = (t * 1.2) % 1;
    const sp = [0, 1].map((i) => { const p = (t * 1.4 + i / 2) % 1; return sparkle([104, 414][i], [170, 220][i], 20 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: 4 * Math.abs(sin(t * TAU * 2)), sq: 0.015, rot: 2 * sin(t * TAU) },
      behind: sp,
      face: cheeks(0.5) + beak('smile') + `
        <rect x="160" y="184" width="90" height="58" rx="22" fill="url(#shades)" stroke="${O}" stroke-width="7"/>
        <rect x="262" y="184" width="90" height="58" rx="22" fill="url(#shades)" stroke="${O}" stroke-width="7"/>
        <path d="M248 202 Q 256 194 264 202" stroke="${O}" stroke-width="9" fill="none"/>
        <clipPath id="lensC"><rect x="160" y="184" width="90" height="58" rx="22"/><rect x="262" y="184" width="90" height="58" rx="22"/></clipPath>
        <g clip-path="url(#lensC)"><path d="M${120 + 300 * g} 250 L ${160 + 300 * g} 176" stroke="#fff" stroke-width="16" opacity=".55"/></g>`,
      front: flipper(150, 300, -22, 96, -1) + flipper(362, 300, 22, 96, 1),
    };
  },
  // bots / a break: sipping hot cocoa, steam curls
  coffee(t) {
    const steam = [0, 1].map((i) => { const p = (t + i / 2) % 1; return `<path d="M${292 + i * 26} ${300 - 60 * p} q -14 -18 0 -36 q 14 -18 0 -36" stroke="#C9CEE0" stroke-width="8" fill="none" stroke-linecap="round" opacity="${1 - p}"/>`; }).join('');
    return {
      pose: { dy: 2 * sin(t * TAU), sq: 0.015 * sin(t * TAU), rot: -2 },
      face: face({ t, happy: true, cheeks: 0.75 }),
      front: steam + `<g transform="translate(306 380)"><path d="M-44 -38 L 44 -38 L 38 44 Q 36 58 22 58 L -22 58 Q -36 58 -38 44 Z" fill="url(#mug)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M44 -18 q 34 0 32 28 q -2 24 -36 22" stroke="${O}" stroke-width="10" fill="none"/>
          <ellipse cx="0" cy="-38" rx="44" ry="10" fill="#6B3A22" stroke="${O}" stroke-width="7"/>
          <path d="M-16 10 c -9 -6 -10 -14 -3 -18 c 3 -1.5 5 0 6 2 c 1 -2 3 -3.5 6 -2 c 7 4 5 12 -9 18 z" fill="#fff"/></g>`
        + flipper(150, 300, -20, 96, -1) + flipper(362, 304, -110, 84, 1),
    };
  },
};

function frame(name, t) {
  const s = SCENES[name](t);
  const { dy = 0, sq = 0, rot = 0 } = s.pose;
  const lift = Math.max(0, -dy) / 30;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="${SIZE}" height="${SIZE}">${defs}
  <ellipse cx="256" cy="462" rx="${140 * (1 - 0.35 * lift)}" ry="${18 * (1 - 0.35 * lift)}" fill="#0B1A3A" opacity="${0.16 * (1 - 0.4 * lift)}" filter="url(#blur4)"/>
  <g transform="translate(0 6) translate(256 ${450 + dy}) rotate(${rot}) scale(${1 + sq} ${1 - sq}) translate(-256 -450)">
    ${penguin(s, t)}
  </g>
  ${s.over || ''}
</svg>`;
}

(async () => {
  const only = process.env.ONLY ? process.env.ONLY.split(',') : Object.keys(SCENES);
  const fontDir = path.resolve(__dirname, '../../../backend/web-client/fonts');
  const b64 = fs.readFileSync(path.join(fontDir, 'PlusJakartaSans-ExtraBold.woff2')).toString('base64');
  const font = `@font-face{font-family:Jakarta;src:url(data:font/woff2;base64,${b64}) format('woff2');font-weight:800}`;
  const b = await chromium.launch();
  const COLS = 6;
  if (process.env.PREVIEW) {
    const picks = (process.env.PICKS || '0,0.2,0.4,0.6,0.8,0.95').split(',').map(Number);
    const html = `<html><head><style>${font}body{margin:0;background:#F3F4F9;width:${picks.length * SIZE}px}svg{float:left}</style></head><body>${only.map((n) => picks.map((t) => frame(n, t)).join('')).join('')}</body></html>`;
    const p = await b.newPage({ viewport: { width: picks.length * SIZE, height: only.length * SIZE } });
    await p.setContent(html);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: process.env.PREVIEW });
    await b.close();
    return;
  }
  fs.mkdirSync(OUT, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pingo-'));
  const rows = Math.ceil(FRAMES / COLS);
  const p = await b.newPage({ viewport: { width: COLS * SIZE, height: rows * SIZE } });
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
n, size, cols = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
frames = [sheet.crop(((i % cols) * size, (i // cols) * size, (i % cols + 1) * size, (i // cols + 1) * size)) for i in range(n)]
frames[0].save(sys.argv[2], save_all=True, append_images=frames[1:], duration=83, loop=0, quality=78, method=5, alpha_quality=80)
`, sheet, path.join(OUT, `${name}.webp`), String(FRAMES), String(SIZE), String(COLS)]);
    console.log('✓', name, (fs.statSync(path.join(OUT, `${name}.webp`)).size / 1024).toFixed(0) + ' KB');
  }
  await b.close();
})();
