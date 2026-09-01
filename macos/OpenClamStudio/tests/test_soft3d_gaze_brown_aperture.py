"""Source-owned brown 3D eyes, without embedding private portrait fixtures."""
import unittest

import cv2
import numpy as np

from studio import expression, soft3d_gaze
from studio.blink import LOWER, UPPER


def enclosed_brown_fixture(scale=1):
    size = int(1024 * scale)
    image = np.full((size, size, 3), (78, 145, 225), np.uint8)
    lm = np.full((478, 2), size / 2, np.float32)
    yy, xx = np.mgrid[:size, :size].astype(np.float32)
    eye_masks = {}
    for side, cx in (("r", 400), ("l", 625)):
        cy, radius = 420, 34
        xs = np.linspace(cx - 61, cx + 61, 9)
        curvature = np.sqrt(np.maximum(0, 1 - ((xs - cx) / 61) ** 2))
        lm[UPPER[side]] = np.column_stack([xs, cy - 27 * curvature]) * scale
        lm[LOWER[side]] = np.column_stack([xs, cy + 15 * curvature]) * scale
        lm[soft3d_gaze.IRIS[side]] = (cx * scale, cy * scale)
        lm[soft3d_gaze.IRIS_RING[side]] = lm[soft3d_gaze.IRIS[side]] + scale * np.array(
            [[24, 0], [0, -24], [-24, 0], [0, 24]])
        eye = ((xx / scale - cx) / 61) ** 2 + ((yy / scale - cy) / 50) ** 2 <= 1
        eye_masks[side] = eye
        dist = np.hypot(xx / scale - cx, yy / scale - cy)
        light = (xx / scale - cx) / 16 + 12 * np.exp(-((dist - radius - 3) / 12) ** 2)
        paint = np.clip(np.array((205, 222, 234)) + light[..., None], 0, 255).astype(np.uint8)
        paint[dist <= radius] = (4, 16, 37)
        paint[dist < radius - 2] = (12, 54, 111)
        paint[dist < 12] = (2, 3, 4)
        cv2.circle(paint, (int((cx - 9) * scale), int((cy - 12) * scale)),
                   max(1, int(3 * scale)), (248, 249, 250), -1)
        image[eye] = paint[eye]
        cv2.ellipse(image, (int(cx * scale), int(cy * scale)),
                    (int(62 * scale), int(51 * scale)), 0, 0, 360,
                    (9, 21, 39), max(1, int(scale)))
    return image, lm, eye_masks


def render(prepared, dx, dy):
    patch = soft3d_gaze.state(prepared, dx, dy)
    a = patch[..., 3:4].astype(np.float32) / 255
    return np.rint(prepared.base * (1 - a) + patch[..., :3] * a).astype(np.uint8)


def occluded_brown_fixture():
    """Brown iris intersects a fixed dark lower lash, like a shaded 3D eye."""
    image, lm, _ = enclosed_brown_fixture()
    image[:] = (78, 145, 225)
    yy, xx = np.mgrid[:1024, :1024].astype(np.float32)
    true_eyes = {}
    for side, cx in (("r", 400), ("l", 625)):
        normalized_x = (xx - cx) / 61
        upper = 420 - 30 * (1 - normalized_x ** 2)
        lower = 420 + 27 * (1 - normalized_x ** 2)
        eye = (yy > upper) & (yy < lower) & (abs(normalized_x) < 1)
        true_eyes[side] = eye
        distance = np.hypot(xx - cx, yy - 420)
        paint = np.empty_like(image)
        paint[:] = (205, 222, 234)
        paint[distance <= 34] = (4, 16, 37)
        paint[distance < 32] = (12, 54, 111)
        paint[distance < 12] = (2, 3, 4)
        cv2.circle(paint, (cx - 9, 408), 3, (248, 249, 250), -1)
        image[eye] = paint[eye]
        xs = np.arange(cx - 60, cx + 61)
        curve = 1 - ((xs - cx) / 61) ** 2
        for boundary in (420 - 30 * curve, 420 + 27 * curve):
            cv2.polylines(image, [np.rint(np.column_stack([xs, boundary])).astype(np.int32)],
                          False, (2, 6, 20), 1)
    return image, lm, true_eyes


