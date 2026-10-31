// Pebo — Talvio's mascot, drawn as layered SVG and rendered to looping animated WebP for the app's
// screens (password, empty lists, code sent, success…). Original character; no third-party art.
// Usage: node mobile/tool/branding/pebo_art.js            → mobile/assets/mascot/*.webp
//        PREVIEW=/tmp/x.png ONLY=hide,search node ...      → a contact sheet to look at
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const OUT = process.env.OUT || path.resolve(__dirname, '../../assets/mascot');
const FRAMES = 30; // 2.5 s at 12 fps
const SIZE = 360;
const TAU = Math.PI * 2;
const sin = (x) => Math.sin(x);
const ease = (x) => 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, x)));

const defs = `<defs>
<radialGradient id="body" cx="36%" cy="26%" r="85%"><stop offset="0" stop-color="#D4FFF0"/><stop offset=".32" stop-color="#7EF0CC"/><stop offset=".78" stop-color="#2EC4A6"/><stop offset="1" stop-color="#169985"/></radialGradient>
<radialGradient id="limb" cx="35%" cy="30%" r="80%"><stop offset="0" stop-color="#B9FBE5"/><stop offset=".6" stop-color="#4AD8B6"/><stop offset="1" stop-color="#22A992"/></radialGradient>
<radialGradient id="iris" cx="38%" cy="34%" r="70%"><stop offset="0" stop-color="#3D4F8F"/><stop offset=".55" stop-color="#1E2A55"/><stop offset="1" stop-color="#0F1530"/></radialGradient>
<linearGradient id="leaf" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#C8FF8A"/><stop offset="1" stop-color="#3FBF5C"/></linearGradient>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE7A0"/><stop offset=".5" stop-color="#F6B532"/><stop offset="1" stop-color="#C7861A"/></linearGradient>
<radialGradient id="glass" cx="35%" cy="30%" r="75%"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".95"/><stop offset=".5" stop-color="#BFE9FF" stop-opacity=".55"/><stop offset="1" stop-color="#6CC3F5" stop-opacity=".5"/></radialGradient>
<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E9ECF8"/></linearGradient>
<linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="mug" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FF7A9A"/><stop offset="1" stop-color="#E0406A"/></linearGradient>
<linearGradient id="shades" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A3F5C"/><stop offset="1" stop-color="#0E1020"/></linearGradient>
<filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="9"/></filter>
<filter id="blur4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
<clipPath id="bodyClip"><path d="${bodyPath()}"/></clipPath>
</defs>`;

function bodyPath() {
  // a soft gummy drop: rounder at the top, wide sitting base
  return 'M256 150 C 352 150 408 222 410 306 C 412 380 372 432 256 432 C 140 432 100 380 102 306 C 104 222 160 150 256 150 Z';
}

const LINE = '#0F7E70';
const INK = '#14203F';

function eye(x, y, o = {}) {
  const { lid = 0, look = [0, 0], big = 1, happy = false, sad = false } = o;
  if (happy) return `<path d="M${x - 26} ${y + 8} Q ${x} ${y - 26} ${x + 26} ${y + 8}" fill="none" stroke="${INK}" stroke-width="11" stroke-linecap="round"/>`;
  if (sad) return `<path d="M${x - 24} ${y - 4} Q ${x} ${y + 18} ${x + 24} ${y - 4}" fill="none" stroke="${INK}" stroke-width="10" stroke-linecap="round"/>`;
  const rx = 31 * big, ry = 38 * big;
  const open = 1 - lid;
  if (open < 0.12) return `<path d="M${x - 26} ${y + 4} Q ${x} ${y + 14} ${x + 26} ${y + 4}" fill="none" stroke="${INK}" stroke-width="10" stroke-linecap="round"/>`;
  const [lx, ly] = look;
  return `<g transform="translate(${x} ${y}) scale(1 ${open}) translate(${-x} ${-y})">
  <ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${ry}" fill="#fff"/>
  <ellipse cx="${x}" cy="${y + 4}" rx="${rx}" ry="${ry}" fill="none" stroke="#9EC9D8" stroke-opacity=".5" stroke-width="3"/>
  <ellipse cx="${x + lx}" cy="${y + 6 + ly}" rx="${21 * big}" ry="${25 * big}" fill="url(#iris)"/>
  <ellipse cx="${x + lx}" cy="${y + 8 + ly}" rx="${10 * big}" ry="${12 * big}" fill="#070B1C"/>
  <ellipse cx="${x + lx - 8}" cy="${y - 4 + ly}" rx="${8 * big}" ry="${9 * big}" fill="#fff"/>
  <circle cx="${x + lx + 9}" cy="${y + 16 + ly}" r="${4 * big}" fill="#fff" opacity=".85"/>
  <ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${ry}" fill="none" stroke="${LINE}" stroke-width="5"/>
</g>`;
}

