// Evaluated in Chrome and WKWebView to measure the actual visible composer.
function viewerLayoutEvidence(extraControls = []) {
  const viewport = window.visualViewport;
  const left = viewport?.offsetLeft ?? 0, top = viewport?.offsetTop ?? 0;
  const width = viewport?.width ?? innerWidth, height = viewport?.height ?? innerHeight;

  function measure(id, hitTest) {
    const element = document.getElementById(id);
    const {x, y, width: w, height: h, right, bottom} = element.getBoundingClientRect();
    let visible = w > 0 && h > 0;
    for (let node = element; node && visible; node = node.parentElement) {
      const css = getComputedStyle(node);
      visible = !node.hidden && !node.inert && node.getAttribute('aria-hidden') !== 'true' &&
        css.display !== 'none' && css.visibility === 'visible' && Number(css.opacity) > 0;
    }
    const inside = x >= left - 1 && y >= top - 1 && right <= left + width + 1 && bottom <= top + height + 1;
    // Sample the center and near each edge so ancestor clipping and overlays
    // cannot pass with a positive but inaccessible bounding box.
    const reachable = !hitTest || [[.5,.5],[.1,.5],[.9,.5],[.5,.1],[.5,.9]].every(([a,b]) =>
      element.contains(document.elementFromPoint(x + w*a, y + h*b)));
    return {x, y, width:w, height:h, right, bottom, visible, inside, reachable};
  }
  const ids = ['chat-input','chat-send','chat-capture',...extraControls];
  const controls = Object.fromEntries(ids.map(id => [id, measure(id, true)]));
  const chat = measure('chat-panel', false), form = measure('chat-form', false);
  const input = document.getElementById('chat-input');
  return {width, height, scrollWidth:document.documentElement.scrollWidth, chat, form, controls,
    font:parseFloat(getComputedStyle(input).fontSize), draft:input.value,
    usable:[chat, form, ...Object.values(controls)].every(r => r.visible && r.inside && r.reachable) &&
      ids.filter(id => id !== 'chat-input').every(id => controls[id].height >= 44 && controls[id].width >= 44)};
}

if (typeof module !== 'undefined') module.exports = viewerLayoutEvidence;
