"""Synthetic safety contracts for detached 3D Idle white-plate particles."""
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import motion


def _plate():
    source = np.full((300, 220, 3), 255, np.uint8)
    rgba = np.zeros((300, 220, 4), np.uint8)
    source[20:280, 80:145] = (35, 98, 208)
    rgba[20:280, 80:145, :3] = source[20:280, 80:145]
    rgba[20:280, 80:145, 3] = 255
    return source, rgba


def _island(source, rgba, *, x=75, y=125, w=2, h=3,
            color=(217, 217, 217), alpha=109):
    source[y:y + h, x:x + w] = color
    rgba[y:y + h, x:x + w, :3] = color
    rgba[y:y + h, x:x + w, 3] = alpha


class IdlePlateSpeckleTests(unittest.TestCase):
    def test_only_proved_detached_neutral_particle_is_removed(self):
        source, rgba = _plate()
        _island(source, rgba)
        rgba[125:128, 75:77, 3] = np.array([[11, 44], [150, 88], [8, 109]])
        before = rgba.copy()
        source_before = source.copy()
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        changed = np.any(output != before, axis=2)
        self.assertEqual(6, int(changed.sum()))
        self.assertTrue(np.all(output[125:128, 75:77] == 0))
        self.assertTrue(np.array_equal(output[~changed], before[~changed]))
        self.assertTrue(np.array_equal(output[before[:, :, 3] >= 192],
                                       before[before[:, :, 3] >= 192]))
        self.assertTrue(np.array_equal(rgba, before))
        self.assertTrue(np.array_equal(source, source_before))
        self.assertEqual(1, receipt["removed_components"])
        self.assertEqual(6, receipt["removed_pixels"])

    def test_even_alpha_one_connection_protects_fine_body_detail(self):
        source, rgba = _plate()
        _island(source, rgba)
        source[126, 77:81] = (217, 217, 217)
        rgba[126, 77:81] = (217, 217, 217, 1)
        result, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertIs(result, rgba)
        self.assertEqual(0, receipt["removed_pixels"])

    def test_opaque_grey_island_and_pale_clothing_are_immutable(self):
        for alpha in (192, 254, 255):
            with self.subTest(alpha=alpha):
                source, rgba = _plate()
                _island(source, rgba, alpha=alpha)
                source[90:105, 80:100] = 238
                rgba[90:105, 80:100] = (238, 238, 238, 255)
                output, receipt = motion._remove_idle_plate_speckles(source, rgba)
                self.assertTrue(np.array_equal(output, rgba))
                self.assertEqual(0, receipt["removed_pixels"])

    def test_detached_hair_and_heel_bands_are_not_candidates(self):
        source, rgba = _plate()
        _island(source, rgba, y=30)
        _island(source, rgba, y=271)
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertTrue(np.array_equal(output, rgba))
        self.assertEqual(0, receipt["removed_pixels"])

    def test_chromatic_skin_and_dark_detail_are_not_plate(self):
        for color in ((75, 142, 213), (15, 15, 15), (189, 189, 189)):
            with self.subTest(color=color):
                source, rgba = _plate()
                _island(source, rgba, color=color)
                output, receipt = motion._remove_idle_plate_speckles(source, rgba)
                self.assertTrue(np.array_equal(output, rgba))
                self.assertEqual(0, receipt["removed_pixels"])

    def test_source_enclosed_white_detail_cannot_be_removed(self):
        source, rgba = _plate()
        _island(source, rgba)
        # Intentionally make the semantic matte incomplete.  The decoded
        # source still encloses the white feature, so it is not exterior plate.
        cv2.rectangle(source, (73, 123), (78, 129), (18, 18, 18), 1)
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertTrue(np.array_equal(output, rgba))
        self.assertEqual(0, receipt["removed_pixels"])

    def test_right_side_and_distant_neutral_islands_are_untouched(self):
        source, rgba = _plate()
        _island(source, rgba, x=148)
        _island(source, rgba, x=10)
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertTrue(np.array_equal(output, rgba))
        self.assertEqual(0, receipt["removed_pixels"])

    def test_large_or_connected_shadow_is_not_automatically_erased(self):
        source, rgba = _plate()
        _island(source, rgba, x=70, y=100, w=6, h=40)
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertTrue(np.array_equal(output, rgba))
        self.assertEqual(0, receipt["removed_pixels"])

    def test_white_eyes_glasses_and_one_pixel_heel_remain_exact(self):
        source, rgba = _plate()
        for x in (95, 126):
            cv2.circle(source, (x, 40), 10, (15, 15, 15), -1)
            cv2.circle(source, (x, 40), 7, (250, 250, 250), -1)
            cv2.circle(source, (x, 40), 3, (22, 22, 22), -1)
        rgba[20:280, 80:145, :3] = source[20:280, 80:145]
        source[270:295, 82] = (217, 217, 217)
        rgba[270:295, 82] = (217, 217, 217, 109)
        _island(source, rgba)
        output, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertEqual(6, receipt["removed_pixels"])
        self.assertTrue(np.array_equal(output[:, 80:], rgba[:, 80:]))

    def test_nonwhite_plate_and_malformed_input_are_not_reinterpreted(self):
        source, rgba = _plate()
        _island(source, rgba)
        source[0] = 30
        source[-1] = 30
        source[:, 0] = 30
        source[:, -1] = 30
        result, receipt = motion._remove_idle_plate_speckles(source, rgba)
        self.assertIs(result, rgba)
        self.assertFalse(receipt["available"])
        result, receipt = motion._remove_idle_plate_speckles(source[:20], rgba)
        self.assertIs(result, rgba)
        self.assertFalse(receipt["available"])

    def test_photo_flat_art_other_motion_and_free_idle_are_byte_identical(self):
        source, rgba = _plate()
        _island(source, rgba)
        frames = [rgba]
        variants = [
            ("idle", medium, "folded-cross")
            for medium in ("photograph", "illustration", "anime", "unknown", "game art")
        ] + [("walk", "3d render", "folded-cross"),
             ("move", "3d render", "free"),
             ("idle", "3d render", "free")]
        for kind, medium, validation in variants:
            with self.subTest(kind=kind, medium=medium, validation=validation):
                result, receipt = motion._refine_idle_plate_speckles(
                    [source], frames, kind, medium, validation)
                self.assertIs(result, frames)
                self.assertIsNone(receipt)
        result, receipt = motion._refine_idle_plate_speckles(
            [source], frames, "idle", "3d render", "folded-cross")
        self.assertEqual(6, receipt["removed_pixels"])
        self.assertFalse(np.array_equal(result[0], rgba))
        self.assertEqual("source-connected-detached-idle-plate-v1", receipt["method"])

    def test_frame_mismatch_fails_instead_of_silently_truncating(self):
        source, rgba = _plate()
        with self.assertRaisesRegex(RuntimeError, "frame counts differ"):
            motion._refine_idle_plate_speckles(
                [source], [rgba, rgba], "idle", "3d render", "folded-cross")

    def test_actual_normalisation_receipt_does_not_change_legacy_pixels(self):
        source, rgba = _plate()
        _island(source, rgba)
        legacy, legacy_bounds, legacy_scale = motion._normalise_frames(
            [rgba], include_scale=True)
        transform = {}
        frames, bounds, scale = motion._normalise_frames(
            [rgba], include_scale=True, transform_receipt=transform)
        self.assertTrue(np.array_equal(legacy[0], frames[0]))
        self.assertEqual((legacy_bounds, legacy_scale), (bounds, scale))
        left, top, right, bottom = transform["crop_xyxy"]
        width, height = transform["resize"]
        x, y = transform["offset"]
        mapped, exterior = motion._normalised_idle_plate_source(source, transform)
        expected = cv2.resize(source[top:bottom, left:right], (width, height),
                              interpolation=cv2.INTER_AREA)
        self.assertTrue(np.array_equal(mapped[y:y + height, x:x + width], expected))
        self.assertFalse(np.any(exterior[:y]))
        self.assertFalse(np.any(exterior[:, :x]))

    def test_final_pass_removes_particle_detached_by_ordinary_alpha_cutoff(self):
        source, rgba = _plate()
        _island(source, rgba)
        source[126, 77:80] = (217, 217, 217)
        rgba[126, 77:80] = (217, 217, 217, 1)
        native, native_report = motion._refine_idle_plate_speckles(
            [source], [rgba], "idle", "3d render", "folded-cross")
        self.assertEqual(0, native_report["removed_pixels"])
        transform = {}
        packed, _bounds = motion._normalise_frames(native, transform_receipt=transform)
        before = packed[0].copy()
        output, report = motion._refine_idle_plate_speckles(
            [source], packed, "idle", "3d render", "folded-cross",
            normalisation=transform)
        self.assertEqual(6, report["removed_pixels"])
        changed = np.any(output[0] != before, axis=2)
        self.assertEqual(6, int(changed.sum()))
        self.assertTrue(np.array_equal(output[0][~changed], before[~changed]))
        self.assertTrue(np.array_equal(output[0][before[:, :, 3] >= 192],
                                       before[before[:, :, 3] >= 192]))
        self.assertTrue(np.array_equal(before, packed[0]))
        self.assertEqual(transform, report["normalisation"])

    def test_final_pass_keeps_connected_opaque_and_chromatic_detail(self):
        for color, alpha in (((217, 217, 217), 255), ((35, 98, 208), 109),
                             ((10, 10, 10), 109)):
            with self.subTest(color=color, alpha=alpha):
                source, rgba = _plate()
                _island(source, rgba, color=color, alpha=alpha)
                transform = {}
                packed, _ = motion._normalise_frames([rgba], transform_receipt=transform)
                output, report = motion._refine_idle_plate_speckles(
                    [source], packed, "idle", "3d render", "folded-cross",
                    normalisation=transform)
                self.assertEqual(0, report["removed_pixels"])
                self.assertTrue(np.array_equal(packed[0], output[0]))

    def test_bake_padding_cannot_invent_white_plate_evidence(self):
        source, rgba = _plate()
        _island(source, rgba)
        source[0] = source[-1] = 30
        source[:, 0] = source[:, -1] = 30
        transform = {}
        packed, _ = motion._normalise_frames([rgba], transform_receipt=transform)
        output, report = motion._refine_idle_plate_speckles(
            [source], packed, "idle", "3d render", "folded-cross",
            normalisation=transform)
        self.assertEqual(0, report["measured_frames"])
        self.assertEqual(0, report["removed_pixels"])
        self.assertTrue(np.array_equal(packed[0], output[0]))

    def test_source_connectivity_is_measured_before_crop(self):
        source, rgba = _plate()
        _island(source, rgba)
        cv2.rectangle(source, (73, 123), (78, 129), (18, 18, 18), 1)
        # The crop cuts the enclosing source ring.  Artificial surrounding
        # white pixels must still not turn the enclosed feature into plate.
        transform = {"v": 1, "filter": "INTER_AREA", "source_size": [220, 300],
                     "crop_xyxy": [75, 125, 145, 280], "resize": [70, 155],
                     "offset": [10, 10], "canvas_size": [100, 180]}
        _mapped, exterior = motion._normalised_idle_plate_source(source, transform)
        self.assertFalse(np.any(exterior[10:13, 10:12]))

    def test_resampling_mixed_skin_and_plate_is_not_exterior(self):
        source = np.full((20, 20, 3), 255, np.uint8)
        source[8, 8] = (50, 100, 200)
        transform = {"v": 1, "filter": "INTER_AREA", "source_size": [20, 20],
                     "crop_xyxy": [0, 0, 20, 20], "resize": [10, 10],
                     "offset": [0, 0], "canvas_size": [10, 10]}
        _mapped, exterior = motion._normalised_idle_plate_source(source, transform)
        self.assertFalse(exterior[4, 4])
        self.assertTrue(exterior[3, 3])
        transform["source_size"] = [999, 999]
        with self.assertRaisesRegex(RuntimeError, "normalisation mismatch"):
            motion._normalised_idle_plate_source(source, transform)

    def test_real_process_final_gate_receives_cleaned_packed_particles(self):
        source, rgba = _plate()
        _island(source, rgba)
        source[126, 77:80] = (217, 217, 217)
        rgba[126, 77:80] = (217, 217, 217, 1)
        transform = {}
        expected, _ = motion._normalise_frames([rgba], transform_receipt=transform)
        expected, _ = motion._refine_idle_plate_speckles(
            [source], expected, "idle", "3d render", "folded-cross",
            normalisation=transform)

        class PackedGateReached(Exception):
            pass

        def contact(frames, _bounds, _validation):
            self.assertTrue(np.array_equal(expected[0], frames[0]))
            raise PackedGateReached()

        quality = {"available": True, "valid": True}
        with tempfile.TemporaryDirectory() as stage, \
                mock.patch.object(motion, "_decode_video", return_value=[source, source]), \
                mock.patch.object(motion, "_segment_frames", return_value=(
                    [rgba, rgba], [None, None], "stylized-plate", dict(quality))), \
                mock.patch.object(motion, "_motion_cast_shadow_quality", return_value=quality), \
                mock.patch.object(motion, "_source_alpha_integrity_quality", return_value=quality), \
                mock.patch.object(motion, "_extremity_integrity", return_value=quality), \
                mock.patch.object(motion, "_idle_contact_quality", side_effect=contact):
            with self.assertRaises(PackedGateReached):
                motion._process_clip(
                    "idle", "unused.mp4", 12, stage, lambda _message: None,
                    source_medium="3d render", idle_validation="folded-cross")

    def test_real_process_path_refines_before_unchanged_source_shadow_gate(self):
        source, rgba = _plate()
        _island(source, rgba)

        class ShadowGateReached(Exception):
            pass

        def shadow_gate(sources, frames, kind, idle_validation):
            self.assertEqual("idle", kind)
            self.assertTrue(np.array_equal(source, sources[0]))
            self.assertTrue(np.all(frames[0][125:128, 75:77] == 0))
            self.assertTrue(np.array_equal(frames[0][:, 80:], rgba[:, 80:]))
            raise ShadowGateReached("Unchanged shadow gate receives original source")

        color_quality = {
            "available": True, "valid": True,
            "alpha_integrity_quality": {"available": True, "valid": True},
        }
        with tempfile.TemporaryDirectory() as stage, \
                mock.patch.object(motion, "_decode_video", return_value=[source, source]), \
                mock.patch.object(motion, "_segment_frames", return_value=(
                    [rgba, rgba], [None, None], "stylized-plate", color_quality)), \
                mock.patch.object(motion, "_motion_cast_shadow_quality", side_effect=shadow_gate):
            with self.assertRaises(ShadowGateReached):
                motion._process_clip(
                    "idle", "unused.mp4", 12, stage, lambda _message: None,
                    source_medium="3d render", idle_validation="folded-cross")


if __name__ == "__main__":
    unittest.main()
