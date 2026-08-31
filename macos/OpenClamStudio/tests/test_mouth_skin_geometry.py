"""Provider-free soft-3D mouth geometry; no real detector needed by this suite."""
import copy
import hashlib
import unittest
from unittest.mock import patch

import cv2
import numpy as np

from studio import face, mouth_skin


def landmarks(dx=0, dy=0):
    result = np.zeros((478, 2), np.float32)
    angle = np.linspace(0, 2*np.pi, len(face.OUTER_LIP), endpoint=False)
    result[face.OUTER_LIP, 0] = 32+10*np.cos(angle)+dx
    result[face.OUTER_LIP, 1] = 34+6*np.sin(angle)+dy
    return result


class MouthSkinGeometryTests(unittest.TestCase):
    def setUp(self):
        self.key = np.full((64, 64, 3), 50, np.uint8)
        self.sil = np.full_like(self.key, 200)
        self.pp = np.full_like(self.key, 100)
        self.bank = [("sil", self.sil), ("PP", self.pp)]
        self.box = [12, 20, 40, 30]
        self.atlas_box = [8, 16, 48, 36]
        self.logs = []

    def atlas(self, *, families=None, states=None, alpha=255):
        families = families or ["smile"]
        states = states or [0.0, 1.0]
        patches = []
        for i in range(len(families)*len(self.bank)*len(states)):
            img = np.zeros((36, 48, 4), np.uint8)
            img[:, :, :3] = (40+i, 120+i, 200+i)
            img[:, :, 3] = alpha
            patches.append(img)
        spec = {"box": self.atlas_box, "states": states,
                "visemes": ["sil", "PP"], "patches": patches,
                "viseme_x_offsets": {"sil": 0, "PP": 0}}
        if families != ["smile"]:
            spec["emotions"] = families
        return spec

    def run_build(self, smile=None, emotion=None, **kwargs):
        return mouth_skin.build(self.key, self.bank, smile, emotion,
                kwargs.pop("source_medium", "3d render"), log=self.logs.append,
                key_landmarks=landmarks(), mouth_box=self.box, **kwargs)

    def test_photo_2d_unknown_return_before_inspecting_images_or_detecting(self):
        with patch.object(face, "detect", side_effect=AssertionError("must not run")):
            for value in ("photograph", "photorealistic", "illustration", "2d",
                          "cartoon", "anime", "unknown", None, "3d cartoon"):
                with self.subTest(value=value):
                    self.assertIsNone(mouth_skin.build(None, None, None, None, value))

    def test_accepted_3d_spellings_are_explicit(self):
        with patch.object(face, "detect", return_value=(landmarks(), None)):
            for medium in ("3d render", "3d-render", "soft-3d", " Soft-3D "):
                result = self.run_build(source_medium=medium)
                self.assertEqual(1, result["v"])
                self.assertEqual("canonical-pixels", result["space"])
                self.assertEqual({"sil", "PP"}, set(result["contours"]))

    def test_canonical_neutral_not_provider_redrawn_sil(self):
        captured = []
        def detect(image):
            captured.append(image.copy())
            return landmarks(), None
        smile = self.atlas(alpha=0)
        with patch.object(face, "detect", side_effect=detect):
            result = self.run_build(smile=smile)
        self.assertIsNotNone(result)
        # Plain PP, followed by two sil states, followed by two PP states.
        self.assertEqual(5, len(captured))
        self.assertEqual([50, 50, 50], captured[1][34, 32].tolist())
        self.assertEqual([50, 50, 50], captured[2][34, 32].tolist())
        self.assertEqual([100, 100, 100], captured[3][34, 32].tolist())
        self.assertEqual([50, 50, 50], captured[3][4, 4].tolist())

    def test_own_viseme_alpha_and_emotion_row_order(self):
        captured = []
        def detect(image):
            captured.append(image.copy())
            return landmarks(), None
        smile = self.atlas(alpha=0)
        emotion = self.atlas(families=["anger", "sorrow", "horror"], alpha=128)
        with patch.object(face, "detect", side_effect=detect):
            result = self.run_build(smile, emotion)
        self.assertIsNotNone(result)
        self.assertEqual(17, len(captured))
        self.assertEqual({"smile", "anger", "sorrow", "horror"}, set(result["emotion_contours"]))
        for family in result["emotion_contours"].values():
            self.assertEqual({"sil", "PP"}, set(family))
            self.assertTrue(all(len(states) == 2 for states in family.values()))
        expected = np.rint(np.array([40, 120, 200])*128/255+50*(1-128/255)).astype(int)
        np.testing.assert_array_equal(expected, captured[5][34, 32])
        # First emotion's PP cell follows its two sil states; it must not use
        # sil as the backing plate or read a neighbouring atlas row.
        expected_pp = np.rint(np.array([42, 122, 202])*128/255+100*(1-128/255)).astype(int)
        np.testing.assert_array_equal(expected_pp, captured[7][34, 32])

    def test_registration_applied_for_detection_then_removed_from_metadata(self):
        self.pp[:, :, 0] = np.arange(64, dtype=np.uint8)[None, :]
        smile = self.atlas(alpha=0)
        smile["viseme_x_offsets"]["PP"] = 4
        captured = []
        def detect(image):
            captured.append(image.copy())
            pp = int(image[34, 32, 1]) == 100
            return landmarks(dx=4 if pp else 0), None
        with patch.object(face, "detect", side_effect=detect):
            result = self.run_build(smile)
        self.assertIsNotNone(result)
        self.assertEqual(28, int(captured[0][34, 32, 0]))
        self.assertAlmostEqual(32, float(np.asarray(result["contours"]["PP"])[:, 0].mean()), places=4)
        self.assertAlmostEqual(32, float(np.asarray(result["emotion_contours"]["smile"]["PP"][1])[:, 0].mean()), places=4)

    def test_subpixel_atlas_sample_is_premultiplied_not_hidden_rgb(self):
        base = np.full((4, 4, 3), 80, np.uint8)
        patch_rgba = np.zeros((4, 4, 4), np.uint8)
        patch_rgba[:, 1] = [20, 40, 60, 255]
        patch_rgba[:, 0] = [255, 0, 255, 0]  # Must never bleed through.
        result = mouth_skin._with_atlas(base, patch_rgba, (0, 0, 4, 4),
                                       (0, 0, 4, 4), .5)
        np.testing.assert_array_equal([50, 60, 70], result[1, 1])

    def test_registration_over_runtime_point35_width_cap_fails_closed(self):
        smile = self.atlas(alpha=0)
        smile["viseme_x_offsets"]["PP"] = self.box[2] * .4
        with patch.object(face, "detect", return_value=(landmarks(), None)) as detect:
            self.assertIsNone(self.run_build(smile))
        detect.assert_not_called()
        self.assertIn("unsafe mouth registration", self.logs[-1])

    def test_atlas_clipping_does_not_resize_or_read_adjacent_state(self):
        base = np.full((8, 8, 3), 80, np.uint8)
        rgba = np.full((2, 3, 4), 255, np.uint8)
        rgba[:, :, :3] = [5, 10, 15]
        result = mouth_skin._with_atlas(base, rgba, (6, 5, 3, 2),
                                       (2, 2, 8, 8), 0)
        np.testing.assert_array_equal([5, 10, 15], result[3, 4])
        np.testing.assert_array_equal([80, 80, 80], result[3, 3])
        np.testing.assert_array_equal([80, 80, 80], result[5, 4])

    def test_all_selected_states_are_detected_not_reused_plain_geometry(self):
        calls = 0
        def detect(image):
            nonlocal calls
            calls += 1
            return landmarks(dy=calls*.1), None
        with patch.object(face, "detect", side_effect=detect):
            result = self.run_build(self.atlas())
        state0, state1 = result["emotion_contours"]["smile"]["PP"]
        self.assertGreater(np.asarray(state1)[:, 1].mean(), np.asarray(state0)[:, 1].mean())

    def test_missing_one_selected_face_disables_whole_opt_in(self):
        with patch.object(face, "detect", side_effect=[(landmarks(), None), (None, None)]):
            self.assertIsNone(self.run_build(self.atlas()))
        self.assertIn("disabled", self.logs[-1])

    def test_out_of_box_degenerate_and_nonfinite_landmarks_reject(self):
        for altered in (landmarks(dx=32), np.zeros((478, 2)), np.full((478, 2), np.nan)):
            with self.subTest(points=altered[61].tolist()):
                with patch.object(face, "detect", return_value=(altered, None)):
                    self.assertIsNone(self.run_build())

    def test_fewer_than_eight_hull_vertices_rejects_as_runtime_requires(self):
        points = landmarks()
        triangle = np.array([[22, 34], [42, 34], [32, 40]], np.float32)
        points[face.OUTER_LIP] = triangle[np.arange(len(face.OUTER_LIP)) % 3]
        with patch.object(face, "detect", return_value=(points, None)):
            self.assertIsNone(self.run_build())
        self.assertIn("degenerate lip polygon", self.logs[-1])

    def test_inputs_are_byte_identical_after_build(self):
        smile, emotion = self.atlas(), self.atlas(families=["sorrow", "horror", "anger"])
        arrays = [self.key, self.sil, self.pp] + smile["patches"] + emotion["patches"]
        originals = [image.copy() for image in arrays]
        with patch.object(face, "detect", return_value=(landmarks(), None)):
            self.assertIsNotNone(self.run_build(smile, emotion))
        for before, after in zip(originals, arrays):
            np.testing.assert_array_equal(before, after)

    def test_canonical_identity_matches_exact_decoded_pixels_only(self):
        with patch.object(face, "detect", return_value=(landmarks(), None)):
            result = self.run_build()
        expected = {"format": "bgr8", "shape": [64, 64, 3],
                    "sha256": hashlib.sha256(self.key.tobytes()).hexdigest()}
        self.assertEqual(expected, result["canonical_key"])
        self.assertTrue(mouth_skin.matches_key(result, self.key.copy()))
        self.assertTrue(mouth_skin.matches_key(result, np.asfortranarray(self.key)))
        changed = self.key.copy(); changed[0, 0, 0] += 1
        self.assertFalse(mouth_skin.matches_key(result, changed))
        self.assertFalse(mouth_skin.matches_key(result, self.key.reshape(32, 128, 3)))
        self.assertFalse(mouth_skin.matches_key(result, None))
        for attribute, value in (("canonical_key", None), ("v", 2), ("space", "local")):
            stale = copy.deepcopy(result); stale[attribute] = value
            self.assertFalse(mouth_skin.matches_key(stale, self.key))

    def test_bad_atlas_shape_name_count_state_or_offset_rejects(self):
        variations = []
        wrong = self.atlas(); wrong["patches"] = wrong["patches"][:-1]; variations.append(wrong)
        wrong = self.atlas(); wrong["visemes"] = ["sil", "unknown"]; variations.append(wrong)
        wrong = self.atlas(); wrong["states"] = [0, float("nan")]; variations.append(wrong)
        wrong = self.atlas(); wrong["states"] = [1, 0]; variations.append(wrong)
        wrong = self.atlas(); wrong["box"] = [-1, 16, 48, 36]; variations.append(wrong)
        wrong = self.atlas(); wrong["patches"][0] = np.zeros((35, 48, 4), np.uint8); variations.append(wrong)
        wrong = self.atlas(); wrong["viseme_x_offsets"]["PP"] = 80; variations.append(wrong)
        wrong = self.atlas(); wrong["viseme_x_offsets"]["PP"] = float("nan"); variations.append(wrong)
        with patch.object(face, "detect", return_value=(landmarks(), None)):
            for index, spec in enumerate(variations):
                with self.subTest(case=index):
                    self.assertIsNone(self.run_build(spec))


if __name__ == "__main__":
    unittest.main()
