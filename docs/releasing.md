# Releasing Setbeam

Public builds are signed with Developer ID, notarized, stapled and shipped as a
disk image. Installed release builds update themselves through a signed Sparkle
feed. Developer builds from `scripts/build-app.sh` stay ad-hoc signed and never
check for updates.

## What must exist on the releasing Mac

| Item | Where | Check |
| --- | --- | --- |
| Developer ID Application certificate, team `G2R8798RLT` | login Keychain | `security find-identity -v -p codesigning` |
| notarytool profile `DFA` (override with `SETBEAM_NOTARY_PROFILE`) | login Keychain | `xcrun notarytool history --keychain-profile DFA` |
| Sparkle EdDSA private key, account `Setbeam` | login Keychain | `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account Setbeam -p` prints the `SUPublicEDKey` in `scripts/signing/update-configuration.plist` |
| `gh` signed in with push access | GitHub CLI | `gh auth status` |

The Sparkle private key signs every update. Losing it strands installed copies
on their current build, so keep it when moving Macs. Export a backup with
`generate_keys --account Setbeam -x <file>` to private storage, never into Git.
Notarization also needs the Apple Developer Program agreements to be current;
an expired agreement makes `notarytool` return HTTP 403.

## Stage, then publish

1. Write `docs/releases/<version>-build<N>.md`. Use absolute HTTPS links:
   Sparkle shows these notes inside the app.
2. Commit and push. The candidate must match a pushed commit.
3. `scripts/release.py --version 0.3.0 --build N --notes docs/releases/0.3.0-buildN.md --preflight`
   checks the identity, notary profile, update key, notes, tree and tag
   without building.
4. Run the same command without `--preflight`. It builds with the hardened
   runtime, audits every executable, notarizes and staples the app and the disk
   image, confirms that the image's app matches the notarized app file for file,
   and writes a signed `appcast.xml` that keeps the published feed's earlier
   items. Output goes to `dist/Setbeam-<version>-build<N>-release/`; nothing is
   published.
5. Install the staged disk image on a Mac and check the release as usual.
6. `scripts/publish-release.py dist/Setbeam-<version>-build<N>-release` creates
   the GitHub prerelease with the disk image and checksum, confirms an
   anonymous download matches, then pushes the feed to the `gh-pages` branch
   and waits until `https://austinpresley.github.io/setbeam/appcast.xml` serves it.
   The first publication also enables GitHub Pages for that branch.
   Rerunning resumes after a partial failure: an existing release is reused
   only if it is this candidate's prerelease, and an identical published feed
   counts as done. The feed is read from the `gh-pages` branch. Publishing
   stops if that feed changed after staging; stage again. A build number must
   be higher than every published one.
7. Point the README, setup guide and previous release page at the new build.

`SETBEAM_VERSION`, `SETBEAM_BUILD`, `SETBEAM_UPDATES=1` and
`SETBEAM_SIGNING_IDENTITY` select the release build inside `build-app.sh`;
`release.py` sets all four.

## Update behavior

The app checks daily by default; Settings → Updates turns that off. Installing
an update quits and reopens Setbeam through the normal Quit path, which stops
its owned processes. An update found by a scheduled check while sharing is
active waits as a menu item. Launches with command-line arguments, which every
integration and QA launch uses, and `SETBEAM_DISABLE_UPDATES=1` never contact
the feed.
