"""Pure regression checks for the frame-analysis expression criteria."""

import unittest
from unittest import mock

from qa import talking_avatar_frame_analysis as frame_qa


class TalkingAvatarFrameAnalysisTests(unittest.TestCase):
    def _analyse(self, neutral, speaking):
        with mock.patch.object(frame_qa, "_frame_metrics") as metrics, \
             mock.patch.object(frame_qa, "_atlas_metrics", return_value={
                 "valid": True,
                 "unique_tiles": 2,
                 "max_delta_from_first": 0.01,
             }), \
             mock.patch.object(frame_qa.Path, "read_text", return_value=(
                 '{"v":22,"visemes":["sil","aa"],'
                 '"eyes":{"states":[0,1],"l":{},"r":{}},'
                 '"gaze":{"dxs":[0,1],"dys":[0],"l":{},"r":{}},'
                 '"brow":{"dys":[0,1],"sqs":[0],"l":{},"r":{}},'
                 '"forehead":{"dys":[0,1],"sqs":[0],"l":{},"r":{}},'
                 '"cheek":{"ups":[0,1],"l":{},"r":{}},'
                 '"eyebag":{"ups":[0,1],"l":{},"r":{}},'
                 '"smile":{"states":[0,1],"visemes":["sil","aa"]},'
                 '"emotion_mouth":{"states":[0,1],"visemes":["sil","aa"],'
                 '"emotions":["sorrow","horror","anger"]}}'
             )):
            metrics.side_effect = [neutral, *speaking]
            return frame_qa.analyse(
                frame_qa.Path("runtime"), "neutral.png",
                [f"frame-{index}.png" for index in range(len(speaking))],
                expect="laughter")

    @staticmethod
    def _row(**changes):
        row = {
            "file": "frame.png", "eye_span_px": 100.0,
            "mouth_aperture": 0.08, "mouth_width": 0.60,
            "smile_corner_lift": 0.02, "eye_open": 0.30,
            "brow_lift": 0.10, "yaw": 0.0, "pitch": 0.0, "roll": 0.0,
        }
        row.update(changes)
        return row

    def test_laughter_needs_corner_lift_not_mouth_widening(self):
        neutral = self._row(smile_corner_lift=0.01, mouth_width=0.60)
        speaking = [
            self._row(smile_corner_lift=0.02, mouth_width=0.60,
                      mouth_aperture=0.10, yaw=0.2),
            self._row(smile_corner_lift=0.022, mouth_width=0.60,
                      mouth_aperture=0.11, yaw=-0.2),
        ]
        result = self._analyse(neutral, speaking)
        laughter = result["capture"]["expression_landscapes"]["laughter"]
        self.assertEqual(0.0, laughter["mouth_width_gain"])
        self.assertTrue(laughter["pass"])

    def test_laughter_rejects_closed_lash_landscape(self):
        neutral = self._row(smile_corner_lift=0.01, eye_open=0.30)
        speaking = [
            self._row(smile_corner_lift=0.022, eye_open=0.12,
                      mouth_aperture=0.10, yaw=0.2),
            self._row(smile_corner_lift=0.024, eye_open=0.13,
                      mouth_aperture=0.11, yaw=-0.2),
        ]
        result = self._analyse(neutral, speaking)
        self.assertFalse(
            result["capture"]["expression_landscapes"]["laughter"]["pass"])


if __name__ == "__main__":
    unittest.main()
