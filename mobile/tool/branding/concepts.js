// Mascot concepts (stills) to pick a character before animating. node concepts.js /tmp/out.png
const { chromium } = require('playwright');

const O = '#2B1D2E';
const defs = `<defs>
<filter id="b4"><feGaussianBlur stdDeviation="4"/></filter>
<linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".5" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<radialGradient id="irisB" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#8A6CFF"/><stop offset=".6" stop-color="#4B2FB8"/><stop offset="1" stop-color="#22145E"/></radialGradient>
<radialGradient id="irisG" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#9BE36A"/><stop offset=".6" stop-color="#3E9A2C"/><stop offset="1" stop-color="#1C4A12"/></radialGradient>
<radialGradient id="irisK" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#6B5A4E"/><stop offset="1" stop-color="#1A1210"/></radialGradient>
</defs>`;

// big anime-ish eye: white, coloured iris, pupil, two highlights
function eye(x, y, iris, s = 1, look = [0, 0]) {
  return `<ellipse cx="${x}" cy="${y}" rx="${30 * s}" ry="${36 * s}" fill="#fff" stroke="${O}" stroke-width="8"/>
  <ellipse cx="${x + look[0]}" cy="${y + 4 + look[1]}" rx="${21 * s}" ry="${26 * s}" fill="url(#${iris})"/>
  <ellipse cx="${x + look[0]}" cy="${y + 6 + look[1]}" rx="${10 * s}" ry="${13 * s}" fill="#0B0714"/>
  <ellipse cx="${x + look[0] - 8 * s}" cy="${y - 6 + look[1]}" rx="${8 * s}" ry="${10 * s}" fill="#fff"/>
  <circle cx="${x + look[0] + 9 * s}" cy="${y + 16 + look[1]}" r="${4 * s}" fill="#fff"/>`;
}
const shadow = `<ellipse cx="256" cy="470" rx="130" ry="16" fill="#1A1430" opacity=".18" filter="url(#b4)"/>`;

// ---------------------------------------------------------------- 1. Bobo the bunny (ears flop over the eyes)
function bunny(pose) {
  const C = { fur: '#FFFFFF', sh: '#E3DDF2', ear: '#FFB3C8', earSh: '#F08BAA', blush: '#FF8FB0' };
  const ears = pose === 'hide'
    ? `<path d="M196 150 C 150 120 130 170 160 230 C 176 262 222 260 232 230 C 240 200 230 168 196 150 Z" fill="${C.fur}" stroke="${O}" stroke-width="10"/>
       <path d="M192 168 C 162 156 154 192 172 226 C 184 246 214 242 218 222 C 222 202 214 178 192 168 Z" fill="${C.ear}"/>
       <path d="M316 150 C 362 120 382 170 352 230 C 336 262 290 260 280 230 C 272 200 282 168 316 150 Z" fill="${C.fur}" stroke="${O}" stroke-width="10"/>
       <path d="M320 168 C 350 156 358 192 340 226 C 328 246 298 242 294 222 C 290 202 298 178 320 168 Z" fill="${C.ear}"/>`
    : `<path d="M206 170 C 170 90 168 20 204 18 C 240 16 246 96 236 168" fill="${C.fur}" stroke="${O}" stroke-width="10" stroke-linejoin="round"/>
       <path d="M210 150 C 190 90 192 44 208 42 C 226 42 230 100 226 150 Z" fill="${C.ear}"/>
       <path d="M276 168 C 290 96 320 30 352 46 C 384 62 340 130 304 176" fill="${C.fur}" stroke="${O}" stroke-width="10" stroke-linejoin="round"/>
       <path d="M288 154 C 304 104 326 64 344 70 C 360 78 330 126 306 160 Z" fill="${C.ear}"/>`;
  const front = pose === 'hide'
    ? `<ellipse cx="200" cy="300" rx="30" ry="24" fill="#fff" stroke="${O}" stroke-width="9"/><ellipse cx="312" cy="300" rx="30" ry="24" fill="#fff" stroke="${O}" stroke-width="9"/>`
    : `<path d="M352 330 C 392 300 410 250 398 226" stroke="${O}" stroke-width="40" stroke-linecap="round" fill="none"/>
       <path d="M352 330 C 392 300 410 250 398 226" stroke="#fff" stroke-width="24" stroke-linecap="round" fill="none"/>
       <ellipse cx="190" cy="372" rx="30" ry="24" fill="#fff" stroke="${O}" stroke-width="9"/>`;
  const eyes = pose === 'hide' ? '' : eye(212, 262, 'irisB') + eye(300, 262, 'irisB');
  return `${shadow}
  ${pose === 'hide' ? '' : ears}
  <path d="M256 150 C 356 150 392 230 388 300 C 384 390 340 448 256 448 C 172 448 128 390 124 300 C 120 230 156 150 256 150 Z" fill="${C.fur}" stroke="${O}" stroke-width="10"/>
  <path d="M388 300 C 384 390 340 448 256 448 C 300 430 352 380 356 300 C 360 240 340 200 320 176 C 366 196 390 250 388 300 Z" fill="${C.sh}"/>
  <ellipse cx="200" cy="200" rx="40" ry="22" fill="#fff" opacity=".9" transform="rotate(-25 200 200)"/>
  <ellipse cx="212" cy="460" rx="40" ry="18" fill="#fff" stroke="${O}" stroke-width="9"/><ellipse cx="300" cy="460" rx="40" ry="18" fill="#fff" stroke="${O}" stroke-width="9"/>
  ${eyes}
  <ellipse cx="178" cy="312" rx="22" ry="12" fill="${C.blush}" opacity=".7"/><ellipse cx="334" cy="312" rx="22" ry="12" fill="${C.blush}" opacity=".7"/>
  <path d="M246 302 Q 256 312 266 302 Q 256 296 246 302 Z" fill="#FF6E96" stroke="${O}" stroke-width="5"/>
  <path d="M256 310 L 256 322 M 256 322 Q 244 334 234 324 M 256 322 Q 268 334 278 324" fill="none" stroke="${O}" stroke-width="6" stroke-linecap="round"/>
  <path d="M168 360 C 210 384 302 384 344 360 L 346 388 C 300 410 212 410 166 388 Z" fill="url(#brand)" stroke="${O}" stroke-width="8"/>
  ${pose === 'hide' ? ears : ''}
  ${front}`;
}

