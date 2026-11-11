# Source chooser, 2026-11-04

Austin requested the last confirmed source first, a cleaner name, separate source categories, removal of Sample feed from the chooser, application groups with larger icons, no repeated app name beneath every window, and app names in place of untitled labels. He requested sol-loop on high.

## UX

- Surface and flow: the existing Choose a source sheet, opened with Command-O or Choose Source, selects one source or closes with Done or Escape. Transmitter cards keep their existing inline guides.
- Order: Recent source, Displays, Cameras, Application windows, Wireless transmitters. Advertised network streams keep their own conditional section. Recent source uses the existing picture-confirmed save gate and restore action. Saved sample sources are omitted from the chooser as well.
- Application windows: group by bundle identifier, with application name as the fallback when it is absent. Sort groups by application name and their windows by the existing title/number order. Each group has one 40 pt application icon and name. Cards retain previews, window titles, tooltips, and exact window identity. Only the monitored window has the Current source caption.
- Labels: blank titles and the exact generic titles Untitled and Untitled window use the application name. Numbered document titles such as Untitled 2 remain distinct. Source labels avoid repeating the application name when it is also the title.
- Layout: the sheet is 640 pt wide with 24 pt margins. Source rows use 48 pt artwork. Window thumbnails fit their grid cells at their original aspect ratio. Existing no-permission, loading, list-failure, and empty-window messages remain. Cameras have inline connection guidance when none are detected.
- Access: window buttons retain their application name in accessible labels and help. Group headings expose the application name; decorative icons are hidden from accessibility.

## Scope and baseline

The checkout already had extensive uncommitted work, including transmitter guides and later Advanced settings in SettingsViews.swift. Those changes are preserved. Task-only before copies and the review patch are under ignored `build/source-chooser/`. Git merge-base with origin/main after fetch was `218e8c51f05249e238d3ceaa5ec304586937f18f`. The task patch, rather than all existing changes since that base, defines this review.

No media pipeline, capture selection, restore identity, permissions, hardware compatibility, or hosted workflow changed. Tests and native fixture checks run locally on Austin's Mac. Physical hardware and spoken VoiceOver qualification are separate.

## Validation

- Release `scripts/build-app.sh` passed, producing version 0.2.0 build 27. Existing warnings in AccsoonDiscovery.swift, MediaRuntime.swift, and the probe entry point remain outside this change; no new warning comes from the changed app files. The project keeps its existing Swift 5 language mode.
- All 217 Swift tests passed, 153 core and 64 app. The new cases cover application grouping across process IDs, fallback grouping without bundle identifiers, stable ordering, complete identity preservation, and untitled labels. The existing preview test now expects its fixture application name.
- The first two full-check attempts stopped at that test's old `Untitled window` expectation. The first replacement missed the indexed expression; the second compile had already consumed the old assertion before it was corrected. The final run uses the corrected source. The full script later stopped at the known format-cadence assertion: expected 30 fps, measured 30.000004109589607 fps, largest interval 0.050067000000000306 s. The exact 50.067 ms failure is already documented for earlier builds in verification-pyro-h-2026-10-29.md and verification-shared-pointers-2026-11-01.md. The relevant media code and probe are unchanged by this task. The unchanged packaged-runtime rerun passed all five format checks. The remaining nine frame-rate checks and large-keyframe check then passed against packaged helpers. The keyframe probe delivered 1,750 KB keyframes and decoded 509 frames in seven seconds with no decoder errors. The original full script did not exit successfully; it stopped at the known assertion. Coverage after that stop was completed with these focused probes. Earlier stages passed the native bridge, 43 viewer checks, 12 pointer checks, all 217 Swift tests, and the Pyro H, general media, source recovery, viewer access, local address, short address, and source-safety probes. No threshold or media behavior was changed.
- Native QA used an isolated preferences suite and the release app, with four generated fixture windows. No actual desktop or other app window was shared. Selecting the untitled fixture opened its private preview with source name Chooser Fixtures. The saved source appeared first after picture confirmation and restored that exact window after relaunch, without starting sharing. A real click selected it; Command-O opened the chooser and Escape closed it. The Pyro H guide opened from its existing card. Quit with the chooser closed cleaned up the owned media children.
- The captured native windows were inspected in light and dark. Recent source is a full-width first row. App groups have a 40 pt icon/name header; cards fit their previews, show two-line titles, omit app captions, and retain Current source on the selected card. Wireless cards remain below windows. Native AX geometry checks passed for section order, common leading edges, group heading height, all four window cards, 8 pt grid gaps, and card containment. This existing app has no template grid-probe workflow; the task's AX geometry checks supply actual rendered frames instead.
- Screenshots under `build/source-chooser/shots/`: `recent-light.png`, `recent-dark.png`, `windows-light.png`, `windows-dark.png`, `wireless-light.png`, and `wireless-dark.png`. Recent-source captures are cropped above live display thumbnails. The other images contain only generated fixture previews. The fixture icon is generic; real application groups use their running application's icon.
- No physical camera, capture device, transmitter, second device, or spoken VoiceOver test was performed.

## Sol review

One GPT-6.1 Sol reviewer on provider codex, `reasoningEffort: high`, `serviceTier: default`. Round 1 approved with no findings. No sub-reviewers, edits, or additional checks were started by the reviewer. It independently read the exact task patch, before copies, current files, surrounding callers, unit results, and saved screenshots. It noted that the full media check had not yet completed.

- Ledger: no findings to fix or decline. Sol changed nothing.
- Task diff before and after review: 7 files, +159/−79. Documentation is additional. No behavior changed after approval.
- Usage was not exposed by the orchestration tools.
- Task ID: `node:delegated-task:command%3Amcp%3A4eeefad2-4071-4ec7-9644-39dcaf309fc3%3Adelegate-task%3Asetbeam-source-chooser-sol-r1-20261104`.
- No commit, push, PR, or hosted workflow ran. Existing uncommitted work is preserved.

## Packaging

The archive candidate contains the release app with all 37 app files matching the fresh build. Strict recursive signatures pass. All six executables are arm64 and link only system libraries. The app does not need Homebrew. The source manifest covers 135 inputs. Executable SHA-256: `ec102905cd718c24be85ecd21f7cdc51ee06bfae124804e88b0704fe1bd9884f`.

Build 27 is installed at `~/Applications/Setbeam.app`. The previous app is preserved at `~/Applications/.Setbeam-before-source-chooser-build27.app`. All 37 installed files match the archived and freshly built app, and strict signatures pass. The 135 source-input hashes remain unchanged after Sol approval. ZIP integrity and extracted signatures pass.

Archive: `dist/Setbeam-0.2.0-build27.zip`, SHA-256 `8d68c8d434df9667cf3d286bd9ce1f9445f0501d1a977658cd904efb45a1ea3a`.

Private Austin Deliveries upload completed with remote verification under Setbeam / Source chooser. Receipt `20261104T055442Z--206db79bf2cf` reports `state: delivered` and includes the archive and light-mode screenshot. [Open delivery](https://drive.google.com/drive/folders/15bC6ys8rOHxqxAj9mMzpSii2TnlpOLsQ). Local receipt: `build/source-chooser/delivery.json`.
