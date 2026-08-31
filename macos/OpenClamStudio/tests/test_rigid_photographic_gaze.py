"""Pixel-level gaze tests: rigid iris, fixed lids, explicit medium policy."""
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import expression, rigid_gaze
from studio.blink import LOWER, UPPER


def eye_fixture(scale=1):
    """Authored eyes with a textured iris, pupil, catchlight and fixed glasses."""
    size = int(1024 * scale)
    image = np.full((size, size, 3), (90, 145, 193), np.uint8)
    lm = np.full((478, 2), (size / 2, size / 2), np.float32)
    for side, cx in (("r", 400), ("l", 625)):
        cy, radius = 420, 19
        xs = np.linspace(cx - 55, cx + 55, 9)
        curvature = np.sqrt(np.maximum(0, 1 - ((xs - cx) / 55) ** 2))
        upper = np.column_stack([xs, cy - 25 * curvature]) * scale
        lower = np.column_stack([xs, cy + 25 * curvature]) * scale
        lm[UPPER[side]] = upper
        lm[LOWER[side]] = lower
        centre = np.array([cx, cy]) * scale
        lm[rigid_gaze.IRIS[side]] = centre
        lm[rigid_gaze.IRIS_RING[side]] = centre + scale * np.array(
            [[radius, 0], [0, -radius], [-radius, 0], [0, radius]])
        polygon = np.rint(np.vstack([upper, lower[::-1]])).astype(np.int32)
        mask = np.zeros(image.shape[:2], np.uint8)
        cv2.fillPoly(mask, [polygon], 255)
        yy, xx = np.mgrid[:size, :size]
        # A non-uniform sclera exercises the fill without ever sampling skin.
        gray = np.clip(225 + (xx - centre[0]) / (11 * scale), 205, 235).astype(np.uint8)
        image[mask > 0] = np.repeat(gray[..., None], 3, axis=2)[mask > 0]
        cv2.circle(image, tuple(centre.astype(int)), int(radius * scale), (115, 83, 32), -1)
        cv2.circle(image, tuple(centre.astype(int)), int((radius - 2) * scale), (159, 116, 45), -1)
        # Fine asymmetric detail is a stronger invariant than a plain disc.
        cv2.line(image, tuple((centre + [-13, -1] * np.array(scale)).astype(int)),
                 tuple((centre + [-9, 8] * np.array(scale)).astype(int)),
                 (185, 131, 50), max(1, int(scale)))
        cv2.circle(image, tuple(centre.astype(int)), int(6 * scale), (3, 4, 5), -1)
        cv2.circle(image, tuple((centre + [2, -3] * np.array(scale)).astype(int)),
                   max(1, int(scale)), (251, 251, 251), -1)
        for line in (upper - [0, scale], lower + [0, scale]):
            cv2.polylines(image, [np.rint(line).astype(np.int32)], False, (8, 11, 13),
                          max(1, int(2 * scale)))
        # Frame and external eyelash strokes cannot be pulled into the eye.
        cv2.polylines(image, [np.rint(upper - [0, 7 * scale]).astype(np.int32)],
                      False, (0, 0, 0), max(1, int(4 * scale)))
    box = tuple(int(v * scale) for v in (338, 384, 124, 72))
    return image, lm, box


def over(base, patch):
    alpha = patch[..., 3:4].astype(np.float32) / 255
    return np.rint(base * (1 - alpha) + patch[..., :3] * alpha).astype(np.uint8)


class RigidPhotographicGazeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.box = eye_fixture()
        cls.prepared = rigid_gaze.prepare(cls.image, cls.lm, "r", cls.box)

    def test_neutral_is_exact_and_input_is_not_mutated(self):
        image, lm, box = eye_fixture()
        original, landmarks = image.copy(), lm.copy()
        prepared = rigid_gaze.prepare(image, lm, "r", box)
        patch = rigid_gaze.state(prepared, 0, 0)
        np.testing.assert_array_equal(patch[..., :3], prepared.base)
        self.assertFalse(patch[..., 3].any())
        np.testing.assert_array_equal(over(prepared.base, patch), prepared.base)
        np.testing.assert_array_equal(image, original)
        np.testing.assert_array_equal(lm, landmarks)

    def test_alpha_is_fixed_lid_aperture_for_all_extremes_and_diagonals(self):
        p = self.prepared
        expected = np.rint(p.aperture * 255).astype(np.uint8)
        for dx, dy in ((-9, 0), (9, 0), (0, -3.5), (0, 3.5),
                       (-9, -3.5), (9, -3.5), (-9, 3.5), (9, 3.5)):
            with self.subTest(dx=dx, dy=dy):
                patch = rigid_gaze.state(p, dx, dy)
                np.testing.assert_array_equal(patch[..., 3], expected)
                rendered = over(p.base, patch)
                np.testing.assert_array_equal(rendered[expected == 0], p.base[expected == 0])

    def test_observed_iris_texture_has_one_constant_translation(self):
        p = self.prepared
        for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, 3), (9, -3)):
            patch = rigid_gaze.state(p, dx, dy)
            yy, xx = np.where((p.aperture > .999) & (p.disc > .999))
            tx, ty = xx + dx, yy + dy
            valid = (tx >= 0) & (tx < p.box[2]) & (ty >= 0) & (ty < p.box[3])
            xx, yy, tx, ty = xx[valid], yy[valid], tx[valid], ty[valid]
            valid = p.aperture[ty, tx] > .999
            with self.subTest(dx=dx, dy=dy):
                self.assertGreater(int(valid.sum()), 500)
                np.testing.assert_array_equal(patch[ty[valid], tx[valid], :3],
                                              p.base[yy[valid], xx[valid]])

    def test_pupil_area_and_centroid_move_without_shearing_or_double_pupil(self):
        p = self.prepared

        def pupil_stats(rgb):
            pupil = (rgb.max(axis=2) < 7) & (p.aperture > .999)
            count, labels, stats, centers = cv2.connectedComponentsWithStats(pupil.astype(np.uint8))
            components = [i for i in range(1, count) if stats[i, cv2.CC_STAT_AREA] > 4]
            self.assertEqual(len(components), 1)
            i = components[0]
            return stats[i, cv2.CC_STAT_AREA], centers[i]

        area, centre = pupil_stats(p.base)
        for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, -3), (9, 3)):
            with self.subTest(dx=dx, dy=dy):
                moved_area, moved_centre = pupil_stats(over(p.base, rigid_gaze.state(p, dx, dy)))
                self.assertEqual(moved_area, area)
                np.testing.assert_allclose(moved_centre, centre + [dx, dy], atol=.01)

    def test_old_pupil_does_not_remain_under_partial_alpha(self):
        p = self.prepared
        image = over(p.base, rigid_gaze.state(p, 16, 0))
        # The vacated pupil centre is still inside the stationary lid opening,
        # but outside the translated pupil. It must not retain its black dot.
        x, y = np.rint(self.lm[468] - self.box[:2]).astype(int)
        self.assertLess(int(p.base[y, x].max()), 20)
        self.assertGreater(int(image[y, x].max()), 90)

    def test_eyelid_occlusion_clips_disc_instead_of_squeezing_it(self):
        p = self.prepared
        patch = rigid_gaze.state(p, 0, 22)
        rendered = over(p.base, patch)
        source = (p.base.max(axis=2) < 7) & (p.aperture > .999)
        translated = np.zeros_like(source)
        translated[22:] = source[:-22]
        expected = translated & (patch[..., 3] == 255)
        actual = (rendered.max(axis=2) < 7) & (patch[..., 3] == 255)
        np.testing.assert_array_equal(actual, expected)
        self.assertGreater(int(actual.sum()), 0)
        self.assertLess(int(actual.sum()), int(source.sum()))

    def test_no_glasses_lash_or_face_pixels_change_outside_aperture(self):
        p = self.prepared
        x, y, w, h = self.box
        result = self.image.copy()
        result[y:y + h, x:x + w] = over(p.base, rigid_gaze.state(p, -9, -3.5))
        protected = np.ones(self.image.shape[:2], bool)
        protected[y:y + h, x:x + w] = p.aperture == 0
        np.testing.assert_array_equal(result[protected], self.image[protected])

    def test_all_observed_sclera_outside_vacated_iris_is_preserved(self):
        p = self.prepared
        distance = np.hypot(p.grid_x - p.centre[0], p.grid_y - p.centre[1])
        known = (p.aperture > .999) & (distance > p.radius + 2)
        np.testing.assert_array_equal(p.sclera[known], p.base[known])
        self.assertTrue(np.isfinite(p.sclera).all())
        # The reconstructed iris footprint cannot inherit the dark pupil.
        core = (p.aperture > .999) & (distance < p.radius * .7)
        self.assertGreater(float(p.sclera[core].min()), 190)

    def test_scale_and_no_contrast_fallback_are_finite(self):
        image, lm, box = eye_fixture(.5)
        p = rigid_gaze.prepare(image, lm, "r", box)
        self.assertTrue(np.isfinite(rigid_gaze.state(p, 4.5, 1.75)).all())
        self.assertTrue(np.isfinite(p.centre).all())
        flat = np.full_like(p.base, 200)
        centre, radius, refined = rigid_gaze._limbus_circle(
            flat, p.aperture, p.centre, p.radius, .5)
        np.testing.assert_array_equal(centre, p.centre)
        self.assertEqual(radius, p.radius)
        self.assertFalse(refined)

    def test_invalid_input_rejected_before_remap(self):
        for dx, dy in ((np.nan, 0), (0, np.inf), (1e9, 0)):
            with self.subTest(dx=dx, dy=dy), self.assertRaises(ValueError):
                rigid_gaze.state(self.prepared, dx, dy)
        invalid = self.lm.copy()
        invalid[468] = np.nan
        with self.assertRaises(ValueError):
            rigid_gaze.prepare(self.image, invalid, "r", self.box)
        with self.assertRaises(ValueError):
            rigid_gaze.prepare(self.image, self.lm, "r", (-1, 0, 50, 50))
        shut = self.lm.copy()
        shut[LOWER["r"]] = shut[UPPER["r"]]
        with self.assertRaisesRegex(ValueError, "visible, open"):
            rigid_gaze.prepare(self.image, shut, "r", self.box)

    def test_state_render_does_not_repeat_fitting_or_sclera_reconstruction(self):
        with mock.patch.object(rigid_gaze, "_limbus_circle", side_effect=AssertionError("fit per tile")), \
                mock.patch.object(rigid_gaze, "_sclera", side_effect=AssertionError("fill per tile")):
            for dy in expression.GAZE_DY:
                for dx in expression.GAZE_DX:
                    rigid_gaze.state(self.prepared, dx, dy)


