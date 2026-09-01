"""A warm socket shadow must not turn a valid large 3-D blink into a block."""
import unittest
from unittest import mock
from contextlib import ExitStack
import os
import tempfile

import cv2
import numpy as np

from studio import export
from tests.test_soft3d_blink_ownership import _eye_fixture, _pair_fixture, _registration


def _fixture(*, small=False, block=False, shadow=True):
    patch = np.full((230, 220, 3), (100, 150, 220), np.uint8)
    alpha = np.zeros(patch.shape[:2], np.uint8)
    cv2.ellipse(alpha, (110, 100), (70, 65), 0, 0, 360, 255, -1)
    width = 30 if small else 67
    if shadow:
        # Warm socket/nose shadow attached to the inner tip of the closed lid.
        # It is skin, not dark ink, but joins it at the old <100 cutoff.
        cv2.rectangle(patch, (110 + width - 10, 100),
                      (184, 219), (55, 78, 110), -1)
    points = np.array([(110-width, 119), (110-width//2, 130),
                       (110, 134), (110+width//2, 130),
                       (110+width, 119)], np.int32)
    if block:
        cv2.rectangle(patch, (43, 115), (177, 144), (20, 24, 30), -1)
    else:
        cv2.polylines(patch, [points], False, (20, 24, 30), 3, cv2.LINE_AA)
    return patch, alpha


class Soft3DWarmShadowBlinkTests(unittest.TestCase):
    def test_lower_ink_cutoff_still_rejects_disconnected_grey_provider_art(self):
        patch, alpha = _fixture()
        cv2.rectangle(patch, (82, 88), (124, 107), (82, 82, 82), -1)
        # This 860-pixel foreign mark is invisible to <70 ink, but must remain
        # subject to the original <100 foreign-art gate.
        self.assertIsNone(export._soft3d_lid_topology(patch, alpha))

    def test_full_lid_separates_from_connected_warm_skin_without_pixel_edits(self):
        patch, alpha = _fixture()
        before = patch.copy()
        self.assertIsNone(export._stylized_lid_topology(patch, alpha))
        result = export._soft3d_lid_topology(patch, alpha)
        self.assertIsNotNone(result)
        self.assertEqual(70, result["ink_threshold"])
        row = result["stats"][result["lid_index"]]
        self.assertGreater(row[cv2.CC_STAT_WIDTH], 125)
        self.assertLess(row[cv2.CC_STAT_HEIGHT], 25)
        np.testing.assert_array_equal(before, patch)

    def test_fallback_does_not_accept_smaller_nested_lid_or_solid_block(self):
        for options in ({"small": True}, {"block": True}):
            with self.subTest(options=options):
                patch, alpha = _fixture(**options)
                self.assertIsNone(export._soft3d_lid_topology(patch, alpha))

    def test_successful_existing_measurement_is_returned_unchanged(self):
        patch, alpha = _fixture(shadow=False)
        result = export._stylized_lid_topology(patch, alpha)
        self.assertIsNotNone(result)
        with mock.patch.object(export, "_stylized_lid_topology", return_value=result) as measure:
            self.assertIs(result, export._soft3d_lid_topology(patch, alpha))
        measure.assert_called_once_with(patch, alpha, compact_eye=False)

    def test_compact_eye_rejection_never_retries_a_lower_cutoff(self):
        patch, alpha = _fixture()
        with mock.patch.object(export, "_stylized_lid_topology", return_value=None) as measure:
            self.assertIsNone(export._soft3d_lid_topology(patch, alpha, compact_eye=True))
        measure.assert_called_once_with(patch, alpha, compact_eye=True)

    def test_photographs_and_unknown_media_never_enter_fallback(self):
        with mock.patch.object(export, "_soft3d_lid_topology", side_effect=AssertionError):
            for medium in ("photograph", "unknown"):
                self.assertIsNone(export.preflight_stylized_blink("/no-assets", medium))

    def test_spatial_registration_fits_quiet_skin_without_blurring_authored_rgb(self):
        patch, alpha = _fixture(shadow=False)
        yy, xx = np.indices(alpha.shape)
        texture = ((xx + yy) % 3).astype(np.uint8)
        neutral = np.full(patch.shape, (100, 150, 220), np.uint8)
        neutral += texture[:, :, None]
        patch += texture[:, :, None]
        neutral[alpha > 0] = 240
        cv2.ellipse(neutral, (110, 100), (70, 65), 0, 0, 360, (30, 30, 30), 2)
        patch = np.clip(patch.astype(float) - ((xx-110)*.4)[:, :, None], 0, 255).astype(np.uint8)
        before_key, before_source = neutral.copy(), patch.copy()
        topology = export._soft3d_lid_topology(patch, alpha)
        old = export._stylized_flat_skin_registration(neutral, patch, alpha, topology)
        self.assertGreater(old["p95"], 18)
        registered = export._soft3d_authored_skin_registration(neutral, patch, alpha, topology)
        self.assertIsNotNone(registered)
        self.assertLess(registered["p95"], 2)
        field = registered["skin_field"]
        correction = export._soft3d_skin_field(alpha.shape, field["coefficients"], field["centre"], field["extent"])
        self.assertTrue(np.isfinite(correction).all())
        # It is a smooth additive tone field, not a re-rendered/blurred image.
        self.assertLess(float(np.max(np.abs(np.diff(correction, axis=1)))), .5)
        self.assertLess(float(np.max(np.abs(correction[alpha > 0]))), 40)
        np.testing.assert_array_equal(before_key, neutral)
        np.testing.assert_array_equal(before_source, patch)

    def test_already_exact_registration_is_returned_byte_unchanged(self):
        patch, alpha = _fixture(shadow=False)
        old = {"p95": 1.0, "corrected": patch, "correction": np.zeros(3)}
        with mock.patch.object(export, "_stylized_flat_skin_registration", return_value=old):
            self.assertIs(old, export._soft3d_authored_skin_registration(patch, patch, alpha, {}))

    def test_registered_warm_highlight_is_not_reclassified_as_open_sclera(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        skin = np.all(key == (90, 150, 220), axis=2)
        key[skin] = (99, 158, 220)
        for cx in (120, 305):
            # Authored warm highlight (S=77), whose registered B/G +9/+8
            # correction crosses the generic S<72 white-paint threshold.
            cv2.ellipse(shut, (cx, 101), (24, 20), 0, 0, 360,
                        (178, 222, 255), -1)
        original = shut.copy()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            harmonic = stack.enter_context(mock.patch.object(
                export, "_harmonic_stylized_skin", side_effect=AssertionError))
            result = export.preflight_stylized_blink(
                directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)
            harmonic.assert_not_called()
            self.assertEqual("semantic-eye-switch", result["metadata"]["mode"])
            self.assertEqual(["raw"], os.listdir(directory))
        np.testing.assert_array_equal(original, shut)

    def test_real_source_sclera_cannot_be_hidden_by_a_skin_tint(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        for cx in (120, 305):
            cv2.ellipse(shut, (cx, 101), (24, 20), 0, 0, 360,
                        (245, 245, 245), -1)
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            registration = stack.enter_context(mock.patch.object(
                export, "_soft3d_authored_skin_registration", side_effect=AssertionError))
            with self.assertRaises(export.StylizedBlinkNotReady):
                export.preflight_stylized_blink(
                    directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)
            registration.assert_not_called()
            self.assertEqual(["raw"], os.listdir(directory))

    def test_unregistered_large_3d_cannot_publish_harmonic_skin(self):
        key, shut, landmarks, eyes, *_ = _pair_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            stack.enter_context(mock.patch.object(export, "_stylized_flat_skin_registration", return_value=None))
            harmonic = stack.enter_context(mock.patch.object(export, "_harmonic_stylized_skin", side_effect=AssertionError))
            with self.assertRaises(export.StylizedBlinkNotReady):
                export.preflight_stylized_blink(directory, "3d render", neutral=key, eyes=eyes, log=lambda _: None)
            harmonic.assert_not_called()
            self.assertEqual(["raw"], os.listdir(directory))

    def test_registered_upper_crease_is_not_preserved_as_a_second_lid(self):
        key, sclera = _eye_fixture()
        source = key.copy()
        # Warm open-upper-lid crease, separated from the eye rim. The accepted
        # closed source replaces it with smooth skin; black art is unchanged.
        cv2.line(key, (68, 42), (109, 42), (35, 75, 165), 2, cv2.LINE_AA)
        without_source = export._soft3d_static_blink_art(key, sclera)
        with_source = export._soft3d_static_blink_art(key, sclera, registered_source=source)
        self.assertEqual(255, int(without_source[42, 88]))
        self.assertEqual(0, int(with_source[42, 88]))
        for x, y in ((45, 15), (52, 41), (143, 132), (145, 145)):
            self.assertEqual(255, int(with_source[y, x]), (x, y))

    def test_same_warm_colour_mark_below_eye_remains_protected(self):
        key, sclera = _eye_fixture()
        source = key.copy()
        cv2.line(key, (70, 138), (105, 138), (35, 75, 165), 2, cv2.LINE_AA)
        protected = export._soft3d_static_blink_art(key, sclera, registered_source=source)
        self.assertEqual(255, int(protected[138, 88]), "a cheek mark is not an upper-lid crease")

    def test_skin_fit_never_bypasses_missing_quiet_boundary_evidence(self):
        patch, alpha = _fixture()
        with mock.patch.object(export, "_stylized_flat_skin_registration", return_value=None):
            self.assertIsNone(export._soft3d_authored_skin_registration(patch, patch, alpha, {}))


if __name__ == "__main__":
    unittest.main()
