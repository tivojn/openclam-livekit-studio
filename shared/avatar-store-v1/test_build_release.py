#!/usr/bin/env python3
from __future__ import annotations

import copy
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from PIL import Image


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("build_release", ROOT / "build_release.py")
BUILD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILD)


PACKAGE_FIXTURES = ROOT.parent / "avatar-package-v2" / "fixtures"
BASE_CATALOG = ROOT / "catalog" / "v1" / "catalog.json"


def _image_payload(
    image_format: str,
    size: tuple[int, int],
    color: tuple[int, ...],
) -> bytes:
    output = io.BytesIO()
    mode = "RGB" if image_format == "JPEG" else "RGBA"
    Image.new(mode, size, color).save(output, format=image_format)
    return output.getvalue()


def _full_expression() -> dict:
    def sprite(
        width: int,
        height: int,
        columns: int,
        rows: int,
        storage: str,
    ) -> dict:
        return {
            "box": {"x": 0, "y": 0, "width": width, "height": height},
            "columns": columns,
            "rows": rows,
            "storage": storage,
        }

    return {
        "smile": sprite(4, 4, 5, 15, "gridAtlas"),
        "emotionMouth": sprite(4, 4, 4, 45, "gridAtlas"),
        "leftForehead": sprite(4, 3, 14, 3, "verticalStrip"),
        "rightForehead": sprite(4, 3, 14, 3, "verticalStrip"),
        "leftCheek": sprite(4, 4, 1, 5, "verticalStrip"),
        "rightCheek": sprite(4, 4, 1, 5, "verticalStrip"),
        "leftUnderEye": sprite(4, 4, 1, 5, "verticalStrip"),
        "rightUnderEye": sprite(4, 4, 1, 5, "verticalStrip"),
        "browOffsets": list(BUILD.avtr.IOS_BROW_OFFSETS),
        "browSqueezeOffsets": list(BUILD.avtr.IOS_BROW_SQUEEZE_OFFSETS),
        "smileStrengths": list(BUILD.avtr.IOS_SMILE_STRENGTHS),
        "smileVisemes": list(BUILD.avtr.IOS_VISEMES),
        "emotionMouthStrengths": list(
            BUILD.avtr.IOS_EMOTION_MOUTH_STRENGTHS
        ),
        "emotionMouthEmotions": ["sorrow", "horror", "anger"],
        "emotionMouthVisemes": list(BUILD.avtr.IOS_VISEMES),
        "cheekOffsets": list(BUILD.avtr.IOS_CHEEK_OFFSETS),
        "underEyeOffsets": list(BUILD.avtr.IOS_UNDER_EYE_OFFSETS),
        "browGain": 1,
        "foreheadGain": 1,
        "underEyeGain": 1,
    }


