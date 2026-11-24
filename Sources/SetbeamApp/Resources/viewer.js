(() => {
  const video = document.getElementById('video');
  const label = document.getElementById('state');
  const slate = document.getElementById('slate');
  const sound = document.getElementById('sound');
  const retry = document.getElementById('retry');
  const awakeVideo = document.getElementById('keepawake');
  let reader, mode = 'connecting', config, revision = -1, displayedRevision, lastFrameAt;
  let mediaStream, frameCallback, mediaGeneration = 0, playAttempt = 0, soundEnabled = false;
  let playBlocked = false, unavailable = false, suspended = false, stateKnown = false, admissionConfirmed = false;
  let readerStartedAt = 0, readerGeneration = 0, hasAudio = false, everPlayed = false;
  const player = document.getElementById('player');
  const pip = document.getElementById('pip');
  const fullscreen = document.getElementById('fullscreen');
  // Pushed state replaces 1.5 s polling while the stream stays healthy. Polling remains the fallback.
  let events, eventsAt = 0, eventsHeard = false, eventsRetryAt = 0, pushes = 0, stateSequence;
  let heartbeatAt = 0, reportedPlaying, heartbeatAgain = false;
  const requests = new Map();
  let viewerName = '', pointersOn = false, networkHint = 'Stay on the same network as the operator.';
  try { viewerName = sessionStorage.getItem('setbeam-viewer-name') || ''; } catch { /* Naming also works without storage. */ }
  // This tab's name and color identify it to the operator, in chat, and when pointing.
  const palette = globalThis.SetbeamPointers?.COLORS || {blue: ['#1a5ed9', '#fff']};
  const colorNames = Object.keys(palette);
  let viewerColor;
  try { viewerColor = sessionStorage.getItem('setbeam-pointer-color'); } catch {}
  if (!Object.hasOwn(palette, viewerColor)) viewerColor = colorNames[Math.floor(Math.random() * colorNames.length)];
  let draftColor = viewerColor, editing = false;
  let healthGeneration = 0, statsPrevious, statsPending = false, healthQuality = 'checking', healthAt = 0, badSamples = 0, goodSamples = 0;
  const statsFreshFor = 7000;
  let measurements, measuredAt;
  let wantsAwake = false, wakeLock, awakeAttempt, fallbackAwake = false, awakeRetryAt = 0, wakeLockFailed = false;
  const id = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
  // Setbeam issues each tab a secret pass. Only that pass identifies this session; under approval
  // it is admitted, declined, or removed by the operator, and a reload keeps that decision.
  const passKey = 'setbeam-pass:' + (globalThis.location?.pathname || '');
  let pass, access = 'joining', approval = false, mediaReady = false;
  // Under approval a new request is sent only when the viewer presses Ask to join. A saved name
  // prefills the form; restoring a pass resumes its request or decision without asking again.
  let asking = false, askTicket, joinNote = '', joinTrouble = false, joinNumber, joinDirty = false, shownJoin;
  try { pass = sessionStorage.getItem(passKey) || undefined; } catch { /* A tab without storage joins again after reload. */ }
  const refused = () => access === 'declined' || access === 'removed';
  // Under approval a name is fixed once the session has one; a session admitted unnamed may set one first label.
  const nameLocked = () => approval && !!pass && !!viewerName;
  const ended = () => unavailable || mode === 'stopped' || refused();
  const running = () => !suspended && !ended();
  const liveTrack = () => !!mediaStream?.getVideoTracks().some(track => track.readyState === 'live' && !track.muted);
  const playing = () => running() && mode === 'live' && liveTrack() && !video.paused &&
    video.readyState >= 2 && lastFrameAt !== undefined && Date.now() - lastFrameAt < 6000;
  const stalled = () => !document.hidden && !playBlocked && Date.now() - (lastFrameAt ?? readerStartedAt) > 10000;
  const pointers = globalThis.SetbeamPointers?.attach({
    pass: () => pass, name: () => viewerName, color: () => viewerColor, nameLocked,
    editIdentity: () => openEditor(), live: playing
  });
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
    if (refused()) return access;
    if (unavailable) return 'unavailable';
    if (mode === 'stopped') return access === 'admitted' ? undefined : 'ended';
    if (!['name', 'full', 'pending'].includes(access)) return undefined;
    // With approval off the same name and color step comes first, then the picture plays.
    return access === 'name' && !approval ? 'identify' : access;
  }
  const identityForm = view => view === 'name' || view === 'identify' || view === 'edit';
  // The hint explains who can see the chosen name.
  function identityHint(view) {
    const seen = 'The operator sees your name. Other viewers see it on your chat messages' +
      (pointersOn ? ' and when you point.' : '.');
    if (view === 'name') return seen + ' Your name stays fixed after you ask.';
    if (view === 'edit' && nameLocked()) return seen + ' Your name is fixed while the operator approves viewers. You can change your color.';
    return seen;
  }
  function joinMessage(view) {
    if (view === 'name' && asking) return 'Sending your request…';
    if (view === 'identify' && asking) return 'Joining…';
    if ((view === 'name' || view === 'identify') && joinNote === 'error') return navigator.onLine === false
      ? 'This device is offline. Reconnect to the viewing network, then try again.'
      : 'The request could not be confirmed. Check that you are on the viewing network, then try again.';
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
    joinRetry.hidden = view !== 'full'; joinRetry.disabled = asking;
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
  const canEdit = () => access === 'admitted' && admissionConfirmed && running();
  function openEditor() {
    if (!canEdit() || chatLayerOpen()) return;
    if (editing) { closeEditor(); return; }
    editing = true; joinDirty = false; joinNote = ''; update();
  }
  function closeEditor(restoreFocus = true) {
    editing = false; joinNote = '';
    if (restoreFocus && canEdit()) { controlsShown = true; scheduleControls(); }
    update();
    if (restoreFocus && canEdit()) document.getElementById('identity-button').focus();
  }
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
    pip.hidden = !pipSupported(); pip.disabled = !live && !inPip();
    fullscreen.hidden = !standardFullscreenSupported() && typeof video.webkitEnterFullscreen !== 'function';
    fullscreen.disabled = !canEdit() || (!standardFullscreenSupported() && !live && !video.webkitDisplayingFullscreen);
    retry.hidden = !(running() && playBlocked && mode === 'live');
    syncSound();
    fullscreenState(); pipState();
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
    renderIdentity();
    if (ended()) { wantsAwake = false; releaseAwake(); }
    else if (live && !wantsAwake) engageAwake();
    if (live !== reportedPlaying) heartbeat();

    const collaborationSuspended = suspended || !stateKnown || !admissionConfirmed;
    const pointable = pointersOn && access === 'admitted' && !ended() && !collaborationSuspended;
    pointers?.update({enabled: pointable, live: pointable && live, revision: displayedRevision,
      suspended: collaborationSuspended});
    chat?.update({admitted: access === 'admitted', active: !ended(), live, revision, displayedRevision,
      suspended: collaborationSuspended});
    renderedPlaying = live;
  }
  // On a large screen the controls float over the picture and fade after 3 s without movement. Keyboard focus,
  // an open editor, and pointing keep them in view. On a phone held upright they sit below the picture.
  const controls = document.getElementById('controls');
  const identityButton = document.getElementById('identity-button');
  let renderedPlaying = false;
  let controlsShown = true, controlsTimer;
  const pictureIsPointing = () => document.getElementById('picture').classList?.contains?.('pointing');
  const controlsPinned = () => editing || controls.contains(document.activeElement) || document.activeElement === identityButton || pictureIsPointing();
  function displayControls(shown) {
    if (controlsShown === shown || !running()) return;
    controlsShown = shown; update();
  }
  function scheduleControls() {
    clearTimeout(controlsTimer);
    if (!running()) return;
    controlsTimer = setTimeout(() => {
      if (controlsPinned()) scheduleControls(); else displayControls(false);
    }, 3000);
  }
  function revealControls() { displayControls(true); scheduleControls(); }
  controls.addEventListener('focusin', revealControls);
  controls.addEventListener('focusout', scheduleControls);
  identityButton.addEventListener('focus', revealControls);
  identityButton.addEventListener('blur', scheduleControls);
  document.getElementById('stage').addEventListener('pointermove', event => {
    if (event.pointerType !== 'touch') revealControls();
  });
  scheduleControls();
  document.getElementById('pointer').addEventListener('click', () => { if (editing) closeEditor(false); }, {capture: true});
  const inPip = () => document.pictureInPictureElement === video || video.webkitPresentationMode === 'picture-in-picture';
  async function exitPip() {
    try {
      if (document.pictureInPictureElement === video) await document.exitPictureInPicture();
      else if (video.webkitPresentationMode === 'picture-in-picture') video.webkitSetPresentationMode('inline');
    } catch {}
  }
  function observeAudio(stream, generation) {
    const updateAudio = () => {
      if (generation !== mediaGeneration) return;
      const available = stream.getAudioTracks().some(track => track.readyState !== 'ended' && !track.muted);
      if (hasAudio !== available) { hasAudio = available; update(); }
    };
    const watched = new WeakSet();
    const watch = track => {
      if (watched.has(track)) return;
      watched.add(track);
      track.addEventListener('ended', updateAudio); track.addEventListener('mute', updateAudio);
      track.addEventListener('unmute', updateAudio);
    };
    stream.addEventListener('addtrack', () => { stream.getAudioTracks().forEach(watch); updateAudio(); });
    stream.addEventListener('removetrack', updateAudio);
    stream.getAudioTracks().forEach(watch);
    return () => { stream.getAudioTracks().forEach(watch); updateAudio(); };
  }
  function aspectRatio() {
    if (video.videoWidth > 0 && video.videoHeight > 0) player.style.setProperty('--feed-ratio', video.videoWidth / video.videoHeight);
  }
  video.addEventListener('loadedmetadata', aspectRatio); video.addEventListener('resize', aspectRatio);

  let refreshAudio, fallbackFrame, fallbackStats, watchingFrames = false;
  function detachVideo() {
    mediaGeneration++; playAttempt++;
    if (frameCallback !== undefined) video.cancelVideoFrameCallback?.(frameCallback);
    frameCallback = undefined; fallbackFrame = undefined; fallbackStats = undefined; watchingFrames = false;
    lastFrameAt = undefined; displayedRevision = undefined; mediaStream = undefined;
    hasAudio = false; playBlocked = false; refreshAudio = undefined;
    resetHealth();
    video.muted = true;
    if (video.srcObject) {
      exitPip();
      if (video.webkitDisplayingFullscreen) { try { video.webkitExitFullscreen(); } catch {} }
      video.srcObject = null;
    }
  }
  function closeReader() {
    readerGeneration++;
    reader?.close(); reader = undefined;
    detachVideo();
  }
  function syncSound() {
    video.muted = !soundEnabled || !mediaStream || mode !== 'live' || !running();
    const pressed = String(!video.muted);
    if (sound.getAttribute('aria-pressed') !== pressed) {
      sound.setAttribute('aria-pressed', pressed);
      action(sound, video.muted ? 'Unmute' : 'Mute');
      document.getElementById('sound-icon').setAttribute('href', video.muted ? '#i-volume-x' : '#i-volume');
    }
  }
  async function play() {
    const attempt = ++playAttempt;
    syncSound();
    try {
      await video.play();
      if (attempt === playAttempt && playBlocked) { playBlocked = false; update(); }
    } catch (error) {
      if (attempt !== playAttempt || error?.name !== 'NotAllowedError') return;
      if (!video.muted) {
        soundEnabled = false; syncSound();
        await play();
      } else { playBlocked = true; update(); }
    }
  }
  function startReader() {
    if (reader) closeReader();
    readerStartedAt = Date.now();
    const generation = readerGeneration, publisher = revision;
    const watched = new WeakSet();
    const watchVideo = track => {
      if (watched.has(track)) return;
      watched.add(track);
      const invalidate = () => {
        if (generation !== readerGeneration || !mediaStream?.getVideoTracks().includes(track) || liveTrack()) return;
        lastFrameAt = undefined; displayedRevision = undefined;
        resetHealth(); update();
      };
      track.addEventListener('mute', invalidate); track.addEventListener('ended', invalidate);
    };
    const prepareVideo = () => {
      const tracks = mediaStream.getVideoTracks();
      tracks.forEach(watchVideo);
      if (!watchingFrames && tracks.length) { watchingFrames = true; watchFrames(publisher); }
    };
    reader = new MediaMTXWebRTCReader({url: config.whepURL, user: config.user, pass: config.pass,
      onTrack: event => {
        if (generation !== readerGeneration || !running()) return;
        const stream = event.streams?.[0];
        if (!mediaStream) {
          mediaStream = stream || new MediaStream();
          if (event.track && !stream) mediaStream.addTrack(event.track);
          video.srcObject = mediaStream;
          refreshAudio = observeAudio(mediaStream, mediaGeneration);
          const attached = mediaStream;
          attached.addEventListener('addtrack', () => { if (mediaStream === attached) prepareVideo(); });
          aspectRatio(); play();
        } else if (event.track && stream !== mediaStream && !mediaStream.getTracks().includes(event.track)) {
          mediaStream.addTrack(event.track);
        }
        prepareVideo();
        refreshAudio();
      },
      onError: () => {
        if (generation === readerGeneration) { detachVideo(); update(); }
      }});
  }
  function watchFrames(publisher) {
    const generation = mediaGeneration;
    let lastFrame;
    const decoded = value => {
      if (generation !== mediaGeneration || video.srcObject !== mediaStream || !liveTrack() ||
          video.paused || video.readyState < 2 || video.videoWidth <= 0 || video.videoHeight <= 0 ||
          !Number.isFinite(value) || value === lastFrame) return;
      lastFrame = value;
      lastFrameAt = Date.now(); displayedRevision = publisher; everPlayed = true;
      if (!renderedPlaying) update();
    };
    if (video.requestVideoFrameCallback) {
      const next = (_, metadata) => {
        if (generation !== mediaGeneration) return;
        decoded(metadata.presentedFrames ?? metadata.mediaTime);
        frameCallback = video.requestVideoFrameCallback(next);
      };
      frameCallback = video.requestVideoFrameCallback(next);
    } else {
      const progress = () => {
        const quality = video.getVideoPlaybackQuality?.();
        return quality ? quality.totalVideoFrames - quality.droppedVideoFrames : video.webkitDecodedFrameCount;
      };
      lastFrame = progress();
      if (lastFrame !== undefined) fallbackFrame = () => decoded(progress());
      else {
        let pending = false;
        fallbackStats = async () => {
          if (pending || !liveTrack() || typeof reader?.getStats !== 'function') return;
          pending = true;
          try {
            const report = await reader.getStats();
            const videoStats = [...report.values()].find(stat =>
              stat.type === 'inbound-rtp' && (stat.kind ?? stat.mediaType) === 'video');
            const count = videoStats?.framesDecoded;
            if (!Number.isFinite(count)) return;
            if (lastFrame === undefined) lastFrame = count;
            else if (count > lastFrame) decoded(count);
          } catch {} finally { pending = false; }
        };
      }
    }
  }
  video.addEventListener('timeupdate', () => fallbackFrame?.());

  // Track the request separately from a held lock or a fallback clip that actually started.
  function engageAwake() {
    if (!canEdit() || mode !== 'live') return;
    wantsAwake = true; acquireAwake(true);
  }
  async function acquireAwake(gesture = false) {
    if (!wantsAwake || !canEdit() || !stateKnown || document.hidden || wakeLock || awakeAttempt ||
        (fallbackAwake && !awakeVideo.paused) || (!gesture && Date.now() < awakeRetryAt)) return;
    const attempt = awakeAttempt = {};
    awakeRetryAt = Date.now() + 3000;
    try {
      if (navigator.wakeLock?.request && !wakeLockFailed) {
        try {
          const lock = await navigator.wakeLock.request('screen');
          if (awakeAttempt !== attempt) { await lock.release(); return; }
          if (!lock.released) {
            wakeLock = lock;
            lock.addEventListener('release', () => { if (wakeLock === lock) wakeLock = undefined; });
            return;
          }
        } catch { if (awakeAttempt === attempt) wakeLockFailed = true; }
      }
      if (awakeAttempt !== attempt || !globalThis.SetbeamKeepAwakeVideo) return;
      if (!awakeVideo.src) awakeVideo.src = globalThis.SetbeamKeepAwakeVideo;
      awakeVideo.muted = true;
      await awakeVideo.play();
      if (awakeAttempt === attempt) fallbackAwake = !awakeVideo.paused;
      else if (!awakeAttempt && (!running() || document.hidden)) awakeVideo.pause();
    } catch {
      if (awakeAttempt === attempt) fallbackAwake = false;
    } finally { if (awakeAttempt === attempt) awakeAttempt = undefined; }
  }
  function releaseAwake() {
    awakeAttempt = undefined; fallbackAwake = false; wakeLockFailed = false; awakeRetryAt = 0;
    const lock = wakeLock; wakeLock = undefined; lock?.release().catch(() => {});
    if (awakeVideo.src) awakeVideo.pause();
  }

  function toggleSound() {
    if (sound.hidden || sound.disabled) return;
    soundEnabled = !soundEnabled;
    engageAwake(); play();
  }
  const standardFullscreenSupported = () => document.fullscreenEnabled !== false && typeof player.requestFullscreen === 'function';
  const isFullscreen = () => document.fullscreenElement === player || video.webkitDisplayingFullscreen;
  function fullscreenState() {
    const expanded = !!isFullscreen();
    action(fullscreen, expanded ? 'Exit full screen' : 'Enter full screen');
    fullscreen.setAttribute('aria-pressed', String(expanded));
    document.getElementById('fullscreen-icon').setAttribute('href', expanded ? '#i-min' : '#i-max');
  }
  async function toggleFullscreen() {
    if (fullscreen.hidden || fullscreen.disabled || inPip()) return;
    engageAwake();
    try {
      if (document.fullscreenElement === player) await document.exitFullscreen();
      else if (video.webkitDisplayingFullscreen) video.webkitExitFullscreen();
      else if (!document.fullscreenElement && standardFullscreenSupported()) await player.requestFullscreen();
      else if (!document.fullscreenElement && playing()) video.webkitEnterFullscreen?.();
    } catch {
      if (!document.fullscreenElement && !isFullscreen() && playing()) {
        try { video.webkitEnterFullscreen?.(); } catch {}
      }
    }
    fullscreenChanged();
  }
  function exitPlayerFullscreen() {
    if (document.fullscreenElement === player) document.exitFullscreen()?.catch?.(() => {});
  }
  function fullscreenChanged() {
    if (!running()) exitPlayerFullscreen();
    if (video.webkitDisplayingFullscreen && (!running() || !mediaStream)) {
      try { video.webkitExitFullscreen(); } catch {}
    }
    fullscreenState();
  }
  function pipState() {
    pip.setAttribute('aria-pressed', String(inPip()));
    action(pip, inPip() ? 'Exit picture in picture' : 'Picture in picture');
  }
  pip.addEventListener('click', async () => {
    if (pip.hidden || pip.disabled || isFullscreen()) return;
    const generation = mediaGeneration;
    engageAwake();
    try {
      if (inPip()) await exitPip();
      else if (document.pictureInPictureEnabled && video.requestPictureInPicture) await video.requestPictureInPicture();
      else video.webkitSetPresentationMode('picture-in-picture');
    } catch {}
    if (generation !== mediaGeneration || !running()) await exitPip();
    pipState();
  });
  function pipChanged() {
    if (inPip() && (!running() || mode !== 'live' || !mediaStream)) exitPip();
    pipState();
  }
  video.addEventListener('enterpictureinpicture', pipChanged); video.addEventListener('leavepictureinpicture', pipChanged);
  video.addEventListener('webkitpresentationmodechanged', pipChanged);
  document.addEventListener('fullscreenchange', fullscreenChanged);
  video.addEventListener('webkitbeginfullscreen', fullscreenChanged); video.addEventListener('webkitendfullscreen', fullscreenChanged);
  sound.addEventListener('click', toggleSound);
  retry.addEventListener('click', () => { if (playBlocked && mediaStream && running()) { engageAwake(); play(); } });
  document.getElementById('picture').addEventListener('click', event => {
    engageAwake();
    if (!event?.target?.closest?.('button') && !pictureIsPointing()) revealControls();
  });
  document.getElementById('picture').addEventListener('dblclick', event => {
    if (!editing && !pictureIsPointing() && !event.target.closest('button')) toggleFullscreen();
  });
  fullscreen.addEventListener('click', toggleFullscreen);
  document.addEventListener('click', event => {
    if (!editing || !event.target?.closest) return;
    if (!event.target.closest('#join, #identity-button')) closeEditor(false);
  });
  const shortcutButtons = {m: sound, f: fullscreen, p: document.getElementById('pointer'), c: document.getElementById('chat-toggle')};
  const chatLayerOpen = () => document.getElementById('chat-image-dialog').open ||
    document.getElementById('chat-copy-dialog').open ||
    document.getElementById('chat-menu').hidden === false ||
    document.getElementById('chat-information').hidden === false;
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.isComposing || event.repeat) return;
    if (event.key === 'Escape' && editing && !chatLayerOpen()) { event.preventDefault(); closeEditor(); return; }
    if (editing || !canEdit() || chatLayerOpen() || chat?.blocksViewerShortcuts?.() ||
        event.ctrlKey || event.metaKey || event.altKey ||
        event.target.closest?.('input,textarea,select,[contenteditable],dialog,[role="menu"]')) return;
    const button = shortcutButtons[event.key.toLowerCase()];
    if (!button || button.hidden || button.disabled) return;
    event.preventDefault(); revealControls();
    if (button === sound) toggleSound();
    else if (button === fullscreen) toggleFullscreen();
    else button.click?.();
  });
  function cancelRequest(kind) {
    const attempt = requests.get(kind);
    requests.delete(kind);
    attempt?.abort();
  }
  function send(kind, options, result, failed = () => {}, settled = () => {}) {
    if (!running() || requests.has(kind)) return;
    const controller = new AbortController();
    const attempt = {abort: () => controller.abort()};
    requests.set(kind, attempt);
    const {signal} = controller;
    const timer = setTimeout(attempt.abort, 5000);
    const canceled = new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(new Error('Request canceled')), {once: true});
    });
    const response = (async () => {
      const response = await fetch(kind, {...options, signal, cache: 'no-store'});
      let body;
      if (response.ok || kind === 'config.json' && response.status === 403) {
        try { body = await response.json(); }
        catch (error) { if (response.ok) throw error; }
      }
      return {status: response.status, ok: response.ok, body};
    })();
    const complete = (callback, value) => {
      clearTimeout(timer);
      if (requests.get(kind) !== attempt) return;
      requests.delete(kind);
      if (running()) { callback(value); settled(); }
    };
    Promise.race([response, canceled]).then(value => complete(result, value), error => complete(failed, error));
  }
  function heartbeat() {
    if (!running() || !stateKnown || !pass || access !== 'admitted' || !admissionConfirmed) return;
    if (requests.has('heartbeat')) { heartbeatAgain = true; return; }
    heartbeatAgain = false; heartbeatAt = Date.now(); reportedPlaying = playing();
    sampleHealth();
    const body = {pass, mobile: mobile(), playing: reportedPlaying, health: viewerHealth(),
      revision: displayedRevision ?? -1, color: viewerColor};
    const ageMs = Date.now() - measuredAt;
    if (measurements && reportedPlaying && !document.hidden && !playBlocked && ageMs >= 0 && ageMs < statsFreshFor) {
      body.measurements = {...measurements, ageMs};
    }
    if (!approval || viewerName) body.name = viewerName;
    send('heartbeat', post(body), response => {
      if (response.status === 404) expire();
      else if (response.ok) {
        if (!admission(response.body?.admission)) chat?.activity(response.body?.chatLastID);
      }
    }, undefined, () => { if (heartbeatAgain) heartbeat(); });
  }
  function admission(value) {
    if (value === 'removed' || value === 'declined') { access = value; terminate(); }
    else if (value === 'unknown') {
      if (approval) joinNote = 'again';
      forgetPass(); resetAdmission(approval ? 'name' : 'joining'); update();
    } else return false;
    return true;
  }
  function forgetPass() {
    pass = undefined; joinNumber = undefined;
    try { sessionStorage.removeItem(passKey); } catch {}
  }
  function resetMedia() {
    cancelRequest('config.json'); config = undefined;
    closeReader();
  }
  function resetAdmission(next) {
    access = next; admissionConfirmed = false; mediaReady = false;
    cancelRequest('join'); cancelRequest('heartbeat');
    reportedPlaying = undefined; heartbeatAgain = false;
    resetMedia();
  }
  const mobile = () => /iPhone|iPad|Android/.test(navigator.userAgent);
  const post = body => ({method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  function join() {
    if (!running() || requests.has('join') || (access === 'admitted' && admissionConfirmed && mediaReady) ||
        (access === 'full' && !asking)) return;
    if (!pass && !asking && (access === 'name' || !viewerName)) {
      if (access === 'joining') { access = 'name'; update(); }
      return;
    }
    const asked = asking, hadPass = !!pass;
    const failed = () => {
      if (asked) { asking = false; joinNote = 'error'; }
      else joinTrouble = true;
      update();
    };
    send('join', post({pass, name: (asked || !approval) && viewerName || undefined, ask: asked || undefined,
      requestID: asked ? askTicket.id : undefined, color: viewerColor, mobile: mobile()}), response => {
      if (asked) asking = false;
      joinTrouble = false;
      if (response.status === 404) { expire(); return; }
      if (response.status === 400) {
        forgetPass(); resetAdmission('name'); approval = true;
        if (asked) { joinNote = 'empty'; askTicket = undefined; }
        else if (hadPass) joinNote = 'again';
      } else if (response.status === 503) { resetAdmission('full'); }
      else if (!response.ok || typeof response.body?.pass !== 'string' ||
          !['pending', 'admitted', 'declined', 'removed'].includes(response.body.admission)) { failed(); return; }
      else {
        const result = response.body;
        if (pass !== result.pass) resetAdmission(result.admission);
        pass = result.pass; access = result.admission; admissionConfirmed = true;
        mediaReady = result.ready !== false;
        joinNumber = Number.isInteger(result.number) ? result.number : undefined;
        asking = false; joinNote = ''; askTicket = undefined;
        try { sessionStorage.setItem(passKey, pass); } catch {}
        if (approval && typeof result.name === 'string') viewerName = result.name;
        if (refused()) { terminate(); return; }
      }
      reconcile();
      // Ask pressed while a resume was in flight is handled as soon as that resume settles.
    }, failed, () => { if (!asked && asking) join(); });
  }
  function reconcileMedia() {
    if (!running() || !stateKnown || mode !== 'live' || access !== 'admitted' || !admissionConfirmed || !mediaReady) return;
    if (config) {
      if (!reader || stalled()) startReader();
      return;
    }
    send('config.json', {headers: {'X-Setbeam-Pass': pass}}, response => {
      if (response.status === 404) { expire(); return; }
      if (response.status === 403) {
        if (!admission(response.body?.admission)) {
          resetAdmission('joining'); update();
        }
        return;
      }
      if (response.status === 503) { mediaReady = false; return; }
      if (!response.ok || typeof response.body?.whepURL !== 'string') return;
      const details = response.body;
      if ((Number.isSafeInteger(details.revision) && details.revision !== revision) ||
          (stateSequence !== undefined && Number.isSafeInteger(details.sequence) && details.sequence > stateSequence)) {
        pollState(); return;
      }
      config = response.body; startReader();
    });
  }
  function resetHealth() {
    healthGeneration++;
    statsPrevious = undefined; statsPending = false; healthQuality = 'checking'; healthAt = 0; badSamples = 0; goodSamples = 0;
    measurements = undefined; measuredAt = undefined;
  }
  function viewerHealth() {
    if (document.hidden) return 'background';
    if (playBlocked) return 'ready';
    if (mediaStream && video.paused) return 'paused';
    if (!playing()) return everPlayed ? 'reconnecting' : 'connecting';
    if (typeof reader?.getStats !== 'function') return 'playing';
    return Date.now() - healthAt < statsFreshFor ? healthQuality : 'checking';
  }
  function inboundMeasurements(inbound, settledRate) {
    if (!inbound) return;
    const values = {};
    const {frameWidth: width, frameHeight: height, framesPerSecond: fps, framesDropped: droppedFrames} = inbound;
    const dimension = value => Number.isInteger(value) && value > 0 && value <= 16384;
    if (dimension(width) && dimension(height)) { values.width = width; values.height = height; }
    if (settledRate && Number.isFinite(fps) && fps >= 0 && fps <= 60) values.fps = fps;
    if (Number.isSafeInteger(droppedFrames) && droppedFrames >= 0) values.droppedFrames = droppedFrames;
    if (Object.keys(values).length) return values;
  }
  function sampleHealth() {
    if (!playing() || document.hidden || statsPending || typeof reader?.getStats !== 'function') return;
    const generation = healthGeneration;
    const sampledRevision = displayedRevision, startedAt = Date.now();
    statsPending = true;
    reader.getStats().then(report => {
      if (generation !== healthGeneration || sampledRevision !== displayedRevision || !playing() || playBlocked || document.hidden) return;
      const videoStats = [...report.values()].filter(s => s.type === 'inbound-rtp' && s.kind === 'video');
      const inbound = videoStats.find(s => Number.isFinite(s.packetsReceived) && Number.isFinite(s.packetsLost) && Number.isFinite(s.timestamp));
      // A new peer can decode its buffered startup frames in a burst. Wait for a full
      // sampling interval and omit rates beyond the normal bounds of Setbeam's output.
      measurements = inboundMeasurements(inbound || videoStats[0], startedAt - measuredAt >= 1500);
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
        healthQuality = 'playing'; healthAt = Date.now(); statsPrevious = undefined;
        measurements = undefined; measuredAt = undefined;
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
  function requestID() {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
    // randomUUID needs a secure origin. getRandomValues also works on a plain HTTP LAN.
    if (!globalThis.crypto?.getRandomValues) return undefined;
    const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
    return hex.replace(/^(........)(....)(....)(....)/, '$1-$2-$3-$4-');
  }
  function ask() {
    if (!running()) return;
    if (askTicket?.name !== viewerName || askTicket?.color !== viewerColor) {
      askTicket = {id: requestID(), name: viewerName, color: viewerColor};
    }
    asking = true; joinNote = ''; update(); join();
  }
  document.getElementById('join-form').addEventListener('submit', event => {
    event.preventDefault();
    if (asking || !running()) return;
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
  document.getElementById('join-cancel').addEventListener('click', () => closeEditor());
  document.getElementById('identity-button').addEventListener('click', openEditor);
  document.getElementById('join-retry').addEventListener('click', () => {
    if (!asking && access === 'full') ask();
  });
  // Title, sample label, and network advice are public session details shown before and after joining.
  function describe(state) {
    text(document.getElementById('title'), state.title); document.title = state.title + ' · Setbeam';
    document.getElementById('sample').hidden = !state.sample;
    networkHint = state.wifiSSID ? 'Stay on ' + state.wifiSSID + '.' : 'Stay on the same network as the operator.';
  }
  function applyState(state, pushesBefore) {
    if (!['live', 'holding', 'reconnecting', 'stopped'].includes(state?.state)) return;
    const sequence = Number.isSafeInteger(state.sequence) && state.sequence >= 0 ? state.sequence : undefined;
    if (sequence !== undefined) {
      if (stateSequence !== undefined && (sequence < stateSequence || sequence === stateSequence && stateKnown)) return;
      stateSequence = sequence;
    } else if (stateSequence !== undefined || pushesBefore !== undefined && pushes !== pushesBefore) return;

    const changedMedia = mode !== state.state || revision !== state.revision || approval !== (state.approval === true);
    mode = state.state; revision = state.revision;
    approval = state.approval === true; pointersOn = state.pointers === true; stateKnown = true;
    describe(state);
    if (mode === 'stopped') { terminate(); return; }
    if (changedMedia) resetMedia();
    reconcile();
  }
  function openEvents() {
    eventsAt = Date.now(); eventsHeard = false;
    const source = events = new EventSource('events?id=' + encodeURIComponent(id));
    source.onmessage = message => {
      if (source !== events || !running()) return;
      let state; try { state = JSON.parse(message.data); } catch { return; }
      if (!['live', 'holding', 'reconnecting', 'stopped'].includes(state?.state)) return;
      eventsAt = Date.now(); eventsHeard = true; pushes++;
      applyState(state);
    };
    source.onerror = () => { if (source === events) { dropEvents(); pollState(); } };
  }
  function dropEvents() {
    const previous = events;
    events = undefined; eventsRetryAt = Date.now() + 15000;
    previous?.close();
  }
  function pollState() {
    const pushesBefore = pushes;
    send('state.json', {}, response => {
      // A legacy response that started before a push has no authority over that push.
      if (response.status === 404) { if (pushesBefore === pushes) expire(); }
      else if (response.ok) applyState(response.body, pushesBefore);
    });
  }
  function reconcile() {
    if (!running()) return;
    if (stateKnown && access === 'admitted' && admissionConfirmed && !events &&
        typeof EventSource === 'function' && Date.now() >= eventsRetryAt) openEvents();
    reconcileMedia();
    update();
  }
  function cancelWork() {
    for (const kind of requests.keys()) cancelRequest(kind);
    dropEvents();
    resetMedia();
    heartbeatAgain = false; reportedPlaying = undefined;
    clearInterval(ticker); ticker = undefined; clearTimeout(controlsTimer);
    exitPlayerFullscreen(); releaseAwake();
  }
  function terminate() {
    asking = false; askTicket = undefined;
    cancelWork(); update();
  }
  function expire() {
    if (access === 'admitted') mode = 'stopped';
    else unavailable = true;
    terminate();
  }
  function resume() {
    if (!suspended || ended()) return;
    suspended = false; eventsRetryAt = 0;
    startTicks(); revealControls(); pollState(); join(); update();
  }
  window.addEventListener('online', () => { pollState(); join(); });
  window.addEventListener('pagehide', () => {
    if (!running()) return;
    suspended = true; stateKnown = false; admissionConfirmed = false;
    if (asking) { asking = false; joinNote = 'error'; }
    cancelWork(); update();
  });
  window.addEventListener('pageshow', resume);
  document.addEventListener('visibilitychange', () => {
    resetHealth(); heartbeat();
    if (document.hidden) releaseAwake();
    else { acquireAwake(true); pollState(); }
  });
  video.addEventListener('pause', () => {
    if (!mediaStream || !running()) return;
    const previous = reportedPlaying;
    resetHealth(); update();
    if (playing() === previous) heartbeat();
  });
  let ticker;
  function startTicks() { ticker = setInterval(tick, 1500); }
  function tick() {
    if (!running()) return;
    if (events && !streaming()) dropEvents();
    if (!events) pollState();
    join();
    fallbackStats?.();
    reconcile();
    acquireAwake();
    if (Date.now() - heartbeatAt >= 2500) heartbeat();
  }
  // Collaboration uses the displayed publisher. A state announcement alone cannot make video ready.
  const chat = globalThis.SetbeamChat?.attach({
    pass: () => pass, live: playing, displayedRevision: () => displayedRevision, identityOpen: () => editing
  });
  startTicks(); pollState(); join(); update();
})();
