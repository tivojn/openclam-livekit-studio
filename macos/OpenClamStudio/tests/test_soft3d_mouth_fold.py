"""A shaded smile fold belongs to its mouth, not to an immutable cheek ring."""
import ast
from pathlib import Path
import unittest

import cv2
import numpy as np

from studio import compose, face


def _fixture():
    size = 512
    yy, xx = np.indices((size, size), dtype=np.float32)
    base = np.stack((100 + xx * .04, 158 + yy * .025,
                     214 + (xx + yy) * .012), axis=2)
    key = base.copy()
    # A smooth old smile crease extends beyond the opaque lip-only envelope.
    crease = np.exp(-(((xx - 335) / 12) ** 2
                      + ((yy - 356) / 12) ** 2) / 2) * 26
    key -= crease[..., None]
    key, donor = np.uint8(key), np.uint8(base)
    landmarks = np.full((478, 2), (256, 300), np.float32)
    angles = np.linspace(-np.pi / 2, np.pi * 1.5,
                         len(face.FACE_OVAL), endpoint=False)
    landmarks[face.FACE_OVAL, 0] = 256 + 180 * np.cos(angles)
    landmarks[face.FACE_OVAL, 1] = 256 + 226 * np.sin(angles)
    for i, index in enumerate(face.NOSE_CORE + [2, 98, 327]):
        theta = 2 * np.pi * i / len(face.NOSE_CORE + [2, 98, 327])
        landmarks[index] = (256 + 20 * np.cos(theta),
                            274 + 20 * np.sin(theta))
    for i, index in enumerate(face.OUTER_LIP):
        if i <= 10:
            nx = -1 + i / 5
            y = 338 + 32 * (1 - nx * nx)
        else:
            nx = 1 - (i - 10) * 2 / 10
            y = 338 + 12 * (1 - nx * nx)
        landmarks[index] = (256 + 60 * nx, y)
    landmarks[face.MOUTH_L] = (196, 338)
    landmarks[face.MOUTH_R] = (316, 338)
    landmarks[0] = (256, 350)
    landmarks[17] = (256, 370)
    landmarks[152] = (256, 482)
    source = landmarks.copy()
    source[face.OUTER_LIP, 0] = 256 + (source[face.OUTER_LIP, 0] - 256) * .76
    source[face.OUTER_LIP, 1] = 356
    source[0] = (256, 351)
    source[17] = (256, 368)
    cv2.ellipse(donor, (256, 359), (39, 9), 0, 0, 360, (25, 35, 65), -1)
    transform = np.eye(2, 3, dtype=np.float32)
    alpha = compose._stylized_mouth_alpha(
        key.shape, landmarks, source, transform)
    return key, donor.astype(np.float32), alpha, landmarks, source, transform


def _run(data, medium="3d render"):
    return compose._soft3d_smile_fold_alpha(*data, medium)


class Soft3DMouthFoldTests(unittest.TestCase):
    def test_connected_fold_is_replaced_without_changing_lips_or_far_face(self):
        data = _fixture()
        key, donor, alpha, *_ = data
        originals = [value.copy() for value in data]
        result = _run(data)
        self.assertGreater(float(result[356, 335]), .95)
        self.assertLess(float(alpha[356, 335]), .15)
        self.assertTrue(np.all(result >= alpha))
        np.testing.assert_array_equal(result[alpha == 1], alpha[alpha == 1])
        actual = key * (1 - result[..., None]) + donor * result[..., None]
        baseline = key * (1 - alpha[..., None]) + donor * alpha[..., None]
        np.testing.assert_array_equal(actual[alpha == 1], baseline[alpha == 1])
        np.testing.assert_array_equal(actual[:300], key[:300])
        np.testing.assert_array_equal(actual[410:], key[410:])
        self.assertLess(np.abs(actual[356, 335] - donor[356, 335]).max(), 1)
        for value, original in zip(data, originals):
            np.testing.assert_array_equal(value, original)

    def test_photo_2d_unknown_and_unopted_paths_are_literal_noops(self):
        data = _fixture()
        for medium in (None, "photograph", "photo", "illustration", "anime",
                       "game art", "unknown", "3D render", {}, True):
            with self.subTest(medium=medium):
                self.assertIs(_run(data, medium), data[2])

    def test_ordinary_neutral_and_unchanged_smile_keep_previous_bytes(self):
        for case in ("neutral", "same", "wider"):
            with self.subTest(case=case):
                key, donor, alpha, klm, slm, transform = _fixture()
                if case == "neutral":
                    klm[0, 1] = klm[[61, 291], 1].mean() - 3
                elif case == "same":
                    slm = klm.copy()
                else:
                    slm[face.OUTER_LIP, 0] = 256 + (klm[face.OUTER_LIP, 0] - 256) * 1.1
                self.assertIs(_run((key, donor, alpha, klm, slm, transform)), alpha)

    def test_disconnected_provider_change_does_not_get_extra_ownership(self):
        key, donor, alpha, klm, slm, transform = _fixture()
        # Remove the connected fold; an isolated spot beyond the mask is not
        # evidence that a larger canonical cheek region needs replacement.
        key = np.uint8(donor)
        donor = donor.copy()
        donor[370:375, 340:345] -= 12
        result = _run((key, donor, alpha, klm, slm, transform))
        np.testing.assert_array_equal(result, alpha)

    def test_sharp_unshared_art_is_not_removed_by_smooth_fold_transfer(self):
        key, donor, alpha, klm, slm, transform = _fixture()
        cv2.rectangle(key, (333, 354), (336, 358), (0, 0, 0), -1)
        result = _run((key, donor, alpha, klm, slm, transform))
        np.testing.assert_array_equal(result[354:359, 333:337], alpha[354:359, 333:337])

    def test_nose_and_silhouette_guard_override_extra_fold_support(self):
        for case in ("nose", "silhouette"):
            with self.subTest(case=case):
                key, donor, alpha, klm, slm, transform = _fixture()
                if case == "nose":
                    klm[face.NOSE_CORE + [2, 98, 327]] += (79, 82)
                else:
                    klm[face.FACE_OVAL, 0] = np.minimum(klm[face.FACE_OVAL, 0], 336)
                result = _run((key, donor, alpha, klm, slm, transform))
                self.assertEqual(float(alpha[356, 335]), float(result[356, 335]))

    def test_registered_geometry_not_raw_detector_position_controls_gate(self):
        data = _fixture()
        expected = _run(data)
        key, donor, alpha, klm, slm, _ = data
        moved = slm + (13, -11)
        transform = np.array([[1, 0, -13], [0, 1, 11]], np.float32)
        actual = _run((key, donor, alpha, klm, moved, transform))
        np.testing.assert_array_equal(actual, expected)

    def test_invalid_geometry_does_not_expand_the_mask(self):
        for invalid in (None, [], np.zeros((12, 2)), np.full((478, 2), np.nan)):
            with self.subTest(type=type(invalid).__name__):
                key, donor, alpha, _klm, slm, transform = _fixture()
                self.assertIs(_run((key, donor, alpha, invalid, slm, transform)), alpha)

    def test_every_build_compositor_call_passes_explicit_source_medium(self):
        source = Path(compose.__file__).with_name("build.py").read_text()
        calls = [node for node in ast.walk(ast.parse(source))
                 if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute)
                 and isinstance(node.func.value, ast.Name)
                 and node.func.value.id == "compose"
                 and node.func.attr == "compose_all"]
        self.assertEqual(6, len(calls))
        for call in calls:
            self.assertIn("source_medium", {item.arg for item in call.keywords})


if __name__ == "__main__":
    unittest.main()
