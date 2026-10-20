// Evaluate this function in the actual viewer tab, with "live", "holding", or "stopped".
// It observes decoded playback; it does not simulate media or change application state.
async function checkSetbeamPlayback(expected = 'live', timeout = 20000) {
  const deadline = performance.now() + timeout;
  const video = document.querySelector('video');
  if (!video) throw new Error('Viewer video is absent');
  let previous = video.currentTime;
  while (performance.now() < deadline) {
    const label = document.getElementById('state')?.textContent;
    if (expected === 'holding' && label === 'On hold' && video.muted && !video.srcObject) return {state:expected, muted:true};
    if (expected === 'stopped' && label === 'Sharing ended' && video.muted) return {state:expected, muted:true};
    if (expected === 'live' && label === 'Live feed' && video.readyState >= 2 && !video.paused && video.currentTime > previous) {
      return {state:expected, ready:video.readyState, time:video.currentTime};
    }
    previous = video.currentTime;
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  throw new Error(`Viewer did not reach ${expected}: ${document.getElementById('state')?.textContent}, ready=${video.readyState}, paused=${video.paused}`);
}
