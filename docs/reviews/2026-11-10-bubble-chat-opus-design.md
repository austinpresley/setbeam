**Verdict: approved with changes.** The direction fits `docs/design-standard.md`: bubbles, a context menu for actions, and no action row at rest. Seven items below need to be in the build. They're mostly interaction edge cases the plan doesn't yet cover. Everything after that is a refinement.

## Must address

1. **Copy will fail on the phone, as planned.** The viewer is served over plain `http://` on the LAN (`ViewerGateway+Chat.swift:35`). `navigator.clipboard` doesn't exist on insecure pages. If touch text selection is turned off, Copy becomes the only way to get text out, and it won't work.
   - Fall back to `document.execCommand('copy')` on a temporary read-only textarea, inside the same tap.
   - If that fails too, open the text in a small selectable view.
   - Test this in Mac WebKit with the page on an `http` LAN address, not `localhost`. Safari treats `localhost` as secure, so Copy would pass there and still fail for viewers.

2. **"Dismiss on scroll/resize" will close the menu by accident.**
   - On iOS, if the keyboard is up and someone long-presses a bubble, the input loses focus and the keyboard drops. That resizes the visual viewport, and the menu closes as soon as it opens. On `visualViewport` resize, move the menu instead of closing it. Close only on orientation change or when the anchor bubble disappears.
   - The 2-second poll scrolls the log to the end when it was already at the end (`chat.js:226`). That scroll would close an open menu. While a menu is open, hold off that auto-scroll, or ignore scrolls the code caused.

3. **Avoid duplicate menus and stray taps on touch.**
   - Android Chrome fires `contextmenu` on long-press, so it would race the long-press timer. When `contextmenu` fires, call `preventDefault()` and cancel the timer.
   - After a long-press opens the menu, swallow the click that follows. Otherwise it toggles the menu shut or enlarges the image.
   - Open actions on tap only when `pointerType === 'touch'`. With a mouse, a click that opens a menu breaks text selection and feels wrong. Desktop users get right-click, the hover More button and the keyboard.
   - Set `-webkit-touch-callout:none` and `draggable=false` on chat images too, so iOS's Save Image callout doesn't compete with the long-press.

4. **Keyboard and screen-reader structure.**
   - Don't give each message, or each More button, its own Tab stop: that's up to 100 stops. Make the log one Tab stop, with arrow keys moving between messages (roving tabindex). Enter, the ContextMenu key and Shift+F10 open the menu for the focused message.
   - The menu should be `role="menu"`: reactions as `menuitemradio` with `aria-checked` marking your own, Reply and Copy as `menuitem`, arrow keys to move. Tab or Escape closes it and returns focus to the bubble.
   - The menu's Escape handler must call `preventDefault()` before the document-level handler runs (`chat.js:276`). Otherwise Escape closes the whole chat panel.
   - The log is `aria-live` with `aria-relevant="additions"`. Rewriting reaction counts or timestamps adds text nodes, so screen readers will announce reaction changes. Hide the visible reaction summary from the live region (`aria-hidden`) and include it in the message's label instead. Only new messages should be announced.
   - The operator `✓` uses `aria-label` on a plain `<span>`, which screen readers don't reliably announce. Use visually hidden text instead.

5. **Native: right-click vs. text selection.** `Text.textSelection(.enabled)` at `SessionChatView.swift:69` takes right-click for its own text menu, so the message menu becomes unreliable. Remove text selection from bubbles and add a Copy action. Right-click then works everywhere on the bubble, and the hover More button becomes a convenience instead of a workaround.
   - Build the reactions as a palette row inside the menu (`Picker` with `.pickerStyle(.palette)`, macOS 14+), with text labels such as "Heart, selected". Emoji glyphs alone read poorly in VoiceOver.
   - Press-and-hold on Mac isn't standard. Keep it as the explicit request, but it must not also fire the image's tap action.
   - Change the row from `.contain` to a single combined accessibility element. Its label covers author, operator, time, reply, sample image and reactions, so grouped messages without a header still name their author.

6. **Pin down the data rules before writing the UI.**
   - Have the server set `mine` in `messages(for:)`. The browser has no reliable way to know its own author number, and matching by name breaks when someone renames.
   - Store reactions as one entry per participant, capped at 128. Replacing your own reaction doesn't count toward the cap. Reject reaction kinds that aren't one of the six.
   - Legacy `like`: `liked:true` sets your reaction to heart, replacing any other. `liked:false` removes only a heart. The `likes` count means hearts only, and `liked` means your reaction is a heart.
   - Reactions currently draw on the same 4-token rate budget as posting (`SessionChat.swift:63`). A few quick reaction toggles would then block the next message with "Wait a moment". Give reactions their own small budget, or don't charge for no-op changes.

7. **Update the 2026-11-10 section of `docs/design-standard.md`.** It still says "aligned author/message rows" and "a message actions menu". Record the bubble direction and press-and-hold so the standard doesn't contradict the build.

## Refinements

- **Grouping:** start a new group when the author number, name or colour changes, or after about 5 minutes. Show name, cursor avatar, operator badge and time once per group, with no repeated avatar column. Own bubbles drop the name.
- **Spacing:** about 2–4 pt between bubbles in a group, about 12 pt between groups. Bubbles take at most about 75–80% of the column width.
- **Colour:** on the Mac, tint own bubbles with `accentColor` rather than a fixed blue, with primary-colour text. In the browser, use a dark blue tint that meets 4.5:1 text contrast. Never fill a bubble with someone's pointer colour. Increase Contrast and `prefers-contrast` add a border to both bubble styles. Use solid fills, not translucent materials.
- **Reaction summary:** small chips under the bubble rather than overlapping its corner, which avoids clipping and overlapping touch targets. Show counts only, highlight your own, and collapse when narrow. Tapping a chip opens the same menu, not a second set of controls.
- **Menu:** reactions on top (6 × 44 px fits a 320 px screen), then Reply and Copy, plus Remove for Everyone on the Mac only. A quiet "Sent 10:42" line at the top of the menu covers touch users, who never see hover times.
- **Images:** keep a visible "Sample" text label on the thumbnail itself, not only in the alt text. The browser's enlarged view can be a modal `<dialog>` with a 44 px close button; trapping focus is fine there. While the menu is open, a poll should update its checked reaction in place, not rebuild the menu, so focus isn't lost.
- **Composer:** shorten the browser's notice to the native wording, "Not encrypted · Clears at Stop". The info button needs `aria-expanded` and must work by tap; a hover title isn't enough. Keep Return-to-send off on touch keyboards; hardware-keyboard Return is optional and best matched to the Mac.

Nothing above changes media, Hold, admission or Origin handling.
