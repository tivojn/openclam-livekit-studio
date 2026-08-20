#!/usr/bin/env python3
"""Rebuild the deterministic, non-person golden ios-light AVTR fixture."""

from __future__ import annotations

import binascii
import base64
import hashlib
import json
from pathlib import Path
import struct
import zipfile
import zlib


ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
ARCHIVE = FIXTURES / "ios-light-golden.avtr"
READABLE_MANIFEST = FIXTURES / "ios-light-golden.manifest.json"
MOTION_ARCHIVE = FIXTURES / "ios-light-motion-v3-golden.avtr"
MOTION_READABLE_MANIFEST = FIXTURES / "ios-light-motion-v3-golden.manifest.json"

# Procedural 64x96, six-frame HEVC-with-alpha clips. They contain only colored
# rectangles over transparency. Keeping their known-good bytes in the fixture
# builder avoids nondeterminism from VideoToolbox encoder versions while still
# exercising the real AVFoundation alpha validation and player path.
EDGE_IDLE_MOTION = base64.b64decode(
    "AAAAFGZ0eXBxdCAgAAACAHF0ICAAAAAId2lkZQAAAlNtZGF0AAAAO04BBTJHVkrcXExDP5TvxRE80UOoAQAAAwADAwAAAwABAgAAyoALAAADAAADAAAdQgwDiSQBDf////+AAAAAmygBr7PRD6TuH/0x0HN6iJ7uRUbuFeFL/d134ctn90bizdnw7L0ATSYBK7TJRHl73YbgwDDuvIlsJRCJkGVscJZ0rna58CSqYlmgrZxGvmY3x8Z1Ntxrijg0dZAAAJ2n4EkGlKML2mE8hmR0jlVVdJcmiRKAdxDSidWR0Q1ZmRYY6g0AGrYLAcGSsF79KsNsZ17mUA2MYigAup+NAAAAO04JBTJHVkrcXExDP5TvxRE80UOoAQAAAwADAwAAAwABAgAAyoALAAADAAADAAAdTAwDiSQBDf////+AAAAAMCgJk+y0VIWPRaf9jRanmzYjP8oHIf/3NGnIVGFbMBkNVSyzYnoJcr9JceLg5YHoMAAAABUCAdABrEtxwOz6eNmoAAAXpQAAmrgAAAAVAgmkAGsS3HBi8+zqgD8JDYIcxoTgAAAAFQIB0ALMS3HA7Pp42agAABelAACauAAAABUCCaQAsxLccGLz7OqAPwkNghzGhOAAAAAVAgHQA+xLccDs+njZqAAAF6UAAJq4AAAAFQIJpAD7EtxwYvPs6oA/CQ2CHMaE4AAAABUCAdAEjEtxwOz6eNmoAAAXpQAAmrgAAAAVAgmkASMS3HBi8+zqgD8JDYIcxoTgAAAAFQIB0AWMS3HA7Pp42agAABelAACauAAAABUCCaQBYxLccGLz7OqAPwkNghzGhOAAAANjbW9vdgAAAGxtdmhkAAAAAOV8uwDlfLsAAAAD6AAAAfQAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAu90cmFrAAAAXHRraGQAAAAD5Xy7AOV8uwAAAAABAAAAAAAAAfQAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAH0AAAAAAABAAAAAAJnbWRpYQAAACBtZGhkAAAAAOV8uwDlfLsAAAAwAAAAGAB//wAAAAAALWhkbHIAAAAAbWhscnZpZGUAAAAAAAAAAAAAAAAMVmlkZW9IYW5kbGVyAAACEm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACxoZGxyAAAAAGRobHJ1cmwgAAAAAAAAAAAAAAAAC0RhdGFIYW5kbGVyAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABpnN0YmwAAAEWc3RzZAAAAAAAAAABAAABBmh2YzEAAAAAAAAAAQAAAABGRk1QAAACAAAAAgAAQABgAEgAAABIAAAAAAAAAAEWTGF2YyBoZXZjX3ZpZGVvdG9vbGJveAAAAAAAAAAAAAAY//8AAACWaHZjQwEBYAAAALAAAAAAAB7wAPz9+PgAAA8EoAABAClAAQwR//8BYAAAAwCwAAADAAADAB4XBv8ACAAIMChTgFAAMFAMGPxekKEAAQApQgEBAWAAAAMAsAAAAwAAAwAeoBQgYcGPiBe5FkUv/Ln8T+sBagQEBAGiAAEACEQBwGERgpkgJwABAAlOAaUEEAB/kIAAAAAKZmllbAEAAAAAEHBhc3AAAAABAAAAAQAAABhzdHRzAAAAAAAAAAEAAAAGAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAGAAAAAQAAACxzdHN6AAAAAAAAAAAAAAAGAAABUQAAADIAAAAyAAAAMgAAADIAAAAyAAAAFHN0Y28AAAAAAAAAAQAAACQ="
)
MOVES_MOTION = base64.b64decode(
    "AAAAFGZ0eXBxdCAgAAACAHF0ICAAAAAId2lkZQAAAeNtZGF0AAAAO04BBTJHVkrcXExDP5TvxRE80UOoAQAAAwADAwAAAwABAgAAyoALAAADAAADAAAdkgwDiSQBDf////+AAAAAKygBr7LFML2sP/7+jloGmi/RFbPfy04/ZDODm2KS+BxPrDgHSqv6gO7wUBAAAAA7TgkFMkdWStxcTEM/lO/FETzRQ6gBAAADAAMDAAADAAECAADKgAsAAAMAAAMAAB2cDAOJJAEN/////4AAAAAwKAmT7LRUhY9Fp/2NFqebNiM/ygch//c0achUYVswGQ1VLLNieglyv0lx4uDlgegwAAAAFQIB0AGsS3HA7Pp42agAABelAACauAAAABUCCaQAaxLccGLz7OqAPwkNghzGhOAAAAAVAgHQAsxLccDs+njZqAAAF6UAAJq4AAAAFQIJpACzEtxwYvPs6oA/CQ2CHMaE4AAAABUCAdAD7EtxwOz6eNmoAAAXpQAAmrgAAAAVAgmkAPsS3HBi8+zqgD8JDYIcxoTgAAAAFQIB0ASMS3HA7Pp42agAABelAACauAAAABUCCaQBIxLccGLz7OqAPwkNghzGhOAAAAAVAgHQBYxLccDs+njZqAAAF6UAAJq4AAAAFQIJpAFjEtxwYvPs6oA/CQ2CHMaE4AAAA2Ntb292AAAAbG12aGQAAAAA5Xy7AOV8uwAAAAPoAAAB9AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAC73RyYWsAAABcdGtoZAAAAAPlfLsA5Xy7AAAAAAEAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAGAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAfQAAAAAAAEAAAAAAmdtZGlhAAAAIG1kaGQAAAAA5Xy7AOV8uwAAADAAAAAYAH//AAAAAAAtaGRscgAAAABtaGxydmlkZQAAAAAAAAAAAAAAAAxWaWRlb0hhbmRsZXIAAAISbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAALGhkbHIAAAAAZGhscnVybCAAAAAAAAAAAAAAAAALRGF0YUhhbmRsZXIAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAGmc3RibAAAARZzdHNkAAAAAAAAAAEAAAEGaHZjMQAAAAAAAAABAAAAAEZGTVAAAAIAAAACAABAAGAASAAAAEgAAAAAAAAAARZMYXZjIGhldmNfdmlkZW90b29sYm94AAAAAAAAAAAAABj//wAAAJZodmNDAQFgAAAAsAAAAAAAHvAA/P34+AAADwSgAAEAKUABDBH//wFgAAADALAAAAMAAAMAHhcG/wAIAAgwKFOAUAAwUAwY/F6QoQABAClCAQEBYAAAAwCwAAADAAADAB6gFCBhwY+IF7kWRS/8ufxP6wFqBAQEAaIAAQAIRAHAYRGCmSAnAAEACU4BpQQQAH+QgAAAAApmaWVsAQAAAAAQcGFzcAAAAAEAAAABAAAAGHN0dHMAAAAAAAAAAQAAAAYAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAYAAAABAAAALHN0c3oAAAAAAAAAAAAAAAYAAADhAAAAMgAAADIAAAAyAAAAMgAAADIAAAAUc3RjbwAAAAAAAAABAAAAJA=="
)


