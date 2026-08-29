"""Publish a built avatar into a runtime that consumes viseme frames.

The eye region is pixel-identical across every viseme frame by construction, so
the eyes do not belong in the frames at all.  They ship as two small RGBA sprite
strips - one per eye - holding the lid TRAVEL synthesised in blink.py.  The
runtime draws one mouth frame and stamps the current lid position on top.

That is both lighter and better than the old scheme.  Lighter: 16 frames instead
of 32.  Better: the previous export baked exactly two eye states, so a blink
could only ever be a hard cut to fully-shut and a hard cut back - the lid never
existed in between, which no amount of timing can rescue.  Now the lid has 8
positions per eye and the two eyes can be driven independently.
"""
import os, json, shutil, subprocess
import numpy as np, cv2
from . import face, blink, expression, cutout, limbs, rig, build as reg


# The renderer version is not only an asset schema: it also tells the desktop
# which calibrated runtime controls can be consumed safely.  Keep a runtime
# bundle with preserved face strips current when its Pet layers are refreshed
# without source visemes.
RUNTIME_VERSION = 22
# Must match ``body.STYLIZED_HEAD_HANDOFF_VERSION``.  Keeping this gate in the
# publisher prevents malformed or future authoring metadata from opting an old
# runtime into alpha semantics the current renderer has not reviewed.
STYLIZED_HEAD_HANDOFF_VERSION = 2

# runtime viseme name -> studio shape name
NAME_MAP = {"sil": "closed", "PP": "PP", "FF": "FF", "TH": "TH", "DD": "DD",
            "kk": "kk", "CH": "CH", "SS": "SS", "nn": "nn", "RR": "RR",
            "aa": "ah", "E": "eh", "ih": "ih", "oh": "oh", "ou": "oo"}


def _source_medium(manifest):
    """Resolve detector routing from original intake evidence first.

    ``source_metrics`` (or its legacy ``metrics`` name) describes the uploaded
    source and is therefore authoritative.  A generated canonical head is only
    a compatibility fallback for older manifests without an intake report.
    Malformed, missing-field, unknown, and future report values stay on the
    strict photographic route rather than inheriting a permissive head hint.
    """
    manifest = manifest if isinstance(manifest, dict) else {}
    for key in ("source_metrics", "metrics"):
        if key not in manifest:
            continue
        report = manifest.get(key)
        if not isinstance(report, dict):
            return "photograph"
        return reg._source_medium(report)
    head = manifest.get("head")
    if isinstance(head, dict) and "source_medium" in head:
        return reg._source_medium({"source_medium": head.get("source_medium")})
    return "photograph"


def _runtime_version(value):
    """Return a defensively parsed runtime version for a preserved bundle."""
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


def _runtime_rig_profile(source_manifest, preserved_runtime=None):
    """Normalize current controls without discarding an old runtime-only rig.

    A source manifest is authoritative after a rebuild.  Imported/runtime-only
    avatars can have no persisted source profile, however, so preserve a valid
    profile from their current runtime before falling back to natural defaults.
    In either case ``rig.normalize`` adds newly introduced safe controls such
    as the independent under-eye target.
    """
    source_manifest = source_manifest if isinstance(source_manifest, dict) else {}
    preserved_runtime = (
        preserved_runtime if isinstance(preserved_runtime, dict) else {})
    for candidate in (
            source_manifest.get("rig_profile"),
            preserved_runtime.get("rig_profile")):
        if not isinstance(candidate, dict):
            continue
        try:
            return rig.normalize(candidate)
        except (TypeError, ValueError):
            # An old or malformed draft must never block the asset-preserving
            # migration; a later candidate/default remains safe to publish.
            continue
    return rig.normalize()


def _runtime_face_asset(destination, reference, label):
    """Validate an existing face-sprite reference before a schema upgrade."""
    if not isinstance(reference, str) or not reference.startswith("assets/"):
        raise ValueError(f"runtime {label} asset reference is missing")
    root = os.path.abspath(destination)
    asset = os.path.abspath(os.path.join(root, reference[len("assets/"):]))
    if os.path.commonpath((root, asset)) != root:
        raise ValueError(f"runtime {label} asset escapes its bundle")
    if not os.path.isfile(asset) or os.path.getsize(asset) <= 0:
        raise ValueError(f"runtime {label} asset is missing")


_STYLIZED_SOURCE_MEDIA = frozenset({
    "anime", "illustration", "illustrated", "cartoon", "drawing",
    "game art", "game-art", "3d render", "3d-render", "soft-3d",
})


def _is_stylized_source_medium(value):
    """Recognize only the reviewed non-photographic intake categories."""
    return str(value or "").strip().lower() in _STYLIZED_SOURCE_MEDIA


def _stylized_mouth_geometry(shape, landmarks):
    """Return the one provider-redraw region a stylized runtime may replace.

    The photo expression boxes intentionally include cheek/under-eye context.
    Reusing either of them for a cartoon viseme lets the generated phoneme
    repaint the lower edges of oversized eyes (and, on the retained 3-D Luffy,
    produced white wedges below both sclerae).  This box is derived only from
    the canonical outer lip.  Its proportions were checked against every one
    of the 15 retained visemes for both flat and soft-3-D Luffy banks.
    """
    if landmarks is None:
        return None
    try:
        points = np.asarray(landmarks[face.OUTER_LIP], np.float64)
    except (IndexError, TypeError, ValueError):
        return None
    if points.shape != (len(face.OUTER_LIP), 2) or not np.isfinite(points).all():
        return None
    width = float(np.ptp(points[:, 0]))
    if width < 4.0:
        return None
    centre_x, centre_y = points.mean(axis=0)
    image_height, image_width = shape[:2]
    x0 = max(0, int(np.floor(centre_x - 0.75 * width)))
    x1 = min(image_width, int(np.ceil(centre_x + 0.75 * width)))
    y0 = max(0, int(np.floor(centre_y - 0.28 * width)))
    y1 = min(image_height, int(np.ceil(centre_y + 0.48 * width)))
    if x1 <= x0 or y1 <= y0:
        return None
    return {"box": [x0, y0, x1 - x0, y1 - y0],
            "basis": "canonical-outer-lip-v1"}


def _remove_stylized_blink_assets(destination):
    for side in blink.SIDES:
        try:
            os.remove(os.path.join(destination, f"stylized-blink-{side}.png"))
        except FileNotFoundError:
            pass


