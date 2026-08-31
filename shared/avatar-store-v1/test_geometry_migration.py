"""The Store migration seal must be tied to the previous reviewed catalog."""
from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from test_build_release import BASE_CATALOG, BUILD, _production_urls


class StoreGeometryMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        Image.new("RGBA", (64, 64), (80, 90, 100, 255)).save(self.source / "keyframe.png")
        self.reference = self.root / "approved.avtr"
        self.reference.write_bytes(b"only-the-exporter-validates-this-fixture")
        self.digest = hashlib.sha256(self.reference.read_bytes()).hexdigest()
        self.catalog = json.loads(BASE_CATALOG.read_text())
        row = next(row for row in self.catalog["entries"] if row["id"] == "luffy-2d")
        row["variants"]["ios-light"].update(
            sha256=self.digest, bytes=self.reference.stat().st_size)
        self.base = self.root / "catalog.json"
        self.base.write_text(json.dumps(self.catalog))
        self.output = self.root / "staged"
        self.manifest = {
            "format": BUILD.avtr.FORMAT, "version": 4, "variant": "ios-light",
            "id": "luffy-2d", "displayName": "Luffy · 2D",
        }

    def arguments(self, **overrides):
        arguments = dict(
            identifier="luffy-2d", display_name="Luffy · 2D", author="OpenClam", version=2,
            base_catalog_path=self.base, release_tag="avatar-store-v1.0.6",
            approved_geometry_package=self.reference, approved_geometry_sha256=self.digest,
            **_production_urls(tag="avatar-store-v1.0.6", identifier="luffy-2d"),
        )
        arguments.update(overrides)
        return arguments

    def test_reference_pin_forwards_to_both_normal_exports_and_preserves_other_entries(self):
        def exporter(identifier, name, authoring, runtime, destination, **kwargs):
            Path(destination).write_bytes(b"deterministic-reviewed-ios-v4")
            return copy.deepcopy(self.manifest)
        with patch.object(BUILD, "_validate_ready_source"), \
                patch.object(BUILD.avtr, "export_ios_light", side_effect=exporter) as export, \
                patch.object(BUILD, "normalize_archive"), \
                patch.object(BUILD, "_validate_ios_archive", return_value=self.manifest):
            result = BUILD.build_release(self.source, self.output, **self.arguments())
        self.assertEqual(export.call_count, 2)
        for call in export.call_args_list:
            self.assertEqual(call.kwargs["approved_geometry_package"], self.reference)
            self.assertEqual(call.kwargs["approved_geometry_sha256"], self.digest)
            self.assertTrue(call.kwargs["require_full_expression"])
        self.assertTrue(result["verifiedReproducible"])
        self.assertTrue(result["approvedGeometryMigration"]["geometryVerified"])
        self.assertFalse(result["approvedGeometryMigration"]["recomposed"])
        expected = {row["id"]: row for row in self.catalog["entries"] if row["id"] != "luffy-2d"}
        actual = {row["id"]: row for row in result["catalog"]["entries"] if row["id"] != "luffy-2d"}
        self.assertEqual(actual, expected)

    def test_missing_pair_catalog_or_versioned_tag_rejects_before_export(self):
        for overrides in (
            {"approved_geometry_package": None},
            {"approved_geometry_sha256": None},
            {"base_catalog_path": None},
            {"release_tag": None},
        ):
            with self.subTest(overrides=overrides), patch.object(BUILD.avtr, "export_ios_light") as export:
                with self.assertRaises(BUILD.StoreBuildError):
                    BUILD.build_release(self.source, self.output, **self.arguments(**overrides))
                export.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_wrong_hash_wrong_identity_and_nonincrementing_version_reject(self):
        for overrides in (
            {"approved_geometry_sha256": "a" * 64},
            {"display_name": "Other face"},
            {"version": 1},
        ):
            with self.subTest(overrides=overrides), patch.object(BUILD, "_validate_ready_source"), \
                    patch.object(BUILD.avtr, "export_ios_light") as export:
                with self.assertRaisesRegex(BUILD.StoreBuildError, "existing Store identity"):
                    BUILD.build_release(self.source, self.output, **self.arguments(**overrides))
                export.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_missing_reference_or_catalog_byte_mismatch_rejects(self):
        for path in (self.root / "absent.avtr", self.root / "short.avtr"):
            if path.name == "short.avtr":
                path.write_bytes(b"short")
            with self.subTest(path=path), patch.object(BUILD, "_validate_ready_source"), \
                    patch.object(BUILD.avtr, "export_ios_light") as export:
                with self.assertRaisesRegex(BUILD.StoreBuildError, "reference (bytes|package)"):
                    BUILD.build_release(self.source, self.output,
                                        **self.arguments(approved_geometry_package=path))
                export.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_exporter_validation_failure_cannot_publish_or_leave_output(self):
        with patch.object(BUILD, "_validate_ready_source"), \
                patch.object(BUILD.avtr, "export_ios_light", side_effect=BUILD.avtr.AvatarPackageError("pixel seal failed")):
            with self.assertRaisesRegex(BUILD.avtr.AvatarPackageError, "pixel seal failed"):
                BUILD.build_release(self.source, self.output, **self.arguments())
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".openclam-store-*")), [])


if __name__ == "__main__":
    unittest.main()
