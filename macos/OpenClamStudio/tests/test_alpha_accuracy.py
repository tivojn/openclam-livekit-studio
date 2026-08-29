"""Synthetic alpha regressions for cavities, crisp edges, and thin details."""
import json
import os
import tempfile
import types
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import cutout, export as runtime_export, motion


def _pose(left_ankle=(52, 130), right_ankle=(104, 130)):
    points = {
        "nose": (78, 20),
        "neck": (78, 38),
        "root": (78, 78),
        "left_hip": (62, 78),
        "right_hip": (94, 78),
        "left_shoulder": (60, 42),
        "right_shoulder": (96, 42),
        "left_elbow": (48, 70),
        "right_elbow": (108, 70),
        "left_wrist": (44, 98),
        "right_wrist": (112, 98),
        "left_knee": (56, 104),
        "right_knee": (100, 104),
        "left_ankle": left_ankle,
        "right_ankle": right_ankle,
    }
    return {
        "width": 160,
        "height": 180,
        "joints": {
            name: {"x": x, "y": y, "confidence": 0.9}
            for name, (x, y) in points.items()
        },
    }


def _tight_render(image):
    """Run the Python tight-cutout cleanup around a synthetic helper result."""
    with tempfile.TemporaryDirectory() as directory:
        source = os.path.join(directory, "source.png")
        destination = os.path.join(directory, "cutout.png")
        source_image = np.full(image.shape[:2] + (3,), 255, np.uint8)
        visible = image[:, :, 3] > 0
        source_image[visible] = image[:, :, :3][visible]
        if not cv2.imwrite(source, source_image):
            raise AssertionError("could not write synthetic source")
        if not cv2.imwrite(destination, image):
            raise AssertionError("could not write synthetic cutout")
        completed = types.SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.object(cutout, "helper_path", return_value="helper"), \
                mock.patch.object(
                    cutout.subprocess, "run", return_value=completed):
            result = cutout.render(
                source, destination, log=lambda _message: None, tight=True)
        rendered = cv2.imread(destination, cv2.IMREAD_UNCHANGED)
    return result, rendered


def _rising_crossing(profile, threshold):
    """Return the interpolated first rising threshold crossing of a row."""
    above = np.flatnonzero(profile >= threshold)
    if above.size == 0:
        return np.nan
    right = int(above[0])
    if right == 0:
        return 0.0
    left_value = float(profile[right - 1])
    right_value = float(profile[right])
    if right_value <= left_value:
        return float(right)
    fraction = (float(threshold) - left_value) / (right_value - left_value)
    return float(right - 1) + min(1.0, max(0.0, fraction))


def _rising_edge_metrics(alpha, rows):
    """Measure 50% edge position and 10%-to-90% transition width."""
    positions = []
    widths = []
    for row in rows:
        profile = alpha[row].astype(np.float32)
        low = _rising_crossing(profile, 0.1 * 255.0)
        middle = _rising_crossing(profile, 0.5 * 255.0)
        high = _rising_crossing(profile, 0.9 * 255.0)
        if np.isfinite(low) and np.isfinite(middle) and np.isfinite(high):
            positions.append(middle)
            widths.append(high - low)
    return np.asarray(positions), np.asarray(widths)


def _dominant_component(labels, region):
    values = labels[region]
    values = values[values > 0]
    if values.size == 0:
        return 0
    return int(np.bincount(values).argmax())


def _thin_detail_fixture(stem_width):
    """Create one-pixel hair cores and an anti-aliased high-heel stem."""
    image = np.zeros((76, 80, 4), np.uint8)
    alpha = image[:, :, 3]

    # A compact person/shoe mass anchors every thin feature to one component.
    alpha[10:44, 28:52] = 255
    alpha[36:46, 28:58] = 255

    stem_x = 51
    stem_rows = slice(45, 67)
    alpha[stem_rows, stem_x:stem_x + stem_width] = 255

    hair_core = np.zeros_like(alpha)
    strands = (
        np.array(((29, 14), (25, 12), (21, 9), (17, 7), (12, 8))),
        np.array(((29, 19), (25, 18), (21, 17), (17, 15), (13, 13))),
    )
    for strand in strands:
        cv2.polylines(
            hair_core, [strand.astype(np.int32)], False, 255, 1, cv2.LINE_8)
    alpha[hair_core > 0] = 255

    # Explicit fractional side samples model anti-aliasing without a blur.
    detail_core = np.zeros_like(alpha)
    detail_core[stem_rows, stem_x:stem_x + stem_width] = 255
    detail_core[hair_core > 0] = 255
    side_samples = (
        cv2.dilate(detail_core, np.ones((3, 3), np.uint8)) > 0
    ) & (alpha == 0)
    alpha[side_samples] = 64

    image[:, :, :3][alpha >= 128] = (35, 55, 105)
    image[:, :, :3][(alpha > 0) & (alpha < 128)] = (230, 235, 240)
    return image, stem_x, stem_rows


