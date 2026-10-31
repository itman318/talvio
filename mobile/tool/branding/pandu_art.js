// Pandu — Talvio's mascot: a chubby panda cub in a Talvio-gradient scarf. Original character,
// sticker-style art (bold outline, cel shading, props that tell a story), rendered to looping animated WebP.
// Usage: node mobile/tool/branding/pandu_art.js                    → mobile/assets/mascot/*.webp
//        PREVIEW=/tmp/x.png ONLY=hide,search PICKS=0,.3,.6 node ...  → contact sheet to look at
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const OUT = process.env.OUT || path.resolve(__dirname, '../../assets/mascot');
const FRAMES = 36; // 3 s at 12 fps
const SIZE = 360;
const TAU = Math.PI * 2;
const sin = Math.sin;
const ease = (x) => 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, x)));
const blinkAt = (t, at = 0.82) => (t > at && t < at + 0.06 ? sin(((t - at) / 0.06) * Math.PI) : 0);
const bounce = (t, n = 2) => Math.abs(sin(t * Math.PI * n)); // 0..1 hops

const O = '#2B1D2E'; // outline
const W = 10;
const DARK = '#2F2A3D';

const defs = `<defs>
<radialGradient id="fur" cx="38%" cy="28%" r="80%"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".7" stop-color="#F7F6FC"/><stop offset="1" stop-color="#E4E2EF"/></radialGradient>
<radialGradient id="dark" cx="35%" cy="25%" r="85%"><stop offset="0" stop-color="#55506A"/><stop offset=".6" stop-color="${DARK}"/><stop offset="1" stop-color="#1D1928"/></radialGradient>
<radialGradient id="iris" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#8A6A55"/><stop offset=".55" stop-color="#4A3226"/><stop offset="1" stop-color="#1A100C"/></radialGradient>
<linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="scarf" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#7B4BE0"/></linearGradient>
<linearGradient id="scarfTail" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2557E"/><stop offset="1" stop-color="#7B4BE0"/></linearGradient>
<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6E9F6"/></linearGradient>
<linearGradient id="metal" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF8A9E"/><stop offset="1" stop-color="#C8366A"/></linearGradient>
<radialGradient id="lens" cx="35%" cy="30%" r="75%"><stop offset="0" stop-color="#E6F7FF"/><stop offset=".45" stop-color="#6CC3F5"/><stop offset="1" stop-color="#1F5FA8"/></radialGradient>
<linearGradient id="mug" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#7EE0B8"/><stop offset="1" stop-color="#22A77E"/></linearGradient>
<linearGradient id="cap" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9DA8FF"/><stop offset="1" stop-color="#5563E0"/></linearGradient>
<linearGradient id="shades" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A3F5C"/><stop offset="1" stop-color="#0E1020"/></linearGradient>
<linearGradient id="bamboo" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#A8E86A"/><stop offset="1" stop-color="#4EA82E"/></linearGradient>
<filter id="b4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
<filter id="b10" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="10"/></filter>
<clipPath id="bodyClip"><path d="M256 140 C 362 140 402 214 400 292 C 398 392 346 452 256 452 C 166 452 114 392 112 292 C 110 214 150 140 256 140 Z"/></clipPath>
</defs>`;

const BODY = 'M256 140 C 362 140 402 214 400 292 C 398 392 346 452 256 452 C 166 452 114 392 112 292 C 110 214 150 140 256 140 Z';

function ears(t, lag = 0) {
  const a = 5 * sin(t * TAU * 2 - 0.8 - lag);
  const ear = (x, r) => `<g transform="rotate(${r} ${x} 190)"><circle cx="${x}" cy="160" r="44" fill="url(#dark)" stroke="${O}" stroke-width="${W}"/><circle cx="${x}" cy="160" r="20" fill="#FF9AB4" opacity=".85"/></g>`;
  return ear(160, -a) + ear(352, a);
}

