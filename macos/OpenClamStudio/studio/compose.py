"""Pose-lock generated frames and composite only speech-coupled regions.

Full-frame swaps create global flicker and head jitter. For photographs, the
lip and jaw core is transferred at full strength while a softly weighted
lower-face envelope carries subtle mouth-corner, chin, nasolabial-fold and
cheek motion. For stylized sources, only the registered outer-lip union is
transferred and locally colour-harmonized; the canonical face remains literal
art. Eyes and the rest of the upper face remain canonical pixels.
"""
import os, json, hashlib
import numpy as np, cv2
from . import face, rig, visemes

FEATHER = 9
LOWER_FACE_ALPHA = 0.62
NOSE_LOCK_STRENGTH = 1.0
NOSE_LOCK_FEATHER = 2.5
INNER_MOUTH = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324,
               308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
# Donor candidate lists live in rig (the profile normalizer validates donor
# overrides and cannot import compose back); these names stay as aliases.
UPPER_TEETH_DONORS = rig.UPPER_TEETH_DONORS
LOWER_TEETH_DONORS = rig.LOWER_TEETH_DONORS
TEETH_DONORS = UPPER_TEETH_DONORS
DENTAL_ROWS = rig.DENTAL_ROWS
DENTAL_DONORS = rig.DENTAL_DONORS
LOWER_MOUTH_ANCHORS = [14, 17, 84, 181, 91, 146, 314, 405, 321, 375]
TEETH_SHAPES = {"FF", "TH", "DD", "nn", "kk", "CH", "SS", "ah", "eh", "ih"}
MIN_TEETH_PIXELS = {"upper": 20, "lower": 20}


def _mouth_cavity(shape, lm):
    mask = np.zeros(shape[:2], np.uint8)
    cv2.fillPoly(mask, [lm[INNER_MOUTH].astype(np.int32)], 255)
    return mask


def _dental_band(shape, lm, cavity=None):
    """The inner-mouth polygon routinely traces the lip line THROUGH the
    teeth on open-mouth renders, leaving most of a bright dental row outside
    the cavity - undetected, unremoved, and doubled under the pasted
    canonical row (gary66 `ah`: 14732 enamel px in the mouth, 174 inside the
    polygon). Grow the search band vertically, clamped to the outer-lip hull
    so it can never wander into skin."""
    if cavity is None:
        cavity = _mouth_cavity(shape, lm)
    ys = np.nonzero(cavity.max(axis=1))[0]
    if not len(ys):
        return cavity
    reach = max(9, int(round((int(ys[-1]) - int(ys[0])) * 0.6))) | 1
    band = cv2.dilate(cavity, np.ones((reach, 3), np.uint8))
    hull = np.zeros_like(cavity)
    cv2.fillPoly(hull, [cv2.convexHull(
        lm[face.OUTER_LIP].astype(np.int32))], 255)
    return cv2.bitwise_and(band, hull)


def _row_zone(cavity, lm, row):
    if row not in DENTAL_ROWS:
        raise ValueError(f"unknown dental row: {row}")
    rows = np.indices(cavity.shape)[0]
    split = int(round(float((lm[13, 1] + lm[14, 1]) * 0.5)))
    if row == "upper":
        selected = (cavity > 0) & (rows <= split)
    else:
        selected = (cavity > 0) & (rows > split)
    return selected.astype(np.uint8) * 255


def _tooth_mask(img, cavity, lm=None, upper_only=False, row=None):
    """Segment photographic teeth only inside the requested inner-mouth row."""
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    selected = ((cavity > 0) & (hsv[..., 2] > 108) &
                (hsv[..., 1] < 105) & (lab[..., 0] > 112))
    if upper_only:
        row = "upper"
    if row is not None:
        if lm is None:
            raise ValueError("landmarks are required for dental row segmentation")
        selected &= _row_zone(cavity, lm, row) > 0
    mask = selected.astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    clean = np.zeros_like(mask)
    for index in range(1, count):
        if stats[index, cv2.CC_STAT_AREA] >= 4:
            clean[labels == index] = 255
    return clean


def _scan_tooth_donors(viseme_dir, row="upper", allow_stylized=False):
    """Detect the enamel row on every candidate frame: the election and the
    calibration panel's donor dropdown (name + detected pixels) share one
    scan instead of running face detection twice per frame."""
    if row not in DENTAL_ROWS:
        raise ValueError(f"unknown dental row: {row}")
    candidates = []
    for name in DENTAL_DONORS[row]:
        path = os.path.join(viseme_dir, f"v_{name}.jpg")
        donor = cv2.imread(path)
        if donor is None:
            continue
        donor_lm, _ = _detect_composition_face(donor, allow_stylized)
        if donor_lm is None:
            continue
        band = _dental_band(donor.shape, donor_lm)
        master = _tooth_mask(donor, band, donor_lm, row=row)
        candidates.append(
            (name, donor, donor_lm, master, int(np.count_nonzero(master))))
    return candidates


