// "Tali the Fox" — Talvio's official sticker pack (512×512 transparent PNG, Telegram-style character stickers).
// Usage: node mobile/tool/branding/fox_stickers.js            (uses playwright, or CHROME=/path/to/chrome)
//        PREVIEW=1 node ...                                   (only writes the HTML/SVG files to OUT_TMP)
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const OUT = process.env.OUT || path.resolve(__dirname, '../../../backend/assets/stickers/talvio-fox');

// ------------------------------------------------------------------ palette
const P = {
  fur: ['#FFB27F', '#FF7A47', '#E4532C'], // highlight → base → shade
  cream: ['#FFFFFF', '#FFF1E4', '#F6D9C2'],
  ink: '#2A1F2D',
  inner: '#FF9DB0',
  blush: '#FF6F91',
  heart: ['#FF8FB1', '#F0386B'],
  gold: ['#FFE08A', '#F5B022'],
  blue: ['#9ED8FF', '#3C9BEA'],
  mint: ['#8FF0D4', '#18B892'],
};

const defs = `
<defs>
  <radialGradient id="fur" cx="38%" cy="28%" r="80%"><stop offset="0" stop-color="${P.fur[0]}"/><stop offset=".55" stop-color="${P.fur[1]}"/><stop offset="1" stop-color="${P.fur[2]}"/></radialGradient>
  <radialGradient id="furB" cx="40%" cy="20%" r="90%"><stop offset="0" stop-color="${P.fur[0]}"/><stop offset=".5" stop-color="${P.fur[1]}"/><stop offset="1" stop-color="${P.fur[2]}"/></radialGradient>
  <linearGradient id="furDark" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F0683A"/><stop offset="1" stop-color="#C9441F"/></linearGradient>
  <radialGradient id="cream" cx="45%" cy="30%" r="80%"><stop offset="0" stop-color="${P.cream[0]}"/><stop offset=".6" stop-color="${P.cream[1]}"/><stop offset="1" stop-color="${P.cream[2]}"/></radialGradient>
  <radialGradient id="eye" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#5A4256"/><stop offset="1" stop-color="${P.ink}"/></radialGradient>
  <linearGradient id="heart" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${P.heart[0]}"/><stop offset="1" stop-color="${P.heart[1]}"/></linearGradient>
  <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.gold[0]}"/><stop offset="1" stop-color="${P.gold[1]}"/></linearGradient>
  <linearGradient id="blue" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.blue[0]}"/><stop offset="1" stop-color="${P.blue[1]}"/></linearGradient>
  <linearGradient id="mint" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${P.mint[0]}"/><stop offset="1" stop-color="${P.mint[1]}"/></linearGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B3150"/><stop offset="1" stop-color="#151022"/></linearGradient>
  <linearGradient id="tear" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#CFF0FF"/><stop offset="1" stop-color="#5BB8F5"/></linearGradient>
  <filter id="sticker" x="-20%" y="-20%" width="140%" height="140%">
    <feMorphology in="SourceAlpha" operator="dilate" radius="9" result="d"/>
    <feGaussianBlur in="d" stdDeviation="1.2" result="db"/>
    <feFlood flood-color="#ffffff"/>
    <feComposite in2="db" operator="in" result="outline"/>
    <feGaussianBlur in="d" stdDeviation="7" result="sb"/>
    <feOffset in="sb" dy="7" result="so"/>
    <feFlood flood-color="#2A1F2D" flood-opacity=".28"/>
    <feComposite in2="so" operator="in" result="shadow"/>
    <feMerge><feMergeNode in="shadow"/><feMergeNode in="outline"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>`;

