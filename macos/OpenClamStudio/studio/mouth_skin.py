"""Provider-free lip geometry for opt-in soft-3D mouth skin matching.

This module does not recolour, export, or change any image. It measures the
exact selected mouth image, including its own emotion atlas alpha, so the
renderer can correct surrounding donor skin without modifying lips or teeth.
Photographs, illustrations, and unknown media deliberately return no metadata.

Input images are OpenCV BGR / atlas BGRA uint8 arrays. Returned polygons use
full canonical-image pixel coordinates BEFORE the viseme's horizontal runtime
registration. Add ``smile['viseme_x_offsets'][name]`` once when rendering them.
Emotion polygons retain the exact ``states`` order of their respective atlas.
"""
from collections.abc import Mapping
import hashlib

import cv2
import numpy as np

from . import face


SOFT_3D_MEDIA = frozenset({"3d render", "3d-render", "soft-3d"})
VERSION = 1
MAX_VISEMES = 32
MAX_STATES = 16
MIN_POLYGON_VERTICES = 8
EMOTIONS = frozenset({"sorrow", "horror", "anger"})


class MouthSkinGeometryError(ValueError):
    """Geometry is incomplete or unsafe; do not enable skin matching."""


def _image(value, shape=None, channels=3):
    if (not isinstance(value, np.ndarray) or value.dtype != np.uint8
            or value.ndim != 3 or value.shape[2] != channels
            or min(value.shape[:2]) < 1
            or (shape is not None and value.shape[:2] != shape)):
        raise MouthSkinGeometryError("unexpected image dimensions or format")
    return value


def _key_identity(key):
    _image(key)
    return {"format": "bgr8", "shape": list(key.shape),
            "sha256": hashlib.sha256(np.ascontiguousarray(key).tobytes()).hexdigest()}


def matches_key(metadata, key):
    """Permit metadata reuse only for exactly the same decoded canonical key.

    The caller must separately retain/verify the unchanged viseme and emotion
    banks; a matching head does not establish their identity.
    """
    if (not isinstance(metadata, Mapping) or metadata.get("v") != VERSION
            or metadata.get("space") != "canonical-pixels"):
        return False
    try:
        return metadata.get("canonical_key") == _key_identity(key)
    except (MouthSkinGeometryError, ValueError, TypeError):
        return False


def _points(landmarks):
    try:
        points = np.asarray(landmarks, np.float64)[face.OUTER_LIP]
    except (TypeError, ValueError, IndexError) as error:
        raise MouthSkinGeometryError("outer-lip landmarks unavailable") from error
    if points.shape != (len(face.OUTER_LIP), 2) or not np.isfinite(points).all():
        raise MouthSkinGeometryError("invalid outer-lip landmarks")
    return points


def _detect(image):
    try:
        landmarks, _ = face.detect(image)
    except Exception as error:
        raise MouthSkinGeometryError("local lip detection failed") from error
    if landmarks is None:
        raise MouthSkinGeometryError("local lip detection found no face")
    return _points(landmarks)


def _box(value, shape):
    try:
        values = np.asarray(value, np.float64)
    except (ValueError, TypeError) as error:
        raise MouthSkinGeometryError("invalid mouth or atlas box") from error
    if (values.shape != (4,) or not np.isfinite(values).all()
            or not np.equal(values, np.floor(values)).all()):
        raise MouthSkinGeometryError("invalid mouth or atlas box")
    x, y, w, h = map(int, values)
    if (x < 0 or y < 0 or w < 1 or h < 1
            or x+w > shape[1] or y+h > shape[0]):
        raise MouthSkinGeometryError("mouth or atlas box leaves the image")
    return x, y, w, h


def _canonical_box(points, shape):
    # Same canonical-outer-lip-v1 support as export._stylized_mouth_geometry.
    width = float(np.ptp(points[:, 0]))
    if width < 4:
        raise MouthSkinGeometryError("canonical mouth is too small")
    cx, cy = points.mean(axis=0)
    x0 = max(0, int(np.floor(cx-.75*width)))
    x1 = min(shape[1], int(np.ceil(cx+.75*width)))
    y0 = max(0, int(np.floor(cy-.28*width)))
    y1 = min(shape[0], int(np.ceil(cy+.48*width)))
    return _box([x0, y0, x1-x0, y1-y0], shape)