def _make_v4_archive(
    destination: Path,
    *,
    identifier: str = "cleo",
    display_name: str = "Cleo",
    motion_roles: tuple[str, ...] = ("walk", "edgeIdle", "moves"),
) -> dict:
    rig = json.loads(
        (PACKAGE_FIXTURES / "ios-light-golden.manifest.json").read_text()
    )["rig"]
    filenames = dict(BUILD.avtr.IOS_LEGACY_ROLE_FILENAMES)
    filenames.update({
        f"viseme-{name}": f"viseme-{name}.jpg"
        for name in BUILD.avtr.IOS_VISEMES
    })
    filenames.update(BUILD.avtr.IOS_EXPRESSION_ROLE_FILENAMES)
    sizes = {
        "thumbnail": (64, 64),
        "body": (128, 192),
        "eye-left": (4, 32),
        "eye-right": (4, 32),
        "brow-left": (4, 126),
        "brow-right": (4, 126),
        "gaze-left-atlas": (100, 44),
        "gaze-right-atlas": (100, 44),
        "smile-atlas": (20, 60),
        "emotion-mouth-atlas": (16, 180),
        "forehead-left": (4, 126),
        "forehead-right": (4, 126),
        "cheek-left": (4, 20),
        "cheek-right": (4, 20),
        "under-eye-left": (4, 20),
        "under-eye-right": (4, 20),
    }
    payloads: dict[str, bytes] = {}
    assets = {}
    for index, (role, filename) in enumerate(sorted(filenames.items())):
        image_format = (
            "JPEG" if role == "thumbnail" or role.startswith("viseme-")
            else "PNG"
        )
        size = sizes.get(role, (1024, 1024))
        color = (
            (20 + index % 200, 80, 120)
            if image_format == "JPEG"
            else (20 + index % 200, 80, 120, 255)
        )
        payload = _image_payload(image_format, size, color)
        path = f"assets/{filename}"
        payloads[path] = payload
        assets[role] = {
            "path": path,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "byteCount": len(payload),
            "mediaType": (
                "image/jpeg" if image_format == "JPEG" else "image/png"
            ),
            "width": size[0],
            "height": size[1],
        }

    motions = {}
    for role in motion_roles:
        _, filename = BUILD.avtr.IOS_MOTION_FILENAMES[role]
        payload = (
            b"\x00\x00\x00\x14ftypqt  \x00\x00\x02\x00qt  "
            + role.encode("ascii")
        )
        path = f"assets/{filename}"
        payloads[path] = payload
        motions[role] = {
            "path": path,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "byteCount": len(payload),
            "mediaType": "video/quicktime",
            "width": 64,
            "height": 96,
            "durationMilliseconds": 500,
        }

    manifest = {
        "format": BUILD.avtr.FORMAT,
        "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
        "variant": BUILD.avtr.IOS_VARIANT,
        "id": identifier,
        "displayName": display_name,
        "rig": rig,
        "expression": _full_expression(),
        "assets": assets,
        "motions": motions,
    }
    manifest_payload = json.dumps(
        manifest, sort_keys=True, separators=(",", ":")
    ).encode()
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            BUILD._fixed_zip_info(BUILD.avtr.MANIFEST, zipfile.ZIP_DEFLATED),
            manifest_payload,
        )
        for path, payload in sorted(payloads.items()):
            archive.writestr(
                BUILD._fixed_zip_info(path, zipfile.ZIP_DEFLATED), payload
            )
    return manifest


def _motion_probe() -> dict:
    return {
        "streamCount": 1,
        "videoTracks": 1,
        "audioTracks": 0,
        "formatNames": ["mov", "mp4"],
        "codecName": "hevc",
        "codecTag": "hvc1",
        "width": 64,
        "height": 96,
        "durationMilliseconds": 500,
        "hasAlpha": True,
    }


