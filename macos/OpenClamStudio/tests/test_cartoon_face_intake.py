"""Stylized portraits get a safe intake fallback without weakening runtime QA."""
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

import cv2
import numpy as np

from studio import build, face, generate, prep


def plausible_mesh(width=100, height=80):
    """A synthetic but anatomically coherent 478-point stylized mesh."""
    landmarks = np.full((478, 2), (width * 0.5, height * 0.5), np.float32)
    centre_x, centre_y = width * 0.5, height * 0.52
    oval_width, oval_height = width * 0.60, height * 0.70
    for index, landmark_index in enumerate(face.FACE_OVAL):
        angle = 2.0 * np.pi * index / len(face.FACE_OVAL)
        landmarks[landmark_index] = (
            centre_x + np.cos(angle) * oval_width / 2.0,
            centre_y + np.sin(angle) * oval_height / 2.0)

    eye_y = height * 0.36
    landmarks[face.EYE_R_OUT] = (centre_x - oval_width * 0.30, eye_y)
    landmarks[face.EYE_L_OUT] = (centre_x + oval_width * 0.30, eye_y)
    mouth_y = height * 0.64
    for index, landmark_index in enumerate(face.OUTER_LIP):
        angle = 2.0 * np.pi * index / len(face.OUTER_LIP)
        landmarks[landmark_index] = (
            centre_x + np.cos(angle) * oval_width * 0.09,
            mouth_y + np.sin(angle) * oval_height * 0.04)
    landmarks[face.MOUTH_L] = (centre_x - oval_width * 0.09, mouth_y)
    landmarks[face.MOUTH_R] = (centre_x + oval_width * 0.09, mouth_y)
    landmarks[face.PHILTRUM] = (centre_x, height * 0.56)
    landmarks[face.NOSE_TIP] = (centre_x, height * 0.52)
    return landmarks


class CartoonDetectorTests(unittest.TestCase):
    def test_strict_photo_returns_without_starting_stylized_detector(self):
        image = np.zeros((80, 100, 3), np.uint8)
        landmarks = plausible_mesh()
        transform = np.eye(4)
        with mock.patch.object(face, "detect", return_value=(landmarks, transform)), \
                mock.patch.object(
                    face, "classify_source_medium",
                    return_value={"source_medium": "photograph", "medium_score": 0.4}), \
                mock.patch.object(
                    face, "stylized_detector",
                    side_effect=AssertionError("fallback should not run")):
            found, found_transform, metadata = face.detect_for_intake(image)
        self.assertIs(found, landmarks)
        self.assertIs(found_transform, transform)
        self.assertEqual(metadata, {
            "detection_mode": "strict",
            "source_medium": "photograph",
            "medium_score": 0.4})

    def test_bottom_right_crop_remaps_all_landmarks_to_source(self):
        image = np.zeros((100, 200, 3), np.uint8)
        box = (100, 20, 100, 80)
        local = plausible_mesh(100, 80)
        transform = np.eye(4)
        with mock.patch.object(face, "detect", return_value=(None, None)), \
                mock.patch.object(face, "stylized_detector", return_value=object()), \
                mock.patch.object(face, "_stylized_windows", return_value=iter((box,))), \
                mock.patch.object(face, "_detect_with",
                                  return_value=(local, transform)), \
                mock.patch.object(
                    face, "classify_source_medium",
                    return_value={"source_medium": "photograph", "medium_score": 0.5}):
            found, found_transform, metadata = face.detect_for_intake(image)
        expected = local + np.asarray((box[0], box[1]), np.float32)
        np.testing.assert_allclose(found, expected)
        self.assertIs(found_transform, transform)
        self.assertEqual(metadata["detection_mode"], "crop-fallback")
        # Needing a crop fallback must not turn an ordinary photo into a cartoon.
        self.assertEqual(metadata["source_medium"], "photograph")
        self.assertEqual(metadata["detection_crop"], {
            "x": 100, "y": 20, "width": 100, "height": 80,
            "source": [200, 100]})

    def test_blank_source_exhausts_only_bounded_unique_windows(self):
        image = np.zeros((100, 200, 3), np.uint8)
        windows = list(face._stylized_windows(200, 100))
        self.assertEqual(len(windows), len(set(windows)))
        self.assertLessEqual(len(windows), 270)
        for x, y, width, height in windows:
            self.assertGreater(width, 0)
            self.assertGreater(height, 0)
            self.assertGreaterEqual(x, 0)
            self.assertGreaterEqual(y, 0)
            self.assertLessEqual(x + width, 200)
            self.assertLessEqual(y + height, 100)
        with mock.patch.object(face, "detect", return_value=(None, None)), \
                mock.patch.object(face, "stylized_detector", return_value=object()), \
                mock.patch.object(face, "_detect_with",
                                  return_value=(None, None)) as detect_crop:
            found = face.detect_for_intake(image)
        self.assertEqual(found, (None, None, None))
        self.assertEqual(detect_crop.call_count, len(windows))

    def test_collapsed_or_nonfinite_mesh_is_rejected(self):
        collapsed = np.full((478, 2), 40.0, np.float32)
        self.assertIsNone(face._stylized_mesh_quality(collapsed, 100, 80, 80))
        malformed = plausible_mesh()
        malformed[face.NOSE_TIP] = (np.nan, np.nan)
        self.assertIsNone(face._stylized_mesh_quality(malformed, 100, 80, 80))

    def test_source_medium_is_independent_of_detector_path(self):
        landmarks = plausible_mesh(160, 160)
        illustration = np.full((160, 160, 3), (120, 180, 235), np.uint8)
        cv2.rectangle(illustration, (35, 35), (125, 125), (8, 8, 8), 5)
        cv2.circle(illustration, (62, 70), 12, (255, 255, 255), -1)
        cv2.circle(illustration, (98, 70), 12, (255, 255, 255), -1)

        rng = np.random.default_rng(11)
        texture = rng.normal(128, 24, (160, 160, 3)).clip(0, 255).astype(np.uint8)
        photograph_like = cv2.GaussianBlur(texture, (0, 0), 1.1)

        self.assertEqual(
            face.classify_source_medium(illustration, landmarks)["source_medium"],
            "illustration")
        self.assertEqual(
            face.classify_source_medium(photograph_like, landmarks)["source_medium"],
            "photograph")


