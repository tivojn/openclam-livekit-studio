"""Local portrait cut-out through macOS Vision.

The runtime keeps JPEG viseme plates for compactness and ships one RGBA mask.
Every viseme was pose-locked to the same keyframe, so that single mask can clip
all mouth poses without producing a halo that changes while the avatar speaks.
"""
import os
import subprocess

import cv2
import numpy as np


CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class AmbiguousStylizedPlateError(RuntimeError):
    """An enclosed cartoon plate-colour slit cannot safely be erased."""

    def __init__(self, components):
        self.components = components
        locations = ", ".join(str(item["bounds"]) for item in components)
        super().__init__(
            "ambiguous enclosed white silhouette slit at " + locations
            + "; pixels were preserved, not erased. Regenerate this view with "
            "loose hair curls/strands separated from the silhouette: every "
            "background gap must remain visibly open to the exterior plate. "
            "Preserve the character's eyes, teeth, clothing and identity.")


def helper_path():
    configured = os.environ.get("OPENCLAM_CUTOUT_HELPER")
    candidates = [
        configured,
        os.path.join(CODE_ROOT, ".electron-native", "person-cutout"),
        os.path.join(CODE_ROOT, "native", "person-cutout"),
    ]
    return next((path for path in candidates if path and os.access(path, os.X_OK)), None)


def _decontaminate_edges(image):
    alpha = image[:, :, 3]
    kernel = np.ones((3, 3), np.uint8)
    foreground = alpha > 8
    core = cv2.erode((alpha > 96).astype("uint8"), kernel, iterations=3).astype(bool)
    filled = core.copy()
    colors = image[:, :, :3].astype("float32")
    propagated = np.zeros_like(colors)
    propagated[core] = colors[core]
    for _step in range(16):
        weights = cv2.boxFilter(filled.astype("float32"), -1, (3, 3), normalize=False)
        new = (~filled) & (weights > 0)
        if not np.any(new):
            break
        for channel in range(3):
            total = cv2.boxFilter(
                propagated[:, :, channel] * filled, -1, (3, 3), normalize=False)
            propagated[:, :, channel][new] = total[new] / weights[new]
        filled[new] = True
    contaminated = foreground & (alpha < 246)
    replace = contaminated & filled
    image[:, :, :3][replace] = np.clip(propagated[replace], 0, 255).astype("uint8")
    return image


def _border_mask(height, width):
    """The narrow outside band used to prove a deliberately flat plate."""
    band = max(2, min(12, round(min(height, width) * 0.015)))
    mask = np.zeros((height, width), np.uint8)
    mask[:band, :] = 1
    mask[-band:, :] = 1
    mask[:, :band] = 1
    mask[:, -band:] = 1
    return mask.astype(bool)


def _flat_plate_model(image):
    """Return a trusted border colour for a white/neutral/green studio plate.

    This is deliberately unavailable to ordinary photographs.  Callers must
    opt in after source-medium classification; even then a real, uniform,
    border-supported plate is required before any pixel is made transparent.
    """
    height, width = image.shape[:2]
    if min(height, width) < 16:
        return None
    border = image[_border_mask(height, width)].astype(np.int16)
    low = border.min(axis=1)
    high = border.max(axis=1)
    chroma = high - low

    white_seed = (low >= 225) & (chroma <= 24)
    white_support = float(((low >= 238) & (chroma <= 16)).mean())
    if white_support >= 0.52 and int(white_seed.sum()) >= 32:
        colour = np.median(border[white_seed], axis=0).astype(np.float32)
        return "white", colour, white_support

    # Canonical stylized heads are sometimes normalized onto a deliberately
    # light neutral-gray plate rather than RGB-255 white. This path remains
    # opt-in and requires much stronger border uniformity than the white plate
    # so an ordinary bright photograph can never qualify by accident.
    # Soft-3D generators also use a deliberately uniform medium-light gray
    # studio plate (the retained Luffy head measures BGR 203--210 around the
    # complete border).  Keep this branch stylized-only and demand nearly the
    # whole border be neutral, but do not require that neutral to be close to
    # paper white.  Ordinary photographs never reach this opt-in extractor.
    neutral_seed = (low >= 195) & (chroma <= 12)
    neutral_support = float(((low >= 200) & (chroma <= 8)).mean())
    neutral_range = float(np.percentile(low, 99) - np.percentile(low, 1))
    if (neutral_support >= 0.90 and neutral_range <= 12.0
            and int(neutral_seed.sum()) >= 32):
        colour = np.median(border[neutral_seed], axis=0).astype(np.float32)
        return "light-neutral", colour, neutral_support

    blue, green, red = (border[:, index] for index in range(3))
    green_seed = (
        (green >= 105)
        & (green - red >= 28)
        & (green - blue >= 28)
    )
    green_support = float(green_seed.mean())
    if green_support >= 0.52 and int(green_seed.sum()) >= 32:
        colour = np.median(border[green_seed], axis=0).astype(np.float32)
        return "green", colour, green_support
    return None