def _stylized_eye_alpha(neutral, geometry):
    """Return a feathered alpha around a drawn sclera, not a human mesh oval."""
    try:
        x, y, width, height = [int(round(float(value)))
                               for value in geometry.get("box")]
    except (AttributeError, TypeError, ValueError):
        return None
    if width <= 0 or height <= 0:
        return None
    image_height, image_width = neutral.shape[:2]
    pad_x = max(16, int(round(width * 0.28)))
    pad_y = max(20, int(round(height * 0.75)))
    x0 = max(0, x - pad_x)
    y0 = max(0, y - pad_y)
    x1 = min(image_width, x + width + pad_x)
    y1 = min(image_height, y + height + pad_y)
    crop = neutral[y0:y1, x0:x1]
    if not crop.size:
        return None

    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    white = ((hsv[:, :, 1] < 85) & (hsv[:, :, 2] > 135)).astype(np.uint8) * 255
    guard = np.zeros_like(white)
    centre = (int(round(x + width * 0.5 - x0)),
              int(round(y + height * 0.65 - y0)))
    radii = (max(12, int(round(width * 0.62))),
             max(12, int(round(height * 0.95))))
    cv2.ellipse(guard, centre, radii, 0, 0, 360, 255, -1)
    white = cv2.bitwise_and(white, guard)
    opening = max(3, min(13, int(round(min(width, height) * 0.12)))) | 1
    white = cv2.morphologyEx(
        white, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (opening, opening)))

    count, labels, stats, centres = cv2.connectedComponentsWithStats(white)
    minimum_area = max(24, width * height * 0.05)
    candidates = [index for index in range(1, count)
                  if float(stats[index, cv2.CC_STAT_AREA]) >= minimum_area]
    if not candidates:
        return None
    cx, cy = centre
    selected = min(candidates, key=lambda index: (
        ((centres[index, 0] - cx) / max(width, 1)) ** 2
        + ((centres[index, 1] - cy) / max(height, 1)) ** 2
        - float(stats[index, cv2.CC_STAT_AREA]) / (width * height) * 0.15))
    solid = (labels == selected).astype(np.uint8) * 255
    contours, _ = cv2.findContours(
        solid, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    solid.fill(0)
    cv2.drawContours(solid, [max(contours, key=cv2.contourArea)], -1, 255, -1)
    # The semantic plate must replace the entire drawn sclera and its outer
    # ink, but it must not consume nearby stylized hair or eyebrow tips.  The
    # old 25%-of-eye kernel expanded as far as 31 px and pulled those dark
    # shapes into canonical inpainting, producing smeared triangles above
    # Luffy's closed eyes.  A 7--11 px kernel covers the actual illustrated
    # outline while keeping the authored hair and brow byte-identical.
    dilation = max(7, min(11, int(round(min(width, height) * 0.08)))) | 1
    solid = cv2.dilate(
        solid,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dilation, dilation)))

    # Hair and eyebrow strokes can cross a cartoon sclera. Preserve only dark
    # components connected to the search boundary; the enclosed pupil is the
    # one dark component that must be replaced by the closed-lid source.
    dark = (cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY) < 55).astype(np.uint8)
    dark_count, dark_labels = cv2.connectedComponents(dark)
    border_labels = np.unique(np.concatenate((
        dark_labels[0], dark_labels[-1], dark_labels[:, 0], dark_labels[:, -1])))
    border_labels = border_labels[border_labels > 0]
    if dark_count > 1 and border_labels.size:
        preserve = np.isin(dark_labels, border_labels).astype(np.uint8) * 255
        preserve = cv2.dilate(
            preserve, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
        solid[preserve > 0] = 0

    alpha = cv2.GaussianBlur(solid, (0, 0), 1.5)
    rows, columns = np.nonzero(alpha > 1)
    if not len(rows):
        return None
    # Keep enough authored source below the open sclera to recover a provider
    # blink whose closed-lid curve sits lower than MediaPipe's open-eye mesh.
    # This is common for oversized cartoon eyes; the previous twelve-pixel
    # crop clipped that curve and made the valid full-eye plate fail QA.
    margin_x = 12
    margin_top = 12
    margin_bottom = max(20, int(round((rows.max() - rows.min() + 1) * 0.32)))
    local_x0 = max(0, int(columns.min()) - margin_x)
    local_y0 = max(0, int(rows.min()) - margin_top)
    local_x1 = min(alpha.shape[1], int(columns.max()) + margin_x + 1)
    local_y1 = min(alpha.shape[0], int(rows.max()) + margin_bottom + 1)
    return ([x0 + local_x0, y0 + local_y0,
             local_x1 - local_x0, local_y1 - local_y0],
            alpha[local_y0:local_y1, local_x0:local_x1])


def _stylized_sclera_fraction(image, box, alpha):
    """Measure visible white eye paint inside one authored cartoon sclera."""
    x, y, width, height = box
    patch = image[y:y + height, x:x + width]
    if patch.shape[:2] != alpha.shape[:2]:
        return 1.0
    hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
    core = alpha > 128
    count = int(np.count_nonzero(core))
    if count < 24:
        return 1.0
    white = (hsv[:, :, 1] < 72) & (hsv[:, :, 2] > 155)
    return float(np.count_nonzero(white & core)) / count


def _stylized_lid_topology(patch, alpha):
    """Return one clean authored closed-lid component, or ``None``.

    Registration and topology are deliberately separate.  A locally aligned
    stylized source is normally the best plate, but oversized cartoon eyes can
    make the per-eye MediaPipe fit collapse a real full-width lid into a small
    inner component.  Callers may therefore try another *already stability
    gated* alignment without weakening any of the foreign-art or seam gates
    that run after this helper succeeds.
    """
    if (patch is None or not isinstance(alpha, np.ndarray)
            or patch.ndim != 3 or patch.shape[:2] != alpha.shape[:2]):
        return None
    core = alpha > 96
    rows, columns = np.nonzero(core)
    if not len(rows):
        return None
    core_x0, core_x1 = int(columns.min()), int(columns.max())
    core_y0, core_y1 = int(rows.min()), int(rows.max())
    core_width = core_x1 - core_x0 + 1
    core_height = core_y1 - core_y0 + 1
    patch_height, patch_width = alpha.shape[:2]

    # Search the full semantic-eye crop, not only the neutral sclera. A valid
    # authored cartoon blink can place its curved lid just below the open-eye
    # oval.  The bounds stay tied to the canonical sclera, so hair and facial
    # art elsewhere in the provider frame cannot qualify as a lid.
    analysis_guard = np.zeros_like(alpha, dtype=bool)
    search_y0 = max(0, int(round(core_y0 + core_height * 0.35)))
    search_y1 = min(
        patch_height,
        int(round(core_y0 + core_height * 1.28)),
    )
    search_x0 = max(0, int(round(core_x0 - core_width * 0.08)))
    search_x1 = min(
        patch_width,
        int(round(core_x1 + 1 + core_width * 0.08)),
    )
    analysis_guard[search_y0:search_y1, search_x0:search_x1] = True
    gray = cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY)
    # Keep the cutoff below mid-tone illustrated skin. Raising this to a
    # photographic threshold turns a flat-shaded face into one component.
    dark = ((gray < 100) & analysis_guard).astype(np.uint8) * 255
    dark = cv2.morphologyEx(
        dark, cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_RECT, (5, 3)))
    count, labels, stats, centres = cv2.connectedComponentsWithStats(dark)
    lid_candidates = []
    for index in range(1, count):
        component_width = int(stats[index, cv2.CC_STAT_WIDTH])
        component_height = int(stats[index, cv2.CC_STAT_HEIGHT])
        centre_y = float(centres[index, 1])
        aspect = component_width / max(component_height, 1)
        if (component_width >= core_width * 0.42
                and component_height <= core_height * 0.38
                and aspect >= 2.35
                and centre_y >= core_y0 + core_height * 0.45
                and centre_y <= core_y0 + core_height * 1.20):
            lid_candidates.append(index)
    if not lid_candidates:
        return None
    lid_index = max(
        lid_candidates,
        key=lambda index: int(stats[index, cv2.CC_STAT_AREA]))
    return {
        "core": core,
        "core_x0": core_x0,
        "core_y0": core_y0,
        "core_width": core_width,
        "core_height": core_height,
        "labels": labels,
        "stats": stats,
        "centres": centres,
        "lid_index": lid_index,
    }


