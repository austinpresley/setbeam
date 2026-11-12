# Build 40 prerelease verification

The implementation baseline is private build 39, commit `83ad498`. Viewer access
fixes are in `327f5c0`, `807dd46` and `930929c`. The release retains the existing
build-38 memory correction. Austin authorized full-app review findings 1, 2 and
3; the other review items remain separate work.

## Regression evidence

Nine targeted cases were observed failing before their corrections. They cover
approved sessions hidden after twelve seconds without heartbeats, pending
requests disappearing before their thirty-second expiry, capacity
removing an approved identity or an unexpired pending request, failed credential
or disconnect changes leaving audience output active, immediate Start after a
failed private approval change, Start overtaking a coalesced newer approval
choice, and approval changing during a pending media command.

The actual-media failure cases establish decoded guest or admitted RTSP playback
before the injected fault and verify that existing playback ends afterward.
They cover failure before the credential request, injected lost confirmation
after a real accepted PATCH, and failure before disconnection. The original
private source and media-server processes remain running. A new explicit share
rejects the ended session's credentials. The lost-confirmation case is fault
injection, not a physical network-loss qualification.

Two code/spec review rounds found private-failure, pending-capacity and Start
ordering cases; their regressions and fixes are retained. Both third-round
reviews found no blockers in `83ad498...930929c`. These were source-only reviews.
The parent performed the builds and runtime checks.

An expanded focused run had one startup failure in
`testFailedPrivateApprovalCannotBeBypassedByImmediateStart`, before reaching its
authorization assertions: `The video service could not start.` The same test,
the coalesced-Start regression and the busy-control regression then pass
unchanged in isolation. No timeout, assertion or acceptance limit was relaxed.
This does not establish the cause of that previously recorded intermittent
startup failure. Two earlier full-check attempts were deliberately interrupted
to address review findings and are not counted as final validation.

## Local release checks

The complete isolated `scripts/check.sh` passes in 730.764 seconds using the
candidate app's bundled helpers and fixtures: 303 Swift tests with one opt-in
endurance soak skipped, five Python cases, 59 Node checks and every media stage.
Its 1,750 KB keyframe check decodes 503 frames in seven seconds without errors.
All 178 frozen source, test, script and notice inputs remain unchanged.

The release-mode writer regression passes four cases in 6.6 seconds. Its
accelerated volume case sends 1,300,000 frames, 81,250 MiB or 79.35 GiB, with
0 MiB reported footprint growth. This is an accelerated software memory check,
not an hours-long physical-source qualification.

Dark inline Viewers and light independent Sharing windows keep the stalled
viewer visible with No recent update and its Remove action. Chrome decodes 369
and 370 frames respectively while that viewer sends no heartbeats. Both runs
show two joined sessions but only one confirmed playing. Remove stops the
stalled viewer's decoding before its heartbeats resume, rejects its playback
configuration with HTTP 403, and leaves the other viewer decoding. The same
remaining page follows Hold, Resume and Stop. Native presented frames advance
by 61 over 2.5 seconds after Stop in each run. Floating monitoring also remains
live during Hold and after closing the floating window.

One light operator-driven attempt reports `Operator/browser phase timed out`
while waiting for the operator's Remove action. The operator paused longer than
the driver's existing two-minute deadline. The unchanged repeated case passes;
this is not counted as a successful first attempt or a media failure.

Eight Chrome and seven macOS WebKit layouts pass with actual decoded sample,
canvas attachments, compact draft controls and rotation-draft retention. These
are local desktop browser engines at phone/tablet sizes, not physical iOS tests.
Scoped layout checks find no added spacing, sizing or font overrides. Measured
status details fit inside their viewer scroll areas in both native appearances.
The light and dark windows are key in their captures and show full, unclipped
status text and actions. Normal Quit removes all seven recorded owned native
processes in each principal QA run.

T3 preview snapshots twice report `Preview automation snapshot timed out after
15000ms.` The unused tab is closed. Local Chrome/WKWebView checks supply browser
evidence. The QA copy differs only in bundle identity and signatures: its
unsigned executable, resources and helpers match the release candidate.

All six packaged executables are arm64, pass strict signatures and link only
system libraries. The bundle has 38 hashed files, with matching viewer assets,
upstream/dependency notices and source archives. Build 40 is installed with all
38 files matching; build 39 is preserved at
`~/Applications/.Setbeam-before-access-build40.app`. Normal installed startup
restores the saved CineView setup privately. The unavailable transmitter is not
a physical test. No hosted test, build or packaging workflow was enabled or run.

## Screenshot provenance

The current main light/dark and Sharing Options PNGs are unmodified native
window captures. The viewer JPEG is an actual browser page capture exported at
quality 85. No controls or media were composited. Images use labeled fictional
sample media from an isolated QA launch mode; sample selection is not offered
in the normal source chooser. The portrait's provenance stays in
`Fixtures/sample-image-notes.txt`.

The archive passes ZIP integrity, extracts to the same 38 app-file hashes with
strict signatures intact, and preserves all six executable permissions.

- Archive: `Setbeam-0.2.0-build40-macOS-arm64.zip`.
- SHA-256: `b5421edd2b6fa0fae547704653cd29ce51ab804f308831afc6997c42d0a7edcf`.
- Bytes: 64,679,595.
- [Public prerelease](https://github.com/austinpresley/setbeam/releases/tag/v0.2.0-build40).

The [private build and checksum](https://drive.google.com/drive/folders/1MFCJzffS3IT6YXZAv7VSnZD_w8l2Op2O) are delivered with remote
verification, delivery `20261112T011502Z--e0c1a9df5009`. All 41 current public documentation
references resolve locally. GitHub's Markdown API preserves the themed images,
build-40 links and details markup; local 900 px dark and 360 px light renders
load all four images without horizontal overflow. This is a local rendering of
GitHub-sanitized Markdown, not a physical phone check.

The prerelease is published at the tag above with two assets. An anonymous
HTTPS download matches SHA-256 `b5421edd2b6fa0fae547704653cd29ce51ab804f308831afc6997c42d0a7edcf` byte for byte.
Its checksum asset also matches the local file. Build 20's existing release
notes are preserved with a superseding-build notice. The README and setup guide
target build 40. GitHub Actions remains disabled; all tests/builds/packaging ran
locally.

## Qualification limits

This is an ad-hoc signed Apple Silicon developer prerelease, not notarized.
Hardware compatibility has not changed. Physical iOS/Safari and keyboard tests,
audible native output and A/V timing, the deferred two-hour transmitter run,
physical 4K devices, wider capture hardware, older macOS and Intel support
remain separate qualification. See [hardware tests](hardware-tests.md) and
[current status](status.md).
