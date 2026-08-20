#!/usr/bin/env python3
"""Build a deterministic, hash-pinned OpenClam avatar-store release bundle.

This tool calls the product AVTR v2 exporters, normalizes ZIP metadata so an
unchanged approved avatar produces byte-identical archives, validates both
profiles, and writes the exact shared catalog contract. It never uploads.
"""
from __future__ import annotations

import argparse
import hashlib
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
) -> None:
    catalog_parts = urlparse(catalog_url).path.strip("/").split("/")
    release_parts = urlparse(release_url).path.strip("/").split("/")
    thumbnail_parts = urlparse(thumbnail_url).path.strip("/").split("/")
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


def _validate_ios_archive(path: Path) -> dict:
    if path.stat().st_size > avtr.MAX_IOS_ARCHIVE_BYTES:
        raise StoreBuildError("iPhone archive exceeds the AVTR v2 limit")
    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        expected = {avtr.MANIFEST} | {
            f"assets/{name}" for name in avtr.IOS_ROLE_FILENAMES.values()
        }
        if len(names) != 19 or len(names) != len(set(names)) or set(names) != expected:
            raise StoreBuildError("iPhone archive file contract is invalid")
        if any(not avtr._regular_zip_entry(info) for info in infos):
            raise StoreBuildError("iPhone archive contains a non-regular entry")
        manifest = json.loads(archive.read(avtr.MANIFEST))
        if set(manifest) != {
            "format", "version", "variant", "id", "displayName", "rig", "assets"
        } or manifest.get("format") != avtr.FORMAT \
                or manifest.get("version") != avtr.VERSION \
                or manifest.get("variant") != avtr.IOS_VARIANT:
            raise StoreBuildError("iPhone manifest contract is invalid")
        if set(manifest.get("assets", {})) != set(avtr.IOS_ROLE_FILENAMES):
            raise StoreBuildError("iPhone asset ledger is invalid")
        for role, row in manifest["assets"].items():
            payload = archive.read(row["path"])
            if len(payload) != row["byteCount"] \
                    or hashlib.sha256(payload).hexdigest() != row["sha256"]:
                raise StoreBuildError(f"iPhone asset integrity failed: {role}")
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
    if not isinstance(entries, list) or len(entries) != 1:
        raise StoreBuildError("release bundle must contain exactly one entry")
    entry = entries[0]
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
    if not isinstance(variants, dict) or set(variants) != {
        avtr.IOS_VARIANT, avtr.MAC_VARIANT
    }:
        raise StoreBuildError("catalog variants are invalid")
    for profile in (avtr.IOS_VARIANT, avtr.MAC_VARIANT):
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
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise StoreBuildError("invalid avatar version")
    catalog_url = _strict_https(catalog_url, "raw.githubusercontent.com")
    release_url = _strict_https(release_url, "github.com")
    thumbnail_url = _strict_https(thumbnail_url, "raw.githubusercontent.com")
    ios_filename, mac_filename, thumbnail_filename = artifact_filenames(identifier)
    _validate_repository_urls(
        catalog_url=catalog_url,
        release_url=release_url,
        thumbnail_url=thumbnail_url,
        thumbnail_filename=thumbnail_filename,
    )

    _validate_ready_source(source, identifier, display_name)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".openclam-store-", dir=output.parent))
    try:
        releases = stage / "release-assets"
        catalog_root = stage / "catalog" / "v1"
        releases.mkdir(parents=True)
        catalog_root.mkdir(parents=True)
        ios_path = releases / ios_filename
        mac_path = releases / mac_filename
        thumbnail_path = catalog_root / thumbnail_filename

        ios_manifest = avtr.export_ios_light(
            identifier, display_name, source, source / "runtime", ios_path
        )
        mac_manifest = avtr.export_macos_full(identifier, source, mac_path)
        normalize_archive(ios_path, zipfile.ZIP_DEFLATED)
        normalize_archive(mac_path, zipfile.ZIP_STORED)
        _validate_ios_archive(ios_path)
        _validate_mac_archive(mac_path, mac_manifest["capabilities"])

        shutil.copyfile(source / "keyframe.png", thumbnail_path)
        os.chmod(thumbnail_path, 0o600)
        with Image.open(thumbnail_path) as image:
            image.verify()
        with Image.open(thumbnail_path) as image:
            if image.format != "PNG":
                raise StoreBuildError("store thumbnail must be PNG")
            width, height = image.size

        ios_record = artifact_record(ios_path)
        mac_record = artifact_record(mac_path)
        thumbnail_record = artifact_record(thumbnail_path)
        catalog = {
            "schemaVersion": 1,
            "entries": [{
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
                "variants": {
                    avtr.IOS_VARIANT: {
                        "url": f"{release_url}/{ios_filename}",
                        "sha256": ios_record["sha256"],
                        "bytes": ios_record["bytes"],
                        "format": avtr.FORMAT,
                        "profile": avtr.IOS_VARIANT,
                    },
                    avtr.MAC_VARIANT: {
                        "url": f"{release_url}/{mac_filename}",
                        "sha256": mac_record["sha256"],
                        "bytes": mac_record["bytes"],
                        "format": avtr.FORMAT,
                        "profile": avtr.MAC_VARIANT,
                    },
                },
            }],
        }
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
        for artifact in (ios_path, mac_path, thumbnail_path, catalog_path):
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
    )
    print(json.dumps({
        "catalogURL": result["catalogURL"],
        "output": result["output"],
        "entry": result["catalog"]["entries"][0],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
