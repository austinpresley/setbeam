**Round-3 verdict: approved, with one gate still open.** Both round-2 must-fix items are resolved, and the four should-fix items I raised are fixed. The new evidence is current and matches the source. Final sign-off is still waiting on `scripts/check.sh` and packaging. I found no blockers in code or design.

I compared only against `/tmp/setbeam-before-bubble-chat-20261110` (Sources, Tests, scripts) and ran nothing.

## Evidence is current
- All 14 hashes in `final-review-inputs.json` match the files on disk.
- The browser reports (00:42–00:54) are newer than `chat.js` (00:35), `viewer.css` and `viewer.html`.
- The native captures and `native-keyboard-proof.json` (01:11–01:28) are newer than `SessionChatView.swift` (01:04) and `SessionModel.swift` (00:37).
- `verified-assets.json` confirms the browser served the current source files.

## Round-2 items
1. **Must 1, a small finger drift closing the menu: fixed.**
   - Touch movement is now measured from `touchstart`, using the same 10 px limit as the hold timer (`chat.js:220-225`).
   - The interaction test opens the menu by hold, moves 3 px after the 500 ms timer and before release, and checks the menu is still open (`check-chat-interactions.js:45-47`).
   - The real-scroll and pointer-cancel paths still dismiss the menu.
2. **Must 2, choosing actions from the keyboard: fixed with the hotkey approach.**
   - The palette is focusable, takes focus when it opens, and handles 1–6, R, I, ⌘C and Shift-D (`SessionChatView.swift:333-342, 373-375`).
   - Keys 1–6 follow the reaction order, which is the same in the core enum, the native palette and the browser.
   - The proof records Full Keyboard Access off, plus 2, R, I and Shift-D chosen through the native UI. It does not claim arrow selection inside the palette.
3. **Should 3, iOS Copy: fixed.** Copy now uses `setSelectionRange`, accepts the result only when the whole text is selected, and gives the helper a 16 px font. If selection fails it falls back to the selectable dialog.
4. **Should 4, native palette: fixed.**
   - The right-click palette now uses cached colour emoji images.
   - There is one "None" choice and no separate Remove row.
   - `native-emoji-context-final.png` shows them rendering correctly.
5. **Should 5, following new messages after a menu closes: fixed.** The browser records "at end" when the menu opens and scrolls down in `closeActions`. A tap inside the log doesn't trigger this, which is right. Native defers its scroll with `pendingChatScroll` while the popover is open.
6. **Should 6, focus when a message is removed: fixed.** If focus was in the removed row, its menu, the image or the Copy dialog, focus moves to the next message, or to the log when the chat is empty (`chat.js:275-281, 325`). The real native operator removal test covers this.

All the delayed-Copy guards are still in place: the attempt counter, generation, the open/admitted/active checks, the row-and-text match, and closing on removal.

## Visual check
- **Native dark and light:** own bubbles use the accent tint. The light theme has good contrast and no keyboard focus is shown at rest.
- **Dense native:** with six reaction kinds, three chips plus "+3" fit in 320 pt.
- **Phone reaction menu:** bubbles sit on the correct sides, and the selected heart is highlighted.
- **Phone landscape:** the layout is compact, and the notice fits on one line.

## Should fix (not blocking)
- **A. ⌘C in the native palette isn't in the proof.** Only 2, R, I and Shift-D were exercised. ⌘C should arrive in `onKeyPress` because Edit > Copy has nothing to copy while the popover has focus, but it hasn't been observed. Either record one native ⌘C run or stop claiming it.
- **B. Sighted keyboard users can't see the hotkeys.** The list exists only as the accessibility hint (`:377`), and the emoji tooltips show only the label. Add the key to the tooltips (for example "Love (1)", "Reply (R)") or a small caption line.
- **C. Starting a reply hides the message being replied to on native.** In `native-dense-draft-final.png`, the composer grew for the reply and image draft, and the replied-to message's chips are cut off by it. The transcript only scrolls when the last message ID changes (`:45-48`). When the view was at the end, scroll to the last message after `chatReplyTo` or `chatAttachment` changes or a reaction is added. Because the minimum is macOS 14, `defaultScrollAnchor(_:for:)` isn't available.
- **D. `docs/status.md` contradicts itself.** One place says "the old hint was removed", another says "its hint says exactly that". The hint now lists only the hotkeys. Use one wording.

Something I checked and set aside: in WebKit portrait, Send sits below the fold (851 vs 844 on iPhone, 1104 vs 1024 on iPad mini). The panel CSS is the same as the baseline, and the page scrolls in portrait, so this isn't a regression.

## Gate
- **`scripts/check.sh`:** still running. At 01:36 the log showed only passes, the last being the RTMP/RTSP reconnect checks, and no failures. It needs to finish cleanly, then packaging.
- **Not counted:** physical iOS, the iOS Simulator and spoken VoiceOver. This is an ad-hoc local build.

Media, capture, pointers, admission, Origin and Hold are unchanged in this diff.
