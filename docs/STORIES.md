# Setbeam future backlog

Recorded: 2026-10-31, from Austin's screen-sharing and collaborative-review requests.

These stories record requested work and its implementation state. S-001 is
implemented in Build 21, S-002 in Build 24, S-006 in Build 23, and S-008 in Build 22. S-003 and S-005 have partial
foundations shipped with S-008; their remaining work is recorded below. Other
stories are future work without a promised release date. Existing behavior and
evidence remain in [status.md](status.md)
and [architecture.md](architecture.md). The order below is a proposed dependency
order, with private sharing before collaborative pointers. UX details for future
stories will be worked through before implementation.

## Later: share a selected window

### S-001 Share one application window

As the operator, I choose a single application window, such as Capture One,
instead of sharing an entire display.

Screens: Choose a source, main monitor, floating preview, browser viewer.

Acceptance:
- [snap] The source chooser offers application windows alongside entire displays and clearly identifies the selected window.
- [self] One capture supplies local monitoring, floating preview, and audience sharing; unrelated desktop windows are absent from the shared picture.
- [self] Closing or losing the chosen window produces an unavailable state without substituting another window or the whole display.
- [self] Hold suppresses outgoing source picture and sound, and Stop Sharing leaves local monitoring available.
- [manual] Check window movement, resizing, occlusion, minimization, closing/reopening, permissions, and multiple displays on the supported macOS versions; document the actual limitations.

Verification: Implemented in Build 21, commit `225fd5e`. See
[window source verification](verification-window-source-2026-11-01.md) for local
automated checks, real window capture, native dark/light chooser previews,
browser sharing, Hold/Stop, exact-window restoration, and both Sol approvals.
Capture One itself, multiple displays/mixed scaling, attached sheets/full-screen
windows, VoiceOver, and the Finder-launched app's own recording grant remain
unverified. A resized window fits within the initial capture dimensions until
Retry now restarts capture at its new size.

Status: done

## Later: optional viewer access controls and details

The existing viewer already accepts optional names and reports playback health.
Extend those capabilities rather than introducing accounts or another roster.

### S-002 Request access with a viewer name

As a viewer, I enter a display name when a session asks me to identify myself.

Screens: browser join page, browser Connection help, operator viewer details.

Acceptance:
- [snap] An approval-enabled session asks for a name before requesting access and shows a clear waiting, admitted, or declined state.
- [self] Ordinary link sharing retains its existing optional-name behavior when approval is disabled.
- [unit] Names are bounded plain text; duplicate names remain distinguishable by browser session number and are not treated as verified identities.
- [self] Names are not placed in viewing links or disclosed to other viewers unless the operator enables shared pointers.

Verification: Implemented in Build 24 on the Build 22 admission foundation. The dedicated join page, explicit Ask, bounded names, preserved pass states, duplicate-name session numbers, optional naming with approval off, and retired-link retries passed local browser/controller and real-media checks. GPT-6.1 Sol on high approved in round 2 after one expired-link fix. Physical phone/tablet/second-computer, real keyboard overlap, and spoken accessibility checks remain open. See [viewer join verification](verification-viewer-join-2026-11-02.md).

UX (Build 24):
- Flow: open the link -> session title and Ask to join card -> type or review the name -> Ask to join -> Waiting for the operator -> Admit starts the picture; Decline or Remove shows the decision -> reload keeps the state
- Surface: a join card replaces the picture and control bar until the session is admitted; admitted viewers keep the picture-first page
- States: ask; sending; waiting with "Asking as Sam (session 4)"; declined; removed; busy with Try again; link no longer active with Try again; sharing ended; offline or failed send; connection lost while waiting; lapsed request asks again with the name kept
- Words: "Ask to join", "Your name", "Only the operator sees this name. Names are not verified.", "Waiting for the operator"
- Access: focus moves only when the step changes; touch does not open the keyboard by itself; messages use a status region; reduced motion stops the spinner

