"""Pixel-level guards for the explicit legacy soft-3D jaw-band repair."""
import copy
import unittest
from unittest.mock import patch

import numpy as np

from studio import body


class Soft3DJawBandRepairTests(unittest.TestCase):
    def fixture(self, *, curved=True, feather=6, residual=True):
        height = width = 256
        yy, xx = np.mgrid[:height, :width]
        anchor = (175 - np.rint((np.arange(width) - 128) ** 2 * .005)
                  if curved else np.full(width, 175)).astype(int)
        edge = anchor + 3
        clean = np.empty((height, width, 4), np.uint8)
        for channel, base in enumerate((20, 40, 65)):
            clean[:, :, channel] = np.rint(base + yy * .5).astype(np.uint8)
        clean[:, :, 3] = 255
        clean[:, :12, 3] = 0
        clean[220:, :, :3] = (30, 10, 180)  # Clothing must never be retouched.
        donor = clean.copy()
        if residual:
            pale = yy <= edge[None]
            donor[:, :, :3][pale] += 45
        phase = np.clip((yy - anchor[None]) / feather, 0, 1)
        head = np.rint((1 - phase * phase * (3 - 2 * phase)) * 255).astype(np.uint8)
        clear = np.where(yy <= anchor[None], 255, 0).astype(np.uint8)
        affine = np.array([[1., 0., 0.], [0., 1., 0.]])
        bounds = [60, 40, 136, 152]
        handoff = {
            "v": 5, "method": "anatomical-jaw-plus-local-neck-recomposite",
            "body_owns_neck": True, "provider_face_contour_removed": True,
            "body_feather_px": 6,
        }
        return donor, head, clear, affine, bounds, handoff, clean, anchor, edge

    def repair(self, fixture, **overrides):
        donor, head, clear, affine, bounds, handoff = fixture[:6]
        options = {"source_medium": "3d render", "neck_handoff": handoff}
        options.update(overrides)
        return body._repair_soft_3d_jaw_band(
            donor, head, clear, affine, bounds, **options)

    def test_repairs_only_proven_rgb_band_and_preserves_every_input(self):
        fixture = self.fixture()
        before = copy.deepcopy(fixture)
        corrected, receipt = self.repair(fixture)
        self.assertTrue(receipt["applied"])
        self.assertGreater(receipt["arc_columns"], 30)
        self.assertTrue(receipt["visual_review_required"])
        donor, head, clear, affine, bounds, handoff, clean = fixture[:7]
        allowed = np.zeros(donor.shape[:2], bool)
        for column, start, edge in receipt["bands"]:
            allowed[start:edge + 1, column] = True
            np.testing.assert_array_equal(corrected[edge + 1:, column], donor[edge + 1:, column])
        np.testing.assert_array_equal(corrected[~allowed], donor[~allowed])
        np.testing.assert_array_equal(corrected[:, :, 3], donor[:, :, 3])
        self.assertLessEqual(int(np.max(np.abs(
            corrected[:, :, :3][allowed].astype(int) - clean[:, :, :3][allowed]))), 1)
        for index in (0, 1, 2, 3, 6, 7, 8):
            np.testing.assert_array_equal(fixture[index], before[index])
        self.assertEqual(bounds, before[4])
        self.assertEqual(handoff, before[5])

    def test_photograph_illustration_and_unknown_are_exact_noops_before_image_work(self):
        fixture = self.fixture()
        for medium in ("photograph", "illustration", None, "unknown"):
            with self.subTest(medium=medium), patch.object(body.cv2, "warpAffine", side_effect=AssertionError):
                corrected, receipt = self.repair(fixture, source_medium=medium)
                self.assertIs(corrected, fixture[0])
                self.assertFalse(receipt["applied"])

    def test_only_known_legacy_recomposite_provenance_is_eligible(self):
        fixture = self.fixture()
        for override in (None, {}, {"v": 4}, {**fixture[5], "v": 6},
                         {**fixture[5], "method": "other"},
                         {**fixture[5], "body_owns_neck": False},
                         {**fixture[5], "provider_face_contour_removed": False}):
            with self.subTest(handoff=override), patch.object(body.cv2, "warpAffine", side_effect=AssertionError):
                corrected, receipt = self.repair(fixture, neck_handoff=override)
                self.assertIs(corrected, fixture[0])
                self.assertEqual(receipt["reason"], "not-known-v5-neck-recomposite")

    def test_repeat_application_is_idempotent(self):
        fixture = list(self.fixture())
        corrected, receipt = self.repair(fixture)
        self.assertTrue(receipt["applied"])
        fixture[0] = corrected
        second, second_receipt = self.repair(fixture)
        self.assertIs(second, corrected)
        self.assertFalse(second_receipt["applied"])

    def test_smooth_existing_neck_is_not_recoloured(self):
        fixture = self.fixture(residual=False)
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_horizontal_band_is_not_mistaken_for_curved_jaw(self):
        fixture = self.fixture(curved=False)
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertEqual(receipt["reason"], "residual-not-lower-jaw-shaped")

    def test_isolated_highlight_is_not_a_jaw(self):
        fixture = list(self.fixture())
        fixture[0][:, :126] = fixture[6][:, :126]
        fixture[0][:, 131:] = fixture[6][:, 131:]
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_disconnected_alpha_support_does_not_get_interpolated_over(self):
        fixture = list(self.fixture())
        fixture[0][:, 125:131, 3] = 240
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_semtransparent_support_is_never_edited(self):
        fixture = list(self.fixture())
        fixture[0][:, :, 3] = 249
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_long_hair_feather_is_not_a_neck_band(self):
        fixture = self.fixture(feather=24)
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_dark_shadow_and_mixed_colour_edges_are_not_repaired(self):
        for mixed in (False, True):
            with self.subTest(mixed=mixed):
                fixture = list(self.fixture())
                for column, edge in enumerate(fixture[8]):
                    channels = [0] if mixed else [0, 1, 2]
                    for channel in channels:
                        fixture[0][:edge + 1, column, channel] = np.clip(
                            fixture[6][:edge + 1, column, channel].astype(int) - 15, 0, 255)
                corrected, receipt = self.repair(fixture)
                self.assertIs(corrected, fixture[0])
                self.assertFalse(receipt["applied"])

    def test_large_unbounded_contrast_is_ambiguous(self):
        fixture = list(self.fixture())
        fixture[0][:, :, :3] = 0
        for column, edge in enumerate(fixture[8]):
            fixture[0][:edge + 1, column, :3] = 200
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_textured_or_discontinuous_neck_support_is_not_extrapolated(self):
        fixture = list(self.fixture())
        for column, edge in enumerate(fixture[8]):
            fixture[0][edge + 2, column, :3] += 25
        corrected, receipt = self.repair(fixture)
        self.assertIs(corrected, fixture[0])
        self.assertFalse(receipt["applied"])

    def test_tilted_and_mirrored_transforms_are_not_reinterpreted(self):
        for affine in ([[1., .1, 0], [0, 1., 0]], [[-1., 0., 256], [0., 1., 0.]]):
            fixture = list(self.fixture())
            fixture[3] = affine
            corrected, receipt = self.repair(fixture)
            self.assertIs(corrected, fixture[0])
            self.assertEqual(receipt["reason"], "not-upright-neck-handoff")

    def test_malformed_known_handoff_inputs_raise_actionable_error(self):
        for index, value in ((0, np.zeros((5, 5), np.uint8)),
                             (1, np.zeros((5, 5), np.float32)),
                             (2, np.zeros((5, 5), np.uint8)),
                             (3, [[1, 0, float("nan")], [0, 1, 0]]),
                             (4, [60, 40, 100]),
                             (4, [60, 40, float("inf"), 120])):
            with self.subTest(index=index):
                fixture = list(self.fixture())
                fixture[index] = value
                with self.assertRaisesRegex(RuntimeError, "soft-3D jaw-band repair inputs"):
                    self.repair(fixture)


if __name__ == "__main__":
    unittest.main()