def _heel_plate_fixture(include_shadow_alpha=False, include_stem_alpha=True):
    """White-plate lower body with a real 2px heel and a touching shadow."""
    source = np.full((180, 160, 3), 255, np.uint8)
    source[48:138, 96:108] = (68, 92, 128)
    source[132:144, 88:114] = (18, 25, 38)
    # This broad, low-saturation plate shadow touches the genuine stem. It is
    # intentionally plausible H.264 white-plate evidence, not a subject core.
    source[163:170, 86:130] = (232, 232, 232)
    source[143:169, 109:111] = (12, 18, 28)

    alpha = np.zeros((180, 160), np.uint8)
    alpha[48:138, 96:108] = 255
    alpha[132:144, 88:114] = 255
    if include_stem_alpha:
        alpha[143:169, 109:111] = 255
    if include_shadow_alpha:
        alpha[163:170, 86:130] = 255
    frame = np.zeros((180, 160, 4), np.uint8)
    frame[:, :, :3] = source
    frame[:, :, 3] = alpha
    frame[:, :, :3][alpha == 0] = 0
    return source, frame


class AlphaAccuracy(unittest.TestCase):
    def test_native_accurate_mask_is_not_expanded_or_reblurred(self):
        source = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "electron", "native", "person_cutout.swift",
        )
        with open(source, encoding="utf-8") as handle:
            swift = handle.read()
        self.assertIn("request.qualityLevel = .accurate", swift)
        self.assertNotIn('applyingFilter("CIMorphologyMaximum"', swift)
        self.assertNotIn('applyingFilter("CIGaussianBlur"', swift)

    def test_tight_cutout_keeps_antialiased_edge_position_and_width(self):
        """Cleanup must neither soften nor pull in an already-correct edge."""
        image = np.zeros((64, 72, 4), np.uint8)
        alpha = image[:, :, 3]
        for row in range(10, 54):
            phase = (row % 3) * 8
            alpha[row, 17] = 4
            alpha[row, 18] = 48 + phase
            alpha[row, 19] = 176 + phase
            alpha[row, 20:50] = 255
            alpha[row, 50] = 176 + phase
            alpha[row, 51] = 48 + phase
            alpha[row, 52] = 4
        image[:, :, :3][alpha >= 128] = (35, 55, 105)
        image[:, :, :3][(alpha > 0) & (alpha < 128)] = (245, 245, 245)

        result, rendered = _tight_render(image)

        self.assertIsNotNone(result)
        self.assertIsNotNone(rendered)
        before_positions, before_widths = _rising_edge_metrics(
            alpha, range(10, 54))
        after_alpha = rendered[:, :, 3]
        after_positions, after_widths = _rising_edge_metrics(
            after_alpha, range(10, 54))

        self.assertLessEqual(
            float(np.percentile(np.abs(after_positions - before_positions), 95)),
            0.25,
        )
        self.assertLessEqual(
            float(np.percentile(after_widths - before_widths, 95)), 0.25)
        self.assertLessEqual(float(np.percentile(after_widths, 95)), 2.5)

        visible_before = alpha >= 8
        visible_after = after_alpha >= 8
        self.assertEqual(0, int(np.count_nonzero(
            visible_after & ~visible_before)))
        fractional_before = int(np.count_nonzero((alpha >= 8) & (alpha < 247)))
        fractional_after = int(np.count_nonzero(
            (after_alpha >= 8) & (after_alpha < 247)))
        self.assertGreaterEqual(fractional_after, int(0.98 * fractional_before))
        opaque_before = int(np.count_nonzero(alpha >= 247))
        opaque_after = int(np.count_nonzero(after_alpha >= 247))
        self.assertGreaterEqual(opaque_after, int(0.995 * opaque_before))

    def test_tight_cutout_preserves_connected_heel_and_hair_details(self):
        """One-to-three-pixel stems and hair cores must retain reach and width."""
        for stem_width in (1, 2, 3):
            with self.subTest(stem_width=stem_width):
                image, stem_x, stem_rows = _thin_detail_fixture(stem_width)
                source_alpha = image[:, :, 3]
                result, rendered = _tight_render(image)

                self.assertIsNotNone(result)
                self.assertIsNotNone(rendered)
                output_alpha = rendered[:, :, 3]
                source_core = source_alpha >= 128
                output_core = output_alpha >= 128
                _, source_labels = cv2.connectedComponents(
                    source_core.astype(np.uint8), connectivity=8)
                _, output_labels = cv2.connectedComponents(
                    output_core.astype(np.uint8), connectivity=8)
                body_region = np.s_[20:36, 32:48]
                hair_region = np.s_[4:22, 8:29]
                heel_tip_region = np.s_[64:68, stem_x - 1:stem_x + stem_width + 1]
                source_component = _dominant_component(
                    source_labels, body_region)
                output_component = _dominant_component(
                    output_labels, body_region)

                source_hair = int(np.count_nonzero(
                    source_labels[hair_region] == source_component))
                output_hair = int(np.count_nonzero(
                    output_labels[hair_region] == output_component))
                output_tip = int(np.count_nonzero(
                    output_labels[heel_tip_region] == output_component))
                self.assertGreater(source_component, 0)
                self.assertGreater(output_component, 0)
                self.assertGreater(output_tip, 0)
                self.assertGreaterEqual(output_hair, int(0.98 * source_hair))

                stem_window = np.s_[
                    stem_rows, stem_x - 2:stem_x + stem_width + 2]
                source_widths = source_core[stem_window].sum(axis=1)
                output_widths = output_core[stem_window].sum(axis=1)
                self.assertGreaterEqual(
                    float(np.median(output_widths)),
                    float(np.median(source_widths)) - 0.25,
                )
                self.assertLessEqual(
                    float(np.percentile(output_widths, 95)),
                    float(np.percentile(source_widths, 95)) + 0.25,
                )

                source_hair_points = np.argwhere(
                    source_core & (np.indices(source_core.shape)[1] < 28))
                output_hair_points = np.argwhere(
                    output_core & (np.indices(output_core.shape)[1] < 28))
                self.assertLessEqual(
                    int(output_hair_points[:, 1].min()),
                    int(source_hair_points[:, 1].min()) + 1,
                )
                self.assertEqual(0, int(np.count_nonzero(
                    (output_alpha >= 8) & ~(source_alpha >= 8))))

    def test_motion_cache_version_covers_source_aware_matte(self):
        self.assertGreaterEqual(motion.MOTION_VERSION, 11)

    def test_white_plate_refinement_does_not_reblur_a_crisp_boundary(self):
        source = np.full((72, 80, 3), 255, np.uint8)
        source[12:62, 24:58] = (35, 55, 105)
        rgba = np.zeros((72, 80, 4), np.uint8)
        rgba[:, :, :3] = source
        rgba[10:64, 21:61, 3] = 255
        rgba[9:65, 20, 3] = 72
        rgba[9:65, 61, 3] = 72

        refined = motion._refine_white_matte(source, rgba)
        alpha = refined[:, :, 3]

        self.assertEqual(0, int(np.count_nonzero(alpha[:, :24])))
        self.assertEqual(0, int(np.count_nonzero(alpha[:, 58:])))
        self.assertTrue(np.all(alpha[14:60, 26:56] == 255))
        positions, widths = _rising_edge_metrics(alpha, range(14, 60))
        self.assertLessEqual(float(np.percentile(widths, 95)), 1.25)
        self.assertLessEqual(
            float(np.percentile(np.abs(positions - 23.5), 95)), 0.5)

    def test_current_white_plate_veto_removes_temporal_double_heel(self):
        def frame(stem_x):
            alpha = np.zeros((180, 160), np.uint8)
            alpha[24:132, 62:98] = 255
            alpha[124:143, 58:108] = 255
            alpha[141:169, stem_x:stem_x + 2] = 255
            rgba = np.zeros((180, 160, 4), np.uint8)
            rgba[:, :, 3] = alpha
            rgba[:, :, :3][alpha > 0] = (25, 40, 75)
            return rgba

        previous = frame(58)
        current = frame(72)
        following = frame(58)
        sources = []
        for stem_x in (58, 72, 58):
            source = np.full((180, 160, 3), 255, np.uint8)
            source[24:132, 62:98] = (25, 40, 75)
            source[124:143, 58:108] = (25, 40, 75)
            source[141:169, stem_x:stem_x + 2] = (25, 40, 75)
            sources.append(source)

        repaired = motion._stabilise_segmented(
            [previous, current, following], source_frames=sources)[1]

        self.assertEqual(0, int(np.count_nonzero(repaired[145:168, 58:60, 3])))
        self.assertTrue(np.all(repaired[145:168, 72:74, 3] == 255))
        self.assertEqual(0, int(np.count_nonzero(
            repaired[:, :, 3][motion._white_plate_confidence(sources[1]) > 0.93]
        )))

    def test_source_aware_cavity_keeps_white_calf_gap_transparent(self):
        alpha = np.zeros((160, 120), np.uint8)
        alpha[10:150, 30:90] = 255
        alpha[85:115, 58:64] = 0

        source = np.full((160, 120, 3), 255, np.uint8)
        source[alpha > 0] = (45, 55, 75)
        source[104:114, 61] = (18, 24, 38)

        source_unknown = motion._fill_lower_body_alpha_holes(alpha)
        repaired = motion._fill_lower_body_alpha_holes(alpha, source)

        self.assertEqual(0, int(source_unknown[92, 60]))
        self.assertEqual(0, int(repaired[92, 60]))
        self.assertEqual(255, int(repaired[110, 61]))

    def test_pose_guided_source_recovery_restores_thin_heel_only(self):
        alpha = np.zeros((180, 160), np.uint8)
        alpha[55:137, 99:106] = 255
        alpha[132:141, 91:110] = 255
        current = np.zeros((180, 160, 4), np.uint8)
        current[:, :, 3] = alpha
        current[:, :, :3][alpha > 0] = (70, 90, 120)

        source = np.full((180, 160, 3), 255, np.uint8)
        source[alpha > 0] = (70, 90, 120)
        source[140:146, 108:110] = (20, 35, 65)

        repaired = motion._recover_source_ankles(
            current, alpha, source, _pose())

        self.assertEqual(255, int(repaired[144, 108]))
        self.assertEqual((20, 35, 65), tuple(current[144, 108, :3]))
        self.assertEqual(0, int(repaired[144, 94]))

    def test_ankle_recovery_covers_the_release_gate_outer_column(self):
        alpha = np.zeros((180, 160), np.uint8)
        alpha[55:137, 99:106] = 255
        alpha[132:141, 99:110] = 255
        current = np.zeros((180, 160, 4), np.uint8)
        current[:, :, 3] = alpha
        current[:, :, :3][alpha > 0] = (70, 90, 120)

        source = np.full((180, 160, 3), 255, np.uint8)
        source[alpha > 0] = (70, 90, 120)
        # right_ankle is x=104 and the 110px tracked body height makes x=113
        # the outer column of the 8%-wide QA corridor.  It is connected to the
        # shoe in current-source evidence, but the former 7.5% recovery box
        # stopped one pixel short and made the release gate reject the frame.
        source[136:142, 109:114] = (20, 35, 65)
        source[141:166, 112:114] = (20, 35, 65)

        repaired = motion._recover_source_ankles(
            current, alpha, source, _pose())

        self.assertGreaterEqual(int(repaired[150, 113]), 192)
        self.assertEqual((20, 35, 65), tuple(current[150, 113, :3]))

    def test_pose_guided_source_recovery_does_not_promote_pale_floor_shadow(self):
        alpha = np.zeros((180, 160), np.uint8)
        alpha[55:137, 99:106] = 255
        alpha[132:141, 91:110] = 255
        current = np.zeros((180, 160, 4), np.uint8)
        current[:, :, 3] = alpha
        current[:, :, :3][alpha > 0] = (70, 90, 120)

        source = np.full((180, 160, 3), 255, np.uint8)
        source[alpha > 0] = (70, 90, 120)
        # A compressed pale floor shadow can touch the shoe exactly like this.
        # With no strong non-plate core it is ambiguous and must remain plate;
        # authoring already forbids white/off-white footwear on a white plate.
        source[140:150, 106:111] = (232, 232, 232)

        repaired = motion._recover_source_ankles(
            current, alpha, source, _pose())

        self.assertEqual(0, int(repaired[145, 108]))
        self.assertEqual(0, int(repaired[145, 94]))

    def test_stabiliser_restores_heel_stem_but_clears_touching_floor_shadow(self):
        source, segmented = _heel_plate_fixture(
            include_shadow_alpha=True, include_stem_alpha=False)

        repaired = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source])[0]

        self.assertTrue(np.all(repaired[146:162, 109:111, 3] == 255))
        self.assertEqual(0, int(np.count_nonzero(
            repaired[164:170, 86:108, 3])))
        self.assertEqual(0, int(np.count_nonzero(
            repaired[164:170, 112:130, 3])))

    def test_final_white_plate_veto_runs_after_additive_hole_repair(self):
        source = np.full((180, 160, 3), 255, np.uint8)
        source[28:150, 62:100] = (44, 61, 104)
        alpha = np.zeros((180, 160), np.uint8)
        alpha[28:150, 62:100] = 255
        segmented = np.zeros((180, 160, 4), np.uint8)
        segmented[:, :, :3] = source
        segmented[:, :, 3] = alpha
        segmented[:, :, :3][alpha == 0] = 0

        def additive_plate_fill(_current, current_alpha, _source, _pose):
            output = current_alpha.copy()
            # Model an additive repair that accidentally paints a small piece
            # of exterior-connected white plate after the temporal veto.
            output[72:77, 38:44] = 255
            return output

        with mock.patch.object(
                motion, "_fill_face_alpha_holes",
                side_effect=additive_plate_fill):
            repaired = motion._stabilise_segmented(
                [segmented], poses=[_pose()], source_frames=[source])[0]

        self.assertEqual(0, int(np.count_nonzero(
            repaired[72:77, 38:44, 3])))
        quality = motion._source_alpha_integrity_quality(
            [repaired], [source], [_pose()])
        self.assertTrue(quality["valid"], quality)

    def test_exterior_gray_arm_waist_gap_stays_transparent(self):
        source = np.full((180, 160, 3), 255, np.uint8)
        source[34:132, 68:102] = (36, 45, 78)
        source[48:122, 51:58] = (82, 112, 168)
        # Provider compression/shading makes this genuine background gap gray,
        # while it remains connected to the exterior above and below the arm.
        source[48:122, 58:68] = (232, 232, 232)
        rgba = np.zeros((180, 160, 4), np.uint8)
        rgba[:, :, :3] = source
        rgba[34:132, 51:102, 3] = 255

        refined = motion._refine_white_matte(source, rgba)

        self.assertEqual(0, int(np.count_nonzero(
            refined[54:116, 60:66, 3])))
        self.assertTrue(np.all(refined[54:116, 52:57, 3] >= 192))
        self.assertTrue(np.all(refined[54:116, 70:96, 3] >= 192))

    def test_release_gate_rejects_plate_shadow_and_missing_heel_stem(self):
        source, good = _heel_plate_fixture()
        good_quality = motion._source_alpha_integrity_quality(
            [good], [source], [_pose()])
        self.assertTrue(good_quality["valid"], good_quality)
        self.assertEqual(0, good_quality["maximum_plate_leak_pixels"])
        self.assertGreaterEqual(good_quality["tracked_ankle_frames"], 1)

        _source, leaked = _heel_plate_fixture(include_shadow_alpha=True)
        leaked_quality = motion._source_alpha_integrity_quality(
            [leaked], [source], [_pose()])
        self.assertFalse(leaked_quality["valid"])
        self.assertGreater(leaked_quality["maximum_plate_leak_pixels"], 0)

        _source, missing = _heel_plate_fixture(include_stem_alpha=False)
        missing_quality = motion._source_alpha_integrity_quality(
            [missing], [source], [_pose()])
        self.assertFalse(missing_quality["valid"])
        self.assertIn(1, missing_quality["failed_ankle_frames"])

    def test_face_hole_repair_restores_teeth_but_not_leg_gap(self):
        alpha = np.zeros((180, 160), np.uint8)
        alpha[8:62, 52:105] = 255
        alpha[62:142, 45:112] = 255
        alpha[29:35, 73:84] = 0
        alpha[103:124, 75:82] = 0
        current = np.zeros((180, 160, 4), np.uint8)
        current[:, :, 3] = alpha
        source = np.full((180, 160, 3), 255, np.uint8)
        source[alpha > 0] = (55, 70, 105)
        source[29:35, 73:84] = (245, 245, 245)

        repaired = motion._fill_face_alpha_holes(
            current, alpha, source, _pose())

        self.assertTrue(np.all(repaired[29:35, 73:84] == 255))
        self.assertEqual((245, 245, 245), tuple(current[31, 78, :3]))
        self.assertTrue(np.all(repaired[103:124, 75:82] == 0))

    def test_stylized_eye_repair_restores_sclera_only_for_cartoon_path(self):
        source = np.full((180, 160, 3), 255, np.uint8)
        source[5:150, 45:112] = (76, 138, 216)
        alpha = np.zeros((180, 160), np.uint8)
        alpha[5:150, 45:112] = 255
        # Deliberately white illustrated eyes, bounded by opaque black ink.
        for center in ((66, 14), (90, 14)):
            cv2.circle(source, center, 6, (255, 255, 255), cv2.FILLED)
            cv2.circle(source, center, 2, (18, 18, 18), cv2.FILLED)
            cv2.circle(alpha, center, 6, 0, cv2.FILLED)
            cv2.circle(alpha, center, 2, 255, cv2.FILLED)
        # A white negative-space cavity in the lower body must stay open.
        source[104:124, 75:82] = 255
        alpha[104:124, 75:82] = 0
        segmented = np.dstack((source.copy(), alpha))
        segmented[:, :, :3][alpha == 0] = 0

        photographic = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source])[0]
        stylized = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source],
            allow_stylized=True)[0]

        self.assertEqual(0, int(photographic[14, 62, 3]))
        self.assertEqual(255, int(stylized[14, 62, 3]))
        self.assertEqual((255, 255, 255), tuple(stylized[14, 62, :3]))
        self.assertEqual(0, int(stylized[112, 78, 3]))

    def test_stylized_eye_repair_uses_source_when_matte_hole_is_exterior(self):
        """An eye opened through a coarse matte edge still uses authored ink."""
        source = np.full((180, 160, 3), 255, np.uint8)
        source[5:150, 45:112] = (76, 138, 216)
        alpha = np.zeros((180, 160), np.uint8)
        alpha[5:150, 45:112] = 255
        for center in ((66, 14), (90, 14)):
            cv2.circle(source, center, 6, (255, 255, 255), cv2.FILLED)
            cv2.circle(source, center, 2, (18, 18, 18), cv2.FILLED)
            cv2.circle(alpha, center, 6, 0, cv2.FILLED)
            cv2.circle(alpha, center, 2, 255, cv2.FILLED)
            # Connect the missing sclera to exterior alpha. RETR_CCOMP no
            # longer sees a child cavity, matching the Luffy Move regression.
            cv2.line(alpha, (center[0], 8), (center[0], 0), 0, 2)
        # A white lower-body gap must remain transparent.
        source[104:124, 75:82] = 255
        alpha[104:124, 75:82] = 0
        segmented = np.dstack((source.copy(), alpha))
        segmented[:, :, :3][alpha == 0] = 0

        photographic = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source])[0]
        stylized = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source],
            allow_stylized=True)[0]

        for center in ((66, 14), (90, 14)):
            with self.subTest(center=center):
                self.assertEqual(0, int(photographic[
                    center[1], center[0] - 4, 3]))
                self.assertEqual(255, int(stylized[
                    center[1], center[0] - 4, 3]))
                self.assertEqual(255, int(stylized[
                    center[1], center[0], 3]))
                self.assertEqual((18, 18, 18), tuple(stylized[
                    center[1], center[0], :3]))
        self.assertEqual(0, int(stylized[112, 78, 3]))

    def test_stylized_shadow_sliver_is_removed_without_photo_relaxation(self):
        """A sparse gray cast-shadow strip is stylized-only background."""
        source = np.full((180, 160, 3), 255, np.uint8)
        alpha = np.zeros((180, 160), np.uint8)
        source[30:145, 55:105] = (45, 70, 150)
        alpha[30:145, 55:105] = 255
        # Enclosed low-saturation wardrobe detail/highlight must survive.
        source[55:110, 62:68] = (205, 205, 205)
        alpha[55:110, 62:68] = 255
        # A crooked, sparse strip models the neutral wall/contact shadow in
        # Luffy Idle frame 0. It is connected to the exterior neutral plate,
        # yet darker than the normal white-background veto threshold.
        shadow_points = np.array((
            (42, 45), (38, 55), (43, 65), (39, 75),
            (44, 85), (40, 98),
        ), dtype=np.int32)
        shadow = np.zeros(alpha.shape, np.uint8)
        cv2.polylines(
            source, [shadow_points], False, (201, 201, 201), 2,
            cv2.LINE_8)
        cv2.polylines(
            shadow, [shadow_points], False, 255, 2, cv2.LINE_8)
        shadow_fringe = np.zeros(alpha.shape, np.uint8)
        cv2.polylines(
            source, [shadow_points + (4, 0)], False,
            (150, 180, 210), 1, cv2.LINE_8)
        cv2.polylines(
            shadow_fringe, [shadow_points + (4, 0)], False,
            255, 1, cv2.LINE_8)
        shadow_satellite = np.array(
            ((40, 102), (43, 105), (40, 108)), dtype=np.int32)
        cv2.polylines(
            source, [shadow_satellite], False, (201, 201, 201), 1,
            cv2.LINE_8)
        cv2.polylines(
            shadow, [shadow_satellite], False, 255, 1, cv2.LINE_8)
        alpha[(shadow > 0) | (shadow_fringe > 0)] = 160
        segmented = np.dstack((source.copy(), alpha))
        segmented[:, :, :3][alpha == 0] = 0

        photographic = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source])[0]
        stylized = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source],
            allow_stylized=True)[0]

        self.assertEqual(
            int(np.count_nonzero(shadow)),
            int(np.count_nonzero(photographic[:, :, 3][shadow > 0])))
        self.assertEqual(
            int(np.count_nonzero(shadow_fringe)),
            int(np.count_nonzero(
                photographic[:, :, 3][shadow_fringe > 0])))
        self.assertEqual(
            0, int(np.count_nonzero(stylized[:, :, 3][shadow > 0])))
        self.assertEqual(
            0, int(np.count_nonzero(
                stylized[:, :, 3][shadow_fringe > 0])))
        self.assertTrue(np.all(stylized[55:110, 62:68, 3] == 255))
        self.assertTrue(np.all(
            stylized[55:110, 62:68, :3] == (205, 205, 205)))

    def test_stylized_head_plate_wedge_does_not_remove_solid_accessory(self):
        source = np.full((180, 160, 3), 255, np.uint8)
        alpha = np.zeros((180, 160), np.uint8)
        source[5:150, 60:97] = (76, 138, 216)
        alpha[5:150, 60:97] = 255
        # Plate/object antialias around the same wedge carries more colour
        # than the neutral core. It is removable only after the core proves
        # the topology; a blanket saturation relaxation would be unsafe.
        fringe_points = np.array(
            ((60, 14), (61, 15), (60, 16), (61, 17)), dtype=np.int32)
        fringe = np.zeros(alpha.shape, np.uint8)
        cv2.polylines(
            source, [fringe_points], False, (150, 180, 210), 1,
            cv2.LINE_8)
        cv2.polylines(
            fringe, [fringe_points], False, 255, 1, cv2.LINE_8)
        # Sparse neutral plate caught within a black cartoon hair spike.
        wedge_points = np.array(
            ((60, 17), (65, 20), (61, 23), (65, 26)), dtype=np.int32)
        wedge = np.zeros(alpha.shape, np.uint8)
        cv2.polylines(
            source, [wedge_points], False, (190, 190, 190), 1,
            cv2.LINE_8)
        cv2.polylines(
            wedge, [wedge_points], False, 255, 1, cv2.LINE_8)
        # A compact gray head accessory touches the plate but is solid, not a
        # sparse triangular gap, and must remain authored foreground.
        source[17:26, 92:97] = (190, 190, 190)
        segmented = np.dstack((source.copy(), alpha))

        photographic = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source])[0]
        stylized = motion._stabilise_segmented(
            [segmented], poses=[_pose()], source_frames=[source],
            allow_stylized=True)[0]

        self.assertTrue(np.all(photographic[:, :, 3][wedge > 0] == 255))
        self.assertEqual(
            0, int(np.count_nonzero(stylized[:, :, 3][wedge > 0])))
        self.assertTrue(np.all(photographic[:, :, 3][fringe > 0] == 255))
        self.assertEqual(
            0, int(np.count_nonzero(stylized[:, :, 3][fringe > 0])))
        self.assertTrue(np.all(stylized[17:26, 92:97, 3] == 255))
        self.assertTrue(np.all(
            stylized[17:26, 92:97, :3] == (190, 190, 190)))

    def test_full_stabiliser_preserves_calf_gap_and_repairs_real_dropout(self):
        alpha = np.zeros((160, 120), np.uint8)
        alpha[10:150, 30:90] = 255
        alpha[96:126, 56:63] = 0
        source = np.full((160, 120, 3), 255, np.uint8)
        source[alpha > 0] = (35, 60, 120)
        # One dark source-supported strand inside an otherwise white cavity
        # represents a real thin structure that the semantic mask omitted.
        source[111:125, 61] = (18, 24, 38)
        rgba = np.dstack((source.copy(), alpha))

        repaired = motion._stabilise_segmented(
            [rgba], source_frames=[source])[0]

        self.assertEqual(0, int(repaired[104, 59, 3]))
        self.assertGreaterEqual(int(repaired[118, 61, 3]), 24)
        self.assertEqual((18, 24, 38), tuple(repaired[118, 61, :3]))

    def test_segment_frames_uses_loose_vision_mask_and_one_final_cleanup(self):
        frame = np.full((64, 48, 3), 255, np.uint8)
        frame[12:58, 18:30] = (40, 55, 90)
        rgba = np.dstack((frame, np.where(
            np.any(frame < 240, axis=2), 255, 0).astype(np.uint8)))
        pose = _pose(left_ankle=(20, 52), right_ankle=(28, 52))
        render_calls = []

        def render(_source, destination, **kwargs):
            render_calls.append(kwargs)
            cv2.imwrite(destination, rgba)
            with open(kwargs["pose_destination"], "w") as handle:
                json.dump(pose, handle)
            return {"ok": True}

        def stabilise(
                segmented, poses, source_frames=None, allow_stylized=False):
            self.assertIs(frame, source_frames[0])
            self.assertFalse(allow_stylized)
            return segmented

        with tempfile.TemporaryDirectory() as workspace:
            with (
                mock.patch.object(motion, "_is_green_screen", return_value=False),
                mock.patch.object(motion, "_rvm_matte", return_value=None),
                mock.patch.object(motion.cutout, "render", side_effect=render),
                mock.patch.object(
                    motion, "_stabilise_segmented", side_effect=stabilise),
                mock.patch.object(
                    motion.cutout, "_decontaminate_edges",
                    side_effect=lambda image: image) as decontaminate,
                mock.patch.object(
                    motion, "_color_fidelity_quality", return_value={"valid": True}),
            ):
                repaired, _poses, method, _quality = motion._segment_frames(
                    [frame], workspace, lambda _message: None)

        self.assertEqual("macos-vision-person-segmentation", method)
        self.assertEqual(1, len(repaired))
        self.assertIs(False, render_calls[0]["tight"])
        self.assertEqual(1, decontaminate.call_count)

    def test_segment_frames_keeps_source_authority_with_rvm(self):
        frame = np.full((64, 48, 3), 255, np.uint8)
        frame[12:58, 18:30] = (40, 55, 90)
        rgba = np.dstack((frame, np.where(
            np.any(frame < 240, axis=2), 255, 0).astype(np.uint8)))
        pose = _pose(left_ankle=(20, 52), right_ankle=(28, 52))

        def render(_source, destination, **kwargs):
            cv2.imwrite(destination, rgba)
            with open(kwargs["pose_destination"], "w") as handle:
                json.dump(pose, handle)
            return {"ok": True}

        def stabilise(
                segmented, poses, source_frames=None, allow_stylized=False):
            self.assertIs(frame, source_frames[0])
            self.assertFalse(allow_stylized)
            return segmented

        with tempfile.TemporaryDirectory() as workspace:
            with (
                mock.patch.object(motion, "_is_green_screen", return_value=False),
                mock.patch.object(motion, "_rvm_matte", return_value=[rgba]),
                mock.patch.object(motion.cutout, "render", side_effect=render),
                mock.patch.object(
                    motion, "_stabilise_segmented", side_effect=stabilise),
                mock.patch.object(
                    motion, "_color_fidelity_quality", return_value={"valid": True}),
            ):
                _repaired, _poses, method, _quality = motion._segment_frames(
                    [frame], workspace, lambda _message: None)

        self.assertEqual("robust-video-matting", method)

    def test_stabiliser_rejects_mismatched_source_sequence(self):
        rgba = np.zeros((16, 16, 4), np.uint8)
        with self.assertRaisesRegex(ValueError, "frame counts differ"):
            motion._stabilise_segmented([rgba], source_frames=[])

    def test_runtime_publish_adds_walk_hevc_without_changing_desktop_to_video(self):
        with tempfile.TemporaryDirectory() as avatar_dir, \
                tempfile.TemporaryDirectory() as runtime_dir:
            motion_dir = os.path.join(avatar_dir, "motion")
            os.makedirs(motion_dir)
            cv2.imwrite(
                os.path.join(motion_dir, "walk-0.png"),
                np.zeros((4, 4, 4), np.uint8),
            )
            with open(os.path.join(motion_dir, "walk-alpha.mov"), "wb") as handle:
                handle.write(b"prores-alpha")
            with open(os.path.join(motion_dir, "motion.json"), "w") as handle:
                json.dump({
                    "v": motion.MOTION_VERSION,
                    "walk": {
                        "fps": 24,
                        "frames": 1,
                        "sheets": [{
                            "image": "walk-0.png", "first": 0,
                            "count": 1, "columns": 1, "rows": 1,
                        }],
                        "alpha_video": "walk-alpha.mov",
                        "alpha_stream": None,
                    },
                }, handle)

            def encode(_source, destination, _log):
                with open(destination, "wb") as handle:
                    handle.write(b"hevc-alpha")
                return True

            with mock.patch.object(
                    runtime_export, "_hevc_alpha_for_web",
                    side_effect=encode) as encoder:
                published = runtime_export._publish_motion(
                    avatar_dir, runtime_dir, lambda _message: None)

            self.assertEqual(1, encoder.call_count)
            self.assertEqual(
                "assets/motion-walk.mov",
                published["walk"]["alpha_stream_hevc"],
            )
            self.assertNotIn("alpha_stream", published["walk"])
            self.assertTrue(os.path.isfile(
                os.path.join(runtime_dir, "motion-walk.mov")))


if __name__ == "__main__":
    unittest.main()