def _polygon(points, key_points, box, registration=0.0):
    x, y, w, h = box
    span = np.ptp(points, axis=0)
    canonical_width = float(np.ptp(key_points[:, 0]))
    if (span[0] < max(2.0, canonical_width*.15)
            or span[0] > canonical_width*1.8
            or span[1] < .5 or span[1] > canonical_width*1.1
            or points[:, 0].min() < x-1 or points[:, 0].max() > x+w+1
            or points[:, 1].min() < y-1 or points[:, 1].max() > y+h+1):
        raise MouthSkinGeometryError("detected lips leave the safe mouth region")
    hull = cv2.convexHull(points.astype(np.float32)).reshape(-1, 2)
    if len(hull) < MIN_POLYGON_VERTICES or cv2.contourArea(hull) < 2.0:
        raise MouthSkinGeometryError("degenerate lip polygon")
    # Detection runs in registered space over the canonical head, matching the
    # renderer. Persist pre-registration pixels, not a second shifted geometry.
    hull[:, 0] -= float(registration)
    return np.round(hull.astype(np.float64), 4).tolist()


def _registered_mouth(image, box, registration):
    x, y, w, h = box
    if x-registration < 0 or x+w-registration > image.shape[1]:
        raise MouthSkinGeometryError("registered mouth leaves its source image")
    gx, gy = np.meshgrid(np.arange(x, x+w, dtype=np.float32)-registration,
                         np.arange(y, y+h, dtype=np.float32))
    return cv2.remap(image, gx, gy, cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_CONSTANT)


def _with_atlas(base, patch, atlas_box, mouth_box, registration):
    """Overlay only this selected cell, in premultiplied-alpha sample space."""
    ax, ay, aw, ah = atlas_box
    x, y, w, h = mouth_box
    _image(patch, (ah, aw), channels=4)
    gx, gy = np.meshgrid(
        np.arange(x, x+w, dtype=np.float32)-registration-ax,
        np.arange(y, y+h, dtype=np.float32)-ay)
    rgba = patch.astype(np.float32)
    alpha = rgba[:, :, 3:4]/255.0
    premultiplied = np.concatenate((rgba[:, :, :3]*alpha, alpha), axis=2)
    sampled = cv2.remap(premultiplied, gx, gy, cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_CONSTANT)
    return np.clip(np.rint(sampled[:, :, :3]
                   + base.astype(np.float32)*(1-sampled[:, :, 3:4])),
                   0, 255).astype(np.uint8)


def _atlas(spec, bank_names, shape, *, emotions=False):
    if spec is None:
        return None
    if not isinstance(spec, Mapping):
        raise MouthSkinGeometryError("invalid emotion atlas description")
    names = spec.get("visemes")
    if (not isinstance(names, (list, tuple)) or len(names) != len(bank_names)
            or len(set(names)) != len(names) or set(names) != bank_names):
        raise MouthSkinGeometryError("emotion atlas does not match the viseme bank")
    states = spec.get("states")
    if not isinstance(states, (list, tuple)) or not 1 <= len(states) <= MAX_STATES:
        raise MouthSkinGeometryError("invalid emotion strength states")
    try:
        strengths = np.asarray(states, np.float64)
    except (ValueError, TypeError) as error:
        raise MouthSkinGeometryError("invalid emotion strength states") from error
    if (strengths.shape != (len(states),) or not np.isfinite(strengths).all()
            or (strengths < 0).any() or (strengths > 1).any()
            or (np.diff(strengths) <= 0).any()):
        raise MouthSkinGeometryError("invalid emotion strength states")
    families = spec.get("emotions") if emotions else ["smile"]
    if (not isinstance(families, (list, tuple)) or not 1 <= len(families) <= 3
            or len(set(families)) != len(families)
            or (emotions and not set(families) <= EMOTIONS)):
        raise MouthSkinGeometryError("invalid emotion families")
    patches = spec.get("patches")
    count = len(families)*len(names)*len(states)
    if not isinstance(patches, (list, tuple)) or len(patches) != count:
        raise MouthSkinGeometryError("incomplete emotion atlas cells")
    box = _box(spec.get("box"), shape)
    for patch in patches:
        _image(patch, (box[3], box[2]), channels=4)
    return list(names), len(states), list(families), patches, box


