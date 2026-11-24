// Run the shipped viewer controller against deterministic browser and network failures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const controller = fs.readFileSync('Sources/SetbeamApp/Resources/viewer.js', 'utf8');

function browser(options = {}) {
  let joinValue = options.join, heartbeatValue;
  const joinResponse = () => joinValue;
  const configHeaders = [];
  let now = 1_000, interval, requests = 0, hung = false, deferState = false, releaseState;
  const timers = new Map(), readers = [], listeners = {}, urls = [], sources = [], locks = [], heartbeats = [], joins = [], tabMessages = [];
  let joinFails = false, stateGone = false, config = {whepURL: 'http://localhost/live/whep', user: 'guest', pass: 'synthetic'};
  const queuedResponses = new Map(), chatUpdates = [], chatActivity = [];
  let clipFails = options.clipFails, unmuteFails = options.unmuteFails, uuidCounter = 0;
  // Elements inside the join page, for focus checks.
  const joinParts = new Set(['join-title', 'join-name', 'join-submit', 'join-cancel', 'join-retry', 'join-form', 'join-status']);
  // Most checks describe a tab that already chose its name and color; identity checks pass their own storage.
  const storage = new Map(Object.entries(options.storage || {'setbeam-viewer-name': 'Test viewer', 'setbeam-pointer-color': 'blue'}));
  const created = [];
  function create(tag) {
    const node = {tag, style: {setProperty(name, value) { this[name] = value; }}, attributes: {}, events: {}, children: [], checked: false,
      setAttribute(name, value) { this.attributes[name] = value; }, addEventListener(name, fn) { this.events[name] = fn; },
      append(...items) { this.children.push(...items); }, focus() { context.document.activeElement = this; }};
    created.push(node); return node;
  }
  let stats, statsError = false, resolveStats, frameCallback, frames = 0, canceledFrames = 0;
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      hidden: ['chat-menu', 'chat-information'].includes(id), textContent: '', paused: false, readyState: 4, currentTime: 0, muted: true, plays: 0,
      style: {setProperty(name, value) { this[name] = value; }}, parentElement: {attributes: {}, toggleAttribute(name, enabled) { if (enabled) this.attributes[name] = ''; else delete this.attributes[name]; }}, writes: 0,
      attributes: {}, contains(target) { return target === this || (id === 'join' && joinParts.has(target?.id)); }, addEventListener(name, fn) { listeners[id + ':' + name] = fn; },
      children: [], append(...items) { this.children.push(...items); },
      id, focuses: 0,
      getAttribute(name) { return this.attributes[name]; }, setAttribute(name, value) { this.attributes[name] = value; },
      focus() { context.document.activeElement = this; this.focuses++; },
      play() {
        this.plays++;
        if (id === 'keepawake' && clipFails || id === 'video' && unmuteFails && !this.muted) {
          this.paused = true; return Promise.reject(Object.assign(new Error('Playback blocked'), {name: 'NotAllowedError'}));
        }
        // Browsers reject blocked autoplay with NotAllowedError, and a replaced source with AbortError.
        if (id === 'video' && options.autoplayBlocked) return Promise.reject(Object.assign(new Error('Autoplay blocked'), {name: 'NotAllowedError'}));
        if (id === 'video' && options.playInterrupted) return Promise.reject(Object.assign(new Error('The play() request was interrupted by a new load request.'), {name: 'AbortError'}));
        this.paused = false; return Promise.resolve();
      }, pause() { this.paused = true; }
    });
    const el = elements.get(id);
    if (!Object.getOwnPropertyDescriptor(el, 'textContent').get) {
      let value = el.textContent;
      Object.defineProperty(el, 'textContent', {get() { return value; }, set(next) { value = next; this.writes++; }});
    }
    return el;
  }
  const audioListeners = {};
  const audio = {kind: 'audio', readyState: 'live', muted: !!options.mutedAudio, addEventListener(name, fn) { audioListeners[name] = fn; }};
  const videoTrack = {kind: 'video', readyState: 'live', muted: false, addEventListener() {}};
  class MediaStream {
    constructor() { this.tracks = []; this.videoTracks = []; }
    getAudioTracks() { return this.tracks; }
    getVideoTracks() { return this.videoTracks; }
    getTracks() { return [...this.videoTracks, ...this.tracks]; }
    addTrack(track) { (track.kind === 'video' ? this.videoTracks : this.tracks).push(track); }
    addEventListener(name, fn) {
      const key = 'stream:' + name, previous = listeners[key];
      listeners[key] = event => { previous?.(event); fn(event); };
    }
  }
  const stream = new MediaStream();
  stream.addTrack(videoTrack);
  if (!options.silent) stream.addTrack(audio);
  const state = {state: 'live', title: 'Recovery test', revision: 1};
  const context = {
    document: {getElementById: element, createElement: create, pictureInPictureEnabled: !!options.pip, hidden: false, addEventListener(name, fn) { listeners[name] = fn; }, body: {id: 'body'}},
    matchMedia: query => ({matches: query === '(pointer: fine)' && !!options.finePointer}),
    navigator: {userAgent: 'test'}, crypto: {randomUUID: () => uuidCounter++ === 0 ? 'viewer-test' :
      '00000000-0000-4000-8000-' + String(uuidCounter).padStart(12, '0')},
    sessionStorage: {getItem(key) { return storage.get(key); }, setItem(key, value) { storage.set(key, value); }, removeItem(key) { storage.delete(key); }},
    Date: class extends Date { static now() { return now; } },
    AbortController, MediaStream,
    setTimeout(fn, delay) { const id = {}; timers.set(id, {fn, due: now + delay}); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval(fn) { interval = fn; return fn; }, clearInterval(id) { if (id === interval) interval = undefined; },
    MediaMTXWebRTCReader: class {
      constructor(config) {
        this.config = config; this.closed = false; readers.push(this);
        if (options.stats) this.getStats = () => {
          if (statsError) return Promise.reject(new Error('Statistics unavailable'));
          if (options.deferStats) return new Promise(resolve => { resolveStats = resolve; });
          return Promise.resolve(stats || new Map());
        };
      }
      close() { this.closed = true; }
    },
    fetch(url, request = {}) {
      const options = {...request, join: joinResponse()};
      requests++; urls.push(url);
      if (url === 'heartbeat') heartbeats.push(JSON.parse(options.body));
      if (url === 'config.json') configHeaders.push(request.headers || {});
      if (url === 'join') joins.push(JSON.parse(request.body));
      const queued = queuedResponses.get(url);
      if (queued?.length) return queued.shift()(request);
      if (deferState && url === 'state.json') {
        // Capture this response now and deliver it only when the test releases it.
        deferState = false; const snapshot = {...state};
        return new Promise(resolve => { releaseState = () => resolve({ok: true, status: 200, json: async () => snapshot}); });
      }
      if (hung) return new Promise((resolve, reject) => {
        options.signal?.addEventListener('abort', () => reject(new Error('aborted')), {once: true});
      });
      // Stop and a changed code both retire the link, so its state is gone too.
      if (url === 'state.json' && stateGone) return Promise.resolve({ok: false, status: 404, json: async () => ({})});
      if (url === 'heartbeat' && heartbeatValue) return Promise.resolve({ok: true, status: 200, json: async () => heartbeatValue});
      if (url === 'join') {
        const body = JSON.parse(request.body);
        if (joinFails) return Promise.reject(new TypeError('Failed to fetch'));
        const join = (typeof options.join === 'function' ? options.join(body) : options.join) || {pass: 'a'.repeat(48), number: 1, admission: 'admitted', ready: true, color: 'blue'};
        return Promise.resolve({ok: !join.status, status: join.status || 200, json: async () => join});
      }
      return Promise.resolve({ok: true, status: 200, json: async () => url === 'config.json'
        ? config : state});
    }
  };
  if (options.plainHTTP) context.crypto = {getRandomValues: bytes => bytes.fill(255)};
  if (!options.noFrameCounter) element('video').getVideoPlaybackQuality = () => ({totalVideoFrames: frames, droppedVideoFrames: 0});
  if (options.frameCallback) {
    element('video').requestVideoFrameCallback = fn => { frameCallback = fn; return fn; };
    element('video').cancelVideoFrameCallback = fn => {
      canceledFrames++; if (frameCallback === fn) frameCallback = undefined;
    };
  }
  if (options.chat) context.SetbeamChat = {attach(viewer) {
    chatUpdates.viewer = viewer;
    return {update(value) { chatUpdates.push(value); }, activity(value) { chatActivity.push(value); }};
  }};
  if (options.tabClaims) context.BroadcastChannel = class {
    postMessage(message) {
      tabMessages.push(message);
      if (options.existingTab && message.type === 'claim') {
        this.onmessage({data: {type: 'occupied', key: message.key, sender: 'existing-viewer', target: message.sender}});
      }
    }
    close() {}
  };
  element('retry').setAttribute('aria-label', 'Play feed');
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
    let notify;
    const lock = {type, released: false, release() { this.released = true; notify?.(); return Promise.resolve(); },
      addEventListener(name, fn) { if (name === 'release') notify = fn; }};
    locks.push(lock); return Promise.resolve(lock);
  }};
  if (options.keepAwakeVideo) context.SetbeamKeepAwakeVideo = 'data:video/mp4;base64,AAAA';
  const pointerUpdates = [];
  const palette = {blue: ['#1a5ed9', '#fff'], teal: ['#0b7480', '#fff'], brown: ['#8a5526', '#fff']};
  pointerUpdates.identityChanges = 0;
  if (options.pointers) context.SetbeamPointers = {COLORS: palette, attach(viewer) {
    pointerUpdates.viewer = viewer;
    return {color: () => viewer.color(), identityChanged() { pointerUpdates.identityChanges++; }, update(value) { pointerUpdates.push(value); }};
  }};
  else context.SetbeamPointers = {COLORS: palette, attach() { return undefined; }};
  vm.runInNewContext(controller, context);
  const settle = async () => { for (let n = 0; n < 120; n++) await Promise.resolve(); };
  function frame() {
    const video = element('video'); video.currentTime += 1;
    frames++;
    if (options.frameCallback) frameCallback?.(now, {presentedFrames: frames});
    else listeners['video:timeupdate']();
  }
  function queueResponse(url, fn) {
    if (!queuedResponses.has(url)) queuedResponses.set(url, []);
    queuedResponses.get(url).push(fn);
  }
  return {
    chatUpdates, chatActivity, videoTrack, tabMessages,
    get frameCallback() { return frameCallback; }, get canceledFrames() { return canceledFrames; },
    set config(value) { config = value; }, set clipFails(value) { clipFails = value; },
    set unmuteFails(value) { unmuteFails = value; },
    defer(url, body, status = 200) {
      let release, signal;
      queueResponse(url, request => {
        signal = request.signal;
        return new Promise(resolve => {
          release = () => resolve({ok: status >= 200 && status < 300, status, json: async () => body});
        });
      });
      return {get signal() { return signal; }, async release() { release(); await settle(); }};
    },
    rejectNext(url) { queueResponse(url, () => Promise.reject(new Error('Connection unavailable'))); },
    pointerUpdates, set join(value) { joinValue = value; }, set heartbeatResponse(value) { heartbeatValue = value; }, configHeaders,
    readers, state, elements, listeners, settle, sources, locks, context, stream, audio, audioListeners, heartbeats, storage, joins, urls,
    set joinFails(value) { joinFails = value; }, set stateGone(value) { stateGone = value; }, el: element,
    async submit(name) { element('join-name').value = name; listeners['join-form:submit']({preventDefault() {}}); await settle(); },
    // Picks a swatch on the join card, as a click on its radio input would.
    pick(color) { const input = created.find(node => node.tag === 'input' && node.value === color); input.checked = true; input.events.change(); },
    swatches() { return created.filter(node => node.tag === 'input').map(node => node.value); },
    set stats(value) { stats = value; }, set statsError(value) { statsError = value; },
    async releaseStats(value) { resolveStats(value); await settle(); },
    get requests() { return requests; }, set hung(value) { hung = value; },
    deferNextState() { deferState = true; }, async releaseState() { releaseState(); await settle(); },
    count(url) { return urls.filter(value => value === url).length; },
    async push(value = state) {
      const source = sources.at(-1); source.readyState = 1;
      source.onmessage({data: JSON.stringify(value)}); await settle();
    },
    frame,
    async tick(ms = 1500) {
      now += ms;
      for (const [id, timer] of [...timers]) if (timer.due <= now) { timers.delete(id); timer.fn(); }
      interval?.(); await settle();
    },
    async track() {
      readers.at(-1).config.onTrack({streams: [stream], track: videoTrack}); await settle();
      frame();
    }
  };
}

