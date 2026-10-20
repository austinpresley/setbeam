# Setbeam

Read `docs/status.md` and `docs/plan.md` before implementation work. Read
`docs/architecture.md` before changing media flow or module interfaces.

## Product invariants

- Receive a camera once; local preview, floating preview, and sharing read the Mac's feed.
- Stop Sharing leaves local monitoring available.
- Hold suppresses camera video and audio in the outgoing media, while local monitoring continues.
- Label sample media explicitly. Mark hardware compatibility only with recorded physical evidence in `docs/hardware-tests.md`.
- Viewer access is read-only. Publishing and administration stay private.
- Supervise owned processes and clean up their process groups. Match no processes by global command-line patterns.
- Bundle runtime dependencies. The finished app must not depend on a developer's Homebrew installation.

## Workflow

Keep changes small and update `docs/status.md` with actual evidence and remaining work.
Run `scripts/check.sh` and the integration checks relevant to changed behavior.
Record exact failures and distinguish automated checks from physical tests.
Keep credentials, session secrets, generated build output, and runtime directories out of Git.

The development remote is this fork. Target development PRs at this fork; upstream contributions require a separate request.
Preserve the upstream MIT notice and dependency notices. The original launcher remains a reference under its existing name.
