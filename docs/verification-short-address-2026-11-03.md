# Short address and join request card verification, 2026-11-03

Version 0.2.0, build 26. Starting commit `df085a5`, with the build 25 work uncommitted. Claude Opus 5.5 implemented the change on high. Independent GPT-6.1 Sol review on xhigh approved both Standards and Spec in round 2 after all first-round findings were resolved. The reviewed candidate was numbered 25; only the build number and completion records changed after approval. Final packaging and delivery evidence is below.

Austin authorized the opt-in, approval-only short address proposed in [viewer setup verification](verification-viewer-setup-2026-11-03.md) (lines 21-36), plus an approval alert that arrives like a notification, native or custom.

All QA ran on this Mac with an isolated copy of the candidate (`build/short-address/qa`). It had its own preferences suite `app.setbeam.qa.shortaddress` (removed afterwards), session log, and the labeled sample feed. Viewing used Ethernet `en0` (192.168.1.238) with the local name `setbeam-qa.local`. No phone, tablet, second computer, or physical transmitter was used. The installed app was not launched or replaced.

## What changed

1. **Short address.** A new option, Advanced > Viewer network > Let viewers ask from setbeam.local, appears under Offer a local address. It is saved and off by default. The caption reads: "Anyone on this network who opens setbeam.local can ask to join. You admit each request, so this works only with Ask before viewers join. Setbeam answers on port 80 for the viewing address only, while you share."
   - It is open only while sharing, with approval on, the local address offered, and a viewing network other devices can join. Port 80 answers only once the name is active.
   - Typing the name gives `302 Found` to `http://<typed host>:<gateway port>/s/<short-address code>/`, with `Cache-Control: no-store`. That code is separate from the viewing link's code, which is also the shared `guest` media password. It is 32 random bytes and changes with every new link and at Stop.
   - The listener binds IPv4 `0.0.0.0:80` without address reuse. It answers only connections whose local destination is the viewing address, and only `GET`/`HEAD /` with the active name or the viewing address as `Host`. Other connections close without a reply, as does a request still arriving when the viewing address moves. Other hosts, paths, and methods get 404, 405, or 400 without either code. Each connection has a 3 s deadline and at most 16 are open at once. A header over 4 KB in total, however it is split, gets 431.
   - Requests through the short address always wait for Admit, and need a name and Ask to join. Their bound is 8 of the existing 16 pending, and the 128-pass bound is unchanged. Admitted viewers play with their own read-only reader, as link viewers do under approval.
   - Turning approval off, or turning the option or the local address off, declines typed requests still waiting and never admits them. A new typed request then gets the generic 404, so the page shows the link as no longer active. Admitted sessions keep playing. Stop retires the short-address path with the link. Waiting pages then show "This viewing link is no longer active", not a refusal. Local monitoring continues.
   - Port in use, refusal, and other failures are named in Settings and the join sheet with the link or QR code as the fallback, and retried every 10 s. A new name updates the route in place. A new viewing address also closes requests still open to the old one.
   - Settings, the join sheet, and the approval toggle's caption say what typing the name does now. Operator rows read "Typed setbeam-qa.local. Names are chosen by viewers and are not verified." The generic unavailable page now reads "Ask the operator for the current link or QR code. Typing the address alone works only when the operator lets viewers ask to join from it."
2. **Join request card.** Each new request, from the link or the short address, shows a card in the top-trailing corner of the screen being watched. That is the main window's screen while Setbeam is in front, otherwise the floating preview's.
   - The card is a borderless, non-activating panel at status-bar level. It joins all Spaces and full-screen apps, cannot become key, and accepts the first click. It shows up to three requests with name, color, route ("Typed setbeam-qa.local" or "Opened the viewing link"), session number, and device, each with Decline and Admit. More requests show "N more…", which opens Picture and Viewers.
   - It hides after 20 s unless the pointer is over it, and also on its close button, when nothing waits, and at Stop or Quit. A new request also posts a VoiceOver announcement and, when Setbeam is in the background, one informational Dock bounce.
   - Waiting requests stay in the sharing bar ("N asking to join"), Picture and Viewers, a new pending button in the floating preview's controls, the menu bar menu (with Admit and Decline per request, and a clock icon), Feed > Show Join Requests, and the Dock badge.
   - Each request is announced once per link, by session number. Heartbeats, list refreshes, a reloaded tab, or a row that briefly drops out never announce it again. A card acts only if that exact request (link, number, join time) is still waiting, so answers given elsewhere, lapsed requests, and earlier links do nothing.
   - The card draws its own small filled buttons. System bordered buttons render gray while the app is inactive, which is when the card is used (first capture below). Since round 1, Admit's text and fill come from the resolved accent at 7:1. Hover and press raise contrast and add a stroke. Truncated text has tooltips that show while another app is in front.