def _elect_tooth_donor(candidates, row, choice="auto"):
    """Pick the frame with the MOST complete detected row, not the first
    acceptable one: a fixed priority order elected SS's clenched, lip-shaded
    sliver as the canonical enamel while ah/eh held wide, well-lit rows.
    An explicit choice overrides the election (the owner saw the auto donor
    carry a defect - carol 2026-08-01); a choice with no detected enamel
    falls back to the election, advisory, never a veto."""
    best = None
    best_pixels = 0
    for name, donor, donor_lm, master, pixels in candidates:
        if choice != "auto" and name == choice and pixels > 0:
            return name, donor, donor_lm, master
        if pixels >= MIN_TEETH_PIXELS[row] and pixels > best_pixels:
            best = name, donor, donor_lm, master
            best_pixels = pixels
    return best


def _select_tooth_donor(viseme_dir, row="upper", choice="auto",
                        allow_stylized=False):
    return _elect_tooth_donor(
        _scan_tooth_donors(viseme_dir, row, allow_stylized), row, choice)


def _select_dental_donors(viseme_dir, profile=None, allow_stylized=False):
    profile = rig.normalize(profile)
    return {
        row: selected
        for row in DENTAL_ROWS
        if (selected := _select_tooth_donor(
            viseme_dir, row, profile[f"{row}_teeth_donor"],
            allow_stylized=allow_stylized)) is not None
    }


def _tooth_plate(master):
    return cv2.dilate(
        master, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 3)))


def _lower_row_transform(donor_lm, target_lm):
    source = np.asarray(donor_lm[LOWER_MOUTH_ANCHORS], np.float32)
    target = np.asarray(target_lm[LOWER_MOUTH_ANCHORS], np.float32)

    def translation():
        delta = (target - source).mean(axis=0)
        return np.array([[1.0, 0.0, delta[0]],
                         [0.0, 1.0, delta[1]]], np.float32)

    if (not np.isfinite(source).all() or not np.isfinite(target).all() or
            float(np.linalg.norm(source - source.mean(axis=0), axis=1).max()) < 1.0):
        return translation()
    transform, _ = cv2.estimateAffinePartial2D(
        source, target, method=cv2.LMEDS)
    if transform is None or not np.isfinite(transform).all():
        return translation()
    scale = float(np.hypot(transform[0, 0], transform[1, 0]))
    if not 0.78 <= scale <= 1.28:
        return translation()
    return transform.astype(np.float32)