def _border_connected(mask):
    """Keep only candidate background that is connected to the image edge."""
    count, labels = cv2.connectedComponents(mask.astype(np.uint8), connectivity=8)
    if count <= 1:
        return np.zeros_like(mask, dtype=bool)
    edge_labels = np.unique(np.concatenate((
        labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1],
    )))
    edge_labels = edge_labels[edge_labels > 0]
    if edge_labels.size == 0:
        return np.zeros_like(mask, dtype=bool)
    return np.isin(labels, edge_labels)


def _enclosed_white_silhouette_slits(image, distance, core, core_limit):
    """Find ambiguous near-exterior hair slits on an explicit body plate.

    This is a *rejection* diagnostic, never a matte repair.  A white hair gap
    and authored white detail can have identical pixels.  In particular, the
    body alpha gate's upper-face exemption must not silently certify a long
    white crescent enclosed by a loose hair strand.  Restrict the diagnostic
    to slender, plate-coloured upper-silhouette islands; retain compact
    highlights, pupil-bearing sclera, shaded white surfaces and lower-body
    clothing without guessing at their alpha.
    """
    height, width = image.shape[:2]
    extent = min(height, width)
    subject = (~core) & (distance > 96.0)
    points = cv2.findNonZero(subject.astype(np.uint8))
    if points is None:
        return []
    _sx, sy, _sw, sh = cv2.boundingRect(points)
    count, labels, stats, _centres = cv2.connectedComponentsWithStats(
        (distance <= core_limit).astype(np.uint8), connectivity=8)
    strict_labels = labels

    def candidates():
        # Keep the original strict pass: a larger diagnostic component must
        # never conceal a slit that already failed. A second, bounded colour
        # radius only joins antialiased *fragments for rejection*. It does not
        # change the removable background core or the output matte. Sarah's
        # near-white hair crescent splits into tiny strict islands, separated
        # by slightly shaded white pixels; testing them independently missed
        # the visible aggregate. Dark hair is never used as a joining bridge.
        for fragmented, limit in ((False, core_limit),
                                  (True, min(56.0, core_limit + 20.0))):
            if fragmented:
                n, component_labels, component_stats, _ = cv2.connectedComponentsWithStats(
                    (distance <= limit).astype(np.uint8), connectivity=8)
            else:
                n, component_labels, component_stats = count, labels, stats
            exterior = set(int(value) for value in np.unique(np.concatenate((
                component_labels[0, :], component_labels[-1, :],
                component_labels[:, 0], component_labels[:, -1],
            ))))
            for label in range(1, n):
                if label not in exterior:
                    yield component_labels, component_stats[label], label, fragmented

    exterior_distance = cv2.distanceTransform(
        (~core).astype(np.uint8), cv2.DIST_L2, 5)
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    risks = []

    def has_authored_pupil(candidate, pixels):
        points = cv2.findNonZero(candidate.astype(np.uint8))
        if points is None:
            return False
        _x, _y, eye_width, eye_height = cv2.boundingRect(points)
        # A long hair crescent's convex hull also contains dark strands.
        # They are not a pupil: require a compact eye-shaped pale surface.
        if not .35 <= eye_width / max(1.0, float(eye_height)) <= 3.0:
            return False
        hull = np.zeros(candidate.shape, np.uint8)
        cv2.fillConvexPoly(hull, cv2.convexHull(points), 1)
        dark = (np.max(pixels, axis=2) <= 96) & (hull > 0) & ~candidate
        pupil_pixels = int(np.count_nonzero(dark))
        area = int(np.count_nonzero(candidate))
        return max(6, round(area * .025)) <= pupil_pixels <= area * .55

    seen_bounds = set()
    for component_labels, bounds, label, fragmented in candidates():
        x, y, w, h, area = (int(value) for value in bounds)
        if (area < 24 or area > max(256, round(extent * extent * .001))
                or max(w, h) < max(18, round(extent * .018))
                or min(w, h) > max(12, round(extent * .022))
                or h < w * 2.8
                or y + h > sy + sh * .25):
            continue
        margin = max(12, min(24, round(extent * .018)))
        x0, y0 = max(0, x - margin), max(0, y - margin)
        x1, y1 = min(width, x + w + margin), min(height, y + h + margin)
        roi = np.s_[y0:y1, x0:x1]
        component = component_labels[roi] == label
        # The broader radius is only evidence of adjacency, not evidence
        # that every grouped pixel is plate-white. Require the same minimum
        # strict-white support and multiple disconnected strict fragments.
        white_support = component & (distance[roi] <= core_limit)
        support_area = int(np.count_nonzero(white_support))
        fragment_ids = np.unique(strict_labels[roi][white_support])
        fragment_ids = fragment_ids[fragment_ids > 0]
        if fragmented and (support_area < 24 or len(fragment_ids) < 2):
            continue
        distances = exterior_distance[roi][component]
        if (float(np.min(distances)) > max(6.0, extent * .014)
                or float(np.max(distances)) > max(12.0, extent * .022)):
            continue
        pixels = image[roi]
        if support_area == 0 or float(np.mean(
                np.min(pixels[white_support], axis=1) >= 248)) < .45:
            continue
        if has_authored_pupil(component, pixels):
            continue
        # A profile sclera may split into several plate-white fragments.
        # Recover its connected pale surface locally before checking for the
        # authored pupil, without crossing the already-proven exterior plate.
        local_hsv = hsv[roi]
        pale = ((local_hsv[:, :, 2] >= 175)
                & (local_hsv[:, :, 1] <= 45) & ~core[roi])
        _n, pale_labels = cv2.connectedComponents(
            pale.astype(np.uint8), connectivity=8)
        ids = np.unique(pale_labels[component])
        ids = ids[ids > 0]
        if len(ids) == 1 and has_authored_pupil(pale_labels == ids[0], pixels):
            continue
        ring = cv2.dilate(
            component.astype(np.uint8),
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)),
        ).astype(bool) & ~component & ~core[roi]
        ring_count = int(np.count_nonzero(ring))
        if ring_count < 32:
            continue
        white_surface = ((local_hsv[:, :, 2] >= 175)
                         & (local_hsv[:, :, 1] <= 45))
        dark_material = ((local_hsv[:, :, 2] <= 120)
                         | ((local_hsv[:, :, 1] >= 80)
                            & (local_hsv[:, :, 2] <= 195)))
        if (float(np.mean(white_surface[ring])) >= .65
                or float(np.mean(dark_material[ring])) < .32):
            continue
        if (x, y, w, h) in seen_bounds:
            continue
        seen_bounds.add((x, y, w, h))
        risks.append({
            "kind": "ambiguous-enclosed-white-silhouette-slit",
            "bounds": [x, y, w, h],
            "plate_pixels": support_area,
            "strict_fragment_count": int(len(fragment_ids)),
            "fragmented": fragmented,
            "nearest_exterior_px": round(float(np.min(distances)), 3),
            "furthest_exterior_px": round(float(np.max(distances)), 3),
        })
    return risks


