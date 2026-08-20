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
    IDENTITY = {
        "identifier": "fixture-avatar",
        "display_name": "Fixture Avatar",
        "author": "Example Publisher",
        "version": 7,
    }

    def test_catalog_validator_accepts_a_synthetic_generic_contract(self):
        digest = "a" * 64
        package = lambda profile: {
            "url": (
                "https://github.com/openclam-fixtures/avatar-store-fixtures/"
                f"releases/download/fixtures-v1/fixture-avatar-{profile}.avtr"
            ),
            "sha256": digest,
            "bytes": 1,
            "format": "openclam-avatar",
            "profile": profile,
        }
        catalog = {
            "schemaVersion": 1,
            "entries": [{
                "id": self.IDENTITY["identifier"],
                "name": self.IDENTITY["display_name"],
                "author": self.IDENTITY["author"],
                "version": self.IDENTITY["version"],
                "thumbnail": {
                    "url": (
                        "https://raw.githubusercontent.com/openclam-fixtures/"
                        "avatar-store-fixtures/main/catalog/v1/"
                        "fixture-avatar-thumbnail.png"
                    ),
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
        BUILD._validate_catalog(catalog, **self.IDENTITY)

    def test_catalog_validator_rejects_extra_mutable_fields(self):
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD._validate_catalog(
                {
                    "schemaVersion": 1,
                    "generatedAt": "never allowed",
                    "entries": [],
                },
                **self.IDENTITY,
            )

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

    def test_artifact_names_are_derived_from_explicit_synthetic_identity(self):
        self.assertEqual(
            BUILD.artifact_filenames("fixture-avatar"),
            (
                "fixture-avatar-ios-light.avtr",
                "fixture-avatar-macos-full.avtr",
                "fixture-avatar-thumbnail.png",
            ),
        )
        for removed_default in (
            "CATALOG_URL", "THUMBNAIL_URL", "RELEASE_URL",
            "IOS_FILENAME", "MAC_FILENAME", "THUMBNAIL_FILENAME",
        ):
            self.assertFalse(hasattr(BUILD, removed_default))

    def test_identity_and_urls_fail_closed(self):
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD.artifact_filenames("Fixture Avatar")
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD._safe_text(" Publisher", "avatar publisher")
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD._strict_https("http://example.invalid/file", "example.invalid")
        BUILD._validate_repository_urls(
            catalog_url=(
                "https://raw.githubusercontent.com/openclam-fixtures/"
                "avatar-store-fixtures/main/catalog/v1/catalog.json"
            ),
            release_url=(
                "https://github.com/openclam-fixtures/avatar-store-fixtures/"
                "releases/download/fixtures-v1"
            ),
            thumbnail_url=(
                "https://raw.githubusercontent.com/openclam-fixtures/"
                "avatar-store-fixtures/main/catalog/v1/fixture-avatar-thumbnail.png"
            ),
            thumbnail_filename="fixture-avatar-thumbnail.png",
        )
        with self.assertRaises(BUILD.StoreBuildError):
            BUILD._validate_repository_urls(
                catalog_url=(
                    "https://raw.githubusercontent.com/openclam-fixtures/"
                    "avatar-store-fixtures/main/catalog/v1/catalog.json"
                ),
                release_url=(
                    "https://github.com/different-owner/avatar-store-fixtures/"
                    "releases/download/fixtures-v1"
                ),
                thumbnail_url=(
                    "https://raw.githubusercontent.com/openclam-fixtures/"
                    "avatar-store-fixtures/main/catalog/v1/fixture-avatar-thumbnail.png"
                ),
                thumbnail_filename="fixture-avatar-thumbnail.png",
            )


if __name__ == "__main__":
    unittest.main()