## Notification choice

Native macOS notifications (`UNUserNotificationCenter`) were not used:

- They need a permission the operator grants. Denial or Focus silences them, and a prompt shown while nobody is at the Mac records a denial.
- Actions from a notification arrive through a delegate after the app is relaunched or activated. A stale action needs the same checks, with no way to show a row disappearing.
- Banners share space and grouping with every other app's notifications.

The card needs no permission and works when notifications are denied. It acts once and refuses stale actions. It keeps other apps in front, and it uses the app's own type, symbols, accent color, and materials. The Dock badge, Dock bounce, and VoiceOver announcement need no permission either. No permission prompt was added, so there is no denied state to fall back from. No sound plays: Setbeam runs on set, where a sound can reach live microphones.

## Automated checks

- **Swift: 15 new tests, 209 in total (149 core and 60 app).**
  - `ShortAddressReplyTests` (3): a typed name redirects to the ask-only path on the same host. Case, `:80`, a trailing dot, a query, and the IP address are accepted. Other paths, hosts, ports, methods, and a missing `Host` are refused without the code. Port errors are named.
  - `ShortAddressListenerTests` (3): on a real wildcard listener, only the viewing address is answered; another local address (`en0` or `en1`) gets no reply until the route moves to it. Stop releases the port. A port another socket holds reports `inUse` without flapping, and becomes active when released. Stop then start reuses the port promptly.
  - `ShortAddressAdmissionTests` (3): the short address never opens without approval. Typed requests are always pending and need Ask to join. Closing it, or turning approval off, declines waiting typed requests while link requests are kept or admitted as before. Admitted sessions continue and known passes resume. The pending bound is 8. A new link closes it.
  - `ShortAddressGatewayTests` (1): on the real gateway, the ask-only path serves the page and state without the link's code. Join and config never return it. Closing declines the waiting request and 404s new ones, while the link keeps working. A new link retires the path.
  - `JoinRequestTests` (5): each request is announced once across heartbeats, reloads, a brief drop-out, and links. A card acts only on the same waiting request. The center mirrors waiting requests and clears at Stop. Stale answers do nothing. The short-address setting is opt-in and saved, and its status names what it needs.
  - `ViewerGatewayTests.testExpiredNavigation…` was updated for the new unavailable-page sentence. Its first run failed on the old sentence (`XCTAssertTrue failed`, 4 times, line 25) and passed after the update.
- **Real-media probe `--short-address-test`, 8 PASS lines, added to `scripts/check.sh`.** It uses the real gateway, the real port 80 listener, the system responder (this Mac only), bundled MediaMTX, and FFmpeg:
  - an unprivileged wildcard listener answers on port 80
  - only `GET /` redirects, and other hosts and paths get 404 without either code
  - another local address gets no reply
  - a typed request must ask with a name, waits without playback details, and the link's code alone gets WHEP 401
  - after Admit, its own reader decodes 50 real audience frames
  - Hold reaches the typed viewer while monitoring continues
  - approval off stops port 80, declines waiting typed requests, refuses new ones, and keeps the admitted viewer
  - Stop retires the path with the link, and monitoring continues

  It reports and continues on a substitute port if port 80 is unavailable. Port 80 was free on every run here.
- Viewer and pointer controllers are unchanged; check-viewer-recovery.js and check-viewer-pointers.js pass with their existing tests.

## Full check

The final `scripts/check.sh` passed on its first run, with no QA app running (exit 0, 10 min 38 s):

