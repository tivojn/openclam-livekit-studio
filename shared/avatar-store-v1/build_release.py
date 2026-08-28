#!/usr/bin/env python3
"""Build a deterministic, hash-pinned OpenClam avatar-store release bundle.

This tool calls the product AVTR exporters, normalizes ZIP metadata so an
unchanged approved avatar produces byte-identical archives, validates the
selected profiles (including iOS AVTR v2/v3/v4), and writes the exact shared
catalog contract. It never uploads.
"""
from __future__ import annotations

import argparse
import copy
import filecmp
import hashlib
import io
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import urlparse

import jsonschema
from PIL import Image


HERE = Path(__file__).resolve().parent
SUITE_ROOT = HERE.parents[1]
SERVER_ROOT = SUITE_ROOT / "macos" / "OpenClamStudio" / "server"
sys.path.insert(0, str(SERVER_ROOT))

import avatar_package as avtr  # noqa: E402


FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
REQUIRED_CAPABILITIES = {"head", "fullBody", "walk", "edgeIdle", "moves"}
IDENTIFIER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
IMMUTABLE_TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MUTABLE_REFS = {"head", "latest", "main", "master", "trunk"}
STORE_TAG_RE = re.compile(r"^avatar-store-v[0-9]+\.[0-9]+\.[0-9]+$")
FULL_EXPRESSION_STORE_RELEASES = {
    "ara": {
        "displayName": "Ara",
        "preserve": frozenset({"captain-ayer", "cleo"}),
    },
    "cleo": {
        "displayName": "Cleo",
        "preserve": frozenset({"captain-ayer", "ara"}),
    },
}
FULL_EXPRESSION_REQUIRED_MOTIONS = frozenset({"walk", "edgeIdle", "moves"})
# Kept as aliases for existing callers while the Store transitions from the
# original Cleo-only release helper to protected full-expression updates.
CLEO_PUBLIC_ID = "cleo"
CLEO_PUBLIC_NAME = "Cleo"
CLEO_TAG_RE = STORE_TAG_RE
CLEO_REQUIRED_MOTIONS = FULL_EXPRESSION_REQUIRED_MOTIONS
PACKAGE_SCHEMA_ROOT = SUITE_ROOT / "shared" / "avatar-package-v2"
PACKAGE_SCHEMAS = {
    avtr.VERSION: PACKAGE_SCHEMA_ROOT / "manifest.schema.json",
    avtr.IOS_MOTION_VERSION: PACKAGE_SCHEMA_ROOT / "ios-light-v3.schema.json",
    avtr.IOS_EXPRESSION_VERSION:
        PACKAGE_SCHEMA_ROOT / "ios-full-expression-v4.schema.json",
}


class StoreBuildError(ValueError):
    """A safe release-builder failure."""


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_record(path: Path) -> dict[str, int | str]:
    size = path.stat().st_size
    if size < 1:
        raise StoreBuildError(f"empty artifact: {path.name}")
    return {"sha256": sha256_path(path), "bytes": size}


