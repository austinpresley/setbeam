# Collaboration audit integration

## Browser viewer

Keep `revision` in collaboration updates as the latest gateway state revision.
Pass `displayedRevision` separately to chat and pointers. Set it only after the
current reader presents a fresh frame, and stamp it with the revision that
started that reader. Clear it on detach, stale playback, Hold, pause, or when
the document is hidden. Report changes in gateway revision before awaiting a
configuration fetch. Both modules compare the two values and suppress picture
actions during a mismatch. An omitted displayed revision retains compatibility
with older callers. An explicitly undefined displayed revision means no
confirmed picture. Preserve the admitted-pass callback and optional
`chat.activity(chatLastID)` hint. Chat polls its own authenticated history.

The isolated viewer change binds frame callbacks to the stream and reader
generation. If combining it with a replacement viewer controller, use that
controller's reader and gateway generations for these same checks.

## Native outgoing preview

Browser frame posts require the authoritative gateway to be live at the
submitted revision. `setChatFramePermission` belongs to Mac operator posts.

The native preview integration should include its decoded revision in
`SessionModel.canCaptureChatFrame`. Clear readiness before a decoder restart or
publisher revision change, start the outgoing decoder for the new revision, and
expose readiness only after its first fresh frame. Continue to use
`audiencePlayer.picture` and honor the capture generation checks before and
after encoding. `clearChatAttachment()` invalidates a draft through transitions
and keeps its explicit removal or recapture choice. Use
`clearChatAttachment(discard: true)` when removing it explicitly or ending the
session. Call `refreshChat()` when ending the session if Stop and a new share
can occur before the chat polling tick runs.