Build 24: a saved name pre-fills the form but never sends a request; the
gateway requires an explicit ask under approval. Restored passes resume without a
new request, and turning approval off while the form is open plays without a name.
Local browser emulation and real-media checks pass, and GPT-6.1 Sol review is
approved. Physical phone, tablet, and second-computer checks remain open. See
[viewer join verification](verification-viewer-join-2026-11-02.md).

Status: done

### S-003 Approve or remove an individual viewer

As the operator, I optionally enable viewer approval, admit or decline requests,
and remove a viewer without interrupting the other viewers.

Screens: sharing options, pending requests, operator viewer details, browser join page.
Depends: S-002.

Acceptance:
- [snap] Approval is an explicit session option; pending requests and admitted browser sessions have distinct actions and states.
- [self] Pending and declined sessions cannot obtain source media, playback credentials, viewer presence, or administrative access by bypassing the join page.
- [self] Removing a viewer terminates its existing media access and invalidates its playback authorization; reloading an old link cannot silently readmit it.
- [self] A shared session-wide media credential is not sufficient for individual revocation. Verify per-viewer authorization through actual playback, not only UI state or heartbeats.
- [self] Admission and removal preserve other viewers, local monitoring, Hold, and Stop Sharing behavior.

Progress: Partial in Build 22; authorization enforcement is implemented. Optional
approval, Admit/Decline/Remove, per-viewer read credentials, bypass rejection, and
active-media revocation were checked with real local media sessions. Physical
multi-device qualification remains open. See [shared pointers verification](verification-shared-pointers-2026-11-01.md).

Status: doing

### S-004 Offer an optional session password

As the operator, I can choose an additional session password if this option is
included after access-control design.

Screens: sharing options, browser join page.
Depends: S-003.

Acceptance:
- [snap] Password protection is optional and distinct from operator approval; a password does not grant publishing or administration rights.
- [self] Missing or incorrect passwords cannot obtain playback or presence credentials; failed attempts have bounded retries.
- [self] Passwords do not appear in URLs, QR codes, logs, or ordinary preferences, and changing the password invalidates the intended admissions.
- [manual] Resolve and verify credential protection for local-network browser transport before implementation; describe any actual protection limits accurately.

Open decision: Candidate option; exact admission/password policy still to design.

Status: todo

### S-005 Inspect a viewer's basic session details

As the operator, I see who is connected and whether their picture is playing,
with a small amount of useful session information.

Screens: operator viewer details, struggling-viewer details.
Depends: S-002.

Acceptance:
- [snap] Show name or numbered fallback, admission/playback state, joined time, last update, and the existing plain-language playback-health indicator.
- [self] Optional technical details use available browser measurements, such as received dimensions, frame rate, packet loss, jitter, and round-trip time. Missing data stays unavailable.
- [unit] Hold, background, paused, blocked playback, stale reports, and replaced peers remain distinct from poor playback.
- [self] A browser session is not labeled as a unique person or physical device. Round-trip time is not labeled as end-to-end video delay, and playback health is not Wi-Fi signal strength.
- [self] The roster stays operator-only. Shared-pointer participants receive only the minimal name/color/pointer presence enabled for that session.

Progress: Partial in Build 22. Rows add admission state, pointing state, and color
to existing names, session numbers, and playback health. Joined time, last update,
and optional technical measurements are not yet shown.

Status: doing

## Later: easier joining

### S-006 Open a friendly local address

As a viewer, I can use a readable local address when QR scanning is inconvenient.

Screens: invitations, persistent QR panel, browser unavailable/help page.

Acceptance:
- [snap] Offer a friendly local hostname while retaining Copy Link, QR invitations, and a numeric-address fallback.
- [self] Local name discovery works without an internet service; verify the selected viewing interface and collision handling when two Macs share the network.
- [self] A hostname never bypasses the private session token, approval, or optional password. Expired sessions stay expired.
- [manual] Check supported desktop, phone, and tablet browsers, local-network permissions, DHCP address changes, and networks that block multicast discovery. Do not promise universal `.local` support or a permanent reusable session link.