def _row_assets(donor, donor_lm, master, target_lm, row):
    if row == "upper":
        return donor, master, _tooth_plate(master)
    transform = _lower_row_transform(donor_lm, target_lm)
    height, width = master.shape
    donor_frame = cv2.warpAffine(
        donor, transform, (width, height), flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_REPLICATE)
    transformed = cv2.warpAffine(
        master, transform, (width, height), flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return donor_frame, transformed, _tooth_plate(transformed)


def canonicalize_teeth(viseme_dir, diag_dir=None, log=print, selected=None,
                       profile=None, allow_stylized=False):
    """Lock skull-attached upper teeth and jaw-attached lower teeth."""
    profile = rig.normalize(profile)
    strength = profile["teeth"] / 100.0
    if strength <= 0.0:
        log("  dental lock released: strength 0, every frame keeps its own teeth")
        return []
    if selected is None:
        selected = _select_dental_donors(
            viseme_dir, profile, allow_stylized=allow_stylized)
    if not selected:
        log("  dental lock skipped: no canonical dental rows found")
        return []
    missing = [row for row in DENTAL_ROWS if row not in selected]
    if missing:
        log(f"  dental lock warning: no canonical {', '.join(missing)} row found")
    for row, values in selected.items():
        choice = profile[f"{row}_teeth_donor"]
        if choice != "auto" and values[0] != choice:
            log(f"  ADVISORY {row} donor override {choice} has no detected "
                f"enamel - auto election {values[0]} used instead")
    donor_summary = ", ".join(
        f"{row} {values[0]} ({np.count_nonzero(values[3])}px)"
        for row, values in selected.items())
    if strength < 1.0:
        donor_summary += f" at {profile['teeth']:.0f}% strength"
    log(f"  dental lock donors: {donor_summary}")
    dental_diag_dir = None
    if diag_dir:
        dental_diag_dir = os.path.join(diag_dir, "dental")
        os.makedirs(dental_diag_dir, exist_ok=True)
        for index, (row, values) in enumerate(selected.items()):
            master = values[3]
            cv2.imwrite(
                os.path.join(diag_dir, f"{4 + index * 2:02d}_teeth_{row}_master.png"),
                master)
            cv2.imwrite(
                os.path.join(diag_dir, f"{5 + index * 2:02d}_teeth_{row}_plate.png"),
                _tooth_plate(master))

    report = []
    for name in visemes.ORDER:
        if name not in TEETH_SHAPES:
            continue
        path = os.path.join(viseme_dir, f"v_{name}.jpg")
        img = cv2.imread(path)
        if img is None:
            continue
        lm, _ = _detect_composition_face(img, allow_stylized)
        if lm is None:
            continue
        cavity = _mouth_cavity(img.shape, lm)
        band = _dental_band(img.shape, lm, cavity)
        rows = {}
        remove = np.zeros(cavity.shape, np.uint8)
        for row, values in selected.items():
            donor_name, donor, donor_lm, master = values
            donor_frame, canonical, plate = _row_assets(
                donor, donor_lm, master, lm, row)
            zone = _row_zone(band, lm, row)
            generated = _tooth_mask(img, band, lm, row=row)
            replace = name != donor_name
            if replace:
                row_remove = cv2.bitwise_and(
                    cv2.dilate(generated, np.ones((3, 3), np.uint8)), zone)
                remove = cv2.bitwise_or(remove, row_remove)
            rows[row] = dict(
                donor=donor_name, donor_frame=donor_frame,
                canonical=canonical, plate=plate, zone=zone,
                generated=generated, replace=replace)

        if np.any(remove):
            work = cv2.inpaint(img, remove, 2.0, cv2.INPAINT_TELEA).astype(np.float32)
        else:
            work = img.astype(np.float32)
        cavity_inner = cv2.erode(band, np.ones((2, 2), np.uint8))
        details = {}
        for row, values in rows.items():
            reveal = cv2.bitwise_and(values["plate"], cavity_inner)
            reveal = cv2.bitwise_and(reveal, values["zone"])
            enamel = cv2.bitwise_and(values["canonical"], cavity_inner)
            enamel = cv2.bitwise_and(enamel, values["zone"])
            if dental_diag_dir:
                reference = np.zeros_like(img)
                reference[enamel > 0] = values["donor_frame"][enamel > 0]
                cv2.imwrite(os.path.join(
                    dental_diag_dir, f"{row}_{name}_mask.png"), enamel)
                cv2.imwrite(os.path.join(
                    dental_diag_dir, f"{row}_{name}_zone.png"), values["zone"])
                cv2.imwrite(os.path.join(
                    dental_diag_dir, f"{row}_{name}_reference.png"), reference)
            if values["replace"]:
                reveal_alpha = cv2.GaussianBlur(
                    reveal, (0, 0), .55).astype(np.float32) / 255.0
                soft_zone = cv2.GaussianBlur(
                    values["zone"], (0, 0), .45).astype(np.float32) / 255.0
                reveal_alpha *= soft_zone
                reveal_alpha[enamel > 0] = 1.0
                work = (work * (1 - reveal_alpha[..., None]) +
                        values["donor_frame"].astype(np.float32) *
                        reveal_alpha[..., None])
            details[row] = dict(
                donor=values["donor"],
                removed=(int(np.count_nonzero(values["generated"]))
                         if values["replace"] else 0),
                revealed=int(np.count_nonzero(enamel)),
            )
        # Partial lock: a literal lerp toward the frame's own render. Only
        # the dental band differs between img and work, so the whole-frame
        # blend is regional by construction; 100 keeps today's exact bytes.
        if strength < 1.0:
            work = img.astype(np.float32) * (1.0 - strength) + work * strength
        cv2.imwrite(path, np.clip(work, 0, 255).astype(np.uint8),
                    [cv2.IMWRITE_JPEG_QUALITY, 95])
        report.append(dict(name=name, rows=details))
        detail = "   ".join(
            f"{row} removed {values['removed']:4d}px / revealed {values['revealed']:4d}px"
            for row, values in details.items())
        log(f"  {name:7s} {detail}")
    return report


def soften_oral_shadows(viseme_dir, log=print, allow_stylized=False):
    """Soften near-black cavity pixels and ink-like inner-lip contours."""
    report = []
    cavity_target = np.array([52.0, 58.0, 98.0], np.float32)
    contour_target = np.array([72.0, 78.0, 128.0], np.float32)
    kernel = np.ones((5, 5), np.uint8)
    for name in visemes.ORDER:
        if name in visemes.EYE_SHAPES:
            continue
        path = os.path.join(viseme_dir, f"v_{name}.jpg")
        img = cv2.imread(path)
        if img is None:
            continue
        lm, _ = _detect_composition_face(img, allow_stylized)
        if lm is None:
            continue
        cavity = _mouth_cavity(img.shape, lm)
        dental = _tooth_mask(img, cavity)
        value = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)[..., 2].astype(np.float32)
        darkness = np.clip((105.0 - value) / 105.0, 0.0, 1.0)
        region = cv2.GaussianBlur(cavity, (0, 0), .65).astype(np.float32) / 255.0
        alpha = .84 * np.power(darkness, 1.35) * region
        work = (img.astype(np.float32) * (1.0 - alpha[..., None]) +
                cavity_target[None, None, :] * alpha[..., None])

        contour = cv2.subtract(cv2.dilate(cavity, kernel),
                               cv2.erode(cavity, kernel))
        contour = cv2.GaussianBlur(contour, (0, 0), .7).astype(np.float32) / 255.0
        work_value = cv2.cvtColor(np.clip(work, 0, 255).astype(np.uint8),
                                  cv2.COLOR_BGR2HSV)[..., 2].astype(np.float32)
        contour_darkness = np.clip((115.0 - work_value) / 115.0, 0.0, 1.0)
        contour_alpha = .45 * np.power(contour_darkness, 1.2) * contour
        work = (work * (1.0 - contour_alpha[..., None]) +
                contour_target[None, None, :] * contour_alpha[..., None])
        work = np.clip(work, 0, 255).astype(np.uint8)
        work[dental > 0] = img[dental > 0]

        before = int(np.percentile(value[cavity > 0], 5))
        after_value = cv2.cvtColor(work, cv2.COLOR_BGR2HSV)[..., 2]
        after = int(np.percentile(after_value[cavity > 0], 5))
        cv2.imwrite(path, work, [cv2.IMWRITE_JPEG_QUALITY, 95])
        report.append(dict(name=name, shadow_p05_before=before,
                           shadow_p05_after=after))
        log(f"  {name:7s} oral shadow p05 {before:3d} -> {after:3d}")
    return report