def _strict_https(url: str, expected_host: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != expected_host \
            or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise StoreBuildError(f"unsafe release URL: {url}")
    return url.rstrip("/")


def _safe_text(value: str, label: str) -> str:
    if not isinstance(value, str) or value != value.strip() or not value \
            or len(value) > 64 or any(ord(character) < 32 for character in value):
        raise StoreBuildError(f"invalid {label}")
    return value


def artifact_filenames(identifier: str) -> tuple[str, str, str]:
    if not isinstance(identifier, str) or not IDENTIFIER_RE.fullmatch(identifier):
        raise StoreBuildError("invalid avatar identifier")
    return (
        f"{identifier}-ios-light.avtr",
        f"{identifier}-macos-full.avtr",
        f"{identifier}-thumbnail.png",
    )


def _validate_repository_urls(
    *,
    catalog_url: str,
    release_url: str,
    thumbnail_url: str,
    thumbnail_filename: str,
    release_tag: str | None = None,
) -> None:
    catalog_parts = urlparse(catalog_url).path.strip("/").split("/")
    release_parts = urlparse(release_url).path.strip("/").split("/")
    thumbnail_parts = urlparse(thumbnail_url).path.strip("/").split("/")
    if release_tag is not None:
        if not IMMUTABLE_TAG_RE.fullmatch(release_tag) \
                or release_tag.lower() in MUTABLE_REFS:
            raise StoreBuildError("release tag must be an immutable Git reference")
        catalog_tails = {
            (release_tag, "catalog", "v1", "catalog.json"),
            (
                release_tag, "shared", "avatar-store-v1", "catalog", "v1",
                "catalog.json",
            ),
        }
        thumbnail_tails = {
            (release_tag, "catalog", "v1", thumbnail_filename),
            (
                release_tag, "shared", "avatar-store-v1", "catalog", "v1",
                thumbnail_filename,
            ),
        }
        if tuple(catalog_parts[2:]) not in catalog_tails:
            raise StoreBuildError("catalog URL must use the immutable release tag")
        if tuple(thumbnail_parts[2:]) not in thumbnail_tails:
            raise StoreBuildError("thumbnail URL must use the immutable release tag")
    else:
        # Preserve the generic fixture-builder contract. Production releases
        # provide ``release_tag`` and therefore cannot use a mutable branch.
        if len(catalog_parts) != 6 \
                or catalog_parts[2:] != ["main", "catalog", "v1", "catalog.json"]:
            raise StoreBuildError("catalog URL must use the exact v1 catalog path")
        if len(thumbnail_parts) != 6 \
                or thumbnail_parts[2:] != [
                    "main", "catalog", "v1", thumbnail_filename
                ]:
            raise StoreBuildError("thumbnail URL must use the exact v1 catalog path")
    if len(release_parts) != 5 \
            or release_parts[2:4] != ["releases", "download"] \
            or not release_parts[4]:
        raise StoreBuildError("release URL must identify one GitHub release tag")
    if release_tag is not None and release_parts[4] != release_tag:
        raise StoreBuildError("all release URLs must use the same immutable tag")
    repositories = {
        tuple(catalog_parts[:2]),
        tuple(release_parts[:2]),
        tuple(thumbnail_parts[:2]),
    }
    if len(repositories) != 1:
        raise StoreBuildError("catalog, thumbnail, and release URLs must share one repository")


def _fixed_zip_info(name: str, compression: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
    info.create_system = 3
    info.compress_type = compression
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    info.extra = b""
    info.comment = b""
    return info


def normalize_archive(path: Path, compression: int) -> None:
    """Rewrite a generated archive with fixed order, timestamps and modes."""
    temporary = path.with_name(f".{path.name}.normalize-{os.getpid()}.tmp")
    try:
        with zipfile.ZipFile(path, "r") as source:
            names = source.namelist()
            if len(names) != len(set(names)) or avtr.MANIFEST not in names:
                raise StoreBuildError(f"invalid generated archive: {path.name}")
            ordered = [avtr.MANIFEST] + sorted(
                name for name in names if name != avtr.MANIFEST
            )
            with zipfile.ZipFile(
                temporary,
                "w",
                compression=compression,
                compresslevel=9 if compression == zipfile.ZIP_DEFLATED else None,
                allowZip64=True,
            ) as target:
                for name in ordered:
                    original = source.getinfo(name)
                    if original.is_dir():
                        raise StoreBuildError(f"unexpected directory entry: {name}")
                    info = _fixed_zip_info(name, compression)
                    info.file_size = original.file_size
                    with source.open(original, "r") as reader, target.open(
                        info, "w"
                    ) as writer:
                        shutil.copyfileobj(reader, writer, 1024 * 1024)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_checksum(path: Path) -> Path:
    sidecar = path.with_name(path.name + ".sha256")
    sidecar.write_text(f"{sha256_path(path)}  {path.name}\n", encoding="ascii")
    os.chmod(sidecar, 0o600)
    return sidecar


def _validate_ready_source(root: Path, identifier: str, name: str) -> None:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("slug") != identifier or manifest.get("name") != name:
        raise StoreBuildError("source avatar identity does not match the release")
    if manifest.get("status") != "ready":
        raise StoreBuildError("source avatar must be approved and ready")
    capabilities = avtr._capabilities(root)
    if set(capabilities) != REQUIRED_CAPABILITIES or not all(capabilities.values()):
        raise StoreBuildError("source avatar lacks a required store capability")
    # This invokes the product exporter's regular-file, pruning, path, size,
    # hard-link and credential preflight without creating an archive.
    avtr._authoring_files(root)


def _image_payload_details(payload: bytes, role: str) -> tuple[int, int, str]:
    try:
        with Image.open(io.BytesIO(payload)) as image:
            image.verify()
        with Image.open(io.BytesIO(payload)) as image:
            width, height = image.size
            image_format = image.format
    except Exception as error:
        raise StoreBuildError(f"iPhone image asset is invalid: {role}") from error
    media_type = {"PNG": "image/png", "JPEG": "image/jpeg"}.get(image_format)
    if media_type is None:
        raise StoreBuildError(f"iPhone image asset type is invalid: {role}")
    return width, height, media_type


def _validate_ios_motion_payload(payload: bytes, role: str, row: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="openclam-store-motion-") as temporary:
        path = Path(temporary) / f"{role}.mov"
        path.write_bytes(payload)
        os.chmod(path, 0o600)
        if not avtr._quicktime_header(path):
            raise StoreBuildError(f"iPhone motion is not QuickTime: {role}")
        try:
            inspected = avtr._probe_motion_details(path)
        except avtr.AvatarPackageError as error:
            raise StoreBuildError(f"iPhone motion inspection failed: {role}") from error
    if inspected.get("streamCount") != 1 \
            or inspected.get("videoTracks") != 1 \
            or inspected.get("audioTracks") != 0 \
            or "mov" not in inspected.get("formatNames", []) \
            or inspected.get("codecName") != "hevc" \
            or inspected.get("codecTag") != "hvc1" \
            or inspected.get("hasAlpha") is not True:
        raise StoreBuildError(f"iPhone motion codec contract is invalid: {role}")
    if inspected.get("width") != row.get("width") \
            or inspected.get("height") != row.get("height") \
            or abs(
                int(inspected.get("durationMilliseconds") or 0)
                - int(row.get("durationMilliseconds") or 0)
            ) > avtr.MAX_IOS_MOTION_DURATION_DRIFT_MS:
        raise StoreBuildError(f"iPhone motion metadata is invalid: {role}")


def _validate_ios_archive(
    path: Path,
    *,
    require_full_expression: bool = False,
    required_motions: frozenset[str] | None = None,
) -> dict:
    if path.stat().st_size > avtr.MAX_IOS_ARCHIVE_BYTES:
        raise StoreBuildError("iPhone archive exceeds the AVTR limit")
    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)) \
                or avtr.MANIFEST not in names \
                or any(not avtr._safe_zip_path(name) for name in names):
            raise StoreBuildError("iPhone archive file contract is invalid")
        if any(not avtr._regular_zip_entry(info) for info in infos):
            raise StoreBuildError("iPhone archive contains a non-regular entry")
        raw_manifest = archive.read(avtr.MANIFEST)
        if not 1 <= len(raw_manifest) <= avtr.MAX_MANIFEST_BYTES:
            raise StoreBuildError("iPhone manifest size is invalid")
        try:
            manifest = json.loads(raw_manifest)
            version = manifest["version"]
            schema_path = PACKAGE_SCHEMAS[version]
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            jsonschema.Draft202012Validator.check_schema(schema)
            jsonschema.Draft202012Validator(schema).validate(manifest)
        except (
            KeyError, TypeError, ValueError, json.JSONDecodeError,
            jsonschema.ValidationError, jsonschema.SchemaError,
        ) as error:
            raise StoreBuildError("iPhone manifest contract is invalid") from error
        if manifest.get("format") != avtr.FORMAT \
                or manifest.get("variant") != avtr.IOS_VARIANT:
            raise StoreBuildError("iPhone manifest contract is invalid")
        if require_full_expression \
                and manifest.get("version") != avtr.IOS_EXPRESSION_VERSION:
            raise StoreBuildError("iPhone Store release must use full-expression v4")
        archive_limit = (
            avtr.MAX_IOS_ARCHIVE_BYTES
            if manifest["version"] == avtr.IOS_EXPRESSION_VERSION
            else avtr.MAX_IOS_LEGACY_ARCHIVE_BYTES
        )
        if path.stat().st_size > archive_limit:
            raise StoreBuildError("iPhone archive exceeds its AVTR profile limit")

        assets = manifest.get("assets")
        motions = manifest.get("motions") or {}
        if not isinstance(assets, dict) or not isinstance(motions, dict):
            raise StoreBuildError("iPhone asset ledger is invalid")
        if required_motions is not None and set(motions) != set(required_motions):
            raise StoreBuildError("iPhone Store release requires walk, edge idle, and moves")
        declared_paths = {
            row["path"] for row in [*assets.values(), *motions.values()]
        }
        expected = {avtr.MANIFEST, *declared_paths}
        if set(names) != expected or len(names) != len(expected):
            raise StoreBuildError("iPhone archive file contract is invalid")

        decoded_pixels = 0
        for role, row in manifest["assets"].items():
            payload = archive.read(row["path"])
            if len(payload) != row["byteCount"] \
                    or hashlib.sha256(payload).hexdigest() != row["sha256"]:
                raise StoreBuildError(f"iPhone asset integrity failed: {role}")
            width, height, media_type = _image_payload_details(payload, role)
            if (width, height, media_type) != (
                row["width"], row["height"], row["mediaType"]
            ):
                raise StoreBuildError(f"iPhone image ledger is invalid: {role}")
            decoded_pixels += width * height
        if decoded_pixels > avtr.MAX_IOS_TOTAL_PIXELS:
            raise StoreBuildError("iPhone decoded image budget is exceeded")
        try:
            avtr._validate_ios_rig_assets(
                manifest["rig"],
                assets,
                visemes=(
                    avtr.IOS_VISEMES
                    if manifest["version"] == avtr.IOS_EXPRESSION_VERSION
                    else avtr.IOS_LEGACY_VISEMES
                ),
                expression=manifest.get("expression"),
            )
        except avtr.AvatarPackageError as error:
            raise StoreBuildError("iPhone rig and asset geometry is invalid") from error
        for role, row in motions.items():
            payload = archive.read(row["path"])
            if len(payload) != row["byteCount"] \
                    or hashlib.sha256(payload).hexdigest() != row["sha256"]:
                raise StoreBuildError(f"iPhone motion integrity failed: {role}")
            _validate_ios_motion_payload(payload, role, row)

        expanded_limit = (
            avtr.MAX_IOS_EXPANDED_BYTES
            if manifest["version"] == avtr.IOS_EXPRESSION_VERSION
            else avtr.MAX_IOS_LEGACY_EXPANDED_BYTES
        )
        if sum(info.file_size for info in infos) > expanded_limit:
            raise StoreBuildError("iPhone expanded archive budget is exceeded")
        return manifest