// ------------------------------------------------------------------ parts
const ln = (d, w = 7, c = P.ink) => `<path d="${d}" fill="none" stroke="${c}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`;
const gloss = (cx, cy, r = 7) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="#fff"/><circle cx="${cx + r * 1.5}" cy="${cy + r * 1.6}" r="${r * 0.45}" fill="#fff" opacity=".85"/>`;

function tail(kind = 'right') {
  if (kind === 'none') return '';
  const flip = kind === 'left' ? 'translate(512 0) scale(-1 1)' : '';
  return `<g transform="${flip}">
    <path d="M338 410 C420 420 470 360 452 290 C440 245 400 230 392 262 C386 290 410 300 404 336 C398 372 360 380 330 372 Z" fill="url(#furB)"/>
    <path d="M452 290 C440 245 400 230 392 262 C388 280 398 290 402 304 C420 300 440 300 452 290 Z" fill="url(#cream)"/>
  </g>`;
}

function body() {
  return `
  <ellipse cx="256" cy="392" rx="112" ry="92" fill="url(#furB)"/>
  <ellipse cx="256" cy="404" rx="66" ry="66" fill="url(#cream)"/>
  <ellipse cx="206" cy="470" rx="40" ry="22" fill="url(#furDark)"/>
  <ellipse cx="306" cy="470" rx="40" ry="22" fill="url(#furDark)"/>
  <ellipse cx="200" cy="474" rx="22" ry="11" fill="#FFE3CF"/>
  <ellipse cx="312" cy="474" rx="22" ry="11" fill="#FFE3CF"/>`;
}

function ears(kind = 'up') {
  const droop = kind === 'down';
  const L = droop
    ? 'M128 196 C88 180 58 132 70 104 C112 108 154 132 176 158 Z'
    : 'M136 170 C118 120 120 70 140 46 C176 66 206 104 216 136 Z';
  const Li = droop ? 'M126 182 C100 168 84 140 88 122 C114 126 142 142 158 160 Z' : 'M150 150 C140 116 142 86 152 70 C174 86 192 110 200 132 Z';
  const mirror = (d) => d.replace(/(\d+(?:\.\d+)?) (\d+(?:\.\d+)?)/g, (_, x, y) => `${512 - Number(x)} ${y}`);
  return `
  <path d="${L}" fill="url(#fur)"/><path d="${Li}" fill="${P.inner}" opacity=".85"/><path d="${L.replace(/C.*$/, '')}" fill="none"/>
  <path d="${mirror(L)}" fill="url(#fur)"/><path d="${mirror(Li)}" fill="${P.inner}" opacity=".85"/>
  <path d="${droop ? 'M70 104 C78 98 92 100 100 104 C90 108 80 110 70 104Z' : 'M140 46 C146 52 150 62 150 70 C146 64 142 56 140 46Z'}" fill="${P.ink}" opacity=".85"/>
  <path d="${mirror(droop ? 'M70 104 C78 98 92 100 100 104 C90 108 80 110 70 104Z' : 'M140 46 C146 52 150 62 150 70 C146 64 142 56 140 46Z')}" fill="${P.ink}" opacity=".85"/>`;
}

function head() {
  return `
  <path d="M256 92 C352 92 412 150 414 222 C416 266 396 300 360 322 C330 340 296 348 256 348 C216 348 182 340 152 322 C116 300 96 266 98 222 C100 150 160 92 256 92 Z" fill="url(#fur)"/>
  <path d="M98 232 C86 246 80 262 84 280 C98 274 110 270 122 270 Z" fill="url(#fur)"/>
  <path d="M414 232 C426 246 432 262 428 280 C414 274 402 270 390 270 Z" fill="url(#fur)"/>
  <path d="M256 258 C240 226 214 206 182 204 C148 202 118 222 104 252 C100 262 98 272 100 282 C116 306 140 326 170 338 C196 346 226 350 256 350 C286 350 316 346 342 338 C372 326 396 306 412 282 C414 272 412 262 408 252 C394 222 364 202 330 204 C298 206 272 226 256 258 Z" fill="url(#cream)"/>
  <path d="M232 132 C244 124 268 124 280 132" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="8" stroke-linecap="round"/>`;
}

const EYES = {
  normal: `<ellipse cx="200" cy="232" rx="21" ry="26" fill="url(#eye)"/><ellipse cx="312" cy="232" rx="21" ry="26" fill="url(#eye)"/>${gloss(193, 222)}${gloss(305, 222)}`,
  big: `<ellipse cx="200" cy="230" rx="27" ry="32" fill="url(#eye)"/><ellipse cx="312" cy="230" rx="27" ry="32" fill="url(#eye)"/>${gloss(190, 216, 10)}${gloss(302, 216, 10)}`,
  happy: ln('M178 238 Q200 212 222 238', 9) + ln('M290 238 Q312 212 334 238', 9),
  laugh: ln('M178 222 L214 236 L178 250', 9) + ln('M334 222 L298 236 L334 250', 9),
  closed: ln('M178 232 Q200 250 222 232', 8) + ln('M290 232 Q312 250 334 232', 8),
  wink: ln('M178 238 Q200 212 222 238', 9) + `<ellipse cx="312" cy="232" rx="21" ry="26" fill="url(#eye)"/>${gloss(305, 222)}`,
  heart: [200, 312].map((x) => `<path d="M${x} 254 C${x - 40} 228 ${x - 26} 196 ${x} 214 C${x + 26} 196 ${x + 40} 228 ${x} 254 Z" fill="url(#heart)"/><circle cx="${x - 12}" cy="218" r="5" fill="#fff" opacity=".9"/>`).join(''),
  star: [200, 312].map((x) => `<path d="M${x} 200 L${x + 9} 222 L${x + 32} 224 L${x + 14} 238 L${x + 20} 261 L${x} 248 L${x - 20} 261 L${x - 14} 238 L${x - 32} 224 L${x - 9} 222 Z" fill="url(#gold)" stroke="#E39A12" stroke-width="3" stroke-linejoin="round"/>`).join(''),
  sad: `<ellipse cx="200" cy="236" rx="24" ry="28" fill="url(#eye)"/><ellipse cx="312" cy="236" rx="24" ry="28" fill="url(#eye)"/>${gloss(192, 224, 9)}${gloss(304, 224, 9)}` + ln('M172 196 Q192 188 218 200', 7) + ln('M340 196 Q320 188 294 200', 7),
  angry: `<ellipse cx="200" cy="238" rx="19" ry="21" fill="url(#eye)"/><ellipse cx="312" cy="238" rx="19" ry="21" fill="url(#eye)"/>${gloss(194, 230, 6)}${gloss(306, 230, 6)}` + ln('M170 206 L224 222', 10) + ln('M342 206 L288 222', 10),
  sleepy: ln('M178 238 Q200 246 222 238', 8) + ln('M290 238 Q312 246 334 238', 8),
  surprised: `<circle cx="200" cy="230" r="27" fill="#fff" stroke="${P.ink}" stroke-width="6"/><circle cx="312" cy="230" r="27" fill="#fff" stroke="${P.ink}" stroke-width="6"/><circle cx="200" cy="232" r="11" fill="${P.ink}"/><circle cx="312" cy="232" r="11" fill="${P.ink}"/>`,
  think: `<ellipse cx="200" cy="236" rx="19" ry="23" fill="url(#eye)"/><ellipse cx="312" cy="232" rx="19" ry="23" fill="url(#eye)"/>${gloss(194, 228, 6)}${gloss(306, 224, 6)}` + ln('M290 190 Q314 178 338 190', 8) + ln('M178 208 L222 212', 7),
  side: `<ellipse cx="208" cy="234" rx="19" ry="24" fill="url(#eye)"/><ellipse cx="320" cy="234" rx="19" ry="24" fill="url(#eye)"/>${gloss(204, 224, 6)}${gloss(316, 224, 6)}`,
  pleading: `<ellipse cx="200" cy="230" rx="30" ry="34" fill="url(#eye)"/><ellipse cx="312" cy="230" rx="30" ry="34" fill="url(#eye)"/>${gloss(189, 214, 11)}${gloss(301, 214, 11)}<circle cx="212" cy="246" r="4" fill="#fff" opacity=".7"/><circle cx="324" cy="246" r="4" fill="#fff" opacity=".7"/>` + ln('M168 190 Q188 184 214 194', 6) + ln('M344 190 Q324 184 298 194', 6),
  glasses: `<path d="M160 214 H352 V222 H160 Z" fill="${P.ink}"/><path d="M162 216 H244 C246 250 228 264 204 264 C178 264 162 248 162 216 Z" fill="url(#glass)"/><path d="M268 216 H350 C350 248 334 264 308 264 C284 264 266 250 268 216 Z" fill="url(#glass)"/><path d="M180 226 L200 226 L186 246 Z" fill="#fff" opacity=".35"/><path d="M286 226 L306 226 L292 246 Z" fill="#fff" opacity=".35"/>`,
};

const NOSE = `<path d="M244 262 C244 254 268 254 268 262 C268 270 260 276 256 276 C252 276 244 270 244 262 Z" fill="${P.ink}"/><ellipse cx="251" cy="260" rx="5" ry="3" fill="#fff" opacity=".6"/>`;

const MOUTH = {
  smile: ln('M230 284 Q243 298 256 284 Q269 298 282 284', 6),
  grin: `<path d="M222 284 Q256 284 290 284 Q286 326 256 328 Q226 326 222 284 Z" fill="#7A2335"/><path d="M234 312 Q256 298 278 312 Q270 326 256 327 Q242 326 234 312 Z" fill="#FF7A8F"/>` + ln('M222 284 Q256 284 290 284', 5),
  open: `<ellipse cx="256" cy="300" rx="22" ry="20" fill="#7A2335"/><ellipse cx="256" cy="310" rx="13" ry="8" fill="#FF7A8F"/>`,
  o: `<ellipse cx="256" cy="302" rx="14" ry="18" fill="#7A2335"/>`,
  frown: ln('M232 304 Q256 284 280 304', 6),
  wobbly: ln('M226 302 Q236 292 246 302 Q256 312 266 302 Q276 292 286 302', 6),
  flat: ln('M238 294 H274', 6),
  smirk: ln('M236 292 Q262 302 284 284', 6),
  tongue: ln('M230 284 Q243 298 256 284 Q269 298 282 284', 6) + `<path d="M260 292 Q262 318 276 318 Q290 316 286 292 Z" fill="#FF7A8F" stroke="${P.ink}" stroke-width="4"/>`,
  kiss: ln('M250 284 Q262 290 252 296 Q264 302 250 308', 6),
  tiny: ln('M248 290 Q256 296 264 290', 5),
  shout: `<path d="M228 286 Q256 280 284 286 Q290 320 256 326 Q222 320 228 286 Z" fill="#7A2335"/><path d="M236 312 Q256 302 276 312 Q268 324 256 325 Q244 324 236 312 Z" fill="#FF7A8F"/>`,
};

const BLUSH = `<ellipse cx="166" cy="276" rx="22" ry="12" fill="${P.blush}" opacity=".45"/><ellipse cx="346" cy="276" rx="22" ry="12" fill="${P.blush}" opacity=".45"/>`;
const BLUSH_BIG = `<ellipse cx="166" cy="274" rx="28" ry="16" fill="${P.blush}" opacity=".7"/><ellipse cx="346" cy="274" rx="28" ry="16" fill="${P.blush}" opacity=".7"/>` + [156, 166, 176, 336, 346, 356].map((x) => ln(`M${x} 268 l-5 10`, 3, '#E0417A')).join('');

// arms: a capsule from shoulder to paw
function arm(x1, y1, x2, y2, paw = true) {
  const tip = paw === 'fur' ? `<circle cx="${x2}" cy="${y2}" r="24" fill="url(#furDark)"/><path d="M${x2 - 10} ${y2 - 18} v10 M${x2 + 2} ${y2 - 20} v10" stroke="#B83A1A" stroke-width="4" stroke-linecap="round"/>` : paw ? `<circle cx="${x2}" cy="${y2}" r="21" fill="url(#cream)"/>` : '';
  return `<path d="M${x1} ${y1} L${x2} ${y2}" stroke="url(#furDark)" stroke-width="40" stroke-linecap="round"/>` + tip;
}
const ARMS = {
  rest: arm(170, 360, 182, 412) + arm(342, 360, 330, 412),
  thumb: arm(170, 360, 182, 412) + arm(342, 356, 388, 336, false),
  wave: arm(170, 360, 182, 412) + arm(350, 352, 408, 280) + ln('M436 248 q12 -8 20 -2', 6, '#FFB27F') + ln('M440 276 q14 -2 20 6', 6, '#FFB27F'),
  hug: arm(170, 352, 220, 404) + arm(342, 352, 292, 404),
  pray: arm(176, 356, 246, 372) + arm(336, 356, 266, 372),
  chin: arm(170, 360, 182, 412) + arm(342, 352, 296, 318),
  cover: arm(186, 356, 168, 290, 'fur') + arm(326, 356, 344, 290, 'fur'),
  up: arm(168, 350, 112, 284) + arm(344, 350, 400, 284),
  cup: arm(170, 352, 228, 396) + arm(342, 352, 290, 396),
};

// props drawn in front
const PROPS = {
  heart: `<g transform="translate(256 400)"><path d="M0 52 C-86 0 -60 -64 0 -28 C60 -64 86 0 0 52 Z" fill="url(#heart)"/><path d="M-38 -26 C-30 -40 -14 -40 -8 -32" fill="none" stroke="#fff" stroke-width="8" stroke-linecap="round" opacity=".8"/></g>`,
  smallHeart: `<g transform="translate(400 150) rotate(14)"><path d="M0 26 C-44 0 -30 -32 0 -14 C30 -32 44 0 0 26 Z" fill="url(#heart)"/></g>`,
  tears: `<path d="M178 256 C170 290 168 330 176 360" stroke="url(#tear)" stroke-width="16" fill="none" stroke-linecap="round" opacity=".9"/><path d="M334 256 C342 290 344 330 336 360" stroke="url(#tear)" stroke-width="16" fill="none" stroke-linecap="round" opacity=".9"/>`,
  joyTears: `<path d="M150 236 q-24 10 -30 34 q18 4 30 -10 z" fill="url(#tear)"/><path d="M362 236 q24 10 30 34 q-18 4 -30 -10 z" fill="url(#tear)"/>`,
  tearDrop: `<path d="M330 260 q-12 22 0 32 q12 -10 0 -32 z" fill="url(#tear)" stroke="#fff" stroke-width="3"/>`,
  zzz: `<text x="372" y="140" font-family="Jakarta" font-weight="800" font-size="62" fill="#8E7CF8" stroke="#fff" stroke-width="10" paint-order="stroke">Z</text><text x="420" y="96" font-family="Jakarta" font-weight="800" font-size="42" fill="#8E7CF8" stroke="#fff" stroke-width="8" paint-order="stroke">z</text><text x="450" y="64" font-family="Jakarta" font-weight="800" font-size="28" fill="#8E7CF8" stroke="#fff" stroke-width="6" paint-order="stroke">z</text>`,
  nightcap: `<path d="M150 150 C190 70 300 60 350 120 C320 112 250 110 150 150 Z" fill="#6C5BE3"/><path d="M350 120 C390 120 420 150 430 190" stroke="#6C5BE3" stroke-width="26" stroke-linecap="round" fill="none"/><circle cx="432" cy="196" r="22" fill="#fff"/><path d="M146 156 C210 120 300 112 356 124" stroke="#fff" stroke-width="20" stroke-linecap="round" fill="none"/>`,
  partyHat: `<g transform="rotate(-14 256 100)"><path d="M210 128 L256 18 L302 128 Z" fill="url(#mint)"/><path d="M226 92 L286 92 M238 62 L274 62" stroke="#FFE08A" stroke-width="10"/><circle cx="256" cy="18" r="16" fill="url(#gold)"/><path d="M204 128 Q256 140 308 128" stroke="#fff" stroke-width="10" stroke-linecap="round"/></g>`,
  confetti: `<rect x="70" y="120" width="22" height="14" rx="4" fill="#6C5BE3" transform="rotate(30 81 127)"/><rect x="430" y="210" width="22" height="14" rx="4" fill="#18B892" transform="rotate(-24 441 217)"/><circle cx="96" cy="300" r="10" fill="#F5B022"/><circle cx="420" cy="320" r="9" fill="#F0386B"/><rect x="60" y="210" width="18" height="12" rx="3" fill="#F0386B" transform="rotate(-40 69 216)"/><rect x="440" y="120" width="18" height="12" rx="3" fill="#F5B022" transform="rotate(40 449 126)"/><path d="M110 80 q10 14 0 26 q-10 12 0 26" stroke="#3C9BEA" stroke-width="6" fill="none" stroke-linecap="round"/><path d="M410 380 q12 10 4 24" stroke="#6C5BE3" stroke-width="6" fill="none" stroke-linecap="round"/>`,
  sparkles: [[100, 140, 1], [420, 120, 0.8], [440, 300, 0.6], [80, 320, 0.55]].map(([x, y, s]) => `<path transform="translate(${x} ${y}) scale(${s})" d="M0 -30 C4 -8 8 -4 30 0 C8 4 4 8 0 30 C-4 8 -8 4 -30 0 C-8 -4 -4 -8 0 -30 Z" fill="url(#gold)"/>`).join(''),
  bang: `<g transform="translate(410 120) rotate(12)"><rect x="-12" y="-46" width="24" height="64" rx="12" fill="#F0386B"/><circle cx="0" cy="40" r="13" fill="#F0386B"/></g><g transform="translate(450 170) rotate(24) scale(.7)"><rect x="-12" y="-46" width="24" height="64" rx="12" fill="#F0386B"/><circle cx="0" cy="40" r="13" fill="#F0386B"/></g>`,
  steam: `<path d="M110 120 c-20 -10 -10 -40 14 -36 c0 -24 34 -28 40 -6 c22 -6 34 22 16 34 c10 18 -14 32 -28 22 c-12 14 -40 6 -42 -14 z" fill="#fff" stroke="#E4D7E4" stroke-width="4"/><path d="M402 120 c20 -10 10 -40 -14 -36 c0 -24 -34 -28 -40 -6 c-22 -6 -34 22 -16 34 c-10 18 14 32 28 22 c12 14 40 6 42 -14 z" fill="#fff" stroke="#E4D7E4" stroke-width="4"/><path d="M190 168 l-14 -10 M322 168 l14 -10" stroke="#F0386B" stroke-width="6" stroke-linecap="round"/>`,
  angerMark: `<g transform="translate(380 130)" stroke="#F0386B" stroke-width="10" stroke-linecap="round" fill="none"><path d="M-24 -8 q12 0 12 -14"/><path d="M8 -22 q0 12 14 12"/><path d="M22 10 q-12 0 -12 14"/><path d="M-10 24 q0 -12 -14 -12"/></g>`,
  thought: `<circle cx="372" cy="150" r="10" fill="#fff" stroke="#D9CFE0" stroke-width="4"/><circle cx="398" cy="118" r="15" fill="#fff" stroke="#D9CFE0" stroke-width="4"/><ellipse cx="442" cy="72" rx="44" ry="32" fill="#fff" stroke="#D9CFE0" stroke-width="4"/><text x="442" y="88" text-anchor="middle" font-family="Jakarta" font-weight="800" font-size="44" fill="#6C5BE3">?</text>`,
  cup: `<g transform="translate(256 400)"><path d="M-46 -34 H46 L38 34 Q36 48 22 48 H-22 Q-36 48 -38 34 Z" fill="#fff" stroke="#E4D7E4" stroke-width="4"/><path d="M-46 -34 H46 L44 -14 H-44 Z" fill="#8A5A3C"/><path d="M44 -20 q34 0 30 24 q-4 22 -36 18" fill="none" stroke="#fff" stroke-width="12"/><path d="M-20 -6 q6 10 0 20" stroke="#F0386B" stroke-width="6" fill="none" stroke-linecap="round"/><path d="M-16 -54 q-12 -14 0 -28 q12 -14 0 -28" stroke="#fff" stroke-width="8" fill="none" stroke-linecap="round" opacity=".9"/><path d="M14 -54 q-12 -14 0 -28 q12 -14 0 -28" stroke="#fff" stroke-width="8" fill="none" stroke-linecap="round" opacity=".9"/></g>`,
  gift: `<g transform="translate(256 404)"><rect x="-64" y="-34" width="128" height="86" rx="12" fill="url(#mint)"/><rect x="-72" y="-54" width="144" height="30" rx="10" fill="#4FD8B4"/><rect x="-12" y="-54" width="24" height="106" fill="url(#gold)"/><path d="M0 -54 C-30 -96 -70 -70 -40 -56 Z M0 -54 C30 -96 70 -70 40 -56 Z" fill="url(#gold)" stroke="#E39A12" stroke-width="3"/></g>`,
  phone: `<g transform="translate(256 398) rotate(-6)"><rect x="-40" y="-62" width="80" height="124" rx="16" fill="${P.ink}"/><rect x="-32" y="-52" width="64" height="100" rx="8" fill="url(#blue)"/><rect x="-22" y="-38" width="38" height="12" rx="6" fill="#fff"/><rect x="-14" y="-18" width="38" height="12" rx="6" fill="#FFB27F"/><rect x="-22" y="2" width="30" height="12" rx="6" fill="#fff"/></g>`,
  thumb: `<g transform="translate(398 318) rotate(-6)"><rect x="-32" y="-22" width="64" height="56" rx="20" fill="url(#cream)" stroke="#EBC6AC" stroke-width="4"/><path d="M-24 -6 H22 M-24 10 H22" stroke="#EBC6AC" stroke-width="4" stroke-linecap="round"/><rect x="-30" y="-76" width="30" height="66" rx="15" fill="url(#cream)" stroke="#EBC6AC" stroke-width="4"/></g>`,
  ok: '',
  kissHeart: `<g transform="translate(332 300) rotate(-10)"><path d="M0 22 C-38 0 -26 -28 0 -12 C26 -28 38 0 0 22 Z" fill="url(#heart)"/></g>`,
  crown: `<g transform="translate(256 92)"><path d="M-70 30 L-80 -36 L-36 -6 L0 -50 L36 -6 L80 -36 L70 30 Z" fill="url(#gold)" stroke="#E39A12" stroke-width="5" stroke-linejoin="round"/><circle cx="0" cy="4" r="10" fill="#F0386B"/><circle cx="-44" cy="12" r="7" fill="#3C9BEA"/><circle cx="44" cy="12" r="7" fill="#18B892"/></g>`,
  sweat: `<path d="M370 170 q-16 26 0 38 q16 -12 0 -38 z" fill="url(#tear)" stroke="#fff" stroke-width="4"/>`,
};

// ------------------------------------------------------------------ animation (t = 0..1, loops)
const TAU = Math.PI * 2;
const sin = (t, k = 1, ph = 0) => Math.sin(TAU * k * t + ph);
const f = (n) => Number(n.toFixed(3));
const about = (x, y, inner) => `translate(${x} ${y}) ${inner} translate(${-x} ${-y})`;

function propAnim(k, t, i = 0) {
  switch (k) {
    case 'heart': return about(256, 400, `scale(${f(1 + 0.1 * Math.abs(sin(t, 2)))})`);
    case 'smallHeart': case 'kissHeart': return `translate(${f(4 * sin(t))} ${f(-18 * t)})`;
    case 'sparkles': return about(256, 220, `scale(${f(1 + 0.04 * sin(t, 2))})`);
    case 'zzz': return `translate(${f(10 * t)} ${f(-24 * t)})`;
    case 'confetti': return `translate(0 ${f(26 * t - 13)})`;
    case 'joyTears': return `translate(0 ${f(6 * Math.abs(sin(t, 2)))})`;
    case 'steam': return about(256, 110, `scale(${f(1 + 0.08 * sin(t, 2))})`);
    case 'angerMark': return about(380, 130, `scale(${f(1 + 0.15 * Math.abs(sin(t, 2)))})`);
    case 'bang': return about(430, 150, `rotate(${f(8 * sin(t, 2))})`);
    case 'thought': return `translate(0 ${f(-5 * sin(t))})`;
    case 'cup': return `translate(0 ${f(-3 * sin(t))})`;
    case 'crown': return about(256, 92, `rotate(${f(5 * sin(t))})`);
    case 'sweat': return `translate(0 ${f(16 * t)})`;
    case 'thumb': return about(398, 330, `rotate(${f(-8 * Math.abs(sin(t, 2)))})`);
    case 'gift': return about(256, 404, `rotate(${f(3 * sin(t, 2))})`);
    case 'phone': return about(256, 398, `rotate(${f(2 * sin(t, 3))})`);
    case 'partyHat': return about(256, 128, `rotate(${f(5 * sin(t))})`);
    case 'nightcap': return about(256, 150, `rotate(${f(2 * sin(t))})`);
    default: return '';
  }
}
function propOpacity(k, t) {
  if (k === 'smallHeart' || k === 'kissHeart' || k === 'zzz' || k === 'sweat') return f(t < 0.8 ? 1 : (1 - t) / 0.2);
  if (k === 'tears') return f(0.65 + 0.35 * Math.abs(sin(t, 2)));
  if (k === 'sparkles') return f(0.7 + 0.3 * Math.abs(sin(t, 1.5)));
  return 1;
}
const props = (list, t) => list.map((k, i) => `<g transform="${propAnim(k, t, i)}" opacity="${propOpacity(k, t)}">${PROPS[k]}</g>`).join('');

const BLINKS = ['normal', 'big', 'sad', 'side', 'wink', 'angry', 'think', 'pleading', 'surprised'];
function blink(eyes, t) {
  if (!BLINKS.includes(eyes)) return 1;
  const d = Math.abs(t - 0.64);
  return d < 0.05 ? f(0.12 + 0.88 * (d / 0.05)) : 1;
}

function armsFor(kind, t) {
  if (kind === 'wave') {
    return arm(170, 360, 182, 412) + `<g transform="${about(350, 352, `rotate(${f(-18 * sin(t, 2))})`)}">${arm(350, 352, 408, 280)}</g>`;
  }
  if (kind === 'up') {
    return `<g transform="${about(168, 350, `rotate(${f(10 * sin(t, 2))})`)}">${arm(168, 350, 112, 284)}</g><g transform="${about(344, 350, `rotate(${f(-10 * sin(t, 2))})`)}">${arm(344, 350, 400, 284)}</g>`;
  }
  return ARMS[kind];
}

function fox({ eyes = 'normal', mouth = 'smile', arms = 'rest', ears: e = 'up', tail: tl = 'right', blush = 'soft', back = [], front = [], top = [], tilt = 0, shake = false }, t = 0) {
  const bob = f(-3 * (1 - Math.cos(TAU * t)));
  const sq = f(0.015 * Math.cos(TAU * t));
  const headTilt = f(tilt + (shake ? 5 * sin(t, 4) : 3 * sin(t, 1, 1)));
  const tailRot = f(9 * sin(t, 1, 0.5));
  const bl = blink(eyes, t);
  return `<g filter="url(#sticker)">
    ${props(back, t)}
    <g transform="translate(0 ${bob}) ${about(256, 490, `scale(${f(1 + sq)} ${f(1 - sq)})`)}">
      <g transform="${about(340, 400, `rotate(${tailRot})`)}">${tail(tl)}</g>
      ${body()}
      <g transform="rotate(${headTilt} 256 330)">
        ${ears(e)}
        ${head()}
        ${blush === 'big' ? BLUSH_BIG : blush === 'none' ? '' : BLUSH}
        <g transform="${about(256, 232, `scale(1 ${bl})`)}">${EYES[eyes]}</g>
        ${NOSE}
        ${MOUTH[mouth]}
        ${props(top, t)}
      </g>
      ${armsFor(arms, t)}
      ${props(front, t)}
    </g>
  </g>`;
}

const LIST = [
  ['hello', '👋', { eyes: 'happy', mouth: 'grin', arms: 'wave', back: ['sparkles'] }],
  ['love', '❤️', { eyes: 'heart', mouth: 'grin', arms: 'hug', front: ['heart'], blush: 'big' }],
  ['laugh', '😂', { eyes: 'laugh', mouth: 'grin', arms: 'rest', top: ['joyTears'], tilt: -6, shake: true }],
  ['thanks', '🙏', { eyes: 'closed', mouth: 'smile', arms: 'pray', back: ['sparkles'] }],
  ['like', '👍', { eyes: 'wink', mouth: 'grin', arms: 'thumb', front: ['thumb'], back: ['sparkles'] }],
  ['wow', '😮', { eyes: 'surprised', mouth: 'o', arms: 'up', back: ['bang'] }],
  ['cry', '😭', { eyes: 'closed', mouth: 'wobbly', ears: 'down', top: ['tears'] }],
  ['angry', '😠', { eyes: 'angry', mouth: 'shout', blush: 'none', back: ['steam', 'angerMark'] }],
  ['sleepy', '😴', { eyes: 'sleepy', mouth: 'tiny', top: ['nightcap'], back: ['zzz'], tail: 'left' }],
  ['cool', '😎', { eyes: 'glasses', mouth: 'smirk', back: ['sparkles'] }],
  ['party', '🥳', { eyes: 'happy', mouth: 'grin', arms: 'up', top: ['partyHat'], back: ['confetti'] }],
  ['think', '🤔', { eyes: 'think', mouth: 'flat', arms: 'chin', back: ['thought'] }],
  ['coffee', '☕', { eyes: 'closed', mouth: 'smile', arms: 'cup', front: ['cup'] }],
  ['kiss', '😘', { eyes: 'wink', mouth: 'kiss', blush: 'big', back: ['kissHeart', 'smallHeart'] }],
  ['shy', '😊', { eyes: 'side', mouth: 'tiny', arms: 'cover', blush: 'big', ears: 'down' }],
  ['starstruck', '🤩', { eyes: 'star', mouth: 'grin', back: ['sparkles'], blush: 'big' }],
  ['gift', '🎁', { eyes: 'happy', mouth: 'smile', arms: 'cup', front: ['gift'] }],
  ['please', '🥺', { eyes: 'pleading', mouth: 'wobbly', arms: 'pray', ears: 'down' }],
  ['busy', '📱', { eyes: 'side', mouth: 'flat', arms: 'cup', front: ['phone'], top: ['sweat'] }],
  ['king', '👑', { eyes: 'closed', mouth: 'smirk', top: ['crown'], back: ['sparkles'] }],
];

const FRAMES = 20; // 2 s at 10 fps
const SIZE = 320;
const COLS = 5;

function svg(spec, t = 0, size = 512) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="${size}" height="${size}">${defs}${fox(spec, t)}</svg>`;
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const fontDir = path.resolve(__dirname, '../../../backend/web-client/fonts');
  const b64 = fs.readFileSync(path.join(fontDir, 'PlusJakartaSans-ExtraBold.woff2')).toString('base64');
  const font = `@font-face{font-family:Jakarta;src:url(data:font/woff2;base64,${b64}) format('woff2');font-weight:800}`;
  const rows = Math.ceil(FRAMES / COLS);
  const page = (spec) => `<html><head><style>${font}html,body{margin:0;background:transparent}svg{display:block;float:left}</style></head><body style="width:${COLS * SIZE}px">${
    Array.from({ length: FRAMES }, (_, i) => svg(spec, i / FRAMES, SIZE)).join('')}</body></html>`;
  const only = process.env.ONLY ? process.env.ONLY.split(',') : null;
  const items = LIST.filter((x) => !only || only.includes(x[0]));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fox-'));
  let chromium = null;
  try {
    ({ chromium } = require('playwright'));
  } catch (_) {
    chromium = null;
  }
  const b = chromium ? await chromium.launch() : null;
  const p = b ? await b.newPage({ viewport: { width: COLS * SIZE, height: rows * SIZE } }) : null;
  for (const [name, , spec] of items) {
    const sheet = path.join(tmp, `${name}-sheet.png`);
    if (p) {
      await p.setContent(page(spec));
      await p.evaluate(() => document.fonts.ready);
      await p.screenshot({ path: sheet, omitBackground: true, clip: { x: 0, y: 0, width: COLS * SIZE, height: rows * SIZE } });
    } else {
      const f = path.join(tmp, `${name}.html`);
      fs.writeFileSync(f, page(spec));
      execFileSync(process.env.CHROME || 'chromium', ['--headless', '--no-sandbox', '--hide-scrollbars', '--default-background-color=00000000',
        `--window-size=${COLS * SIZE},${rows * SIZE}`, '--virtual-time-budget=3000', `--screenshot=${sheet}`, `file://${f}`], { stdio: 'ignore' });
    }
    // slice the sheet into frames → animated WebP (+ a still PNG of the first frame)
    execFileSync('python3', ['-c', `
import sys
from PIL import Image
sheet = Image.open(sys.argv[1]).convert('RGBA')
n, size, cols = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
frames = [sheet.crop(((i % cols) * size, (i // cols) * size, (i % cols + 1) * size, (i // cols + 1) * size)) for i in range(n)]
frames[0].save(sys.argv[2] + '.png', optimize=True)
frames[0].save(sys.argv[2] + '.webp', save_all=True, append_images=frames[1:], duration=100, loop=0, quality=70, method=4, alpha_quality=70)
`, sheet, path.join(OUT, name), String(FRAMES), String(SIZE), String(COLS)]);
  }
  if (b) await b.close();
  if (!only) {
    fs.writeFileSync(path.join(OUT, 'pack.json'), JSON.stringify({ title: 'Tali the Fox', animated: true, stickers: LIST.map(([n, e]) => ({ file: `${n}.webp`, emoji: e })) }, null, 2));
  }
  console.log('stickers:', items.length, '→', OUT);
})();
