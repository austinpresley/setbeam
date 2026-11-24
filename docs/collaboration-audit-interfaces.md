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
generation. The viewer recovery branch already tracks both revisions and
passes them to chat. When integrating that branch, use its reader handling
and send both `revision` and `displayedRevision` to pointers in
`pointers.update`, as it already does for chat. Both modules honor the
optional `suspended` update flag while the viewer revalidates its state.

## Native outgoing preview

Browser frame posts require the authoritative gateway to be live at the
submitted revision. `setChatFramePermission` belongs to Mac operator posts.
The audience transition owner should publish the new revision or non-live
state when it invalidates the outgoing picture. Browser capture follows that
published transition even when the Mac decoder is unavailable.

The parent integration binds the outgoing decoder to the audience revision
and generation. Its `SessionModel.freshOutgoingPicture` getter is the
capture input for `captureChatFrame()` and the readiness check for
`canCaptureChatFrame`. Recheck the decoder generation after encoding.
`clearChatAttachment()` invalidates a draft through transitions
and keeps its explicit removal or recapture choice. Use
`clearChatAttachment(discard: true)` when removing it explicitly or ending the
session. Call `refreshChat()` when ending the session if Stop and a new share
can occur before the chat polling tick runs.

## Android chat history

`GET chat` returns up to 100 retained messages in one JSON array in
ascending message-ID order. `hasFrame` is current
JPEG availability. Optional `hadFrame` records whether a JPEG was attached
at send time, including image-only messages after JPEG eviction. Older
gateways omit `hadFrame`. `sampleFrame` retains the original label, and
`replyTo` can reference a removed or evicted row. Count unread messages from
retained rows and exclude messages written by the reader.

Accepted text is cleaned before the gateway enforces 1,200 Swift characters
and 6,144 UTF-8 bytes. A Swift character can include multiple Unicode scalars.
The receiver's 1,200-code-point display limit can shorten accepted text with
many multiscalar characters.
Author labels are bounded at 40 Swift characters and 160 UTF-8 bytes. The
combined JSON-encoded text and author label cannot exceed 8,192 bytes per
entry. Even reserving another 1,024 bytes per row for fields and up to six
reaction summaries keeps a complete 100-row response below Android's existing
1 MiB HTTP cap. JPEGs are fetched separately.

An admitted sender can POST `{"action":"receipt","requestID":"…"}` to the
same endpoint. It returns `{"ok":true,"messageID":null}` while no acceptance
is recorded, or the original numeric ID. Accepted posts return the same
numeric ID on retries after deletion, eviction, or publisher revision
changes. The gateway stores the author-scoped receipts until the share ends
and accepts up to 65,536 distinct posts per share. Reaction and frame access
continue once that cap is reached. The browser keeps an unconfirmed draft
and its request ID in the open page until reconciliation or session end.
