(() => {
  const video = document.getElementById('video');
  const label = document.getElementById('state');
  const slate = document.getElementById('slate');
  const sound = document.getElementById('sound');
  const retry = document.getElementById('retry');
  let reader, mode = 'reconnecting', config, revision = -1, lastTime = -1, lastFrameAt = 0;
  let receivedTrack = false, pollRunning = false, playBlocked = false, unavailable = false;
  let readerStartedAt = 0, readerGeneration = 0;
  const id = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
  const playing = () => mode === 'live' && receivedTrack && !video.paused && video.readyState >= 2 && Date.now() - lastFrameAt < 6000;
  function show(title, copy) {
    slate.hidden = false;
    document.getElementById('slate-title').textContent = title;
    document.getElementById('slate-copy').textContent = copy;
  }
  function update() {
    label.className = 'state ' + (playing() ? 'live' : mode === 'live' ? 'reconnecting' : mode);
    sound.disabled = !playing();
    retry.hidden = !playBlocked && !unavailable;
    if (unavailable) { label.textContent = 'Session unavailable'; show('This viewing link is unavailable', 'Ask the operator for the current viewing code.'); }
    else if (mode === 'holding') { label.textContent = 'On hold'; show('Audience on hold', 'The operator is still monitoring. Your picture will return here when sharing resumes.'); }
    else if (mode === 'stopped') { label.textContent = 'Sharing ended'; show('Sharing has ended', 'Ask the operator for a new code when sharing starts again.'); }
    else if (playBlocked) { label.textContent = 'Ready to play'; show('Your picture is ready', 'Tap Try again to start playback.'); }
    else if (playing()) { label.textContent = 'Live feed'; slate.hidden = true; }
    else { label.textContent = 'Reconnecting'; show('Waiting for the picture', 'Keep this page open. Your picture reconnects automatically.'); }
    video.muted = mode !== 'live' || sound.getAttribute('aria-pressed') !== 'true';
  }
  function closeReader() {
    readerGeneration++;
    reader?.close(); reader = undefined; receivedTrack = false; lastFrameAt = 0; lastTime = -1;
    video.srcObject = null; video.muted = true;
  }
  function play() { return video.play().then(() => { playBlocked = false; update(); }).catch(() => { playBlocked = true; update(); }); }
  function startReader() {
    closeReader(); playBlocked = false; readerStartedAt = Date.now();
    const generation = readerGeneration;
    reader = new MediaMTXWebRTCReader({url: config.whepURL, user: config.user, pass: config.pass,
      onTrack: event => {
        if (generation !== readerGeneration) return;
        video.srcObject = event.streams[0]; receivedTrack = true; play();
      },
      onError: () => { if (generation === readerGeneration) { receivedTrack = false; update(); } }});
  }
  function frame() {
    if (video.currentTime !== lastTime && !video.paused && video.readyState >= 2) {
      lastTime = video.currentTime; lastFrameAt = Date.now(); update();
    }
  }
  if (video.requestVideoFrameCallback) {
    const nextFrame = () => { frame(); video.requestVideoFrameCallback(nextFrame); };
    video.requestVideoFrameCallback(nextFrame);
  } else { video.addEventListener('timeupdate', frame); }
  sound.addEventListener('click', () => {
    const enabled = sound.getAttribute('aria-pressed') !== 'true';
    sound.setAttribute('aria-pressed', String(enabled)); sound.textContent = enabled ? 'Mute sound' : 'Enable sound';
    update(); play();
  });
  retry.addEventListener('click', () => { if (unavailable) { unavailable = false; config = undefined; poll(); } else { play(); } });
  document.getElementById('fullscreen').addEventListener('click', () => {
    const picture = document.getElementById('picture');
    if (picture.requestFullscreen) picture.requestFullscreen().catch(() => {});
    else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
  });
  async function request(url, options = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(url, {...options, signal: controller.signal, cache: 'no-store'});
      // Include body consumption in the deadline, since headers can arrive before a stalled body.
      const body = response.ok ? await response.json() : undefined;
      return {ok: response.ok, status: response.status, body};
    } finally { clearTimeout(timeout); }
  }
  async function poll() {
    if (pollRunning) return; pollRunning = true;
    try {
      if (!config) {
        const response = await request('config.json');
        if (response.status === 404) { unavailable = true; update(); return; }
        if (!response.ok) throw new Error('Connection unavailable');
        config = response.body; unavailable = false;
      }
      const response = await request('state.json');
      if (response.status === 404) { mode = 'stopped'; closeReader(); update(); return; }
      if (!response.ok) throw new Error('Connection unavailable');
      const state = response.body; const previous = mode; mode = state.state;
      if (mode === 'live' && revision >= 0 && revision !== state.revision) {
        const refreshed = await request('config.json');
        if (!refreshed.ok) throw new Error('Connection unavailable');
        config = refreshed.body;
      }
      document.getElementById('title').textContent = state.title; document.title = state.title + ' · Setbeam';
      document.getElementById('sample').hidden = !state.sample;
      document.getElementById('network-hint').textContent = state.wifiSSID ? 'Stay on ' + state.wifiSSID + '. Your picture reconnects automatically.' : 'Stay on the same network as the operator. Your picture reconnects automatically.';
      const stalled = !document.hidden && !playBlocked && Date.now() - (lastFrameAt || readerStartedAt) > 10000;
      if (mode === 'live' && (previous !== 'live' || revision !== state.revision || !reader || stalled)) startReader();
      else if (mode !== 'live') closeReader();
      revision = state.revision;
      update();
      await request('heartbeat', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({id, mobile: /iPhone|iPad|Android/.test(navigator.userAgent), playing: playing(), revision})}).catch(() => {});
    } catch { if (mode !== 'holding' && mode !== 'stopped') mode = 'reconnecting'; update(); }
    finally { pollRunning = false; }
  }
  window.addEventListener('online', poll);
  window.addEventListener('pagehide', closeReader);
  window.addEventListener('pageshow', poll);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
  setInterval(() => { update(); poll(); }, 1500);
  poll();
})();
