# Floating preview verification

Date: 2026-10-20. PiP changes for the combined build 7. Packaging and delivery belong to the main-window/recovery thread.

## Behavior

The floating preview is a resizable picture window without a title bar or controls over the feed. Pinch and scroll magnify around the pointer, with a 1× to 6× range. Dragging a magnified picture pans within its image edges. Double-click or 0 restores the complete picture. At full picture, dragging moves the window. The keyboard also supports plus/minus and arrow-key panning.

A separate companion strip appears on hover and remains reachable across the small gap below the picture. It hides after the pointer leaves. Keyboard focus keeps its buttons available. Near the screen bottom, the strip appears above the picture. Showing it does not resize or shift the picture. It contains the session name, sample/status label, local sound, and Close. A noninteractive percentage badge appears while magnified, including at the minimum 220-pixel window width. There are no zoom buttons.

Main and floating views continue to consume the same NativePreview decoder. Magnification changes only the floating view's drawing. Audience media, source reception, and local sound routing are unchanged. Closing PiP leaves monitoring available. Source changes reset inspection. The floating aspect ratio follows the decoded picture. This pass does not increase the shared decoder's 1280-pixel/24-fps output.

## Automated evidence

Eight app geometry tests cover pointer anchoring, pan limits at all edges, returning to the whole picture, letterboxed source geometry, resizing while magnified, maximum zoom, invalid zoom factors, aspect-preserving corner resizing, and minimum-size edge resizing. `swift test` passes with 32 core tests and eight app tests. `scripts/check.sh` passed before the final window-move/edge-resize corrections, including viewer-controller checks, encoded sample media, authenticated RTSP/RTMP, silent audience Hold, independent local monitoring, source/server recovery, source replacement, audio-track reporting, and owned-process cleanup. The build owner is rerunning the final packaged check after refreshing the executable.

The initial compile reported `use the 'required' modifier to override a required initializer` for HoverHostingView's root-view initializer. It was corrected. The first check invocation stopped at `Sources/SetbeamApp/PlayerView.swift:37: new blank line at EOF`; removing the extra blank line corrected it, and the complete check was rerun successfully.

## Native evidence

The isolated harness under ignored `build/pip-qa` compiles the actual application views and runs the real encoded sample feed with separate preferences. It verifies native hover visibility, separate window placement, scrolling and keyboard magnification, drag-to-pan without moving the window, double-click and keyboard reset, stable picture geometry during hover, above-picture placement near the screen bottom, minimum-size controls, close/reopen, and continued local monitoring. Native screenshots were visually inspected in the full-size and 220-pixel layouts. The percentage badge and sound/close actions fit without overlapping the picture.

CUA-routed mouse input initially exposed a real borderless-window issue. `performDrag` logged `Window move completed without beginning` and did not move the picture. Explicit tracking of the owned window corrected it. Borderless native resize tracking also intercepted edge input without resizing, so the picture now handles its edges directly, preserving aspect ratio and minimum size. Final CUA checks moved the window by 50 points horizontally and 25 vertically, grew it from 400×225 to 460×259 using the right edge, and returned it to 400×225 using the corner. Routed scrolling reported 143 percent through accessibility, dragging panned the magnified picture, and double-click restored `Full picture`. The corrected paths passed with the separate controls still outside the feed.

Local evidence is in `build/logs/pip-native-qa.log`, `pip-swift-tests.log`, `pip-check.log`, and `build/pip-qa/*.png`. Source media, saved production preferences, and the running real-source app are not changed by this harness. The pictures are explicitly sample media.

Physical trackpad pinch, another display/Space, a physical source during gesture use, and a full VoiceOver pass are not yet recorded. Existing source compatibility evidence remains in hardware-tests.md. This UI check makes no additional hardware or latency claim.
