// Evaluate in an actual viewer tab before or during a ("live", "holding", "stopped") transition.
async function checkSetbeamPlayback(expected = 'live', timeout = 20000) {
  const deadline = performance.now() + timeout;
  const video = document.querySelector('video');
  if (!video) throw new Error('Viewer video is absent');
  if (!video.requestVideoFrameCallback) throw new Error('Viewer engine does not expose presented video frames');
  const observed = {frames: 0, mediaTime: null, presented: null};
  let callback;
  function onFrame(_, frame) {
    observed.frames++;
    observed.mediaTime = frame.mediaTime;
    observed.presented = frame.presentedFrames;
    callback = video.requestVideoFrameCallback(onFrame);
  }
  callback = video.requestVideoFrameCallback(onFrame);
  let baseline;
  try {
    while (performance.now() < deadline) {
      const label = document.getElementById('state')?.textContent;
      const now = performance.now();
      const detached = video.muted && !video.srcObject;
      const matches = expected === 'holding' ? detached && label === 'On hold' :
        expected === 'stopped' ? detached && label === 'Sharing ended' :
        label === 'Live feed' && !!video.srcObject && video.readyState >= 2 && !video.paused;
      if (!matches || baseline?.stream !== video.srcObject) baseline = undefined;
      if (matches) {
        baseline ??= {...observed, stream: video.srcObject, now};
        const frames = observed.frames - baseline.frames;
        if (expected === 'live' && frames >= 2 && observed.mediaTime > (baseline.mediaTime ?? -1)) {
          return {state:expected, frames, mediaTime:observed.mediaTime, presented:observed.presented};
        }
        if (expected !== 'live' && now - baseline.now >= 1000) {
          if (frames !== 0) throw new Error(`${frames} frames presented after ${expected} detached the video`);
          return {state:expected, muted:true, detached:true, frames, observedMs:now - baseline.now};
        }
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error(`Viewer did not reach ${expected}: ${document.getElementById('state')?.textContent}, callback frames=${observed.frames}`);
  } finally {
    video.cancelVideoFrameCallback(callback);
  }
}