def build(key, viseme_bank, smile, emotion_mouth, source_medium, log=print,
          *, key_landmarks=None, mouth_box=None):
    """Return measured soft-3D metadata, or None without changing any input.

    A missing/invalid contour fails the optional correction closed as a whole;
    it never substitutes canonical geometry for a different selected viseme.
    The caller may continue publishing the original approved renderer without
    this metadata. No image generation, network, file IO, or pixel writes are
    performed here. The existing local Face Landmarker owns detection.
    """
    if str(source_medium).strip().lower() not in SOFT_3D_MEDIA:
        return None
    try:
        _image(key)
        shape = key.shape[:2]
        if not isinstance(viseme_bank, (list, tuple)) or not 1 <= len(viseme_bank) <= MAX_VISEMES:
            raise MouthSkinGeometryError("invalid viseme bank")
        bank = {}
        for entry in viseme_bank:
            if not isinstance(entry, (list, tuple)) or len(entry) != 2:
                raise MouthSkinGeometryError("invalid viseme entry")
            name, image = entry
            if not isinstance(name, str) or not name or name in bank:
                raise MouthSkinGeometryError("duplicate or invalid viseme name")
            bank[name] = _image(image, shape)
        if "sil" not in bank:
            raise MouthSkinGeometryError("canonical neutral viseme is missing")
        key_points = _points(key_landmarks) if key_landmarks is not None else _detect(key)
        box = _canonical_box(key_points, shape) if mouth_box is None else _box(mouth_box, shape)
        canonical = _polygon(key_points, key_points, box)
        names = set(bank)
        smile_atlas = _atlas(smile, names, shape)
        emotion_atlas = _atlas(emotion_mouth, names, shape, emotions=True)
        offsets = smile.get("viseme_x_offsets", {}) if isinstance(smile, Mapping) else {}
        if not isinstance(offsets, Mapping):
            raise MouthSkinGeometryError("invalid mouth registration")
        registrations, mouth_planes = {}, {}
        contours = {"sil": canonical}
        x, y, w, h = box
        for name, image in bank.items():
            offset = float(offsets.get(name, 0.0))
            if not np.isfinite(offset) or abs(offset) > w*.35:
                raise MouthSkinGeometryError("unsafe mouth registration")
            # Both runtime and this helper use the immutable key for sil.
            if name == "sil":
                offset = 0.0
                image = key
            registrations[name] = offset
            plane = _registered_mouth(image, box, offset)
            mouth_planes[name] = plane
            if name != "sil":
                resolved = key.copy()
                resolved[y:y+h, x:x+w] = plane
                contours[name] = _polygon(_detect(resolved), key_points, box, offset)
        emotion_contours = {}
        measured = len(contours)
        for atlas in (smile_atlas, emotion_atlas):
            if atlas is None:
                continue
            atlas_names, state_count, families, patches, atlas_box = atlas
            for family_index, family in enumerate(families):
                per_viseme = {}
                for viseme_index, name in enumerate(atlas_names):
                    state_contours = []
                    for state in range(state_count):
                        index = ((family_index*len(atlas_names)+viseme_index)*state_count+state)
                        plane = _with_atlas(mouth_planes[name], patches[index],
                                            atlas_box, box, registrations[name])
                        resolved = key.copy()
                        resolved[y:y+h, x:x+w] = plane
                        state_contours.append(_polygon(_detect(resolved), key_points,
                                                       box, registrations[name]))
                        measured += 1
                    per_viseme[name] = state_contours
                emotion_contours[family] = per_viseme
        log(f"  soft-3D mouth skin: {measured} native lip contours; selected lips protected")
        return {"v": VERSION, "space": "canonical-pixels", "canonical_key": _key_identity(key), "contours": contours,
                "emotion_contours": emotion_contours}
    except (MouthSkinGeometryError, ValueError, TypeError, IndexError, cv2.error) as error:
        log(f"  mouth skin matching disabled: {error}")
        return None
