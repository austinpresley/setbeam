#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { echo 'The runtime build requires Apple Silicon.' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'Install pkg-config before building the runtime.' >&2; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' || { echo 'Install Python 3.12 or newer.' >&2; exit 1; }
xcrun --sdk macosx --find clang >/dev/null
if [[ -z "${SETBEAM_BUILD_LOCK_FD:-}" ]]; then
  exec python3 scripts/build-support.py lock "$ROOT/scripts/build-runtime.sh" "$@"
fi
JOBS="${SETBEAM_BUILD_JOBS:-6}"
if [[ "${SETBEAM_REBUILD_OPUS:-0}" != 1 && "${SETBEAM_REBUILD_FFMPEG:-0}" != 1 ]]; then
  if python3 scripts/build-support.py matches; then
    echo 'Verified cached runtime against the archive, patch, build options, toolchain, and output hashes.'
    exit 0
  else
    [[ $? == 1 ]] || exit 1
  fi
fi
scratch="$(mktemp -d "$ROOT/Vendor/.runtime.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/licenses" "$scratch/tmp"
python3 scripts/build-support.py extract "$scratch"
export TMPDIR="$scratch/tmp" MACOSX_DEPLOYMENT_TARGET=14.0
export CC="$(xcrun --sdk macosx --find clang)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS CPATH LIBRARY_PATH PKG_CONFIG_SYSROOT_DIR
(
  cd "$scratch/sources/opus-1.6.1"
  ./configure --prefix="$scratch/opus" \
    --disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs
  make -j "$JOBS"
  make install
) > build/logs/opus-build.log 2>&1 || { tail -n 70 build/logs/opus-build.log; exit 1; }
python3 scripts/patch-avfoundation.py "$scratch/sources/ffmpeg-9.0.2"
(
    cd "$scratch/sources/ffmpeg-9.0.2"
    export PKG_CONFIG_LIBDIR="$scratch/opus/lib/pkgconfig" PKG_CONFIG_PATH=""
    ./configure --prefix="$scratch/ffmpeg" --arch=aarch64 --target-os=darwin --cc="$CC" \
      --disable-autodetect --disable-everything --disable-gpl --disable-nonfree \
      --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay \
      --enable-ffmpeg --enable-ffprobe --enable-pthreads --enable-avfoundation \
      --enable-videotoolbox --enable-libopus --enable-zlib --pkg-config-flags=--static \
      --enable-indev=lavfi,avfoundation \
      --enable-demuxer=rtsp,rtp,sdp,mov,matroska,rawvideo,image2,image2pipe,h264,hevc,aac \
      --enable-muxer=rtsp,rtp,mov,mp4,flv,matroska,image2,image2pipe,null,framecrc,framemd5,pcm_s16le \
      --enable-protocol=file,pipe,tcp,udp,rtp,http,rtmp \
      --enable-decoder=h264,hevc,aac,aac_latm,opus,libopus,rawvideo,wrapped_avframe,mjpeg,png,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le \
      --enable-encoder=h264_videotoolbox,libopus,aac,mjpeg,png,wrapped_avframe,pcm_s16le,rawvideo \
      --enable-parser=h264,hevc,aac,aac_latm,opus,mjpeg,png \
      --enable-filter=testsrc2,color,sine,anullsrc,anull,scale,format,aresample,aformat,fps,select,null,volume,split,asplit,setpts,asetpts,trim,atrim \
      --enable-bsf=h264_mp4toannexb,aac_adtstoasc,extract_extradata,filter_units,setts
    make -j "$JOBS"
    cp ffmpeg ffprobe "$scratch/bin/"
    cp ffbuild/config.mak "$scratch/licenses/FFmpeg-build-configuration.txt"
) > build/logs/ffmpeg-build.log 2>&1 || { tail -n 70 build/logs/ffmpeg-build.log; exit 1; }
cp "$scratch/sources/mediamtx/mediamtx" "$scratch/bin/"
cp "$scratch/sources/mediamtx/LICENSE" "$scratch/licenses/MediaMTX-MIT.txt"
cp "$scratch/sources/opus-1.6.1/COPYING" "$scratch/licenses/Opus-BSD.txt"
cp "$scratch/sources/ffmpeg-9.0.2/COPYING.LGPLv2.1" "$scratch/licenses/FFmpeg-LGPL-2.1.txt"
cp scripts/build-runtime.sh scripts/build-support.py scripts/patch-avfoundation.py "$scratch/licenses/"
if grep -q 'was built for newer.*version' build/logs/ffmpeg-build.log; then
  echo 'Mixed deployment targets in the media runtime.' >&2
  exit 1
fi
for binary in "$scratch"/bin/*; do
  links="$(otool -L "$binary")"
  if awk 'NR > 1 && $1 !~ /^\/(System\/Library|usr\/lib)\// {print; bad=1} END {exit !bad}' <<< "$links"; then
    echo "Non-system dynamic library dependency in $binary" >&2
    exit 1
  fi
done
python3 scripts/build-support.py install-runtime "$scratch"
echo 'Project-local runtime ready. Build logs are in build/logs.'
