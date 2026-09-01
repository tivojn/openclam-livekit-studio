"""The canonical and donor hair silhouettes must meet without a notch."""
import inspect
import unittest

import cv2
import numpy as np

from studio import body


class StylizedHairHandoffTests(unittest.TestCase):
    def fixture(self, gap=3, reconnect=True):
        shape = (32, 40)
        clear = np.zeros(shape, np.uint8)
        donor = np.zeros(shape, np.uint8)
        warped = np.zeros(shape, np.uint8)
        # Canonical head/hair ends at x=22. The donor is source-supported all
        # the way through the handoff, but the clear mask removes a short band
        # before retained donor hair resumes.
        warped[8:30, 12:23] = 255
        donor[8:30, 8:31] = 255
        clear[8:11, 23:23 + gap] = 255
        if not reconnect:
            clear[11:22, 23:23 + gap] = 255
        projected = np.array([
            [12, 8], [22, 8], [22, 30], [12, 30]], np.float32)
        return clear, donor, warped, projected

    def release_fixture(self):
        shape = (64, 80)
        clear = np.zeros(shape, np.uint8)
        donor = np.zeros(shape, np.uint8)
        warped = np.zeros(shape, np.uint8)
        donor[8:44, 15:66] = 255
        warped[8:32, 20:61] = 255
        fade = (254, 252, 249, 245, 240, 208, 163, 114, 66, 28, 7, 4)
        for row, alpha in enumerate(fade, 32):
            warped[row, 20:61] = alpha
        projected = np.array([
            [20, 8], [60, 8], [60, 52], [20, 52]], np.float32)
        hair_bridge = {
            "applied": True,
            "events": [
                {"side": "viewer-left", "gap_rows": [12, 13]},
                {"side": "viewer-right", "gap_rows": [12, 13]},
            ],
        }
        return clear, donor, warped, projected, hair_bridge

    def test_short_reconnecting_hair_shelf_is_erased_then_tapered(self):
        inputs = self.fixture(gap=3)
        originals = [value.copy() for value in inputs]
        result, receipt = body._taper_short_stylized_hair_protrusions(
            *inputs, source_medium="3d render")
        self.assertTrue(receipt["applied"])
        self.assertTrue(np.all(result >= originals[0]))
        # The detached donor shelf is erased for all three gap rows. Once the
        # silhouettes reconnect, retain the canonical edge for five more rows
        # through the high-contrast handoff, then release the exterior edge
        # one pixel per row until the donor's natural x=30 contour is reached.
        donor_visible = (inputs[1] > 8) & (result < 5)
        final = (inputs[2] > 4) | donor_visible
        right_edges = [int(np.flatnonzero(final[row])[-1])
                       for row in range(8, 24)]
        self.assertEqual(
            [22, 22, 22, 22, 22, 22, 22, 22,
             23, 24, 25, 26, 27, 28, 29, 30], right_edges)
        self.assertTrue(all(after - before <= 1 for before, after in zip(
            right_edges, right_edges[1:])))
        for row in range(8, 24):
            visible = np.flatnonzero(final[row])
            self.assertEqual(len(visible), visible[-1] - visible[0] + 1)
        self.assertGreater(receipt["changed_pixels"], 0)
        for value, original in zip(inputs, originals):
            self.assertTrue(np.array_equal(value, original))

    def test_large_gap_and_non_3d_routes_are_byte_identical(self):
        inputs = self.fixture(gap=5)
        result, receipt = body._taper_short_stylized_hair_protrusions(
            *inputs, source_medium="3d render")
        self.assertIsNot(result, inputs[0])
        self.assertTrue(np.array_equal(result, inputs[0]))
        self.assertFalse(receipt["applied"])
        for medium in (None, "photograph", "illustration", "2d cartoon"):
            result, receipt = body._taper_short_stylized_hair_protrusions(
                *inputs, source_medium=medium)
            self.assertIs(result, inputs[0])
            self.assertFalse(receipt["applied"])

    def test_missing_donor_support_is_never_invented(self):
        clear, donor, warped, projected = self.fixture(gap=3)
        donor[8:22, 24] = 0
        original = clear.copy()
        result, receipt = body._taper_short_stylized_hair_protrusions(
            clear, donor, warped, projected, source_medium="3d render")
        self.assertTrue(np.array_equal(result, original))
        self.assertFalse(receipt["applied"])

    def test_long_unreconnecting_gap_is_not_treated_as_handoff(self):
        inputs = self.fixture(gap=3, reconnect=False)
        result, receipt = body._taper_short_stylized_hair_protrusions(
            *inputs, source_medium="3d render")
        self.assertTrue(np.array_equal(result, inputs[0]))
        self.assertFalse(receipt["applied"])

    def test_production_clear_mask_runs_the_bounded_hair_taper(self):
        source = inspect.getsource(body._stylized_head_clear_mask)
        self.assertIn("_taper_short_stylized_hair_protrusions(", source)
        self.assertIn("_release_soft_3d_lateral_donor_hair(", source)
        self.assertIn("lateral_hair_release", source)
        self.assertLess(
            source.index("_taper_short_stylized_hair_protrusions("),
            source.index("clear_alpha[upper_head_erase] = 255"))
        self.assertLess(
            source.index("clear_alpha[upper_head_erase] = 255"),
            source.index("_release_soft_3d_lateral_donor_hair("))
        self.assertNotIn("_bridge_short_stylized_hair_gaps(", source)
        self.assertNotIn("retired-alpha-only-hair-bridge", source)

    def test_soft3d_head_erase_owns_low_alpha_and_sampling_guard(self):
        donor = np.zeros((7, 12), np.uint8)
        donor[3, 4:9] = (1, 4, 8, 12, 255)
        head_side = np.zeros_like(donor, dtype=bool)
        head_side[2:5, 2:11] = True
        canonical = np.zeros_like(head_side)
        canonical[3, 10] = True

        silhouette, erased, guard_pixels = (
            body._stylized_donor_head_erase_support(
                donor, head_side, canonical, source_medium="3d render"))
        self.assertTrue(np.array_equal(
            np.flatnonzero(silhouette[3]), np.array([7, 8])))
        self.assertTrue(np.array_equal(
            np.flatnonzero(erased[3]), np.arange(3, 10)))
        self.assertFalse(erased[3, 10])
        self.assertGreater(guard_pixels, 0)

        legacy, legacy_erased, legacy_guard = (
            body._stylized_donor_head_erase_support(
                donor, head_side, canonical, source_medium="2d cartoon"))
        self.assertTrue(np.array_equal(legacy, silhouette))
        self.assertTrue(np.array_equal(legacy_erased, silhouette))
        self.assertEqual(legacy_guard, 0)

    def test_soft3d_sampling_guard_prevents_noninteger_canvas_halo(self):
        donor = np.zeros((20, 28), np.uint8)
        donor[4:16, 7:21] = 255
        head_side = np.ones_like(donor, dtype=bool)
        canonical = np.zeros_like(head_side)
        _silhouette, erased, _guard_pixels = (
            body._stylized_donor_head_erase_support(
                donor, head_side, canonical, source_medium="3d render"))

        scale = 2.123
        size = (round(donor.shape[1] * scale),
                round(donor.shape[0] * scale))

        def residual(clear):
            body_alpha = cv2.resize(
                donor, size, interpolation=cv2.INTER_LINEAR).astype(np.float32)
            clear_alpha = cv2.resize(
                clear.astype(np.uint8) * 255, size,
                interpolation=cv2.INTER_LINEAR).astype(np.float32)
            return body_alpha * (1.0 - clear_alpha / 255.0)

        guarded = residual(erased)
        unguarded = residual(donor > 8)
        self.assertLessEqual(float(np.max(guarded)), 1.0)
        self.assertEqual(int(np.count_nonzero(guarded > 4)), 0)
        self.assertGreater(int(np.count_nonzero(unguarded > 16)), 0)

    def test_soft3d_upper_head_owner_closes_side_island_above_jaw_only(self):
        donor = np.zeros((12, 16), np.uint8)
        donor[1:10, 2:14] = 255
        warped = np.zeros_like(donor)
        warped[2:9, 5:11] = 255
        projected = np.array([
            [5, 2], [10, 2], [10, 9], [5, 9]], np.float32)

        owner = body._soft_3d_upper_head_erase_support(
            donor, warped, projected, 2.0,
            source_medium="3d render")
        # The donor island immediately outboard of canonical art is owned
        # through y=7 (= jaw bottom 9 minus the two-pixel feather).
        self.assertTrue(owner[6, 4])
        self.assertTrue(owner[7, 4])
        self.assertFalse(owner[8, 4])
        self.assertFalse(owner[6, 5])
        self.assertFalse(owner[6, 1])

        for medium in (None, "photograph", "illustration", "2d cartoon"):
            untouched = body._soft_3d_upper_head_erase_support(
                donor, warped, projected, 2.0, source_medium=medium)
            self.assertFalse(np.any(untouched))

    def test_soft3d_upper_owner_removes_only_outboard_low_alpha_fringe(self):
        donor = np.zeros((14, 20), np.uint8)
        donor[2:12, 2:18] = 255
        warped = np.zeros_like(donor)
        warped[6, 6:15] = 255
        warped[6, 4] = 5
        warped[6, 10] = 6
        warped[6, 15] = 8
        projected = np.array([
            [6, 2], [14, 2], [14, 11], [6, 11]], np.float32)

        owner = body._soft_3d_upper_head_erase_support(
            donor, warped, projected, 2.0,
            source_medium="3d render")

        # Alpha 5-8 outside the solid row envelope must not preserve opaque
        # donor backing. The same alpha inside that envelope is real authored
        # antialiasing and remains backed by the generated body.
        self.assertTrue(owner[6, 4])
        self.assertTrue(owner[6, 15])
        self.assertFalse(owner[6, 6])
        self.assertFalse(owner[6, 10])
        clear = owner.astype(np.float32)
        source = warped.astype(np.float32)
        cleared_donor = donor.astype(np.float32) * (1.0 - clear)
        composite_alpha = source + cleared_donor * (1.0 - source / 255.0)
        self.assertEqual(5, int(composite_alpha[6, 4]))
        self.assertEqual(255, int(composite_alpha[6, 10]))

    def test_soft_3d_support_extends_lateral_hair_but_not_central_neck(self):
        support = np.zeros((180, 180), np.float32)
        oval = np.array([
            [50, 30], [130, 30], [130, 110], [50, 110]], np.float32)
        original = support.copy()
        result, receipt = body._soft_3d_hair_and_neck_support(
            support, oval, source_medium="3d render")
        self.assertTrue(receipt["applied"])
        self.assertEqual(receipt["neck_owner"], "generated-body")
        self.assertGreater(float(result[118, 55]), 0.0)
        self.assertEqual(float(result[118, 90]), float(original[118, 90]))
        self.assertTrue(np.array_equal(support, original))

    def test_non_3d_support_routes_remain_byte_identical(self):
        support = np.linspace(0, 1, 64, dtype=np.float32).reshape(8, 8)
        oval = np.array([[1, 1], [6, 1], [6, 6], [1, 6]], np.float32)
        for medium in (None, "photograph", "illustration", "2d cartoon"):
            result, receipt = body._soft_3d_hair_and_neck_support(
                support, oval, source_medium=medium)
            self.assertIs(result, support)
            self.assertFalse(receipt["applied"])

    def test_proven_hair_stays_canonical_then_releases_by_source_alpha(self):
        inputs = self.release_fixture()
        originals = [value.copy() if isinstance(value, np.ndarray) else value
                     for value in inputs]
        result, receipt = body._release_soft_3d_lateral_donor_hair(
            *inputs, source_medium="3d render")

        self.assertTrue(receipt["applied"])
        self.assertEqual("generated-body", receipt["central_neck_owner"])
        self.assertTrue(np.all(result[12:32, 14:20] == 255))
        self.assertTrue(np.all(result[12:32, 61:67] == 255))
        self.assertTrue(np.all(result[43] == 0))
        previous_left = None
        previous_right = None
        for row in range(12, 43):
            alpha = int(inputs[2][row, 20])
            owner = np.clip((alpha - 4.0) / 251.0, 0.0, 1.0)
            raw_left = 20.0 - (1.0 - owner) * 6.0
            raw_right = 60.0 + (1.0 - owner) * 6.0
            left_target = raw_left if previous_left is None else min(
                previous_left, max(raw_left, previous_left - 1.0))
            right_target = raw_right if previous_right is None else max(
                previous_right, min(raw_right, previous_right + 1.0))
            previous_left = left_target
            previous_right = right_target
            expected_left = np.round(255.0 * np.clip(
                left_target - np.arange(14, 20), 0.0, 1.0)).astype(np.uint8)
            expected_right = np.round(255.0 * np.clip(
                np.arange(61, 67) - right_target, 0.0, 1.0)).astype(np.uint8)
            expected_left[0] = min(expected_left[0], round(255.0 * owner))
            expected_right[-1] = min(
                expected_right[-1], round(255.0 * owner))
            self.assertTrue(np.array_equal(expected_left, result[row, 14:20]))
            self.assertTrue(np.array_equal(expected_right, result[row, 61:67]))
        for value, original in zip(inputs[:4], originals[:4]):
            self.assertTrue(np.array_equal(value, original))

    def test_release_changes_only_outboard_donor_and_never_central_neck(self):
        inputs = self.release_fixture()
        result, _receipt = body._release_soft_3d_lateral_donor_hair(
            *inputs, source_medium="3d render")
        changed_y, changed_x = np.nonzero(result != inputs[0])

        self.assertGreater(len(changed_y), 0)
        donor_guard = cv2.dilate(
            (inputs[1] > 0).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        self.assertTrue(np.all(donor_guard[changed_y, changed_x]))
        self.assertTrue(np.all(inputs[2][changed_y, changed_x] <= 4))
        self.assertTrue(np.all((changed_x < 20) | (changed_x > 60)))
        self.assertTrue(np.array_equal(result[:, 20:61], inputs[0][:, 20:61]))

    def test_source_alpha_release_has_no_binary_end_shelf(self):
        inputs = self.release_fixture()
        result, _receipt = body._release_soft_3d_lateral_donor_hair(
            *inputs, source_medium="3d render")
        source = inputs[2].astype(np.float32)
        donor = inputs[1].astype(np.float32)
        cleared_donor = donor * (1.0 - result.astype(np.float32) / 255.0)
        composite_alpha = source + cleared_donor * (1.0 - source / 255.0)
        edges = []
        for row in range(31, 44):
            visible = np.flatnonzero(composite_alpha[row] > 16)
            edges.append((int(visible[0]), int(visible[-1])))
        self.assertTrue(all(
            max(abs(after[0] - before[0]), abs(after[1] - before[1])) <= 1
            for before, after in zip(edges, edges[1:])))
        self.assertEqual((20, 60), edges[0])
        self.assertEqual((15, 65), edges[-1])

    def test_source_alpha_release_clamps_row_edge_jitter(self):
        clear, donor, warped, projected, event = self.release_fixture()
        # The donor widens as the authored hair begins fading. Without a
        # row-wise target clamp this realistic edge change advances the visible
        # right contour by two native pixels in one row.
        donor[38:44, 66:68] = 255
        event["events"] = [event["events"][1]]
        result, receipt = body._release_soft_3d_lateral_donor_hair(
            clear, donor, warped, projected, event,
            source_medium="3d render")

        self.assertTrue(receipt["applied"])
        source = warped.astype(np.float32)
        cleared_donor = donor.astype(np.float32) * (
            1.0 - result.astype(np.float32) / 255.0)
        composite_alpha = source + cleared_donor * (1.0 - source / 255.0)
        right_edges = []
        for row in range(31, 44):
            visible = np.flatnonzero(composite_alpha[row] > 16)
            right_edges.append(int(visible[-1]))
        self.assertTrue(all(
            0 <= after - before <= 1
            for before, after in zip(right_edges, right_edges[1:])))

    def test_release_requires_a_proven_event_and_is_noop_for_other_media(self):
        clear, donor, warped, projected, event = self.release_fixture()
        no_event = {"applied": False, "events": []}
        result, receipt = body._release_soft_3d_lateral_donor_hair(
            clear, donor, warped, projected, no_event,
            source_medium="3d render")
        self.assertIs(result, clear)
        self.assertFalse(receipt["applied"])

        long_gap = self.fixture(gap=3, reconnect=False)
        _tapered, long_gap_receipt = body._taper_short_stylized_hair_protrusions(
            *long_gap, source_medium="3d render")
        result, receipt = body._release_soft_3d_lateral_donor_hair(
            *long_gap, long_gap_receipt, source_medium="3d render")
        self.assertIs(result, long_gap[0])
        self.assertFalse(receipt["applied"])

        for medium in (None, "photograph", "illustration", "2d cartoon"):
            result, receipt = body._release_soft_3d_lateral_donor_hair(
                clear, donor, warped, projected, event, source_medium=medium)
            self.assertIs(result, clear)
            self.assertFalse(receipt["applied"])

    def test_release_touches_only_the_sides_named_by_the_detector(self):
        clear, donor, warped, projected, event = self.release_fixture()
        event["events"] = [event["events"][1]]
        result, receipt = body._release_soft_3d_lateral_donor_hair(
            clear, donor, warped, projected, event,
            source_medium="3d render")
        self.assertTrue(receipt["applied"])
        self.assertTrue(np.array_equal(result[:, :20], clear[:, :20]))
        self.assertTrue(np.all(result[12:32, 61:67] == 255))

if __name__ == "__main__":
    unittest.main()