test('a duplicated tab opens a separate request without sharing the original pass', async () => {
  const oldPass = '1'.repeat(48);
  const b = browser({tabClaims: true, existingTab: true, storage: {
    'setbeam-viewer-name': 'Test viewer', 'setbeam-pass:': oldPass, 'setbeam-pass::tab': 'copied-tab-key'
  }});
  await b.settle();
  assert.equal(b.joins[0].pass, undefined);
  assert.equal(b.tabMessages[0].key, 'copied-tab-key');
  assert.ok(!JSON.stringify(b.tabMessages).includes(oldPass));
});

test('a reloaded tab with no live sibling keeps its existing pass', async () => {
  const oldPass = '1'.repeat(48);
  const b = browser({tabClaims: true, storage: {
    'setbeam-viewer-name': 'Test viewer', 'setbeam-pass:': oldPass, 'setbeam-pass::tab': 'owned-tab-key'
  }});
  await b.settle();
  assert.equal(b.count('join'), 0);
  await b.tick(200);
  assert.equal(b.joins[0].pass, oldPass);
});

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

test('a playing picture keeps the screen on with a Wake Lock until sharing ends', async () => {
  const b = browser({eventSource: true, wakeLock: true}); await b.settle(); await b.push();
  assert.equal(b.locks.length, 0, 'nothing is held before the picture plays');
  await b.track(); await b.settle();
  assert.equal(b.locks.length, 1); assert.equal(b.locks[0].type, 'screen');
  b.listeners['sound:click'](); await b.settle();
  assert.equal(b.locks.length, 1, 'another gesture keeps the same lock');
  await b.push({...b.state, state: 'stopped'});
  assert.equal(b.locks[0].released, true);
});

