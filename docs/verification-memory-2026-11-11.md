# Display-sharing memory investigation

Austin reported about 75 GB of Setbeam RAM use during a shoot while sharing a
whole computer monitor to an iPad and phone. The input route and an incident
memory profile were not available. GitHub main was `218e8c5`, build 20; this
Mac's installed private build was 37. The leaking VideoPipeWriter and native
preview implementation were unchanged between build 20 and the task baseline.
Existing uncommitted work was preserved.

## Confirmed cause

VideoPipeWriter drained its Data with `removeFirst`. That advanced the logical
start without releasing the consumed backing allocation. Later appends extended
the same storage, retaining the cumulative encoded bytes sent during the shoot.
The existing 8 MiB limit checked only the unsent count, so an empty pipe could
still own a growing allocation. This route serves This Mac's screen and
application windows. It is independent of the number of viewers.

The focused production-writer regression failed in 1.266 seconds after 3,073
64 KiB frames, with 193 MiB footprint growth. Its sink was fully writable and
drained every frame. This excludes network congestion and a growing queue of
unsent frames as necessary triggers.

The fix keeps a write offset, releases empty storage, and explicitly copies only
the unsent tail before appending to a partially drained buffer. It preserves
nonblocking writes, the 8 MiB backpressure limit, failure recovery, and ownership.
Partial-write concatenation is checked byte for byte.

An audit found the same consumed-prefix pattern in the Accsoon TCP control
output after a partial send. It now copies only the unsent tail and resets fully
drained storage too. The socket loop is private and currently has no independent
full-transport memory-test seam; existing protocol/fragment tests and the shared
Data behavior establish a narrower result. No physical Accsoon endurance result
is claimed. Other persistent media Data buffers use removeSubrange without
advancing their start index; no further removeFirst-based Data queue remains.

The extended regression then sent 1,300,000 frames, 81,250 MiB or 79.35 GiB,
through the actual writer in 6.5 seconds with less than 1 MiB growth. This is an
accelerated byte-volume check, not an hours-long decoded-video test.

```sh
SETBEAM_MEMORY_PIPE_FRAMES=1300000 swift test -c release --filter 'VideoPipeWriterTests|PreviewMemoryTests'
```

An initial 10-minute actual 1920x1080 display-sharing test, with the pipe still
unfixed, grew from 45.8 to 182.2 MiB despite a capped picture pool. Heap snapshots
showed one Swift Data backing allocation growing from about 39 to 149 MiB while
object counts and IOSurface memory stayed nearly constant. This led to the
writer regression above. The original 256 MiB soak allowance passed despite
this trend, so the final test also requires a 96 MiB growth ceiling and a final
quarter mean within 32 MiB of its first quarter. The 96 MiB guard compares with
the sampled warm-up peak, not one low instant in that warm-up cycle. Initial helper measurements
misread proc_listchildpids' return value as bytes; those helper numbers are
invalid. Final runs count all returned child PIDs and their descendants.

## Additional preview protection

A rapid 4K display-layer stress check reproduced 393 MiB growth before its
safety stop. A readiness guard alone and per-frame flush did not bound this
burst. Bypassing the renderer used 11 MiB; pacing frames used 37 MiB. This is a
separate stalled-renderer failure mode, not evidence that it caused the shoot.

Every NativePreview now shares an eight-buffer allocation budget across decoder
recovery and format changes. Buffer attachments retain allocation leases until
the actual CVPixelBuffers are released, including references held by renderers.
Saturation drops presentation frames, and released buffers permit playback to
resume. The production Core Video pool also enforces its allocation threshold.
Display layers check readiness and flush on detachment, window occlusion
changes, minimization and close. Detached or hidden monitors do not enqueue.

