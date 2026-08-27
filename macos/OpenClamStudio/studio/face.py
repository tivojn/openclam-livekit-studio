"""MediaPipe FaceLandmarker wrapper + the landmark groups the pipeline needs.

mediapipe 0.10.35 dropped mp.solutions - everything goes through
mediapipe.tasks.python.vision.FaceLandmarker with a downloaded .task model.
"""
import os, math, warnings, hashlib, tempfile, threading, urllib.request
warnings.filterwarnings("ignore")
import numpy as np, cv2
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.abspath(os.environ.get(
    "OPENCLAM_FACE_MODEL",
    os.path.join(CODE_ROOT, "models", "face_landmarker.task")))
MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
             "face_landmarker/float16/1/face_landmarker.task")
MODEL_SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
MODEL_LIMIT = 8 * 1024 * 1024

# Rigid anchors - everything that must NOT move with speech.  Nose, alar base,
# nose bridge, cheeks, infraorbital, jaw hinge, philtrum.  Every lip and chin
# point is deliberately excluded so an affine fitted here captures head-pose
# error WITHOUT flattening the viseme's mouth shape.
RIGID = [1, 2, 164, 98, 327, 6, 168, 4, 5, 195, 197,
         205, 425, 50, 280, 101, 330, 36, 266, 203, 423,
         234, 454, 93, 323, 132, 361, 58, 288]

OUTER_LIP = [61,146,91,181,84,17,314,405,321,375,291,409,270,269,267,0,37,39,40,185]
CHIN      = [17,18,200,199,175,152,148,377,176,400,32,262,171,396,140,369,150,149,378,379]
# Jawline through mouth-corner cheeks, nasolabial folds and alar base.
# The envelope deliberately stops below the eyes.
LOWER_FACE = [234,93,132,58,172,136,150,149,176,148,152,377,400,378,379,365,397,
              288,361,323,454,425,280,330,266,327,2,98,36,101,50,205]
# Bridge, tip, nasal base and both alae: effectively rigid during speech.
NOSE_CORE = [168,6,197,195,5,4,1]
NOSE_BASE = [2,98,327,36,266,101,330,50,280]
NOSE_RIGID = NOSE_CORE + NOSE_BASE
JAW_REGION = [61,146,91,181,84,17,314,405,321,375,291,
              288,397,365,379,378,400,377,152,148,176,149,150,136,172,58]
CHEEK_L = [234,93,132,58,172,136,150,205,203,50,101,36,61,146,91,181]
CHEEK_R = [454,323,361,288,397,365,379,425,423,280,330,266,291,375,321,405]
NASOLABIAL_L = [50,101,36,98,2,164,61,185,40,39,37,0]
NASOLABIAL_R = [280,330,266,327,2,164,291,409,270,269,267,0]
FACE_OVAL = [10,338,297,332,284,251,389,356,454,323,361,288,397,365,379,378,400,377,152,
             148,176,149,150,136,172,58,132,93,234,127,162,21,54,103,67,109]
EYE_L = [263,249,390,373,374,380,381,382,362,398,384,385,386,387,388,466]
EYE_R = [33,7,163,144,145,153,154,155,133,173,157,158,159,160,161,246]
BROW_L = [336,296,334,293,300,276,283,282,295,285]
BROW_R = [107,66,105,63,70,46,53,52,65,55]

MOUTH_L, MOUTH_R, PHILTRUM = 61, 291, 164
EYE_L_OUT, EYE_R_OUT = 263, 33
NOSE_TIP = 1

_det = None
_det_lock = threading.Lock()
_stylized_det = None
_stylized_det_lock = threading.Lock()

# The human-trained landmarker can understand a surprising amount of drawn
# anatomy, but an oversized cartoon face often falls outside its full-frame
# detector prior.  These windows are intentionally bounded and are only tried
# by detect_for_intake() after the normal, strict full-frame pass fails.  The
# 0.72 x 0.77 corner windows are important for large, off-centre illustrated
# portraits; the remaining sizes make the same recovery useful for ordinary
# crops without becoming an unbounded sliding-window scan.
STYLIZED_WIDTH_FRACTIONS = (0.80, 0.75, 0.72, 0.70, 0.65)
STYLIZED_HEIGHT_FRACTIONS = (0.90, 0.85, 0.80, 0.77, 0.75, 0.70)
STYLIZED_ANCHORS = (0.0, 0.5, 1.0)


