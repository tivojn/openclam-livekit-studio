"""Regressions for source-authoritative static full-body alpha cleanup."""

import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, body_alpha


def _rgba(source, alpha):
    image = np.zeros(source.shape[:2] + (4,), np.uint8)
    image[:, :, :3] = source
    image[:, :, 3] = alpha
    image[:, :, :3][alpha == 0] = 0
    return image


def _body_fixture():
    source = np.full((220, 180, 3), 255, np.uint8)
    alpha = np.zeros(source.shape[:2], np.uint8)
    # Fuchsia torso plus pale, genuinely chromatic arms and legs.
    source[35:130, 66:114] = (175, 20, 235)
    alpha[35:130, 66:114] = 255
    source[42:133, 42:56] = (198, 218, 244)
    alpha[42:133, 42:56] = 255
    source[42:133, 124:138] = (198, 218, 244)
    alpha[42:133, 124:138] = 255
    source[122:196, 72:84] = (198, 218, 244)
    alpha[122:196, 72:84] = 255
    source[122:196, 96:108] = (198, 218, 244)
    alpha[122:196, 96:108] = 255
    return source, alpha


def _stylized_eye_fixture():
    """Flat-colour body with one shaded-white cartoon sclera."""
    source = np.full((240, 160, 3), 255, np.uint8)
    alpha = np.zeros(source.shape[:2], np.uint8)
    source[20:95, 45:115] = (80, 125, 220)
    alpha[20:95, 45:115] = 255
    source[90:220, 60:100] = (35, 40, 210)
    alpha[90:220, 60:100] = 255
    source[45:75, 55:90] = (232, 239, 244)
    source[52:68, 62:83] = 250
    replacement_head = np.zeros(alpha.shape, dtype=bool)
    replacement_head[20:95, 45:115] = True
    return source, alpha, replacement_head


