# Viewer site redesign proposal, 2026-11-21

Status: implemented on `design/viewer-site-rethink` on 2026-11-21. Austin approved all five behavior changes.

Mockups are in `design/mockups/viewer-web-v1/` (ignored by Git). Run `source/export.sh`
to render them, and `source/build_gallery.py` to rebuild `viewer-before-after.html`.
The before screens use the current `viewer.html` and `viewer.css`, fixed in each state
without the page scripts. The after screens are static HTML. Both sets show labelled
sample media at 1280×800 and 390×844. Neither set was taken on a physical phone.

## Direction

The picture is the page. Text gives way to icons, and each action has one home.

| Screen | Now | Proposed |
| --- | --- | --- |
| Ask to join | Heading, 4 sentences, labelled fields | Avatar preview, name field, colors, one button; the name note moves into ⓘ |
| Waiting | Heading and 3 sentences | Pulsing avatar, "Waiting to be let in", "Keep this page open" |
| Watching, desktop | Header row above the picture | Full-window picture; LIVE and Sample stay; the controls dock fades when idle |
| Controls | `…` menu, help panel with paragraphs | One dock: sound, point, chat, PiP, full screen; shortcuts in tooltips |
| Identity | In the help panel | Tap your avatar: name (locked under approval), color, pointer toggles |
| Chat, phone | Toggle, chat below the picture | Chat always under the picture when enabled; no toggle |
| Hold, ended | Status text plus a sentence | One symbol plus one or two words |

Unchanged: the Sample label, the read-only media path, the locked name while approval
is on, chat during Hold, and the keyboard and accessibility labels behind each icon.

## Behavior changes (approved)

1. Keep the screen on automatically while the picture plays. This removes the sun button.
2. On a phone held upright, show chat under the picture whenever chat is on.
3. Show "not encrypted" as a lock icon in the composer instead of a permanent footer line.
4. Remove the help panel. Network advice appears only when the connection drops.
5. Start pointing with one tap. The explanation becomes a first-use hint.

## Implementation notes

- The status element keeps its full text ("Live feed", "On hold") for assistive
  technology. The pill shows LIVE or HOLD through CSS alternative-text content.
- Phone landscape uses the large-screen layout. Docked chat closes when the phone
  turns sideways, and the toggle opens it as an overlay there.
- Declined, removed, busy, unavailable and ended steps show one symbol, a short
  title and at most one line. The expired-link page matches.
- Light appearance and the chat image and copy dialogs are unchanged.