def _model_hash(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return ""


def _ensure_model():
    if _model_hash(MODEL) == MODEL_SHA256:
        return
    directory = os.path.dirname(MODEL)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".face-landmarker-", dir=directory)
    try:
        digest = hashlib.sha256()
        total = 0
        print("[viv] downloading the public Face Landmarker model...", flush=True)
        with os.fdopen(descriptor, "wb") as output, \
             urllib.request.urlopen(MODEL_URL, timeout=90) as response:
            if not response.geturl().startswith("https://"):
                raise RuntimeError("Face Landmarker download was redirected to an insecure URL")
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MODEL_LIMIT:
                    raise RuntimeError("Face Landmarker download exceeded its size limit")
                output.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != MODEL_SHA256:
            raise RuntimeError("Face Landmarker download failed checksum verification")
        os.chmod(temporary, 0o600)
        os.replace(temporary, MODEL)
    except RuntimeError:
        raise
    except Exception as error:
        raise RuntimeError(
            "Face Landmarker download failed; connect to the internet and retry") from error
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def detector():
    global _det
    if _det is None:
        with _det_lock:
            if _det is None:
                _ensure_model()
                _det = vision.FaceLandmarker.create_from_options(
                    vision.FaceLandmarkerOptions(
                        base_options=mpp.BaseOptions(model_asset_path=MODEL),
                        running_mode=vision.RunningMode.IMAGE, num_faces=1,
                        output_facial_transformation_matrixes=True,
                        min_face_detection_confidence=0.3))
    return _det


def stylized_detector():
    """A permissive detector used only behind the intake topology gate.

    Lower presence thresholds help MediaPipe propose meshes for illustration,
    while _stylized_mesh_quality() rejects the weak eye/texture boxes that
    those thresholds can otherwise expose.  Runtime plates never use this
    detector: a generated canonical head must still pass detect().
    """
    global _stylized_det
    if _stylized_det is None:
        with _stylized_det_lock:
            if _stylized_det is None:
                _ensure_model()
                _stylized_det = vision.FaceLandmarker.create_from_options(
                    vision.FaceLandmarkerOptions(
                        base_options=mpp.BaseOptions(model_asset_path=MODEL),
                        running_mode=vision.RunningMode.IMAGE, num_faces=1,
                        output_facial_transformation_matrixes=True,
                        min_face_detection_confidence=0.10,
                        min_face_presence_confidence=0.01,
                        min_tracking_confidence=0.01))
    return _stylized_det


