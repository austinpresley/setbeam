(() => {
  const video = document.getElementById('video');
  const label = document.getElementById('state');
  const slate = document.getElementById('slate');
  const sound = document.getElementById('sound');
  const retry = document.getElementById('retry');
  const awakeVideo = document.getElementById('keepawake');
  let reader, mode = 'connecting', config, revision = -1, lastTime = -1, lastFrameAt = 0;
  let receivedTrack = false, pollRunning = false, playBlocked = false, unavailable = false;
  let readerStartedAt = 0, readerGeneration = 0, hasAudio = false, everPlayed = false;
  const player = document.getElementById('player');
  const pip = document.getElementById('pip');
  const fullscreen = document.getElementById('fullscreen');
  // Pushed state replaces 1.5 s polling while the stream stays healthy. Polling remains the fallback.
  let events, eventsAt = 0, eventsHeard = false, eventsRetryAt = 0, applying = Promise.resolve(), pushes = 0;
  let heartbeatAt = 0, reportedPlaying;
  let viewerName = '', pointersOn = false, networkHint = 'Stay on the same network as the operator.';
  try { viewerName = sessionStorage.getItem('setbeam-viewer-name') || ''; } catch { /* Naming also works without storage. */ }
  // One identity, a name and a color, labels this session for the operator and for shared pointers.
  // It is chosen once on the join card and saved only in this tab. Names are labels, not verified.
  const palette = globalThis.SetbeamPointers?.COLORS || {blue: ['#1a5ed9', '#fff']};
  const colorNames = Object.keys(palette);
  let viewerColor;
  try { viewerColor = sessionStorage.getItem('setbeam-pointer-color'); } catch {}
  if (!Object.hasOwn(palette, viewerColor)) viewerColor = colorNames[Math.floor(Math.random() * colorNames.length)];
  let draftColor = viewerColor, editing = false;
  let healthGeneration = 0, statsPrevious, statsPending = false, healthQuality = 'checking', healthAt = 0, badSamples = 0, goodSamples = 0;
  const statsFreshFor = 7000;
  let measurements, measuredAt;
  let keepAwake = false, wakeLock, wakeLockPending = false;
  const id = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
  // Setbeam issues each tab a secret pass. Only that pass identifies this session; under approval
  // it is admitted, declined, or removed by the operator, and a reload keeps that decision.
  const passKey = 'setbeam-pass:' + (globalThis.location?.pathname || '');
  let pass, access = 'joining', approval = false, mediaReady = false, joinRunning = false;
  // Under approval a new request is sent only when the viewer presses Ask to join. A saved name
  // prefills the form; restoring a pass resumes its request or decision without asking again.
  let asking = false, pollAgain = false, joinNote = '', joinTrouble = false, joinNumber, joinDirty = false, shownJoin;
  try { pass = sessionStorage.getItem(passKey) || undefined; } catch { /* A tab without storage joins again after reload. */ }
  const refused = () => access === 'declined' || access === 'removed';
  // Under approval a name is fixed once the session has one; a session admitted unnamed may set one first label.
  const nameLocked = () => approval && !!pass && !!viewerName;
  const pointers = globalThis.SetbeamPointers?.attach({
    pass: () => pass, name: () => viewerName, color: () => viewerColor, nameLocked,
    editIdentity: () => openEditor(), live: () => mode === 'live' && access === 'admitted' && !unavailable
  });
  const chat = globalThis.SetbeamChat?.attach({pass: () => pass, live: () => playing(), revision: () => revision});
  const playing = () => mode === 'live' && receivedTrack && !video.paused && video.readyState >= 2 && Date.now() - lastFrameAt < 6000;
  const stalled = () => !document.hidden && !playBlocked && Date.now() - (lastFrameAt || readerStartedAt) > 10000;
  // A stream must deliver its first state quickly and a keepalive about every 10 s after that.
  const streaming = () => events && events.readyState !== 2 && Date.now() - eventsAt <= (eventsHeard ? 25000 : 5000);
  function text(element, value) { if (element.textContent !== value) element.textContent = value; }
  // Shortcut keys appear in each control's tooltip rather than in a help panel.
  const shortcuts = {sound: 'M', fullscreen: 'F', pointer: 'P', 'chat-toggle': 'C'};
  function action(button, name) {
    if (button.getAttribute('aria-label') !== name) {
      const key = shortcuts[button.id];
      button.setAttribute('aria-label', name); button.setAttribute('title', key ? name + ' (' + key + ')' : name);
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
  // Badge label, card title, copy, symbol, and page state for each step of the join page.
  // The card shows the viewer's avatar while choosing or waiting, and one symbol otherwise. Form titles are
  // read by assistive technology only; the avatar, fields, and button carry the step on screen.
  const joinViews = {
    identify: ['Joining', 'Join this feed', '', 'user', 'ask', 'form'],
    name: ['Ask to join', 'Ask to join', '', 'user', 'ask', 'form'],
    edit: ['', 'Your name and color', '', 'user', '', 'form'],
    full: ['Session busy', 'Session busy', 'Try again shortly.', 'user', 'ask', 'notice'],
    pending: ['Waiting to join', 'Waiting to be let in', 'Keep this page open', 'loader', 'pending', 'wait'],
    declined: ['Not admitted', 'Not admitted', 'Check with the operator.', 'link-off', 'refused', 'notice'],
    removed: ['Removed', 'Removed from this session', '', 'link-off', 'refused', 'notice'],
    unavailable: ['Session unavailable', 'Link unavailable', 'Ask for the current link or code.', 'link-off', 'refused', 'notice'],
    ended: ['Sharing ended', 'Sharing ended', 'Ask for a new link.', 'end', 'refused', 'notice']
  };
  // An avatar is the name's first letter on the chosen color, so the viewer sees how others see them.
  function paintAvatar(element, name, colorName) {
    const [background, foreground] = palette[colorName] || palette[viewerColor] || ['#77777f', '#fff'];
    text(element, ([...(name || '').trim()][0] || '').toUpperCase());
    element.style.setProperty('--c', background); element.style.setProperty('--t', foreground);
  }
  // Only a session that is not admitted sees the join page; admitted viewers keep the picture.
  function joinView() {
    if (!['name', 'full', 'pending', 'declined', 'removed'].includes(access)) return undefined;
    if (refused()) return access;
    if (unavailable) return 'unavailable';
    if (mode === 'stopped') return 'ended';
    // With approval off the same name and color step comes first, then the picture plays.
    return access === 'name' && !approval ? 'identify' : access;
  }
  const identityForm = view => view === 'name' || view === 'identify' || view === 'edit';
  // Every place the name appears is listed, so the viewer knows who sees it before choosing.
  function identityHint(view) {
    const seen = pointersOn ? 'Shown to the operator, and to other viewers when you point.' : 'Shown to the operator.';
    if (view === 'name') return seen + ' It stays fixed after you ask. Names are not verified.';
    if (view === 'edit' && nameLocked()) return 'Names stay fixed while the operator approves viewers. You can change your color.';
    return seen + ' Names are not verified.';
  }
  function joinMessage(view) {
    if (view === 'name' && asking) return 'Sending your request…';
    if (view === 'identify' && asking) return 'Joining…';
    if ((view === 'name' || view === 'identify') && joinNote === 'error') return navigator.onLine === false
      ? 'This device is offline. Reconnect to the viewing network, then try again.'
      : 'The request did not reach the operator. Check that you are on the viewing network, then try again.';
    if (view === 'name' && joinNote === 'again') return 'This page needs to ask again. Check your name, then send a new request.';
    if (identityForm(view) && joinNote === 'empty') return 'Enter a name the operator will recognize.';
    if (view === 'pending' && joinTrouble) return 'Connection lost. Keep this page open while it reconnects.';
    if (view === 'full' && asking) return 'Trying again…';
    return '';
  }
  function joinDetail(view) {
    if (!joinNumber || !['pending', 'declined', 'removed'].includes(view)) return '';
    const verb = view === 'pending' ? 'Asking' : view === 'declined' ? 'Asked' : 'Joined';
    return viewerName ? verb + ' as ' + viewerName + ' (session ' + joinNumber + ')' : 'Session ' + joinNumber;
  }
  // Focus moves only when the step changes, never on a poll, and a touch keyboard opens only on request.
  function renderJoin(view) {
    const section = document.getElementById('join'), previous = shownJoin, focused = document.activeElement;
    const hadFocus = !focused || focused === document.body || section.contains(focused);
    shownJoin = view; section.hidden = !view;
    if (!view) { if (previous && focused && section.contains(focused)) document.getElementById('title').focus(); return; }
    const [, title, copy, symbol, , kind] = joinViews[view];
    const heading = document.getElementById('join-title'), joinName = document.getElementById('join-name');
    section.className = 'join ' + kind;
    text(heading, title); text(document.getElementById('join-copy'), copy); document.getElementById('join-copy').hidden = !copy;
    document.getElementById('join-icon').setAttribute('href', '#i-' + symbol);
    const detail = joinDetail(view), joinRetry = document.getElementById('join-retry');
    text(document.getElementById('join-detail'), detail); document.getElementById('join-detail').hidden = !detail;
    const form = identityForm(view), locked = view === 'edit' && nameLocked(), submit = document.getElementById('join-submit');
    document.getElementById('join-form').hidden = !form;
    text(submit, view === 'name' ? 'Ask to join' : view === 'edit' ? 'Save' : 'Join');
    submit.disabled = asking; joinName.readOnly = asking || locked;
    document.getElementById('join-cancel').hidden = view !== 'edit';
    // Network advice appears only when a request could not get through.
    const trouble = joinNote === 'error' || view === 'pending' && joinTrouble;
    text(document.getElementById('join-network'), trouble ? networkHint : ''); document.getElementById('join-network').hidden = !trouble;
    // Pointer choices sit with the identity they show, while this viewer is pointing.
    document.getElementById('pointer-form').hidden = view !== 'edit' || !pointersOn;
    text(document.getElementById('join-hint'), identityHint(view));
    document.getElementById('join-hint-button').setAttribute('title', identityHint(view));
    joinRetry.hidden = !(view === 'unavailable' || view === 'full' && approval); joinRetry.disabled = asking;
    text(document.getElementById('join-status'), joinMessage(view));
    if (view === previous) return;
    if (form && !joinDirty && focused !== joinName) { joinName.value = viewerName; draftColor = viewerColor; }
    renderSwatches(); paintJoinAvatar();
    // Changing the name or color was asked for, so the editor always takes focus.
    if (view === 'edit') (locked ? swatchInputs.find(input => input.checked) || submit : joinName).focus();
    else if (hadFocus && (previous || globalThis.matchMedia?.('(pointer: fine)').matches)) (form ? joinName : heading).focus();
  }
  // The avatar in the corner is the one identity; it opens the editor and has no name field of its own.
  function renderIdentity() {
    const locked = nameLocked();
    paintAvatar(document.getElementById('identity-avatar'), viewerName, viewerColor);
    const direct = document.getElementById('identity-button');
    direct.hidden = !canEdit();
    direct.setAttribute('aria-expanded', String(editing));
    action(direct, (viewerName || 'Your identity') + '. ' + (locked ? 'Change color' : 'Change name or color'));
  }
  const canEdit = () => access === 'admitted' && !unavailable && mode !== 'stopped';
  function openEditor() {
    if (!canEdit()) return;
    if (editing) { closeEditor(); return; }
    editing = true; joinDirty = false; joinNote = ''; update();
  }
  function closeEditor() { editing = false; joinNote = ''; update(); document.getElementById('identity-button').focus(); }
  function update() {
    const live = playing(), waiting = everPlayed ? 'reconnecting' : 'connecting', view = joinView();
    if (editing && (view || !canEdit())) editing = false;
    const shown = view || (editing ? 'edit' : undefined);
    const state = view ? joinViews[view][4] : unavailable ? 'unavailable' : playBlocked && mode === 'live' ? 'blocked' : mode === 'live' && !live ? waiting : mode;
    label.className = 'state ' + state;
    const collaborationClasses = ['chat-open', 'chat-docked', 'keyboard-tight'].filter(name => player.classList?.contains(name)).join(' ');
    player.className = 'player ' + state + (view ? ' join-open' : editing ? ' identity-open' : '') + (controlsShown ? '' : ' idle') +
      (collaborationClasses ? ' ' + collaborationClasses : '');
    sound.hidden = !hasAudio; sound.disabled = !live;
    pip.hidden = !pipSupported(); pip.disabled = !live;
    retry.hidden = !(playBlocked && mode === 'live') && !unavailable;
    action(retry, unavailable ? 'Reconnect' : 'Play feed');
    document.getElementById('retry-icon').setAttribute('href', unavailable ? '#i-loader' : '#i-play');
    if (shown || shownJoin) renderJoin(shown);
    // The join page replaces the picture slate until the session is admitted.
    if (view) text(label, joinViews[view][0]);
    else if (unavailable) { text(label, 'Session unavailable'); show('Link unavailable', 'Ask for the current link or code.', 'link-off'); }
    else if (mode === 'holding') { text(label, 'On hold'); show('On hold', '', 'pause'); }
    else if (mode === 'stopped') { text(label, 'Sharing ended'); show('Sharing ended', 'Ask for a new link.', 'end'); }
    else if (playBlocked && mode === 'live') { text(label, 'Ready to play'); show('Tap to watch', '', 'play'); }
    else if (live) { text(label, 'Live feed'); slate.hidden = true; }
    // Network advice appears only after the picture drops, not before the first picture.
    else { text(label, everPlayed ? 'Reconnecting' : 'Connecting'); show(everPlayed ? 'Reconnecting' : 'Connecting', everPlayed ? networkHint : '', 'loader'); }
    video.muted = mode !== 'live' || unavailable || sound.getAttribute('aria-pressed') !== 'true';
    renderIdentity();
    const ended = mode === 'stopped' || unavailable || refused();
    if (ended && keepAwake) releaseAwake();
    // The screen stays on once the picture plays, until the session ends.
    else if (!ended && live && !keepAwake) engageAwake();
    if (streaming() && live !== reportedPlaying) heartbeat();
    // Pointing ends with the session: removal, refusal, Stop, and an unavailable link all close it.
    const pointable = pointersOn && access === 'admitted' && !unavailable && mode !== 'stopped';
    pointers?.update({enabled: pointable, live: pointable && mode === 'live', revision});
    chat?.update({admitted: access === 'admitted', active: !ended, live: playing(), revision});
  }
  // On a large screen the controls float over the picture and fade after 3 s without movement. Keyboard focus,
  // an open editor, and pointing keep them in view. On a phone held upright they sit below the picture.
  const controls = document.getElementById('controls');
  let controlsShown = true, controlsTimer;
  const pictureIsPointing = () => document.getElementById('picture').classList?.contains?.('pointing');
  const controlsPinned = () => editing || controls.contains(document.activeElement) || pictureIsPointing();
  function displayControls(shown) {
    if (controlsShown === shown) return;
    controlsShown = shown; update();
  }
  function scheduleControls() {
    clearTimeout(controlsTimer);
    controlsTimer = setTimeout(() => {
      if (controlsPinned()) scheduleControls(); else displayControls(false);
    }, 3000);
  }
  function revealControls() { displayControls(true); scheduleControls(); }
  controls.addEventListener('focusin', revealControls);
  controls.addEventListener('focusout', scheduleControls);
  document.getElementById('stage').addEventListener('pointermove', event => {
    if (event.pointerType !== 'touch') revealControls();
  });
  scheduleControls();
  document.getElementById('pointer').addEventListener('click', () => { if (editing) closeEditor(); }, {capture: true});
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
    resetHealth();
    if (video.webkitDisplayingFullscreen) { try { video.webkitExitFullscreen(); } catch {} }
    reader?.close(); reader = undefined; receivedTrack = false; lastFrameAt = 0; lastTime = -1;
    video.srcObject = null; video.muted = true;
  }
  function play() {
    const generation = readerGeneration;
    return video.play().then(() => { if (generation === readerGeneration) { playBlocked = false; update(); } })
      // Only the autoplay policy blocks playback. A replaced source aborts the earlier request.
      .catch(error => { if (generation === readerGeneration && error?.name === 'NotAllowedError') { playBlocked = true; update(); } });
  }
  function startReader() {
    closeReader(); playBlocked = false; readerStartedAt = Date.now();
    if (!config || access !== 'admitted') return;
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

  // Keep the viewer's screen on once the picture plays or after a tap. Wake Lock needs a secure context;
  // otherwise a tiny muted looping clip plays, which keeps the screen on in some mobile browsers.
  function engageAwake() {
    if (keepAwake || mode === 'stopped' || unavailable) return;
    keepAwake = true; acquireAwake();
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
    awakeVideo.pause();
  }

  function toggleSound() {
    if (sound.hidden || sound.disabled) return;
    const enabled = sound.getAttribute('aria-pressed') !== 'true';
    sound.setAttribute('aria-pressed', String(enabled)); action(sound, enabled ? 'Mute' : 'Unmute');
    document.getElementById('sound-icon').setAttribute('href', enabled ? '#i-volume' : '#i-volume-x');
    engageAwake(); update(); play();
  }
  function fullscreenState() {
    const expanded = document.fullscreenElement === player || video.webkitDisplayingFullscreen;
    action(fullscreen, expanded ? 'Exit full screen' : 'Enter full screen');
    document.getElementById('fullscreen-icon').setAttribute('href', expanded ? '#i-min' : '#i-max');
  }
  function toggleFullscreen() {
    engageAwake();
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
  document.getElementById('picture').addEventListener('click', event => {
    engageAwake();
    if (!event?.target?.closest?.('button') && !pictureIsPointing()) revealControls();
  });
  document.getElementById('picture').addEventListener('dblclick', event => { if (!event.target.closest('button')) toggleFullscreen(); });
  fullscreen.addEventListener('click', toggleFullscreen);
  // A click outside the identity editor closes it, as Escape and Cancel do.
  document.addEventListener('click', event => {
    if (!editing || !event?.target?.closest) return;
    if (!event.target.closest('#join') && !event.target.closest('#identity-button')) closeEditor();
  });
  const press = id => { const button = document.getElementById(id); if (!button.hidden && !button.disabled) button.click?.(); };
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && editing) { event.preventDefault(); closeEditor(); return; }
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || event.repeat || event.target.closest?.('input,textarea,select,[contenteditable]')) return;
    const key = event.key.toLowerCase();
    if (key === 'm') { event.preventDefault(); toggleSound(); }
    if (key === 'f') { event.preventDefault(); toggleFullscreen(); }
    if (key === 'p') { event.preventDefault(); press('pointer'); }
    if (key === 'c') { event.preventDefault(); press('chat-toggle'); }
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
    sampleHealth();
    if (!pass || refused()) return Promise.resolve();
    const sent = pass;
    const body = {pass, mobile: /iPhone|iPad|Android/.test(navigator.userAgent), playing: reportedPlaying, health: viewerHealth(), revision, color: viewerColor};
    const ageMs = Date.now() - measuredAt;
    if (measurements && access === 'admitted' && reportedPlaying && !document.hidden && !playBlocked && ageMs >= 0 && ageMs < statsFreshFor) {
      body.measurements = {...measurements, ageMs};
    }
    // Under approval the gateway accepts only a first label for a session admitted unnamed.
    if (!approval || viewerName) body.name = viewerName;
    return request('heartbeat', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)})
      .then(response => { if (sent === pass && response.ok) { admission(response.body?.admission); chat?.activity(response.body?.chatLastID); } }).catch(() => {});
  }
  // Removal and refusal end playback at once. An unknown pass, such as after a restarted gateway, joins again.
  function admission(value) {
    if (value === 'removed' || value === 'declined') { access = value; config = undefined; closeReader(); dropEvents(); update(); }
    else if (value === 'unknown') { if (approval) joinNote = 'again'; forgetPass(); config = undefined; closeReader(); update(); }
  }
  function forgetPass() {
    pass = undefined; access = 'joining'; mediaReady = false; joinNumber = undefined;
    try { sessionStorage.removeItem(passKey); } catch {}
  }
  const mobile = () => /iPhone|iPad|Android/.test(navigator.userAgent);
  async function join() {
    if (joinRunning || refused()) return false;
    const asked = asking, hadPass = !!pass;
    // A new session waits on the join card until the viewer chooses a name and color. Under approval
    // a request goes out only after Ask to join. A restored pass resumes its state as before.
    if (!pass && !asked && (access === 'name' || !viewerName)) { access = 'name'; return false; }
    if (!pass && access === 'full' && approval && !asked) return false;
    joinRunning = true;
    try {
      let response;
      try {
        response = await request('join', {method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({pass, name: (asked || !approval) && viewerName || undefined, ask: asked || undefined, color: viewerColor, mobile: mobile()})});
      } catch (error) {
        // A failed request is reported in the form; the viewer decides whether to send it again.
        if (!asked) throw error;
        asking = false; joinNote = 'error'; return false;
      }
      if (asked) asking = false;
      joinTrouble = false;
      if (response.status === 404) { unavailable = true; return false; }
      if (response.status === 400) {
        // The gateway needs a name and an explicit request: approval is on and this tab has no request.
        forgetPass(); access = 'name'; approval = true;
        if (asked) joinNote = 'empty'; else if (hadPass) joinNote = 'again';
        return false;
      }
      if (response.status === 503) { access = 'full'; return false; }
      if (!response.ok || typeof response.body?.pass !== 'string') {
        if (asked) { joinNote = 'error'; return false; }
        throw new Error('Connection unavailable');
      }
      pass = response.body.pass; access = response.body.admission; mediaReady = response.body.ready === true;
      joinNumber = Number.isInteger(response.body.number) ? response.body.number : undefined; joinNote = '';
      try { sessionStorage.setItem(passKey, pass); } catch {}
      if (approval && typeof response.body.name === 'string') viewerName = response.body.name;
      if (access !== 'admitted') { config = undefined; closeReader(); }
      return access === 'admitted' && mediaReady;
    } finally { joinRunning = false; }
  }
  async function loadConfig() {
    const response = await request('config.json', {headers: {'X-Setbeam-Pass': pass || ''}});
    if (response.status === 404) { unavailable = true; return false; }
    // Refused, not yet admitted, or not yet in effect: join again to learn this session's state.
    if (response.status === 403 || response.status === 503) { config = undefined; mediaReady = false; return false; }
    if (!response.ok) throw new Error('Connection unavailable');
    config = response.body; unavailable = false;
    return true;
  }
  function resetHealth() {
    healthGeneration++;
    statsPrevious = undefined; statsPending = false; healthQuality = 'checking'; healthAt = 0; badSamples = 0; goodSamples = 0;
    measurements = undefined;
  }
  function viewerHealth() {
    if (document.hidden) return 'background';
    if (playBlocked) return 'ready';
    if (receivedTrack && video.paused) return 'paused';
    if (!playing()) return everPlayed ? 'reconnecting' : 'connecting';
    if (typeof reader?.getStats !== 'function') return 'playing';
    return Date.now() - healthAt < statsFreshFor ? healthQuality : 'checking';
  }
  function inboundMeasurements(inbound) {
    if (!inbound) return;
    const values = {};
    const {frameWidth: width, frameHeight: height, framesPerSecond: fps, framesDropped: droppedFrames} = inbound;
    const dimension = value => Number.isInteger(value) && value > 0 && value <= 16384;
    if (dimension(width) && dimension(height)) { values.width = width; values.height = height; }
    if (Number.isFinite(fps) && fps >= 0 && fps <= 1000) values.fps = fps;
    if (Number.isSafeInteger(droppedFrames) && droppedFrames >= 0) values.droppedFrames = droppedFrames;
    if (Object.keys(values).length) return values;
  }
  function sampleHealth() {
    if (!playing() || document.hidden || statsPending || typeof reader?.getStats !== 'function') return;
    const generation = healthGeneration;
    const sampledRevision = revision, startedAt = Date.now();
    statsPending = true;
    reader.getStats().then(report => {
      if (generation !== healthGeneration || sampledRevision !== revision || !playing() || playBlocked || document.hidden) return;
      const videoStats = [...report.values()].filter(s => s.type === 'inbound-rtp' && s.kind === 'video');
      const inbound = videoStats.find(s => Number.isFinite(s.packetsReceived) && Number.isFinite(s.packetsLost) && Number.isFinite(s.timestamp));
      measurements = inboundMeasurements(inbound || videoStats[0]);
      measuredAt = startedAt;
      const previous = statsPrevious;
      statsPrevious = inbound && {...inbound};
      healthAt = Date.now();
      if (!inbound) { healthQuality = 'playing'; return; }
      if (!previous || previous.id !== inbound.id || inbound.timestamp <= previous.timestamp || inbound.packetsReceived < previous.packetsReceived) {
        healthQuality = 'checking'; badSamples = 0; goodSamples = 0; return;
      }
      const received = inbound.packetsReceived - previous.packetsReceived;
      const lost = Math.max(0, inbound.packetsLost - previous.packetsLost);
      // Zero new packets is inconclusive. The existing decoded-frame watchdog handles a frozen peer.
      if (received + lost <= 0) { healthQuality = 'checking'; return; }
      const transport = report.get(inbound.transportId);
      const rtt = report.get(transport?.selectedCandidatePairId)?.currentRoundTripTime;
      const decoded = inbound.framesDecoded - previous.framesDecoded;
      const dropped = inbound.framesDropped - previous.framesDropped;
      const bad = lost / (received + lost) > 0.03 || inbound.jitter > 0.08 || rtt > 0.3 || (dropped > 0 && dropped / (decoded + dropped) > 0.1);
      badSamples = bad ? badSamples + 1 : 0; goodSamples = bad ? 0 : goodSamples + 1;
      if (badSamples >= 2) healthQuality = 'struggling';
      else if (goodSamples >= 2) healthQuality = 'good';
    }).catch(() => {
      if (generation === healthGeneration) {
        healthQuality = 'playing'; healthAt = Date.now(); statsPrevious = undefined; measurements = undefined;
      }
    }).finally(() => { if (generation === healthGeneration) statsPending = false; });
  }
  function cleanName(value) {
    return [...value.replace(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f]/g, '').trim().replace(/\s+/g, ' ')].slice(0, 40).join('');
  }
  const joinName = document.getElementById('join-name');
  joinName.value = viewerName;
  // The card's avatar follows the draft name and color as they change.
  function paintJoinAvatar() { paintAvatar(document.getElementById('join-avatar'), shownJoin === 'pending' ? viewerName : joinName.value, draftColor); }
  joinName.addEventListener('input', () => { joinDirty = true; paintJoinAvatar(); });
  const hintButton = document.getElementById('join-hint-button');
  hintButton.addEventListener('click', () => {
    const open = hintButton.getAttribute('aria-expanded') !== 'true';
    hintButton.setAttribute('aria-expanded', String(open)); document.getElementById('join-hint').hidden = !open;
  });
  const swatchInputs = [];
  for (const name of colorNames) {
    const option = document.createElement('label'); option.className = 'swatch'; option.title = name[0].toUpperCase() + name.slice(1);
    const input = document.createElement('input'); input.type = 'radio'; input.name = 'viewer-color'; input.value = name;
    input.setAttribute('aria-label', option.title);
    const dot = document.createElement('span'); dot.style.setProperty('--c', palette[name][0]);
    input.addEventListener('change', () => { if (input.checked) { draftColor = name; joinDirty = true; paintJoinAvatar(); } });
    option.append(input, dot); document.getElementById('join-colors').append(option); swatchInputs.push(input);
  }
  function renderSwatches() { for (const input of swatchInputs) input.checked = input.value === draftColor; }
  function ask() {
    asking = true; joinNote = ''; update();
    if (pollRunning) pollAgain = true; else poll();
  }
  document.getElementById('join-form').addEventListener('submit', event => {
    event.preventDefault();
    if (asking) return;
    const name = editing && nameLocked() ? viewerName : cleanName(joinName.value);
    joinName.value = name;
    if (!name) { joinNote = 'empty'; update(); joinName.focus(); return; }
    const changed = name !== viewerName || draftColor !== viewerColor;
    viewerName = name; viewerColor = draftColor; joinDirty = false;
    try { sessionStorage.setItem('setbeam-viewer-name', name); sessionStorage.setItem('setbeam-pointer-color', viewerColor); } catch {}
    if (!editing) { ask(); return; }
    // An admitted session's heartbeat carries the change; an open pointer channel announces it again.
    closeEditor();
    if (changed) { heartbeat(); pointers?.identityChanged?.(); }
  });
  document.getElementById('join-cancel').addEventListener('click', closeEditor);
  document.getElementById('identity-button').addEventListener('click', openEditor);
  document.getElementById('join-retry').addEventListener('click', () => {
    if (asking) return;
    joinTrouble = false;
    if (unavailable) { unavailable = false; config = undefined; update(); poll(); }
    else if (access === 'full') ask();
  });
  // Title, sample label, and network advice are public session details shown before and after joining.
  function describe(state) {
    text(document.getElementById('title'), state.title); document.title = state.title + ' · Setbeam';
    document.getElementById('sample').hidden = !state.sample;
    networkHint = state.wifiSSID ? 'Stay on ' + state.wifiSSID + '.' : 'Stay on the same network as the operator.';
  }
  async function applyState(state) {
    const previous = mode; mode = state.state;
    approval = state.approval === true; pointersOn = state.pointers === true;
    if (mode === 'live' && access === 'admitted' && revision >= 0 && revision !== state.revision) {
      // A publisher revision can move this session to its own credential.
      if (!(await loadConfig())) throw new Error('Connection unavailable');
    }
    describe(state);
    if (mode === 'live' && config && (previous !== 'live' || revision !== state.revision || !reader || stalled())) startReader();
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
    if (pollRunning || refused()) return; pollRunning = true;
    try {
      if (!config) {
        // Join first; only an admitted session whose own access is in effect gets playback details.
        if (!(await join()) || !(await loadConfig())) {
          // The join page also learns the title, whether approval is still on, and whether the link still works.
          if (!unavailable && !refused()) {
            const response = await request('state.json');
            if (response.ok) {
              approval = response.body.approval === true; pointersOn = response.body.pointers === true; mode = response.body.state;
              describe(response.body);
            } else if (response.status === 404) unavailable = true;
          }
          update(); return;
        }
      }
      const pushesBefore = pushes;
      const response = await request('state.json');
      if (response.status === 404) { mode = 'stopped'; closeReader(); update(); return; }
      if (!response.ok) throw new Error('Connection unavailable');
      // A state pushed while this request was in flight is newer than its response.
      if (pushes === pushesBefore) await applyState(response.body);
      await heartbeat();
      if (!events && typeof EventSource === 'function' && Date.now() >= eventsRetryAt) openEvents();
    } catch { if (mode !== 'holding' && mode !== 'stopped') mode = 'reconnecting'; joinTrouble = true; update(); }
    finally {
      pollRunning = false;
      // Ask to join pressed during an earlier poll is sent at once rather than on the next tick.
      if (pollAgain) { pollAgain = false; poll(); }
    }
  }
  window.addEventListener('online', poll);
  window.addEventListener('pagehide', closeReader);
  window.addEventListener('pageshow', poll);
  document.addEventListener('visibilitychange', () => { resetHealth(); heartbeat(); if (!document.hidden) { acquireAwake(); poll(); } });
  video.addEventListener('pause', () => { resetHealth(); heartbeat(); });
  setInterval(() => {
    update();
    if (events && !streaming()) dropEvents();
    if (!events) { poll(); return; }
    // While state is pushed, the periodic tick keeps the stale-peer watchdog and heartbeat running.
    if (!config && !refused()) { poll(); return; }
    if (mode === 'live' && config && (!reader || stalled())) startReader();
    // Every other tick, about 3 s. A strict 3000 ms threshold slips to 4.5 s with ordinary timer jitter.
    if (Date.now() - heartbeatAt >= 2500) heartbeat();
  }, 1500);
  poll();
})();
