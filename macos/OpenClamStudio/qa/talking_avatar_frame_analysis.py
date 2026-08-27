#!/usr/bin/env python3
"""Measure talking-avatar motion from captured UI frames and runtime atlases.

The report deliberately contains only geometry and image-difference metrics. It
never records speech text, audio, account data, or provider credentials.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np

CODE_ROOT = Path(__file__).resolve().parents[1]
if str(CODE_ROOT) not in sys.path:
    sys.path.insert(0, str(CODE_ROOT))

from studio.face import BROW_L, BROW_R, detect, pose_angles


def _distance(points: np.ndarray, first: int, second: int) -> float:
    return float(np.linalg.norm(points[first] - points[second]))


def _frame_metrics(path: str) -> dict | None:
    image = cv2.imread(path, cv2.IMREAD_COLOR)
    if image is None:
        return None
    landmarks, transform = detect(image)
    if landmarks is None:
        return None
    eye_span = max(1e-6, _distance(landmarks, 33, 263))
    mouth_width = max(1e-6, _distance(landmarks, 61, 291))
    left_eye_width = max(1e-6, _distance(landmarks, 263, 362))
    right_eye_width = max(1e-6, _distance(landmarks, 33, 133))
    left_eye_open = _distance(landmarks, 386, 374) / left_eye_width
    right_eye_open = _distance(landmarks, 159, 145) / right_eye_width
    left_brow = (float(np.mean(landmarks[[263, 362], 1]))
                 - float(np.mean(landmarks[BROW_L, 1]))) / eye_span
    right_brow = (float(np.mean(landmarks[[33, 133], 1]))
                  - float(np.mean(landmarks[BROW_R, 1]))) / eye_span
    angles = pose_angles(transform) or (0.0, 0.0, 0.0)
    lip_midline = .5 * (float(landmarks[0, 1]) + float(landmarks[17, 1]))
    corner_line = .5 * (float(landmarks[61, 1]) + float(landmarks[291, 1]))
    return {
        "file": os.path.basename(path),
        "eye_span_px": round(eye_span, 4),
        "mouth_aperture": round(_distance(landmarks, 13, 14) / mouth_width, 6),
        "mouth_width": round(mouth_width / eye_span, 6),
        "smile_corner_lift": round((lip_midline - corner_line) / mouth_width, 6),
        "eye_open": round((left_eye_open + right_eye_open) / 2.0, 6),
        "brow_lift": round((left_brow + right_brow) / 2.0, 6),
        "yaw": round(float(angles[0]), 5),
        "pitch": round(float(angles[1]), 5),
        "roll": round(float(angles[2]), 5),
    }


def _range(rows: list[dict], key: str) -> float:
    values = [float(row[key]) for row in rows]
    return max(values) - min(values) if values else 0.0


def _extrema(rows: list[dict], key: str) -> dict:
    """Name the exact captured frames behind one reported motion range."""
    if not rows:
        return {}
    low = min(rows, key=lambda row: float(row[key]))
    high = max(rows, key=lambda row: float(row[key]))
    return {
        "min": {"file": low["file"], "value": low[key]},
        "max": {"file": high["file"], "value": high[key]},
    }


def _atlas_spec(manifest: dict, name: str) -> tuple[int, str]:
    block = manifest.get(name) or {}
    if name == "eyes":
        return len(block.get("states") or []), "states"
    if name == "gaze":
        return len(block.get("dxs") or []) * len(block.get("dys") or []), "grid"
    if name in {"brow", "forehead"}:
        return len(block.get("dys") or []) * len(block.get("sqs") or []), "grid"
    if name in {"cheek", "eyebag"}:
        return len(block.get("ups") or []), "states"
    if name in {"smile", "emotion_mouth"}:
        emotions = len(block.get("emotions") or ["smile"])
        return (len(block.get("states") or []) * len(block.get("visemes") or [])
                * emotions, "viseme-grid")
    raise ValueError(name)


def _atlas_metrics(runtime: Path, manifest: dict, name: str, side: str) -> dict:
    block = manifest.get(name) or {}
    side_block = block if name in {"smile", "emotion_mouth"} else (block.get(side) or {})
    count, layout = _atlas_spec(manifest, name)
    source = Path(str(side_block.get("src") or "")).name
    image = cv2.imread(str(runtime / source), cv2.IMREAD_UNCHANGED)
    tile_height = int((side_block.get("box") or [0, 0, 0, 0])[3] or 0)
    tile_width = int((side_block.get("box") or [0, 0, 0, 0])[2] or 0)
    valid = bool(image is not None and count > 0 and tile_height > 0
                 and tile_width > 0 and image.shape[0] == count * tile_height
                 and image.shape[1] == tile_width)
    if not valid:
        return {"valid": False, "states": count, "layout": layout,
                "source": source}
    tiles = image.reshape(count, tile_height, tile_width, image.shape[2]).astype(np.float32)
    reference = tiles[0]
    deltas = np.mean(np.abs(tiles - reference), axis=(1, 2, 3)) / 255.0
    unique = len({tile.tobytes() for tile in tiles})
    return {
        "valid": True,
        "states": count,
        "layout": layout,
        "source": source,
        "unique_tiles": unique,
        "max_delta_from_first": round(float(np.max(deltas)), 7),
        "mean_delta_from_first": round(float(np.mean(deltas)), 7),
    }


def analyse(runtime: Path, neutral: str, frames: list[str], expect: str | None = None) -> dict:
    manifest_path = runtime / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    neutral_metrics = _frame_metrics(neutral)
    frame_rows = [row for row in (_frame_metrics(path) for path in frames) if row]
    # Chat/Talk deliberately changes scale between the user's speaking pose and
    # its tiny edge-idle pose. Mixing those two presentations would make face
    # detector noise look like expression. Analyse the largest coherent crop,
    # which is the close-up speaking pose used by the capture workflow.
    maximum_eye_span = max((row["eye_span_px"] for row in frame_rows), default=0.0)
    analysed_rows = [row for row in frame_rows
                     if row["eye_span_px"] >= maximum_eye_span * 0.72]
    all_rows = list(analysed_rows)
    if (neutral_metrics and maximum_eye_span > 0
            and neutral_metrics["eye_span_px"] >= maximum_eye_span * 0.72):
        all_rows.insert(0, neutral_metrics)
    metric_names = (
        "mouth_aperture", "mouth_width", "smile_corner_lift", "eye_open", "brow_lift",
        "yaw", "pitch", "roll",
    )
    ranges = {key: round(_range(all_rows, key), 6) for key in metric_names}
    extrema = {key: _extrema(all_rows, key) for key in metric_names}
    mouth_pass = ranges["mouth_aperture"] >= 0.012 or ranges["mouth_width"] >= 0.012
    upper_face_pass = (ranges["eye_open"] >= 0.008
                       or ranges["brow_lift"] >= 0.006
                       or ranges["yaw"] >= 0.12
                       or ranges["pitch"] >= 0.12
                       or ranges["roll"] >= 0.12)
    neutral_width = float((neutral_metrics or {}).get("mouth_width", 0.0))
    neutral_lift = float((neutral_metrics or {}).get("smile_corner_lift", 0.0))
    widest = max((float(row["mouth_width"]) for row in analysed_rows), default=0.0)
    narrowest = min((float(row["mouth_width"]) for row in analysed_rows),
                    default=neutral_width)
    highest_corners = max((float(row["smile_corner_lift"]) for row in analysed_rows),
                          default=neutral_lift)
    lowest_corners = min((float(row["smile_corner_lift"]) for row in analysed_rows),
                         default=neutral_lift)
    neutral_aperture = float((neutral_metrics or {}).get("mouth_aperture", 0.0))
    widest_aperture = max((float(row["mouth_aperture"]) for row in analysed_rows),
                          default=neutral_aperture)
    neutral_brow = float((neutral_metrics or {}).get("brow_lift", 0.0))
    highest_brow = max((float(row["brow_lift"]) for row in analysed_rows),
                       default=neutral_brow)
    lowest_brow = min((float(row["brow_lift"]) for row in analysed_rows),
                      default=neutral_brow)
    neutral_eye = float((neutral_metrics or {}).get("eye_open", 0.0))
    open_eye_floor = (min((float(row["eye_open"]) for row in analysed_rows),
                          default=0.0) / neutral_eye
                      if neutral_eye > 1e-6 else 0.0)
    median_eye_ratio = (float(np.median([
        float(row["eye_open"]) for row in analysed_rows
    ])) / neutral_eye if neutral_eye > 1e-6 and analysed_rows else 0.0)
    laughter_landscape = {
        # Kept for diagnosis only. The approved v22 smile deliberately does
        # not widen the mouth: it lifts both photographed corners while each
        # active viseme retains its own width, aperture, teeth, and tongue.
        "mouth_width_gain": round(widest - neutral_width, 6),
        "corner_lift_gain": round(highest_corners - neutral_lift, 6),
        "open_eye_floor_ratio": round(open_eye_floor, 6),
        # One natural blink may appear in a frame burst. Median openness is the
        # stable eyelash/upper-face check and therefore ignores that outlier.
        "median_eye_open_ratio": round(median_eye_ratio, 6),
    }
    laughter_landscape["pass"] = bool(neutral_metrics
        and laughter_landscape["corner_lift_gain"] >= .006
        and .82 <= laughter_landscape["median_eye_open_ratio"] <= 1.18)
    sorrow_landscape = {
        "corner_drop": round(neutral_lift - lowest_corners, 6),
        "inner_brow_lift": round(highest_brow - neutral_brow, 6),
    }
    sorrow_landscape["pass"] = bool(neutral_metrics
        and sorrow_landscape["corner_drop"] >= .018
        and sorrow_landscape["inner_brow_lift"] >= .005)
    horror_landscape = {
        "aperture_gain": round(widest_aperture - neutral_aperture, 6),
        "inner_brow_lift": round(highest_brow - neutral_brow, 6),
        "open_eye_floor_ratio": round(open_eye_floor, 6),
    }
    horror_landscape["pass"] = bool(neutral_metrics
        and horror_landscape["aperture_gain"] >= .055
        and horror_landscape["inner_brow_lift"] >= .005
        and horror_landscape["open_eye_floor_ratio"] >= .68)
    anger_landscape = {
        "aperture_gain": round(widest_aperture - neutral_aperture, 6),
        "corner_drop": round(neutral_lift - lowest_corners, 6),
        "brow_drop": round(neutral_brow - lowest_brow, 6),
    }
    anger_landscape["pass"] = bool(neutral_metrics
        and anger_landscape["aperture_gain"] >= .018
        and anger_landscape["corner_drop"] >= .012
        and anger_landscape["brow_drop"] >= .005)
    expression_landscapes = {
        "laughter": laughter_landscape,
        "sorrow": sorrow_landscape,
        "horror": horror_landscape,
        "anger": anger_landscape,
    }
    atlas = {
        name: {side: _atlas_metrics(runtime, manifest, name, side)
               for side in ("l", "r")}
        for name in ("eyes", "gaze", "brow", "forehead", "cheek", "eyebag")
    }
    atlas["smile"] = {"mouth": _atlas_metrics(runtime, manifest, "smile", "mouth")}
    atlas["emotion_mouth"] = {
        "mouth": _atlas_metrics(runtime, manifest, "emotion_mouth", "mouth")}
    atlas_pass = all(
        item["valid"] and item.get("unique_tiles", 0) > 1
        and item.get("max_delta_from_first", 0.0) > 0.00001
        for group in atlas.values() for item in group.values()
    )
    expected_counts = {
        "visemes": len(manifest.get("visemes") or []),
        "eyelids_per_side": len((manifest.get("eyes") or {}).get("states") or []),
        "gaze_positions_per_side": (
            len((manifest.get("gaze") or {}).get("dxs") or [])
            * len((manifest.get("gaze") or {}).get("dys") or [])
        ),
        "brow_forehead_positions_per_side": (
            len((manifest.get("brow") or {}).get("dys") or [])
            * len((manifest.get("brow") or {}).get("sqs") or [])
        ),
        "cheek_states_per_side": len((manifest.get("cheek") or {}).get("ups") or []),
        "under_eye_states_per_side": len((manifest.get("eyebag") or {}).get("ups") or []),
        "laughter_mouth_states": (
            len((manifest.get("smile") or {}).get("states") or [])
            * len((manifest.get("smile") or {}).get("visemes") or [])
        ),
        "emotion_mouth_states": (
            len((manifest.get("emotion_mouth") or {}).get("states") or [])
            * len((manifest.get("emotion_mouth") or {}).get("visemes") or [])
            * len((manifest.get("emotion_mouth") or {}).get("emotions") or [])
        ),
    }
    return {
        "schema": 1,
        "runtime_version": manifest.get("v"),
        "runtime_counts": expected_counts,
        "capture": {
            "requested_frames": len(frames),
            "detected_frames": len(frame_rows),
            "analysed_close_up_frames": len(analysed_rows),
            "neutral_detected": neutral_metrics is not None,
            "neutral_metrics": neutral_metrics,
            "ranges": ranges,
            "extrema": extrema,
            "mouth_motion_pass": mouth_pass,
            "upper_face_motion_pass": upper_face_pass,
            "expression_landscapes": expression_landscapes,
            "sample_metrics": analysed_rows[:8],
        },
        "atlases": atlas,
        "atlas_variation_pass": atlas_pass,
        "expression_expectation": expect,
        "overall_pass": bool(analysed_rows and neutral_metrics and mouth_pass
                             and upper_face_pass and atlas_pass
                             and (expect is None
                                  or expression_landscapes[expect]["pass"])),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--neutral", required=True)
    parser.add_argument("--frames", required=True,
                        help="Glob for captured speaking frames")
    parser.add_argument("--output", required=True)
    parser.add_argument("--expect", choices=("laughter", "sorrow", "horror", "anger"),
                        default=None)
    args = parser.parse_args()
    frames = sorted(glob.glob(args.frames))
    report = analyse(Path(args.runtime), args.neutral, frames, expect=args.expect)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({
        "overall_pass": report["overall_pass"],
        "detected_frames": report["capture"]["detected_frames"],
        "ranges": report["capture"]["ranges"],
        "atlas_variation_pass": report["atlas_variation_pass"],
    }, indent=2))
    return 0 if report["overall_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
