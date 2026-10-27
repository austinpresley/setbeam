# Getting started

Setbeam receives a computer display or camera feed on your Mac, then shares it with nearby browser viewers. The Mac's main window and floating preview use the same received feed.

## Build from source

Use an Apple Silicon Mac with macOS 14 or later. Install Xcode with Swift 6, Python 3.12 or newer, Node.js, `make`, `pkg-config`, and `curl`.

From the repository root:

```sh
scripts/build-runtime.sh
scripts/check.sh
scripts/build-app.sh
open build/Setbeam.app
```

Third-party build products stay under the ignored `Vendor/` directory. The app bundles its runtime and needs no Homebrew installation to run. Pinned versions and source hashes are in [runtime-lock.json](../runtime-lock.json); licensing and bundled source details are in [third-party notices](../THIRD_PARTY_NOTICES.md).

The default build is ad-hoc signed and is not notarized. No public release is available. The development build was tested on macOS 27; older supported macOS versions still need physical verification.

## Connect a source

Open the source control at the top left and choose a detected source, your last working setup, or the labeled sample. RTSP addresses, incoming RTMP, and manual connection settings are in **Advanced** under the gear menu. For this computer's display, choose **This Mac's screen** and the display name/resolution. Allow Setbeam in Screen Recording when requested, then retry. Setbeam excludes its own windows and includes your cursor. This source has no sound. If the display disconnects, Setbeam waits for that same display.

For the physically tested Accsoon CineView Master 4K on firmware 3.30:

1. Power the transmitter and give it a live HDMI or SDI picture from a computer or camera.
2. Join the Wi-Fi network named on the transmitter's screen.
3. Choose the detected model and network in Setbeam.

Once Setbeam confirms a sustained picture and fresh local playback, it remembers the setup. The next launch restores private monitoring with sharing and Hold off. Complete network addresses and incoming credentials use Keychain.

Connection route, model, and firmware matter. See [hardware tests](hardware-tests.md) for exact evidence and open checks. Other transmitters, camera-content formats, and physical capture hardware remain unverified.

## Monitor on your Mac

Your monitor shows the picture as received. Transmitter and network streams are not re-encoded for local monitoring, and only the viewers' copy is converted for browsers. The Mac's display stays awake while a live picture is visible in the main window or floating preview.

The speaker control changes sound on this Mac. The adjacent picture-in-picture control opens the resizable floating preview. Zoom or pan there to inspect detail; double-click or press `0` to restore the whole picture.

The gear menu contains **Test my setup**, viewing-network settings, capture audio routing when applicable, **Save frame**, Advanced, and diagnostics.

Native audible output remains unverified. On the development Mac, the audio device stalled during startup; Setbeam returned to mute with an explanation. The outgoing stream contains audio, and silent Hold is verified. See [current limits](status.md#remaining-evidence-and-release-work).

## Invite viewers

Click **Start sharing**, then open the QR control in the footer. Viewers can scan the code or open a copied link. **Show join codes** opens a sheet you can leave visible for a group. The sharing state and playback count open the actual outgoing picture, audience sound, and opened/playing counts.

Viewers need network access to the Mac. Ethernet can serve viewers while Wi-Fi receives a transmitter. Optional viewing Wi-Fi details add a join code without changing the Mac's Wi-Fi connection.

Each viewer receives a separate copy of the picture. With several phones on one Wi-Fi network, choose a lighter **Viewer picture** in Advanced (12, 6, or 3 Mbps per viewer). Your local monitor is unaffected. Open viewer pages reconnect at the new rate.

Viewer pages and signaling use local HTTP. Use a trusted local network and keep the viewing link private. It grants read-only viewing access. Setbeam has no internet relay or remote account service.

## Hold, resume, or stop

**Hold** replaces the audience's source picture with a holding screen and suppresses source audio in the outgoing media. Local monitoring continues. **Resume** restores the feed through the same viewer page. **Stop sharing** ends audience access while leaving your local monitor available.

## Recover a connection

The selected source and open viewer pages retry after interruptions. Temporary viewing-network loss preserves sharing and Hold while Setbeam waits for the same interface. Wi-Fi selection stays under your control.

If a transmitter power cycle leaves the Mac on another Wi-Fi network, you can turn on **Rejoin automatically** for the saved transmitter in Advanced and enter its Wi-Fi password. It is off by default and asks for Location access, which macOS requires before an app can find a Wi-Fi network by name. Setbeam does not switch networks while viewers depend on the Mac's Wi-Fi.

If the Mac receives a different IP address, viewers need the updated viewing code. Stopping sharing or quitting ends the audience session. Reopening the app restores private monitoring.

To see what happened during a dropout, choose **Show session log** in Advanced. The log records connection, recovery, and sharing events with timestamps. It leaves out stream addresses, keys, and viewing links.

See [project status](status.md) for remaining work, [the execution plan](plan.md) for scope, and [architecture](architecture.md) for implementation details.

## README screenshots

The README's [dark](../Assets/screenshots/main-dark.jpg) and [light](../Assets/screenshots/main-light.jpg) images are unmodified native Build 8 captures of the full-width layout retained in Build 9. They show fictional sample media, not a physical source. Capture evidence is recorded in [layout verification](verification-layout-2026-10-20.md); the portrait's generation notes are in [Fixtures/sample-image-notes.txt](../Fixtures/sample-image-notes.txt).
