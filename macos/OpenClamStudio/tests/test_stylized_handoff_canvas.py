"""A cartoon head and its body eraser must share one geometric handoff."""
import os
import tempfile
import unittest

import cv2
import numpy as np

from studio import body


def _landmarks():
    landmarks = np.zeros((478, 2), np.float32)
    for index, landmark in enumerate(body.face.FACE_OVAL):
        angle = 2.0 * np.pi * index / len(body.face.FACE_OVAL)
        landmarks[landmark] = (
            90.0 + 38.0 * np.cos(angle),
            85.0 + 42.0 * np.sin(angle),
        )
    return landmarks


class StylizedHandoffCanvasTests(unittest.TestCase):
    def test_lateral_handoff_is_independent_of_portrait_or_body_canvas(self):
        oval = _landmarks()[body.face.FACE_OVAL]
        portrait_support, portrait_head, _ = body._stylized_jaw_handoff(
            (180, 180), oval, feather_px=10.0)
        translated = oval + np.array([310.0, 20.0], np.float32)
        body_support, body_head, _ = body._stylized_jaw_handoff(
            (400, 800), translated, feather_px=10.0)
        # A larger canvas may add empty background, never change whether the
        # same point on a loose forelock belongs to the canonical head.
        self.assertTrue(np.array_equal(
            portrait_head, body_head[20:200, 310:490]))
        np.testing.assert_allclose(
            portrait_support[12:-12, 12:-12],
            body_support[32:188, 322:478], atol=1e-6, rtol=0.0)

    def test_lateral_boundary_scales_with_face_not_canvas_padding(self):
        oval = _landmarks()[body.face.FACE_OVAL]
        _, small, _ = body._stylized_jaw_handoff(
            (180, 180), oval, feather_px=10.0)
        _, large, _ = body._stylized_jaw_handoff(
            (500, 1200), oval * 2.0 + [410.0, 30.0], feather_px=20.0)
        small_boundary = np.sum(small, axis=0) - 1
        large_boundary = np.sum(large, axis=0) - 1
        for x in range(10, 170):
            self.assertLessEqual(abs(
                int(large_boundary[410 + 2 * x])
                - (2 * int(small_boundary[x]) + 30)), 1)

    def test_body_eraser_never_slices_a_continuous_canonical_forelock(self):
        landmarks = _landmarks()
        portrait = np.zeros((180, 180, 4), np.uint8)
        ink = (22, 40, 80, 255)
        cv2.ellipse(portrait, (90, 84), (42, 45), 0, 0, 360, ink, -1)
        cv2.ellipse(portrait, (90, 35), (64, 24), 0, 0, 360, ink, -1)
        # A continuous thin side strand crosses the lateral handoff below
        # eye level, matching Celine's existing authored hair silhouette.
        cv2.rectangle(portrait, (14, 32), (21, 122), ink, -1)
        cv2.rectangle(portrait, (14, 32), (35, 50), ink, -1)
        cv2.rectangle(portrait, (75, 124), (105, 155), ink, -1)
        body_rgba = np.zeros((360, 800, 4), np.uint8)
        body_rgba[:180, 310:490] = portrait
        transform = np.array([[1, 0, 310], [0, 1, 0]], np.float64)
        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            body_path = os.path.join(directory, "body.png")
            preview_path = os.path.join(directory, "preview.png")
            body._stylized_head_mask(
                portrait, landmarks, mask_path, transform=transform,
                source_medium="illustration")
            body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [362, 43, 76, 84], clear_path,
                source_medium="illustration")
            cv2.imwrite(body_path, body_rgba)
            body._runtime_composite_preview(
                body_path, portrait[:, :, :3], mask_path, transform,
                preview_path, replace=True, clear_mask_path=clear_path)
            preview = cv2.imread(preview_path, cv2.IMREAD_UNCHANGED)
        self.assertTrue(np.all(preview[40:122, 324:332, 3] == 255))
        self.assertTrue(np.array_equal(
            preview[40:122, 324:332], body_rgba[40:122, 324:332]))


if __name__ == "__main__":
    unittest.main()