class Brown3DSourceApertureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.eye_masks = enclosed_brown_fixture()
        cls.prepared = {}
        for side in ("r", "l"):
            box = expression._box(expression._eyeball_mask(cls.image.shape, cls.lm, side, 1), 7, cls.image.shape)
            cls.prepared[side] = soft3d_gaze.prepare(cls.image, cls.lm, side, box)

    def test_source_cavity_remeasures_complete_brown_limbus(self):
        for p in self.prepared.values():
            self.assertEqual(p.evidence.get("brown_aperture_method"), "source-enclosed-sclera")
            self.assertGreater(p.evidence["brown_iris_lower_undercoverage_pixels"], 100)
            self.assertIn("source_iris_refit", p.evidence)
            self.assertGreater(min(p.ellipse[1]), 64)
            self.assertLess(max(p.ellipse[1]), 71)

    def test_every_old_lower_iris_pixel_has_opaque_ownership(self):
        for side, p in self.prepared.items():
            x, y, _, _ = p.box
            cx = 400 if side == "r" else 625
            old_lower = ((np.hypot(p.grid_x + x - cx, p.grid_y + y - 420) <= 33)
                         & (p.grid_y + y > 440))
            self.assertGreater(int(old_lower.sum()), 250)
            self.assertTrue(np.all(p.aperture[old_lower] == 1))
            self.assertTrue(np.all(p.iris_alpha[old_lower] == 1))
            moved = render(p, -9, -3)
            matte = cv2.remap(p.iris_alpha, p.grid_x + 9, p.grid_y + 3,
                             cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
            vacated = old_lower & (matte == 0)
            self.assertGreater(int(vacated.sum()), 20)
            self.assertGreater(int(moved[vacated].min()), 190)

    def test_neutral_source_and_dry_lashes_skin_are_exact_all_550_states(self):
        for side, p in self.prepared.items():
            x, y, w, h = p.box
            outside_source_eye = ~self.eye_masks[side][y:y+h, x:x+w]
            self.assertFalse(p.aperture[outside_source_eye].any())
            np.testing.assert_array_equal(render(p, 0, 0), p.base)
            for dy in expression.GAZE_DY:
                for dx in expression.GAZE_DX:
                    result = render(p, dx, dy)
                    np.testing.assert_array_equal(result[outside_source_eye], p.base[outside_source_eye])

    def test_observed_iris_texture_and_glint_are_rigid_integer_translation(self):
        for p in self.prepared.values():
            for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, -3), (9, 3)):
                yy, xx = np.where((p.iris_alpha == 1) & (p.aperture == 1))
                tx, ty = xx + dx, yy + dy
                valid = ((tx >= 0) & (tx < p.box[2]) & (ty >= 0) & (ty < p.box[3]))
                xx, yy, tx, ty = xx[valid], yy[valid], tx[valid], ty[valid]
                valid = p.aperture[ty, tx] == 1
                self.assertGreater(int(valid.sum()), 3500)
                np.testing.assert_array_equal(render(p, dx, dy)[ty[valid], tx[valid]],
                                              p.base[yy[valid], xx[valid]])

    def test_inputs_unchanged_and_half_resolution_supported(self):
        image, lm, _ = enclosed_brown_fixture(.5)
        image_before, lm_before = image.copy(), lm.copy()
        box = expression._box(expression._eyeball_mask(image.shape, lm, "r", .5), 4, image.shape)
        p = soft3d_gaze.prepare(image, lm, "r", box)
        self.assertEqual(p.evidence["brown_aperture_method"], "source-enclosed-sclera")
        self.assertTrue(np.isfinite(render(p, 4.5, 1.75)).all())
        np.testing.assert_array_equal(image, image_before)
        np.testing.assert_array_equal(lm, lm_before)


