# Notarized install and signed updates, 0.3.0 build 41

Austin asked on 2026-11-14 to make the public download installable and
updatable. Implementation is on `release/notarized-updates`: `0e82763` adds
Sparkle and Developer ID signing, `808a829` adds release staging, publication
and the end-to-end update check. Later commits fix review findings, set
version 0.3.0 and document installation.

## Notarization and publication

Notarization first returned HTTP 403, "A required agreement is missing or has
expired," for profile `DFA`. Austin renewed the agreement; access returned at
04:31 after fifteen minute-by-minute retries had failed. A 0.2.0 candidate was
notarized and verified, then discarded unpublished when Austin chose 0.3.0.

The published candidate is commit `2273230`, tag `v0.3.0-build41`. Apple
accepted the app (`cb528165-60c8-40aa-933b-4db263bbc243`) and the disk image
(`f3b2c8a9-99e3-435c-8a14-107a20fa9579`) with no issues; both are stapled.
The app has 125 files, including the staple ticket. A quarantined copy of the
disk image and of its installed app are accepted by Gatekeeper as `Notarized
Developer ID`, and `syspolicy_check distribution` reports the app ready for
distribution. `check-update-install.py` passes starting from the notarized app
in the image.

`publish-release.py` created the prerelease, and an anonymous download matched
SHA-256 `e58e76f54a3d4f9c5c2835379f02de542c3efab51a1e2dbc448a687faa17dc57`
(66,546,792 bytes). It then pushed `gh-pages`, which made GitHub enable Pages
by itself. The explicit enable request returned `409 GitHub Pages is already
enabled.` and stopped the script. The script now accepts that response. The
rerun reused the matching release, found the feed already on the branch, and
confirmed the HTTPS feed matches. Separately, the live feed's signature verifies with
`sign_update --verify`, and its enclosure points to the published image.

Before publication, an independent GPT-6.1 Sol (xhigh) review found three
defects. Publishing could not resume after a partial failure. An older staged
candidate could drop newer feed items. Any HTTP error was read as a first
release. Staging now reads the feed from `gh-pages` and records its hash.
Publishing refuses a changed feed, requires increasing builds, and resumes a
matching release. Twelve release tests cover these rules.

## Signing

A Developer ID build of build 41 passes the release audit. All 11 executables
carry the hardened runtime, team `G2R8798RLT` and a secure timestamp, and link
only system libraries or the bundled Sparkle framework. That covers the app, five
helpers and five Sparkle binaries. The six Setbeam executables are arm64; Sparkle's
binaries are its universal release. The app has camera, audio-input and location
entitlements. ffmpeg has camera and audio-input, because it opens capture devices
itself. Strict deep verification passes. Gatekeeper rejects the build only as
`source=Unnotarized Developer ID`.

The release disk-image commands were exercised on that build. The signed
66,487,472-byte image verifies, mounts read-only with `Setbeam.app` and an
Applications link, and its app matches all 124 files. Gatekeeper rejects it
only as unnotarized. That was before notarization; see above for the
notarized result.

## Updates

`scripts/check-update-install.py` passes on the Developer ID build. It makes
"installed" build 9000 and "newer" build 9001 copies under the QA identifier
`app.setbeam.mac.updateqa`, serves a signed feed and EdDSA-signed disk image from
127.0.0.1, launches build 9000 without arguments and quits it normally. Sparkle
fetched the feed and image, required the feed signature, verified the image,
and replaced the copy with build 9001. All 124 files match and the strict
signature is valid. This exercises Sparkle's quiet install-on-Quit path. The
interactive update window and relaunch are Sparkle's standard UI and were not
clicked through.

The first run quit only after SIGTERM. Diagnosis: Quit returns `User canceled
(-128)` while the first-launch Permissions sheet is open. Preserved build 39
does the same, so this predates the update work. The check now starts from a
second-launch state and fails if normal Quit takes longer than 60 seconds; it passes.
This sheet behavior would also delay a Sparkle install on the first launch.

Native Settings → Updates was captured in dark and light from an argument-free
QA copy. It shows the version, automatic checks, Check Now and last-checked
time. The app menu reads "About Setbeam, Check for Updates…, Settings…".

The QA launches used separate bundle identifiers. Their preferences, caches and
temporary apps were removed afterward. The installed build 40 kept running
throughout. The Sparkle EdDSA key was created in the login Keychain under
account `Setbeam`; its public half is in
`scripts/signing/update-configuration.plist`.

## Automated checks

The complete `scripts/check.sh` passes twice with the hardened, Developer
ID-signed helpers and packaged fixtures. On `0e82763` it takes 730.25 seconds:
308 Swift tests and a 530-frame keyframe stage. The final run on `808a829`
takes 729.93 seconds: 309 Swift tests with one opt-in soak skipped, five
preview-timing and five release-feed Python cases, the Node viewer checks and
every media stage. Its 1,749 KB keyframe stage decodes 500 frames in seven
seconds without decoder errors.

## Not yet verified

A published build-to-build update, installation on a second Mac, and Sparkle's
interactive update window. Build 40 has no updater; its users, including
Austin's installed copy, install build 41 once by hand. Hardware qualification is
unchanged.
