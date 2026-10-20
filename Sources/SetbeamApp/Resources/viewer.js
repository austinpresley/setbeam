(() => {
  const video = document.getElementById('video');
  const label = document.getElementById('state');
  const slate = document.getElementById('slate');
  const sound = document.getElementById('sound');
  let reader, mode = 'reconnecting', config, lastTime = -1, lastFrameAt = 0, receivedTrack = false;
  const id = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
  function show(title, copy) {
    slate.hidden = false; document.getElementById('slate-title').textContent = title; document.getElementById('slate-copy').textContent = copy;
  }
  function update() {
    label.className = 'state ' + mode;
    sound.disabled = mode !== 'live';
    if (mode === 'holding') { label.textContent = 'On hold'; show('Feed paused', 'The operator will resume shortly.'); }
    else if (mode === 'stopped') { label.textContent = 'Sharing ended'; show('Sharing has ended', 'You can keep this page open.'); }
    else if (mode === 'live' && receivedTrack && Date.now() - lastFrameAt < 6000) { label.textContent = 'Live feed'; slate.hidden = true; }
    else { label.textContent = 'Reconnecting'; show('Feed reconnecting', 'Keep this page open. The feed will return here.'); }
    // Holding also silences an already-decoded audio buffer immediately. The server replaces the actual media too.
    video.muted = mode !== 'live' || sound.getAttribute('aria-pressed') !== 'true';
  }
  function startReader() {
    reader?.close(); receivedTrack = false; lastFrameAt = 0; lastTime = -1; video.srcObject = null;
    reader = new MediaMTXWebRTCReader({url:config.whepURL, user:config.user, pass:config.pass,
      onTrack:event => { video.srcObject = event.streams[0]; receivedTrack = true; video.play().catch(() => {}); },
      onError:() => { receivedTrack = false; update(); }});
  }
  sound.addEventListener('click', () => { const enabled = sound.getAttribute('aria-pressed') !== 'true'; sound.setAttribute('aria-pressed',String(enabled)); sound.textContent = enabled?'Mute sound':'Enable sound'; update(); });
  document.getElementById('fullscreen').addEventListener('click', () => {
    if (video.requestFullscreen) video.requestFullscreen().catch(() => {});
    else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
  });
  video.addEventListener('timeupdate', () => { if (video.currentTime !== lastTime) { lastTime = video.currentTime; lastFrameAt = Date.now(); update(); } });
  video.addEventListener('playing', () => { lastFrameAt = Date.now(); update(); });
  async function poll() {
    try {
      const response = await fetch('state.json', {cache:'no-store'});
      if (response.status === 404) { mode='stopped'; update(); reader?.close(); return; }
      if (!response.ok) throw new Error();
      const state = await response.json(); const previous = mode; mode=state.state;
      document.getElementById('title').textContent=state.title; document.title=state.title+' · Setbeam';
      document.getElementById('sample').hidden=!state.sample;
      // Replacing the audience publisher resets its media timeline. Resume needs a fresh peer.
      if (mode === 'live' && previous !== 'live' && config) startReader();
      else if (mode !== 'live') { reader?.close(); reader=undefined; video.srcObject=null; receivedTrack=false; }
      update();
      fetch('heartbeat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,mobile:/iPhone|iPad|Android/.test(navigator.userAgent),playing:receivedTrack&&Date.now()-lastFrameAt<6000&&mode==='live'})}).catch(() => {});
    } catch { if(mode!=='holding'&&mode!=='stopped')mode='reconnecting';update(); }
  }
  async function init() {
    try { const response=await fetch('config.json',{cache:'no-store'});if(!response.ok)throw new Error();config=await response.json();await poll();setInterval(poll,1500); }
    catch { show('This session is unavailable','Ask the operator for a new viewing link.');label.textContent='Not connected'; }
  }
  window.addEventListener('pagehide',() => reader?.close());init();
})();
