#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("build_release", ROOT / "build_release.py")
BUILD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILD)


class AvatarStoreReleaseTests(unittest.TestCase):
    def test_catalog_validator_accepts_the_frozen_contract(self):
        digest = "a" * 64
        package = lambda profile: {
            "url": f"https://github.com/tivojn/openclam-avatar-store/{profile}",
            "sha256": digest,
            "bytes": 1,
            "format": "openclam-avatar",
            "profile": profile,
        }
        catalog = {
            "schemaVersion": 1,
            "entries": [{
                "id": "vivieen",
                "name": "Vivieen",
                "author": "OpenClam",
                "version": 1,
                "thumbnail": {
                    "url": BUILD.THUMBNAIL_URL,
                    "sha256": digest,
                    "bytes": 1,
                    "mime": "image/png",
                    "width": 1,
                    "height": 1,
                },
                "variants": {
                    "ios-light": package("ios-light"),
                    "macos-full": package("macos-full"),
                },
            }],
        }
        BUILD._validate_catalog(catalog)

    def test_catalog_validator_rejects_extra_mutable_fields(self):
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD._validate_catalog({
                "schemaVersion": 1,
                "generatedAt": "never allowed",
                "entries": [],
            })

    def test_archive_normalization_is_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first.avtr"
            second = root / "second.avtr"
            for index, path in enumerate((first, second), start=1):
                with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                    info = zipfile.ZipInfo("assets/payload.bin", (2020 + index, 1, 1, 0, 0, 0))
                    archive.writestr(info, b"payload")
                    archive.writestr("manifest.json", b"{}")
                BUILD.normalize_archive(path, zipfile.ZIP_DEFLATED)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(
                    archive.namelist(), ["manifest.json", "assets/payload.bin"]
                )
                self.assertTrue(all(
                    info.date_time == BUILD.FIXED_ZIP_TIME
                    for info in archive.infolist()
                ))

    def test_schema_and_builder_share_the_exact_root_keys(self):
        schema = json.loads((ROOT / "catalog.schema.json").read_text())
        self.assertEqual(schema["required"], ["schemaVersion", "entries"])
        self.assertFalse(schema["additionalProperties"])

    def test_release_urls_and_names_are_frozen(self):
        self.assertEqual(BUILD.IOS_FILENAME, "Vivieen-iPhone.avtr")
        self.assertEqual(BUILD.MAC_FILENAME, "Vivieen-Mac.avtr")
        self.assertEqual(BUILD.THUMBNAIL_FILENAME, "vivieen-thumbnail.png")
        self.assertEqual(
            BUILD.CATALOG_URL,
            "https://raw.githubusercontent.com/tivojn/openclam-avatar-store/"
            "main/catalog/v1/catalog.json",
        )
        self.assertTrue(BUILD.RELEASE_URL.endswith("/avatars-v1.0.0"))


if __name__ == "__main__":
    unittest.main()