// eyes sit inside the dark patches
function eyes(o = {}) {
  const { look = [0, 0], lid = 0, happy = false, closed = false, big = 1, wink = false } = o;
  const patch = `<ellipse cx="204" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(-22 204 262)"/>
    <ellipse cx="308" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(22 308 262)"/>`;
  const arc = (x, up) => up
    ? `<path d="M${x - 20} ${266} Q ${x} ${242} ${x + 20} ${266}" stroke="#fff" stroke-width="9" stroke-linecap="round" fill="none"/>`
    : `<path d="M${x - 20} ${262} Q ${x} ${276} ${x + 20} ${262}" stroke="#fff" stroke-width="8" stroke-linecap="round" fill="none"/>`;
  if (happy) return patch + arc(208, true) + arc(304, true);
  if (closed) return patch + arc(208, false) + arc(304, false);
  const one = (x, l) => {
    const open = 1 - l;
    if (open < 0.15) return arc(x, false);
    const [lx, ly] = look;
    return `<g transform="translate(${x} 262) scale(1 ${open}) translate(${-x} -262)">
      <ellipse cx="${x}" cy="262" rx="${27 * big}" ry="${31 * big}" fill="#fff"/>
      <ellipse cx="${x + lx}" cy="${266 + ly}" rx="${18 * big}" ry="${22 * big}" fill="url(#iris)"/>
      <ellipse cx="${x + lx}" cy="${268 + ly}" rx="${9 * big}" ry="${11 * big}" fill="#0B0714"/>
      <ellipse cx="${x + lx - 7 * big}" cy="${256 + ly}" rx="${7 * big}" ry="${9 * big}" fill="#fff"/>
      <circle cx="${x + lx + 8 * big}" cy="${276 + ly}" r="${3.5 * big}" fill="#fff"/></g>`;
  };
  return patch + one(208, lid) + (wink ? arc(304, true) : one(304, lid));
}

function snout(kind = 'smile', t = 0) {
  const nose = `<ellipse cx="256" cy="312" rx="17" ry="11" fill="url(#dark)"/><ellipse cx="250" cy="308" rx="6" ry="3" fill="#fff" opacity=".6"/>`;
  if (kind === 'open') return nose + `<path d="M234 326 Q 256 322 278 326 Q 274 356 256 356 Q 238 356 234 326 Z" fill="#8A2441" stroke="${O}" stroke-width="7" stroke-linejoin="round"/><ellipse cx="256" cy="347" rx="11" ry="6" fill="#FF7A9A"/>`;
  if (kind === 'o') return nose + `<ellipse cx="256" cy="338" rx="10" ry="${12 + 2 * sin(t * TAU * 3)}" fill="#8A2441" stroke="${O}" stroke-width="6"/>`;
  if (kind === 'flat') return nose + `<path d="M242 332 Q 256 328 270 332" stroke="${O}" stroke-width="7" fill="none" stroke-linecap="round"/>`;
  return nose + `<path d="M256 322 L 256 330 M 256 330 Q 244 342 234 332 M 256 330 Q 268 342 278 332" fill="none" stroke="${O}" stroke-width="6" stroke-linecap="round"/>`;
}

const cheeks = (a = 0.65) => `<ellipse cx="160" cy="320" rx="22" ry="12" fill="#FF7FA0" opacity="${a}" filter="url(#b4)"/><ellipse cx="352" cy="320" rx="22" ry="12" fill="#FF7FA0" opacity="${a}" filter="url(#b4)"/>`;

