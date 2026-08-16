#!/usr/bin/env python3
"""Rebuild the deterministic, non-person golden ios-light AVTR fixture."""

from __future__ import annotations

import binascii
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

    files: dict[str, bytes] = {}
    assets: dict[str, dict] = {}
    for index, (role, (width, height)) in enumerate(sizes.items()):
        path = f"assets/{role}.png"
        data = png(
            width,
            height,
            ((37 + index * 17) % 255, (89 + index * 23) % 255, (151 + index * 29) % 255, 255),
        )
        files[path] = data
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
    files["manifest.json"] = manifest_data
    READABLE_MANIFEST.write_bytes(manifest_data + b"\n")

    with zipfile.ZipFile(ARCHIVE, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in ["manifest.json"] + sorted(name for name in files if name != "manifest.json"):
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 2, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            info.create_system = 3
            archive.writestr(info, files[path])

    print(f"wrote {ARCHIVE} ({ARCHIVE.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

