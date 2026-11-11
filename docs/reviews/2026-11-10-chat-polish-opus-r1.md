**Verdict: approved with changes, provisionally.** The visual direction answers Austin's feedback, and the media invariants hold. I'm not giving final sign-off until the items under "Gating" are done. Nothing I found is high severity.

The review covered only the five baseline files, the two docs, both screenshots, and the model code needed to trace what was removed. I didn't run anything.

## Media invariants
- Only one picture is left on screen. `CompactAudiencePreview` is gone from both the docked and the separate-window Sharing panel, and nothing in Sources, scripts or Tests still refers to `outgoingSummary` or "Outgoing preview".
- The hidden outgoing decoder (`audiencePlayer`, 384 px, 8 fps, no audio) still runs, and it's still needed. `canCaptureChatFrame` and `captureChatFrame` read from it (`SessionModel.swift:943,959`). This is a status check of the Mac's own feed, not a second source. Don't remove it.
- Hold, Stop and status are unchanged. The command bar shows the phase title in orange for Hold and attention states, and the recovery banner remains (`MainView.swift:145`).

## Appearance (chat-dark.png against Austin's screenshot)
It's a clear improvement. The blue Like/Reply/Remove rows, the identity disclosure, the three-line footnote and the duplicate picture are all gone. Names, text and reply quotes line up on one left edge. Timestamps are quiet, and the composer reads as one unit. Smaller issues I can see:
1. **Low:** The image card's thumbnail has dark letterbox bars, because a 16:9 frame is fitted into a 64×44 box. Use a 16:9 box (64×36) or fill and clip it.
2. **Low:** "Image from Sam, client" repeats the author name just above it, and "Sample media · View image" is wordy. Suggest a "Frame" title with "Sample media" as the second line, or no second line when it isn't sample media.
3. **Low:** A permanent "…" on every row makes a stacked column of icons, against the design standard's rule to show secondary actions on hover or focus. Consider showing it on hover or focus, and keep the context menu and accessibility actions as the way in that's always there.
4. **Nit:** The panel title "Sharing" sits next to the toolbar status "Sharing". That's acceptable for a panel title.

## Code, UX and accessibility
1. **Medium: two outgoing facts no longer appear anywhere in normal use.**
   - "Picture confirmed / Checking outgoing picture" (`audiencePreviewPlaying`) was the Mac's proof that the outgoing feed was actually decoding.
   - "Sound included / No audio track" (`audienceHasAudio`) now appears only in Test my setup.
   - The status can show a green "Sharing" while the outgoing decoder is not yet playing.
   - Don't bring the thumbnail back. Put these quietly in the status button's help and accessibility label, or in one line under Viewers or Options.
2. **Low–medium:** The camera button can be disabled with no explanation: while the outgoing check is pending, during Hold, or while busy. Its help text always says "Attach a frame from the shared feed". Give it a help string for each disabled reason.
3. **Low–medium:** The composer `TextField` uses `.plain` inside a custom box, so it no longer has a focus ring. Keyboard and Full Keyboard Access users can't see that it has focus. Tint the box border when `composing` is true.
4. **Low:** `SessionChatView.swift:199` uses `.help("Open \(title.lowercased())")`, which lowercases the sender's name ("Open image from sam, client"). The accessibility label next to it also ends with a stray ". " when the image isn't sample media.
5. **Low:** "Remove Message" deletes for everyone with no confirmation. The old help said "for everyone" and that wording is now gone. Rename it "Remove for Everyone".
6. **Low, needs a check:** On macOS, right-clicking text that has `.textSelection(.enabled)` may show the system text menu instead of the row's `.contextMenu`. The "…" menu still works either way. Check by right-clicking on the message text, not just the row.
7. **Low:** Each row is read as separate elements. Add `.accessibilityActions` (Reply, Like, Remove) to the row so VoiceOver users don't have to find the menu button.
8. **Low:** The enlarged image is only a 400 pt popover, about 360×203 for 16:9. That's small for judging a frame. It's fine for now; a sheet or Quick Look could come later.

## Gating (outside the code)
- **Full check:** `scripts/check.sh` must pass when run on its own. The source-recovery failure ("The video service could not start") happened alongside the QA sample run, so it isn't attributed yet. Record the exact result either way.
- **Evidence:** Light, compact, separate-window, Hold and Stop screenshots must be captured and inspected. Hold matters most: the camera button should be disabled with a reason, the status should read On Hold, and the local picture should stay live.
- **Status doc:** `docs/status.md` doesn't record the build-36 polish yet; AGENTS.md requires it.

With Medium item 1 and the two Low–medium items fixed, the remaining evidence clean, and the full check passing, I'd approve this polish.
