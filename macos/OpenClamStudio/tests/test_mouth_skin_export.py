"""Mouth-skin metadata must describe the pixels the runtime actually receives.

Exercise both real publishers with temporary encoded image banks. Unrelated
face-layer generation is stubbed; JPEG/PNG encoding, metadata identity checks,
mouth-skin construction, and manifest publication run normally.
"""
from contextlib import ExitStack
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import export, face, mouth_skin


class MouthSkinExportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="openclam-mouth-skin-export-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.runtime = self.directory / "runtime"
        self.runtime.mkdir()
        self.visemes = self.directory / "visemes"
        self.visemes.mkdir()
        y, x = np.indices((64, 64))
        # High-frequency colour makes encoding loss measurable. A flat-colour
        # fixture can accidentally accept pre-JPEG arrays as published pixels.
        self.key = np.stack(((x * 17 + y * 7) % 256,
                             (x * 5 + y * 23) % 256,
                             (x * 11 + y * 13) % 256), axis=2).astype(np.uint8)
        self.provider_neutral = np.roll(255 - self.key, 5, axis=1).copy()
        self.pp = np.roll(self.key, 7, axis=0).copy()
        self._write_image(self.directory / "keyframe.png", self.key)
        self._write_image(self.visemes / "v_closed.jpg", self.provider_neutral, 99)
        self._write_image(self.visemes / "v_PP.jpg", self.pp, 99)
        self._write_image(self.visemes / "v_blink.jpg", self.key, 99)
        self.landmarks = np.full((478, 2), 32, np.float32)
        angles = np.linspace(0, 2 * np.pi, len(face.OUTER_LIP), endpoint=False)
        self.landmarks[face.OUTER_LIP, 0] = 32 + 10 * np.cos(angles)
        self.landmarks[face.OUTER_LIP, 1] = 36 + 4 * np.sin(angles)
        self.geometry = export._stylized_mouth_geometry(self.key.shape, self.landmarks)
        self.smile = self._atlas()
        self.emotion = self._atlas(["sorrow", "horror", "anger"])

    def _write_image(self, path, image, quality=None):
        options = [] if quality is None else [cv2.IMWRITE_JPEG_QUALITY, quality]
        self.assertTrue(cv2.imwrite(str(path), image, options))

    def _read(self, path):
        image = cv2.imread(str(path))
        self.assertIsNotNone(image)
        return image

    def _atlas(self, families=None):
        _, _, width, height = self.geometry["box"]
        families = families or ["smile"]
        patches = []
        for index in range(len(families) * 2 * 2):
            patch = np.zeros((height, width, 4), np.uint8)
            patch[:, :, :3] = (40 + index, 90 + index, 150 + index)
            patch[:, :, 3] = 32 + index
            patches.append(patch)
        result = {"box": self.geometry["box"], "states": [0., 1.],
                  "visemes": ["sil", "PP"], "patches": patches,
                  "viseme_x_offsets": {"sil": 0., "PP": 1.25}}
        if families != ["smile"]:
            result["emotions"] = families
        return result

    def _metadata(self, neutral):
        polygon = self.landmarks[face.OUTER_LIP].astype(float).tolist()
        return {"v": 1, "space": "canonical-pixels",
                "canonical_key": {
                    "format": "bgr8", "shape": list(neutral.shape),
                    "sha256": hashlib.sha256(neutral.tobytes()).hexdigest()},
                "contours": {"sil": polygon, "PP": polygon},
                "emotion_contours": {}, "retained_marker": "approved-bank"}

    def _seed_runtime(self, *, quality=92, metadata=None):
        self._write_image(self.runtime / "sil_open.jpg", self.key, quality)
        self._write_image(self.runtime / "PP_open.jpg", self.pp, 92)
        self._write_image(self.runtime / "smile.png", np.vstack(self.smile["patches"]))
        self._write_image(self.runtime / "emotion-mouth.png",
                          np.vstack(self.emotion["patches"]))
        neutral = self._read(self.runtime / "sil_open.jpg")
        skin = self._metadata(neutral) if metadata is None else metadata
        manifest = {"v": export.RUNTIME_VERSION,
                    "frames": {"sil": {"open": "assets/sil_open.jpg"},
                               "PP": {"open": "assets/PP_open.jpg"}},
                    "eyes": {}, "source_medium": "3d render",
                    "stylized_mouth": {
                        **self.geometry,
                        "viseme_x_offsets": self.smile["viseme_x_offsets"],
                        "skin_match": skin}}
        (self.runtime / "manifest.json").write_text(json.dumps(manifest))
        return skin

    def _published_manifest(self):
        return json.loads((self.runtime / "manifest.json").read_text())

    def _source_manifest(self, medium):
        return {"status": "ready", "name": "Fixture",
                "source_metrics": {"source_medium": medium}}

    def _common_patches(self, stack, medium):
        stack.enter_context(mock.patch.object(export.reg, "adir",
                                              return_value=str(self.directory)))
        stack.enter_context(mock.patch.object(export.reg, "read_manifest",
                                              return_value=self._source_manifest(medium)))
        stack.enter_context(mock.patch.object(export.face, "detect_for_intake",
                                              return_value=(self.landmarks, np.eye(4), {})))
        stack.enter_context(mock.patch.object(export.face, "detect",
                                              return_value=(self.landmarks, np.eye(4))))
        stack.enter_context(mock.patch.object(export.cutout, "render", return_value={}))
        stack.enter_context(mock.patch.object(export, "_publish_motion", return_value=None))
        stack.enter_context(mock.patch.object(export, "_publish_stylized_blink_source",
                                              return_value=None))

    def _publish_pet(self, medium="3d render"):
        with ExitStack() as stack:
            self._common_patches(stack, medium)
            rebuild = stack.enter_context(mock.patch.object(
                mouth_skin, "build", side_effect=AssertionError("Pet refresh rebuilt face metadata")))
            result = export.publish_pet_assets("fixture", runtime_dir=str(self.runtime),
                                               log=lambda _: None)
            rebuild.assert_not_called()
        self.assertEqual(result, self._published_manifest())
        return result

    def _export(self, medium="3d render", *, reject_metadata=False, gaze_metadata=None):
        def layer(count=1):
            return {side: {"box": [1, 1, 2, 2],
                           "patches": [np.zeros((2, 2, 4), np.uint8)
                                       for _ in range(count)]}
                    for side in export.blink.SIDES}
        expression = {"gaze": {**layer(), "dxs": [0.], "dys": [0.]},
                      "brow": {**layer(), "dys": [0.], "sqs": [0.]},
                      "forehead": {**layer(), "dys": [0.], "sqs": [0.]},
                      "cheek": {**layer(), "ups": [0.]},
                      "eyebag": {**layer(), "ups": [0.]}}
        expression["gaze"].update(gaze_metadata or {})
        with ExitStack() as stack:
            self._common_patches(stack, medium)
            stack.enter_context(mock.patch.object(export, "NAME_MAP",
                                                  {"sil": "closed", "PP": "PP"}))
            stack.enter_context(mock.patch.object(export.blink, "build",
                                                  return_value={"eyes": layer(2), "states": [0., 1.]}))
            stack.enter_context(mock.patch.object(export.expression, "build", return_value=expression))
            stack.enter_context(mock.patch.object(export.expression, "build_smile", return_value=self.smile))
            stack.enter_context(mock.patch.object(export.expression, "build_emotion_mouths",
                                                  return_value=self.emotion))
            options = {"return_value": None} if reject_metadata else {"wraps": mouth_skin.build}
            measured = stack.enter_context(mock.patch.object(mouth_skin, "build", **options))
            result = export.export("fixture", str(self.runtime), quality=37, states=2,
                                   log=lambda _: None)
        self.assertEqual(result, self._published_manifest())
        return result, measured

    def test_full_export_preserves_measured_gaze_geometry_without_changing_mouth(self):
        geometry = {
            side: {"mode": "soft-3d-rigid-iris-v1", "centre": [24., 25.],
                   "diameters": [12., 12.5], "angle": 3.,
                   "max_translation": [3., 2.]}
            for side in export.blink.SIDES
        }
        result, measured = self._export(gaze_metadata={
            "mode": "soft-3d-rigid-iris-v1", "geometry": geometry})
        self.assertEqual(result["gaze"]["geometry"], geometry)
        self.assertEqual(result["gaze"]["mode"], "soft-3d-rigid-iris-v1")
        for side in export.blink.SIDES:
            self.assertEqual(result["gaze"][side]["src"], f"assets/gaze_{side}.png")
        measured.assert_called_once()
        self.assertIn("skin_match", result["stylized_mouth"])

    def test_full_export_does_not_invent_rigid_geometry_on_legacy_gaze(self):
        result, _ = self._export(medium="illustration")
        self.assertNotIn("mode", result["gaze"])
        self.assertNotIn("geometry", result["gaze"])

    def test_pet_refresh_retains_exact_decoded_neutral_and_unchanged_face_bank(self):
        skin = self._seed_runtime()
        self.assertFalse(np.array_equal(self.key, self._read(self.runtime / "sil_open.jpg")))
        before = {path.name: path.read_bytes() for path in self.runtime.iterdir()
                  if path.suffix in {".jpg", ".png"}}
        result = self._publish_pet()
        self.assertEqual(skin, result["stylized_mouth"]["skin_match"])
        self.assertEqual(self.smile["viseme_x_offsets"],
                         result["stylized_mouth"]["viseme_x_offsets"])
        for name, payload in before.items():
            self.assertEqual(payload, (self.runtime / name).read_bytes(), name)

    def test_pet_refresh_discards_metadata_for_a_changed_canonical_key(self):
        self._seed_runtime()
        self._write_image(self.directory / "keyframe.png", 255 - self.key)
        result = self._publish_pet()
        self.assertNotIn("skin_match", result["stylized_mouth"])

    def test_pet_refresh_discards_metadata_when_only_jpeg_encoding_changes(self):
        skin = self._seed_runtime(quality=37)
        old_decoded = self._read(self.runtime / "sil_open.jpg")
        self.assertTrue(mouth_skin.matches_key(skin, old_decoded))
        result = self._publish_pet()
        new_decoded = self._read(self.runtime / "sil_open.jpg")
        self.assertFalse(np.array_equal(old_decoded, new_decoded))
        self.assertNotIn("skin_match", result["stylized_mouth"])
        np.testing.assert_array_equal(self.key, self._read(self.directory / "keyframe.png"))

    def test_pet_refresh_does_not_accept_pre_jpeg_key_identity(self):
        skin = self._seed_runtime(metadata=self._metadata(self.key))
        self.assertTrue(mouth_skin.matches_key(skin, self.key))
        self.assertFalse(mouth_skin.matches_key(skin, self._read(self.runtime / "sil_open.jpg")))
        self.assertNotIn("skin_match", self._publish_pet()["stylized_mouth"])

    def test_pet_refresh_drops_invalid_metadata_without_dropping_other_mouth_fields(self):
        for field, value in (("v", 0), ("space", "unknown"), ("canonical_key", None)):
            with self.subTest(field=field):
                skin = self._seed_runtime()
                malformed = copy.deepcopy(skin)
                malformed[field] = value
                self._seed_runtime(metadata=malformed)
                result = self._publish_pet()
                self.assertNotIn("skin_match", result["stylized_mouth"])
                self.assertEqual(self.smile["viseme_x_offsets"],
                                 result["stylized_mouth"]["viseme_x_offsets"])

    def test_pet_refresh_never_retains_3d_metadata_on_photo_or_2d_routes(self):
        for medium in ("photograph", "illustration", "anime", "unknown"):
            with self.subTest(medium=medium):
                self._seed_runtime()
                result = self._publish_pet(medium)
                self.assertNotIn("skin_match", result.get("stylized_mouth") or {})

    def test_full_export_measures_decoded_published_bytes_and_exact_atlas_cells(self):
        result, measured = self._export()
        measured.assert_called_once()
        neutral, bank, smile, emotion, medium = measured.call_args.args
        decoded_neutral = self._read(self.runtime / "sil_open.jpg")
        np.testing.assert_array_equal(decoded_neutral, neutral)
        self.assertFalse(np.array_equal(self.key, neutral), "fixture must expose JPEG loss")
        self.assertFalse(np.array_equal(self._read(self.visemes / "v_closed.jpg"), neutral))
        self.assertEqual(["sil", "PP"], [name for name, _ in bank])
        for name, pixels in bank:
            np.testing.assert_array_equal(self._read(self.runtime / f"{name}_open.jpg"), pixels)
        self.assertFalse(np.array_equal(self._read(self.visemes / "v_PP.jpg"), bank[1][1]))
        self.assertIs(smile, self.smile)
        self.assertIs(emotion, self.emotion)
        for filename, atlas in (("smile.png", smile), ("emotion-mouth.png", emotion)):
            np.testing.assert_array_equal(
                np.vstack(atlas["patches"]),
                cv2.imread(str(self.runtime / filename), cv2.IMREAD_UNCHANGED))
        self.assertEqual("3d render", medium)
        self.assertEqual(self.geometry["box"], measured.call_args.kwargs["mouth_box"])
        self.assertNotIn("key_landmarks", measured.call_args.kwargs,
                         "JPEG mouth geometry must be measured, not supplied from the PNG")
        self.assertTrue(mouth_skin.matches_key(result["stylized_mouth"]["skin_match"], neutral))
        self.assertEqual({"smile", "sorrow", "horror", "anger"},
                         set(result["stylized_mouth"]["skin_match"]["emotion_contours"]))

    def test_full_export_photo_and_2d_do_not_invoke_the_optional_3d_builder(self):
        for medium in ("photograph", "illustration", "anime", "unknown"):
            with self.subTest(medium=medium):
                result, measured = self._export(medium)
                measured.assert_not_called()
                self.assertNotIn("skin_match", result.get("stylized_mouth") or {})

    def test_full_export_optional_geometry_rejection_preserves_existing_face_pipeline(self):
        result, measured = self._export(reject_metadata=True)
        measured.assert_called_once()
        self.assertNotIn("skin_match", result["stylized_mouth"])
        self.assertEqual(["sil", "PP"], result["visemes"])
        self.assertEqual(self.smile["viseme_x_offsets"], result["stylized_mouth"]["viseme_x_offsets"])
        self.assertTrue((self.runtime / "smile.png").is_file())
        self.assertTrue((self.runtime / "emotion-mouth.png").is_file())


if __name__ == "__main__":
    unittest.main()
