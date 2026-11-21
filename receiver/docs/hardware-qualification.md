# Receiver hardware qualification

This is a physical checklist for one dedicated Setbeam Receiver device. Mark a
row **Pass** only after watching it happen on the actual hardware, and record
the evidence. ADB output, emulator runs and fake-adb tests are software
evidence, and they never pass a row here. Copy confirmed hardware results to
`docs/hardware-tests.md` according to that file's rules.

Status: **not started.** No onn device has been attached to this work yet.

## Record first

| Field | Value |
| --- | --- |
| Date / tester | |
| Retail model and box/label model number | |
| `status --json`: `device.model`, `device.build_fingerprint`, `device.security_patch`, `device.sdk` | |
| Android user (profile) current during setup (`device.user`), and the Google TV profiles present | |
| HOME candidates and priorities (from `status`) | |
| Startup path in use (HOME / receiver boot start / Projectivy + version / manual) | |
| Receiver APK version code and SHA-256 | |
| Mac: Setbeam build, macOS version, source, sharing output resolution and frame rate | |
| Network: Wi-Fi or Ethernet, same subnet, mDNS allowed? | |
| TV / monitor model, HDMI port, CEC on/off | |
| Receipt path | |

## Setup (one time, remote allowed)

| # | Step | Expected | Result / evidence |
| --- | --- | --- | --- |
| S1 | `setbeam-receiver status --serial …` | Device identified, no receipt | |
| S2 | `provision … --apk … --host http://setbeam.local/ --name "…"` dry run | Plan printed, no change on device | |
| S3 | Same with `--apply` | Exit 0, or 3 with named blockers. Receipt written | |
| S4 | If exit 3: chosen fallback configured (receiver boot start or Projectivy) | Recorded in the first table | |
| S5 | Receiver shows the configured host and label on screen | Matches input. The tool reports `accepted`, or `delivered` if the app's log line was not observed | |
| S6 | Optional `--home-key-probe` (HOME path only) | `passed`, or record `inconclusive` (role kept) / `failed` (role rolled back, exit 3) with the front activity | |
| S7 | Multiple profiles only: `status` on each profile after setup | Receiver installed for the provisioning profile. Profiles that had it before keep it | |

After S5, put the remote out of reach. A "No remote" row fails if anyone
touches the remote, phone remote app or TV buttons.

## Startup without the remote

| # | Scenario | Expected | No remote? | Result / evidence (time from power to picture) |
| --- | --- | --- | --- | --- |
| B1 | Cold power: pull the box's power for at least 30 s, Mac sharing already on, then restore power | Receiver opens full screen by itself and asks. Operator Admit, then playback | Yes | |
| B2 | Cold power with the Mac not sharing yet | Receiver waits without error loops. When sharing starts, it asks once | Yes | |
| B3 | Standby wake by TV power-on through HDMI-CEC | Receiver returns to the front, or reconnects without a new request if its pass is still valid | Yes | |
| B4 | Standby wake by the box's own sleep timer or screensaver ending | Same as B3. Record whether the stock launcher flashes first (reported about 3 s on a 4K Pro with Projectivy) | Yes | |
| B5 | Wi-Fi joins late: router powered after the box | Receiver retries with backoff, then asks when the network is up | Yes | |
| B6 | Wi-Fi drops for 60 s during playback | Picture stops cleanly, then resumes without a new Admit while the share is unchanged | Yes | |
| B7 | Mac offline or asleep during box boot | Receiver waits. No crash, no repeated requests on the Mac | Yes | |
| B8 | mDNS blocked or `.local` unresolved (configured IPv4 host) | Configured-host fallback works | Yes | |
| B9 | OS update applied (record old and new fingerprint) | Re-run B1 and B3. `status` warns about the fingerprint change | Yes | |
| B10 | Google TV Profile Picker at boot (if more than one profile, or "who's watching" is enabled) | Record whether the picker appears before the receiver, and which profile the receiver starts in. A picker that needs a remote press fails "No remote" | Yes | |
| B11 | Receiver crashes or is force-stopped while unattended: from the Mac, `adb shell am force-stop com.setbeam.receiver` on the test box only | Record whether it comes back without a remote. On the HOME path Android relaunches HOME. On the boot-start path it may stay closed until the next boot. Projectivy behavior must be recorded separately | Yes | |

