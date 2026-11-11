# Transmitter expansion through existing inputs

Researched 2026-10-29. The initial model review covers Pyro H, Mars 400S Pro, CineView HE, CineView 2 SDI, and Austin's owned Mars 300/Mars 300 Pro. Additional direct-wireless and SDK candidates follow below. This is documentation research, with upstream project code identified separately. No hardware tests or Setbeam compatibility passes occurred.

Setbeam's only physically verified direct wireless model remains the **CineView Master 4K, firmware 3.30**, with product IDs 21 and 24 observed on the same unit. The recorded route is RTMS4, with a real 1920×1080 computer-display feed, encoded audio, native/browser/phone picture, and recovery after power cycling with manual Wi-Fi rejoin. Camera content, audible source sound/A/V timing, long sessions, and 4K qualification remain open. The product-24 continuous criterion failed 2 of 116 samples. Recognition of both IDs does not establish another model. [Physical ledger](../hardware-tests.md), [recognition code](../../Sources/SetbeamCore/AccsoonDiscovery.swift).

Complete RTSP/RTSPS URLs, authenticated incoming RTMP, and compatible macOS AVFoundation capture devices are existing input types. They provide places to test more hardware, without establishing compatibility with every transmitter using those terms. The older October 20 research's unresolved Master 4K direct-input question is superseded by the physical ledger. [Architecture](../architecture.md), [earlier route research](wireless-video-support-2026-10-20.md), [owned targets](owned-wireless-camera-targets-2026-10-20.md).

## Model findings and required proof

### Hollyland Pyro H

