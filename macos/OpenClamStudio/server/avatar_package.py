"""OpenClam AVTR export and import.

The two profiles deliberately do not synchronize devices:

* ``macos-full`` is a hash-ledgered authoring project for OpenClam Studio.
* ``ios-light`` is either the fixed 19-file v2 runtime package, or v3 with
  one to three optional, transparent runtime motion clips.

Neither profile carries application settings, histories, credentials, or keys.
"""
from __future__ import annotations

import hashlib
import io
import json
import math
import mimetypes
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unicodedata
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Mapping

from PIL import Image


FORMAT = "openclam-avatar"
VERSION = 2
IOS_MOTION_VERSION = 3
IOS_EXPRESSION_VERSION = 4
MAC_VARIANT = "macos-full"
IOS_VARIANT = "ios-light"
MANIFEST = "manifest.json"
AUTHORING_PREFIX = "authoring/"

MAX_MANIFEST_BYTES = 128 * 1024
MAX_MAC_ARCHIVE_BYTES = 4 * 1024 * 1024 * 1024
MAX_MAC_EXPANDED_BYTES = 8 * 1024 * 1024 * 1024
MAX_MAC_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_MAC_ENTRIES = 40_000
MAX_MAC_PATH_BYTES = 1_024

MAX_IOS_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_IOS_EXPANDED_BYTES = 96 * 1024 * 1024
MAX_IOS_LEGACY_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_IOS_LEGACY_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_IOS_ASSET_BYTES = 16 * 1024 * 1024
MAX_IOS_MOTION_BYTES = 16 * 1024 * 1024
MAX_IOS_DIMENSION = 8_192
MAX_IOS_TEXTURE_DIMENSION = 8_192
MAX_IOS_PIXELS = 16 * 1024 * 1024
MAX_IOS_TOTAL_PIXELS = 48 * 1024 * 1024
MAX_IOS_MOTION_DIMENSION = 4_096
MIN_IOS_MOTION_DURATION_MS = 250
MAX_IOS_MOTION_DURATION_MS = 12_000
MAX_IOS_MOTION_DURATION_DRIFT_MS = 50

ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
MAC_PATH_PATTERN = re.compile(r"^authoring/[A-Za-z0-9][A-Za-z0-9._/-]*$")
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
MEDIA_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*$")

IOS_LEGACY_VISEMES = ("sil", "FF", "TH", "nn", "RR", "aa", "E", "ih", "ou")
IOS_VISEMES = (
    "sil", "PP", "FF", "TH", "DD", "kk", "CH", "SS", "nn", "RR",
    "aa", "E", "ih", "oh", "ou",
)
IOS_BROW_OFFSETS = (-5.0, -3.5, -2.0, -1.0, 0.0, 0.75, 1.5,
                    2.5, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0)
IOS_BROW_SQUEEZE_OFFSETS = (-3.0, 0.0, 4.0)
IOS_SMILE_STRENGTHS = (0.0, 0.18, 0.34, 0.68, 1.0)
IOS_EMOTION_MOUTH_STRENGTHS = (0.0, 0.34, 0.68, 1.0)
IOS_CHEEK_OFFSETS = (0.0, 0.8, 1.6, 2.45, 3.3)
IOS_UNDER_EYE_OFFSETS = (0.0, 0.5, 1.0, 1.6, 2.3)
IOS_LEGACY_ROLE_FILENAMES = {
    "thumbnail": "thumbnail.jpg",
    "body": "body.png",
    "head-mask": "head-mask.png",
    "eye-left": "eye-left.png",
    "eye-right": "eye-right.png",
    "brow-left": "brow-left.png",
    "brow-right": "brow-right.png",
    "gaze-left-atlas": "gaze-left-atlas.png",
    "gaze-right-atlas": "gaze-right-atlas.png",
    **{f"viseme-{name}": f"viseme-{name}.jpg" for name in IOS_LEGACY_VISEMES},
}
IOS_EXPRESSION_ROLE_FILENAMES = {
    "smile-atlas": "smile-atlas.png",
    "emotion-mouth-atlas": "emotion-mouth-atlas.png",
    "forehead-left": "forehead-left.png",
    "forehead-right": "forehead-right.png",
    "cheek-left": "cheek-left.png",
    "cheek-right": "cheek-right.png",
    "under-eye-left": "under-eye-left.png",
    "under-eye-right": "under-eye-right.png",
}
# Public compatibility alias used by the v2 contract tests and downstream
# tools that still describe the fixed 19-file package.
IOS_ROLE_FILENAMES = IOS_LEGACY_ROLE_FILENAMES
IOS_MOTION_FILENAMES = {
    "walk": ("walk", "motion-walk.mov"),
    "edgeIdle": ("idle", "motion-edge-idle.mov"),
    "moves": ("move", "motion-moves.mov"),
}

_PRUNED_TOP_LEVEL = {
    "runtime", "diag", "cache", "caches", ".cache", "logs", "history",
    "histories", "conversations", "threads", "messages", "credentials",
    "secrets", "keychain", "vault", ".wardrobe.json",
}
_PRUNED_SEGMENTS = {
    "__pycache__", ".ds_store", "node_modules", ".git", ".svn",
}
_PRUNED_SUFFIXES = (
    ".log", ".pyc", ".pyo", ".tmp", ".partial", ".previous",
    ".activate-backup",
)
_SENSITIVE_TEXT_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"\bsk-[A-Za-z0-9_-]{24,}\b"),
    re.compile(rb"\bxai-[A-Za-z0-9_-]{24,}\b"),
    re.compile(rb"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(rb"\b(?:api[_-]?key|access[_-]?token|bearer)\s*[:=]\s*[\"']?[^\s\"']{20,}", re.I),
)


class AvatarPackageError(ValueError):
    """A safe, user-displayable AVTR validation failure."""


def _safe_identifier(value: object) -> str:
    identifier = str(value or "")
    if not ID_PATTERN.fullmatch(identifier):
        raise AvatarPackageError("invalid avatar identifier")
    return identifier


def _safe_display_name(value: object) -> str:
    name = str(value or "")
    if name != name.strip() or not name or len(name) > 64 \
            or any(unicodedata.category(character) == "Cc" for character in name):
        raise AvatarPackageError("invalid avatar display name")
    return name


def _safe_zip_path(value: str, prefix: str | None = None) -> bool:
    if not value or value != unicodedata.normalize("NFC", value) \
            or value.startswith("/") or "\\" in value or ":" in value \
            or len(value.encode("utf-8")) > MAX_MAC_PATH_BYTES:
        return False
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return prefix is None or value.startswith(prefix)


