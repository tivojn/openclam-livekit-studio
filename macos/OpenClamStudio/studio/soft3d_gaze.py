"""Measured soft-3D iris translation, separate from photographic/2D policies.

Large shaded cartoon irises are often considerably larger than MediaPipe's
human iris estimate. We use that estimate only to search for the *observed*
iris/sclera border, validate a near-round authored ellipse, and move its paint
rigidly under a stationary anatomical opening. No pixels are radially warped.
Flat art retains its own path. An unsupported explicit 3D eye stays neutral,
rather than falling back to a radial warp that could deform authored geometry.

Preparation is offline and once per eye; a tile needs only two local remaps.
"""
from dataclasses import dataclass

import cv2
import numpy as np

from .blink import LOWER, UPPER, _line


MODE = "soft-3d-rigid-iris-v1"
NEUTRAL_MODE = "soft-3d-neutral-gaze-v1"
IRIS = {"r": 468, "l": 473}
IRIS_RING = {"r": [469, 470, 471, 472], "l": [474, 475, 476, 477]}


class UnsupportedSoft3DIris(ValueError):
    """No reliable near-round shaded iris: do not impose human eye geometry."""


def _smoothstep(start, stop, value):
    t = np.clip((value - start) / np.maximum(stop - start, 1e-6), 0, 1)
    return t * t * (3 - 2 * t)


def _aperture(lm, side, box, scale):
    """Keep the authored wet-eye opening fixed, including bold lashes/frames."""
    x, y, width, height = box
    rows = np.arange(height, dtype=np.float32)[:, None]
    columns = np.arange(x, x + width, dtype=np.float32)
    upper = _line(lm[UPPER[side]], columns) - y
    lower = _line(lm[LOWER[side]], columns) - y
    distance = np.minimum(rows - upper, lower - rows)
    result = _smoothstep(max(.5 * scale, .35), max(1.5 * scale, 1), distance)
    left = max(lm[UPPER[side]][:, 0].min(), lm[LOWER[side]][:, 0].min())
    right = min(lm[UPPER[side]][:, 0].max(), lm[LOWER[side]][:, 0].max())
    result[:, (columns <= left) | (columns >= right)] = 0
    return result.astype(np.float32)


def _ellipse_distance(xx, yy, ellipse):
    (cx, cy), (width, height), angle = ellipse
    theta = np.deg2rad(angle)
    px = (xx - cx) * np.cos(theta) + (yy - cy) * np.sin(theta)
    py = -(xx - cx) * np.sin(theta) + (yy - cy) * np.cos(theta)
    norm = np.hypot(px / (width * .5), py / (height * .5))
    return (norm - 1) * min(width, height) * .5


