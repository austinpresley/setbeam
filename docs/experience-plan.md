# Dependable setup and native polish

Austin authorized the complete experience pass on 2026-10-20. Opening Setbeam should restore a proven local picture. Sharing always requires an explicit action after launch.

## Design

The live picture is the largest element. A quiet header names the feed and its input; the audience column explains exactly who can see it. Connection steps appear beside the missing picture. A device chooser uses the names macOS reports and device illustrations, without inventing a camera behind a capture device.

Use the system font and native controls, with 24-point window padding, a 24-point feed title, 13-point body controls, and 11-point supporting text. Native semantic colors adapt to appearance and contrast settings. The light appearance reference colors are window #F5F5F7, text #1D1D1F, secondary text #6E6E73, action #007AFF, success #248A3D, and attention #9A6700. Status always includes words and symbols as well as color. Respect Reduce Motion and preserve keyboard access.

This follows the requested Apple direction. It avoids decorative dashboard cards and puts the working picture, source identity, and private/sharing state first.

## Acceptance checklist

| Behavior | Acceptance | Evidence |
| --- | --- | --- |
| Recognize hardware | Show detected device name and illustration; resolve saved unique identity after enumeration changes; never substitute another device | Implemented. Native chooser identifies the physical Master 4K and SSID. Discovery/identity tests pass; bundled capture adapter resolves exact IDs in-process. Capture hot-plug physical evidence remains open. |
| Minimal physical guidance | Explain the missing cable, source power, permission, or named Wi-Fi; confirm with fresh source and preview frames | Passed native sample and physical Master 4K setup. Empty stream arrays produced input guidance; restored source confirmed with decoded frames. |
| Remember a proven setup | Persist only after sustained reception and native playback; failed choices preserve the last working setup; credentials use Keychain | Readiness/store tests pass. Native sample and real Accsoon require two seconds of fresh reception and native playback before confirmation. |
| Private automatic restore | Restore that same setup on launch; never restore sharing or Hold after app launch | Passed sample and real Master 4K. Quit from active Hold, reopen same setup and floating monitor with sharing/Hold off. |
| Advanced | Stream addresses, interface selection, sound-input routing, and diagnostics are disclosed in Advanced | Native inspection passed. Simple viewing Wi-Fi sheet contains only join-code details. |
| Automatic recovery | Recover stopped or stalled source, preview decoder, and media server with bounded retry delays; retain source identity and in-session Hold | Automated stopped/stalled source and server checks pass. Physical input-helper failure recovered in 4.3 s; Wi-Fi rejoin restored the same unit. Preview restart is supervised; exhaustive OS sleep/wake remains open. |
| Honest readiness | Stale frames remove the healthy state; old pictures are visibly marked; audience readiness includes its actual relay | Stalled-source integration check and real Wi-Fi interruption pass. Native/browser status follows actual frame freshness. |
| Useful recovery | Show one relevant physical action or retry, with technical diagnostics available in Advanced | Inspected no-input, disconnected source, joining, and sound-output fallback states. No raw stream address is required for the tested Accsoon. |
| Clear audience state | Private, Sharing, Reconnecting, and On Hold are visible; local monitoring survives Hold/Stop | Actual-media probe and native/Chromium checks pass with sample and physical Master 4K. Actual outgoing Hold video differs and audio is silent. |
| Workspace | Restore main/floating geometry, floating visibility, and local sound preference; closing the app does not erase visibility preference | Native relaunch and floating-frame checks pass. Unmute preference survives host audio timeout while actual playback returns to mute. Audible output remains unverified. |
| Viewer joining | Automatic LAN choice, optional Wi-Fi QR, viewing QR, copy link feedback, opened versus playing status, and reconnecting viewer without reload | Native/Chromium pass. Wi-Fi join metadata was saved/cleared without changing the active viewing link or playback. Physical phone QR scanning remains open. |
| Native polish | Inspect compact and resized native layouts, light/dark appearance, accessibility labels and keyboard actions; inspect mobile viewer layout | Native inspection passed. Chromium at 390×844 and 1280×800 fits without overflow. Viewer respects reduced motion and uses accessible controls. VoiceOver end-to-end remains open. |
| Portable delivery | Required checks, bundled dependency audit, app signing check, packaged runtime checks, and private delivery | 26 tests plus packaged media checks pass; system-only dependency audit and strict ad-hoc signature verification pass. Distribution launch/delivery are recorded in the build 3 verification record. |

Hardware compatibility remains a separate evidence requirement in hardware-tests.md. Generic discovery, successful sample playback, and local RTSP tests do not prove any named transmitter, physical capture route, phone, or Safari support.
