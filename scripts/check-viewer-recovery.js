// Run the shipped viewer controller against deterministic browser and network failures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const controller = fs.readFileSync('Sources/SetbeamApp/Resources/viewer.js', 'utf8');

function browser() {
  let now = 1_000, interval, requests = 0, hung = false;
  const timers = new Map(), readers = [], listeners = {};
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      hidden: false, textContent: '', paused: false, readyState: 4, currentTime: 0, muted: true,
      attributes: {}, addEventListener(name, fn) { listeners[id + ':' + name] = fn; },
      getAttribute(name) { return this.attributes[name]; }, setAttribute(name, value) { this.attributes[name] = value; },
      play() { this.paused = false; return Promise.resolve(); }
    });
    return elements.get(id);
  }
  const state = {state: 'live', title: 'Recovery test', revision: 1};
  const context = {
    document: {getElementById: element, hidden: false, addEventListener(name, fn) { listeners[name] = fn; }},
    navigator: {userAgent: 'test'}, crypto: {randomUUID: () => 'viewer-test'},
    Date: class extends Date { static now() { return now; } },
    AbortController,
    setTimeout(fn, delay) { const id = {}; timers.set(id, {fn, due: now + delay}); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval(fn) { interval = fn; },
    MediaMTXWebRTCReader: class {
      constructor(config) { this.config = config; this.closed = false; readers.push(this); }
      close() { this.closed = true; }
    },
    fetch(url, options = {}) {
      requests++;
      if (hung) return new Promise((resolve, reject) => {
        options.signal?.addEventListener('abort', () => reject(new Error('aborted')), {once: true});
      });
      return Promise.resolve({ok: true, status: 200, json: async () => url === 'config.json'
        ? {whepURL: 'http://localhost/live/whep', user: 'guest', pass: 'synthetic'} : state});
    }
  };
  context.window = {addEventListener(name, fn) { listeners[name] = fn; }};
  vm.runInNewContext(controller, context);
  const settle = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
  return {
    readers, state, elements, listeners, settle,
    get requests() { return requests; }, set hung(value) { hung = value; },
    async tick(ms = 1500) {
      now += ms;
      for (const [id, timer] of [...timers]) if (timer.due <= now) { timers.delete(id); timer.fn(); }
      interval(); await settle();
    },
    async track() {
      readers.at(-1).config.onTrack({streams: [{}]}); await settle();
      const video = element('video'); video.currentTime += 1; listeners['video:timeupdate']();
    }
  };
}

test('a frozen open peer reconnects without a server revision or operator action', async () => {
  const b = browser(); await b.settle(); await b.track();
  assert.equal(b.elements.get('state').textContent, 'Live feed');
  await b.tick(11_000);
  assert.equal(b.readers.length, 2, 'stale decoded frames must replace the peer');
  assert.equal(b.readers[0].closed, true);
  await b.track(); assert.equal(b.elements.get('state').textContent, 'Live feed');
});

test('a hung state request times out and polling resumes when the network returns', async () => {
  const b = browser(); await b.settle(); b.hung = true; await b.tick();
  const before = b.requests;
  await b.tick(6_000); b.hung = false; await b.tick();
  assert.ok(b.requests > before, 'a stalled fetch must not lock polling forever');
  await b.track(); assert.equal(b.elements.get('state').textContent, 'Live feed');
});

test('Hold and Stop close media and never trigger the stale-peer watchdog', async () => {
  for (const mode of ['holding', 'stopped']) {
    const b = browser(); await b.settle(); await b.track(); b.state.state = mode;
    await b.tick(); const count = b.readers.length; await b.tick(30_000);
    assert.equal(b.readers.length, count); assert.equal(b.readers[0].closed, true);
    assert.equal(b.elements.get('video').muted, true);
  }
});

test('a restored page and a publisher revision both reconnect on the same page', async () => {
  const b = browser(); await b.settle(); b.listeners.pagehide();
  b.listeners.pageshow(); await b.settle(); assert.equal(b.readers.length, 2);
  b.state.revision++; await b.tick(); assert.equal(b.readers.length, 3);
});

test('callbacks from a replaced peer cannot attach an old feed', async () => {
  const b = browser(); await b.settle(); const old = b.readers[0];
  b.state.revision++; await b.tick(); await b.track();
  const currentStream = b.elements.get('video').srcObject;
  old.config.onTrack({streams: [{old: true}]}); old.config.onError(); await b.settle();
  assert.equal(b.elements.get('video').srcObject, currentStream);
  assert.equal(b.elements.get('state').textContent, 'Live feed');
});
