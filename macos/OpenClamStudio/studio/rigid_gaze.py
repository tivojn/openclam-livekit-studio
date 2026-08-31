"""Photographic iris translation under a stationary, measured lid aperture.

This is a local atlas baker, not an image-generation or face-warping model.
Observed iris/pupil pixels move by one constant translation; the lid opening
clips that disc. Only the sclera newly exposed behind the iris is reconstructed
from observed sclera. Small, previously occluded iris caps use nearby observed
iris paint, never skin/lashes. Preparation happens once per eye, not per tile.

The photographic geometry policy is explicit. Cartoon irises can be intentionally
non-circular or off-centre and must not be silently forced through this fitter.
"""
from dataclasses import dataclass

import cv2
import numpy as np

from .blink import LOWER, UPPER, _line


MODE = "photo-rigid-iris-v1"
IRIS = {"r": 468, "l": 473}
IRIS_RING = {"r": [469, 470, 471, 472], "l": [474, 475, 476, 477]}


def _smoothstep(start, stop, value):
    t = np.clip((value - start) / max(stop - start, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _photo_aperture(landmarks, side, box, scale):
    """Keep photographed eyelid/lash pigment outside the gaze layer's alpha."""
    x, y, width, height = box
    rows = np.arange(height, dtype=np.float32)[:, None]
    columns = np.arange(x, x + width, dtype=np.float32)
    upper = _line(landmarks[UPPER[side]], columns) - y
    lower = _line(landmarks[LOWER[side]], columns) - y
    distance = np.minimum(rows - upper[None, :], lower[None, :] - rows)
    aperture = _smoothstep(max(.4 * scale, .25), max(1.4 * scale, .9), distance)
    left = max(landmarks[UPPER[side]][:, 0].min(),
               landmarks[LOWER[side]][:, 0].min())
    right = min(landmarks[UPPER[side]][:, 0].max(),
                landmarks[LOWER[side]][:, 0].max())
    aperture[:, (columns <= left) | (columns >= right)] = 0
    return aperture.astype(np.float32)


def _limbus_circle(base, aperture, centre, radius, scale):
    """Refine only when actual wet-eye contrast supports the landmark circle.

    A truncated MediaPipe iris ring can include eyelid pixels. At a far glance
    that old error became a bright cap or leftover crescent. Sample outward
    dark-to-sclera contrast strictly inside the lid aperture, then accept only a
    small, well-supported correction. No face detector/provider call is made.
    """
    gray = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = cv2.GaussianBlur(gray, (0, 0), max(.45 * scale, .3))
    step = max(.25 * scale, .15)
    angles = np.linspace(0, 2 * np.pi, 96, endpoint=False)
    radii = np.arange(.74 * radius, 1.22 * radius, step)
    span = max(2, int(round(1.5 * scale / step)))
    if len(radii) <= span:
        return centre, radius, False
    xx = (centre[0] + np.cos(angles)[:, None] * radii).astype(np.float32)
    yy = (centre[1] + np.sin(angles)[:, None] * radii).astype(np.float32)
    samples = cv2.remap(gray, xx, yy, cv2.INTER_LINEAR)
    wet = cv2.remap(aperture, xx, yy, cv2.INTER_LINEAR)
    derivative = samples[:, span:] - samples[:, :-span]
    valid = (wet[:, span:] > .995) & (wet[:, :-span] > .995)
    derivative[~valid] = -999
    indexes = derivative.argmax(axis=1) + span // 2
    use = derivative.max(axis=1) > 8
    points = np.stack([xx[np.arange(len(angles)), indexes],
                       yy[np.arange(len(angles)), indexes]], axis=1)[use]
    if len(points) < 12:
        return centre, radius, False
    design = np.column_stack([2 * points[:, 0], 2 * points[:, 1],
                              np.ones(len(points))])
    target = np.sum(points * points, axis=1)

    def fit(a, b):
        cx, cy, constant = np.linalg.lstsq(a, b, rcond=None)[0]
        squared = constant + cx * cx + cy * cy
        return np.array([cx, cy]), np.sqrt(max(0.0, squared))

    measured, measured_radius = fit(design, target)
    residual = np.abs(np.linalg.norm(points - measured, axis=1) - measured_radius)
    inliers = residual < max(1.2 * scale, .8)
    if np.count_nonzero(inliers) >= 12:
        measured, measured_radius = fit(design[inliers], target[inliers])
    else:
        return centre, radius, False
    # Require evidence on both sides; a short lower-lid arc can fit an
    # unrelated circle very well. Stylized/non-circular eyes stay separate.
    inlier_points = points[inliers]
    both_sides = (np.min(inlier_points[:, 0]) < centre[0] - .45 * radius
                  and np.max(inlier_points[:, 0]) > centre[0] + .45 * radius)
    if (not both_sides or not np.isfinite(measured).all()
            or not np.isfinite(measured_radius)
            or np.linalg.norm(measured - centre) > .18 * radius
            or not .75 * radius < measured_radius < 1.15 * radius):
        return centre, radius, False
    return measured.astype(np.float32), float(measured_radius), True


def _sclera(base, aperture, distance, radius, scale):
    """Fill the old iris footprint without pulling lash/skin pigment inside."""
    height, width = aperture.shape
    rows, columns = np.mgrid[:height, :width].astype(np.float32)
    rim = max(1.3 * scale, .9)
    known = (aperture > .99) & (distance > radius + rim)
    if np.count_nonzero(known) < 8:
        raise ValueError("rigid gaze needs visible sclera beside the iris")
    design = np.stack([np.ones_like(columns), columns / width, rows / height], axis=-1)
    values = base[known].astype(np.float64)
    # Avoid dark limbal/tear-duct outliers in the initial smooth field.
    bright = values.mean(axis=1) >= np.percentile(values.mean(axis=1), 12)
    coefficients = np.linalg.lstsq(design[known][bright], values[bright], rcond=None)[0]
    fill = np.clip(design @ coefficients, 0, 255).astype(np.float32)
    wet = aperture > .001
    holes = wet & (distance < radius + rim)
    fill[~holes] = base[~holes]
    # Bounded harmonic interpolation on the wet-eye graph. In particular,
    # unlike ordinary inpainting, its neighbours never include lid or glasses.
    for _ in range(120):
        total = np.zeros_like(fill)
        count = np.zeros((height, width), np.float32)
        for sy, sx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            neighbour = np.roll(fill, (sy, sx), (0, 1))
            permitted = np.roll(wet, (sy, sx), (0, 1))
            if sy == 1:
                permitted[0] = False
            elif sy == -1:
                permitted[-1] = False
            elif sx == 1:
                permitted[:, 0] = False
            else:
                permitted[:, -1] = False
            total += neighbour * permitted[..., None]
            count += permitted
        fill[holes] = total[holes] / np.maximum(count[holes, None], 1)
    return fill


@dataclass(frozen=True)
class PreparedIris:
    box: tuple
    base: np.ndarray
    texture: np.ndarray
    sclera: np.ndarray
    aperture: np.ndarray
    disc: np.ndarray
    grid_x: np.ndarray
    grid_y: np.ndarray
    centre: np.ndarray
    radius: float
    contrast_refined: bool


def prepare(key, landmarks, side, box):
    """Prepare one *photographic* eye; inputs and original pixels are read-only."""
    image = np.asarray(key)
    lm = np.asarray(landmarks, dtype=np.float32)
    if (image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8
            or lm.shape != (478, 2) or not np.isfinite(lm).all()
            or side not in IRIS):
        raise ValueError("invalid photographic gaze image or landmarks")
    if len(box) != 4 or not np.isfinite(box).all():
        raise ValueError("invalid photographic gaze box")
    x, y, width, height = (int(v) for v in box)
    if (min(x, y) < 0 or min(width, height) < 3
            or x + width > image.shape[1] or y + height > image.shape[0]):
        raise ValueError("photographic gaze box is outside the keyframe")
    centre = lm[IRIS[side]].copy()
    radius = float(np.linalg.norm(lm[IRIS_RING[side]] - centre, axis=1).mean())
    if radius < 2 or radius > max(width, height) * .5:
        raise ValueError("invalid photographic iris radius")
    centre -= np.array([x, y], np.float32)
    scale = max(image.shape[:2]) / 1024.0
    base = image[y:y + height, x:x + width].copy()
    aperture = _photo_aperture(lm, side, (x, y, width, height), scale)
    centre, radius, refined = _limbus_circle(base, aperture, centre, radius, scale)
    grid_y, grid_x = np.mgrid[:height, :width].astype(np.float32)
    distance = np.hypot(grid_x - centre[0], grid_y - centre[1])
    disc = (1 - _smoothstep(radius - max(.4 * scale, .25),
                            radius + max(.8 * scale, .5), distance)).astype(np.float32)
    observed = (aperture > .99) & (disc > .001)
    if np.count_nonzero(observed) < 8:
        raise ValueError("rigid gaze needs a visible, open photographic iris")
    # Keep *all* observed iris pixels unchanged, including pupil/catchlights.
    # Only the invisible caps need extrapolation. Nearest observed iris paint
    # cannot accidentally import a skin tone or an eyelash into the disc.
    texture = base.copy()
    unknown = (disc > .001) & ~observed
    _, labels = cv2.distanceTransformWithLabels(
        (~observed).astype(np.uint8), cv2.DIST_L2, 5,
        labelType=cv2.DIST_LABEL_PIXEL)
    coordinates = np.argwhere(observed)
    nearest = coordinates[np.clip(labels[unknown] - 1, 0, len(coordinates) - 1)]
    texture[unknown] = texture[nearest[:, 0], nearest[:, 1]]
    return PreparedIris(
        (x, y, width, height), base, texture,
        _sclera(base, aperture, distance, radius, scale), aperture, disc,
        grid_x, grid_y, centre, radius, refined)


def state(prepared, dx, dy):
    """A straight-alpha tile: rigid iris translation, fixed lid alpha.

    There is no radial displacement falloff and no crossfade with the old
    iris. Opacity is only the stationary anatomical aperture. Runtime must
    continue selecting one nearest atlas cell, not dissolving two pupils.
    """
    dx, dy = float(dx), float(dy)
    if not np.isfinite([dx, dy]).all():
        raise ValueError("gaze displacement must be finite")
    if abs(dx) > prepared.box[2] or abs(dy) > prepared.box[3]:
        raise ValueError("gaze displacement exceeds its local eye patch")
    if dx == 0 and dy == 0:
        return np.dstack([prepared.base.copy(),
                          np.zeros(prepared.aperture.shape, np.uint8)])
    map_x = (prepared.grid_x - dx).astype(np.float32)
    map_y = (prepared.grid_y - dy).astype(np.float32)
    texture = cv2.remap(prepared.texture, map_x, map_y, cv2.INTER_LANCZOS4,
                        borderMode=cv2.BORDER_REPLICATE)
    disc = cv2.remap(prepared.disc, map_x, map_y, cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_CONSTANT)
    rgb = prepared.sclera * (1 - disc[..., None]) + texture * disc[..., None]
    rgb = np.where(prepared.aperture[..., None] > 0, rgb, prepared.base)
    return np.dstack([
        np.rint(rgb).clip(0, 255).astype(np.uint8),
        np.rint(prepared.aperture * 255).clip(0, 255).astype(np.uint8)])