- 209 Swift tests, 0 failures: 149 core and 60 app (194 before, 15 new).
- 43 viewer and 12 pointer checks, 0 failures.
- 60 probe PASS lines: the same 52 as build 25, plus the 8 new short-address lines.

Log: `build/short-address/check-run1.log`, with `check-run1-logs/`. `git diff --check` passes. No probe or preview-bridge intermittent failure occurred. An earlier standalone `swift test` run (`build/short-address/swift-test-1.log`) failed only on the unavailable-page sentence described above.

### After review round 1

The first `scripts/check.sh` run after the fixes stopped after 3 s. The failure was at `scripts/check-preview-bridge.py` line 102, `assert all(0 < delta < 100_000 for delta in intervals)` (`AssertionError`), the known intermittent preview-bridge interval assertion. That script and the preview bridge are unchanged (`r2/check-run1-preview-bridge-fail.log`). The unchanged rerun passed (exit 0, 10 min 40 s, `r2/check-run2.log` with `r2/check-run2-logs/`):

- 214 Swift tests, 0 failures: 152 core and 62 app. That is 209 before, plus 3 listener and parser regressions and 2 palette tests.
- 43 viewer and 12 pointer checks, 0 failures.
- 60 probe PASS lines, including the 10 `--local-address-test` and 8 `--short-address-test` lines that now use the shared helpers in `ProbeRequests.swift`.

## Native QA (isolated copy)

Captures are of Setbeam's own windows, in `build/short-address/qa/shots/`. The sample is the labeled `Demo.mp4`. Frontmost-app checks used System Events. Clicks were real `CGEvent` mouse events at the button frames read through Accessibility (`qa/click.swift`).

- **Port 80 and the name** (`qa/curl-checks.txt`): `lsof` showed `Setbeam … TCP *:80 (LISTEN)` (IPv4 only) while sharing, and `setbeam-qa.local` resolved to 192.168.1.238.
  - `curl http://setbeam-qa.local/` returned `302 Found` with `Location: http://setbeam-qa.local:<port>/s/<64 hex>/` and `Cache-Control: no-store`.
  - The same request to 192.168.1.234 (Wi-Fi, not the viewing address) and to 127.0.0.1 got no reply (curl exit 56).
  - `Host: example.com` and `/viewer.js` returned 404.
- **One request** (`native-dark-card-one`, first build): a T3 tab opened `http://setbeam-qa.local/`. It landed on Ask to join, with approval true in state, and asked as Sam. The card appeared at the top right while Stream Deck stayed frontmost. Two problems in this capture were fixed before the later captures: the route text was truncated, and Admit was gray.
- **Several requests** (`native-dark-card-four`): Sam from the browser, plus Kai, Ana, and Lee from `qa/asker.py`, which types the name, asks, and heartbeats like a waiting page. The card showed three rows and "1 more…". The Dock item's status label (read through the Dock's Accessibility) was 4. Finder stayed frontmost.
- **Admit without taking focus**: one real click on "Admit Sam, session 1" while Finder was frontmost admitted Sam (`viewer.admit`, shortAddress true). Finder stayed frontmost.
  - The T3 tab played 1280×720, advancing 2.00 s in 2 s. The Dock label went to 3.
  - Reloading Sam's tab resumed playback with no new request. Alerts stayed at 4, one per request.
