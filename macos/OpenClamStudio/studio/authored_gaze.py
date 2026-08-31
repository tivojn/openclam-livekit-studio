"""Rigid gaze for explicitly selected flat artwork, not photographic eyes.

Human landmark lids often cross the middle of an illustrated eye. Landmarks
therefore locate a bounded search, but do not define its aperture or pupil.
An observed, enclosed near-neutral sclera component supplies the actual eye
opening. Its enclosed foreground supplies the *authored* iris/pupil silhouette,
including internal white catchlights. Nothing is fitted to a circle or ellipse.

The entire source foreground is translated once beneath the stationary opening.
Ambiguous/open/occluded foregrounds are deliberately unsupported; callers must
keep neutral gaze, never fall back to the old deforming radial warp.
"""
from dataclasses import dataclass

import cv2
import numpy as np

from .blink import UPPER, LOWER


MODE = "authored-2d-rigid-iris-v1"
NEUTRAL_MODE = "authored-2d-neutral-gaze-v1"
IRIS = {"r": 468, "l": 473}


class UnsupportedAuthoredIris(ValueError):
    """No unambiguous authored foreground: use a transparent neutral tile."""


def _box(image, box):
    if len(box) != 4 or not np.isfinite(box).all():
        raise ValueError("invalid authored gaze box")
    x, y, width, height = [int(v) for v in box]
    if (min(x, y) < 0 or min(width, height) < 3
            or x + width > image.shape[1] or y + height > image.shape[0]):
        raise ValueError("authored gaze box is outside the keyframe")
    return x, y, width, height


def neutral(key, box):
    """Explicit safe fallback; no changed pixels and no hidden legacy warp."""
    image = np.asarray(key)
    x, y, width, height = _box(image, box)
    return np.dstack([image[y:y+height, x:x+width].copy(),
                      np.zeros((height, width), np.uint8)])


def _filled(mask):
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL,
                                    cv2.CHAIN_APPROX_SIMPLE)
    result = np.zeros(mask.shape, np.uint8)
    cv2.drawContours(result, contours, -1, 1, cv2.FILLED)
    return result.astype(bool)


def _observe(image, lm, side, requested_box):
    x, y, width, height = requested_box
    scale = max(image.shape[:2]) / 1024
    corners = lm[UPPER[side] + LOWER[side]]
    span = float(np.ptp(corners[:, 0]))
    if span < max(8 * scale, 5):
        raise UnsupportedAuthoredIris("illustrated eye is too small to isolate")
    pad = int(np.ceil(max(width, height) * .65))
    x0, y0 = max(x - pad, 0), max(y - pad, 0)
    x1, y1 = min(image.shape[1], x + width + pad), min(image.shape[0], y + height + pad)
    base = image[y0:y1, x0:x1]
    centre = lm[IRIS[side]] - [x0, y0]
    cx, cy = np.rint(centre).astype(int)
    if not (0 <= cx < base.shape[1] and 0 <= cy < base.shape[0]):
        raise UnsupportedAuthoredIris("iris seed lies outside bounded eye search")

    # A deliberately limited observation policy: clearly light near-neutral
    # sclera only. Coloured/ambiguous sclera is not normalized to white.
    low, high = base.min(axis=2), base.max(axis=2)
    white = (low >= 145) & ((high.astype(np.int16) - low) <= 65)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(white.astype(np.uint8), 8)
    candidates = []
    for label in range(1, count):
        bx, by, bw, bh, area = [int(v) for v in stats[label]]
        if (area < max(48 * scale * scale, 24) or min(bx, by) < 1
                or bx + bw >= base.shape[1] or by + bh >= base.shape[0]
                or not .65 * span <= bw <= 2.1 * span
                or not .3 * span <= bh <= 2.2 * span):
            continue
        sclera = labels == label
        opening = _filled(sclera)
        if not opening[cy, cx]:
            continue
        holes = opening & ~sclera
        nholes, holelabels, holestats, centroids = cv2.connectedComponentsWithStats(
            holes.astype(np.uint8), 8)
        for component in range(1, nholes):
            area_iris = int(holestats[component, cv2.CC_STAT_AREA])
            if (area_iris < max(24 * scale * scale, 12)
                    or area_iris > .88 * int(opening.sum())
                    or np.linalg.norm(centroids[component] - centre) > .75 * span):
                continue
            foreground = holelabels == component
            # Catchlights enclosed by foreground must move with that artwork,
            # not remain behind as another stationary white eye feature.
            foreground = _filled(foreground)
            other_holes = holes & ~foreground
            if int(other_holes.sum()) > max(8 * scale * scale, .01 * area_iris):
                continue
            # Even tiny unrelated ink marks remain fixed; do not claim them
            # merely because their outline is enclosed by a white eye.
            opening = sclera | foreground
            candidates.append((int(opening.sum()), opening, foreground, sclera,
                               (x0, y0), span))
    if len(candidates) != 1:
        raise UnsupportedAuthoredIris(
            "no unique enclosed illustrated iris and sclera; keep neutral gaze")
    return candidates[0][1:]