Compatibility: physical phone/tablet, second-computer, local-network permission, actual DHCP-change, and multicast-blocking-network checks remain open.

Decision (2026-11-02): publish `<name>.local` through the system DNS-SD responder on the selected viewing interface while sharing, default `setbeam`, editable in Settings. Conflicts move to `name-2` and later numbers. Join codes keep the IP address. The private code still makes hand-typed links impractical.

UX:
- Flow: ⌘, or gear > Viewing network… -> Viewer network > Offer a local address, Local address field -> inline validation -> Save applies at once, and while sharing the link's host changes and its code stays -> status line shows the effective name
- Surface: inline in the existing Advanced sheet (changes one value); invitation row in the join sheet; one caption in the QR panel
- States: off; used while sharing; checking; active; in use, so viewers use `name-2`; unavailable, so invitations use the IP address; invalid name with Save disabled; unsaved change
- Words: "Offer a local address", "Local address", "Copy viewing link", "Copy IP address link", "Viewers on this network can open setbeam.local."
- Access: field labeled "Local address name"; warnings pair orange with a symbol and words

Implementation: Build 23, reviewed by GPT-6.1 Sol on high and installed locally. Real system-name resolution, collision simulation, selected-interface publication, native dark/light Settings, browser playback, access restrictions, Hold/Stop, and packaged checks pass on this Mac. The private code remains in the link, so the hostname alone does not open the session and hand typing remains impractical. Physical multi-device/network qualification remains open; see [local address verification](verification-friendly-address-2026-11-02.md).

Status: done

### S-010 Type the short address and ask to join

