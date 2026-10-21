# Build 8 layout verification

Date: 2026-10-20. Austin approved the privately delivered Build 7 layout mockup and requested implementation. Review exports are archived locally outside the source files. Version 0.2.0, build 8 targets the same Apple Silicon macOS 14-or-later app.

## Presentation

The native main window uses the full width for its local picture. Its unified toolbar contains the session/source control, local sound, floating preview, and one gear menu. The footer shows Private, Sharing, On hold, or an outgoing reconnection warning. QR invitations, Hold/Resume, and Stop remain available during sharing. Start sharing appears only while private.

The source popover contains source confirmation, remembered setup, session rename, connection details, and a previous input when it differs from the active input. Input and Mac sound status live in the speaker popover. The actual outgoing thumbnail, audience sound, and playback/opened counts live in sharing status. The invitation popover contains the QR, accurate viewing-network instructions, copied-link feedback, and the join sheet. Sample media is explicitly named in the source control, floating preview, and viewer.

The gear menu opens setup tests, viewing-network settings, capture audio routing when applicable, Save frame, diagnostics, Advanced, and About. Advanced opens the requested section directly and cancels back to monitoring. Native Feed menu commands preserve keyboard access to floating preview, frame export, local mute, sharing, invitations, source choice, and session rename.

Recovery guidance, errors, changed viewing addresses, and a failed outgoing picture remain visible in the main window. A missing replacement source keeps its previous-source recovery action visible and Resume disabled. The local-monitoring hint only appears when a fresh local picture is available. The picture fits its available height in compact windows; it is not stretched or cropped to fill a different aspect ratio. Existing saved window geometry is preserved; the new first-open size is 900 by 636.

## Native sample checks

An isolated, separately identified `SetbeamLayout8QA.app` ran the bundled sample and loopback viewer without changing the existing physical-source app. Native screenshots and private telemetry are ignored under `build/layout-native`.

- The actual 900 by 636 dark window shows an 868-pixel-wide preview, source title at the left, and native icon controls at the right. The former main-window sidebar and permanent healthy/audio text are absent.
- QR invitations open from the footer. Copy viewing link changes to Link copied. Toolbar sound details open below the toolbar. Their accessible text distinguishes Input and Mac speakers; the toggle changes between Unmute this Mac and Mute this Mac.
- Viewing network opens Advanced with that section visible. The source menu opens the rename sheet; saving Studio sample updates the toolbar title without replacing the feed.
- Native Hold makes the existing Chromium viewer report On hold, mute, and remove its source playback. Local native frames keep advancing. The outgoing-status popover reads the actual holding output. Explicit Resume restores decoded video on the same viewer page.
- Native Stop makes the viewer report Sharing ended and mute. The app returns to Private with Start sharing, and native frames keep advancing.
- The floating-preview toolbar control opens the existing floating window; the native frame check passes with floating visibility required.
- Changing from sample to an unavailable RTSP input puts the same browser page on silent Hold, exposes recovery and the previous source, and disables Resume. Returning to the previous sample restores fresh local/outgoing pictures while viewers stay held on the same page. It requires explicit Resume.
- The final release QA opens at 900 by 636 in dark and light appearances. A clean light first run shows Choose a source and disables Start sharing until the selected sample has fresh native frames. Resizing to 640 by 472 keeps the whole picture and footer controls visible without clipping. The persistent join sheet opens correctly from the QR popover.
- Force Quit of the final release QA stopped the app and all ten owned sharing descendants. Normal Quit from final light/private monitoring stopped the app and all six owned descendants.

These are sample-media and software observations. They do not establish audible local output, physical camera/capture compatibility, trackpad behavior, or new transmitter/network reliability evidence.

## Initial corrections

The first candidate compiled, but macOS placed primary-action toolbar items beside the source. An automatic toolbar group following a principal spacer places them at the trailing edge. An inherited QA frame was 900 by 572; resizing to the intended 900 by 636 confirmed the full-width preview, and saved user geometry remains respected.