def _regular_zip_entry(info: zipfile.ZipInfo) -> bool:
    if info.is_dir():
        return False
    mode = (info.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    return kind in (0, stat.S_IFREG)


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def _zip_entry(path: str, compression: int) -> zipfile.ZipInfo:
    """Create a reproducible, regular-file ZIP entry without host metadata."""
    info = zipfile.ZipInfo(path, date_time=_ZIP_TIMESTAMP)
    info.compress_type = compression
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    return info


def _write_zip_bytes(
    archive: zipfile.ZipFile, path: str, content: bytes, compression: int
) -> None:
    archive.writestr(_zip_entry(path, compression), content)


def _write_zip_file(
    archive: zipfile.ZipFile, source: Path, path: str, compression: int
) -> None:
    info = _zip_entry(path, compression)
    info.file_size = source.stat().st_size
    with source.open("rb") as input_file, archive.open(info, "w") as output_file:
        shutil.copyfileobj(input_file, output_file, length=1024 * 1024)


def _media_type(path: str) -> str:
    extension = PurePosixPath(path).suffix.lower()
    explicit = {
        ".json": "application/json",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webm": "video/webm",
        ".mov": "video/quicktime",
        ".mp4": "video/mp4",
        ".wav": "audio/wav",
    }
    guessed = explicit.get(extension) or mimetypes.guess_type(path)[0]
    value = guessed or "application/octet-stream"
    return value if MEDIA_PATTERN.fullmatch(value) else "application/octet-stream"


def _pruned(relative: Path) -> bool:
    lowered = [part.lower() for part in relative.parts]
    if not lowered:
        return True
    if lowered[0] in _PRUNED_TOP_LEVEL:
        return True
    return any(
        part in _PRUNED_SEGMENTS
        or part.startswith(".runtime-")
        or part.startswith(".motion-")
        or part.startswith(".body-")
        or part.startswith(".import-")
        or part.startswith(".delete-")
        or part.endswith(_PRUNED_SUFFIXES)
        for part in lowered
    )


def _reject_embedded_secret(path: Path) -> None:
    if path.stat().st_size > 1024 * 1024:
        return
    if path.suffix.lower() not in {".json", ".txt", ".md", ".yaml", ".yml", ".toml", ".ini"}:
        return
    content = path.read_bytes()
    if any(pattern.search(content) for pattern in _SENSITIVE_TEXT_PATTERNS):
        raise AvatarPackageError(f"authoring file may contain a credential: {path.name}")


def _authoring_files(root: Path) -> list[tuple[Path, str]]:
    root = root.resolve(strict=True)
    values: list[tuple[Path, str]] = []
    for base, folders, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        relative_base = base_path.relative_to(root)
        folders[:] = sorted(
            name for name in folders
            if not _pruned(relative_base / name)
            and not (base_path / name).is_symlink()
        )
        for filename in sorted(files):
            source = base_path / filename
            relative = source.relative_to(root)
            if _pruned(relative):
                continue
            details = source.lstat()
            if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
                raise AvatarPackageError(f"unsafe authoring file: {relative.as_posix()}")
            archive_path = AUTHORING_PREFIX + relative.as_posix()
            if not _safe_zip_path(archive_path, AUTHORING_PREFIX) \
                    or not MAC_PATH_PATTERN.fullmatch(archive_path):
                raise AvatarPackageError(f"unsafe authoring path: {relative.as_posix()}")
            if details.st_size < 1 or details.st_size > MAX_MAC_FILE_BYTES:
                raise AvatarPackageError(f"invalid authoring file size: {relative.as_posix()}")
            _reject_embedded_secret(source)
            values.append((source, archive_path))
    if not values or len(values) > MAX_MAC_ENTRIES:
        raise AvatarPackageError("invalid number of authoring files")
    if AUTHORING_PREFIX + "manifest.json" not in {path for _, path in values}:
        raise AvatarPackageError("avatar authoring manifest is missing")
    return values


def _read_json_file(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        raise AvatarPackageError(f"invalid JSON: {path.name}") from error
    if not isinstance(value, dict):
        raise AvatarPackageError(f"invalid JSON object: {path.name}")
    return value


def _capabilities(root: Path) -> dict[str, bool]:
    motion_path = root / "motion" / "motion.json"
    motion = _read_json_file(motion_path) if motion_path.is_file() else {}
    return {
        "head": (root / "keyframe.png").is_file()
        and (root / "visemes").is_dir(),
        "fullBody": (root / "body" / "body.json").is_file()
        and (root / "body" / "body.png").is_file()
        and (root / "body" / "head-mask.png").is_file(),
        "walk": bool(motion.get("walk")),
        "edgeIdle": bool(motion.get("idle")),
        "moves": bool(motion.get("move")),
    }


def export_macos_full(
    identifier: str,
    directory: str | os.PathLike,
    destination: str | os.PathLike,
) -> dict:
    """Export a complete, editable Mac avatar project."""
    identifier = _safe_identifier(identifier)
    root = Path(directory).resolve(strict=True)
    source_manifest = _read_json_file(root / "manifest.json")
    display_name = _safe_display_name(source_manifest.get("name") or identifier)
    status = str(source_manifest.get("status") or "draft")
    if status not in {"draft", "building", "ready", "failed"}:
        status = "draft"

    files = _authoring_files(root)
    total = sum(source.stat().st_size for source, _ in files)
    if total > MAX_MAC_EXPANDED_BYTES:
        raise AvatarPackageError("avatar authoring project is too large")
    ledger = [
        {
            "path": archive_path,
            "sha256": _sha256_path(source),
            "byteCount": source.stat().st_size,
            "mediaType": _media_type(archive_path),
        }
        for source, archive_path in files
    ]
    manifest = {
        "format": FORMAT,
        "version": VERSION,
        "variant": MAC_VARIANT,
        "id": identifier,
        "displayName": display_name,
        "status": status,
        "capabilities": _capabilities(root),
        "files": ledger,
    }
    manifest_bytes = json.dumps(
        manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise AvatarPackageError("avatar manifest is too large")

    destination_path = Path(destination)
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".openclam-avtr-", suffix=".tmp", dir=destination_path.parent
    )
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_STORED) as archive:
            _write_zip_bytes(archive, MANIFEST, manifest_bytes, zipfile.ZIP_STORED)
            for source, archive_path in files:
                _write_zip_file(
                    archive, source, archive_path, zipfile.ZIP_STORED
                )
        if os.path.getsize(temporary) > MAX_MAC_ARCHIVE_BYTES:
            raise AvatarPackageError("avatar archive is too large")
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination_path)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)
    return manifest


