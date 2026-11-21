# Receiver native dependencies

Setbeam Receiver (`receiver/android`) has one runtime dependency: the native
WebRTC library for Android. Everything else is the Android platform. Build
tools (Gradle, the Android Gradle Plugin, JUnit, org.json for JVM tests) do
not ship in the APK.

Facts below were checked on 2026-11-17 against the primary sources named in
each row.

## WebRTC for Android

| Field | Value |
| --- | --- |
| Coordinates | `io.github.webrtc-sdk:android:144.7559.15` ([Maven Central](https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/144.7559.15/)) |
| Publisher | The `webrtc-sdk` project ([github.com/webrtc-sdk/android](https://github.com/webrtc-sdk/android)), release [`v144.7559.15`](https://github.com/webrtc-sdk/android/releases/tag/v144.7559.15), published 2026-09-05 |
| Source | `CHANGES.md` in that repository: "Corresponds to https://github.com/webrtc-sdk/webrtc/commit/30d5e63ae91da483e06577b5c35ee91cc5e5c3db". That commit (2026-09-04) is on the webrtc-sdk fork of Google's libwebrtc, M144 branch. |
| AAR SHA-256 | `fc7c8d027eb33860ccbb7847988f7f942d44a92d1f575348bba6c0250cde4071` (equals Maven Central's published `.sha256`) |
| POM SHA-256 | `9682ba549bd4d7732aa093427f09f597d9251ed7954b3df6a2b470d7cd356cf0` |
| Signature | `.aar.asc` and `.pom.asc` verify with RSA key `E65BD4351D0FF0EF9C0C15FF3CCBD94F6FC0F446` (uid `dliu1030`, fetched from keys.openpgp.org). The key is not certified by any key we trust, so this proves only that the Central artifact matches that publisher key. |
| Contents | `classes.jar` (Java 17 class files, `org.webrtc`) and `libjingle_peerconnection_so.so` for armeabi-v7a, arm64-v8a, x86 and x86_64. The APK keeps armeabi-v7a and arm64-v8a only (`abiFilters`). |
| Bundled `.so` check | The two `.so` files in `app-debug.apk` are byte-identical to the signed AAR's: arm64-v8a `5d68547d…612e`, armeabi-v7a `58e3fd27…5815`. |
| Licenses | POM: BSD-3-Clause. Packaging repository `LICENSE`: MIT ("Copyright (c) 2023 WebRTC SDKs"). WebRTC: BSD-3-Clause plus Google's Additional IP Rights Grant (`PATENTS`). The AAR contains no license file. |
| Minimum SDK | AAR manifest `minSdkVersion 21`; the app uses 26. |

Why this version: it is the newest release whose changelog names its exact
source commit. 150.7871.04 (2026-10-23) has no source commit in `CHANGES.md`,
and its build script rewrites class-file versions after download.

### Enforcement

`receiver/android/gradle/verification-metadata.xml` pins a SHA-256 for every
artifact Gradle resolves for the default `build.sh` tasks. The WebRTC entries
carry the origin note above. A build with a changed WebRTC hash fails with
"Dependency verification failed … android-144.7559.15.aar"; this was checked by
editing the hash locally and restoring it. To update the dependency, check the
new artifact's `.sha256` and `.asc`, then regenerate with
`./gradlew --write-verification-metadata sha256 testDebugUnitTest lintDebug assembleDebug assembleRelease`
and review the diff.

The Gradle wrapper is 9.9.1. `gradle-wrapper.properties` pins the
distribution's SHA-256 `d8a18a7a…a228`, and the committed
`gradle-wrapper.jar` matches Gradle's published wrapper checksum
`621008af…af8`.

### What the native library contains

Identified from strings in `libjingle_peerconnection_so.so` and from the
source commit's `DEPS`:

| Component | Pinned revision (from `DEPS`) | License |
| --- | --- | --- |
| BoringSSL | `b94d71f87ff943a617d77f3ff029f9a01a1ec6bc` | Apache-2.0 plus legacy OpenSSL/ISC notices (`LICENSE`) |
| libvpx (VP8/VP9; "v1.15.2-142-g9a7674e1a" in the binary) | `9a7674e1a83d1261a49776c8794b87c9bccc85d7` | BSD-3-Clause plus patent grant |
| libaom (AV1) | `5d80673d723a5e2e268b124d81d425053823d875` | BSD-2-Clause plus AOM Patent License 1.0 |
| dav1d (AV1 decode) | `fcbc3d1b93f91c709293ed9faea8b7cbcac9030b` | BSD-2-Clause |
| Opus | chromium `src/third_party` `a3b630c291f1cf3b711687b1c4be322d3015512e` | BSD-3-Clause |
| libyuv | `4825d9b29eea4dac24607245db7ec7d4c41c1964` | BSD-3-Clause |
| libsrtp | `a52756acb1c5e133089c798736dd171567df11f5` | BSD-3-Clause |
| Abseil | chromium `src/third_party` `a3b630c…` | Apache-2.0 |
| CRC32C (dcSCTP checksums) | `d3d60ac6e0f16780bcfcc825385e1d338801a558` | BSD-3-Clause |
| PFFFT, RNNoise (audio processing) | chromium `src/third_party` `a3b630c…` | BSD-style |

No FFmpeg or OpenH264 code is present: neither name appears in the binary,
although both are listed in `DEPS`. H.264 is decoded only through Android
MediaCodec, by the device's hardware decoder where the platform reports one,
or by the platform's own software decoder (`c2.android.avc.decoder`) as
WebRTC's fallback. The receiver's diagnostics name the decoder actually
created and what `MediaCodecInfo` says about it.

### Notices in the app

`app/src/main/assets/third_party_notices.txt` ships in the APK and opens from
Mac settings › Open-source notices. It has the full texts of WebRTC `LICENSE`
and `PATENTS` at the source commit, the packaging MIT license, and each
component above. Each text was fetched from that component's own repository
at the revision `DEPS` pins. PFFFT and RNNoise are included even though their
names do not appear in the binary, because WebRTC's audio processing links
them. Review this list again when the dependency changes.

## Platform facilities used instead of libraries

- HTTP: `core/MiniHttp.java`, a bounded HTTP/1.1 client over `java.net.Socket`.
  HTTPS uses the platform `SSLSocketFactory`, endpoint identification and the
  platform hostname verifier, and there is no way to turn either off.
- JSON: Android's built-in `org.json`.
- Discovery: Android `NsdManager`.
- Secret storage: Android Keystore AES-GCM.

## Test-only dependencies

`junit:junit:4.13.2` (EPL-1.0) and `org.json:json:20250517` (public domain),
both pinned in the verification metadata. They are not in the APK.
