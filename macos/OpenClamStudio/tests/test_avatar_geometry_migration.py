"""Explicit, hash-pinned Store migration must not weaken ordinary exports."""
from __future__ import annotations

import hashlib
import io
import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from server import avatar_package as package
from tests.test_avatar_package_v2 import (
    add_full_expression_runtime, add_runtime_motions,
    configure_stylized_body_replacement, make_authoring, make_runtime,
    motion_probe,
)


class ApprovedGeometryMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_temp = tempfile.TemporaryDirectory()
        cls.fixture_root = Path(cls.fixture_temp.name)
        cls.fixture = make_authoring(cls.fixture_root)
        runtime = make_runtime(cls.fixture)
        configure_stylized_body_replacement(cls.fixture, runtime)
        add_full_expression_runtime(runtime)
        add_runtime_motions(runtime, kinds=("walk", "idle", "move"))
        cls.reference = cls.fixture_root / "previous.avtr"
        with patch.object(package, "_probe_motion_details", return_value=motion_probe()):
            package.export_ios_light(
                "nova", "Nova", cls.fixture, runtime, cls.reference,
                require_full_expression=True,
            )

    @classmethod
    def tearDownClass(cls):
        cls.fixture_temp.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.avatar = self.root / "nova"
        shutil.copytree(self.fixture, self.avatar)
        self.runtime = self.avatar / "runtime"
        self.prior = self.root / "previous.avtr"
        shutil.copyfile(self.reference, self.prior)
        self.destination = self.root / "candidate.avtr"
        self.destination.write_bytes(b"previous approved destination")
        self.probe = patch.object(package, "_probe_motion_details", return_value=motion_probe())
        self.probe.start()
        self.addCleanup(self.probe.stop)

    def digest(self):
        return hashlib.sha256(self.prior.read_bytes()).hexdigest()

    def change_bodies(self, callback):
        authored_path = self.avatar / "body/body.json"
        runtime_path = self.runtime / "manifest.json"
        authored = json.loads(authored_path.read_text())
        runtime = json.loads(runtime_path.read_text())
        callback(authored)
        callback(runtime["body"])
        authored_path.write_text(json.dumps(authored))
        runtime_path.write_text(json.dumps(runtime))

    def make_legacy(self):
        self.change_bodies(lambda body: body.pop("head_handoff_version", None))

    def rewrite_reference(self, callback):
        with zipfile.ZipFile(self.prior) as archive:
            entries = {info.filename: archive.read(info.filename)
                       for info in archive.infolist()}
        manifest = json.loads(entries["manifest.json"])
        callback(manifest, entries)
        entries["manifest.json"] = json.dumps(manifest).encode()
        with zipfile.ZipFile(self.prior, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, payload in entries.items():
                archive.writestr(name, payload)

    def export(self, **overrides):
        arguments = dict(
            require_full_expression=True,
            approved_geometry_package=self.prior,
            approved_geometry_sha256=self.digest(),
        )
        arguments.update(overrides)
        return package.export_ios_light(
            "nova", "Nova", self.avatar, self.runtime, self.destination,
            **arguments,
        )

    def assert_rejected(self, pattern, **overrides):
        with self.assertRaisesRegex(package.AvatarPackageError, pattern):
            self.export(**overrides)
        self.assertEqual(self.destination.read_bytes(), b"previous approved destination")

    def test_explicit_reference_reuses_pixels_without_relabelling_metadata(self):
        self.make_legacy()
        before = {path.relative_to(self.avatar): path.read_bytes()
                  for path in self.avatar.rglob("*") if path.is_file()}
        manifest = self.export()
        self.assertEqual(manifest["version"], 4)
        self.assertEqual(manifest["sourceMedium"], "illustration")
        self.assertEqual(set(manifest["motions"]), {"walk", "edgeIdle", "moves"})
        self.assertEqual(before, {path.relative_to(self.avatar): path.read_bytes()
                                 for path in self.avatar.rglob("*") if path.is_file()})
        with zipfile.ZipFile(self.prior) as previous, zipfile.ZipFile(self.destination) as current:
            for role in ("body", "head-mask", "viseme-sil"):
                old_manifest = json.loads(previous.read("manifest.json"))
                self.assertEqual(previous.read(old_manifest["assets"][role]["path"]),
                                 current.read(manifest["assets"][role]["path"]))

    def test_normal_export_still_rejects_old_handoff_even_with_reference_beside_it(self):
        self.make_legacy()
        self.assert_rejected("handoff metadata", approved_geometry_package=None,
                             approved_geometry_sha256=None)

    def test_exact_approved_static_affine_can_migrate_but_new_tilt_cannot(self):
        transform = [[0.3407548, -0.0061732, 128], [0.0061732, 0.3407548, 64]]
        affine = dict(a=transform[0][0], b=transform[1][0], c=transform[0][1],
                      d=transform[1][1], tx=128, ty=64)
        self.change_bodies(lambda body: body.update(face_transform=transform))
        self.rewrite_reference(lambda manifest, _: manifest["rig"].update(faceTransform=affine))
        self.make_legacy()
        self.assert_rejected("not upright", approved_geometry_package=None,
                             approved_geometry_sha256=None)
        self.assertEqual(self.export()["rig"]["faceTransform"], affine)

    def test_encoding_only_png_change_is_allowed(self):
        for path in (self.avatar / "body/body-composite.png",
                     self.avatar / "body/head-mask.png", self.runtime / "head-mask.png"):
            with Image.open(path) as image:
                rgba = image.convert("RGBA")
            rgba.save(path, format="PNG", compress_level=0)
        self.make_legacy()
        self.export()

    def test_changed_baked_body_pixels_fail(self):
        path = self.avatar / "body/body-composite.png"
        with Image.open(path) as image:
            rgba = image.convert("RGBA")
        rgba.putpixel((200, 300), (241, 30, 40, 255))
        rgba.save(path)
        self.make_legacy()
        self.assert_rejected("current body pixels")

    def test_changed_head_mask_fails_even_when_authoring_and_runtime_match(self):
        for path in (self.avatar / "body/head-mask.png", self.runtime / "head-mask.png"):
            with Image.open(path) as image:
                rgba = image.convert("RGBA")
            rgba.putpixel((200, 300), (120, 80, 50, 254))
            rgba.save(path)
        self.make_legacy()
        self.assert_rejected("current head-mask pixels")

    def test_changed_canonical_neutral_fails(self):
        path = self.runtime / "sil_open.jpg"
        Image.new("RGB", (1024, 1024), (190, 70, 45)).save(path, quality=95)
        self.make_legacy()
        self.assert_rejected("current viseme-sil pixels")

    def test_changed_affine_or_bounds_fail_even_when_local_metadata_agrees(self):
        self.make_legacy()
        self.change_bodies(lambda body: body["face_transform"][0].__setitem__(2, 129))
        self.assert_rejected("current faceTransform")
        self.change_bodies(lambda body: body["face_transform"][0].__setitem__(2, 128))
        self.change_bodies(lambda body: body["alignment"]["face_bounds"].__setitem__(0, 151))
        self.assert_rejected("current faceBoundsInBody")

    def test_wrong_or_incomplete_reference_arguments_fail(self):
        self.assert_rejected("both package and SHA", approved_geometry_sha256=None)
        self.assert_rejected("both package and SHA", approved_geometry_package=None)
        self.assert_rejected("SHA-256 does not match", approved_geometry_sha256="a" * 64)
        self.assert_rejected("SHA-256 is invalid", approved_geometry_sha256="not-a-hash")
        self.assert_rejected("missing or unsafe", approved_geometry_package=self.root / "absent.avtr")

    def test_invalid_pack_is_rejected_even_when_its_external_hash_matches(self):
        self.prior.write_bytes(b"not an avatar archive")
        self.assert_rejected("reference package is invalid")

    def test_reference_checks_all_assets_not_just_geometry(self):
        def tamper(manifest, entries):
            entries[manifest["assets"]["viseme-PP"]["path"]] += b"changed"
        self.rewrite_reference(tamper)
        self.assert_rejected("asset integrity failed: viseme-PP")

    def test_reference_checks_schema_and_identity(self):
        self.rewrite_reference(lambda manifest, _: manifest.update(id="different"))
        self.assert_rejected("reference identity")
        self.rewrite_reference(lambda manifest, _: manifest.update(id="nova", unknown=True))
        self.assert_rejected("reference package is invalid")

    def test_reference_checks_real_motion_contract(self):
        with patch.object(package, "_probe_motion_details", return_value=motion_probe(alpha=False)):
            self.assert_rejected("reference motion contract")

    def test_reference_does_not_override_stale_mask_or_path_checks(self):
        self.make_legacy()
        clear = self.runtime / "head-clear-mask.png"
        with Image.open(clear) as image:
            rgba = image.convert("RGBA")
        rgba.putpixel((1, 1), (255, 255, 255, 0))
        rgba.save(clear)
        self.assert_rejected("runtime is stale")
        shutil.copyfile(self.avatar / "body/head-clear-mask.png", clear)
        self.change_bodies(lambda body: body.update(head_clear_mask="../escape.png"))
        self.assert_rejected("(path|asset)")

    def test_reference_does_not_override_missing_full_expression(self):
        manifest_path = self.runtime / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("cheek")
        manifest_path.write_text(json.dumps(manifest))
        self.assert_rejected("(complete iPhone expression|full-expression)")

    def test_noncartoon_migration_is_not_allowed(self):
        path = self.avatar / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["source_metrics"]["source_medium"] = "photograph"
        path.write_text(json.dumps(manifest))
        self.assert_rejected("explicit cartoon replacement")


if __name__ == "__main__":
    unittest.main()