class CartoonKeyframeTests(unittest.TestCase):
    def test_source_mesh_projects_into_keyframe_without_redetection(self):
        image = np.zeros((100, 200, 3), np.uint8)
        local = plausible_mesh(100, 80)
        source_landmarks = local + np.asarray((100, 20), np.float32)
        detection = {
            "detection_mode": "crop-fallback",
            "source_medium": "illustration",
            "medium_score": 0.9,
            "detection_crop": {
                "x": 100, "y": 20, "width": 100, "height": 80,
                "source": [200, 100]},
            "topology": {"face_area": 0.3},
        }
        with tempfile.TemporaryDirectory() as directory:
            output = os.path.join(directory, "key.png")
            with mock.patch.object(prep, "read_image_bgr", return_value=image), \
                    mock.patch.object(
                        face, "detect_for_intake",
                        return_value=(source_landmarks, np.eye(4), detection)), \
                    mock.patch.object(
                        face, "detect",
                        side_effect=AssertionError("cartoon keyframe was redetected")):
                metrics = prep.build_keyframe(
                    "unused.png", output, allow_stylized=True)
            keyframe = cv2.imread(output, cv2.IMREAD_COLOR)
        self.assertEqual(keyframe.shape, (1024, 1024, 3))
        self.assertEqual(metrics["detection_mode"], "crop-fallback")
        self.assertEqual(metrics["source_medium"], "illustration")
        self.assertEqual(metrics["detection_crop"], detection["detection_crop"])
        # The proven crop expands to a 100px square at x=100,y=0.
        projected = source_landmarks.copy()
        projected[:, 0] = (projected[:, 0] - 100) * 10.24
        projected[:, 1] *= 10.24
        expected_width = float(np.ptp(projected[face.OUTER_LIP, 0]))
        self.assertAlmostEqual(metrics["mouth_width_px"], expected_width, places=3)


class CartoonRegistrationTransactionTests(unittest.TestCase):
    def test_rejection_removes_only_new_reserved_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            avatars = os.path.join(directory, "avatars")
            os.makedirs(os.path.join(avatars, "l"))
            keep = os.path.join(avatars, "l", "keep.txt")
            with open(keep, "w", encoding="utf-8") as handle:
                handle.write("existing")
            upload = os.path.join(directory, "l.png")
            cv2.imwrite(upload, np.zeros((20, 20, 3), np.uint8))
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        prep, "build_keyframe",
                        side_effect=ValueError("no face detected")):
                with self.assertRaisesRegex(ValueError, "no face detected"):
                    build.create_avatar(upload, slug="l")
            self.assertTrue(os.path.isfile(keep))
            self.assertFalse(os.path.exists(os.path.join(avatars, "l-2")))

    def test_simultaneous_same_name_uploads_get_exclusive_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            avatars = os.path.join(directory, "avatars")
            upload = os.path.join(directory, "l.png")
            cv2.imwrite(upload, np.full((20, 20, 3), 127, np.uint8))

            def fake_keyframe(_source, output, **_kwargs):
                cv2.imwrite(output, np.full((32, 32, 3), 127, np.uint8))
                return {
                    "source_medium": "illustration",
                    "detection_mode": "strict", "warnings": []}

            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(prep, "build_keyframe", side_effect=fake_keyframe):
                with ThreadPoolExecutor(max_workers=2) as executor:
                    manifests = list(executor.map(
                        lambda _index: build.create_avatar(upload, slug="l"),
                        range(2)))

            self.assertEqual({item["slug"] for item in manifests}, {"l", "l-2"})
            self.assertTrue(os.path.isfile(os.path.join(avatars, "l", "manifest.json")))
            self.assertTrue(os.path.isfile(os.path.join(avatars, "l-2", "manifest.json")))


class StylizedHeadPromptTests(unittest.TestCase):
    def test_prompt_preserves_medium_and_identity_headwear(self):
        prompt = generate.STYLIZED_HEAD_PROMPT.lower()
        self.assertIn("preserve the source medium", prompt)
        self.assertIn("do not photorealize", prompt)
        self.assertIn("identity-bearing headwear", prompt)
        self.assertIn("closed, relaxed mouth", prompt)

    def test_prompt_versions_do_not_invalidate_existing_photo_heads(self):
        self.assertEqual(generate.HEAD_PROMPT_VERSION, 3)
        self.assertEqual(generate.head_prompt_version("photograph"), 3)
        self.assertNotEqual(
            generate.head_prompt_version("illustration"),
            generate.head_prompt_version("photograph"))


if __name__ == "__main__":
    unittest.main()