The first toolbar popovers preferred the space above the window. The attachment edges were corrected so toolbar popovers prefer below their controls and footer popovers prefer above them. Accessible labels were added to the gear image and each audio/viewer detail row. An offline-input check exposed a local-monitoring hint while waiting for picture; it is now limited to fresh local playback. Previous-source presentation now omits the already-active input.

The first packaged check passed all suites, but its source-freeze guard then correctly refused distribution with `RuntimeError: Source changed during validation: ['Sources/SetbeamApp/SessionModel.swift', 'Sources/SetbeamApp/MainView.swift']`. Those were the final presentation corrections above. That candidate was not distributed; release build and packaged checks were restarted from the final source snapshot.

The identity-isolated final QA copy was re-signed after changing its bundle identifier. A setup assertion that compared whole signed executables failed with `AssertionError`, because re-signing changes the embedded signature. The QA and release `__TEXT,__text` instruction sections were then compared and matched. The distribution bundle retains its original verified release signature.

## Final package

The final frozen candidate passed all 42 Swift tests, five viewer-controller checks, and `scripts/check.sh` against its own packaged helpers and fixtures. The actual-media sample/RTSP/RTMP, source/server recovery, silent Hold, read-only access, source switching, and owned-process cleanup probes all passed. The source snapshot stayed unchanged. Strict bundle signatures, bundled viewer resource hashes, and system-only dynamic dependencies passed.

- App: `dist/Setbeam-0.2.0-build8-macOS-arm64/Setbeam.app`
- Executable SHA256: `6f98baa7d7604b1a480c1dc824a282421ab6d0df13a81eaa08e427fc8a2b814f`
- Source snapshot SHA256: `a254c66ce727f24eecf54bb3fb5a365ff712643010207544c03a3beb40eecaaa`
- App archive SHA256: `b632038596fa4b2e0db60a277deb31a8851b095a886ae2b1c5051c39446b5542`
- Ignored evidence: `build/layout-native/package8.log`, `packaged-check8.log`, `final-force-quit.log`, `final-normal-quit.log`, and native telemetry/screenshots in that directory.

After the old production app was confirmed private and quit normally, Build 8 launched from `/tmp` and restored the same saved CineView Master 4K. Fresh native frames, setup confirmation, input audio-track presence, Mac sound muted, and sharing/Hold off were observed. The finished app was left monitoring privately. This adds a restoration observation, not a new compatibility claim or long-session test. The recorded short-soak failure and deferred two-hour check remain open.

## Private delivery

Delivery `20261021T031406Z--835679eec990` completed with remote verification through `agent-deliver`. The private delivery folder contains `Setbeam-0.2.0-build8-macOS-arm64.zip`, `BUILD-NOTES.txt`, and the finished native dark/light sample screenshots. Runtime directories, logs, QA bundles, session credentials, and physical-source captures were excluded. The delivered archive matches the SHA256 recorded above.

## Recorded walkthrough

Austin requested a video of Build 8 in action. `dist/Setbeam-build8-walkthrough.mp4` is a 46.13-second, 1440×932, 30 fps H.264 recording of the real native release QA app using its explicitly labeled fictional sample. ScreenCaptureKit captured only that owned sample process, excluding other apps and the desktop. The final edit trims pauses and adds captions outside the app window. It shows Private, Start sharing, QR invitations and copy feedback, source/session and sound details, Hold and the actual outgoing holding output, Resume, Stop, and settings. It has no audio track.

The entire finished MP4 decoded without errors. Chromium loaded it at the expected dimensions/duration and confirmed advancing playback with no media error. The sample app was quit after recording, expiring its invitation. Production monitoring was untouched. Temporary capture/encoding files remain ignored under `build/walkthrough8`; there were no app-code changes or new hardware-test claims.

Delivery `20261021T032820Z--ed844be91d89` uploaded only the finished MP4 and completed remote verification. The private video folder contains the walkthrough.
