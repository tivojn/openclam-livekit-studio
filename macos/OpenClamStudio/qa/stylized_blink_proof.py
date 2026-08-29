#!/usr/bin/env python3
"""Render deterministic open/half/closed proof for a built stylized avatar."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def _asset(runtime: Path, value: str) -> Path:
    relative = value.removeprefix("assets/")
    return runtime / relative


def _sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _compose(canonical: Image.Image, runtime: Path, metadata: dict) -> Image.Image:
    result = canonical.convert("RGBA").copy()
    for side in ("r", "l"):
        value = metadata[side]
        x, y, width, height = [int(round(float(item))) for item in value["box"]]
        with Image.open(_asset(runtime, value["src"])) as source:
            plate = source.convert("RGBA")
        if plate.size != (width, height):
            raise SystemExit(f"{side} semantic plate does not match its full-eye box")
        result.alpha_composite(plate, (x, y))
    return result


def _proof_crop(frames: list[Image.Image], metadata: dict) -> tuple[int, int, int, int]:
    boxes = [metadata[side]["box"] for side in ("r", "l")]
    left = min(float(box[0]) for box in boxes)
    top = min(float(box[1]) for box in boxes)
    right = max(float(box[0]) + float(box[2]) for box in boxes)
    bottom = max(float(box[1]) + float(box[3]) for box in boxes)
    span = right - left
    height = bottom - top
    canvas_width, canvas_height = frames[0].size
    return (
        max(0, int(round(left - span * .22))),
        max(0, int(round(top - height * .35))),
        min(canvas_width, int(round(right + span * .22))),
        min(canvas_height, int(round(bottom + height * .55))),
    )


def _eye_metrics(canonical: Image.Image, runtime: Path, metadata: dict) -> dict:
    """Return pixel evidence that the large authored eye is fully replaced."""
    canonical_rgba = np.asarray(canonical.convert("RGBA"), dtype=np.uint8)
    result = {}
    for side in ("r", "l"):
        value = metadata[side]
        x, y, width, height = [int(round(float(item))) for item in value["box"]]
        neutral = canonical_rgba[y:y + height, x:x + width, :3]
        with Image.open(_asset(runtime, value["src"])) as image:
            plate = np.asarray(image.convert("RGBA"), dtype=np.uint8)
        if plate.shape[:2] != neutral.shape[:2]:
            raise SystemExit(f"{side} semantic plate does not match its full-eye box")
        rgb = neutral.astype(np.float32)
        maximum = rgb.max(axis=2)
        minimum = rgb.min(axis=2)
        saturation = (maximum - minimum) * 255.0 / np.maximum(maximum, 1.0)
        white = (saturation < 85.0) & (maximum > 135.0)
        component_count, labels, stats, _ = cv2.connectedComponentsWithStats(
            white.astype(np.uint8)
        )
        candidates = [
            index for index in range(1, component_count)
            if int(stats[index, cv2.CC_STAT_AREA]) >= 24
        ]
        hard_alpha = plate[:, :, 3] >= 250
        if not candidates:
            raise SystemExit(f"{side} canonical sclera was not found in proof crop")
        white_index = max(
            candidates,
            key=lambda index: int(np.count_nonzero(
                (labels == index) & hard_alpha
            )),
        )
        open_sclera = labels == white_index
        alpha = plate[:, :, 3].astype(np.float32) / 255.0
        rendered = np.clip(
            plate[:, :, :3].astype(np.float32) * alpha[:, :, None]
            + rgb * (1.0 - alpha[:, :, None]),
            0,
            255,
        )
        render_max = rendered.max(axis=2)
        render_min = rendered.min(axis=2)
        render_saturation = (
            (render_max - render_min) * 255.0 / np.maximum(render_max, 1.0)
        )
        remaining = open_sclera & (render_saturation < 72.0) & (render_max > 155.0)
        remaining_count, _, remaining_stats, _ = cv2.connectedComponentsWithStats(
            remaining.astype(np.uint8)
        )
        remaining_areas = [
            int(remaining_stats[index, cv2.CC_STAT_AREA])
            for index in range(1, remaining_count)
        ]
        inset_threshold = max(24, int(np.count_nonzero(open_sclera) * .01))
        feather = (plate[:, :, 3] > 2) & (plate[:, :, 3] < 24)
        seam_delta = np.abs(
            plate[:, :, :3].astype(np.int16) - neutral.astype(np.int16)
        ).max(axis=2)
        result[side] = {
            "openScleraPixels": int(np.count_nonzero(open_sclera)),
            "minimumAlphaOverOpenSclera": int(
                plate[:, :, 3][open_sclera].min(initial=255)
            ),
            "closedScleraComponentPixelsRemaining": int(sum(
                area for area in remaining_areas if area >= inset_threshold
            )),
            "largestNearNeutralComponent": max(remaining_areas, default=0),
            "featherP99ColorDelta": float(
                np.percentile(seam_delta[feather], 99) if np.any(feather) else 0.0
            ),
        }
    return result


def render(avatar: Path, output: Path, runtime: Path | None = None) -> dict:
    runtime = runtime or avatar / "runtime"
    manifest = json.loads((runtime / "manifest.json").read_text())
    metadata = manifest.get("stylized_blink")
    if not isinstance(metadata, dict) or metadata.get("mode") != "semantic-eye-switch":
        raise SystemExit("avatar has no reviewed semantic full-eye blink; rebuild its face")
    with Image.open(avatar / "keyframe.png") as image:
        canonical = image.convert("RGBA")

    # Runtime policy deliberately leaves the canonical authored eye untouched
    # at both open and half closure, then switches the complete eye at closed.
    open_frame = canonical.copy()
    half_frame = canonical.copy()
    closed_frame = _compose(canonical, runtime, metadata)
    frames = [open_frame, half_frame, closed_frame]
    labels = ["OPEN · canonical", "HALF · canonical", "CLOSED · full-eye plate"]
    crop = _proof_crop(frames, metadata)
    panels = [frame.crop(crop) for frame in frames]
    target_height = 520
    panels = [
        panel.resize(
            (max(1, round(panel.width * target_height / panel.height)), target_height),
            Image.Resampling.LANCZOS,
        )
        for panel in panels
    ]
    gap = 24
    header = 62
    sheet = Image.new(
        "RGB",
        (sum(panel.width for panel in panels) + gap * 4, target_height + header + gap),
        (27, 27, 29),
    )
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=20)
    x = gap
    for panel, label in zip(panels, labels):
        sheet.paste(panel.convert("RGB"), (x, header))
        draw.text((x, 20), label, fill=(245, 245, 247), font=font)
        x += panel.width + gap
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True)

    metrics = {
        "avatar": avatar.name,
        "sourceMedium": manifest.get("source_medium"),
        "policy": "canonical-open/canonical-half/semantic-full-eye-closed",
        "openSHA256": _sha(open_frame),
        "halfSHA256": _sha(half_frame),
        "openEqualsHalf": _sha(open_frame) == _sha(half_frame),
        "closedDiffersFromOpen": _sha(closed_frame) != _sha(open_frame),
        "closedEyeBoxes": {side: metadata[side]["box"] for side in ("r", "l")},
        "pixelEvidence": _eye_metrics(canonical, runtime, metadata),
        "proof": str(output.resolve()),
    }
    output.with_suffix(".json").write_text(json.dumps(metrics, indent=2) + "\n")
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("avatar", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--runtime", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(
        render(arguments.avatar, arguments.output, arguments.runtime), indent=2
    ))


if __name__ == "__main__":
    main()
