// Shared pointers: an admitted viewer's opt-in, named pointer over the shared picture.
// Positions are fractions of the visible source picture, never of the page or window.
// The channel carries presence only; it cannot control the Mac, media, or the session.
(() => {
  // The validated preset colors, in the order the join card offers them. Fill, then name text with at least 4.5:1 contrast.
  const COLORS = {red: ['#c42b2b', '#fff'], orange: ['#fa941a', '#141414'], yellow: ['#fad11f', '#141414'], lime: ['#a6d93b', '#141414'],
    green: ['#17783a', '#fff'], teal: ['#0b7480', '#fff'], cyan: ['#3cc8e6', '#141414'], blue: ['#1a5ed9', '#fff'],
    indigo: ['#4338ca', '#fff'], purple: ['#7540cc', '#fff'], pink: ['#cc2980', '#fff'], brown: ['#8a5526', '#fff']};
  const SEND_INTERVAL = 33, PING_INTERVAL = 5000, FADE = 600, IDLE = 4000, HANDSHAKE_TIMEOUT = 5000;
  const cleanLabel = value => Array.from(value.replace(/[\p{Cc}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/gu, '').replace(/\s+/gu, ' ').trim()).slice(0, 40).join('');

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
    return item && Number.isSafeInteger(item.n) && item.n > 0 && typeof item.label === 'string' && Object.hasOwn(COLORS, item.color) &&
      Number.isFinite(item.x) && Number.isFinite(item.y) && item.x >= 0 && item.x <= 1 && item.y >= 0 && item.y <= 1 &&
      Number.isFinite(item.ttl) && item.ttl > 0;
  }

  function attach(viewer) {
    const $ = id => document.getElementById(id);
    const picture = $('picture'), video = $('video'), layer = $('pointer-layer'), button = $('pointer');
    const share = $('pointer-share'), showOthers = $('pointer-show'), status = $('pointer-status');
    // The viewer's one name and color, chosen on the join card, label this pointer.
    const color = () => Object.hasOwn(COLORS, viewer.color?.()) ? viewer.color() : 'blue';
    let enabled = false, live = false, suspended = false, wanted = false, joined = false, socket, channelPass, retryAt = 0, retryDelay = 1000, denied = '';
    let gatewayRevision = -1, displayedRevision, serverRevision = -1, selfNumber, lastSent, pending, sendTimer, pingTimer, sweepTimer, handshakeTimer;
    let ownExpires = 0, ownPoint;
    const sharing = () => share.checked, watching = () => showOthers.checked;
    const pictureReady = () => live && !suspended && !document.hidden && Number.isSafeInteger(gatewayRevision) && gatewayRevision >= 0 &&
      (viewer.displayedRevision ? viewer.displayedRevision() : displayedRevision) === gatewayRevision && serverRevision <= gatewayRevision;
    const canShare = () => enabled && joined && wanted && sharing() && pictureReady();
    const marks = new Map();
    let statusTimer, lastReady;

    // Status appears briefly over the picture: the first-use hint, then only changes and problems.
    function say(value) {
      if (status.textContent === value) return;
      status.textContent = value; status.hidden = !value;
      clearTimeout(statusTimer);
      if (value) statusTimer = setTimeout(() => { status.hidden = true; }, 4000);
    }
    function refresh() {
      button.hidden = !enabled;
      button.setAttribute('aria-pressed', String(wanted));
      action(wanted ? 'Stop pointing' : 'Point at the picture');
      $('pointer-share-row').hidden = !wanted; $('pointer-show-row').hidden = !wanted;
      picture.classList.toggle('pointing', canShare());
      layer.hidden = !pictureReady() || (!watching() && !sharing());
      if (denied === 'name') say('Choose a name before pointing.');
      else if (denied === 'full') say('Too many people are pointing right now.');
      else if (denied) say('Pointing is unavailable for this page.');
      else if (wanted && !sharing() && !watching()) say('');
      else if (wanted && !joined) say('Connecting…');
      else if (wanted && !pictureReady()) say('Pointers return when the picture is live.');
      else if (wanted && sharing()) say('Pointing as ' + cleanLabel(viewer.name()) + '. Move over the picture or tap it.');
      else if (wanted) say('Watching shared pointers.');
      else say('');
    }

    function channelFailed() {
      close(); retryAt = Date.now() + retryDelay; retryDelay = Math.min(10000, retryDelay * 2);
      refresh();
    }
    function open() {
      if (socket || !wanted || !enabled || suspended || (!sharing() && !watching()) || Date.now() < retryAt) return;
      const pass = viewer.pass();
      if (!pass) return;
      const path = location.pathname.replace(/[^/]*$/, '') + 'presence';
      let next;
      try { next = socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + path); }
      catch { channelFailed(); return; }
      channelPass = pass;
      handshakeTimer = setTimeout(() => { if (next === socket && !joined) channelFailed(); }, HANDSHAKE_TIMEOUT);
      next.onopen = () => {
        if (next !== socket) return;
        try { next.send(JSON.stringify({t: 'hello', pass, name: cleanLabel(viewer.name()), color: color()})); }
        catch { channelFailed(); }
      };
      next.onmessage = event => {
        if (next !== socket || typeof event.data !== 'string' || event.data.length > 32_768) return;
        let message; try { message = JSON.parse(event.data); } catch { return; }
        if (message?.t === 'welcome' && !joined && Number.isSafeInteger(message.n) && message.n > 0 && Number.isSafeInteger(message.r)) {
          clearTimeout(handshakeTimer); joined = true; selfNumber = message.n; serverRevision = message.r;
          denied = ''; retryDelay = 1000; startPing(); refresh();
        } else if (message?.t === 'pointers' && joined && Array.isArray(message.items)) receive(message);
        else if (message?.t === 'denied') {
          denied = message.reason === 'full' || message.reason === 'name' ? message.reason : 'access';
          if (denied !== 'full') wanted = false;
          channelFailed();
        }
      };
      next.onclose = next.onerror = () => { if (next === socket) channelFailed(); };
    }
    function close() {
      const current = socket; socket = undefined; channelPass = undefined; joined = false; selfNumber = undefined; serverRevision = -1;
      clearTimeout(handshakeTimer); stopPing(); clearMarks(); clearMotion();
      try { current?.close(); } catch {}
    }
    function reconnect() { close(); retryAt = 0; open(); refresh(); }
    function send(message) {
      if (!joined || socket?.readyState !== 1) return false;
      try { socket.send(JSON.stringify(message)); return true; }
      catch { channelFailed(); return false; }
    }
    function startPing() { stopPing(); pingTimer = setInterval(() => send({t: 'ping'}), PING_INTERVAL); }
    function stopPing() { clearInterval(pingTimer); pingTimer = undefined; }

    // Coalesce to about 30 updates per second and never resend an unchanged position.
    function queue(point, tap) {
      if (!canShare()) return;
      if (!point) { pending = undefined; hide(); return; }
      pending = {x: Math.round(point.x * 10000) / 10000, y: Math.round(point.y * 10000) / 10000, tap: !!tap};
      if (!sendTimer) flush();
    }
    function flush() {
      sendTimer = undefined;
      const next = pending; pending = undefined;
      if (!next || !canShare()) return;
      if (!next.tap && lastSent && lastSent.x === next.x && lastSent.y === next.y) return;
      if (!send({t: 'move', x: next.x, y: next.y, r: gatewayRevision, tap: next.tap || undefined})) return;
      lastSent = next;
      sendTimer = setTimeout(flush, SEND_INTERVAL);
    }
    function clearMotion() {
      clearTimeout(sendTimer); sendTimer = undefined; pending = undefined; lastSent = undefined;
      ownPoint = undefined; ownExpires = 0; renderOwn();
    }
    function hide() {
      if (lastSent) send({t: 'hide'});
      clearMotion();
    }
    function rect() {
      const box = picture.getBoundingClientRect();
      return contentRect(box, video.videoWidth, video.videoHeight);
    }
    function pointerEvent(event, tap) {
      if (!canShare() || event.isPrimary === false || (tap && event.button !== undefined && event.button !== 0)) return;
      const point = toPicture(rect(), event.clientX, event.clientY);
      queue(point, tap);
      // A touch has no visible cursor, so show this viewer where the others see the pointer.
      if (point && event.pointerType !== 'mouse') { ownPoint = point; ownExpires = Date.now() + IDLE; renderOwn(); }
    }
    picture.addEventListener('pointermove', event => pointerEvent(event, false));
    picture.addEventListener('pointerdown', event => pointerEvent(event, true));
    picture.addEventListener('pointerleave', event => { if (event.pointerType === 'mouse') queue(null); });
    picture.addEventListener('pointercancel', event => { if (event.isPrimary !== false && canShare()) hide(); });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { hide(); clearMarks(); }
      refresh();
    });
    window.addEventListener('pagehide', () => { wanted = false; close(); });

    function place(element, x, y) {
      element.style.left = (x * 100) + '%'; element.style.top = (y * 100) + '%';
      const flip = x > 0.5, width = rect()?.width || 0;
      element.classList.toggle('flip-x', flip); element.classList.toggle('flip-y', y > 0.85);
      element.label.style.maxWidth = Math.max(0, Math.min(144, width * (flip ? x : 1 - x) - 16)) + 'px';
    }
    function mark(colorName, label) {
      const element = document.createElement('div'); element.className = 'pointer-mark';
      element.style.setProperty('--c', COLORS[colorName][0]); element.style.setProperty('--t', COLORS[colorName][1]);
      element.append(document.createElement('i'));
      const name = document.createElement('b'); name.textContent = label; element.append(name);
      name.dir = 'auto'; name.style.overflow = 'hidden'; name.style.textOverflow = 'ellipsis'; element.label = name;
      layer.append(element);
      return element;
    }
    function receive(message) {
      // A snapshot delayed past Hold or a newer picture describes positions that no longer apply.
      if (!Number.isSafeInteger(message.r) || message.r < serverRevision) return;
      serverRevision = message.r;
      if (!pictureReady()) { clearMotion(); clearMarks(); refresh(); return; }
      if (!watching() || message.r !== gatewayRevision) return;
      const now = Date.now(), seen = new Set();
      for (const item of message.items.slice(0, 32)) {
        if (!validItem(item) || item.n === selfNumber) continue;
        const label = cleanLabel(item.label);
        if (!label) continue;
        seen.add(item.n);
        let entry = marks.get(item.n);
        if (!entry || entry.color !== item.color || entry.label !== label) {
          entry?.element.remove();
          entry = {element: mark(item.color, label), color: item.color, label};
          marks.set(item.n, entry);
        }
        entry.x = item.x; entry.y = item.y; entry.expires = now + Math.min(IDLE, item.ttl);
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
      if (!ownPoint) { own?.remove(); own = undefined; return; }
      if (!own || own.dataset.color !== color()) { own?.remove(); own = mark(color(), 'You'); own.dataset.color = color(); }
      own.classList.remove('fading'); place(own, ownPoint.x, ownPoint.y); sweep();
    }
    function clearMarks() {
      for (const entry of marks.values()) entry.element.remove();
      marks.clear(); sweep();
    }
    // Follow the picture through resizing, full screen, and letterboxing.
    function layout() {
      const box = picture.getBoundingClientRect(), r = rect();
      if (!r) return;
      layer.style.left = (r.left - box.left) + 'px'; layer.style.top = (r.top - box.top) + 'px';
      layer.style.width = r.width + 'px'; layer.style.height = r.height + 'px';
      for (const entry of marks.values()) place(entry.element, entry.x, entry.y);
      if (own && ownPoint) place(own, ownPoint.x, ownPoint.y);
    }
    if (typeof ResizeObserver === 'function') new ResizeObserver(layout).observe(picture);
    window.addEventListener('resize', layout); video.addEventListener('resize', layout); video.addEventListener('loadedmetadata', layout);
    document.addEventListener('fullscreenchange', layout);

    function action(name) {
      if (button.getAttribute('aria-label') === name) return;
      button.setAttribute('aria-label', name); button.setAttribute('title', name + ' (P)');
    }
    // One tap starts pointing and another stops it.
    function toggle() {
      if (wanted) { wanted = false; denied = ''; hide(); close(); refresh(); return; }
      // A session without a name chooses one on the join card first; pointing never asks for a second name.
      if (!cleanLabel(viewer.name() || '')) { denied = 'name'; refresh(); viewer.editIdentity?.(); return; }
      wanted = true; denied = ''; retryAt = 0; retryDelay = 1000; open(); refresh();
    }
    button.addEventListener('click', toggle);
    $('pointer-form').addEventListener('submit', event => { event.preventDefault(); toggle(); });
    function changeOptions() {
      if (!sharing()) hide();
      if (!watching()) clearMarks();
      if (!sharing() && !watching()) close();
      else open();
      refresh();
    }
    share.addEventListener('change', changeOptions);
    showOthers.addEventListener('change', changeOptions);

    return {
      color,
      identityChanged() { if (socket) reconnect(); },
      update(next) {
        const previousRevision = gatewayRevision, previousEnabled = enabled;
        enabled = next.enabled; live = next.live; suspended = next.suspended === true; gatewayRevision = next.revision;
        displayedRevision = Object.hasOwn(next, 'displayedRevision') ? next.displayedRevision : (live ? gatewayRevision : undefined);
        const ready = pictureReady();
        const channelEnded = (!enabled && (wanted || socket || denied)) || (socket && channelPass !== viewer.pass());
        const pictureChanged = previousRevision !== gatewayRevision || lastReady !== ready;
        if (suspended) {
          if (socket) close();
          lastReady = false;
          if (pictureChanged || previousEnabled !== enabled) refresh();
          return;
        }
        if (channelEnded) {
          wanted = false; denied = ''; close();
        } else if (pictureChanged) {
          if (!ready && previousRevision === gatewayRevision && live) hide();
          clearMotion(); clearMarks();
        }
        lastReady = ready;
        if (pictureChanged || channelEnded || previousEnabled !== enabled) { refresh(); layout(); }
        if (enabled && wanted && !socket && Date.now() >= retryAt && (sharing() || watching())) { open(); refresh(); }
      }
    };
  }
  globalThis.SetbeamPointers = {COLORS, contentRect, toPicture, validItem, attach};
})();
