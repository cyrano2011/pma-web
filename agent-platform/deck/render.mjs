import puppeteer from 'puppeteer';
const browser = await puppeteer.launch({
  executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || undefined,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--font-render-hinting=none'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 2 });
await page.goto('file://' + process.argv[2], { waitUntil: 'networkidle0' });
await page.evaluateHandle('document.fonts.ready');

// 슬라이드가 720px 를 넘치지 않는지 검사 (넘치면 내용이 잘린다)
const overflow = await page.evaluate(() => {
  const out = [];
  document.querySelectorAll('.slide').forEach((s, i) => {
    if (s.scrollHeight > 721 || s.scrollWidth > 1281)
      out.push({ slide: i + 1, h: s.scrollHeight, w: s.scrollWidth });
  });
  return out;
});
if (overflow.length) console.log('OVERFLOW: ' + JSON.stringify(overflow));
else console.log('OVERFLOW: none');

await page.pdf({
  path: process.argv[3],
  width: '1280px', height: '720px',
  printBackground: true, preferCSSPageSize: true, margin: { top: 0, right: 0, bottom: 0, left: 0 },
});
await browser.close();
console.log('rendered');
