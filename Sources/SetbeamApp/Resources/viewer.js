(() => {
  const video = document.getElementById('video');
  const label = document.getElementById('state');
  const slate = document.getElementById('slate');
  const sound = document.getElementById('sound');
  const retry = document.getElementById('retry');
  const awake = document.getElementById('awake');
  const awakeVideo = document.getElementById('keepawake');
  let reader, mode = 'connecting', config, revision = -1, lastTime = -1, lastFrameAt = 0;
  let receivedTrack = false, pollRunning = false, playBlocked = false, unavailable = false;
  let readerStartedAt = 0, readerGeneration = 0, hasAudio = false, everPlayed = false;
  const player = document.getElementById('player');
  const help = document.getElementById('help');
  const pip = document.getElementById('pip');
  const fullscreen = document.getElementById('fullscreen');
  // Pushed state replaces 1.5 s polling while the stream stays healthy. Polling remains the fallback.
  let events, eventsAt = 0, eventsHeard = false, eventsRetryAt = 0, applying = Promise.resolve(), pushes = 0;
  let heartbeatAt = 0, reportedPlaying;
  let keepAwake = false, wakeLock, wakeLockPending = false;
  const id = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
  const playing = () => mode === 'live' && receivedTrack && !video.paused && video.readyState >= 2 && Date.now() - lastFrameAt < 6000;
  const stalled = () => !document.hidden && !playBlocked && Date.now() - (lastFrameAt || readerStartedAt) > 10000;
  // A stream must deliver its first state quickly and a keepalive about every 10 s after that.
  const streaming = () => events && events.readyState !== 2 && Date.now() - eventsAt <= (eventsHeard ? 25000 : 5000);
  function text(element, value) { if (element.textContent !== value) element.textContent = value; }
  function action(button, name) {
    if (button.getAttribute('aria-label') !== name) {
      button.setAttribute('aria-label', name); button.setAttribute('title', name);
    }
  }
  function show(title, copy, symbol) {
    slate.hidden = false;
    text(document.getElementById('slate-title'), title);
    text(document.getElementById('slate-copy'), copy);
    document.getElementById('slate-icon').setAttribute('href', '#i-' + symbol);
    document.getElementById('slate-icon').parentElement.toggleAttribute('hidden', playBlocked && mode === 'live' && !unavailable);
  }
  function pipSupported() {
    return !!(document.pictureInPictureEnabled && video.requestPictureInPicture) ||
      !!video.webkitSupportsPresentationMode?.('picture-in-picture');
  }
  function update() {
    const live = playing(), waiting = everPlayed ? 'reconnecting' : 'connecting';
    const state = unavailable ? 'unavailable' : playBlocked && mode === 'live' ? 'blocked' : mode === 'live' && !live ? waiting : mode;
    label.className = 'state ' + state;
    player.className = 'player ' + state;
    sound.hidden = !hasAudio; sound.disabled = !live;
    pip.hidden = !pipSupported(); pip.disabled = !live;
    retry.hidden = !(playBlocked && mode === 'live') && !unavailable;
    action(retry, unavailable ? 'Reconnect' : 'Play feed');
    document.getElementById('retry-icon').setAttribute('href', unavailable ? '#i-loader' : '#i-play');
    if (unavailable) { text(label, 'Session unavailable'); show('This viewing link is unavailable', 'Ask the operator for the current code.', 'link-off'); }
    else if (mode === 'holding') { text(label, 'On hold'); show('On hold', 'Your picture returns when sharing resumes.', 'pause'); }
    else if (mode === 'stopped') { text(label, 'Sharing ended'); show('Sharing ended', 'Ask the operator for a new code.', 'end'); }
    else if (playBlocked && mode === 'live') { text(label, 'Ready to play'); show('Your picture is ready', 'Tap to watch.', 'play'); }
    else if (live) { text(label, 'Live feed'); slate.hidden = true; }
    else { text(label, everPlayed ? 'Reconnecting' : 'Connecting'); show('Waiting for the picture', everPlayed ? 'Keep this page open. Stay on the viewing network.' : 'Waiting for the picture.', 'loader'); }
    video.muted = mode !== 'live' || unavailable || sound.getAttribute('aria-pressed') !== 'true';
    const ended = mode === 'stopped' || unavailable;
    if (ended && keepAwake) releaseAwake();
    awake.disabled = ended;
    if (streaming() && live !== reportedPlaying) heartbeat();
  }
  function exitPip() {
    try {
      if (document.pictureInPictureElement === video) document.exitPictureInPicture()?.catch?.(() => {});
      if (video.webkitPresentationMode === 'picture-in-picture') video.webkitSetPresentationMode('inline');
    } catch { /* Detaching media below still suppresses the source. */ }
  }
  function observeAudio(stream, generation) {
    const updateAudio = () => {
      if (generation !== readerGeneration) return;
      const tracks = stream.getAudioTracks();
      // WebRTC can negotiate an audio receiver even for a video-only publisher.
      hasAudio = tracks.some(track => track.readyState !== 'ended' && !track.muted);
      update();
    };
    const watch = track => {
      track.addEventListener('ended', updateAudio, {once: true});
      track.addEventListener('mute', updateAudio); track.addEventListener('unmute', updateAudio);
    };
    stream.addEventListener('addtrack', event => { watch(event.track); updateAudio(); });
    stream.addEventListener('removetrack', updateAudio);
    stream.getAudioTracks().forEach(watch);
    updateAudio();
  }
  function aspectRatio() {
    if (video.videoWidth > 0 && video.videoHeight > 0) {
      player.style.setProperty('--feed-ratio', video.videoWidth / video.videoHeight);
    }
  }
  video.addEventListener('loadedmetadata', aspectRatio); video.addEventListener('resize', aspectRatio);
  function closeReader() {
    readerGeneration++; exitPip(); hasAudio = false;
    if (video.webkitDisplayingFullscreen) { try { video.webkitExitFullscreen(); } catch {} }
    reader?.close(); reader = undefined; receivedTrack = false; lastFrameAt = 0; lastTime = -1;
    video.srcObject = null; video.muted = true;
  }
  function play() {
    const generation = readerGeneration;
    return video.play().then(() => { if (generation === readerGeneration) { playBlocked = false; update(); } })
      .catch(() => { if (generation === readerGeneration) { playBlocked = true; update(); } });
  }
  function startReader() {
    closeReader(); playBlocked = false; readerStartedAt = Date.now();
    const generation = readerGeneration;
    reader = new MediaMTXWebRTCReader({url: config.whepURL, user: config.user, pass: config.pass,
      onTrack: event => {
        if (generation !== readerGeneration) return;
        video.srcObject = event.streams[0]; receivedTrack = true;
        observeAudio(event.streams[0], generation); aspectRatio(); play();
      },
      onError: () => { if (generation === readerGeneration) { receivedTrack = false; update(); } }});
  }
  function frame() {
    if (video.currentTime !== lastTime && !video.paused && video.readyState >= 2) {
      lastTime = video.currentTime; lastFrameAt = Date.now(); everPlayed = true; update();
    }
  }
  if (video.requestVideoFrameCallback) {
    const nextFrame = () => { frame(); video.requestVideoFrameCallback(nextFrame); };
    video.requestVideoFrameCallback(nextFrame);
  } else { video.addEventListener('timeupdate', frame); }

  // Keep the viewer's screen on after a tap. Wake Lock needs a secure context; plain-HTTP LAN
  // pages fall back to a tiny muted looping clip; some mobile browsers keep the screen on while it plays.
  function engageAwake() {
    if (keepAwake || mode === 'stopped' || unavailable) return;
    keepAwake = true; acquireAwake(); awake.setAttribute('aria-pressed', 'true');
  }
  function acquireAwake() {
    if (!keepAwake || document.hidden) return;
    if (!navigator.wakeLock?.request) { playAwakeVideo(); return; }
    if (wakeLock || wakeLockPending) return;
    wakeLockPending = true;
    navigator.wakeLock.request('screen').then(lock => {
      wakeLockPending = false;
      if (!keepAwake) { lock.release().catch(() => {}); return; }
      wakeLock = lock;
      lock.addEventListener?.('release', () => { if (wakeLock === lock) wakeLock = undefined; });
    }).catch(() => { wakeLockPending = false; playAwakeVideo(); });
  }
  function playAwakeVideo() {
    if (!keepAwake || !globalThis.SetbeamKeepAwakeVideo) return;
    if (!awakeVideo.src) { awakeVideo.muted = true; awakeVideo.src = globalThis.SetbeamKeepAwakeVideo; }
    awakeVideo.play()?.catch?.(() => {});
  }
  function releaseAwake() {
    keepAwake = false;
    const lock = wakeLock; wakeLock = undefined; lock?.release().catch(() => {});
    awakeVideo.pause(); awake.setAttribute('aria-pressed', 'false');
  }

  function toggleSound() {
    if (sound.hidden || sound.disabled) return;
    const enabled = sound.getAttribute('aria-pressed') !== 'true';
    sound.setAttribute('aria-pressed', String(enabled)); action(sound, enabled ? 'Mute' : 'Unmute');
    document.getElementById('sound-icon').setAttribute('href', enabled ? '#i-volume' : '#i-volume-x');
    engageAwake(); update(); play();
  }
  function closeHelp() { document.getElementById('help-panel').hidden = true; help.setAttribute('aria-expanded', 'false'); }
  function fullscreenState() {
    const expanded = document.fullscreenElement === player || video.webkitDisplayingFullscreen;
    action(fullscreen, expanded ? 'Exit full screen' : 'Enter full screen');
    document.getElementById('fullscreen-icon').setAttribute('href', expanded ? '#i-min' : '#i-max');
  }
  function toggleFullscreen() {
    engageAwake(); closeHelp();
    if (document.fullscreenElement) { document.exitFullscreen().catch(() => {}); return; }
    if (video.webkitDisplayingFullscreen) { video.webkitExitFullscreen(); return; }
    const native = () => { try { video.webkitEnterFullscreen?.(); } catch {} };
    if (player.requestFullscreen) player.requestFullscreen().catch(native);
    else native();
  }
  function pipState() {
    pip.setAttribute('aria-pressed', String(document.pictureInPictureElement === video || video.webkitPresentationMode === 'picture-in-picture'));
  }
  pip.addEventListener('click', async () => {
    engageAwake();
    try {
      if (document.pictureInPictureElement === video || video.webkitPresentationMode === 'picture-in-picture') exitPip();
      else if (video.requestPictureInPicture) await video.requestPictureInPicture();
      else video.webkitSetPresentationMode('picture-in-picture');
    } catch { /* The browser can refuse PiP even when the API is present. */ }
    pipState();
  });
  video.addEventListener('enterpictureinpicture', pipState); video.addEventListener('leavepictureinpicture', pipState);
  video.addEventListener('webkitpresentationmodechanged', pipState);
  document.addEventListener('fullscreenchange', fullscreenState);
  video.addEventListener('webkitbeginfullscreen', fullscreenState); video.addEventListener('webkitendfullscreen', fullscreenState);
  sound.addEventListener('click', toggleSound);
  retry.addEventListener('click', () => { engageAwake(); if (unavailable) { unavailable = false; config = undefined; poll(); } else { play(); } });
  awake.addEventListener('click', () => { if (keepAwake) releaseAwake(); else engageAwake(); });
  document.getElementById('picture').addEventListener('click', engageAwake);
  document.getElementById('picture').addEventListener('dblclick', event => { if (!event.target.closest('button')) toggleFullscreen(); });
  fullscreen.addEventListener('click', toggleFullscreen);
  help.addEventListener('click', () => {
    const panel = document.getElementById('help-panel'); panel.hidden = !panel.hidden;
    help.setAttribute('aria-expanded', String(!panel.hidden));
  });
  document.addEventListener('click', event => { if (!help.contains(event.target) && !document.getElementById('help-panel').contains(event.target)) closeHelp(); });
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || event.repeat || event.target.closest?.('input,textarea,select,[contenteditable]')) return;
    if (event.key.toLowerCase() === 'm') { event.preventDefault(); toggleSound(); }
    if (event.key.toLowerCase() === 'f') { event.preventDefault(); toggleFullscreen(); }
    if (event.key === 'Escape') closeHelp();
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
  function heartbeat() {
    heartbeatAt = Date.now(); reportedPlaying = playing();
    return request('heartbeat', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({id, mobile: /iPhone|iPad|Android/.test(navigator.userAgent), playing: reportedPlaying, revision})}).catch(() => {});
  }
  async function applyState(state) {
    const previous = mode; mode = state.state;
    if (mode === 'live' && revision >= 0 && revision !== state.revision) {
      const refreshed = await request('config.json');
      if (!refreshed.ok) throw new Error('Connection unavailable');
      config = refreshed.body;
    }
    text(document.getElementById('title'), state.title); document.title = state.title + ' · Setbeam';
    document.getElementById('sample').hidden = !state.sample;
    text(document.getElementById('network-hint'), state.wifiSSID ? 'Stay on ' + state.wifiSSID + '.' : 'Stay on the same network as the operator.');
    if (mode === 'live' && (previous !== 'live' || revision !== state.revision || !reader || stalled())) startReader();
    else if (mode !== 'live') closeReader();
    revision = state.revision;
    update();
  }
  function openEvents() {
    eventsAt = Date.now(); eventsHeard = false;
    const source = events = new EventSource('events?id=' + encodeURIComponent(id));
    source.onmessage = message => {
      if (source !== events) return;
      eventsAt = Date.now(); eventsHeard = true; pushes++;
      let state; try { state = JSON.parse(message.data); } catch { return; }
      applying = applying.then(() => applyState(state)).catch(() => {
        if (mode !== 'holding' && mode !== 'stopped') mode = 'reconnecting';
        dropEvents(); update();
      });
    };
    // A failed or refused stream, including a replaced viewing link, falls back to polling at once.
    source.onerror = () => { if (source === events) { dropEvents(); poll(); } };
  }
  function dropEvents() { events?.close(); events = undefined; eventsRetryAt = Date.now() + 15000; }
  async function poll() {
    if (pollRunning) return; pollRunning = true;
    try {
      if (!config) {
        const response = await request('config.json');
        if (response.status === 404) { unavailable = true; update(); return; }
        if (!response.ok) throw new Error('Connection unavailable');
        config = response.body; unavailable = false;
      }
      const pushesBefore = pushes;
      const response = await request('state.json');
      if (response.status === 404) { mode = 'stopped'; closeReader(); update(); return; }
      if (!response.ok) throw new Error('Connection unavailable');
      // A state pushed while this request was in flight is newer than its response.
      if (pushes === pushesBefore) await applyState(response.body);
      await heartbeat();
      if (!events && typeof EventSource === 'function' && Date.now() >= eventsRetryAt) openEvents();
    } catch { if (mode !== 'holding' && mode !== 'stopped') mode = 'reconnecting'; update(); }
    finally { pollRunning = false; }
  }
  window.addEventListener('online', poll);
  window.addEventListener('pagehide', closeReader);
  window.addEventListener('pageshow', poll);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { acquireAwake(); poll(); } });
  setInterval(() => {
    update();
    if (events && !streaming()) dropEvents();
    if (!events) { poll(); return; }
    // While state is pushed, the periodic tick keeps the stale-peer watchdog and heartbeat running.
    if (mode === 'live' && config && (!reader || stalled())) startReader();
    // Every other tick, about 3 s. A strict 3000 ms threshold slips to 4.5 s with ordinary timer jitter.
    if (Date.now() - heartbeatAt >= 2500) heartbeat();
  }, 1500);
  poll();
})();
