// Renders the Talvio mark into every Android/iOS/Play asset we need.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const OUT = process.argv[2];
const FONTS = path.resolve(__dirname, '../../../backend/web-client/fonts');
const DEFS = `<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A62"/><stop offset=".48" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<linearGradient id="c" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F2557E"/><stop offset="1" stop-color="#6C4BE0"/></linearGradient>
<mask id="tcut"><rect width="512" height="512" fill="#fff"/><rect x="178" y="170" width="156" height="44" rx="22" fill="#000"/><rect x="234" y="170" width="44" height="150" rx="22" fill="#000"/></mask></defs>`;
// Talvio mark: a speech bubble with a "T" and two little sparks. Art bbox x100..412 y90..418 (center 256,254)
const BUBBLE = 'M256 96c-88 0-156 62-156 144 0 40 16 76 44 102l-16 66c-2 8 6 14 13 10l70-38c14 4 29 6 45 6 88 0 156-62 156-146S344 96 256 96z';
const ART = (mono) => mono
  ? `<path d="${BUBBLE}" fill="#fff" mask="url(#tcut)"/><circle cx="372" cy="128" r="16" fill="#fff"/>`
  : `<path d="${BUBBLE}" fill="#fff"/><rect x="178" y="170" width="156" height="44" rx="22" fill="url(#c)"/><rect x="234" y="170" width="44" height="150" rx="22" fill="url(#c)"/>
<circle cx="372" cy="128" r="16" fill="#fff"/><circle cx="404" cy="98" r="8" fill="#fff" opacity=".8"/>`;
const centered = (canvas, artW, mono) => {
  const s = artW / 312;
  return `<g transform="translate(${canvas / 2 - 256 * s} ${canvas / 2 - 254 * s}) scale(${s})">${ART(mono)}</g>`;
};
const svg = {
  full: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<rect width="512" height="512" rx="116" fill="url(#bg)"/><circle cx="150" cy="120" r="170" fill="#fff" opacity=".10"/>${centered(512, 330)}</svg>`,
  square: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<rect width="512" height="512" fill="url(#bg)"/>${centered(512, 330)}</svg>`,
  round: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">${DEFS}<circle cx="256" cy="256" r="256" fill="url(#bg)"/>${centered(512, 300)}</svg>`,
  fg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 56)}</svg>`,
  mono: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">${DEFS}${centered(108, 56, true)}</svg>`,
  splash: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 288 288">${DEFS}${centered(288, 150)}</svg>`,
  feature: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 500">${DEFS}<rect width="1024" height="500" fill="url(#bg)"/>
  <circle cx="900" cy="-40" r="260" fill="#EF5A3C" opacity=".14"/><circle cx="120" cy="560" r="240" fill="#E0417A" opacity=".10"/>
  <g transform="translate(110 130)"><rect width="240" height="240" rx="56" fill="url(#bg)"/>${`<g transform="translate(${120 - 256 * 0.5} ${120 - 254 * 0.5}) scale(0.5)">${ART(false)}</g>`}</g>
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
