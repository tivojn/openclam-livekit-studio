"""Context-aware proportion QA for generated standing body plates.

The identity-overlay safety checks in :mod:`studio.body` deliberately answer a
different question: can the calibrated face be mapped crisply and without an
oversized *overlay mask*?  They do not prove that the image provider authored
an adult/runway body at the requested number of heads tall.

This module measures the provider-authored silhouette before identity
compositing.  The hard floor is intentionally contextual.  Editorial builds
and briefs that explicitly ask for runway/supermodel proportions must clear
it; ordinary photographic, illustrated, anime, and creature bodies are
measured for diagnostics but are not rejected by this fashion-specific rule.
"""
from __future__ import annotations

import math
import re
from typing import Any, Mapping, Optional, Sequence

import cv2
import numpy as np


REPORT_VERSION = 1
RUNWAY_TARGET_HEADS = (7.5, 8.0)
# Hair volume and the face-oval detector make a literal 7.5 cutoff too brittle.
# 6.45 apparent heads is a conservative hard floor: it tolerates coiffure above
# the anatomical crown while still rejecting the measured Cleo candidate at
# 5.92 (stored face bounds) / 5.79 (raw chin landmark).
MIN_RUNWAY_APPARENT_HEADS = 6.45
ALPHA_THRESHOLD = 8
MIN_SHOULDER_CONFIDENCE = 0.45

_RUNWAY_CUE = re.compile(
    r"(?:\brunway(?:[\s-]+model)?\b|\bsuper[\s-]*model\b|"
    r"\bfashion[\s-]+model\b|\b(?:seven(?:\s+and\s+a\s+half)?|7(?:\.5)?)"
    r"\s*(?:-|\N{EN DASH}|\N{EM DASH}|to)?\s*(?:8|eight)?\s*heads?"
    r"(?:\s+tall)?\b)",
    re.IGNORECASE,
)


def _plain_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def runway_requirement(options: Optional[Mapping[str, Any]]) -> tuple[bool, str]:
    """Return whether the fashion-specific gate applies and why.

    Only owner-visible authoring fields are inspected.  In particular, this
    must not inspect the fixed provider wrapper, which mentions runway
    proportions for historical reasons and would accidentally gate every
    ordinary body.
    """
    options = options if isinstance(options, Mapping) else {}
    style = _plain_text(options.get("style")).lower()
    if style == "editorial":
        return True, "style:editorial"
    authoring = " ".join(
        _plain_text(options.get(field))
        for field in ("prompt", "outfit", "notes")
    )
    match = _RUNWAY_CUE.search(authoring)
    if match:
        return True, f"brief:{match.group(0).lower()}"
    return False, "ordinary"


def _main_person_bounds(image: np.ndarray) -> list[int]:
    if (not isinstance(image, np.ndarray) or image.ndim != 3
            or image.shape[2] != 4):
        raise ValueError("generated body plate must be an RGBA image")
    alpha = image[:, :, 3]
    foreground = (alpha > ALPHA_THRESHOLD).astype(np.uint8)
    labels, _components, stats, _centroids = cv2.connectedComponentsWithStats(
        foreground, connectivity=8)
    if labels <= 1:
        raise ValueError("generated body cutout is empty")
    # Detached floor-shadow and plate fragments must not be allowed to make the
    # person look artificially taller.  The body is the largest foreground
    # component after alpha QA; small disconnected fragments are diagnostic
    # noise, not part of the anthropometric measurement.
    index = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    x = int(stats[index, cv2.CC_STAT_LEFT])
    y = int(stats[index, cv2.CC_STAT_TOP])
    width = int(stats[index, cv2.CC_STAT_WIDTH])
    height = int(stats[index, cv2.CC_STAT_HEIGHT])
    if width <= 0 or height <= 0:
        raise ValueError("generated body cutout has invalid bounds")
    return [x, y, width, height]


def _face_box(face_bounds: Sequence[Any]) -> list[float]:
    if not isinstance(face_bounds, (list, tuple)) or len(face_bounds) != 4:
        raise ValueError("generated face bounds are missing")
    try:
        values = [float(value) for value in face_bounds]
    except (TypeError, ValueError) as error:
        raise ValueError("generated face bounds are invalid") from error
    if (not all(math.isfinite(value) for value in values)
            or values[2] <= 0 or values[3] <= 0):
        raise ValueError("generated face bounds are invalid")
    return values


def _joint(pose: Optional[Mapping[str, Any]], name: str):
    try:
        value = (pose.get("joints") or {})[name]
        x = float(value["x"])
        y = float(value["y"])
        confidence = float(value.get("confidence", 0.0))
    except (AttributeError, KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(value) for value in (x, y, confidence)):
        return None
    return x, y, confidence