def _harmonic_stylized_skin(target, mask):
    """Fill one authored cartoon eye from its canonical skin boundary.

    A generated closed-eye source is useful evidence for the lid stroke, but
    its illumination and even its local face geometry are not registered
    tightly enough to publish as skin.  Copying that source makes a bright
    sticker; fitting one global colour or quadratic surface makes a circular
    disk.  Instead solve the discrete Laplace equation over the *exact* full
    eye mask, with the avatar's own neighbouring skin as Dirichlet boundary
    conditions.  The solution meets the canonical face continuously at every
    usable boundary pixel and contains no radial inpaint centre.

    Dark ink, pale background, and neutral-grey pixels are deliberately not
    boundary conditions.  They behave as a no-flux edge, so a fringe, brow,
    or studio backdrop cannot bleed into the reconstructed skin.  Returning
    ``None`` is the fail-closed path for a mask without enough genuine skin or
    for a singular/non-finite solve.  This helper is called only after the
    source medium has passed the explicit stylized gate.
    """
    if (target is None or not isinstance(mask, np.ndarray)
            or target.ndim != 3 or target.shape[2] != 3
            or mask.shape != target.shape[:2]):
        return None
    solid = mask.astype(bool)
    ys, xs = np.nonzero(solid)
    pixel_count = len(ys)
    if pixel_count < 24 or pixel_count >= solid.size * 0.82:
        return None

    gray = cv2.cvtColor(target, cv2.COLOR_BGR2GRAY)
    hsv = cv2.cvtColor(target, cv2.COLOR_BGR2HSV)
    skin = (gray > 95) & (hsv[:, :, 1] > 28)
    boundary = (
        cv2.dilate(
            solid.astype(np.uint8),
            cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3)),
        ).astype(bool)
        & ~solid
        & skin
    )
    if int(np.count_nonzero(boundary)) < max(12, int(np.sqrt(pixel_count))):
        return None

    # SciPy is already a pinned backend/Electron dependency.  Import lazily so
    # photo-only call sites pay no import or initialization cost whatsoever.
    try:
        from scipy import sparse
        from scipy.sparse.linalg import MatrixRankWarning, spsolve
    except (ImportError, AttributeError):
        return None

    index = np.full(solid.shape, -1, np.int32)
    index[ys, xs] = np.arange(pixel_count, dtype=np.int32)
    rows = []
    columns = []
    values = []
    rhs = np.zeros((pixel_count, 3), np.float64)
    boundary_terms = 0
    height, width = solid.shape
    for equation, (y, x) in enumerate(zip(ys, xs)):
        degree = 0
        for ny, nx in ((y - 1, x), (y + 1, x),
                       (y, x - 1), (y, x + 1)):
            if not (0 <= ny < height and 0 <= nx < width):
                continue
            if solid[ny, nx]:
                rows.append(equation)
                columns.append(int(index[ny, nx]))
                values.append(-1.0)
                degree += 1
            elif skin[ny, nx]:
                rhs[equation] += target[ny, nx]
                degree += 1
                boundary_terms += 1
        # A temporarily isolated pixel is held at its canonical value.  The
        # global boundary preflight above still prevents an unconstrained eye
        # component from being accepted as a black/zero solution.
        if degree == 0:
            degree = 1
            rhs[equation] = target[y, x]
        rows.append(equation)
        columns.append(equation)
        values.append(float(degree))
    if boundary_terms < max(12, int(np.sqrt(pixel_count))):
        return None

    matrix = sparse.csr_matrix(
        (values, (rows, columns)), shape=(pixel_count, pixel_count)
    )
    result = target.copy()
    try:
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("error", MatrixRankWarning)
            for channel in range(3):
                solved = spsolve(matrix, rhs[:, channel])
                if not np.isfinite(solved).all():
                    return None
                result[ys, xs, channel] = np.clip(
                    np.rint(solved), 0, 255
                ).astype(np.uint8)
    except (ArithmeticError, RuntimeError, ValueError, MatrixRankWarning):
        return None
    return result