// arm: shoulder → paw, slightly curved. pad = show the pink paw pad (palm towards us)
function arm(sx, sy, hx, hy, o = {}) {
  const { bend = 0, pad = false, r = 0 } = o;
  const mx = (sx + hx) / 2 + bend, my = (sy + hy) / 2;
  return `<path d="M${sx} ${sy} Q ${mx} ${my} ${hx} ${hy}" stroke="${O}" stroke-width="64" stroke-linecap="round" fill="none"/>
    <path d="M${sx} ${sy} Q ${mx} ${my} ${hx} ${hy}" stroke="${DARK}" stroke-width="46" stroke-linecap="round" fill="none"/>
    <g transform="rotate(${r} ${hx} ${hy})"><ellipse cx="${hx}" cy="${hy}" rx="36" ry="30" fill="url(#dark)" stroke="${O}" stroke-width="9"/>
    ${pad ? `<ellipse cx="${hx}" cy="${hy + 6}" rx="13" ry="10" fill="#FF9AB4"/><circle cx="${hx - 16}" cy="${hy - 10}" r="6" fill="#FF9AB4"/><circle cx="${hx}" cy="${hy - 16}" r="6" fill="#FF9AB4"/><circle cx="${hx + 16}" cy="${hy - 10}" r="6" fill="#FF9AB4"/>` : `<path d="M${hx - 18} ${hy - 12} q 12 -10 28 -8" stroke="#8E88A8" stroke-width="5" stroke-linecap="round" fill="none"/>`}</g>`;
}

function scarf(t, wind = 0) {
  const sw = 7 * sin(t * TAU * 2 - 1) + wind;
  return `<path d="M164 360 C 206 384 306 384 348 360 L 352 392 C 306 416 206 416 160 392 Z" fill="url(#scarf)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
    <path d="M186 376 l 4 22 M216 382 l 2 22 M256 386 l 0 22 M296 382 l -2 22 M326 376 l -4 22" stroke="#fff" stroke-opacity=".35" stroke-width="5" stroke-linecap="round"/>
    <path d="M308 392 C ${322 + sw} 420 ${328 + sw} 440 ${338 + sw * 1.5} 458 L ${304 + sw * 1.5} 464 C ${298 + sw} 442 292 418 284 396 Z" fill="url(#scarfTail)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>`;
}

function body(t) {
  return `<path d="${BODY}" fill="url(#fur)"/>
  <g clip-path="url(#bodyClip)">
    <path d="M100 330 C 130 420 180 460 256 460 C 332 460 382 420 412 330 C 362 362 300 374 256 374 C 212 374 150 362 100 330 Z" fill="url(#dark)"/>
    <path d="M400 292 C 398 392 346 452 256 452 C 316 432 362 380 366 300 C 370 240 350 200 330 170 C 376 196 402 240 400 292 Z" fill="#C9C6DB" opacity=".55"/>
    <ellipse cx="196" cy="190" rx="44" ry="22" fill="#fff" transform="rotate(-25 196 190)"/>
  </g>
  <path d="${BODY}" fill="none" stroke="${O}" stroke-width="${W}"/>`;
}

function feet(t, kick = 0) {
  return `<ellipse cx="206" cy="${462 - kick}" rx="42" ry="19" fill="url(#dark)" stroke="${O}" stroke-width="9"/><ellipse cx="206" cy="${462 - kick}" rx="14" ry="8" fill="#FF9AB4" opacity=".8"/>
    <ellipse cx="306" cy="462" rx="42" ry="19" fill="url(#dark)" stroke="${O}" stroke-width="9"/><ellipse cx="306" cy="462" rx="14" ry="8" fill="#FF9AB4" opacity=".8"/>`;
}

function sparkle(x, y, r, color = '#FFC94D', a = 1) {
  if (r < 1) return '';
  return `<path d="M${x} ${y - r} Q ${x} ${y} ${x + r} ${y} Q ${x} ${y} ${x} ${y + r} Q ${x} ${y} ${x - r} ${y} Q ${x} ${y} ${x} ${y - r} Z" fill="${color}" stroke="${O}" stroke-width="3" opacity="${a}"/>`;
}

function panda(s, t) {
  return `${s.behind || ''}
    ${s.noEars ? '' : ears(t)}
    ${s.backArms || ''}
    ${body(t)}
    ${feet(t, s.kick || 0)}
    ${scarf(t, s.wind || 0)}
    ${s.face}
    ${s.front || ''}`;
}

const face = (o = {}) => eyes(o) + cheeks(o.cheeks ?? 0.65) + snout(o.mouth || 'smile', o.t || 0);
const LS = [150, 352], RS = [362, 352];

