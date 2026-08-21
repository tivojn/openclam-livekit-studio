#!/usr/bin/env python3
"""Stage the reviewed bundled iOS avatars for the public Avatar Store.

The generated AVTR files are deterministic, contain only the already-shipped
runtime media, and intentionally omit a macOS variant when no reviewed Mac
authoring archive exists. This tool never uploads or changes release policy.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import zipfile
from pathlib import Path

import jsonschema
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios" / "OpenClamLiveKit" / "App"
ASSET_CATALOG = IOS / "Assets.xcassets"
BUNDLE = IOS / "AvatarCatalog" / "Resources" / "AvatarCatalogAssets.bundle"
SCHEMA = Path(__file__).with_name("catalog.schema.json")
REPOSITORY = "tivojn/openclam-livekit-studio"
TAG = "avatar-store-v1.0.0"
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def rect(x: float, y: float, width: int, height: int) -> dict:
    return {"x": x, "y": y, "width": width, "height": height}


def sprite(box: dict, columns: int, rows: int, storage: str) -> dict:
    return {"box": box, "columns": columns, "rows": rows, "storage": storage}


PROFILES = {
    "captain-ayer": {
        "name": "Captain Ayer",
        "version": 2,
        "rig": {
            "bodySize": {"width": 941, "height": 1672},
            "faceTransform": {
                "a": 0.2375028, "b": -0.000602, "c": 0.000602,
                "d": 0.2375028, "tx": 360.640128, "ty": 29.3446383,
            },
            "faceBoundsInBody": rect(426, 119, 114, 137),
            "leftEye": sprite(rect(524, 470, 182, 104), 1, 8, "verticalStrip"),
            "rightEye": sprite(rect(320, 471, 176, 105), 1, 8, "verticalStrip"),
            "leftBrow": sprite(rect(530, 436, 213, 104), 14, 3, "verticalStrip"),
            "rightBrow": sprite(rect(281, 439, 214, 102), 14, 3, "verticalStrip"),
            "leftGaze": sprite(rect(557, 501, 115, 59), 25, 11, "gridAtlas"),
            "rightGaze": sprite(rect(353, 502, 115, 61), 25, 11, "gridAtlas"),
        },
        "assets": {
            "thumbnail": ASSET_CATALOG / "CaptainAyerKeyframe.imageset/CaptainAyerKeyframe.png",
            "body": ASSET_CATALOG / "CaptainAyerBody.imageset/CaptainAyerBody.png",
            "head-mask": ASSET_CATALOG / "CaptainAyerHeadMask.imageset/CaptainAyerHeadMask.png",
            "eye-left": ASSET_CATALOG / "CaptainAyerEyeLeft.imageset/CaptainAyerEyeLeft.png",
            "eye-right": ASSET_CATALOG / "CaptainAyerEyeRight.imageset/CaptainAyerEyeRight.png",
            "brow-left": ASSET_CATALOG / "CaptainAyerBrowLeft.imageset/CaptainAyerBrowLeft.png",
            "brow-right": ASSET_CATALOG / "CaptainAyerBrowRight.imageset/CaptainAyerBrowRight.png",
            "gaze-left-atlas": ASSET_CATALOG / "CaptainAyerGazeLeftAtlas.imageset/CaptainAyerGazeLeftAtlas.png",
            "gaze-right-atlas": ASSET_CATALOG / "CaptainAyerGazeRightAtlas.imageset/CaptainAyerGazeRightAtlas.png",
            "viseme-sil": ASSET_CATALOG / "CaptainAyerVisemeSil.imageset/CaptainAyerVisemeSil.jpg",
            "viseme-FF": ASSET_CATALOG / "CaptainAyerVisemeFF.imageset/CaptainAyerVisemeFF.jpg",
            "viseme-TH": ASSET_CATALOG / "CaptainAyerVisemeTH.imageset/CaptainAyerVisemeTH.jpg",
            "viseme-nn": ASSET_CATALOG / "CaptainAyerVisemeNN.imageset/CaptainAyerVisemeNN.jpg",
            "viseme-RR": ASSET_CATALOG / "CaptainAyerVisemeRR.imageset/CaptainAyerVisemeRR.jpg",
            "viseme-aa": ASSET_CATALOG / "CaptainAyerVisemeAA.imageset/CaptainAyerVisemeAA.jpg",
            "viseme-E": ASSET_CATALOG / "CaptainAyerVisemeE.imageset/CaptainAyerVisemeE.jpg",
            "viseme-ih": ASSET_CATALOG / "CaptainAyerVisemeIH.imageset/CaptainAyerVisemeIH.jpg",
            "viseme-ou": ASSET_CATALOG / "CaptainAyerVisemeOU.imageset/CaptainAyerVisemeOU.jpg",
        },
        "motions": {},
    },
    "ara": {
        "name": "Ara",
        "version": 3,
        "rig": {
            "bodySize": {"width": 864, "height": 1152},
            "faceTransform": {
                "a": 0.1832646, "b": -0.0058198, "c": 0.0058198,
                "d": 0.1832646, "tx": 337.4508185, "ty": 6.4314091,
            },
            "faceBoundsInBody": rect(391, 68, 85, 111),
            "leftEye": sprite(rect(555, 494, 169, 106), 1, 8, "verticalStrip"),
            "rightEye": sprite(rect(333, 485, 178, 105), 1, 8, "verticalStrip"),
            "leftBrow": sprite(rect(561, 439, 195, 112), 14, 3, "verticalStrip"),
            "rightBrow": sprite(rect(293, 424, 231, 122), 14, 3, "verticalStrip"),
            "leftGaze": sprite(rect(584, 525, 106, 57), 25, 11, "gridAtlas"),
            "rightGaze": sprite(rect(366, 516, 116, 57), 25, 11, "gridAtlas"),
        },
        "assets": {
            role: BUNDLE / "ara" / filename
            for role, filename in {
                "thumbnail": "thumbnail.jpg", "body": "body.png",
                "head-mask": "head-mask.png", "eye-left": "eye-left.png",
                "eye-right": "eye-right.png", "brow-left": "brow-left.png",
                "brow-right": "brow-right.png",
                "gaze-left-atlas": "gaze-left-atlas.png",
                "gaze-right-atlas": "gaze-right-atlas.png",
                "viseme-sil": "viseme-sil.jpg", "viseme-FF": "viseme-FF.jpg",
                "viseme-TH": "viseme-TH.jpg", "viseme-nn": "viseme-nn.jpg",
                "viseme-RR": "viseme-RR.jpg", "viseme-aa": "viseme-aa.jpg",
                "viseme-E": "viseme-E.jpg", "viseme-ih": "viseme-ih.jpg",
                "viseme-ou": "viseme-ou.jpg",
            }.items()
        },
        "motions": {
            "edgeIdle": (BUNDLE / "ara/motion-edge-idle.mov", 720, 1088, 6083),
            "moves": (BUNDLE / "ara/motion-moves.mov", 720, 1088, 6083),
        },
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_record(source: Path, archive_path: str) -> dict:
    with Image.open(source) as image:
        width, height = image.size
        media_type = {"PNG": "image/png", "JPEG": "image/jpeg"}.get(image.format)
    if media_type is None:
        raise ValueError(f"unsupported image: {source}")
    return {
        "path": archive_path,
        "sha256": sha256(source),
        "byteCount": source.stat().st_size,
        "mediaType": media_type,
        "width": width,
        "height": height,
    }


def zip_info(path: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(path, FIXED_TIME)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    return info


def build_package(identifier: str, profile: dict, destination: Path) -> dict:
    assets = {}
    members = []
    for role, source in profile["assets"].items():
        suffix = source.suffix.lower()
        archive_path = f"assets/{role}{suffix}"
        assets[role] = image_record(source, archive_path)
        members.append((archive_path, source))

    motions = {}
    for role, (source, width, height, duration) in profile["motions"].items():
        filename = {"edgeIdle": "motion-edge-idle.mov", "moves": "motion-moves.mov"}[role]
        archive_path = f"assets/{filename}"
        motions[role] = {
            "path": archive_path,
            "sha256": sha256(source),
            "byteCount": source.stat().st_size,
            "mediaType": "video/quicktime",
            "width": width,
            "height": height,
            "durationMilliseconds": duration,
        }
        members.append((archive_path, source))

    manifest = {
        "format": "openclam-avatar",
        "version": profile["version"],
        "variant": "ios-light",
        "id": identifier,
        "displayName": profile["name"],
        "rig": profile["rig"],
        "assets": assets,
    }
    if motions:
        manifest["motions"] = motions
    schema_name = "ios-light-v3.schema.json" if motions else "manifest.schema.json"
    schema = json.loads((ROOT / "shared/avatar-package-v2" / schema_name).read_text())
    jsonschema.Draft202012Validator(schema).validate(manifest)
    manifest_data = json.dumps(
        manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr(zip_info("manifest.json"), manifest_data)
        for archive_path, source in sorted(members):
            archive.writestr(zip_info(archive_path), source.read_bytes())
    os.chmod(destination, 0o600)
    return manifest


def build(output: Path) -> None:
    if output.exists():
        raise ValueError("output already exists")
    release_assets = output / "release-assets"
    catalog_root = output / "catalog/v1"
    release_assets.mkdir(parents=True)
    catalog_root.mkdir(parents=True)
    entries = []

    for identifier, profile in PROFILES.items():
        package = release_assets / f"{identifier}-ios-light.avtr"
        build_package(identifier, profile, package)
        package_hash = sha256(package)
        package.with_suffix(package.suffix + ".sha256").write_text(
            f"{package_hash}  {package.name}\n", encoding="ascii"
        )

        thumbnail = catalog_root / f"{identifier}-thumbnail.png"
        with Image.open(profile["assets"]["thumbnail"]) as source:
            source.convert("RGBA").save(thumbnail, "PNG", compress_level=9)
        thumbnail_hash = sha256(thumbnail)
        thumbnail.with_suffix(thumbnail.suffix + ".sha256").write_text(
            f"{thumbnail_hash}  {thumbnail.name}\n", encoding="ascii"
        )
        with Image.open(thumbnail) as image:
            width, height = image.size

        entries.append({
            "id": identifier,
            "name": profile["name"],
            "author": "OpenClam",
            "version": 1,
            "thumbnail": {
                "url": (
                    f"https://raw.githubusercontent.com/{REPOSITORY}/{TAG}/"
                    f"shared/avatar-store-v1/catalog/v1/{thumbnail.name}"
                ),
                "sha256": thumbnail_hash,
                "bytes": thumbnail.stat().st_size,
                "mime": "image/png",
                "width": width,
                "height": height,
            },
            "variants": {
                "ios-light": {
                    "url": f"https://github.com/{REPOSITORY}/releases/download/{TAG}/{package.name}",
                    "sha256": package_hash,
                    "bytes": package.stat().st_size,
                    "format": "openclam-avatar",
                    "profile": "ios-light",
                }
            },
        })

    catalog = {"schemaVersion": 1, "entries": entries}
    schema = json.loads(SCHEMA.read_text())
    jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(catalog)
    catalog_path = catalog_root / "catalog.json"
    catalog_path.write_text(
        json.dumps(catalog, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    catalog_hash = sha256(catalog_path)
    catalog_path.with_suffix(".json.sha256").write_text(
        f"{catalog_hash}  catalog.json\n", encoding="ascii"
    )
    shutil.copy2(SCHEMA, catalog_root / "catalog.schema.json")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