def _validate_mac_archive(path: Path, expected_capabilities: dict) -> dict:
    with tempfile.TemporaryDirectory(prefix="openclam-store-import-") as temporary:
        result = avtr.import_macos_full(path, Path(temporary) / "avatars")
    if result.get("capabilities") != expected_capabilities:
        raise StoreBuildError("Mac capability ledger changed during validation")
    return result


def _validate_catalog(
    catalog: object,
    *,
    identifier: str,
    display_name: str,
    author: str,
    version: int,
) -> None:
    schema = json.loads((HERE / "catalog.schema.json").read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    try:
        jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(catalog)
    except jsonschema.ValidationError as error:
        raise StoreBuildError("catalog does not match the v1 schema") from error
    if not isinstance(catalog, dict) or set(catalog) != {"schemaVersion", "entries"} \
            or catalog.get("schemaVersion") != 1:
        raise StoreBuildError("catalog root is invalid")
    entries = catalog.get("entries")
    if not isinstance(entries, list) or not entries:
        raise StoreBuildError("release catalog must contain at least one entry")
    identifiers = [entry.get("id") for entry in entries if isinstance(entry, dict)]
    if len(identifiers) != len(entries) or len(identifiers) != len(set(identifiers)):
        raise StoreBuildError("release catalog contains duplicate identities")
    matches = [entry for entry in entries if entry.get("id") == identifier]
    if len(matches) != 1:
        raise StoreBuildError("release catalog must contain the requested identity once")
    entry = matches[0]
    if not isinstance(entry, dict) or set(entry) != {
        "id", "name", "author", "version", "thumbnail", "variants"
    }:
        raise StoreBuildError("catalog entry is invalid")
    if (entry["id"], entry["name"], entry["author"], entry["version"]) != (
        identifier, display_name, author, version
    ):
        raise StoreBuildError("catalog identity is invalid")
    thumbnail = entry.get("thumbnail")
    if not isinstance(thumbnail, dict) or set(thumbnail) != {
        "url", "sha256", "bytes", "mime", "width", "height"
    } or thumbnail.get("mime") != "image/png":
        raise StoreBuildError("catalog thumbnail is invalid")
    variants = entry.get("variants")
    if not isinstance(variants, dict) \
            or avtr.IOS_VARIANT not in variants \
            or not set(variants).issubset({avtr.IOS_VARIANT, avtr.MAC_VARIANT}):
        raise StoreBuildError("catalog variants are invalid")
    for profile in variants:
        row = variants.get(profile)
        if not isinstance(row, dict) or set(row) != {
            "url", "sha256", "bytes", "format", "profile"
        } or row.get("format") != avtr.FORMAT or row.get("profile") != profile:
            raise StoreBuildError(f"catalog {profile} package is invalid")
        for key in ("sha256",):
            value = row.get(key)
            if not isinstance(value, str) or len(value) != 64 \
                    or any(character not in "0123456789abcdef" for character in value):
                raise StoreBuildError(f"catalog {profile} hash is invalid")
        if not isinstance(row.get("bytes"), int) or row["bytes"] < 1:
            raise StoreBuildError(f"catalog {profile} size is invalid")


def _read_base_catalog(path: Path) -> dict:
    try:
        path = Path(path)
        catalog = json.loads(path.expanduser().resolve(strict=True).read_text(
            encoding="utf-8"
        ))
        schema = json.loads((HERE / "catalog.schema.json").read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(catalog)
    except (
        OSError, UnicodeDecodeError, json.JSONDecodeError,
        jsonschema.ValidationError,
    ) as error:
        raise StoreBuildError("base catalog is invalid") from error
    entries = catalog.get("entries") if isinstance(catalog, dict) else None
    identifiers = [entry.get("id") for entry in entries or [] if isinstance(entry, dict)]
    if not isinstance(entries, list) or len(identifiers) != len(entries) \
            or len(identifiers) != len(set(identifiers)):
        raise StoreBuildError("base catalog identities are invalid")
    return catalog


def _merge_catalog(
    base_catalog: dict | None,
    entry: dict,
    *,
    require_existing: bool = False,
    preserved_identifiers: frozenset[str] = frozenset(),
) -> dict:
    if base_catalog is None:
        if require_existing or preserved_identifiers:
            raise StoreBuildError("this Store release requires the reviewed base catalog")
        return {"schemaVersion": 1, "entries": [copy.deepcopy(entry)]}

    result = copy.deepcopy(base_catalog)
    entries = result["entries"]
    preserved = {
        identifier: copy.deepcopy(next(
            (row for row in entries if row.get("id") == identifier), None
        ))
        for identifier in preserved_identifiers
    }
    if any(value is None for value in preserved.values()):
        raise StoreBuildError("base catalog is missing a preserved avatar")

    existing_index = next((
        index for index, row in enumerate(entries) if row.get("id") == entry["id"]
    ), None)
    if existing_index is None:
        if require_existing:
            raise StoreBuildError("base catalog is missing the avatar being updated")
        entries.append(copy.deepcopy(entry))
    else:
        current_version = entries[existing_index].get("version")
        if not isinstance(current_version, int) \
                or entry["version"] <= current_version:
            raise StoreBuildError("Store avatar version must increase monotonically")
        entries[existing_index] = copy.deepcopy(entry)

    for identifier, original in preserved.items():
        merged = next((row for row in entries if row.get("id") == identifier), None)
        if merged != original:
            raise StoreBuildError(f"catalog merge changed preserved avatar: {identifier}")
    return result


def _archives_match(first: Path, second: Path) -> bool:
    return first.stat().st_size == second.stat().st_size \
        and sha256_path(first) == sha256_path(second) \
        and filecmp.cmp(first, second, shallow=False)


def _export_archives(
    releases: Path,
    *,
    identifier: str,
    display_name: str,
    source: Path,
    include_macos_full: bool,
    require_full_expression: bool,
    required_motions: frozenset[str] | None,
) -> dict:
    ios_filename, mac_filename, _ = artifact_filenames(identifier)
    ios_path = releases / ios_filename
    ios_manifest = avtr.export_ios_light(
        identifier,
        display_name,
        source,
        source / "runtime",
        ios_path,
        require_full_expression=require_full_expression,
    )
    normalize_archive(ios_path, zipfile.ZIP_DEFLATED)
    validated_ios = _validate_ios_archive(
        ios_path,
        require_full_expression=require_full_expression,
        required_motions=required_motions,
    )
    if validated_ios != ios_manifest:
        raise StoreBuildError("normalized iPhone manifest changed after export")
    if (validated_ios.get("id"), validated_ios.get("displayName")) != (
        identifier, display_name
    ):
        raise StoreBuildError("iPhone archive identity does not match the Store entry")

    mac_path = None
    mac_manifest = None
    if include_macos_full:
        mac_path = releases / mac_filename
        mac_manifest = avtr.export_macos_full(identifier, source, mac_path)
        if (mac_manifest.get("id"), mac_manifest.get("displayName")) != (
            identifier, display_name
        ):
            raise StoreBuildError("Mac archive identity does not match the Store entry")
        normalize_archive(mac_path, zipfile.ZIP_STORED)
        _validate_mac_archive(mac_path, mac_manifest["capabilities"])
    return {
        "iosPath": ios_path,
        "iosManifest": ios_manifest,
        "macPath": mac_path,
        "macManifest": mac_manifest,
    }


def build_release(
    source_root: Path,
    output_root: Path,
    *,
    identifier: str,
    display_name: str,
    author: str,
    version: int,
    catalog_url: str,
    release_url: str,
    thumbnail_url: str,
    base_catalog_path: Path | None = None,
    source_identifier: str | None = None,
    source_display_name: str | None = None,
    release_tag: str | None = None,
    include_macos_full: bool = False,
    require_full_expression: bool = False,
    verify_reproducible: bool = False,
) -> dict:
    source = source_root.expanduser().resolve(strict=True)
    if not source.is_dir() or source.is_symlink():
        raise StoreBuildError("avatar source must be a regular directory")
    output = output_root.expanduser().resolve(strict=False)
    if output.exists():
        raise StoreBuildError("output path already exists")
    if source == output or source in output.parents or output in source.parents:
        raise StoreBuildError("output and avatar source must be separate")
    if not IDENTIFIER_RE.fullmatch(identifier):
        raise StoreBuildError("invalid avatar identifier")
    display_name = _safe_text(display_name, "avatar display name")
    author = _safe_text(author, "avatar publisher")
    protected_release = next((
        (public_id, policy)
        for public_id, policy in FULL_EXPRESSION_STORE_RELEASES.items()
        if identifier == public_id or display_name == policy["displayName"]
    ), None)
    if protected_release is not None:
        public_id, policy = protected_release
        public_name = policy["displayName"]
        if (identifier, display_name) != (public_id, public_name):
            raise StoreBuildError(
                f"{public_name} Store releases must use public identity "
                f"{public_id} / {public_name}"
            )
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise StoreBuildError("invalid avatar version")
    source_identifier = source_identifier or identifier
    source_display_name = source_display_name or display_name
    if not IDENTIFIER_RE.fullmatch(source_identifier):
        raise StoreBuildError("invalid source avatar identifier")
    source_display_name = _safe_text(source_display_name, "source avatar display name")
    if protected_release is not None:
        public_id, policy = protected_release
        public_name = policy["displayName"]
        if base_catalog_path is None:
            raise StoreBuildError(
                f"{public_name} Store releases require the reviewed base catalog"
            )
        if release_tag is None or not STORE_TAG_RE.fullmatch(release_tag):
            raise StoreBuildError(
                f"{public_name} Store releases require an immutable version tag"
            )
        require_full_expression = True
        verify_reproducible = True
    # A full-expression Store package is also a complete animated companion.
    # Keep this invariant for new identities (not only the historically
    # protected Ara/Cleo updates), so a new v4 full-expression package cannot
    # accidentally ship without one of the three Store animation modes.
    required_motions = (
        FULL_EXPRESSION_REQUIRED_MOTIONS
        if require_full_expression else None
    )
    catalog_url = _strict_https(catalog_url, "raw.githubusercontent.com")
    release_url = _strict_https(release_url, "github.com")
    thumbnail_url = _strict_https(thumbnail_url, "raw.githubusercontent.com")
    ios_filename, mac_filename, thumbnail_filename = artifact_filenames(identifier)
    _validate_repository_urls(
        catalog_url=catalog_url,
        release_url=release_url,
        thumbnail_url=thumbnail_url,
        thumbnail_filename=thumbnail_filename,
        release_tag=release_tag,
    )

    _validate_ready_source(source, source_identifier, source_display_name)
    base_catalog = (
        _read_base_catalog(base_catalog_path) if base_catalog_path is not None else None
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".openclam-store-", dir=output.parent))
    try:
        releases = stage / "release-assets"
        catalog_root = stage / "catalog" / "v1"
        releases.mkdir(parents=True)
        catalog_root.mkdir(parents=True)
        thumbnail_path = catalog_root / thumbnail_filename

        built = _export_archives(
            releases,
            identifier=identifier,
            display_name=display_name,
            source=source,
            include_macos_full=include_macos_full,
            require_full_expression=require_full_expression,
            required_motions=required_motions,
        )
        ios_path = built["iosPath"]
        mac_path = built["macPath"]
        ios_manifest = built["iosManifest"]
        mac_manifest = built["macManifest"]

        if verify_reproducible:
            with tempfile.TemporaryDirectory(
                prefix=".openclam-store-repro-", dir=output.parent
            ) as repeat_root:
                repeat_releases = Path(repeat_root) / "release-assets"
                repeat_releases.mkdir()
                repeated = _export_archives(
                    repeat_releases,
                    identifier=identifier,
                    display_name=display_name,
                    source=source,
                    include_macos_full=include_macos_full,
                    require_full_expression=require_full_expression,
                    required_motions=required_motions,
                )
                if not _archives_match(ios_path, repeated["iosPath"]):
                    raise StoreBuildError("iPhone AVTR export is not byte reproducible")
                if include_macos_full and not _archives_match(
                    mac_path, repeated["macPath"]
                ):
                    raise StoreBuildError("Mac AVTR export is not byte reproducible")

        shutil.copyfile(source / "keyframe.png", thumbnail_path)
        os.chmod(thumbnail_path, 0o600)
        with Image.open(thumbnail_path) as image:
            image.verify()
        with Image.open(thumbnail_path) as image:
            if image.format != "PNG":
                raise StoreBuildError("store thumbnail must be PNG")
            width, height = image.size

        ios_record = artifact_record(ios_path)
        thumbnail_record = artifact_record(thumbnail_path)
        variants = {
            avtr.IOS_VARIANT: {
                "url": f"{release_url}/{ios_filename}",
                "sha256": ios_record["sha256"],
                "bytes": ios_record["bytes"],
                "format": avtr.FORMAT,
                "profile": avtr.IOS_VARIANT,
            }
        }
        if include_macos_full:
            mac_record = artifact_record(mac_path)
            variants[avtr.MAC_VARIANT] = {
                "url": f"{release_url}/{mac_filename}",
                "sha256": mac_record["sha256"],
                "bytes": mac_record["bytes"],
                "format": avtr.FORMAT,
                "profile": avtr.MAC_VARIANT,
            }
        entry = {
            "id": identifier,
            "name": display_name,
            "author": author,
            "version": version,
            "thumbnail": {
                "url": thumbnail_url,
                "sha256": thumbnail_record["sha256"],
                "bytes": thumbnail_record["bytes"],
                "mime": "image/png",
                "width": width,
                "height": height,
            },
            "variants": variants,
        }
        catalog = _merge_catalog(
            base_catalog,
            entry,
            require_existing=protected_release is not None,
            preserved_identifiers=(
                policy["preserve"]
                if protected_release is not None else frozenset()
            ),
        )
        _validate_catalog(
            catalog,
            identifier=identifier,
            display_name=display_name,
            author=author,
            version=version,
        )
        catalog_path = catalog_root / "catalog.json"
        catalog_path.write_text(
            json.dumps(catalog, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(catalog_path, 0o600)
        artifacts = [ios_path, thumbnail_path, catalog_path]
        if mac_path is not None:
            artifacts.append(mac_path)
        for artifact in artifacts:
            write_checksum(artifact)

        # Keep the schema beside the public catalog so clients and reviewers
        # can validate the exact contract used to create it.
        shutil.copyfile(HERE / "catalog.schema.json", catalog_root / "catalog.schema.json")
        os.chmod(catalog_root / "catalog.schema.json", 0o600)
        os.replace(stage, output)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise

    return {
        "catalogURL": catalog_url,
        "output": str(output),
        "iosManifest": ios_manifest,
        "macManifest": mac_manifest,
        "catalog": catalog,
        "verifiedReproducible": verify_reproducible,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--avatar-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identifier", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--author", required=True)
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--catalog-url", required=True)
    parser.add_argument("--release-url", required=True)
    parser.add_argument("--thumbnail-url", required=True)
    parser.add_argument("--base-catalog", type=Path)
    parser.add_argument("--source-identifier")
    parser.add_argument("--source-display-name")
    parser.add_argument("--release-tag")
    parser.add_argument("--include-macos-full", action="store_true")
    parser.add_argument("--require-full-expression", action="store_true")
    parser.add_argument("--verify-reproducible", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    result = build_release(
        arguments.avatar_root,
        arguments.output,
        identifier=arguments.identifier,
        display_name=arguments.display_name,
        author=arguments.author,
        version=arguments.version,
        catalog_url=arguments.catalog_url,
        release_url=arguments.release_url,
        thumbnail_url=arguments.thumbnail_url,
        base_catalog_path=arguments.base_catalog,
        source_identifier=arguments.source_identifier,
        source_display_name=arguments.source_display_name,
        release_tag=arguments.release_tag,
        include_macos_full=arguments.include_macos_full,
        require_full_expression=arguments.require_full_expression,
        verify_reproducible=arguments.verify_reproducible,
    )
    selected_entry = next(
        entry for entry in result["catalog"]["entries"]
        if entry["id"] == arguments.identifier
    )
    print(json.dumps({
        "catalogURL": result["catalogURL"],
        "output": result["output"],
        "entry": selected_entry,
        "verifiedReproducible": result["verifiedReproducible"],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
