"""Turn any uploaded portrait into a clean square keyframe for the viseme set.

Why a dedicated prep step: the first prototype set was built straight off a video
still whose head carried yaw + ~13 deg roll.  Every generated mouth then had to
fight the model's frontal prior.  Prep now measures the pose up front, crops a
face-centred square at the resolution the mouth actually needs, and reports
whether the source is frontal enough to build from.
"""
import os, json, subprocess, tempfile
import numpy as np, cv2
from . import cutout, face

# OpenCV has no HEIC/HEIF codec, but every iPhone portrait arrives as one.
# sips ships with macOS, so the decode needs no Python imaging dependency.
HEIC_EXTENSIONS = (".heic", ".heif")


def decode_heic(src_path, out_path):
    result = subprocess.run(
        ["/usr/bin/sips", "-s", "format", "png", src_path, "--out", out_path],
        capture_output=True, text=True, timeout=120)
    if result.returncode or not os.path.isfile(out_path) \
            or os.path.getsize(out_path) == 0:
        detail = (result.stderr or result.stdout or "").strip()[-300:]
        raise ValueError(
            "could not decode this photo with macOS sips"
            + (f": {detail}" if detail else ""))
    return out_path


def read_image_bgr(src_path):
    """cv2.imread, with a sips fallback: iPhone photos are often HEIC even
    when the file name claims .jpg, and OpenCV silently returns None on
    containers it cannot parse."""
    img = cv2.imread(src_path, cv2.IMREAD_COLOR)
    if img is not None:
        return img
    descriptor, converted = tempfile.mkstemp(suffix=".png")
    os.close(descriptor)
    try:
        decode_heic(src_path, converted)
        return cv2.imread(converted, cv2.IMREAD_COLOR)
    except ValueError:
        return None
    finally:
        if os.path.exists(converted):
            os.remove(converted)

KEY_SIZE = 1024          # gpt-image-2 native square - max mouth pixels
FACE_FRAC = 0.46         # face width as a fraction of the keyframe
EYE_LINE = 0.40          # eye line this far down the keyframe
CROWN_CLEARANCE = 0.055  # empty band the hair must keep above it, as a fraction
                         # of the keyframe.  The runtime nods the head about a
                         # neck pivot below the frame, so the crown travels
                         # ~1.5x the eye line: a plate that merely touches the
                         # top edge clips on every idle breath.
HAIR_ABOVE_EYES = 1.05   # eye line to top of hair, in face-oval widths.  Only a
                         # fallback, used when no silhouette is available.


def silhouette_top(img, lm, log=None):
    """Topmost head row of the person silhouette, or None if unavailable.

    The face oval stops at the hairline, so landmarks cannot say where a
    bouffant, a bun or a high ponytail ends.  macOS Vision segments the whole
    person, which is the only local signal that knows about hair volume.
    """
    handle, source = tempfile.mkstemp(suffix=".png")
    os.close(handle)
    handle, mask = tempfile.mkstemp(suffix=".png")
    os.close(handle)
    try:
        if not cv2.imwrite(source, img):
            return None
        if cutout.render(source, mask, log=log or (lambda *_: None)) is None:
            return None
        rgba = cv2.imread(mask, cv2.IMREAD_UNCHANGED)
        if rgba is None or rgba.ndim != 3 or rgba.shape[2] != 4:
            return None
        oval = lm[face.FACE_OVAL]
        fw = float(oval[:, 0].max() - oval[:, 0].min())
        cx = float(oval[:, 0].mean())
        # Only the column band around the head: a raised arm or a bystander at
        # the edge of the frame must never pass for a hairline.
        left = max(0, int(round(cx - fw)))
        right = min(rgba.shape[1], int(round(cx + fw)) + 1)
        rows = np.where((rgba[:, left:right, 3] > 8).any(axis=1))[0]
        return float(rows.min()) if rows.size else None
    finally:
        for path in (source, mask):
            try:
                os.remove(path)
            except OSError:
                pass


def _border_colour(img):
    """Median colour of the image border - the backdrop, in practice."""
    edges = np.concatenate([img[:2].reshape(-1, 3), img[-2:].reshape(-1, 3),
                            img[:, :2].reshape(-1, 3), img[:, -2:].reshape(-1, 3)])
    return tuple(float(value) for value in np.median(edges, axis=0))