def _strict_mac_manifest(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != {
        "format", "version", "variant", "id", "displayName", "status",
        "capabilities", "files",
    }:
        raise AvatarPackageError("invalid Mac avatar manifest")
    if value.get("format") != FORMAT or value.get("version") != VERSION \
            or value.get("variant") != MAC_VARIANT:
        raise AvatarPackageError("this is not a Mac-full OpenClam avatar")
    _safe_identifier(value.get("id"))
    _safe_display_name(value.get("displayName"))
    if value.get("status") not in {"draft", "building", "ready", "failed"}:
        raise AvatarPackageError("invalid avatar status")
    capabilities = value.get("capabilities")
    expected_capabilities = {"head", "fullBody", "walk", "edgeIdle", "moves"}
    if not isinstance(capabilities, dict) or set(capabilities) != expected_capabilities \
            or not all(isinstance(capabilities[key], bool) for key in expected_capabilities):
        raise AvatarPackageError("invalid avatar capabilities")
    rows = value.get("files")
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_MAC_ENTRIES:
        raise AvatarPackageError("invalid avatar file ledger")
    seen: set[str] = set()
    total = 0
    for row in rows:
        if not isinstance(row, dict) or set(row) != {
            "path", "sha256", "byteCount", "mediaType"
        }:
            raise AvatarPackageError("invalid avatar file ledger")
        path = row.get("path")
        byte_count = row.get("byteCount")
        if not isinstance(path, str) or not _safe_zip_path(path, AUTHORING_PREFIX) \
                or not MAC_PATH_PATTERN.fullmatch(path) or path in seen:
            raise AvatarPackageError("invalid or duplicate authoring path")
        seen.add(path)
        if not isinstance(row.get("sha256"), str) \
                or not HASH_PATTERN.fullmatch(row["sha256"]):
            raise AvatarPackageError("invalid authoring hash")
        if not isinstance(byte_count, int) or not 1 <= byte_count <= MAX_MAC_FILE_BYTES:
            raise AvatarPackageError("invalid authoring file size")
        if not isinstance(row.get("mediaType"), str) \
                or not MEDIA_PATTERN.fullmatch(row["mediaType"]) \
                or row["mediaType"] != _media_type(path):
            raise AvatarPackageError("invalid authoring media type")
        total += byte_count
        if total > MAX_MAC_EXPANDED_BYTES:
            raise AvatarPackageError("avatar contents are too large")
    if AUTHORING_PREFIX + "manifest.json" not in seen:
        raise AvatarPackageError("avatar authoring manifest is missing")
    return value


def import_macos_full(
    archive_path: str | os.PathLike,
    avatars_root: str | os.PathLike,
    on_progress: Callable[[int, int], None] | None = None,
) -> dict:
    """Validate and atomically install a complete Mac authoring project."""
    source_path = Path(archive_path)
    if not source_path.is_file() or source_path.is_symlink() \
            or source_path.stat().st_size > MAX_MAC_ARCHIVE_BYTES:
        raise AvatarPackageError("invalid or oversized avatar archive")
    with zipfile.ZipFile(source_path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)) or MANIFEST not in names:
            raise AvatarPackageError("duplicate or missing avatar manifest")
        manifest_entry = entries[names.index(MANIFEST)]
        if not _regular_zip_entry(manifest_entry) \
                or not 1 <= manifest_entry.file_size <= MAX_MANIFEST_BYTES:
            raise AvatarPackageError("invalid avatar manifest")
        try:
            manifest = _strict_mac_manifest(json.loads(archive.read(MANIFEST)))
        except AvatarPackageError:
            raise
        except Exception as error:
            raise AvatarPackageError("invalid avatar manifest") from error
        expected = {row["path"]: row for row in manifest["files"]}
        payload_entries = [entry for entry in entries if entry.filename != MANIFEST]
        if set(entry.filename for entry in payload_entries) != set(expected):
            raise AvatarPackageError("avatar ledger does not match archive contents")
        expanded = 0
        for entry in payload_entries:
            if not _regular_zip_entry(entry) or not _safe_zip_path(
                entry.filename, AUTHORING_PREFIX
            ) or entry.file_size != expected[entry.filename]["byteCount"]:
                raise AvatarPackageError("unsafe or altered avatar entry")
            expanded += entry.file_size
            if expanded > MAX_MAC_EXPANDED_BYTES:
                raise AvatarPackageError("avatar contents are too large")

        avatars = Path(avatars_root)
        avatars.mkdir(parents=True, exist_ok=True, mode=0o700)
        base = manifest["id"]
        identifier = base
        suffix = 2
        while (avatars / identifier).exists():
            tail = f"-{suffix}"
            identifier = base[: 64 - len(tail)] + tail
            suffix += 1
        stage = avatars / f".import-{uuid.uuid4().hex}"
        stage.mkdir(mode=0o700)
        written = 0
        try:
            for entry in payload_entries:
                relative = PurePosixPath(entry.filename).relative_to("authoring")
                destination = stage.joinpath(*relative.parts)
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                digest = hashlib.sha256()
                actual = 0
                with archive.open(entry) as feed, destination.open("xb") as output:
                    while True:
                        chunk = feed.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                        digest.update(chunk)
                        actual += len(chunk)
                os.chmod(destination, 0o600)
                row = expected[entry.filename]
                if actual != row["byteCount"] or digest.hexdigest() != row["sha256"]:
                    raise AvatarPackageError("avatar integrity check failed")
                written += actual
                if on_progress:
                    on_progress(written, expanded)
            source_manifest_path = stage / "manifest.json"
            source_manifest = _read_json_file(source_manifest_path)
            source_manifest["slug"] = identifier
            source_manifest_path.write_text(
                json.dumps(source_manifest, ensure_ascii=False, indent=1),
                encoding="utf-8",
            )
            if _capabilities(stage) != manifest["capabilities"]:
                raise AvatarPackageError("avatar capability ledger does not match files")
            destination = avatars / identifier
            os.replace(stage, destination)
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise
    return {
        "slug": identifier,
        "name": manifest["displayName"],
        "status": manifest["status"],
        "variant": MAC_VARIANT,
        "capabilities": manifest["capabilities"],
    }


def _runtime_asset(runtime_root: Path, declared: object) -> Path:
    if not isinstance(declared, str) or not declared.startswith("assets/"):
        raise AvatarPackageError("runtime asset path is invalid")
    relative = declared[len("assets/"):]
    if not _safe_zip_path(relative) or "/" in relative:
        raise AvatarPackageError("runtime asset path is invalid")
    path = runtime_root / relative
    if not path.is_file() or path.is_symlink():
        raise AvatarPackageError("runtime asset is missing")
    return path


def _box(value: object) -> dict:
    if not isinstance(value, list) or len(value) != 4:
        raise AvatarPackageError("runtime sprite box is invalid")
    x, y, width, height = value
    if not all(isinstance(item, (int, float)) and item == item for item in value) \
            or not 0 <= x <= 1024 or not 0 <= y <= 1024 \
            or not 1 <= width <= 1024 or not 1 <= height <= 1024 \
            or x + width > 1024 or y + height > 1024:
        raise AvatarPackageError("runtime sprite box is invalid")
    return {"x": x, "y": y, "width": int(width), "height": int(height)}