- **Discoverable after hiding**: with the pointer resting on the card after the click, it stayed up. Once the pointer moved away, it hid on its own within 20 s. Requests stayed in the Dock label (3) and the floating preview's controls (`native-dark-floating-pending`, button "3 asking to join. Show requests"). They also stayed in the main bar button "3 asking to join" and the menu bar item "3 asking to join".
- **Picture and Viewers** (`native-dark-viewers-typed`, `native-light-viewers-typed`): each typed row reads "Typed setbeam-qa.local. Names are chosen by viewers and are not verified."
- **Answered elsewhere** (`native-dark-card-after-decline`): Decline for Kai in Picture and Viewers turned Kai's client to declined. Feed > Show Join Requests reopened the card with only Ana and Lee.
- **Settings** (`native-dark-settings-active`, `native-light-settings-active`): the option, its caption, and "Viewers on this network can type setbeam-qa.local and ask to join."
- **Join sheet** (`native-dark-join-sheet`, `native-light-join-sheet`): the line "Viewers on this network can also type setbeam-qa.local and ask to join." The dark capture predates the final wording of the line above it, which now reads "Copy viewing link uses this name. People with the link also ask to join." (light capture). The QR code in these captures encodes that QA session's link, which Stop expired.
- **Approval off from the sharing popover**: caption before: "Viewers enter a name and wait for you to admit them, including anyone who types setbeam-qa.local."
  - After: `lsof` showed nothing on port 80, and `curl` got no connection. Kai, Ana, and Lee all read declined. Pending went to 0, the card hid, and the Dock label cleared.
  - Status: "Turn on Ask before viewers join. Until then, typing setbeam-qa.local doesn't open anything." Caption: "… Needed for viewers to ask from setbeam-qa.local."
  - Admitted Sam kept playing (1.96 s in 2 s). Turning approval on again reopened port 80.
- **Port in use** (`native-dark-settings-port-in-use`, `native-dark-join-sheet-port-in-use`): Stop, then `qa/hold80.py` bound `0.0.0.0:80` as another app would, then Start.
  - Status: "Another app is using this Mac's web port (80), so typing setbeam-qa.local doesn't reach Setbeam. Send the link or QR code. Setbeam keeps trying." Logged `short.address` `unavailable` `inUse`.
  - After the holder stopped, the short address was active again within the 10 s retry, and `curl` returned 302.
- **Light card** (`native-light-card`): three requests, with Finder frontmost.
- **Stop**: a waiting T3 tab showed "This viewing link is no longer active", and the scripted clients got 404. Port 80 was free and the name no longer answered. The card and Dock label cleared, and local monitoring kept playing.
- **Quit**: before each normal Quit the QA app had 7 owned processes (`owned-before-quit-dark.txt`, `owned-before-quit-light.txt`, and two earlier rounds). None remained afterwards. The scripted clients, the port holder, and headless Chrome were not running at the end.

## Browser QA

- A T3 preview tab drove the real flow: typing `http://setbeam-qa.local/`, landing on Ask to join, asking, waiting, playing after Admit, reloading, and seeing Stop.
- T3 echoed the redirected URL, including that session's short-address code. That code is the ask-only one, not the link's, and Stop retired it.
- `preview_snapshot` with `save: true` failed with "Preview snapshot failed: Preview automation snapshot timed out after 15000ms.", as in earlier notes.
- Fallback: headless Chrome (`--headless=new --screenshot`, fresh temporary profile, its own process group) loaded `http://setbeam-qa.local/` at 1280×800 (`browser-desktop-typed-ask`): Ask to join, with no request created (pending and alerts unchanged).
- The 390×844 capture from the same CLI was clipped on the right, because that mode doesn't emulate a phone viewport. It was deleted. The viewer page itself is unchanged from build 25, whose phone layout was verified with device emulation.

## Incidents

- At 02:59:45 UTC, the first click on the card's close button did not reach the card, and Calendar became frontmost. The card stayed up.
  - A retry at 03:00:09 hid it (`viewer.request.card` dismiss). No Calendar window was on screen when checked afterwards.
  - The likely cause is a system notification banner in the same corner, but this was not confirmed.
  - System banners sit above the card's level and use the same corner. That is a known limit below.
- One scripted client died on a transient `.local` lookup failure (`[Errno 8] nodename nor servname provided`). Its request lapsed, and the card and Dock label dropped to 2 as expected. The client was then made to retry.
- Escape was sent through System Events once to close the QA app's sharing popover while it was frontmost.
- During port-80 QA, the QA app's wildcard listener was reachable from the LAN at this Mac's other addresses, and it closed those connections without a reply. Sharing published `setbeam-qa.local` on the Ethernet network while QA shared.

## Known limits