// ------------------------------------------------------------------ scenes (t: 0..1, loops)
const SCENES = {
  // password: paws (pink pads out) over the eyes, shy sway; one paw slides down to peek, then back
  hide(t) {
    const w = 3 * sin(t * TAU * 2);
    const peek = t > 0.5 && t < 0.85 ? ease((t - 0.5) / 0.1) * (1 - ease((t - 0.75) / 0.1)) : 0;
    return {
      pose: { sq: 0.015 * sin(t * TAU * 2), rot: w * 0.7 },
      face: face({ t, look: [-4, 2], cheeks: 0.9 }),
      front: arm(...LS, 206, 258 + w, { bend: -30, pad: true, r: -10 }) + arm(...RS, 306 + 20 * peek, 258 - w + 62 * peek, { bend: 30, pad: true, r: 10 })
        + sparkle(96, 150, 14 * (0.5 + 0.5 * sin(t * TAU * 2)), '#FF9AB8') + sparkle(424, 190, 10 * (0.5 - 0.5 * sin(t * TAU * 2)), '#FF9AB8'),
    };
  },
  // password shown: one paw down, cheeky side-eye
  peek(t) {
    const w = 3 * sin(t * TAU);
    return {
      pose: { sq: 0.012 * sin(t * TAU), rot: 3 },
      face: face({ t, look: [9, -3], lid: blinkAt(t), cheeks: 0.85 }),
      front: arm(...LS, 206, 258 + w, { bend: -30, pad: true, r: -10 }) + arm(...RS, 392, 410, { bend: 10 }),
    };
  },
  // nothing found: binoculars, turning to scan left and right
  search(t) {
    const a = sin(t * TAU);
    const bx = 256 + 16 * a;
    return {
      pose: { sq: 0.012, rot: 6 * a, dy: -4 * bounce(t, 2) },
      face: snout('o', t) + cheeks(0.6) + `<ellipse cx="204" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(-22 204 262)"/><ellipse cx="308" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(22 308 262)"/>`,
      front: arm(...LS, bx - 64, 300, { bend: -20 }) + arm(...RS, bx + 64, 300, { bend: 20 })
        + `<g transform="translate(${bx} 258) rotate(${5 * a})">
          <rect x="-18" y="-16" width="36" height="28" rx="9" fill="url(#metal)" stroke="${O}" stroke-width="8"/>
          <rect x="-90" y="-40" width="72" height="80" rx="24" fill="url(#metal)" stroke="${O}" stroke-width="${W}"/>
          <rect x="18" y="-40" width="72" height="80" rx="24" fill="url(#metal)" stroke="${O}" stroke-width="${W}"/>
          <circle cx="-54" cy="-2" r="27" fill="url(#lens)" stroke="${O}" stroke-width="7"/>
          <circle cx="54" cy="-2" r="27" fill="url(#lens)" stroke="${O}" stroke-width="7"/>
          <path d="M-68 -14 a 15 15 0 0 1 13 -11 M40 -14 a 15 15 0 0 1 13 -11" stroke="#fff" stroke-width="6" stroke-linecap="round" fill="none" opacity="${0.5 + 0.5 * Math.abs(a)}"/>
          <path d="M-60 40 q 0 20 -10 30 M60 40 q 0 20 10 30" stroke="${O}" stroke-width="5" fill="none"/>
        </g>`,
    };
  },
  // code sent: holds up a sealed letter with a hop, sparkles
  mail(t) {
    const hop = bounce(t, 2);
    const sp = [0, 1, 2].map((i) => { const p = (t * 1.5 + i / 3) % 1; return sparkle([96, 416, 430][i], [140, 110, 300][i] - 26 * p, 20 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: -16 * hop, sq: -0.03 * hop + 0.02 },
      behind: sp,
      face: face({ t, look: [0, -4], lid: blinkAt(t), mouth: 'open' }),
      front: `<g transform="translate(256 ${408 - 8 * hop}) rotate(${4 * sin(t * TAU)})">
          <rect x="-96" y="-62" width="192" height="124" rx="16" fill="url(#paper)" stroke="${O}" stroke-width="${W}"/>
          <path d="M-90 -54 L 0 14 L 90 -54" fill="none" stroke="${O}" stroke-width="8" stroke-linejoin="round"/>
          <path d="M-90 56 L -30 4 M 90 56 L 30 4" stroke="#B9BFD8" stroke-width="6" stroke-linecap="round"/>
          <circle cx="0" cy="12" r="24" fill="url(#brand)" stroke="${O}" stroke-width="6"/>
          <path d="M0 23 c -13 -8 -15 -17 -8 -21 c 4 -2 6.5 0 8 2.6 c 1.5 -2.6 4 -4.6 8 -2.6 c 7 4 5 13 -8 21 z" fill="#fff"/>
        </g>` + arm(...LS, 168, 392 - 8 * hop, { bend: -10 }) + arm(...RS, 344, 392 - 8 * hop, { bend: 10 }),
    };
  },
  // hello: big wave, body sways, ears bob
  wave(t) {
    const w = sin(t * TAU * 3);
    return {
      pose: { sq: 0.02 * sin(t * TAU * 2), rot: 3 * sin(t * TAU) },
      face: face({ t, look: [5, 0], lid: blinkAt(t), mouth: 'open' }),
      front: arm(...LS, 156, 418, { bend: -10 }) + arm(...RS, 432 + 18 * w, 214 - 6 * Math.abs(w), { bend: 26, pad: true, r: 20 * w })
        + `<path d="M478 166 q 14 14 8 34 M494 146 q 24 22 16 54" stroke="${O}" stroke-width="7" fill="none" stroke-linecap="round" opacity="${0.3 + 0.6 * Math.abs(w)}"/>`,
      wind: 5 * w,
    };
  },
  // thinking: paw on chin, eyes up, bulb flickers then lights
  think(t) {
    const on = t > 0.5 ? Math.min(1, (t - 0.5) / 0.08) : (t > 0.42 && t < 0.46 ? 0.6 : 0);
    const bob = 4 * sin(t * TAU * 2);
    return {
      pose: { rot: 6, sq: 0.012 * sin(t * TAU), dy: on > 0.5 ? -6 * bounce((t - 0.5) * 2, 1) : 0 },
      behind: `<g transform="translate(410 ${96 + bob})">
          <circle r="${50 + 14 * on}" fill="#FFE07A" opacity="${0.5 * on}" filter="url(#b10)"/>
          <path d="M0 -40 C 25 -40 38 -22 38 -2 C 38 16 25 24 20 38 L -20 38 C -25 24 -38 16 -38 -2 C -38 -22 -25 -40 0 -40 Z" fill="${on > 0.5 ? '#FFE07A' : '#F2F4FA'}" stroke="${O}" stroke-width="8"/>
          <rect x="-18" y="38" width="36" height="20" rx="6" fill="#9AA3BD" stroke="${O}" stroke-width="6"/>
          ${on > 0.5 ? '<path d="M-56 -42 l -12 -10 M 56 -42 l 12 -10 M 0 -56 l 0 -14 M-62 0 l -16 0 M62 0 l 16 0" stroke="#F6B532" stroke-width="7" stroke-linecap="round"/>' : ''}
        </g>`,
      face: face({ t, look: [9, -11], lid: blinkAt(t, 0.2), mouth: on > 0.5 ? 'open' : 'flat', cheeks: 0.5 }),
      front: arm(...LS, 156, 418, { bend: -10 }) + arm(...RS, 286, 352, { bend: 40 }),
    };
  },
  // all quiet: dozing in a night cap; breathing, bubble, z's
  sleep(t) {
    const br = sin(t * TAU);
    const zs = [0, 1, 2].map((i) => { const p = (t + i / 3) % 1; return `<text x="${370 + 70 * p}" y="${150 - 100 * p}" font-family="Jakarta" font-weight="800" font-size="${32 + 36 * p}" fill="#8E98FF" stroke="${O}" stroke-width="3" opacity="${(1 - p) * 0.95}">z</text>`; }).join('');
    return {
      pose: { sq: 0.04 * br, rot: -6 },
      noEars: true,
      face: face({ t, closed: true, cheeks: 0.75, mouth: 'flat' }) + `<circle cx="288" cy="${336 + 2 * br}" r="${9 + 8 * Math.max(0, br)}" fill="#D6F0FF" stroke="#6FA8D0" stroke-width="4" opacity=".9"/>`,
      front: `<path d="M140 196 C 166 110 320 92 372 158 C 404 158 436 178 446 222 C 420 198 392 190 370 198 C 322 170 206 170 140 196 Z" fill="url(#cap)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
        <path d="M142 196 C 216 166 316 168 370 198" stroke="#fff" stroke-width="24" stroke-linecap="round" fill="none"/>
        <circle cx="448" cy="232" r="22" fill="#fff" stroke="${O}" stroke-width="7"/>
        <circle cx="236" cy="150" r="6" fill="#fff" opacity=".8"/><circle cx="300" cy="138" r="5" fill="#fff" opacity=".8"/>`
        + arm(...LS, 220, 420, { bend: -20 }) + arm(...RS, 292, 420, { bend: 20 }) + zs,
    };
  },
  // success / Plus: big jumps with confetti and a party hat
  celebrate(t) {
    const hop = bounce(t, 2);
    const conf = Array.from({ length: 24 }, (_, i) => {
      const r = (k) => ((Math.sin(i * 12.9898 + k * 78.233) * 43758.5453) % 1 + 1) % 1;
      const p = (t * (0.8 + r(1) * 0.6) + r(2)) % 1;
      const x = 20 + r(3) * 472 + 16 * sin(p * 9 + i), y = -20 + 540 * p;
      const c = ['#FF5E8A', '#FFC94D', '#8E54E9', '#3CC8FF', '#2ED47A', '#FF8A3D'][i % 6];
      return `<rect x="-9" y="-5" width="18" height="10" rx="2" fill="${c}" stroke="${O}" stroke-width="2" transform="translate(${x} ${y}) rotate(${p * 720 + i * 40})"/>`;
    }).join('');
    return {
      pose: { dy: -40 * hop, sq: hop < 0.2 ? 0.06 : -0.04 * hop },
      kick: 10 * hop,
      face: face({ t, happy: true, mouth: 'open', cheeks: 0.85 }),
      front: arm(...LS, 96, 222 + 16 * (1 - hop), { bend: -24, pad: true, r: -20 }) + arm(...RS, 416, 222 + 16 * (1 - hop), { bend: 24, pad: true, r: 20 })
        + `<g transform="rotate(-14 300 120)"><path d="M250 158 L 306 40 L 356 158 Z" fill="url(#brand)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M266 124 L 340 124 M282 90 L 326 90" stroke="#FFE07A" stroke-width="9" stroke-linecap="round"/>
          <circle cx="306" cy="40" r="17" fill="#FFE07A" stroke="${O}" stroke-width="7"/></g>`,
      over: conf,
    };
  },
  // cool / unlocked: shades with a glint, nodding to a beat, thumbs up
  cool(t) {
    const g = (t * 1.2) % 1;
    const nod = Math.abs(sin(t * TAU * 2));
    const sp = [0, 1].map((i) => { const p = (t * 1.4 + i / 2) % 1; return sparkle([96, 430][i], [170, 230][i], 22 * sin(p * Math.PI)); }).join('');
    return {
      pose: { dy: 6 * nod, sq: 0.02 * nod, rot: 3 * sin(t * TAU) },
      behind: sp,
      face: `<ellipse cx="204" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(-22 204 262)"/><ellipse cx="308" cy="262" rx="46" ry="52" fill="url(#dark)" transform="rotate(22 308 262)"/>`
        + cheeks(0.5) + `<ellipse cx="256" cy="312" rx="17" ry="11" fill="url(#dark)"/><path d="M236 330 Q 262 352 284 324" fill="none" stroke="${O}" stroke-width="7" stroke-linecap="round"/>
        <rect x="150" y="228" width="100" height="66" rx="24" fill="url(#shades)" stroke="${O}" stroke-width="7"/>
        <rect x="262" y="228" width="100" height="66" rx="24" fill="url(#shades)" stroke="${O}" stroke-width="7"/>
        <path d="M248 248 Q 256 240 264 248" stroke="${O}" stroke-width="10" fill="none"/>
        <path d="M150 244 L 118 232 M362 244 L 394 232" stroke="${O}" stroke-width="9" stroke-linecap="round"/>
        <clipPath id="lensC"><rect x="150" y="228" width="100" height="66" rx="24"/><rect x="262" y="228" width="100" height="66" rx="24"/></clipPath>
        <g clip-path="url(#lensC)"><path d="M${110 + 320 * g} 300 L ${154 + 320 * g} 220" stroke="#fff" stroke-width="18" opacity=".55"/><path d="M${136 + 320 * g} 300 L ${168 + 320 * g} 220" stroke="#fff" stroke-width="6" opacity=".45"/></g>`,
      front: arm(...LS, 156, 418, { bend: -10 }) + arm(...RS, 410, 300 - 4 * nod, { bend: 20 })
        + `<g transform="translate(410 ${270 - 4 * nod})"><rect x="-12" y="-46" width="24" height="40" rx="12" fill="url(#dark)" stroke="${O}" stroke-width="8"/></g>`,
    };
  },
  // bots / a break: sipping bamboo tea, steam curls, happy eyes
  coffee(t) {
    const sip = t > 0.4 && t < 0.7 ? ease((t - 0.4) / 0.1) * (1 - ease((t - 0.6) / 0.1)) : 0;
    const my = 404 - 40 * sip, mx = 316 - 30 * sip;
    const steam = [0, 1].map((i) => { const p = (t + i / 2) % 1; return `<path d="M${mx + 64 + i * 24} ${my - 50 - 60 * p} q -16 -18 0 -36 q 16 -18 0 -36" stroke="#C9CEE0" stroke-width="8" fill="none" stroke-linecap="round" opacity="${1 - p}"/>`; }).join('');
    return {
      pose: { dy: 2 * sin(t * TAU), sq: 0.015 * sin(t * TAU), rot: -3 + 4 * sip },
      face: face({ t, happy: true, cheeks: 0.8 }),
      front: steam + arm(...LS, 156, 418, { bend: -10 }) + `<g transform="translate(${mx} ${my}) rotate(${-24 * sip})"><path d="M-46 -40 L 46 -40 L 40 46 Q 38 60 24 60 L -24 60 Q -38 60 -40 46 Z" fill="url(#mug)" stroke="${O}" stroke-width="${W}" stroke-linejoin="round"/>
          <path d="M46 -20 q 36 0 34 30 q -2 26 -38 24" stroke="${O}" stroke-width="10" fill="none"/>
          <ellipse cx="0" cy="-40" rx="46" ry="10" fill="#7BB84A" stroke="${O}" stroke-width="7"/>
          <path d="M-24 0 l 0 40 M-24 10 q 14 -10 22 -2" stroke="#fff" stroke-width="6" stroke-linecap="round" fill="none" opacity=".8"/></g>`
        + arm(...RS, mx - 34, my + 10, { bend: 20 }),
    };
  },
};

function frame(name, t) {
  const s = SCENES[name](t);
  const { dy = 0, sq = 0, rot = 0 } = s.pose;
  const lift = Math.max(0, -dy) / 40;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="${SIZE}" height="${SIZE}">${defs}
  <g transform="translate(256 256) scale(.92) translate(-256 -256)">
  <ellipse cx="256" cy="482" rx="${140 * (1 - 0.35 * lift)}" ry="${16 * (1 - 0.35 * lift)}" fill="#1A1430" opacity="${0.18 * (1 - 0.45 * lift)}" filter="url(#b4)"/>
  <g transform="translate(256 ${478 + dy}) rotate(${rot}) scale(${1 + sq} ${1 - sq}) translate(-256 -478)">
    ${panda(s, t)}
  </g>
  ${s.over || ''}
  </g>
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
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pandu-'));
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