def _regional_mask(key, landmarks, groups, dilate, face_mask, eye_guard):
    mask = np.zeros(key.shape[:2], np.uint8)
    for group in groups:
        mask = cv2.bitwise_or(
            mask, face.hull_mask(key.shape, landmarks, group, dilate=dilate))
    mask = cv2.bitwise_and(mask, face_mask)
    return cv2.bitwise_and(mask, cv2.bitwise_not(eye_guard))


def _masks(key, klm, profile=None):
    profile = rig.normalize(profile)
    height, width = key.shape[:2]
    scale = max(height, width) / 1024.0
    face_mask = face.hull_mask(key.shape, klm, face.FACE_OVAL)
    face_mask = cv2.erode(face_mask, cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (int(23 * scale) | 1, int(23 * scale) | 1)))
    eye_guard = face.hull_mask(
        key.shape, klm, face.EYE_L + face.EYE_R,
        dilate=int(41 * scale) | 1)

    lip_core = _regional_mask(
        key, klm, [face.OUTER_LIP], int(31 * scale) | 1,
        face_mask, eye_guard)
    regions = {
        "jaw": _regional_mask(
            key, klm, [face.JAW_REGION], int(17 * scale) | 1,
            face_mask, eye_guard),
        "cheeks": _regional_mask(
            key, klm, [face.CHEEK_L, face.CHEEK_R],
            int(19 * scale) | 1, face_mask, eye_guard),
        "nasolabial": _regional_mask(
            key, klm, [face.NASOLABIAL_L, face.NASOLABIAL_R],
            int(13 * scale) | 1, face_mask, eye_guard),
    }
    support = np.zeros((height, width), np.uint8)
    for region in regions.values():
        support = cv2.bitwise_or(support, region)
    nose_core = face.hull_mask(
        key.shape, klm, face.NOSE_CORE, dilate=int(5 * scale) | 1)
    nose_base = face.hull_mask(
        key.shape, klm, face.NOSE_BASE, dilate=int(7 * scale) | 1)
    mouth = dict(kind="mouth", core=lip_core, regions=regions,
                 support=support, nose_core=nose_core,
                 nose_base=nose_base, profile=profile)

    eyes = np.zeros((height, width), np.uint8)
    for indices in (face.EYE_L + face.BROW_L,
                    face.EYE_R + face.BROW_R):
        eyes = cv2.bitwise_or(
            eyes, face.hull_mask(key.shape, klm, indices,
                                 dilate=int(21 * scale) | 1))
    eyes = cv2.bitwise_and(eyes, face_mask)
    return dict(mouth=mouth, eyes=eyes), face_mask


