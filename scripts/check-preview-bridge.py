#!/usr/bin/env python3
"""Actual decoded protocol checks, using generated local media and owned children."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import socket
import time
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--tools", type=Path, default=Path("Vendor/bin"))
args = parser.parse_args()
tools = args.tools.resolve()

with tempfile.TemporaryDirectory(prefix="Setbeam-preview-check-") as temporary:
    media = Path(temporary) / "1080p60.mp4"
    subprocess.run([str(tools / "ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-c:v", "h264_videotoolbox",
        "-realtime", "true", "-pix_fmt", "yuv420p", "-c:a", "aac", str(media)], check=True, timeout=30)

    def decode(options, source=media, maximum_video=None):
        records = []
        child = subprocess.Popen([str(tools / "setbeam-preview"), str(source)] + options, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=temporary)
        timeout = threading.Timer(15, child.kill); timeout.start()
        try:
            while True:
                header = child.stdout.read(64)
                if not header:
                    break
                assert len(header) == 64 and header[:6] == b"SBPF\x01\x00", "invalid protocol header"
                kind = struct.unpack_from("<H", header, 6)[0]
                size, flags = struct.unpack_from("<II", header, 8)
                pts, duration = struct.unpack_from("<qq", header, 16)
                width, height, channels, rate = struct.unpack_from("<IIII", header, 32)
                assert size <= 8192 * 8192 * 3 // 2, "unbounded packet"
                payload = child.stdout.read(size)
                assert len(payload) == size, "truncated payload"
                records.append(dict(kind=kind, flags=flags, pts=pts, duration=duration, width=width, height=height, channels=channels, rate=rate, size=size))
                if maximum_video and sum(record["kind"] == 1 for record in records) >= maximum_video:
                    child.terminate(); break
            assert child.wait(timeout=10) == 0, child.stderr.read().decode()
        finally:
            timeout.cancel()
            if child.poll() is None:
                child.kill()
            child.wait()
        return records

    records = decode([])
    video = [record for record in records if record["kind"] == 1]
    audio = [record for record in records if record["kind"] == 2]
    assert len(video) == 60, len(video)
    assert all(record["width"] == 1920 and record["height"] == 1080 and record["size"] == 1920 * 1080 * 3 // 2 for record in video)
    cadence = [(right["pts"] - left["pts"]) / 1e6 for left, right in zip(video, video[1:])]
    assert cadence and all(abs(step - 1 / 60) < 0.000002 for step in cadence), cadence
    assert all(record["channels"] == 2 and record["rate"] == 48000 and record["size"] % 8 == 0 for record in audio)
    assert len(audio) > 40 and abs(video[0]["pts"] - audio[0]["pts"]) < 50_000
    assert abs(video[-1]["pts"] - audio[-1]["pts"]) < 100_000
    thumbnail = decode(["--silent", "--width", "384", "--fps", "8"])
    small = [record for record in thumbnail if record["kind"] == 1]
    assert 7 <= len(small) <= 8 and all(record["width"] == 384 and record["height"] == 216 for record in small)
    assert all(record["kind"] != 2 for record in thumbnail)
    print("PASS: one timestamped native decode preserves 1920x1080 at 60 fps with synchronized-source PCM; bounded protocol and silent 384/8 thumbnail pass")
    print(json.dumps(dict(videoFrames=len(video), audioPackets=len(audio), firstVideoPTS=video[0]["pts"], lastVideoPTS=video[-1]["pts"],
        firstAudioPTS=audio[0]["pts"], lastAudioPTS=audio[-1]["pts"], thumbnailFrames=len(small)), sort_keys=True))

    # Exercise the real loopback transport. RTSP's 90 kHz packet clock differs
    # from decoder frame time bases, which a file-only test cannot expose.
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0)); port = reserve.getsockname()[1]
    address = f"rtsp://127.0.0.1:{port}/source"
    config = Path(temporary) / "mediamtx.json"
    config.write_text(json.dumps(dict(logLevel="error", rtspAddress=f"127.0.0.1:{port}", rtspTransports=["tcp"], rtspEncryption="no",
        rtmp=False, hls=False, webrtc=False, srt=False, paths=dict(source={}))))
    server = subprocess.Popen([str(tools / "mediamtx"), str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=temporary)
    sender = None
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                assert server.poll() is None and time.monotonic() < deadline, "fixture server did not start"
                time.sleep(0.02)
        sender = subprocess.Popen([str(tools / "ffmpeg"), "-v", "error", "-re", "-stream_loop", "-1", "-i", str(media),
            "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", "libopus", "-rtsp_transport", "tcp", "-f", "rtsp", address],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=temporary)
        time.sleep(0.3)
        live = decode([], source=address, maximum_video=90)
        live_video = [record for record in live if record["kind"] == 1]
        live_audio = [record for record in live if record["kind"] == 2]
        assert len(live_video) == 90 and live_audio
        intervals = [right["pts"] - left["pts"] for left, right in zip(live_video, live_video[1:])]
        assert all(right["duration"] == delta for right, delta in zip(live_video[1:], intervals)), live_video[:3]
        # The one-second MP4 loop can contain one longer interval at its audio-tail
        # boundary. Preserve that real PTS delta rather than inventing constant fps.
        assert sum(abs(delta / 1e6 - 1 / 60) < 0.00001 for delta in intervals) >= 85, intervals
        assert all(0 < delta < 100_000 for delta in intervals)
        print("PASS: actual MediaMTX loopback RTSP retains 1080p60 decoded frame duration and video/audio PTS")
    finally:
        for child in [sender, server]:
            if child is not None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