// ---------------------------------------------------------------- 2. Miko the cat (orange tabby, paws over eyes)
function cat(pose) {
  const C = { fur: '#FFA54A', sh: '#E8782A', light: '#FFD7A8', belly: '#FFF3E4' };
  const look = pose === 'hide' ? '' : eye(208, 258, 'irisG') + eye(304, 258, 'irisG');
  const paws = pose === 'hide'
    ? `<path d="M150 380 C 150 330 170 290 196 262" stroke="${O}" stroke-width="58" stroke-linecap="round" fill="none"/>
       <path d="M150 380 C 150 330 170 290 196 262" stroke="${C.fur}" stroke-width="40" stroke-linecap="round" fill="none"/>
       <path d="M362 380 C 362 330 342 290 316 262" stroke="${O}" stroke-width="58" stroke-linecap="round" fill="none"/>
       <path d="M362 380 C 362 330 342 290 316 262" stroke="${C.fur}" stroke-width="40" stroke-linecap="round" fill="none"/>
       <ellipse cx="204" cy="252" rx="42" ry="36" fill="${C.belly}" stroke="${O}" stroke-width="9"/>
       <ellipse cx="308" cy="252" rx="42" ry="36" fill="${C.belly}" stroke="${O}" stroke-width="9"/>
       <ellipse cx="204" cy="262" rx="13" ry="10" fill="#FF9AB4"/><ellipse cx="308" cy="262" rx="13" ry="10" fill="#FF9AB4"/>
       <circle cx="186" cy="238" r="7" fill="#FF9AB4"/><circle cx="204" cy="232" r="7" fill="#FF9AB4"/><circle cx="222" cy="238" r="7" fill="#FF9AB4"/>
       <circle cx="290" cy="238" r="7" fill="#FF9AB4"/><circle cx="308" cy="232" r="7" fill="#FF9AB4"/><circle cx="326" cy="238" r="7" fill="#FF9AB4"/>`
    : `<path d="M356 360 C 400 330 416 270 400 236" stroke="${O}" stroke-width="54" stroke-linecap="round" fill="none"/>
       <path d="M356 360 C 400 330 416 270 400 236" stroke="${C.fur}" stroke-width="36" stroke-linecap="round" fill="none"/>
       <ellipse cx="402" cy="226" rx="30" ry="26" fill="${C.belly}" stroke="${O}" stroke-width="9"/>`;
  return `${shadow}
  <path d="M370 420 C 450 420 470 330 430 300 C 414 290 400 304 414 318 C 436 340 420 392 370 396 Z" fill="${C.fur}" stroke="${O}" stroke-width="10" stroke-linejoin="round"/>
  <path d="M150 210 L 156 110 L 226 160 Z" fill="${C.fur}" stroke="${O}" stroke-width="10" stroke-linejoin="round"/><path d="M164 182 L 166 134 L 204 160 Z" fill="#FF9AB4"/>
  <path d="M362 210 L 356 110 L 286 160 Z" fill="${C.fur}" stroke="${O}" stroke-width="10" stroke-linejoin="round"/><path d="M348 182 L 346 134 L 308 160 Z" fill="#FF9AB4"/>
  <path d="M256 140 C 360 140 400 210 398 290 C 396 390 346 450 256 450 C 166 450 116 390 114 290 C 112 210 152 140 256 140 Z" fill="${C.fur}" stroke="${O}" stroke-width="10"/>
  <path d="M398 290 C 396 390 346 450 256 450 C 310 430 360 380 364 300 C 368 240 350 200 330 170 C 376 196 400 240 398 290 Z" fill="${C.sh}"/>
  <path d="M236 146 L 246 186 L 256 146 M 266 146 L 276 186 M 286 150 L 290 180" stroke="${C.sh}" stroke-width="10" stroke-linecap="round"/>
  <path d="M256 330 C 320 330 340 380 330 420 C 310 448 202 448 182 420 C 172 380 192 330 256 330 Z" fill="${C.belly}"/>
  <ellipse cx="196" cy="196" rx="36" ry="18" fill="${C.light}" opacity=".9" transform="rotate(-25 196 196)"/>
  ${look}
  <ellipse cx="172" cy="304" rx="22" ry="12" fill="#FF7FA0" opacity=".6"/><ellipse cx="340" cy="304" rx="22" ry="12" fill="#FF7FA0" opacity=".6"/>
  <path d="M244 298 Q 256 308 268 298 Q 256 290 244 298 Z" fill="#FF6E96" stroke="${O}" stroke-width="5"/>
  <path d="M256 306 L 256 314 M 256 314 Q 242 330 230 316 M 256 314 Q 270 330 282 316" fill="none" stroke="${O}" stroke-width="6" stroke-linecap="round"/>
  <path d="M150 300 L 104 292 M150 314 L 106 320 M362 300 L 408 292 M362 314 L 406 320" stroke="${O}" stroke-width="5" stroke-linecap="round"/>
  <path d="M170 350 C 210 372 302 372 342 350 L 344 376 C 300 398 212 398 168 376 Z" fill="url(#brand)" stroke="${O}" stroke-width="8"/>
  <circle cx="256" cy="392" r="16" fill="#FFD54A" stroke="${O}" stroke-width="7"/>
  <ellipse cx="210" cy="456" rx="38" ry="18" fill="${C.fur}" stroke="${O}" stroke-width="9"/><ellipse cx="302" cy="456" rx="38" ry="18" fill="${C.fur}" stroke="${O}" stroke-width="9"/>
  ${paws}`;
}

