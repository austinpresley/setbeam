# Getting started

Setbeam receives a computer display or camera feed on your Mac, then shares it with nearby browser viewers. The Mac's main window and floating preview use the same received feed.

## Install the prerelease

[Download Setbeam 0.3.0 build 41](https://github.com/austinpresley/setbeam/releases/tag/v0.3.0-build41) for an Apple Silicon Mac running macOS 14 or later. Open the disk image and drag **Setbeam** to Applications. FFmpeg, MediaMTX, the native preview helper, fixtures, and dependency notices are bundled. You do not need Homebrew to run it.

The app is signed with Developer ID and notarized by Apple, so macOS opens it normally. Setbeam checks for signed updates once a day. Choose **Setbeam → Check for Updates…** to check now, or turn automatic checks off in **Settings → Updates**. Installing an update quits and reopens the app. An update found while you're sharing waits in the menus.

Build 40 and earlier can't update themselves; install build 41 once by hand. Because the signature changed, macOS asks again for Screen Recording, Camera, Microphone, Local Network and Location access the first time each is needed.

The development build was tested on macOS 27. Older supported macOS versions still need physical verification. See the [release notes](releases/0.3.0-build41.md) for validation and current limits.

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

The default source build is ad-hoc signed, not notarized, and doesn't check for updates. Public releases are built with [the release procedure](releasing.md).

## Connect a source

Open the source control at the top left and choose a detected source or your last working setup. **Enter Stream Address** in the chooser opens RTSP setup directly. The CineView guide offers the Accsoon SEE incoming-stream route. These controls describe the current developer build; earlier published builds use the older menus. For this computer's display, choose **Displays** and select the display name/resolution. Allow Setbeam in Screen Recording when requested, then retry. Setbeam excludes its own windows and includes your cursor. This source has no sound. If the display disconnects, Setbeam waits for that same display.

To share one application window instead, such as Capture One, choose it under **Application windows** in the same chooser. Windows are listed with their application, title, and an updating preview once Setbeam has Screen Recording access; opening the chooser never asks for it. Only that window is shared, without sound, wherever it moves and even when other windows cover it. Its size when chosen sets the picture size; after a resize the whole window is fitted inside that picture without cropping. Minimizing it, hiding its application, or closing it pauses the picture until that same window is shown again. If its application quits, choose the window again: Setbeam never switches to another window or the whole display. After relaunch, Setbeam restores the window privately only while its application is still running.

For the physically tested Accsoon CineView Master 4K on firmware 3.30:

1. Power the transmitter and give it a live HDMI or SDI picture from a computer or camera.
2. Join the Wi-Fi network named on the transmitter's screen.
3. Choose the detected model and network in Setbeam.

Once Setbeam confirms a sustained picture and fresh local playback, it remembers the setup. The next launch restores private monitoring with sharing and Hold off. Complete network addresses and incoming credentials use Keychain.

For the ported Hollyland Pyro H connection:

1. Power the Pyro H transmitter and supply a live HDMI picture from a computer or camera.
2. Join the **transmitter's** Wi-Fi on the Mac. Close HollyView or other clients receiving directly from that transmitter.
3. Open **Choose a source**. Setbeam checks only that Wi-Fi router for the original launcher's `/live` stream on ports 5554, 554, and 8554. Choose **Hollyland Pyro H** when a compatible stream appears, after confirming the connected transmitter model.
4. Check the private picture, then start sharing when ready. For another IP/port, enter the complete RTSP address under **Source → Enter Stream Address**.

The Pyro H software path is tested with simulated H.264/AAC media; a physical Pyro H has not been verified in Setbeam. Discovery checks a compatible endpoint, not a unique transmitter identity. A proven setup restores its exact saved address privately and retries that address after loss. It does not switch Wi-Fi or substitute another discovered endpoint. Discovery pauses during network-source monitoring to protect transmitters with a single-client limit. See [Pyro H verification](verification-pyro-h-2026-10-29.md) for evidence and the remaining hardware checks.

Connection route, model, and firmware matter. See [hardware tests](hardware-tests.md) for exact evidence and open checks. Other transmitters, camera-content formats, and physical capture hardware remain unverified.

## Monitor on your Mac

Your monitor shows the picture as received. Transmitter and network streams are not re-encoded for local monitoring, and only the viewers' copy is converted for browsers. The Mac's display stays awake while a live picture is visible in the main window or floating preview.

The speaker control changes sound on this Mac. The adjacent picture-in-picture control opens the resizable [minimal floating preview](#minimal-floating-preview), with local inspection and audience actions.

Use the Source menu for **Source Details**, the Monitor menu for **Save Frame**, and the Sharing menu for invitations, viewers, options and chat. **Test My Setup** is in Help. Capture frame rate, explicit capture sound and transmitter rejoin belong to Source Details. Permissions and diagnostics open from Settings or Help.

Native audible output remains unverified. On the development Mac, the audio device stalled during startup; Setbeam returned to mute with an explanation. The outgoing stream contains audio, and silent Hold is verified. See [current limits](status.md#remaining-evidence-and-release-work).

## Invite viewers

Click **Start Sharing** above the picture. Open the **Sharing** toolbar control,
then choose **Invite**, or use **Sharing → Invite Viewers**. Viewers can scan the
code or open a copied link. Click either small QR code or **Enlarge Codes…** to
show larger Wi-Fi and viewing codes side by side. **Done** or Escape closes
them. **Sharing → Show Large Join Codes…** opens the same view.

**Viewers** shows requests first and playback problems before other joined
sessions. The circles in **Asking to join** and **Joined** use each viewer's
chosen color, including later color changes. Hover a circle to see its color
name. Names and colors are labels chosen by viewers, not verified identities.
Joined counts browser sessions; playback health appears separately. With viewer approval on, admitted sessions remain listed until you remove them or stop sharing. **No recent update** means playback is unconfirmed; the session still has access and its Remove action remains available.

The main window has one local picture. Sharing contains Invite, Viewers, Options
and Chat without a second live thumbnail. Clicking sharing status opens or
focuses this Sharing home and preserves the last selected tab.
Sharing can sit beside the monitor or in its own window. The independent window
keeps its own audience controls; opening or closing it never changes media.

If the viewing network is **This Mac only**, invitations show **Choose viewing network** instead of a QR code. Select a network your viewers can reach, then start sharing again.

Viewers need network access to the Mac. Ethernet can serve viewers while Wi-Fi receives a transmitter. Optional viewing Wi-Fi details add a join code without changing the Mac's Wi-Fi connection.

Each viewer receives a separate copy of the picture. With several phones on one Wi-Fi network, open **Sharing → Sharing Options** and choose a lighter **Picture quality** (12, 6, or 3 Mbps per viewer). Your local monitor is unaffected. Open viewer pages reconnect at the new rate.

For Capture One or other still-image review, set the viewers' **Frame rate** to **1 fps** in Sharing Options. Keep **Picture quality** at Best when image detail matters more than motion. FPS changes keep the same image dimensions and bitrate allowance, and external-source local monitoring keeps its original cadence. **Match source** restores the incoming rate, up to 30 fps.

When using **This Mac's screen** or an application window, **Capture frame rate** in Source Details independently controls the local capture rate. Choose **1 fps** there as well to reduce capture work, or leave **Match display** for the display's rate, up to 30 fps. Both FPS choices are remembered; relaunch still starts privately.

Viewer pages and signaling use local HTTP. Use a trusted local network and keep the viewing link private. It grants read-only media access; admitted viewers may use chat and pointers. Setbeam has no internet relay or remote account service.

## Hold, resume, or stop

The labeled controls above the local picture stay available while the Sharing
panel is closed. **Hold** replaces the audience's source picture with a holding
screen and suppresses source audio in the outgoing media. Local monitoring
continues against the same dark surround in light and dark appearance.
The main picture keeps monitoring the source during Hold. The sharing status
confirms when viewers receive the holding output. A requested change remains
**Applying Hold** or **Resuming sharing** until its output is confirmed. A
failure offers **Retry Hold** or **Retry Resume** for the intended change.
**Resume Sharing** restores the feed through the same viewer page.
**Stop Sharing** ends audience access while leaving your local monitor available. If a viewer permission change cannot be confirmed, Setbeam stops sharing and retires that viewing link. Your private monitor continues. Start sharing again to retry; permissions must apply before the outgoing picture starts.

On the viewer page, sound stays directly available. The three-dot control opens
secondary actions, which also appear on pointer movement or keyboard focus.
Focused controls and open editors stay visible. Pointing keeps its picture
gestures; use the three-dot control while actively pointing.

## Recover a connection

The selected source and open viewer pages retry after interruptions. Temporary viewing-network loss preserves sharing and Hold while Setbeam waits for the same interface. Wi-Fi selection stays under your control.

If a transmitter power cycle leaves the Mac on another Wi-Fi network, you can turn on **Rejoin automatically** for the saved transmitter in Source Details and enter its Wi-Fi password. It is off by default and asks for Location access, which macOS requires before an app can find a Wi-Fi network by name. Setbeam does not switch networks while viewers depend on the Mac's Wi-Fi.

If the Mac receives a different IP address, viewers need the updated viewing code. Stopping sharing or quitting ends the audience session. Reopening the app restores private monitoring.

To see what happened during a dropout, choose **Show Session Log** in Settings → Diagnostics. The log records connection, recovery, and sharing events with timestamps. It leaves out stream addresses, keys, and viewing links.

See [project status](status.md) for remaining work, [the execution plan](plan.md) for scope, and [architecture](architecture.md) for implementation details.

## README screenshots

The README's [dark](../Assets/screenshots/main-dark.png) and [light](../Assets/screenshots/main-light.png) main windows, [browser viewer](../Assets/screenshots/viewer.jpg), and [Sharing Options](../Assets/screenshots/sharing-options.png) show build 40. They use explicitly labeled fictional sample media from the local QA launch mode, not a physical source. The main windows and options are unmodified native PNG captures. The browser image is a page capture exported as JPEG. No controls or media were composited. Capture and release evidence is recorded in [build 40 verification](verification-release-build40.md). The portrait's generation notes remain in [Fixtures/sample-image-notes.txt](../Fixtures/sample-image-notes.txt).

## Minimal floating preview

Use Monitor > Show Floating Preview to keep the local picture above your working
app. Hover reveals Close and, while sharing, the centered pause action. On Hold,
a subtle dark veil and a persistent play button let you resume. The local picture
continues beneath the veil. A small viewer shortcut stays visible when sessions
are joined or waiting and opens individual viewer actions.

Pointer use leaves your working app's keyboard focus alone. Use Monitor > Focus
Floating Preview for deliberate keyboard control. Tab moves through controls;
Space presses a focused action. Plus/minus and arrows inspect the picture; 0
fits it. Escape returns focus, and Command-W closes only the floating preview.

Pinch or scroll to zoom, drag a zoomed picture to pan, and double-click the
picture outside the controls to fit it. At full picture, drag to move the window
and use its edges to resize. A pointer Resume waits through the Mac's double-click
interval so another click or picture gesture can cancel it. Hold is immediate.
Sound and less frequent sharing settings remain in the main window and menus.


## Chat and shared display pointers

Open **Sharing → Show Chat** or press Command-4. Admitted viewers open chat from
the speech-bubble button in the viewer header. Each message uses its author's
name and cursor-color arrow. Reply, like, or capture a frame and preview it before
Send. The DigiTech can remove a message and its image for everyone. A badge marks
the DigiTech; viewer names are labels chosen by viewers.

Chat is shared within the current viewing session on the local network. It is
not encrypted, is held in memory and clears at Stop. Previously sent images stay
in chat during Hold. New frame attachments require live outgoing video and the
same source revision; the Mac uses its outgoing preview, never the private local
picture. Sample images keep their label. Unread messages appear in Sharing and
the viewer header.

For a **This Mac's screen** source, turn on **Show pointers on shared display**
in Sharing Options or the Monitor menu. Pointers pass clicks and typing through
to the source app and stay outside Setbeam's captured video. This choice starts
off and resets at Stop, a source/display change, sleep or session deactivation.
Hold hides the overlay. External transmitting computers and application-window
sources cannot use this display overlay. Preview pointers remain a separate
choice.

## Viewing Wi-Fi and portable join codes

In Invite, edit viewing Wi-Fi and choose a cached network or type its name. macOS
asks for Location only after **Allow Wi-Fi Names…**. Refresh is explicit and is
unavailable during sharing or network-source reception. Selecting a name never
joins it. Secured networks require a password; select **Open network** only when
there is none. Password-format feedback is not a connection test. Save the
settings and scan the Wi-Fi code with a phone to test actual joining.

Choose **Sharing → Open Join Codes in Window** for independent resizable codes.
Select Both, Feed or Wi-Fi and use **Keep on Top** when needed. Save PDF and Print
produce dated snapshots. Viewing codes expire at Stop; a Wi-Fi code includes any
saved password. If a saved password is unavailable, re-enter it before exporting
that Wi-Fi code. Feed-only export remains available independently.

Opening Setbeam from Applications or the Dock brings back the main monitor,
including when it was closed or minimized. Reopening leaves current monitoring and sharing alone. Cold launch restores
monitoring privately. The menu-bar menu puts Open Setbeam first and
keeps sharing controls, floating preview and pending join requests close at hand.


In native chat, open a message's three-dot menu to Reply, Like or Remove for
Everyone. Click an image attachment to enlarge it. The camera in the composer
attaches an outgoing frame for review before Send. Your name and arrow open
identity editing; the information button explains chat lifetime and privacy.
The Sharing status tooltip reports outgoing picture confirmation and whether
an audio track is included without adding another picture.
