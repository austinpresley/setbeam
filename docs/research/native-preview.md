# Native WebRTC preview investigation

Source research: 2026-10-20. This note records investigation leads, not a diagnosed WebKit defect. The implementation session reports working Chrome playback of the same H.264 Baseline/Opus feed, successful WKWebView WHEP negotiation and track events, but native `readyState=0`, `currentTime=0`, and both remote tracks remaining muted. These observations were supplied by the active implementation session and were not independently reproduced in this research task.

The strongest next discriminator is received media, not another permission change. The WebRTC specification initializes a receiver's track as muted and requires it to unmute when receptive RTP data arrives. A negotiated track alone therefore does not prove media delivery. Both audio and video staying muted makes transport/receiver delivery the first branch to investigate. This is an inference, not proof. [WebRTC receiver behavior](https://www.w3.org/TR/webrtc/#mediastreamtrack-network-use)

Read `getStats()` twice a short interval apart. Record connection/ICE/DTLS states; selected candidate-pair ID and candidate addresses/protocol; inbound RTP packet and byte deltas; video `framesDecoded`, `keyFramesDecoded`, and `framesRendered` where exposed; and the negotiated codec's parameters. These statistics separate transport delivery, decoding, and display. [Statistics definitions](https://www.w3.org/TR/webrtc-stats/)

| Hypothesis | Prediction and controlled probe |
| --- | --- |
| ICE/DTLS or receive transport does not complete | No selected pair, no inbound RTP progress, or failed transport state. Compare the same player on a real HTTP URL in WKWebView; then test one candidate transport/address choice at a time. Do not change codecs concurrently. |
| Receiver gets RTP but cannot decode the chosen H.264 representation | Packet counters increase while decoded frames remain zero. Inspect the negotiated `profile-level-id`, packetization mode, SPS/PPS, IDR arrival, and source parameters. Try a tightly controlled Baseline/no-B-frame sample. Chrome success does not establish WebKit decoder compatibility. |
| Media decodes but element/display state prevents presentation | Decoded frame counters increase while rendered frames/currentTime do not. Keep one stable `srcObject`, log playback promise outcomes and media events, and compare a visible foreground window with the same real-URL page. |
| A native view update replaces the document/reader | Peer/session identifiers or navigation events change repeatedly. Count document loads and reader creation; verify unchanged playback descriptors do not reload the page. |

These are proposed falsifiable probes. The assigned research task made no application changes or native UI actions.

Loading real HTTP content is a useful differential test, but do not assume `loadHTMLString(baseURL:)` necessarily creates an opaque origin on the current OS. Current WebKit `loadData` supplies the base URL in its resource request. Log actual `location.href`, `location.origin`, and `isSecureContext`. [Current implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp)

Historical reports need qualification. WebKit bug 221031 concerned iOS 14.4 `getUserMedia` on a non-HTTP(S) custom scheme and is resolved. Bug 174500 described ICE host-candidate restrictions without capture permission and was fixed through mDNS work in 2018. Neither establishes that a current macOS receive-only player requires camera or microphone access. [Origin-related historical bug](https://bugs.webkit.org/show_bug.cgi?id=221031), [ICE-related historical bug](https://bugs.webkit.org/show_bug.cgi?id=174500)

Apple's current local-network privacy note explicitly exempts traffic originating from WKWebView, SFSafariViewController, and Safari. That weakens a missing Local Network privacy declaration as an explanation for this WK-only receive failure; native helpers remain a separate consideration. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

MediaMTX documents browser-dependent codec restrictions and specifically warns about H.264 B-frames. Its official reader example assigns `event.streams[0]` to the video element. A single `play()` AbortError can follow an interrupted load/play operation, so do not treat it as a codec or permission diagnosis without the transport and decoder counters. [Codec guidance](https://mediamtx.org/docs/features/webrtc-specific-features#codec-support-in-browsers), [official reader example](https://github.com/bluenviron/mediamtx/blob/main/docs/4-read/07-web-browsers.md), [HTML media playback algorithm](https://html.spec.whatwg.org/multipage/media.html#dom-media-play-dev)

No exact current macOS WKWebView bug matching all reported symptoms was established by the bounded primary-source review. Select the next change from actual counter deltas, then rerun the same native playback signal.

## Implementation outcome

The native test remained red with ICE/DTLS in `new`, zero transport bytes, and no selected candidate pair. Real localhost HTTP loading, adding the LAN ICE candidate, and omitting the unused data channel did not change that result. No current WebKit root cause was established. These experimental changes and temporary probes were removed.

The checkpoint uses a shared native JPEG frame renderer fed by the private local RTSP relay. Its real decoded-frame check passes in the main and floating views. The browser retains the exact pinned MediaMTX reader. Chromium playback passes; Safari and physical phone playback remain open checks. Native Core Audio output opening also stalled on this host. Its startup runs off the UI thread with a timeout, so this no longer blocks preview or audience controls. Audible local output still needs verification.
