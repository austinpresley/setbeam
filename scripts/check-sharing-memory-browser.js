// Local Chrome endurance companion to SharingMemorySoakTests. No hosted service.
// PLAYWRIGHT_MODULE=/path/to/playwright-core node scripts/check-sharing-memory-browser.js CONTROL REPORT
const fs = require('node:fs');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const [controlFile, reportFile, ackFile, playwrightModule, chromePath] = process.argv.slice(2);
const {chromium} = require(playwrightModule || process.env.PLAYWRIGHT_MODULE || 'playwright-core');

const MiB = 1024 * 1024;
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const redact = message => message.replace(/\/s\/[^/\s'"]+/g, '/s/<REDACTED>');

async function withDeadline(task, ms) {
  let timer;
  try {
    return await Promise.race([task, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Chrome did not return a video or memory sample within 8 seconds')), ms);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

async function join(browser, url, errors) {
  return Promise.all([['phone', 390, 844], ['tablet', 1024, 768]].map(async ([name, width, height]) => {
    const context = await browser.newContext({viewport: {width, height}, isMobile: true, hasTouch: true});
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(redact(error.message)));
    await page.goto(url, {timeout: 15000});
    await page.locator('#join-name').fill('Memory test ' + name);
    await page.locator('#join-submit').click();
    await page.waitForFunction(() => document.getElementById('state').textContent === 'Live feed' && document.querySelector('video').currentTime > 1, null, {timeout: 30000});
    return {page, name};
  }));
}

async function browserMemory(system) {
  const {processInfo} = await system.send('SystemInfo.getProcessInfo');
  const pids = processInfo.map(process => process.id);
  const rows = execFileSync('/bin/ps', ['-o', 'pid=,rss=', '-p', pids.join(',')], {encoding: 'utf8', timeout: 5000}).trim().split('\n');
  const members = rows.map(line => line.trim().split(/\s+/).map(Number));
  assert.ok(members.some(([pid]) => pid === processInfo.find(process => process.type === 'browser')?.id), 'Missing Chrome root RSS');
  return {pids: members.map(([pid]) => pid), bytes: members.reduce((sum, [, rss]) => sum + rss * 1024, 0)};
}

async function readViewer({page, name}, measureMotion = false) {
  const state = await page.evaluate(measureMotion => {
    const video = document.querySelector('video');
    const ready = video.srcObject && video.readyState >= 2 && video.videoWidth > 0;
    let pixels = null;
    if (ready && measureMotion) {
      const canvas = document.createElement('canvas');
      canvas.width = 32;
      canvas.height = 18;
      const context = canvas.getContext('2d');
      context.drawImage(video, 0, 0, canvas.width, canvas.height);
      pixels = context.getImageData(0, 0, canvas.width, canvas.height).data.reduce(
        (hash, channel) => Math.imul(hash ^ channel, 16777619), 2166136261) >>> 0;
    }
    return {state: document.getElementById('state').textContent, time: video.currentTime, width: video.videoWidth, height: video.videoHeight,
      frames: video.getVideoPlaybackQuality().totalVideoFrames, attached: !!video.srcObject, muted: video.muted,
      heapBytes: performance.memory?.usedJSHeapSize, pixels};
  }, measureMotion);
  assert.ok(!state.heapBytes || state.heapBytes < 128 * MiB, name + ' JavaScript heap exceeded 128 MiB');
  return {name, ...state};
}

async function integrated(browser, pages, errors, controlFile, reportFile, ackFile, initial) {
  const system = await browser.newBrowserCDPSession();
  const began = performance.now();
  const motion = new Map();
  const record = data => fs.appendFileSync(reportFile, JSON.stringify({at: new Date().toISOString(), ...data}) + '\n');
  let phaseID, phaseBegan, acked = false, warmupRSS = 0;
  const detachedSince = new Map();
  while (process.ppid === initial.pid && performance.now() - began < (initial.duration + 600) * 1000) {
    const {phase, step} = read(controlFile);
    const now = performance.now();
    if (phase === 'abort') throw new Error('Mac soak stopped before completion');
    if (phaseID !== step) {
      phaseID = step;
      phaseBegan = now;
      acked = false;
      motion.clear();
      detachedSince.clear();
    }
    const [viewers, {bytes, pids}] = await withDeadline(
      Promise.all([Promise.all(pages.map(page => readViewer(page, true))), browserMemory(system)]), 8000);
    if (phase === 'warmup') warmupRSS = Math.max(warmupRSS, bytes);
    record({phase, step, browserRSSBytes: bytes, warmupRSSBytes: warmupRSS, pids, viewers});
    assert.ok(warmupRSS > 0 && bytes < warmupRSS + 512 * MiB, 'Browser RSS exceeded its warm-up peak by 512 MiB');
    assert.deepEqual(errors, [], 'Viewer JavaScript exceptions');
    const ready = viewers.map(viewer => {
      const previous = motion.get(viewer.name);
      const playing = viewer.state === 'Live feed' && viewer.attached && viewer.pixels !== null;
      const advanced = Boolean(playing && previous && previous.pixels !== null &&
        viewer.pixels !== previous.pixels && viewer.frames > previous.frames && viewer.time > previous.time);
      const lastAdvance = advanced ? now : previous?.lastAdvance ?? phaseBegan;
      motion.set(viewer.name, {pixels: viewer.pixels, frames: viewer.frames, time: viewer.time, lastAdvance});
      if (phase === 'hold' || phase === 'stop') {
        const expected = phase === 'hold' ? 'On hold' : 'Sharing ended';
        const detached = viewer.state === expected && viewer.muted && !viewer.attached;
        if (acked) assert.ok(detached, viewer.name + ' reattached media during ' + phase);
        if (!detached) {
          detachedSince.delete(viewer.name);
          return false;
        }
        const first = detachedSince.get(viewer.name);
        if (!first) {
          detachedSince.set(viewer.name, {at: now, frames: viewer.frames});
          return false;
        }
        assert.equal(viewer.frames, first.frames, viewer.name + ' presented frames after detaching in ' + phase);
        return now - first.at >= 1000;
      }
      if (phase === 'stall') return now - Math.max(phaseBegan, lastAdvance) >= 4000 && !playing;
      if (phase === 'live') {
        assert.ok(now - Math.max(phaseBegan, lastAdvance) < 15000, viewer.name + ' went 15s without moving decoded video');
      }
      return advanced && viewer.frames > 1;
    });
    if (ready.every(Boolean) && !acked) {
      record({event: 'phaseVerified', phase, step, phaseSeconds: (now - phaseBegan) / 1000,
        viewers, detachedSeconds: [...detachedSince].map(([name, first]) => ({name, seconds: (now - first.at) / 1000})),
        secondsSinceMovingFrame: pages.map(({name}) => (now - motion.get(name).lastAdvance) / 1000)});
      fs.writeFileSync(ackFile + '.tmp', JSON.stringify({step}));
      fs.renameSync(ackFile + '.tmp', ackFile);
      if (phase === 'stop') return step;
      acked = true;
    }
    await pause(1000);
  }
  throw new Error('Mac soak exited or exceeded the browser deadline before Stop was verified');
}

async function legacy(browser, pages, errors) {
  const samples = [], stalled = new Map();
  let baselineRSS;
  const system = await browser.newBrowserCDPSession();
  const began = Date.now();
  while (fs.existsSync(controlFile) && Date.now() - began < 4 * 60 * 60 * 1000) {
    const viewers = [];
    for (const page of pages) {
      const state = await readViewer(page);
      const {name} = state;
      const previous = stalled.get(name);
      const since = state.state === 'Live feed' && previous?.time === state.time ? previous.since : Date.now();
      stalled.set(name, {time: state.time, since});
      assert.ok(Date.now() - since < 20000, name + ' decoded video stalled for 20 seconds');
      if (state.state === 'On hold') assert.ok(state.muted && !state.attached, name + ' retained media during Hold');
      viewers.push(state);
    }
    const {bytes: rss} = await browserMemory(system);
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
}

(async () => {
  const control = read(controlFile);
  const {url} = control;
  assert.match(url, /^http:\/\/127\.0\.0\.1:\d+\/s\/[a-zA-Z0-9]+\/$/, 'Expected a private loopback viewer link');
  const browser = await chromium.launch({
    executablePath: chromePath || process.env.SETBEAM_TEST_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true, args: ['--mute-audio', '--enable-precise-memory-info'], timeout: 15000
  });
  const errors = [];
  let stoppedStep;
  try {
    const pages = await join(browser, url, errors);
    if (ackFile) {
      stoppedStep = await integrated(browser, pages, errors, controlFile, reportFile, ackFile, control);
    } else {
      await legacy(browser, pages, errors);
    }
  } finally { await browser.close(); }
  if (ackFile) {
    fs.appendFileSync(reportFile, JSON.stringify({passed: true, stoppedStep}) + '\n');
    process.exit(0);
  }
})().catch(error => { console.error(redact(error.message)); process.exitCode = 1; });