def _sprite(meta: object, columns: int, rows: int, storage: str) -> dict:
    if not isinstance(meta, dict):
        raise AvatarPackageError("runtime sprite is invalid")
    return {
        "box": _box(meta.get("box")),
        "columns": columns,
        "rows": rows,
        "storage": storage,
    }


def _image_details(path: Path) -> tuple[int, int, str]:
    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            width, height = image.size
            image_format = image.format
    except Exception as error:
        raise AvatarPackageError(f"avatar image is invalid: {path.name}") from error
    if not 1 <= width <= MAX_IOS_DIMENSION or not 1 <= height <= MAX_IOS_DIMENSION \
            or width * height > MAX_IOS_PIXELS:
        raise AvatarPackageError(f"avatar image is too large: {path.name}")
    media_type = {"PNG": "image/png", "JPEG": "image/jpeg"}.get(image_format)
    if not media_type:
        raise AvatarPackageError(f"avatar image type is unsupported: {path.name}")
    return width, height, media_type


def _copy_gaze_atlas(source: Path, destination: Path, box: Mapping[str, object]) -> None:
    _copy_vertical_strip_as_grid(source, destination, box, columns=25, rows=11)


def _copy_vertical_strip_as_grid(
    source: Path,
    destination: Path,
    box: Mapping[str, object],
    *,
    columns: int,
    rows: int,
) -> None:
    """Repack a logical row-major strip into a device-safe 2D texture."""
    frame_width = int(box["width"])
    frame_height = int(box["height"])
    atlas_width = frame_width * columns
    atlas_height = frame_height * rows
    if atlas_width > MAX_IOS_TEXTURE_DIMENSION \
            or atlas_height > MAX_IOS_TEXTURE_DIMENSION \
            or atlas_width * atlas_height > MAX_IOS_PIXELS:
        raise AvatarPackageError("iPhone atlas exceeds the device texture limit")
    with Image.open(source) as strip:
        strip.load()
        if strip.size != (frame_width, frame_height * columns * rows):
            raise AvatarPackageError("runtime sprite strip dimensions are invalid")
        atlas = Image.new("RGBA", (atlas_width, atlas_height))
        for row in range(rows):
            for column in range(columns):
                index = row * columns + column
                frame = strip.crop((
                    0, index * frame_height, frame_width, (index + 1) * frame_height
                ))
                atlas.paste(frame, (column * frame_width, row * frame_height))
        atlas.save(destination, format="PNG", optimize=True)


def _copy_clean_image(
    source: Path, destination: Path, *, jpeg_quality: int | None = None
) -> None:
    """Re-encode a runtime image without EXIF, comments, profiles, or paths."""
    try:
        with Image.open(source) as image:
            image.load()
            if jpeg_quality is None:
                clean = image.convert("RGBA")
                clean.info.clear()
                clean.save(
                    destination, format="PNG", optimize=True, compress_level=9
                )
            else:
                clean = image.convert("RGB")
                clean.info.clear()
                clean.save(
                    destination,
                    format="JPEG",
                    quality=jpeg_quality,
                    subsampling=0,
                    optimize=False,
                    progressive=False,
                )
    except AvatarPackageError:
        raise
    except Exception as error:
        raise AvatarPackageError(f"avatar image is invalid: {source.name}") from error


def _asset_record(path: Path, archive_path: str) -> dict:
    size = path.stat().st_size
    if not 1 <= size <= MAX_IOS_ASSET_BYTES:
        raise AvatarPackageError(f"iPhone avatar asset is too large: {path.name}")
    width, height, media_type = _image_details(path)
    return {
        "path": archive_path,
        "sha256": _sha256_path(path),
        "byteCount": size,
        "mediaType": media_type,
        "width": width,
        "height": height,
    }


def _expression_geometry(runtime_manifest: Mapping[str, object]) -> dict | None:
    """Return the complete v22 expression contract, or ``None`` for legacy rigs.

    Partial expression banks are never labelled as full-expression packages.
    This makes v4 a positive capability statement while preserving export of
    old v2/v3 avatars until their source project is rebuilt on the Mac.
    """
    if int(runtime_manifest.get("v") or 0) < 22:
        return None
    smile = runtime_manifest.get("smile")
    emotion = runtime_manifest.get("emotion_mouth")
    forehead = runtime_manifest.get("forehead")
    cheek = runtime_manifest.get("cheek")
    under_eye = runtime_manifest.get("eyebag")
    brow = runtime_manifest.get("brow")
    values = (smile, emotion, forehead, cheek, under_eye, brow)
    if not all(isinstance(value, dict) for value in values):
        raise AvatarPackageError(
            "rebuild the avatar face to publish the complete iPhone expression rig"
        )
    if list(smile.get("visemes") or []) != list(IOS_VISEMES) \
            or list(emotion.get("visemes") or []) != list(IOS_VISEMES) \
            or list(emotion.get("emotions") or []) != ["sorrow", "horror", "anger"]:
        raise AvatarPackageError("runtime expression visemes do not match iPhone v4")
    state_banks = (
        (smile.get("states"), IOS_SMILE_STRENGTHS),
        (emotion.get("states"), IOS_EMOTION_MOUTH_STRENGTHS),
        (forehead.get("dys"), IOS_BROW_OFFSETS),
        (forehead.get("sqs"), IOS_BROW_SQUEEZE_OFFSETS),
        (brow.get("dys"), IOS_BROW_OFFSETS),
        (brow.get("sqs"), IOS_BROW_SQUEEZE_OFFSETS),
        (cheek.get("ups"), IOS_CHEEK_OFFSETS),
        (under_eye.get("ups"), IOS_UNDER_EYE_OFFSETS),
    )
    if any(
        not isinstance(values, list)
        or len(values) != len(expected)
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in values
        )
        or tuple(float(value) for value in values) != expected
        for values, expected in state_banks
    ):
        raise AvatarPackageError("runtime expression state banks are incomplete")

    profile = runtime_manifest.get("rig_profile")
    if profile is None:
        profile = {}
    if not isinstance(profile, dict):
        raise AvatarPackageError("runtime expression calibration is invalid")

    def calibrated_gain(
        key: str,
        fallback: float,
        reference: float,
        ceiling: float,
    ) -> float:
        value = profile.get(key, fallback)
        if isinstance(value, bool) or not isinstance(value, (int, float)) \
                or not math.isfinite(float(value)) \
                or not 0 <= float(value) <= 150:
            raise AvatarPackageError("runtime expression calibration is invalid")
        return round(min(ceiling, math.sqrt(float(value) / reference)), 6)

    return {
        "smile": _sprite(
            smile, len(smile["states"]), len(IOS_VISEMES), "gridAtlas"
        ),
        "emotionMouth": _sprite(
            emotion,
            len(emotion["states"]),
            len(IOS_VISEMES) * len(emotion["emotions"]),
            "gridAtlas",
        ),
        "leftForehead": _sprite(forehead.get("l"), 14, 3, "verticalStrip"),
        "rightForehead": _sprite(forehead.get("r"), 14, 3, "verticalStrip"),
        "leftCheek": _sprite(
            cheek.get("l"), 1, len(cheek["ups"]), "verticalStrip"
        ),
        "rightCheek": _sprite(
            cheek.get("r"), 1, len(cheek["ups"]), "verticalStrip"
        ),
        "leftUnderEye": _sprite(
            under_eye.get("l"), 1, len(under_eye["ups"]), "verticalStrip"
        ),
        "rightUnderEye": _sprite(
            under_eye.get("r"), 1, len(under_eye["ups"]), "verticalStrip"
        ),
        "browOffsets": list(brow.get("dys") or []),
        "browSqueezeOffsets": list(brow.get("sqs") or []),
        "smileStrengths": list(smile["states"]),
        "smileVisemes": list(smile["visemes"]),
        "emotionMouthStrengths": list(emotion["states"]),
        "emotionMouthEmotions": list(emotion["emotions"]),
        "emotionMouthVisemes": list(emotion["visemes"]),
        "cheekOffsets": list(cheek["ups"]),
        "underEyeOffsets": list(under_eye["ups"]),
        "browGain": calibrated_gain("brows", 10, 10, 1.35),
        "foreheadGain": calibrated_gain("forehead", 100, 100, 1.2),
        "underEyeGain": calibrated_gain("eyebags", 35, 35, 1.35),
    }


