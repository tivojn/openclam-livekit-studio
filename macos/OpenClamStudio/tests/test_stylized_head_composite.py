"""Regressions for anatomically complete stylized standing-head replacement."""
import inspect
import os
import tempfile
import unittest

import cv2
import numpy as np

from studio import body


def _oval_landmarks(center=(90.0, 85.0), radii=(38.0, 42.0)):
    landmarks = np.zeros((478, 2), np.float32)
    for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
        angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
        landmarks[landmark_index] = (
            center[0] + radii[0] * np.cos(angle),
            center[1] + radii[1] * np.sin(angle),
        )
    return landmarks


def _stylized_portrait():
    """Transparent canonical head with hat, ears, jaw, neck, and a bust."""
    image = np.zeros((180, 180, 4), np.uint8)
    color = (40, 150, 230, 255)
    cv2.ellipse(image, (90, 34), (70, 24), 0, 0, 360, color, -1)
    cv2.ellipse(image, (90, 84), (42, 45), 0, 0, 360, color, -1)
    cv2.ellipse(image, (44, 85), (5, 11), 0, 0, 360, color, -1)
    cv2.ellipse(image, (136, 85), (5, 11), 0, 0, 360, color, -1)
    cv2.rectangle(image, (75, 124), (105, 154), color, -1)
    cv2.rectangle(image, (18, 151), (162, 179), color, -1)
    return image