def _clean_sclera(base, opening, holes):
    """Local smooth fill uses only measured sclera, never iris/lash/skin RGB."""
    known = opening & ~holes
    if int(known.sum()) < 24:
        raise UnsupportedAuthoredIris("not enough fixed sclera to erase old iris")
    height, width = opening.shape
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    design = np.stack([np.ones_like(xx), xx / width, yy / height], axis=-1)
    values = base[known].astype(np.float64)
    coefficients = np.linalg.lstsq(design[known], values, rcond=None)[0]
    fill = np.clip(design @ coefficients, 0, 255).astype(np.float32)
    fill[~holes] = base[~holes]
    for _ in range(160):
        total = np.zeros_like(fill)
        neighbours = np.zeros(opening.shape, np.float32)
        for sy, sx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            permitted = np.roll(opening, (sy, sx), (0, 1))
            if sy == 1:
                permitted[0] = False
            elif sy == -1:
                permitted[-1] = False
            elif sx == 1:
                permitted[:, 0] = False
            else:
                permitted[:, -1] = False
            total += np.roll(fill, (sy, sx), (0, 1)) * permitted[..., None]
            neighbours += permitted
        fill[holes] = total[holes] / np.maximum(neighbours[holes, None], 1)
    return fill


@dataclass(frozen=True)
class PreparedIris:
    box: tuple
    base: np.ndarray
    sclera: np.ndarray
    aperture: np.ndarray
    iris_alpha: np.ndarray
    texture_premultiplied: np.ndarray
    grid_x: np.ndarray
    grid_y: np.ndarray
    limits: tuple
    observed_foreground: np.ndarray
    evidence: dict

    def metadata(self):
        return dict(mode=MODE, box=list(self.box),
                    max_translation=[float(v) for v in self.limits],
                    **self.evidence)