def _publish_stylized_blink_source(neutral, avatar_home, eyes, destination,
                                     source_medium, log=print):
    """Publish a seam-gated closed-eye plate for a reviewed cartoon.

    The ordinary eyelid synthesizer is deliberately optimized for a human eye
    opening.  On an oversized drawn sclera its landmark-derived mask can cover
    only the inner part of the eye, which looks like a second, smaller eye
    blinking inside a static one.  A stylized avatar instead gets a late-switch
    pair of semantic-eye RGBA plates locally registered from the original
    generated blink.

    This path is fail-closed: photographs and unknown media never enter the
    permissive intake detector, and a weak affine fit or insufficiently closed
    source produces no alternative blink asset at all.  The web renderer then
    keeps the canonical eyes static rather than falling back to human strips.
    """
    if not _is_stylized_source_medium(source_medium):
        _remove_stylized_blink_assets(destination)
        return None
    if not isinstance(eyes, dict):
        return None

    raw_path = next((
        os.path.join(avatar_home, "raw", f"v_blink.{extension}")
        for extension in ("png", "jpg", "jpeg", "webp")
        if os.path.isfile(os.path.join(
            avatar_home, "raw", f"v_blink.{extension}"))
    ), None)
    if raw_path is None:
        log("  stylized blink source missing; keeping calibrated eyelid strip")
        return None

    source = cv2.imread(raw_path, cv2.IMREAD_COLOR)
    if neutral is None or source is None:
        return None
    height, width = neutral.shape[:2]
    if source.shape[:2] != (height, width):
        source = cv2.resize(
            source, (width, height), interpolation=cv2.INTER_LANCZOS4)

    key_landmarks, _, _ = face.detect_for_intake(neutral)
    source_landmarks, _, _ = face.detect_for_intake(source)
    if key_landmarks is None or source_landmarks is None:
        log("  stylized blink source rejected: face registration failed")
        return None
    transform, _ = cv2.estimateAffine2D(
        source_landmarks[face.RIGID], key_landmarks[face.RIGID],
        method=cv2.LMEDS, refineIters=50)
    if transform is None or not np.isfinite(transform).all():
        log("  stylized blink source rejected: affine registration failed")
        return None
    determinant = float(np.linalg.det(transform[:, :2]))
    projected = ((transform[:, :2] @ source_landmarks[face.RIGID].T).T
                 + transform[:, 2])
    residuals = np.linalg.norm(projected - key_landmarks[face.RIGID], axis=1)
    if (not 0.5 <= determinant <= 1.8
            or float(np.max(residuals)) > max(height, width) * 0.10):
        log("  stylized blink source rejected: unstable face registration")
        return None

    aligned = cv2.warpAffine(
        source, transform, (width, height), flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_REPLICATE)
    aligned_landmarks, _, _ = face.detect_for_intake(aligned)
    if aligned_landmarks is None:
        log("  stylized blink source rejected: aligned face was lost")
        return None
    eye_masks = {}
    for side in blink.SIDES:
        geometry = eyes.get(side) if isinstance(eyes.get(side), dict) else {}
        mask = _stylized_eye_alpha(neutral, geometry)
        if mask is None:
            log(f"  stylized blink source rejected: {side} sclera was not isolated")
            return None
        eye_masks[side] = mask
        open_aperture = blink._aperture(key_landmarks, side)
        shut_aperture = blink._aperture(aligned_landmarks, side)
        box, alpha = mask
        open_sclera = _stylized_sclera_fraction(neutral, box, alpha)
        shut_sclera = _stylized_sclera_fraction(aligned, box, alpha)
        # MediaPipe's lid curve is noisy on oversized hand-drawn eyes.  The
        # new soft-3-D Luffy measures 0.815 on one side even though 100% of the
        # white eye paint disappears.  Sclera disappearance is direct rendered
        # evidence; aperture remains a broad registration sanity bound only.
        # This route is stylized-only and cannot weaken photographic blink QA.
        visually_closed = (shut_aperture <= open_aperture * 1.25
                           and shut_sclera <= 0.045
                           and shut_sclera <= open_sclera * 0.10)
        if (not np.isfinite(open_aperture) or not np.isfinite(shut_aperture)
                or open_aperture <= 1.0
                or not visually_closed):
            log(f"  stylized blink source rejected: {side} eye is not closed")
            return None

    os.makedirs(destination, exist_ok=True)
    prepared = {}
    for side in blink.SIDES:
        box, alpha = eye_masks[side]
        x0, y0, patch_width, patch_height = box
        # Prefer a local eye+brow fit: a provider can turn a stylized head while
        # preserving a valid closed eye.  Oversized cartoon eyes can, however,
        # make that local MediaPipe fit collapse a real full-width lid into a
        # small inner blink.  If and only if local alignment produces no clean
        # lid topology, retry with the already stability-gated global alignment
        # above.  The selected plate still passes the identical foreign-art,
        # canonical-sclera, skin-fill and seam gates below.
        indices = np.asarray(blink.EYE[side] + blink.BROW[side], np.int32)
        local_transform, _ = cv2.estimateAffinePartial2D(
            source_landmarks[indices], key_landmarks[indices],
            method=cv2.LMEDS, refineIters=50)
        local = None
        if local_transform is not None and np.isfinite(local_transform).all():
            local_determinant = float(np.linalg.det(local_transform[:, :2]))
            if 0.45 <= local_determinant <= 2.2:
                local = cv2.warpAffine(
                    source, local_transform, (width, height),
                    flags=cv2.INTER_LANCZOS4,
                    borderMode=cv2.BORDER_REPLICATE)
        patch = (local[y0:y0 + patch_height, x0:x0 + patch_width].copy()
                 if local is not None else None)
        selected_alignment = local
        topology = _stylized_lid_topology(patch, alpha)
        if topology is None:
            # ``aligned`` already passed global determinant/residual, face,
            # aperture and sclera-disappearance gates.  It is therefore a
            # bounded fallback candidate, not a permissive second detector.
            patch = aligned[y0:y0 + patch_height,
                            x0:x0 + patch_width].copy()
            selected_alignment = aligned
            topology = _stylized_lid_topology(patch, alpha)
            if topology is None:
                log(f"  stylized blink source rejected: {side} lid stroke is not clean")
                return None
            log(f"  stylized blink source: {side} using stable global lid alignment")
        core = topology["core"]
        core_x0 = topology["core_x0"]
        core_y0 = topology["core_y0"]
        core_width = topology["core_width"]
        core_height = topology["core_height"]
        labels = topology["labels"]
        stats = topology["stats"]
        centres = topology["centres"]
        lid_index = topology["lid_index"]
        # Reject substantial provider art *inside* the canonical eye, while
        # tolerating a fringe/brow component which merely grazes the generous
        # semantic search crop.  The retained real Luffy fringe overlaps the
        # full-eye core by only 8.16%; the synthetic displaced-hair regression
        # overlaps it completely.  The overlap qualification keeps this gate
        # strict where an artifact could survive while avoiding the broad
        # false rejection that originally disabled Luffy's valid blink.
        foreign_limit = max(48, int(np.count_nonzero(core) * 0.012))
        for index in range(1, len(stats)):
            if index == lid_index:
                continue
            area = int(stats[index, cv2.CC_STAT_AREA])
            component_width = int(stats[index, cv2.CC_STAT_WIDTH])
            component_height = int(stats[index, cv2.CC_STAT_HEIGHT])
            if area <= 0:
                continue
            component = labels == index
            core_overlap = (
                float(np.count_nonzero(component & core)) / area
            )
            if (area > foreign_limit
                    and core_overlap >= 0.35
                    and (component_height > core_height * 0.25
                         or component_width > core_width * 0.25)):
                log(f"  stylized blink source rejected: {side} contains foreign dark art")
                return None
        # Topology and foreign-art QA deliberately run on the original bounded
        # eye crop above.  After the alignment has been accepted, add canonical
        # skin below the publication plate so its feather cannot land on the
        # lower arc of an oversized open sclera.  Padding only after topology is
        # important: a clipped/small local lid cannot become acceptable merely
        # because more unrelated source pixels entered its search crop.
        extra_bottom = min(
            height - (y0 + patch_height),
            max(20, int(round(core_height * 0.36))),
        )
        if extra_bottom > 0:
            patch_height += extra_bottom
            box = [x0, y0, patch_width, patch_height]
            patch = selected_alignment[
                y0:y0 + patch_height, x0:x0 + patch_width
            ].copy()
            alpha = np.pad(
                alpha, ((0, extra_bottom), (0, 0)), mode="constant"
            )
            core = np.pad(
                core, ((0, extra_bottom), (0, 0)), mode="constant"
            )
            labels = np.pad(
                labels, ((0, extra_bottom), (0, 0)), mode="constant"
            )
        neutral_patch = neutral[y0:y0 + patch_height,
                                x0:x0 + patch_width]
        # Build one coherent full-eye replacement. First remove every dark
        # provider mark inside the authored eye region (pupil, displaced hair,
        # eyebrow), then restore only the reviewed closed-lid component. The
        # neutral sclera underneath is therefore completely covered instead
        # of receiving a smaller inset blink patch.
        # Reconstruct skin from the canonical face, not the provider's blink
        # image. Provider lighting/pose differences made the old plate read as
        # a circular skin-colour sticker even though its alpha covered the
        # correct full eye. The canonical boundary supplies identical tone and
        # texture; only the reviewed lid stroke is borrowed from the provider.
        # Re-isolate the exact canonical sclera inside the generous semantic
        # crop.  The crop/alpha intentionally extends below the open eye so it
        # can contain a provider-painted low lid, but using that whole area as
        # the inpaint mask produces a round skin sticker and can erase nearby
        # hair.  Filling the outer sclera contour also fills its pupil hole, so
        # every original eye pixel is removed while surrounding art remains
        # byte-identical to the canonical head.
        neutral_hsv = cv2.cvtColor(neutral_patch, cv2.COLOR_BGR2HSV)
        neutral_white = (
            (neutral_hsv[:, :, 1] < 85)
            & (neutral_hsv[:, :, 2] > 135)
        ).astype(np.uint8) * 255
        neutral_white = cv2.morphologyEx(
            neutral_white,
            cv2.MORPH_OPEN,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)),
        )
        white_count, white_labels, white_stats, white_centres = (
            cv2.connectedComponentsWithStats(neutral_white)
        )
        white_candidates = [
            index for index in range(1, white_count)
            if int(white_stats[index, cv2.CC_STAT_AREA])
            >= max(24, int(core_width * core_height * 0.10))
        ]
        if not white_candidates:
            log(f"  stylized blink source rejected: {side} canonical sclera was lost")
            return None
        # Prefer the component centred in the authored eye.  A crop near the
        # edge of a pale head can also contain the light studio background,
        # which is often larger but is not the sclera.
        target_x = core_x0 + core_width * 0.5
        target_y = core_y0 + core_height * 0.5
        white_index = min(
            white_candidates,
            key=lambda index: (
                ((float(white_centres[index, 0]) - target_x)
                 / max(core_width, 1)) ** 2
                + ((float(white_centres[index, 1]) - target_y)
                   / max(core_height, 1)) ** 2
                - float(white_stats[index, cv2.CC_STAT_AREA])
                  / max(core_width * core_height, 1) * 0.08
            ),
        )
        white_component = (
            (white_labels == white_index).astype(np.uint8) * 255
        )
        white_contours, _ = cv2.findContours(
            white_component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        if not white_contours:
            return None
        eye_fill = np.zeros_like(alpha, dtype=np.uint8)
        cv2.drawContours(
            eye_fill,
            [max(white_contours, key=cv2.contourArea)],
            -1,
            255,
            -1,
        )
        sclera_core_fill = eye_fill.copy()
        # Remove the complete thick illustrated outline, then protect every
        # unrelated canonical dark stroke outside a tighter sclera guard.  The
        # broader fill/feather no longer leaves a pale oval of the old eye, but
        # cannot consume a nearby brow or fringe tip.
        sclera_art_guard = cv2.dilate(
            sclera_core_fill,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11)),
        )
        transition_kernel = int(round(min(core_width, core_height) * 0.18))
        transition_kernel = max(17, min(31, transition_kernel)) | 1
        eye_fill = cv2.dilate(
            sclera_core_fill,
            cv2.getStructuringElement(
                cv2.MORPH_ELLIPSE,
                (transition_kernel, transition_kernel),
            ),
        )
        lid_mask = (labels == lid_index).astype(np.uint8) * 255
        lid_region = cv2.dilate(
            lid_mask,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)),
        )
        lid_centre_y = float(centres[lid_index, 1])
        relative_lid_y = (lid_centre_y - core_y0) / max(core_height, 1)
        shift_y = 0
        if relative_lid_y < 0.56 or relative_lid_y > 0.88:
            shift_y = int(round(
                core_y0 + core_height * 0.74 - lid_centre_y
            ))

        # Use provider pixels only for the reviewed lid stroke.  Reconstruct
        # the surrounding skin from the canonical face's own boundary: even a
        # colour-matched provider crop retains different lighting/texture and
        # reads as a circular patch at close-up scale.  The harmonic solution
        # is continuous with this exact avatar on the complete eye boundary.
        cleaned = _harmonic_stylized_skin(
            neutral_patch,
            eye_fill > 0,
        )
        if cleaned is None:
            log(f"  stylized blink source rejected: {side} skin fill was unstable")
            return None
        # A broad colour transition makes the generated/canonical skin join
        # imperceptible, but it may overlap a nearby authored fringe or brow.
        # Restore those canonical dark strokes outside the actual sclera/outline
        # guard; the pupil and open-eye outline remain inside the guard and are
        # intentionally replaced.
        canonical_dark = (
            (cv2.cvtColor(neutral_patch, cv2.COLOR_BGR2GRAY) < 100)
            & (eye_fill > 0)
            & ~(
                cv2.dilate(
                    sclera_core_fill,
                    cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (21, 21)),
                ) > 0
            )
        ).astype(np.uint8) * 255
        canonical_dark = cv2.dilate(
            canonical_dark,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)),
        )
        cleaned[canonical_dark > 0] = neutral_patch[canonical_dark > 0]
        translation = np.array([[1., 0., 0.], [0., 1., shift_y]])
        shifted_source = cv2.warpAffine(
            patch,
            translation,
            (patch_width, patch_height),
            flags=cv2.INTER_LANCZOS4,
            borderMode=cv2.BORDER_REPLICATE,
        )
        shifted_lid = cv2.warpAffine(
            lid_region,
            translation,
            (patch_width, patch_height),
            flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        )
        restore = (shifted_lid > 0) & (sclera_art_guard > 0)
        cleaned[restore] = shifted_source[restore]
        patch = cleaned

        # Publish alpha from the exact full sclera rather than the earlier
        # search crop.  This closes every white pixel and the complete outer
        # ink even when one side of a stylized eye sits outside the landmark
        # heuristic used to find the source lid.
        semantic_alpha = cv2.GaussianBlur(eye_fill, (0, 0), 9.0)
        # The original thick eye outline must be fully occluded; feather only
        # outside the guarded sclera.  Otherwise the open oval remains faintly
        # visible through two successive partial-alpha blends.
        semantic_alpha[eye_fill > 0] = 255

        # The plate is byte-identical to the canonical neutral throughout its
        # feather. Provider pixels reach only the semantic sclera interior;
        # this makes the edge delta exactly zero and prevents a circular skin
        # halo even on a dark Chat/Talk canvas.
        interior = (
            semantic_alpha.astype(np.float32) / 255.0
        )[:, :, None]
        patch = np.clip(
            patch.astype(np.float32) * interior
            + neutral_patch.astype(np.float32) * (1.0 - interior),
            0, 255).astype(np.uint8)
        feather = (semantic_alpha > 2) & (semantic_alpha < 24)
        if np.any(feather):
            seam_delta = np.abs(
                patch.astype(np.int16) - neutral_patch.astype(np.int16)).max(2)
            if float(np.percentile(seam_delta[feather], 99)) > 2.0:
                log(f"  stylized blink source rejected: {side} feather seam")
                return None
        prepared[side] = (box, np.dstack((patch, semantic_alpha)))

    os.makedirs(destination, exist_ok=True)
    result = {"mode": "semantic-eye-switch"}
    for side in blink.SIDES:
        box, rgba = prepared[side]
        filename = f"stylized-blink-{side}.png"
        cv2.imwrite(os.path.join(destination, filename), rgba,
                    [cv2.IMWRITE_PNG_COMPRESSION, 9])
        result[side] = {
            "src": f"assets/{filename}",
            "box": box,
        }
    log("  stylized semantic-eye blink plates published")
    return result


