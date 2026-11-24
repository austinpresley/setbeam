# Releasing Setbeam

Setbeam ships as a Developer ID-signed, notarized disk image for Apple Silicon
Macs. Sparkle verifies the signed feed and the disk image. Builds from
`scripts/build-app.sh` default to ad-hoc signing with updates off.

## Releasing Mac

Start from a clean checkout on an Apple Silicon Mac with macOS 14 or later.
Install Xcode with Swift 6, Python 3.12 or newer, `make`, `pkg-config`, `curl`,
and the GitHub CLI. Confirm that Xcode is selected and its first-launch setup
has finished. The first run resolves the pinned Swift package and downloads
checksum-pinned runtime source archives. It can start with empty `.build/`,
`build/`, `Vendor/`, and `dist/` directories.

| Item | Where | Check |
| --- | --- | --- |
| Developer ID Application certificate, team `G2R8798RLT` | Login Keychain | `security find-identity -v -p codesigning` |
| Notary profile `DFA`, overridable with `SETBEAM_NOTARY_PROFILE` | Login Keychain | `xcrun notarytool history --keychain-profile DFA` |
| Sparkle EdDSA private key, account `Setbeam` | Login Keychain | Preflight compares its public key with `scripts/signing/update-configuration.plist` |
| Release and Pages permissions on `austinpresley/setbeam` | GitHub CLI | `gh auth status --hostname github.com` |

Both URLs for `origin` must point to `austinpresley/setbeam`. Preflight checks
the source commit against branches advertised by that remote. Keep the Apple
Developer Program agreements current so notarization can submit.

## Stage and verify

1. Write and commit `docs/releases/<version>-build<N>.md`. Use absolute HTTPS
   links in notes shown by Sparkle. Push the source commit to an origin branch.
   Pick a build number higher than both the public feed and all builds already
   distributed privately. Build 43 was delivered privately and has the same
   bundle ID and update feed.
2. Run `scripts/release.py --version 0.3.1 --build N --notes docs/releases/0.3.1-buildN.md --preflight`.
   This checks the checkout, origin, tag, notes, and signing prerequisites.
3. Run the same command without `--preflight`. It checks the published build
   order before compiling, builds a fresh release app, audits the app, and
   notarizes and staples the app and DMG. The staging directory holds the
   signed appcast, checksums, manifest, and logs. Failed staging prints the
   private working directory. The notary submission ID is recorded before
   waiting, so an interrupted wait can be inspected with `notarytool info` or
   `notarytool wait`.
4. Run `scripts/publish-release.py dist/Setbeam-<version>-build<N>-release --verify-only`.
   This checks the exact disk image, mounted app, Git origin and tag, and
   appcast. Sparkle signatures are verified with the configured public key.
   This mode needs read access to origin and the local Apple verification tools.
5. Install the staged disk image on a test Mac. Exercise a quarantined clean
   install on macOS 14 and update a disposable copy of the previous build,
   including interactive installation and relaunch. Check update behavior
   with an active share and confirm that the owned helper group exits on Quit
   and Force Quit. Run all validation locally.

## Publish or resume

Run `scripts/publish-release.py dist/Setbeam-<version>-build<N>-release`.
The publisher verifies or creates the origin tag at the candidate commit. It
uploads missing assets to a draft prerelease and verifies their bytes before
making the release public. It verifies the DMG and checksum through anonymous
downloads before updating Pages. Verify the release page and update the
download links in the README and setup guide after Pages serves the feed.

If a run stops, rerun it with the same candidate. An existing draft or public
prerelease must have the expected tag, commit, notes, and assets. Completed
assets are verified and reused. A conflicting or incomplete asset requires
explicit inspection before retrying. If the exact feed is already on the
Pages branch, the publisher resumes with the Pages checks.

The push checks the old Pages commit advertised by Git and builds directly on
that commit. If the branch moves, stop using that appcast. To keep the same
verified DMG when the build is still newer than every published item, run
`scripts/publish-release.py CANDIDATE --refresh-feed NEW_CANDIDATE` with the
current Sparkle signing key. Verify and publish the new candidate directory.
The refresh signs a replacement appcast and retains the original DMG. If the
feed has reached that build number, stage a higher build with a fresh tag.
Older staging directories without the new provenance fields need restaging.

## Withdraw or repair an update

Keep the last good DMG, signed feed and candidate logs. To withdraw an offer,
remove the affected item from the current feed, sign and verify the edited
feed with the current Sparkle key, then publish it as a normal fast-forward
commit on the current Pages tip. Check that the HTTPS feed has updated before
altering the release assets. For installs already on the withdrawn build,
ship a higher-numbered repair built from the last good source plus any needed
data migration. Keep the same bundle ID and trusted signers and exercise the
repair on disposable copies.

Back up the Sparkle private key to private storage using
`generate_keys --account Setbeam -x <file>`. A Developer ID certificate
renewal within the same team keeps the configured Sparkle key. Verify the
upgrade from an installed old build with the replacement certificate before
publication. The standard scripts support one Sparkle public key per feed.
If the update key is lost, the Developer ID team changes, or a deliberate
Sparkle key rotation is needed, use a separately distributed, notarized
manual installer and a new feed for the new key. Keep the old feed and
installer available for recovery. Test the manual migration with a disposable
install before handing it to operators.

## Bundled runtime

The runtime cache verifies downloaded archives before installing them. Changes
to the pinned archives, AVFoundation patch, configure options, or recorded
toolchain invalidate the runtime. The rebuild starts from fresh extractions.
The app includes the lock, input and output hashes, patched build scripts,
license files, and relinking sources. The reader entry in the lock records
both the upstream MediaMTX file and the exact patched file shipped in Setbeam.
Update the bundled hash and change description when changing `reader.js`.

## Update behavior

The app checks daily by default. Settings → Updates turns that off. Installing
an update quits and reopens Setbeam through the normal Quit path, which stops
its owned processes. A scheduled update found during a share appears as a menu
item. Launches with command-line arguments or `SETBEAM_DISABLE_UPDATES=1`
skip the feed.
