#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { echo 'This prototype runtime build targets Apple Silicon.' >&2; exit 1; }
JOBS="${SETBEAM_BUILD_JOBS:-6}"
mkdir -p Vendor/cache Vendor/sources Vendor/bin Vendor/licenses build/logs
python3 - <<'PY'
import hashlib,json,subprocess,tarfile
from pathlib import Path
root=Path.cwd();lock=json.loads((root/'runtime-lock.json').read_text())
for item in lock['dependencies']:
    archive=root/'Vendor/cache'/item['archive']
    if not archive.exists():
        subprocess.run(['curl','-fL','--retry','3','--connect-timeout','20','--max-time','180',item['url'],'-o',str(archive)],check=True)
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest!=item['sha256']:raise SystemExit('Checksum mismatch: '+item['name'])
    destination=root/'Vendor/sources'
    if item['name']=='mediamtx':destination=destination/'mediamtx';destination.mkdir(exist_ok=True)
    marker=destination/(item['name']+'-'+item['version']) if item['name']!='mediamtx' else destination/'mediamtx'
    if not marker.exists():
        with tarfile.open(archive) as source:source.extractall(destination,filter='data')
    print('Verified '+item['name']+' '+item['version'])
for item in lock['sourceMaterials']:
    archive=root/'Vendor/cache'/item['archive']
    if not archive.exists():
        subprocess.run(['curl','-fL','--retry','3','--connect-timeout','20','--max-time','180',item['url'],'-o',str(archive)],check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']:
        raise SystemExit('Checksum mismatch: '+item['archive'])
PY
cp Vendor/sources/mediamtx/mediamtx Vendor/bin/mediamtx
cp Vendor/sources/mediamtx/LICENSE Vendor/licenses/MediaMTX-MIT.txt
if [[ ! -f Vendor/opus/lib/libopus.a || "${SETBEAM_REBUILD_OPUS:-0}" == 1 ]]; then
  (
    cd Vendor/sources/opus-1.6.1
    export MACOSX_DEPLOYMENT_TARGET=14.0
    [[ ! -f Makefile ]] || make clean
    ./configure --prefix="$ROOT/Vendor/opus" \
      --disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs
    make -j "$JOBS"
    make install
  ) > build/logs/opus-build.log 2>&1
fi
cp Vendor/sources/opus-1.6.1/COPYING Vendor/licenses/Opus-BSD.txt
if [[ ! -x Vendor/bin/ffmpeg || "${SETBEAM_REBUILD_FFMPEG:-0}" == 1 ]]; then
  (
    cd Vendor/sources/ffmpeg-9.0.2
    [[ ! -f Makefile ]] || make clean
    export PKG_CONFIG_LIBDIR="$ROOT/Vendor/opus/lib/pkgconfig"
    export PKG_CONFIG_PATH=""
    export MACOSX_DEPLOYMENT_TARGET=14.0
    ./configure --prefix="$ROOT/Vendor/ffmpeg" --arch=aarch64 --target-os=darwin \
      --disable-autodetect --disable-everything --disable-gpl --disable-nonfree \
      --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay \
      --enable-ffmpeg --enable-ffprobe --enable-pthreads --enable-avfoundation \
      --enable-videotoolbox --enable-libopus --enable-zlib --pkg-config-flags=--static \
      --enable-indev=lavfi,avfoundation \
      --enable-demuxer=rtsp,rtp,mov,matroska,rawvideo,image2,image2pipe,h264 \
      --enable-muxer=rtsp,rtp,mov,mp4,matroska,image2,image2pipe,null,framecrc,framemd5,pcm_s16le \
      --enable-protocol=file,pipe,tcp,udp,rtp,http \
      --enable-decoder=h264,hevc,aac,aac_latm,opus,libopus,rawvideo,wrapped_avframe,mjpeg,png,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le \
      --enable-encoder=h264_videotoolbox,libopus,aac,mjpeg,png,wrapped_avframe,pcm_s16le,rawvideo \
      --enable-parser=h264,hevc,aac,aac_latm,opus,mjpeg,png \
      --enable-filter=testsrc2,color,sine,anullsrc,anull,scale,format,aresample,aformat,fps,null,volume,split,asplit,setpts,asetpts,trim,atrim \
      --enable-bsf=h264_mp4toannexb,aac_adtstoasc,extract_extradata,filter_units,setts
    make -j "$JOBS"
    cp ffmpeg ffprobe "$ROOT/Vendor/bin/"
    cp ffbuild/config.mak "$ROOT/Vendor/licenses/FFmpeg-build-configuration.txt"
  ) > build/logs/ffmpeg-build.log 2>&1
fi
cp Vendor/sources/ffmpeg-9.0.2/COPYING.LGPLv2.1 Vendor/licenses/FFmpeg-LGPL-2.1.txt
cp runtime-lock.json Vendor/licenses/runtime-lock.json
cp scripts/build-runtime.sh Vendor/licenses/build-runtime.sh
if [[ -f build/logs/ffmpeg-build.log ]] && grep -q 'was built for newer.*version' build/logs/ffmpeg-build.log; then
  echo 'Mixed deployment targets in the media runtime; rebuild Opus and FFmpeg.' >&2
  exit 1
fi
for executable in Vendor/bin/mediamtx Vendor/bin/ffmpeg Vendor/bin/ffprobe; do
  if otool -L "$executable" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' | grep -q .; then
    echo "Non-system dynamic library dependency in $executable" >&2
    otool -L "$executable" >&2
    exit 1
  fi
done
Vendor/bin/ffmpeg -hide_banner -version | head -n 3
Vendor/bin/mediamtx --version
echo 'Project-local runtime ready. Build logs are in build/logs.'
