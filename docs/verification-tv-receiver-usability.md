# Android TV setup and remote controls

Receiver 0.2.1, version code 5. Tested locally on November 19, 2026.

## What changed

- First launch opens **Choose a Mac**. Pressing OK on a discovered Mac pairs
  with its short address and asks to join under the saved TV name or
  **Setbeam TV**. The Mac operator still admits each share. The chooser
  keeps focus on the selected address through discovery refreshes.
- **Enter address** opens manual pairing. **TV setup** holds startup,
  permissions, licensing, and Forget this Mac. Down moves between the
  address, name, and Connect. Back closes the keyboard, then returns to
  the chooser. The launcher is reachable when the TV has its normal Home app.
- **TV options** puts six icon-led controls in one row. Sound is focused
  first during playback, and Chat is one move to the right. From a status
  card the menu starts on Mac settings. Back or 10 idle seconds closes it.
- Status cards show the next step in a short line of text. Connection
  diagnostics are available under **Info**. The sample label and privacy
  cover are still visible when applicable.

The layout follows Android TV guidance on visible focus, directional
navigation, and edge insets. [Android TV navigation](https://developer.android.com/design/ui/tv/guides/foundations/navigation-on-tv)
and [TV layouts](https://developer.android.com/training/tv/playback/compose/layouts).

## Local checks

- Android offline build passes 86 JVM tests. Lint reports zero errors and
  eight warnings. Debug and unsigned release APKs assemble.
- APK verification passes with the existing developer certificate, guarded
  configuration activity, overlay declaration, and boot receiver. The tested
  developer APK SHA-256 is
  `90c0cb66f43e955bfa63b9951a66b55f67eff532d245314f931936bbba0ab141`.
- `scripts/check.sh` passes on retry. It ran 126 Swift tests with one opt-in
  soak skipped, five Python checks, 59 Node checks, and every media stage.
  The keyframe check decoded 495 frames in seven seconds without errors.
  The short-address probe used its built-in substitute port because the TV
  fixture held port 80. The TV integration checks used port 80.
- All 102 local provisioning tests pass.
- The before and after images are captures from 0.2.0 and 0.2.1 on the same
  Google TV AVD. The options comparison uses the same moving Sample source
  at different points in its loop.

## Google TV emulator

The final run, `receiver/integration/artifacts/20261119-033216`, used the
API 36 Google TV emulator at a 1920 × 1080 interface size. All eight steps
passed against the real Setbeam gateway, short-address listener and MediaMTX.

- First launch, manual address validation, Back to the launcher, and real
  DNS-SD discovery. One OK on the advertised Mac created a pending request
  on the fixture through its short address, with zero media readers.
- Pending approval and return from Mac settings kept the same request.
  Admit started native playback. The Sample label stayed visible.
- The options strip responded to Left, Right, OK and Back. Playback continued
  beneath it. Input extended the idle timeout. The focused speaker icon
  was dark on the light focus tile.
- The remote muted and unmuted Sound, opened Chat, and toggled Pop-ups and
  Pointers. The pointer stayed visible beyond 25 seconds while the other
  viewer kept moving it.
- Hold covered the picture and stopped media without interrupting Mac
  monitoring. Resume restored playback. Removal stayed in effect across
  an app restart.

A separate fresh install used the remote to enter the fixture's IPv4
address. Connect reached the real Mac's pending queue as **Setbeam TV**
through the short address, with zero media readers. Evidence is in
`receiver/integration/artifacts/20261119-033856`.

Both runs uninstalled the test receiver, restored the launcher and display
settings, and verified that the Mac fixture's process group exited. The
owned emulator and private adb server stopped after the manual test.

## Issues found during verification

- The first `scripts/check.sh` stopped when MediaMTX tried to bind UDP
  port 55171, which was already in use. The retry passed the Pyro H stage.
- The first D-pad setup run opened the name keyboard when it tried to
  reach Connect. Android's text control was consuming a vertical arrow.
  The manual form now moves to the adjacent control on each vertical press
  outside the keyboard.
- One fresh run timed out waiting for **Choose a Mac**. The screenshot
  showed the screen, but Vision omitted the heading at 1080p. Static setup
  assertions now use Android's accessibility hierarchy. Playback continues
  to use screenshots.
- The first screenshot of focused Sound showed a white icon on the white
  focus tile. Toggle icons now use the same focus colors as their labels.

Physical onn hardware, HDMI output, cold startup, and a physical remote are
covered by the separate [hardware checklist](../receiver/docs/hardware-qualification.md).

## Delivery

[Developer APK, four before-and-after comparisons, and checksums](https://drive.google.com/drive/folders/19wy9eb2L5EVlIfT2-Dk4_wH6ggj7p-nu).
Remote verification completed for delivery `20261119T083949Z--04c21d4a3b46`.