def _production_urls(
    tag: str = "avatar-store-v1.0.2",
    identifier: str = "cleo",
) -> dict[str, str]:
    repository = "tivojn/openclam-livekit-studio"
    return {
        "catalog_url": (
            f"https://raw.githubusercontent.com/{repository}/{tag}/"
            "shared/avatar-store-v1/catalog/v1/catalog.json"
        ),
        "release_url": (
            f"https://github.com/{repository}/releases/download/{tag}"
        ),
        "thumbnail_url": (
            f"https://raw.githubusercontent.com/{repository}/{tag}/"
            f"shared/avatar-store-v1/catalog/v1/{identifier}-thumbnail.png"
        ),
    }


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

    def test_v2_and_v3_archives_remain_valid_legacy_inputs(self):
        v2 = BUILD._validate_ios_archive(
            PACKAGE_FIXTURES / "ios-light-golden.avtr"
        )
        self.assertEqual(v2["version"], BUILD.avtr.VERSION)
        with self.assertRaisesRegex(BUILD.StoreBuildError, "full-expression v4"):
            BUILD._validate_ios_archive(
                PACKAGE_FIXTURES / "ios-light-golden.avtr",
                require_full_expression=True,
            )

        with patch.object(
            BUILD.avtr, "_probe_motion_details", return_value=_motion_probe()
        ):
            v3 = BUILD._validate_ios_archive(
                PACKAGE_FIXTURES / "ios-light-motion-v3-golden.avtr"
            )
        self.assertEqual(v3["version"], BUILD.avtr.IOS_MOTION_VERSION)
        self.assertEqual(set(v3["motions"]), {"edgeIdle", "moves"})

    def test_v4_archive_requires_full_expression_and_exact_store_motions(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "cleo-v4.avtr"
            expected = _make_v4_archive(archive)
            with patch.object(
                BUILD.avtr, "_probe_motion_details", return_value=_motion_probe()
            ) as probe:
                validated = BUILD._validate_ios_archive(
                    archive,
                    require_full_expression=True,
                    required_motions=BUILD.CLEO_REQUIRED_MOTIONS,
                )
            self.assertEqual(validated, expected)
            self.assertEqual(probe.call_count, 3)

            missing = Path(temporary) / "cleo-missing-walk.avtr"
            _make_v4_archive(missing, motion_roles=("edgeIdle", "moves"))
            with self.assertRaisesRegex(
                BUILD.StoreBuildError, "requires walk, edge idle, and moves"
            ):
                BUILD._validate_ios_archive(
                    missing,
                    require_full_expression=True,
                    required_motions=BUILD.CLEO_REQUIRED_MOTIONS,
                )

    def test_v4_archive_rejects_asset_ledger_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / "original.avtr"
            _make_v4_archive(original)
            tampered = root / "tampered.avtr"
            with zipfile.ZipFile(original) as source, zipfile.ZipFile(
                tampered, "w", zipfile.ZIP_DEFLATED
            ) as destination:
                for info in source.infolist():
                    payload = source.read(info)
                    if info.filename == "assets/viseme-aa.jpg":
                        payload += b"tampered"
                    destination.writestr(
                        BUILD._fixed_zip_info(
                            info.filename, zipfile.ZIP_DEFLATED
                        ),
                        payload,
                    )
            with self.assertRaisesRegex(
                BUILD.StoreBuildError, "asset integrity failed"
            ):
                BUILD._validate_ios_archive(
                    tampered,
                    require_full_expression=True,
                    required_motions=BUILD.CLEO_REQUIRED_MOTIONS,
                )

    def test_versioned_repository_urls_cross_check_one_immutable_tag(self):
        tag = "avatar-store-v1.0.2"
        urls = _production_urls(tag)
        BUILD._validate_repository_urls(
            **urls,
            thumbnail_filename="cleo-thumbnail.png",
            release_tag=tag,
        )
        for key in ("catalog_url", "release_url", "thumbnail_url"):
            mismatched = dict(urls)
            mismatched[key] = mismatched[key].replace(tag, "avatar-store-v1.0.3")
            with self.subTest(key=key), self.assertRaises(
                BUILD.StoreBuildError
            ):
                BUILD._validate_repository_urls(
                    **mismatched,
                    thumbnail_filename="cleo-thumbnail.png",
                    release_tag=tag,
                )
        with self.assertRaisesRegex(BUILD.StoreBuildError, "immutable"):
            BUILD._validate_repository_urls(
                **urls,
                thumbnail_filename="cleo-thumbnail.png",
                release_tag="main",
            )

    def test_explicit_catalog_merge_preserves_every_other_entry(self):
        base = json.loads(BASE_CATALOG.read_text())
        originals = {
            row["id"]: copy.deepcopy(row)
            for row in base["entries"]
            if row["id"] != "cleo"
        }
        current = next(row for row in base["entries"] if row["id"] == "cleo")
        updated = copy.deepcopy(current)
        updated["version"] = current["version"] + 1
        updated["thumbnail"]["url"] = _production_urls()["thumbnail_url"]

        merged = BUILD._merge_catalog(
            base,
            updated,
            require_existing=True,
            preserved_identifiers=frozenset(originals),
        )
        merged_by_id = {row["id"]: row for row in merged["entries"]}
        for identifier, original in originals.items():
            self.assertEqual(merged_by_id[identifier], original)
        self.assertEqual(merged_by_id["cleo"], updated)
        self.assertEqual(
            [row["id"] for row in merged["entries"]],
            [row["id"] for row in base["entries"]],
        )

        same_version = copy.deepcopy(updated)
        same_version["version"] = current["version"]
        with self.assertRaisesRegex(BUILD.StoreBuildError, "increase"):
            BUILD._merge_catalog(
                base,
                same_version,
                require_existing=True,
                preserved_identifiers=frozenset(originals),
            )
        missing_ara = copy.deepcopy(base)
        missing_ara["entries"] = [
            row for row in missing_ara["entries"] if row["id"] != "ara"
        ]
        with self.assertRaisesRegex(BUILD.StoreBuildError, "preserved avatar"):
            BUILD._merge_catalog(
                missing_ara,
                updated,
                require_existing=True,
                preserved_identifiers=frozenset(originals),
            )

    def test_ara_staging_forces_v4_and_preserves_captain_and_cleo(self):
        base = json.loads(BASE_CATALOG.read_text())
        originals = {
            row["id"]: copy.deepcopy(row)
            for row in base["entries"]
            if row["id"] in {"captain-ayer", "cleo"}
        }
        manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "ara",
            "displayName": "Ara",
        }

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prior_catalog = root / "prior-catalog.json"
            prior_catalog.write_text(json.dumps({
                **base,
                "entries": [
                    ({**row, "version": 1} if row["id"] == "ara" else row)
                    for row in base["entries"]
                ],
            }))
            source = root / "cleo-full-expression-fresh-20260827"
            source.mkdir()
            Image.new("RGBA", (64, 64), (80, 90, 100, 255)).save(
                source / "keyframe.png"
            )
            output = root / "staged-release"

            def export_ios(
                identifier, display_name, authoring, runtime, destination, **kwargs
            ):
                Path(destination).write_bytes(b"deterministic-ara-ios-v4")
                return copy.deepcopy(manifest)

            with patch.object(BUILD, "_validate_ready_source") as ready, \
                    patch.object(
                        BUILD.avtr, "export_ios_light", side_effect=export_ios
                    ) as ios_export, \
                    patch.object(BUILD, "normalize_archive"), \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=manifest
                    ) as validate_ios:
                result = BUILD.build_release(
                    source,
                    output,
                    identifier="ara",
                    display_name="Ara",
                    author="OpenClam",
                    version=2,
                    base_catalog_path=prior_catalog,
                    source_identifier="cleo-full-expression-fresh-20260827",
                    source_display_name="Cleo Full Expression Fresh 20260827",
                    release_tag="avatar-store-v1.0.2",
                    **_production_urls(identifier="ara"),
                )

            ready.assert_called_once_with(
                source.resolve(),
                "cleo-full-expression-fresh-20260827",
                "Cleo Full Expression Fresh 20260827",
            )
            self.assertEqual(ios_export.call_count, 2)
            self.assertTrue(all(
                call.kwargs["require_full_expression"] is True
                for call in ios_export.call_args_list
            ))
            self.assertTrue(all(
                call.kwargs["require_full_expression"] is True
                and call.kwargs["required_motions"]
                    == BUILD.FULL_EXPRESSION_REQUIRED_MOTIONS
                for call in validate_ios.call_args_list
            ))
            self.assertTrue(result["verifiedReproducible"])

            merged = {row["id"]: row for row in result["catalog"]["entries"]}
            self.assertEqual(merged["captain-ayer"], originals["captain-ayer"])
            self.assertEqual(merged["cleo"], originals["cleo"])
            self.assertEqual((merged["ara"]["id"], merged["ara"]["name"]), (
                "ara", "Ara"
            ))
            self.assertEqual(merged["ara"]["version"], 2)
            self.assertTrue(
                (output / "release-assets" / "ara-ios-light.avtr").is_file()
            )

    def test_new_full_expression_identity_requires_all_store_motions(self):
        manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "new-avatar",
            "displayName": "New Avatar",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "new-avatar-project"
            source.mkdir()
            Image.new("RGBA", (64, 64), (80, 90, 100, 255)).save(
                source / "keyframe.png"
            )
            output = root / "staged-release"

            def export_ios(
                identifier, display_name, authoring, runtime, destination, **kwargs
            ):
                Path(destination).write_bytes(b"deterministic-new-avatar-ios-v4")
                return copy.deepcopy(manifest)

            with patch.object(BUILD, "_validate_ready_source"), \
                    patch.object(
                        BUILD.avtr, "export_ios_light", side_effect=export_ios
                    ), \
                    patch.object(BUILD, "normalize_archive"), \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=manifest
                    ) as validate_ios:
                BUILD.build_release(
                    source,
                    output,
                    identifier="new-avatar",
                    display_name="New Avatar",
                    author="OpenClam",
                    version=1,
                    base_catalog_path=BASE_CATALOG,
                    source_identifier="new-avatar-project",
                    source_display_name="New Avatar",
                    release_tag="avatar-store-v1.0.2",
                    require_full_expression=True,
                    **_production_urls(identifier="new-avatar"),
                )

            validate_ios.assert_called_once()
            self.assertTrue(validate_ios.call_args.kwargs["require_full_expression"])
            self.assertEqual(
                validate_ios.call_args.kwargs["required_motions"],
                BUILD.FULL_EXPRESSION_REQUIRED_MOTIONS,
            )

    def test_cleo_staging_forces_public_identity_v4_two_builds_and_ios_only(self):
        base = json.loads(BASE_CATALOG.read_text())
        originals = {
            row["id"]: copy.deepcopy(row)
            for row in base["entries"]
            if row["id"] != "cleo"
        }
        manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "cleo",
            "displayName": "Cleo",
        }

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prior_catalog = root / "prior-catalog.json"
            prior_catalog.write_text(json.dumps({
                **base,
                "entries": [
                    ({**row, "version": 1} if row["id"] == "cleo" else row)
                    for row in base["entries"]
                ],
            }))
            source = root / "cleo-full-expression"
            source.mkdir()
            Image.new("RGBA", (64, 64), (80, 90, 100, 255)).save(
                source / "keyframe.png"
            )
            output = root / "staged-release"

            def export_ios(
                identifier, display_name, authoring, runtime, destination, **kwargs
            ):
                Path(destination).write_bytes(b"deterministic-ios-v4")
                return copy.deepcopy(manifest)

            with patch.object(BUILD, "_validate_ready_source") as ready, \
                    patch.object(
                        BUILD.avtr, "export_ios_light", side_effect=export_ios
                    ) as ios_export, \
                    patch.object(BUILD, "normalize_archive") as normalize, \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=manifest
                    ) as validate_ios, \
                    patch.object(BUILD.avtr, "export_macos_full") as mac_export:
                result = BUILD.build_release(
                    source,
                    output,
                    identifier="cleo",
                    display_name="Cleo",
                    author="OpenClam",
                    version=2,
                    base_catalog_path=prior_catalog,
                    source_identifier="cleo-full-expression",
                    source_display_name="Cleo Full Expression",
                    release_tag="avatar-store-v1.0.2",
                    **_production_urls(),
                )

            ready.assert_called_once_with(
                source.resolve(), "cleo-full-expression", "Cleo Full Expression"
            )
            self.assertEqual(ios_export.call_count, 2)
            self.assertEqual(normalize.call_count, 2)
            self.assertEqual(validate_ios.call_count, 2)
            self.assertTrue(all(
                call.kwargs["require_full_expression"] is True
                and call.kwargs["required_motions"] == BUILD.CLEO_REQUIRED_MOTIONS
                for call in validate_ios.call_args_list
            ))
            self.assertTrue(all(
                call.kwargs["require_full_expression"] is True
                for call in ios_export.call_args_list
            ))
            mac_export.assert_not_called()
            self.assertTrue(result["verifiedReproducible"])
            self.assertIsNone(result["macManifest"])

            merged = {row["id"]: row for row in result["catalog"]["entries"]}
            self.assertEqual(set(merged), set(originals) | {"cleo"})
            for identifier, original in originals.items():
                self.assertEqual(merged[identifier], original)
            self.assertEqual((merged["cleo"]["id"], merged["cleo"]["name"]), (
                "cleo", "Cleo"
            ))
            self.assertEqual(set(merged["cleo"]["variants"]), {"ios-light"})
            self.assertFalse(
                (output / "release-assets" / "cleo-macos-full.avtr").exists()
            )
            self.assertTrue(
                (output / "release-assets" / "cleo-ios-light.avtr").is_file()
            )

    def test_cleo_staging_rejects_non_reproducible_second_build(self):
        manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "cleo",
            "displayName": "Cleo",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            Image.new("RGBA", (8, 8), (0, 0, 0, 255)).save(
                source / "keyframe.png"
            )
            output = root / "output"
            build_number = 0

            def export_ios(*arguments, **kwargs):
                nonlocal build_number
                build_number += 1
                Path(arguments[4]).write_bytes(f"build-{build_number}".encode())
                return copy.deepcopy(manifest)

            with patch.object(BUILD, "_validate_ready_source"), \
                    patch.object(
                        BUILD.avtr, "export_ios_light", side_effect=export_ios
                    ), \
                    patch.object(BUILD, "normalize_archive"), \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=manifest
                    ):
                with self.assertRaisesRegex(
                    BUILD.StoreBuildError, "not byte reproducible"
                ):
                    BUILD.build_release(
                        source,
                        output,
                        identifier="cleo",
                        display_name="Cleo",
                        author="OpenClam",
                        version=2,
                        base_catalog_path=BASE_CATALOG,
                        source_identifier="cleo-full-expression",
                        source_display_name="Cleo Full Expression",
                        release_tag="avatar-store-v1.0.2",
                        **_production_urls(),
                    )
            self.assertFalse(output.exists())

    def test_exported_archive_must_keep_the_public_store_identity(self):
        wrong_manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "cleo-full-expression",
            "displayName": "Cleo Full Expression",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            releases = root / "release-assets"
            source = root / "source"
            releases.mkdir()
            (source / "runtime").mkdir(parents=True)

            def export_ios(*arguments, **kwargs):
                Path(arguments[4]).write_bytes(b"archive")
                return copy.deepcopy(wrong_manifest)

            with patch.object(
                    BUILD.avtr, "export_ios_light", side_effect=export_ios), \
                    patch.object(BUILD, "normalize_archive"), \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=wrong_manifest
                    ):
                with self.assertRaisesRegex(
                    BUILD.StoreBuildError, "archive identity"
                ):
                    BUILD._export_archives(
                        releases,
                        identifier="cleo",
                        display_name="Cleo",
                        source=source,
                        include_macos_full=False,
                        require_full_expression=True,
                        required_motions=BUILD.CLEO_REQUIRED_MOTIONS,
                    )

    def test_optional_mac_archive_must_keep_the_public_store_identity(self):
        ios_manifest = {
            "format": BUILD.avtr.FORMAT,
            "version": BUILD.avtr.IOS_EXPRESSION_VERSION,
            "variant": BUILD.avtr.IOS_VARIANT,
            "id": "cleo",
            "displayName": "Cleo",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            releases = root / "release-assets"
            source = root / "source"
            releases.mkdir()
            (source / "runtime").mkdir(parents=True)

            def export_ios(*arguments, **kwargs):
                Path(arguments[4]).write_bytes(b"ios-archive")
                return copy.deepcopy(ios_manifest)

            def export_mac(*arguments, **kwargs):
                Path(arguments[2]).write_bytes(b"mac-archive")
                return {
                    "id": "cleo",
                    "displayName": "Cleo Full Expression",
                    "capabilities": {},
                }

            with patch.object(
                    BUILD.avtr, "export_ios_light", side_effect=export_ios), \
                    patch.object(
                        BUILD.avtr, "export_macos_full", side_effect=export_mac
                    ), \
                    patch.object(BUILD, "normalize_archive"), \
                    patch.object(
                        BUILD, "_validate_ios_archive", return_value=ios_manifest
                    ):
                with self.assertRaisesRegex(
                    BUILD.StoreBuildError, "Mac archive identity"
                ):
                    BUILD._export_archives(
                        releases,
                        identifier="cleo",
                        display_name="Cleo",
                        source=source,
                        include_macos_full=True,
                        require_full_expression=True,
                        required_motions=BUILD.CLEO_REQUIRED_MOTIONS,
                    )

    def test_cleo_public_identity_base_catalog_and_tag_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            common = {
                "source_root": source,
                "output_root": root / "output",
                "author": "OpenClam",
                "version": 2,
                **_production_urls(),
            }
            for identifier, display_name in (
                ("cleo", "Cleo Full Expression"),
                ("cleo-full-expression", "Cleo"),
            ):
                with self.subTest(identifier=identifier), self.assertRaisesRegex(
                    BUILD.StoreBuildError, "public identity cleo / Cleo"
                ):
                    BUILD.build_release(
                        **common,
                        identifier=identifier,
                        display_name=display_name,
                    )

            with self.assertRaisesRegex(BUILD.StoreBuildError, "base catalog"):
                BUILD.build_release(
                    **common,
                    identifier="cleo",
                    display_name="Cleo",
                    release_tag="avatar-store-v1.0.2",
                )
            with self.assertRaisesRegex(BUILD.StoreBuildError, "version tag"):
                BUILD.build_release(
                    **common,
                    identifier="cleo",
                    display_name="Cleo",
                    base_catalog_path=BASE_CATALOG,
                )

    def test_ara_public_identity_base_catalog_and_tag_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            common = {
                "source_root": source,
                "output_root": root / "output",
                "author": "OpenClam",
                "version": 2,
                **_production_urls(identifier="ara"),
            }
            for identifier, display_name in (
                ("ara", "Ara Full Expression"),
                ("ara-full-expression", "Ara"),
            ):
                with self.subTest(identifier=identifier), self.assertRaisesRegex(
                    BUILD.StoreBuildError, "public identity ara / Ara"
                ):
                    BUILD.build_release(
                        **common,
                        identifier=identifier,
                        display_name=display_name,
                    )

            with self.assertRaisesRegex(BUILD.StoreBuildError, "base catalog"):
                BUILD.build_release(
                    **common,
                    identifier="ara",
                    display_name="Ara",
                    release_tag="avatar-store-v1.0.2",
                )
            with self.assertRaisesRegex(BUILD.StoreBuildError, "version tag"):
                BUILD.build_release(
                    **common,
                    identifier="ara",
                    display_name="Ara",
                    base_catalog_path=BASE_CATALOG,
                )


if __name__ == "__main__":
    unittest.main()
