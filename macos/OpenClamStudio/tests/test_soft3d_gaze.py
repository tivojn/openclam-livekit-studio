"""Soft-3D-only rigid iris policy and source-owned lower eyelid regressions."""
from contextlib import ExitStack
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import expression, rigid_gaze, soft3d_gaze
from studio.blink import LOWER, UPPER, _line


def shaded_eye_fixture(scale=1, iris_aspect=1):
    """Large green authored iris; the human lower-lid estimate is 3px too high.

    The black pupil/glint and fixed brown lower lash reproduce the ownership
    error without embedding any user's portrait in the repository.
    """
    size = int(1024 * scale)
    image = np.full((size, size, 3), (86, 144, 212), np.uint8)
    lm = np.full((478, 2), size / 2, np.float32)
    yy, xx = np.mgrid[:size, :size].astype(np.float32)
    true_lowers = {}
    for side, cx in (("r", 400), ("l", 625)):
        cy = 420
        xs = np.linspace(cx - 56, cx + 56, 9)
        curvature = np.sqrt(np.maximum(0, 1 - ((xs - cx) / 56) ** 2))
        upper = np.column_stack([xs, cy - 27 * curvature]) * scale
        lower = np.column_stack([xs, cy + 28 * curvature]) * scale
        lm[UPPER[side]] = upper
        lm[LOWER[side]] = lower - np.column_stack([np.zeros(9), 3 * curvature * scale])
        true_lowers[side] = lower
        centre = np.array([cx, cy - 1]) * scale
        lm[soft3d_gaze.IRIS[side]] = [cx * scale, (cy + 2) * scale]
        lm[soft3d_gaze.IRIS_RING[side]] = lm[soft3d_gaze.IRIS[side]] + scale * np.array(
            [[22, 0], [0, -22], [-22, 0], [0, 22]])
        mask = np.zeros(image.shape[:2], np.uint8)
        cv2.fillPoly(mask, [np.rint(np.vstack([upper, lower[::-1]])).astype(np.int32)], 255)
        gray = np.clip(222 + (xx - centre[0]) / (12 * scale), 206, 238).astype(np.uint8)
        paint = np.repeat(gray[..., None], 3, axis=2)
        radius = 30 * scale
        norm = np.hypot((xx - centre[0]) / iris_aspect, yy - centre[1])
        iris = norm <= radius
        paint[iris] = (31, 70, 50)
        paint[norm < radius - 2 * scale] = (55, 132, 94)
        cv2.circle(paint, tuple(centre.astype(int)), int(10 * scale), (3, 4, 4), -1)
        cv2.circle(paint, tuple((centre + np.array([8, -10]) * scale).astype(int)),
                   max(1, int(3 * scale)), (248, 249, 250), -1)
        # An off-centre colored spoke must move rather than deform.
        cv2.line(paint, tuple((centre + np.array([-17, 9]) * scale).astype(int)),
                 tuple((centre + np.array([-13, 18]) * scale).astype(int)),
                 (78, 155, 110), max(1, int(scale)))
        image[mask > 0] = paint[mask > 0]
        cv2.polylines(image, [np.rint(upper - [0, scale]).astype(np.int32)],
                      False, (5, 7, 10), max(1, int(2 * scale)))
        cv2.polylines(image, [np.rint(lower + [0, scale]).astype(np.int32)],
                      False, (24, 44, 72), max(1, int(scale)))
        cv2.polylines(image, [np.rint(upper - [0, 7 * scale]).astype(np.int32)],
                      False, (1, 1, 1), max(1, int(4 * scale)))
    return image, lm, tuple(int(v * scale) for v in (338, 382, 124, 80)), true_lowers


def over(base, patch):
    alpha = patch[..., 3:4].astype(np.float32) / 255
    return np.rint(base * (1 - alpha) + patch[..., :3] * alpha).astype(np.uint8)


def tissue_stubs():
    stack = ExitStack()
    mask = np.zeros((1024, 1024), np.float32)
    mask[380:458, 340:685] = 1
    dummy = np.zeros((1, 1, 4), np.uint8)
    for name in ("_brow_alpha", "_forehead_weight", "_eyebag_weight"):
        stack.enter_context(mock.patch.object(expression, name, return_value=mask))
    stack.enter_context(mock.patch.object(expression, "_cheek_weight", return_value=(mask, mask)))
    for name in ("brow_state", "forehead_state", "cheek_state"):
        stack.enter_context(mock.patch.object(expression, name, return_value=dummy))
    return stack


