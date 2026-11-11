const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [html, out, fps, scenes, only, size] = [process.argv[2], process.argv[3], Number(process.argv[4] || 30), process.argv[5].split(','), process.argv[6], Number(process.argv[7] || 512)];
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 512, height: 512 }, deviceScaleFactor: size / 512 });
  p.on('pageerror', (e) => console.log('PAGE ERROR', e.message));
  for (const sc of scenes) {
    await p.goto('file://' + html + '#' + sc); await p.reload();
    await p.evaluate(() => document.fonts.ready);
    const n = Math.round((await p.evaluate(() => DUR)) * fps);
    fs.mkdirSync(`${out}/${sc}`, { recursive: true });
    const list = only && only !== 'all' ? only.split(',').map((x) => Math.round(Number(x) * fps)) : [...Array(n).keys()];
    for (const i of list) {
      await p.evaluate((t) => draw(t), i / fps);
      await p.screenshot({ path: `${out}/${sc}/f${String(i).padStart(3, '0')}.png`, omitBackground: true });
    }
  }
  await b.close();
})();
