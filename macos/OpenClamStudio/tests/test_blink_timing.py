import random
import unittest

from studio import blink


class BlinkTimingTests(unittest.TestCase):
    def test_idle_blinks_are_irregular_and_more_attentive(self):
        events = blink.schedule(
            60_000, random.Random(29), speaking=False, start=700)
        intervals = [
            current["t0"] - previous["t0"]
            for previous, current in zip(events, events[1:])
        ]
        self.assertGreater(len(intervals), 10)
        self.assertTrue(all(1700 <= value <= 5300 for value in intervals))
        self.assertGreater(max(intervals) - min(intervals), 1200)

    def test_speaking_blinks_keep_a_subtle_bilateral_lead(self):
        events = blink.schedule(
            60_000, random.Random(31), speaking=True, start=700)
        intervals = [
            current["t0"] - previous["t0"]
            for previous, current in zip(events, events[1:])
        ]
        self.assertTrue(all(1300 <= value <= 4300 for value in intervals))
        self.assertTrue(all(22 <= abs(event["skew"]) <= 56
                            for event in events))
        self.assertTrue(any(event["skew"] < 0 for event in events))
        self.assertTrue(any(event["skew"] > 0 for event in events))

    def test_eye_curves_are_offset_without_becoming_two_blinks(self):
        event = {"t0": 1000, "k": 1, "amp": 1, "skew": 40}
        left = blink.lid_at([event], 1080, "l")
        right = blink.lid_at([event], 1080, "r")
        self.assertGreater(left, right)
        self.assertGreater(right, 0)
        self.assertEqual(blink.lid_at([event], 1600, "l"), 0)
        self.assertEqual(blink.lid_at([event], 1600, "r"), 0)


if __name__ == "__main__":
    unittest.main()
