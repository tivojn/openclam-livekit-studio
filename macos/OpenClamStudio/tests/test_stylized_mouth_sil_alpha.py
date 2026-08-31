"""Closed cartoon expression cells must cover the immutable old lip corners."""
import unittest
from unittest import mock

import numpy as np

from studio import expression, face


BOX = [411, 593, 218, 121]
# Measured canonical outer-lip geometry from the failing flat-art source. Its
# closed donor is narrower, with alpha 186--222 over these old corner pixels.
OUTLINE = [
    [453.9774, 651.0988], [460.4802, 658.8072], [468.7858, 667.0710],
    [481.7942, 676.7810], [499.0139, 682.9901], [519.4020, 684.6999],
    [539.4069, 682.3600], [556.8681, 675.4566], [570.1089, 665.4810],
    [579.3395, 656.8940], [586.0600, 649.5022], [579.0238, 645.9672],
    [569.9380, 642.2727], [557.2670, 638.1363], [539.9751, 633.5802],
    [521.8386, 638.0668], [503.1233, 634.2620], [484.8358, 639.5465],
    [471.4792, 644.1096], [461.6183, 647.4831],
]
OLD_CORNERS = [(448, 650), (449, 649), (451, 650),
               (590, 650), (591, 649), (589, 650)]


def fixture():
    landmarks = np.zeros((478, 2), np.float32)
    landmarks[face.OUTER_LIP] = OUTLINE
    yy, xx = np.indices((BOX[3], BOX[2]))
    cell = np.stack(((xx * 3 + yy) % 256, (xx + yy * 7) % 256,
                     (xx * 5 + yy * 3) % 256, np.full_like(xx, 195)), axis=2).astype(np.uint8)
    return landmarks, cell


class CanonicalSilAlphaTests(unittest.TestCase):
    def test_actual_old_corners_are_opaque_with_every_rgb_pixel_unchanged(self):
        landmarks, cell = fixture()
        original = cell.copy()
        result = expression._own_canonical_sil_alpha(
            cell, landmarks, BOX, (1024, 1024, 3), "illustration")
        for x, y in OLD_CORNERS:
            self.assertEqual(255, result[y - BOX[1], x - BOX[0], 3])
        np.testing.assert_array_equal(result[:, :, :3], cell[:, :, :3])
        np.testing.assert_array_equal(cell, original)
        self.assertTrue((result[:, :, 3] >= original[:, :, 3]).all())
        # The nose / jaw and every atlas border stay exactly as supplied.
        for region in (np.s_[:20], np.s_[-10:], np.s_[:, :20], np.s_[:, -20:]):
            np.testing.assert_array_equal(result[region], original[region])

    def test_removes_transmitted_old_stroke_not_donor_art(self):
        landmarks, cell = fixture()
        x, y = 449 - BOX[0], 649 - BOX[1]
        old_rgb = np.array([181, 81, 53], np.float32)
        cell[y, x] = [244, 180, 142, 195]
        result = expression._own_canonical_sil_alpha(
            cell, landmarks, BOX, (1024, 1024, 3), "illustration")
        def composite(pixel):
            alpha = float(pixel[3]) / 255
            return np.rint(pixel[:3] * alpha + old_rgb * (1 - alpha)).astype(np.uint8)
        self.assertFalse(np.array_equal(composite(cell[y, x]), cell[y, x, :3]))
        np.testing.assert_array_equal(composite(result[y, x]), cell[y, x, :3])

    def test_only_explicit_cartoon_media_change_alpha(self):
        landmarks, cell = fixture()
        for medium in ("illustration", "3d render"):
            with self.subTest(medium=medium):
                result = expression._own_canonical_sil_alpha(
                    cell, landmarks, BOX, (1024, 1024, 3), medium)
                self.assertGreater(np.count_nonzero(result != cell), 0)
        for medium in (None, "photograph", "photo", "anime", "game art", "unknown", {}, True):
            with self.subTest(medium=medium):
                result = expression._own_canonical_sil_alpha(
                    cell, landmarks, BOX, (1024, 1024, 3), medium)
                self.assertIs(result, cell)

    def test_bad_or_cropped_geometry_is_exact_no_op(self):
        landmarks, cell = fixture()
        invalid = []
        for value in (float("nan"), float("inf"), -1, 2048):
            edited = landmarks.copy()
            edited[face.OUTER_LIP[0], 0] = value
            invalid.append(edited)
        degenerate = landmarks.copy()
        degenerate[face.OUTER_LIP] = [520, 651]
        invalid.extend([degenerate, None, np.zeros((5, 2)), {"lip": OUTLINE}])
        for geometry in invalid:
            with self.subTest(geometry_type=type(geometry).__name__):
                self.assertIs(cell, expression._own_canonical_sil_alpha(
                    cell, geometry, BOX, (1024, 1024, 3), "illustration"))
        for box in ([411, 593, 218., 121], [True, 593, 218, 121],
                    [450, 620, 218, 121], [-411, 593, 218, 121], [411, 593, 218]):
            self.assertIs(cell, expression._own_canonical_sil_alpha(
                cell, landmarks, box, (1024, 1024, 3), "illustration"))

    def test_bank_repair_changes_exactly_seventeen_sil_alpha_cells(self):
        landmarks, cell = fixture()
        key = np.zeros((1024, 1024, 3), np.uint8)
        names = ["sil", "PP", "FF", "TH", "DD", "kk", "CH", "SS",
                 "nn", "RR", "aa", "E", "ih", "oh", "ou"]
        bank = [(name, key) for name in names]
        with mock.patch.object(expression.face, "detect", return_value=(landmarks, None)), \
                mock.patch.object(expression, "_smile_box", return_value=BOX), \
                mock.patch.object(expression, "_smile_patch", side_effect=lambda *args: cell.copy()), \
                mock.patch.object(expression, "_emotion_mouth_patch", side_effect=lambda *args: cell.copy()):
            for medium in ("illustration", "3d render"):
                smile = expression.build_smile(key, landmarks, bank, source_medium=medium, log=lambda _: None)
                emotion = expression.build_emotion_mouths(key, landmarks, bank, source_medium=medium, log=lambda _: None)
                expected = [set(range(5)), set(range(4)) | set(range(60, 64)) | set(range(120, 124))]
                for result, owned in zip((smile, emotion), expected):
                    self.assertEqual(names, result["visemes"])
                    changed = set()
                    for index, patch in enumerate(result["patches"]):
                        np.testing.assert_array_equal(patch[:, :, :3], cell[:, :, :3])
                        if np.any(patch[:, :, 3] != cell[:, :, 3]):
                            changed.add(index)
                        if index not in owned:
                            np.testing.assert_array_equal(patch, cell)
                    self.assertEqual(owned, changed)
            for medium in (None, "photograph"):
                for builder in (expression.build_smile, expression.build_emotion_mouths):
                    result = builder(key, landmarks, bank, source_medium=medium, log=lambda _: None)
                    for patch in result["patches"]:
                        np.testing.assert_array_equal(patch, cell)


if __name__ == "__main__":
    unittest.main()
