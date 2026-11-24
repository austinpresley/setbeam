"""Validate the real 60 fps loopback fixture without rewriting its source clock."""


def validate_live_timing(video):
    assert len(video) == 90, len(video)
    # A frame-rate guess estimates only the first duration. Later positive PTS
    # deltas are authoritative, including the first RTCP alignment.
    assert 1_000 <= video[0]["duration"] < 100_000, video[:3]
    intervals = [right["pts"] - left["pts"] for left, right in zip(video, video[1:])]
    cadence = 1e6 / 60
    # The first RTCP report can shift the RTP clock in either direction. A
    # forward shift adds to the normal frame interval in the decoder output.
    adjustments = [(index, delta) for index, delta in enumerate(intervals) if not 0 < delta < 100_000]
    assert len(adjustments) <= 1, adjustments
    assert all(index < 30 and -100_000 < delta < cadence + 100_000 for index, delta in adjustments), adjustments
    for right, delta in zip(video[1:], intervals):
        duration = right["duration"]
        assert 0 < duration and (duration < 100_000 or delta >= 100_000), right
        if delta > 0:
            assert duration == delta, right
    # The one-second MP4 loop can have a longer audio-tail interval. Keep the
    # original requirement for at least 85 normal steps out of the 89 measured.
    assert sum(abs(delta - cadence) < 10 for delta in intervals) >= 85, intervals
