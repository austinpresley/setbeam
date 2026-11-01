// Run the shipped shared-pointer controller against a deterministic page and presence channel.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync('Sources/SetbeamApp/Resources/pointers.js', 'utf8');

function page(options = {}) {
  let now = 10_000, nextTimer = 1;
  const timers = new Map(), sockets = [], listeners = {}, elements = new Map(), storage = new Map();
  function node(tag = 'div', id) {
    const el = {
      tag, id, hidden: false, disabled: false, value: '', checked: false, type: '', name: '', title: '', className: '', dataset: {},
      children: [], parent: null, attributes: {}, events: {}, _text: '',
      style: {setProperty(key, value) { this[key] = value; }},
      classList: {
        set: new Set(), add(...names) { names.forEach(n => this.set.add(n)); }, remove(...names) { names.forEach(n => this.set.delete(n)); },
        toggle(name, on) { if (on === undefined ? !this.set.has(name) : on) this.set.add(name); else this.set.delete(name); }, contains(name) { return this.set.has(name); }
      },
      get textContent() { return this._text; }, set textContent(value) { this._text = String(value); this.children = []; },
      get innerHTML() { throw new Error('pointers.js must not use innerHTML'); }, set innerHTML(_) { throw new Error('pointers.js must not use innerHTML'); },
      append(...items) { for (const item of items) { item.parent = this; this.children.push(item); } },
      remove() { if (this.parent) this.parent.children = this.parent.children.filter(c => c !== this); this.parent = null; },
      setAttribute(k, v) { this.attributes[k] = String(v); }, getAttribute(k) { return this.attributes[k]; },
      addEventListener(name, fn) { (this.events[name] ||= []).push(fn); },
      dispatch(name, event = {}) { for (const fn of this.events[name] || []) fn({preventDefault() {}, target: this, ...event}); },
      contains(target) { for (let t = target; t; t = t.parent) if (t === this) return true; return false; },
      focus() { context.document.activeElement = this; },
      getBoundingClientRect() { return this.rect || {left: 0, top: 0, width: 0, height: 0}; }
    };
    return el;
  }
  const get = id => { if (!elements.has(id)) elements.set(id, node('div', id)); return elements.get(id); };
  // A 4:3 picture in a 16:9 page area: 1600x900 at (100, 50), so the picture is 1200x900 at x=300.
  get('picture').rect = options.box || {left: 100, top: 50, width: 1600, height: 900};
  Object.assign(get('video'), {videoWidth: options.videoWidth || 1440, videoHeight: options.videoHeight || 1080});
  get('pointer').hidden = true; get('pointer-panel').hidden = true; get('pointer-show').checked = true; get('pointer-share').checked = true;
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.closed = true; }
    open() { this.readyState = 1; this.onopen?.(); }
    message(value) { this.onmessage?.({data: JSON.stringify(value)}); }
    drop() { this.readyState = 3; this.onclose?.(); }
  }
  const context = {
    document: {getElementById: get, createElement: tag => node(tag), addEventListener(name, fn) { (listeners[name] ||= []).push(fn); }, hidden: false, activeElement: null},
    window: {addEventListener(name, fn) { (listeners['window:' + name] ||= []).push(fn); }},
    location: {protocol: 'http:', host: '192.168.1.5:8080', pathname: '/s/token/'},
    sessionStorage: {getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v)},
    WebSocket: FakeSocket, Date: class extends Date { static now() { return now; } },
    setTimeout(fn, delay) { const id = nextTimer++; timers.set(id, {fn, due: now + delay}); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval(fn, delay) { const id = nextTimer++; timers.set(id, {fn, due: now + delay, every: delay}); return id; },
    clearInterval(id) { timers.delete(id); }, Object, Number, Math, JSON, String, Array, Set, Map, Infinity
  };
  context.globalThis = context;
  vm.runInNewContext(source, context);
  const state = {name: options.name ?? 'Sam', locked: !!options.locked, live: true, pass: 'f'.repeat(48)};
  const controller = context.SetbeamPointers.attach({pass: () => state.pass, name: () => state.name, nameLocked: () => state.locked,
    setName: value => (state.name = value.trim()), live: () => state.live});
  return {
    api: context.SetbeamPointers, controller, get, sockets, state, listeners,
    advance(ms) {
      const end = now + ms;
      while (true) {
        const due = [...timers.entries()].filter(([, t]) => t.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
        if (!due) break;
        const [id, timer] = due; now = timer.due;
        if (timer.every) timer.due += timer.every; else timers.delete(id);
        timer.fn();
      }
      now = end;
    },
    start() { get('pointer-form').dispatch('submit'); const socket = sockets.at(-1); socket.open(); socket.message({t: 'welcome', n: 2, r: 7}); return socket; },
    moves(socket) { return socket.sent.filter(m => m.t === 'move'); },
    marks() { return get('pointer-layer').children.filter(c => c.className === 'pointer-mark'); }
  };
}