def prepare(key, landmarks, side, box):
    """Observe flat-art geometry; returned box may exceed human landmark box."""
    image = np.asarray(key)
    lm = np.asarray(landmarks, np.float32)
    if (image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8
            or lm.shape != (478, 2) or not np.isfinite(lm).all() or side not in IRIS):
        raise ValueError("invalid authored gaze image or landmarks")
    requested = _box(image, box)
    opening, foreground, _white, origin, _span = _observe(image, lm, side, requested)
    oy, ox = np.nonzero(opening)
    padding = 3
    left, right = max(0, int(ox.min()) - padding), min(opening.shape[1], int(ox.max()) + padding + 1)
    top, bottom = max(0, int(oy.min()) - padding), min(opening.shape[0], int(oy.max()) + padding + 1)
    x, y = origin[0] + left, origin[1] + top
    width, height = right - left, bottom - top
    opening = opening[top:bottom, left:right]
    foreground = foreground[top:bottom, left:right]
    base = image[y:y+height, x:x+width].copy()
    scale = max(image.shape[:2]) / 1024
    distance = cv2.distanceTransform((~foreground).astype(np.uint8), cv2.DIST_L2, 5)
    # Retain original antialias paint just outside the measured dark/coloured
    # foreground. This is a pixel-distance fringe, never a normalized contour.
    matte = np.clip(1 + max(.8 * scale, .5) - distance, 0, 1).astype(np.float32)
    matte *= opening
    if np.any((matte > 0) & ~opening):
        raise UnsupportedAuthoredIris("authored iris paint crosses the fixed eye")
    holes = matte > 0
    sclera = _clean_sclera(base, opening, holes)
    contours, _ = cv2.findContours(foreground.astype(np.uint8), cv2.RETR_EXTERNAL,
                                    cv2.CHAIN_APPROX_SIMPLE)
    contour = max(contours, key=cv2.contourArea).reshape(-1, 2)
    ys, xs = np.nonzero(foreground)
    # Bounded gaze can become naturally occluded by the original aperture, but
    # it is never squeezed, stretched, rotated, or fitted to a round shape.
    limits = (min(9 * scale, .18 * (ox.max() - ox.min())),
              min(3.5 * scale, .09 * (oy.max() - oy.min())))
    evidence = dict(
        requested_box=list(requested), measured_from="enclosed-authored-sclera",
        foreground_pixels=int(foreground.sum()), aperture_pixels=int(opening.sum()),
        authored_aperture_bounds=[x, y, width, height],
        foreground_bounds=[int(xs.min()+x), int(ys.min()+y),
                           int(xs.max()-xs.min()+1), int(ys.max()-ys.min()+1)],
        authored_contour=(contour + [x, y]).astype(int).tolist(),
        centre_unmodified=True, shape_fit="none", texture_motion="rigid-translation")
    # Publish only the full moving foreground envelope, not the whole large
    # cartoon eye. This keeps 275-tile PNGs bounded while retaining the *entire*
    # authored foreground (unlike the old human-lid-derived clipping box).
    my, mx = np.nonzero(matte > 0)
    pad_x, pad_y = int(np.ceil(limits[0])) + 2, int(np.ceil(limits[1])) + 2
    left, top = max(0, int(mx.min())-pad_x), max(0, int(my.min())-pad_y)
    right, bottom = min(width, int(mx.max())+pad_x+1), min(height, int(my.max())+pad_y+1)
    base = base[top:bottom, left:right].copy()
    sclera = sclera[top:bottom, left:right].copy()
    opening = opening[top:bottom, left:right].copy()
    foreground = foreground[top:bottom, left:right].copy()
    matte = matte[top:bottom, left:right].copy()
    x, y, width, height = x+left, y+top, right-left, bottom-top
    grid_y, grid_x = np.mgrid[:height, :width].astype(np.float32)
    return PreparedIris((x, y, width, height), base, sclera, opening, matte,
                        base.astype(np.float32) * matte[..., None], grid_x, grid_y,
                        limits, foreground, evidence)


def state(prepared, dx, dy):
    """Pure premultiplied translation beneath a fixed authored eye opening."""
    dx, dy = float(dx), float(dy)
    if not np.isfinite([dx, dy]).all():
        raise ValueError("authored gaze displacement must be finite")
    dx = float(np.clip(dx, -prepared.limits[0], prepared.limits[0]))
    dy = float(np.clip(dy, -prepared.limits[1], prepared.limits[1]))
    if dx == 0 and dy == 0:
        return np.dstack([prepared.base.copy(), np.zeros(prepared.aperture.shape, np.uint8)])
    map_x, map_y = prepared.grid_x-dx, prepared.grid_y-dy
    translated = cv2.remap(prepared.texture_premultiplied, map_x, map_y,
                           cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    matte = cv2.remap(prepared.iris_alpha, map_x, map_y, cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_CONSTANT)
    rgb = prepared.sclera * (1-matte[..., None]) + translated
    owner = ((prepared.iris_alpha > 0) | (matte > 0)) & prepared.aperture
    rgb[~owner] = prepared.base[~owner]
    return np.dstack([np.rint(rgb).clip(0, 255).astype(np.uint8), owner.astype(np.uint8)*255])