def square_crop(img, lm, crown_y=None):
    """Face-centred square crop box (x0, y0, size).

    Two things used to cut the crown off.  The eye line alone decided the top
    edge, which leaves only 0.87 face-widths above the eyes - fine for a crop
    cut, nowhere near enough for hair volume.  And the box was then clamped
    into the image, so a window that did reach high enough silently slid back
    DOWN instead of overhanging.  The crown left the frame with no warning
    either way.  Now the hair sets the ceiling and the caller pads, so the
    framing the geometry asked for is the framing that ships.
    """
    oval = lm[face.FACE_OVAL]
    fw = float(oval[:, 0].max() - oval[:, 0].min())
    cx = float(oval[:, 0].mean())
    eye_y = float((lm[face.EYE_L_OUT][1] + lm[face.EYE_R_OUT][1]) / 2)

    size = int(round(fw / FACE_FRAC))
    if crown_y is None:
        crown_y = eye_y - fw * HAIR_ABOVE_EYES
    # The crown, not the eye line, owns the top edge whenever the hair is tall.
    top = min(eye_y - size * EYE_LINE, crown_y - size * CROWN_CLEARANCE)
    return int(round(cx - size / 2)), int(round(top)), size


def take_square(img, x0, y0, size, top_fill=None):
    """Crop, extending the source wherever the box overhangs it.

    Sides and bottom replicate the edge, which is seamless on the plain
    backdrops these portraits use.  The top can be told to fill with a flat
    colour instead: when the photo itself already cuts the hair, replicating
    that row would smear hair upward and hand the cut-out a fake crown.
    """
    H, W = img.shape[:2]
    left, top = max(0, -x0), max(0, -y0)
    right, bottom = max(0, x0 + size - W), max(0, y0 + size - H)
    if left or top or right or bottom:
        img = cv2.copyMakeBorder(img, top, bottom, left, right,
                                 cv2.BORDER_REPLICATE)
        if top and top_fill is not None:
            img[:top] = top_fill
        x0, y0 = x0 + left, y0 + top
    return img[y0:y0 + size, x0:x0 + size]


def _stylized_reference_square(img, detection_crop):
    """Expand the proven cartoon detection crop into a square reference.

    This retains more of the illustration than the detector window while
    guaranteeing that the already-validated face stays inside.  Whenever the
    source has enough room the square remains wholly in-image, avoiding the
    conspicuous letterbox bands a generic contain operation would add.
    """
    height, width = img.shape[:2]
    crop_width = int(detection_crop["width"])
    crop_height = int(detection_crop["height"])
    size = max(crop_width, crop_height)
    centre_x = float(detection_crop["x"]) + crop_width / 2.0
    centre_y = float(detection_crop["y"]) + crop_height / 2.0
    x0 = int(round(centre_x - size / 2.0))
    y0 = int(round(centre_y - size / 2.0))
    if size <= width:
        x0 = min(max(0, x0), width - size)
    if size <= height:
        y0 = min(max(0, y0), height - size)
    square = take_square(img, x0, y0, size, _border_colour(img))
    return square, x0, y0, size


def _contained_reference_square(img):
    """Place a complete illustrated head on a square background.

    A strict detector can recognize a large cartoon on the provider's full
    square and then lose it after the ordinary photographic face crop.  That
    crop also cuts identity-bearing hats and exaggerated hair because neither
    is represented by the face oval.  Canonical illustration renders are
    already framed as complete heads, so contain the whole render instead of
    re-cropping it around human proportions.  The returned origin preserves
    the same coordinate contract as ``take_square`` for landmark projection.
    """
    height, width = img.shape[:2]
    size = max(height, width)
    x0 = int(round((width - size) / 2.0))
    y0 = int(round((height - size) / 2.0))
    canvas = np.empty((size, size, 3), dtype=img.dtype)
    canvas[:] = _border_colour(img)
    left, top = -x0, -y0
    canvas[top:top + height, left:left + width] = img
    return canvas, x0, y0, size


_SOURCE_MEDIUM_OVERRIDES = frozenset({
    "photograph", "illustration", "3d render",
})