def _validate_current_face_layers(runtime, destination):
    """Prove a preserved bank can render every current upper-face layer.

    ``publish_pet_assets`` intentionally does not regenerate face sprites.  A
    A legacy bank lacking under-eye or forehead strips must therefore remain
    legacy (and ask for a source-backed rebuild) instead of being relabelled,
    where the renderer would silently skip its independent targets forever.
    """
    requirements = (
        ("eyes", "states", "eyelid"),
        ("brow", "dys", "brow"),
        ("forehead", "dys", "forehead"),
        ("eyebag", "ups", "under-eye"),
    )
    for key, positions, label in requirements:
        layer = runtime.get(key)
        if not isinstance(layer, dict):
            raise ValueError(f"runtime {label} layer is missing; cannot migrate to v{RUNTIME_VERSION}")
        values = layer.get(positions)
        if not isinstance(values, list) or not values:
            raise ValueError(f"runtime {label} metadata is missing; cannot migrate to v{RUNTIME_VERSION}")
        for side in ("l", "r"):
            sprite = layer.get(side)
            if not isinstance(sprite, dict):
                raise ValueError(f"runtime {label}_{side} metadata is missing; cannot migrate to v{RUNTIME_VERSION}")
            box = sprite.get("box")
            if not isinstance(box, list) or len(box) != 4:
                raise ValueError(f"runtime {label}_{side} box is missing; cannot migrate to v{RUNTIME_VERSION}")
            try:
                box_values = [float(value) for value in box]
            except (TypeError, ValueError):
                raise ValueError(f"runtime {label}_{side} box is invalid; cannot migrate to v{RUNTIME_VERSION}")
            if (not all(np.isfinite(value) for value in box_values)
                    or box_values[2] <= 0 or box_values[3] <= 0):
                raise ValueError(f"runtime {label}_{side} box is invalid; cannot migrate to v{RUNTIME_VERSION}")
            _runtime_face_asset(destination, sprite.get("src"), f"{label}_{side}")

    smile = runtime.get("smile")
    if not isinstance(smile, dict):
        raise ValueError(
            f"runtime laughter-mouth layer is missing; cannot migrate to v{RUNTIME_VERSION}")
    if (not isinstance(smile.get("states"), list) or not smile["states"]
            or not isinstance(smile.get("visemes"), list) or not smile["visemes"]):
        raise ValueError(
            f"runtime laughter-mouth metadata is missing; cannot migrate to v{RUNTIME_VERSION}")
    box = smile.get("box")
    try:
        box_values = [float(value) for value in box]
    except (TypeError, ValueError):
        box_values = []
    if (len(box_values) != 4 or not all(np.isfinite(value) for value in box_values)
            or box_values[2] <= 0 or box_values[3] <= 0):
        raise ValueError(
            f"runtime laughter-mouth box is invalid; cannot migrate to v{RUNTIME_VERSION}")
    _runtime_face_asset(destination, smile.get("src"), "laughter-mouth")

    emotion_mouth = runtime.get("emotion_mouth")
    if not isinstance(emotion_mouth, dict):
        raise ValueError(
            f"runtime emotion-mouth layer is missing; cannot migrate to v{RUNTIME_VERSION}")
    if (not isinstance(emotion_mouth.get("states"), list)
            or not emotion_mouth["states"]
            or not isinstance(emotion_mouth.get("visemes"), list)
            or not emotion_mouth["visemes"]
            or not isinstance(emotion_mouth.get("emotions"), list)
            or not emotion_mouth["emotions"]):
        raise ValueError(
            f"runtime emotion-mouth metadata is missing; cannot migrate to v{RUNTIME_VERSION}")
    emotion_box = emotion_mouth.get("box")
    try:
        emotion_box_values = [float(value) for value in emotion_box]
    except (TypeError, ValueError):
        emotion_box_values = []
    if (len(emotion_box_values) != 4
            or not all(np.isfinite(value) for value in emotion_box_values)
            or emotion_box_values[2] <= 0 or emotion_box_values[3] <= 0):
        raise ValueError(
            f"runtime emotion-mouth box is invalid; cannot migrate to v{RUNTIME_VERSION}")
    _runtime_face_asset(destination, emotion_mouth.get("src"), "emotion-mouth")


def _runtime_body_metadata(source):
    runtime = dict(source)
    runtime.pop("views", None)
    runtime.pop("turnaround", None)
    runtime.pop("motion_reference", None)
    if (str(runtime.get("head_composite") or "").strip().lower() != "replace"
            or type(runtime.get("head_handoff_version")) is not int
            or runtime.get("head_handoff_version")
            != STYLIZED_HEAD_HANDOFF_VERSION):
        runtime.pop("head_handoff_version", None)
    return runtime


