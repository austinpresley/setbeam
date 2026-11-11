# Minimal floating preview revision, 2026-11-06

Austin found the two-row concept cluttered and requested a picture-first
floating preview, with a light Hold wash, centered icon control, viewer quick
action and optional hover controls. This direction supersedes the earlier
48-point bar and its design rating.

The revised prototype removes both rows, source/monitor names, text status,
separate Resume, More, sound and Fit controls. Hover reveals Hold and Close.
Confirmed Hold uses a light wash and a persistent play icon to resume. The
small viewer/request shortcut opens individual Admit, Decline and Remove
actions. Other commands remain in the main window or menu bar.

Opus 5.5 at high effort endorsed the revised direction with refinements to
glyph/action consistency, persistent held-state indication, double-click
suppression and the connected-viewer shortcut. The response and design notes
are retained under ignored `design/mockups/floating-preview-v3/`.

Twenty-one simulated interaction and geometry checks pass. These cover no added
window height, hover visibility, true pending Hold/Resume states, suppression of
drag/double-click activation, viewer decisions/removal, closing without changing
sharing, private preview and 220/340-point containment. Rest, hover and compact
HTML renders pass with no console errors; a 360-pixel conversation layout also
renders successfully. The source image is explicitly labeled sample media.

This is a prototype, not an app change. Native media commands, focus behavior,
accessibility, source loss, source-shaped resize and physical verification remain
implementation work. The app/media suite was not rerun. No production source,
installation, media behavior, hosted CI, commit, push or PR changed.

Seven final smoke checks also pass after the caption and wash-transition polish,
including true pending states, updated captions, popup containment, no added
height at 220 points and unique control IDs.

## Delivery

Austin Deliveries reports delivered with remote verification under Setbeam /
Floating preview 2. Receipt `20261106T193457Z--4acee34e77ee` includes the rest and
hover PNGs, the self-contained interactive prototype and the design notes.
[Open the revised design](https://drive.google.com/drive/folders/1l8JngDCpIxhlXSx-oNuGuFjM4hpaBzh-).