As a viewer on the same network, I type only `setbeam.local` (or the operator's local name), enter my name and color, and ask to join. As the operator, I see each request arrive without leaving the app I'm in, and I admit or decline it from there.

Screens: Advanced > Viewer network, join sheet and QR panel, sharing popover, join request card, Picture and Viewers, floating preview controls, menu bar menu, browser join card.

Acceptance:
- [self] Off by default. Typing the name opens anything only while sharing with Ask before viewers join, the local address, and the option all on, on a network others can join.
- [self] The typed name never reveals the viewing link's code or media credential. Every typed request needs a name, an explicit Ask to join, and Admit. Admitted viewers play with their own read-only reader.
- [self] Port 80 in use, refused, or unavailable is named in Settings and invitations with the link or QR code as the fallback, and is retried. Connections to other local addresses get no reply.
- [self] Turning approval or the option off declines typed requests still waiting and never admits them. Stop retires the typed path with the link; local monitoring continues.
- [snap] Each new request shows a card with Admit and Decline that floats over other apps and the floating preview without taking focus. Several requests, reloads, heartbeats, and answers given elsewhere are handled without repeat alerts or stale actions.
- [manual] Phones, tablets, and other computers typing the name; networks that block multicast; another app owning port 80 on a real set.

Decision (2026-11-03): Austin authorized the opt-in, approval-only short address proposed in [viewer setup verification](verification-viewer-setup-2026-11-03.md) and an approval alert, native or custom. The short address uses its own ask-only code, not the link's code, because that code is also the shared media password and would let anyone who typed the name watch once approval was off. The alert is Setbeam's own card, not a macOS notification: it needs no permission, works when notifications are denied or silenced by Focus, and can carry Admit and Decline that act once. See [short address verification](verification-short-address-2026-11-03.md).

UX:
- Flow: Viewing network… > Viewer network > Offer a local address > Let viewers ask from setbeam.local -> Save. While sharing with approval: viewer types the name -> Ask to join card -> waits. Operator: card in the corner -> Admit or Decline, or later from the sharing bar, Picture and Viewers, floating preview controls, the menu bar, or Feed > Show Join Requests.
- Surface: one toggle inline in the existing Advanced section; a non-activating corner card for alerts, because the decision is time-sensitive and the operator is often in another app; no sheet or alert, which would take focus.
- States: off; needs approval; needs the local address; no viewing network; ready while you share; starting; active; port in use; refused; unavailable (each with the link fallback); one request; several (three rows and "N more…"); card hidden with requests still waiting; stale action; Stop.
- Words: "Let viewers ask from setbeam.local", "Anyone on this network who opens setbeam.local can ask to join.", "Asking to join", "Typed setbeam.local", "Admit", "Decline", "Review…", "Names are chosen by viewers and are not verified."
- Access: Admit and Decline labels name the viewer and session; the card is announced to VoiceOver; every action on the card also exists in keyboard-reachable windows and menus; warnings pair orange with a symbol and words.

Implementation: candidate for build 26, pending review. Status: implemented locally, not yet reviewed or delivered.

## Later: point out picture details together

### S-007 Highlight the presenter's cursor

As the operator sharing this Mac's screen or an application window, I can enable
a visible cursor highlight so viewers can follow what I am pointing at.

Screens: picture/sharing options, main monitor, browser viewer.

Acceptance:
- [snap] Cursor highlighting is optional, clearly distinguished from shared viewer pointers, and leaves ordinary cursor capture usable when disabled.
- [self] The highlight follows the selected captured content through movement, scaling, and source changes without exposing cursor positions outside it.
- [self] Highlighting preserves the single-capture path, picture quality settings, local monitoring, and Hold/Stop behavior.
- [manual] Confirm readability over light and dark pictures and at low screen-capture frame rates. Decide whether the highlight is captured or drawn as an overlay during UX design.

Status: todo

### S-008 Point together with named viewer cursors

As an admitted viewer, I opt into pointing at the shared picture so the operator
and other participating viewers can see my colored pointer with my display name.
This works for both computer-display and camera/transmitter feeds.

Screens: browser pointing controls, multi-viewer picture, native monitor pointer overlay.
Depends: S-002, S-003, S-005.

Acceptance:
- [snap] The operator enables shared pointers for the session; each viewer can start or stop pointing and hide overlays. Pointer color and a visible name distinguish participants.
- [snap] A viewer can choose a color from a small preset palette alongside their name. Start with one cursor shape; optional cursor-shape choices are a later refinement.
- [unit] Colors use validated palette identifiers and readable pointer/name treatments over light and dark pictures. Duplicate colors do not merge sessions or replace name/session identity.
- [self] A stationary pointer and its name fade away after an inactivity interval and reappear on meaningful movement or an explicit pointing action. Heartbeats and repeated unchanged coordinates do not reset the inactivity timer; the exact interval and fade timing will be tuned during UX review.
- [self] Idle expiry also works if the sending page is throttled or loses contact; receivers expire stale positions without waiting for a final hide message from that viewer.
- [self] Pointer updates and animation run independently of source capture and viewer video frame rates. Verify responsive pointer movement with the picture at 1 fps while retaining bounded message rates and queues.
- [self] Pointer locations are relative to the visible picture, with correct mapping across aspect ratios, letterboxing, resizing, browser full screen, and any supported zoom/pan. Movement over page controls is not shared.
- [self] The Mac's monitor and participating browser viewers show the same named pointers. The overlay does not enter the encoded source or require another received feed.
- [self] Pointer messages grant no keyboard/mouse control, media publishing, or administration. Only admitted sessions can send or receive bounded, rate-limited presence data.
- [self] Leaving the picture, becoming inactive, disconnecting, revocation, Hold, Stop, and source/publisher revision changes expire or clear the appropriate pointers. Old positions never appear on a replacement source.
- [self] Only minimal name/color/position presence is shared; private operator roster details, session secrets, and coordinates outside the picture are not broadcast or retained as history.
- [manual] Check simultaneous laptops, touch-to-point on phones/tablets, low-rate still-image review, network loss, and viewer capacity. Page overlays in native phone full screen or video PiP require separate qualification.
- [manual] For moving footage, explain that viewers can be on different frames. Frame-anchored comments or synchronized review are separate future work.

Feasibility: Supported by browser pointer and messaging APIs. Production transport
and native overlays are implemented in Build 22.

Verification: Build 22 code is `c5e5ea6`, with final evidence in `926b6e7`.
[Shared pointers verification](verification-shared-pointers-2026-11-01.md) records
the 178 Swift tests, 31 viewer and 12 pointer checks, real-media admission/removal,
native/browser QA, 26 pointer updates/s with 1 fps video, and approval from both
GPT-6.1 Sol high reviewers in round 3. Real phones/tablets/multiple laptops and
native non-16:9 QA remain open; touch and non-16:9 mapping have controller/unit
coverage. Native video PiP does not include page overlays, and moving footage is
not frame-synchronized. A growing sharing popover can overlap underlying status
text until it is reopened; its controls remain accessible.

Status: done

## Later: temporary drawing tools

### S-009 Mark a detail with a temporary arrow or circle

As an admitted viewer, I can briefly mark a picture detail with an arrow or circle
when pointing alone is insufficient. Defer this until shared cursors are working;
the initial collaboration feature uses cursors only.

Screens: browser pointing/drawing controls, multi-viewer picture, native monitor overlay.
Depends: S-008.

Acceptance:
- [snap] Temporary arrows and circles have explicit tools, use the participant's name/color, and leave the picture readable.
- [self] Marks automatically fade and expire after a bounded lifetime. They are transient overlays, with no persistent drawing history or comments.
- [self] Drawing positions use the same picture-relative mapping as shared pointers, including supported zoom/pan and differing viewer sizes.
- [self] Hold, Stop, source changes, and revoked access clear the appropriate marks. Drawing grants no media publishing, source control, or administrative permissions.
- [manual] Check simultaneous participants, touch drawing, a 1 fps picture, and delayed/disconnected clients before claiming multi-device support.

Status: todo

## S-010: Organize source setup and sharing around the monitor

As the operator, I want source settings, invitations, and viewer management in predictable places while my local picture stays available.

Acceptance:
- [snap] Keep the approved source chooser and monitor-first window. Sharing is an optional trailing panel with Invite, Viewers, and Options, with a separate-window fallback.
- [self] Opening, switching, detaching, and closing Sharing does not change monitoring, sharing, Hold, or viewer identity. Viewer counts and request review open Viewers; invitation actions open Invite.
- [snap] Invite shares one code/link presentation with the large join-code view, including Wi-Fi editing, typed-address status, and explicit IP fallback.
- [self] Viewers shows pending requests first, then admitted sessions with playback health. Admit, Decline, and Remove use the existing server-authorized actions.
- [snap] Source Details owns source name, capture frame rate, capture sound input, saved setup, and transmitter reconnection. Viewer output and admission/network options belong to Sharing.
- [self] Manual stream entry opens directly from the chooser. Settings uses the standard app-menu command and Command-comma. Source, Monitor, Sharing, and Help menus match these responsibilities.
- [self] Browser viewers can edit their identity directly without hiding the picture or replacing the media peer. Approval still fixes an admitted name and permits color changes.
- [manual] Keep hardware compatibility, audible sound, and second-device qualification separate from local automated/native checks.

UX:
- Flow: source control -> Source Details or Choose a source -> local picture; Invite/Viewers indicators -> matching Sharing tab -> close or detach without changing media.
- Surface: optional inspector for ongoing audience work, separate window when needed, focused sheets for source setup, standard Settings window for permissions and diagnostics.
- States: private, sharing, Hold, no viewers, pending requests, reconnecting viewers, limited viewing network, unavailable network choice, invalid local address, no source, and current-source settings.
- Words: Session name is the viewer-facing title; Source name labels the input. Advanced is replaced by Source Details, Sharing Options, and Diagnostics.
- Access: native segmented picker, labeled icon controls, keyboard menu commands, Escape on short tasks, explicit consequences before a network change stops sharing.

Status: implemented in build 29. Opus approved, native/browser verification and the remaining unchanged timing/port-reuse failures are recorded in verification-organization-2026-11-04.md. Manual qualifications remain separate.

## Feasibility references

Browser [Pointer Events](https://www.w3.org/TR/pointerevents3/) cover mouse, pen,
and touch input. The [WebSocket API](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API)
provides bidirectional browser/server messaging. Together with Setbeam's existing
local viewer gateway and session identity, these support the proposed pointer
design. This is a feasibility inference, not an implementation or network test;
the transport choice remains open.

Background browser tabs can have their timers throttled; see the
[Page Visibility API notes](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API#policies_in_place_to_aid_background_page_performance).
Receivers therefore expire idle pointer positions from meaningful-movement age
instead of relying on the sender to transmit a final hide event.

Window sharing is supported by ScreenCaptureKit's
[desktop-independent window filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)).
Behavior on the supported macOS versions still needs implementation and runtime checks.

## Outside this request

Desktop audio and NDI integration were discussed as possibilities but were not
requested for this backlog pass. Persistent drawings, comments, remote control,
and frame-synchronized review are not part of S-008.


## Approved design refinement, 2026-11-08

Austin approved the final three-round design review with current native control sizes, viewer-selected avatar colors, and easy QR enlargement.

UX:
- Flow: Sharing status -> current/last Sharing tab; requests -> Viewers; click either small QR or Enlarge Codes -> larger join codes -> Done or Escape. Opening a presentation never starts sharing.
- Surface: stable main command area, optional Sharing inspector and independent window, existing join-code sheet, contextual browser controls with a persistent keyboard/touch entry and direct sound control.
- States: private, starting, pending Hold/Resume, confirmed sharing/Hold, target-specific failure/retry, outgoing recovery and stopping. Source readiness and outgoing readiness remain separate facts.
- Words: existing CONTEXT.md terms remain authoritative. Joined counts browser sessions; names/colors are chosen and not verified. Incoming connection details name the input destination rather than the viewing network.
- Access: native Mac control sizing, target-specific menu actions, accessible chosen-color labels, clickable QR buttons, Escape/Done, no hidden focused browser controls, and unchanged floating keyboard/pointer paths.

Acceptance:
- [self] Main, menus, outgoing summary and setup checks never certify Hold/silence from intent alone; failed commands retry their explicit target.
- [snap] Remove the permanent Local monitor heading and redundant docked Start action; one outgoing check remains above every Sharing tab.
- [self] All twelve chosen colors survive pending -> joined and later color updates in the same browser session.
- [snap] Both small QR codes have an obvious enlargement path, and large codes decode to the same active payloads.
- [self] Browser controls disclose without changing media, preserve focus and pointer gestures, and leave sound directly available.

Status: implemented in build 34. Packaged checks, native/browser evidence and qualification limits are recorded in verification-design-implementation-2026-11-08.md.

## S-011: Show pointers on the shared display

Opt in to named viewer pointers on the exact display selected by This Mac's screen. The overlay passes clicks and focus through, stays outside captured media, clears at Hold/revision changes, and resets at Stop, source/display changes, sleep and session deactivation. External sending computers and application-window sources cannot use it.

UX: Sharing > Options > Pointers or Monitor menu toggles the overlay inline, separately from preview pointers. The native toggle supports keyboard and accessibility. The overlay never becomes key.

## S-012: Choose viewing Wi-Fi and test join details

Offer cached, deduplicated network names with a connected marker and manual entry. Ask Location only from Allow Wi-Fi Names. Fresh scanning is explicit and unavailable during sharing or network-source reception. Unsupported enterprise/WEP networks require manual joining. The editor has no association capability. Password format feedback must say it is not a connection test; test a saved join code with a phone.

UX: Invite > Edit Wi-Fi > Choose Wi-Fi or type > password > Save. Cancel preserves saved details. Permission denial, empty scans, failures and unsupported security have inline guidance. Do not switch the Mac's live Wi-Fi to test a password.

## S-013: Use the viewer on iPhone and iPad

Keep the complete original-aspect picture, safe areas, 44-pixel targets and 16-pixel input text. Portrait phones put chat below the picture, short landscape windows use a drawer, and wide tablets use a side column. Rotation and keyboard presentation preserve drafts. Native iPhone video full screen and PiP remain video-only.

UX: Open Chat in the header; Close or Escape returns focus. Touch controls have explicit entry points. Record browser-engine, simulator and physical evidence separately.

## S-014: Discuss the feed in session chat

Admitted viewers and the DigiTech can send plain-text messages, reply, like and explicitly attach an outgoing frame. Names and cursor-color arrow avatars identify authors; the server assigns the DigiTech role. Pending/removed viewers cannot read chat or fetch frames. History clears at Stop or a new link. Earlier sent frames remain during Hold; new captures and stale-revision submissions are refused. No media control, publishing or administration is granted.

UX: Sharing > Chat, Command-4 or the viewer header opens chat. Reply has Cancel; Capture Frame previews an unsent attachment; Send publishes it. Failures keep text drafts. Explain that local-network chat is not encrypted. Keep history and images bounded in memory, outside logs and persistent storage. Native build 36 keeps one main live picture, compact sent-image attachments that enlarge on request, a quiet message menu and one composer. Reply, Like and Remove for Everyone have row accessibility actions; keyboard focus is visible. Identity and full chat information open from explicit controls. Compact drafts keep both cancellation controls and Send visible.

## S-015: Float, save and print join codes

Provide independent resizable Join Codes with Both, Feed and Wi-Fi views and optional Keep on Top. Live codes follow current payloads. Unavailable passwords never generate an open-network code. Save PDF and Print produce dated snapshots labeled with expiry, password inclusion and approval behavior. A changed viewing link invalidates an open Save operation.

UX: Sharing > Open Join Codes in Window or the large codes sheet opens a normal window. Native Save/Cancel and Print/Cancel finish exports. Closing preserves monitoring and sharing.

## S-016: Reopen from Finder or the Dock

Opening Setbeam raises and unminimizes its main monitor, even when another panel exists or the main window was closed. Cold launch presents the main scene. Opening never starts sharing.

UX: Finder, Dock and Open Setbeam lead directly to the monitor. A regression must fail first on the original missing reopen handler.

## S-017: Keep the menu bar focused

Put Open Setbeam first. Keep Start/Hold/Resume, Stop, floating preview and pending join decisions easy to reach. Group Invite, Viewers, Chat, Copy Link and Join Codes in a secondary menu. Follow observed media readiness and target-specific retry behavior.

UX: Use the native keyboard-accessible menu. The pending count and menu-bar icon read the same request state.

Status: S-011 through S-017 are implemented in build 35. Opus 5.5 High round 4 approves each implementation for the local developer build. Software evidence and remaining manual qualification are recorded in verification-collaboration-2026-11-10.md.


## S-014 refinement: compact Messages-style chat, build 37

Own messages use trailing accent-tinted bubbles; others use leading neutral
bubbles. Consecutive messages group only when author number, name and color
match within five minutes. Show only reactions that exist, with one of six
choices per participant, replaceable/removable and bounded to 128 participants.

UX:
- Flow: hold or right-click a bubble -> choose reaction, Reply or Copy. Touch
  also supports a short tap. A quiet More control appears on hover/focus.
- Surface: one anchored action menu; images open in a separate view. The native
  operator alone can Remove for Everyone. No Like/Reply row at rest.
- Access: one conversation keyboard stop, arrow navigation, Enter/ContextMenu
  or Shift-F10 on the web, Escape/Tab close the menu without closing chat. Native
  rows expose complete author/content/reaction labels and accessibility actions.
- States: failed sends keep drafts; deleted messages close their menus; scroll
  cancels a pending hold; keyboard viewport resizing repositions an open menu.
- Copy: supports plain-HTTP LAN pages, with a selectable-text fallback.
- Compact layout: retain 16px web inputs, 44px touch controls, draft cancellation
  and image removal in short landscape. Keep the encryption/Stop notice concise.

Software engine checks and real iOS/VoiceOver qualification remain separate.
