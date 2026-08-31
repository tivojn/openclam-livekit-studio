"""Source-pixel gaze for explicitly selected 3D black-button eyes.

This is not the shaded/coloured 3D iris fitter, the photographic iris fitter,
or the flat-art matte. A complete small dark button, its antialiased bright
rim, and any enclosed catchlights move together under the native eye opening.
The old button is filled from *rim-excluded* measured sclera so the glossy rim
does not become a stationary white halo. Ambiguous geometry/shading fails
closed; callers retain neutral gaze rather than use the legacy radial warp.

Only the bounded observation, harmonic fill, and rigid premultiplied sampler
are shared with authored_gaze. Source-medium dispatch remains the caller's
responsibility and must explicitly remain 3D.
"""
from dataclasses import dataclass

import cv2
import numpy as np

from . import authored_gaze


MODE = "soft-3d-authored-iris-v1"
NEUTRAL_MODE = "soft-3d-neutral-gaze-v1"


class UnsupportedButtonIris(ValueError):
    """No complete native button/rim or no reliable native sclera fill."""


@dataclass(frozen=True)
class PreparedButtonIris(authored_gaze.PreparedIris):
    def metadata(self):
        return dict(mode=MODE, source_medium="3d render", box=list(self.box),
                    max_translation=[float(v) for v in self.limits],
                    **self.evidence)


def neutral(key, box):
    return authored_gaze.neutral(key, box)


def _shading_evidence(base, opening, foreground, distance, fill, scale):
    """Reject a fill inconsistent with independent nearby native shading.

The hidden sclera under the original pupil is unknowable. A held-out native
ring checks whether smooth reconstruction is appropriate; a separately fitted
quadratic checks that the harmonic fill does not invent a bright/dark disc.
Neither comparison calls a filled pixel ground truth.
"""
    ring = opening & (distance > 6 * scale) & (distance <= 14 * scale)
    yy, xx = np.mgrid[:opening.shape[0], :opening.shape[1]]
    ys, xs = np.nonzero(foreground)
    unit = max(float(np.ptp(xs)), float(np.ptp(ys)), 1)
    u, v = (xx - xs.mean()) / unit, (yy - ys.mean()) / unit
    design = np.stack([np.ones_like(u), u, v, u*u, u*v, v*v], axis=-1)
    heldout = ring & ((xx + 3 * yy) % 5 == 0)
    training = ring & ~heldout
    if int(training.sum()) < 48 or int(heldout.sum()) < 16:
        raise UnsupportedButtonIris("not enough rim-free native sclera to validate shading")
    coefficient, _residuals, rank, _singular = np.linalg.lstsq(
        design[training], base[training].astype(np.float64), rcond=None)
    if rank < 6:
        raise UnsupportedButtonIris("native sclera ring is geometrically ambiguous")
    prediction = design @ coefficient
    heldout_error = float(np.quantile(np.abs(prediction[heldout] - base[heldout]), .95))
    reconstruction_error = float(np.quantile(np.abs(prediction[foreground] - fill[foreground]), .95))
    if not np.isfinite([heldout_error, reconstruction_error]).all() or max(
            heldout_error, reconstruction_error) > 12:
        raise UnsupportedButtonIris("native sclera shading cannot be reconstructed reliably")
    return dict(native_sclera_samples=int(ring.sum()),
                sclera_heldout_p95_rgb=heldout_error,
                sclera_reconstruction_model_p95_rgb=reconstruction_error,
                sclera_fill="rim-excluded-native-harmonic",
                hidden_sclera_is_estimate=True)


