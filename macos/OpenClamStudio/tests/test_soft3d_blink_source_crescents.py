"""Warm 3-D sclera evidence must close full eyes, never invent smaller ones."""
from contextlib import ExitStack
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import blink, export
from tests.test_soft3d_blink_ownership import _pair_fixture, _registration


def _warm_fixture():
    skin = (60, 120, 220)
    key = np.full((260, 460, 3), skin, np.uint8)
    shut = key.copy()
    landmarks = np.full((478, 2), (230, 130), np.float32)
    eyes = {}
    for side, cx in zip(blink.SIDES, (130, 330)):
        cy = 118
        cv2.ellipse(key, (cx, cy), (50, 23), 0, 0, 360,
                    (125, 180, 230), -1)
        cv2.ellipse(key, (cx, cy), (50, 23), 0, 0, 360,
                    (20, 25, 30), 2)
        cv2.circle(key, (cx, cy), 20, (25, 55, 90), -1)
        cv2.circle(key, (cx, cy), 10, (15, 18, 20), -1)
        cv2.circle(key, (cx - 5, cy - 7), 3, (250, 250, 250), -1)
        curve = np.array([(cx - 47, cy + 6), (cx - 24, cy + 16),
                          (cx, cy + 19), (cx + 24, cy + 16),
                          (cx + 47, cy + 6)], np.int32)
        cv2.polylines(shut, [curve], False, (20, 25, 30), 2, cv2.LINE_AA)
        angles = np.linspace(0, 2 * np.pi, len(blink.EYE[side]), endpoint=False)
        landmarks[blink.EYE[side], 0] = cx + np.cos(angles) * 50
        landmarks[blink.EYE[side], 1] = cy + np.sin(angles) * 23
        iris_index = 468 if side == "r" else 473
        landmarks[iris_index] = (cx, cy)
        landmarks[iris_index + 1:iris_index + 5] = [
            (cx + 14, cy), (cx, cy - 14), (cx - 14, cy), (cx, cy + 14)]
        eyes[side] = {"box": [cx - 72, cy - 40, 144, 80]}
    return key, shut, landmarks, eyes


class Soft3DSourceCrescentBlinkTests(unittest.TestCase):
    def test_warm_source_crescents_are_measured_without_pixel_changes(self):
        key, shut, landmarks, _ = _warm_fixture()
        before_key, before_landmarks = key.copy(), landmarks.copy()
        self.assertIsNone(export._soft3d_compact_eye_masks(key, landmarks))
        result = export._soft3d_source_crescent_masks(key, landmarks)
        self.assertIsNotNone(result)
        masks, observations = result
        for side, cx in zip(blink.SIDES, (130, 330)):
            observed = observations[side]
            self.assertEqual(255, observed[118, cx - 35])
            self.assertEqual(255, observed[118, cx + 35])
            self.assertEqual(0, observed[118, cx])  # pupil, not white paint
            self.assertEqual(0, observed[111, cx - 5])  # isolated catchlight
            self.assertEqual(0, observed[150, cx])  # dry skin
            box, alpha = masks[side]
            x, y, width, height = box
            self.assertEqual((height, width), alpha.shape)
            self.assertGreater(width, 100)
            self.assertEqual(255, alpha[118 - y, cx - x])
        np.testing.assert_array_equal(before_key, key)
        np.testing.assert_array_equal(before_landmarks, landmarks)

    def test_whole_pair_rejected_when_one_eye_has_no_source_crescents(self):
        key, _, landmarks, _ = _warm_fixture()
        key[:, 245:] = (60, 120, 220)
        self.assertIsNotNone(export._soft3d_source_sclera(key, landmarks, "r"))
        self.assertIsNone(export._soft3d_source_crescent_masks(key, landmarks))

    def test_landmarks_alone_or_unseparated_skin_colour_are_not_evidence(self):
        key, _, landmarks, _ = _warm_fixture()
        for paint in ((125, 180, 230), (80, 80, 80), (200, 200, 200)):
            uniform = np.full(key.shape, paint, np.uint8)
            self.assertIsNone(export._soft3d_source_crescent_masks(uniform, landmarks))

    def test_open_background_connection_is_not_an_isolated_sclera(self):
        key, _, landmarks, _ = _warm_fixture()
        cv2.rectangle(key, (0, 113), (100, 123), (125, 180, 230), -1)
        self.assertIsNone(export._soft3d_source_sclera(key, landmarks, "r"))

    def test_bad_image_landmarks_or_side_fail_closed(self):
        key, _, landmarks, _ = _warm_fixture()
        nonfinite = landmarks.copy()
        nonfinite[468, 0] = np.nan
        enormous = landmarks.astype(np.float64)
        enormous[468, 0] = 1e300
        outside = landmarks.copy()
        outside[468, 1] = -1
        for image, points, side in (
                (None, landmarks, "r"), (key[:, :, 0], landmarks, "r"),
                (key.astype(float), landmarks, "r"), (key, None, "r"),
                (key, landmarks[:477], "r"), (key, nonfinite, "r"),
                (key, enormous, "r"), (key, outside, "r"),
                (key, landmarks.astype(str), "r"), (key, landmarks, "other")):
            with self.subTest(side=side, shape=getattr(points, "shape", None)):
                self.assertIsNone(export._soft3d_source_sclera(image, points, side))

    def test_optional_observation_must_match_canonical_shape_and_type(self):
        key, _, _, eyes = _warm_fixture()
        for observation in (np.zeros((3, 4), np.uint8),
                            np.zeros(key.shape[:2], np.float32), "mask"):
            self.assertIsNone(export._stylized_eye_alpha(
                key, eyes["r"], source_sclera=observation))

    def test_existing_successful_full_eye_never_uses_new_fallback(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            fallback = stack.enter_context(mock.patch.object(
                export, "_soft3d_source_crescent_masks", side_effect=AssertionError))
            result = export.preflight_stylized_blink(
                directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)
            self.assertIsNotNone(result)
            fallback.assert_not_called()

    def test_existing_compact_masks_have_priority_over_source_fallback(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        masks = {side: export._stylized_eye_alpha(key, eyes[side])
                 for side in blink.SIDES}
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            stack.enter_context(mock.patch.object(export, "_stylized_eye_alpha", return_value=None))
            old_compact = stack.enter_context(mock.patch.object(
                export, "_soft3d_compact_eye_masks", return_value=masks))
            fallback = stack.enter_context(mock.patch.object(
                export, "_soft3d_source_crescent_masks", side_effect=AssertionError))
            try:
                export.preflight_stylized_blink(
                    directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)
            except export.StylizedBlinkNotReady:
                pass  # Subsequent source QA is independent of mask routing.
            old_compact.assert_called_once()
            fallback.assert_not_called()

    def test_non3d_media_never_dispatch_source_fallback(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            stack.enter_context(mock.patch.object(export, "_stylized_eye_alpha", return_value=None))
            fallback = stack.enter_context(mock.patch.object(
                export, "_soft3d_source_crescent_masks", side_effect=AssertionError))
            for medium in ("illustration", "photograph", "unknown", None):
                try:
                    export.preflight_stylized_blink(
                        directory, medium, neutral=key, eyes=eyes, log=lambda _: None)
                except export.StylizedBlinkNotReady:
                    pass
            fallback.assert_not_called()

    def test_warm_mask_does_not_allow_an_unclosed_provider_eye(self):
        key, _, landmarks, eyes = _warm_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), key)
            _registration(stack, landmarks)
            with self.assertRaises(export.StylizedBlinkNotReady):
                export.preflight_stylized_blink(
                    directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)


if __name__ == "__main__":
    unittest.main()
