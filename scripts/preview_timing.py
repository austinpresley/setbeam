"""Validate the real 60 fps loopback fixture without rewriting its source clock."""


def validate_live_timing(video):
    assert len(video) == 90, len(video)
    # A frame-rate guess estimates only the first duration. Later positive PTS
    # deltas are authoritative, even when initial RTCP alignment makes one tiny.
    assert 1_000 <= video[0]["duration"] < 100_000, video[:3]
    assert all(0 < record["duration"] < 100_000 for record in video), video[:3]
    intervals = [right["pts"] - left["pts"] for left, right in zip(video, video[1:])]
    assert all(right["duration"] == delta for right, delta in zip(video[1:], intervals) if delta > 0), video[:3]
    adjustments = [(index, delta) for index, delta in enumerate(intervals) if delta <= 0]
    assert len(adjustments) <= 1 and all(index < 30 and -100_000 < delta <= 0 for index, delta in adjustments), adjustments
    # The one-second MP4 loop can have a longer audio-tail interval. Keep the
    # original requirement for at least 85 normal steps out of the 89 measured.
    assert sum(abs(delta / 1e6 - 1 / 60) < 0.00001 for delta in intervals) >= 85, intervals
    assert all(delta < 100_000 for delta in intervals), intervals