- Not physically qualified: other devices typing the name, phone browsers that treat a bare `.local` word as a search, networks that block multicast, and an app that really owns port 80 on a set.
- Port 80 works unprivileged only on the wildcard address on the tested macOS 27 build. Other macOS versions or managed Macs may refuse it. That is reported and the link remains.
- While sharing with the short address open, the macOS Application Firewall may treat port 80 like the existing gateway listener. That was not exercised here.
- The card shares the top-trailing corner with system notification banners, which can cover it briefly.
- The card is not keyboard-focusable, so it never takes keystrokes from other apps. Keyboard users answer in Picture and Viewers or the menu bar.
- The phone layout of the join page at the short address was not re-captured, because the page is unchanged.

## Review round 1

Two GPT-6.1 Sol reviewers on xhigh reviewed `review-r1-code.patch` (SHA-256 `5dda4db8…7ffa`). Both withheld approval for the same destination finding. Standards raised five hard-rule findings and one judgement suggestion. Spec raised only the shared finding. Neither changed project sources. Both independently passed the 15 focused Swift tests and 55 viewer and pointer checks. Before any fix, the reviewed state was copied to `build/short-address/pre-r2-snapshot/`, with hashes in `pre-r2-snapshot.sha256`. The r1 candidate app was kept as `build/short-address/r1-Setbeam.app`.

| # | Axis | Finding | Response |
|---|------|---------|----------|
| 1 | Standards + Spec, P2 hard | A request still being read when the viewing address moved got the new 302 (connect to A, send part of the header, move to B, finish on A). | Fixed. A new viewing address cancels every open request. Each reply also checks the connection's destination against the same route snapshot it is built from. |
| 2 | Standards, P2 hard | Fixed white on the accent fill measured 3.23:1. Whole-button opacity on press lowered contrast. | Fixed. `CardButtonPalette` resolves the accent SwiftUI draws and chooses white or dark text. It deepens or lightens the fill until the label reaches 7:1. Hover and press move the fill away from the text and add a stroke. Opacity is no longer used. |
| 3 | Standards, P3 hard | Each receive allowed another full 4 KB, so a 6059-byte header got a 302. | Fixed. Reads ask only for the bytes that remain under 4 KB. Past the limit the reply is `431`, and `reply(to:)` itself looks for the header end only within 4 KB. |
| 4 | Standards, P3 hard | Name, route, device, and title truncated without tooltips. | Fixed. Each has `.help` with its full value. The panel sets `allowsToolTipsWhenApplicationIsInactive`, without which no tooltip appeared at all (see below). |
| 5 | Standards, P3 hard | The card's buttons had no hover state. | Fixed. Hover deepens the fill (white text) or lightens it (dark text) and adds a 1 pt inner stroke. The size never changes. |
| 6 | Standards, judgement | Probe HTTP, WHEP, and frame-count helpers were copied from `LocalAddressProbe.swift`. | Resolved. The three helpers moved unchanged to `Sources/SetbeamProbe/ProbeRequests.swift`, and both probes call them. The raw-socket helper is used only by the short-address probe and stays there. |

### Regression proof

- **Before** (`build/short-address/r2/swift-test-prefix-red.log`, new tests run against the unmodified r1 `ShortAddress.swift`): 9 failures across 13 tests.
  - `testAnOpenRequestIsNotAnsweredAfterTheViewingAddressMoves`: a real socket to 127.0.0.1 sent half a header, the route moved to 127.0.0.2, and the rest of the header got `HTTP/1.1 302 Found`.
  - `testHeadersOverTheLimitAreRefusedHoweverTheyArrive`: a 4097-byte header sent in 7 packets got `302 Found`. Over-limit headers got 400 rather than 431.
  - `testTheParserRefusesHeadersOverTheLimit`: 4097- and 6059-byte headers were parsed and redirected by `reply(to:)`.
- **After** (`swift-test-postfix-green.log`): all 13 short-address tests pass.
- **Each defence alone** (`mutation-nocancel.log`, `mutation-nocheck.log`): with only the destination recheck, or only the cancel on move, the moved-address test still passes. With neither, the code is r1's, which failed.
- **Contrast.** `CardButtonPaletteTests` covers blue, purple, pink, red, orange, yellow, green, graphite, the current accent, and SwiftUI's resolved accent, in light and dark. It also covers a 729-color grid. Every rest state reaches 7:1, and hover and press never lower it. The test asserts that the r1 pair, white on the dark-mode accent, is below 4.5:1.
- **Real port 80 on the QA copy** (`qa/curl-checks-r2.txt`, `qa/split-header.py`):
  - 4096-byte headers in 1 or 7 packets: 302.
  - 4097 bytes in 7 packets: `431 Request Header Fields Too Large`.
  - 6059 bytes in 1 packet: 431.
  - 6059 bytes in 7 packets: closed while the client was still sending (`Broken pipe`), with no reply.
  - The Wi-Fi address and 127.0.0.1: closed without a reply.

