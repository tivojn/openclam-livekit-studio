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


def _source_brown_aperture(image, lm, side, box, scale, ellipse):
    """Resolve a brown 3D eye whose human lower lid crosses visible iris paint.

    Brown iris and warm skin can have almost the same chroma, so the small
    green/skin separation band above is deliberately not made more permissive.
    This fallback instead observes the source sclera. A completely enclosed
    iris uses that actual cavity. A partly occluded iris additionally requires
    bilateral white crescents and a bounded continuous source lash boundary;
    its missing cap is not sampled from the dark lash. No photographic or
    illustrated caller uses this helper, and ambiguous eyes fail closed.
    """
    x, y, width, height = box
    (ex, ey), axes, angle = ellipse
    cx, cy = ex + x, ey + y
    radius = min(axes) * .5
    x0, y0 = max(0, int(np.floor(cx - radius * 2.5))), max(0, int(np.floor(cy - radius * 2.1)))
    x1 = min(image.shape[1], int(np.ceil(cx + radius * 2.5)) + 1)
    y1 = min(image.shape[0], int(np.ceil(cy + radius * 2.3)) + 1)
    observation_box = (x0, y0, x1 - x0, y1 - y0)
    base = image[y0:y1, x0:x1].copy()
    rows, columns = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    canonical_ellipse = ((cx, cy), axes, angle)
    distance = _ellipse_distance(columns, rows, canonical_ellipse)
    geometric = _aperture(lm, side, observation_box, scale)
    paint = base.astype(np.float32)
    gray = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
    brown = ((paint[..., 2] > paint[..., 1] + 12)
             & (paint[..., 1] > paint[..., 0] + 6) & (gray < 110))
    core = distance < -max(3 * scale, 1.5)
    visible_core = core & (geometric > .99)
    if (int(visible_core.sum()) < 24
            or float(brown[visible_core].mean()) < .15):
        return None  # Not this source-material policy; never infer a new style.
    below = core & (rows > cy) & (geometric == 0) & brown
    if int(below.sum()) < max(12, .025 * int(core.sum())):
        return None  # No source-supported lower undercoverage to repair.

    seed = (geometric > .99) & (distance > 3 * scale) & (gray > 100)
    dry = ((rows > cy + radius * 1.85) & (rows < cy + radius * 2.2)
           & (abs(columns - cx) < radius * .7))
    if int(seed.sum()) < 24 or int(dry.sum()) < 24:
        raise UnsupportedSoft3DIris("brown 3D eye has no reliable source sclera/skin boundary")
    # Normalized red/blue separation tolerates the native sclera's lighting;
    # thresholds are learned from this eye and the adjacent lower skin.
    score = (paint[..., 2] - paint[..., 0]) / np.maximum(paint[..., 2] + paint[..., 0], 1)
    wet_score = float(np.percentile(score[seed], 75))
    dry_score = float(np.median(score[dry]))
    if dry_score - wet_score < .18:
        raise UnsupportedSoft3DIris("brown 3D lower eyelid materials cannot be separated safely")
    threshold = wet_score + (dry_score - wet_score) * .45
    white = (score < threshold) & (gray > max(50, float(np.median(gray[seed])) * .32))
    count, labels, _stats, _centres = cv2.connectedComponentsWithStats(white.astype(np.uint8), 8)
    selected = [label for label in range(1, count)
                if int(((labels == label) & seed).sum()) >= max(8, int(8 * scale * scale))]
    if not selected or len(selected) > 2:
        raise UnsupportedSoft3DIris("brown 3D sclera is disconnected or ambiguous")
    sclera = np.isin(labels, selected)
    opening = np.zeros(sclera.shape, np.uint8)
    contours, _ = cv2.findContours(sclera.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(opening, contours, -1, 1, cv2.FILLED)
    local_ellipse = ((cx - x0, cy - y0), axes, angle)
    evidence = dict(brown_iris_lower_undercoverage_pixels=int(below.sum()),
                    brown_aperture_source_box=list(observation_box))
    interior = cv2.distanceTransform(opening, cv2.DIST_L2, 5)
    # A measured iris AND its native glossy rim must lie entirely inside the
    # source cavity. Testing only its inner core can still leave a stationary
    # outer limbus, or pull a painted lash along with the iris.
    footprint = distance <= 6 * scale
    if (not np.any(footprint) or np.any(interior[footprint] < max(1.5 * scale, 1))
            or opening[0].any() or opening[-1].any()
            or opening[:, 0].any() or opening[:, -1].any()):
        aperture, local_ellipse, lower, partial_evidence = _occluded_brown_aperture(
            base, sclera, local_ellipse, scale)
        evidence.update(partial_evidence)
        evidence['brown_aperture_method'] = 'source-occluded-sclera'
        evidence['source_lower_border_columns'] = int(np.any(aperture != geometric, axis=0).sum())
        return observation_box, base, aperture, local_ellipse, evidence, lower
    # Source edges, not the too-small human landmarks, own the fixed lid.
    aperture = _smoothstep(max(.5 * scale, .35), max(1.5 * scale, 1), interior)
    # The first fit may only have seen the upper iris arc through the incorrect
    # human opening. Refit against the recovered source cavity before deciding
    # which pixels belong to sclera. Otherwise the previously clipped lower
    # limbus can sit outside the old ellipse and pollute the reconstructed fill.
    local_ellipse, refined_fit = _measure_ellipse(
        base, aperture, np.asarray(local_ellipse[0], np.float32), radius / 1.25, scale)
    local_y, local_x = np.mgrid[:base.shape[0], :base.shape[1]].astype(np.float32)
    refined_footprint = _ellipse_distance(local_x, local_y, local_ellipse) <= 6 * scale
    if np.any(interior[refined_footprint] < max(1.5 * scale, 1)):
        raise UnsupportedSoft3DIris("remeasured brown 3D iris reaches an uncertain source eyelid")
    evidence['brown_aperture_method'] = 'source-enclosed-sclera'
    evidence['source_iris_refit'] = refined_fit
    evidence['source_lower_border_columns'] = int(np.any(aperture != geometric, axis=0).sum())
    return observation_box, base, aperture.astype(np.float32), local_ellipse, evidence, None


def _occluded_brown_aperture(base, sclera, ellipse, scale):
    """Use two observed scleral crescents and a continuous local lash trough.

    White pixels below the iris centre cannot be evidence for an upper lid.
    Fit those borders separately, then refine the lower border within a small
    source-supported band. A smooth, globally connected path keeps the real
    dry lash fixed instead of following unrelated per-column dark minima.
    This is preparation only; there is no fitting in the tile/render loop.
    """
    from scipy.interpolate import UnivariateSpline

    height, width = sclera.shape
    yy, _xx = np.mgrid[:height, :width].astype(np.float32)
    cols = np.arange(width)
    (cx, cy), axes, _ = ellipse
    radius = min(axes) * .5
    low = np.full(width, np.nan)
    high = low.copy()
    for col in cols:
        wet_rows = np.flatnonzero(sclera[:, col])
        if len(wet_rows) >= max(3, int(3 * scale)):
            high[col], low[col] = wet_rows[0], wet_rows[-1]
    support = np.isfinite(low) & (abs(cols - cx) < radius * 1.85)
    normalized_x = (cols - cx) / radius
    curves, counts = {}, {}
    for name, points in (('lower', low), ('upper', high)):
        actual = support & ((points > cy) if name == 'lower' else (points < cy))
        # A sloping upper lid may expose only a very thin inner white crescent;
        # it still must have an actual observation on both sides, not a fit
        # through lower-eye observations substituted for missing upper ones.
        side_samples = 4 if name == 'lower' else 1
        if (int(actual.sum()) < 12
                or int((actual & (cols < cx - radius * .4)).sum()) < side_samples
                or int((actual & (cols > cx + radius * .4)).sum()) < side_samples):
            raise UnsupportedSoft3DIris("occluded brown iris needs two source-supported scleral crescents")
        keep = actual.copy()
        for _ in range(3):
            if int(keep.sum()) < 8:
                raise UnsupportedSoft3DIris("occluded brown eyelid has insufficient stable source observations")
            coefficients = np.polyfit(normalized_x[keep], points[keep], 4)
            predicted = np.polyval(coefficients, normalized_x)
            residual = abs(predicted - points)
            keep = actual & (residual < max(1.5 * scale, float(np.percentile(residual[actual], 80))))
        curves[name] = predicted.astype(np.float32)
        counts[name] = int(actual.sum())
    available = cols[np.isfinite(low)]
    if not len(available):
        raise UnsupportedSoft3DIris("occluded brown iris has no measured canthi")
    left, right = int(available.min()), int(available.max())
    if (right - left < radius * 1.5 or left == 0 or right == width - 1
            or not np.isfinite([*curves['upper'], *curves['lower']]).all()):
        raise UnsupportedSoft3DIris("occluded brown eyelid does not have a bounded source opening")

    gray = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = cv2.GaussianBlur(gray, (0, 0), max(.6 * scale, .3))
    possible = abs(yy - curves['lower'][None, :]) <= max(5 * scale, 2.5)
    costs = np.full((height, width), 1e9, np.float32)
    for col in range(left, right + 1):
        band = possible[:, col]
        if int(band.sum()) < 3:
            raise UnsupportedSoft3DIris("occluded brown lower lid leaves the source crop")
        values = gray[band, col]
        lo, hi = np.percentile(values, [5, 85])
        costs[band, col] = ((values - lo) / max(hi - lo, 15)
                            + .015 * ((np.flatnonzero(band) - curves['lower'][col]) / scale) ** 2)
    dp, parents = costs[:, left].copy(), {}
    reach = max(1, int(round(2 * scale)))
    steps = np.arange(-reach, reach + 1)
    for col in range(left + 1, right + 1):
        choices = []
        for step in steps:
            value = np.roll(dp, step) + .08 * (step / scale) ** 2
            if step > 0:
                value[:step] = 1e9
            elif step < 0:
                value[step:] = 1e9
            choices.append(value)
        choices = np.stack(choices)
        picked = choices.argmin(axis=0)
        parents[col] = steps[picked]
        dp = choices[picked, np.arange(height)] + costs[:, col]
    if not np.isfinite(dp).all() or float(dp.min()) >= 1e8:
        raise UnsupportedSoft3DIris("occluded brown lower lid has no continuous source border")
    row, path = int(dp.argmin()), np.full(width, np.nan)
    for col in range(right, left, -1):
        path[col] = row
        row -= int(parents[col][row])
    path[left] = row
    stable = np.arange(left, right + 1)
    lower = UnivariateSpline(stable, path[stable], s=len(stable) * .18 * scale * scale,
                             k=3)(cols).astype(np.float32)
    if (not np.isfinite(lower).all()
            or np.max(abs(lower[stable] - curves['lower'][stable])) > max(6 * scale, 3)
            or np.any(lower[stable] - curves['upper'][stable] < -2 * scale)):
        raise UnsupportedSoft3DIris("occluded brown lower border is inconsistent with visible sclera")
    aperture = _smoothstep(.3 * scale, 1.25 * scale,
                           np.minimum(yy - curves['upper'], lower - yy))
    aperture[:, (cols < left) | (cols > right)] = 0
    ellipse, fit = _measure_ellipse(base, aperture, np.array(ellipse[0]), radius / 1.25, scale)
    return aperture.astype(np.float32), ellipse, lower, dict(
        source_iris_refit=fit, source_sclera_border_samples=counts,
        source_lower_lid_method='bounded-continuous-source-spline')


def _complete_occluded_iris_cap(base, observed, unknown, ellipse, texture, iris_alpha):
    """Complete only unseen caps from equal-radius native iris paint.

    Nearest-pixel filling would drag a horizontal lash shadow into a round
    moving cap. Sampling the two closest visible angles at the SAME authored
    radius preserves its ring shading without stretching known iris/glints.
    The original observed pixels are never modified. Ambiguous rings reject.
    """
    angles = np.arange(720, dtype=np.float32) * (2 * np.pi / 720)
    centre = np.array(ellipse[0])
    rx, ry = np.array(ellipse[1]) * .5
    theta = np.deg2rad(ellipse[2])
    source_mask = observed.astype(np.float32)
    completed, fade_pixels, widest_gap = 0, 0, 0.
    for uy, ux in np.argwhere(unknown):
        px = (ux - centre[0]) * np.cos(theta) + (uy - centre[1]) * np.sin(theta)
        py = -(ux - centre[0]) * np.sin(theta) + (uy - centre[1]) * np.cos(theta)
        rho, own_angle = np.hypot(px / rx, py / ry), np.arctan2(py / ry, px / rx)
        qx, qy = rho * rx * np.cos(angles), rho * ry * np.sin(angles)
        mx = (centre[0] + qx * np.cos(theta) - qy * np.sin(theta)).astype(np.float32)[None, :]
        my = (centre[1] + qx * np.sin(theta) + qy * np.cos(theta)).astype(np.float32)[None, :]
        valid = cv2.remap(source_mask, mx, my, cv2.INTER_LINEAR)[0] > .99
        delta = (angles - own_angle + np.pi) % (2 * np.pi) - np.pi
        before, after = valid & (delta <= 0), valid & (delta >= 0)
        if not before.any() or not after.any():
            # At the last quantized <2% fade pixels the 0.5-degree angular
            # sample grid can miss a sliver. Keep the existing nearest native
            # colour there only; this is never allowed for the actual iris.
            if rho > 1 and iris_alpha[uy, ux] < .02:
                fade_pixels += 1
                continue
            raise UnsupportedSoft3DIris("occluded iris cap has no source paint at its own radius")
        left = np.where(before, -delta, np.inf).argmin()
        right = np.where(after, delta, np.inf).argmin()
        dl, dr = -delta[left], delta[right]
        if dl + dr > np.pi * 1.25:
            raise UnsupportedSoft3DIris("too much occluded iris texture would have to be inferred")
        colors = cv2.remap(base, mx, my, cv2.INTER_LINEAR)[0].astype(float)
        texture[uy, ux] = np.rint((colors[left] * dr + colors[right] * dl)
                                 / max(dl + dr, 1e-5)).clip(0, 255).astype(np.uint8)
        completed += 1
        widest_gap = max(widest_gap, float(dl + dr))
    if fade_pixels > max(16, .01 * int((iris_alpha > .001).sum())):
        raise UnsupportedSoft3DIris("occluded iris has too many unobserved outer fade pixels")
    return dict(occluded_cap_pixels=completed, occluded_cap_outer_fade_pixels=fade_pixels,
                occluded_cap_max_arc_degrees=float(np.rad2deg(widest_gap)))


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


def _sclera(base, aperture, distance, scale, *, rim_source_pixels=1.5):
    """Reconstruct only the old iris footprint on the isolated wet-eye graph."""
    height, width = aperture.shape
    rows, columns = np.mgrid[:height, :width].astype(np.float32)
    rim = max(rim_source_pixels * scale, 1)
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
    source_lower = None
    if not refined_columns:
        resolved = _source_brown_aperture(image, lm, side, (x, y, width, height), scale, ellipse)
        if resolved is not None:
            (x, y, width, height), base, aperture, ellipse, source_evidence, source_lower = resolved
            evidence.update(source_evidence)
            refined_columns = evidence['source_lower_border_columns']
    grid_y, grid_x = np.mgrid[:height, :width].astype(np.float32)
    distance = _ellipse_distance(grid_x, grid_y, ellipse)
    iris_alpha = (1 - _smoothstep(-max(.4 * scale, .25), max(.8 * scale, .5), distance)).astype(np.float32)
    brown_source_aperture = 'brown_aperture_method' in evidence
    occluded_brown_aperture = evidence.get('brown_aperture_method') == 'source-occluded-sclera'
    if brown_source_aperture:
        # The native glossy rim belongs to the translated iris too; including
        # it in the old-sclera fill would leave a stationary pale second disc.
        iris_alpha = (1 - _smoothstep(2 * scale, 4.5 * scale, distance)).astype(np.float32)
        evidence.update(iris_rim_full_ownership_source_px=2,
                        iris_rim_fade_end_source_px=4.5,
                        sclera_rim_exclusion_source_px=6)
    if occluded_brown_aperture:
        # A lower lid partly hides this source iris; a glossy enclosed-eye rim
        # would include the fixed lash. Use the measured limbus and a small
        # native transition instead, excluding the lower shadow from texture.
        iris_alpha = (1 - _smoothstep(scale, 2.5 * scale, distance)).astype(np.float32)
        evidence.update(iris_rim_full_ownership_source_px=1,
                        iris_rim_fade_end_source_px=2.5,
                        sclera_rim_exclusion_source_px=5,
                        source_texture_lower_lid_inset_px=4 * scale)
    observed = (aperture > .99) & (iris_alpha > .001)
    if occluded_brown_aperture:
        observed &= grid_y < source_lower[None, :] - 4 * scale
    if int(observed.sum()) < 32:
        raise UnsupportedSoft3DIris("soft-3D iris paint is not visible")
    texture = base.copy()
    unknown = (iris_alpha > .001) & ~observed
    _, labels = cv2.distanceTransformWithLabels(
        (~observed).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
    coordinates = np.argwhere(observed)
    nearest = coordinates[np.clip(labels[unknown] - 1, 0, len(coordinates) - 1)]
    texture[unknown] = texture[nearest[:, 0], nearest[:, 1]]
    if occluded_brown_aperture:
        evidence.update(_complete_occluded_iris_cap(base, observed, unknown, ellipse, texture, iris_alpha))
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
        if occluded_brown_aperture:
            lower_fringe = fringe & (grid_y > ellipse[0][1]) & (distance < 5 * scale)
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
                        _sclera(base, aperture, distance, scale,
                                rim_source_pixels=5 if occluded_brown_aperture else
                                (6 if brown_source_aperture else 1.5)), aperture, iris_alpha,
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
