// Run the shipped viewer controller against deterministic browser and network failures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const controller = fs.readFileSync('Sources/SetbeamApp/Resources/viewer.js', 'utf8');

function browser(options = {}) {
  let now = 1_000, interval, requests = 0, hung = false, deferState = false, releaseState;
  const timers = new Map(), readers = [], listeners = {}, urls = [], sources = [], locks = [];
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      hidden: false, textContent: '', paused: false, readyState: 4, currentTime: 0, muted: true, plays: 0,
      style: {setProperty(name, value) { this[name] = value; }}, parentElement: {attributes: {}, toggleAttribute(name, enabled) { if (enabled) this.attributes[name] = ''; else delete this.attributes[name]; }}, writes: 0,
      attributes: {}, contains(target) { return target === this; }, addEventListener(name, fn) { listeners[id + ':' + name] = fn; },
      getAttribute(name) { return this.attributes[name]; }, setAttribute(name, value) { this.attributes[name] = value; },
      play() { this.plays++; if (id === 'video' && options.autoplayBlocked) return Promise.reject(new Error('Autoplay blocked')); this.paused = false; return Promise.resolve(); }, pause() { this.paused = true; }
    });
    const el = elements.get(id);
    if (!Object.getOwnPropertyDescriptor(el, 'textContent').get) {
      let value = el.textContent;
      Object.defineProperty(el, 'textContent', {get() { return value; }, set(next) { value = next; this.writes++; }});
    }
    return el;
  }
  const audioListeners = {};
  const audio = {readyState: 'live', muted: !!options.mutedAudio, addEventListener(name, fn) { audioListeners[name] = fn; }};
  const stream = {tracks: options.silent ? [] : [audio], getAudioTracks() { return this.tracks; }, addEventListener(name, fn) { listeners['stream:' + name] = fn; }};
  const state = {state: 'live', title: 'Recovery test', revision: 1};
  const context = {
    document: {getElementById: element, pictureInPictureEnabled: !!options.pip, hidden: false, addEventListener(name, fn) { listeners[name] = fn; }},
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
      requests++; urls.push(url);
      if (deferState && url === 'state.json') {
        // Capture this response now and deliver it only when the test releases it.
        deferState = false; const snapshot = {...state};
        return new Promise(resolve => { releaseState = () => resolve({ok: true, status: 200, json: async () => snapshot}); });
      }
      if (hung) return new Promise((resolve, reject) => {
        options.signal?.addEventListener('abort', () => reject(new Error('aborted')), {once: true});
      });
      return Promise.resolve({ok: true, status: 200, json: async () => url === 'config.json'
        ? {whepURL: 'http://localhost/live/whep', user: 'guest', pass: 'synthetic'} : state});
    }
  };
  element('video').videoWidth = 1920; element('video').videoHeight = 1200;
  element('player').requestFullscreen = () => { context.document.fullscreenElement = element('player'); return Promise.resolve(); };
  context.document.exitFullscreen = () => { context.document.fullscreenElement = null; return Promise.resolve(); };
  element('video').requestPictureInPicture = () => { context.document.pictureInPictureElement = element('video'); return Promise.resolve(); };
  context.document.exitPictureInPicture = () => { context.document.pictureInPictureElement = null; return Promise.resolve(); };
  context.window = {addEventListener(name, fn) { listeners[name] = fn; }};
  if (options.eventSource) context.EventSource = class {
    constructor(url) { this.url = url; this.readyState = 0; sources.push(this); }
    close() { this.readyState = 2; }
  };
  if (options.wakeLock) context.navigator.wakeLock = {request(type) {
    const lock = {type, released: false, release() { this.released = true; return Promise.resolve(); }, addEventListener() {}};
    locks.push(lock); return Promise.resolve(lock);
  }};
  if (options.keepAwakeVideo) context.SetbeamKeepAwakeVideo = 'data:video/mp4;base64,AAAA';
  vm.runInNewContext(controller, context);
  const settle = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
  return {
    readers, state, elements, listeners, settle, sources, locks, context, stream, audio, audioListeners,
    get requests() { return requests; }, set hung(value) { hung = value; },
    deferNextState() { deferState = true; }, async releaseState() { releaseState(); await settle(); },
    count(url) { return urls.filter(value => value === url).length; },
    async push(value = state) {
      const source = sources.at(-1); source.readyState = 1;
      source.onmessage({data: JSON.stringify(value)}); await settle();
    },
    frame() { const video = element('video'); video.currentTime += 1; listeners['video:timeupdate'](); },
    async tick(ms = 1500) {
      now += ms;
      for (const [id, timer] of [...timers]) if (timer.due <= now) { timers.delete(id); timer.fn(); }
      interval(); await settle();
    },
    async track() {
      readers.at(-1).config.onTrack({streams: [stream]}); await settle();
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

test('pushed state replaces polling, and pushed Hold and Stop close media', async () => {
  const b = browser({eventSource: true}); await b.settle();
  assert.equal(b.sources.length, 1, 'the stream opens after the first polled state');
  assert.equal(b.sources[0].url, 'events?id=viewer-test');
  await b.push(); await b.track();
  assert.equal(b.elements.get('state').textContent, 'Live feed');
  const polled = b.count('state.json');
  for (let n = 0; n < 6; n++) await b.tick();
  assert.equal(b.count('state.json'), polled, 'a healthy stream must not poll state');
  await b.push({...b.state, state: 'holding'});
  assert.equal(b.elements.get('state').textContent, 'On hold');
  assert.equal(b.readers[0].closed, true); assert.equal(b.elements.get('video').muted, true);
  await b.push({...b.state, state: 'stopped'});
  assert.equal(b.elements.get('state').textContent, 'Sharing ended');
  assert.equal(b.count('state.json'), polled);
});

test('heartbeats every 3 s while state is pushed, and at once when playback changes', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.push();
  const before = b.count('heartbeat');
  await b.track(); await b.settle();
  assert.equal(b.count('heartbeat'), before + 1, 'the first decoded frame reports playback immediately');
  const start = b.count('heartbeat');
  for (let n = 0; n < 8; n++) { b.frame(); await b.tick(); }
  assert.equal(b.count('heartbeat') - start, 4, '12 s of playback sends four heartbeats instead of eight');
  for (let n = 0; n < 5; n++) await b.tick();
  assert.ok(b.count('heartbeat') - start >= 6, 'stopped playback is reported without waiting for polling');
});

test('a failed or silent stream falls back to polling and reopens later', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.push();
  const failed = b.sources[0], polled = b.count('state.json');
  failed.readyState = 2; failed.onerror(); await b.settle();
  assert.equal(b.count('state.json'), polled + 1, 'an error polls at once');
  await b.tick(); assert.equal(b.count('state.json'), polled + 2, 'polling continues while the stream is down');
  for (let n = 0; n < 11; n++) await b.tick();
  assert.equal(b.sources.length, 2, 'the stream is retried after its delay');
  await b.push(); const silent = b.sources[1], before = b.count('state.json');
  await b.tick(26_000);
  assert.equal(silent.readyState, 2, 'a stream without keepalives is closed');
  assert.equal(b.count('state.json'), before + 1, 'polling resumes after silence');
});