### Native QA, round 2 (isolated copy, `build/short-address/qa/shots-r2/`)

The QA copy of the r2 candidate used the same preferences suite as before, again removed afterwards. It ran with the labeled sample feed, `setbeam-qa.local` on `en0`, and a long session title. Finder was frontmost throughout, except for one deliberate activation to compare tooltips. Scripted askers (`qa/asker.py`) supplied requests, one with a 44-character name that the gateway trims to 40.

- **Contrast, measured from captures.** `r2/tools/measure.swift` takes the most common pixel in each button as the fill and the pixel with the highest contrast as the text. Captures carry the display's "Laptop 16:10" profile, but their raw pixels equal the specified sRGB values. A full-screen region capture matched the window capture exactly, so WindowServer draws these values without color matching. Both readings are given, raw (specified sRGB) first, then converted through the display profile, as the round 1 reviewer measured.

| State | Admit, dark and light | Decline, dark | Decline, light |
|-------|----------------------|---------------|----------------|
| r1 rest | 4.02:1 raw, 3.23:1 converted (white on `#0091FF`) | quaternary fill | quaternary fill |
| rest | 7.12:1 raw, 5.40:1 converted (white on `#0055B3`) | 7.19:1 raw, 5.45:1 converted | 12.33:1 raw, 11.75:1 converted |
| hover | 6.60:1 converted | 8.63:1 converted (before the fill change below) | 12.29:1 converted |
| pressed | 8.29:1 converted | 10.21:1 converted (before the fill change below) | 12.76:1 converted |

  - Dark Decline's fill was raised from 0.24 to 0.32 gray after a full-screen capture showed the first fill nearly merging with the dark material. Its text went from 0.93 to 0.96 gray. Hover and press were measured on the first fill.
  - The 7:1 aim holds for the specified colors. Read through the display profile, which lightens dark colors, the floor of 4.5:1 holds in every state.
- **Hover and press.** Captures are `native-{dark,light}-card-{admit,decline}-{hover,pressed}`. Pressing and releasing outside the button cancelled the action (still 3 waiting). In every state the card stayed 352 pt wide, and the same measurement rectangles found each button at the same place and size.
- **Non-activating buttons:** a real click on Admit for Kai admitted him (`viewer.admit`, shortAddress true), and Decline for Lee declined him. The close button hid the card (`joinRequestCard` false, 4 still waiting). Finder stayed frontmost after each.
- **Tooltips.** On the r1 panel, hovering truncated text created no tooltip window, whether Finder or Setbeam was frontmost. With `allowsToolTipsWhenApplicationIsInactive`, and Finder frontmost, tooltip windows showed the full title ("Stage left rehearsal monitor for the evening run-through"), name ("Alexandria Montgomery-Fitzgerald of Ligh", as trimmed by the gateway), route, and device. The captures are `native-dark-card-{title,name,route,device}-tooltip-window`.
  - AppKit shows a tooltip again only after the pointer leaves the card and returns.
  - Region screenshots sometimes missed the tooltip window, and one shows a leftover close-button tooltip. The window captures are the evidence.
- **Cleanup.** Before each of the three Quits, the copy owned 11 processes (`qa/owned-before-quit-r2-{a,dark,light}.txt`), and none remained afterwards. Port 80 was free. The askers were stopped by their recorded PIDs, and the QA preferences suite was deleted.

### Limits after round 2

- Neither reviewer, nor this round, used VoiceOver or a keyboard live on the card. It still cannot become key, so keyboard users answer in Picture and Viewers or the menu bar.
- Accent colors other than the current blue were checked only by unit tests and not on screen, because changing the system accent is a global preference.
- The round 1 Calendar activation during a close click was not reproduced. The close click in round 2 kept Finder frontmost.
- The physical limits under Known limits are unchanged.