def _body_pose(body_dir, log=print):
    """Skeleton joints of the standing plate, in body-plate pixels.

    Baked once and cached beside the body: the runtime classifies a click by
    its nearest bone segment (arm, hand, torso, leg), so the pet can react to
    the part that was actually touched instead of treating the whole
    silhouette as one button. Head stays mask-exact and is not part of this.
    """
    cache = os.path.join(body_dir, "pose.json")
    metadata = {}
    try:
        with open(os.path.join(body_dir, "body.json")) as handle:
            metadata = json.load(handle) or {}
    except (OSError, ValueError):
        pass
    front_source = os.path.basename(str(
        ((((metadata.get("views") or {}).get("front") or {}).get("source"))
         or "")))
    candidates = [front_source, "source-front.png", "source.png"]
    candidates.extend(
        name for name in sorted(os.listdir(body_dir))
        if name.startswith("source-front.") or name.startswith("source."))
    source = next((os.path.join(body_dir, name)
                   for name in candidates
                   if name and os.path.isfile(os.path.join(body_dir, name))), None)
    if not source:
        return None
    if os.path.isfile(cache) and os.path.getmtime(cache) >= os.path.getmtime(source):
        try:
            with open(cache) as handle:
                return json.load(handle)
        except (OSError, ValueError):
            pass
    import tempfile
    with tempfile.TemporaryDirectory() as work:
        pose_path = os.path.join(work, "pose.json")
        cutout.render(source, os.path.join(work, "cut.png"),
                      log=lambda _m: None, tight=True,
                      pose_destination=pose_path)
        try:
            with open(pose_path) as handle:
                pose = json.load(handle)
        except (OSError, ValueError):
            return None
    joints = {}
    for name, joint in (pose.get("joints") or {}).items():
        try:
            if float(joint.get("confidence", 0)) < 0.3:
                continue
            joints[name] = {
                "x": round(float(joint["x"]), 1),
                "y": round(float(joint["y"]), 1),
                "confidence": round(float(joint["confidence"]), 2),
            }
        except (KeyError, TypeError, ValueError):
            continue
    if len(joints) < 6:
        log("  body skeleton too sparse; part reactions limited to the head")
        return None
    result = {"joints": joints}
    with open(cache, "w") as handle:
        json.dump(result, handle, indent=1)
    log(f"  body skeleton baked: {len(joints)} joints")
    return result


def _publish_body_extras(body_dir, body_meta, destination, log):
    """Skeleton + limb-reaction strips for the standing plate.

    Strictly an enhancement: any failure here (a Vision miss on an unusual
    body, a degenerate skeleton) logs and leaves a runtime without part
    reactions rather than blocking the publish of a freshly generated body.
    """
    for name in os.listdir(destination):
        if name.startswith("react_") and name.endswith(".png"):
            os.remove(os.path.join(destination, name))
    try:
        pose = _body_pose(body_dir, log=log)
        if not pose:
            return
        body_meta["pose"] = pose
        plate = cv2.imread(os.path.join(destination, "body.png"),
                           cv2.IMREAD_UNCHANGED)
        if plate is None or plate.ndim != 3 or plate.shape[2] != 4:
            return
        reactions = {}
        for name, reaction in limbs.build(plate, pose, log=log).items():
            strip = f"react_{name}.png"
            cv2.imwrite(os.path.join(destination, strip),
                        np.vstack(reaction["patches"]),
                        [cv2.IMWRITE_PNG_COMPRESSION, 9])
            reactions[name] = {
                "src": f"assets/{strip}",
                "box": reaction["box"],
                "states": len(reaction["patches"]),
            }
        if reactions:
            body_meta["reactions"] = reactions
    except Exception as error:
        body_meta.pop("reactions", None)
        log(f"  part reactions skipped for this publish: {error}")


# Her definition on a phone, measured against the ProRes master (SSIM on
# the idle loop, 2026-08-03):
#
#   q:v=60 alpha=0.75   436 KB   0.9845   <- what shipped
#   q:v=75 alpha=0.95   980 KB   0.9902
#   q:v=85 alpha=0.95  1364 KB   0.9936   <- here
#   q:v=92 alpha=0.95  2396 KB   0.9960
#
# 85 cuts the error against the master by 59% for about a megabyte, and a
# phone fetches each clip once and keeps it. Past 85 the curve flattens
# while the file nearly doubles. The master is 720x1088 because that is
# the generator's ceiling, so this is the last real detail available -
# worth not throwing away in the encode.
HEVC_ALPHA_QUALITY = "0.95"
HEVC_VIDEO_QUALITY = "85"


def _hevc_alpha_for_web(source, destination, log=print):
    """WebKit refuses the ProRes-4444 alpha master (MEDIA_ERR 4 on the
    iPhone, 2026-08-02) - Safari's transparent-video format is HEVC with
    alpha (hvc1 via VideoToolbox). Encode once beside the master, reuse
    on every later publish."""
    # The quality lives in the cache NAME: changing the settings must
    # invalidate every twin ever made, and an mtime check cannot see that.
    cache = (source[:-len(".mov")]
             + f".q{HEVC_VIDEO_QUALITY}a{HEVC_ALPHA_QUALITY}.hevc.mov")
    fresh = (os.path.isfile(cache)
             and os.path.getmtime(cache) >= os.path.getmtime(source))
    if not fresh:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            return False
        result = subprocess.run(
            [ffmpeg, "-y", "-v", "error", "-i", source,
             "-c:v", "hevc_videotoolbox", "-allow_sw", "1",
             "-alpha_quality", HEVC_ALPHA_QUALITY,
             "-q:v", HEVC_VIDEO_QUALITY,
             "-tag:v", "hvc1", "-pix_fmt", "bgra", "-an", cache],
            capture_output=True, text=True)
        if result.returncode != 0 or not os.path.isfile(cache):
            log(f"  hevc-alpha encode failed: {result.stderr.strip()[:200]}")
            try:
                os.remove(cache)
            except OSError:
                pass
            return False
        log(f"  hevc-alpha web twin encoded: {os.path.basename(cache)}")
    shutil.copy2(cache, destination)
    return True


def _publish_motion(directory, destination, log):
    for name in os.listdir(destination):
        if name.startswith("motion-") and name.endswith(".png"):
            os.remove(os.path.join(destination, name))
    motion_dir = os.path.join(directory, "motion")
    manifest_path = os.path.join(motion_dir, "motion.json")
    if not os.path.isfile(manifest_path):
        return None
    with open(manifest_path) as handle:
        source = json.load(handle)
    runtime = {"v": source.get("v", 1)}
    published = False
    for name in os.listdir(destination):
        if name.startswith("motion-") and name.endswith((".webm", ".mov")):
            os.remove(os.path.join(destination, name))
    for kind in ("walk", "idle", "move"):
        clip = dict(source.get(kind) or {})
        if not clip.get("sheets"):
            continue
        # The same take ships in every decode the fleet needs: HEVC-alpha mov
        # for WebKit on real devices and the PNG atlas as the universal
        # fallback. Idle/move additionally use VP9-alpha in Chromium. Walk
        # deliberately remains atlas-driven on desktop so its animation phase
        # stays locked to window travel, but iOS still requires its HEVC twin.
        stream = clip.get("alpha_stream")
        stream_path = os.path.join(motion_dir, str(stream or ""))
        if stream and os.path.isfile(stream_path):
            stream_name = f"motion-{kind}.webm"
            shutil.copy2(stream_path, os.path.join(destination, stream_name))
            clip["alpha_stream"] = f"assets/{stream_name}"
        else:
            clip.pop("alpha_stream", None)
        hevc = clip.get("alpha_video")
        hevc_path = os.path.join(motion_dir, str(hevc or ""))
        hevc_name = f"motion-{kind}.mov"
        if (hevc and os.path.isfile(hevc_path)
                and not hevc_path.endswith(".hevc.mov")
                and _hevc_alpha_for_web(
                    hevc_path, os.path.join(destination, hevc_name), log)):
            clip["alpha_stream_hevc"] = f"assets/{hevc_name}"
        else:
            clip.pop("alpha_stream_hevc", None)
        sheets = []
        for index, sheet in enumerate(clip.get("sheets") or []):
            name = f"motion-{kind}-{index}.png"
            shutil.copy2(os.path.join(motion_dir, sheet["image"]),
                         os.path.join(destination, name))
            sheets.append({**sheet, "image": f"assets/{name}"})
        clip["sheets"] = sheets
        poster_name = f"motion-{kind}-poster.png"
        if clip.get("poster") and os.path.isfile(os.path.join(motion_dir, clip["poster"])):
            shutil.copy2(os.path.join(motion_dir, clip["poster"]),
                         os.path.join(destination, poster_name))
            clip["poster"] = f"assets/{poster_name}"
        clip.pop("alpha_video", None)
        clip.pop("source_loop", None)
        runtime[kind] = clip
        published = True
    if not published:
        return None
    log("  alpha Pet motion published")
    return runtime