Five regression cases cover stalled 4K rendering, retained renderer buffers and
resumption, format changes, decoder replacement and detached monitors. The 4K
stress case uses about 96 MiB after the fix. Core Video's
[allocation threshold](https://developer.apple.com/documentation/corevideo/kcvpixelbufferpoolallocationthresholdkey)
limits allocations; a pool by itself only reuses buffers. Apple's
[renderer readiness documentation](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/isreadyformoremediadata)
also explains that enqueueing can continue when the renderer is full.

An early test-host check of NSWindow.occlusionState failed because the XCTest
host reported no visible occlusion state. The final stress test checks its
window's actual isVisible property; production rendering does not require an
occlusion-state flag. Packaged-app visual verification remains separate.

## Sustained checks

The fixed 10-minute actual display run passes. The native host starts at 46.6
MiB, peaks at 57.2 MiB and ends at 53.3 MiB over 118 samples. Its first/final
quarter means are 46.0/52.6 MiB. Native frames reach 18,232 with two decoded
browser viewers, repeated hiding/restoration, Hold/Resume, and Stop preserving
monitoring. The companion browser check also passes.

The first three 4K attempts hit the too-narrow instant-baseline growth guard.
The reports record `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`
during cleanup; the samples immediately before failure exceed that growth
allowance. Heap profiles show 6–18 MiB of live objects against 393–843 MiB
physical footprint, predominantly large malloc regions. The fixed display
writer's growing live Data allocation is absent. The final harness samples the
warm-up envelope before judging later peaks. It retains the 96 MiB envelope
allowance, 1 GiB absolute host guard and 32 MiB first/final-quarter trend check.
This is a measurement correction for allocation churn, not a claim that the
earlier 4K attempts passed. The completed 10-minute 3840x2160/30 fps run passes
all three checks. It records 118 samples and reaches 18,236 native frames.
Physical footprint starts at 631.0 MiB, peaks at 842.3 MiB and ends at 438.6 MiB.
First/final-quarter means are 522.7/503.8 MiB. Both 4K Chrome viewers decode,
follow Hold/Resume and pass the independent browser memory check. The fixture
is an explicitly labeled generated checkerboard, not a physical 4K device.

The harness also records live and reserved malloc bytes for future runs, using
Apple's [malloc zone statistics](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h).
The passing long run above predates that extra diagnostic field; its physical
footprint checks and all production source hashes are unchanged.

Build 38 is installed privately, with all 38 app files matching the package.
Six arm64 executables pass strict signatures and link only
system libraries. The complete isolated scripts/check.sh exits 0 with 290 Swift
tests, one opt-in soak skipped by default, five Python cases, 59 Node checks and
every media integration stage passing. The final large-keyframe stage decodes
500 frames in seven seconds from 1,750 KB keyframes without decoder errors.
No failure or stage retry occurred in this full check. All 96 packaged source
inputs remain unchanged through it.

The actual packaged app is visually inspected in light and dark appearances for
both main and floating previews. Native telemetry confirms decoded frames keep
advancing. Native Hold/Resume preserves the local picture; closing and reopening
the floating window restores fresh video. Stop Sharing leaves both monitors
advancing privately. Normal Quit during an isolated active sharing session
removes all 11 recorded app/helper processes. Test preferences and logs are
separate from the production setup. Build 37 is preserved before installation.
The app is an ad-hoc signed Apple Silicon developer build, not notarized.

The ZIP passes an integrity check and extracts to the same 38 app-file hashes
with strict signatures intact. Installed build 38 also matches those hashes.
A final diagnostic launch with --experience-file targeting Project Vault stalled
in Data.write's atomic temporary-file open; the app's main thread was sampled
in that file operation and no telemetry file appeared. That owned diagnostic
instance was stopped. A normal Launch Services start without the test-only flag
opens promptly, preserves the saved CineView setup and is visibly Private with
sharing off. The unavailable transmitter is not counted as a physical test.

The opt-in endurance test exercises the real MediaRuntime, native decoder,
main/floating display views and outgoing preview. It repeatedly hides/restores
both windows, changes Hold/Resume, and checks that Stop preserves monitoring.
Physical footprint includes the test host and every owned helper descendant.
The Chrome companion joins two independent viewers at phone/tablet sizes,
checks decoded progress and Hold suppression, and records JavaScript heap and
browser process RSS. Browser RSS is a sum that includes shared mappings; it is
not directly comparable to the native physical footprint.

```sh
SETBEAM_MEMORY_SOAK_SECONDS=600 SETBEAM_MEMORY_SOURCE=screen \
SETBEAM_MEMORY_CONTROL=/tmp/setbeam-memory-screen-control.json \
SETBEAM_MEMORY_REPORT="$PWD/build/logs/memory-screen-fixed.json" \
swift test -c release --filter SharingMemorySoakTests

PLAYWRIGHT_MODULE=/path/to/playwright-core \
node scripts/check-sharing-memory-browser.js \
/tmp/setbeam-memory-screen-control.json build/logs/memory-screen-fixed-browser.json
```

The control file contains a temporary loopback-only viewing link, is private,
and is deleted at test exit. Reports contain measurements, not credentials or
source screenshots. T3 preview snapshots timed out twice, so the browser check
used the repository's installed-Chrome/Playwright workflow.

## Qualification limits

No claim of a literal 75 GB incident reproduction is made. The storage leak is
reproduced and fixed at its production call site. The incident's exact input
route, duration and memory profile remain unknown. Native tests and desktop
Chrome viewports do not qualify physical iPad/iPhone Safari, transmitters or
capture hardware. No hardware compatibility record was changed. All work and
validation ran locally; no hosted workflow was dispatched.
