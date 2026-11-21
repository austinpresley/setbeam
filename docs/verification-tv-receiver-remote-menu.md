# TV remote menu verification, 2026-11-18

Austin approved an OK menu with Connection info and Mac settings, with Back
dismissing it and clean playback when closed. Receiver 0.1.2, version code 3,
implements it in the current activity, so video and audio keep playing beneath
the menu and diagnostics. Left/Right chooses an item and OK activates it.
Back closes the current overlay. With neither overlay open, Back retains
Android's normal navigation. On status cards, Receiver options opens the same
menu. Ask again retains its existing explicit action.

The menu hides after 10 seconds without input. Key events refresh the timeout
before focused buttons consume them. Focus stays within the menu while the
controller renders new status. The menu and diagnostics close when the
activity leaves the foreground. Sample labeling and non-live privacy covers
are unchanged. There are no new permissions or dependencies, and no media,
admission, discovery, startup-tool or Mac source changes.

## Frozen inputs

- Developer APK SHA-256: `504a4cf01cbe021495f3fa2e27f803c3295b0d9b66292d87c6b8ef37a472a079`.
- Version 0.1.2, code 3, debuggable, signed with the existing developer
  certificate `2216d2895332572f9b98fe0fa8e46a2d5c9e94c13adb1e7de137edd3a37d1eb7`.
- The 55-file Android source manifest follows the exact file set and format in
  [the initial verification](verification-tv-receiver.md). Its SHA-256 is
  `ef713c30b54f91e2404f5d9b6f805aed23f7c1071e1a66c797a38e426809ee1d`.

## Local results

- Offline Android build: 69 JVM tests pass, lint has zero errors and 18 warnings,
  and debug/unsigned release APKs assemble.
- `verify-apk --expect-signer` passes, including signature, guarded CONFIGURE
  activity, overlay declaration and boot receiver.
- Full local `scripts/check.sh`: exit 0, 310 Swift tests with one opt-in soak
  skipped, five Python preview cases, 59 Node cases and every media stage.
  The 1,749 KB keyframe stage decodes 487 frames in seven seconds without errors.
- Integration Python compilation and `git diff --check` pass.

Logs remain under ignored `build/logs/receiver-remote-menu-*`.

## Emulator interaction and real stream

Initial UI smoke testing failed with `Back did not return from setup`.
A diagnostic run required two Back presses while an input-method transition
was present. Setup now requests `stateHidden|adjustResize`, and the integration
check waits for the settings window to be visible rather than only resumed.
The corrected smoke run reports `mInputShown=false` and a single Back returning
to the receiver. A separate keyboard check confirms that OK on a text field
opens the keyboard and Back closes it while setup remains open.

Real-stack run `receiver/integration/artifacts/20261118-011327` passes all
seven cases: preflight, configure, ask-pending, admit-live, remote-controls,
hold-resume and remove-terminal. It uses the actual Mac gateway, short-address
listener and MediaRuntime, rotating labeled sample media, and Google TV API 36
with a 1920x1080 interface.

- Pending status-card options reach Mac settings with only OK and direction
  keys. Up/Down stays in the menu, periodic renders do not steal focus, and
  returning from settings preserves the same single pending request.
- During live playback, OK opens the menu with Connection info focused.
  The picture continues moving underneath. OK opens diagnostics containing
  the session name, and Back hides them.
- Back dismisses the menu without leaving MainActivity. Right then OK opens
  Mac settings; Back returns to fresh admitted playback on the same share.
- Navigation extends the timeout. Inactivity closes the menu and leaves
  clean playback in front. Optional Menu and Info shortcuts still work.
- The menu can open during Hold without exposing the picture. Hold/Resume
  and removal privacy checks pass, and removal stays terminal after restart.

Actual captures are `04-remote-menu.png`, `05-connection-info.png` and
`03-clean-playback.png` in that run. Delivery copies remain under
`build/deliveries/tv-receiver-remote-menu/`.

Cleanup has no restore problems: the receiver is uninstalled, HOME and settings
match the baseline, the fixture's process group is empty, and the owned emulator
and private adb server are stopped. No physical device, hosted CI, commit,
push, public release or Mac app installation was used. Boot tests were not
repeated for this UI change. Physical onn, sustained 4K30, HDMI, cold power,
standby/CEC, Wi-Fi/mDNS and long unattended behavior retain the limits in the
[original verification](verification-tv-receiver.md).

## Private delivery

The [APK, menu and clean captures, guide and checksums](https://drive.google.com/drive/folders/1MLyaxBlnTs1OUcN-TmhbKxoFhyXTjXhw)
are delivered with remote verification under Setbeam / TV remote menu,
delivery `20261118T062039Z--c8ebd63401e4`. Local originals remain under
`build/deliveries/tv-receiver-remote-menu/`.
