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
  let viewerName = '', pointersOn = false;
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
  // Badge label, card title, copy, symbol, and page state for each step of the join page.
  const joinViews = {
    identify: ['Joining', 'Join this feed', 'Choose a name and color so the operator knows who is watching.', 'user', 'ask'],
    name: ['Ask to join', 'Ask to join', 'The operator admits each viewer. Choose a name they will recognize and a color.', 'user', 'ask'],
    edit: ['', 'Your name and color', 'Change how you appear to the operator and to other viewers.', 'user', ''],
    full: ['Session busy', 'This session is busy', 'Too many people are waiting to join. Try again shortly.', 'user', 'ask'],
    pending: ['Waiting to join', 'Waiting for the operator', 'Keep this page open. The picture starts when the operator admits you.', 'loader', 'pending'],
    declined: ['Not admitted', 'The operator declined this request', 'Ask the operator if you should be watching.', 'link-off', 'refused'],
    removed: ['Removed', 'The operator removed you from this session', 'This page no longer receives the picture.', 'link-off', 'refused'],
    unavailable: ['Session unavailable', 'This viewing link is no longer active', 'Sharing may have ended or the code changed. Ask the operator for the current code.', 'link-off', 'refused'],
    ended: ['Sharing ended', 'Sharing ended', 'Ask the operator for a new code.', 'end', 'refused']
  };
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
    const [, title, copy, symbol] = joinViews[view];
    const heading = document.getElementById('join-title'), joinName = document.getElementById('join-name');
    text(heading, title); text(document.getElementById('join-copy'), copy);
    document.getElementById('join-icon').setAttribute('href', '#i-' + symbol);
    const detail = joinDetail(view), joinRetry = document.getElementById('join-retry');
    text(document.getElementById('join-detail'), detail); document.getElementById('join-detail').hidden = !detail;
    const form = identityForm(view), locked = view === 'edit' && nameLocked(), submit = document.getElementById('join-submit');
    document.getElementById('join-form').hidden = !form;
    text(submit, view === 'name' ? 'Ask to join' : view === 'edit' ? 'Save' : 'Join');
    submit.disabled = asking; joinName.readOnly = asking || locked;
    document.getElementById('join-cancel').hidden = view !== 'edit';
    document.getElementById('join-network').hidden = view === 'edit';
    text(document.getElementById('join-hint'), identityHint(view));
    joinRetry.hidden = !(view === 'unavailable' || view === 'full' && approval); joinRetry.disabled = asking;
    text(document.getElementById('join-status'), joinMessage(view));
    if (view === previous) return;
    if (form && !joinDirty && focused !== joinName) { joinName.value = viewerName; draftColor = viewerColor; }
    renderSwatches();
    // Changing the name or color was asked for, so the editor always takes focus.
    if (view === 'edit') (locked ? swatchInputs.find(input => input.checked) || submit : joinName).focus();
    else if (hadFocus && (previous || globalThis.matchMedia?.('(pointer: fine)').matches)) (form ? joinName : heading).focus();
  }
  // Connection help shows the one identity and offers to change it; it has no name field of its own.
  function renderIdentity() {
    text(document.getElementById('identity-name'), viewerName || 'No name yet');
    document.getElementById('identity-dot').style.setProperty('--c', palette[viewerColor][0]);
    const locked = nameLocked();
    text(document.getElementById('identity-note'), locked ? 'Names stay fixed while the operator approves viewers. You can change your color.'
      : pointersOn ? 'The operator sees this name, and other viewers see it when you point.' : 'The operator sees this name.');
    const edit = document.getElementById('identity-edit');
    text(edit, locked ? 'Change color' : 'Change name or color');
    edit.hidden = !canEdit();
    const direct = document.getElementById('identity-button');
    direct.hidden = !canEdit();
    direct.setAttribute('aria-expanded', String(editing));
    action(direct, (viewerName || 'Your identity') + '. ' + (locked ? 'Change color' : 'Change name or color'));
  }
  const canEdit = () => access === 'admitted' && !unavailable && mode !== 'stopped';
  function openEditor() {
    if (!canEdit()) return;
    if (editing) { closeEditor(); return; }
    closeHelp(); editing = true; joinDirty = false; joinNote = ''; update();
    if (globalThis.matchMedia?.('(max-width:600px), (max-height:600px)').matches) document.getElementById('join').scrollIntoView?.({block: 'nearest'});
  }
  function closeEditor() { editing = false; joinNote = ''; update(); document.getElementById('identity-button').focus(); }
  function update() {
    const live = playing(), waiting = everPlayed ? 'reconnecting' : 'connecting', view = joinView();
    if (editing && (view || !canEdit())) editing = false;
    const shown = view || (editing ? 'edit' : undefined);
    const state = view ? joinViews[view][4] : unavailable ? 'unavailable' : playBlocked && mode === 'live' ? 'blocked' : mode === 'live' && !live ? waiting : mode;
    label.className = 'state ' + state;
    const collaborationClasses = ['chat-open', 'keyboard-tight'].filter(name => player.classList?.contains(name)).join(' ');
    player.className = 'player ' + state + (view ? ' join-open' : editing ? ' identity-open' : '') + (collaborationClasses ? ' ' + collaborationClasses : '');
    sound.hidden = !hasAudio; sound.disabled = !live;
    pip.hidden = !pipSupported(); pip.disabled = !live;
    retry.hidden = !(playBlocked && mode === 'live') && !unavailable;
    action(retry, unavailable ? 'Reconnect' : 'Play feed');
    document.getElementById('retry-icon').setAttribute('href', unavailable ? '#i-loader' : '#i-play');
    if (shown || shownJoin) renderJoin(shown);
    // The join page replaces the picture slate until the session is admitted.
    if (view) text(label, joinViews[view][0]);
    else if (unavailable) { text(label, 'Session unavailable'); show('This viewing link is unavailable', 'Ask the operator for the current code.', 'link-off'); }
    else if (mode === 'holding') { text(label, 'On hold'); show('On hold', 'Your picture returns when sharing resumes.', 'pause'); }
    else if (mode === 'stopped') { text(label, 'Sharing ended'); show('Sharing ended', 'Ask the operator for a new code.', 'end'); }
    else if (playBlocked && mode === 'live') { text(label, 'Ready to play'); show('Your picture is ready', 'Tap to watch.', 'play'); }
    else if (live) { text(label, 'Live feed'); slate.hidden = true; }
    else { text(label, everPlayed ? 'Reconnecting' : 'Connecting'); show('Waiting for the picture', everPlayed ? 'Keep this page open. Stay on the viewing network.' : 'Waiting for the picture.', 'loader'); }
    video.muted = mode !== 'live' || unavailable || sound.getAttribute('aria-pressed') !== 'true';
    renderIdentity();
    if (editing) positionIdentityEditor();
    const ended = mode === 'stopped' || unavailable || refused();
    if (ended && keepAwake) releaseAwake();
    awake.disabled = ended;
    if (streaming() && live !== reportedPlaying) heartbeat();
    // Pointing ends with the session: removal, refusal, Stop, and an unavailable link all close it.
    const pointable = pointersOn && access === 'admitted' && !unavailable && mode !== 'stopped';
    pointers?.update({enabled: pointable, live: pointable && mode === 'live', revision});
    chat?.update({admitted: access === 'admitted', active: !ended, live: playing(), revision});
  }
  const controls = document.getElementById('controls');
  const controlsToggle = document.getElementById('controls-toggle');
  let controlsShown = false, controlsTimer;
  const controlsPinned = () => editing || controls.contains(document.activeElement) ||
    !document.getElementById('help-panel').hidden || !document.getElementById('pointer-panel').hidden;
  function displayControls(shown) {
    controlsShown = shown; controls.hidden = !shown;
    controlsToggle.setAttribute('aria-expanded', String(shown));
    action(controlsToggle, shown ? 'Hide viewer controls' : 'Show viewer controls');
  }
  function scheduleControls() {
    clearTimeout(controlsTimer);
    controlsTimer = setTimeout(() => {
      if (controlsPinned()) scheduleControls(); else displayControls(false);
    }, 3000);
  }
  function revealControls() { displayControls(true); scheduleControls(); }
  controlsToggle.addEventListener('click', () => {
    if (controlsShown && !controlsPinned()) { clearTimeout(controlsTimer); displayControls(false); }
    else revealControls();
  });
  controlsToggle.addEventListener('focus', () => {
    // Pointer focus precedes click; revealing here would make that same click close it.
    if (controlsToggle.matches?.(':focus-visible')) revealControls();
  });
  controls.addEventListener('focusin', revealControls);
  controls.addEventListener('focusout', scheduleControls);
  controls.addEventListener('pointermove', revealControls);
  const pictureIsPointing = () => document.getElementById('picture').classList?.contains?.('pointing');
  document.getElementById('picture').addEventListener('pointermove', event => {
    if (event.pointerType !== 'touch' && !pictureIsPointing()) revealControls();
  });
  displayControls(false);
  function positionIdentityEditor() {
    const picture = document.getElementById('picture');
    if (typeof picture.getBoundingClientRect !== 'function') return;
    const outer = player.getBoundingClientRect(), content = picture.getBoundingClientRect();
    player.style.setProperty('--identity-right', Math.max(6, outer.right - content.right + 6) + 'px');
  }
  window.addEventListener('resize', positionIdentityEditor);
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
  document.getElementById('picture').addEventListener('click', event => {
    engageAwake();
    if (!event?.target?.closest?.('button') && !pictureIsPointing()) revealControls();
  });
  document.getElementById('picture').addEventListener('dblclick', event => { if (!event.target.closest('button')) toggleFullscreen(); });
  fullscreen.addEventListener('click', toggleFullscreen);
  help.addEventListener('click', () => {
    const panel = document.getElementById('help-panel'); panel.hidden = !panel.hidden;
    help.setAttribute('aria-expanded', String(!panel.hidden)); revealControls();
  });
  document.addEventListener('click', event => { if (!help.contains(event.target) && !document.getElementById('help-panel').contains(event.target)) closeHelp(); });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && editing) { event.preventDefault(); closeEditor(); return; }
    if (event.key === 'Escape' && !document.getElementById('help-panel').hidden) {
      event.preventDefault(); closeHelp(); help.focus(); return;
    }
    if (!event.defaultPrevented && event.key === 'Escape' && controlsShown && document.getElementById('pointer-panel').hidden) {
      event.preventDefault(); displayControls(false); controlsToggle.focus(); displayControls(false); return;
    }
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || event.repeat || event.target.closest?.('input,textarea,select,[contenteditable]')) return;
    if (event.key.toLowerCase() === 'm') { event.preventDefault(); toggleSound(); }
    if (event.key.toLowerCase() === 'f') { event.preventDefault(); toggleFullscreen(); }
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
  }
  function viewerHealth() {
    if (document.hidden) return 'background';
    if (playBlocked) return 'ready';
    if (receivedTrack && video.paused) return 'paused';
    if (!playing()) return everPlayed ? 'reconnecting' : 'connecting';
    if (typeof reader?.getStats !== 'function') return 'playing';
    return Date.now() - healthAt < 7000 ? healthQuality : 'checking';
  }
  function sampleHealth() {
    if (!playing() || document.hidden || statsPending || typeof reader?.getStats !== 'function') return;
    const generation = healthGeneration;
    statsPending = true;
    reader.getStats().then(report => {
      if (generation !== healthGeneration) return;
      const inbound = [...report.values()].find(s => s.type === 'inbound-rtp' && s.kind === 'video' && Number.isFinite(s.packetsReceived) && Number.isFinite(s.packetsLost) && Number.isFinite(s.timestamp));
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
      if (generation === healthGeneration) { healthQuality = 'playing'; healthAt = Date.now(); statsPrevious = undefined; }
    }).finally(() => { if (generation === healthGeneration) statsPending = false; });
  }
  function cleanName(value) {
    return [...value.replace(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f]/g, '').trim().replace(/\s+/g, ' ')].slice(0, 40).join('');
  }
  const joinName = document.getElementById('join-name');
  joinName.value = viewerName;
  joinName.addEventListener('input', () => { joinDirty = true; });
  const swatchInputs = [];
  for (const name of colorNames) {
    const option = document.createElement('label'); option.className = 'swatch'; option.title = name[0].toUpperCase() + name.slice(1);
    const input = document.createElement('input'); input.type = 'radio'; input.name = 'viewer-color'; input.value = name;
    input.setAttribute('aria-label', option.title);
    const dot = document.createElement('span'); dot.style.setProperty('--c', palette[name][0]);
    input.addEventListener('change', () => { if (input.checked) { draftColor = name; joinDirty = true; } });
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
  document.getElementById('identity-edit').addEventListener('click', openEditor);
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
    const network = state.wifiSSID ? 'Stay on ' + state.wifiSSID + '.' : 'Stay on the same network as the operator.';
    text(document.getElementById('network-hint'), network); text(document.getElementById('join-network'), network);
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