function mouth(kind, t) {
  switch (kind) {
    case 'open': return `<path d="M228 352 Q 256 350 284 352 Q 282 392 256 392 Q 230 392 228 352 Z" fill="#7A1F3D" stroke="${INK}" stroke-width="7" stroke-linejoin="round"/>
      <ellipse cx="256" cy="383" rx="15" ry="8" fill="#FF7A9A"/>`;
    case 'o': { const s = 1 + 0.1 * sin(t * TAU * 2); return `<ellipse cx="256" cy="366" rx="${15 * s}" ry="${19 * s}" fill="#7A1F3D" stroke="${INK}" stroke-width="7"/>`; }
    case 'flat': return `<path d="M236 362 Q 256 358 276 362" fill="none" stroke="${INK}" stroke-width="9" stroke-linecap="round"/>`;
    case 'side': return `<path d="M244 364 Q 262 356 280 360" fill="none" stroke="${INK}" stroke-width="9" stroke-linecap="round"/>`;
    case 'sleep': { const o = 6 + 4 * sin(t * TAU); return `<ellipse cx="256" cy="366" rx="9" ry="${o}" fill="#7A1F3D" stroke="${INK}" stroke-width="5"/>`; }
    default: return `<path d="M230 350 Q 256 378 282 350" fill="none" stroke="${INK}" stroke-width="9" stroke-linecap="round"/>`;
  }
}

function hand(x, y, r = 30, rot = 0) {
  return `<g transform="rotate(${rot} ${x} ${y})"><ellipse cx="${x}" cy="${y}" rx="${r}" ry="${r * 0.86}" fill="url(#limb)" stroke="${LINE}" stroke-width="6"/>
  <path d="M${x - r * 0.35} ${y - r * 0.55} q ${r * 0.1} ${-r * 0.2} ${r * 0.35} ${-r * 0.15}" stroke="#fff" stroke-opacity=".7" stroke-width="5" fill="none" stroke-linecap="round"/></g>`;
}

function arm(sx, sy, ex, ey) {
  return `<path d="M${sx} ${sy} Q ${(sx + ex) / 2} ${(sy + ey) / 2 + 10} ${ex} ${ey}" stroke="${LINE}" stroke-width="42" stroke-linecap="round" fill="none"/>
  <path d="M${sx} ${sy} Q ${(sx + ex) / 2} ${(sy + ey) / 2 + 10} ${ex} ${ey}" stroke="#47D3B2" stroke-width="30" stroke-linecap="round" fill="none"/>`;
}

function sprout(t) {
  const sw = 8 * sin(t * TAU + 0.6);
  return `<g>
  <path d="M256 156 Q ${258 + sw * 0.3} 128 ${262 + sw} 110" stroke="${LINE}" stroke-width="9" stroke-linecap="round" fill="none"/>
  <path d="M${262 + sw} 112 C ${282 + sw} 82 ${322 + sw} 84 ${334 + sw} 96 C ${318 + sw} 122 ${282 + sw} 126 ${262 + sw} 112 Z" fill="url(#leaf)" stroke="#2C8E46" stroke-width="5" stroke-linejoin="round"/>
  <path d="M${262 + sw} 112 C ${236 + sw} 92 ${210 + sw} 98 ${202 + sw} 108 C ${216 + sw} 126 ${244 + sw} 124 ${262 + sw} 112 Z" fill="url(#leaf)" stroke="#2C8E46" stroke-width="5" stroke-linejoin="round"/>
  <path d="M${270 + sw} 108 Q ${296 + sw} 98 ${322 + sw} 98" stroke="#E9FFD0" stroke-opacity=".7" stroke-width="3" fill="none" stroke-linecap="round"/>
</g>`;
}

