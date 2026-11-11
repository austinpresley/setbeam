// Local Chrome endurance companion to SharingMemorySoakTests. No hosted service.
// PLAYWRIGHT_MODULE=/path/to/playwright-core node scripts/check-sharing-memory-browser.js CONTROL REPORT
const fs = require('node:fs');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');

(async () => {
  const [controlFile, reportFile] = process.argv.slice(2);
  const {url} = JSON.parse(fs.readFileSync(controlFile, 'utf8'));
  const browser = await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  const errors = [], samples = [], pages = [], stalled = new Map();
  let baselineRSS;
  try {
    for (const [name, width, height] of [['phone', 390, 844], ['tablet', 1024, 768]]) {
      const context = await browser.newContext({viewport: {width, height}, isMobile: true, hasTouch: true});
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(error.message.replace(/\/s\/[^/\s]+/g, '/s/<REDACTED>')));
      await page.goto(url);
      await page.locator('#join-name').fill('Memory test ' + name);
      await page.locator('#join-submit').click();
      await page.waitForFunction(() => document.getElementById('state').textContent === 'Live feed' && document.querySelector('video').currentTime > 1, null, {timeout: 30000});
      pages.push({page, name});
    }
    const system = await browser.newBrowserCDPSession();
    const began = Date.now();
    while (fs.existsSync(controlFile) && Date.now() - began < 4 * 60 * 60 * 1000) {
      const viewers = [];
      for (const {page, name} of pages) {
        const state = await page.evaluate(() => {
          const video = document.querySelector('video');
          return {state: document.getElementById('state').textContent, time: video.currentTime, width: video.videoWidth, height: video.videoHeight,
            frames: video.getVideoPlaybackQuality().totalVideoFrames, attached: !!video.srcObject, muted: video.muted,
            heapBytes: performance.memory?.usedJSHeapSize};
        });
        const previous = stalled.get(name);
        const since = state.state === 'Live feed' && previous?.time === state.time ? previous.since : Date.now();
        stalled.set(name, {time: state.time, since});
        assert.ok(Date.now() - since < 20000, name + ' decoded video stalled for 20 seconds');
        if (state.state === 'On hold') assert.ok(state.muted && !state.attached, name + ' retained media during Hold');
        assert.ok(!state.heapBytes || state.heapBytes < 128 * 1024 * 1024, name + ' JavaScript heap exceeded 128 MiB');
        viewers.push({name, ...state});
      }
      const {processInfo} = await system.send('SystemInfo.getProcessInfo');
      const ids = processInfo.map(process => String(process.id)).join(',');
      const rss = execFileSync('/bin/ps', ['-o', 'rss=', '-p', ids], {encoding: 'utf8'}).trim().split(/\s+/).reduce((sum, value) => sum + Number(value) * 1024, 0);
      baselineRSS ??= rss;
      assert.ok(rss < baselineRSS + 512 * 1024 * 1024, 'Browser process RSS grew by more than 512 MiB');
      assert.deepEqual(errors, [], 'Viewer JavaScript exceptions');
      samples.push({seconds: (Date.now() - began) / 1000, browserRSSBytes: rss, viewers});
      fs.writeFileSync(reportFile, JSON.stringify({passed: false, running: true, samples}, null, 2));
      console.log(JSON.stringify(samples.at(-1)));
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
    assert.ok(samples.length >= 2, 'Too few browser memory samples');
    fs.writeFileSync(reportFile, JSON.stringify({passed: true, running: false, samples}, null, 2));
    console.log('PASS: two decoded viewers stayed within the browser memory budget');
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