test('without Wake Lock playback starts the muted fallback clip, and Stop pauses it', async () => {
  const b = browser({keepAwakeVideo: true}); await b.settle();
  const clip = b.elements.get('keepawake');
  assert.equal(clip.plays, 0, 'the join and connecting steps do not hold the screen');
  await b.track(); await b.settle();
  assert.equal(clip.plays, 1); assert.equal(clip.muted, true); assert.match(clip.src, /^data:video\/mp4;base64,/);
  b.listeners['picture:click'](); await b.settle();
  assert.equal(clip.plays, 1, 'a tap keeps the same clip');
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

test('tooltips name each shortcut, and P and C press only visible, enabled controls', async () => {
  const b = browser(); await b.settle(); await b.track();
  b.listeners.fullscreenchange();
  assert.equal(b.el('fullscreen').getAttribute('aria-label'), 'Enter full screen');
  assert.equal(b.el('fullscreen').getAttribute('title'), 'Enter full screen (F)');
  b.listeners['sound:click'](); await b.settle();
  assert.equal(b.el('sound').getAttribute('aria-label'), 'Mute'); assert.equal(b.el('sound').getAttribute('title'), 'Mute (M)');
  const key = value => b.listeners.keydown({key: value, target: {closest: () => false}, preventDefault() {}});
  let chats = 0, points = 0;
  b.el('chat-toggle').click = () => chats++; b.el('pointer').click = () => points++;
  key('c'); key('P'); assert.deepEqual([chats, points], [1, 1]);
  b.el('chat-toggle').hidden = true; b.el('pointer').disabled = true;
  key('c'); key('p'); assert.deepEqual([chats, points], [1, 1]);
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

test('an interrupted play request is not blocked playback, and the stale-peer watchdog still reconnects', async () => {
  // A second track replaced the source while the first play() was pending; 4K frames had not yet decoded.
  const b = browser({playInterrupted: true}); await b.settle(); await b.track();
  assert.notEqual(b.elements.get('state').textContent, 'Ready to play');
  assert.equal(b.elements.get('retry').hidden, true);
  const readers = b.readers.length;
  await b.tick(11000);
  assert.ok(b.readers.length > readers, 'a peer that never decodes must still be replaced');
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

function reception(packets, lost = 0, jitter = 0.005, rtt = 0.01, decoded = packets, dropped = 0, id = 'video') {
  return new Map([
    [id, {id, type: 'inbound-rtp', kind: 'video', packetsReceived: packets, packetsLost: lost, jitter,
      framesDecoded: decoded, framesDropped: dropped, timestamp: packets + lost, transportId: 'transport'}],
    ['transport', {selectedCandidatePairId: 'pair'}], ['pair', {currentRoundTripTime: rtt}]
  ]);
}
async function sample(b, stats) {
  b.stats = stats; b.frame(); await b.tick(3000);
}

test('a new tab chooses one name and color before it plays, with approval off', async () => {
  const b = browser({storage: {}}); await b.settle(); await b.tick();
  assert.equal(joinVisible(b), true, 'The join card comes first');
  assert.equal(b.el('join-title').textContent, 'Join this feed'); assert.equal(b.el('join-submit').textContent, 'Join');
  assert.equal(b.el('state').textContent, 'Joining');
  assert.equal(b.count('join'), 0, 'Nothing is sent before the viewer chooses');
  assert.equal(b.count('config.json'), 0); assert.equal(b.readers.length, 0);
  assert.equal(b.swatches().length, 3, 'Every palette color is offered');
  assert.match(b.el('join-hint').textContent, /The operator sees your name\. Other viewers see it on your chat messages\./);
  b.pick('teal');
  await b.submit('  Alex\n\u202e  ' + 'x'.repeat(70));
  const sent = b.joins.at(-1);
  assert.equal(sent.name.length, 40); assert.ok(!sent.name.includes('\u202e')); assert.ok(!sent.name.includes('\n'));
  assert.equal(sent.color, 'teal'); assert.equal(sent.ask, true);
  assert.equal(b.storage.get('setbeam-viewer-name'), sent.name); assert.equal(b.storage.get('setbeam-pointer-color'), 'teal');
  assert.equal(joinVisible(b), false); assert.equal(b.readers.length, 1, 'The picture plays after joining');
  await b.track(); await b.tick(3000);
  assert.deepEqual({name: b.heartbeats.at(-1).name, color: b.heartbeats.at(-1).color}, {name: sent.name, color: 'teal'});
  assert.equal(b.el('identity-avatar').textContent, 'A', 'The corner avatar shows the same identity');
  assert.equal(b.el('identity-avatar').style['--c'], '#0b7480');
  assert.match(b.el('identity-button').getAttribute('aria-label'), /^Alex x+\. Change name or color$/);
  const reload = browser({storage: Object.fromEntries(b.storage)}); await reload.settle();
  assert.equal(joinVisible(reload), false, 'A reload keeps the identity without asking again');
  assert.deepEqual({name: reload.joins[0].name, color: reload.joins[0].color}, {name: sent.name, color: 'teal'});
});

test('an empty name is not sent, and shared pointers are named in the hint', async () => {
  const b = browser({storage: {}}); await b.settle();
  b.state.pointers = true; await b.tick();
  assert.match(b.el('join-hint').textContent, /Other viewers see it on your chat messages and when you point/);
  await b.submit('   ');
  assert.equal(b.count('join'), 0); assert.equal(b.el('join-status').textContent, 'Enter a name the operator will recognize.');
});

test('health needs sustained measurements and remains good at one decoded frame per sample', async () => {
  const b = browser({eventSource: true, stats: true}); await b.settle(); await b.push(); await b.track();
  for (let n = 1; n <= 5; n++) await sample(b, reception(n * 100, 0, 0.005, 0.01, n));
  assert.equal(b.heartbeats.at(-1).health, 'good');
  assert.equal(b.readers.length, 1, 'health never opens another peer');
  await sample(b, reception(600, 30));
  await sample(b, reception(700, 30));
  assert.equal(b.heartbeats.at(-1).health, 'good', 'one bad interval must not flash a warning');
  for (let n = 8; n <= 11; n++) await sample(b, reception(n * 100, 30 + (n - 7) * 20));
  assert.equal(b.heartbeats.at(-1).health, 'struggling');
  for (let n = 12; n <= 15; n++) await sample(b, reception(n * 100, 110));
  assert.equal(b.heartbeats.at(-1).health, 'good', 'two clean intervals recover the indicator');
});

test('sustained jitter, round trip delay, and dropped frames each report struggling', async () => {
  for (const problem of ['jitter', 'rtt', 'drops']) {
    const b = browser({eventSource: true, stats: true}); await b.settle(); await b.push(); await b.track();
    for (let n = 1; n <= 5; n++) await sample(b, reception(n * 100, 0, problem === 'jitter' ? 0.15 : 0.005,
      problem === 'rtt' ? 0.5 : 0.01, n * 10, problem === 'drops' ? n * 10 : 0));
    assert.equal(b.heartbeats.at(-1).health, 'struggling', problem);
  }
});

test('unsupported or failed statistics keep fresh playback visible without inventing a score', async () => {
  for (const options of [{}, {stats: true}]) {
    const b = browser({...options, eventSource: true}); await b.settle(); await b.push(); await b.track();
    await sample(b, new Map()); await sample(b, new Map());
    assert.equal(b.heartbeats.at(-1).health, 'playing');
    b.statsError = true; await sample(b, reception(100)); await sample(b, reception(200));
    assert.equal(b.heartbeats.at(-1).health, 'playing'); assert.equal(b.readers.length, 1);
  }
});

test('background, blocked, paused, and stalled playback have distinct health states', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.push(); await b.track();
  b.context.document.hidden = true; b.listeners.visibilitychange(); await b.settle();
  assert.equal(b.heartbeats.at(-1).health, 'background');
  b.context.document.hidden = false; b.listeners.visibilitychange(); await b.settle();
  b.elements.get('video').paused = true; b.listeners['video:pause'](); await b.settle();
  assert.equal(b.heartbeats.at(-1).health, 'paused');
  b.elements.get('video').paused = false; await b.tick(7000);
  assert.equal(b.heartbeats.at(-1).health, 'reconnecting');
  const blocked = browser({eventSource: true, autoplayBlocked: true}); await blocked.settle(); await blocked.push(); await blocked.track();
  await blocked.tick(3000); assert.equal(blocked.heartbeats.at(-1).health, 'ready');
});

test('late statistics from a replaced peer cannot change the new viewer health', async () => {
  const b = browser({eventSource: true, stats: true, deferStats: true}); await b.settle(); await b.push(); await b.track();
  await b.tick(3000);
  await b.push({...b.state, state: 'holding'});
  const old = reception(500, 200);
  Object.assign(old.get('video'), {frameWidth: 1920, frameHeight: 1080, framesPerSecond: 30});
  await b.releaseStats(old);
  await b.push({...b.state, revision: 2}); await b.track();
  await b.tick(3000);
  assert.equal(b.heartbeats.at(-1).health, 'checking');
  assert.equal(b.heartbeats.at(-1).measurements, undefined);
});

test('heartbeats report sparse current inbound video measurements and clear them on pause', async () => {
  const b = browser({eventSource: true, stats: true}); await b.settle(); await b.push(); await b.track();
  const full = reception(100);
  Object.assign(full.get('video'), {frameWidth: 1920, frameHeight: 1080, framesPerSecond: 182});
  await sample(b, full);
  const settled = reception(200);
  Object.assign(settled.get('video'), {frameWidth: 1920, frameHeight: 1080, framesPerSecond: 29.97});
  await sample(b, settled);
  assert.deepEqual(b.heartbeats.at(-1).measurements, {width: 1920, height: 1080, droppedFrames: 0, ageMs: 3000},
    'do not report the startup decode burst as the picture cadence');
  const partial = new Map([['video', {type: 'inbound-rtp', kind: 'video', frameWidth: 0, frameHeight: 1080,
    framesPerSecond: 1, framesDropped: '0'}]]);
  await sample(b, partial);
  assert.deepEqual(b.heartbeats.at(-1).measurements, {width: 1920, height: 1080, fps: 29.97, droppedFrames: 0, ageMs: 3000});
  await sample(b, partial);
  assert.deepEqual(b.heartbeats.at(-1).measurements, {fps: 1, ageMs: 3000});
  b.elements.get('video').paused = true; b.listeners['video:pause'](); await b.settle();
  assert.equal(b.heartbeats.at(-1).measurements, undefined);
});

test('slow statistics cannot refresh an expired measurement', async () => {
  const b = browser({eventSource: true, stats: true, deferStats: true}); await b.settle(); await b.push(); await b.track();
  await b.tick(3000);
  for (let i = 0; i < 3; i++) { b.frame(); await b.tick(3000); }
  await b.releaseStats(reception(100));
  b.frame(); await b.tick(3000);
  assert.equal(b.heartbeats.at(-1).measurements, undefined);
});

const pass = 'b'.repeat(48);
test('approval asks for a name before requesting access and fetches nothing playable', async () => {
  const b = browser({join: {status: 400}}); b.state.approval = true; await b.settle();
  assert.equal(b.elements.get('join-form').hidden, false);
  assert.equal(b.elements.get('state').textContent, 'Ask to join');
  assert.equal(b.count('config.json'), 0); assert.equal(b.readers.length, 0);
  b.elements.get('join-name').value = '   ';
  b.listeners['join-form:submit']({preventDefault() {}}); await b.settle();
  assert.equal(b.count('join'), 1, 'An empty name is not sent');
  b.join = {pass, number: 4, admission: 'pending', ready: false, color: 'blue', name: 'Sam'};
  b.elements.get('join-name').value = ' Sam ';
  b.listeners['join-form:submit']({preventDefault() {}}); await b.settle();
  assert.equal(b.elements.get('state').textContent, 'Waiting to join');
  assert.equal(b.elements.get('join-form').hidden, true);
  assert.equal(b.storage.get('setbeam-pass:'), pass, 'The tab keeps its pass across reloads');
  await b.tick(); await b.tick();
  assert.equal(b.count('config.json'), 0, 'A waiting page never asks for playback details');
  assert.equal(b.readers.length, 0);
  b.join = {pass, number: 4, admission: 'admitted', ready: true, color: 'blue', name: 'Sam'};
  await b.tick();
  assert.equal(b.readers.length, 1, 'Admission starts playback');
  assert.equal(b.configHeaders.at(-1)['X-Setbeam-Pass'], pass);
});

test('removal reported by the gateway ends playback and the page stops asking', async () => {
  const b = browser({join: {pass, number: 2, admission: 'admitted', ready: true, color: 'blue'}}); await b.settle(); await b.track();
  assert.equal(b.elements.get('state').textContent, 'Live feed');
  b.heartbeatResponse = {ok: true, admission: 'removed'};
  await b.tick(); await b.tick();
  assert.equal(b.readers.at(-1).closed, true);
  assert.equal(b.elements.get('state').textContent, 'Removed');
  const requests = b.requests;
  await b.tick(); await b.tick(); await b.tick();
  assert.equal(b.count('config.json'), 1, 'No new playback request after removal');
  assert.ok(b.requests - requests <= 3, 'A removed page does not poll the gateway');
});

test('a reloaded removed or declined tab stays refused', async () => {
  for (const admission of ['removed', 'declined']) {
    const b = browser({storage: {'setbeam-pass:': pass}, join: {pass, number: 2, admission, ready: false, color: 'blue'}}); await b.settle();
    assert.equal(b.count('config.json'), 0);
    assert.equal(b.elements.get('state').textContent, admission === 'removed' ? 'Removed' : 'Not admitted');
  }
});

test('an unknown pass, such as after a new link, joins again instead of reusing old details', async () => {
  const b = browser({join: {pass, number: 2, admission: 'admitted', ready: true, color: 'blue'}}); await b.settle(); await b.track();
  b.heartbeatResponse = {ok: false, admission: 'unknown'};
  await b.tick(); await b.tick();
  assert.equal(b.readers.at(-1).closed, true);
  b.heartbeatResponse = {ok: true, admission: 'admitted'};
  const joins = b.count('join');
  await b.tick();
  assert.ok(b.count('join') > joins);
});

test('pointing is offered only while admitted, enabled, and the session continues', async () => {
  const b = browser({eventSource: true, pointers: true, storage: {'setbeam-pass:': pass}, join: {pass, number: 2, admission: 'admitted', ready: true, color: 'blue'}});
  await b.settle();
  await b.push({...b.state, pointers: true}); await b.track();
  assert.deepEqual({...b.pointerUpdates.at(-1)}, {enabled: true, live: true, revision: 1, displayedRevision: 1, suspended: false});
  assert.equal(b.pointerUpdates.viewer.nameLocked(), false);
  await b.push({...b.state, approval: true, pointers: true});
  assert.equal(b.pointerUpdates.viewer.nameLocked(), false, 'A session admitted unnamed before approval may name itself once');
  // Pointing without a name opens the one join card rather than a second name field.
  b.pointerUpdates.viewer.editIdentity(); await b.settle();
  assert.equal(b.el('join-title').textContent, 'Your name and color'); assert.equal(b.el('join-name').readOnly, false);
  b.pick('brown'); await b.submit(' Ana ');
  assert.equal(b.pointerUpdates.viewer.name(), 'Ana'); assert.equal(b.pointerUpdates.viewer.color(), 'brown');
  assert.equal(b.pointerUpdates.identityChanges, 1, 'An open pointer channel announces the new identity');
  assert.equal(b.pointerUpdates.viewer.nameLocked(), true, 'Under approval the name is then fixed');
  await b.push({...b.state, state: 'holding', pointers: true});
  assert.equal(b.pointerUpdates.at(-1).live, false, 'Hold stops pointing');
  await b.push({...b.state, state: 'stopped', pointers: true});
  assert.equal(b.pointerUpdates.at(-1).enabled, false, 'Stop ends pointing');
  const c = browser({eventSource: true, pointers: true, join: {pass, number: 3, admission: 'admitted', ready: true, color: 'blue'}});
  await c.settle(); await c.push({...c.state, pointers: true}); await c.track();
  c.heartbeatResponse = {ok: true, admission: 'removed'};
  await c.tick(); await c.tick();
  assert.equal(c.pointerUpdates.at(-1).enabled, false, 'Removal ends pointing');
});

// A small model of the gateway's admission rules for join-page tests.
function gateway(options = {}) {
  const model = {approval: options.approval ?? true, admission: 'pending', requests: 0, lapsed: false, full: false, gone: false};
  model.join = body => {
    if (model.gone) return {status: 404};
    if (body.pass === pass && !model.lapsed) return {pass, number: 4, admission: model.approval || model.admission !== 'pending' ? model.admission : 'admitted',
      ready: model.admission === 'admitted' || !model.approval, color: 'blue', name: body.name ?? 'Sam'};
    if (model.approval && !(body.ask && body.name)) return {status: 400};
    if (model.full) return {status: 503};
    model.requests++; model.lapsed = false;
    return {pass, number: 4, admission: model.approval ? 'pending' : 'admitted', ready: !model.approval, color: 'blue', name: body.name};
  };
  return model;
}
const joinVisible = b => b.el('join').hidden === false && (b.el('player').className.includes('join-open') || b.el('player').className.includes('identity-open'));

test('a saved name prefills Ask to join, and only the viewer sends a request', async () => {
  const g = gateway();
  const b = browser({join: g.join, storage: {'setbeam-viewer-name': 'Sam'}}); b.state.approval = true; await b.settle();
  assert.equal(b.joins[0].ask, undefined, 'The first join only learns this tab\'s state');
  assert.equal(g.requests, 0, 'A saved name never asks on its own');
  assert.ok(joinVisible(b), 'The join page replaces the picture and controls');
  assert.equal(b.el('join-form').hidden, false); assert.equal(b.el('join-name').value, 'Sam');
  assert.equal(b.el('state').textContent, 'Ask to join'); assert.equal(b.el('join-title').textContent, 'Ask to join');
  await b.tick(); await b.tick(); await b.tick();
  assert.equal(g.requests, 0, 'Polling while the form is open sends no request');
  assert.equal(b.el('title').textContent, 'Recovery test', 'The join page shows the session title');
  await b.submit(' Sam  Lee ');
  assert.equal(g.requests, 1);
  assert.deepEqual({name: b.joins.at(-1).name, ask: b.joins.at(-1).ask}, {name: 'Sam Lee', ask: true});
  assert.equal(b.el('state').textContent, 'Waiting to join'); assert.equal(b.el('join-form').hidden, true);
  assert.equal(b.el('join-detail').textContent, 'Asking as Sam Lee (session 4)');
  await b.tick(); await b.tick();
  assert.equal(g.requests, 1, 'Waiting resumes the same request');
  assert.ok(b.joins.slice(b.joins.findIndex(body => body.ask) + 1).every(body => body.pass === pass && !body.ask));
  assert.equal(b.count('config.json'), 0); assert.equal(b.readers.length, 0, 'Joining never fetches playable details');
  assert.ok(b.urls.every(url => !/Sam/.test(url)), 'Names are never placed in request URLs');
  g.admission = 'admitted'; await b.tick();
  assert.equal(joinVisible(b), false, 'Admission returns the picture-first page');
  assert.equal(b.readers.length, 1); assert.equal(b.configHeaders.at(-1)['X-Setbeam-Pass'], pass);
});

test('reloading a pending, declined, or removed tab keeps its state without a new request', async () => {
  for (const admission of ['pending', 'declined', 'removed']) {
    const g = gateway(); g.admission = admission;
    const b = browser({join: g.join, storage: {'setbeam-pass:': pass, 'setbeam-viewer-name': 'Sam'}}); b.state.approval = true; await b.settle();
    await b.tick();
    assert.equal(g.requests, 0, admission);
    assert.ok(b.joins.every(body => body.pass === pass && !body.ask), admission);
    assert.equal(b.el('join-form').hidden, true, admission);
    assert.match(b.el('join-detail').textContent, /Sam \(session 4\)$/, admission);
    assert.equal(b.el('join-retry').hidden, true, 'Refusals offer no way to ask again: ' + admission);
    assert.equal(b.count('config.json'), 0, admission);
  }
});

test('a failed request is reported in the form and sent again only when the viewer asks', async () => {
  const g = gateway();
  const b = browser({join: g.join}); b.state.approval = true; await b.settle();
  b.joinFails = true; await b.submit('Ana');
  assert.match(b.el('join-status').textContent, /could not be confirmed/);
  assert.equal(b.el('join-submit').disabled, false); assert.equal(b.el('join-name').readOnly, false);
  const asks = b.joins.filter(body => body.ask).length;
  b.joinFails = false; await b.tick(); await b.tick();
  assert.equal(b.joins.filter(body => body.ask).length, asks, 'No automatic resend after a failure');
  assert.equal(b.el('state').textContent, 'Ask to join');
  await b.submit('Ana');
  assert.equal(g.requests, 1); assert.equal(b.el('state').textContent, 'Waiting to join');
  assert.equal(b.el('join-status').textContent, '');
});

test('a lost connection while waiting shows reconnecting, and a lapsed request asks again with the name kept', async () => {
  const g = gateway();
  const b = browser({join: g.join}); b.state.approval = true; await b.settle(); await b.submit('Ana');
  b.joinFails = true; await b.tick();
  assert.equal(b.el('state').textContent, 'Waiting to join');
  assert.match(b.el('join-status').textContent, /Connection lost/);
  b.joinFails = false; g.lapsed = true; await b.tick();
  assert.equal(b.el('state').textContent, 'Ask to join');
  assert.match(b.el('join-status').textContent, /needs to ask again/);
  assert.equal(b.el('join-name').value, 'Ana');
  await b.tick(); await b.tick();
  assert.equal(g.requests, 1, 'The page does not replace a lapsed request by itself');
});

test('turning approval off while the form is open keeps the card and joins only when the viewer does', async () => {
  const g = gateway();
  const b = browser({join: g.join}); b.state.approval = true; await b.settle();
  assert.equal(b.el('state').textContent, 'Ask to join');
  g.approval = false; b.state.approval = false; await b.tick(); await b.tick();
  assert.equal(joinVisible(b), true, 'A name and color are still chosen first');
  assert.equal(b.el('join-submit').textContent, 'Join'); assert.equal(b.el('join-name').value, 'Test viewer');
  assert.equal(g.requests, 0); assert.equal(b.readers.length, 0);
  await b.submit('Lee');
  assert.equal(joinVisible(b), false); assert.equal(b.readers.length, 1);
  assert.equal(b.joins.at(-1).name, 'Lee');
});

test('with approval off a saved identity plays at once, and Change name or color edits it in place', async () => {
  const g = gateway({approval: false});
  const b = browser({join: g.join, eventSource: true, storage: {'setbeam-viewer-name': 'Sam', 'setbeam-pointer-color': 'blue'}});
  await b.settle(); await b.push(); await b.track();
  assert.equal(joinVisible(b), false); assert.equal(b.el('state').textContent, 'Live feed');
  assert.deepEqual({name: b.joins[0].name, ask: b.joins[0].ask, color: b.joins[0].color}, {name: 'Sam', ask: undefined, color: 'blue'});
  assert.equal(b.el('identity-button').hidden, false);
  b.listeners['identity-button:click'](); await b.settle();
  assert.equal(b.el('player').className.includes('join-open'), false, 'An admitted viewer keeps the picture and controls visible while editing');
  assert.equal(b.el('player').className.includes('identity-open'), true);
  assert.equal(b.el('identity-button').getAttribute('aria-expanded'), 'true');
  assert.equal(joinVisible(b), true); assert.equal(b.el('join-title').textContent, 'Your name and color');
  assert.equal(b.el('join-submit').textContent, 'Save'); assert.equal(b.el('join-cancel').hidden, false);
  assert.equal(b.context.document.activeElement, b.el('join-name'), 'The editor takes focus');
  assert.equal(b.el('state').textContent, 'Live feed', 'The badge keeps the feed state');
  b.pick('brown'); await b.submit('Sam (iPad)');
  assert.equal(joinVisible(b), false); assert.equal(b.context.document.activeElement, b.el('identity-button'));
  assert.deepEqual({name: b.heartbeats.at(-1).name, color: b.heartbeats.at(-1).color}, {name: 'Sam (iPad)', color: 'brown'});
  assert.equal(b.storage.get('setbeam-viewer-name'), 'Sam (iPad)'); assert.equal(b.readers.length, 1, 'Editing keeps the same peer');
  b.listeners['identity-button:click'](); await b.settle();
  b.el('join-name').value = 'Someone else'; b.pick('teal');
  b.listeners.keydown({key: 'Escape', target: {closest: () => true}, preventDefault() {}});
  assert.equal(joinVisible(b), false, 'Escape cancels the editor');
  assert.equal(b.el('identity-avatar').textContent, 'S'); assert.equal(b.storage.get('setbeam-pointer-color'), 'brown');
  b.listeners['identity-button:click'](); await b.settle();
  assert.equal(b.el('join-name').value, 'Sam (iPad)', 'A cancelled draft is not kept');
  b.listeners['identity-button:click'](); await b.settle();
  assert.equal(joinVisible(b), false, 'The direct identity button also closes its editor');
  assert.equal(b.el('identity-button').getAttribute('aria-expanded'), 'false');
  b.listeners['identity-button:click'](); await b.settle();
  b.listeners['pointer:click'](); await b.settle();
  assert.equal(joinVisible(b), false, 'Opening pointing controls closes identity editing first');
  assert.equal(b.count('join'), 1, 'Editing never sends a new join request');
});

test('focus follows step changes on a keyboard device and stays put during polls', async () => {
  const g = gateway();
  const b = browser({join: g.join, finePointer: true}); b.state.approval = true; await b.settle();
  assert.equal(b.context.document.activeElement, b.el('join-name'), 'The name field is ready for typing');
  await b.tick(); await b.tick();
  assert.equal(b.el('join-name').focuses, 1, 'Polls never move focus again');
  b.el('join-submit').focus(); await b.submit('Ana');
  assert.equal(b.context.document.activeElement, b.el('join-title'), 'Waiting moves focus to the new heading');
  await b.tick(); await b.tick(); assert.equal(b.el('join-title').focuses, 1);
  g.admission = 'admitted'; await b.tick();
  assert.equal(b.context.document.activeElement, b.el('title'), 'Admission moves focus to the session title');
  const touch = browser({join: gateway().join}); touch.state.approval = true; await touch.settle();
  assert.equal(touch.el('join-name').focuses, 0, 'A touch keyboard opens only when the viewer taps the field');
});

test('a busy session waits for Try again, and a changed link replaces the waiting page', async () => {
  const g = gateway(); g.full = true;
  const b = browser({join: g.join}); b.state.approval = true; await b.settle(); await b.submit('Ana');
  assert.equal(b.el('state').textContent, 'Session busy'); assert.equal(b.el('join-retry').hidden, false);
  const sent = b.joins.length; await b.tick(); await b.tick();
  assert.equal(b.joins.length, sent, 'Busy requests are not repeated automatically under approval');
  g.full = false; b.listeners['join-retry:click'](); await b.settle();
  assert.equal(b.joins.at(-1).ask, true); assert.equal(b.el('state').textContent, 'Waiting to join');
  g.gone = true; await b.tick();
  assert.equal(b.el('state').textContent, 'Session unavailable');
  assert.equal(b.el('join-title').textContent, 'Link unavailable');
  assert.equal(b.el('join-retry').hidden, true); assert.equal(b.count('config.json'), 0);
});

test('a link retired while the form is open shows a terminal notice', async () => {
  const g = gateway();
  const b = browser({join: g.join, storage: {'setbeam-viewer-name': 'Sam'}}); b.state.approval = true; await b.settle();
  assert.equal(b.el('state').textContent, 'Ask to join');
  g.gone = true; b.stateGone = true; await b.tick(); await b.tick();
  assert.equal(b.el('state').textContent, 'Session unavailable', 'Stop while the form is open retires the form');
  assert.equal(b.el('join-form').hidden, true); assert.equal(b.el('join-retry').hidden, true);
  b.listeners['join-retry:click'](); await b.settle(); await b.tick();
  assert.equal(b.el('state').textContent, 'Session unavailable', 'Try again on a retired link stays unavailable');
  assert.equal(b.el('join-form').hidden, true);
  assert.equal(g.requests, 0); assert.ok(b.joins.every(body => !body.ask), 'Nothing asks on the viewer\'s behalf');
  assert.equal(b.count('config.json'), 0);
});

test('an Ask on a retired link shows a terminal notice without another request', async () => {
  const g = gateway();
  const b = browser({join: g.join}); b.state.approval = true; await b.settle();
  assert.equal(b.el('state').textContent, 'Ask to join');
  g.gone = true; b.stateGone = true; await b.submit('Ana');
  assert.equal(b.el('state').textContent, 'Session unavailable');
  const asks = b.joins.filter(body => body.ask).length;
  b.listeners['join-retry:click'](); await b.settle(); await b.tick(); await b.tick();
  assert.equal(b.el('state').textContent, 'Session unavailable', 'Try again does not return to a form that cannot work');
  assert.equal(b.el('join-form').hidden, true); assert.equal(b.el('join-retry').hidden, true);
  assert.equal(b.joins.filter(body => body.ask).length, asks, 'Try again sends no new request');
  assert.equal(g.requests, 0); assert.equal(b.count('config.json'), 0);
});

test('under approval an admitted name is read-only in the editor, and Hold keeps the picture page', async () => {
  const g = gateway(); g.admission = 'admitted';
  const b = browser({eventSource: true, join: g.join, storage: {'setbeam-pass:': pass, 'setbeam-viewer-name': 'Sam'}});
  await b.settle(); await b.push({...b.state, approval: true}); await b.track();
  assert.equal(b.el('identity-button').getAttribute('aria-label'), 'Sam. Change color');
  b.listeners['identity-button:click'](); await b.settle();
  assert.match(b.el('join-hint').textContent, /fixed while the operator approves/);
  assert.equal(b.el('join-name').readOnly, true, 'The admitted name cannot be edited');
  b.el('join-name').value = 'Director'; b.pick('teal'); b.listeners['join-form:submit']({preventDefault() {}}); await b.settle();
  assert.deepEqual({name: b.heartbeats.at(-1).name, color: b.heartbeats.at(-1).color}, {name: 'Sam', color: 'teal'});
  assert.equal(b.storage.get('setbeam-viewer-name'), 'Sam');
  await b.push({...b.state, approval: true, state: 'holding'});
  assert.equal(joinVisible(b), false); assert.equal(b.el('state').textContent, 'On hold');
  await b.push({...b.state, approval: true, state: 'live', revision: 2}); await b.track();
  assert.equal(b.el('state').textContent, 'Live feed');
  assert.equal(g.requests, 0, 'Recovering playback never sends a new request');
});


test('the dock fades after 3 s without movement and stays while focused', async () => {
  const b = browser(); await b.settle(); await b.track();
  const idle = () => b.el('player').className.split(' ').includes('idle');
  assert.equal(idle(), false, 'controls start in view');
  await b.tick(3100); assert.equal(idle(), true);
  b.listeners['stage:pointermove']({pointerType: 'mouse'}); assert.equal(idle(), false, 'movement reveals the dock');
  const peers = b.readers.length;
  b.el('controls').focus(); b.listeners['controls:focusin']();
  b.frame(); await b.tick(3100); assert.equal(idle(), false, 'keyboard focus pins controls');
  b.context.document.activeElement = b.context.document.body;
  b.frame(); await b.tick(3100); assert.equal(idle(), true);
  b.listeners['stage:pointermove']({pointerType: 'touch'}); assert.equal(idle(), true, 'a finger on the picture is not a hover');
  assert.equal(b.readers.length, peers, 'fading never replaces media');
});

test('pointing keeps the dock in view so the viewer can stop, and picture taps stay with pointing', async () => {
  const b = browser({pointers: true}); await b.settle(); await b.track();
  b.el('picture').classList = {contains(name) { return name === 'pointing'; }};
  b.listeners['picture:click']({target: {closest() { return null; }}});
  b.frame(); await b.tick(3100); b.frame(); await b.tick(3100);
  assert.equal(b.el('player').className.split(' ').includes('idle'), false);
});

test('playback updates preserve chat layout and compact keyboard classes', async () => {
  const b = browser(); await b.settle(); await b.track();
  const player = b.el('player');
  player.className += ' chat-open keyboard-tight';
  player.classList = {contains(name) { return player.className.split(' ').includes(name); }};
  await b.tick(); await b.track();
  assert.ok(player.className.split(' ').includes('chat-open'), 'A video update must not close the chat layout');
  assert.ok(player.className.split(' ').includes('keyboard-tight'), 'A video update must not expand the keyboard composer');
  b.state.state = 'holding'; await b.tick();
  assert.ok(player.className.split(' ').includes('chat-open'), 'Chat remains open through Hold');
});

test('Hold, Stop, and removal invalidate delayed credentials immediately', async () => {
  for (const transition of ['holding', 'stopped', 'removed']) {
    const b = browser({eventSource: true, chat: true}); await b.settle(); await b.track();
    const late = b.defer('config.json', {whepURL: 'http://localhost/late/whep'});
    await b.push({...b.state, revision: 2});
    assert.equal(b.readers[0].closed, true);
    assert.equal(b.chatUpdates.viewer.displayedRevision(), undefined);
    assert.equal(b.chatUpdates.at(-1).revision, 2);
    assert.equal(b.heartbeats.at(-1).playing, false);
    assert.ok(late.signal);
    if (transition === 'removed') {
      b.heartbeatResponse = {ok: true, admission: 'removed'}; await b.tick(3000);
    } else await b.push({...b.state, state: transition, revision: 2});
    assert.equal(b.el('state').textContent, {holding: 'On hold', stopped: 'Sharing ended', removed: 'Removed'}[transition]);
    assert.equal(late.signal.aborted, true);
    await late.release();
    assert.equal(b.readers.length, 1);
    assert.equal(b.el('video').srcObject, null);
  }
});

test('a matching config waits for sequenced state when the gateway is ahead', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.track();
  const config = {whepURL: 'http://localhost/next/whep', revision: 2, sequence: 11};
  b.config = config;
  await b.push({...b.state, revision: 2, sequence: 10});
  assert.equal(b.readers.length, 1);
  await b.push({...b.state, revision: 2, sequence: 11});
  assert.equal(b.readers.length, 2);
  assert.equal(b.readers[1].config.url, config.whepURL);
});

test('sequence orders polls and pushes regardless of delivery order', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.track();
  await b.push({...b.state, sequence: 4});
  const newerPoll = b.defer('state.json', {...b.state, state: 'holding', sequence: 6});
  b.listeners.online(); await b.settle();
  await b.push({...b.state, sequence: 5});
  await newerPoll.release();
  assert.equal(b.el('state').textContent, 'On hold');
  await b.push({...b.state, sequence: 5});
  assert.equal(b.el('state').textContent, 'On hold');
  assert.equal(b.readers.length, 1);
});

test('a retired poll result cannot end a session after a newer push', async () => {
  const b = browser({eventSource: true}); await b.settle(); await b.track();
  const expired = b.defer('state.json', undefined, 404);
  b.listeners.online(); await b.settle(); await b.push();
  await expired.release();
  assert.equal(b.el('state').textContent, 'Live feed');
  assert.equal(b.readers[0].closed, false);
});

test('temporarily losing control polling leaves the decoded feed and sound playing', async () => {
  const b = browser(); await b.settle(); await b.track();
  b.listeners['sound:click'](); await b.settle();
  b.rejectNext('state.json'); await b.tick();
  assert.equal(b.el('state').textContent, 'Live feed');
  assert.equal(b.el('video').muted, false);
  assert.equal(b.readers.length, 1);
  b.state.state = 'holding'; await b.tick();
  assert.equal(b.el('state').textContent, 'On hold');
});

test('a timed-out config cannot replace the credentials from a later attempt', async () => {
  const b = browser(); await b.settle();
  const expired = b.defer('config.json', {whepURL: 'http://localhost/old/whep'});
  b.state.revision++; await b.tick();
  const count = b.readers.length;
  await b.tick(5100); await b.tick();
  assert.equal(expired.signal.aborted, true);
  assert.equal(b.readers.length, count + 1);
  await expired.release();
  assert.equal(b.readers.length, count + 1);
  assert.match(b.readers.at(-1).config.url, /\/live\/whep$/);
});

test('pagehide cancels work and pageshow checks both state and the stored pass', async () => {
  const b = browser({eventSource: true, chat: true, wakeLock: true}); await b.settle(); await b.track(); await b.settle();
  await b.push({...b.state, sequence: 8});
  const oldHeartbeat = b.defer('heartbeat', {admission: 'removed', chatLastID: 99});
  const oldState = b.defer('state.json', {...b.state, state: 'stopped', sequence: 9});
  b.listeners.visibilitychange(); await b.settle();
  b.listeners.pagehide();
  assert.equal(oldState.signal.aborted, true);
  assert.equal(oldHeartbeat.signal.aborted, true);
  assert.equal(b.readers[0].closed, true);
  assert.equal(b.sources[0].readyState, 2);
  assert.equal(b.locks[0].released, true);
  assert.equal(b.chatUpdates.at(-1).suspended, true);
  const before = b.requests;
  b.listeners.online(); await b.tick(30_000); assert.equal(b.requests, before);

  const resumedState = b.defer('state.json', {...b.state, sequence: 8});
  b.listeners.pageshow(); await b.settle();
  assert.equal(b.joins.at(-1).pass, b.storage.get('setbeam-pass:'));
  assert.equal(b.readers.length, 1);
  await oldState.release(); await oldHeartbeat.release();
  await resumedState.release(); await b.track();
  assert.equal(b.readers.length, 2);
  assert.equal(b.sources.length, 2);
  assert.equal(b.chatUpdates.at(-1).suspended, false);
  assert.equal(b.chatActivity.includes(99), false);
  assert.equal(b.el('state').textContent, 'Live feed');
});

test('terminal links ignore online, page restore, tick, and click retries', async () => {
  const b = browser(); await b.settle(); await b.track();
  b.stateGone = true; await b.tick();
  assert.equal(b.el('state').textContent, 'Sharing ended');
  const before = b.requests;
  b.listeners.pagehide(); b.listeners.pageshow(); b.listeners.online();
  b.listeners['retry:click'](); await b.tick(15_000);
  assert.equal(b.requests, before);
});

test('a newer heartbeat supersedes a timed-out one, and stale activity and admission are ignored', async () => {
  const b = browser({eventSource: true, chat: true}); await b.settle(); await b.push(); await b.track(); await b.settle();
  const old = b.defer('heartbeat', {admission: 'unknown', chatLastID: 95});
  await b.tick(3000);
  b.frame(); await b.tick(2000);
  assert.equal(b.count('heartbeat'), 3, 'only one heartbeat is in flight');
  b.heartbeatResponse = {admission: 'admitted', chatLastID: 96};
  b.frame(); await b.tick(3200);
  assert.equal(old.signal.aborted, true);
  assert.equal(b.chatActivity.at(-1), 96);
  await old.release();
  assert.equal(b.chatActivity.includes(95), false);
  assert.equal(b.readers[0].closed, false);
});

test('a join retry for the same draft keeps its UUID, while an edited draft gets a new UUID', async () => {
  const b = browser({join: {status: 400}}); b.state.approval = true; await b.settle();
  b.joinFails = true;
  await b.submit('Ana'); await b.submit('Ana');
  const asked = b.joins.filter(body => body.ask);
  const id = asked[0].requestID;
  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.equal(asked[1].requestID, id);
  b.pick('teal'); await b.submit('Ana');
  assert.notEqual(b.joins.at(-1).requestID, id);
  assert.equal(b.joins[0].requestID, undefined);
});

test('streamless audio and a clock advance do not establish fresh video', async () => {
  const b = browser({chat: true, pointers: true}); b.state.pointers = true; await b.settle();
  const track = b.readers[0].config.onTrack;
  track({track: b.audio, streams: []}); await b.settle();
  b.frame();
  assert.equal(b.chatUpdates.viewer.live(), false);
  const stream = b.el('video').srcObject;
  track({track: b.videoTrack, streams: []}); await b.settle();
  assert.equal(b.el('video').srcObject, stream);
  b.el('video').currentTime += 1; b.listeners['video:timeupdate']();
  assert.equal(b.chatUpdates.viewer.live(), false, 'a media clock advance alone does not prove a decoded frame');
  b.frame(); assert.equal(b.chatUpdates.viewer.displayedRevision(), 1);
  assert.equal(b.pointerUpdates.at(-1).live, true);
  const paints = b.chatUpdates.length;
  for (let n = 0; n < 50; n++) b.frame();
  assert.equal(b.chatUpdates.length, paints, 'steady frames do not render or update collaboration');
});

test('old frame callbacks cannot establish readiness after reconnecting', async () => {
  const b = browser({eventSource: true, frameCallback: true, chat: true}); await b.settle(); await b.track();
  const first = b.frameCallback;
  await b.push({...b.state, revision: 2});
  assert.equal(b.canceledFrames, 1);
  first(1000, {presentedFrames: 2});
  assert.equal(b.chatUpdates.viewer.displayedRevision(), undefined);
  await b.track(); assert.equal(b.chatUpdates.viewer.displayedRevision(), 2);
});

test('a rejected unmute resumes the same peer silently and can be retried', async () => {
  const b = browser({unmuteFails: true}); await b.settle(); await b.track();
  b.listeners['sound:click'](); await b.settle();
  assert.equal(b.el('video').muted, true);
  assert.equal(b.el('video').paused, false);
  assert.equal(b.el('sound').getAttribute('aria-pressed'), 'false');
  assert.equal(b.el('state').textContent, 'Live feed');
  b.unmuteFails = false; b.listeners['sound:click'](); await b.settle();
  assert.equal(b.el('video').muted, false);
  assert.equal(b.readers.length, 1);
});

test('late PiP entry after Hold exits and native fullscreen is not triggered by pointing', async () => {
  const b = browser({eventSource: true, pip: true}); await b.settle(); await b.track();
  let complete;
  b.el('video').requestPictureInPicture = () => new Promise(resolve => { complete = () => {
    b.context.document.pictureInPictureElement = b.el('video'); resolve();
  }; });
  const entering = b.listeners['pip:click']();
  await b.push({...b.state, state: 'holding'});
  complete(); await entering;
  assert.equal(b.context.document.pictureInPictureElement, null);
  assert.equal(b.el('pip').getAttribute('aria-pressed'), 'false');
  await b.push(b.state); await b.track();
  b.el('picture').classList = {contains: name => name === 'pointing'};
  b.listeners['picture:dblclick']({target: {closest() { return null; }}});
  assert.equal(b.context.document.fullscreenElement, undefined);
});

test('wake lock release and blocked fallback playback both retry', async () => {
  const lock = browser({wakeLock: true}); await lock.settle(); await lock.track(); await lock.settle();
  await lock.locks[0].release(); lock.frame(); await lock.tick(3000);
  assert.equal(lock.locks.length, 2);
  const b = browser({keepAwakeVideo: true, clipFails: true}); await b.settle(); await b.track(); await b.settle();
  assert.equal(b.el('keepawake').paused, true);
  b.clipFails = false; b.listeners['picture:click'](); await b.settle();
  assert.equal(b.el('keepawake').plays, 2);
  assert.equal(b.el('keepawake').paused, false);
  b.context.document.hidden = true; b.listeners.visibilitychange();
  assert.equal(b.el('keepawake').paused, true);
});

test('focused avatar stays visible and identity Escape takes priority over background chat', async () => {
  const b = browser({chat: true}); await b.settle(); await b.track(); await b.tick(3000);
  b.el('identity-button').focus(); b.listeners['identity-button:focus']();
  await b.tick(3000);
  assert.ok(!b.el('player').className.includes(' idle'));
  b.listeners['identity-button:click']();
  const key = (key, options = {}) => {
    const event = {key, target: b.context.document.activeElement, preventDefault() { this.defaultPrevented = true; }, ...options};
    b.listeners.keydown(event);
    return event.defaultPrevented;
  };
  b.el('chat-menu').hidden = false;
  assert.equal(key('Escape'), undefined, 'the chat menu owns Escape');
  assert.equal(key('f'), undefined, 'a menu blocks global shortcuts');
  b.el('chat-menu').hidden = true;
  assert.equal(key('Escape'), true, 'the identity editor closes before background chat');
  assert.equal(b.chatUpdates.viewer.identityOpen(), false);
  assert.equal(key('f', {isComposing: true}), undefined);
  b.el('pointer').hidden = true;
  assert.equal(key('p'), undefined, 'an unavailable shortcut leaves the key alone');
});

const whepReader = fs.readFileSync('Sources/SetbeamApp/Resources/reader.js', 'utf8');

function whep() {
  const requests = [], peers = [], errors = [], tracks = [], timers = new Map();
  let now = 0;
  const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 96 97 98\r\na=rtpmap:96 pcma/8000/2\r\na=rtpmap:97 multiopus/48000/6\r\na=rtpmap:98 L16/48000/2\r\n';
  class Peer {
    constructor() { peers.push(this); this.closed = false; this.answers = 0; this.transceivers = []; }
    addTransceiver(kind, options) { this.transceivers.push({kind, ...options}); }
    createDataChannel() {}
    close() { this.closed = true; }
    async createOffer() { return {sdp}; }
    async setLocalDescription() {}
    async setRemoteDescription() { this.answers++; }
  }
  const context = {
    window: {}, AbortController, URL, btoa, RTCSessionDescription: class {}, RTCPeerConnection: Peer,
    setTimeout(fn, delay) { const key = {}; timers.set(key, {fn, at: now + delay}); return key; },
    clearTimeout(key) { timers.delete(key); },
    fetch(url, options) {
      return new Promise((resolve, reject) => {
        const request = {url, ...options, resolve, reject};
        requests.push(request);
        if (options.method === 'OPTIONS' || options.method === 'DELETE') {
          resolve({status: 204, ok: true, headers: {get: () => null}});
        }
      });
    },
  };
  vm.runInNewContext(whepReader, context);
  const reader = new context.window.MediaMTXWebRTCReader({
    url: 'http://localhost/live/whep', user: 'guest', pass: 'synthetic',
    onError: error => errors.push(error), onTrack: track => tracks.push(track),
  });
  const settle = async () => { for (let n = 0; n < 48; n++) await Promise.resolve(); };
  return {
    reader, requests, peers, errors, tracks, settle,
    get offers() { return requests.filter(request => request.method === 'POST'); },
    get deletes() { return requests.filter(request => request.method === 'DELETE'); },
    answer(request, id, body = async () => 'v=0\r\n') {
      request.resolve({status: 201, headers: {get: () => '/live/whep/' + id}, text: body});
    },
    async advance(ms) {
      now += ms;
      for (const [key, timer] of [...timers]) if (timer.at <= now && timers.delete(key)) timer.fn();
      await settle();
    }
  };
}

test('WHEP close deletes its session once with read credentials and cancels PATCH', async () => {
  const w = whep(); await w.settle();
  const [offer] = w.offers, pc = w.peers.at(-1);
  w.answer(offer, 'active'); await w.settle();
  assert.deepEqual(pc.transceivers, [{kind: 'video', direction: 'recvonly'}, {kind: 'audio', direction: 'recvonly'}]);
  pc.onicecandidate({candidate: {candidate: 'candidate:fixture', sdpMLineIndex: 0}});
  const patch = w.requests.at(-1);
  w.reader.close(); w.reader.close();
  assert.equal(pc.closed, true);
  assert.equal(patch.method, 'PATCH');
  assert.equal(patch.signal.aborted, true);
  assert.equal(w.deletes.length, 1);
  assert.equal(w.deletes[0].url, 'http://localhost/live/whep/active');
  assert.equal(w.deletes[0].headers.Authorization, offer.headers.Authorization);
  assert.equal(w.deletes[0].keepalive, true);
  patch.reject(new Error('aborted')); await w.advance(10_000);
  assert.equal(w.errors.length, 0);
  assert.equal(w.offers.length, 1);
});

test('WHEP close deletes a late 201 without applying or consuming its answer', async () => {
  const w = whep(); await w.settle();
  const old = w.peers.at(-1);
  w.reader.close();
  let consumed = false;
  w.answer(w.offers[0], 'late', () => { consumed = true; });
  await w.settle();
  assert.equal(old.answers, 0);
  assert.equal(consumed, false);
  assert.equal(w.deletes[0].url, 'http://localhost/live/whep/late');
  old.ontrack({track: 'stale'});
  assert.deepEqual(w.tracks, []);
});

test('WHEP negotiation deadline permits a new attempt before a stale POST returns', async () => {
  const w = whep(); await w.settle();
  const old = w.peers.at(-1);
  await w.advance(8000); await w.advance(2000);
  assert.equal(old.closed, true);
  assert.match(w.errors[0], /timed out/);
  const active = w.peers.at(-1);
  w.answer(w.offers[1], 'replacement'); await w.settle();
  w.answer(w.offers[0], 'stale'); await w.settle();
  assert.equal(active.closed, false);
  assert.equal(old.answers, 0);
  assert.equal(active.answers, 1);
  assert.deepEqual(w.deletes.map(request => request.url), ['http://localhost/live/whep/stale']);
  w.reader.close();
  assert.equal(w.deletes.at(-1).url, 'http://localhost/live/whep/replacement');
});

test('WHEP negotiation deadline includes a stalled answer body', async () => {
  const w = whep(); await w.settle();
  const old = w.peers.at(-1), [offer] = w.offers;
  let finishBody;
  w.answer(offer, 'headers', () => new Promise(resolve => { finishBody = resolve; })); await w.settle();
  await w.advance(8000); await w.advance(2000);
  assert.equal(offer.signal.aborted, true);
  assert.equal(old.answers, 0);
  assert.equal(w.deletes[0].url, 'http://localhost/live/whep/headers');
  assert.equal(w.offers.length, 2);
  finishBody('v=0\r\n'); await w.settle();
  assert.equal(old.answers, 0);
  w.reader.close();
});

test('admission starts the state stream before reader credentials are ready', async () => {
  const b = browser({eventSource: true, join: {pass, admission: 'admitted', ready: false}}); await b.settle();
  assert.equal(b.sources.length, 1);
  assert.equal(b.count('config.json'), 0);
  await b.push({...b.state, state: 'holding'});
  assert.equal(b.el('state').textContent, 'On hold');
  b.join = {pass, admission: 'admitted', ready: true}; await b.tick();
  assert.equal(b.count('config.json'), 0);
  await b.push(b.state);
  assert.equal(b.readers.length, 1);
});

test('plain HTTP joins still generate a UUID when randomUUID is unavailable', async () => {
  const b = browser({plainHTTP: true, storage: {}}); await b.settle(); await b.submit('Ana');
  assert.equal(b.joins[0].requestID, 'ffffffff-ffff-4fff-bfff-ffffffffffff');
});

test('a browser with only inbound decoder statistics waits for those counters to advance', async () => {
  const b = browser({stats: true, noFrameCounter: true, chat: true}); await b.settle(); await b.track();
  b.stats = reception(10, 0, 0, 0, 4);
  await b.tick(); assert.equal(b.chatUpdates.viewer.live(), false);
  b.stats = reception(25, 0, 0, 0, 5);
  await b.tick(); assert.equal(b.chatUpdates.viewer.live(), true);
});
