# Receiver startup and provisioning

This note covers how a dedicated Android TV or Google TV device, such as an
onn 4K box, is prepared to open Setbeam Receiver by itself, and the Mac-side
tool that does it. Physical results belong in
[hardware-qualification.md](hardware-qualification.md). Nothing here is
qualified on an onn device yet.

Goal: after one-time setup, the TV powers on, Setbeam Receiver opens full
screen, asks the paired Mac through the short address, waits for the
operator's Admit, plays, and reconnects. Nobody touches the remote after setup.

## What Android allows

**HOME priority wins over the user's choice.** When more than one activity
handles `MAIN` + `HOME`, AOSP's `ResolveIntentHelper.chooseBestActivity`
returns the first one outright if its priority differs from the second. Only
when the top priorities tie does the saved preference (the HOME role holder)
decide. Android caps every activity intent-filter priority at 0 for apps that
are not privileged system apps, so Setbeam Receiver's HOME activity is always
priority 0.
Sources: [`ResolveIntentHelper.java`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/pm/ResolveIntentHelper.java)
lines 153-185 and [`ComponentResolver.adjustPriority`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/pm/resolution/ComponentResolver.java)
("non-privileged applications can never define a priority >0"), both on
`main` as read 2026-11-17. Vendor builds may differ, and the tool measures the
real device.

