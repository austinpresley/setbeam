# Setbeam design standard

Austin approved this direction on 2026-11-06 after rejecting an overly dense
floating-preview proposal. Use it for future design decisions across Setbeam.

Start with the user's picture and task. Every persistent control or label must
earn the space it takes. Prefer a familiar gesture or a contextual control over
another always-visible row. Keep the Mac's system fonts, symbols, materials,
keyboard behavior and appearance conventions.

- Keep pictures large and complete at their default zoom. Avoid decorative
  frames, status borders, repeated names and toolbars added for symmetry.
- Show secondary actions on hover, keyboard focus or explicit request. A small
  useful control is better than a container full of controls.
- Give each common interaction one clear home. Avoid duplicating the same
  status and action in several corners of a window.
- Use gentle, meaningful state changes. Hold uses a subtle dark veil and a centered
  play action to resume; hover reveals the pause action while sharing.
- Keep viewer requests actionable and visible until answered, with individual
  decisions available on demand. A joined session is not proof of playback.
- Keep routine work quiet. Explain recovery and failed actions when needed,
  without pretending a requested change has already completed.
- Make all actions available through keyboard and accessibility paths. Pointer
  use in a floating panel must leave the working app's keystrokes alone.
- Honor Reduce Motion, Reduce Transparency and readable inactive controls.
- Treat computer-display and camera feeds equally. Simplicity never changes
  source identity, media ownership, viewer access or Hold's outgoing silence.

The floating preview has no source/monitor name, bottom toolbar, More menu,
sound control or Fit label. Sound and less frequent commands remain in the
main window and menus. Zoom keeps its gestures. Closing the preview leaves
monitoring and sharing running.

Custom floating-preview layout values are in `FloatingPreviewStyle`. Other
screens should use system controls and existing semantic styles. Do not create
new app-wide themes, accent pickers or decorative components to apply this
standard. Improve other screens when their own task calls for it.

## Native implementation choices

The approved concept's 26-point corner controls use 28-point native hit areas,
with 8-point insets, to align with the four-point layout scale and Mac control
sizes. The centered media control remains 48 points. These canonical values
live in `FloatingPreviewStyle`; the concept images express the direction.

The picture has no caption, including in sample mode. Sample media remains
explicitly identified in the main window, the floating preview's accessibility
label and its tooltip. Do not add source names back over the picture.

Confirmed Hold uses a 22% black veil with restrained desaturation and the same
dark frosted control face as the hover pause action. The centered white play symbol stays visible while held.

The native implementation references are [sharing](../Assets/screenshots/floating-preview.png),
[Hold](../Assets/screenshots/floating-preview-hold.png), and
[viewer actions](../Assets/screenshots/floating-preview-actions.png). They use
sample media and fixture viewer identities. Physical hardware is not shown.

## Single picture and quiet chat, 2026-11-10

The main window shows one local media picture. Sharing has no duplicate live
thumbnail, including in its separate window. The existing sharing commands and
status still distinguish private monitoring, live output, transitions and Hold.
A floating monitor stays an explicit optional action.

Build 37 supersedes the row treatment with grouped bubbles and contextual
reply/reaction actions across native and browser chat. Shared images are compact attachments that enlarge on request. Keep the
draft and its capture, identity and Send controls together in one composer.
Put identity editing and longer session information behind explicit controls;
keep the encryption and Stop-lifetime notice visible in one line.


## Messages-style conversation in every view, build 37

Own messages sit on the right in a restrained accent tint; others sit on the
left in neutral bubbles. Group consecutive messages only when author number,
name and cursor color match, within five minutes. Keep names and operator roles
clear. Never use pointer colors as bubble fills. Use four-point within-group
spacing and twelve-point group spacing. Images are compact and enlarge on request.

There are no permanent Like/Reply rows. Right-click or hold a bubble to reveal
reactions, Reply and Copy. A quiet More control appears on hover/keyboard focus;
touch also allows a short tap. The message list is one keyboard stop with arrow
navigation. Only used reactions appear as small summary chips. Native operator
moderation stays private. Keep one composer and the short encryption/Stop notice.

Dismiss gesture menus safely, preserve drafts and plain-HTTP copying, and keep
all commands reachable through keyboard and accessibility actions. Visible
keyboard focus and increased contrast remain part of the native appearance.


Native palette keyboard access with the Mac's default keyboard settings uses
1-6 for reactions, R for Reply, Command-C for Copy, I for the image and Shift-D
for Remove for Everyone. The conversation itself retains arrow navigation and
Return to open actions. Browser menus retain arrow/Return navigation.

## Approved audit improvements, 2026-11-11

Austin approved all six audit findings and the five accompanying mockups.
Recovery instructions, the next action and connection details belong together
in the missing picture, with one explanation for each source problem. Private
copy appears only while sharing is off; active Hold and transitions use observed
outgoing state. Keep secondary recovery commands in Connection details.

Wireless cards show their physical-test limits before setup, including the
exact tested route and firmware. Short source categories fit their content;
application windows retain the roomy two-column thumbnail grid. Keep stream
address entry beside the category choices.

The existing sharing strip shows outgoing picture and audio facts. Admission
and confirmed playback are separate counts. Retain visible pending requests,
Hold and Stop at compact widths. Joining and pointer controls lead Sharing
Options, followed by viewer output. Local address and viewing network disclose
their controls with the current value visible. Immediate switches and each
scoped Apply action retain their existing effects and confirmations.

Phone chat uses the space below the complete picture. Its empty composer is
one approximately 54 px row with 44 px capture and Send targets. Drafts grow
when needed; replies, images and reactions remain contextual. The lifetime
notice reads "Clears when sharing stops." Mac controls retain native sizes.