def _alpha_ring(mask, face_m, scale, profile=None):
    sigma = FEATHER * scale
    if isinstance(mask, dict) and mask.get("kind") == "mouth":
        profile = rig.normalize(profile or mask.get("profile"))
        core_alpha = cv2.GaussianBlur(
            mask["core"], (0, 0), sigma).astype(np.float32) / 255.0
        alpha = core_alpha * (profile["lips"] / 100.0)
        for name, region in mask["regions"].items():
            region_alpha = cv2.GaussianBlur(
                region, (0, 0), sigma * 1.35).astype(np.float32) / 255.0
            alpha = np.maximum(
                alpha, region_alpha * (profile[name] / 100.0))
        nose_base = cv2.GaussianBlur(
            mask["nose_base"], (0, 0), NOSE_LOCK_FEATHER * scale
        ).astype(np.float32) / 255.0
        nose_cap = profile["nose"] / 100.0
        alpha = (alpha * (1.0 - nose_base) +
                 np.minimum(alpha, nose_cap) * nose_base)
        alpha[mask["nose_base"] > 0] = np.minimum(
            alpha[mask["nose_base"] > 0], nose_cap)
        nose_core = cv2.GaussianBlur(
            mask["nose_core"], (0, 0), NOSE_LOCK_FEATHER * scale
        ).astype(np.float32) / 255.0
        alpha *= 1.0 - nose_core
        alpha[mask["nose_core"] > 0] = 0.0
        ring_base = mask["support"]
    elif isinstance(mask, tuple):
        core, support, nose_guard = mask
        core_alpha = cv2.GaussianBlur(
            core, (0, 0), sigma).astype(np.float32) / 255.0
        support_alpha = cv2.GaussianBlur(
            support, (0, 0), sigma * 1.35).astype(np.float32) / 255.0
        alpha = np.maximum(core_alpha, support_alpha * LOWER_FACE_ALPHA)
        nose_lock = cv2.GaussianBlur(
            nose_guard, (0, 0), NOSE_LOCK_FEATHER * scale
        ).astype(np.float32) / 255.0
        alpha *= 1.0 - NOSE_LOCK_STRENGTH * nose_lock
        ring_base = support
    else:
        alpha = cv2.GaussianBlur(
            mask, (0, 0), sigma).astype(np.float32) / 255.0
        ring_base = mask
    alpha = np.clip(alpha, 0.0, 1.0)
    k1 = np.ones((int(35 * scale) | 1,) * 2, np.uint8)
    k2 = np.ones((int(9 * scale) | 1,) * 2, np.uint8)
    ring = cv2.bitwise_and(
        cv2.dilate(ring_base, k1),
        cv2.bitwise_not(cv2.dilate(ring_base, k2))) > 0
    ring = np.logical_and(ring, face_m > 0)
    return alpha, ring


