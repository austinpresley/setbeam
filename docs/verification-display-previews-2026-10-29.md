# Display source previews

Austin requested small, rounded previews of each connected display in the source chooser. Build 19 adds a 120 by 72 point preview to each display row, preserving the whole picture's aspect ratio. Other input routes and transmitter recognition are unchanged.

## Design and behavior

The existing Choose a source sheet remains the entry point. Names and resolutions sit beside each thumbnail; the whole row still selects that display. Previews refresh every two seconds while the chooser is open. Escape and Done dismiss it. Loading, unavailable, and permission-denied states occupy the same frame. A denied grant adds Enable Previews without blocking other sources. The row keeps its existing combined accessibility label and adds the full name as hover help.

SCScreenshotManager captures small, silent pictures of unselected displays with Setbeam excluded. Images stay in memory and clear when the sheet closes. The monitored display reuses the existing NativePreview frame, preserving one capture stream and one upstream feed. Display IDs remain UUIDs; no stream URL, source choice, or sharing intent changes while browsing. The [Apple API documentation](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:)) and installed SDK headers establish the screenshot API's macOS 14 availability.

## Native verification

An isolated QA copy used separate preference suites and session logs under ignored `build/display-previews`. It did not restore Austin's saved source.

- The actual 1920 by 1200 test display appeared with a readable name, resolution, and rounded thumbnail in active light and dark sheets. The full 16:10 picture fits without clipping. No unsolicited focus ring or unnecessary scroll bar appeared.
- A labeled display-content fixture changed color and moved a square behind Setbeam. Native screenshots recorded 6,867 changed pixels among 7,168 sampled thumbnail pixels while the source remained unselected, monitoring and sharing remained false, and the chooser stayed open. Setbeam's own sheet was excluded from the thumbnail.
- Screenshot measurements found a 120 by 72 point thumbnail inside a 485 by 96 point row with 12 point insets. The layout-grid skill's checker passed the measured geometry. Its lint passed the new file and added layout lines.
- A separate Launch Services launch without inherited recording access showed Preview off and Enable Previews. Opening the chooser did not trigger a permission prompt, and the sample remained selectable. No permission grant was changed for this check.
- Escape closed the chooser, and normal Quit closed the isolated sessions.
- The final packaged Build 19 selected the display privately and presented 1920 by 1200 video at about 30 fps. Reopening the chooser showed the same live feed in its thumbnail while native presented frames advanced from 75 to 563. Sharing stayed off. Normal Quit removed the app and all six recorded descendants.

Captures are retained locally as `build/display-previews/chooser-light.png`, `chooser-dark.png`, and `chooser-permission-denied.png`. Only one test display was connected. Physical multi-display/portrait layouts, hot-unplug, and VoiceOver speech remain untested.

## Automated checks and packaging

Debug and packaged release builds pass without new compiler warnings. The first full `scripts/check.sh` attempt passed the preview bridge and 26 viewer checks, then failed `SourceConfigurationTests.testFailedControllerUpdatesCannotShowThePreviousNetworkSourceUnderNewIdentity` with `The video service could not start.` The unchanged isolated test passed in 48.359 seconds. The complete unchanged retry passed all 119 Swift tests, 26 viewer checks, and preview, media, recovery, source-switching, format, frame-rate, and large-keyframe checks. The final probe decoded 490 frames in seven seconds from 1,749 KB keyframes without decoder errors. Exact logs are retained under ignored `build/display-previews`.

Strict recursive signatures, arm64 executables, system-only dynamic libraries, all six viewer resources, matching sample/hold fixtures, and bundled dependency notices/source archives pass. The 95-file source/test/script manifest stayed unchanged through verification. The final executable SHA256 is `ddbaed76c694efdeaa0a18e2ec1698d2c3653e08f73fe58f5086c9f6d88551b7`. The distribution app is `dist/Setbeam-0.2.0-build19-macOS-arm64/Setbeam.app`. The matching app is installed at `~/Applications/Setbeam.app`. ZIP integrity, extracted strict signatures, and all 36 installed/extracted file hashes pass. The archive SHA256 is `91de3f231bb2dd16c29f010bc747316c5ded0f7a8d5d2d8e2422e25a7cbad331`.

Private delivery completed with remote verification for the Build 19 archive and native dark chooser screenshot. All QA apps, their recorded helpers, and the temporary display-content fixture were closed.

All validation runs locally. No hosted workflow was enabled or run. The app remains an ad-hoc signed Apple Silicon developer build for macOS 14 or later, without notarization.

## Wireless compatibility

Direct wireless reception remains physically verified only for the CineView Master 4K firmware 3.30 unit recorded in [hardware-tests.md](hardware-tests.md), including the same unit's observed product IDs 21 and 24. The generic RTSP, authenticated incoming RTMP, and capture adapters are connection types, not additional model qualifications. The Hollyland Mars 300 and Mars 300 Pro remain unverified. This change adds no transmitter or physical compatibility claim.
