# Viewer transport protection options

Investigated 2026-11-14 after Austin asked to protect the viewer transport and
chose HTTPS over gateway resource limits. This is a design note. No source
changed, nothing was built, and no device was tested. It resolves the S-004
item "Resolve and verify credential protection for local-network browser
transport before implementation" only as far as the facts below go.

## What crosses the network today

Everything a viewer exchanges with the Mac, except media itself, is plain HTTP
on the viewing network.

| Traffic | Where | What a capture reveals |
| --- | --- | --- |
| Viewer page and scripts | Gateway, `http://<address>:<port>/s/<code>/` | The 64-character link code in every request path. With approval off it is also the shared `guest` media password. |
| Short address | Port 80, `302` to `/s/<short code>/` | The ask-only short code. It is not a media credential. |
| `join`, heartbeats, `config.json`, state, events | Gateway | Each tab's secret pass in `x-setbeam-pass`. `config.json` returns the WHEP URL, user and password. |
| Chat and frames | Gateway | Message text, attached JPEGs and the pass. Both native and browser UI already say chat is not encrypted. |
| Shared pointers | `ws://` on the gateway | The pass in the first message, then pointer positions. |
| WHEP signaling | MediaMTX, `http://<address>:<webPort>/live/whep` (second origin) | The read user and password as HTTP Basic, and the SDP offer/answer including DTLS fingerprints. |
| Audio and video | WebRTC, ICE port | Nothing useful passively. WebRTC always uses DTLS-SRTP. |

Sources: `ViewerGateway.swift` (`respond`, `config.json`), `Session.swift`
(`PlaybackDescriptor.whepURL`), `MediaRuntime.swift` (`webrtcAddress`,
`audience` descriptor), `reader.js` (`Authorization: Basic`), `pointers.js`
(`ws://`), `docs/architecture.md` short-address and chat sections.

Consequence: anyone who can read the viewing network's traffic can take the
link code or a pass and play the feed, join chat, or replay a session's media
credential until Stop rotates the link or the operator removes that session.
On WPA2-Personal, any client that knows the Wi-Fi password and captures another
client's handshake can decrypt that client's traffic. Open networks need no
password at all. ARP spoofing gives an active attacker the same position on
most networks. Approval limits the damage, since a sniffed pass is one
removable session, but it doesn't stop the capture.

Plain HTTP also costs features. Browsers expose Screen Wake Lock, the async
Clipboard API and `crypto.subtle` only in secure contexts, which is why the
viewer falls back to a looping clip for keep-awake and to a selectable field for
Copy.

## The constraint

No public certificate authority will issue a certificate for a private IP
address or a `.local` name. Every HTTPS option therefore picks one of three
trust models: browsers that don't trust the certificate, devices that are
told to trust a Setbeam authority, or a public domain name that resolves to the
Mac's private address.

## Options

### A. Per-Mac self-signed certificate

Setbeam generates a key and certificate for the current viewing address and
`.local` name. The gateway serves TLS, and WHEP moves behind the gateway so
there is one origin and one certificate (MediaMTX also supports
`webrtcEncryption` with its own key and certificate, but a second origin means
a second warning).

- Protects against passive capture, including the WPA2 case.
- Doesn't protect against an active attacker. Viewers must click through a
  full-page warning, so they will click through an attacker's certificate too.
- Every viewer sees a certificate warning on first visit, and again whenever the
  certificate or address changes. Typing `setbeam.local` would lead to a
  warning page, which undercuts the short address.
- Secure WebSockets may fail on iPhone and iPad. Cockpit's documentation says
  Safari's default WebSocket stack on iOS, iPadOS and Apple-silicon Macs
  refuses `wss://` to self-signed certificates "even when they are manually
  marked as trusted". The page is undated and names a workaround flag that may
  since have become the default, so this needs a device test. If it holds,
  shared pointers must move off WebSockets (to the existing event stream plus
  POST).
- Whether a page reached by bypassing a certificate error counts as a secure
  context (and so gets Wake Lock and Clipboard) is not settled by anything I
  found. Test per browser.

### B. Setbeam root authority installed on viewer devices

Setbeam generates one authority per Mac, keeps its key in Keychain, and issues
short-lived server certificates for the current address and name. Devices that
install and trust the authority get ordinary HTTPS with no warning and real
protection against active attackers.

