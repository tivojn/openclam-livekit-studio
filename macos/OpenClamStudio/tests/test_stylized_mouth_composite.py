"""Focused QA for medium-safe stylized viseme asset composition."""
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import compose, face, rig


def _mouth_landmarks(center=(64.0, 72.0), radii=(16.0, 5.0)):
    landmarks = np.full((478, 2), center, np.float32)
    angles = np.linspace(
        0.0, np.pi * 2.0, len(face.OUTER_LIP), endpoint=False)
    landmarks[face.OUTER_LIP, 0] = center[0] + np.cos(angles) * radii[0]
    landmarks[face.OUTER_LIP, 1] = center[1] + np.sin(angles) * radii[1]
    return landmarks


class StylizedMouthCompositeTests(unittest.TestCase):
    def test_transfer_is_lip_only_and_harmonizes_provider_skin(self):
        canonical = np.full((128, 128, 3), (84, 148, 214), np.uint8)
        donor = np.full((128, 128, 3), (124, 105, 164), np.uint8)
        # Preserve a deliberately high-contrast authored mouth interior.
        cv2.ellipse(donor, (68, 73), (17, 6), 0, 0, 360,
                    (24, 32, 70), -1)
        cv2.line(donor, (54, 71), (82, 71), (235, 240, 245), 2)
        key_landmarks = _mouth_landmarks()
        donor_landmarks = _mouth_landmarks(center=(68.0, 73.0),
                                           radii=(17.0, 6.0))
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

        alpha = compose._stylized_mouth_alpha(
            canonical.shape, key_landmarks, donor_landmarks, transform)
        matched = compose._stylized_patch_harmonize(
            canonical.astype(np.float32), donor.astype(np.float32), alpha)
        result = (
            canonical.astype(np.float32) * (1.0 - alpha[..., None])
            + matched * alpha[..., None]).astype(np.uint8)

        # The face, nose, chin edge, and cheeks remain literal canonical art.
        self.assertEqual(0.0, float(alpha[40, 64]))
        self.assertEqual(0.0, float(alpha[104, 64]))
        self.assertEqual(0.0, float(alpha[72, 24]))
        self.assertTrue(np.array_equal(result[40, 64], canonical[40, 64]))
        self.assertTrue(np.array_equal(result[104, 64], canonical[104, 64]))

        # Skin immediately beside the lips converges strongly toward the
        # canonical palette, while the dark mouth/bright tooth line survive.
        sample = (72, 45)
        before = np.linalg.norm(
            donor[sample].astype(np.float32)
            - canonical[sample].astype(np.float32))
        after = np.linalg.norm(
            result[sample].astype(np.float32)
            - canonical[sample].astype(np.float32))
        self.assertLess(after, before * 0.28)
        self.assertLess(int(result[73, 68, 2]), 125)
        self.assertGreater(int(result[71, 68, 0]), 160)

    def test_stylized_postprocess_never_invokes_photo_dental_rewriters(self):
        with mock.patch.object(
                compose, "_select_dental_donors",
                side_effect=AssertionError("stylized elected photo teeth")), \
                mock.patch.object(
                    compose, "soften_oral_shadows",
                    side_effect=AssertionError("stylized recolored oral art")), \
                mock.patch.object(
                    compose, "canonicalize_teeth",
                    side_effect=AssertionError("stylized pasted donor teeth")):
            shadows, teeth = compose._finish_viseme_bank(
                "/unused", None, lambda _message: None, rig.normalize(),
                allow_stylized=True)
        self.assertEqual([], shadows)
        self.assertEqual([], teeth)

    def test_photo_postprocess_keeps_the_existing_pipeline(self):
        donors = {"upper": ("SS", None, None, None)}
        with mock.patch.object(
                compose, "_select_dental_donors",
                return_value=donors) as select, \
                mock.patch.object(
                    compose, "soften_oral_shadows",
                    return_value=[{"name": "ah"}]) as shadows, \
                mock.patch.object(
                    compose, "canonicalize_teeth",
                    return_value=[{"name": "ah"}]) as teeth:
            observed_shadows, observed_teeth = compose._finish_viseme_bank(
                "/photo", "/diag", lambda _message: None, rig.normalize(),
                allow_stylized=False)
        select.assert_called_once()
        shadows.assert_called_once()
        teeth.assert_called_once()
        self.assertEqual([{"name": "ah"}], observed_shadows)
        self.assertEqual([{"name": "ah"}], observed_teeth)


if __name__ == "__main__":
    unittest.main()