test('mapping uses the visible source picture, not the page or letterbox', () => {
  const raw = page().api;
  // Values come from the page's own realm; compare them as plain data.
  const plain = fn => (...args) => JSON.parse(JSON.stringify(fn(...args)));
  const api = {contentRect: plain(raw.contentRect), toPicture: plain(raw.toPicture)};
  const rect = api.contentRect({left: 100, top: 50, width: 1600, height: 900}, 1440, 1080);
  assert.deepEqual(rect, {left: 300, top: 50, width: 1200, height: 900});
  assert.deepEqual(api.toPicture(rect, 300, 50), {x: 0, y: 0});
  assert.deepEqual(api.toPicture(rect, 1500, 950), {x: 1, y: 1});
  assert.deepEqual(api.toPicture(rect, 900, 500), {x: 0.5, y: 0.5});
  assert.equal(api.toPicture(rect, 250, 500), null, 'The pillarbox is not the picture');
  assert.equal(api.toPicture(rect, NaN, 500), null);
  assert.equal(api.contentRect({left: 0, top: 0, width: 800, height: 600}, 0, 0), null, 'No picture before metadata');
  // Browser full screen gives the picture element a different shape; a wide source letterboxes vertically.
  const full = api.contentRect({left: 0, top: 0, width: 1000, height: 1000}, 2560, 1080);
  assert.equal(full.top, (1000 - 1000 * 1080 / 2560) / 2);
});

test('pointing needs the host option and a name, then announces only name, color, and pass', () => {
  const p = page({name: ''});
  p.controller.update({enabled: false, live: true, revision: 7});
  assert.equal(p.get('pointer').hidden, true, 'No control until the operator enables shared pointers');
  p.controller.update({enabled: true, live: true, revision: 7});
  assert.equal(p.get('pointer').hidden, false);
  p.get('pointer-form').dispatch('submit');
  assert.equal(p.sockets.length, 0, 'A name is required');
  p.get('pointer-name').value = '  Sam  ';
  p.get('pointer-form').dispatch('submit');
  const socket = p.sockets[0];
  assert.equal(socket.url, 'ws://192.168.1.5:8080/s/token/presence');
  socket.open();
  assert.deepEqual(socket.sent[0], {t: 'hello', pass: 'f'.repeat(48), name: 'Sam', color: 'blue'});
});

test('moves are picture fractions, coalesced, never repeated, and hidden outside the picture', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  const picture = p.get('picture');
  for (let x = 300; x < 400; x += 5) picture.dispatch('pointermove', {clientX: x, clientY: 500, pointerType: 'mouse'});
  assert.equal(p.moves(socket).length, 1, 'One immediate update, the rest coalesce');
  p.advance(40);
  assert.equal(p.moves(socket).length, 2);
  assert.equal(p.moves(socket).at(-1).x, Math.round((395 - 300) / 1200 * 10000) / 10000, 'Only the newest coalesced position is sent');
  assert.equal(p.moves(socket).at(-1).r, 7);
  for (let n = 0; n < 10; n++) { picture.dispatch('pointermove', {clientX: 395, clientY: 500, pointerType: 'mouse'}); p.advance(40); }
  assert.equal(p.moves(socket).length, 2, 'An unchanged position is not resent');
  picture.dispatch('pointermove', {clientX: 200, clientY: 500, pointerType: 'mouse'});
  assert.equal(socket.sent.at(-1).t, 'hide', 'Movement over the pillarbox hides the pointer');
  picture.dispatch('pointermove', {clientX: 900, clientY: 500, pointerType: 'mouse'}); p.advance(40);
  picture.dispatch('pointerleave', {pointerType: 'mouse'});
  assert.equal(socket.sent.at(-1).t, 'hide');
  picture.dispatch('pointerdown', {clientX: 900, clientY: 500, pointerType: 'touch'});
  assert.equal(socket.sent.at(-1).tap, true, 'A tap is an explicit point');
  p.get('pointer-share').checked = false; p.get('pointer-share').dispatch('change');
  const count = socket.sent.length;
  picture.dispatch('pointermove', {clientX: 1000, clientY: 500, pointerType: 'mouse'}); p.advance(40);
  assert.equal(socket.sent.length, count, 'Nothing is shared while sharing my pointer is off');
});

test('names render as text and invalid items are ignored', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  socket.message({t: 'pointers', r: 7, items: [
    {n: 3, label: '<img src=x onerror=alert(1)>', color: 'pink', x: 0.25, y: 0.5, ttl: 3900},
    {n: 4, label: 'Bad', color: 'url(javascript:1)', x: 0.5, y: 0.5, ttl: 3900},
    {n: 5, label: 'Bad', color: 'blue', x: 1.5, y: 0.5, ttl: 3900},
    {n: 6, label: 'Bad', color: 'blue', x: 0.5, y: 0.5, ttl: -1}]});
  const marks = p.marks();
  assert.equal(marks.length, 1);
  assert.equal(marks[0].children.find(c => c.tag === 'b').textContent, '<img src=x onerror=alert(1)>');
  assert.equal(marks[0].style.left, '25%'); assert.equal(marks[0].style.top, '50%');
  assert.equal(p.get('pointer-layer').style.left, '200px', 'The layer covers the visible picture inside the element');
  assert.equal(p.get('pointer-layer').style.width, '1200px');
});