class BodyAlphaQualityTests(unittest.TestCase):
    def test_stylized_neutral_eye_is_not_a_detached_shadow(self):
        source, alpha, replacement_head = _stylized_eye_fixture()
        # A narrow neutral eyelid/pupil detail is surrounded by a pale sclera.
        # It has the exact detached, elongated geometry used by the general
        # wall/shadow audit, but the complete region will be replaced by the
        # already validated canonical cartoon head at runtime.
        source[55:60, 68:77] = (180, 180, 180)

        strict = body_alpha._floor_shadow(source, _rgba(source, alpha))
        self.assertTrue(any(
            item["kind"] == "detached-neutral"
            for item in strict["components"]))

        refined, report = body_alpha.refine(
            source, _rgba(source, alpha),
            replacement_head_mask=replacement_head)

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])
        np.testing.assert_array_equal(alpha, refined[:, :, 3])

    def test_stylized_eye_inside_canonical_head_replacement_is_allowed(self):
        source, alpha, replacement_head = _stylized_eye_fixture()

        refined, report = body_alpha.refine(
            source, _rgba(source, alpha),
            replacement_head_mask=replacement_head)

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["ambiguous_white_subject_components"])
        self.assertTrue(any(
            item["kind"] == "canonical-head-replacement"
            and item["bounds"] == [62, 52, 21, 16]
            for item in report["protected_white_detail_components"]))
        np.testing.assert_array_equal(alpha, refined[:, :, 3])

    def test_stylized_white_clothing_outside_replaced_head_still_rejects(self):
        source, alpha, replacement_head = _stylized_eye_fixture()
        source[105:170, 65:95] = (232, 239, 244)
        source[120:155, 72:88] = 250

        _refined, report = body_alpha.refine(
            source, _rgba(source, alpha),
            replacement_head_mask=replacement_head)

        self.assertFalse(report["valid"], report)
        self.assertEqual(
            [[72, 120, 16, 35]],
            [item["bounds"]
             for item in report["ambiguous_white_subject_components"]])
        self.assertIn("non-white wardrobe", report["reason"])

    def test_photorealistic_path_does_not_exempt_the_same_white_detail(self):
        source, alpha, _replacement_head = _stylized_eye_fixture()

        _refined, report = body_alpha.refine(
            source, _rgba(source, alpha))

        self.assertFalse(report["valid"], report)
        self.assertEqual(
            [[62, 52, 21, 16]],
            [item["bounds"]
             for item in report["ambiguous_white_subject_components"]])
        self.assertFalse(any(
            item["kind"] == "canonical-head-replacement"
            for item in report["protected_white_detail_components"]))

    def test_exterior_arm_waist_plate_is_removed_without_touching_skin(self):
        source, alpha = _body_fixture()
        # Vision falsely bridges the pure-white opening from arm to waist.
        alpha[58:118, 56:66] = 255
        original_skin = alpha[42:133, 42:56].copy()

        raw = body_alpha.quality(source, _rgba(source, alpha))
        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(raw["valid"])
        self.assertTrue(raw["exterior_plate_components"])
        self.assertTrue(report["valid"], report)
        self.assertEqual(0, int(np.count_nonzero(refined[62:114, 58:64, 3])))
        self.assertEqual(0, int(np.count_nonzero(
            body_alpha._strict_plate(source) & (refined[:, :, 3] >= 24))))
        np.testing.assert_array_equal(original_skin, refined[42:133, 42:56, 3])
        self.assertEqual(0, report["lost_source_subject_pixels"])

    def test_enclosed_white_pump_opening_is_removed_but_heel_stem_survives(self):
        source, alpha = _body_fixture()
        # Black pump and a one-pixel stiletto stem.  The semantic matte fills
        # the white opening under the arch as if it were solid anatomy.
        source[180:192, 92:140] = (18, 20, 24)
        source[164:181, 92:104] = (18, 20, 24)
        source[192:211, 96:97] = (12, 14, 18)
        alpha[164:192, 92:140] = 255
        alpha[192:211, 96:97] = 255
        source[181:191, 104:130] = 255
        alpha[181:191, 104:130] = 255

        raw = body_alpha.quality(source, _rgba(source, alpha))
        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(raw["valid"])
        self.assertTrue(raw["enclosed_plate_components"])
        self.assertTrue(report["valid"], report)
        self.assertEqual(0, int(np.count_nonzero(refined[182:190, 106:128, 3])))
        self.assertEqual(19, int(np.count_nonzero(refined[192:211, 96, 3])))
        self.assertEqual(0, report["lost_source_subject_pixels"])

    def test_shaded_white_fabric_and_pale_skin_are_not_erased(self):
        source, alpha = _body_fixture()
        # A pure highlight is enclosed by shaded warm-white cloth.  This is a
        # real garment, not plate: its opaque near-white fabric ring protects
        # the exact-white centre from the enclosed-gap rule.
        source[58:112, 72:108] = (232, 239, 244)
        source[70:100, 80:100] = 250
        alpha[58:112, 72:108] = 255
        before = alpha.copy()

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"], report)
        self.assertTrue(report["ambiguous_white_subject_components"])
        np.testing.assert_array_equal(before, refined[:, :, 3])
        self.assertEqual(0, report["lost_source_subject_pixels"])

    def test_white_sleeve_touching_plate_is_not_erased(self):
        source, alpha = _body_fixture()
        # A warm-white sleeve reaches the outer silhouette. Its exact-white
        # highlight is RGB-connected to the pure-white plate, but the opaque
        # shaded fabric around it proves that it belongs to the garment.
        source[48:120, 24:56] = (228, 236, 242)
        source[62:106, 24:45] = 250
        alpha[48:120, 24:56] = 255
        # Connect the sleeve to the torso so its alpha component contains
        # source-confirmed coloured anatomy, as a real garment would.
        source[48:65, 52:76] = (228, 236, 242)
        alpha[48:65, 52:76] = 255
        before = alpha.copy()

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"], report)
        self.assertTrue(report["ambiguous_white_subject_components"])
        np.testing.assert_array_equal(before, refined[:, :, 3])
        self.assertEqual(0, report["removed_plate_pixels"])
        self.assertEqual(0, report["lost_source_subject_pixels"])

    def test_plate_connected_gray_fringe_is_removed_with_white_core(self):
        source, alpha = _body_fixture()
        # Widen this synthetic arm/body opening so its neutral middle is not
        # within the three-pixel preservation collar of either real limb.
        source[42:133, 42:56] = 255
        alpha[42:133, 42:56] = 0
        source[42:133, 24:38] = (198, 218, 244)
        alpha[42:133, 24:38] = 255
        alpha[58:118, 38:66] = 255
        # Provider resampling/shadow grades the otherwise proven plate gap to
        # neutral grey.  It remains connected to the strict-white core.
        source[72:106, 48:56] = (230, 231, 232)

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertGreater(report["removed_plate_fringe_pixels"], 0)
        self.assertEqual(0, int(np.count_nonzero(refined[60:114, 42:62, 3])))

    def test_fragmented_near_plate_edge_zipper_is_fully_removed(self):
        source, alpha = _body_fixture()
        # Isolated resampling pixels have no exact-white seed or mutual
        # connectivity, but each is still source-proven near-white plate.
        coordinates = [(y, 60 + (y % 3)) for y in range(58, 118, 3)]
        for index, (y, x) in enumerate(coordinates):
            source[y, x] = (232, 233, 234)
            alpha[y, x] = 18 if index % 2 else 120

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertEqual(0, report["residual_near_plate_pixels"])
        self.assertEqual(0, report["visible_near_plate_edge_pixels"])
        self.assertEqual(0, sum(
            int(refined[y, x, 3] > 0) for y, x in coordinates))
        self.assertGreater(report["removed_faint_plate_pixels"], 0)

    def test_chromatic_white_matte_is_unmatted_without_alpha_erosion(self):
        source = np.full((150, 130, 3), 255, np.uint8)
        alpha = np.zeros((150, 130), np.uint8)
        foreground = np.array((175, 20, 235), np.float32)
        source[25:125, 48:88] = foreground.astype(np.uint8)
        alpha[25:125, 48:88] = 255
        # Opaque-source RGB was already blended against the white generation
        # plate, while Vision supplies a separate semantic alpha.
        matte_color = np.rint(foreground * 0.40 + 255.0 * 0.60).astype(np.uint8)
        source[35:115, 45:48] = matte_color
        alpha[35:115, 45:48] = 180
        before_alpha = alpha.copy()

        raw = body_alpha.quality(source, _rgba(source, alpha))
        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(raw["valid"])
        self.assertGreaterEqual(raw["white_matte_edge_pixels"], 200)
        self.assertTrue(report["valid"], report)
        self.assertEqual(0, report["white_matte_edge_pixels"])
        self.assertGreaterEqual(
            report["decontaminated_white_matte_pixels"], 200)
        np.testing.assert_array_equal(before_alpha, refined[:, :, 3])
        np.testing.assert_array_equal(
            np.broadcast_to(foreground.astype(np.uint8), (80, 3, 3)),
            refined[35:115, 45:48, :3])
        dark = np.float32((27, 27, 27))
        amount = alpha[35:115, 45:48, None].astype(np.float32) / 255.0
        before_composite = source[35:115, 45:48].astype(np.float32) * amount \
            + dark * (1.0 - amount)
        after_composite = refined[35:115, 45:48, :3].astype(np.float32) * amount \
            + dark * (1.0 - amount)
        self.assertLess(
            float(np.mean(after_composite[:, :, 1])),
            float(np.mean(before_composite[:, :, 1])) - 80.0)

    def test_detached_floor_shadow_hard_rejects_instead_of_cutting_anatomy(self):
        source, alpha = _body_fixture()
        source[205:211, 55:125] = (165, 165, 165)
        alpha[205:211, 55:125] = 220
        image = _rgba(source, alpha)

        refined, report = body_alpha.refine(source, image)

        self.assertFalse(report["valid"])
        self.assertTrue(report["floor_shadow_components"])
        self.assertIn("floor, wall, or contact shadow", report["reason"])
        np.testing.assert_array_equal(
            image[205:211, 55:125, 3], refined[205:211, 55:125, 3])

    def test_preservation_audit_rejects_a_lost_dark_heel_pixel(self):
        source, alpha = _body_fixture()
        source[190:214, 118:119] = (12, 14, 18)
        alpha[190:214, 118:119] = 255
        damaged = _rgba(source, alpha)
        damaged[198, 118, 3] = 0

        report = body_alpha.quality(
            source, damaged, baseline_alpha=alpha)

        self.assertFalse(report["valid"])
        self.assertEqual(1, report["lost_source_subject_pixels"])

    def test_near_plate_growth_cannot_flood_through_charcoal(self):
        source = np.full((120, 120, 3), 255, np.uint8)
        alpha = np.zeros((120, 120), np.uint8)
        source[30:90, 40:80] = (90, 92, 93)
        alpha[30:90, 40:80] = 255
        # Exterior pure-white false alpha touches the legal charcoal subject.
        alpha[55:65, 0:40] = 255

        refined, _report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertEqual(2400, int(np.count_nonzero(
            refined[30:90, 40:80, 3])))

    def test_small_white_patent_highlight_is_preserved(self):
        source = np.full((100, 100, 3), 255, np.uint8)
        alpha = np.zeros((100, 100), np.uint8)
        source[60:90, 30:80] = (20, 20, 20)
        alpha[60:90, 30:80] = 255
        source[70:76, 48:54] = 255

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertEqual(36, int(np.count_nonzero(
            refined[70:76, 48:54, 3])))
        self.assertTrue(report["protected_white_detail_components"])

    def test_compact_white_and_near_white_skin_highlights_are_preserved(self):
        for highlight_color in (255, (236, 237, 238)):
            with self.subTest(highlight_color=highlight_color):
                source, alpha = _body_fixture()
                source[80:83, 48:51] = highlight_color

                refined, report = body_alpha.refine(
                    source, _rgba(source, alpha))

                self.assertTrue(report["valid"], report)
                self.assertEqual(9, int(np.count_nonzero(
                    refined[80:83, 48:51, 3])))
                self.assertTrue(any(
                    item["kind"] == "skin-specular"
                    for item in report["protected_white_detail_components"]))

    def test_skin_highlight_loss_is_caught_by_preservation_audit(self):
        for highlight_color in (255, (236, 237, 238)):
            with self.subTest(highlight_color=highlight_color):
                source, alpha = _body_fixture()
                source[80:83, 48:51] = highlight_color
                damaged = _rgba(source, alpha)
                damaged[80:83, 48:51, 3] = 0

                report = body_alpha.quality(
                    source, damaged, baseline_alpha=alpha)

                self.assertFalse(report["valid"])
                self.assertEqual(9, report["lost_source_subject_pixels"])

    def test_large_irregular_patent_reflection_is_preserved(self):
        source = np.full((130, 130, 3), 255, np.uint8)
        alpha = np.zeros((130, 130), np.uint8)
        source[55:112, 28:102] = (18, 20, 24)
        alpha[55:112, 28:102] = 255
        highlight = np.zeros(alpha.shape, np.uint8)
        cv2.ellipse(highlight, (58, 80), (6, 10), 12, 0, 360, 1, -1)
        highlight = highlight.astype(bool)
        source[highlight] = (236, 237, 238)
        strict_core = np.zeros(alpha.shape, np.uint8)
        cv2.ellipse(strict_core, (57, 77), (2, 3), 12, 0, 360, 1, -1)
        source[strict_core.astype(bool)] = 250

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertEqual(
            int(np.count_nonzero(highlight)),
            int(np.count_nonzero(refined[:, :, 3][highlight])))
        self.assertTrue(any(
            item["kind"] == "dark-specular"
            and item["visible_pixels"] > 64
            for item in report["protected_white_detail_components"]))

    def test_gray_provider_plate_is_hard_rejected(self):
        source = np.full((160, 120, 3), 235, np.uint8)
        alpha = np.zeros((160, 120), np.uint8)
        source[20:145, 45:75] = (170, 20, 235)
        alpha[20:145, 45:75] = 255
        alpha[60:120, 30:45] = 255

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["available"])
        self.assertFalse(report["valid"])
        self.assertIn("pure-white plate", report["reason"])

    def test_gray_halo_bridge_is_repaired_not_mistaken_for_white_fabric(self):
        source = np.full((140, 140, 3), 255, np.uint8)
        alpha = np.zeros((140, 140), np.uint8)
        source[20:125, 30:50] = (190, 215, 244)
        alpha[20:125, 30:50] = 255
        source[20:125, 90:110] = (180, 20, 235)
        alpha[20:125, 90:110] = 255
        source[45:105, 55:85] = (230, 230, 230)
        alpha[45:105, 55:85] = 255
        source[52:98, 62:78] = 250

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertEqual(0, int(np.count_nonzero(
            refined[45:105, 55:85, 3])))

    def test_contact_shadow_above_stiletto_tip_is_rejected(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:195, 75:105] = (160, 30, 230)
        alpha[20:195, 75:105] = 255
        source[190:221, 80:82] = (15, 15, 15)
        alpha[190:221, 80:82] = 255
        source[198:204, 65:145] = (165, 165, 165)
        alpha[198:204, 65:145] = 200

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"])
        self.assertEqual(
            "floor-contact", report["floor_shadow_components"][0]["kind"])

    def test_vertical_wall_contact_shadow_is_rejected(self):
        source = np.full((220, 180, 3), 255, np.uint8)
        alpha = np.zeros((220, 180), np.uint8)
        source[30:200, 70:110] = (160, 30, 230)
        alpha[30:200, 70:110] = 255
        source[40:140, 110:120] = (180, 180, 180)
        alpha[40:140, 110:120] = 180

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"])
        self.assertEqual(
            "wall-contact", report["floor_shadow_components"][0]["kind"])

    def test_smooth_gradient_wall_shadow_is_rejected(self):
        source = np.full((220, 180, 3), 255, np.uint8)
        alpha = np.zeros((220, 180), np.uint8)
        source[30:200, 70:110] = (160, 30, 230)
        alpha[30:200, 70:110] = 255
        for offset in range(100):
            value = 130 + int(offset * 0.9)
            source[40 + offset, 110:120] = value
        alpha[40:140, 110:120] = 180

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"])
        self.assertEqual(
            "wall-contact", report["floor_shadow_components"][0]["kind"])

    def test_opaque_gray_garment_shading_is_not_a_wall_shadow(self):
        source = np.full((220, 180, 3), 255, np.uint8)
        alpha = np.zeros((220, 180), np.uint8)
        source[30:200, 70:110] = (160, 30, 230)
        alpha[30:200, 70:110] = 255
        for offset in range(100):
            value = 130 + int(offset * 0.9)
            source[40 + offset, 110:120] = value
        alpha[40:140, 110:120] = 255

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])

    def test_verified_stylized_opaque_detached_cuff_is_not_a_shadow(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:220, 75:105] = (40, 45, 205)
        alpha[20:220, 75:105] = 255
        # A 10x5 rolled-cuff highlight is detached in low-chroma colour space
        # but fully opaque and well above the floor band. This reproduces the
        # retained 3D Luffy side component [570, 980, 10, 5].
        source[100:105, 50:60] = (82, 82, 82)
        alpha[100:105, 50:60] = 255

        _refined, report = body_alpha.refine(
            source, _rgba(source, alpha), verified_stylized=True)

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])

    def test_photo_path_still_rejects_same_opaque_detached_component(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:220, 75:105] = (40, 45, 205)
        alpha[20:220, 75:105] = 255
        source[100:105, 50:60] = (82, 82, 82)
        alpha[100:105, 50:60] = 255

        _refined, report = body_alpha.refine(
            source, _rgba(source, alpha))

        self.assertFalse(report["valid"], report)
        self.assertEqual(
            "detached-neutral",
            report["floor_shadow_components"][0]["kind"])

    def test_broad_translucent_shadow_directly_under_pump_is_rejected(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:180, 75:105] = (160, 30, 230)
        alpha[20:180, 75:105] = 255
        source[180:192, 75:95] = (195, 215, 244)
        alpha[180:192, 75:95] = 255
        source[190:198, 58:125] = (18, 20, 24)
        alpha[190:198, 58:125] = 255
        source[198:204, 55:132] = (165, 165, 165)
        alpha[198:204, 55:132] = 180

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"])
        self.assertEqual(
            "floor-contact", report["floor_shadow_components"][0]["kind"])

    def test_dark_fuzzy_shadow_merged_with_black_pump_is_rejected(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:180, 75:105] = (160, 30, 230)
        alpha[20:180, 75:105] = 255
        source[180:198, 58:125] = (18, 20, 24)
        alpha[180:198, 58:125] = 255
        # Dark, low-alpha smear extends several pixels below the solid sole.
        source[198:206, 72:128] = (42, 43, 44)
        alpha[198:206, 72:128] = 82

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertFalse(report["valid"])
        self.assertTrue(any(
            item["kind"] == "fuzzy-floor-contact"
            for item in report["floor_shadow_components"]))

    def test_two_pixel_black_pump_antialias_is_not_a_fuzzy_shadow(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:180, 75:105] = (160, 30, 230)
        alpha[20:180, 75:105] = 255
        source[180:198, 58:125] = (18, 20, 24)
        alpha[180:198, 58:125] = 255
        source[198:200, 58:125] = (28, 29, 30)
        alpha[198:200, 58:125] = 96

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])

    def test_gray_loafer_with_broad_foot_attachment_is_not_a_shadow(self):
        source = np.full((240, 180, 3), 255, np.uint8)
        alpha = np.zeros((240, 180), np.uint8)
        source[20:195, 75:105] = (160, 30, 230)
        alpha[20:195, 75:105] = 255
        source[190:198, 58:122] = (105, 106, 107)
        alpha[190:198, 58:122] = 255

        _refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])

    def test_compact_opaque_pale_flare_beneath_black_pump_is_rejected(self):
        source = np.full((260, 200, 3), 255, np.uint8)
        alpha = np.zeros((260, 200), np.uint8)
        source[20:205, 91:109] = (165, 35, 225)
        alpha[20:205, 91:109] = 255
        # Preserve a black pump and its one-pixel stiletto stem.
        cv2.rectangle(source, (73, 198), (145, 218), (18, 20, 24), -1)
        cv2.rectangle(alpha, (73, 198), (145, 218), 255, -1)
        source[205:242, 73:74] = (12, 14, 18)
        alpha[205:242, 73:74] = 255
        # Vision falsely retains a compact opaque floor reflection.  Its pale,
        # triangular source pixels are exterior-exposed yet touch the black
        # outsole, matching the real Cleo side-plate regression.
        flare = np.zeros(alpha.shape, np.uint8)
        cv2.fillConvexPoly(
            flare, np.array(((76, 216), (112, 216), (101, 246))), 1)
        flare = flare.astype(bool)
        source[flare] = (212, 213, 214)
        alpha[flare] = 252
        image = _rgba(source, alpha)

        refined, report = body_alpha.refine(source, image)

        self.assertFalse(report["valid"])
        self.assertTrue(any(
            item["kind"] == "pale-shoe-flare"
            for item in report["floor_shadow_components"]))
        self.assertIn(
            "opaque pale floor/shoe flare remains beneath footwear",
            report["reason"])
        # This gate rejects for regeneration; it must never invent a cut that
        # can consume real black footwear or a fine heel stem.
        np.testing.assert_array_equal(
            image[198:219, 73:146, 3], refined[198:219, 73:146, 3])
        np.testing.assert_array_equal(
            image[205:242, 73:74, 3], refined[205:242, 73:74, 3])

    def test_micro_opaque_pale_flare_beneath_black_pump_is_rejected(self):
        source = np.full((260, 200, 3), 255, np.uint8)
        alpha = np.zeros((260, 200), np.uint8)
        source[20:205, 91:109] = (165, 35, 225)
        alpha[20:205, 91:109] = 255
        cv2.rectangle(source, (73, 198), (145, 218), (18, 20, 24), -1)
        cv2.rectangle(alpha, (73, 198), (145, 218), 255, -1)
        source[205:242, 73:74] = (12, 14, 18)
        alpha[205:242, 73:74] = 255
        # Sixty mostly opaque pixels remain too material to tolerate, but the
        # narrow width keeps this below the macro geometry threshold and
        # therefore exercises the eased micro hard gate.
        source[218:228, 78:84] = (212, 213, 214)
        alpha[218:228, 78:84] = 240
        image = _rgba(source, alpha)

        refined, report = body_alpha.refine(source, image)

        self.assertFalse(report["valid"])
        micro_flares = [
            item for item in report["floor_shadow_components"]
            if item["kind"] == "pale-shoe-flare"
            and item["scale"] == "micro"
        ]
        self.assertEqual(1, len(micro_flares), report)
        self.assertEqual([78, 218, 6, 10], micro_flares[0]["bounds"])
        self.assertLess(micro_flares[0]["visible_pixels"], 64)
        # Rejection never edits either the flare or the one-pixel heel stem.
        np.testing.assert_array_equal(
            image[218:228, 78:84, 3], refined[218:228, 78:84, 3])
        np.testing.assert_array_equal(
            image[205:242, 73:74, 3], refined[205:242, 73:74, 3])

    def test_sub_runtime_pixel_pale_contact_fleck_is_tolerated(self):
        source = np.full((260, 200, 3), 255, np.uint8)
        alpha = np.zeros((260, 200), np.uint8)
        source[20:205, 91:109] = (165, 35, 225)
        alpha[20:205, 91:109] = 255
        cv2.rectangle(source, (73, 198), (145, 218), (18, 20, 24), -1)
        cv2.rectangle(alpha, (73, 198), (145, 218), 255, -1)
        source[205:242, 73:74] = (12, 14, 18)
        alpha[205:242, 73:74] = 255
        source[218:225, 78:84] = (212, 213, 214)
        alpha[218:225, 78:84] = 240

        _refined, report = body_alpha.refine(
            source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])

    def test_compact_patent_highlight_at_outsole_edge_is_valid(self):
        source = np.full((260, 200, 3), 255, np.uint8)
        alpha = np.zeros((260, 200), np.uint8)
        source[20:205, 91:109] = (165, 35, 225)
        alpha[20:205, 91:109] = 255
        cv2.rectangle(source, (62, 196), (146, 230), (18, 20, 24), -1)
        cv2.rectangle(alpha, (62, 196), (146, 230), 255, -1)
        # Same 42 px and compact geometry as the regression, but this real
        # patent reflection is embedded in the outsole and only touches the
        # lower silhouette. Most of its ring is dark shoe, not white plate.
        source[224:231, 94:100] = (212, 213, 214)

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertFalse(report["floor_shadow_components"])
        self.assertEqual(42, int(np.count_nonzero(
            refined[224:231, 94:100, 3])))

    def test_bottom_patent_highlight_enclosed_by_black_pump_is_valid(self):
        source = np.full((260, 200, 3), 255, np.uint8)
        alpha = np.zeros((260, 200), np.uint8)
        source[20:205, 91:109] = (165, 35, 225)
        alpha[20:205, 91:109] = 255
        cv2.rectangle(source, (62, 196), (146, 230), (18, 20, 24), -1)
        cv2.rectangle(alpha, (62, 196), (146, 230), 255, -1)
        highlight = np.zeros(alpha.shape, np.uint8)
        cv2.ellipse(highlight, (103, 213), (9, 6), 0, 0, 360, 1, -1)
        highlight = highlight.astype(bool)
        source[highlight] = (236, 237, 238)

        refined, report = body_alpha.refine(source, _rgba(source, alpha))

        self.assertTrue(report["valid"], report)
        self.assertEqual(
            int(np.count_nonzero(highlight)),
            int(np.count_nonzero(refined[:, :, 3][highlight])))

    def test_component_records_do_not_retain_full_frame_masks(self):
        mask = np.zeros((128, 128), np.uint8)
        mask[::3, ::3] = 1
        alpha = np.full(mask.shape, 255, np.uint8)

        _labels, records = body_alpha._component_records(mask, alpha)

        self.assertGreater(len(records), 1000)
        for record in records:
            self.assertFalse(any(
                isinstance(value, np.ndarray) for value in record.values()))

    def test_fragmented_highlight_scan_never_materialises_full_frame_records(self):
        source = np.full((420, 420, 3), 255, np.uint8)
        alpha = np.zeros((420, 420), np.uint8)
        alpha[2::6, 2::6] = 120

        with mock.patch.object(
                body_alpha, "_record_mask",
                side_effect=AssertionError("full-frame component allocated")):
            _labels, protected, records = (
                body_alpha._compact_supported_highlights(source, alpha))

        self.assertEqual(0, int(np.count_nonzero(protected)))
        self.assertFalse(records)

    def test_body_prompts_pin_shadowless_gaps_and_fine_heels(self):
        options = {
            "style": "editorial",
            "pose": "relaxed",
            "presentation": "feminine",
            "medium": "photograph",
        }
        for prompt in (
                body._prompt(options, "front"),
                body._prompt(options, "side"),
                body._prompt(options, "back"),
                body._edit_prompt("Change the dress to scarlet", "front")):
            lowered = prompt.lower()
            self.assertIn("uniform rgb-255 white continues behind and beneath", lowered)
            self.assertIn("the figure casts nothing", lowered)
            self.assertIn("white touches every outsole edge", lowered)
            self.assertIn("both sides of each heel stem", lowered)

    def test_alpha_rejection_invalidates_cached_turnaround(self):
        config = {"provider": "openai", "model": "gpt-image-2", "api_key": "x"}
        public = {
            "name": "openai", "title": "OpenAI Images", "model": "gpt-image-2",
            "route": "direct:openai", "direct": True,
        }

        def generate(_prompt, _references, _lane, **options):
            path = os.path.join(options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((180, 120, 3), 160, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            with mock.patch.object(
                    body, "image_provider_selection", return_value=(config, public)), \
                    mock.patch.object(
                        body.media_gen, "generate_image_edit_sync", side_effect=generate), \
                    mock.patch.object(
                        body, "_preflight_front_source", return_value={"valid": True}), \
                    mock.patch.object(
                        body, "_preflight_alpha_source", return_value={"valid": True}), \
                    mock.patch.object(
                        body, "_install_sources",
                        side_effect=body.GeneratedBodyAlphaError("unsafe alpha")):
                with self.assertRaises(body.GeneratedBodyAlphaError):
                    body.build(
                        directory,
                        {"style": "editorial", "pose": "relaxed"},
                        log=lambda _message: None)
            self.assertFalse(os.path.exists(os.path.join(directory, ".body-cache")))


if __name__ == "__main__":
    unittest.main()
