# Clean TV playback verification, 2026-11-18

Austin requested a clean receiver picture and asked about standard Android TV
remote navigation. Receiver 0.1.1, version code 2, removes the persistent
session-name/Live badge. The session name is in optional diagnostics instead.
SAMPLE MEDIA remains visible for sample sources. The only Android changes
from the delivered 0.1.0 source manifest are MainActivity, its layout and the
version in app/build.gradle. Media, admission, discovery, startup and the
provisioning tool are unchanged.

Current controls are OK to toggle diagnostics during playback, direction pad
and OK for setup/status controls, Menu to open Mac settings when the remote
delivers it, and Back to return from setup. Main-screen Back uses Android's
normal behavior. System Home, volume and power are not intercepted. An OK menu
for connection info and Mac settings is a proposal, not implemented.

## Inputs and local checks

- Debug APK SHA-256: `8983bfa53ba564f516473a8a20c71a9eb7032a9541a5aa12bb93390c30a7b3e9`.
- Version 0.1.1, code 2, debuggable, signed with the existing developer certificate
  `2216d2895332572f9b98fe0fa8e46a2d5c9e94c13adb1e7de137edd3a37d1eb7`.
- Offline Android build: all 69 JVM tests pass, lint has zero errors and
  18 warnings, debug and unsigned release APKs assemble.
- `verify-apk --expect-signer` passes, including the protected CONFIGURE
  activity, requested overlay permission and boot receiver.
- Full local `scripts/check.sh`: exit 0, 310 Swift tests with one opt-in soak
  skipped, five Python preview cases, 59 Node cases and every media stage.
  The 1,749 KB keyframe stage decodes 497 frames in seven seconds without errors.
- `git diff --check` and integration Python compilation pass.

Logs are ignored under `build/logs/receiver-clean-playback-*`.

## Real-stack emulator check

Run `receiver/integration/artifacts/20261118-005447` uses the actual Mac
gateway, short-address listener and MediaRuntime, a rotating labeled sample,
and the dedicated Google TV API 36 emulator with a 1920x1080 interface.

All seven cases pass: preflight, configure, ask-pending, admit-live,
remote-controls, hold-resume and remove-terminal. The new remote-controls
case presses DPAD_CENTER to hide diagnostics, confirms no title/Live badge
and a retained SAMPLE MEDIA label, captures clean playback, then presses
DPAD_CENTER to show the session name in diagnostics and again to hide it.
Menu opens Mac settings; Back returns to advancing playback without changing
the pairing. The Mac reports fresh admitted playback. Hold and removal cover
the picture, and removal stays terminal after an app restart.

Actual clean capture: `03-clean-playback.png` in that run. The delivered copy
is `build/deliveries/tv-receiver-clean-playback/Clean-playback.png`.

Cleanup passes with no restore problems: the receiver is uninstalled, HOME
and settings match the captured baseline, the fixture's media process group
is empty, and the owned emulator and private adb server are stopped. Ports
80 and 5137 are free. The Mac app was not reinstalled or repackaged, and no
physical device, hosted CI, commit, push or public release was used.

These are software checks. Physical onn, sustained 4K30, real HDMI, cold power,
standby/CEC, Wi-Fi/mDNS and long unattended behavior retain the limits in the
[original verification](verification-tv-receiver.md).

## Private delivery

The [APK, clean screenshot, guide and checksums](https://drive.google.com/drive/folders/1YJU9i7r4Cs6I9ZcITo111TnkCr7PRyzs)
are delivered with remote verification under Setbeam / Clean playback,
delivery `20261118T055940Z--6479b0d0b9aa`. Local originals remain in
`build/deliveries/tv-receiver-clean-playback/`.