def png(width: int, height: int, rgba: tuple[int, int, int, int]) -> bytes:
    signature = b"\x89PNG\r\n\x1a\n"

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return (
            struct.pack(">I", len(payload))
            + body
            + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    row = b"\x00" + bytes(rgba) * width
    pixels = zlib.compress(row * height, level=9)
    return signature + chunk(b"IHDR", ihdr) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


def sprite(box: dict[str, int], columns: int, rows: int, storage: str) -> dict:
    return {"box": box, "columns": columns, "rows": rows, "storage": storage}


def write_archive(path: Path, files: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in ["manifest.json"] + sorted(item for item in files if item != "manifest.json"):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 2, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            info.create_system = 3
            archive.writestr(info, files[name])


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    rig = {
        "bodySize": {"width": 128, "height": 192},
        "faceTransform": {"a": 0.1, "b": 0, "c": 0, "d": 0.1, "tx": 12, "ty": 4},
        "faceBoundsInBody": {"x": 35, "y": 28, "width": 58, "height": 70},
        "leftEye": sprite({"x": 560, "y": 480, "width": 4, "height": 4}, 1, 8, "verticalStrip"),
        "rightEye": sprite({"x": 456, "y": 480, "width": 4, "height": 4}, 1, 8, "verticalStrip"),
        "leftBrow": sprite({"x": 560, "y": 450, "width": 4, "height": 3}, 14, 3, "verticalStrip"),
        "rightBrow": sprite({"x": 456, "y": 450, "width": 4, "height": 3}, 14, 3, "verticalStrip"),
        "leftGaze": sprite({"x": 560, "y": 490, "width": 4, "height": 4}, 25, 11, "gridAtlas"),
        "rightGaze": sprite({"x": 458, "y": 490, "width": 4, "height": 4}, 25, 11, "gridAtlas"),
    }

    sizes = {
        "thumbnail": (64, 64),
        "body": (128, 192),
        "head-mask": (1024, 1024),
        "eye-left": (4, 32),
        "eye-right": (4, 32),
        "brow-left": (4, 126),
        "brow-right": (4, 126),
        "gaze-left-atlas": (100, 44),
        "gaze-right-atlas": (100, 44),
    }
    for viseme in ("sil", "FF", "TH", "nn", "RR", "aa", "E", "ih", "ou"):
        sizes[f"viseme-{viseme}"] = (1024, 1024)

    image_files: dict[str, bytes] = {}
    assets: dict[str, dict] = {}
    for index, (role, (width, height)) in enumerate(sizes.items()):
        path = f"assets/{role}.png"
        data = png(
            width,
            height,
            ((37 + index * 17) % 255, (89 + index * 23) % 255, (151 + index * 29) % 255, 255),
        )
        image_files[path] = data
        assets[role] = {
            "path": path,
            "sha256": hashlib.sha256(data).hexdigest(),
            "byteCount": len(data),
            "mediaType": "image/png",
            "width": width,
            "height": height,
        }

    manifest = {
        "format": "openclam-avatar",
        "version": 2,
        "variant": "ios-light",
        "id": "golden-guide",
        "displayName": "Golden Guide",
        "rig": rig,
        "assets": assets,
    }
    manifest_data = json.dumps(
        manifest,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    files = dict(image_files)
    files["manifest.json"] = manifest_data
    READABLE_MANIFEST.write_bytes(manifest_data + b"\n")
    write_archive(ARCHIVE, files)

    motion_sources = {
        "edgeIdle": ("assets/motion-edge-idle.mov", EDGE_IDLE_MOTION),
        "moves": ("assets/motion-moves.mov", MOVES_MOTION),
    }
    motion_files: dict[str, bytes] = {}
    motions: dict[str, dict] = {}
    for kind, (path, data) in motion_sources.items():
        motion_files[path] = data
        motions[kind] = {
            "path": path,
            "sha256": hashlib.sha256(data).hexdigest(),
            "byteCount": len(data),
            "mediaType": "video/quicktime",
            "width": 64,
            "height": 96,
            "durationMilliseconds": 500,
        }

    motion_manifest = {
        "format": "openclam-avatar",
        "version": 3,
        "variant": "ios-light",
        "id": "motion-guide",
        "displayName": "Motion Guide",
        "rig": rig,
        "assets": assets,
        "motions": motions,
    }
    motion_manifest_data = json.dumps(
        motion_manifest,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    motion_package_files = dict(image_files)
    motion_package_files.update(motion_files)
    motion_package_files["manifest.json"] = motion_manifest_data
    MOTION_READABLE_MANIFEST.write_bytes(motion_manifest_data + b"\n")
    write_archive(MOTION_ARCHIVE, motion_package_files)

    print(f"wrote {ARCHIVE} ({ARCHIVE.stat().st_size} bytes)")
    print(f"wrote {MOTION_ARCHIVE} ({MOTION_ARCHIVE.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
