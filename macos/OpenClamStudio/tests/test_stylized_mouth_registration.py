"""Pixel registration is optional, rigid, and never a photo/blink rewrite."""
import copy
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import compose, export, expression, face


def artwork():
    image = np.full((256, 256, 3), (115, 174, 219), np.uint8)
    cv2.rectangle(image, (18, 10), (237, 44), (15, 21, 35), -1)
    for x in (78, 174):
        cv2.ellipse(image, (x, 93), (35, 40), 0, 0, 360, (251, 252, 252), -1)
        cv2.ellipse(image, (x, 93), (35, 40), 0, 0, 360, (14, 19, 29), 2)
        cv2.circle(image, (x, 94), 12, (8, 12, 18), -1)
    cv2.line(image, (125, 131), (119, 152), (19, 32, 57), 4)
    cv2.line(image, (119, 152), (132, 152), (19, 32, 57), 3)
    cv2.line(image, (104, 191), (152, 191), (37, 54, 78), 2)
    landmarks = np.full((478, 2), (128.0, 185.0), np.float32)
    angles = np.linspace(0, np.pi * 2, len(face.OUTER_LIP), endpoint=False)
    landmarks[face.OUTER_LIP, 0] = 128 + 28 * np.cos(angles)
    landmarks[face.OUTER_LIP, 1] = 191 + 7 * np.sin(angles)
    return image, landmarks


class StylizedMouthRegistrationTests(unittest.TestCase):
    def test_identical_upper_art_overrides_fictitious_landmark_tilt(self):
        key, landmarks = artwork()
        donor = key.copy()
        cv2.ellipse(donor, (128, 191), (25, 8), 0, 0, 360, (24, 34, 54), -1)
        before = (key.copy(), donor.copy(), landmarks.copy())
        bad = cv2.getRotationMatrix2D((128, 128), 6, 1).astype(np.float32)
        selected, evidence = compose._stylized_mouth_registration(
            key, donor, landmarks, landmarks, bad)
        self.assertEqual("stylized-upper-face-rigid-pixels-v1", evidence["method"])
        np.testing.assert_allclose(selected, np.eye(2, 3), atol=0.02)
        self.assertGreater(evidence["correlation"], 0.999)
        self.assertLess(evidence["registered_edge_mae"], evidence["landmark_edge_mae"] * 0.1)
        for actual, original in zip((key, donor, landmarks), before):
            np.testing.assert_array_equal(actual, original)

    def test_small_true_translation_is_recovered_without_scaling_art(self):
        key, landmarks = artwork()
        offset = np.array([[1, 0, 3], [0, 1, -2]], np.float32)
        donor = cv2.warpAffine(key, offset, (256, 256), borderMode=cv2.BORDER_REPLICATE)
        generated = landmarks + (3, -2)
        wrong = cv2.getRotationMatrix2D((128, 128), -6, 1.02).astype(np.float32)
        selected, evidence = compose._stylized_mouth_registration(
            key, donor, landmarks, generated, wrong)
        self.assertEqual("stylized-upper-face-rigid-pixels-v1", evidence["method"])
        np.testing.assert_allclose(selected, [[1, 0, -3], [0, 1, 2]], atol=0.08)
        self.assertAlmostEqual(1.0, np.linalg.det(selected[:, :2]), places=5)

    def test_textureless_or_already_correct_input_keeps_existing_transform(self):
        key, landmarks = artwork()
        current = np.eye(2, 3, dtype=np.float32)
        selected, evidence = compose._stylized_mouth_registration(
            key, key.copy(), landmarks, landmarks, current)
        self.assertIs(selected, current)
        self.assertEqual({"method": "landmarks"}, evidence)
        blank = np.full_like(key, 150)
        with mock.patch.object(cv2, "findTransformECC", side_effect=AssertionError("blank image used ECC")):
            selected, _ = compose._stylized_mouth_registration(blank, blank, landmarks, landmarks, current)
        self.assertIs(selected, current)

    def test_low_confidence_large_motion_and_failed_fit_are_not_used(self):
        key, landmarks = artwork()
        current = cv2.getRotationMatrix2D((128, 128), 5, 1).astype(np.float32)
        oversized = np.array([[1, 0, 45], [0, 1, 0]], np.float32)
        rotated = cv2.getRotationMatrix2D((0, 0), 9, 1).astype(np.float32)
        for correlation, inverse in [(0.8, np.eye(2, 3, dtype=np.float32)), (0.999, oversized), (0.999, rotated)]:
            with self.subTest(correlation=correlation, inverse=inverse.tolist()), mock.patch.object(
                    cv2, "findTransformECC", return_value=(correlation, inverse)):
                selected, evidence = compose._stylized_mouth_registration(
                    key, key.copy(), landmarks, landmarks, current)
                self.assertIs(selected, current)
                self.assertEqual({"method": "landmarks"}, evidence)
        with mock.patch.object(cv2, "findTransformECC", side_effect=cv2.error("no convergence")):
            selected, _ = compose._stylized_mouth_registration(key, key.copy(), landmarks, landmarks, current)
        self.assertIs(selected, current)

    def test_correct_pixel_registration_does_not_transfer_a_second_nose(self):
        key, landmarks = artwork()
        donor = key.copy()
        cv2.ellipse(donor, (128, 191), (25, 8), 0, 0, 360, (24, 34, 54), -1)
        bad = cv2.getRotationMatrix2D((128, 128), 6, 1).astype(np.float32)
        transform, _ = compose._stylized_mouth_registration(key, donor, landmarks, landmarks, bad)
        alpha = compose._stylized_mouth_alpha(key.shape, landmarks, landmarks, transform)
        warped = cv2.warpAffine(donor, transform, (256, 256), flags=cv2.INTER_LANCZOS4,
                                borderMode=cv2.BORDER_REPLICATE)
        matched = compose._stylized_patch_harmonize(key, warped, alpha)
        rendered = (key * (1 - alpha[..., None]) + matched * alpha[..., None]).astype(np.uint8)
        np.testing.assert_array_equal(rendered[:169], key[:169])
        self.assertEqual(0, np.count_nonzero(alpha[:169]))
        self.assertLess(int(rendered[191, 128, 2]), 100)

    def test_photo_and_blink_pipeline_never_dispatch_pixel_refinement(self):
        image, landmarks = artwork()
        identity = np.eye(2, 3, dtype=np.float32)
        test_alpha = np.zeros((256, 256), np.float32)
        test_alpha[8:-8, 8:-8] = 1.0
        for allow_stylized, name in [(False, "ah"), (True, "blink")]:
            with self.subTest(allow_stylized=allow_stylized, name=name), tempfile.TemporaryDirectory() as root:
                key = os.path.join(root, "key.png")
                raw = os.path.join(root, "raw")
                out = os.path.join(root, "out")
                os.makedirs(raw)
                cv2.imwrite(key, image)
                cv2.imwrite(os.path.join(raw, f"v_{name}.png"), image)
                with mock.patch.object(compose.visemes, "ORDER", [name]), \
                        mock.patch.object(compose, "_detect_composition_face", return_value=(landmarks, None)), \
                        mock.patch.object(compose.face, "metrics", return_value={}), \
                        mock.patch.object(compose.face, "foreshortening", return_value=1.0), \
                        mock.patch.object(compose, "_masks", return_value=({"mouth": None, "eyes": None}, np.ones((256, 256), np.uint8))), \
                        mock.patch.object(compose, "_alpha_ring", return_value=(test_alpha, np.ones((256, 256), bool))), \
                        mock.patch.object(cv2, "estimateAffine2D", return_value=(identity, None)), \
                        mock.patch.object(compose, "_finish_viseme_bank", return_value=([], [])), \
                        mock.patch.object(compose, "_stylized_mouth_registration", side_effect=AssertionError("wrong medium/eye dispatch")):
                    report, _ = compose.compose_all(key, raw, out, allow_stylized=allow_stylized, log=lambda _: None)
                self.assertNotIn("registration", report[0])
                expected = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 95])[1]
                with open(os.path.join(out, f"v_{name}.jpg"), "rb") as result:
                    self.assertEqual(expected.tobytes(), result.read())


class CanonicalRegistrationHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = self.temporary.name
        self.key, self.landmarks = artwork()
        self.key_path = os.path.join(self.root, "keyframe.png")
        self.visemes = os.path.join(self.root, "visemes")
        os.makedirs(self.visemes)
        self.plate_path = os.path.join(self.visemes, "v_ah.jpg")
        cv2.imwrite(self.key_path, self.key)
        donor = self.key.copy()
        cv2.ellipse(donor, (128, 191), (25, 8), 0, 0, 360, (24, 34, 54), -1)
        cv2.imwrite(self.plate_path, donor, [cv2.IMWRITE_JPEG_QUALITY, 95])
        self.image = cv2.imread(self.plate_path)
        self.registration = {
            "method": "stylized-upper-face-rigid-pixels-v1", "correlation": .999,
            "landmark_edge_mae": 45., "registered_edge_mae": 3.,
            "rotation_degrees": 0.01,
        }
        compose._seal_stylized_registration(
            self.key, self.key_path, self.plate_path, self.registration)

    def _smile(self, medium, registration):
        biased = self.landmarks.copy()
        biased[face.OUTER_LIP, 0] += 34.0
        with mock.patch.object(expression.face, "detect", return_value=(biased, None)), \
                mock.patch.object(expression, "_smile_box", return_value=[85, 170, 95, 45]), \
                mock.patch.object(expression, "_smile_patch", return_value=np.zeros((45, 95, 4), np.uint8)):
            return expression.build_smile(
                self.key, self.landmarks, [("aa", self.image)], states=[0],
                source_medium=medium, canonical_registrations={"aa": registration},
                log=lambda _: None)

    def test_exact_registered_cartoon_plate_is_not_centered_twice(self):
        for medium in ("illustration", "3d render"):
            with self.subTest(medium=medium):
                result = self._smile(medium, self.registration)
                self.assertEqual({"aa": 0.0}, result["viseme_x_offsets"])
        legacy = self._smile("3d render", None)
        self.assertLess(legacy["viseme_x_offsets"]["aa"], -15.0)
        np.testing.assert_array_equal(result["patches"], legacy["patches"])

    def test_photo_legacy_unknown_and_missing_proof_keep_exact_offset(self):
        legacy = self._smile("photograph", None)
        for medium in ("photograph", "photo", "anime", "game art", "unknown", None, {}):
            with self.subTest(medium=medium):
                result = self._smile(medium, self.registration)
                self.assertEqual(legacy["viseme_x_offsets"], result["viseme_x_offsets"])
                np.testing.assert_array_equal(legacy["patches"], result["patches"])

    def test_pixel_proof_fails_closed_for_changed_key_frame_or_metadata(self):
        self.assertTrue(compose.canonical_mouth_registration_matches(
            self.key, self.image, self.registration))
        changed_key, changed_image = self.key.copy(), self.image.copy()
        changed_key[0, 0, 0] ^= 1
        changed_image[0, 0, 0] ^= 1
        for key, image in ((changed_key, self.image), (self.key, changed_image)):
            self.assertFalse(compose.canonical_mouth_registration_matches(key, image, self.registration))
        variants = []
        for field, value in (("method", "landmarks"), ("correlation", .8),
                             ("correlation", True), ("rotation_degrees", 9.),
                             ("registered_edge_mae", 40.)):
            variant = copy.deepcopy(self.registration)
            variant[field] = value
            variants.append(variant)
        for field, value in (("v", True), ("v", 2), ("shape", [256., 256, 3]),
                             ("canonical_bgr_sha256", "0" * 64),
                             ("processed_bgr_sha256", "0" * 64)):
            variant = copy.deepcopy(self.registration)
            variant["canonical_pixel_registration"][field] = value
            variants.append(variant)
        for registration in variants + [{}, None]:
            with self.subTest(registration=registration):
                self.assertFalse(compose.canonical_mouth_registration_matches(
                    self.key, self.image, registration))
                self.assertLess(self._smile("3d render", registration)["viseme_x_offsets"]["aa"], 0.)

    def test_export_requires_exact_files_and_unambiguous_known_shape(self):
        row = {"name": "ah", "registration": self.registration}
        bank = [("aa", self.image)]
        def verify(rows, medium="3d render"):
            return export._canonical_mouth_registrations(
                self.root, medium, {"visemes": rows}, self.key, bank)
        self.assertEqual({"aa": self.registration}, verify([row]))
        for medium in ("photograph", "anime", None, {}):
            self.assertEqual({}, verify([row], medium))
        for rows in ([row, row], [{"name": "blink", "registration": self.registration}],
                     [{"name": "../../ah", "registration": self.registration}],
                     [{"name": []}], None, [row] * 65):
            self.assertEqual({}, verify(rows))
        # Trailing JPEG bytes leave every decoded pixel unchanged, but a new
        # file is not the file sealed by upstream composition.
        with open(self.plate_path, "ab") as handle:
            handle.write(b"changed-encoding")
        np.testing.assert_array_equal(self.image, cv2.imread(self.plate_path))
        self.assertEqual({}, verify([row]))

    def test_compose_report_produces_a_verifiable_final_jpeg_seal(self):
        raw = os.path.join(self.root, "raw")
        os.makedirs(raw)
        cv2.imwrite(os.path.join(raw, "v_ah.png"), self.image)
        bad = cv2.getRotationMatrix2D((128, 128), 6, 1).astype(np.float32)
        alpha = np.zeros((256, 256), np.float32)
        with mock.patch.object(compose.visemes, "ORDER", ["ah"]), \
                mock.patch.object(compose, "_detect_composition_face", return_value=(self.landmarks, None)), \
                mock.patch.object(compose.face, "metrics", return_value={}), \
                mock.patch.object(compose.face, "foreshortening", return_value=1.), \
                mock.patch.object(compose, "_masks", return_value=({"mouth": None, "eyes": None}, np.ones((256, 256), np.uint8))), \
                mock.patch.object(compose, "_alpha_ring", return_value=(alpha, np.ones((256, 256), bool))), \
                mock.patch.object(cv2, "estimateAffine2D", return_value=(bad, None)):
            report, _ = compose.compose_all(
                self.key_path, raw, self.visemes, allow_stylized=True, log=lambda _: None)
        frame = cv2.imread(self.plate_path)
        registration = report[0]["registration"]
        self.assertTrue(compose.canonical_mouth_registration_matches(
            self.key, frame, registration,
            keyframe_path=self.key_path, processed_path=self.plate_path))
        self.assertEqual({"aa": registration}, export._canonical_mouth_registrations(
            self.root, "3d render", {"visemes": report}, self.key, [("aa", frame)]))


if __name__ == "__main__":
    unittest.main()
