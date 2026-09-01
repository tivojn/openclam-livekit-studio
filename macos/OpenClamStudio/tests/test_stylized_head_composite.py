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
        self.assertEqual(4, body.STYLIZED_HEAD_HANDOFF_VERSION)
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
        self.assertGreater(int(mask[129, 90]), 192)  # signed-distance feather
        self.assertLess(int(mask[129, 90]), 250)
        self.assertGreater(int(mask[132, 90]), 64)
        self.assertLess(int(mask[132, 90]), 192)
        self.assertEqual(0, int(mask[137, 90]))      # body owns the neck
        self.assertEqual(0, int(mask[178, 90]))      # source bust/clothing

    def test_soft_3d_handoff_keeps_hair_but_hands_central_neck_to_body(self):
        """Soft 3-D keeps lateral hair while the generated body owns the neck."""
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.full((220, 180, 4), (190, 30, 20, 255), np.uint8)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

        with tempfile.TemporaryDirectory() as directory:
            illustration_mask_path = os.path.join(
                directory, "illustration-mask.png")
            soft_3d_mask_path = os.path.join(directory, "soft-3d-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            body_path = os.path.join(directory, "body.png")
            preview_path = os.path.join(directory, "preview.png")
            body._stylized_head_mask(
                portrait, landmarks, illustration_mask_path,
                transform=transform, source_medium="illustration")
            body._stylized_head_mask(
                portrait, landmarks, soft_3d_mask_path,
                transform=transform, source_medium="3d render")
            receipt = body._stylized_head_clear_mask(
                body_rgba, soft_3d_mask_path, transform, landmarks,
                [52, 43, 76, 84], clear_path,
                source_medium="3d render")
            cv2.imwrite(body_path, body_rgba)
            body._runtime_composite_preview(
                body_path, portrait[:, :, :3], soft_3d_mask_path, transform,
                preview_path, replace=True, clear_mask_path=clear_path)
            illustration_mask = cv2.imread(
                illustration_mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            soft_3d_mask = cv2.imread(
                soft_3d_mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            preview = cv2.imread(preview_path, cv2.IMREAD_UNCHANGED)

        # Hat, ears and the complete anatomical jaw retain the same authority.
        for y, x in ((20, 90), (85, 44), (126, 90)):
            self.assertEqual(
                int(illustration_mask[y, x]), int(soft_3d_mask[y, x]))
            self.assertGreater(int(soft_3d_mask[y, x]), 250)
        # The source portrait deliberately contains a narrow long neck.  It
        # must not override the wider generated-body neck below the jaw: doing
        # so creates a visible width step when the portrait layer fades out.
        self.assertGreater(int(illustration_mask[133, 90]), 64)
        self.assertEqual(0, int(soft_3d_mask[133, 90]))
        self.assertTrue(np.array_equal(
            body_rgba[133, 90], preview[133, 90]))
        # The source bust/clothing remains excluded below the handoff too.
        self.assertLess(int(soft_3d_mask[150, 90]), 8)
        self.assertEqual(0, int(soft_3d_mask[151, 90]))
        self.assertTrue(np.array_equal(
            body_rgba[151, 90], preview[151, 90]))
        self.assertEqual("soft-3d-jaw-v1", receipt["handoff_profile"])
        self.assertEqual("3d render", receipt["source_medium"])
        self.assertGreaterEqual(receipt["handoff_feather_px"], 6.0)
        self.assertLessEqual(receipt["handoff_feather_px"], 12.0)

    def test_soft_3d_long_hair_does_not_collapse_at_the_ear_handoff(self):
        portrait = np.zeros((200, 180, 4), np.uint8)
        color = (35, 80, 120, 255)
        cv2.ellipse(portrait, (90, 82), (44, 47), 0, 0, 360, color, -1)
        # Source-supported long hair continues well below both ears.
        cv2.rectangle(portrait, (30, 35), (54, 165), color, -1)
        cv2.rectangle(portrait, (126, 35), (150, 165), color, -1)
        cv2.rectangle(portrait, (75, 124), (105, 154), color, -1)
        landmarks = _oval_landmarks()
        body_rgba = np.full((220, 180, 4), (190, 30, 20, 255), np.uint8)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            body._stylized_head_mask(
                portrait, landmarks, mask_path, transform=transform,
                source_medium="3d render")
            receipt = body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [52, 43, 76, 84], clear_path,
                source_medium="3d render")
            mask = cv2.imread(
                mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            clear = cv2.imread(
                clear_path, cv2.IMREAD_UNCHANGED)[:, :, 3]

        # Both lateral hair lobes remain continuous below the facial jaw; the
        # previous jaw-only field cut both columns to zero near eye/ear level.
        for x in (42, 138):
            self.assertGreater(int(mask[135, x]), 240)
            self.assertGreater(int(mask[145, x]), 128)
            self.assertGreater(int(clear[135, x]), 240)
        self.assertEqual(
            "erasure-only-short-hair-taper",
            receipt["hair_bridge"]["method"])
        self.assertFalse(receipt["hair_bridge"]["applied"])

    def test_illustration_handoff_retains_existing_luffy_safe_overlap(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.full((220, 180, 4), 255, np.uint8)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)
        with tempfile.TemporaryDirectory() as directory:
            default_path = os.path.join(directory, "default.png")
            illustration_path = os.path.join(directory, "illustration.png")
            clear_path = os.path.join(directory, "clear.png")
            body._stylized_head_mask(
                portrait, landmarks, default_path, transform=transform)
            body._stylized_head_mask(
                portrait, landmarks, illustration_path, transform=transform,
                source_medium="illustration")
            receipt = body._stylized_head_clear_mask(
                body_rgba, illustration_path, transform, landmarks,
                [52, 43, 76, 84], clear_path,
                source_medium="illustration")
            default_mask = cv2.imread(
                default_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            illustration_mask = cv2.imread(
                illustration_path, cv2.IMREAD_UNCHANGED)[:, :, 3]

        self.assertTrue(np.array_equal(default_mask, illustration_mask))
        self.assertEqual("illustration-jaw-v2", receipt["handoff_profile"])
        self.assertEqual("illustration", receipt["source_medium"])
        self.assertGreaterEqual(receipt["handoff_feather_px"], 10.0)
        self.assertLessEqual(receipt["handoff_feather_px"], 16.0)

    def test_shared_curved_jaw_avoids_a_long_horizontal_collar_edge(self):
        head_source = inspect.getsource(body._stylized_head_mask)
        clear_source = inspect.getsource(body._stylized_head_clear_mask)
        self.assertIn("_stylized_jaw_handoff", head_source)
        self.assertIn("_stylized_jaw_handoff", clear_source)
        self.assertNotIn("chin_stop", clear_source)

        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.full((220, 180, 4), 255, np.uint8)
        transform = np.array(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)
        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            body._stylized_head_mask(portrait, landmarks, mask_path)
            receipt = body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [52, 43, 76, 84], clear_path)
            mask = cv2.imread(
                mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
            clear = cv2.imread(
                clear_path, cv2.IMREAD_UNCHANGED)[:, :, 3]

        vertical_edge = np.abs(
            clear[1:].astype(np.int16) - clear[:-1].astype(np.int16)) > 200

        def longest_run(row):
            padded = np.pad(row.astype(np.int8), (1, 1))
            changes = np.diff(padded)
            starts = np.flatnonzero(changes == 1)
            ends = np.flatnonzero(changes == -1)
            return int(np.max(ends - starts)) if len(starts) else 0

        longest_horizontal_edge = max(
            longest_run(row) for row in vertical_edge)
        projected_width = float(np.ptp(
            landmarks[body.face.FACE_OVAL, 0]))
        self.assertLess(
            longest_horizontal_edge, int(round(projected_width * 0.20)))
        self.assertGreater(
            receipt["jaw_boundary_row_range"][1]
            - receipt["jaw_boundary_row_range"][0],
            20)
        self.assertGreaterEqual(receipt["handoff_feather_px"], 10.0)
        self.assertLessEqual(receipt["handoff_feather_px"], 16.0)
        overlay_feather = (mask > 4) & (mask < 250)
        self.assertGreater(int(np.sum(overlay_feather)), 0)
        self.assertTrue(np.all(
            clear[:mask.shape[0]][overlay_feather] == 0))

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
        self.assertEqual(
            [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            receipt["face_transform"])

    def test_wide_body_plate_never_treats_shoulders_as_extrapolated_jaw(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.zeros((360, 800, 4), np.uint8)
        donor = (20, 30, 190, 255)
        cv2.ellipse(body_rgba, (400, 84), (50, 46), 0, 0, 360, donor, -1)
        cv2.rectangle(body_rgba, (80, 150), (720, 359), donor, -1)
        transform = np.array(
            [[1.0, 0.0, 310.0], [0.0, 1.0, 0.0]], np.float32)

        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            clear_path = os.path.join(directory, "head-clear-mask.png")
            body._stylized_head_mask(
                portrait, landmarks, mask_path, transform=transform)
            receipt = body._stylized_head_clear_mask(
                body_rgba, mask_path, transform, landmarks,
                [362, 43, 76, 84], clear_path)
            clear = cv2.imread(
                clear_path, cv2.IMREAD_UNCHANGED)[:, :, 3]

        # The previous unbounded diagonal reached below row 300 at the image
        # edges and erased these perfectly valid shoulders/torso pixels.
        self.assertEqual(0, int(clear[170, 100]))
        self.assertEqual(0, int(clear[170, 700]))
        self.assertLessEqual(receipt["jaw_boundary_row_range"][1], 130)

    def test_jaw_handoff_keeps_body_under_antialiased_stylized_edge(self):
        portrait = _stylized_portrait()
        landmarks = _oval_landmarks()
        body_rgba = np.zeros((220, 180, 4), np.uint8)
        donor = (20, 30, 190, 255)
        cv2.ellipse(body_rgba, (90, 84), (50, 46), 0, 0, 360, donor, -1)
        # The donor neck is deliberately wider than the canonical under-jaw
        # feather.  This reproduces the two/five-pixel Luffy gap when a binary
        # clear mask erased the backing body beyond the overlay's edge.
        cv2.rectangle(body_rgba, (68, 118), (112, 170), donor, -1)
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

        handoff_start, handoff_end = receipt["handoff_row_range"]
        self.assertLessEqual(handoff_start, 124)
        self.assertGreaterEqual(handoff_end, 126)
        self.assertGreater(receipt["handoff_pixels_preserved"], 0)
        # Outside the canonical mask but still inside the donor neck, the body
        # must remain fully opaque across the final jaw rows.
        self.assertEqual(0, int(mask[126, 70]))
        self.assertLessEqual(int(clear[126, 70]), 4)
        self.assertEqual(255, int(preview[126, 70, 3]))
        self.assertEqual(255, int(preview[126, 110, 3]))

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
        self.assertNotIn(
            "_stylized_jaw_handoff", inspect.getsource(body._head_mask))
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