def _validate_ios_rig_assets(
    rig: Mapping[str, object],
    assets: Mapping[str, dict],
    *,
    visemes: Iterable[str] = IOS_LEGACY_VISEMES,
    expression: Mapping[str, object] | None = None,
) -> None:
    """Cross-check renderer geometry against the staged, metadata-free pixels."""
    decoded_pixels = sum(
        int(asset["width"]) * int(asset["height"])
        for asset in assets.values()
    )
    if decoded_pixels > MAX_IOS_TOTAL_PIXELS:
        raise AvatarPackageError("iPhone avatar decoded images are too large")
    if any(
        int(asset["width"]) > MAX_IOS_TEXTURE_DIMENSION
        or int(asset["height"]) > MAX_IOS_TEXTURE_DIMENSION
        for asset in assets.values()
    ):
        raise AvatarPackageError("iPhone avatar exceeds the device texture limit")
    body_size = rig["bodySize"]
    body_width = body_size["width"]
    body_height = body_size["height"]
    if not 64 <= body_width <= MAX_IOS_MOTION_DIMENSION \
            or not 64 <= body_height <= MAX_IOS_MOTION_DIMENSION \
            or body_width * body_height > MAX_IOS_PIXELS:
        raise AvatarPackageError("iPhone body dimensions are invalid")
    body_asset = assets["body"]
    if (body_asset["width"], body_asset["height"]) != (body_width, body_height):
        raise AvatarPackageError("iPhone body dimensions do not match its runtime rig")

    face = rig["faceBoundsInBody"]
    if not all(math.isfinite(float(face[key])) for key in ("x", "y", "width", "height")) \
            or face["x"] < 0 or face["y"] < 0 \
            or face["width"] < 1 or face["height"] < 1 \
            or face["x"] + face["width"] > body_width \
            or face["y"] + face["height"] > body_height:
        raise AvatarPackageError("iPhone face bounds do not fit the body")

    transform = rig["faceTransform"]
    a = float(transform["a"])
    b = float(transform["b"])
    c = float(transform["c"])
    d = float(transform["d"])
    tx = float(transform["tx"])
    ty = float(transform["ty"])
    scale_x = math.hypot(a, b)
    scale_y = math.hypot(c, d)
    maximum_scale = max(scale_x, scale_y)
    dot_product = a * c + b * d
    determinant = a * d - b * c
    if not all(math.isfinite(value) and abs(value) <= 8192 for value in (
            a, b, c, d, tx, ty)) \
            or not 0.01 <= scale_x <= 2 \
            or not 0.01 <= scale_y <= 2 \
            or abs(scale_x - scale_y) > maximum_scale * 0.05 \
            or abs(dot_product) > scale_x * scale_y * 0.05 \
            or determinant <= 0:
        raise AvatarPackageError(
            "iPhone face transform does not match iOS renderer limits"
        )

    def transformed(x: float, y: float) -> tuple[float, float]:
        return (a * x + c * y + tx, b * x + d * y + ty)

    face_center = transformed(512, 512)
    if not all(math.isfinite(value) for value in face_center) \
            or not 0 <= face_center[0] < body_width \
            or not 0 <= face_center[1] < body_height:
        raise AvatarPackageError(
            "iPhone face transform places the face outside the body"
        )

    left_gaze_box = rig["leftGaze"]["box"]
    right_gaze_box = rig["rightGaze"]["box"]
    eye_source_x = (
        left_gaze_box["x"] + left_gaze_box["width"] / 2
        + right_gaze_box["x"] + right_gaze_box["width"] / 2
    ) / 2
    eye_source_y = (
        left_gaze_box["y"] + left_gaze_box["height"] / 2
        + right_gaze_box["y"] + right_gaze_box["height"] / 2
    ) / 2
    eye_anchor = transformed(eye_source_x, eye_source_y)
    if not all(math.isfinite(value) for value in eye_anchor) \
            or not face["x"] - 2 <= eye_anchor[0] < face["x"] + face["width"] + 2 \
            or not face["y"] - 2 <= eye_anchor[1] < face["y"] + face["height"] + 2:
        raise AvatarPackageError(
            "iPhone face transform places the eye anchor outside the face bounds"
        )

    face_size = (assets["head-mask"]["width"], assets["head-mask"]["height"])
    if any(
        (assets[f"viseme-{viseme}"]["width"], assets[f"viseme-{viseme}"]["height"])
        != face_size
        for viseme in visemes
    ):
        raise AvatarPackageError("iPhone face images have inconsistent dimensions")

    expected_sprites = {
        "eye-left": (rig["leftEye"], 1, 8),
        "eye-right": (rig["rightEye"], 1, 8),
        "brow-left": (rig["leftBrow"], 1, 14 * 3),
        "brow-right": (rig["rightBrow"], 1, 14 * 3),
        "gaze-left-atlas": (rig["leftGaze"], 25, 11),
        "gaze-right-atlas": (rig["rightGaze"], 25, 11),
    }
    for role, (sprite, width_factor, height_factor) in expected_sprites.items():
        box = sprite["box"]
        expected = (box["width"] * width_factor, box["height"] * height_factor)
        actual = (assets[role]["width"], assets[role]["height"])
        if actual != expected:
            raise AvatarPackageError(f"iPhone {role} dimensions do not match its runtime rig")

    if expression is None:
        return
    expression_sprites = {
        "smile-atlas": expression["smile"],
        "emotion-mouth-atlas": expression["emotionMouth"],
        "forehead-left": expression["leftForehead"],
        "forehead-right": expression["rightForehead"],
        "cheek-left": expression["leftCheek"],
        "cheek-right": expression["rightCheek"],
        "under-eye-left": expression["leftUnderEye"],
        "under-eye-right": expression["rightUnderEye"],
    }
    for role, sprite in expression_sprites.items():
        box = sprite["box"]
        expected_storage = (
            "gridAtlas"
            if role in {"smile-atlas", "emotion-mouth-atlas"}
            else "verticalStrip"
        )
        if sprite["storage"] != expected_storage:
            raise AvatarPackageError(f"iPhone {role} storage is invalid")
        if expected_storage == "gridAtlas":
            expected = (
                box["width"] * sprite["columns"],
                box["height"] * sprite["rows"],
            )
        else:
            expected = (
                box["width"],
                box["height"] * sprite["columns"] * sprite["rows"],
            )
        actual = (assets[role]["width"], assets[role]["height"])
        if actual != expected:
            raise AvatarPackageError(f"iPhone {role} dimensions do not match its runtime rig")