## Admission and session behavior

| # | Scenario | Expected | Result / evidence |
| --- | --- | --- | --- |
| A1 | First request | The Mac's join card shows the label as unverified. Nothing plays before Admit | |
| A2 | Decline | Receiver stops asking on this share. No new card until a new share | |
| A3 | Remove an admitted receiver | Media access ends. No automatic new request on this share | |
| A4 | Stop Sharing | Receiver stops playback. Local monitoring on the Mac continues | |
| A5 | New share (new ask path) | Receiver asks again, and needs a fresh Admit | |
| A6 | Hold / Resume | Receiver shows the held state with no audio. Resume returns picture and sound | |
| A7 | Receiver power-cycled while admitted on the same share | Resumes with its stored pass and no new request | |
| A8 | Second receiver or browser viewer at the same time | Both play. The Mac still receives the source once | |

## Picture and sound

| # | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| P1 | HDMI output mode (TV info overlay or `dumpsys display`) versus the sender's output | Record both. For example, a 3840×2160 30 fps H.264 sender against a 2160p60 HDMI mode | |
| P2 | 4K30 H.264 playback for 30 minutes | No decoder errors and no growing delay. Record dropped frames if the app shows them | |
| P3 | Frame-rate match or judder: 30 fps content on a 60 Hz HDMI mode | Record visible judder. Note whether the receiver requests a mode switch | |
| P4 | Opus audio on HDMI | Audible, in sync to the eye. Silent while on Hold | |
| P5 | Unattended screen-on and sleep. First record the exact sleep setting: `adb shell settings get secure attentive_timeout` (value in ms, or `null`) and the TV's energy-saver "turn off display" choice, with menu path and value. Set it to Never or off if the firmware permits, and record what was possible. Then leave the box untouched in each state: Waiting for the Mac (not sharing), Sharing ended, Declined or Removed, Waiting for Admit, and playback | No screensaver, ambient mode, or standby in any state for at least 3 hours each (playback at least 1 hour). Record any timeout that still applied despite the app's screen-on request, and how long it took. When the Mac shares later, the receiver asks by itself with no remote | |
| P6 | Graphics memory and 4K composition: 3840×2160 30 fps playback for at least 1 hour. Read the receiver's Info overlay (Buffer requested/confirmed, Display mode) and `adb shell dumpsys SurfaceFlinger` (the receiver's layer buffer size and whether HWC composes it as a device or client layer). Record `adb shell dumpsys meminfo com.setbeam.receiver` (Graphics) at start and end | Confirmed buffer 3840x2160. Layer composed without falling back to GPU client composition, or record the fallback. No GL out-of-memory, black frames, or crashes. Graphics memory steady, not growing | |

## Restore

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| R1 | `restore --serial …` dry run | Plan matches the receipt | |
| R2 | `restore --apply` while the TV is on the profile recorded in the receipt | Exit 0, original HOME resolves, receipt archived. Exit 5 means not exactly restored; record the reason | |
| R1a | If `status` shows `NEEDS RESTORE` | `provision` is refused (exit 2) until `restore` succeeds. Record whether `--force` was needed and why | |
| R2a | `status` after R2 | HOME holders and resolution match the `before` of the receipt's last HOME change (not its first snapshot, if HOME changed in between). The overlay app-op shows its recorded mode (or the receiver is absent) | |
| R3 | Power-cycle after restore | Stock behavior returns | |
| R4 | If Projectivy was used: disable its accessibility service and autostart, or uninstall it, by hand | Stock launcher on boot | |

## Known bounds

- The provisioning tool never reboots, so B1-B9 are always manual power
  actions.
- A `HOME verified` result from the tool is not a pass for B1 or B3.
- Projectivy's results can change with Projectivy or Google TV updates. Record
  both versions.