def _stylized_mouth_registration(key, donor, key_landmarks, source_landmarks,
                                  landmark_transform):
    """Prefer a proven rigid pixel fit when a cartoon mesh invents face tilt.

    Large drawn eyes can move the human detector's cheek/nose anchors between
    otherwise pixel-aligned plates. Fitting an affine to those anchors then
    rotates a clean authored mouth and pulls a second nose into its mask. This
    optional refinement sees only the unchanged upper image, never the moving
    lips, and cannot shear or scale artwork. A high correlation AND a material
    improvement on upper-face edge pixels are required; ambiguous inputs keep
    their existing registration. Photographs and eye plates never call it.
    """
    diagnostics = {"method": "landmarks"}
    if key.shape != donor.shape or key.ndim != 3:
        return landmark_transform, diagnostics
    height, width = key.shape[:2]
    canonical = np.asarray(key_landmarks, np.float32)[face.OUTER_LIP]
    generated = np.asarray(source_landmarks, np.float32)[face.OUTER_LIP]
    if not np.isfinite(canonical).all() or not np.isfinite(generated).all():
        return landmark_transform, diagnostics
    mouth_width = max(float(np.ptp(canonical[:, 0])),
                      float(np.ptp(generated[:, 0])), 4.0)
    cutoff = min(float(canonical[:, 1].min()),
                 float(generated[:, 1].min())) - mouth_width * 0.15
    sample_scale = min(1.0, 512.0 / max(height, width))
    sample_size = (max(1, int(round(width * sample_scale))),
                   max(1, int(round(height * sample_scale))))
    top = min(sample_size[1], int(cutoff * sample_scale))
    if top < 32 or sample_size[0] < 32:
        return landmark_transform, diagnostics
    key_gray = cv2.resize(cv2.cvtColor(key, cv2.COLOR_BGR2GRAY), sample_size,
                          interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    donor_gray = cv2.resize(cv2.cvtColor(donor, cv2.COLOR_BGR2GRAY), sample_size,
                            interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    input_mask = np.zeros(key_gray.shape, np.uint8)
    input_mask[2:top, 2:-2] = 255
    gradient_x = cv2.Sobel(key_gray, cv2.CV_32F, 1, 0, ksize=3)
    gradient_y = cv2.Sobel(key_gray, cv2.CV_32F, 0, 1, ksize=3)
    edges = ((input_mask > 0)
             & (gradient_x * gradient_x + gradient_y * gradient_y > 0.04))
    if np.count_nonzero(edges) < max(64, int(input_mask.size * 0.002)):
        return landmark_transform, diagnostics

    try:
        correlation, inverse = cv2.findTransformECC(
            key_gray, donor_gray, np.eye(2, 3, dtype=np.float32),
            cv2.MOTION_EUCLIDEAN,
            (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 100, 1e-6),
            input_mask, 5)
    except cv2.error:
        return landmark_transform, diagnostics
    if (not np.isfinite(correlation) or correlation < 0.97
            or not np.isfinite(inverse).all()):
        return landmark_transform, diagnostics
    fitted = cv2.invertAffineTransform(inverse).astype(np.float32)
    angle = float(np.degrees(np.arctan2(fitted[1, 0], fitted[0, 0])))
    translation = float(np.linalg.norm(fitted[:, 2])) / sample_scale
    if abs(angle) > 8.0 or translation > max(height, width) * 0.04:
        return landmark_transform, diagnostics

    legacy = np.asarray(landmark_transform, np.float32).copy()
    if legacy.shape != (2, 3) or not np.isfinite(legacy).all():
        return landmark_transform, diagnostics
    legacy[:, 2] *= sample_scale

    def edge_error(transform):
        registered = cv2.warpAffine(
            donor_gray, transform, sample_size, flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_REPLICATE)
        return float(np.mean(np.abs(registered[edges] - key_gray[edges]))) * 255.0

    legacy_error = edge_error(legacy)
    fitted_error = edge_error(fitted)
    if fitted_error > legacy_error * 0.8 or legacy_error - fitted_error < 1.0:
        return landmark_transform, diagnostics
    fitted[:, 2] /= sample_scale
    diagnostics = {
        "method": "stylized-upper-face-rigid-pixels-v1",
        "correlation": round(float(correlation), 7),
        "landmark_edge_mae": round(legacy_error, 4),
        "registered_edge_mae": round(fitted_error, 4),
        "rotation_degrees": round(angle, 5),
    }
    return fitted, diagnostics


def _registration_pixel_sha256(image):
    return hashlib.sha256(np.ascontiguousarray(image).tobytes()).hexdigest()


def _registration_file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _seal_stylized_registration(key, keyframe_path, processed_path, registration):
    """Bind successful pixel registration to the exact resulting JPEG bank.

    The normal build already retains each registration record in its manifest.
    A later expression export must not re-centre these canonical plates using
    the same human lip detector which misregistered the cartoon in the first
    place. Hash both files and their decoded pixels: a stale report or a newly
    encoded/replaced plate is not evidence of canonical registration.
    """
    if registration.get("method") != "stylized-upper-face-rigid-pixels-v1":
        return
    decoded = cv2.imread(processed_path)
    if decoded is None or decoded.shape != key.shape:
        return
    registration["canonical_pixel_registration"] = {
        "v": 1, "shape": list(key.shape),
        "canonical_file_sha256": _registration_file_sha256(keyframe_path),
        "canonical_bgr_sha256": _registration_pixel_sha256(key),
        "processed_file_sha256": _registration_file_sha256(processed_path),
        "processed_bgr_sha256": _registration_pixel_sha256(decoded),
    }


def canonical_mouth_registration_matches(key, image, registration, *,
                                         keyframe_path=None, processed_path=None):
    """Verify an upstream pixel-registration seal; unproven banks stay legacy."""
    if (not isinstance(registration, dict)
            or registration.get("method") != "stylized-upper-face-rigid-pixels-v1"):
        return False
    seal = registration.get("canonical_pixel_registration")
    if (not isinstance(seal, dict) or type(seal.get("v")) is not int
            or seal["v"] != 1 or not isinstance(seal.get("shape"), list)
            or len(seal["shape"]) != 3
            or any(type(value) is not int for value in seal["shape"])
            or not isinstance(key, np.ndarray) or not isinstance(image, np.ndarray)
            or key.dtype != np.uint8 or image.dtype != np.uint8
            or key.ndim != 3 or key.shape[2] != 3
            or key.shape != image.shape or seal["shape"] != list(key.shape)):
        return False
    measured = [registration.get(name) for name in (
        "correlation", "landmark_edge_mae", "registered_edge_mae", "rotation_degrees")]
    if any(type(value) not in (int, float) or not np.isfinite(value)
           for value in measured):
        return False
    correlation, legacy_error, fitted_error, angle = measured
    if (not 0.97 <= correlation <= 1.000001 or abs(angle) > 8.0
            or fitted_error < 0 or fitted_error > legacy_error * 0.8
            or legacy_error - fitted_error < 1.0):
        return False
    if (seal.get("canonical_bgr_sha256") != _registration_pixel_sha256(key)
            or seal.get("processed_bgr_sha256") != _registration_pixel_sha256(image)):
        return False
    if keyframe_path is not None or processed_path is not None:
        if keyframe_path is None or processed_path is None:
            return False
        try:
            return (seal.get("canonical_file_sha256") == _registration_file_sha256(keyframe_path)
                    and seal.get("processed_file_sha256") == _registration_file_sha256(processed_path))
        except (OSError, TypeError, ValueError):
            return False
    return True


def _stylized_mouth_alpha(shape, key_landmarks, source_landmarks, transform):
    """Return a tight, registered lip transfer for illustrated faces.

    Photographic mouths need some cheek/jaw coupling to remain anatomical, but
    applying that broad skin envelope to rendered artwork transfers a second
    colour grade and texture over the canonical face.  The web/iOS stylized
    renderers already use the canonical head as their immutable identity
    plate, so their viseme asset should contain only the union of the canonical
    and provider-authored outer lips plus a small antialiased margin.
    """
    height, width = shape[:2]
    canonical = np.asarray(key_landmarks, np.float32)[face.OUTER_LIP]
    generated = np.asarray(source_landmarks, np.float32)[face.OUTER_LIP]
    projected = ((np.asarray(transform, np.float32)[:, :2]
                  @ generated.T).T
                 + np.asarray(transform, np.float32)[:, 2])
    points = np.vstack((canonical, projected))
    finite = points[np.isfinite(points).all(axis=1)]
    if len(finite) < 3:
        return np.zeros((height, width), np.float32)
    mouth_width = max(
        4.0,
        float(np.ptp(canonical[:, 0])),
        float(np.ptp(projected[:, 0])),
    )
    core = np.zeros((height, width), np.uint8)
    cv2.fillConvexPoly(
        core, cv2.convexHull(np.round(finite).astype(np.int32)), 255)
    # Human lip landmarks can sit slightly inside/below authored cartoon lines.
    # The margin must own those old corners fully, not just feather them: a
    # partially covered rest-mouth line becomes a detached stroke beside a
    # smaller viseme. Keep the smooth skin transition OUTSIDE this bounded
    # eight-percent ownership margin, not through the lip art itself.
    margin = max(2, int(round(mouth_width * 0.08)))
    kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (margin * 2 + 1, margin * 2 + 1))
    support = cv2.dilate(core, kernel)
    distance = cv2.distanceTransform(
        (support == 0).astype(np.uint8), cv2.DIST_L2, 5)
    feather = max(2.4, mouth_width * 0.075)
    progress = np.clip(distance / feather, 0.0, 1.0)
    alpha = 1.0 - progress * progress * (3.0 - 2.0 * progress)
    return np.clip(alpha, 0.0, 1.0)


def _stylized_patch_harmonize(key, donor, alpha):
    """Match local low-frequency colour while preserving authored mouth art.

    A provider can keep the correct character yet return a slightly warmer or
    smoother frame.  A single global RGB offset does not follow the face's
    shaded gradient and leaves a visible oval patch.  Matching only the broad
    low-frequency field retains the donor's lip lines, teeth, tongue and oral
    interior while making its surrounding skin converge on the canonical art.
    """
    support = alpha > 0.02
    points = cv2.findNonZero(support.astype(np.uint8))
    if points is None:
        return donor.astype(np.float32)
    _x, _y, width, _height = cv2.boundingRect(points)
    sigma = max(4.0, float(width) * 0.42)
    canonical_low = cv2.GaussianBlur(
        key.astype(np.float32), (0, 0), sigma)
    donor_low = cv2.GaussianBlur(
        donor.astype(np.float32), (0, 0), sigma)
    correction = np.clip(canonical_low - donor_low, -48.0, 48.0)
    return np.clip(donor.astype(np.float32) + correction, 0.0, 255.0)


def _finish_viseme_bank(viseme_dir, diag_dir, log, profile,
                        allow_stylized=False):
    """Apply photographic dental/shadow correction only to photographs.

    The tooth detector and warm-cavity targets are explicitly photographic.
    Running them over a cartoon elects fragments from unrelated mouth shapes,
    inpaints line art, and pastes those fragments back into every viseme.  The
    stylized generation contract already locks the character's dental design;
    keep those authored pixels intact.
    """
    if allow_stylized:
        log("  stylized mouth plates preserved: no photographic dental or "
            "oral-shadow rewrite")
        return [], []
    dental_donors = _select_dental_donors(
        viseme_dir, profile, allow_stylized=False)
    oral_shadows = soften_oral_shadows(
        viseme_dir, log, allow_stylized=False)
    teeth = canonicalize_teeth(
        viseme_dir, diag_dir, log, selected=dental_donors, profile=profile,
        allow_stylized=False)
    return oral_shadows, teeth


def _detect_composition_face(image, allow_stylized=False):
    """Return a production mesh, with an explicit cartoon-only fallback.

    The permissive path is still topology-gated by ``detect_for_intake`` and
    must be opted into by a build whose source medium was already classified
    as non-photographic.  Photo builds therefore keep the original strict
    production detector.
    """
    if allow_stylized:
        landmarks, transform, _metadata = face.detect_for_intake(image)
        return landmarks, transform
    return face.detect(image)


def compose_all(keyframe_path, raw_dir, out_dir, diag_dir=None, log=print,
                profile=None, allow_stylized=False):
    key = cv2.imread(keyframe_path)
    H, W = key.shape[:2]
    scale = max(H, W) / 1024.0
    klm, kM = _detect_composition_face(key, allow_stylized)
    if klm is None:
        raise ValueError("no face in keyframe")
    kmet = face.metrics(klm, kM)

    profile = rig.normalize(profile)
    masks, face_m = _masks(key, klm, profile)
    prepared = {
        name: _alpha_ring(mask, face_m, scale, profile)
        for name, mask in masks.items()
    }
    os.makedirs(out_dir, exist_ok=True)
    if diag_dir:
        os.makedirs(diag_dir, exist_ok=True)
        # The stylized mask is registered per generated plate below.  Writing
        # the broad photographic envelope here made diagnostics claim that
        # cheeks/jaw were still transferred even after the stylized fix.
        if not allow_stylized:
            cv2.imwrite(os.path.join(diag_dir, "02_mask_mouth.png"),
                        (prepared["mouth"][0] * 255).astype(np.uint8))
        cv2.imwrite(os.path.join(diag_dir, "03_mask_eyes.png"),
                    (prepared["eyes"][0] * 255).astype(np.uint8))
        for name, region in masks["mouth"]["regions"].items():
            cv2.imwrite(os.path.join(diag_dir, f"02_mask_{name}.png"), region)

    kl = key.astype(np.float32)
    report = []
    for name in visemes.ORDER:
        src_path = os.path.join(raw_dir, f"v_{name}.png")
        if not os.path.exists(src_path):
            src_path = os.path.join(raw_dir, f"v_{name}.jpg")
        if not os.path.exists(src_path):
            log(f"  {name}: raw render missing, skipped")
            continue
        src = cv2.imread(src_path)
        if src.shape[:2] != (H, W):
            src = cv2.resize(src, (W, H), interpolation=cv2.INTER_LANCZOS4)
        slm, sM = _detect_composition_face(src, allow_stylized)
        if slm is None:
            log(f"  {name}: no face in render, skipped")
            continue

        M, _ = cv2.estimateAffine2D(slm[face.RIGID], klm[face.RIGID],
                                    method=cv2.LMEDS, refineIters=50)
        if M is None:
            M = cv2.estimateAffinePartial2D(slm[face.RIGID], klm[face.RIGID])[0]
        registration = None
        if allow_stylized and name not in visemes.EYE_SHAPES:
            M, registration = _stylized_mouth_registration(
                key, src, klm, slm, M)
        warped = cv2.warpAffine(src, M, (W, H), flags=cv2.INTER_LANCZOS4,
                                borderMode=cv2.BORDER_REPLICATE)
        proj = (M[:, :2] @ slm[face.RIGID].T).T + M[:, 2]
        resid = float(np.linalg.norm(proj - klm[face.RIGID], axis=1).mean())

        wl = warped.astype(np.float32)
        if allow_stylized and name not in visemes.EYE_SHAPES:
            alpha = _stylized_mouth_alpha(
                key.shape, klm, slm, M)
            if diag_dir and name in {"closed", "ah"}:
                cv2.imwrite(
                    os.path.join(
                        diag_dir, f"02_mask_mouth_stylized_{name}.png"),
                    np.round(alpha * 255.0).astype(np.uint8))
            # Keep the legacy report useful: measure the surrounding canonical
            # difference even though the stylized compositor now performs a
            # spatial low-frequency match rather than applying this scalar.
            hard = (alpha > 0.08).astype(np.uint8) * 255
            outer = cv2.dilate(
                hard, cv2.getStructuringElement(
                    cv2.MORPH_ELLIPSE, (17, 17)))
            ring = (outer > 0) & (hard == 0) & (face_m > 0)
            off = (kl[ring].mean(axis=0) - wl[ring].mean(axis=0)
                   if np.any(ring) else np.zeros(3, np.float32))
            wl = _stylized_patch_harmonize(kl, wl, alpha)
        else:
            alpha, ring = prepared[
                "eyes" if name in visemes.EYE_SHAPES else "mouth"]
            off = kl[ring].mean(axis=0) - wl[ring].mean(axis=0)
            wl = np.clip(wl + off, 0, 255)
        out = (kl * (1 - alpha[..., None]) + wl * alpha[..., None]).astype(np.uint8)
        processed_path = os.path.join(out_dir, f"v_{name}.jpg")
        cv2.imwrite(processed_path, out, [cv2.IMWRITE_JPEG_QUALITY, 95])
        if registration is not None:
            _seal_stylized_registration(
                key, keyframe_path, processed_path, registration)

        d = np.abs(out.astype(np.float32) - kl).mean(axis=2)
        outside = float(d[alpha < 0.02].mean())
        olm, _ = _detect_composition_face(out, allow_stylized)
        fs = float(face.foreshortening(olm)) if olm is not None else None
        report.append(dict(name=name, resid_px=round(resid, 2),
                           outside_delta=round(outside, 4),
                           foreshortening=None if fs is None else round(fs, 3),
                           tone_shift=[round(float(v), 1) for v in off]))
        if registration is not None:
            report[-1]["registration"] = registration
        log(f"  {name:7s} rigid residual {resid:5.2f}px   off-region delta {outside:.4f}"
            + (f"   foreshortening {fs:.2f}" if fs else ""))

    oral_shadows, teeth = _finish_viseme_bank(
        out_dir, diag_dir, log, profile,
        allow_stylized=allow_stylized)
    if diag_dir:
        json.dump(dict(keyframe=kmet, visemes=report, teeth=teeth,
                       oral_shadows=oral_shadows, rig_profile=profile),
                  open(os.path.join(diag_dir, "compose.json"), "w"), indent=1)
    return report, kmet