def prepare(key, landmarks, side, box):
    image = np.asarray(key)
    lm = np.asarray(landmarks, np.float32)
    if (image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8
            or lm.shape != (478, 2) or not np.isfinite(lm).all()
            or side not in authored_gaze.IRIS):
        raise ValueError("invalid 3D button gaze image or landmarks")
    requested = authored_gaze._box(image, box)
    scale = max(image.shape[:2]) / 1024
    # Human lids can sit high inside a large 3D eye. This small, scale-aware
    # search expansion must still find one *complete* enclosed foreground.
    pad = max(1, int(np.ceil(8 * scale)))
    x, y, width, height = requested
    x0, y0 = max(x-pad, 0), max(y-pad, 0)
    x1, y1 = min(image.shape[1], x+width+pad), min(image.shape[0], y+height+pad)
    observation_box = (x0, y0, x1-x0, y1-y0)
    try:
        opening, foreground, _white, origin, _span = authored_gaze._observe(
            image, lm, side, observation_box)
    except authored_gaze.UnsupportedAuthoredIris as error:
        raise UnsupportedButtonIris(str(error)) from error
    oy, ox = np.nonzero(opening)
    left, right = max(0, int(ox.min())-3), min(opening.shape[1], int(ox.max())+4)
    top, bottom = max(0, int(oy.min())-3), min(opening.shape[0], int(oy.max())+4)
    x, y = origin[0]+left, origin[1]+top
    width, height = right-left, bottom-top
    opening = opening[top:bottom, left:right].copy()
    foreground = foreground[top:bottom, left:right].copy()
    base = image[y:y+height, x:x+width].copy()

    paint = base[foreground].astype(np.float32)
    dark = paint.max(axis=1) < 105
    fraction = float(foreground.sum() / opening.sum())
    if (not .012 <= fraction <= .35 or float(dark.mean()) < .70
            or float(np.median(np.ptp(paint[dark], axis=1))) > 20):
        raise UnsupportedButtonIris("source is not a small native neutral-colour 3D button eye")
    interior = cv2.distanceTransform(opening.astype(np.uint8), cv2.DIST_L2, 5)
    if float(interior[foreground].min()) < max(6*scale, 2):
        raise UnsupportedButtonIris("3D button rim is occluded by the source eyelid")

    distance = cv2.distanceTransform((~foreground).astype(np.uint8), cv2.DIST_L2, 5)
    # Glossy 3D button paint extends beyond the dark segmentation. Own the
    # first two native pixels completely, then fade only its outer bright rim.
    # The flat-art helper deliberately keeps its separate much narrower matte.
    matte = np.clip((4.5*scale-distance) / max(2.5*scale, .5), 0, 1).astype(np.float32)
    matte *= opening
    # Do not sample the bright rim into the vacant pupil: it would spread into
    # a second white disc even though the black pupil itself moves correctly.
    holes = (distance <= 6*scale) & opening
    try:
        sclera = authored_gaze._clean_sclera(base, opening, holes)
    except authored_gaze.UnsupportedAuthoredIris as error:
        raise UnsupportedButtonIris(str(error)) from error
    shading = _shading_evidence(base, opening, foreground, distance, sclera, scale)
    contours, _ = cv2.findContours(foreground.astype(np.uint8), cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
    contour = max(contours, key=cv2.contourArea).reshape(-1, 2)
    ys, xs = np.nonzero(foreground)
    limits = (min(9*scale, .18*float(np.ptp(ox))),
              min(3.5*scale, .09*float(np.ptp(oy))))
    evidence = dict(
        requested_box=list(requested), observation_margin_source_px=8,
        measured_from="enclosed-native-3d-button-sclera",
        foreground_pixels=int(foreground.sum()), aperture_pixels=int(opening.sum()),
        authored_aperture_bounds=[x, y, width, height],
        foreground_bounds=[int(xs.min()+x), int(ys.min()+y),
                           int(np.ptp(xs)+1), int(np.ptp(ys)+1)],
        authored_contour=(contour+[x, y]).astype(int).tolist(),
        dark_button_fraction=float(dark.mean()), button_to_aperture_ratio=fraction,
        rim_full_ownership_source_px=2, rim_fade_end_source_px=4.5,
        sclera_rim_exclusion_source_px=6, centre_unmodified=True,
        shape_fit="none", texture_motion="rigid-translation", **shading)
    my, mx = np.nonzero(matte > 0)
    pad_x, pad_y = int(np.ceil(limits[0]))+2, int(np.ceil(limits[1]))+2
    left, top = max(0, int(mx.min())-pad_x), max(0, int(my.min())-pad_y)
    right, bottom = min(width, int(mx.max())+pad_x+1), min(height, int(my.max())+pad_y+1)
    base, sclera = base[top:bottom, left:right].copy(), sclera[top:bottom, left:right].copy()
    opening, foreground = opening[top:bottom, left:right].copy(), foreground[top:bottom, left:right].copy()
    matte = matte[top:bottom, left:right].copy()
    x, y, width, height = x+left, y+top, right-left, bottom-top
    grid_y, grid_x = np.mgrid[:height, :width].astype(np.float32)
    return PreparedButtonIris((x, y, width, height), base, sclera, opening, matte,
                             base.astype(np.float32)*matte[..., None], grid_x, grid_y,
                             limits, foreground, evidence)


def state(prepared, dx, dy):
    """Identical native shape/paint; no radial or circular deformation."""
    if not isinstance(prepared, PreparedButtonIris):
        raise TypeError("3D button gaze requires its own prepared rim/shading policy")
    return authored_gaze.state(prepared, dx, dy)
