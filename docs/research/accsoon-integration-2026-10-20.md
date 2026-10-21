# Accsoon CineView Master 4K integration evidence

Investigated 2026-10-20 using public official software and retained packets from Austin's powered transmitter. The artifact investigation did not change transmitter configuration, update firmware, or contact Accsoon. Later live Setbeam tests passed direct video and encoded audio on the exact unit; those results are in [hardware-tests.md](../hardware-tests.md). SEE 1.9.3 was installed with Austin's authorization, but its device list stayed empty on this Ethernet-plus-Wi-Fi Mac, so the vendor-picture baseline remains unverified.

## Official routes and limits

The [current SDK request page](https://accsoon.com/sdk-launch-request/) names Nano, HE, SE, Quad, 2 SDI, and SeeMo. It does not name Master 4K or publish a macOS SDK archive, interface, or redistribution terms. The [SDK partner page](https://accsoon.com/accsoon-sdk-partners/) describes integrations, mainly for SeeMo. Neither page establishes a usable, redistributable Master 4K SDK for Setbeam.

The [Master 4K manual v2.0](https://accsoon.com/wp-content/uploads/2025/02/Accsoon-CineView-Master-4K-User-Manual-EN-V2.0.pdf), printed pages 7-8 and 23-26, documents Apple Silicon MacBook wireless monitoring through SEE and app-initiated RTMP/SRT push. It calls the transmitter USB output an iOS output. These facts do not establish generic Mac UVC or RTSP.

The [official App Store listing](https://apps.apple.com/us/app/accsoon-see/id6443441166) currently lists SEE 1.9.3, macOS 12.5+ on M1+, and labels it Designed for iPad, not verified for macOS. The vendor release history says 1.7.8 added push reconnect and an H.265 monitoring option dependent on firmware.

## Artifact identity and analysis

The [official download center](https://accsoon.com/download-center/) links [SEE Android 1.4.2 build 2](https://accsoon.com/wp-content/uploads/2026/06/Accsoon_see_1.4.2_2.apk). Downloaded APK SHA-256 is `9e026f785b469b97d6d4dcc27af7cb3fbecfeb696b1d10022b2f3eebe7c5261f`.

REA 6.4.0 archive inspection succeeded, Evidence `ev_de628df7c1cc4d262ec7e76be72f4386a07d79c4a71685510f9c36faa469b65f`. Android decompilation returned `capability_unavailable` because the caller-supplied JADX MCP JAR is absent. No tool was installed. Ordinary Python ZIP/DEX metadata inspection recovered exact field constants and method bytecode. Those observations are separate from REA Evidence.

Installed Ghidra 12.1.4 through REA supplied native pseudocode and instructions for:

- `lib/arm64-v8a/librtms_4_0_client.so`, SHA-256 `9f4c5491ae0fb03e261ab9f9f924201e5fc7efba2554c3f407eaac35c7a2aaff`.
- `lib/arm64-v8a/libwit07_rtms_client.so`, SHA-256 `e5d5931f2486e974b6159b15b9307e206f1195e54ad4f8f36ac757767a34c5c5`.

Complete local Evidence and extracted artifacts are under ignored `build/accsoon-research/`. No vendor binary belongs in the shipped app.

## Observed unit and useful protocol facts

Retained live packets came from the Mac's joined `Accsoon_11D5` network. The parent task recorded Mac Wi-Fi address `10.0.1.10`, working Ethernet internet, peer `10.0.1.1`, successful TCP 28010, passive UDP beacons, and a successful read-only status session. DHCP or SSID alone would not establish the model.

Decoded GET_SYS_INFO identifies `product_id: 21`, matching the official APK's `ACCSOON_PRODUCT_ID_WIT07_SERVER_TRI_FREQ` constant. It reports `firmware_version: 798` and `hard_version: 256`. The APK formatter in `classes2.dex`, `VersionConversionUtils.versionCode2VersionString(short)`, code offset 1821628, formats the high byte as major and the low byte with `%02d`; firmware therefore displays **3.30**. The reported hardware value is `0x0100`.

The unit reports valid video. Streams 1 and 2 advertise codec 265, VIC 16, integer frame rate, and progressive output. Audio advertises 48 kHz, 16-bit, stereo. VIC and codec fields still need a decoded-frame check before asserting delivered picture format. Firmware status shows no update in progress or pending reboot/off. The status exposes no camera or computer model name.

### Discovery

The RTMS4 wrapper constructor at `0x110854` initializes UDP local 28001, UDP remote 28000, TCP remote 28010, and alive timeout 6000 ms. Evidence `ev_720104e8d8fa5ae1dc9058628ecf11237538a8b3b001ab1458504bf1d483fdd7`. An older packaged SysCfg_OnePh.json uses 28100/28101 and refers to CineEye Pro2; those older ports were not the route on this unit.

A regular UDP socket on 28001 receives beacons without packet capture privileges. Header magic is `93 6e 77 78`, sender UID is uint32 little-endian at 4, byte 8 is `40`, byte 9 is basic channel 0, and uint16 command at 10 is 10. TLVs begin at 12, with type at 0, ciphertext length uint16 at 2, CRC32 at 4, and ciphertext at 8 relative to each TLV. Profile TLV type 0 contains JSON `uid`, `net`, and `stream`; custom TLV type 1 contains `grp_num`, `public_ssid`, `public_key`, and stream bitrate levels. Keep network keys private and runtime data out of Git.

The native AES helper uses independent AES-128 blocks with a static protocol key, no IV. CRC32 validated both retained TLVs before JSON parsing. Details and key remain in local analysis, not product copy. Evidence `ev_5f387d1a9cc7e3a7d4a1c5a9b0afac4055666ab9001897980a0d8ea1f411c3da` and `ev_4b016c9a9790c98235bb20ff56ed76fecc999a7747598ec769c5679fc3dcceb2`.

The live profile advertises `10.0.2.1`, `10.0.1.1`, and `10.0.0.1` with band priorities. The client selects an address in its local subnet from the discovered profile. It does not use a fixed host string. The SSID is available as `custom.public_ssid`; exact product/firmware/hardware keys are root `product_id`, `firmware_version`, `hard_version` in status JSON.

### Status session and cleanup

All multibyte fields below are little-endian. TCP frames carry uint32 magic `0x78a3f889`, uint32 payload length, then payload. Frame verification and sending come from `tcp_lib_class` at `0x16e7ac` and `0x16ec50`, Evidence `ev_fec798f66495a7332fab5459bac336fa105f5e623db4aaf8e3a2e0ed5fa19cd0` and `ev_9e2a17d01434d52fb4f18904ed169e18d7d8197c04d8bfd8cbd851f21301aecf`.

Common RTMS header is uint32 `0x78776e93`, nonzero random uint32 client UID, byte `0x40`, byte basic channel. On channel 0, uint16 command follows at offset 10. Connect command 11 then carries one-byte stream count and that many one-byte stream IDs. Count zero was accepted live with command 12 acknowledgement. Disconnect command 13 has no extra body. A same-client disconnect followed by socket close releases the owned session. Evidence `ev_30342cda3251f49d23287cb3369a27f39aa644c77fe0773c48b558a5198f7ae3`, `ev_ef316cd2014f1549f0223b3042e5885a69ae1cf8bd152b26b3409d5a2e8d1252`, `ev_65e03d18be5960fcba7944f6aa96a446cd5ae7c7ec126f39362af46f85c9a4fc`.

On basic channel 3, uint16 command follows the 10-byte header. GET_SYS_INFO is 20 with no body; its live response command was `0x8014` with JSON at offset 12. GET_UPDATE_INFO is 1000 with no body, used by the vendor's firmware query. Requests for status do not need any configuration command.

### Media subscription and packet reconstruction

Subscribe to the advertised lower bitrate video stream by connect command 11 with count 1 and stream ID 1. Keep UDP 28001 bound before session establishment. Native client code receives discovery profiles and does not require transmitting a client profile. The server learns peer IP from the established session.

Media packets use basic channel 2 and a 24-byte RTMS header. Stream ID is byte 12, substream ID byte 13, message ID uint32 at 16, total fragments uint16 at 20, zero-based fragment index uint16 at 22. Group by peer UID, stream, substream, and message ID; reject inconsistent counts and invalid indices. Concatenate fragment bytes from 24 onward in index order once complete. Native `get_msg` performs that concatenation; no padding is inserted. Evidence `ev_0fa42b5a2ddf2e35edc8d82df8a5f729202f97a95507f6e02cd45a19291e7db1`, `ev_9bc9a792372978b0dfe9346649e384ddacc29b848f01adabf1cc76e1ce42d897`.

A reconstructed video message begins with a 24-byte private header. It contains a uint64 timestamp at 0, packed codec/NAL fields at 8, a uint16 format field at 12, sequence uint32 at 16, and encoded-data length uint32 at 20. The encoded bytes begin at 24. The timestamp scale is addressed below; its clock origin and all packed flags remain unresolved. Evidence `ev_90fd65f15a0f7cf44adc56ae89c54d3c6147730cd77ad65c49b4a84e0fdf52f2`.

ACK packets use channel 1, uint16 command 50 at 10, stream/substream bytes at 12/13, uint16 flags/list-count at 14, uint16 incrementing ACK sequence at 16, cumulative complete-message ID uint32 at 18, then any additional uint32 IDs. With an empty additional list, `0x8000` marks the cumulative ID valid and total payload length is 22. ACK complete contiguous messages at the profile interval, currently 250 ms. The vendor resends connect-with-current-stream-list every 500 ms. TCP supports an empty eight-byte outer heartbeat. NAK uses channel 1, command 52, stream/substream bytes at 12/13, incrementing uint16 sequence at 14, uint16 element count at 16. Each element carries uint32 message ID, uint16 missing-fragment count, then that many uint16 fragment indices. Send a bounded request for missing indices after a fragment gap. Evidence `ev_cd3dd5ed0ac39f64973053dbba9c105191f15091e08b0c0ad99cdd88e41bfcc2`. Cumulative ACK must not advance past an incomplete earlier message. ACK Evidence `ev_b698aa0c33a312f5229d47f2cd9826a7d7f3879beefd878cab2799149f1c8afe`.

An empty fragment list in a NAK element requests the whole retained message. The server loop obtains that message by ID and calls `tx_msg` when the index vector is empty; selected indices use individual retransmission. Evidence `ev_8a9cc53245e663c9889dd53080baa269ea72d2dbb1830d00f8c854c556cd7c2c`, function `0x182bbc`. Its command handler rejects nonincreasing nearby NAK sequences, so start at 1 and increment. ACK/NAK can use the established TCP outer framing; native sending prefers available TCP and falls back to UDP. The official Java periodic status task sends empty-body commands 1000, 20, 30, and 90 every two seconds. A command-0 keepalive interval was not established from that task.

### Audio and timestamps

Code 37 is AAC. Ordinary DEX metadata recovered the exact `AudioCodecParams.CODE_TYPE_PT_AAC` constant value 37 in `classes.dex`, static-values offset 8698760. The app's `AudioDecoder.getMime(int)` maps 37 to `audio/mp4a-latm`. `AudioDecoder.init`, `classes2.dex` offset 1640536, sets `is-adts` to 1 and `aac-profile` to 2, the AAC-LC object type. Its sample rate and channel count come from advertised audio parameters. `SyncAACDecoder.createMediaFormat`, `classes.dex` offset 4721848, independently configures ADTS. The AudioSpecificConfig generator gives `1190` for AAC-LC, 48 kHz, stereo. Focused metadata is retained in ignored `build/accsoon-research/dex-audio-evidence.json`.

Native `code_audio`, function `0x18cf2c`, constructs a 24-byte private header followed by unchanged encoded audio. Its uint64 timestamp is at 0, codec is the low 10 bits of the field at 8, sequence uint32 at 16, and payload length uint32 at 20. The advertised 16-bit sample depth describes decoded audio; the wire payload is an AAC bitstream and must not be byte-swapped or interpreted as L16 PCM. Evidence `ev_f99ede387106ae83342f0ac12882e6cb7b2f4e7c417c49a1fa3b76a260009176`. An actual captured audio payload still needs its ADTS sync, frame length, object type, sampling-frequency index, and channel configuration validated before asserting physical audio playback.

For a loopback RTP bridge, strip each validated ADTS header and packetize its AAC access unit as MPEG4-GENERIC, with AudioSpecificConfig from the validated format. AAC-hbr uses a 16-bit AU-headers-length field and a 16-bit AU header containing a 13-bit byte count and 3-bit zero AU index. Those RTP fields use network byte order; RTMS private fields use little-endian. The SDP must describe the same payload convention. This is a proposed bridge implementation, not an observed Accsoon RTP output. [RFC 3640 sections 3.2.1 and 3.3.6](https://www.rfc-editor.org/rfc/rfc3640.html#section-3.3.6).

Native video and audio code copies the caller's uint64 timestamp unchanged; it does not establish the firmware clock's origin or cross-stream synchronization. Bounded statistics from the current 48 retained video messages show 47 sequential increments, median timestamp delta 16667, minimum 16649, maximum 16688, total span 783339. With VIC 16 and a 60 fps cadence, these observations support **microsecond timestamp units**. They contradict treating these fields as nanoseconds. Preserve the raw timestamp and use a relative epoch for playback; cross-stream clock origin still needs a joint audio/video capture. The timing ledger is ignored `build/accsoon-research/retained-video-timing.json`.

## Remaining proof

At the initial artifact checkpoint, only discovery and firmware/status reads had been established. The first media probe retained parameter sets and 26 complete HEVC TRAIL_R messages, with one incomplete message and no random-access picture. The bundled FFmpeg then lacked a raw HEVC demuxer. Its rejection did not establish a packet-format failure. Subsequent implementation used receive buffering, socket draining, native acknowledgement/retransmission scheduling, and a standard loopback RTP/SDP bridge.

## Final live implementation result

Setbeam directly received and decoded this Master 4K's 1920×1080p60 computer-display picture and AAC 48 kHz stereo stream. Local H.264/Opus, exported fine text, native/floating preview, actual Chromium playback, audience Hold/Resume/Stop, private saved restoration, helper recovery, and Wi-Fi rejoin passed. No vendor executable or library ships in Setbeam.

Two runtime issues were isolated and corrected. A moving fragment window had retained an expired gap timer after the oldest message completed; the timer now follows the oldest pending message, with a regression test. A local decoder could miss initial HEVC parameter packets; a bounded 192 KiB cache now repeats missing VPS/SPS/PPS at random-access pictures. Synthetic tests cover late decoder startup, partial/full parameter presence, replacement, and oversized-set rejection. Clean packaged native startup passed with the physical source.

A real no-input event left the transmitter reachable but its media arrays empty despite outer valid flags. Setbeam now requires actual advertised streams and guides the operator to restore HDMI/SDI picture. Austin restored the source and direct reception resumed. Native audible output, A/V timing, latency, longer sessions, other formats, camera content, and coexistence remain unverified. See the physical evidence record for exact boundaries.