function body(o = {}) {
  const { tint = null } = o;
  return `<g>
  <path d="${bodyPath()}" fill="url(#body)"/>
  ${tint ? `<path d="${bodyPath()}" fill="${tint}"/>` : ''}
  <g clip-path="url(#bodyClip)">
    <ellipse cx="256" cy="452" rx="190" ry="70" fill="#0E7F70" opacity=".28" filter="url(#soft)"/>
    <ellipse cx="256" cy="392" rx="96" ry="44" fill="#fff" opacity=".18"/>
    <ellipse cx="190" cy="208" rx="54" ry="30" fill="#fff" opacity=".55" transform="rotate(-24 190 208)" filter="url(#blur4)"/>
    <ellipse cx="176" cy="200" rx="18" ry="10" fill="#fff" opacity=".9" transform="rotate(-24 176 200)"/>
  </g>
  <path d="${bodyPath()}" fill="none" stroke="${LINE}" stroke-width="8"/>
</g>`;
}

function cheeks(a = 0.55) {
  return `<ellipse cx="170" cy="342" rx="26" ry="15" fill="#FF6F96" opacity="${a}" filter="url(#blur4)"/>
  <ellipse cx="342" cy="342" rx="26" ry="15" fill="#FF6F96" opacity="${a}" filter="url(#blur4)"/>`;
}

function feet() {
  return `<ellipse cx="200" cy="430" rx="34" ry="16" fill="url(#limb)" stroke="${LINE}" stroke-width="6"/>
  <ellipse cx="312" cy="430" rx="34" ry="16" fill="url(#limb)" stroke="${LINE}" stroke-width="6"/>`;
}

function sparkle(x, y, r, color = '#FFC94D', a = 1) {
  if (r < 1) return '';
  return `<path d="M${x} ${y - r} Q ${x} ${y} ${x + r} ${y} Q ${x} ${y} ${x} ${y + r} Q ${x} ${y} ${x - r} ${y} Q ${x} ${y} ${x} ${y - r} Z" fill="${color}" opacity="${a}"/>`;
}

const blinkAt = (t, at = 0.82) => (t > at && t < at + 0.07 ? sin(((t - at) / 0.07) * Math.PI) : 0);