def _source_lower_aperture(base, lm, side, box, scale, aperture, ellipse):
    """Refine only a source-supported lower wet/lash border, never the upper lid.

    A human landmark can cut through a large shaded iris. Feathering *inside*
    that estimate leaves the neutral lower limbus visible after the disc moves.
    Learn the source's wet-eye/adjacent-skin chroma difference (not a green-iris
    constant), then find its connected transition in a small lower-edge band.
    Full alpha owns confirmed wet paint; only the actual mixed border feathers.
    No evidence of separable materials means retain the geometric aperture.
    """
    x, y, width, height = box
    rows, columns = np.mgrid[:height, :width].astype(np.float32)
    lower = _line(lm[LOWER[side]], np.arange(x, x + width, dtype=np.float32)) - y
    image = base.astype(np.float32)
    chroma = np.stack([image[..., 2] - image[..., 1],
                       image[..., 1] - image[..., 0]], axis=-1)
    centre, axes, _ = ellipse
    central = abs(columns - centre[0]) < min(axes) * .38
    wet = (aperture > .995) & (rows > lower - 8 * scale) & central
    dry = (rows > lower + 6 * scale) & (rows < lower + 11 * scale) & central
    if int(wet.sum()) < 24 or int(dry.sum()) < 24:
        return aperture, 0
    wet_centre = np.median(chroma[wet], axis=0)
    dry_centre = np.median(chroma[dry], axis=0)
    direction = dry_centre - wet_centre
    length = float(np.linalg.norm(direction))
    if length < 24:
        return aperture, 0
    direction /= length
    score = chroma @ direction
    if np.percentile(score[dry], 15) - np.percentile(score[wet], 85) < 20:
        return aperture, 0
    wet_reference = np.full(width, np.nan, np.float32)
    dry_reference = wet_reference.copy()
    for column in range(width):
        wet_rows = ((aperture[:, column] > .995)
                    & (rows[:, column] >= lower[column] - 7 * scale)
                    & (rows[:, column] <= lower[column] - 2 * scale))
        dry_rows = ((rows[:, column] > lower[column] + 6 * scale)
                    & (rows[:, column] < lower[column] + 11 * scale))
        if int(wet_rows.sum()) >= 3 and int(dry_rows.sum()) >= 3:
            wet_reference[column] = np.median(score[wet_rows, column])
            dry_reference[column] = np.median(score[dry_rows, column])
    valid = (np.isfinite(wet_reference) & np.isfinite(dry_reference)
             & (dry_reference - wet_reference > 20))
    if int(valid.sum()) < max(8, int(min(axes) * .4)):
        return aperture, 0
    for reference in (wet_reference, dry_reference):
        reference[:] = np.interp(np.arange(width), np.flatnonzero(valid), reference[valid])
        reference[:] = cv2.GaussianBlur(reference[None, :], (0, 0), max(scale, .5))[0]
    separation = np.maximum(dry_reference - wet_reference, 20)
    # A dark opaque limbus has different chroma from the brighter iris centre;
    # it is not a partly transparent lash. Include the measured source iris's
    # own chroma envelope so the entire old painted ring has full ownership.
    iris_interior = ((aperture > .995)
                     & (_ellipse_distance(columns, rows, ellipse) < -max(2 * scale, 1)))
    if int(iris_interior.sum()) < 16:
        return aperture, 0
    iris_score = float(np.percentile(score[iris_interior], 95))
    wet_bound = np.maximum(wet_reference + separation * .14, iris_score)
    dry_bound = np.maximum(wet_reference + separation * .40, wet_bound + separation * .15)
    confidence = 1 - _smoothstep(wet_bound, dry_bound, score)
    result = aperture.copy()
    upper = _line(lm[UPPER[side]], np.arange(x, x + width, dtype=np.float32)) - y
    top_alpha = _smoothstep(max(.5 * scale, .35), max(1.5 * scale, 1), rows - upper)
    changed = 0
    for column in np.flatnonzero(valid):
        start = max(0, int(np.ceil(lower[column] - 4 * scale)))
        stop = min(height, int(np.ceil(lower[column] + 8 * scale)) + 1)
        if stop - start < 3 or confidence[start, column] < .98:
            continue
        edge = np.minimum.accumulate(confidence[start:stop, column])
        if not np.any(edge < .01):
            continue  # No bounded source border found: don't expand the mask.
        proposed = np.ones(height, np.float32)
        proposed[start:stop] = edge
        proposed[stop:] = 0
        result[:, column] = np.minimum(proposed, top_alpha[:, column])
        changed += 1
    return result.astype(np.float32), changed