def publish_pet_assets(slug, runtime_dir=None, log=print):
    """Add Pet layers without rebuilding the calibrated face bank."""
    directory = reg.adir(slug)
    destination = runtime_dir or os.path.join(directory, "runtime")
    manifest_path = os.path.join(destination, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise ValueError("avatar runtime is missing")
    with open(manifest_path) as handle:
        runtime = json.load(handle)
    source_manifest = reg.read_manifest(slug) or {}
    source_medium = _source_medium(source_manifest)
    cutout_meta = cutout.render(
        os.path.join(directory, "keyframe.png"),
        os.path.join(destination, "cutout.png"),
        log=log,
        allow_stylized=source_medium != "photograph",
    )
    body_meta = None
    body_dir = os.path.join(directory, "body")
    body_manifest = os.path.join(body_dir, "body.json")
    if os.path.isfile(body_manifest):
        with open(body_manifest) as handle:
            body_meta = _runtime_body_metadata(json.load(handle))
        shutil.copy2(os.path.join(body_dir, "body.png"), os.path.join(destination, "body.png"))
        shutil.copy2(os.path.join(body_dir, "head-mask.png"), os.path.join(destination, "head-mask.png"))
        body_meta["image"] = "assets/body.png"
        body_meta["head_mask"] = "assets/head-mask.png"
        clear_mask = str(body_meta.get("head_clear_mask") or "")
        clear_mask_source = os.path.join(body_dir, os.path.basename(clear_mask))
        if clear_mask and os.path.isfile(clear_mask_source):
            shutil.copy2(clear_mask_source, os.path.join(destination, "head-clear-mask.png"))
            body_meta["head_clear_mask"] = "assets/head-clear-mask.png"
        else:
            body_meta.pop("head_clear_mask", None)
            body_meta.pop("head_clear_quality", None)
            body_meta.pop("head_handoff_version", None)
            try:
                os.remove(os.path.join(destination, "head-clear-mask.png"))
            except FileNotFoundError:
                pass
        _publish_body_extras(body_dir, body_meta, destination, log)
    else:
        for name in ("body.png", "head-mask.png", "head-clear-mask.png"):
            try:
                os.remove(os.path.join(destination, name))
            except FileNotFoundError:
                pass
    motion_meta = _publish_motion(directory, destination, log)
    # Face sprites are preserved on this no-viseme road.  Never declare the
    # bundle current until the legacy bank proves it has every layer that v22
    # actually drives, especially the forehead and independent under-eye strips.
    if _runtime_version(runtime.get("v")) < RUNTIME_VERSION:
        _validate_current_face_layers(runtime, destination)
    neutral_reference = ((((runtime.get("frames") or {}).get("sil") or {})
                          .get("open")) or "")
    neutral_path = os.path.join(
        destination, os.path.basename(str(neutral_reference)))
    keyframe_path = os.path.join(directory, "keyframe.png")
    keyframe = (cv2.imread(keyframe_path) if os.path.isfile(keyframe_path)
                else None)
    # A provider may repaint a cartoon's whole face even for the nominal
    # closed-mouth viseme.  That was the static outer face / moving inner face
    # artifact: every runtime part was calibrated against a different neutral
    # identity.  Keep the authored canonical keyframe as the stylized neutral;
    # mouth animation remains the bounded viseme crop in the web compositor.
    if (_is_stylized_source_medium(source_medium) and keyframe is not None
            and neutral_reference):
        cv2.imwrite(neutral_path, keyframe,
                    [cv2.IMWRITE_JPEG_QUALITY, 92])
        neutral = keyframe
    else:
        neutral = (cv2.imread(neutral_path) if neutral_reference
                   and os.path.isfile(neutral_path) else None)
    if neutral is None:
        neutral = keyframe
    stylized_mouth = None
    if (_is_stylized_source_medium(source_medium) and keyframe is not None):
        mouth_landmarks, _, _ = face.detect_for_intake(keyframe)
        stylized_mouth = _stylized_mouth_geometry(
            keyframe.shape, mouth_landmarks)
        # This refresh path intentionally retains the existing face bank.  Its
        # authored per-viseme registration therefore remains authoritative.
        previous_mouth = runtime.get("stylized_mouth")
        previous_offsets = (previous_mouth.get("viseme_x_offsets")
                            if isinstance(previous_mouth, dict) else None)
        if stylized_mouth is not None and isinstance(previous_offsets, dict):
            stylized_mouth["viseme_x_offsets"] = previous_offsets
    stylized_blink = _publish_stylized_blink_source(
        neutral, directory, runtime.get("eyes"), destination,
        source_medium, log=log)
    runtime.update(
        # This branch preserves a proven face bank when an imported avatar no
        # longer carries source visemes.  It must still cross the current
        # runtime schema boundary: v16 otherwise kept being copied forever
        # and never acquired the normalized ``rig_profile.eyebags`` control.
        v=max(RUNTIME_VERSION, _runtime_version(runtime.get("v"))),
        rig_profile=_runtime_rig_profile(source_manifest, runtime),
        cutout=cutout_meta,
        body=body_meta,
        motion=motion_meta,
        source_medium=source_medium,
        built=source_manifest.get("updated", runtime.get("built")),
    )
    if stylized_blink:
        runtime["stylized_blink"] = stylized_blink
    else:
        runtime.pop("stylized_blink", None)
    if stylized_mouth:
        runtime["stylized_mouth"] = stylized_mouth
    else:
        runtime.pop("stylized_mouth", None)
    temporary = manifest_path + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(runtime, handle, indent=1)
    os.replace(temporary, manifest_path)
    log("Pet runtime layers published")
    return runtime


def export(slug, dest, quality=92, states=blink.N_STATES, log=print,
           source_dir=None, manifest_data=None):
    d = source_dir or reg.adir(slug)
    # Persistent, avatar-level assets (the body plates and motion takes)
    # live in the avatar's HOME dir. A calibration recompose exports from
    # a temporary stage that only holds keyframe+visemes - resolving body/
    # motion against `d` there published runtimes with neither, so every
    # facial rebuild silently stripped the full-body set (vvn, 2026-08-02;
    # carol's 'body no longer attached' was this too).
    home = reg.adir(slug)
    m = manifest_data or reg.read_manifest(slug)
    if not m or m.get("status") != "ready":
        raise ValueError(f"{slug} is not built yet")
    source_medium = _source_medium(m)
    allow_stylized = source_medium != "photograph"
    vis = os.path.join(d, "visemes")
    key = cv2.imread(os.path.join(d, "keyframe.png"))
    shut = cv2.imread(os.path.join(vis, "v_blink.jpg"))
    if shut is None:
        raise ValueError("missing blink frame")

    log("synthesising eyelid travel")
    lids = blink.build(
        key, shut, n=states, log=log,
        allow_stylized=allow_stylized)

    # Measure exactly which pixels the viseme bank repaints, and forbid the
    # cheek layer from touching them.  A dilated lip hull is a guess; this is
    # the ground truth, and a cheek patch that overlapped the mouth would stamp
    # stale keyframe pixels over a moving jaw.
    touched = np.zeros(key.shape[:2], np.float32)
    for shape in set(NAME_MAP.values()):
        v = cv2.imread(os.path.join(vis, f"v_{shape}.jpg"))
        if v is not None:
            touched = np.maximum(
                touched, np.abs(v.astype(np.float32) - key.astype(np.float32)).max(2))
    avoid = (touched > 6).astype(np.float32)

    log("synthesising gaze, brow, forehead, cheek and under-eye layers")
    if allow_stylized:
        klm, _, _metadata = face.detect_for_intake(key)
    else:
        klm, _ = face.detect(key)
    if klm is None:
        raise ValueError("no face landmarks on keyframe")
    expr = expression.build(key, klm, avoid=avoid, log=log)

    os.makedirs(dest, exist_ok=True)
    for f in os.listdir(dest):
        if f.endswith((".jpg", ".png", ".json")):
            os.remove(os.path.join(dest, f))

    H, W = key.shape[:2]
    log("extracting transparent person silhouette")
    cutout_meta = cutout.render(
        os.path.join(d, "keyframe.png"),
        os.path.join(dest, "cutout.png"),
        log=log,
        allow_stylized=allow_stylized,
    )
    body_meta = None
    body_dir = os.path.join(home, "body")
    body_manifest = os.path.join(body_dir, "body.json")
    if os.path.isfile(body_manifest):
        with open(body_manifest) as handle:
            body_meta = _runtime_body_metadata(json.load(handle))
        shutil.copy2(os.path.join(body_dir, "body.png"), os.path.join(dest, "body.png"))
        shutil.copy2(os.path.join(body_dir, "head-mask.png"), os.path.join(dest, "head-mask.png"))
        body_meta["image"] = "assets/body.png"
        body_meta["head_mask"] = "assets/head-mask.png"
        clear_mask = str(body_meta.get("head_clear_mask") or "")
        clear_mask_source = os.path.join(body_dir, os.path.basename(clear_mask))
        if clear_mask and os.path.isfile(clear_mask_source):
            shutil.copy2(clear_mask_source, os.path.join(dest, "head-clear-mask.png"))
            body_meta["head_clear_mask"] = "assets/head-clear-mask.png"
        else:
            body_meta.pop("head_clear_mask", None)
            body_meta.pop("head_clear_quality", None)
            body_meta.pop("head_handoff_version", None)
            try:
                os.remove(os.path.join(dest, "head-clear-mask.png"))
            except FileNotFoundError:
                pass
        _publish_body_extras(body_dir, body_meta, dest, log)
        log("  full-body plate published")
    motion_meta = _publish_motion(home, dest, log)

    frames, names, viseme_bank = {}, [], []
    for rt, shape in NAME_MAP.items():
        src = os.path.join(vis, f"v_{shape}.jpg")
        if not os.path.exists(src):
            log(f"  {rt}: no {shape} frame, skipped")
            continue
        img = cv2.imread(src)
        out = os.path.join(dest, f"{rt}_open.jpg")
        # Stylized mouths are composited over one immutable identity plate in
        # Chat/Talk.  Publish the canonical keyframe for that neutral instead
        # of a provider-redrawn `v_closed` face; photographs keep the original
        # viseme frame byte-for-byte through this branch.
        published = (key if rt == "sil"
                     and _is_stylized_source_medium(source_medium) else img)
        cv2.imwrite(out, published, [cv2.IMWRITE_JPEG_QUALITY, quality])
        frames[rt] = dict(open=f"assets/{rt}_open.jpg")
        names.append(rt)
        viseme_bank.append((rt, img))

    log("synthesising viseme-safe laughter mouth states")
    smile = expression.build_smile(key, klm, viseme_bank, log=log)
    smile_path = os.path.join(dest, "smile.png")
    cv2.imwrite(smile_path, np.vstack(smile["patches"]),
                [cv2.IMWRITE_PNG_COMPRESSION, 9])
    smile_meta = dict(src="assets/smile.png", box=smile["box"],
                      states=smile["states"], visemes=smile["visemes"])
    log(f"  smile.png  {len(smile['patches'])} states, "
        f"{os.path.getsize(smile_path)/1024:.0f} KB")
    emotion_mouth = expression.build_emotion_mouths(
        key, klm, viseme_bank, log=log)
    emotion_mouth_path = os.path.join(dest, "emotion-mouth.png")
    cv2.imwrite(emotion_mouth_path, np.vstack(emotion_mouth["patches"]),
                [cv2.IMWRITE_PNG_COMPRESSION, 9])
    emotion_mouth_meta = dict(
        src="assets/emotion-mouth.png", box=emotion_mouth["box"],
        states=emotion_mouth["states"], emotions=emotion_mouth["emotions"],
        visemes=emotion_mouth["visemes"])
    log(f"  emotion-mouth.png  {len(emotion_mouth['patches'])} states, "
        f"{os.path.getsize(emotion_mouth_path)/1024:.0f} KB")

    def _strip(layer, prefix, meta):
        for side in blink.SIDES:
            e = layer[side]
            p = os.path.join(dest, f"{prefix}_{side}.png")
            cv2.imwrite(p, np.vstack(e["patches"]), [cv2.IMWRITE_PNG_COMPRESSION, 9])
            meta[side] = dict(src=f"assets/{prefix}_{side}.png", box=e["box"])
            log(f"  {prefix}_{side}.png  {len(e['patches'])} states, "
                f"{os.path.getsize(p)/1024:.0f} KB")
        return meta

    eyes = _strip(lids["eyes"], "eye",
                  dict(states=[round(t, 4) for t in lids["states"]]))
    neutral = (key if _is_stylized_source_medium(source_medium) else
               next((image for name, image in viseme_bank if name == "sil"), key))
    stylized_mouth = (_stylized_mouth_geometry(key.shape, klm)
                      if _is_stylized_source_medium(source_medium) else None)
    if stylized_mouth is not None:
        stylized_mouth["viseme_x_offsets"] = smile["viseme_x_offsets"]
    stylized_blink = _publish_stylized_blink_source(
        neutral, home, eyes, dest, source_medium, log=log)
    gaze = _strip(expr["gaze"], "gaze",
                  dict(dxs=expr["gaze"]["dxs"], dys=expr["gaze"]["dys"]))
    brow = _strip(expr["brow"], "brow", dict(dys=expr["brow"]["dys"],
                                             sqs=expr["brow"].get("sqs", [0.0])))
    forehead = _strip(
        expr["forehead"], "forehead",
        dict(dys=expr["forehead"]["dys"],
             sqs=expr["forehead"].get("sqs", [0.0])))
    cheek = _strip(expr["cheek"], "cheek", dict(ups=expr["cheek"]["ups"]))
    eyebag = (_strip(expr["eyebag"], "eyebag", dict(ups=expr["eyebag"]["ups"]))
              if expr.get("eyebag") else None)

    timing = dict(close=blink.CLOSE, hold=blink.HOLD, open=blink.OPEN,
                  settle=blink.SETTLE, creep=blink.CREEP)
    # v17 adds the independent `eyebags` calibration target consumed by the
    # desktop runtime. The strips already existed; versioning makes old
    # bundles refresh so their normalized rig profile reaches the renderer.
    manifest = dict(v=RUNTIME_VERSION, w=W, h=H, avatar=dict(slug=slug, name=m["name"]),
                    visemes=names, frames=frames, eyes=eyes, gaze=gaze, brow=brow,
                    forehead=forehead, smile=smile_meta,
                    emotion_mouth=emotion_mouth_meta,
                    cheek=cheek, eyebag=eyebag,
                    neck=expression.neck(klm), cutout=cutout_meta,
                    body=body_meta, motion=motion_meta, blink=timing,
                    source_medium=source_medium,
                    stylized_mouth=stylized_mouth,
                    stylized_blink=stylized_blink,
                    built=m.get("updated"), quality=m.get("quality"),
                    rig_profile=_runtime_rig_profile(m))
    with open(os.path.join(dest, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    log(f"exported {len(names)} visemes, {states} lid states, "
        f"{len(gaze['dxs']) * len(gaze['dys'])} gaze states, "
        f"{len(brow['dys'])} brow/forehead and {len(cheek['ups'])} cheek states "
        f"per side -> {dest}")
    return manifest


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("slug", nargs="?")
    ap.add_argument("--dest", default=os.path.expanduser("~/OpenClamStudio/web/assets"))
    a = ap.parse_args()
    export(a.slug or reg.get_active(), a.dest)
