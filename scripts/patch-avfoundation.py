#!/usr/bin/env python3
"""Add exact capture-device identity options to the pinned LGPL FFmpeg adapter.

The original source archive plus this script and build-runtime.sh are the complete
rebuild materials. Missing IDs fail without selecting a default device or screen.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / 'libavdevice/avfoundation.m'
text = source.read_text()
if 'setbeam_exact_device_identity_v1' in text:
    raise SystemExit(0)
changes = [
    ('    char            *video_filename;\n', '    char            *video_filename;\n    char            *video_device_unique_id;\n    char            *audio_device_unique_id;\n'),
    ('    // check for device index given in filename\n', '''    // setbeam_exact_device_identity_v1: resolve within this process, never fall back.
    if (ctx->video_device_unique_id) {
        NSString *wanted = [NSString stringWithUTF8String:ctx->video_device_unique_id];
        ctx->video_device_index = -1;
        int index = 0;
        for (AVCaptureDevice *device in devices) {
            if ([[device uniqueID] isEqualToString:wanted]) ctx->video_device_index = index;
            index++;
        }
        for (AVCaptureDevice *device in devices_muxed) {
            if ([[device uniqueID] isEqualToString:wanted]) ctx->video_device_index = index;
            index++;
        }
        if (ctx->video_device_index < 0) {
            av_log(s, AV_LOG_ERROR, "The selected video device is disconnected.\\n");
            goto fail;
        }
    }
    if (ctx->audio_device_unique_id) {
        NSString *wanted = [NSString stringWithUTF8String:ctx->audio_device_unique_id];
        ctx->audio_device_index = -1;
        int index = 0;
        for (AVCaptureDevice *device in getDevicesWithMediaType(AVMediaTypeAudio)) {
            if ([[device uniqueID] isEqualToString:wanted]) ctx->audio_device_index = index;
            index++;
        }
        if (ctx->audio_device_index < 0) {
            av_log(s, AV_LOG_ERROR, "The selected audio device is disconnected.\\n");
            goto fail;
        }
    }

    // check for device index given in filename
'''),
    ('static const AVOption options[] = {\n', '''static const AVOption options[] = {
    { "video_device_unique_id", "open this exact video device, without fallback", offsetof(AVFContext, video_device_unique_id), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
    { "audio_device_unique_id", "open this exact audio device, without fallback", offsetof(AVFContext, audio_device_unique_id), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
''')]
for original, replacement in changes:
    if text.count(original) != 1:
        raise SystemExit('Pinned AVFoundation patch no longer matches its source')
    text = text.replace(original, replacement)
source.write_text(text)