class ExplicitGazeRoutingTests(unittest.TestCase):
    def test_only_explicit_photograph_uses_rigid_generator(self):
        # Execute the real build loop with only unrelated tissue bakers stubbed.
        # This checks actual routing/preparation count, not a source substring.
        image, lm, _box = eye_fixture()
        alpha = np.zeros(image.shape[:2], np.float32)
        alpha[390:448, 343:682] = 1
        dummy = np.zeros((1, 1, 4), np.uint8)
        with mock.patch.object(expression, "_brow_alpha", return_value=alpha), \
                mock.patch.object(expression, "_forehead_weight", return_value=alpha), \
                mock.patch.object(expression, "_cheek_weight", return_value=(alpha, alpha)), \
                mock.patch.object(expression, "_eyebag_weight", return_value=alpha), \
                mock.patch.object(expression, "brow_state", return_value=dummy), \
                mock.patch.object(expression, "forehead_state", return_value=dummy), \
                mock.patch.object(expression, "cheek_state", return_value=dummy):
            with mock.patch.object(rigid_gaze, "prepare", wraps=rigid_gaze.prepare) as prepare:
                photo = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                         source_medium="photograph", log=lambda *_: None)
                self.assertEqual(prepare.call_count, 2)
                self.assertEqual(photo["gaze"]["mode"], rigid_gaze.MODE)
            with mock.patch.object(rigid_gaze, "prepare", side_effect=AssertionError("photo route on cartoon")):
                baseline = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0], log=lambda *_: None)
                for medium in ("unknown", "game art"):
                    result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                              source_medium=medium, log=lambda *_: None)
                    self.assertNotIn("mode", result["gaze"])
                    for side in ("r", "l"):
                        for actual, expected in zip(result["gaze"][side]["patches"],
                                                    baseline["gaze"][side]["patches"]):
                            np.testing.assert_array_equal(actual, expected)
                        # Unknown media retain the same neutral source RGB.
                        x, y, w, h = result["gaze"][side]["box"]
                        np.testing.assert_array_equal(result["gaze"][side]["patches"][1][..., :3],
                                                      image[y:y + h, x:x + w])


if __name__ == "__main__":
    unittest.main()
