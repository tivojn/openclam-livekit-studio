"""Amplitude QA.

Composition quality (does the head stay put?) was already measured.  This adds
the other half: does the mouth open a PLAUSIBLE amount?  The first pass looked
correctly aligned and still wrong, because the prompts described citation-form
articulation and the model rendered someone shouting.

Aperture is measured between the inner lip centres and normalised by mouth
width, so it is scale- and crop-independent.
"""
import os
import numpy as np, cv2
from . import face, visemes

IN_UP, IN_LO, C_L, C_R = 13, 14, 61, 291
INNER_LIP = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324,
             308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
APERTURE_DETECTOR_EPSILON = 0.002


def _aperture_within_limit(ratio, maximum):
    """Allow only subpixel landmark jitter at a mouth-scale ratio."""
    return ratio <= maximum + APERTURE_DETECTOR_EPSILON


def mouth_metrics(lm):
    w = float(np.linalg.norm(lm[C_L] - lm[C_R]))
    ap = float(np.linalg.norm(lm[IN_UP] - lm[IN_LO]))
    return dict(width=w, aperture=ap, ratio=ap / w if w else 0.0)


def tongue_balance(image, lm):
    """Measure whether visible warm tongue tissue is centred in the mouth.

    It intentionally runs only as a TH-specific QA signal. Oral cavity and gum
    colours are not reliable enough to classify a tongue globally, but a
    visible TH tongue should form one small, centred warm-pink component.
    """
    if image is None or lm is None:
        return dict(visible=False, coverage=0.0, offset=0.0)
    polygon = np.rint(np.asarray(lm[INNER_LIP], np.float32)).astype(np.int32)
    mask = np.zeros(image.shape[:2], np.uint8)
    cv2.fillPoly(mask, [polygon.reshape(-1, 1, 2)], 255, lineType=cv2.LINE_AA)
    b, g, r = [channel.astype(np.float32) for channel in cv2.split(image)]
    warmth = np.maximum(0.0, r - .52 * g - .48 * b)
    chroma = np.maximum(r - g, r - b)
    weights = warmth * np.clip(chroma / 34.0, 0.0, 1.0) * (mask / 255.0)
    active = (weights > 5.0) & (mask > 0)
    area = max(1, int(np.count_nonzero(mask)))
    coverage = float(np.count_nonzero(active)) / area
    total = float(weights.sum())
    width = max(float(np.linalg.norm(lm[C_L] - lm[C_R])), 1.0)
    centre = float((lm[C_L][0] + lm[C_R][0]) * .5)
    if total <= 1e-3:
        return dict(visible=False, coverage=round(coverage, 4), offset=0.0)
    xs = np.arange(image.shape[1], dtype=np.float32)[None, :]
    centroid = float((weights * xs).sum() / total)
    return dict(
        visible=coverage >= .025,
        coverage=round(coverage, 4),
        offset=round((centroid - centre) / width, 4),
    )


def _detect(image, allow_stylized=False):
    if allow_stylized:
        landmarks, transform, _metadata = face.detect_for_intake(image)
        return landmarks, transform
    return face.detect(image)


def th_tongue_issue(path, limit=.13, allow_stylized=False):
    image = cv2.imread(path) if path and os.path.isfile(path) else None
    lm, _ = (_detect(image, allow_stylized)
             if image is not None else (None, None))
    result = tongue_balance(image, lm)
    return result if result["visible"] and abs(result["offset"]) > limit else None


def audit(keyframe_path, viseme_dir, log=None, names=None,
          allow_stylized=False):
    key = cv2.imread(keyframe_path)
    klm, _ = _detect(key, allow_stylized)
    if klm is None:
        raise ValueError("no face in keyframe")
    neutral_w = float(np.linalg.norm(klm[C_L] - klm[C_R]))

    rows, over = [], []
    for name in (names or visemes.ORDER):
        p = os.path.join(viseme_dir, f"v_{name}.jpg")
        if not os.path.exists(p):
            continue
        lm, _ = _detect(cv2.imread(p), allow_stylized)
        if lm is None:
            continue
        m = mouth_metrics(lm)
        max_ratio, want_w = visemes.TARGETS.get(name, (1.0, 1.0))
        wr = m["width"] / neutral_w if neutral_w else 1.0
        aperture_ok = _aperture_within_limit(m["ratio"], max_ratio)
        ok = aperture_ok and abs(wr - want_w) <= 0.12
        row = dict(name=name, ratio=round(m["ratio"], 3), max_ratio=max_ratio,
                   width_ratio=round(wr, 3), want_width=want_w, ok=bool(ok))
        rows.append(row)
        if not ok:
            over.append(row)
        if log:
            why = "" if ok else ("  <-- too open" if not aperture_ok
                                 else "  <-- width off")
            log(f"  {name:7s} aperture {m['ratio']:.3f} / {max_ratio:.2f}   "
                f"width {wr:.2f} / {want_w:.2f}{why}")
    return rows, over
