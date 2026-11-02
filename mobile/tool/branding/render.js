// Renders the Hushavia mark into every Android/iOS/Play asset we need.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const OUT = process.argv[2];
const FONTS = path.resolve(__dirname, '../../../backend/web-client/fonts');
const DEFS = `<defs><linearGradient id="bg" x1=".15" y1="0" x2=".85" y2="1"><stop offset="0" stop-color="#8F72FF"/><stop offset="1" stop-color="#4E2FE0"/></linearGradient></defs>`;
// Hushavia mark: a speech bubble folded from one sheet of paper (upper fold white, lower fold lilac) with a mint "seal".
// Drawn in a 100-unit box; art bbox x24.5..75.5 y26.5..78.5 (center 50,52.5).
const UP = '27,29 73,29 73,61';
const LOW = '27,29 73,61 49,61 32,76 36,61 27,61';
const ALL = '27,29 73,29 73,61 49,61 32,76 36,61 27,61';
const ART = (mono) => mono
  ? `<polygon points="${ALL}" fill="#fff" stroke="#fff" stroke-width="5" stroke-linejoin="round"/>`
  : `<polygon points="${UP}" fill="#fff" stroke="#fff" stroke-width="5" stroke-linejoin="round"/>
<polygon points="${LOW}" fill="#D6CBFF" stroke="#D6CBFF" stroke-width="5" stroke-linejoin="round"/><circle cx="66" cy="36" r="2.6" fill="#5EF0D2"/>`;
const centered = (canvas, artW, mono) => {
  const s = artW / 51;
  return `<g transform="translate(${canvas / 2 - 50 * s} ${canvas / 2 - 52.5 * s}) scale(${s})">${ART(mono)}</g>`;
};
const svg = {
  full: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<circle cx="256" cy="256" r="256" fill="url(#bg)"/>${centered(512, 262)}</svg>`,
  square: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<rect width="512" height="512" fill="url(#bg)"/>${centered(512, 290)}</svg>`,
  round: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<circle cx="256" cy="256" r="256" fill="url(#bg)"/>${centered(512, 262)}</svg>`,
  fg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 50)}</svg>`,
  mono: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 50, true)}</svg>`,
  splash: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 288 288">${DEFS}${centered(288, 130)}</svg>`,
  feature: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 500"><defs><linearGradient id="bg" x1=".15" y1="0" x2=".85" y2="1"><stop offset="0" stop-color="#8F72FF"/><stop offset="1" stop-color="#4E2FE0"/></linearGradient></defs>
  <rect width="1024" height="500" fill="#0F0E2A"/><circle cx="230" cy="250" r="260" fill="#6D4AFF" opacity=".16"/>
  <g transform="translate(110 130)"><circle cx="120" cy="120" r="120" fill="url(#bg)"/><g transform="translate(${120 - 50 * 2.45} ${120 - 52.5 * 2.45}) scale(2.45)">${ART(false)}</g></g>
  <text x="410" y="240" font-family="Plus Jakarta Sans, Arial" font-weight="800" font-size="92" fill="#EDEBFF" letter-spacing="-3">hushavia</text>
  <text x="414" y="300" font-family="Plus Jakarta Sans, Arial" font-weight="500" font-size="30" fill="#B9B3E6">Talk freely. Stay private.</text></svg>`,
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
