**Verdict: approved, with one condition. I can't give final sign-off until the isolated full check finishes and passes. It was still running when I finished.** I found no remaining code or design blockers in the six scoped files.

I only compared the six files against `/tmp/setbeam-before-chat-polish-20261110`. I read the round-1 review, the verification doc, the design standard and `docs/status.md`, and looked at the original screenshot and all eight evidence screenshots. I ran no tests or apps and edited nothing.

## Scope
- The SHA-256 of each of the six files matches `build/chat-polish-evidence/review-inputs.json`.
- No source, script or test still refers to `CompactAudiencePreview`, `outgoingSummary` or "Outgoing preview".
- The only changes outside SwiftUI views are the build number moving from 35 to 36 and the focus clearing added to `SharingWindowLifecycle`.

## Round-1 items, all resolved
1. **Medium, outgoing status facts:** fixed. `MonitorControls.swift` `outputStatus` puts "Outgoing picture confirmed / Checking outgoing picture" and "Sound included / No audio track" into the status button's help and accessibility label while sharing. In other states it uses `outputDetail`. No thumbnail came back.
2. **Low–medium, why capture is disabled:** fixed. `captureHelp` is checked in this order: capturing, pending change or busy, Hold, then unconfirmed picture. Each reason covers one of the conditions in `canCaptureChatFrame` (`SessionModel.swift:943`). The rare shutting-down state falls into "unconfirmed picture", which is fine. The disabled accessibility label adds the reason.
3. **Low–medium, composer focus:** fixed. The border turns accent only while the draft has focus (see `chat-focus-light.png` and `chat-compact-draft-dark.png`); otherwise it uses the separator color.
4. **The Low items:** all fixed.
   - The image thumbnail is now 64×36 with "Image" and "Sample media".
   - The sender name keeps its case in help text.
   - The stray ". " at the end of the accessibility label is gone.
   - "Remove for Everyone" is used in both the menu and the accessibility actions.
   - Reply, Like/Unlike and Remove for Everyone are per-row accessibility actions.
5. **The always-visible "…":** I accept keeping it. Right-clicking selectable text really does open the macOS text menu, so the menu has to stay reachable. It reads quietly in both appearances.
6. **The 400 pt enlarged image:** nonblocking, as agreed in round 1.

## Media invariants
- There is one picture on screen in every capture. The hidden outgoing decoder stays, because capture and confirmation depend on it.
- `chat-hold-dark.png` shows On Hold with Resume Sharing, a live local picture, the messages kept, and the capture button disabled.
- `chat-stopped-dark.png` shows Private, an empty "Sharing is off" chat, and a command area that doesn't stretch.
- There are no changes to the gateway, runtime or browser.

## Screenshots
All of them answer Austin's "clean, not sloppy" feedback.
- Names, text, reply quotes and attachments share one left edge.
- Timestamps are quiet, and the like pill appears only when a message has likes.
- The composer is one unit, with the encryption notice reduced to one line.
- In the compact draft, Cancel Reply, Remove Frame and Send are all visible. The message list shrinks to about one row at 472 pt high, which is acceptable for that size.
- The separate window opens without focusing the draft.

**Nits, not blocking:** none worth reopening.

## Full check (the gate)
- The isolated `scripts/check.sh` is **still running**.
- Already passed: the Swift tests, Pyro H, and media integration, which ended with "Setbeam media integration checks passed".
- The source-recovery stage is running now. That is the stage that failed on the first attempt, and `build/logs/source-recovery.log` is still empty.
- Not yet run: the access, local-address, short-address, safety, format, frame-rate and keyframe probes.

Final sign-off needs the run to end with "Swift and media checks passed", source recovery included. Then `docs/status.md` and the verification doc must record that exact result in place of "in progress".
- If source recovery fails again on this isolated run, it is a blocker that needs a diagnosis. Retrying until it passes wouldn't count, and timeouts must not be loosened.
- Install and delivery should wait until the check passes and the docs are updated.

The hardware, real iOS and spoken VoiceOver limits are stated correctly, and no new compatibility is claimed.
