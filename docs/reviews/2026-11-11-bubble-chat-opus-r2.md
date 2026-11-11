**Round-2 verdict: approved with changes.** The data model, server rules, the seven earlier design items and the delayed-Copy guards are correct. One browser touch bug must be fixed. One native keyboard gap must be checked, and fixed if it's real. The full-check and final-evidence gate is still open.

I compared only against `/tmp/setbeam-before-bubble-chat-20261110` (Sources, Tests, scripts) and ran nothing.

## Must fix

**1. A hold on a real finger opens the menu, then closes it.** At `chat.js:216`, every `touchmove` on the log calls `closeActions()`. The finger is still down when the 500 ms timer opens the menu, and a real finger drifts a pixel or two before lifting. On iOS that drift sends `touchmove`, so the menu shuts during the hold that opened it. The interaction test can't catch this: `check-chat-interactions.js:45-46` sends `touchStart` then `touchEnd` with no move in between.
- **Fix:** ignore `touchmove` from the touch that opened the menu until it lifts, or apply the same 10 px threshold `cancelPress` uses. Closing on an actual log `scroll` would also work.
- **Test:** add a check with a 2–4 px move after the menu opens and before release.

**2. The native action popover may not work from the keyboard.** Return at `SessionChatView.swift:40` opens the popover. Its reactions and rows (`SessionChatView.swift:313-338`) are `.plain` buttons. With macOS's default setting (Full Keyboard Access off), those buttons can't take focus, so a keyboard-only user can open the popover but can only close it with Escape. VoiceOver users are fine through the accessibility actions. The evidence covers "arrow/Return menu opening, Escape", not picking anything.
- **Check:** with Full Keyboard Access off, Return on a message, then try to choose a reaction or Reply.
- **Fix if it fails:** make the palette items `.focusable()` with an initial focus and arrow/Return handling, or add key handling in the popover (for example 1–6 for reactions, R for Reply, ⌘C for Copy). The design standard says "keep all commands reachable through keyboard".

## Should fix (not blocking)

**3. iOS Copy could report a false "Copied".** At `chat.js:164-166`, `select()` on a read-only textarea often selects nothing on iOS. If `execCommand('copy')` still returns true, the user sees "Copied" with nothing on the clipboard and never gets the selectable dialog.
- Add `area.setSelectionRange(0, value.length)`.
- Only accept the result if the selection covers the whole value.
- Give `.chat-copy-helper` `font-size:16px` so focusing it can't zoom the page on iOS.
- The Mac WKWebView test couldn't show this; it's a physical-iOS risk.

**4. The native right-click palette doesn't match the chips.** It uses SF Symbols (`drop` for Sad, `exclamationmark.bubble` for Surprise) while the chips and hold popover show 😢 and 😮. The palette also has both a "None" item and a separate "Remove Reaction" row, and clicking the selected item already removes it.
- Draw each emoji into an `NSImage` for the palette items. That avoids the blank-palette bridge bug and keeps the glyphs consistent.
- Drop either "None" or "Remove Reaction".

**5. New messages stay out of view after the menu closes.** `chat.js:312` correctly pauses the auto-scroll while a menu is open. But if the log was at the end and messages arrive meanwhile, nothing scrolls down after the menu closes. The next identical poll is skipped, so the view stays put. Fix: remember "was at end" when the menu opens and scroll down in `closeActions`.

**6. Focus is lost when the target message is removed.** At `chat.js:266`, removing a message while its menu, image or Copy dialog is open closes that view. Focus then goes back to the row being deleted, or stays on the hidden menu, and ends up on `<body>`. If focus was inside chat, move it to the log or a neighbouring row.

## Delayed Copy guards: checked, correct
- **Closing chat:** `show(false)` bumps `copyAttempt` and clears `open`, so both success and failure callbacks do nothing.
- **Losing admission:** `reset()` bumps `generation`, and a 403 in `request` resets. `current()` and `selectableCopy` both check `generation`, `admitted` and `active`.
- **Removal:** the row lookup and text match fail. `render` also closes an open Copy dialog for a removed message.
- **Later Copy:** a new attempt supersedes the earlier one.
- **No early access:** `show` can't run before the `const copyDialog` declaration, because every caller is an event or a later `update`.

## The seven design items
1. **Plain-HTTP Copy:** synchronous fallback, secure API, then a selectable dialog. The LAN WKWebView check shows `isSecureContext` false, no Clipboard API, the exact clipboard text, and the earlier clipboard restored.
2. **Menu stability:** visual-viewport resize repositions the menu and the poll doesn't scroll while it's open. Item 1 above is the gap.
3. **Duplicate menus and stray taps:** `contextmenu` prevents the default and cancels the timer, the following click is swallowed, short tap opens only for touch, and image callouts are off.
4. **Keyboard and screen readers:** one Tab stop with arrow keys; `menu`/`menuitemradio`/`aria-checked`; Escape is handled before the document handler; chips are hidden from the live region and counted in the label; the operator mark is in the label.
5. **Native:** text selection is removed and Copy added, the palette is in the menu, hold suppresses the image click, and each row is one combined accessibility element.
6. **Data rules:** `ownMessage`, one reaction per participant, the 128 cap with replacement allowed at capacity, invalid kinds rejected with 400, legacy heart rules, a separate reaction budget, and Origin returns 403. The core tests cover all of these.
7. **Design standard:** `docs/design-standard.md` now has a Build 37 section.

Media, capture, pointers, admission, Origin, plaintext handling, image bounds and moderation are unchanged in this diff.

## Visual check
In `native-dark`, `native-hold-menu-light`, `showcase/phone-reaction-menu` and `showcase/desktop`, own and other bubbles align correctly. Groups, chips under the bubble, the visible "Sample media" label, the compact composer and the one-line notice all look right. Focus shows as a bubble outline, with no ScrollView-wide ring. Text contrast on the browser's own bubbles (`#244f80`) is about 7.9:1.

## Gate: still open
- The evidence is older than the code. `interactions-final` is from 23:49 and `webkit-chat` from 23:47, but `chat.js` and `SessionChatView.swift` changed at 00:17. `showcase-final/` is empty.
- `scripts/check.sh` hasn't been run to completion.
- The dense native and compact layouts are still being captured.
- Physical iOS, VoiceOver and simulator testing don't count toward this review.

Round 3 needs items 1 and 2 resolved, plus fresh results for the interactions, WKWebView LAN, showcase, dense native and full-check runs.
