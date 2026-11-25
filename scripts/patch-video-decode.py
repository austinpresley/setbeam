#!/usr/bin/env python3
"""Gate the pinned FFmpeg CLI's direct VideoToolbox decode path."""

from pathlib import Path
import sys


source = Path(sys.argv[1]) / "fftools/ffmpeg_dec.c"
text = source.read_text()
changes = (
    ("    enum AVPixelFormat  hwaccel_output_format;\n",
     "    enum AVPixelFormat  hwaccel_output_format;\n    int                 setbeam_video_started;\n"),
    ("    if (pkt) {\n        FrameData *fd = packet_data(pkt);",
     """    // A reader can join a live stream in the middle of a GOP.
    if (pkt && dp->hwaccel_output_format == AV_PIX_FMT_VIDEOTOOLBOX &&
        !dp->setbeam_video_started && pkt->size > 0) {
        if (!(pkt->flags & AV_PKT_FLAG_KEY) || (pkt->flags & AV_PKT_FLAG_CORRUPT))
            return 0;
        dp->setbeam_video_started = 1;
    }

    if (pkt) {
        FrameData *fd = packet_data(pkt);"""),
    ("        if (frame->decode_error_flags || (frame->flags & AV_FRAME_FLAG_CORRUPT)) {",
     """        // Direct encode bypasses Setbeam's software scale/format filter.
        if (dp->hwaccel_output_format == AV_PIX_FMT_VIDEOTOOLBOX) {
            const AVHWFramesContext *hw = frame->hw_frames_ctx ?
                (const AVHWFramesContext *)frame->hw_frames_ctx->data : NULL;
            if (frame->format != AV_PIX_FMT_VIDEOTOOLBOX || !hw ||
                hw->sw_format != AV_PIX_FMT_NV12 || (frame->width & 1) || (frame->height & 1)) {
                av_log(dp, AV_LOG_ERROR, "Unsupported direct VideoToolbox frame; use the software path.\\n");
                return AVERROR_INVALIDDATA;
            }
        }

        if (frame->decode_error_flags || (frame->flags & AV_FRAME_FLAG_CORRUPT)) {"""),
    ("            avcodec_flush_buffers(dp->dec_ctx);",
     "            avcodec_flush_buffers(dp->dec_ctx);\n            dp->setbeam_video_started = 0;"),
)
for old, new in changes:
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected FFmpeg decoder source: {old!r}")
    text = text.replace(old, new, 1)
source.write_text(text)