def _flat_plate_cutout(image, *, reject_enclosed_plate=False):
    """Extract a soft matte from a proven flat illustration plate.

    Colour similarity alone is unsafe because cartoons commonly contain white
    eyes, teeth, and highlights.  Only the similar-colour component connected
    to the outside border is removed, so enclosed white anatomy stays opaque.
    """
    model = _flat_plate_model(image)
    if model is None:
        return None
    kind, background, support = model
    pixels = image.astype(np.float32)
    distance = np.linalg.norm(pixels - background[None, None, :], axis=2)
    border = _border_mask(*image.shape[:2])
    border_distance = distance[border]
    noise = float(np.percentile(border_distance, 96))
    noise = min(18.0, max(3.0, noise + 1.5))
    # A modest colour radius includes JPEG/antialias fringe without walking
    # through pale skin or clothing. Green gets a little more room because
    # chroma subsampling spreads its saturated edge further than white.
    edge_limit = max(noise + 20.0, 112.0 if kind == "green" else 96.0)

    # Prove the removable plate with a deliberately tight colour core first.
    # Using the full feather radius for connectivity lets a light-neutral 3D
    # character's skin become a bridge from the plate into the face: the
    # entire cheek/forehead then receives partial alpha on dark backgrounds.
    # Grow only a narrow antialias ring from the already-proven outside core.
    # This branch is stylized-only; photographs never reach this extractor.
    core_margin = 28.0 if kind == "green" else 18.0
    core_limit = min(edge_limit - 1.0, noise + core_margin)
    core = _border_connected(distance <= core_limit)
    if float(core[border].mean()) < 0.52:
        return None
    if reject_enclosed_plate and kind == "white":
        ambiguous = _enclosed_white_silhouette_slits(
            image, distance, core, core_limit)
        if ambiguous:
            raise AmbiguousStylizedPlateError(ambiguous)

    feather_steps = max(2, min(6, int(round(min(image.shape[:2]) * .005))))
    kernel = np.ones((3, 3), np.uint8)
    near_core = cv2.dilate(
        core.astype(np.uint8), kernel, iterations=feather_steps).astype(bool)
    feather = near_core & ~core & (distance <= edge_limit)

    alpha = np.full(image.shape[:2], 255, np.uint8)
    span = max(1.0, edge_limit - core_limit)
    transition = np.clip((distance - core_limit) / span, 0.0, 1.0)
    # A squared ramp follows the low-opacity side of an antialiased contour
    # more faithfully than a hard chroma threshold and avoids bright halos.
    soft = np.rint(255.0 * transition * transition).astype(np.uint8)
    alpha[core] = 0
    alpha[feather] = soft[feather]

    foreground = alpha > 8
    coverage = float(foreground.mean())
    points = cv2.findNonZero(foreground.astype(np.uint8))
    if points is None or not (0.01 <= coverage <= 0.97):
        return None
    _x, _y, width, height = cv2.boundingRect(points)
    if width < 4 or height < 4:
        return None
    rgba = np.dstack((image.copy(), alpha))
    return rgba, kind, support


