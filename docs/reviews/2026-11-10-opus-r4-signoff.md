I approve all seven items, with no code blockers. This local developer build is ready to deliver under the limits already recorded. Two of the approvals cover the implementation only, with manual checks still to do on real hardware: mobile layout (#3) and reopening (#6). I only read code and evidence, compared against `/tmp/setbeam-before-20261110`. I ran nothing and edited nothing.

## Round-3 requests, checked in the code and evidence

- **Menu uses the reopen path:** "Open Setbeam" (`SetbeamApp.swift:100`), the Sharing submenu's `show()` (`SetbeamApp.swift:130`) and the App commands (`SetbeamApp.swift:91-92`) all call `model.reopenMonitor()` first.
- **Short-keyboard chat draft:** `.keyboard-tight` no longer hides the draft details (`viewer.css:62-69`). It keeps a 32px thumbnail and 44px × buttons. The Chrome check runs at 844×260, requires Remove Frame, Cancel Reply and Send to be at least 44px tall and fully on screen, clicks both, and confirms the draft text survives (`check-collaboration-browser.js:52-63`).
- **PDF footnote:** it now says "Open Wi-Fi network" when there is no password and "Contains Wi-Fi password" only when there is one. A Wi-Fi-only export adds no sentence about viewer access (`JoinCodeWindow.swift:138-139`).
- **Join-codes panel level:** it now starts as a normal window (`JoinCodeWindow.swift:15`) and changes only with the toggle (`JoinCodeWindow.swift:19-21`).
- **Mobile sizes:** `browser-results.json` covers all 8 Chrome sizes, including 820×1180 and 1180×820. `webkit-results.json` covers 7 WKWebView sizes, including 768×1024 and 1024×768, with `actualDecodedSample` and `canvasCapture` true and `physicalIOS` false. None of the sizes overflows sideways, input text is 16px everywhere, and the draft survives every size change.
- **Cold launch:** `cold-launch-count.json` shows `mainWindows: 1` and `visibleMainWindows: 1`. The reopen code is one path: `applicationDidFinishLaunching` and `applicationShouldHandleReopen` both call `reopenMonitor()`, which opens the main window by its ID, un-minimizes and raises it.
- **`docs/status.md`:** it is current and states that the engine scripts are run by hand.

## Verdicts

| # | Item | Verdict |
|---|---|---|
| 1 | Named pointers on the shared screen | **APPROVE.** This covers the code plus local evidence on the one available 1920×1080 display: 1,010 red pointer pixels on screen against 0 in the same region of a real outgoing frame, clicks and typing pass through, and Hold and Stop clear it. Retina, notched and secondary displays and full-screen Spaces remain manual checks. |
| 2 | Wi-Fi name list and password check | **APPROVE.** A secured network can't be saved as an open code. Nothing joins a network automatically, and the password is only checked by scanning the code with a phone. |
| 3 | iPhone portrait/landscape and iPad | **APPROVE, with manual checks on real devices still to do.** The engine evidence round 3 asked for is complete. Mac WebKit and Chrome are not iOS. Simulator, physical iPhone/iPad keyboards and iOS Safari frame capture remain unqualified and are not claimed. |
| 4 | Session chat | **APPROVE.** Viewers write chat as you authorized. Media stays read-only, publishing and moderation stay private, and the plain-HTTP warning is shown in the UI. |
| 5 | Floating, saved and printed QR codes | **APPROVE.** The panel level fix and the footnote fix are both in the code. Phone scans of the screen and of paper remain manual. |
| 6 | Opening from Applications always shows the app | **APPROVE for the developer build, with manual checks still to do.** The tests ran through Launch Services (`open -a`) and the delegate regression test, not by clicking the Dock icon or using Spotlight. They cover cold launch with the main window closed at quit, a closed main window with the floating preview or Sharing window showing, and a minimized main window. A Dock click and a Spotlight launch on a running app call the same `applicationShouldHandleReopen`, and a Dock or Spotlight cold start goes through `applicationDidFinishLaunching`. Actually clicking the Dock icon and using Spotlight is **unqualified, not passed**. One Dock click and one Spotlight launch with the main window closed, on your Mac, would settle it. |
| 7 | Clean menu bar | **APPROVE.** Every entry point that opens the main window goes through `reopenMonitor()`. |

## Small gaps, not blocking

- **Cold-launch record:** `cold-launch-count.json` contains only the process ID and window counts. "Closed at quit" and "sharing off" are recorded in the notes, not in that file.
- **Join Codes window during reopen:** reopening with the Join Codes window open wasn't tested on its own, only with the floating preview and the Sharing window. The code path is the same, so I'm not requiring it.
- **Portrait scrolling:** in Chrome portrait, Send sits slightly below the bottom of the screen (858 vs 844 on iPhone, 1111 vs 1024 on iPad mini), so the page scrolls. That's normal for the stacked portrait layout, and the check only enforces short landscape. Watch for it on a real phone.

**Overall: ready to deliver as a local developer build.** It is not qualified on real hardware: iOS devices, Simulator, actually clicking the Dock icon and using Spotlight, joining Wi-Fi from a phone, scanning paper codes, other display types, and spoken VoiceOver all remain manual checks.