**Consequence for Google TV.** On Google TV builds, the stock launcher
(`com.google.android.apps.tv.launcherx`) and setup recovery
(`com.google.android.tungsten.setupwraith`) can declare higher HOME priorities.
One first-hand report from a Sony BRAVIA running Android TV 12 lists priorities
2 and 1 against Projectivy's 0. In that report, `set-home-activity` alone did
not change HOME; only disabling both Google packages did
([Projectivy issue #158, 2026-11-05 comment](https://github.com/spocky/miproja1/issues/158)).
If an onn build declares the same priorities, making Setbeam the HOME role
holder has no effect there. The tool measures this on the actual device rather
than assuming it either way.

**Setting HOME by shell.** `cmd package set-home-activity` calls
`RoleManager.addRoleHolderAsUser(ROLE_HOME, …)` and prints `Success`
([`PackageManagerShellCommand.java`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/pm/PackageManagerShellCommand.java)).
`cmd role get-role-holders` exists from Android 14
(`android-14.0.0_r1` in `packages/modules/Permission`, absent at
`android-12.0.0_r1` and `android-13.0.0_r1`). On older builds the exact HOME
role holder cannot be read. `cmd shortcut get-default-launcher` names a
launcher even when no explicit holder exists, so it can't support an exact
restore. **The tool therefore refuses HOME changes below Android 14 (SDK 34).**
There, `status` shows the shortcut-service launcher labelled "approximate",
and `provision --no-set-home` still installs and configures the receiver. The
onn boxes launched on Android TV 12 and have reportedly been updated to 14.
`status` shows which one a given box runs.

**Starting from the background.** On Android 10 and later, an app can start an
activity from the background only under listed exceptions. One of them is a
user-granted `SYSTEM_ALERT_WINDOW`. A blocked start fails silently, with only
a log entry
([Android Developers, *Restrictions on starting activities from the background*](https://developer.android.com/guide/components/activities/background-starts),
last updated 2026-05-18). A receiver that starts itself from
`BOOT_COMPLETED` therefore needs that app-op. It also depends on the vendor
build delivering `BOOT_COMPLETED` to a sideloaded app. That is unverified on
onn.

**Device owner provisioning is not assumed.** Android Enterprise
device-owner or kiosk provisioning normally needs a factory-reset device and
vendor support. This work does not depend on it, and the tool never
factory-resets.

## onn models and firmware: known and unknown

| Model (marketing name) | Launch OS | Later OS | Evidence | Startup status |
| --- | --- | --- | --- | --- |
| onn. Google TV 4K Streaming Box (2023) | Android TV 12 | Android TV 14 rollout reported 2025 | [AFTVnews](https://www.aftvnews.com/android-tv-14-update-arrives-for-the-onn-4k-and-onn-4k-pro/), [Cord Cutters News](https://cordcuttersnews.com/walmarts-budget-onn-4k-google-tv-boxes-get-surprise-android-tv-14-update/) | Unmeasured |
| onn. 4K Pro (2024) | Android TV 12 | Android TV 14 build URO1.250103.029.A1, re-issued as .C1 after reported bricking | [9to5Google](https://9to5google.com/2025/06/03/walmart-onn-4k-pro-android-14-google-tv/), [Android Authority](https://www.androidauthority.com/walmart-onn-android-14-update-fix-3573835/) | Unmeasured. One Projectivy user could not enable Projectivy's accessibility service on a newer 4K Pro ([#489](https://github.com/spocky/miproja1/issues/489)). Another saw the stock launcher for about 3 s when leaving ambient mode ([#575](https://github.com/spocky/miproja1/issues/575)) |
| onn. 4K Plus | Android TV 14 (user report, patch 2025-04-01) | Unknown | [Projectivy #315](https://github.com/spocky/miproja1/issues/315) | Unmeasured |
| 2026 onn 4K Pro revision | Unknown | Unknown | [Lon.TV review](https://blog.lon.tv/?p=4925) (not read in full) | Unmeasured |

Unknown until the actual device is attached: the exact model string,
`ro.build.fingerprint`, security patch, launcherx and setupwraith HOME
priorities, whether `BOOT_COMPLETED` reaches a sideloaded app, and whether
HDMI-CEC wake starts a cold boot or resumes from standby. `status` records all
the software facts, and the qualification sheet records the rest. Model names
and firmware above come from press and user reports, not Walmart or Google
documentation.

## Startup paths, in order

1. **Setbeam Receiver as HOME.** The tool requests the HOME role and then
   requires `resolve-activity` for `MAIN`/`HOME` to return
   `com.setbeam.receiver/.MainActivity` before reporting HOME as verified.
   If a higher-priority system launcher still wins, the tool reports
   `HOME not available on this OS build` (exit 3), names the blocking
   activities and their priorities, and rolls the role back. Use
   `--keep-unhonored-home` to keep the role anyway. The rollback is verified.
   With `--home-key-probe`, it first opens Settings (`am start -a
   android.settings.SETTINGS`) and checks that another screen is in front.
   It then sends one `KEYCODE_HOME` press and requires the front activity to
   move to Setbeam Receiver. If Settings can't be brought forward, the probe
   reports **inconclusive**, not success. The resolution-verified role is then
   kept, exit 0, and the run says so. If HOME leaves another screen in front,
   the probe fails. A role changed by this run, or by an open recorded change,
   is then rolled back with the same verified rollback as an unhonored HOME,
   and the run exits 3. `--keep-unhonored-home` keeps it instead. A verified
   resolution or a passed probe is still not a cold-boot result.
2. **Receiver's own boot start.** If the receiver build declares a
   `BOOT_COMPLETED` receiver and requests `SYSTEM_ALERT_WINDOW`,
   `provision --allow-background-start` grants that one app-op to
   `com.setbeam.receiver` only. The current app has both, and its manifest
   says it never draws over other apps. The prior package mode is recorded and
   restored. If that mode can't be read exactly, the tool refuses before any
   change. That covers failed or unrecognized `appops` output, and a `Uid mode`
   line, which would override the package mode. Three output forms are
   accepted, and any other is refused:
   - exactly `No operations.`, read as `default`;
   - exactly two lines, `No operations.` then `Default mode: <mode>` with a
     known mode, read as that mode. QA saw `No operations.` /
     `Default mode: default` on the Google TV API 36 emulator for an op the
     package had never used;
   - one `SYSTEM_ALERT_WINDOW: <mode>` package line.

   A fresh install first checks that the same parser reads `com.android.shell`.
   This is opt-in. Whether it survives an onn cold boot is a physical test.

   **Saving the grant.** AOSP `AppOpsService` doesn't write package-mode
   changes to disk right away: about 10 s later on Android 16, and 30 minutes
   on `android-14.0.0_r1`. A hard reboot (`adb reboot`, power loss) may skip
   the shutdown write. In QA, `BOOT_COMPLETED` arrived, but
   `canDrawOverlays()` was false after a reboot taken seconds after the grant.
   The working hypothesis is that the grant was never saved. QA will confirm
   it with a controlled reboot.
   - **After the grant:** once `appops set … allow` reads back as `allow`, the
     tool runs `appops write-settings`. It requires exit 0 and the exact
     output `Current settings written.` (AOSP `AppOpsService`, `main`,
     Android 14 and 12), then checks that the mode still reads `allow`.
   - **Scope:** this saves all current app-op state for the device and changes
     no mode, so it has nothing of its own to restore. It needs the same
     `MANAGE_APP_OPS_MODES` shell authority as `appops set`.
   - **Already `allow`:** the save still runs, because a grant made shortly
     before may not be on disk yet. That includes a grant this tool didn't
     make, in which case nothing new is recorded.
   - **If the save fails** (refused, unsupported, or unexpected output):
     - **For a change the tool made:** it stays `flush-pending`, the receipt is
       marked `needs-restore`, provisioning is blocked and the run exits 5.
       Setup is never reported as done.
     - **For an `allow` the tool didn't set:** the run exits 4 and reports that
       setup isn't confirmed. Nothing is recorded, because nothing was
       changed.

   Only a real reboot proves the mode persists. The qualification sheet keeps
   that row open.
3. **Projectivy Launcher, manual fallback.** This uses a third-party
   launcher. The tool never installs it. If Austin chooses it:
   install *Projectivy Launcher* from the Play Store on the TV, open it, and
   enable its accessibility service and **Override current launcher**. Then set
   **Autostart app on boot** to Setbeam Receiver, with the optional start delay,
   and optionally run it after standby. Projectivy's release notes add the
   boot delay and make the accessibility service mandatory for "start app
   upon resuming from standby" in 4.70 (2026-06-26). They describe overriding
   through the accessibility service or a launcher manager rather than
   disabling Google's launcher, because the Profile Picker lives in it
   (4.64, 2025-07-04)
   ([releases](https://github.com/spocky/miproja1/releases)).
   Known risks:
   - Users report that the accessibility service is turned off after reboot on
     some TCL and Android TV 12/14 builds ([#415](https://github.com/spocky/miproja1/issues/415), [#489](https://github.com/spocky/miproja1/issues/489)).
   - The press reports that a 2026 Google TV update broke the override for
     some users ([Android Authority](https://www.androidauthority.com/google-tv-update-blocks-projectivy-override-3649445)).
   - Android TV 14 restricts accessibility for some sideloaded installs ([#315](https://github.com/spocky/miproja1/issues/315) comments).
   Treat every Projectivy step as a physical test item.
4. **Manual.** Open Setbeam Receiver from the apps row. Pairing and admission
   are unchanged.

**Out of bounds:** disabling or uninstalling `launcherx` or
`setupwraith` with `pm disable-user`. Community guides do this
([#158](https://github.com/spocky/miproja1/issues/158)), but Projectivy's
developer notes that it removes Google's Profile Picker, Free TV panel and
Google Home panel ([#315](https://github.com/spocky/miproja1/issues/315)). The
tool also never
roots, flashes, factory-resets or reboots the device. It never edits
`settings`, and it never reads app data.

## One-time Mac setup

1. Install Android SDK Platform-Tools for `adb`. Build-Tools are needed only for
   `--apk` verification, which uses `aapt2`. Android Studio's SDK Manager puts
   them under `~/Library/Android/sdk`, and the tool looks there first.
   `ANDROID_HOME`, `SETBEAM_ADB`/`SETBEAM_AAPT2` and `--adb`/`--aapt2` override
   that. Homebrew is not required. The tool needs only the system `python3`
   (3.9 or later) and the standard library. It does not ship inside the Mac
   app.
2. On the TV, enable Developer options. On Google TV builds this is usually
   Settings › System › About, then select **Android TV OS build** seven
   times. Then turn on **USB debugging** or **Wireless debugging**. Record
   which toggle allows network adb on the actual onn build. That is
   unverified here.
3. Connect over the network. Use `adb connect <tv-ip>:5555`, or for wireless
   debugging, `adb pair <ip>:<pair-port>` followed by `adb connect`.
   Accept the **Allow debugging** prompt on the TV, and choose "always allow"
   only on a network you trust
   ([Android Developers, adb](https://developer.android.com/tools/adb),
   updated 2026-09-25). Whether the onn's USB-C power port carries adb is
   unverified, so use the network.
4. Run `receiver/scripts/setbeam-receiver devices` and copy the TV's serial,
   either `IP:port` or the `adb-…._adb-tls-connect._tcp` name.

The adb server that `adb` starts keeps running after the tool exits. Stop it
with `adb kill-server` when you're done. Turn off USB and wireless debugging on
the TV after qualification if the device will sit on an untrusted network.

## Using the tool

```
receiver/scripts/setbeam-receiver status    --serial SERIAL [--json]
receiver/scripts/setbeam-receiver verify-apk --apk Setbeam-Receiver.apk
receiver/scripts/setbeam-receiver provision --serial SERIAL \
    --host http://setbeam.local/ --name "Stage TV" [--apk FILE] [--apply]
receiver/scripts/setbeam-receiver restore   --serial SERIAL [--uninstall-receiver] [--apply]
```

- `provision` and `restore` are dry runs unless `--apply` is given. A dry
  run reads the device and prints every command it would run.
- `--serial` is required on every device command. `ANDROID_SERIAL` is
  removed from adb's environment, and every device command passes
  `-s SERIAL`. A missing, `unauthorized` or `offline` serial is refused.
  So is a device without the leanback TV feature, unless
  `--allow-non-tv` is given for an emulator.
- `--host` must be the short address itself: `http://` + a name or IPv4
  address + optional `:80` + `/`. Viewing links, `/s/…` paths, user info,
  queries, fragments, `https`, other ports and loopback addresses are
  refused, and the refused value is never printed. See the protocol in
  `docs/receiver-protocol.md`.
  - **HTTP only, deliberately.** The current Mac app serves the short address
    only as plain HTTP on port 80. The receiver app's `HostConfig` also
    accepts `https://` and other ports, for a possible future HTTPS short
    address. No Mac build serves that yet, and it is not qualified, so the
    tool refuses it rather than provision a receiver that can't connect.
    `docs/research/viewer-transport-protection-2026-11-14.md` covers the HTTPS
    design, which is not decided.
- `--name` is the receiver's label: at most 40 characters, with no control or
  invisible formatting characters. The operator sees it as an unverified
  label.
- `--apk` is checked on the Mac with `aapt2` before any device command. It
  must have package `com.setbeam.receiver`, `MainActivity` as the
  `LEANBACK_LAUNCHER` activity, `MainActivity` exported with
  `MAIN`+`HOME`+`DEFAULT`, and an exported `com.setbeam.receiver.CONFIGURE`
  **activity guarded by `android:permission="android.permission.WRITE_SECURE_SETTINGS"`**.
  The current app's `ProvisionActivity` is that activity.
  - **Every** exported CONFIGURE handler must require that permission. If any
    exported activity, `activity-alias` or receiver without it handles
    CONFIGURE, the APK is refused, even when a guarded activity also exists.
    Non-exported handlers can't be reached by other apps, so they are allowed.
  - Activities and receivers without their own `android:permission` take the
    `<application>` permission.
  - An `activity-alias` has **only its own** permission. AOSP
    `ParsedActivityUtils` says: "An alias will override permissions to allow
    referencing an Activity through its alias without needing the original
    permission. If an alias needs the same permission, it must be
    re-declared." So an unguarded alias of `ProvisionActivity` is refused.

  The adb shell holds `WRITE_SECURE_SETTINGS`, but ordinary apps can't, so
  other apps on the TV can't repoint the receiver.
  Downgrades are refused. When Java and `apksigner` are available, the signer
  digest is recorded, and `--expect-signer` can require it.
- Without `--apk`, the installed receiver is checked on the device instead.
  `cmd package query-activities` and `query-receivers` for CONFIGURE, without
  `--brief`, dump each handler's `ActivityInfo` `name=`, `packageName=`,
  `exported=` and `permission=` (AOSP `ActivityInfo.dump`). The same rule
  applies: one guarded exported activity, and no unguarded exported handler.
  Otherwise the run is refused before any change. Alias resolution on the
  device comes from Android itself.
- Configuration is sent as an explicit intent to that activity:
  `am start -W -n com.setbeam.receiver/…ProvisionActivity -a com.setbeam.receiver.CONFIGURE --es setbeam_host … --es setbeam_name …`.
  Each remote argument is quoted separately for the device shell. The tool
  reads the receiver's own log (`logcat -d -v epoch -s SetbeamProvision`,
  only entries after the device clock reading taken just before the start).
  It records the result as:
  - **accepted**: the app logged `Pairing accepted for <same host>`.
  - **refused**: the app logged `Pairing refused`. The run stops.
  - **delivered**: the intent arrived but no acceptance was observed. Check the
    TV screen (qualification step S5).

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Done. A `--home-key-probe` may still report inconclusive |
| `1` | Failure |
| `2` | Refused: input, APK, device type, placeholder serial, receipt location or identity, another Android user, unreadable HOME holder or overlay mode, a later HOME or overlay change by someone else, or a receipt that needs restore |
| `3` | HOME not available on this OS build, or the HOME key probe failed. A role this run changed is rolled back and verified first |
| `4` | Device or adb failure, or the receiver refused the configuration |
| `5` | A rollback or restore could not be verified. The receipt is kept; run `restore --apply` |

## Receipts and restore

Before the first change, `provision --apply` writes a receipt to
`~/Library/Application Support/Setbeam/receiver-provisioning/receiver-<hash>.json`
(mode 0600). Set `--receipt-dir` or `SETBEAM_RECEIPT_DIR` to use another
location. A directory inside this repository is refused unless Git ignores it.
The receipt is keyed by a hash of `ro.serialno`, so it follows the device when
its adb address changes. A missing serial, or a factory placeholder such as
`0123456789ABCDEF`, `unknown` or one repeated character, is refused before
any change, because it can't tell two boxes apart. The receipt holds:

- the device's identity: manufacturer, model, device, fingerprint, security
  patch, SDK and the **Android user (profile)**. The serial is stored only as a
  SHA-256 hash.
- the original HOME candidates, the exact role holders (`cmd role`, Android
  14+) and the resolved activity.
- whether the receiver was already installed, and its version.
- the original overlay app-op.
- each change, with its state:
  - **install**: `pending`, `done`, `failed`, then `restored`. It records the
    Android `user` it was installed for, whether this tool installed it there
    (`fresh`), and `other_users_before`, the profiles that already had the
    receiver. Later `--apk` runs are added to the first install's `updates`
    list instead of creating another install change.
  - **configure**: `accepted`, `delivered` or `refused`. This change can't be
    reversed.
  - **HOME and overlay**: `pending`, `done`, `rolled-back`, then `restored`.
    Either can be `superseded`. A HOME rollback that can't be verified is
    marked `rollback-failed`. Only restore resolves it; provisioning never
    supersedes or rebases it.
  - **In flight:** before sending a HOME rollback command, the tool saves
    `rolling-back`. Before any restore command (overlay, HOME or uninstall), it
    saves `restoring`. Only verified success replaces these markers, so a run
    killed after the command but before the check leaves the receipt
    unresolved. The next `restore` resumes it: it re-reads the device, marks
    the change restored if the command took effect, and otherwise repeats the
    command under the usual `--force` rules. `flush-pending` marks an overlay
    grant whose save hasn't been confirmed. Restore treats it like any other
    open overlay change.

**What a re-run keeps.** The receipt's top-level `before` is the first run's
snapshot, kept as history only. Each HOME change records its own `before`,
read from the device immediately before that run's `set-home-activity`.
Rollbacks and restores go back to that state.
- **HOME changed since the receipt was created, with no open HOME change:** for
  example, the operator picked another launcher. The run warns, and a new HOME
  change returns to the operator's choice, not the first snapshot.
- **HOME moved away from Setbeam after an open HOME change:** the open change
  is marked `superseded`, and the new change records the current holder.

The overlay app-op follows the same rule. Its mode is read immediately before
`appops set … allow`, and an unknown mode is refused.
- **Live mode is already `allow`:** nothing is changed. Any open change stays
  the restore target.
- **Open overlay change, but the mode moved away from `allow`:** that is an
  operator's choice on a resolved receipt. The run warns, marks the old change
  `superseded`, and records the live mode as the new restore target.

**A receipt that needs restore blocks provisioning.** A receipt is marked
`needs-restore` when a rollback inside `provision`, or a `restore`, couldn't
be verified. Any `rollback-failed`, `rolling-back`, `restoring` or `flush-pending` change has
the same effect. Every later `provision` is then refused with exit 2 and the
restore command:
- `--apply` makes no change at all: no install, configuration, HOME or
  overlay change, and no receipt write.
- A dry run reports the same condition and also exits 2.

`status` prints `NEEDS RESTORE` and sets `receipt.needs_restore` in `--json`.
Restore runs normally. If the result isn't exact, it needs `--force` to
accept it.

Both `provision` and
`restore` refuse a receipt recorded for another Android user. Switch the TV
to that profile first, because HOME roles and app-ops are per user. They
also refuse a receipt whose manufacturer, model or device differs from the
attached box. `restore --force` overrides the identity check, but never the
user check. A changed fingerprint (OS update) only warns.

If Setbeam already held the HOME role before provisioning, HOME is left
unchanged and is not recorded. Restore then has nothing to undo there.

`restore --apply` always works in this order, and saves the receipt after
each step:

1. **Overlay app-op.** It goes back to its recorded mode. If the receiver is
   gone, the app-op went with it.
   - **Live mode already equals the recorded mode:** no mode is sent. The
     tool still runs `appops write-settings` before marking the change
     restored, because the match may come from an earlier restore that was
     interrupted before its save.
   - **After setting the recorded mode:** the tool saves with `appops
     write-settings`, using the same exact-output check, and confirms the mode.
     If the save fails, the change stays `restoring`, the receipt is marked
     `needs-restore`, and the run exits 5.
   - **Live mode can't be read exactly:** restore refuses, even with
     `--force`.
   - **Live mode is neither `allow` (what this tool set) nor the recorded
     mode:** someone changed it later, and restore refuses without `--force`.
2. **HOME.** It goes back to the recorded holder with `set-home-activity`. If
   no explicit holder was recorded, Setbeam is removed with `role
   remove-role-holder`. Success means:
   - **A holder was recorded:** exactly the recorded holders, and the recorded
     resolution.
   - **No holder was recorded:** Setbeam holds nothing, and HOME resolves as
     before. Android may assign its own default holder at that point.

   If Android's default changes the resolution, for example from the chooser
   to a launcher, the step is reported as not restored (exit 5).
   `restore --apply --force` accepts that result with a warning. If HOME now
   belongs to a third app, restore refuses without `--force`.
3. **Receiver app.** It is uninstalled only when all of these hold:
   - `--uninstall-receiver` is given.
   - This tool installed it for the recorded user.
   - HOME was restored first.

   The uninstall is `adb uninstall --user <recorded user>` only. The receiver
   stays installed in every profile listed in `other_users_before`, and losing
   it there counts as a failure. If the receiver is already absent for that
   user, that counts as restored. A receipt without a recorded user, from an
   older version of the tool, never uninstalls.

On success the receipt is archived as `…restored-<time>.json`. The host and
label stay in the receiver's own app data until it is uninstalled or
reconfigured. If a rollback inside `provision` fails, the run exits 5, prints
the restore command, and makes **no further device changes** in that run.
A later `--allow-background-start` step, for example, is skipped. A restore
with an unverified step also leaves the receipt `needs-restore`. Either way,
provisioning stays blocked until a restore succeeds.

### Android profiles (users)

Google TV profiles are separate Android users. The tool always works on the
current user, and the receipt is tied to it:
- **Presence checks:** `pm path --user <user>`. Without `--user`, AOSP
  `runPath` checks user 0. Other profiles are read from `dumpsys package`
  `User N: … installed=` lines (AOSP `Settings.dumpPackageLPr`, present on
  Android 12, 14 and `main`).
- **Install and uninstall:** `adb install --user <user>` and `adb uninstall
  --user <user>`. Without `--user`, adb installs for every user and uninstalls
  from every user.
- **Shared app code:** if another profile already has the receiver, the
  install adds it to the current profile only. The run warns that it also
  updates the shared app code for those profiles, because Android shares one
  APK across users.
- **No version rollback:** restore never rolls back an APK version. A warning
  says so whenever `--apk` updates an existing install.
- **Unreadable per-profile state:** if the receiver is on the device but the
  per-user lines can't be read consistently, `--apk` is refused before any
  change.
- **Profile mismatch:** a receipt from another profile is refused, and
  `--force` doesn't override that.

Not checked on hardware: adb passing `--user` through to the package manager
on onn firmware, and the real Google TV profile layout.

## OS update sensitivity

A Google TV update can change launcher priorities, role behavior, background
start rules or accessibility rules. After any OS update:

1. Run `status`. It warns when the fingerprint differs from the receipt.
2. Re-run the cold-boot and standby rows of the qualification sheet.

A restore after an update works by package name and checks its result. A
model or user mismatch is refused, as described above.

## Requirements on the receiver app

These are for whoever owns `receiver/android`:

- `MainActivity` must be exported and declare both `MAIN` + `LEANBACK_LAUNCHER`
  and `MAIN` + `HOME` + `DEFAULT`.
- `CONFIGURE` must be handled by an exported activity guarded by
  `WRITE_SECURE_SETTINGS`, as `ProvisionActivity` is today. Then only the adb
  shell and the system can start it. Any other exported CONFIGURE handler,
  including an `activity-alias`, must declare the same permission itself.
- Keep logging `Pairing accepted for <baseUrl>` and `Pairing refused: …` under
  the tag `SetbeamProvision`, without secrets. The tool uses these lines to
  tell "accepted" from "delivered".
- For path 2, the app needs a `BOOT_COMPLETED` receiver and the
  `SYSTEM_ALERT_WINDOW` request. It has both.
- Screen and sleep: the app requests screen-on (`FLAG_KEEP_SCREEN_ON`) in every
  phase while it is in front, not only during playback. That includes waiting
  for the Mac, waiting for Admit, Hold, Sharing ended, declined, and removed. A
  screensaver would otherwise stop the app before a later share arrives. This
  is only a request. The device's own energy-saver or inactivity sleep (on
  Android 11 and later, `Settings.Secure` `attentive_timeout`, which Google TV
  shows as the energy-saver display-off timer) can still put an untouched box
  into standby, even during playback. Whether a given build honors
  screen-on against that timer is unverified.
  - **During setup:** read the setting with
    `adb shell settings get secure attentive_timeout` and in the TV's
    energy-saver screen. Where the firmware permits, choose Never or turn the
    timeout off on the TV.
  - **Afterwards:** verify hours-long unattended waiting for the Mac, Sharing
    ended, declined or removed, and playback.
  - **Records:** put the exact setting name and value in the qualification
    sheet (P5).

  The provisioning tool doesn't change this setting and records no receipt
  for it.

Checked on the Mac only, 2026-11-17: `verify-apk` passes on
`receiver/android/app/build/outputs/apk/debug/app-debug.apk` (version code 1,
debuggable, `ProvisionActivity` guarded by `WRITE_SECURE_SETTINGS`, overlay
request and boot receiver present). The signer was not checked because there
is no Java runtime.
