// Draws the official "Talvio Basics" sticker pack (512×512 PNG, transparent) → backend/assets/stickers/talvio-basics
// Usage: node mobile/tool/branding/stickers.js   (uses playwright, or CHROME=/path/to/chrome as a fallback)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const OUT = path.resolve(__dirname, '../../../backend/assets/stickers/talvio-basics');
const FONTS = path.resolve(__dirname, '../../../backend/web-client/fonts');

const C = { coral: ['#FF8A6E', '#EF5A3C'], rose: ['#F27AA6', '#E0417A'], mint: ['#4FD8C3', '#10B39A'], gold: ['#F7D27E', '#E0A43A'], violet: ['#A596F7', '#6C5BE3'], sky: ['#7CC0F7', '#3C83DE'], ink: ['#8F98C4', '#59628F'] };
const eyes = {
  happy: '<path d="M196 238 q20 -24 40 0" class="ln"/><path d="M276 238 q20 -24 40 0" class="ln"/>',
  open: '<circle cx="216" cy="236" r="15" fill="#151A2E"/><circle cx="296" cy="236" r="15" fill="#151A2E"/><circle cx="221" cy="230" r="5" fill="#fff"/><circle cx="301" cy="230" r="5" fill="#fff"/>',
  wink: '<path d="M196 238 q20 -24 40 0" class="ln"/><circle cx="296" cy="236" r="15" fill="#151A2E"/><circle cx="301" cy="230" r="5" fill="#fff"/>',
  closed: '<path d="M196 236 q20 18 40 0" class="ln"/><path d="M276 236 q20 18 40 0" class="ln"/>',
  heart: '<path d="M216 252 l-20 -20 a12 12 0 0 1 20 -14 a12 12 0 0 1 20 14z" fill="#E0417A"/><path d="M296 252 l-20 -20 a12 12 0 0 1 20 -14 a12 12 0 0 1 20 14z" fill="#E0417A"/>',
  wide: '<circle cx="216" cy="232" r="20" fill="#fff" stroke="#151A2E" stroke-width="7"/><circle cx="296" cy="232" r="20" fill="#fff" stroke="#151A2E" stroke-width="7"/><circle cx="216" cy="234" r="8" fill="#151A2E"/><circle cx="296" cy="234" r="8" fill="#151A2E"/>',
  sad: '<circle cx="216" cy="240" r="13" fill="#151A2E"/><circle cx="296" cy="240" r="13" fill="#151A2E"/><path d="M194 214 l30 10" class="ln"/><path d="M318 214 l-30 10" class="ln"/>',
  sleepy: '<path d="M198 240 h36" class="ln"/><path d="M278 240 h36" class="ln"/>',
  think: '<circle cx="216" cy="236" r="13" fill="#151A2E"/><circle cx="300" cy="226" r="13" fill="#151A2E"/><path d="M280 200 l36 -8" class="ln"/>',
};
const mouths = {
  smile: '<path d="M226 282 q30 30 60 0" class="ln"/>',
  grin: '<path d="M218 276 q38 50 76 0 z" fill="#151A2E"/><path d="M236 296 q20 12 40 0" fill="#FF8A8A"/>',
  o: '<ellipse cx="256" cy="292" rx="16" ry="20" fill="#151A2E"/>',
  flat: '<path d="M234 290 h44" class="ln"/>',
  frown: '<path d="M228 300 q28 -24 56 0" class="ln"/>',
  tongue: '<path d="M222 280 q34 34 68 0" class="ln"/><path d="M262 296 q14 26 26 0" fill="#FF7A8A"/>',
  small: '<path d="M244 288 q12 10 24 0" class="ln"/>',
};
const extras = {
  wave: '<g transform="translate(372 200) rotate(-20)"><rect x="-18" y="-40" width="36" height="70" rx="18" fill="url(#body)" stroke="#fff" stroke-width="10"/></g>',
  heart: '<path d="M400 150 l-34 -34 a20 20 0 0 1 34 -24 a20 20 0 0 1 34 24z" fill="#E0417A" stroke="#fff" stroke-width="8"/>',
  sparkle: '<path d="M398 120 l10 26 26 10 -26 10 -10 26 -10 -26 -26 -10 26 -10z" fill="#F7D27E" stroke="#fff" stroke-width="6"/>',
  tea: '<g transform="translate(360 300)"><rect x="0" y="0" width="70" height="62" rx="12" fill="#fff" stroke="#151A2E" stroke-width="7"/><path d="M70 14 q24 4 0 34" fill="none" stroke="#151A2E" stroke-width="7"/><path d="M18 -18 q8 -12 0 -24 M38 -18 q8 -12 0 -24" stroke="#c5cadb" stroke-width="6" fill="none" stroke-linecap="round"/></g>',
  zz: '<text x="360" y="170" font-size="64" font-weight="800" fill="#6C5BE3" stroke="#fff" stroke-width="8" paint-order="stroke">z<tspan font-size="44" dy="-26">z</tspan></text>',
  thumb: '<g transform="translate(350 250)"><rect x="0" y="20" width="70" height="66" rx="16" fill="url(#body)" stroke="#fff" stroke-width="9"/><rect x="18" y="-22" width="28" height="56" rx="14" fill="url(#body)" stroke="#fff" stroke-width="9"/></g>',
  hands: '<g transform="translate(206 300)"><path d="M18 60 q-6 -50 32 -60 q38 10 32 60z" fill="url(#body)" stroke="#fff" stroke-width="9"/><path d="M50 0 v62" stroke="#fff" stroke-width="6"/></g>',
  tear: '<path d="M300 262 q-10 18 0 26 q10 -8 0 -26z" fill="#7CC0F7" stroke="#fff" stroke-width="4"/>',
  bubble: '<circle cx="380" cy="150" r="14" fill="#fff" stroke="#151A2E" stroke-width="6"/><circle cx="404" cy="116" r="20" fill="#fff" stroke="#151A2E" stroke-width="6"/>',
  stop: '<g transform="translate(360 190)"><rect x="0" y="0" width="64" height="84" rx="30" fill="url(#body)" stroke="#fff" stroke-width="9"/></g>',
  confetti: '<rect x="96" y="120" width="18" height="18" rx="4" fill="#F7D27E" transform="rotate(20 105 129)"/><rect x="392" y="104" width="18" height="18" rx="4" fill="#4FD8C3" transform="rotate(-24 401 113)"/><circle cx="420" cy="176" r="10" fill="#E0417A"/><circle cx="90" cy="190" r="9" fill="#6C5BE3"/>',
};
const list = [
  ['hello', 'Hello!', 'coral', 'happy', 'grin', 'wave', '👋'],
  ['thanks', 'Thank you', 'mint', 'closed', 'smile', 'heart', '🙏'],
  ['haha', 'Hahaha', 'gold', 'closed', 'grin', 'sparkle', '😂'],
  ['wow', 'Wow!', 'violet', 'wide', 'o', 'sparkle', '🤩'],
  ['good', 'Sounds good', 'sky', 'happy', 'smile', 'thumb', '👍'],
  ['congrats', 'Congrats!', 'rose', 'happy', 'grin', 'confetti', '🎉'],
  ['amen', 'Amen', 'mint', 'closed', 'small', 'hands', '🤲'],
  ['love', 'Love you', 'rose', 'heart', 'smile', 'heart', '❤️'],
  ['hmm', 'Hmm...', 'violet', 'think', 'flat', 'bubble', '🤔'],
  ['coffee', 'Coffee?', 'gold', 'open', 'smile', 'tea', '☕'],
  ['wait', 'Wait!', 'coral', 'wide', 'o', 'stop', '✋'],
  ['sorry', 'Sorry!', 'sky', 'sad', 'frown', 'tear', '😔'],
  ['goodnight', 'Good night', 'ink', 'sleepy', 'small', 'zz', '😴'],
  ['awesome', 'Awesome!', 'mint', 'happy', 'smile', 'sparkle', '🌟'],
  ['cool', 'So cool!', 'coral', 'wink', 'tongue', 'sparkle', '😜'],
  ['ok', 'OK!', 'ink', 'open', 'smile', 'thumb', '👌'],
];
function sticker([, label, color, eye, mouth, extra]) {
  const [a, b] = C[color];
  const small = label.length > 9;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs><linearGradient id="body" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>
  <filter id="sh"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#151A2E" flood-opacity=".25"/></filter>
  <style>.ln{fill:none;stroke:#151A2E;stroke-width:10;stroke-linecap:round;stroke-linejoin:round}</style></defs>
  <g filter="url(#sh)">
    <rect x="96" y="120" width="320" height="250" rx="124" fill="url(#body)" stroke="#fff" stroke-width="14"/>
    <path d="M150 352 q-10 40 -40 56 q60 -4 92 -34" fill="url(#body)" stroke="#fff" stroke-width="14" stroke-linejoin="round"/>
    <rect x="104" y="128" width="304" height="234" rx="116" fill="url(#body)"/>
    <ellipse cx="186" cy="276" rx="22" ry="13" fill="#fff" opacity=".28"/><ellipse cx="326" cy="276" rx="22" ry="13" fill="#fff" opacity=".28"/>
    ${eyes[eye]}${mouths[mouth]}
  </g>
  ${extras[extra] || ''}
  <text x="256" y="${small ? 468 : 472}" text-anchor="middle" font-family="Jakarta" font-weight="800" font-size="${small ? 50 : 62}" letter-spacing="-1"
    fill="#151A2E" stroke="#fff" stroke-width="16" stroke-linejoin="round" paint-order="stroke">${label}</text>
</svg>`;
}
(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const b64 = fs.readFileSync(path.join(FONTS, 'PlusJakartaSans-ExtraBold.woff2')).toString('base64');
  const font = `@font-face{font-family:Jakarta;src:url(data:font/woff2;base64,${b64}) format('woff2');font-weight:800}`;
  const html = (s) => `<html><head><style>${font}html,body{margin:0;background:transparent}</style></head><body>${sticker(s)}</body></html>`;
  let chromium = null;
  try {
    ({ chromium } = require('playwright'));
  } catch (_) {
    chromium = null;
  }
  if (chromium) {
    const b = await chromium.launch();
    const p = await b.newPage({ viewport: { width: 512, height: 512 } });
    for (const s of list) {
      await p.setContent(html(s));
      await p.evaluate(() => document.fonts.ready);
      await p.screenshot({ path: path.join(OUT, `${s[0]}.png`), omitBackground: true, clip: { x: 0, y: 0, width: 512, height: 512 } });
    }
    await b.close();
  } else {
    const chrome = process.env.CHROME || 'chromium';
    const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'stk-'));
    for (const s of list) {
      const f = path.join(tmp, `${s[0]}.html`);
      fs.writeFileSync(f, html(s));
      execFileSync(chrome, ['--headless', '--no-sandbox', '--hide-scrollbars', '--default-background-color=00000000', '--window-size=512,512',
        '--virtual-time-budget=2000', `--screenshot=${path.join(OUT, `${s[0]}.png`)}`, `file://${f}`], { stdio: 'ignore' });
    }
  }
  fs.writeFileSync(path.join(OUT, 'pack.json'), JSON.stringify({ title: 'Talvio Basics', stickers: list.map((s) => ({ file: `${s[0]}.png`, emoji: s[6] })) }, null, 2));
  console.log('stickers:', list.length);
})();
