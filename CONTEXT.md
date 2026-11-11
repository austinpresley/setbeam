# Setbeam

Setbeam receives, monitors, and shares video feeds for on-set work. Wireless computer displays used by DigiTechs and camera feeds are peer use cases.

## Language

**Source**:
The origin of the picture, such as a computer display, a camera, or another video output.
_Avoid_: Camera as the generic name for every source.

**Feed**:
The live picture and optional audio received from a source and shown to the operator or viewers.
_Avoid_: Camera feed when the source content is unspecified.

**Transmission system**:
The hardware carrying a source's video wirelessly, such as a transmitter and receiver pair. Its brand and model describe the transport hardware rather than the content of the feed.
_Avoid_: Camera system as a generic label for transmission hardware.

**Input**:
The connection through which a source's feed reaches Setbeam.

**Local monitoring**:
The operator's private view and optional sound on the receiving Mac, including its floating preview.

**Sharing**:
Making a feed available to audience viewers independently of local monitoring.

**Hold**:
Temporarily replacing the audience's feed with a holding state and silence while local monitoring continues.

**This Mac's screen**:
A selected display of the receiving Mac, captured with its cursor and without Setbeam's own windows. This input has no sound.

**Application window**:
One window of another application on the receiving Mac, captured by itself with its cursor and without the desktop or other windows. It is identified by its window number and owning process, never by title. This input has no sound.
_Avoid_: App sharing, for capturing every window of an application.

**Viewer approval**:
An optional session choice in which each browser session asks to join with a name and plays only after the operator admits it. Removing an admitted session ends its media access individually.
_Avoid_: Account, login, or verified identity; names are labels chosen by viewers.

**Viewer identity**:
The one name and color a browser session chooses on its join card. It labels the operator's viewer row and the session's shared pointer. It is a label, not authentication; under viewer approval the name is fixed.
_Avoid_: Profile, account, or login.

**Shared pointer**:
An admitted viewer's opt-in pointer over the shared picture, labeled with their viewer identity and seen by other participating viewers. The operator sees pointers on this Mac only after turning on Show pointers on this Mac. It is presence only and grants no control.
_Avoid_: Remote control, annotation, or cursor highlighting of the operator's own cursor.

**Local address**:
A readable name ending in `.local`, such as `setbeam.local`, that viewers on the same network can use in place of the IP address in the viewing link. It exists only while sharing, keeps the link's private code, and is published by this Mac without an internet service.
_Avoid_: Hostname, domain, Bonjour name, or a permanent link.

**Short address**:
The local address typed by itself, such as `setbeam.local`, with no port or code. When the operator allows it, it opens an ask-only join page: every request waits for the operator's Admit, it needs viewer approval and the local address, and it works only while sharing on a network others can join. It never reveals the viewing link's code.
_Avoid_: Short link, vanity URL, or anything that suggests the name alone plays the feed.

**Join request card**:
The corner card Setbeam shows when a viewer asks to join, with Admit and Decline for each request. It floats above other apps without taking focus and hides itself; requests stay in the sharing bar, the Sharing panel, the floating preview's controls, the menu bar, and the Dock badge until answered.
_Avoid_: Notification, for this card; macOS notifications are not used.

**Sharing panel**:
The optional Invite, Viewers, Options, and Chat panel beside the local monitor. It can open as a separate window on a small screen. Opening, switching, or closing it does not start or stop sharing.

**Source Details**:
Settings for the selected input, including capture frame rate, explicit capture sound, saved setup, and transmitter rejoin. Viewer output settings belong to Sharing Options.

**Session name**:
The title shown on this Mac and the viewer page. It is separate from a source name.
_Avoid_: Feed name as another label for the same setting.

**Session chat**:
The shared conversation among admitted viewers and the DigiTech for one viewing session, including replies, emoji reactions, and explicitly sent feed frames. It ends and clears when sharing stops.
_Avoid_: Public internet chat, or an account message history.

**Shared display pointers**:
Viewer pointers drawn on the selected display attached to this Mac while that display is shared. They grant no control and stay out of the captured picture.
_Avoid_: Remote control, or pointers sent back to an external transmitter.

**Join-code snapshot**:
A dated saved or printed copy of the session's invitation codes. Its viewing code works only while that sharing session remains active.


**Reaction**:
One of six small emoji responses to a session-chat message. Each participant
can select, replace or remove their own reaction. It is session-only and grants
no media or administration control.