def _shoulder_report(
        pose: Optional[Mapping[str, Any]], *, face_width: float,
        head_height: float, person_width: float) -> Optional[dict[str, Any]]:
    left = _joint(pose, "left_shoulder")
    right = _joint(pose, "right_shoulder")
    if left is None or right is None:
        return None
    span = math.hypot(left[0] - right[0], left[1] - right[1])
    confidence = min(left[2], right[2])
    return {
        "span_px": round(float(span), 3),
        "span_to_face_width": round(float(span / face_width), 3),
        "span_to_visual_head_height": round(float(span / head_height), 3),
        "span_to_person_width": round(float(span / person_width), 3),
        "confidence_min": round(float(confidence), 3),
        # Shoulder width is deliberately diagnostic-only: pose, sleeve volume,
        # hairstyle, and Vision joint placement make it unsafe as a hard veto.
        "reliable_for_diagnostic": bool(
            confidence >= MIN_SHOULDER_CONFIDENCE),
    }


def assess(
        body_rgba: np.ndarray, face_bounds: Sequence[Any],
        options: Optional[Mapping[str, Any]] = None,
        pose: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
    """Return a JSON-safe body-proportion report.

    ``face_bounds`` is the generated body's MediaPipe face-oval bounding box,
    before the canonical identity head is composited.  Its lower edge is a
    stable chin proxy.  The top of the main alpha component is the visible
    crown/hair top, so their distance is the apparent head unit the user sees.
    """
    safe_options = options if isinstance(options, Mapping) else {}
    required, trigger = runway_requirement(safe_options)
    style = _plain_text(safe_options.get("style")).lower() or "unspecified"
    base: dict[str, Any] = {
        "v": REPORT_VERSION,
        "valid": True,
        "measurable": False,
        "gate_required": bool(required),
        "gate_trigger": trigger,
        "style": style,
        "target_heads_tall": [float(value) for value in RUNWAY_TARGET_HEADS],
        "minimum_apparent_heads": (
            float(MIN_RUNWAY_APPARENT_HEADS) if required else None),
        "reason": "",
    }
    try:
        person_x, person_y, person_width, person_height = _main_person_bounds(
            body_rgba)
        face_x, face_y, face_width, face_height = _face_box(face_bounds)
        face_bottom = face_y + face_height
        head_height = face_bottom - float(person_y)
        if (head_height <= 0 or face_bottom > body_rgba.shape[0] * 1.05
                or face_x + face_width < person_x
                or face_x > person_x + person_width):
            raise ValueError("generated face is outside the person silhouette")
        apparent_heads = float(person_height) / head_height
        visual_head_fraction = head_height / float(person_height)
        shoulder = _shoulder_report(
            pose, face_width=face_width, head_height=head_height,
            person_width=float(person_width))
    except ValueError as error:
        base["valid"] = not required
        base["reason"] = (
            f"runway body proportion could not be measured: {error}"
            if required else
            "ordinary body; runway proportion gate is not active"
        )
        return base

    base.update({
        "measurable": True,
        "person_bounds": [person_x, person_y, person_width, person_height],
        "face_bounds": [
            round(float(face_x), 3), round(float(face_y), 3),
            round(float(face_width), 3), round(float(face_height), 3),
        ],
        "visible_head_height_px": round(float(head_height), 3),
        "apparent_heads_tall": round(apparent_heads, 3),
        "visual_head_fraction": round(visual_head_fraction, 5),
        "shoulders": shoulder,
    })
    if not required:
        base["reason"] = "ordinary body; runway proportion gate is not active"
        return base
    if apparent_heads + 1e-9 < MIN_RUNWAY_APPARENT_HEADS:
        base["valid"] = False
        base["reason"] = (
            "generated editorial/runway body is head-heavy "
            f"({apparent_heads:.2f} apparent heads tall; require at least "
            f"{MIN_RUNWAY_APPARENT_HEADS:.2f}, target "
            f"{RUNWAY_TARGET_HEADS[0]:.1f}-{RUNWAY_TARGET_HEADS[1]:.1f})"
        )
    else:
        base["reason"] = (
            "editorial/runway body proportion passed "
            f"({apparent_heads:.2f} apparent heads tall)"
        )
    return base


def failure(report: Mapping[str, Any]) -> Optional[str]:
    """Return the hard-gate reason, or ``None`` when the report passes."""
    if bool(report.get("valid")):
        return None
    return str(report.get("reason") or "generated body proportion failed")


__all__ = [
    "MIN_RUNWAY_APPARENT_HEADS",
    "REPORT_VERSION",
    "RUNWAY_TARGET_HEADS",
    "assess",
    "failure",
    "runway_requirement",
]