## Changed files (against the baseline snapshot)

Baseline: `/var/folders/8h/r0gxs7ls4kgc804g7lj475q80000gn/T/setbeam-short-address-baseline-tshuydwi` (HEAD `df085a58f13d4bc556797d530c19244261886ed9`, 190-file manifest).

- Added: `Sources/SetbeamCore/ShortAddress.swift`, `Sources/SetbeamApp/JoinRequestCard.swift`, `Sources/SetbeamProbe/ShortAddressProbe.swift`, `Sources/SetbeamProbe/ProbeRequests.swift` (round 2), `Tests/SetbeamCoreTests/ShortAddressTests.swift`, `Tests/SetbeamAppTests/JoinRequestTests.swift`.
- Changed: `Sources/SetbeamCore/ViewerAccess.swift`, `Sources/SetbeamCore/ViewerGateway.swift`, `Sources/SetbeamApp/SessionModel.swift`, `Sources/SetbeamApp/SettingsViews.swift`, `Sources/SetbeamApp/ViewerActivityRow.swift`, `Sources/SetbeamApp/MonitorPopoverViews.swift`, `Sources/SetbeamApp/FloatingPreview.swift`, `Sources/SetbeamApp/SetbeamApp.swift`, `Sources/SetbeamApp/Resources/expired.html`, `Sources/SetbeamProbe/main.swift`, `Tests/SetbeamCoreTests/ViewerGatewayTests.swift`, `scripts/check.sh`, and `Sources/SetbeamProbe/LocalAddressProbe.swift` (round 2, helpers moved out).
- Docs: `CONTEXT.md`, `docs/architecture.md`, `docs/status.md`, `docs/plan.md`, `docs/STORIES.md` (S-010), and this note.
- Review scope: `build/short-address/review-r1-code.patch` (17 files, +1364/−36, SHA-256 `5dda4db8b8dc72f14d73660467dbe6bb17453320d26b9d709b2193d582f77ffa`) and `build/short-address/review-r1-docs.patch` (the 6 doc files; regenerate after any doc edit). Both are unified diffs against the baseline snapshot, not against HEAD.
- Round 2 scope: `build/short-address/review-r2-code.patch`, 19 files, +1619/−66, SHA-256 `2e88d031f045a5e38f0025c6d71c2d2b439fe3a6941406ce794cf3fe89a130b4`. It is accompanied by `review-r2-docs.patch` (6 doc files) and `review-r1-to-r2.patch` (the change since the reviewed state), all made by `r2/make-patches.sh`. Exact per-file counts are in `review-r2-numstat.txt`. Round 1's patches are unchanged.

## Reviewed candidate before numbering

The reviewed `build/Setbeam.app` had 37 files, built by `scripts/build-app.sh` after the last source edit (`build/short-address/r2/build-app-2.log`). No source file was newer than its executable. The round 1 candidate (executable `63b1a6aa…da1f`) was kept as `build/short-address/r1-Setbeam.app`. The candidate before that was kept as `build/short-address/pre-short-address-Setbeam.app`.

- Strict recursive signature check passed. No executable linked a Homebrew or `/usr/local` path. `expired.html` matched the source. `CFBundleVersion` was 25.
- Executable SHA-256: `09988764ffcd6075f8e4786a9a216ffb1bac7e57e0e7e24aba451426f7e4bdd7`.
- This candidate was not installed, archived, or delivered before review.

## Review round 2

Both delegated GPT-6.1 Sol reviewers ran on xhigh with the default service tier. They reviewed the original brief, all first-round findings and responses, the complete task patches against the immutable baseline, and the incremental fixes. Neither edited project sources.

### Standards

Approved with no actionable remaining findings. All five hard findings are resolved: destination enforcement, contrast, the header bound, inactive-panel tooltips, and hover feedback. The duplicated probe helpers are shared and their bodies match the originals apart from access and type names. The reviewer independently measured Admit at 7.12:1 raw and 5.40:1 through the display profile, increasing on hover and press, satisfying the cited Mac design rules.

