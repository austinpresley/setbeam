# Floating preview refinement, build 33

Austin asked to remove the source name and replace the white Hold wash.
The remaining caption was the sample-media label. It is now removed from the
picture. The main window still visibly identifies sample media; the floating
preview retains its sample accessibility label and tooltip.

Confirmed Hold uses a 22% black veil and the existing 0.72 saturation treatment.
Pause and Play use the same dark material face and white glyph. No new controls
or text appear. Sample recovery no longer reserves space for the deleted
caption. The source receive, decoder, encoder and Hold commands are unchanged.
The design standard, guide and native reference images describe this revision.

## Native evidence

The release build passed the existing 16-check dark interaction matrix,
covering hover, local playback during Hold, pending Hold/Resume honesty,
failed-command retry, keyboard navigation/focus return, double-click/drag guards,
220-point sizing and closing without ending monitoring/sharing.

Light appearance passed Hold, Resume, Stop, private monitoring, the sample AX
label and the viewer panel. Both appearances were inspected as actual native
window captures. Two generated joined sessions provide the count and viewer
panel reference, not proof of remote playback or physical devices.

The removed sample-only recovery spacer and bottom padding are checked with
scoped sample-input failure injection at 220 and 340 points. Each capture is
paired with experience JSON. Only the isolated QA app's bundled encoder and
recorded descendant input PID are used. Permissions and the paused input are restored in a finally
block. The main app's preferences and runtime remain separate.

Evidence is under `build/preview-refinement/qa/`. The owned QA app and generated
focus fixture are shut down before the packaged timing suite.

## Iteration record

- The copied AX harness initially accepted only the previous QA bundle ID. Its
  PID guard was updated and recompiled for the new isolated bundle.
- A light-run assertion included the main window's intentional Sample media
  label. Native window captures and the floating sample AX label verify the
  requested caption removal. A second attempt used an incorrect Resume label;
  the corrected run passes. Earlier attempt logs remain separate.
- The recovery fixture initially selected both the supervisor and its child
  from the owned process tree. Its assertion stopped before changing anything.
  The final selector requires the exact bundled encoder executable. SIGTERM did
  not make that running sample unavailable; the final check pauses the exact
  owned input with SIGSTOP and restores SIGCONT in a finally block. This passes.
- Opus round 1 requested changes for recovery spacing and stale references/guide.
  The references and guide had been updated while that review was in flight;
  the second review receives stable hashes. Recovery spacing was then removed.
- The first full check was deliberately stopped for the recovery-layout fix.
  Only its recorded owned descendant process groups were terminated, and all
  exited. This partial run is not a passing result. The final build receives a
  fresh packaged check.

- The first final-source suite attempt failed the generated native live-timing
  assertion after 3.355 seconds. One frame duration was 116,411 microseconds,
  above the existing 100,000 microsecond limit. The failure and raw stage log
  remain under `build/preview-refinement/timing-attempt1-*`. Code and thresholds
  are unchanged for a clean full-suite rerun.

## Gates

Opus 5.5 high round 2 approves the small code/design delta. It checked all nine
frozen source/document/reference hashes. Its report separately identifies the
failed timing attempt and does not certify the newer run. Two optional
wording/wrapping corrections to the design standard are applied afterward and
recorded in `review/post-review-docs.patch`; no code or design rules change.
The complete local packaged `scripts/check.sh` rerun passes with exit 0 in
647.685 seconds. It used the built app's helpers and fixtures, with unchanged
source/test/build inputs throughout. Results include 262 Swift tests, 5 Python
cases, 55 viewer/pointer checks and every media stage. The large-keyframe probe
preserved 1,749 KB frames and decoded 497 frames in seven seconds with no decoder
errors. No test or threshold was weakened. The successful rerun does not explain
the earlier 116.411 ms frame-duration result; its evidence remains for follow-up.

Strict signatures and all six arm64/system-library-only executable audits pass.
The 39 receive/encode/bridge/probe/supervisor source files match the earlier
baseline. Layout sizes remain on the four-point scale, with no caption space.

The ZIP audit passes, and all 37 built, extracted and installed app files
match. The archive is `dist/Setbeam-0.2.0-build33.zip`, 63,946,296 bytes,
SHA-256 `154e793c90a2f323eac611fec9f0950d232f0d6fa1404f4f055b67172a022f1e`. It includes build notes, app hashes and a
161-input source manifest. The six executables are Apple Silicon and
ad-hoc signed. This is a developer build, not a notarized public release.

Installed at `/Users/apresley/Applications/Setbeam.app` and opened normally. The previous build is
preserved at `/Users/apresley/Applications/.Setbeam-before-preview-build33.app`. Post-install inspection verifies build 33 is
private with no open sheet. Private delivery completed with remote verification, receipt `20261107T015745Z--92f3877cfd45`.
[Download the app and native screenshots](https://drive.google.com/drive/folders/1MPL1Q87qsm1B1dmpOofm8hJ09hym9Ll2).
Local originals remain in `dist/` and `Assets/screenshots/`. No physical, audible-output, spoken VoiceOver,
real Capture One, trackpad pinch or older-macOS qualification is added by this
visual refinement. No hosted CI, commit, push or PR is run.
