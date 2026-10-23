// Renders the Talvio mark into every Android/iOS/Play asset we need.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const OUT = process.argv[2];
const FONTS = path.resolve(__dirname, '../../../backend/web-client/fonts');
const DEFS = `<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#232945"/><stop offset="1" stop-color="#12162A"/></linearGradient>
<linearGradient id="c" x1="0" x2="1"><stop offset="0" stop-color="#FF8A6E"/><stop offset=".5" stop-color="#EF5A3C"/><stop offset="1" stop-color="#E0417A"/></linearGradient></defs>`;
// art in a 512 box, bbox x92..410 y102..388 (center 251,245)
const ART = (mono) => `<rect x="184" y="102" width="226" height="184" rx="92" fill="${mono ? '#fff' : 'url(#c)'}" ${mono ? 'opacity=".55"' : ''}/>
<rect x="92" y="194" width="246" height="194" rx="96" fill="#fff"/>
${mono ? '' : '<circle cx="159" cy="292" r="18" fill="#151A2E"/><circle cx="215" cy="292" r="18" fill="#151A2E"/><circle cx="271" cy="292" r="18" fill="#151A2E"/>'}`;
const centered = (canvas, artW, mono) => {
  const s = artW / 318;
  return `<g transform="translate(${canvas / 2 - 251 * s} ${canvas / 2 - 245 * s}) scale(${s})">${ART(mono)}</g>`;
};
const svg = {
  full: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<rect width="512" height="512" rx="114" fill="url(#bg)"/>${centered(512, 330)}</svg>`,
  square: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<rect width="512" height="512" fill="url(#bg)"/>${centered(512, 330)}</svg>`,
  round: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<circle cx="256" cy="256" r="256" fill="url(#bg)"/>${centered(512, 300)}</svg>`,
  fg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 56)}</svg>`,
  mono: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 56, true)}</svg>`,
  splash: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 288 288">${DEFS}${centered(288, 150)}</svg>`,
  feature: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 500">${DEFS}<rect width="1024" height="500" fill="url(#bg)"/>
  <circle cx="900" cy="-40" r="260" fill="#EF5A3C" opacity=".14"/><circle cx="120" cy="560" r="240" fill="#E0417A" opacity=".10"/>
  <g transform="translate(110 130)"><rect width="240" height="240" rx="56" fill="#1d2340" stroke="#2f365a" stroke-width="2"/>${`<g transform="translate(${120 - 251 * 0.5} ${120 - 245 * 0.5}) scale(0.5)">${ART(false)}</g>`}</g>
  <text x="410" y="240" font-family="Plus Jakarta Sans, Arial" font-weight="800" font-size="92" fill="#fff" letter-spacing="-3">Talvio</text>
  <text x="414" y="300" font-family="Plus Jakarta Sans, Arial" font-weight="500" font-size="30" fill="#c5cadb">Chats, calls &amp; channels — made simple.</text></svg>`,
};
const dens = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
const jobs = [];
for (const [d, k] of Object.entries(dens)) {
  jobs.push(['full', 48 * k, `android/mipmap-${d}/ic_launcher.png`]);
  jobs.push(['round', 48 * k, `android/mipmap-${d}/ic_launcher_round.png`]);
  jobs.push(['fg', 108 * k, `android/drawable-${d}/ic_launcher_foreground.png`]);
  jobs.push(['mono', 108 * k, `android/drawable-${d}/ic_launcher_monochrome.png`]);
  jobs.push(['splash', 288 * k, `android/drawable-${d}/splash_icon.png`]);
  jobs.push(['full', 128 * k, `android/drawable-${d}/splash_logo.png`]);
}
for (const n of [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]) jobs.push(['square', n, `ios/Icon-${n}.png`]);
jobs.push(['full', 512, 'store/icon-512.png']);
jobs.push(['feature', 1024, 'store/feature-graphic-1024x500.png', 500]);
jobs.push(['full', 192, 'web/icon-192.png']);
jobs.push(['full', 512, 'web/icon-512.png']);
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  for (const [k, w, out, h] of jobs) {
    const height = h || w;
    await p.setViewportSize({ width: Math.round(w), height: Math.round(height) });
    await p.goto('file:///tmp/blank.html').catch(() => {});
    await p.setContent(`<html><head><style>@font-face{font-family:"Plus Jakarta Sans";src:url(file://${FONTS}/PlusJakartaSans-ExtraBold.woff2);font-weight:800}@font-face{font-family:"Plus Jakarta Sans";src:url(file://${FONTS}/PlusJakartaSans-Medium.woff2);font-weight:500}</style></head><body style="margin:0;background:transparent">${svg[k].replace('<svg ', `<svg width="${w}" height="${height}" `)}</body></html>`);
    const f = path.join(OUT, out);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: f, omitBackground: true, clip: { x: 0, y: 0, width: Math.round(w), height: Math.round(height) } });
  }
  await b.close();
  console.log('rendered', jobs.length);
})();
