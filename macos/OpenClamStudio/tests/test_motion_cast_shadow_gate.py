"""Synthetic regression coverage for motion cast-shadow rejection."""
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import motion


def _clean_plate():
    height, width = 240, 180
    source = np.full((height, width, 3), 255, dtype=np.uint8)
    alpha = np.zeros((height, width), dtype=np.uint8)

    # Chromatic skin/clothing plus deliberately black hair and one-pixel heel
    # stems.  Those legitimate dark structures must never look like shadows.
    cv2.ellipse(source, (88, 39), (25, 27), 0, 0, 360, (28, 34, 42), -1)
    cv2.ellipse(alpha, (88, 39), (25, 27), 0, 0, 360, 255, -1)
    cv2.circle(source, (91, 43), 18, (112, 156, 205), -1)
    cv2.circle(alpha, (91, 43), 18, 255, -1)
    cv2.rectangle(source, (64, 59), (116, 153), (32, 42, 205), -1)
    cv2.rectangle(alpha, (64, 59), (116, 153), 255, -1)
    for left in (72, 98):
        cv2.rectangle(source, (left, 149), (left + 12, 214), (112, 156, 205), -1)
        cv2.rectangle(alpha, (left, 149), (left + 12, 214), 255, -1)
    cv2.rectangle(source, (65, 211), (86, 217), (24, 24, 24), -1)
    cv2.rectangle(alpha, (65, 211), (86, 217), 255, -1)
    cv2.rectangle(source, (96, 211), (120, 217), (24, 24, 24), -1)
    cv2.rectangle(alpha, (96, 211), (120, 217), 255, -1)
    cv2.line(source, (69, 216), (69, 224), (18, 18, 18), 1, cv2.LINE_8)
    cv2.line(alpha, (69, 216), (69, 224), 255, 1, cv2.LINE_8)
    cv2.line(source, (115, 216), (115, 224), (18, 18, 18), 1, cv2.LINE_8)
    cv2.line(alpha, (115, 216), (115, 224), 255, 1, cv2.LINE_8)
    return source, np.dstack((source.copy(), alpha))


class MotionCastShadowQualityTests(unittest.TestCase):
    def quality(self, source, rgba, *, kind="walk", validation="back-heel", count=8):
        return motion._motion_cast_shadow_quality(
            [source.copy() for _ in range(count)],
            [rgba.copy() for _ in range(count)],
            kind,
            idle_validation=validation,
        )

    def test_clean_black_hair_and_thin_heel_stems_pass(self):
        source, rgba = _clean_plate()
        quality = self.quality(source, rgba)
        self.assertTrue(quality["available"])
        self.assertTrue(quality["valid"], quality)
        self.assertEqual([], quality["floor_shadow_frames"])

    def test_persistent_detached_floor_shadow_is_rejected(self):
        source, rgba = _clean_plate()
        cv2.ellipse(source, (92, 231), (35, 4), 0, 0, 360, (155, 155, 155), -1)
        quality = self.quality(source, rgba)
        self.assertFalse(quality["valid"], quality)
        self.assertIn("floor shadow", quality["reason"])
        self.assertGreaterEqual(
            len(quality["floor_shadow_frames"]),
            quality["minimum_persistent_frames"],
        )

    def test_edge_idle_wall_contact_shadow_is_rejected(self):
        source, rgba = _clean_plate()
        cv2.rectangle(source, (44, 72), (60, 151), (142, 142, 142), -1)
        quality = self.quality(source, rgba, kind="idle")
        self.assertFalse(quality["valid"], quality)
        self.assertIn("wall/contact shadow", quality["reason"])

    def test_off_corridor_neutral_detail_and_one_frame_noise_pass(self):
        clean, rgba = _clean_plate()
        off_corridor = clean.copy()
        cv2.rectangle(off_corridor, (150, 72), (164, 151), (142, 142, 142), -1)
        quality = self.quality(off_corridor, rgba, kind="idle")
        self.assertTrue(quality["valid"], quality)

        noisy = [clean.copy() for _ in range(10)]
        cv2.ellipse(noisy[4], (92, 231), (35, 4), 0, 0, 360, (155, 155, 155), -1)
        quality = motion._motion_cast_shadow_quality(
            noisy, [rgba.copy() for _ in noisy], "walk")
        self.assertTrue(quality["valid"], quality)
        self.assertEqual([5], quality["floor_shadow_frames"])

    @mock.patch.object(motion, "_motion_cast_shadow_quality")
    @mock.patch.object(motion, "_segment_frames")
    @mock.patch.object(motion, "_decode_video")
    def test_process_clip_hard_rejects_shadow_even_in_relaxed_shipping(
            self, decode_video, segment_frames, shadow_quality):
        source, rgba = _clean_plate()
        decode_video.return_value = [source.copy(), source.copy()]
        segment_frames.return_value = (
            [rgba.copy(), rgba.copy()],
            [None, None],
            "chroma-key-green-screen",
            {
                "available": True,
                "valid": True,
                "alpha_integrity_quality": {
                    "available": True, "valid": True, "reason": "clean",
                },
            },
        )
        shadow_quality.return_value = {
            "available": True,
            "valid": False,
            "reason": "persistent detached floor shadow beneath the footwear",
        }
        with tempfile.TemporaryDirectory() as stage:
            with self.assertRaisesRegex(RuntimeError, "failed cast-shadow QA"):
                motion._process_clip(
                    "idle", "unused.mov", motion.IDLE_FPS, stage, lambda _message: None)


if __name__ == "__main__":
    unittest.main()