class OccludedBrown3DSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.true_eyes = occluded_brown_fixture()
        cls.prepared = {}
        for side in ("r", "l"):
            box = expression._box(expression._eyeball_mask(cls.image.shape, cls.lm, side, 1), 7, cls.image.shape)
            cls.prepared[side] = soft3d_gaze.prepare(cls.image, cls.lm, side, box)

    def test_source_partial_opening_does_not_fall_back_to_smaller_human_eye(self):
        for p in self.prepared.values():
            self.assertEqual(p.evidence["brown_aperture_method"], "source-occluded-sclera")
            self.assertEqual(p.evidence["source_lower_lid_method"], "bounded-continuous-source-spline")
            self.assertGreater(min(p.ellipse[1]), 65)
            self.assertLess(max(p.ellipse[1]), 71)
            self.assertGreater(p.evidence["occluded_cap_pixels"], 200)
            self.assertLessEqual(p.evidence["occluded_cap_max_arc_degrees"], 225)

    def test_neutral_and_fixed_dry_lashes_are_exact_in_all_550_states(self):
        for side, p in self.prepared.items():
            x, y, width, height = p.box
            outside = ~self.true_eyes[side][y:y+height, x:x+width]
            self.assertFalse(p.aperture[outside].any())
            np.testing.assert_array_equal(render(p, 0, 0), p.base)
            for dy in expression.GAZE_DY:
                for dx in expression.GAZE_DX:
                    patch = soft3d_gaze.state(p, dx, dy)
                    expected = (p.aperture > 0).astype(np.uint8) * 255 if dx or dy else 0
                    np.testing.assert_array_equal(patch[..., 3], expected)
                    np.testing.assert_array_equal(render(p, dx, dy)[outside], p.base[outside])

    def test_old_lower_iris_is_owned_but_no_lash_shadow_is_transported(self):
        for side, p in self.prepared.items():
            cx = 400 if side == "r" else 625
            canonical_x, canonical_y = p.grid_x + p.box[0], p.grid_y + p.box[1]
            true_lower = 420 + 27 * (1 - ((canonical_x - cx) / 61) ** 2)
            lower_iris = ((np.hypot(canonical_x - cx, canonical_y - 420) < 31)
                         & (canonical_y > 439) & (canonical_y < true_lower - 2))
            self.assertGreater(int(lower_iris.sum()), 100)
            self.assertTrue(np.all(p.aperture[lower_iris] == 1))
            moved_matte = cv2.remap(p.iris_alpha, p.grid_x + 9, p.grid_y + 3,
                                    cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
            vacated = lower_iris & (moved_matte == 0)
            self.assertGreater(int(vacated.sum()), 8)
            self.assertGreater(int(render(p, -9, -3)[vacated].min()), 190)
            # The completed cap is native equal-radius iris colour, not a
            # horizontal black eyelash extended down to make a fake limbus.
            distance = soft3d_gaze._ellipse_distance(p.grid_x, p.grid_y, p.ellipse)
            cap = ((p.grid_y > p.ellipse[0][1] + 25) & (distance < -3)
                   & (distance > -6))
            self.assertGreater(int(cap.sum()), 10)
            self.assertGreater(float(p.texture[cap, 2].mean()), 90)

    def test_observed_iris_and_catchlight_are_not_repainted_or_stretched(self):
        for p in self.prepared.values():
            # Stay clear of the real lower-lash occlusion; every visible
            # central iris/glint pixel must be a rigid source translation.
            observed = ((p.aperture == 1) & (p.iris_alpha == 1)
                        & (p.grid_y < p.ellipse[0][1] + 16))
            np.testing.assert_array_equal(p.texture[observed], p.base[observed])
            for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3)):
                yy, xx = np.where(observed)
                tx, ty = xx + dx, yy + dy
                keep = (tx >= 0) & (tx < p.box[2]) & (ty >= 0) & (ty < p.box[3])
                yy, xx, tx, ty = yy[keep], xx[keep], tx[keep], ty[keep]
                keep = p.aperture[ty, tx] == 1
                self.assertGreater(int(keep.sum()), 1700)
                np.testing.assert_array_equal(render(p, dx, dy)[ty[keep], tx[keep]],
                                              p.base[yy[keep], xx[keep]])

    def test_missing_bilateral_white_or_iris_ring_fails_closed(self):
        p = self.prepared['r']
        absent = np.zeros(p.aperture.shape, bool)
        with self.assertRaises(soft3d_gaze.UnsupportedSoft3DIris):
            soft3d_gaze._occluded_brown_aperture(p.base, absent, p.ellipse, 1)
        observed = np.zeros(p.aperture.shape, bool)
        unknown = np.zeros_like(observed)
        uy, ux = np.rint(p.ellipse[0][::-1]).astype(int)
        unknown[uy, ux] = True
        with self.assertRaises(soft3d_gaze.UnsupportedSoft3DIris):
            soft3d_gaze._complete_occluded_iris_cap(
                p.base, observed, unknown, p.ellipse, p.base.copy(), p.iris_alpha)

    def test_partial_preparation_does_not_mutate_inputs(self):
        image_before, landmarks_before = self.image.copy(), self.lm.copy()
        p = self.prepared['r']
        box = expression._box(expression._eyeball_mask(self.image.shape, self.lm, 'r', 1), 7, self.image.shape)
        again = soft3d_gaze.prepare(self.image, self.lm, 'r', box)
        np.testing.assert_array_equal(again.texture, p.texture)
        np.testing.assert_array_equal(self.image, image_before)
        np.testing.assert_array_equal(self.lm, landmarks_before)


if __name__ == "__main__":
    unittest.main()
