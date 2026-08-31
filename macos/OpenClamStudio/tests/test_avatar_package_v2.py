"""Security and compatibility tests for both OpenClam AVTR v2 profiles."""
from __future__ import annotations

import hashlib
import io
import json
import math
import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import jsonschema
from PIL import Image, PngImagePlugin

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


def quicktime(path: Path, marker=b"motion") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x00\x00\x00\x14ftypqt  \x00\x00\x02\x00qt  " + marker)


def motion_probe(*, codec="hevc", audio=0, alpha=True, duration=6083) -> dict:
    return {
        "streamCount": 1 + audio,
        "videoTracks": 1,
        "audioTracks": audio,
        "formatNames": ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"],
        "codecName": codec,
        "codecTag": "hvc1" if codec == "hevc" else "avc1",
        "width": 720,
        "height": 1088,
        "durationMilliseconds": duration,
        "hasAlpha": alpha,
    }


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
    (avatar / ".wardrobe.json").write_text(json.dumps({
        "version": 3,
        "digest": "portrait-analysis-cache",
        "prompt": "recomputable tailored wardrobe prompt",
    }))
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


def configure_stylized_body_replacement(
    authoring: Path,
    runtime: Path,
    *,
    source_medium: str = "illustration",
) -> None:
    """Author one explicit replacement body with a visibly different bake."""
    authoring_manifest_path = authoring / "manifest.json"
    authoring_manifest = json.loads(authoring_manifest_path.read_text())
    authoring_manifest["source_metrics"] = {"source_medium": source_medium}
    authoring_manifest_path.write_text(json.dumps(authoring_manifest))

    runtime_manifest_path = runtime / "manifest.json"
    runtime_manifest = json.loads(runtime_manifest_path.read_text())
    runtime_body = runtime_manifest["body"]
    runtime_body["head_composite"] = "replace"
    runtime_body["head_handoff_version"] = package.STYLIZED_HEAD_HANDOFF_VERSION
    runtime_body["head_clear_mask"] = "assets/head-clear-mask.png"
    runtime_body["options"] = {"style": "anime", "medium": "anime"}
    runtime_manifest_path.write_text(json.dumps(runtime_manifest))
    png(
        runtime / "head-clear-mask.png",
        (runtime_body["width"], runtime_body["height"]),
        color=(255, 255, 255, 255),
    )

    authored_body = {
        "image": "body.png",
        "head_mask": "head-mask.png",
        "head_composite": "replace",
        "head_handoff_version": package.STYLIZED_HEAD_HANDOFF_VERSION,
        "head_clear_mask": "head-clear-mask.png",
        "width": runtime_body["width"],
        "height": runtime_body["height"],
        "face_transform": runtime_body["face_transform"],
        "alignment": runtime_body["alignment"],
        "options": {"style": "anime", "medium": "anime"},
        "views": {"front": {"preview_image": "body-composite.png"}},
    }
    (authoring / "body" / "body.json").write_text(json.dumps(authored_body))
    png(
        authoring / "body" / "body-composite.png",
        (runtime_body["width"], runtime_body["height"]),
        color=(240, 30, 40, 255),
    )
    shutil.copy2(
        runtime / "head-clear-mask.png",
        authoring / "body" / "head-clear-mask.png",
    )


def add_runtime_motions(runtime: Path, kinds=("idle", "move")) -> None:
    manifest_path = runtime / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    motion = {}
    for index, kind in enumerate(kinds):
        filename = f"motion-{kind}.mov"
        quicktime(runtime / filename, f"clip-{index}".encode())
        motion[kind] = {
            "fps": 12,
            "frames": 73,
            "frame_width": 720,
            "frame_height": 1088,
            "alpha_stream_hevc": f"assets/{filename}",
            "alpha_stream": f"assets/motion-{kind}.webm",
            "rawSource": f"/private/owned-avatar/raw/{kind}.mov",
            "providerPrompt": "never serialize this authoring prompt",
            "apiKey": "sk-" + ("n" * 32),
        }
    manifest["motion"] = motion
    manifest_path.write_text(json.dumps(manifest))


