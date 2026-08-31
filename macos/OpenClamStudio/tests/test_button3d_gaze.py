"""3D button-eye rim and native-shading regressions; procedural public inputs."""
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import authored_gaze, button3d_gaze
from studio.blink import UPPER, LOWER


def fixture(scale=1):
    size = 1024
    image = np.full((size, size, 3), (70, 139, 209), np.uint8)
    truth = image.copy()
    lm = np.full((478, 2), (512, 512), np.float32)
    foregrounds, boxes = {}, {}
    yy, xx = np.mgrid[:size, :size]
    for side, cx in (("r", 390), ("l", 626)):
        cy = 490
        aperture = np.zeros((size, size), np.uint8)
        cv2.ellipse(aperture, (cx, cy), (66, 75), -5, 0, 360, 255, -1)
        u, v = xx-cx, yy-cy
        native = np.rint(np.stack([222+.065*u+.06*v, 227+.055*u+.08*v,
                                   232+.04*u+.055*v], axis=-1)).clip(0, 255).astype(np.uint8)
        image[aperture > 0] = native[aperture > 0]
        cv2.ellipse(image, (cx, cy), (67, 76), -5, 0, 360, (16, 20, 24), 2)
        # Fixed glasses/upper lid paint must never become part of moving eye.
        cv2.line(image, (cx-65, cy-81), (cx+60, cy-81), (7, 8, 11), 4)
        truth[aperture > 0] = native[aperture > 0]
        fg = np.zeros_like(aperture)
        cv2.ellipse(fg, (cx+1, cy+4), (20, 22), -6, 0, 360, 255, -1)
        # This asymmetric native notch/glint must not be replaced by a circle.
        cv2.circle(fg, (cx-18, cy), 4, 255, -1)
        distance = cv2.distanceTransform((fg == 0).astype(np.uint8), cv2.DIST_L2, 5)
        rim = (distance > 0) & (distance <= 3) & (aperture > 0)
        image[rim] = np.minimum(native[rim].astype(np.int16)+23, 255).astype(np.uint8)
        image[fg > 0] = (14, 17, 19)
        cv2.circle(image, (cx-6, cy-4), 4, (253, 254, 254), -1)
        cv2.circle(image, (cx+8, cy+9), 2, (227, 231, 235), -1)
        foregrounds[side] = fg > 0
        xs = np.linspace(cx-43, cx+43, 9)
        curve = np.sqrt(np.maximum(0, 1-((xs-cx)/43)**2))
        lm[UPPER[side]] = np.column_stack([xs, cy-17-20*curve])
        lm[LOWER[side]] = np.column_stack([xs, cy-17+15*curve])
        lm[authored_gaze.IRIS[side]] = [cx+5, cy-13]
        boxes[side] = (cx-49, cy-42, 98, 50)
    if scale != 1:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
        truth = cv2.resize(truth, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
        lm *= scale
        boxes = {s: tuple(int(v*scale) for v in b) for s, b in boxes.items()}
    return image, lm, boxes, truth, foregrounds


def over(base, patch):
    alpha = patch[..., 3:4].astype(np.float32)/255
    return np.rint(base*(1-alpha)+patch[..., :3]*alpha).clip(0, 255).astype(np.uint8)


class Button3DGazeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.boxes, cls.truth, cls.foregrounds = fixture()
        cls.eyes = {s: button3d_gaze.prepare(cls.image, cls.lm, s, cls.boxes[s]) for s in ("r", "l")}

    def test_separate_3d_protocol_and_exact_native_foreground(self):
        for side, p in self.eyes.items():
            m = p.metadata()
            self.assertEqual(m["source_medium"], "3d render")
            self.assertEqual(m["mode"], "soft-3d-authored-iris-v1")
            self.assertNotEqual(m["mode"], authored_gaze.MODE)
            self.assertEqual(m["shape_fit"], "none")
            self.assertEqual(m["sclera_rim_exclusion_source_px"], 6)
            x, y, w, h = p.box
            np.testing.assert_array_equal(p.observed_foreground, self.foregrounds[side][y:y+h, x:x+w])

    def test_neutral_is_exact_and_inputs_unchanged(self):
        image, lm, boxes, _, _ = fixture()
        source, points = image.copy(), lm.copy()
        p = button3d_gaze.prepare(image, lm, "r", boxes["r"])
        patch = button3d_gaze.state(p, 0, 0)
        self.assertFalse(patch[..., 3].any())
        np.testing.assert_array_equal(patch[..., :3], p.base)
        np.testing.assert_array_equal(over(p.base, patch), p.base)
        np.testing.assert_array_equal(image, source)
        np.testing.assert_array_equal(lm, points)

    def test_rim_excluded_fill_recovers_known_native_shading_not_white_disc(self):
        for side, p in self.eyes.items():
            x, y, w, h = p.box
            expected = self.truth[y:y+h, x:x+w].astype(np.float32)
            error = np.abs(p.sclera[p.observed_foreground]-expected[p.observed_foreground])
            self.assertLess(float(np.quantile(error, .95)), 1.5)
            # Negative control: reusing the thin flat-art matte samples glossy
            # 3D rim RGB and spreads it into an incorrect white old-pupil disc.
            bx, by, bw, bh = self.boxes[side]
            flat = authored_gaze.prepare(self.image, self.lm, side, (bx-8, by-8, bw+16, bh+16))
            fx, fy, fw, fh = flat.box
            truth = self.truth[fy:fy+fh, fx:fx+fw].astype(np.float32)
            error = np.abs(flat.sclera[flat.observed_foreground]-truth[flat.observed_foreground])
            self.assertGreater(float(np.quantile(error, .95)), 8)
            self.assertTrue(p.metadata()["hidden_sclera_is_estimate"])

    def test_native_rim_and_catchlight_translate_without_shape_fit(self):
        for p in self.eyes.values():
            full = p.iris_alpha == 1
            self.assertGreater(int((full & ~p.observed_foreground).sum()), 150)
            ys, xs = np.where(full)
            glint = (p.base.min(axis=2) > 245) & p.observed_foreground
            self.assertGreater(int(glint.sum()), 30)
            for dx, dy in ((-9, 0), (9, 0), (0, -3), (0, 3), (-9, 3), (9, -3)):
                patch = button3d_gaze.state(p, dx, dy)
                tx, ty = xs+dx, ys+dy
                valid = (tx >= 0) & (tx < p.box[2]) & (ty >= 0) & (ty < p.box[3])
                sx, sy, tx, ty = xs[valid], ys[valid], tx[valid], ty[valid]
                visible = p.aperture[ty, tx]
                np.testing.assert_array_equal(patch[ty[visible], tx[visible], :3], p.base[sy[visible], sx[visible]])
                moved = cv2.warpAffine(glint.astype(np.uint8), np.float32([[1, 0, dx], [0, 1, dy]]),
                                        (p.box[2], p.box[3]), flags=cv2.INTER_NEAREST) > 0
                moved_fg = cv2.warpAffine(p.observed_foreground.astype(np.uint8),
                                           np.float32([[1, 0, dx], [0, 1, dy]]),
                                           (p.box[2], p.box[3]), flags=cv2.INTER_NEAREST) > 0
                actual = (over(p.base, patch).min(axis=2) > 245) & moved_fg & p.aperture
                np.testing.assert_array_equal(actual, moved & p.aperture)

    def test_all_275_states_per_eye_keep_single_rigid_paint_and_fixed_surroundings(self):
        for p in self.eyes.values():
            for dy in np.linspace(-3.5, 3.5, 11):
                for dx in np.linspace(-9, 9, 25):
                    dx, dy = float(dx), float(dy)
                    patch = button3d_gaze.state(p, dx, dy)
                    self.assertFalse(patch[..., 3][~p.aperture].any())
                    rgb = over(p.base, patch)
                    np.testing.assert_array_equal(rgb[~p.aperture], p.base[~p.aperture])
                    fixed = patch[..., 3] == 0
                    np.testing.assert_array_equal(rgb[fixed], p.base[fixed])
                    if dx == 0 and dy == 0:
                        continue
                    a = cv2.remap(p.iris_alpha, p.grid_x-dx, p.grid_y-dy, cv2.INTER_LINEAR)
                    paint = cv2.remap(p.texture_premultiplied, p.grid_x-dx, p.grid_y-dy, cv2.INTER_LINEAR)
                    core = (a == 1) & p.aperture
                    self.assertGreater(int(core.sum()), 1000)
                    np.testing.assert_array_equal(rgb[core], np.rint(paint[core]).astype(np.uint8))
                    vacated = (p.iris_alpha > 0) & (a == 0) & p.aperture
                    self.assertTrue((patch[..., 3][vacated] == 255).all())
                    np.testing.assert_array_equal(rgb[vacated], np.rint(p.sclera[vacated]).astype(np.uint8))

    def test_vacated_pupil_matches_analytic_shading_not_only_internal_fill(self):
        for p in self.eyes.values():
            x, y, w, h = p.box
            expected = self.truth[y:y+h, x:x+w].astype(np.int16)
            for dx, dy in ((-9, 0), (9, 0), (-9, -3.5), (9, 3.5)):
                a = cv2.remap(p.iris_alpha, p.grid_x-dx, p.grid_y-dy, cv2.INTER_LINEAR)
                vacated = (p.iris_alpha > 0) & (a == 0) & p.aperture
                self.assertGreater(int(vacated.sum()), 250)
                actual = over(p.base, button3d_gaze.state(p, dx, dy)).astype(np.int16)
                self.assertLessEqual(float(np.quantile(np.abs(actual[vacated]-expected[vacated]), .95)), 2)

    def test_coloured_or_large_shaded_iris_does_not_use_button_policy(self):
        for colour in ((50, 89, 20), (83, 48, 26)):
            image = self.image.copy()
            image[self.foregrounds["r"]] = colour
            with self.assertRaises(button3d_gaze.UnsupportedButtonIris):
                button3d_gaze.prepare(image, self.lm, "r", self.boxes["r"])
        image = self.image.copy()
        cv2.ellipse(image, (390, 490), (47, 60), 0, 0, 360, (13, 14, 18), -1)
        with self.assertRaises(button3d_gaze.UnsupportedButtonIris):
            button3d_gaze.prepare(image, self.lm, "r", self.boxes["r"])

    def test_ambiguous_opening_and_foreground_merging_lid_fail_closed(self):
        image = self.image.copy()
        cv2.line(image, (390, 490), (390, 410), (10, 14, 20), 5)
        with self.assertRaises(button3d_gaze.UnsupportedButtonIris):
            button3d_gaze.prepare(image, self.lm, "r", self.boxes["r"])
        with self.assertRaises(button3d_gaze.UnsupportedButtonIris):
            button3d_gaze.prepare(np.full_like(image, 220), self.lm, "r", self.boxes["r"])
        patch = button3d_gaze.neutral(image, self.boxes["r"])
        self.assertFalse(patch[..., 3].any())

    def test_non_smooth_native_shading_is_not_accepted_by_self_comparison(self):
        p = self.eyes["r"]
        distance = cv2.distanceTransform((~p.observed_foreground).astype(np.uint8), cv2.DIST_L2, 5)
        yy, xx = np.mgrid[:p.base.shape[0], :p.base.shape[1]]
        bad = p.base.copy()
        known = (distance > 6) & p.aperture
        bad[known] = np.where(((xx+yy) % 2)[known, None] == 0, 170, 252)
        with self.assertRaises(button3d_gaze.UnsupportedButtonIris):
            button3d_gaze._shading_evidence(bad, p.aperture, p.observed_foreground,
                                           distance, p.sclera, 1)

    def test_scaled_geometry_and_travel_are_bounded(self):
        image, lm, boxes, _truth, _fg = fixture(.5)
        p = button3d_gaze.prepare(image, lm, "r", boxes["r"])
        self.assertEqual(p.limits, (4.5, 1.75))
        np.testing.assert_array_equal(button3d_gaze.state(p, 1e6, -1e6),
                                      button3d_gaze.state(p, 4.5, -1.75))

    def test_no_per_state_observation_or_shading_fit(self):
        with mock.patch.object(authored_gaze, "_observe", side_effect=AssertionError("reobserve")), \
             mock.patch.object(authored_gaze, "_clean_sclera", side_effect=AssertionError("refill")), \
             mock.patch.object(button3d_gaze, "_shading_evidence", side_effect=AssertionError("refit")):
            for dy in np.linspace(-3.5, 3.5, 11):
                for dx in np.linspace(-9, 9, 25):
                    button3d_gaze.state(self.eyes["r"], dx, dy)

    def test_invalid_requests_and_foreign_prepared_policies_rejected(self):
        for dx, dy in ((np.nan, 0), (0, np.inf)):
            with self.assertRaises(ValueError):
                button3d_gaze.state(self.eyes["r"], dx, dy)
        with self.assertRaises(ValueError):
            button3d_gaze.prepare(self.image.astype(np.float32), self.lm, "r", self.boxes["r"])
        with self.assertRaises(ValueError):
            button3d_gaze.prepare(self.image, self.lm, "r", (-1, 3, 100, 50))
        with self.assertRaises(TypeError):
            button3d_gaze.state(authored_gaze.PreparedIris(**vars(self.eyes["r"])), 1, 0)


if __name__ == "__main__":
    unittest.main()