// ---------------------------------------------------------------- 3. Pandu the panda cub
function panda(pose) {
  const C = { fur: '#FFFFFF', sh: '#E0DFEA', dark: '#2E2A3A' };
  const eyes = pose === 'hide' ? '' : `<ellipse cx="206" cy="262" rx="44" ry="50" fill="${C.dark}" transform="rotate(-20 206 262)"/><ellipse cx="306" cy="262" rx="44" ry="50" fill="${C.dark}" transform="rotate(20 306 262)"/>`
    + eye(210, 262, 'irisK', 0.9) + eye(302, 262, 'irisK', 0.9);
  const arms = pose === 'hide'
    ? `<path d="M140 400 C 140 330 168 290 196 266" stroke="${O}" stroke-width="64" stroke-linecap="round" fill="none"/><path d="M140 400 C 140 330 168 290 196 266" stroke="${C.dark}" stroke-width="46" stroke-linecap="round" fill="none"/>
       <path d="M372 400 C 372 330 344 290 316 266" stroke="${O}" stroke-width="64" stroke-linecap="round" fill="none"/><path d="M372 400 C 372 330 344 290 316 266" stroke="${C.dark}" stroke-width="46" stroke-linecap="round" fill="none"/>
       <ellipse cx="204" cy="256" rx="44" ry="38" fill="${C.dark}" stroke="${O}" stroke-width="9"/><ellipse cx="308" cy="256" rx="44" ry="38" fill="${C.dark}" stroke="${O}" stroke-width="9"/>
       <ellipse cx="204" cy="262" rx="14" ry="11" fill="#FF9AB4"/><ellipse cx="308" cy="262" rx="14" ry="11" fill="#FF9AB4"/>`
    : `<path d="M356 360 C 400 330 416 270 400 236" stroke="${O}" stroke-width="60" stroke-linecap="round" fill="none"/><path d="M356 360 C 400 330 416 270 400 236" stroke="${C.dark}" stroke-width="42" stroke-linecap="round" fill="none"/>
       <ellipse cx="160" cy="390" rx="34" ry="28" fill="${C.dark}" stroke="${O}" stroke-width="9"/>`;
  return `${shadow}
  <circle cx="160" cy="160" r="44" fill="${C.dark}" stroke="${O}" stroke-width="10"/><circle cx="352" cy="160" r="44" fill="${C.dark}" stroke="${O}" stroke-width="10"/>
  <circle cx="160" cy="160" r="20" fill="#FF9AB4" opacity=".8"/><circle cx="352" cy="160" r="20" fill="#FF9AB4" opacity=".8"/>
  <path d="M256 140 C 362 140 402 214 400 292 C 398 392 346 452 256 452 C 166 452 114 392 112 292 C 110 214 150 140 256 140 Z" fill="${C.fur}" stroke="${O}" stroke-width="10"/>
  <path d="M112 330 C 130 420 180 452 256 452 C 332 452 382 420 400 330 C 360 360 300 372 256 372 C 212 372 152 360 112 330 Z" fill="${C.dark}"/>
  <path d="M400 292 C 398 392 346 452 256 452 C 316 432 362 380 366 300 C 370 240 350 200 330 170 C 376 196 402 240 400 292 Z" fill="${C.sh}" opacity=".8"/>
  <ellipse cx="200" cy="196" rx="38" ry="20" fill="#fff" transform="rotate(-25 200 196)"/>
  <path d="M112 292 C 110 214 150 140 256 140 C 362 140 402 214 400 292 C 398 392 346 452 256 452 C 166 452 114 392 112 292 Z" fill="none" stroke="${O}" stroke-width="10"/>
  ${eyes}
  <ellipse cx="164" cy="318" rx="22" ry="12" fill="#FF7FA0" opacity=".6"/><ellipse cx="348" cy="318" rx="22" ry="12" fill="#FF7FA0" opacity=".6"/>
  <ellipse cx="256" cy="312" rx="16" ry="11" fill="${C.dark}"/>
  <path d="M256 322 L 256 330 M 256 330 Q 244 342 234 332 M 256 330 Q 268 342 278 332" fill="none" stroke="${O}" stroke-width="6" stroke-linecap="round"/>
  <path d="M170 362 C 210 384 302 384 342 362 L 344 388 C 300 410 212 410 168 388 Z" fill="url(#brand)" stroke="${O}" stroke-width="8"/>
  <ellipse cx="210" cy="462" rx="40" ry="18" fill="${C.dark}" stroke="${O}" stroke-width="9"/><ellipse cx="302" cy="462" rx="40" ry="18" fill="${C.dark}" stroke="${O}" stroke-width="9"/>
  ${arms}`;
}

(async () => {
  const S = 380;
  const cell = (inner, label) => `<div style="float:left;width:${S}px;text-align:center;font:700 22px sans-serif;color:#2B1D2E"><svg viewBox="0 0 512 512" width="${S}" height="${S}">${defs}${inner}</svg><div style="margin-top:-14px">${label}</div></div>`;
  const html = `<html><body style="margin:0;background:#F3F4F9;width:${S * 6}px;padding-top:10px">${
    cell(bunny('hello'), '1 Bobo (bunny)') + cell(bunny('hide'), '1 · password') +
    cell(cat('hello'), '2 Miko (cat)') + cell(cat('hide'), '2 · password') +
    cell(panda('hello'), '3 Pandu (panda)') + cell(panda('hide'), '3 · password')}</body></html>`;
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: S * 6, height: S + 50 } });
  await p.setContent(html);
  await p.screenshot({ path: process.argv[2] || '/tmp/concepts.png' });
  await b.close();
})();