def _run_helper(helper, source, destination, pose_destination, log):
    try:
        command = [helper, source, destination]
        if pose_destination:
            command.append(pose_destination)
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=180,
            stdin=subprocess.DEVNULL,
        )
    except Exception as error:
        log(f"  cutout failed: {error}")
        return False
    if result.returncode or not os.path.exists(destination):
        detail = (result.stderr or result.stdout or "unknown error").strip()[-240:]
        log(f"  cutout failed: {detail}")
        return False
    if pose_destination and not os.path.isfile(pose_destination):
        log("  cutout failed: helper did not produce body-pose metadata")
        return False
    return True


def render(
        source, destination, log=print, tight=False, pose_destination=None,
        allow_stylized=False, reject_enclosed_plate=False):
    """Create an RGBA subject cutout, with an explicit cartoon plate path.

    The default remains macOS Vision person segmentation.  A caller that has
    already classified the source as non-photographic may opt into a local,
    border-connected white/neutral/green extractor. Body-pose requests run
    Vision for their pose receipt; only the semantic matte is replaced.
    """
    flat = None
    if allow_stylized:
        source_image = cv2.imread(source, cv2.IMREAD_COLOR)
        if source_image is not None:
            flat = _flat_plate_cutout(
                source_image, reject_enclosed_plate=reject_enclosed_plate)

    helper_required = pose_destination is not None or flat is None
    if helper_required:
        helper = helper_path()
        if not helper:
            log("  cutout unavailable: macOS Vision helper is not installed")
            return None
        if not _run_helper(
                helper, source, destination, pose_destination, log):
            return None

    method = "macos-vision-person-segmentation"
    if flat is not None:
        image, plate_kind, plate_support = flat
        method = f"border-connected-{plate_kind}-plate"
        directory = os.path.dirname(os.path.abspath(destination))
        os.makedirs(directory, exist_ok=True)
        if not cv2.imwrite(destination, image):
            log("  cutout failed: could not write stylized plate matte")
            return None
        log(
            f"  stylized {plate_kind} plate detected: "
            f"{plate_support * 100:.1f}% border support")
    else:
        image = cv2.imread(destination, cv2.IMREAD_UNCHANGED)

    if image is None or image.ndim != 3 or image.shape[2] != 4:
        log("  cutout failed: helper did not produce an RGBA image")
        return None
    if tight:
        image = _decontaminate_edges(image)
        # Vision already expands and softens its semantic mask in the native
        # helper.  A second, unconditional 3x3 erosion used to remove the pale
        # rim, but it also erased genuine one-to-three-pixel structures such as
        # stiletto stems and narrow shoe straps.  Edge colour cleanup is enough;
        # discard only numerically empty fringe pixels and preserve confident
        # alpha exactly as Vision produced it.
        alpha = image[:, :, 3]
        alpha[alpha < 8] = 0
        image[:, :, :3][alpha == 0] = 0
        cv2.imwrite(destination, image)
    alpha = image[:, :, 3]
    points = cv2.findNonZero((alpha > 8).astype("uint8"))
    if points is None:
        log("  cutout failed: person mask is empty")
        return None
    x, y, width, height = cv2.boundingRect(points)
    coverage = float((alpha > 8).mean())
    log(f"  cutout ready: {coverage * 100:.1f}% foreground")
    return {
        "src": "assets/cutout.png",
        "bounds": [int(x), int(y), int(width), int(height)],
        "coverage": round(coverage, 4),
        "method": method,
    }