def _measure_ellipse(base, aperture, centre, radius, scale):
    """Require actual sclera contrast, not a pupil/glint edge or human radius.

    A bounded deterministic consensus removes occasional catchlight candidates.
    The final ellipse is fitted to real limbus points, NOT to the landmark ring.
    A non-round authored contour, one-sided arc, or unclear white is unsupported.
    """
    wet_pixels = aperture > .995
    if int(wet_pixels.sum()) < 32:
        raise UnsupportedSoft3DIris("soft-3D gaze needs a visible open eye")
    gray = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = cv2.GaussianBlur(gray, (0, 0), max(.45 * scale, .3))
    step = max(.25 * scale, .15)
    angles = np.linspace(0, 2 * np.pi, 128, endpoint=False)
    radii = np.arange(.9 * radius, 1.7 * radius, step)
    span = max(2, int(round(1.5 * scale / step)))
    if len(radii) <= span:
        raise UnsupportedSoft3DIris("soft-3D iris is too small to measure")
    xx = (centre[0] + np.cos(angles)[:, None] * radii).astype(np.float32)
    yy = (centre[1] + np.sin(angles)[:, None] * radii).astype(np.float32)
    samples = cv2.remap(gray, xx, yy, cv2.INTER_LINEAR)
    wet = cv2.remap(aperture, xx, yy, cv2.INTER_LINEAR)
    white = max(110, float(np.percentile(gray[wet_pixels], 60)))
    derivative = samples[:, span:] - samples[:, :-span]
    valid = ((wet[:, span:] > .995) & (wet[:, :-span] > .995)
             & (samples[:, span:] >= white))
    derivative[~valid] = -999
    indexes = derivative.argmax(axis=1) + span // 2
    usable = derivative.max(axis=1) > 12
    points = np.stack([xx[np.arange(len(angles)), indexes],
                       yy[np.arange(len(angles)), indexes]], axis=1)[usable]
    if len(points) < 16:
        raise UnsupportedSoft3DIris("soft-3D iris has insufficient sclera contrast")
    best = np.zeros(len(points), bool)
    rng = np.random.default_rng(0)
    tolerance = max(1.25 * scale, .9)
    for _ in range(160):
        selected = points[rng.choice(len(points), 3, replace=False)]
        design = np.column_stack([2 * selected, np.ones(3)])
        try:
            cx, cy, q = np.linalg.solve(design, np.sum(selected * selected, axis=1))
        except np.linalg.LinAlgError:
            continue
        measured_radius = np.sqrt(max(0, q + cx * cx + cy * cy))
        if (not .85 * radius < measured_radius < 1.65 * radius
                or np.linalg.norm([cx - centre[0], cy - centre[1]]) > .6 * radius):
            continue
        inliers = np.abs(np.linalg.norm(points - [cx, cy], axis=1) - measured_radius) < tolerance
        if int(inliers.sum()) > int(best.sum()):
            best = inliers
    if int(best.sum()) < max(16, .8 * len(points)):
        raise UnsupportedSoft3DIris("soft-3D iris is not reliably near-round")
    inliers = points[best]
    try:
        ellipse = cv2.fitEllipse(inliers.reshape(-1, 1, 2))
    except cv2.error as error:
        raise UnsupportedSoft3DIris("soft-3D iris ellipse could not be measured") from error
    measured = np.asarray(ellipse[0], np.float32)
    axes = np.asarray(ellipse[1], np.float32) * .5
    residual = np.abs(_ellipse_distance(inliers[:, 0], inliers[:, 1], ellipse))
    if (not np.isfinite([*measured, *axes, ellipse[2]]).all()
            or min(axes) < .8 * radius or max(axes) > 1.7 * radius
            or max(axes) / min(axes) > 1.2
            or np.linalg.norm(measured - centre) > .65 * radius
            or np.percentile(residual, 95) > max(1.5 * scale, 1)
            or inliers[:, 0].min() > measured[0] - .55 * min(axes)
            or inliers[:, 0].max() < measured[0] + .55 * min(axes)):
        raise UnsupportedSoft3DIris("soft-3D iris contour is unsupported or ambiguous")
    return ellipse, dict(samples=int(len(points)), inliers=int(best.sum()),
                         residual_p95_px=float(np.percentile(residual, 95)))