def _quicktime_header(path: Path) -> bool:
    """Recognize the app's QuickTime-branded MOV before invoking a parser."""
    try:
        with path.open("rb") as handle:
            header = handle.read(64)
    except OSError:
        return False
    return len(header) >= 12 and header[4:8] == b"ftyp" and header[8:12] == b"qt  "


def _positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise AvatarPackageError(f"runtime motion {label} is invalid")
    return value


def _positive_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AvatarPackageError(f"runtime motion {label} is invalid")
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise AvatarPackageError(f"runtime motion {label} is invalid")
    return number


def _probe_hevc_alpha(path: Path) -> bool:
    """Return positive alpha evidence or fail when FFmpeg cannot inspect it.

    Apple's HEVC-alpha stores the alpha plane as a second HEVC layer. ffprobe
    correctly reports the container, codec, tracks, dimensions, and duration,
    but currently presents only the base layer's yuv420p pixel format. The
    trace_headers bitstream filter is therefore the reliable positive signal.
    The packaged runtime ships that filter and must fail closed when either
    inspection tool is absent; the runtime ledger alone is not media proof.
    """
    executable = shutil.which("ffmpeg")
    if not executable:
        raise AvatarPackageError("iPhone motion validation is unavailable")
    try:
        listing = subprocess.run(
            [executable, "-hide_banner", "-bsfs"],
            capture_output=True,
            text=True,
            timeout=10,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AvatarPackageError("iPhone motion validation is unavailable") from error
    filters = {line.strip() for line in listing.stdout.splitlines()}
    if listing.returncode or "trace_headers" not in filters:
        raise AvatarPackageError("iPhone motion alpha validation is unavailable")
    try:
        traced = subprocess.run(
            [
                executable, "-hide_banner", "-loglevel", "trace", "-i", str(path),
                "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "trace_headers",
                "-frames:v", "1", "-f", "null", "-",
            ],
            capture_output=True,
            text=True,
            timeout=20,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AvatarPackageError("iPhone motion alpha inspection failed") from error
    if traced.returncode:
        raise AvatarPackageError("iPhone motion alpha inspection failed")
    output = traced.stdout + traced.stderr
    if "Alpha Channel Information" not in output:
        return False
    has_alpha_layer = re.search(
        r"nuh_layer_id:\s*1|nuh_layer_id\s+0*1\s*=\s*1", output
    )
    alpha_enabled = re.search(r"alpha_channel_cancel_flag\s+0\s*=\s*0", output)
    return bool(has_alpha_layer and alpha_enabled)


def _probe_motion_details(path: Path) -> dict:
    """Read normalized MOV facts without returning paths or provider metadata."""
    executable = shutil.which("ffprobe")
    if not executable:
        raise AvatarPackageError("iPhone motion validation is unavailable")
    try:
        result = subprocess.run(
            [
                executable, "-v", "error",
                "-show_entries",
                "format=format_name,duration:"
                "stream=codec_type,codec_name,codec_tag_string,width,height,duration",
                "-of", "json", str(path),
            ],
            capture_output=True,
            text=True,
            timeout=20,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AvatarPackageError("iPhone motion inspection failed") from error
    if result.returncode:
        raise AvatarPackageError("iPhone motion is not a valid QuickTime movie")
    try:
        value = json.loads(result.stdout)
        streams = value["streams"]
        container = value["format"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise AvatarPackageError("iPhone motion inspection returned invalid metadata") from error
    if not isinstance(streams, list) or not isinstance(container, dict):
        raise AvatarPackageError("iPhone motion inspection returned invalid metadata")
    video = [item for item in streams if isinstance(item, dict)
             and item.get("codec_type") == "video"]
    audio = [item for item in streams if isinstance(item, dict)
             and item.get("codec_type") == "audio"]
    primary = video[0] if video else {}
    raw_duration = container.get("duration") or primary.get("duration")
    try:
        duration = float(raw_duration)
    except (TypeError, ValueError) as error:
        raise AvatarPackageError("iPhone motion duration is invalid") from error
    if not math.isfinite(duration) or duration <= 0:
        raise AvatarPackageError("iPhone motion duration is invalid")
    return {
        "streamCount": len(streams),
        "videoTracks": len(video),
        "audioTracks": len(audio),
        "formatNames": str(container.get("format_name") or "").split(","),
        "codecName": primary.get("codec_name"),
        "codecTag": primary.get("codec_tag_string"),
        "width": primary.get("width"),
        "height": primary.get("height"),
        "durationMilliseconds": int(round(duration * 1000)),
        "hasAlpha": _probe_hevc_alpha(path),
    }


def _motion_record(path: Path, archive_path: str, runtime_clip: Mapping[str, object]) -> dict:
    size = path.stat().st_size
    if not 1 <= size <= MAX_IOS_MOTION_BYTES:
        raise AvatarPackageError(f"iPhone motion is too large: {path.name}")
    if path.suffix.lower() != ".mov" or not _quicktime_header(path):
        raise AvatarPackageError("iPhone motion is not a QuickTime movie")

    trusted_width = _positive_integer(runtime_clip.get("frame_width"), "width")
    trusted_height = _positive_integer(runtime_clip.get("frame_height"), "height")
    frames = _positive_integer(runtime_clip.get("frames"), "frame count")
    fps = _positive_number(runtime_clip.get("fps"), "frame rate")
    expected_duration = int(round(frames / fps * 1000))
    if not 64 <= trusted_width <= MAX_IOS_MOTION_DIMENSION \
            or not 64 <= trusted_height <= MAX_IOS_MOTION_DIMENSION \
            or trusted_width * trusted_height > MAX_IOS_PIXELS:
        raise AvatarPackageError("iPhone motion dimensions are invalid")
    if not MIN_IOS_MOTION_DURATION_MS <= expected_duration \
            <= MAX_IOS_MOTION_DURATION_MS:
        raise AvatarPackageError("iPhone motion duration is invalid")

    inspected = _probe_motion_details(path)
    if inspected.get("streamCount") != 1 \
            or inspected.get("videoTracks") != 1 \
            or inspected.get("audioTracks") != 0:
        raise AvatarPackageError("iPhone motion must contain one video track and no audio")
    if "mov" not in inspected.get("formatNames", []):
        raise AvatarPackageError("iPhone motion is not a QuickTime movie")
    if inspected.get("codecName") != "hevc" or inspected.get("codecTag") != "hvc1":
        raise AvatarPackageError("iPhone motion must use HEVC with an hvc1 tag")
    if inspected.get("hasAlpha") is not True:
        raise AvatarPackageError("iPhone motion must contain a verified alpha channel")
    width = inspected.get("width")
    height = inspected.get("height")
    duration = inspected.get("durationMilliseconds")
    if width != trusted_width or height != trusted_height:
        raise AvatarPackageError("iPhone motion dimensions do not match its runtime ledger")
    if not isinstance(duration, int) \
            or abs(duration - expected_duration) > MAX_IOS_MOTION_DURATION_DRIFT_MS:
        raise AvatarPackageError("iPhone motion duration does not match its runtime ledger")

    if not isinstance(width, int) or not isinstance(height, int) \
            or not 64 <= width <= MAX_IOS_MOTION_DIMENSION \
            or not 64 <= height <= MAX_IOS_MOTION_DIMENSION \
            or width * height > MAX_IOS_PIXELS:
        raise AvatarPackageError("iPhone motion dimensions are invalid")
    if not isinstance(duration, int) or not MIN_IOS_MOTION_DURATION_MS <= duration \
            <= MAX_IOS_MOTION_DURATION_MS:
        raise AvatarPackageError("iPhone motion duration is invalid")
    return {
        "path": archive_path,
        "sha256": _sha256_path(path),
        "byteCount": size,
        "mediaType": "video/quicktime",
        "width": width,
        "height": height,
        "durationMilliseconds": duration,
    }


def export_ios_light(
    identifier: str,
    display_name: str,
    authoring_root: str | os.PathLike,
    runtime_root: str | os.PathLike,
    destination: str | os.PathLike,
    *,
    require_full_expression: bool = False,
) -> dict:
    """Export an iOS runtime, using full v22 expression parity when available."""
    identifier = _safe_identifier(identifier)
    display_name = _safe_display_name(display_name)
    authoring = Path(authoring_root).resolve(strict=True)
    runtime = Path(runtime_root).resolve(strict=True)
    runtime_manifest = _read_json_file(runtime / "manifest.json")
    body = runtime_manifest.get("body")
    if not isinstance(body, dict):
        raise AvatarPackageError("build a full body before exporting for iPhone")
    transform = body.get("face_transform")
    bounds = (body.get("alignment") or {}).get("face_bounds") \
        if isinstance(body.get("alignment"), dict) else None
    if not isinstance(transform, list) or len(transform) != 2 \
            or any(not isinstance(row, list) or len(row) != 3 for row in transform) \
            or not isinstance(bounds, list) or len(bounds) != 4:
        raise AvatarPackageError("body face alignment is invalid")

    eyes = runtime_manifest.get("eyes")
    brow = runtime_manifest.get("brow")
    gaze = runtime_manifest.get("gaze")
    if not all(isinstance(value, dict) for value in (eyes, brow, gaze)) \
            or len(eyes.get("states") or []) != 8 \
            or len(brow.get("dys") or []) != 14 \
            or len(brow.get("sqs") or []) != 3 \
            or len(gaze.get("dxs") or []) != 25 \
            or len(gaze.get("dys") or []) != 11:
        raise AvatarPackageError("runtime face rig does not match iPhone profile")

    left_eye = _sprite(eyes.get("l"), 1, 8, "verticalStrip")
    right_eye = _sprite(eyes.get("r"), 1, 8, "verticalStrip")
    left_brow = _sprite(brow.get("l"), 14, 3, "verticalStrip")
    right_brow = _sprite(brow.get("r"), 14, 3, "verticalStrip")
    left_gaze = _sprite(gaze.get("l"), 25, 11, "gridAtlas")
    right_gaze = _sprite(gaze.get("r"), 25, 11, "gridAtlas")
    expression = _expression_geometry(runtime_manifest)
    if require_full_expression and expression is None:
        raise AvatarPackageError(
            "rebuild this avatar's face before exporting the full-expression "
            "iPhone AVTR"
        )
    visemes = IOS_VISEMES if expression is not None else IOS_LEGACY_VISEMES
    role_filenames = dict(IOS_LEGACY_ROLE_FILENAMES)
    if expression is not None:
        role_filenames.update({
            f"viseme-{name}": f"viseme-{name}.jpg" for name in IOS_VISEMES
        })
        role_filenames.update(IOS_EXPRESSION_ROLE_FILENAMES)

    matrix_values = [float(value) for row in transform for value in row]
    if not all(value == value and abs(value) <= 8192 for value in matrix_values):
        raise AvatarPackageError("body face transform is invalid")
    m00, m01, tx, m10, m11, ty = matrix_values
    body_width = int(body.get("width") or 0)
    body_height = int(body.get("height") or 0)
    bx, by, bw, bh = bounds
    rig = {
        "bodySize": {"width": body_width, "height": body_height},
        "faceTransform": {
            "a": m00, "b": m10, "c": m01, "d": m11, "tx": tx, "ty": ty,
        },
        "faceBoundsInBody": {
            "x": float(bx), "y": float(by), "width": int(bw), "height": int(bh),
        },
        "leftEye": left_eye,
        "rightEye": right_eye,
        "leftBrow": left_brow,
        "rightBrow": right_brow,
        "leftGaze": left_gaze,
        "rightGaze": right_gaze,
    }

    with tempfile.TemporaryDirectory(prefix="openclam-ios-avtr-") as temporary:
        assets_root = Path(temporary) / "assets"
        assets_root.mkdir()
        sources: dict[str, Path] = {
            "thumbnail": authoring / "keyframe.png",
            "body": _runtime_asset(runtime, body.get("image")),
            "head-mask": _runtime_asset(runtime, body.get("head_mask")),
            "eye-left": _runtime_asset(runtime, eyes["l"].get("src")),
            "eye-right": _runtime_asset(runtime, eyes["r"].get("src")),
            "brow-left": _runtime_asset(runtime, brow["l"].get("src")),
            "brow-right": _runtime_asset(runtime, brow["r"].get("src")),
            "gaze-left-atlas": _runtime_asset(runtime, gaze["l"].get("src")),
            "gaze-right-atlas": _runtime_asset(runtime, gaze["r"].get("src")),
        }
        frames = runtime_manifest.get("frames")
        if not isinstance(frames, dict):
            raise AvatarPackageError("runtime viseme bank is missing")
        for viseme in visemes:
            frame = frames.get(viseme)
            if not isinstance(frame, dict):
                raise AvatarPackageError(f"runtime viseme is missing: {viseme}")
            sources[f"viseme-{viseme}"] = _runtime_asset(runtime, frame.get("open"))

        if expression is not None:
            sources.update({
                "smile-atlas": _runtime_asset(
                    runtime, runtime_manifest["smile"].get("src")
                ),
                "emotion-mouth-atlas": _runtime_asset(
                    runtime, runtime_manifest["emotion_mouth"].get("src")
                ),
                "forehead-left": _runtime_asset(
                    runtime, runtime_manifest["forehead"]["l"].get("src")
                ),
                "forehead-right": _runtime_asset(
                    runtime, runtime_manifest["forehead"]["r"].get("src")
                ),
                "cheek-left": _runtime_asset(
                    runtime, runtime_manifest["cheek"]["l"].get("src")
                ),
                "cheek-right": _runtime_asset(
                    runtime, runtime_manifest["cheek"]["r"].get("src")
                ),
                "under-eye-left": _runtime_asset(
                    runtime, runtime_manifest["eyebag"]["l"].get("src")
                ),
                "under-eye-right": _runtime_asset(
                    runtime, runtime_manifest["eyebag"]["r"].get("src")
                ),
            })

        assets: dict[str, dict] = {}
        for role, filename in role_filenames.items():
            destination_asset = assets_root / filename
            if role == "thumbnail":
                _copy_clean_image(
                    sources[role], destination_asset, jpeg_quality=90
                )
            elif role == "gaze-left-atlas":
                _copy_gaze_atlas(sources[role], destination_asset, left_gaze["box"])
            elif role == "gaze-right-atlas":
                _copy_gaze_atlas(sources[role], destination_asset, right_gaze["box"])
            elif role == "smile-atlas":
                _copy_vertical_strip_as_grid(
                    sources[role],
                    destination_asset,
                    expression["smile"]["box"],
                    columns=expression["smile"]["columns"],
                    rows=expression["smile"]["rows"],
                )
            elif role == "emotion-mouth-atlas":
                _copy_vertical_strip_as_grid(
                    sources[role],
                    destination_asset,
                    expression["emotionMouth"]["box"],
                    columns=expression["emotionMouth"]["columns"],
                    rows=expression["emotionMouth"]["rows"],
                )
            elif role.startswith("viseme-"):
                _copy_clean_image(
                    sources[role], destination_asset, jpeg_quality=95
                )
            else:
                _copy_clean_image(sources[role], destination_asset)
            archive_name = f"assets/{filename}"
            assets[role] = _asset_record(destination_asset, archive_name)

        _validate_ios_rig_assets(
            rig, assets, visemes=visemes, expression=expression
        )

        motions: dict[str, dict] = {}
        runtime_motion = runtime_manifest.get("motion")
        if isinstance(runtime_motion, dict):
            for ios_role, (runtime_role, filename) in IOS_MOTION_FILENAMES.items():
                runtime_clip = runtime_motion.get(runtime_role)
                if not isinstance(runtime_clip, dict) \
                        or runtime_clip.get("alpha_stream_hevc") is None:
                    continue
                source = _runtime_asset(runtime, runtime_clip.get("alpha_stream_hevc"))
                destination_asset = assets_root / filename
                shutil.copyfile(source, destination_asset)
                archive_name = f"assets/{filename}"
                motions[ios_role] = _motion_record(
                    destination_asset, archive_name, runtime_clip
                )

        manifest = {
            "format": FORMAT,
            "version": (
                IOS_EXPRESSION_VERSION if expression is not None
                else IOS_MOTION_VERSION if motions else VERSION
            ),
            "variant": IOS_VARIANT,
            "id": identifier,
            "displayName": display_name,
            "rig": rig,
            "assets": assets,
        }
        if expression is not None:
            manifest["expression"] = expression
        if motions:
            manifest["motions"] = motions
        manifest_bytes = json.dumps(
            manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        if len(manifest_bytes) > MAX_MANIFEST_BYTES:
            raise AvatarPackageError("iPhone avatar manifest is too large")
        total = len(manifest_bytes) + sum(
            path.stat().st_size for path in assets_root.iterdir()
        )
        expanded_limit = (
            MAX_IOS_EXPANDED_BYTES
            if expression is not None
            else MAX_IOS_LEGACY_EXPANDED_BYTES
        )
        if total > expanded_limit:
            raise AvatarPackageError("iPhone avatar contents are too large")

        destination_path = Path(destination)
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_archive = tempfile.mkstemp(
            prefix=".openclam-ios-avtr-", suffix=".tmp", dir=destination_path.parent
        )
        os.close(descriptor)
        try:
            with zipfile.ZipFile(
                temporary_archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9
            ) as archive:
                _write_zip_bytes(
                    archive, MANIFEST, manifest_bytes, zipfile.ZIP_DEFLATED
                )
                for role, filename in role_filenames.items():
                    _write_zip_file(
                        archive,
                        assets_root / filename,
                        f"assets/{filename}",
                        zipfile.ZIP_DEFLATED,
                    )
                for ios_role, (_, filename) in IOS_MOTION_FILENAMES.items():
                    if ios_role in motions:
                        _write_zip_file(
                            archive,
                            assets_root / filename,
                            f"assets/{filename}",
                            zipfile.ZIP_DEFLATED,
                        )
            archive_limit = (
                MAX_IOS_ARCHIVE_BYTES
                if expression is not None
                else MAX_IOS_LEGACY_ARCHIVE_BYTES
            )
            if os.path.getsize(temporary_archive) > archive_limit:
                raise AvatarPackageError("iPhone avatar archive is too large")
            os.chmod(temporary_archive, 0o600)
            os.replace(temporary_archive, destination_path)
        finally:
            if os.path.exists(temporary_archive):
                os.remove(temporary_archive)
    return manifest