test('pointers fade locally from their remaining time, even if the channel goes silent', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 1000}]});
  p.advance(900);
  assert.equal(p.marks()[0].classList.contains('fading'), false);
  p.advance(200);
  assert.equal(p.marks()[0].classList.contains('fading'), true, 'No message needed to expire');
  p.advance(700);
  assert.equal(p.marks().length, 0);
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 3000}]});
  socket.message({t: 'pointers', r: 7, items: []});
  assert.equal(p.marks()[0].classList.contains('fading'), true, 'An omitted pointer fades');
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 3000}]});
  socket.drop();
  assert.equal(p.marks().length, 0, 'A lost channel clears every pointer');
});

test('Hold, a replaced picture, and turning pointers off clear positions and stop sending', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  let socket = p.start();
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 3000}]});
  p.controller.update({enabled: true, live: false, revision: 8});
  assert.equal(p.marks().length, 0, 'Hold clears pointers');
  const count = socket.sent.length;
  p.get('picture').dispatch('pointermove', {clientX: 900, clientY: 500, pointerType: 'mouse'}); p.advance(40);
  assert.equal(socket.sent.length, count, 'Nothing is sent while the picture is not live');
  p.controller.update({enabled: true, live: true, revision: 9});
  socket.message({t: 'pointers', r: 9, items: []});
  p.get('picture').dispatch('pointermove', {clientX: 900, clientY: 500, pointerType: 'mouse'});
  assert.equal(p.moves(socket).at(-1).r, 9, 'Moves follow the current picture revision');
  p.controller.update({enabled: false, live: true, revision: 9});
  assert.equal(socket.closed, true, 'Pointers off closes the channel');
  assert.equal(p.get('pointer').hidden, true);
});

test('a refusal stops reconnecting and a dropped channel retries with backoff', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  let socket = p.start();
  socket.drop();
  p.controller.update({enabled: true, live: true, revision: 7});
  assert.equal(p.sockets.length, 1, 'Waits before reconnecting');
  p.advance(1100); p.controller.update({enabled: true, live: true, revision: 7});
  assert.equal(p.sockets.length, 2);
  socket = p.sockets[1]; socket.open(); socket.message({t: 'denied', reason: 'access'}); socket.drop();
  p.advance(20000); p.controller.update({enabled: true, live: true, revision: 7});
  assert.equal(p.sockets.length, 2, 'A refused page does not keep asking');
});

test('a locked admitted name cannot be edited for pointing', () => {
  const p = page({locked: true, name: 'Approved Sam'});
  p.controller.update({enabled: true, live: true, revision: 7});
  p.get('pointer').dispatch('click');
  assert.equal(p.get('pointer-name').disabled, true);
  assert.equal(p.get('pointer-name').value, 'Approved Sam');
});

test('late snapshots from an earlier picture or during Hold are ignored (A2, B1)', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  p.controller.update({enabled: true, live: true, revision: 8});
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 3000}]});
  assert.equal(p.marks().length, 0, 'A delayed revision-7 snapshot does not restore old positions');
  p.get('picture').dispatch('pointermove', {clientX: 900, clientY: 500, pointerType: 'mouse'});
  assert.equal(p.moves(socket).at(-1).r, 8, 'Outgoing moves keep the newest revision');
  p.controller.update({enabled: true, live: false, revision: 8});
  socket.message({t: 'pointers', r: 8, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 3000}]});
  assert.equal(p.marks().length, 0, 'Nothing renders during Hold');
});

test('turning off sharing drops a queued move and hides at once (A3, B2)', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  const picture = p.get('picture');
  picture.dispatch('pointermove', {clientX: 900, clientY: 500, pointerType: 'mouse'});
  picture.dispatch('pointermove', {clientX: 950, clientY: 500, pointerType: 'mouse'});
  const moves = p.moves(socket).length;
  p.get('pointer-share').checked = false; p.get('pointer-share').dispatch('change');
  assert.equal(socket.sent.at(-1).t, 'hide');
  p.advance(100);
  assert.equal(p.moves(socket).length, moves, 'The queued position is never sent after opting out');
});

test('a pointer refreshed during its fade stays visible (A5, B3)', () => {
  const p = page();
  p.controller.update({enabled: true, live: true, revision: 7});
  const socket = p.start();
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.5, y: 0.5, ttl: 500}]});
  p.advance(600);
  assert.equal(p.marks()[0].classList.contains('fading'), true);
  socket.message({t: 'pointers', r: 7, items: [{n: 3, label: 'Ana', color: 'green', x: 0.6, y: 0.5, ttl: 4000}]});
  p.advance(1000);
  assert.equal(p.marks().length, 1);
  assert.equal(p.marks()[0].classList.contains('fading'), false, 'The earlier removal was cancelled');
});