**Direct Wi-Fi candidate:** upstream Holly Share reads the transmitter Wi-Fi's gateway address, identifies port 5554 as Pyro H's port, and pulls `rtsp://<TX-Wi-Fi-gateway>:5554/live` over TCP. Its README reports testing Pyro H on Apple Silicon/macOS 15 in October 2026 and describes H.264/AAC and a single stream connection. These are firsthand claims from another project, with no reported transmitter firmware and no Setbeam test. Do not hard-code its example IP. [Pinned source, discovery and source configuration](https://github.com/titleunknown/holly-share/blob/3fcf772273d6f3db3423b2eb39f5db70ee601519/holly-share.sh#L28), [upstream test scope and behavior](https://github.com/titleunknown/holly-share/blob/3fcf772273d6f3db3423b2eb39f5db70ee601519/README.md#tested-with).

I found no Hollyland-published direct Wi-Fi RTSP endpoint in the checked Pyro H product/support material. Hollyland documents mobile monitoring outside Broadcast mode and UVC computer streaming. More concretely, its China-site **极影H** support page instructs connecting the **receiver** to the computer with a USB-A-to-Type-C data cable and selecting `hollyland` or `USB Video` in OBS. It specifies **MJPEG, up to 1080p30** for UVC. Treat this regional vendor specification as a test target for the exact market/firmware, independent of the product's 4K30 HDMI capability. [Global product page](https://www.hollyland.com/product/pyro-h), [vendor China support, UVC section](https://www.hollyland.com.cn/support/jiying-h/).

Proof needed: exact TX/RX firmware; actual TCP RTSP negotiation, decoded video/audio and connection takeover behavior; separately, receiver UVC enumeration, delivered format/cadence and audio on the Mac. A successful UVC test would qualify the receiver route only. Do not import Pyro S RTMP instructions into Pyro H.

### Hollyland Mars 400S Pro

The original **Mars 400S Pro**, without II or Ultra, has an explicitly documented **receiver LAN** route. With video format showing on TX and RX, connect the RX through a Type-C-to-LAN connector to the laptop, set the laptop's network interface to DHCP, then open **`rtsp://192.168.218.25:5554`**. The manual supplies no `/live` suffix. This is Ethernet RTSP through the receiver, rather than proof of transmitter Wi-Fi RTSP or USB UVC. [Official manual v1.0.0, printed EN-08, PDF page 11](https://download.hollyland.com/User_manual/MARS%20400S%20PRO/Mars%20400S%20Pro%20User%20Manual%EF%BC%88English%EF%BC%89v1.0.0.pdf#page=11).

Proof needed: exact RX firmware and working adapter model/chipset; actual DHCP/link/address behavior; the complete URL and RTSP transport accepted by the unit; SDP codecs, video/audio, latency and recovery through Setbeam's bundled runtime. The cited instructions do not specify adapter chipset, authentication, or RTP transport. Do not assume every USB Ethernet adapter works, or add `/live` from Pyro H's upstream recipe.

### Accsoon CineView HE and CineView 2 SDI

**HE:** Accsoon explicitly documents receiver USB-C UVC output to a computer, including third-party streaming software, without an extra capture device. This is the strongest documented route to test through Setbeam's capture input. The product's HDMI format table does not establish the USB output modes or Mac audio-device behavior. [Official HE product page, UVC section](https://accsoon.com/cineview-he/).

**2 SDI:** its manual explicitly limits the UVC-out port to the receiver and instructs connecting that receiver to a computer by Type-C cable. The same page separately describes SEE-app RTMP pushing with a URL and code, after selecting Speed Mode on the transmitter. UVC is the simpler first test; the app-mediated RTMP route still needs proof of a reachable local destination and compatibility with Setbeam's authenticated publish details. [Official manual v2.0, printed pp. 14–15, PDF page 8](https://accsoon.com/wp-content/uploads/2025/02/CineView-2-SDI-User-Manual-EN-CN-v2.0.pdf#page=8).

Proof needed **for each model separately**: receiver firmware, USB data cable, stable AVFoundation identity, exposed video modes and audio device, selected mode's actual decoded cadence, unplug/replug and TX/RX power-cycle recovery. Neither manual establishes Setbeam compatibility. Neither receiver-UVC fact applies to Master 4K.

### Owned Mars 300 Pro and original Mars 300

**300 Pro:** Hollyland documents joining the transmitter's `HLD_…` Wi-Fi and opening its Mars 300 Pro page in HollyView. That establishes vendor-app monitoring, with no generic Mac RTSP endpoint or handshake found in this review. Its model-specific FAQ explicitly says Type-C-to-RJ45 streaming is unsupported. The manual identifies receiver HDMI output, so **RX HDMI → compatible capture device → Mac** is the practical fallback. Standard and Enhance have separate firmware families; inspect Austin's unit before assigning either profile. [App instructions](https://www.hollyland.com/faq/how-to-connect-mars-300-pro-with-the-hollyview-app), [RJ45 FAQ](https://www.hollyland.com/support/faq/mars-300pro/others-3), [manual v1.1.0, printed p. 5, PDF page 7](https://download.hollyland.com/User_manual/MARS%20300PRO/Mars%20300%20Pro%20-%20User%20Manual%20%28English%29%20v1.1.0.pdf#page=7), [variant firmware listings](https://www.hollyland.com/download/mars-300-pro).

**Original 300:** keep receiver HDMI capture as the initial target. Hollyland's legacy comparison lists it separately from 300 Pro and describes an HDMI topology, but reverses TX/RX labels in the table. Confirm the actual port labels/output rather than copying that table into setup instructions. No direct network route was established here. [Vendor legacy comparison](https://hollyland-techhelp.zendesk.com/hc/en-us/articles/360062140573-Detailed-Comparison-Mars-Series).

Proof needed: inspect both owned models and the 300 Pro revision/firmware; establish receiver picture first; record capture hardware identity, format and audible embedded audio. Bound the 300 Pro direct-Wi-Fi investigation to establishing a real endpoint/protocol after a HollyView baseline. A working vendor app or open port alone is insufficient. Neither Pyro H's URL nor 400S Pro's receiver-LAN recipe is evidence for 300 Pro.

## Practical order

1. Prove the owned Mars 300 Pro and original 300 through receiver HDMI capture, using a compatible capture device if available. This has the shortest documented route to useful coverage of Austin's equipment. Investigate 300 Pro direct Wi-Fi separately with a bounded protocol discovery task.
2. Test a borrowed Pyro H with the upstream TCP RTSP URL. Keep its vendor-documented 1080p30 MJPEG receiver UVC route as an independent option.
3. Test HE and 2 SDI receiver UVC as hardware becomes available. Existing capture inputs avoid a new radio-protocol adapter.
4. Test Mars 400S Pro receiver LAN when the exact receiver and a working Type-C-LAN adapter are available. It has a vendor-published URL, but extra network/adapter requirements compared with UVC.

This ordering is an engineering recommendation based on ownership and documented connection paths. For every route, record exact model/revision/firmware, Mac/OS, input content, actual format, audio/A/V timing, measured end-to-end delay, source-loss/power-cycle recovery, and coexistence with receivers/vendor apps in the physical ledger. Cover both camera content and a detailed computer display. Verify that local/floating/browser views share one received input, Hold removes outgoing source picture and sound, and Stop Sharing preserves local monitoring. New media-code work is warranted only when a proven source exposes a gap in an existing adapter. [Project compatibility criteria](../hardware-tests.md), [media invariants](../../AGENTS.md).

Source limits: the Pyro H multilingual manual URL returned HTTP 404; the live China support page supplies the UVC details above. The 300 Pro RJ45 FAQ returned HTTP 403 on direct fetch, but its indexed first-party text was available and explicit. Unknown firmware behavior, stream negotiation, UVC modes/audio and Setbeam results remain physical-test questions.

## Further direct-wireless investigation

Accsoon documents RTMS 4.0 for both [CineView Master 4K Lite](https://accsoon.com/cineview-master-4k-lite/) and [CineView Master 4K II](https://accsoon.com/products/master-4k-2/). This makes them candidates for investigation using the existing Master 4K adapter. It does not establish compatibility with Setbeam. Inspect each unit's identity, connection handshake, advertised media, codec, audio parameters, and recovery behavior before adding recognition. The current runtime explicitly constructs an H.265/AAC input description; extending its product-ID allowlist alone would not prove another model works. Their documented wired mobile-video ports do not establish generic Mac UVC support.

Accsoon's [SDK request program](https://accsoon.com/sdk-launch-request/) names CineView Nano, HE, SE, Quad, and 2 SDI. The public page does not establish macOS targets or redistribution terms. Requesting and evaluating a supported Mac SDK is a possible route to those models' direct wireless feeds. A vendor-app monitoring feature is insufficient evidence that our app can receive its feed. No SDK request or vendor contact occurred in this research.

## Software work that can proceed before physical qualification

Keep acquisition separate from the existing monitoring/sharing pipeline. Add a model profile only after identifying its actual connection route. Profiles should record exact model/variant, supported firmware evidence, discovery method, input adapter, media parameters, and setup instructions. Reuse the existing RTSP, authenticated RTMP, and capture adapters where the hardware exposes them. Add a protocol or SDK adapter where it does not. Preserve one received source, private monitoring through Hold/Stop, read-only viewer access, and supervised bundled helpers. The current native app's generic network discovery only lists advertised RTSP services with an explicit path; it has no Pyro H-specific discovery profile.

These are proposed changes. No app code, transmitter compatibility record, or network configuration was changed by this research.