class Soft3DGazeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.box, cls.true_lowers = shaded_eye_fixture()
        cls.prepared = soft3d_gaze.prepare(cls.image, cls.lm, "r", cls.box)

    def test_measures_authored_iris_not_smaller_human_estimate(self):
        p = self.prepared
        self.assertGreater(min(p.ellipse[1]), 57)
        self.assertLess(max(p.ellipse[1]), 63)
        self.assertGreater(p.evidence["source_lower_border_columns"], 40)
        self.assertEqual(p.metadata()["mode"], soft3d_gaze.MODE)

    def test_neutral_exact_inputs_unchanged(self):
        image, lm, box, _ = shaded_eye_fixture()
        original, landmarks = image.copy(), lm.copy()
        p = soft3d_gaze.prepare(image, lm, "r", box)
        patch = soft3d_gaze.state(p, 0, 0)
        np.testing.assert_array_equal(patch[..., :3], p.base)
        self.assertFalse(patch[..., 3].any())
        np.testing.assert_array_equal(image, original)
        np.testing.assert_array_equal(lm, landmarks)

    def test_lower_iris_below_wrong_landmark_is_fully_owned(self):
        p = self.prepared
        x, y, width, _ = p.box
        lower = _line(self.lm[LOWER["r"]], np.arange(x, x + width)) - y
        green = ((p.base[..., 1].astype(float) - p.base[..., 2]) > 14)
        below = p.grid_y > lower
        target = green & below & (p.iris_alpha > .999)
        self.assertGreater(int(target.sum()), 30)
        self.assertTrue(np.all(p.aperture[target] > .99))
        # Moving away must erase the old lower green paint, not just its pupil.
        dx, dy = -9, -3
        patch = soft3d_gaze.state(p, dx, dy)
        moved_matte = cv2.remap(p.iris_alpha, p.grid_x - dx, p.grid_y - dy,
                               cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        vacated = target & (moved_matte == 0)
        self.assertGreater(int(vacated.sum()), 8)
        rendered = over(p.base, patch)
        self.assertGreater(float(rendered[vacated].min()), 150)

    def test_true_lower_lash_skin_and_upper_glasses_do_not_move(self):
        p = self.prepared
        x, y, width, _ = p.box
        lower = _line(self.true_lowers["r"], np.arange(x, x + width)) - y
        upper = _line(self.lm[UPPER["r"]], np.arange(x, x + width)) - y
        protected = (p.grid_y >= lower + 1) | (p.grid_y <= upper - 1)
        self.assertFalse(p.aperture[protected].any())
        for dx, dy in ((-9, 0), (9, 0), (0, -3.5), (0, 3.5), (-9, -3.5), (9, 3.5)):
            np.testing.assert_array_equal(over(p.base, soft3d_gaze.state(p, dx, dy))[protected],
                                          p.base[protected])

    def test_one_rigid_translation_preserves_pupil_glint_texture(self):
        p = self.prepared
        for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, -3), (9, 3)):
            patch = soft3d_gaze.state(p, dx, dy)
            yy, xx = np.where((p.aperture == 1) & (p.iris_alpha == 1))
            tx, ty = xx + dx, yy + dy
            valid = (tx >= 0) & (tx < p.box[2]) & (ty >= 0) & (ty < p.box[3])
            xx, yy, tx, ty = xx[valid], yy[valid], tx[valid], ty[valid]
            valid = p.aperture[ty, tx] == 1
            with self.subTest(dx=dx, dy=dy):
                self.assertGreater(int(valid.sum()), 1600)
                np.testing.assert_array_equal(patch[ty[valid], tx[valid], :3],
                                              p.base[yy[valid], xx[valid]])

    def test_pupil_and_catchlight_components_keep_area_and_centroid(self):
        p = self.prepared

        def components(rgb, glint):
            pixels = (rgb.min(axis=2) > 245) if glint else (rgb.max(axis=2) < 6)
            pixels &= p.aperture == 1
            count, _, stats, centres = cv2.connectedComponentsWithStats(pixels.astype(np.uint8))
            ids = [i for i in range(1, count) if stats[i, cv2.CC_STAT_AREA] > 4]
            self.assertEqual(len(ids), 1)
            return stats[ids[0], cv2.CC_STAT_AREA], centres[ids[0]]

        for glint in (False, True):
            area, centre = components(p.base, glint)
            for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, 3), (9, -3)):
                actual_area, actual_centre = components(over(p.base, soft3d_gaze.state(p, dx, dy)), glint)
                self.assertEqual(area, actual_area)
                np.testing.assert_allclose(actual_centre, centre + [dx, dy], atol=.01)

    def test_fixed_ownership_all_directions_and_no_per_tile_preparation(self):
        p = self.prepared
        ownership = (p.aperture > 0).astype(np.uint8) * 255
        with mock.patch.object(soft3d_gaze, "_measure_ellipse", side_effect=AssertionError("fit per tile")), \
                mock.patch.object(soft3d_gaze, "_sclera", side_effect=AssertionError("fill per tile")), \
                mock.patch.object(soft3d_gaze, "_source_lower_aperture", side_effect=AssertionError("source scan per tile")):
            for dy in expression.GAZE_DY:
                for dx in expression.GAZE_DX:
                    patch = soft3d_gaze.state(p, dx, dy)
                    np.testing.assert_array_equal(patch[..., 3], ownership if dx or dy else 0)
                    self.assertTrue(np.isfinite(patch).all())

    def test_anatomical_travel_clamps_without_squeezing_iris(self):
        p = self.prepared
        for dx, dy in ((1e6, 1e6), (-1e6, -1e6)):
            clipped = np.clip([dx, dy], -np.asarray(p.limits), p.limits)
            np.testing.assert_array_equal(soft3d_gaze.state(p, dx, dy),
                                          soft3d_gaze.state(p, *clipped))
        self.assertLess(p.limits[0], min(p.ellipse[1]) * .5)
        self.assertLess(p.limits[1], p.limits[0])

    def test_unknown_colors_do_not_trigger_blind_lower_mask_expansion(self):
        p = self.prepared
        grayscale = cv2.cvtColor(cv2.cvtColor(p.base, cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR)
        geometric = soft3d_gaze._aperture(self.lm, "r", self.box, 1)
        refined, columns = soft3d_gaze._source_lower_aperture(
            grayscale, self.lm, "r", self.box, 1, geometric, p.ellipse)
        np.testing.assert_array_equal(refined, geometric)
        self.assertEqual(columns, 0)

    def test_nonround_and_unmeasurable_eyes_are_not_forced_into_circle(self):
        image, lm, box, _ = shaded_eye_fixture(iris_aspect=1.65)
        with self.assertRaises(soft3d_gaze.UnsupportedSoft3DIris):
            soft3d_gaze.prepare(image, lm, "r", box)
        flat = np.full_like(self.image, 160)
        with self.assertRaises(soft3d_gaze.UnsupportedSoft3DIris):
            soft3d_gaze.prepare(flat, self.lm, "r", self.box)

    def test_small_scale_and_invalid_values(self):
        image, lm, box, _ = shaded_eye_fixture(.5)
        p = soft3d_gaze.prepare(image, lm, "r", box)
        self.assertTrue(np.isfinite(soft3d_gaze.state(p, 4.5, 1.75)).all())
        for dx, dy in ((np.nan, 0), (0, np.inf)):
            with self.assertRaises(ValueError):
                soft3d_gaze.state(p, dx, dy)
        with self.assertRaises(ValueError):
            soft3d_gaze.prepare(self.image, self.lm, "r", (-1, 0, 124, 80))


class ExplicitSoft3DRoutingTests(unittest.TestCase):
    def test_selected_3d_prepares_each_eye_once_never_uses_photographic_policy(self):
        image, lm, _, _ = shaded_eye_fixture()
        with tissue_stubs(), \
                mock.patch.object(rigid_gaze, "prepare", side_effect=AssertionError("3D relabeled photo")), \
                mock.patch.object(soft3d_gaze, "prepare", wraps=soft3d_gaze.prepare) as prepare:
            result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                      source_medium="3d render", log=lambda *_: None)
        self.assertEqual(prepare.call_count, 2)
        self.assertEqual(result["gaze"]["mode"], soft3d_gaze.MODE)
        self.assertEqual(set(result["gaze"]["geometry"]), {"r", "l"})

    def test_unsupported_3d_uses_explicit_safe_neutral_both_eyes_not_legacy_warp(self):
        image, lm, box, _ = shaded_eye_fixture()
        good = soft3d_gaze.prepare(image, lm, "r", box)
        with tissue_stubs(), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=[good, soft3d_gaze.UnsupportedSoft3DIris("test irregular iris")]), \
                mock.patch.object(expression, "gaze_state", side_effect=AssertionError("unsafe warp fallback")):
            result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[-3.5, 0, 3.5],
                                      source_medium="3d render", log=lambda *_: None)
        self.assertEqual(result["gaze"]["mode"], soft3d_gaze.NEUTRAL_MODE)
        self.assertIn("irregular iris", result["gaze"]["geometry"]["fallback_reason"])
        for side in ("r", "l"):
            x, y, width, height = result["gaze"][side]["box"]
            for patch in result["gaze"][side]["patches"]:
                self.assertFalse(patch[..., 3].any())
                np.testing.assert_array_equal(patch[..., :3], image[y:y + height, x:x + width])

    def test_2d_unknown_and_photo_never_enter_soft3d_helper(self):
        image, lm, _, _ = shaded_eye_fixture()
        with tissue_stubs(), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=AssertionError("wrong art policy")):
            for medium in ("illustration", "unknown", "photograph"):
                with self.subTest(medium=medium):
                    expression.build(image, lm, dxs=[0], dys=[0],
                                     source_medium=medium, log=lambda *_: None)


if __name__ == "__main__":
    unittest.main()
