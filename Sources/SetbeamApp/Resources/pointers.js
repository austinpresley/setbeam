// Shared pointers: an admitted viewer's opt-in, named pointer over the shared picture.
// Positions are fractions of the visible source picture, never of the page or window.
// The channel carries presence only; it cannot control the Mac, media, or the session.
(() => {
  const COLORS = {blue: ['#1a5ed9', '#fff'], green: ['#17783a', '#fff'], orange: ['#fa941a', '#141414'],
    pink: ['#cc2980', '#fff'], purple: ['#7540cc', '#fff'], yellow: ['#fad11f', '#141414']};
  const SEND_INTERVAL = 33, PING_INTERVAL = 5000, FADE = 600, IDLE = 4000;

  // The picture inside an element showing it with object-fit: contain.
  function contentRect(box, videoWidth, videoHeight) {
    if (!(videoWidth > 0 && videoHeight > 0 && box.width > 0 && box.height > 0)) return null;
    const scale = Math.min(box.width / videoWidth, box.height / videoHeight);
    const width = videoWidth * scale, height = videoHeight * scale;
    return {left: box.left + (box.width - width) / 2, top: box.top + (box.height - height) / 2, width, height};
  }
  // A page position as a picture fraction, or null outside the picture (letterbox, controls, page).
  function toPicture(rect, clientX, clientY) {
    if (!rect || !Number.isFinite(clientX) || !Number.isFinite(clientY)) return null;
    const x = (clientX - rect.left) / rect.width, y = (clientY - rect.top) / rect.height;
    return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? {x, y} : null;
  }
  function validItem(item) {
    return item && Number.isInteger(item.n) && typeof item.label === 'string' && Object.hasOwn(COLORS, item.color) &&
      Number.isFinite(item.x) && Number.isFinite(item.y) && item.x >= 0 && item.x <= 1 && item.y >= 0 && item.y <= 1 &&
      Number.isFinite(item.ttl) && item.ttl > 0;
  }

  function attach(viewer) {
    const $ = id => document.getElementById(id);
    const picture = $('picture'), video = $('video'), layer = $('pointer-layer'), button = $('pointer'), panel = $('pointer-panel');
    const nameInput = $('pointer-name'), share = $('pointer-share'), showOthers = $('pointer-show'), status = $('pointer-status');
    let color = 'blue';
    try { if (Object.hasOwn(COLORS, sessionStorage.getItem('setbeam-pointer-color'))) color = sessionStorage.getItem('setbeam-pointer-color'); } catch {}
    let enabled = false, live = false, wanted = false, joined = false, socket, retryAt = 0, retryDelay = 1000, denied = '';
    let serverRevision = -1, lastSent, pending, sendTimer, pingTimer, sweepTimer, sharing = true, ownExpires = 0, ownPoint;
    const marks = new Map();
    let lastRevision, lastInputs = '';

    const swatches = $('pointer-colors');
    for (const name of Object.keys(COLORS)) {
      const label = document.createElement('label'); label.className = 'swatch'; label.title = name[0].toUpperCase() + name.slice(1);
      const input = document.createElement('input'); input.type = 'radio'; input.name = 'pointer-color'; input.value = name;
      input.setAttribute('aria-label', label.title); input.checked = name === color;
      const dot = document.createElement('span'); dot.style.setProperty('--c', COLORS[name][0]);
      input.addEventListener('change', () => { if (input.checked) chooseColor(name); });
      label.append(input, dot); swatches.append(label);
    }
    function chooseColor(name) {
      color = name;
      try { sessionStorage.setItem('setbeam-pointer-color', name); } catch {}
      // The channel announces a color once; rejoin to change it.
      if (joined) { reconnect(); }
    }
    function say(value) { if (status.textContent !== value) status.textContent = value; }
    function refresh() {
      button.hidden = !enabled;
      button.setAttribute('aria-pressed', String(joined && wanted));
      $('pointer-join').textContent = wanted ? 'Stop pointing' : 'Start pointing';
      $('pointer-share-row').hidden = !wanted; $('pointer-show-row').hidden = !wanted;
      nameInput.disabled = viewer.nameLocked();
      if (document.activeElement !== nameInput) nameInput.value = viewer.name();
      picture.classList.toggle('pointing', joined && wanted && sharing && live);
      layer.hidden = !showOthers.checked;
      if (!enabled) { panel.hidden = true; button.setAttribute('aria-expanded', 'false'); }
      if (denied === 'name') say('Enter a name to point.');
      else if (denied === 'full') say('Too many people are pointing right now.');
      else if (denied) say('Pointing is unavailable for this page.');
      else if (wanted && !joined) say('Connecting…');
      else if (wanted && !live) say('Pointers return when the picture is live.');
      else if (wanted) say(viewer.nameLocked() ? 'Pointing as ' + viewer.name() + '.' : 'Pointing. Move over the picture or tap it.');
      else say('');
    }

    function open() {
      if (socket || !wanted || !enabled || Date.now() < retryAt) return;
      const pass = viewer.pass();
      if (!pass) return;
      const path = location.pathname.replace(/[^/]*$/, '') + 'presence';
      let next;
      try { next = socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + path); }
      catch { socket = undefined; retryAt = Date.now() + retryDelay; return; }
      next.onopen = () => { if (next === socket) next.send(JSON.stringify({t: 'hello', pass, name: viewer.name(), color})); };
      next.onmessage = event => {
        if (next !== socket) return;
        let message; try { message = JSON.parse(event.data); } catch { return; }
        if (message.t === 'welcome') { joined = true; denied = ''; retryDelay = 1000; serverRevision = message.r; startPing(); refresh(); }
        else if (message.t === 'pointers' && Array.isArray(message.items)) receive(message);
        else if (message.t === 'denied') { denied = String(message.reason || 'access'); wanted = message.reason === 'full' ? wanted : false; }
      };
      next.onclose = () => {
        if (next !== socket) return;
        socket = undefined; joined = false; stopPing(); clearMarks();
        retryAt = Date.now() + retryDelay; retryDelay = Math.min(10000, retryDelay * 2);
        refresh();
      };
    }
    function close() {
      const current = socket; socket = undefined; joined = false;
      stopPing(); clearMarks(); clearTimeout(sendTimer); sendTimer = undefined; pending = undefined; lastSent = undefined;
      try { current?.close(); } catch {}
    }
    function reconnect() { close(); retryAt = 0; open(); refresh(); }
    function send(message) { if (joined && socket?.readyState === 1) socket.send(JSON.stringify(message)); }
    function startPing() { stopPing(); pingTimer = setInterval(() => send({t: 'ping'}), PING_INTERVAL); }
    function stopPing() { clearInterval(pingTimer); pingTimer = undefined; }

    // Coalesce to about 30 updates per second and never resend an unchanged position.
    function queue(point, tap) {
      if (!joined || !sharing || !live) return;
      if (!point) { pending = undefined; hide(); return; }
      pending = {x: Math.round(point.x * 10000) / 10000, y: Math.round(point.y * 10000) / 10000, tap: !!tap};
      if (!sendTimer) flush();
    }
    function flush() {
      sendTimer = undefined;
      const next = pending; pending = undefined;
      if (!next || !sharing || !live) return;
      if (!next.tap && lastSent && lastSent.x === next.x && lastSent.y === next.y) return;
      lastSent = next;
      send({t: 'move', x: next.x, y: next.y, r: serverRevision, tap: next.tap || undefined});
      sendTimer = setTimeout(flush, SEND_INTERVAL);
    }
    function hide() {
      if (lastSent) send({t: 'hide'});
      lastSent = undefined; ownPoint = undefined; ownExpires = 0; renderOwn();
    }
    function rect() {
      const box = picture.getBoundingClientRect();
      return contentRect(box, video.videoWidth, video.videoHeight);
    }
    function pointerEvent(event, tap) {
      if (!joined || !sharing || !live) return;
      const point = toPicture(rect(), event.clientX, event.clientY);
      queue(point, tap);
      // A touch has no visible cursor, so show this viewer where the others see the pointer.
      if (point && event.pointerType !== 'mouse') { ownPoint = point; ownExpires = Date.now() + IDLE; renderOwn(); }
    }
    picture.addEventListener('pointermove', event => pointerEvent(event, false));
    picture.addEventListener('pointerdown', event => pointerEvent(event, true));
    picture.addEventListener('pointerleave', event => { if (event.pointerType === 'mouse') queue(null); });
    picture.addEventListener('pointercancel', () => queue(null));
    document.addEventListener('visibilitychange', () => { if (document.hidden) queue(null); });
    window.addEventListener('pagehide', () => { wanted = false; close(); });

    function place(element, x, y) {
      element.style.left = (x * 100) + '%'; element.style.top = (y * 100) + '%';
      element.classList.toggle('flip-x', x > 0.85); element.classList.toggle('flip-y', y > 0.9);
    }
    function mark(colorName, label) {
      const element = document.createElement('div'); element.className = 'pointer-mark';
      element.style.setProperty('--c', COLORS[colorName][0]); element.style.setProperty('--t', COLORS[colorName][1]);
      element.append(document.createElement('i'));
      const name = document.createElement('b'); name.textContent = label; element.append(name);
      layer.append(element);
      return element;
    }
    function receive(message) {
      // A snapshot delayed past Hold or a newer picture describes positions that no longer apply.
      if (!live || !Number.isInteger(message.r) || message.r < serverRevision) return;
      if (message.r !== serverRevision) { serverRevision = message.r; lastSent = undefined; }
      const now = Date.now(), seen = new Set();
      for (const item of message.items.slice(0, 32)) {
        if (!validItem(item)) continue;
        seen.add(item.n);
        let entry = marks.get(item.n);
        if (!entry || entry.color !== item.color || entry.label !== item.label) {
          entry?.element.remove();
          entry = {element: mark(item.color, item.label.slice(0, 48)), color: item.color, label: item.label};
          marks.set(item.n, entry);
        }
        entry.expires = now + item.ttl;
        entry.fading = false; entry.element.classList.remove('fading');
        place(entry.element, item.x, item.y);
      }
      for (const [n, entry] of marks) if (!seen.has(n)) fade(n, entry);
      sweep();
    }
    function fade(n, entry) {
      if (entry.fading) return;
      entry.fading = true; entry.element.classList.add('fading');
      // Movement during the fade revives the pointer and cancels this removal.
      setTimeout(() => { if (marks.get(n) === entry && entry.fading) { entry.element.remove(); marks.delete(n); } }, FADE);
    }
    // Expire locally too, so a lost connection or a silent sender never leaves a pointer behind.
    function sweep() {
      clearTimeout(sweepTimer); sweepTimer = undefined;
      const now = Date.now();
      for (const [n, entry] of marks) if (entry.expires <= now) fade(n, entry);
      if (ownPoint && ownExpires <= now) { ownPoint = undefined; renderOwn(); }
      const next = Math.min(...[...marks.values()].filter(e => !e.fading).map(e => e.expires), ownPoint ? ownExpires : Infinity);
      if (Number.isFinite(next)) sweepTimer = setTimeout(sweep, Math.max(50, next - now));
    }
    let own;
    function renderOwn() {
      if (!ownPoint) { own?.classList.add('fading'); return; }
      if (!own || own.dataset.color !== color) { own?.remove(); own = mark(color, 'You'); own.dataset.color = color; }
      own.classList.remove('fading'); place(own, ownPoint.x, ownPoint.y); sweep();
    }
    function clearMarks() {
      for (const entry of marks.values()) entry.element.remove();
      marks.clear(); ownPoint = undefined; own?.remove(); own = undefined;
    }
    // Follow the picture through resizing, full screen, and letterboxing.
    function layout() {
      const box = picture.getBoundingClientRect(), r = rect();
      if (!r) return;
      layer.style.left = (r.left - box.left) + 'px'; layer.style.top = (r.top - box.top) + 'px';
      layer.style.width = r.width + 'px'; layer.style.height = r.height + 'px';
    }
    if (typeof ResizeObserver === 'function') new ResizeObserver(layout).observe(picture);
    window.addEventListener('resize', layout); video.addEventListener('resize', layout); video.addEventListener('loadedmetadata', layout);
    document.addEventListener('fullscreenchange', layout);

    button.addEventListener('click', () => {
      panel.hidden = !panel.hidden; button.setAttribute('aria-expanded', String(!panel.hidden));
      if (!panel.hidden) { refresh(); (nameInput.disabled ? $('pointer-join') : nameInput).focus(); }
    });
    document.addEventListener('click', event => {
      if (!panel.hidden && !panel.contains(event.target) && !button.contains(event.target)) { panel.hidden = true; button.setAttribute('aria-expanded', 'false'); }
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && !panel.hidden) { event.preventDefault(); panel.hidden = true; button.setAttribute('aria-expanded', 'false'); button.focus(); }
    });
    $('pointer-form').addEventListener('submit', event => {
      event.preventDefault();
      if (wanted) { wanted = false; denied = ''; hide(); close(); refresh(); return; }
      const name = viewer.nameLocked() ? viewer.name() : viewer.setName(nameInput.value);
      if (!name) { denied = 'name'; refresh(); nameInput.focus(); return; }
      wanted = true; denied = ''; retryAt = 0; retryDelay = 1000; open(); refresh();
    });
    share.addEventListener('change', () => {
      if (!share.checked) { pending = undefined; clearTimeout(sendTimer); sendTimer = undefined; hide(); }
      sharing = share.checked; refresh();
    });
    showOthers.addEventListener('change', refresh);

    return {
      color: () => color,
      // Called on every viewer update; it acts only when the session's inputs change.
      update(next) {
        const inputs = [next.enabled, next.live, next.revision].join();
        if (inputs !== lastInputs) {
          lastInputs = inputs;
          const revisionChanged = lastRevision !== undefined && next.revision !== lastRevision;
          lastRevision = next.revision;
          if (Number.isInteger(next.revision) && next.revision > serverRevision) serverRevision = next.revision;
          enabled = next.enabled; live = next.live;
          // Hold, Stop, removal, and a replaced picture end this page's positions at once.
          if (!enabled) { wanted = false; denied = ''; close(); }
          else if (!live || revisionChanged) { pending = undefined; lastSent = undefined; ownPoint = undefined; renderOwn(); clearMarks(); }
          refresh(); layout();
        }
        if (enabled && wanted && !socket && Date.now() >= retryAt) { open(); refresh(); }
      }
    };
  }
  globalThis.SetbeamPointers = {COLORS, contentRect, toPicture, validItem, attach};
})();