test('the stale-peer watchdog still reconnects while state is pushed', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.push(); await b.track();
  const polled = b.count('state.json');
  await b.tick(11_000);
  assert.equal(b.readers.length, 2, 'stale decoded frames must replace the peer');
  assert.equal(b.readers[0].closed, true);
  assert.equal(b.count('state.json'), polled);
  await b.track(); assert.equal(b.elements.get('state').textContent, 'Live feed');
});

test('Keep screen on requests a screen Wake Lock and releases it when sharing ends', async () => {
  const b = browser({eventSource: true, wakeLock: true}); await b.settle(); await b.push();
  b.listeners['awake:click'](); await b.settle();
  assert.equal(b.locks.length, 1); assert.equal(b.locks[0].type, 'screen');
  assert.equal(b.elements.get('awake').getAttribute('aria-pressed'), 'true');
  b.listeners['sound:click'](); await b.settle();
  assert.equal(b.locks.length, 1, 'another gesture keeps the same lock');
  await b.push({...b.state, state: 'stopped'});
  assert.equal(b.locks[0].released, true);
  assert.equal(b.elements.get('awake').getAttribute('aria-pressed'), 'false');
  assert.equal(b.elements.get('awake').disabled, true);
});

test('without Wake Lock a tap plays the muted fallback clip, and toggling or Stop pauses it', async () => {
  const b = browser({keepAwakeVideo: true}); await b.settle(); await b.track();
  const clip = b.elements.get('keepawake');
  b.listeners['picture:click'](); await b.settle();
  assert.equal(clip.plays, 1); assert.equal(clip.muted, true); assert.match(clip.src, /^data:video\/mp4;base64,/);
  b.listeners['awake:click'](); await b.settle();
  assert.equal(clip.paused, true); assert.equal(b.elements.get('awake').getAttribute('aria-pressed'), 'false');
  b.listeners['fullscreen:click'](); await b.settle();
  assert.equal(clip.plays, 2); assert.equal(clip.paused, false);
  b.state.state = 'stopped'; await b.tick();
  assert.equal(clip.paused, true, 'an ended session releases the fallback');
});