def _sclera(base, aperture, distance, scale):
    """Reconstruct only the old iris footprint on the isolated wet-eye graph."""
    height, width = aperture.shape
    rows, columns = np.mgrid[:height, :width].astype(np.float32)
    rim = max(1.5 * scale, 1)
    known = (aperture > .99) & (distance > rim)
    if int(known.sum()) < 12:
        raise UnsupportedSoft3DIris("soft-3D gaze needs exposed sclera beside its iris")
    design = np.stack([np.ones_like(columns), columns / width, rows / height], axis=-1)
    values = base[known].astype(np.float64)
    bright = values.mean(axis=1) >= np.percentile(values.mean(axis=1), 15)
    coefficients = np.linalg.lstsq(design[known][bright], values[bright], rcond=None)[0]
    fill = np.clip(design @ coefficients, 0, 255).astype(np.float32)
    wet = aperture > .001
    holes = wet & (distance <= rim)
    fill[~holes] = base[~holes]
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
    neutral_wet: np.ndarray
    sclera: np.ndarray
    aperture: np.ndarray
    iris_alpha: np.ndarray
    grid_x: np.ndarray
    grid_y: np.ndarray
    ellipse: tuple
    limits: tuple
    evidence: dict

    def metadata(self):
        (cx, cy), axes, angle = self.ellipse
        return dict(mode=MODE, centre=[float(cx + self.box[0]), float(cy + self.box[1])],
                    diameters=[float(v) for v in axes], angle=float(angle),
                    max_translation=[float(v) for v in self.limits], **self.evidence)


