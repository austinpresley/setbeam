# Dedicated TV receiver verification, 2026-11-17

Austin requested an Opus 5.5 High team to build a native Google TV receiver
that can open after power-on and be admitted from the Mac. Implementation,
independent reviews, startup diagnosis and local integration used
`claude-opus-5-5`, effort `high`, through T3 delegated tasks.

The developer handoff contains Android Receiver 0.1.0, Mac build 42,
startup/status/restore tools, and setup and qualification guides. Nothing was
installed over Austin's working Mac app, committed, pushed or published.
Hosted CI remained disabled. Prior uncommitted documentation was preserved.

## Result and limits

The native receiver asks through the existing short address, waits for Mac
approval, receives read-only WebRTC media and follows Hold, removal and Stop.
Real-stack emulator checks pass native playback, refusal persistence, recovery,
live re-pairing, unattended waiting, a 4K surface with a 1080p interface, and
no-input playback after both graceful and hard Android reboots.

These are software results. No physical onn device is qualified. Sustained
4K30 decode, real HDMI output, graphics memory/composition, cold power cuts,
CEC/standby, Wi-Fi, mDNS reach, energy saver and long sessions remain open.
The emulator decoded 4K at about 10.7 fps with heavy drops; this is not evidence
that an onn can sustain 4K30. Its MediaCodec decoder reports hardware status,
but that is not a measurement of an onn hardware decoder.

See [the detailed integration record](verification-tv-receiver-integration.md)
and [physical checklist](../receiver/docs/hardware-qualification.md).

## Frozen handoff inputs

| Input | SHA-256 |
| --- | --- |
| Installable developer APK | `26689524ef065a5e475e07b7f2bb7c7e135f735682371e229e721b7ba86aa372` |
| Startup tool | `67169b759a74cc21a15cbd4a01cf2d4a398b52e4ecfe808eee5468fe3eb347e2` |
| Mac build 42 ZIP | `d670891f92d7daa94ea42f96082fddbb953ce781c4a5b135815c5b6719fbeec4` |
| Android source checksum manifest | `0fa7bf774a55ec8d87bca4eb319a06ee4d29bc907c44da519db0f54e5abd1847` |

The Android source manifest lists 55 files, relative to `receiver/android`:
all files beneath `app/src` and `gradle`, plus `app/build.gradle`,
`build.gradle`, `settings.gradle`, `gradle.properties`, `build.sh`, `gradlew`
and `gradlew.bat`. Lines are `sha256`, two spaces, and the relative POSIX
path, sorted by that path, with one final newline. This explicit manifest
replaces an earlier author aggregate whose exact construction was unclear.

The APK is debuggable and signed with the local Android debug certificate,
SHA-256 `2216d2895332572f9b98fe0fa8e46a2d5c9e94c13adb1e7de137edd3a37d1eb7`.
It is not a production store signing identity. Mac build 42 is ad-hoc signed
and not notarized. Dependency provenance, pinned verification metadata and
full notices are in [the receiver dependency record](../receiver/docs/native-dependencies.md)
and the APK's settings/assets.

## Local checks

| Check | Evidence |
| --- | --- |
| Full Mac `scripts/check.sh` | Exit 0; 310 Swift tests, one opt-in soak skipped; five Python preview tests; 59 Node checks; every actual-media stage passes |
| Large-keyframe media stage | 1,749 KB keyframes; 512 decoded frames in seven seconds; no decoder errors |
| Android build | 69 JVM tests pass; lint has zero errors and 18 informational warnings; debug and unsigned release APKs assemble |
| Startup tool | 102 tests pass on system Python 3.9.6 and Python 3.14.7, including real SIGKILL/interruption regressions against fake adb |
| APK | Signature scheme v2 verifies; package/version, guarded CONFIGURE handler, boot receiver and overlay permission verified |
| Mac package | Six arm64 executables pass strict signatures and a positive system-library allowlist; all 38 extracted files match; executable permissions and extracted app signature pass |
| Git hygiene | `git diff --check` passes; no generated APK, Gradle/Swift build output, keystore or runtime receipt is exposed as untracked source |

Logs remain ignored under `build/logs/receiver-*` and the integration artifact
directories. No physical test is inferred from these checks.

## Review and correction record

- Mac discovery passed an independent Opus review with no P0/P1/P2. The TXT
  record contains only public routing/version/identity hints; publishing
  follows actual short-address readiness and interface eligibility.
- Native review corrected UI-sized 4K buffers, visible re-pairing, idle
  readiness, storage and Keystore failures, refusal eviction, discovery
  ordering, old-peer isolation, late callbacks, HTTPS scheme changes,
  rendering privacy and pushed-event coverage. Later reviews approved the
  rendering lock/cover and accurate pinned-renderer limits.
- Real-stack testing then found the stale pending card after the Mac quit.
  Its correction preserves the pass, shows lost contact, resumes the same
  share without another ask, and does not spend the retry budget offline.
  Independent review approved the 69-test controller. The final APK differs
  only by correcting the setup help flag to `--allow-background-start`.
- Startup reviews corrected repeated-install restore order, profile/device
  binding, stale restore baselines, intervening operator changes, exact
  CONFIGURE protection, failed probes, unresolved receipts and interrupted
  mutations. The exact Google TV unused-app-op response and explicit disk
  saves were corrected after actual reboot tests. Final review approves
  tool `67169b75` with no P0/P1/P2.
- An unsupported or persistently failing app-op disk save remains a visible
  failure; a receipt with unresolved owned changes blocks further provision.
  No claim is made that this can repair every firmware or storage failure.

Earlier failed assertions and harness/environment corrections remain in the
integration record. An initial packaging equality check also failed twice
with `AssertionError: ffmpeg`: changing a linker signature changes binary
layout, so raw or signature-stripped byte comparison was the wrong check.
Re-signing temporary copies of the checked Vendor helpers with the same app
identifiers produced byte-identical packaged helpers. The actual executable
signatures and positive system-library audits pass.

## Startup evidence and cleanup

Google TV's priority-2 stock launcher prevented HOME replacement on the
emulator. The tool detected it, returned exit 3 and restored the prior Home
choice. The successful path was the receiver's own `BOOT_COMPLETED` launch
with the operator-authorized overlay app-op, saved explicitly by the tool.

On final inputs, changed boot IDs, an `allow` app-op after boot,
`BAL_ALLOW_SAW_PERMISSION`, the receiver in front, moving pictures and fresh
Mac playback reports all confirm no-input playback after graceful and hard
reboots. Restoration returned the app-op to `default`; HOME stayed unchanged.
This does not establish physical power-on or standby behavior.

The test receiver was uninstalled. The test AVD's Home and settings match its
baseline, owned fixtures and media processes exited, the emulator and private
adb server stopped, and ports 80 and 5137 were free. Ignored artifacts are
retained for inspection; no user application or physical device was modified.

## Private delivery

Seven files were delivered through Austin Deliveries / Setbeam / TV Receiver:
the APK, Mac build 42 ZIP, setup/evidence archive, start guide, two checksum
files and the post-reboot capture. Delivery
`20261118T013155Z--de8577d659ae` reports `delivered` with remote verification.
[Open the delivered handoff](https://drive.google.com/drive/folders/1K4MjWoAgnKxLqbuWKiPIvO2yv7uibVNn).