class StylizedHeadCompositeTests(unittest.TestCase):
    def test_new_jaw_handoff_is_explicitly_versioned_at_authoring(self):
        self.assertEqual(2, body.STYLIZED_HEAD_HANDOFF_VERSION)
        source = inspect.getsource(body._install_sources)
        self.assertIn('metadata["head_handoff_version"]', source)
        self.assertIn("STYLIZED_HEAD_HANDOFF_VERSION", source)

    def test_complete_mask_keeps_hat_ears_and_jaw_but_hands_neck_to_body(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        with tempfile.TemporaryDirectory() as directory:
            destination = os.path.join(directory, "head-mask.png")
            mode = body._stylized_head_mask(
                portrait, landmarks, destination)
            mask = cv2.imread(destination, cv2.IMREAD_UNCHANGED)[:, :, 3]
        self.assertEqual("full-silhouette", mode)
        self.assertGreater(int(mask[20, 90]), 250)   # hat
        self.assertGreater(int(mask[85, 44]), 250)   # left ear
        self.assertGreater(int(mask[126, 90]), 250)  # complete jaw
        self.assertGreater(int(mask[129, 90]), 64)   # short under-jaw feather
        self.assertLess(int(mask[129, 90]), 250)
        self.assertEqual(0, int(mask[132, 90]))      # body owns the neck
        self.assertEqual(0, int(mask[178, 90]))      # source bust/clothing

    def test_body_clear_expands_only_in_face_band_and_preserves_hat_and_neck(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.zeros((220, 180, 4), np.uint8)
        donor = (20, 30, 190, 255)
        cv2.ellipse(body_rgba, (90, 34), (70, 24), 0, 0, 360, donor, -1)
        cv2.ellipse(body_rgba, (90, 84), (50, 46), 0, 0, 360, donor, -1)
        cv2.rectangle(body_rgba, (34, 76), (42, 94), donor, -1)
        cv2.rectangle(body_rgba, (138, 76), (146, 94), donor, -1)
        cv2.rectangle(body_rgba, (70, 124), (110, 170), donor, -1)
        cv2.rectangle(body_rgba, (25, 165), (155, 219), donor, -1)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            preview_path = os.path.join(directory, "preview.png")
            body_path = os.path.join(directory, "body.png")
            body._stylized_head_mask(portrait, landmarks, mask_path)
            cv2.imwrite(body_path, body_rgba)
            receipt = body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [52, 43, 76, 84], clear_path)
            clear = cv2.imread(clear_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            body._runtime_composite_preview(
                body_path, portrait[:, :, :3], mask_path, transform,
                preview_path, replace=True, clear_mask_path=clear_path)
            preview = cv2.imread(preview_path, cv2.IMREAD_UNCHANGED)

        # The donor ear extends two pixels beyond the canonical ear.  The
        # face-band expansion clears it, so no second ear survives.
        self.assertEqual(0, int(mask[85, 38]))
        self.assertEqual(255, int(clear[85, 38]))
        self.assertEqual(0, int(preview[85, 38, 3]))
        # Away from the facial anatomy band there is no expansion: hat and
        # deep-neck clear geometry exactly matches canonical support.
        self.assertTrue(np.array_equal(clear[20], (mask[20] > 4) * 255))
        self.assertTrue(np.array_equal(clear[150], np.zeros(180, np.uint8)))
        # The body-space eraser stops at the canonical jaw.  It must not erase
        # the donor beneath the soft under-jaw handoff, or the feather would
        # reveal transparent background instead of the continuous body neck.
        self.assertEqual(0, int(clear[129, 90]))
        self.assertEqual(255, int(preview[20, 90, 3]))
        self.assertEqual(255, int(preview[129, 90, 3]))
        self.assertEqual(255, int(preview[133, 90, 3]))
        self.assertGreater(receipt["anatomy_pixels"], 0)

    def test_body_clear_removes_larger_shifted_donor_hat(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.zeros((220, 180, 4), np.uint8)
        donor = (20, 30, 190, 255)
        # The donor crown and brim extend beyond the canonical portrait—the
        # real 3D Luffy mismatch that previously rendered as a double hat.
        cv2.ellipse(body_rgba, (90, 28), (82, 31), 0, 0, 360, donor, -1)
        cv2.ellipse(body_rgba, (90, 84), (50, 46), 0, 0, 360, donor, -1)
        cv2.rectangle(body_rgba, (70, 124), (110, 170), donor, -1)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            preview_path = os.path.join(directory, "preview.png")
            body_path = os.path.join(directory, "body.png")
            body._stylized_head_mask(portrait, landmarks, mask_path)
            cv2.imwrite(body_path, body_rgba)
            receipt = body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [52, 43, 76, 84], clear_path)
            clear = cv2.imread(clear_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            body._runtime_composite_preview(
                body_path, portrait[:, :, :3], mask_path, transform,
                preview_path, replace=True, clear_mask_path=clear_path)
            preview = cv2.imread(preview_path, cv2.IMREAD_UNCHANGED)

        self.assertEqual(0, int(mask[8, 90]))
        self.assertEqual(255, int(clear[8, 90]))
        self.assertEqual(0, int(preview[8, 90, 3]))
        self.assertEqual(255, int(preview[20, 90, 3]))
        self.assertGreater(receipt["silhouette_pixels"], 0)
        # The expansion remains clipped above the chin and never erases neck.
        self.assertEqual(0, int(clear[150, 90]))

    def test_photographic_preview_retains_legacy_soft_blend_exactly(self):
        body_rgba = np.zeros((12, 12, 4), np.uint8)
        body_rgba[:, :, :3] = (10, 40, 200)
        body_rgba[:, :, 3] = 255
        keyframe = np.full((12, 12, 3), (160, 120, 20), np.uint8)
        mask = np.full((12, 12, 4), 255, np.uint8)
        mask[:, :, 3] = 128
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)
        with tempfile.TemporaryDirectory() as directory:
            body_path = os.path.join(directory, "body.png")
            mask_path = os.path.join(directory, "head-mask.png")
            preview_path = os.path.join(directory, "preview.png")
            cv2.imwrite(body_path, body_rgba)
            cv2.imwrite(mask_path, mask)
            body._runtime_composite_preview(
                body_path, keyframe, mask_path, transform, preview_path)
            preview = cv2.imread(preview_path, cv2.IMREAD_UNCHANGED)
        alpha = 128.0 / 255.0
        expected = np.round(
            keyframe[0, 0].astype(np.float32) * alpha
            + body_rgba[0, 0, :3].astype(np.float32) * (1.0 - alpha)
        ).astype(np.uint8)
        self.assertTrue(np.array_equal(expected, preview[0, 0, :3]))
        self.assertEqual(255, int(preview[0, 0, 3]))


if __name__ == "__main__":
    unittest.main()
