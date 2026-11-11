import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from preview_timing import validate_live_timing


class PreviewTimingTests(unittest.TestCase):
    def video(self, adjustment=0, at=1):
        pts = [round(i * 1e6 / 60) + (adjustment if i >= at else 0) for i in range(90)]
        return [dict(pts=value, duration=max(1, value - pts[i - 1]) if i else 33333)
                for i, value in enumerate(pts)]

    def test_initial_rtcp_alignment_can_move_either_direction(self):
        for adjustment in [0, -16345, -18000]:
            with self.subTest(adjustment=adjustment):
                validate_live_timing(self.video(adjustment))

    def test_rtp_clock_is_not_a_valid_initial_frame_duration(self):
        video = self.video()
        video[0]["duration"] = 11
        with self.assertRaises(AssertionError):
            validate_live_timing(video)

    def test_positive_durations_still_have_to_match_source_pts(self):
        video = self.video(-16345)
        video[1]["duration"] = 16667
        with self.assertRaises(AssertionError):
            validate_live_timing(video)

    def test_late_or_unbounded_clock_jumps_fail(self):
        for adjustment, at in [(-18000, 50), (-200000, 1), (200000, 1)]:
            with self.subTest(adjustment=adjustment, at=at), self.assertRaises(AssertionError):
                validate_live_timing(self.video(adjustment, at))

    def test_short_or_stalled_decode_fails(self):
        with self.assertRaises(AssertionError):
            validate_live_timing(self.video()[:-1])
        video = self.video()
        for frame in video[50:]:
            frame["pts"] = video[49]["pts"]
        with self.assertRaises(AssertionError):
            validate_live_timing(video)
