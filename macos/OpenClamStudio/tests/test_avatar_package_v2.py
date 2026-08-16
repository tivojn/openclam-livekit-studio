"""Security and compatibility tests for both OpenClam AVTR v2 profiles."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

import jsonschema
from PIL import Image

from server import avatar_package as package


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = PROJECT_ROOT / "contracts" / "avatar-package-v2"
SUITE_SCHEMA_ROOT = PROJECT_ROOT.parents[1] / "shared" / "avatar-package-v2"


def png(path: Path, size=(16, 16), color=(120, 80, 50, 255)) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", size, color).save(path, format="PNG")


def jpg(path: Path, size=(1024, 1024), color=(120, 80, 50)) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, color).save(path, format="JPEG", quality=90)


def make_authoring(root: Path, identifier="nova") -> Path:
    avatar = root / identifier
    (avatar / "visemes").mkdir(parents=True)
    (avatar / "raw").mkdir()
    (avatar / "body").mkdir()
    (avatar / "motion" / "raw").mkdir(parents=True)
    (avatar / "library" / "motion" / "move" / "wave").mkdir(parents=True)
    (avatar / "runtime").mkdir()
    (avatar / "diag").mkdir()
    (avatar / ".motion-cache").mkdir()
    (avatar / "manifest.json").write_text(json.dumps({
        "slug": identifier, "name": "Nova", "status": "ready",
    }))
    png(avatar / "keyframe.png", (1024, 1024))
    jpg(avatar / "visemes" / "v_closed.jpg")
    png(avatar / "raw" / "identity-source.png", (1024, 1024))
    (avatar / "body" / "body.json").write_text("{}")
    png(avatar / "body" / "body.png", (512, 768))
    png(avatar / "body" / "head-mask.png", (1024, 1024))
    (avatar / "motion" / "motion.json").write_text(json.dumps({
        "walk": {"sheets": ["walk.png"]},
        "idle": {"sheets": ["idle.png"]},
        "move": {"sheets": ["wave.png"]},
    }))
    (avatar / "motion" / "raw" / "walk-source.mp4").write_bytes(b"video")
    (avatar / "library" / "motion" / "move" / "wave" / "set.json").write_text("{}")
    (avatar / "runtime" / "manifest.json").write_text("{}")
    (avatar / "diag" / "provider.log").write_text("never export")
    (avatar / ".motion-cache" / "signature").write_text("never export")
    return avatar


def make_runtime(authoring: Path) -> Path:
    runtime = authoring / "runtime"
    runtime.mkdir(exist_ok=True)
    png(runtime / "body.png", (512, 768))
    png(runtime / "head-mask.png", (1024, 1024))
    for name in package.IOS_VISEMES:
        jpg(runtime / f"{name}_open.jpg")

    boxes = {
        "eye_l": [560, 480, 8, 6],
        "eye_r": [456, 480, 8, 6],
        "brow_l": [560, 450, 8, 4],
        "brow_r": [456, 450, 8, 4],
        "gaze_l": [560, 490, 6, 5],
        "gaze_r": [456, 490, 6, 5],
    }
    png(runtime / "eye_l.png", (8, 6 * 8))
    png(runtime / "eye_r.png", (8, 6 * 8))
    png(runtime / "brow_l.png", (8, 4 * 14 * 3))
    png(runtime / "brow_r.png", (8, 4 * 14 * 3))
    png(runtime / "gaze_l.png", (6, 5 * 25 * 11))
    png(runtime / "gaze_r.png", (6, 5 * 25 * 11))
    manifest = {
        "v": 16,
        "w": 1024,
        "h": 1024,
        "frames": {
            name: {"open": f"assets/{name}_open.jpg"}
            for name in package.IOS_VISEMES
        },
        "eyes": {
            "states": [index / 7 for index in range(8)],
            "l": {"src": "assets/eye_l.png", "box": boxes["eye_l"]},
            "r": {"src": "assets/eye_r.png", "box": boxes["eye_r"]},
        },
        "brow": {
            "dys": list(range(14)), "sqs": [0, 1, 2],
            "l": {"src": "assets/brow_l.png", "box": boxes["brow_l"]},
            "r": {"src": "assets/brow_r.png", "box": boxes["brow_r"]},
        },
        "gaze": {
            "dxs": list(range(25)), "dys": list(range(11)),
            "l": {"src": "assets/gaze_l.png", "box": boxes["gaze_l"]},
            "r": {"src": "assets/gaze_r.png", "box": boxes["gaze_r"]},
        },
        "body": {
            "image": "assets/body.png",
            "head_mask": "assets/head-mask.png",
            "width": 512,
            "height": 768,
            "face_transform": [[0.25, 0, 128], [0, 0.25, 64]],
            "alignment": {"face_bounds": [150, 80, 212, 220]},
        },
    }
    (runtime / "manifest.json").write_text(json.dumps(manifest))
    return runtime


class AvatarContractParityTests(unittest.TestCase):
    def test_vendored_schemas_match_suite_contract_when_both_exist(self):
        for name in ("README.md", "manifest.schema.json", "macos-full.schema.json"):
            local = SCHEMA_ROOT / name
            self.assertTrue(local.is_file())
            shared = SUITE_SCHEMA_ROOT / name
            if shared.is_file():
                self.assertEqual(local.read_bytes(), shared.read_bytes())

    def test_ios_schema_rejects_legacy_format_alias(self):
        schema = json.loads((SCHEMA_ROOT / "manifest.schema.json").read_text())
        manifest = json.loads(
            (SUITE_SCHEMA_ROOT / "fixtures" / "ios-light-golden.manifest.json")
            .read_text()
        )
        jsonschema.Draft202012Validator(schema).validate(manifest)
        manifest["format"] = "vivieen-avatar"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(manifest)


class MacFullAvatarPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_round_trip_preserves_authoring_and_rejects_runtime_data(self):
        source = make_authoring(self.root / "source")
        archive = self.root / "Nova-Mac.avtr"
        manifest = package.export_macos_full("nova", source, archive)
        self.assertEqual(manifest["variant"], "macos-full")
        self.assertEqual(manifest["capabilities"], {
            "head": True, "fullBody": True, "walk": True,
            "edgeIdle": True, "moves": True,
        })
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            self.assertEqual(names[0], "manifest.json")
            self.assertIn("authoring/raw/identity-source.png", names)
            self.assertIn("authoring/body/body.png", names)
            self.assertIn("authoring/motion/raw/walk-source.mp4", names)
            self.assertFalse(any("runtime" in name for name in names))
            self.assertFalse(any("diag" in name for name in names))
            self.assertFalse(any("cache" in name for name in names))
            jsonschema.Draft202012Validator(
                json.loads((SCHEMA_ROOT / "macos-full.schema.json").read_text())
            ).validate(json.loads(bundle.read("manifest.json")))

        installed = self.root / "installed"
        seen = []
        result = package.import_macos_full(
            archive, installed, lambda written, total: seen.append((written, total))
        )
        self.assertEqual(result["slug"], "nova")
        self.assertEqual(result["variant"], "macos-full")
        self.assertTrue((installed / "nova" / "raw" / "identity-source.png").is_file())
        self.assertTrue((installed / "nova" / "motion" / "raw" / "walk-source.mp4").is_file())
        self.assertFalse((installed / "nova" / "runtime").exists())
        self.assertEqual(seen[-1][0], seen[-1][1])

    def test_collision_installs_a_new_identifier_without_overwrite(self):
        source = make_authoring(self.root / "source")
        archive = self.root / "Nova-Mac.avtr"
        package.export_macos_full("nova", source, archive)
        installed = self.root / "installed"
        (installed / "nova").mkdir(parents=True)
        (installed / "nova" / "sentinel").write_text("keep")
        result = package.import_macos_full(archive, installed)
        self.assertEqual(result["slug"], "nova-2")
        self.assertEqual((installed / "nova" / "sentinel").read_text(), "keep")

    def test_import_rejects_legacy_format_alias(self):
        source = make_authoring(self.root / "source")
        original = self.root / "Nova-Mac.avtr"
        package.export_macos_full("nova", source, original)
        legacy = self.root / "legacy-format.avtr"
        with zipfile.ZipFile(original) as source_zip, zipfile.ZipFile(legacy, "w") as out:
            for info in source_zip.infolist():
                content = source_zip.read(info)
                if info.filename == "manifest.json":
                    manifest = json.loads(content)
                    manifest["format"] = "vivieen-avatar"
                    content = json.dumps(manifest).encode("utf-8")
                out.writestr(info, content)
        with self.assertRaises(package.AvatarPackageError):
            package.import_macos_full(legacy, self.root / "installed")

    def test_rejects_hash_tampering_extra_entries_and_symlinks(self):
        source = make_authoring(self.root / "source")
        original = self.root / "Nova-Mac.avtr"
        package.export_macos_full("nova", source, original)

        tampered = self.root / "tampered.avtr"
        with zipfile.ZipFile(original) as source_zip, zipfile.ZipFile(tampered, "w") as out:
            for info in source_zip.infolist():
                content = source_zip.read(info)
                if info.filename == "authoring/keyframe.png":
                    content += b"altered"
                out.writestr(info, content)
        with self.assertRaises(package.AvatarPackageError):
            package.import_macos_full(tampered, self.root / "one")

        extra = self.root / "extra.avtr"
        shutil.copy2(original, extra)
        with zipfile.ZipFile(extra, "a") as archive:
            archive.writestr("authoring/unlisted.txt", "extra")
        with self.assertRaises(package.AvatarPackageError):
            package.import_macos_full(extra, self.root / "two")

        linked = self.root / "linked.avtr"
        shutil.copy2(original, linked)
        with zipfile.ZipFile(linked, "a") as archive:
            info = zipfile.ZipInfo("authoring/link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "manifest.json")
        with self.assertRaises(package.AvatarPackageError):
            package.import_macos_full(linked, self.root / "three")

    def test_export_rejects_credential_shaped_authoring_text(self):
        source = make_authoring(self.root / "source")
        (source / "notes.json").write_text(
            '{"api_key":"sk-' + ('a' * 32) + '"}'
        )
        with self.assertRaises(package.AvatarPackageError):
            package.export_macos_full("nova", source, self.root / "bad.avtr")


class IOSLightAvatarPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.authoring = make_authoring(self.root / "source")
        self.runtime = make_runtime(self.authoring)

    def test_export_is_exact_ios_contract_and_converts_gaze_atlases(self):
        archive = self.root / "Nova-iPhone.avtr"
        manifest = package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, archive
        )
        self.assertEqual(manifest["variant"], "ios-light")
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(len(bundle.infolist()), 19)
            self.assertFalse(any(info.is_dir() for info in bundle.infolist()))
            names = set(bundle.namelist())
            self.assertEqual(names, {
                "manifest.json",
                *{f"assets/{value}" for value in package.IOS_ROLE_FILENAMES.values()},
            })
            loaded = json.loads(bundle.read("manifest.json"))
            jsonschema.Draft202012Validator(
                json.loads((SCHEMA_ROOT / "manifest.schema.json").read_text())
            ).validate(loaded)
            self.assertFalse(any(
                word in name.lower()
                for name in names
                for word in ("raw", "source", "prompt", "motion", "history", "key")
            ))
            with Image.open(bundle.open("assets/gaze-left-atlas.png")) as atlas:
                self.assertEqual(atlas.size, (6 * 25, 5 * 11))
            self.assertEqual(loaded["rig"]["faceTransform"], {
                "a": 0.25, "b": 0.0, "c": 0.0, "d": 0.25,
                "tx": 128.0, "ty": 64.0,
            })
            for asset in loaded["assets"].values():
                content = bundle.read(asset["path"])
                self.assertEqual(len(content), asset["byteCount"])
                self.assertEqual(hashlib.sha256(content).hexdigest(), asset["sha256"])

    def test_missing_body_or_incompatible_gaze_fails_without_output(self):
        destination = self.root / "bad.avtr"
        runtime_manifest = json.loads((self.runtime / "manifest.json").read_text())
        runtime_manifest["body"] = None
        (self.runtime / "manifest.json").write_text(json.dumps(runtime_manifest))
        with self.assertRaises(package.AvatarPackageError):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime, destination
            )
        self.assertFalse(destination.exists())

        make_runtime(self.authoring)
        png(self.runtime / "gaze_l.png", (6, 5 * 274))
        with self.assertRaises(package.AvatarPackageError):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime, destination
            )
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