def add_full_expression_runtime(runtime: Path) -> None:
    manifest_path = runtime / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["v"] = 22
    brow = manifest["brow"]
    brow["dys"] = [-5, -3.5, -2, -1, 0, .75, 1.5, 2.5, 4, 6, 8, 10, 12, 14]
    brow["sqs"] = [-3, 0, 4]

    smile_box = [400, 700, 12, 6]
    forehead_l = [550, 380, 9, 8]
    forehead_r = [450, 380, 9, 8]
    cheek_l = [560, 600, 8, 6]
    cheek_r = [456, 600, 8, 6]
    under_l = [560, 550, 7, 4]
    under_r = [456, 550, 7, 4]
    smile_states = [0, .18, .34, .68, 1]
    emotion_states = [0, .34, .68, 1]
    cheek_states = [0, .8, 1.6, 2.45, 3.3]
    under_states = [0, .5, 1, 1.6, 2.3]
    png(runtime / "smile.png", (12, 6 * len(smile_states) * len(package.IOS_VISEMES)))
    png(runtime / "emotion-mouth.png", (
        12, 6 * len(emotion_states) * len(package.IOS_VISEMES) * 3
    ))
    png(runtime / "forehead_l.png", (9, 8 * 14 * 3))
    png(runtime / "forehead_r.png", (9, 8 * 14 * 3))
    png(runtime / "cheek_l.png", (8, 6 * len(cheek_states)))
    png(runtime / "cheek_r.png", (8, 6 * len(cheek_states)))
    png(runtime / "eyebag_l.png", (7, 4 * len(under_states)))
    png(runtime / "eyebag_r.png", (7, 4 * len(under_states)))
    manifest.update({
        "stylized_mouth": {
            "basis": "canonical-outer-lip-v1",
            "box": [400, 694, 12, 18],
            "viseme_x_offsets": {
                name: (12.5 if name == "aa" else 0.0)
                for name in package.IOS_VISEMES
            },
        },
        "smile": {
            "src": "assets/smile.png", "box": smile_box,
            "states": smile_states, "visemes": list(package.IOS_VISEMES),
        },
        "emotion_mouth": {
            "src": "assets/emotion-mouth.png", "box": smile_box,
            "states": emotion_states, "emotions": ["sorrow", "horror", "anger"],
            "visemes": list(package.IOS_VISEMES),
        },
        "forehead": {
            "dys": brow["dys"], "sqs": brow["sqs"],
            "l": {"src": "assets/forehead_l.png", "box": forehead_l},
            "r": {"src": "assets/forehead_r.png", "box": forehead_r},
        },
        "cheek": {
            "ups": cheek_states,
            "l": {"src": "assets/cheek_l.png", "box": cheek_l},
            "r": {"src": "assets/cheek_r.png", "box": cheek_r},
        },
        "eyebag": {
            "ups": under_states,
            "l": {"src": "assets/eyebag_l.png", "box": under_l},
            "r": {"src": "assets/eyebag_r.png", "box": under_r},
        },
    })
    manifest_path.write_text(json.dumps(manifest))


class AvatarContractParityTests(unittest.TestCase):
    SOURCE_MEDIA = {
        "photograph", "game art", "anime", "illustration", "3d render",
    }

    def test_vendored_schemas_match_suite_contract_when_both_exist(self):
        for name in (
                "README.md", "manifest.schema.json", "macos-full.schema.json",
                "ios-light-v3.schema.json", "ios-full-expression-v4.schema.json"):
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

    def test_ios_schemas_allow_legacy_missing_source_medium_but_bound_new_values(self):
        for name in (
                "manifest.schema.json", "ios-light-v3.schema.json",
                "ios-full-expression-v4.schema.json"):
            with self.subTest(schema=name):
                schema = json.loads((SCHEMA_ROOT / name).read_text())
                self.assertNotIn("sourceMedium", schema["required"])
                self.assertEqual(
                    set(schema["properties"]["sourceMedium"]["enum"]),
                    self.SOURCE_MEDIA,
                )


class MacFullAvatarPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_round_trip_preserves_authoring_and_rejects_runtime_data(self):
        source = make_authoring(self.root / "source")
        # A direct export must never serialize crash-recovery snapshots, even
        # if it races an interrupted body edit outside the normal busy guard.
        transaction = source / ".body-edit-transaction"
        transaction.mkdir()
        (transaction / "transaction.json").write_text(
            '{"phase":"state-written","private":"do-not-export"}')
        transaction_stage = source / ".body-edit-transaction-stage-test"
        transaction_stage.mkdir()
        (transaction_stage / "manifest.json").write_text(
            '{"private":"do-not-export"}')
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
            self.assertFalse(any("body-edit-transaction" in name for name in names))
            self.assertNotIn("authoring/.wardrobe.json", names)
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
        self.assertFalse((installed / "nova" / ".wardrobe.json").exists())
        self.assertEqual(seen[-1][0], seen[-1][1])

    def test_export_prunes_only_the_known_wardrobe_cache_hidden_file(self):
        source = make_authoring(self.root / "source")
        (source / ".unexpected.json").write_text("{}")
        with self.assertRaisesRegex(
                package.AvatarPackageError, "unsafe authoring path"):
            package.export_macos_full("nova", source, self.root / "bad.avtr")

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
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(manifest["sourceMedium"], "photograph")
        self.assertNotIn("motions", manifest)
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(len(bundle.infolist()), 19)
            self.assertFalse(any(info.is_dir() for info in bundle.infolist()))
            names = set(bundle.namelist())
            self.assertEqual(names, {
                "manifest.json",
                *{f"assets/{value}" for value in package.IOS_ROLE_FILENAMES.values()},
            })
            loaded = json.loads(bundle.read("manifest.json"))
            self.assertEqual(loaded["sourceMedium"], "photograph")
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

    def test_explicit_stylized_replace_packages_baked_body_pixels(self):
        configure_stylized_body_replacement(self.authoring, self.runtime)
        archive = self.root / "Cartoon-iPhone.avtr"
        manifest = package.export_ios_light(
            "cartoon", "Cartoon", self.authoring, self.runtime, archive)

        self.assertEqual(manifest["sourceMedium"], "illustration")

        with zipfile.ZipFile(archive) as bundle, \
                Image.open(io.BytesIO(bundle.read("assets/body.png"))) as packaged, \
                Image.open(self.authoring / "body" / "body-composite.png") as baked:
            self.assertEqual(
                json.loads(bundle.read("manifest.json"))["sourceMedium"],
                "illustration",
            )
            self.assertEqual(
                baked.convert("RGBA").tobytes(),
                packaged.convert("RGBA").tobytes(),
            )
            self.assertEqual((240, 30, 40, 255), packaged.convert("RGBA").getpixel((0, 0)))

    def test_stylized_export_rejects_non_upright_canonical_registration(self):
        configure_stylized_body_replacement(self.authoring, self.runtime)
        angle = math.radians(8)
        scale = 0.25
        rotated = [
            [scale * math.cos(angle), -scale * math.sin(angle), 128],
            [scale * math.sin(angle), scale * math.cos(angle), 64],
        ]
        runtime_path = self.runtime / "manifest.json"
        runtime = json.loads(runtime_path.read_text())
        runtime["body"]["face_transform"] = rotated
        runtime_path.write_text(json.dumps(runtime))
        authored_path = self.authoring / "body" / "body.json"
        authored = json.loads(authored_path.read_text())
        authored["face_transform"] = rotated
        authored_path.write_text(json.dumps(authored))

        destination = self.root / "tilted-cartoon.avtr"
        with self.assertRaisesRegex(
                package.AvatarPackageError, "registration is not upright"):
            package.export_ios_light(
                "cartoon", "Cartoon", self.authoring, self.runtime,
                destination)
        self.assertFalse(destination.exists())

    def test_stylized_export_rejects_clear_mask_from_old_registration(self):
        configure_stylized_body_replacement(self.authoring, self.runtime)
        stale = [[0.25, 0, 168], [0, 0.25, 64]]
        for path in (
                self.authoring / "body" / "body.json",
                self.runtime / "manifest.json"):
            manifest = json.loads(path.read_text())
            target = manifest["body"] \
                if path.name == "manifest.json" else manifest
            target["head_clear_quality"] = {"face_transform": stale}
            path.write_text(json.dumps(manifest))

        destination = self.root / "stale-clear-mask.avtr"
        with self.assertRaisesRegex(
                package.AvatarPackageError, "head clear mask is stale"):
            package.export_ios_light(
                "cartoon", "Cartoon", self.authoring, self.runtime,
                destination)
        self.assertFalse(destination.exists())

    def test_stylized_bake_requires_current_coordinated_head_handoff(self):
        configure_stylized_body_replacement(self.authoring, self.runtime)
        runtime_manifest = json.loads(
            (self.runtime / "manifest.json").read_text())
        current_body = runtime_manifest["body"]

        for marker in (None, True, "4", 1, 2, 3, 5):
            with self.subTest(runtime_marker=marker):
                candidate = dict(current_body)
                if marker is None:
                    candidate.pop("head_handoff_version", None)
                else:
                    candidate["head_handoff_version"] = marker
                with self.assertRaisesRegex(
                        package.AvatarPackageError,
                        "handoff metadata is missing or unsupported"):
                    package._ios_body_source(
                        self.authoring,
                        self.runtime,
                        candidate,
                        "illustration",
                    )

        authored_path = self.authoring / "body" / "body.json"
        authored = json.loads(authored_path.read_text())
        authored["head_handoff_version"] = 1
        authored_path.write_text(json.dumps(authored))
        with self.assertRaisesRegex(
                package.AvatarPackageError,
                "authored stylized iPhone body handoff metadata"):
            package._ios_body_source(
                self.authoring,
                self.runtime,
                current_body,
                "illustration",
            )

        authored["head_handoff_version"] = package.STYLIZED_HEAD_HANDOFF_VERSION
        authored_path.write_text(json.dumps(authored))
        (self.authoring / "body" / "head-clear-mask.png").unlink()
        with self.assertRaisesRegex(
                package.AvatarPackageError, "head clear mask is missing"):
            package._ios_body_source(
                self.authoring,
                self.runtime,
                current_body,
                "illustration",
            )

        png(
            self.authoring / "body" / "head-clear-mask.png",
            (current_body["width"], current_body["height"]),
            color=(1, 2, 3, 255),
        )
        with self.assertRaisesRegex(
                package.AvatarPackageError, "runtime is stale"):
            package._ios_body_source(
                self.authoring,
                self.runtime,
                current_body,
                "illustration",
            )

    def test_photo_unknown_and_corrupt_sources_never_package_cartoon_bake(self):
        for source_medium in ("photograph", "unknown", "corrupt-future-value"):
            with self.subTest(source_medium=source_medium):
                authoring = make_authoring(
                    self.root / f"source-{source_medium}", "avatar")
                runtime = make_runtime(authoring)
                configure_stylized_body_replacement(
                    authoring, runtime, source_medium=source_medium)
                archive = self.root / f"{source_medium}-iPhone.avtr"
                manifest = package.export_ios_light(
                    "avatar", "Avatar", authoring, runtime, archive)
                self.assertEqual(manifest["sourceMedium"], "photograph")
                with zipfile.ZipFile(archive) as bundle, \
                        Image.open(io.BytesIO(bundle.read("assets/body.png"))) as packaged, \
                        Image.open(runtime / "body.png") as raw:
                    self.assertEqual(
                        raw.convert("RGBA").tobytes(),
                        packaged.convert("RGBA").tobytes(),
                    )
                    self.assertNotEqual(
                        (240, 30, 40, 255),
                        packaged.convert("RGBA").getpixel((0, 0)),
                    )

    def test_stylized_bake_path_and_raw_runtime_comparisons_fail_closed(self):
        configure_stylized_body_replacement(self.authoring, self.runtime)
        authored_body_path = self.authoring / "body" / "body.json"
        authored_body = json.loads(authored_body_path.read_text())
        authored_body["views"]["front"]["preview_image"] = "../body-composite.png"
        authored_body_path.write_text(json.dumps(authored_body))
        invalid_path_archive = self.root / "invalid-path.avtr"
        with self.assertRaisesRegex(
                package.AvatarPackageError, "baked body composite path is invalid"):
            package.export_ios_light(
                "cartoon", "Cartoon", self.authoring, self.runtime,
                invalid_path_archive)
        self.assertFalse(invalid_path_archive.exists())

        authored_body["views"]["front"]["preview_image"] = "body-composite.png"
        authored_body_path.write_text(json.dumps(authored_body))
        png(self.runtime / "body.png", (512, 768), color=(1, 2, 3, 255))
        stale_archive = self.root / "stale-runtime.avtr"
        with self.assertRaisesRegex(
                package.AvatarPackageError, "runtime is stale"):
            package.export_ios_light(
                "cartoon", "Cartoon", self.authoring, self.runtime,
                stale_archive)
        self.assertFalse(stale_archive.exists())

    def test_legacy_export_rejects_texture_dimension_above_8192(self):
        png(self.authoring / "keyframe.png", (package.MAX_IOS_DIMENSION + 1, 1))
        with self.assertRaisesRegex(
                package.AvatarPackageError, "avatar image is too large"):
            package.export_ios_light(
                "nova",
                "Nova",
                self.authoring,
                self.runtime,
                self.root / "oversized-thumbnail.avtr",
            )

    def test_v22_exports_full_expression_v4_with_all_fifteen_visemes(self):
        authoring_manifest_path = self.authoring / "manifest.json"
        authoring_manifest = json.loads(authoring_manifest_path.read_text())
        authoring_manifest["source_metrics"] = {"source_medium": "anime"}
        authoring_manifest_path.write_text(json.dumps(authoring_manifest))
        add_full_expression_runtime(self.runtime)
        archive = self.root / "Nova-iPhone-Full-Expression.avtr"
        manifest = package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, archive
        )

        self.assertEqual(manifest["version"], package.IOS_EXPRESSION_VERSION)
        self.assertEqual(manifest["variant"], "ios-light")
        self.assertEqual(manifest["sourceMedium"], "anime")
        self.assertEqual(
            manifest["speechPatch"],
            {
                "box": {"x": 400.0, "y": 701.2, "width": 12.0, "height": 10.8},
                "visemeXOffsets": {
                    name: (12.5 if name == "aa" else 0.0)
                    for name in package.IOS_VISEMES
                },
            },
        )
        self.assertEqual(manifest["expression"]["smileVisemes"], list(package.IOS_VISEMES))
        self.assertEqual(
            manifest["expression"]["emotionMouthEmotions"],
            ["sorrow", "horror", "anger"],
        )
        self.assertEqual(manifest["expression"]["browGain"], 1)
        self.assertEqual(manifest["expression"]["foreheadGain"], 1)
        self.assertEqual(manifest["expression"]["underEyeGain"], 1)
        expected_roles = {
            *package.IOS_LEGACY_ROLE_FILENAMES,
            *{f"viseme-{name}" for name in package.IOS_VISEMES},
            *package.IOS_EXPRESSION_ROLE_FILENAMES,
        }
        self.assertEqual(set(manifest["assets"]), expected_roles)
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(len(bundle.infolist()), package.IOS_EXPRESSION_VERSION + 29)
            loaded = json.loads(bundle.read("manifest.json"))
            jsonschema.Draft202012Validator(json.loads(
                (SCHEMA_ROOT / "ios-full-expression-v4.schema.json").read_text()
            )).validate(loaded)
            self.assertEqual(loaded["expression"]["smile"]["storage"], "gridAtlas")
            self.assertEqual(loaded["speechPatch"], manifest["speechPatch"])
            self.assertEqual(
                loaded["expression"]["emotionMouth"]["storage"], "gridAtlas"
            )
            self.assertEqual(
                (
                    loaded["assets"]["smile-atlas"]["width"],
                    loaded["assets"]["smile-atlas"]["height"],
                ),
                (12 * 5, 6 * 15),
            )
            self.assertEqual(
                (
                    loaded["assets"]["emotion-mouth-atlas"]["width"],
                    loaded["assets"]["emotion-mouth-atlas"]["height"],
                ),
                (12 * 4, 6 * 45),
            )
            self.assertTrue(all(
                asset["width"] <= package.MAX_IOS_TEXTURE_DIMENSION
                and asset["height"] <= package.MAX_IOS_TEXTURE_DIMENSION
                for asset in loaded["assets"].values()
            ))
            self.assertIn("assets/emotion-mouth-atlas.png", bundle.namelist())
            self.assertIn("assets/forehead-left.png", bundle.namelist())
            self.assertIn("assets/under-eye-right.png", bundle.namelist())

    def test_v4_photo_package_does_not_opt_into_stylized_speech_composition(self):
        add_full_expression_runtime(self.runtime)
        archive = self.root / "Photo-iPhone-Full-Expression.avtr"
        manifest = package.export_ios_light(
            "photo", "Photo", self.authoring, self.runtime, archive
        )

        self.assertEqual(manifest["sourceMedium"], "photograph")
        self.assertNotIn("speechPatch", manifest)
        with zipfile.ZipFile(archive) as bundle:
            self.assertNotIn("speechPatch", json.loads(bundle.read("manifest.json")))

    def test_stylized_v4_rejects_incomplete_viseme_registration(self):
        authoring_manifest_path = self.authoring / "manifest.json"
        authoring_manifest = json.loads(authoring_manifest_path.read_text())
        authoring_manifest["source_metrics"] = {"source_medium": "illustration"}
        authoring_manifest_path.write_text(json.dumps(authoring_manifest))
        add_full_expression_runtime(self.runtime)
        runtime_manifest_path = self.runtime / "manifest.json"
        runtime_manifest = json.loads(runtime_manifest_path.read_text())
        runtime_manifest["stylized_mouth"]["viseme_x_offsets"].pop("kk")
        runtime_manifest_path.write_text(json.dumps(runtime_manifest))

        with self.assertRaisesRegex(
                package.AvatarPackageError,
                "speech registration is incomplete"):
            package.export_ios_light(
                "cartoon", "Cartoon", self.authoring, self.runtime,
                self.root / "invalid-stylized-v4.avtr",
            )

    def test_v22_exports_bounded_per_avatar_expression_calibration(self):
        add_full_expression_runtime(self.runtime)
        manifest_path = self.runtime / "manifest.json"
        runtime_manifest = json.loads(manifest_path.read_text())
        runtime_manifest["rig_profile"] = {
            "brows": 40,
            "forehead": 25,
            "eyebags": 140,
        }
        manifest_path.write_text(json.dumps(runtime_manifest))

        manifest = package.export_ios_light(
            "nova",
            "Nova",
            self.authoring,
            self.runtime,
            self.root / "calibrated-expression.avtr",
        )

        self.assertEqual(manifest["expression"]["browGain"], 1.35)
        self.assertEqual(manifest["expression"]["foreheadGain"], 0.5)
        self.assertEqual(manifest["expression"]["underEyeGain"], 1.35)

    def test_vertical_strip_repack_preserves_every_row_major_frame_address(self):
        source = self.root / "six-frame-strip.png"
        destination = self.root / "six-frame-grid.png"
        colors = [
            (240, 10, 20, 255), (20, 220, 30, 255), (30, 40, 230, 255),
            (200, 120, 10, 255), (120, 20, 180, 255), (10, 180, 170, 255),
        ]
        strip = Image.new("RGBA", (2, len(colors)))
        for index, color in enumerate(colors):
            strip.paste(color, (0, index, 2, index + 1))
        strip.save(source)

        package._copy_vertical_strip_as_grid(
            source,
            destination,
            {"width": 2, "height": 1},
            columns=3,
            rows=2,
        )

        with Image.open(destination) as atlas:
            self.assertEqual(atlas.size, (6, 2))
            for index, expected in enumerate(colors):
                column = index % 3
                row = index // 3
                self.assertEqual(atlas.getpixel((column * 2, row)), expected)

    def test_stylized_semantic_blink_strip_is_transparent_until_full_closure(self):
        source = self.root / "semantic-eye.png"
        destination = self.root / "semantic-eye-strip.png"
        plate = Image.new("RGBA", (11, 7), (0, 0, 0, 0))
        # A full authored eye oval, intentionally much larger than a human lid
        # mesh, with a curved closed line in its lower half.
        for y in range(1, 6):
            for x in range(1, 10):
                plate.putpixel((x, y), (180, 120, 80, 255))
        for x in range(2, 9):
            plate.putpixel((x, 4 + (1 if x in {2, 8} else 0)), (20, 15, 10, 255))
        plate.save(source)

        package._copy_semantic_eye_as_late_switch_strip(
            source,
            destination,
            {"width": 11, "height": 7},
            states=8,
        )

        with Image.open(destination) as strip:
            strip = strip.convert("RGBA")
            self.assertEqual(strip.size, (11, 56))
            for frame in range(7):
                alpha = strip.crop((0, frame * 7, 11, (frame + 1) * 7)).getchannel("A")
                self.assertIsNone(alpha.getbbox())
            closed = strip.crop((0, 49, 11, 56))
            self.assertEqual(list(closed.getdata()), list(plate.getdata()))

    def test_photo_semantic_blink_metadata_is_never_inspected(self):
        malformed = {"stylized_blink": {"mode": "untrusted"}}
        self.assertIsNone(package._ios_semantic_blink(malformed, "photograph"))

    def test_legacy_stylized_blink_exports_static_transparency_not_human_strip(self):
        runtime = {
            "eyes": {
                "l": {"src": "assets/eye_l.png", "box": [40, 80, 18, 9]},
                "r": {"src": "assets/eye_r.png", "box": [90, 80, 18, 9]},
            }
        }
        blink = package._ios_semantic_blink(runtime, "anime")
        self.assertEqual(blink["mode"], "static-canonical")
        destination = self.root / "legacy-stylized-static-eye.png"
        package._copy_static_transparent_eye_strip(
            destination, blink["l"]["box"], states=8
        )
        with Image.open(destination) as strip:
            self.assertEqual(strip.size, (18, 72))
            self.assertIsNone(strip.getchannel("A").getbbox())

    def test_stylized_semantic_blink_uses_full_eye_bounds(self):
        manifest = {
            "stylized_blink": {
                "mode": "semantic-eye-switch",
                "l": {"src": "assets/stylized-blink-l.png", "box": [40, 80, 180, 210]},
                "r": {"src": "assets/stylized-blink-r.png", "box": [300, 70, 190, 220]},
            }
        }
        blink = package._ios_semantic_blink(manifest, "3d render")
        self.assertEqual(blink["l"]["box"], {
            "x": 40, "y": 80, "width": 180, "height": 210,
        })
        self.assertEqual(blink["r"]["box"], {
            "x": 300, "y": 70, "width": 190, "height": 220,
        })
        self.assertEqual(blink["l"]["rows"], 8)

    def test_v4_schema_locks_role_paths_sprite_shapes_and_canonical_states(self):
        add_full_expression_runtime(self.runtime)
        archive = self.root / "Nova-iPhone-Full-Expression.avtr"
        package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, archive
        )
        with zipfile.ZipFile(archive) as bundle:
            manifest = json.loads(bundle.read("manifest.json"))
        validator = jsonschema.Draft202012Validator(json.loads(
            (SCHEMA_ROOT / "ios-full-expression-v4.schema.json").read_text()
        ))

        bad_path = json.loads(json.dumps(manifest))
        bad_path["assets"]["body"]["path"] = "assets/head-mask.png"
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(bad_path)

        bad_sprite = json.loads(json.dumps(manifest))
        bad_sprite["expression"]["smile"]["columns"] = 4
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(bad_sprite)

        bad_states = json.loads(json.dumps(manifest))
        bad_states["expression"]["browOffsets"][1:3] = [-2, -3.5]
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(bad_states)

    def test_v22_rejects_noncanonical_state_bank_and_decoded_pixel_overage(self):
        add_full_expression_runtime(self.runtime)
        manifest_path = self.runtime / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["smile"]["states"] = [0, .34, .18, .68, 1]
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(package.AvatarPackageError, "state banks"):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime, self.root / "bad-state.avtr"
            )

        add_full_expression_runtime(self.runtime)
        with patch.object(package, "MAX_IOS_TOTAL_PIXELS", 1):
            with self.assertRaisesRegex(package.AvatarPackageError, "decoded images"):
                package.export_ios_light(
                    "nova", "Nova", self.authoring, self.runtime,
                    self.root / "too-many-pixels.avtr",
                )

    def test_export_rejects_transforms_or_anchors_swift_would_reject(self):
        manifest_path = self.runtime / "manifest.json"
        original = json.loads(manifest_path.read_text())
        cases = {
            "reflected": ([[-.25, 0, 128], [0, .25, 64]], "renderer limits"),
            "sheared": ([[.25, .05, 128], [0, .25, 64]], "renderer limits"),
            "nonuniform": ([[.25, 0, 128], [0, .30, 64]], "renderer limits"),
            "too-small": ([[.005, 0, 128], [0, .005, 64]], "renderer limits"),
            "eye-outside": ([[.05, 0, 0], [0, .05, 0]], "eye anchor"),
        }
        for label, (transform, message) in cases.items():
            with self.subTest(label=label):
                manifest = json.loads(json.dumps(original))
                manifest["body"]["face_transform"] = transform
                manifest_path.write_text(json.dumps(manifest))
                destination = self.root / f"bad-transform-{label}.avtr"
                with self.assertRaisesRegex(package.AvatarPackageError, message):
                    package.export_ios_light(
                        "nova", "Nova", self.authoring, self.runtime, destination
                    )
                self.assertFalse(destination.exists())

        manifest_path.write_text(json.dumps(original))

    def test_full_expression_ui_export_refuses_legacy_runtime_with_rebuild_guidance(self):
        with self.assertRaisesRegex(package.AvatarPackageError, "rebuild.*full-expression"):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime,
                self.root / "mislabelled.avtr", require_full_expression=True,
            )

    def test_v22_rejects_partial_expression_bank_instead_of_mislabelling_it(self):
        add_full_expression_runtime(self.runtime)
        manifest_path = self.runtime / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("eyebag")
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(package.AvatarPackageError, "complete iPhone expression"):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime, self.root / "bad.avtr"
            )

    def test_export_v3_includes_exact_ara_like_idle_and_move_records(self):
        authoring_manifest_path = self.authoring / "manifest.json"
        authoring_manifest = json.loads(authoring_manifest_path.read_text())
        authoring_manifest["source_metrics"] = {"source_medium": "game-art"}
        authoring_manifest_path.write_text(json.dumps(authoring_manifest))
        add_runtime_motions(self.runtime)
        archive = self.root / "Ara-iPhone.avtr"
        duplicate = self.root / "Ara-iPhone-again.avtr"
        with patch.object(package, "_probe_motion_details", return_value=motion_probe()):
            manifest = package.export_ios_light(
                "nova", "Ara", self.authoring, self.runtime, archive
            )
            duplicate_manifest = package.export_ios_light(
                "nova", "Ara", self.authoring, self.runtime, duplicate
            )

        self.assertEqual(manifest, duplicate_manifest)
        self.assertEqual(
            archive.read_bytes(), duplicate.read_bytes(),
            "the same runtime inputs must produce a byte-identical AVTR",
        )
        self.assertEqual(manifest["version"], 3)
        self.assertEqual(manifest["sourceMedium"], "game art")
        self.assertEqual(set(manifest["motions"]), {"edgeIdle", "moves"})
        self.assertEqual(
            manifest["motions"]["edgeIdle"]["path"],
            "assets/motion-edge-idle.mov",
        )
        self.assertEqual(
            manifest["motions"]["moves"]["path"],
            "assets/motion-moves.mov",
        )
        for record in manifest["motions"].values():
            self.assertEqual(set(record), {
                "path", "sha256", "byteCount", "mediaType", "width", "height",
                "durationMilliseconds",
            })
            self.assertEqual(record["mediaType"], "video/quicktime")
            self.assertEqual((record["width"], record["height"]), (720, 1088))
            self.assertEqual(record["durationMilliseconds"], 6083)

        with zipfile.ZipFile(archive) as bundle, zipfile.ZipFile(duplicate) as repeated:
            names = bundle.namelist()
            self.assertEqual(len(names), 21)
            self.assertEqual(names[0], "manifest.json")
            self.assertEqual(names[-2:], [
                "assets/motion-edge-idle.mov", "assets/motion-moves.mov",
            ])
            self.assertEqual(bundle.read("manifest.json"), repeated.read("manifest.json"))
            loaded = json.loads(bundle.read("manifest.json"))
            jsonschema.Draft202012Validator(
                json.loads((SCHEMA_ROOT / "ios-light-v3.schema.json").read_text())
            ).validate(loaded)
            for record in loaded["motions"].values():
                content = bundle.read(record["path"])
                self.assertEqual(len(content), record["byteCount"])
                self.assertEqual(hashlib.sha256(content).hexdigest(), record["sha256"])
            serialized = bundle.read("manifest.json").decode("utf-8")
            for private_value in (
                    "/private/owned-avatar", "providerPrompt", "authoring prompt",
                    "apiKey", "sk-" + ("n" * 8), "alpha_stream_hevc", "rawSource"):
                self.assertNotIn(private_value, serialized)

    def test_export_strips_image_metadata_and_rejects_rig_asset_mismatch(self):
        marker = "PRIVATE_EXPORT_PATH_/Users/example/portrait.png"
        body_path = self.runtime / "body.png"
        with Image.open(body_path) as source:
            pixels = source.convert("RGBA")
        metadata = PngImagePlugin.PngInfo()
        metadata.add_text("Source", marker)
        pixels.save(body_path, format="PNG", pnginfo=metadata)

        viseme_path = self.runtime / "sil_open.jpg"
        with Image.open(viseme_path) as source:
            pixels = source.convert("RGB")
        exif = Image.Exif()
        exif[0x010E] = marker
        pixels.save(viseme_path, format="JPEG", quality=90, exif=exif)

        archive = self.root / "clean-images.avtr"
        package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, archive
        )
        with zipfile.ZipFile(archive) as bundle:
            self.assertNotIn(marker.encode(), bundle.read("assets/body.png"))
            self.assertNotIn(marker.encode(), bundle.read("assets/viseme-sil.jpg"))

        runtime_manifest_path = self.runtime / "manifest.json"
        runtime_manifest = json.loads(runtime_manifest_path.read_text())
        runtime_manifest["body"]["width"] += 1
        runtime_manifest_path.write_text(json.dumps(runtime_manifest))
        destination = self.root / "mismatched-rig.avtr"
        with self.assertRaisesRegex(
                package.AvatarPackageError, "body dimensions do not match"):
            package.export_ios_light(
                "nova", "Nova", self.authoring, self.runtime, destination
            )
        self.assertFalse(destination.exists())

    def test_export_v3_rejects_wrong_codec_audio_missing_alpha_and_oversize(self):
        add_runtime_motions(self.runtime, ("idle",))
        invalid_probes = {
            "codec": motion_probe(codec="h264"),
            "audio": motion_probe(audio=1),
            "alpha": motion_probe(alpha=False),
            "duration": motion_probe(duration=5900),
        }
        messages = {
            "codec": "HEVC",
            "audio": "no audio",
            "alpha": "alpha channel",
            "duration": "runtime ledger",
        }
        for label, details in invalid_probes.items():
            with self.subTest(label=label):
                destination = self.root / f"invalid-{label}.avtr"
                with patch.object(
                        package, "_probe_motion_details", return_value=details):
                    with self.assertRaisesRegex(
                            package.AvatarPackageError, messages[label]):
                        package.export_ios_light(
                            "nova", "Nova", self.authoring, self.runtime, destination
                        )
                self.assertFalse(destination.exists())

        destination = self.root / "invalid-size.avtr"
        with patch.object(package, "MAX_IOS_MOTION_BYTES", 24), \
                patch.object(package, "_probe_motion_details", return_value=motion_probe()):
            with self.assertRaisesRegex(package.AvatarPackageError, "too large"):
                package.export_ios_light(
                    "nova", "Nova", self.authoring, self.runtime, destination
                )
        self.assertFalse(destination.exists())

    def test_export_v3_rejects_header_only_motion_without_packaged_ffprobe(self):
        add_runtime_motions(self.runtime, ("idle",))
        destination = self.root / "header-only-no-probe.avtr"
        with patch.object(package.shutil, "which", return_value=None):
            with self.assertRaisesRegex(
                    package.AvatarPackageError, "motion validation is unavailable"):
                package.export_ios_light(
                    "nova", "Nova", self.authoring, self.runtime, destination
                )
        self.assertFalse(destination.exists())

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
