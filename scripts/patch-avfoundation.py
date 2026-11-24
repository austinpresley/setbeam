#!/usr/bin/env python3
"""Add exact capture-device identity options to the pinned LGPL FFmpeg adapter.

The original source archive plus this script and build-runtime.sh are the complete
rebuild materials. Missing IDs fail without selecting a default device or screen.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / 'libavdevice/avfoundation.m'
text = source.read_text()
if 'setbeam_exact_device_identity_v2' in text:
    raise SystemExit(0)
changes = [
    ('    char            *video_filename;\n', '    char            *video_filename;\n    char            *video_device_unique_id;\n    char            *audio_device_unique_id;\n'),
    ('    // check for device index given in filename\n', '''    // setbeam_exact_device_identity_v2: resolve within this process, never fall back.
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
        for (AVCaptureDevice *device in getDevicesWithMediaType(AVMediaTypeAudio)) {
            if ([[device uniqueID] isEqualToString:wanted]) {
                audio_device = device;
                break;
            }
        }
        if (!audio_device) {
            av_log(s, AV_LOG_ERROR, "The selected audio device is disconnected.\\n");
            goto fail;
        }
    }

    // check for device index given in filename
'''),
    ('    // get audio device\n    if (ctx->audio_device_index >= 0) {', '''    // The exact-ID match already owns the object from its enumeration.
    if (ctx->audio_device_unique_id) {
        // Skip legacy index and name selection.
    } else if (ctx->audio_device_index >= 0) {'''),
    ('    AVCaptureAudioDataOutput *audio_output;\n', '''    AVCaptureAudioDataOutput *audio_output;
    dispatch_queue_t          video_queue;
    dispatch_queue_t          audio_queue;
    int                       video_configuration_locked;
'''),
    ('        if ([video_device lockForConfiguration:NULL] == YES) {\n', '''        if ([video_device lockForConfiguration:NULL] == YES) {
            ctx->video_configuration_locked = 1;
'''),
    ('    if (audio_device && add_audio_device(s, audio_device)) {\n    }', '''    if (audio_device && add_audio_device(s, audio_device)) {
        goto fail;
    }'''),
    ('    if (!ctx->video_is_screen) {\n        [video_device unlockForConfiguration];\n    }', '''    if (ctx->video_configuration_locked) {
        [video_device unlockForConfiguration];
        ctx->video_configuration_locked = 0;
    }'''),
    ('fail:\n    [pool release];', '''fail:
    if (ctx->video_configuration_locked)
        [video_device unlockForConfiguration];
    [pool release];'''),
    ('    dispatch_release(queue);\n\n    if ([ctx->capture_session canAddOutput:ctx->video_output])', '''    ctx->video_queue = queue;

    if ([ctx->capture_session canAddOutput:ctx->video_output])'''),
    ('    dispatch_release(queue);\n\n    if ([ctx->capture_session canAddOutput:ctx->audio_output])', '''    ctx->audio_queue = queue;

    if ([ctx->capture_session canAddOutput:ctx->audio_output])'''),
    ('static void destroy_context(AVFContext* ctx)\n{\n    [ctx->capture_session stopRunning];', '''static void drain_capture_callbacks(void *unused) {}

static void destroy_context(AVFContext* ctx)
{
    [ctx->capture_session stopRunning];
    [ctx->video_output setSampleBufferDelegate:nil queue:NULL];
    [ctx->audio_output setSampleBufferDelegate:nil queue:NULL];
    if (ctx->video_queue) {
        dispatch_sync_f(ctx->video_queue, NULL, drain_capture_callbacks);
        dispatch_release(ctx->video_queue);
    }
    if (ctx->audio_queue) {
        dispatch_sync_f(ctx->audio_queue, NULL, drain_capture_callbacks);
        dispatch_release(ctx->audio_queue);
    }
    if (ctx->current_audio_frame)
        CFRelease(ctx->current_audio_frame);'''),
    ('static int get_video_config(AVFormatContext *s)\n', '''// Read the first sample under the same lock as the delegate. The runtime
// also supervises startRunning itself, which can block in the device driver.
static int wait_for_capture_sample(AVFormatContext *s, int audio)
{
    AVFContext *ctx = s->priv_data;
    const int64_t deadline = av_gettime_relative() + 5000000;
    for (;;) {
        lock_frames(ctx);
        const int ready = audio ? ctx->current_audio_frame != nil : ctx->current_frame != nil;
        unlock_frames(ctx);
        if (ready)
            return 0;
        if (![ctx->capture_session isRunning] || av_gettime_relative() >= deadline ||
            (s->interrupt_callback.callback && s->interrupt_callback.callback(s->interrupt_callback.opaque))) {
            av_log(s, AV_LOG_ERROR, "The selected %s device did not start delivering samples.\\n",
                   audio ? "audio" : "video");
            return 1;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, YES);
    }
}

static int get_video_config(AVFormatContext *s)
'''),
    ('''    while (ctx->frames_captured < 1) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
    }''', '''    if (wait_for_capture_sample(s, 0))
        return 1;'''),
    ('''    while (ctx->audio_frames_captured < 1) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
    }''', '''    if (wait_for_capture_sample(s, 1))
        return 1;'''),
    ('static const AVOption options[] = {\n', '''static const AVOption options[] = {
    { "video_device_unique_id", "open this exact video device, without fallback", offsetof(AVFContext, video_device_unique_id), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
    { "audio_device_unique_id", "open this exact audio device object, without fallback", offsetof(AVFContext, audio_device_unique_id), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
''')]
for original, replacement in changes:
    if text.count(original) != 1:
        raise SystemExit('Pinned AVFoundation patch no longer matches its source')
    text = text.replace(original, replacement)
source.write_text(text)
