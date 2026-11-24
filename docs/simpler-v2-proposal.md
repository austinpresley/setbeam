# Simpler v2 proposal, 2026-11-24

Status: proposal only. No app source changed. Austin has not chosen what to build.

Austin asked for an ease-of-use rethink with before/after mockups, keeping text
minimal and using clear icons. Simpler v1 (implemented 2026-11-21) cleaned up
individual screens. This round removes whole steps: a separate setup test, two
of the four Sharing panel tabs, the panel button, and the viewer's name card
when admission is off.

Mockups are in `design/mockups/simpler-v2/` (ignored by Git). Run
`source/export.sh` to render the after screens, then
`python3 -I source/build_gallery.py Setbeam-simpler-v2.html` to rebuild the
gallery. Before screens are captures from the 2026-11-24 audit-remediation and
2026-11-21 screenshot sessions, plus the implemented viewer redesign. After
screens are static HTML using the Simpler v1 icon set. All media is labelled
sample media; no physical hardware is shown working.

## Direction

Each task should start from what the operator wants to see, take one click,
and confirm itself.

| # | Task | Now | Proposed | Steps |
| --- | --- | --- | --- | --- |
| 1 | Start | Four category tiles, then a chooser | Found sources on the empty stage with their pictures or device art; the last working one marked with a clock; categories become a row of icons | 2 → 1 |
| 2 | Invite and test | Go Live, open the panel, choose the QR tab; Test My Setup is a separate six-step form | Go Live opens People with the Wi-Fi and Watch codes. A strip of Picture, Sound, Wi-Fi and Scan fills in as checks pass. The first device that plays completes the test. | 5+ → 1 |
| 3 | People | Invite and People are separate tabs; row icons are hard to read | One People tab: compact code on top, requests next with ✓ / ✕, then viewers with one playing / waiting icon each. Panel tabs go from four to two. The panel button leaves the toolbar; faces and chat open the panel. | 4 tabs → 2 |
| 4 | Audience options | Options tab fills the panel beside the picture | LIVE ▾ opens Hold and Stop, three toggle tiles (Ask first, Pointers, On my Mac), quality bars with frame rate under ⋯, and the current network and local address as read-only chips that open Settings | 3 → 1 |
| 5 | Permissions | A scrolling page of paragraphs; Location is cut off | Icon tiles with a status badge or Allow; reasons behind ⓘ; Setbeam asks when a source needs access | scroll → glance |
| 6 | Viewer joins | With Ask first off, the name card still comes before the picture | The picture plays at once with a placeholder avatar; the viewer adds a name the first time they chat or point | 2 → 0 |

## Behavior changes needing approval

1. The empty stage lists detected sources. Displays and windows show
   thumbnails only when Screen Recording is already allowed. Cameras and
   transmitters show device art; no camera opens before it is chosen.
2. Go Live opens the People panel with the codes while nobody has joined.
3. Test My Setup is removed. The readiness strip replaces it: picture and
   outgoing sound come from the actual outgoing feed, Wi-Fi from the
   invitation, and Scan from the first confirmed playback.
4. Invite merges into People, and Options moves to the LIVE menu. Viewing
   network and local address are set in Settings.
5. Permissions become tiles. Explanations move to ⓘ and help text.
6. With Ask first off, viewers watch before naming themselves. With Ask first
   on, the join card is unchanged.

## Unchanged

- Hold sends the holding picture and silence; local monitoring continues
  through Hold and Stop.
- Changing source still holds viewers until the operator resumes.
- SAMPLE stays a word over sample media. Wireless tiles keep their tested or
  untested hardware marks from `hardware-tests.md`.
- Every icon keeps an accessible name, tooltip and keyboard path.

## Open questions

- Should the readiness strip keep the explicit Expected Sound choice, or trust
  the outgoing audio state shown on the Sound step?
- Should the LIVE menu keep frame rate under ⋯, or move it to Settings?
- Without a name, does a viewer's placeholder read as "Guest 2" on the Mac?
