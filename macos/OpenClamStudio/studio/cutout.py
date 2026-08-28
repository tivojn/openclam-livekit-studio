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


def _flat_plate_cutout(image):
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
        allow_stylized=False):
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
            flat = _flat_plate_cutout(source_image)

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