def prepare(key, landmarks, side, box):
    """Prepare ONLY an explicitly selected 3D-render eye, without modifying it."""
    image = np.asarray(key)
    lm = np.asarray(landmarks, np.float32)
    if (image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8
            or lm.shape != (478, 2) or not np.isfinite(lm).all() or side not in IRIS):
        raise ValueError("invalid soft-3D gaze image or landmarks")
    if len(box) != 4 or not np.isfinite(box).all():
        raise ValueError("invalid soft-3D gaze box")
    x, y, width, height = (int(v) for v in box)
    if (min(x, y) < 0 or min(width, height) < 3
            or x + width > image.shape[1] or y + height > image.shape[0]):
        raise ValueError("soft-3D gaze box is outside the keyframe")
    centre = lm[IRIS[side]].copy()
    radius = float(np.linalg.norm(lm[IRIS_RING[side]] - centre, axis=1).mean())
    if radius < 2 or radius > max(width, height) * .5:
        raise UnsupportedSoft3DIris("soft-3D iris estimate is invalid")
    centre -= np.array([x, y], np.float32)
    scale = max(image.shape[:2]) / 1024
    base = image[y:y + height, x:x + width].copy()
    aperture = _aperture(lm, side, (x, y, width, height), scale)
    ellipse, evidence = _measure_ellipse(base, aperture, centre, radius, scale)
    aperture, refined_columns = _source_lower_aperture(
        base, lm, side, (x, y, width, height), scale, aperture, ellipse)
    evidence['source_lower_border_columns'] = refined_columns
    grid_y, grid_x = np.mgrid[:height, :width].astype(np.float32)
    distance = _ellipse_distance(grid_x, grid_y, ellipse)
    iris_alpha = (1 - _smoothstep(-max(.4 * scale, .25), max(.8 * scale, .5), distance)).astype(np.float32)
    observed = (aperture > .99) & (iris_alpha > .001)
    if int(observed.sum()) < 32:
        raise UnsupportedSoft3DIris("soft-3D iris paint is not visible")
    texture = base.copy()
    unknown = (iris_alpha > .001) & ~observed
    _, labels = cv2.distanceTransformWithLabels(
        (~observed).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
    coordinates = np.argwhere(observed)
    nearest = coordinates[np.clip(labels[unknown] - 1, 0, len(coordinates) - 1)]
    texture[unknown] = texture[nearest[:, 0], nearest[:, 1]]
    # Boundary source pixels already mix wet-eye paint and dry lash/skin.
    # Retain that stationary dry contribution when replacing the wet one;
    # source-over with the aperture again would leave a second old iris rim.
    neutral_wet = base.astype(np.float32)
    full_wet = aperture > .99
    _, wet_labels = cv2.distanceTransformWithLabels(
        (~full_wet).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
    wet_coordinates = np.argwhere(full_wet)
    fringe = (aperture > 0) & ~full_wet
    nearest_wet = wet_coordinates[np.clip(wet_labels[fringe] - 1, 0, len(wet_coordinates) - 1)]
    neutral_wet[fringe] = base[nearest_wet[:, 0], nearest_wet[:, 1]]
    # At the lower old-iris fringe, derive the wet contribution against the
    # nearest dry-border source pixel. This is ordinary alpha decontamination:
    # replacing it then yields coverage*newWet + (1-coverage)*stationaryDry,
    # not a bright overshoot or a twice-composited remnant of the original iris.
    dry = aperture == 0
    if refined_columns and np.any(dry):
        _, dry_labels = cv2.distanceTransformWithLabels(
            (~dry).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
        dry_coordinates = np.argwhere(dry)
        lower_fringe = fringe & (grid_y > ellipse[0][1]) & (distance <= max(1.5 * scale, 1))
        nearest_dry = dry_coordinates[np.clip(dry_labels[lower_fringe] - 1, 0, len(dry_coordinates) - 1)]
        dry_paint = base[nearest_dry[:, 0], nearest_dry[:, 1]].astype(np.float32)
        coverage = aperture[lower_fringe, None]
        neutral_wet[lower_fringe] = (base[lower_fringe] - (1 - coverage) * dry_paint) / coverage
    wet_y, wet_x = np.where(aperture > .99)
    small_radius = min(ellipse[1]) * .5
    # The iris may be partly occluded by the lid, never squeezed to stay inside.
    # Clamp large requested glances to local anatomy without changing its size.
    limits = (min(.35 * small_radius, .2 * (wet_x.max() - wet_x.min())),
              min(.18 * small_radius, .2 * (wet_y.max() - wet_y.min())))
    return PreparedIris((x, y, width, height), base, texture, neutral_wet,
                        _sclera(base, aperture, distance, scale), aperture, iris_alpha,
                        grid_x, grid_y, ellipse, limits, evidence)


def state(prepared, dx, dy):
    """Translate the entire iris texture once, then clip by the unchanged lid."""
    dx, dy = float(dx), float(dy)
    if not np.isfinite([dx, dy]).all():
        raise ValueError("soft-3D gaze displacement must be finite")
    dx = float(np.clip(dx, -prepared.limits[0], prepared.limits[0]))
    dy = float(np.clip(dy, -prepared.limits[1], prepared.limits[1]))
    if dx == 0 and dy == 0:
        return np.dstack([prepared.base.copy(), np.zeros(prepared.aperture.shape, np.uint8)])
    map_x = (prepared.grid_x - dx).astype(np.float32)
    map_y = (prepared.grid_y - dy).astype(np.float32)
    texture = cv2.remap(prepared.texture, map_x, map_y, cv2.INTER_LANCZOS4,
                        borderMode=cv2.BORDER_REPLICATE)
    matte = cv2.remap(prepared.iris_alpha, map_x, map_y, cv2.INTER_LINEAR,
                      borderMode=cv2.BORDER_CONSTANT)
    wet_rgb = prepared.sclera * (1 - matte[..., None]) + texture * matte[..., None]
    rgb = (prepared.base.astype(np.float32) + prepared.aperture[..., None]
           * (wet_rgb - prepared.neutral_wet.astype(np.float32)))
    # In uncertain non-refined fringe pixels, never invent a glint brighter
    # than either source or newly exposed wet paint through extrapolation.
    rgb = np.clip(rgb, np.minimum(prepared.base, wet_rgb), np.maximum(prepared.base, wet_rgb))
    ownership = (prepared.aperture > 0).astype(np.uint8) * 255
    return np.dstack([np.rint(rgb).clip(0, 255).astype(np.uint8), ownership])
