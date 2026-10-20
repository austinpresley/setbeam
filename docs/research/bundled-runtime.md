# Bundled runtime research

Source review: 2026-10-20. Targets are FFmpeg 9.0.2, Opus 1.6.1, and MediaMTX 1.21.2 on macOS arm64. These are source-verified build/configuration instructions, not a claim that the resulting binaries have passed integration tests. Build results belong in the project status and runtime checks.

## Source and build recipe

Use the [official FFmpeg 9.0.2 release tarball](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz), its [detached signature](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz.asc), and the [official Opus 1.6.1 tarball](https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz). The Opus release archive was inspected in memory and contains a generated `configure` script. Autotools regeneration is unnecessary. The [Opus download page](https://opus-codec.org/downloads/) publishes its release checksum. Pin archive hashes and preserve matching source archives beside distribution materials.

For Opus, use an isolated project-local prefix and the released configure script:

```sh
./configure --prefix="$RUNTIME_PREFIX" \
  --disable-shared --enable-static --with-pic \
  --disable-doc --disable-extra-programs
make -j "$BUILD_JOBS"
make install
```

Use the same architecture and deployment target for Opus and FFmpeg. The 1.6.1 archive's configure help confirms these flags. Leave optional experimental speech extensions disabled unless a separate requirement justifies them. [Opus build documentation and release source](https://github.com/xiph/opus/tree/v1.6.1)

The following deliberately scoped FFmpeg configuration covers the requested media path. Set `PKG_CONFIG_LIBDIR` to the local Opus `lib/pkgconfig` directory and clear `PKG_CONFIG_PATH`, so a developer's package-manager prefixes cannot supply dependencies accidentally. `--pkg-config-flags=--static` selects Opus's static-link metadata.

```sh
./configure --prefix="$RUNTIME_PREFIX" \
  --arch=aarch64 --target-os=darwin \
  --disable-autodetect --disable-everything \
  --disable-gpl --disable-nonfree --disable-shared --enable-static \
  --disable-doc --disable-debug --disable-ffplay \
  --enable-ffmpeg --enable-ffprobe \
  --enable-pthreads --enable-avfoundation --enable-videotoolbox \
  --enable-libopus --pkg-config-flags=--static \
  --enable-indev=lavfi,avfoundation \
  --enable-demuxer=rtsp,rawvideo,image2 \
  --enable-muxer=rtsp,image2,image2pipe,null \
  --enable-protocol=file,pipe,tcp,udp,rtp,http \
  --enable-decoder=h264,aac,aac_latm,opus,libopus,rawvideo,wrapped_avframe,mjpeg,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le \
  --enable-encoder=h264_videotoolbox,libopus,mjpeg,wrapped_avframe,pcm_s16le \
  --enable-parser=h264,aac,aac_latm,opus \
  --enable-filter=testsrc2,color,sine,anullsrc,scale,format,aresample,aformat
```

Module names and dependencies are verified in the [9.0.2 configure source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure). Configure automatically selects additional internal helpers required by these components. This is a practical starting set, not a mathematically smallest build. Add formats only when a real input or test needs them.

- RTSP is a demuxer/muxer, not an FFmpeg protocol name. It selects HTTP/RTP helpers; use `-rtsp_transport tcp` for both input and output. [RTSP documentation](https://ffmpeg.org/ffmpeg-protocols.html#rtsp)
- `--disable-autodetect` also affects threads and Apple frameworks. Explicitly enable `pthreads`, `avfoundation`, and `videotoolbox`. CoreFoundation/CoreMedia/CoreVideo probes are unconditional in this source. The capture input additionally requires the SDK's `AVCaptureSession` class. [Configure dependencies and framework checks](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure)
- `wrapped_avframe` decoding matters for lavfi inputs. `rawvideo` and PCM decoders cover common capture frames/audio. Test actual capture formats before calling them supported. [Lavfi input implementation](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavdevice/lavfi.c), [AVFoundation input](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavdevice/avfoundation.m)
- H.264 copying needs no video encoder. Sample/holding video and raw capture can use the system VideoToolbox encoder; avoid adding libx264. JPEG export needs `mjpeg` plus `image2` or `image2pipe`. The requested arm64 build does not need x86 NASM. [Encoder configuration](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure), [VideoToolbox encoder](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c)

Required build gates: inspect configure's enabled components, `ffmpeg -buildconf`, codec/device listings, an encoded sample with Opus, RTSP/TCP publish/read, H.264/AAC-to-Opus conversion, and a decoded JPEG. `otool -L` on every shipped executable must show only macOS system locations. Keep FFmpeg libraries and Opus static inside the helper executable; the Swift app communicates with the helper as a process. Ship matching sources, build instructions, and licenses. FFmpeg's own [license guidance](https://ffmpeg.org/legal.html) requires attention to exact corresponding sources; disabling GPL/nonfree does not remove LGPL obligations. Opus's [license](https://github.com/xiph/opus/blob/v1.6.1/COPYING) must be preserved.

## MediaMTX configuration boundaries

Use the [official 1.21.2 release](https://github.com/bluenviron/mediamtx/releases/tag/v1.21.2) and version-matched [configuration reference source](https://github.com/bluenviron/mediamtx/blob/v1.21.2/mediamtx.yml). Replace the entire default user list. Defaults otherwise allow anonymous publishing and reading, and publisher replacement. A suitable generated policy is:

```yaml
authMethod: internal
authInternalUsers:
  - user: setbeam-runtime
    pass: GENERATED_RUNTIME_SECRET
    ips: [127.0.0.1, '::1']
    permissions:
      - action: publish
        path: source
      - action: publish
        path: local
      - action: publish
        path: live
      - action: read
        path: source
      - action: read
        path: local
  - user: setbeam-preview
    pass: GENERATED_PREVIEW_SECRET
    ips: [127.0.0.1, '::1']
    permissions:
      - action: read
        path: local
  - user: setbeam-admin
    pass: GENERATED_ADMIN_SECRET
    ips: [127.0.0.1, '::1']
    permissions:
      - action: api
  - user: any
    pass:
    ips: []
    permissions:
      - action: read
        path: live
api: true
apiAddress: 127.0.0.1:9997
rtsp: true
rtspAddress: 127.0.0.1:8554
rtspTransports: [tcp]
rtmp: false
hls: false
srt: false
moq: false
webrtc: true
webrtcAddress: :8889
webrtcLocalUDPAddress: :8189
webrtcLocalTCPAddress: :8189
pathDefaults:
  source: publisher
  overridePublisher: false
paths:
  source: {}
  local: {}
  live: {}
```

The names are proposed paths, not existing implementation claims. Generate secrets per session and keep them out of logs and public resources. Private RTSP helpers use the runtime account. The private preview uses its own read-only credential. Authenticate API requests with the admin credential even though the API listener is loopback-only. Revoke or close the audience `live` path when sharing stops; leave `local` running. A Hold output must replace actual outgoing media.

Set `webrtcIPsFromInterfaces: false` and generate `webrtcAdditionalHosts` with loopback and the selected reachable viewer address. Set CORS origins to actual local/viewer HTTP origins. Test UDP and TCP media reachability separately from HTTP. A loopback-only RTSP listener intentionally prevents audience RTSP access; add an audience RTSP listener only through a separately reviewed requirement. These keys and permissions come from the [pinned MediaMTX configuration](https://github.com/bluenviron/mediamtx/blob/v1.21.2/mediamtx.yml).

Version 1.21.2 uses `runOnAvailable` and `runOnAvailableRestart`. The command starts when a path becomes available and receives SIGINT when availability ends. Use `runOnOnline` when the distinction between a real online source and an offline replacement matters. The native app can supervise FFmpeg directly instead of embedding shell commands in these hooks. [Pinned hook semantics](https://github.com/bluenviron/mediamtx/blob/v1.21.2/mediamtx.yml)

## Browser reader

Bundle the exact [1.21.2 reader.js](https://github.com/bluenviron/mediamtx/blob/v1.21.2/internal/servers/webrtc/reader.js) and its license. The MediaMTX HTTP server also serves it at `/reader.js`. The constructor takes one configuration object; `onTrack` receives an `RTCTrackEvent`, not a MediaStream. [HTTP routing](https://github.com/bluenviron/mediamtx/blob/v1.21.2/internal/servers/webrtc/http_server.go)

```js
const reader = new MediaMTXWebRTCReader({
  url: `${mediaOrigin}/live/whep`,
  onTrack: (event) => { video.srcObject = event.streams[0]; },
  onError: (error) => { showConnectionError(error); }
});
// Before replacing the reader or disposing the view:
reader.close();
```

For private playback, use `/local/whep` and supply `user` and `pass` in the configuration object. Never embed those credentials in the public viewer. The helper also supports a bearer `token`, but that requires matching server authentication policy. It retries some failures internally, so UI status should observe actual track/playback progress instead of counting reader construction as success. [Reader configuration, auth, retry, and cleanup implementation](https://github.com/bluenviron/mediamtx/blob/v1.21.2/internal/servers/webrtc/reader.js)
