# Floating preview design study, 2026-11-06

Austin requested an iterative design debate with Claude Opus 5.5 at high effort,
followed by a current-versus-proposed comparison. This is a design study, not an
application implementation or build.

Four delegated Opus review rounds returned 7/10, 9/10, 9/10, then an explicit
10/10 approval against the design brief with no remaining must-fix. Sol agrees.
The complete debate and final specification are retained under ignored
`design/mockups/floating-preview-v2/`.

The agreed layout replaces the hidden 52-point hover accessory with one attached
48-point bar. Its 20-point upper row concerns the local picture, zoom and local
sound. Its 28-point lower row concerns true audience state, waiting requests,
Hold/Resume and More. The 220-point minimum remains. Controls never cover the
picture or move on hover or request arrival. Pending and failed commands retain
the last confirmed audience state. Pointer use must leave the working app's
keyboard focus alone; keyboard entry is explicit.

Visual revisions include a one-point neutral picture/bar boundary, a single amber
token, a failed-action badge entirely inside its button, and recovery arrows
distinct from the failed-command exclamation. A synthetic dark source checks
the boundary without capturing private content from Capture One.

## Evidence

- `comparison.png` shows the unaltered native build 31 sample capture beside the
  proposed chrome. `comparison.prototype.html` is self-contained and interactive.
- `stress-220.png`, `portrait-220.png` and `pending.png` show additional simulated
  design states. Portrait mode contains the complete landscape sample; it is
  not a real portrait-source capture.
- Forty-eight browser geometry combinations pass across two container shapes,
  three widths and eight states. The bar remains 48 points, labels fit, action
  coordinates stay stable, aspect ratios are preserved, Private has no waiting
  requests and Fit resets zoom.
- Seventeen simulated interaction checks pass, including pending Hold/Resume,
  admission/decline slot stability, Fit, sound, source loss, failed Hold, Stop
  cancellation/confirmation, private preparation and preview close/reopen. The
  first interaction run found duplicate icon/control IDs in the prototype;
  namespacing those IDs fixed the controls before the passing run.
- The standalone SwiftUI proof compiles in Swift 6 with no warnings and renders
  220/340/500-point footers at 1×/2× plus a synthetic dark-source window. The
  system font measures "Recovering" at 60.989 points in its available 64 points.
- Fixed explicit colors with `appearsActive = false` validate the proposed
  rendering, not real inactive-window focus or native control behavior.
- Browser snapshot calls twice failed with
  `Preview automation snapshot timed out after 15000ms.` HTML captures and DOM
  inspection succeeded. These are separate observations.

The native implementation, focus handoff, VoiceOver, Full Keyboard Access,
Reduce Motion behavior, runtime commands, resize/offscreen restoration and
physical-source qualification remain future work. No app/media regression suite
was run for this design-only study. No production app source, installation,
media behavior, hosted CI, commit, push or PR changed.

## Delivery

Austin Deliveries reports delivered with remote verification under Setbeam /
Floating preview. Receipt `20261106T075341Z--66e667954a17` contains the comparison
PNG, self-contained interactive HTML and final design/debate notes.
[Open the design delivery](https://drive.google.com/drive/folders/1gFCl1L81Yv2_ePZvJeDNg10rZ2Ztz_JH).

The current screenshot's SHA-256 is
`9e6f02b09aa71558646502e5add7ced855675df200de4cf939b143091ba5ea57`,
identical to the original build-31 native capture. The final comparison is
`987f0782557c9accf191d1023f958ccaedf66160567a907fa36c5dfc52a09bc8`.
The delivered HTML is
`cd8f59c327c19166e90cca44521cd152b4c90223c4b11112af083b89c3d969df`.