Validation: exact source reconstruction and patch/baseline hashes; 20 focused Swift tests; 43 viewer and 12 pointer checks; supplied light/dark card, tooltip, Settings, invitation, viewer-list and fallback captures. No fresh GUI, port-80, VoiceOver, keyboard, physical-device or full-suite run. Dark Decline hover/press captures precede its final palette adjustment; current palette tests pass.

### Spec

Approved with no actionable findings. The destination-filter issue is resolved by cancelling old requests on an address move and rechecking each reply against the route snapshot used to construct it. Authorization, explicit asks, pending cleanup, token rotation and stale-action guards remain intact. No regression found in header limits or the helper extraction.

Validation: 32 focused Swift tests; 43 viewer and 12 pointer checks; 40 additional real-socket address-change and Stop/restart cases on ephemeral ports; in-flight hostname rename/current-path handling; exact reconstruction of all 25 scoped files; `git diff --check`. No GUI, port-80, real-media, full-suite or physical-network rerun.

Final findings: Standards 0, Spec 0. No unresolved objection remains on either axis. Usage was not reported. The physical and accessibility limits above remain open.

## Build 26 package and installation

The parent rebuilt locally with `scripts/build-app.sh` (`build/short-address/final/build26.log`). The only build-input change from the approved candidate is `CFBundleVersion` from 25 to 26. All other reviewed inputs match `build/short-address/final/reviewed-inputs.json`; removing code signatures proves the executable is byte-identical to the reviewed candidate.

- Installed: `~/Applications/Setbeam.app`, version 0.2.0 build 26. No installed Setbeam process was running. The previous app was moved to `~/Applications/.Setbeam-before-short-address-build26.app`. The installed GUI was not launched against Austin's saved setup.
- Archive: `dist/Setbeam-0.2.0-build26.zip`, SHA-256 `5f0f9634b8553b79f32a04e0506809bc81db49128fed39dfd710d981d0f177b4`, with a matching `.sha256` file.
- Contents: `Setbeam.app`, `BUILD-NOTES.md`, `APP-SHA256.txt` for all 37 app files, and `SOURCE-MANIFEST.txt` for 140 build inputs. No QA sessions, preferences, links, logs or runtime directories are included.
- Executable SHA-256: `b8ba94f6b5335fc88867f3167165d62e894f11fb6645abb5ecf318b921cf2d86`.
- Source manifest SHA-256: `389d7d0d38c131060451260f854bc9598ae0a1b6280b734ebec55b27352fd415`. All 140 inputs match this checkout.
- ZIP CRC verification passes. All 37 app files are byte-identical across the fresh build, extracted archive and installed app. Strict recursive signatures pass on all three. Every executable is arm64 and links only system libraries; no Homebrew or `/usr/local` dependency exists.
- Parent visual inspection confirmed readable light/dark cards, Settings, join invitations, viewer rows and the floating-preview pending indicator. The screenshots come from the isolated QA sessions described above.

The release `SetbeamProbe` ran sequentially against the installed app's own `Contents/Helpers` and `Contents/Resources/Fixtures`:

- `--access-test`: 7 PASS, exit 0, 45.79 s. Log: `build/short-address/final/packaged-access.log`.
- `--local-address-test`: 10 PASS, exit 0, 26.33 s. Log: `build/short-address/final/packaged-local-address.log`.
- `--short-address-test`: 8 PASS, exit 0, 19.20 s. Log: `build/short-address/final/packaged-short-address.log`.

No commit, push, PR or hosted workflow ran.

## Private delivery

The Austin Deliveries helper returned `state: delivered` with verified HTTPS URL at `2026-11-04T04:09:07.513174+00:00`. Delivery ID: `20261104T040855Z--d9a46b53f81f`. Stable request ID: `setbeam-short-address-build26`. Destination: Setbeam / Short address. Delivered files are `Setbeam-0.2.0-build26.zip` and `Setbeam-0.2.0-build26.zip.sha256`. The uploader health check passed, including actual Google access. Local originals are retained under ignored `dist/`.

[Private verified delivery](https://drive.google.com/drive/folders/1oCc72vu-Y08V0ttGPoLHkpOBQ4khbZIh).
