# Notarized install and signed updates, build 41

Austin asked on 2026-11-14 to make the public download installable and
updatable. Implementation is on `release/notarized-updates`: `0e82763` adds
Sparkle and Developer ID signing, `808a829` adds release staging, publication
and the end-to-end update check. Nothing has been published.

## Blocker: Apple agreement

Every notarization request from the existing `DFA` profile, the one that
notarized PortPanic, returns:

```
Error: HTTP status code: 403. A required agreement is missing or has expired.
This request requires an in-effect agreement that has not been signed or has
expired. Ensure your team has signed the necessary legal agreements and that
they are not expired.
```

`scripts/release.py --preflight` reports only this problem. The Developer ID
identity, Setbeam update key, clean tree and unused tag all pass. Accepting the
current agreement in the Apple Developer account is an account-holder action.
No notarization, stapling or publication has run.

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
only as unnotarized. Notarization, stapling and Gatekeeper acceptance remain
unverified until the agreement is current.

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

Notarization and stapling, Gatekeeper acceptance after download with
quarantine, installation on a second Mac, GitHub Pages serving the feed, and an
update from one published build to the next. Build 40 has no updater; its users
install build 41 once by hand. Hardware qualification is unchanged.