- iPhone and iPad need a configuration profile, an install in Settings, then a
  separate switch under Settings > General > About > Certificate Trust Settings
  ([Apple](https://support.apple.com/102390)). Forum reports describe that
  switch sometimes not appearing.
- This contradicts the product rule that viewers join "without installing an
  app or creating an account". It suits a crew's own iPads that join every day,
  not a client who scans a QR code once.
- A trusted root can vouch for any website. If the authority's key leaked,
  every device that trusted it could be impersonated anywhere. Name
  constraints limiting it to the Mac's addresses and `.local` names reduce
  that, but Apple's handling of name constraints on user-installed roots needs
  verification first.
- Server certificates must meet [Apple's iOS 13 requirements](https://support.apple.com/103769)
  (825-day maximum, among others). Issuing per address change keeps them short.

### C. Public domain pointing at the private address

This is Plex's approach: each server gets a name like
`192-168-1-10.<id>.plex.direct` with a publicly trusted wildcard certificate,
and public DNS answers with the private address
([Valsorda](https://words.filippo.io/how-plex-is-doing-https-for-all-its-users/)).
No warning, no install, real protection.

- Needs a domain, a DNS service that encodes addresses, and an issuing service
  that gives each Mac its own certificate. Austin would operate all of it.
- The viewer's device must reach public DNS. Transmitter Wi-Fi and on-set
  networks are often offline, which is exactly when Setbeam is used.
- Many routers and Pi-hole block public names that resolve to private
  addresses (DNS rebinding protection), and Plex users hit this regularly
  ([Plex forum](https://forums.plex.tv/t/adding-plex-direct-to-dns-rebinding-protection-whitelist/754355)).
- Shipping one shared wildcard key inside the app would violate CA rules and
  get the certificate revoked, so per-Mac issuance is mandatory.

Every option still needs an HTTP fallback, so C is a large outward-facing
service that works only some of the time.

## Recommendation

Build A and B as one mechanism, as an opt-in Sharing Option, with plain HTTP
still the default until physical tests pass:

1. Generate a per-Mac authority and issue the gateway's certificate from it.
   Devices that installed the authority get warning-free HTTPS and protection
   from active attackers. Others can click through and get passive protection.
2. Proxy WHEP through the gateway, so one origin and one certificate cover
   page, state, chat, pointers and signaling. This also removes the separate
   MediaMTX origin and its `webrtcAllowOrigins: *` exposure from viewers.
3. Offer the authority profile from the native invitation panel as a separate,
   explicitly labelled step for repeat devices. Never put it in the viewing
   link or QR code.
4. Keep the short address on HTTP for its redirect only, or retire it when
   HTTPS is on. Decide after the device test, because a warning on `setbeam.local`
   defeats its purpose.
5. State the limits in the UI: without the installed authority, the connection
   is encrypted but the viewer can't confirm it is talking to this Mac.

Before building, run a one-hour device test with a throwaway self-signed server
on the viewing network: iPhone Safari, iPad Safari, Android Chrome and Mac
Safari, each with and without a trusted profile. Record per browser whether the
warning can be bypassed, whether `fetch`, `wss://` and WHEP playback work
afterwards, and whether `isSecureContext` and `navigator.wakeLock` are true.
The result decides whether pointers need to leave WebSockets and whether the
untrusted path (A) is worth shipping at all.

Not recommended: C, for the offline and rebinding reasons above. Encrypting
inside an HTTP page (keys in the URL fragment and in-page crypto) is also out,
since an active attacker can rewrite the page that does the encrypting and
`crypto.subtle` is unavailable outside secure contexts.

## Open questions for Austin

- Is a one-time profile install acceptable for crew devices, with click-through
  for everyone else?
- Should encrypted viewing be opt-in, or the default once qualified?
- Should the short address survive when encryption is on?

## Sources

- [Cockpit: Use Cockpit with Safari on an iPhone or iPad](https://cockpit-project.org/running/safari)
- [WebKit bug 41419: wss after accepting an https warning](https://bugs.webkit.org/show_bug.cgi?id=41419)
- [Apple: Trust manually installed certificate profiles](https://support.apple.com/102390)
- [Apple: Requirements for trusted certificates in iOS 13 and macOS 10.15](https://support.apple.com/103769)
- [Filippo Valsorda: How Plex is doing HTTPS for all its users](https://words.filippo.io/how-plex-is-doing-https-for-all-its-users/)
- [Plex forum: plex.direct and DNS rebinding protection](https://forums.plex.tv/t/adding-plex-direct-to-dns-rebinding-protection-whitelist/754355)
- [Web Platform Tests: Wake Lock not exposed in insecure contexts](https://chromium.googlesource.com/external/w3c/web-platform-tests/+/refs/tags/merge_pr_17019%5E/wake-lock/wakelock-insecure-context.html)
- MediaMTX configuration keys `webrtcEncryption`, `webrtcServerKey`,
  `webrtcServerCert` (MediaMTX configuration reference; not yet checked
  against the bundled version)