// ------------------------------------------------------------------ scenes
// Each returns { pose: {dy, sq, rot}, back, face, front } for time t in 0..1
const SCENES = {
  // password: paws over the eyes, a little shy wiggle; fingers part once to peek
  hide(t) {
    const w = sin(t * TAU * 2) * 3;
    const peek = t > 0.55 && t < 0.8 ? ease((t - 0.55) / 0.1) * (1 - ease((t - 0.7) / 0.1)) : 0;
    return {
      pose: { dy: 0, sq: 0.015 * sin(t * TAU * 2), rot: w * 0.4 },
      face: eye(205, 282, { look: [0, 0] }) + eye(307, 282, { look: [0, 0] }) + cheeks(0.75) + mouth('smile'),
      front: arm(118, 352, 176, 300) + arm(394, 352, 334, 300 + peek * 26)
        + hand(200, 282 + w, 50, -12) + hand(312, 282 - w + peek * 34, 50, 12),
    };
  },
  // password shown: one paw down, peeking with a cheeky look
  peek(t) {
    const w = sin(t * TAU) * 2;
    return {
      pose: { dy: 0, sq: 0.015 * sin(t * TAU), rot: 1.5 },
      face: eye(205, 282, { look: [8, -2] }) + eye(307, 282, { look: [8, -2], lid: blinkAt(t) }) + cheeks(0.7) + mouth('side'),
      front: arm(118, 352, 176, 300) + hand(200, 282 + w, 50, -12) + arm(394, 372, 400, 392) + hand(402, 398, 30, 10),
    };
  },
  // nothing found / no contacts: magnifier sweeping, eyes following
  search(t) {
    const a = sin(t * TAU);
    const mx = 318 + 30 * a, my = 286 - 8 * Math.abs(a);
    const glint = (t * 1.3) % 1;
    return {
      pose: { dy: 3 * sin(t * TAU * 2), sq: 0.01, rot: 3 * a },
      face: eye(205, 282, { look: [10 * a, 0], lid: blinkAt(t, 0.4) }) + eye(307, 282, { look: [10 * a, 0], lid: blinkAt(t, 0.4) }) + cheeks() + mouth('flat'),
      front: arm(140, 368, 150, 392) + hand(150, 396, 28)
        + `<g transform="translate(${mx} ${my}) rotate(${-20 + 8 * a})">
          <rect x="-12" y="58" width="24" height="90" rx="12" fill="#7A4A2A" stroke="#4A2A14" stroke-width="5"/>
          <circle cx="0" cy="0" r="66" fill="url(#glass)"/>
          <circle cx="0" cy="0" r="66" fill="none" stroke="url(#gold)" stroke-width="15"/>
          <circle cx="0" cy="0" r="74" fill="none" stroke="#9A6512" stroke-width="2.5" opacity=".6"/>
          <path d="M-36 -18 A 40 40 0 0 1 -8 -40" stroke="#fff" stroke-width="8" stroke-linecap="round" fill="none" opacity="${0.4 + 0.6 * sin(glint * Math.PI)}"/>
        </g>` + arm(394, 380, mx + 20, my + 116) + hand(mx + 18, my + 118, 30),
    };
  },
  // code sent: holding up a sealed envelope that bobs, sparkles around
  mail(t) {
    const b = 6 * sin(t * TAU * 2);
    const sp = [0, 1, 2].map((i) => { const p = (t * 1.5 + i / 3) % 1; return sparkle([120, 400, 380][i], [170, 150, 300][i] - 20 * p, 16 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: -4 * Math.max(0, sin(t * TAU * 2)), sq: 0.02 * sin(t * TAU * 2), rot: 0 },
      back: sp,
      face: eye(205, 270, { look: [0, -4], lid: blinkAt(t) }) + eye(307, 270, { look: [0, -4], lid: blinkAt(t) }) + cheeks() + mouth('open'),
      front: `<g transform="translate(256 ${372 + b}) rotate(${2 * sin(t * TAU)})">
          <rect x="-82" y="-50" width="164" height="104" rx="14" fill="url(#paper)" stroke="#5C6788" stroke-width="6"/>
          <path d="M-78 -44 L 0 12 L 78 -44" fill="none" stroke="#5C6788" stroke-width="6" stroke-linejoin="round"/>
          <path d="M-78 48 L -24 -2 M 78 48 L 24 -2" stroke="#C3C9DE" stroke-width="5" stroke-linecap="round"/>
          <circle cx="0" cy="10" r="19" fill="url(#brand)" stroke="#fff" stroke-width="4"/>
          <path d="M0 18 c -10 -6 -12 -14 -6 -17 c 3 -1.5 5 0 6 2 c 1 -2 3 -3.5 6 -2 c 6 3 4 11 -6 17 z" fill="#fff"/>
        </g>` + hand(176, 376 + b, 30, -10) + hand(336, 376 + b, 30, 10),
    };
  },
  // hello: friendly wave
  wave(t) {
    const w = sin(t * TAU * 2.5);
    const hx = 438 + 12 * w, hy = 236 - 6 * Math.abs(w);
    return {
      pose: { dy: 2 * sin(t * TAU), sq: 0.02 * sin(t * TAU), rot: 2 * sin(t * TAU) },
      face: eye(205, 282, { look: [4, 0], lid: blinkAt(t) }) + eye(307, 282, { look: [4, 0], lid: blinkAt(t) }) + cheeks() + mouth('open'),
      front: arm(140, 368, 146, 394) + hand(146, 398, 28) + arm(396, 318, hx - 6, hy + 20) + hand(hx, hy, 34, 20 * w)
        + `<path d="M${hx + 40} ${hy - 30} q 12 10 10 26 M${hx + 52} ${hy - 44} q 18 16 14 40" stroke="#2EC4A6" stroke-width="6" fill="none" stroke-linecap="round" opacity="${0.4 + 0.5 * Math.abs(w)}"/>`,
    };
  },
  // thinking: paw on chin, eyes up, lightbulb flickers on
  think(t) {
    const on = t > 0.45 ? Math.min(1, (t - 0.45) / 0.12) : 0;
    const bob = 4 * sin(t * TAU * 2);
    return {
      pose: { dy: 0, sq: 0.012 * sin(t * TAU), rot: 4 },
      back: `<g transform="translate(392 ${118 + bob})">
          <circle cx="0" cy="0" r="${44 + 10 * on}" fill="#FFE07A" opacity="${0.35 * on}" filter="url(#soft)"/>
          <path d="M0 -36 C 22 -36 34 -20 34 -2 C 34 14 22 22 18 34 L -18 34 C -22 22 -34 14 -34 -2 C -34 -20 -22 -36 0 -36 Z" fill="${on > 0.5 ? '#FFE07A' : '#F2F4FA'}" stroke="#8A6A12" stroke-width="5"/>
          <rect x="-16" y="34" width="32" height="18" rx="5" fill="#9AA3BD" stroke="#5C6788" stroke-width="4"/>
          <path d="M-8 6 L 0 18 L 8 6" stroke="#B58712" stroke-width="4" fill="none"/>
        </g>
        <circle cx="352" cy="200" r="9" fill="#E8EBF7" stroke="#B9C0D8" stroke-width="3"/><circle cx="332" cy="226" r="6" fill="#E8EBF7" stroke="#B9C0D8" stroke-width="3"/>`,
      face: eye(205, 282, { look: [10, -12], lid: blinkAt(t, 0.2) }) + eye(307, 282, { look: [10, -12], lid: blinkAt(t, 0.2) }) + cheeks(0.45) + mouth(on > 0.5 ? 'smile' : 'side'),
      front: arm(140, 368, 146, 394) + hand(146, 398, 28) + arm(372, 380, 292, 392) + hand(286, 392, 28, -20),
    };
  },
  // all quiet: dozing with a night cap, z's float away
  sleep(t) {
    const br = sin(t * TAU);
    const zs = [0, 1, 2].map((i) => { const p = (t + i / 3) % 1; return `<text x="${352 + 70 * p}" y="${190 - 110 * p}" font-family="Jakarta" font-weight="800" font-size="${28 + 34 * p}" fill="#7B86F5" opacity="${(1 - p) * 0.95}">z</text>`; }).join('');
    return {
      pose: { dy: 0, sq: 0.03 * br, rot: -4 },
      face: eye(205, 290, { lid: 1 }) + eye(307, 290, { lid: 1 }) + cheeks(0.6) + mouth('sleep', t)
        + `<ellipse cx="${292}" cy="${354 + 4 * br}" rx="${8 + 5 * Math.max(0, br)}" ry="${8 + 5 * Math.max(0, br)}" fill="#C8ECFF" stroke="#7FB8DA" stroke-width="3" opacity=".85"/>`,
      front: `<path d="M150 214 C 186 140 300 128 352 190 C 384 186 412 200 420 236 C 396 214 370 206 350 214 C 300 186 210 186 150 214 Z" fill="#6C7BF2" stroke="#3E4AB8" stroke-width="6" stroke-linejoin="round"/>
        <path d="M156 212 C 230 184 300 186 352 214" stroke="#fff" stroke-width="16" stroke-linecap="round" fill="none"/>
        <circle cx="424" cy="244" r="17" fill="#fff" stroke="#C9CEE8" stroke-width="4"/>` + feet() + zs,
      noSprout: true,
    };
  },
  // success / Plus: jump with confetti and a party hat
  celebrate(t) {
    const j = sin(t * TAU * 2);
    const conf = Array.from({ length: 18 }, (_, i) => {
      const r = (k) => ((Math.sin(i * 12.9898 + k * 78.233) * 43758.5453) % 1 + 1) % 1;
      const p = (t * (0.8 + r(1) * 0.6) + r(2)) % 1;
      const x = 40 + r(3) * 432 + 14 * sin(p * 9 + i), y = -20 + 520 * p;
      const c = ['#FF5E8A', '#FFC94D', '#8E54E9', '#3CC8FF', '#2ED47A', '#FF8A3D'][i % 6];
      return `<rect x="-7" y="-4" width="14" height="8" rx="2" fill="${c}" transform="translate(${x} ${y}) rotate(${p * 720 + i * 40})"/>`;
    }).join('');
    return {
      pose: { dy: -26 * Math.max(0, j), sq: j < 0 ? -0.05 * j : -0.03 * j, rot: 0 },
      face: eye(205, 282, { happy: true }) + eye(307, 282, { happy: true }) + cheeks(0.7) + mouth('open'),
      front: arm(140, 340, 112, 262 - 10 * j) + hand(108, 254 - 10 * j, 30) + arm(372, 340, 400, 262 - 10 * j) + hand(404, 254 - 10 * j, 30)
        + `<g transform="rotate(-14 230 150)"><path d="M190 168 L 236 58 L 282 168 Z" fill="url(#brand)" stroke="#5B2BA8" stroke-width="6" stroke-linejoin="round"/>
          <circle cx="216" cy="140" r="7" fill="#FFE07A"/><circle cx="246" cy="112" r="7" fill="#FFE07A"/><circle cx="252" cy="152" r="6" fill="#fff"/>
          <circle cx="236" cy="56" r="14" fill="#FFE07A" stroke="#C7861A" stroke-width="4"/></g>`,
      over: conf,
      noSprout: true,
    };
  },
  // cool / unlocked: sunglasses with a glint, nodding
  cool(t) {
    const g = (t * 1.2) % 1;
    const sp = [0, 1].map((i) => { const p = (t * 1.4 + i / 2) % 1; return sparkle([110, 410][i], [190, 230][i], 18 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: 4 * Math.abs(sin(t * TAU * 2)), sq: 0.015, rot: 2 * sin(t * TAU) },
      back: sp,
      face: cheeks(0.45) + `<path d="M228 352 Q 262 374 290 346" fill="none" stroke="${INK}" stroke-width="9" stroke-linecap="round"/>
        <rect x="150" y="248" width="100" height="66" rx="24" fill="url(#shades)"/><rect x="262" y="248" width="100" height="66" rx="24" fill="url(#shades)"/>
        <path d="M248 266 Q 256 258 264 266" stroke="#0E1020" stroke-width="10" fill="none"/>
        <path d="M150 262 L 118 252 M362 262 L 394 252" stroke="#0E1020" stroke-width="9" stroke-linecap="round"/>
        <clipPath id="lens"><rect x="150" y="248" width="100" height="66" rx="24"/><rect x="262" y="248" width="100" height="66" rx="24"/></clipPath>
        <g clip-path="url(#lens)"><path d="M${120 + 300 * g} 320 L ${160 + 300 * g} 240" stroke="#fff" stroke-width="16" opacity=".55"/><path d="M${146 + 300 * g} 320 L ${176 + 300 * g} 240" stroke="#fff" stroke-width="6" opacity=".45"/></g>`,
      front: arm(140, 368, 146, 394) + hand(146, 398, 28) + arm(372, 368, 366, 394) + hand(366, 398, 28),
    };
  },
  // bots / coffee break: sipping, steam rising
  coffee(t) {
    const steam = [0, 1].map((i) => { const p = (t + i / 2) % 1; return `<path d="M${300 + i * 22} ${300 - 60 * p} q -14 -18 0 -36 q 14 -18 0 -36" stroke="#C9CEE0" stroke-width="7" fill="none" stroke-linecap="round" opacity="${1 - p}"/>`; }).join('');
    return {
      pose: { dy: 2 * sin(t * TAU), sq: 0.015 * sin(t * TAU), rot: -2 },
      face: eye(205, 282, { happy: true }) + eye(307, 282, { happy: true }) + cheeks(0.6) + mouth('smile'),
      front: `<g transform="translate(312 372)"><path d="M-40 -34 L 40 -34 L 34 40 Q 32 52 20 52 L -20 52 Q -32 52 -34 40 Z" fill="url(#mug)" stroke="#9A2448" stroke-width="6" stroke-linejoin="round"/>
          <path d="M40 -16 q 30 0 28 26 q -2 22 -32 20" stroke="#9A2448" stroke-width="8" fill="none"/>
          <ellipse cx="0" cy="-34" rx="40" ry="9" fill="#5A2E1A" stroke="#9A2448" stroke-width="5"/>
          <path d="M-14 8 c -8 -6 -9 -13 -3 -16 c 3 -1.5 5 0 6 2 c 1 -2 3 -3.5 6 -2 c 6 3 5 10 -9 16 z" fill="#fff" opacity=".9"/></g>`
        + steam + hand(270, 392, 28, -10) + arm(140, 368, 146, 394) + hand(146, 398, 28),
    };
  },
};

function frame(name, t) {
  const s = SCENES[name](t);
  const { dy = 0, sq = 0, rot = 0 } = s.pose;
  const lift = Math.max(0, -dy) / 30;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="${SIZE}" height="${SIZE}">${defs}
  ${s.back || ''}
  <ellipse cx="256" cy="452" rx="${150 * (1 - 0.35 * lift)}" ry="${20 * (1 - 0.35 * lift)}" fill="#0B1A3A" opacity="${0.16 * (1 - 0.4 * lift)}" filter="url(#blur4)"/>
  <g transform="translate(256 ${440 + dy}) rotate(${rot}) scale(${1 + sq} ${1 - sq}) translate(-256 -440)">
    ${s.noSprout ? '' : sprout(t)}
    ${body()}
    ${s.face}
    ${s.front || ''}
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
    const picks = [0, 0.2, 0.4, 0.6, 0.8, 0.95];
    const html = `<html><head><style>${font}body{margin:0;background:#F3F4F9;width:${COLS * SIZE}px}svg{float:left}</style></head><body>${only.map((n) => picks.map((t) => frame(n, t)).join('')).join('')}</body></html>`;
    const p = await b.newPage({ viewport: { width: COLS * SIZE, height: only.length * SIZE } });
    await p.setContent(html);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: process.env.PREVIEW });
    await b.close();
    return;
  }
  fs.mkdirSync(OUT, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pebo-'));
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