test('a slower poll cannot overwrite a newer pushed state', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.track(); await b.push();
  b.deferNextState(); b.listeners.visibilitychange(); await b.settle();
  await b.push({...b.state, state: 'holding'});
  assert.equal(b.elements.get('state').textContent, 'On hold');
  const count = b.readers.length;
  await b.releaseState();
  assert.equal(b.elements.get('state').textContent, 'On hold', 'the stale live response must not reopen media');
  assert.equal(b.readers.length, count);
});

test('first arrival connects, fresh playback changes the label once, and a real stall reconnects', async () => {
  const b = browser(); await b.settle();
  assert.equal(b.elements.get('state').textContent, 'Connecting');
  await b.track(); const label = b.elements.get('state'), writes = label.writes;
  for (let n = 0; n < 60; n++) b.frame();
  assert.equal(label.writes, writes, 'decoded frames must not rewrite the live announcement');
  await b.tick(7000);
  assert.equal(label.textContent, 'Reconnecting');
});

test('the picture follows display dimensions and audio controls follow live track changes', async () => {
  const b = browser({silent: true}); await b.settle(); await b.track();
  assert.equal(b.elements.get('player').style['--feed-ratio'], 1.6);
  assert.equal(b.elements.get('sound').hidden, true);
  b.stream.tracks.push(b.audio); b.listeners['stream:addtrack']({track: b.audio});
  assert.equal(b.elements.get('sound').hidden, false);
  b.listeners['sound:click'](); await b.settle();
  assert.equal(b.elements.get('sound').getAttribute('aria-label'), 'Mute');
  assert.equal(b.elements.get('sound-icon').getAttribute('href'), '#i-volume');
  b.audio.readyState = 'ended'; b.audioListeners.ended();
  assert.equal(b.elements.get('sound').hidden, true);
  b.elements.get('video').videoWidth = 1440; b.elements.get('video').videoHeight = 1080;
  b.listeners['video:resize']();
  assert.equal(b.elements.get('player').style['--feed-ratio'], 4 / 3);
});

test('fullscreen keeps the whole player and shortcuts ignore editable fields', async () => {
  const b = browser(); await b.settle(); await b.track();
  const key = (value, editable = false) => b.listeners.keydown({key: value, target: {closest: () => editable}, preventDefault() {}});
  key('f', true); assert.equal(b.context.document.fullscreenElement, undefined);
  key('f'); assert.equal(b.context.document.fullscreenElement, b.elements.get('player'));
  b.listeners.fullscreenchange();
  assert.equal(b.elements.get('fullscreen').getAttribute('aria-label'), 'Exit full screen');
  key('m'); await b.settle(); assert.equal(b.elements.get('video').muted, false);
  key('m', true); await b.settle(); assert.equal(b.elements.get('video').muted, false);
  key('f'); assert.equal(b.context.document.fullscreenElement, null);
});

test('Hold closes picture in picture and detaches and mutes its source', async () => {
  const b = browser({pip: true}); await b.settle(); await b.track();
  assert.equal(b.elements.get('pip').hidden, false);
  await b.listeners['pip:click']();
  assert.equal(b.context.document.pictureInPictureElement, b.elements.get('video'));
  b.state.state = 'holding'; await b.tick();
  assert.equal(b.context.document.pictureInPictureElement, null);
  assert.equal(b.elements.get('video').srcObject, null);
  assert.equal(b.elements.get('video').muted, true);
  assert.equal(b.elements.get('pip').disabled, true);
});

test('blocked autoplay offers Play feed, and Hold removes that action', async () => {
  const b = browser({autoplayBlocked: true}); await b.settle(); await b.track();
  assert.equal(b.elements.get('state').textContent, 'Ready to play');
  assert.equal(b.elements.get('retry').hidden, false);
  assert.equal(b.elements.get('retry').getAttribute('aria-label'), 'Play feed');
  assert.equal(b.elements.get('state').className, 'state blocked');
  assert.equal(b.elements.get('slate-icon').parentElement.attributes.hidden, '', 'SVG visibility must use the HTML hidden attribute');
  b.state.state = 'holding'; await b.tick();
  assert.equal(b.elements.get('retry').hidden, true);
  assert.equal(b.elements.get('slate-icon').parentElement.attributes.hidden, undefined);
  assert.equal(b.elements.get('state').textContent, 'On hold');
});

test('a negotiated audio receiver without audio packets offers no sound control', async () => {
  const b = browser({mutedAudio: true}); await b.settle(); await b.track();
  assert.equal(b.stream.getAudioTracks().length, 1, 'WebRTC can negotiate a track for a video-only feed');
  assert.equal(b.elements.get('sound').hidden, true);
  b.audio.muted = false; b.audioListeners.unmute();
  assert.equal(b.elements.get('sound').hidden, false, 'real audio arriving exposes the control');
  b.audio.muted = true; b.audioListeners.mute();
  assert.equal(b.elements.get('sound').hidden, true);
});