def _detect_with(instance, bgr):
    """Run one FaceLandmarker instance and return pixel-space geometry."""
    h, w = bgr.shape[:2]
    result = instance.detect(mp.Image(
        image_format=mp.ImageFormat.SRGB,
        data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
    if not result.face_landmarks:
        return None, None
    landmarks = np.array(
        [[point.x * w, point.y * h]
         for point in result.face_landmarks[0]], np.float32)
    transform = (np.array(result.facial_transformation_matrixes[0])
                 if getattr(result, "facial_transformation_matrixes", None)
                 else None)
    return landmarks, transform


def detect(bgr):
    """-> (478x2 landmark array in pixels, 4x4 facial transform) or (None, None)."""
    return _detect_with(detector(), bgr)


def _stylized_mesh_quality(lm, crop_width, crop_height, source_minimum):
    """Return a ranking score for a plausible stylized 478-point face.

    Low-threshold MediaPipe proposals are not trusted merely because they
    contain 478 points.  A real face mesh must have coherent eye, mouth and
    oval topology, remain inside the tested crop, and be large enough to be
    the subject rather than a background motif.  The score favours a large,
    centred mesh and lets detect_for_intake() choose among overlapping crops.
    """
    lm = np.asarray(lm)
    if lm.shape != (478, 2) or not np.isfinite(lm).all():
        return None
    inside = ((lm[:, 0] >= 0) & (lm[:, 0] < crop_width) &
              (lm[:, 1] >= 0) & (lm[:, 1] < crop_height))
    if float(inside.mean()) < 0.99:
        return None

    oval = lm[FACE_OVAL]
    oval_width = float(np.ptp(oval[:, 0]))
    oval_height = float(np.ptp(oval[:, 1]))
    eye_span = float(np.linalg.norm(lm[EYE_L_OUT] - lm[EYE_R_OUT]))
    mouth_width = float(np.ptp(lm[OUTER_LIP, 0]))
    if min(oval_width, oval_height, eye_span, mouth_width) <= 1e-6:
        return None

    eye_ratio = eye_span / oval_width
    mouth_ratio = mouth_width / eye_span
    oval_ratio = oval_height / oval_width
    eye_y = float((lm[EYE_L_OUT, 1] + lm[EYE_R_OUT, 1]) / 2.0)
    mouth_y = float(lm[OUTER_LIP, 1].mean())
    nose_y = float(lm[NOSE_TIP, 1])
    eye_mouth_ratio = (mouth_y - eye_y) / oval_height
    projected_mouth = foreshortening(lm)
    face_area = ((oval_width * oval_height) /
                 max(1.0, float(crop_width * crop_height)))
    if not (0.45 < eye_ratio < 0.80 and
            0.30 < mouth_ratio < 0.75 and
            0.75 < oval_ratio < 1.45 and
            0.20 < eye_mouth_ratio < 0.65 and
            eye_y < nose_y < mouth_y and
            0.55 < projected_mouth < 1.80 and
            oval_width >= 0.18 * float(source_minimum) and
            oval_height >= 0.25 * float(crop_height) and
            face_area >= 0.08):
        return None

    centre = oval.mean(axis=0)
    centre_error = math.hypot(
        float(centre[0]) / crop_width - 0.5,
        float(centre[1]) / crop_height - 0.5)
    score = (face_area - 0.10 * centre_error -
             0.10 * abs(oval_ratio - 1.0) -
             0.03 * abs(eye_ratio - 0.60) -
             0.02 * abs(mouth_ratio - 0.50))
    return dict(
        score=float(score), eye_oval_ratio=float(eye_ratio),
        mouth_eye_ratio=float(mouth_ratio),
        oval_aspect=float(oval_ratio),
        eye_mouth_oval_ratio=float(eye_mouth_ratio),
        foreshortening=float(projected_mouth), face_area=float(face_area))


def _stylized_windows(width, height):
    """Yield unique anchored crop boxes as (x, y, width, height)."""
    seen = set()
    for width_fraction in STYLIZED_WIDTH_FRACTIONS:
        for height_fraction in STYLIZED_HEIGHT_FRACTIONS:
            crop_width = int(round(width * width_fraction))
            crop_height = int(round(height * height_fraction))
            for anchor_x in STYLIZED_ANCHORS:
                for anchor_y in STYLIZED_ANCHORS:
                    x = int(round((width - crop_width) * anchor_x))
                    y = int(round((height - crop_height) * anchor_y))
                    box = (x, y, crop_width, crop_height)
                    if box not in seen:
                        seen.add(box)
                        yield box


def classify_source_medium(bgr, landmarks):
    """Classify the face artwork as photo, illustration, or uncertain.

    Detection strategy and visual medium are deliberately independent.  A
    centred cartoon can pass MediaPipe's strict detector, while an off-centre
    photograph may need the crop fallback.  The prompt pipeline needs the
    *medium*, not the route by which the mesh was found.

    Drawn faces characteristically combine large, nearly flat colour regions
    with a small number of strong ink/shape boundaries.  Natural photographs
    have many more low-amplitude tonal transitions.  We measure both on a
    bounded face crop and leave the ambiguous band as ``unknown`` so a
    medium-preserving prompt can be used instead of guessing.
    """
    image = np.asarray(bgr)
    lm = np.asarray(landmarks)
    if image.ndim != 3 or image.shape[2] < 3 or lm.shape != (478, 2):
        return dict(source_medium="unknown", medium_score=None)

    height, width = image.shape[:2]
    oval = lm[FACE_OVAL]
    x0, y0 = np.min(oval, axis=0)
    x1, y1 = np.max(oval, axis=0)
    pad_x = 0.12 * max(1.0, float(x1 - x0))
    pad_y = 0.12 * max(1.0, float(y1 - y0))
    left = max(0, int(math.floor(x0 - pad_x)))
    top = max(0, int(math.floor(y0 - pad_y)))
    right = min(width, int(math.ceil(x1 + pad_x)))
    bottom = min(height, int(math.ceil(y1 + pad_y)))
    crop = image[top:bottom, left:right, :3]
    if min(crop.shape[:2], default=0) < 8:
        return dict(source_medium="unknown", medium_score=None)

    scale = min(1.0, 256.0 / max(crop.shape[:2]))
    if scale < 1.0:
        crop = cv2.resize(crop, None, fx=scale, fy=scale,
                          interpolation=cv2.INTER_AREA)
    lab = cv2.cvtColor(crop, cv2.COLOR_BGR2LAB).astype(np.float32)
    horizontal = np.linalg.norm(lab[:, 1:] - lab[:, :-1], axis=2).ravel()
    vertical = np.linalg.norm(lab[1:] - lab[:-1], axis=2).ravel()
    delta = np.concatenate((horizontal, vertical))
    if not delta.size:
        return dict(source_medium="unknown", medium_score=None)

    flat_fraction = float(np.mean(delta < 2.0))
    strong_edge_fraction = float(np.mean(delta > 20.0))
    score = flat_fraction + 2.0 * strong_edge_fraction
    if score >= 0.72:
        medium = "illustration"
    elif score <= 0.62:
        medium = "photograph"
    else:
        medium = "unknown"
    return dict(
        source_medium=medium,
        medium_score=round(float(score), 6),
        medium_features=dict(
            flat_fraction=round(flat_fraction, 6),
            strong_edge_fraction=round(strong_edge_fraction, 6)))


def detect_for_intake(bgr):
    """Detect a photo or, after strict failure, a topology-gated cartoon.

    Returns ``(landmarks, transform, metadata)``.  Landmarks from a winning
    crop are remapped into the original image coordinate system.  Consumers
    outside source registration should keep using detect(), so permissive
    cartoon proposals can never silently enter the production runtime.
    """
    landmarks, transform = detect(bgr)
    if landmarks is not None:
        metadata = dict(detection_mode="strict")
        metadata.update(classify_source_medium(bgr, landmarks))
        return landmarks, transform, metadata

    height, width = bgr.shape[:2]
    best = None
    instance = stylized_detector()
    for x, y, crop_width, crop_height in _stylized_windows(width, height):
        local, candidate_transform = _detect_with(
            instance, bgr[y:y + crop_height, x:x + crop_width])
        if local is None:
            continue
        quality = _stylized_mesh_quality(
            local, crop_width, crop_height, min(width, height))
        if quality is None:
            continue
        if best is None or quality["score"] > best[0]:
            mapped = local.copy()
            mapped[:, 0] += x
            mapped[:, 1] += y
            metadata = dict(
                detection_mode="crop-fallback",
                detection_crop=dict(x=x, y=y, width=crop_width,
                                    height=crop_height,
                                    source=[int(width), int(height)]),
                topology={key: round(value, 6)
                          for key, value in quality.items()
                          if key != "score"})
            best = (quality["score"], mapped, candidate_transform, metadata)
    if best is None:
        return None, None, None
    metadata = best[3]
    metadata.update(classify_source_medium(bgr, best[1]))
    return best[1], best[2], metadata


def pose_angles(M):
    """Decompose the facial transformation matrix -> (yaw, pitch, roll) degrees."""
    if M is None:
        return None
    R = np.asarray(M)[:3, :3]
    sy = math.hypot(R[0, 0], R[1, 0])
    return (math.degrees(math.atan2(-R[2, 0], sy)),
            math.degrees(math.atan2(R[2, 1], R[2, 2])),
            math.degrees(math.atan2(R[1, 0], R[0, 0])))


def foreshortening(lm):
    """Philtrum projected onto the mouth-corner line, as a left/right ratio.

    1.00 = perfectly frontal mouth.  A turned head pushes it away from 1.
    This is the metric that exposed 'the mouth was drawn on a frontal prior
    but the head is turned'.
    """
    a, b, p = lm[MOUTH_L], lm[MOUTH_R], lm[PHILTRUM]
    d = b - a
    t = float(np.dot(p - a, d) / (np.dot(d, d) + 1e-9))
    t = min(max(t, 1e-3), 1 - 1e-3)
    return t / (1 - t)


def metrics(lm, M=None):
    yaw = pitch = roll = None
    if M is not None:
        yaw, pitch, roll = pose_angles(M)
    return dict(
        eye_span=float(np.linalg.norm(lm[EYE_L_OUT] - lm[EYE_R_OUT])),
        nose=[float(lm[NOSE_TIP][0]), float(lm[NOSE_TIP][1])],
        mouth_centre=[float(lm[OUTER_LIP].mean(0)[0]), float(lm[OUTER_LIP].mean(0)[1])],
        foreshortening=foreshortening(lm),
        yaw=yaw, pitch=pitch, roll=roll)


def hull_mask(shape, lm, idx, dilate=0, close_poly=True):
    m = np.zeros(shape[:2], np.uint8)
    pts = cv2.convexHull(lm[idx].astype(np.int32))
    cv2.fillConvexPoly(m, pts, 255)
    if dilate:
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dilate, dilate))
        m = cv2.dilate(m, k)
    return m
