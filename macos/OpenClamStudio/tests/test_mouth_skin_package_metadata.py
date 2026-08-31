"""Optional v4 soft-3D contour metadata, with no image or legacy changes."""
from __future__ import annotations

import copy
import hashlib
import json
import math
import tempfile
import unittest
import zipfile
from pathlib import Path

import jsonschema

from server import avatar_package as package
from tests.test_avatar_package_v2 import (
    SCHEMA_ROOT, SUITE_SCHEMA_ROOT, add_full_expression_runtime,
    configure_stylized_body_replacement, make_authoring, make_runtime,
)


def metadata(vertices=12):
    def polygon(shift=0):
        return [[round(511 + shift + 42 * math.cos(i * math.tau / vertices), 4),
                 round(752 + 13 * math.sin(i * math.tau / vertices), 4)]
                for i in range(vertices)]
    return {
        "v": 1, "space": "canonical-pixels",
        "canonical_key": {"format": "bgr8", "shape": [1024, 1024, 3],
                          "sha256": "a" * 64},
        "contours": {name: polygon(i * .1) for i, name in enumerate(package.IOS_VISEMES)},
        "emotion_contours": {
            family: {name: [polygon(i * .1 + s * .05) for s in range(count)]
                     for i, name in enumerate(package.IOS_VISEMES)}
            for family, count in package.IOS_MOUTH_SKIN_FAMILIES.items()
        },
    }


class MouthSkinPackageMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openclam-mouth-metadata-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.authoring = make_authoring(self.root)
        self.runtime = make_runtime(self.authoring)
        configure_stylized_body_replacement(
            self.authoring, self.runtime, source_medium="3d render"
        )
        add_full_expression_runtime(self.runtime)
        self.runtime_path = self.runtime / "manifest.json"
        self.manifest = json.loads(self.runtime_path.read_text())
        self.mouth = self.manifest["stylized_mouth"]
        self.mouth["box"] = [391, 694, 242, 124]
        self.mouth["viseme_x_offsets"] = {name: 0.0 for name in package.IOS_VISEMES}
        self.mouth["viseme_x_offsets"]["aa"] = 1.25
        self.expression = package._expression_geometry(self.manifest)

    def speech(self, medium="3d render"):
        return package._stylized_speech_patch(self.manifest, medium, self.expression)

    def export(self, name):
        self.runtime_path.write_text(json.dumps(self.manifest))
        destination = self.root / name
        manifest = package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, destination
        )
        with zipfile.ZipFile(destination) as archive:
            files = {entry: archive.read(entry) for entry in archive.namelist()}
        return manifest, files, destination.read_bytes()

    def test_absent_metadata_keeps_the_legacy_speech_contract(self):
        self.assertEqual(set(self.speech()), {"box", "visemeXOffsets"})

    def test_complete_plain_and_per_state_contours_preserve_coordinates(self):
        source = metadata()
        self.mouth["skin_match"] = copy.deepcopy(source)
        result = self.speech()["skinMatch"]
        self.assertEqual(result, {k: v for k, v in source.items() if k != "canonical_key"})
        self.assertEqual(self.mouth["skin_match"], source)
        self.assertEqual(sum(len(v) for f in result["emotion_contours"].values()
                             for v in f.values()) + len(result["contours"]), 270)
        self.assertNotIn("canonical_key", result)

    def test_photographs_illustrations_and_unknown_media_never_opt_in(self):
        for medium in ("photograph", "illustration", "anime", "game art", "unknown"):
            with self.subTest(medium=medium):
                before = self.speech(medium)
                self.mouth["skin_match"] = {"malformed": "must not change legacy routing"}
                self.assertEqual(self.speech(medium), before)
                self.mouth.pop("skin_match")

    def test_rejects_malformed_version_space_banks_and_states(self):
        mutations = [
            lambda m: m.update(v=True), lambda m: m.update(v=2),
            lambda m: m.update(v=1.0), lambda m: m.update(space="mouth-local"),
            lambda m: m.update(debug={}), lambda m: m["contours"].pop("TH"),
            lambda m: m["contours"].update(extra=[]),
            lambda m: m["emotion_contours"].pop("horror"),
            lambda m: m["emotion_contours"].update(extra={}),
            lambda m: m["emotion_contours"]["anger"].pop("ou"),
            lambda m: m["emotion_contours"]["smile"]["sil"].pop(),
            lambda m: m["emotion_contours"]["sorrow"]["FF"].append([]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value = metadata()
                mutate(value)
                self.mouth["skin_match"] = value
                with self.assertRaisesRegex(package.AvatarPackageError, "skin geometry is invalid"):
                    self.speech()
        for value in (None, [], False, "metadata"):
            self.mouth["skin_match"] = value
            with self.assertRaises(package.AvatarPackageError):
                self.speech()

    def test_rejects_non_numeric_nonfinite_and_outside_owner_points(self):
        for value in (True, "512", math.nan, math.inf, -1, 1025, 5, 1000):
            with self.subTest(value=value):
                self.mouth["skin_match"] = metadata()
                self.mouth["skin_match"]["contours"]["aa"][0][0] = value
                with self.assertRaises(package.AvatarPackageError):
                    self.speech()
        self.mouth["skin_match"] = metadata()
        self.mouth["skin_match"]["emotion_contours"]["horror"]["ou"][3][0] = [512, 750, 0]
        with self.assertRaises(package.AvatarPackageError):
            self.speech()

    def test_rejects_crossed_duplicate_degenerate_and_excessive_polygons(self):
        good = metadata()["contours"]["sil"]
        crossed = copy.deepcopy(good)
        crossed[2], crossed[8] = crossed[8], crossed[2]
        ring = metadata(vertices=9)["contours"]["sil"]
        star = [ring[(i * 2) % 9] for i in range(9)]
        for value in (good[:7], good * 6, good[:-1] + [good[0]], crossed, star,
                      [[500 + i, 750] for i in range(8)]):
            self.mouth["skin_match"] = metadata()
            self.mouth["skin_match"]["contours"]["sil"] = value
            with self.assertRaises(package.AvatarPackageError):
                self.speech()

    def test_registration_matches_renderer_35_percent_bound(self):
        self.mouth["skin_match"] = metadata()
        self.mouth["viseme_x_offsets"]["aa"] = 242 * .35
        self.assertIn("skinMatch", self.speech())
        self.mouth["viseme_x_offsets"]["aa"] += .001
        with self.assertRaises(package.AvatarPackageError):
            self.speech()

    def test_metadata_has_its_own_bounded_serialized_size(self):
        self.mouth["skin_match"] = metadata(vertices=64)
        with self.assertRaisesRegex(package.AvatarPackageError, "skin geometry is too large"):
            self.speech()

    def test_export_is_manifest_only_reproducible_and_preserves_every_image(self):
        baseline, before_files, _ = self.export("legacy.avtr")
        protected = {str(p.relative_to(self.runtime)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in self.runtime.iterdir() if p.is_file() and p.name != "manifest.json"}
        self.mouth["skin_match"] = metadata()
        manifest, files, first = self.export("geometry.avtr")
        _, _, second = self.export("geometry-again.avtr")
        self.assertEqual(first, second)
        self.assertEqual({k: v for k, v in files.items() if k != "manifest.json"},
                         {k: v for k, v in before_files.items() if k != "manifest.json"})
        without_optional = copy.deepcopy(manifest)
        without_optional["speechPatch"].pop("skinMatch")
        self.assertEqual(without_optional, baseline)
        self.assertLessEqual(len(files["manifest.json"]), package.MAX_MANIFEST_BYTES)
        self.assertEqual(protected, {str(p.relative_to(self.runtime)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in self.runtime.iterdir() if p.is_file() and p.name != "manifest.json"})
        for schema_root in (SCHEMA_ROOT, SUITE_SCHEMA_ROOT):
            schema = json.loads((schema_root / "ios-full-expression-v4.schema.json").read_text())
            validator = jsonschema.Draft202012Validator(schema)
            validator.validate(manifest)
            for medium in ("photograph", "illustration", None):
                changed = copy.deepcopy(manifest)
                if medium is None:
                    changed.pop("sourceMedium")
                else:
                    changed["sourceMedium"] = medium
                self.assertFalse(validator.is_valid(changed))

    def test_photo_and_2d_full_exports_are_byte_identical(self):
        for medium in ("photograph", "illustration"):
            with self.subTest(medium=medium):
                path = self.authoring / "manifest.json"
                authoring = json.loads(path.read_text())
                authoring["source_metrics"]["source_medium"] = medium
                path.write_text(json.dumps(authoring))
                self.mouth.pop("skin_match", None)
                _, _, before = self.export(f"{medium}-before.avtr")
                self.mouth["skin_match"] = {"malformed": True}
                _, _, after = self.export(f"{medium}-after.avtr")
                self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