def _source_medium_override(value):
    """Validate one owner-selected intake lane without accepting aliases.

    Provider/body labels have historically accumulated aliases such as
    ``soft-3d`` and ``cartoon``.  The intake control is deliberately smaller:
    its three visible choices map to three stable manifest values, so a typo or
    future UI value cannot silently lower the photographic quality gates.
    """
    if value is None or not str(value).strip():
        return None
    medium = str(value).strip().lower()
    if medium not in _SOURCE_MEDIUM_OVERRIDES:
        raise ValueError(
            "source medium must be photograph, illustration, or 3d render")
    return medium


def build_keyframe(src_path, out_path, diag_dir=None, allow_stylized=False,
                   source_medium=None):
    img = read_image_bgr(src_path)
    if img is None:
        raise ValueError(f"could not read image: {src_path}")
    detection = None
    if allow_stylized:
        lm, M, detection = face.detect_for_intake(img)
    else:
        lm, M = face.detect(img)
    if lm is None:
        raise ValueError("no face detected in the uploaded image")

    # The local classifier remains valuable evidence, but an explicit owner
    # choice is authoritative.  Apply it before crop policy is selected so a
    # 2-D cartoon gets the same complete-head preservation even when its soft
    # shading happened to look photographic to the heuristic.
    selected_medium = _source_medium_override(source_medium)
    if selected_medium:
        detection = dict(detection or {})
        detected_medium = detection.get("source_medium", "unknown")
        detection["detected_source_medium"] = detected_medium
        detection["source_medium"] = selected_medium
        detection["source_medium_source"] = "user"

    crop_fallback = bool(detection and
                         detection.get("detection_mode") == "crop-fallback")
    fallback_illustration = bool(
        crop_fallback and
        str(detection.get("source_medium") or "").lower() in {
            "illustration", "cartoon", "drawing"})
    strict_illustration = bool(
        detection and not crop_fallback and
        detection.get("source_medium") == "illustration")
    if fallback_illustration:
        # The crop detector proves the face topology, not the visual extent of
        # a drawn character.  Its window can omit a wide hat brim, exaggerated
        # hair, ears or other identity-bearing linework.  Once the independent
        # medium classifier is confident this is artwork, retain the complete
        # provider reference and project the already-approved source mesh into
        # it.  Do not re-run the human full-frame detector: that known failure
        # is why the bounded fallback was needed.
        crop, x0, y0, size = _contained_reference_square(img)
        crown_y = None
    elif crop_fallback:
        # An uncertain or photographic fallback still uses the proven detector
        # window.  Containing an arbitrary full scene could shrink its face or
        # introduce unrelated people and props into the provider reference.
        crop, x0, y0, size = _stylized_reference_square(
            img, detection["detection_crop"])
        crown_y = None
    elif strict_illustration:
        # The full provider render is the reliable strict-detection frame.
        # Keep it intact; a human-proportion crop can both remove headwear and
        # make MediaPipe lose an otherwise valid oversized illustrated face.
        crop, x0, y0, size = _contained_reference_square(img)
        crown_y = None
    else:
        crown_y = silhouette_top(img, lm)
        x0, y0, size = square_crop(img, lm, crown_y)
        clipped = crown_y is not None and crown_y <= 1
        crop = take_square(img, x0, y0, size,
                           _border_colour(img) if clipped else None)
    interp = cv2.INTER_AREA if size > KEY_SIZE else cv2.INTER_LANCZOS4
    key = cv2.resize(crop, (KEY_SIZE, KEY_SIZE), interpolation=interp)
    cv2.imwrite(out_path, key, [cv2.IMWRITE_PNG_COMPRESSION, 3])

    if crop_fallback or strict_illustration:
        # Both paths already carry a source-space mesh approved by
        # detect_for_intake.  Project that proven geometry through the exact
        # square transform instead of asking the strict human detector to find
        # the face again after an illustrated head was contained.  The latter
        # can lose a perfectly valid oversized cartoon simply because padding
        # changed its apparent scale.
        scale = KEY_SIZE / float(size)
        klm = lm.copy()
        klm[:, 0] = (klm[:, 0] - x0) * scale
        klm[:, 1] = (klm[:, 1] - y0) * scale
        kM = M
    else:
        klm, kM = face.detect(key)
        if klm is None:
            raise ValueError("face lost after cropping - try a less tightly cropped photo")
    m = face.metrics(klm, kM)

    lip = klm[face.OUTER_LIP]
    m["mouth_width_px"] = float(lip[:, 0].max() - lip[:, 0].min())
    m["crop"] = dict(x0=x0, y0=y0, size=size, source=[int(img.shape[1]), int(img.shape[0])])
    key_crown = (None if crop_fallback or strict_illustration
                 else silhouette_top(key, klm))
    m["source_crown_y"] = None if crown_y is None else float(crown_y)
    m["crown_clearance"] = (None if key_crown is None
                            else round(float(key_crown) / KEY_SIZE, 4))
    m["warnings"] = warnings_for(m)
    if detection:
        m["detection_mode"] = detection.get("detection_mode", "strict")
        m["source_medium"] = detection.get("source_medium", "unknown")
        if detection.get("detected_source_medium") is not None:
            m["detected_source_medium"] = detection["detected_source_medium"]
        if detection.get("source_medium_source"):
            m["source_medium_source"] = detection["source_medium_source"]
        m["medium_score"] = detection.get("medium_score")
        if detection.get("medium_features"):
            m["medium_features"] = detection["medium_features"]
    if crop_fallback:
        m["detection_crop"] = detection["detection_crop"]
        m["topology"] = detection["topology"]
        if m.get("source_medium") == "illustration":
            m["warnings"].append(
                "Cartoon face recognized with compatibility mode; the build will "
                "preserve its art style and create a trackable animation head")
        else:
            m["warnings"].append(
                "Face recognized with expanded crop search; the build will normalize "
                "it into a strictly trackable animation head")

    if diag_dir:
        os.makedirs(diag_dir, exist_ok=True)
        vis = key.copy()
        for idx, col in ((face.OUTER_LIP, (120, 255, 140)), (face.EYE_L, (255, 190, 90)),
                         (face.EYE_R, (255, 190, 90)), (face.RIGID, (110, 130, 255))):
            for p in klm[idx]:
                cv2.circle(vis, tuple(np.int32(p)), 2, col, -1)
        txt = (f"yaw {m['yaw']:+.1f}  pitch {m['pitch']:+.1f}  roll {m['roll']:+.1f}   "
               f"foreshortening {m['foreshortening']:.2f}   mouth {m['mouth_width_px']:.0f}px")
        cv2.rectangle(vis, (0, 0), (KEY_SIZE, 40), (18, 18, 22), -1)
        cv2.putText(vis, txt, (12, 27), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (120, 255, 140), 1, cv2.LINE_AA)
        cv2.imwrite(os.path.join(diag_dir, "01_keyframe_landmarks.jpg"), vis,
                    [cv2.IMWRITE_JPEG_QUALITY, 92])
    return m


def warnings_for(m):
    """Human-readable quality gates - shown in the UI before a build is spent."""
    w = []
    if m["yaw"] is not None and abs(m["yaw"]) > 8:
        w.append(f"head is turned {abs(m['yaw']):.0f} deg off-axis - a front-facing photo "
                 f"gives noticeably better mouth shapes")
    if m["roll"] is not None and abs(m["roll"]) > 8:
        w.append(f"head is tilted {abs(m['roll']):.0f} deg")
    if abs(m["foreshortening"] - 1.0) > 0.25:
        w.append(f"mouth is foreshortened (ratio {m['foreshortening']:.2f}, frontal is 1.00)")
    if m["mouth_width_px"] < 120:
        w.append(f"mouth is only {m['mouth_width_px']:.0f}px wide - crop tighter on the face")
    if m.get("source_crown_y") is not None and m["source_crown_y"] <= 1:
        w.append("the photo itself cuts the top of the hair - the crown cannot "
                 "be recovered, use a shot with space above the head")
    clearance = m.get("crown_clearance")
    if clearance is not None and clearance < CROWN_CLEARANCE * 0.5:
        w.append(f"only {clearance * 100:.1f}% headroom above the hair - the "
                 f"crown will clip as soon as the head moves")
    return w
