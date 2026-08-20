"""Provider-aware full-body authoring with deterministic face locking.

The image provider designs the body, wardrobe, hair silhouette, and stance. It
is not trusted with identity at runtime: the existing calibrated 1024px face rig
is mapped over the generated head through a robust similarity transform.
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import tempfile

import cv2
import numpy as np
try:
    import media_gen
except ModuleNotFoundError:  # package-style test/import outside server/app.py
    from server import media_gen

from . import cutout, face


STYLES = {"photorealistic", "editorial", "illustrated", "anime", "soft-3d"}
POSES = {"relaxed", "confident", "friendly", "formal", "casual"}
BODY_VIEWS = ("front", "side", "back")
XAI_EDIT_PROVIDER = "xai"
XAI_EDIT_MODEL = "grok-imagine-image-2.0"
# Leave a small margin beneath Imagine 2.0's 8 KiB request ceiling.  This is a
# byte budget because CJK, emoji, and accented text are not one byte per Python
# character.
FULL_BODY_PROMPT_MAX_BYTES = 8_000
_MIN_GENERATED_HEAD_SCALE = 0.17
_MAX_GENERATED_HEAD_SCALE = 1.8
_MIN_GENERATED_FACE_WIDTH_PX = 84
_MIN_GENERATED_FACE_HEIGHT_PX = 100
_MIN_GENERATED_FACE_WIDTH_RATIO = 0.075
_MIN_GENERATED_FACE_HEIGHT_RATIO = 0.065
DEFAULT_BODY_PROMPT = (
    "Create a photorealistic couture-level full-body wardrobe with tailored "
    "authority, editorial sensuality, and zero fast-fashion noise. Read only "
    "the subject's visible feminine, masculine, or androgynous presentation; "
    "do not claim a gender identity and never force a gendered shoe or beauty "
    "code when the presentation is uncertain. Use exactly one hero colour from fuchsia, "
    "scarlet, coral, ultramarine, or camel, plus one restrained accent and "
    "quiet black, charcoal, taupe, or chocolate neutrals. Never use cobalt. "
    "Emerald belongs to the broader house palette but must become ultramarine "
    "on this cutout plate because green damages alpha extraction. Use opaque, "
    "substantial fabric with believable behaviour and crisp seam "
    "tension. Keep the silhouette structured, sensual, and polished: no bare "
    "midriff, sheer fabric, or extreme plunging neckline. Keep accessories "
    "minimal and understated, never ornate, layered, stacked, or visually busy. "
    "Preserve the existing hairstyle with a sleek finish, luminous real skin "
    "texture, defined brows, and presentation-appropriate grooming. Keep "
    "everything opaque and suitable "
    "for public view: no nudity, lingerie, or exposed intimate areas. Both hands "
    "stay empty and clearly visible; nothing is held, carried, or slung on the "
    "body."
)


def _clean(value, maximum=800):
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value or ""))
    return re.sub(r"\s+", " ", value).strip()[:maximum]


def _direction(options):
    """The generation direction, plus whatever the owner asked to keep.

    Notes used to be DROPPED the moment an expanded prompt existed - which
    is the normal path - so "keep his bandana" never reached the model. A
    portrait of a character came back with the right face and none of what
    made him recognisable (owner, 2026-08-04). The note is an ADD-ON: it
    rides after the prompt, never instead of it, and it goes last so it
    reads as the final word.
    """
    from . import wardrobe

    notes = _clean(options.get("notes"), 600)
    custom = wardrobe.migrate_legacy_prompt(
        _clean(options.get("prompt"), 4000), maximum=4000)
    if custom:
        return f"{custom} MUST KEEP: {notes}" if notes else custom
    legacy = []
    outfit = _clean(options.get("outfit"), 500)
    if outfit:
        legacy.append(f"Wardrobe: {outfit}")
    if notes:
        legacy.append(f"MUST KEEP: {notes}")
    base = " ".join(legacy)
    if not base:
        return wardrobe.migrate_legacy_prompt(
            DEFAULT_BODY_PROMPT, ensure_rule=True)
    if not _clean(options.get("outfit"), 500):
        # A note alone still wants the house prompt behind it.
        default = wardrobe.migrate_legacy_prompt(
            DEFAULT_BODY_PROMPT, ensure_rule=True)
        return f"{default} {base}"
    return base


def public_body_metadata(metadata):
    """Read-only policy projection for body status/API responses.

    Existing body projects may contain a prompt written by the retired gold and
    statement-jewellery template.  Return a shallow structural copy whose prompt
    is migrated for display/regeneration; never rewrite the authoring manifest.
    """
    from . import wardrobe

    if not isinstance(metadata, dict):
        return metadata
    projected = dict(metadata)
    options = metadata.get("options")
    if not isinstance(options, dict):
        return projected
    projected_options = dict(options)
    direction = _direction(options)
    projected_options["prompt"] = wardrobe.migrate_legacy_prompt(
        direction, stored=True, ensure_rule=True, maximum=4000)
    projected["options"] = projected_options
    return projected


def _presentation_context(options, style):
    """One explicit presentation branch for the final provider plate.

    A previous generic wrapper listed both 90 mm pumps and masculine no-heels
    language in every request. Even when the tailored portrait brief was right,
    that mixed instruction left the image model free to pick the wrong shoe.
    """
    from . import wardrobe

    presentation = wardrobe._normalise_presentation(
        options.get("presentation") or "androgynous")
    medium = _clean(options.get("medium"), 40).lower()
    if not medium:
        medium = {
            "photorealistic": "photograph",
            "editorial": "photograph",
            "illustrated": "illustration",
            "anime": "anime",
            "soft-3d": "3d render",
        }[style]
    return presentation, medium, wardrobe._presentation_rule(
        presentation, medium)


def image_provider_selection():
    """The direct image lane selected in OpenClam, including its transient key."""
    return media_gen.selected_config("image", media_gen.IMAGE_EDIT_PROVIDERS)


def video_provider_selection():
    """The reviewed direct image-to-video lane selected in OpenClam."""
    return media_gen.selected_config("video", media_gen.AVATAR_VIDEO_PROVIDERS)


def default_provider():
    _config, public = image_provider_selection()
    return public


def default_video_provider():
    _config, public = video_provider_selection()
    return public


def _utf8_prefix(value, maximum):
    """Return a readable prefix that occupies no more than ``maximum`` bytes."""
    encoded = value.encode("utf-8")
    if len(encoded) <= maximum:
        return value
    if maximum < 4:
        return ""
    clipped = encoded[:maximum - 3].decode("utf-8", errors="ignore").rstrip()
    # Avoid cutting an English word when doing so still keeps most of the
    # available art direction. CJK text has no spaces and remains character-safe.
    if " " in clipped:
        whole_words = clipped.rsplit(" ", 1)[0].rstrip(" ,;:-")
        if len(whole_words.encode("utf-8")) >= maximum // 2:
            clipped = whole_words
    return clipped.rstrip(" ,;:-") + "…"


def _fit_direction_bytes(direction, maximum):
    """Fit editable prose while retaining a trailing owner MUST KEEP note."""
    if len(direction.encode("utf-8")) <= maximum:
        return direction
    marker = " MUST KEEP: "
    if marker not in direction:
        return _utf8_prefix(direction, maximum)
    main, note = direction.rsplit(marker, 1)
    tail = marker + note
    # Owner notes are deliberately bounded upstream. Keep the complete note
    # whenever possible and trim the generative prose ahead of it.
    if len(tail.encode("utf-8")) >= maximum - 64:
        tail = marker + _utf8_prefix(note, max(32, maximum // 3))
    main_budget = maximum - len(tail.encode("utf-8"))
    return _utf8_prefix(main, main_budget).rstrip() + tail


def _fit_full_body_prompt(prompt):
    marker = "EDITABLE ART DIRECTION — "
    start = prompt.index(marker) + len(marker)
    end = prompt.index("\n\n", start)
    fixed_bytes = len((prompt[:start] + prompt[end:]).encode("utf-8"))
    available = FULL_BODY_PROMPT_MAX_BYTES - fixed_bytes
    if available < 256:
        raise RuntimeError("the fixed full-body safety prompt exceeds its provider budget")
    direction = _fit_direction_bytes(prompt[start:end], available)
    fitted = prompt[:start] + direction + prompt[end:]
    if len(fitted.encode("utf-8")) > FULL_BODY_PROMPT_MAX_BYTES:
        raise RuntimeError("the full-body prompt could not be fitted safely")
    return fitted


def _head_scale_is_safe(scale):
    return (np.isfinite(scale)
            and _MIN_GENERATED_HEAD_SCALE <= scale <= _MAX_GENERATED_HEAD_SCALE)


def _head_alignment_failure(scale, face_bounds, body_shape, residual):
    """Return a precise reason when a generated head cannot be face-locked.

    The affine scale is relative to the normalized canonical portrait, so it
    is not a reliable measure of rendered head quality by itself.  Landmark
    fitting can move a few thousandths between otherwise identical runs while
    the destination face remains crisp and normally proportioned.  Keep a
    narrow hard transform floor, then require Cleo-calibrated destination
    resolution/framing and a clean landmark fit.
    """
    if not _head_scale_is_safe(scale):
        return (
            f"generated head transform is unsafe ({scale:.3f}x; expected "
            f"{_MIN_GENERATED_HEAD_SCALE:.3f}x to "
            f"{_MAX_GENERATED_HEAD_SCALE:.3f}x)")

    body_height, body_width = body_shape[:2]
    _x, _y, face_width, face_height = face_bounds
    required_width = max(
        _MIN_GENERATED_FACE_WIDTH_PX,
        int(round(body_width * _MIN_GENERATED_FACE_WIDTH_RATIO)),
    )
    required_height = max(
        _MIN_GENERATED_FACE_HEIGHT_PX,
        int(round(body_height * _MIN_GENERATED_FACE_HEIGHT_RATIO)),
    )
    if face_width < required_width or face_height < required_height:
        return (
            "generated head is too small for a crisp identity lock "
            f"({face_width}x{face_height}px; need at least "
            f"{required_width}x{required_height}px)")

    median_residual = float(np.median(residual))
    max_residual = float(np.max(residual))
    median_limit = max(5.0, face_width * 0.075)
    max_limit = max(14.0, face_width * 0.20)
    if (not np.isfinite(median_residual)
            or not np.isfinite(max_residual)
            or median_residual > median_limit
            or max_residual > max_limit):
        return (
            "generated face alignment is unstable "
            f"(median {median_residual:.1f}px, max {max_residual:.1f}px)")
    return None


def _prompt(options, view="front"):
    if view not in BODY_VIEWS:
        raise ValueError(f"unknown full-body view: {view}")
    style = options.get("style") if options.get("style") in STYLES else "photorealistic"
    pose = options.get("pose") if options.get("pose") in POSES else "relaxed"
    direction = _direction(options)
    presentation, medium, presentation_rule = _presentation_context(
        options, style)
    from . import wardrobe
    # Cached house prompts carry the exact fixed accessory clause. Remove that
    # known negative rule before checking the owner's/model's editable prose for
    # contradictory positive assignments.
    editable_direction = direction.replace(wardrobe.ACCESSORY_RULE, " ").replace(
        presentation_rule, " ")
    if presentation != "feminine" and wardrobe._assigns_feminine_heels(
            editable_direction):
        raise ValueError(
            "the full-body direction assigns feminine heels to a "
            "non-feminine presentation")
    if wardrobe._assigns_gold(editable_direction):
        raise ValueError("the full-body direction assigns forbidden gold styling")
    if wardrobe._assigns_excessive_accessories(editable_direction):
        raise ValueError("the full-body direction assigns excessive accessories")
    # Wardrobe's cached brief ends with deterministic house and rig clauses.
    # This plate wrapper carries those clauses itself, so remove their exact
    # duplicates before adding the view-specific identity/turnaround contract.
    stylised = medium in {"game art", "anime", "illustration", "3d render"}
    repeated_rules = [
        presentation_rule, wardrobe.ACCESSORY_RULE, wardrobe.STRUCTURAL_RULE,
    ]
    house_section = ""
    if not stylised:
        repeated_rules += [wardrobe.COLOR_RULE, wardrobe.LUXURY_FINISH_RULE]
        house_section = (
            "\n\nHOUSE STYLE — " + wardrobe.COLOR_RULE + " "
            + wardrobe.LUXURY_FINISH_RULE)
    for rule in repeated_rules:
        direction = direction.replace(rule, " ")
    # ``_direction`` already bounds custom prose and the owner note separately.
    # Leave enough room here for both; the UTF-8 fitter below owns the final
    # provider budget and knows how to retain the trailing MUST KEEP clause.
    direction = _clean(direction, 4800) or DEFAULT_BODY_PROMPT
    style_text = {
        "photorealistic": "Photorealistic editorial portrait photography with natural skin texture",
        "editorial": "High-fashion editorial portrait photography with restrained luxury styling",
        "illustrated": "Polished modern character illustration with sophisticated material rendering",
        "anime": "Premium contemporary anime character art with anatomically coherent proportions",
        "soft-3d": "Refined soft-3D character rendering with realistic materials and restrained stylization",
    }[style]
    pose_text = {
        "relaxed": "balanced relaxed stance, arms naturally separated from the torso",
        "confident": "calm confident stance with excellent posture and relaxed shoulders",
        "friendly": "warm approachable stance with subtle asymmetry and relaxed hands",
        "formal": "formal composed stance, shoulders level, hands naturally at the sides",
        "casual": "natural casual weight shift with hands clearly visible",
    }[pose]
    view_text = {
        "front": (
            "Create the canonical FRONT view. Face, sternum, pelvis, knees, and toes point "
            "straight toward the camera. Keep both shoulders and both sides of the outfit "
            "equally readable; do not rotate into a three-quarter view. Reference 1, the "
            "canonical HD head, is the identity authority."
        ),
        "side": (
            "Create the canonical RIGHT-SIDE view. The nose, chest, knees, and toes point "
            "exactly camera-right in a true 90-degree profile; do not drift toward front or "
            "three-quarter. Reference 1, the canonical HD head, is the identity authority. "
            "Reference 2, the approved front body plate, is the absolute authority for "
            "wardrobe, body proportions, materials, color, accessories, and garment length."
        ),
        "back": (
            "Create the canonical BACK view. The back of the head, shoulders, spine, hips, "
            "knees, and heels face the camera while the face remains completely out of view; "
            "do not turn the head over a shoulder. Reference 1, the canonical HD head, is the "
            "identity and hair authority. Reference 2, the approved front body plate, is the "
            "absolute authority for wardrobe, body proportions, materials, color, "
            "accessories, and garment length."
        ),
    }[view]
    prompt = f"""Create one vertical 3:4 full-body {view}-view character plate of the exact same adult person.

TURNAROUND CONTRACT — this is one member of a matched FRONT / RIGHT-SIDE / BACK full-body set. Return exactly one complete figure for this {view} plate, never a triptych, contact sheet, split screen, duplicate person, inset, or labeled diagram. Treat the camera as rotating around one stationary person: preserve the same posture, shoulder level, arm placement, hand state, leg spacing, weight distribution, outfit, body scale, and camera height across all three plates.

IDENTITY LOCK — preserve the reference person's facial identity, skull proportions, skin tone, hairline, hairstyle, eyebrows, eye shape and color, nose, lips, ears, and apparent age wherever those features are visible. If the reference head wears eyeglasses, keep that exact pair on the face in every plate — same frame shape, thickness, color and position — and never remove them; if the reference wears none, do not add any. Keep a neutral closed mouth. Do not beautify, de-age, or redesign the person.

VIEW — {view_text}

COMPOSITION — show the complete figure from the top of the hair through both feet with 7% clear margin around the silhouette. Camera at waist height, long portrait lens, minimal perspective distortion. Use a {pose_text}. Both hands, both legs, and all footwear must be complete and anatomically correct; no crop, no props, no furniture, no text.

PROPORTION TARGET — give the adult figure a believable supermodel-calibre editorial silhouette: tall, poised, and sculpted, with naturally long legs and a balanced torso-to-leg ratio. Long must never become exaggerated. Reject stretched femurs or shins, a tiny torso, pinched waist, warped hips, knees, or ankles, impossible height, or fashion-illustration anatomy. Preserve any body characteristics clearly visible in the reference and keep adult anatomy realistic.

CARRY NOTHING — both hands are completely empty and clearly visible. Do NOT place a bag, handbag, clutch, purse, tote, shopping bag, backpack, briefcase, portfolio, folder, book, paper, phone, cup, glass, umbrella, weapon, staff, or any other object in either hand, and do NOT sling a bag, strap, or pouch over a shoulder, hook one on an elbow, or wear one across the body. Nothing is held, carried, hooked, or leaned against the figure in any plate of the turnaround.

NO GOLD AND MINIMAL ACCESSORIES — {wardrobe.ACCESSORY_RULE}

EDITABLE ART DIRECTION — {direction}{house_section}

PRESENTATION AND FOOTWEAR — this plate uses only the {presentation} branch inferred from the reference; it is visible styling, not a claim about gender identity. {presentation_rule}

DECENCY FLOOR — regardless of the editable direction, use tasteful opaque clothing suitable for an adult in public. No nudity, lingerie, bare midriff, sheer or transparent fabric, exposed intimate areas, extreme plunging neckline, or sexually provocative styling. The result must read as structured, sensual, polished, proper, and intentionally fashionable.

STYLE — {style_text}. Match the reference head's lighting direction, color temperature, realism, and photographic texture. Avoid airbrushed skin, plastic fabric, exaggerated anatomy, or game-interface styling.

NO COBALT — cobalt is forbidden in clothing, footwear, jewellery, backdrop, and lighting. If the editable art direction requests cobalt, substitute ultramarine and keep the rest of the direction unchanged.

NO GREEN — ban the color green everywhere in the image: no green clothing, garment parts, or accessories, no green props or jewelry stones, no green background, backdrop tint, or green cast in the lighting. If the editable art direction asks for green, substitute a different color and keep everything else of that direction. Downstream alpha keying misreads green as background, so any green in the plate corrupts the cutout.

NO WHITE WARDROBE — ban white and off-white in everything worn: no white or off-white tops, shirts, dresses, trousers, skirts, jackets, or outerwear, and absolutely no white shoes, sneakers, heels, or soles. The figure is cut out from a light studio backdrop, and white wardrobe dissolves into it and shreds the silhouette. If the editable art direction asks for white, substitute a clearly non-white, non-green color and keep everything else of that direction.

BACKGROUND — simple clean studio backdrop with strong person/background separation, never green or green-tinted. The application will remove the background locally, so preserve fine hair edges and do not add smoke, veils, loose particles, or cast shadows behind the figure."""
    return _fit_full_body_prompt(prompt)


def _detect(image, label):
    height, width = image.shape[:2]
    regions = [(0, 0, width, height)]
    if height > width:
        regions += [(0, 0, width, int(height * fraction)) for fraction in (0.58, 0.46, 0.38)]
    for x, y, region_width, region_height in regions:
        crop = image[y:y + region_height, x:x + region_width]
        for scale in (1.0, 2.0, 3.5):
            candidate = crop if scale == 1.0 else cv2.resize(
                crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_LANCZOS4)
            landmarks, _ = face.detect(candidate)
            if landmarks is not None:
                landmarks = landmarks / scale
                landmarks[:, 0] += x
                landmarks[:, 1] += y
                return landmarks
    raise RuntimeError(f"no face detected in the {label}")


def _face_transform(keyframe, body_image):
    key_landmarks = _detect(keyframe, "identity portrait")
    body_landmarks = _detect(body_image, "generated body")
    source = key_landmarks[face.RIGID].astype(np.float32)
    target = body_landmarks[face.RIGID].astype(np.float32)
    transform, inliers = cv2.estimateAffinePartial2D(
        source, target, method=cv2.LMEDS, refineIters=20)
    if transform is None:
        raise RuntimeError("could not align the original face to the generated body")
    projected = cv2.transform(source[None, :, :], transform)[0]
    residual = np.linalg.norm(projected - target, axis=1)
    oval = body_landmarks[face.FACE_OVAL]
    x, y, width, height = cv2.boundingRect(np.round(oval).astype(np.int32))
    scale = float(np.sqrt(transform[0, 0] ** 2 + transform[0, 1] ** 2))
    failure = _head_alignment_failure(
        scale, (x, y, width, height), body_image.shape, residual)
    if failure:
        raise RuntimeError(failure)
    return transform, {
        "residual_median_px": round(float(np.median(residual)), 3),
        "residual_max_px": round(float(np.max(residual)), 3),
        "scale": round(scale, 5),
        "face_bounds": [int(x), int(y), int(width), int(height)],
    }, key_landmarks


def _head_mask(cutout_image, landmarks, destination):
    alpha = cutout_image[:, :, 3].astype(np.float32) / 255.0
    oval = landmarks[face.FACE_OVAL]
    chin = float(np.max(oval[:, 1]))
    top = float(np.min(oval[:, 1]))
    left, right = float(np.min(oval[:, 0])), float(np.max(oval[:, 0]))
    center = (left + right) * 0.5
    face_width = max(1.0, right - left)
    face_height = max(1.0, chin - top)
    # Long dissolve: the live head and the generated body render hair with
    # different tone and sharpness, and a short fade turns that difference
    # into a visible horizontal band (carol, 2026-08-01). Half a face-height
    # spreads the handover below anything the eye can anchor on.
    fade_start = min(alpha.shape[0] - 2, chin + face_height * 0.05)
    fade_end = min(alpha.shape[0], chin + face_height * 0.55)
    ys = np.arange(alpha.shape[0], dtype=np.float32)
    fade = np.ones_like(ys)
    if fade_end > fade_start:
        region = (ys - fade_start) / (fade_end - fade_start)
        fade = np.clip(1.0 - region, 0.0, 1.0)
        fade = fade * fade * (3.0 - 2.0 * fade)
    neck_start = chin + face_height * 0.01
    progress = np.clip((ys - neck_start) / max(1.0, fade_end - neck_start), 0.0, 1.0)
    half_width = face_width * (0.34 - 0.07 * progress)
    # A narrow feather sliced vertically through the side hair; the gate
    # now dissolves over ~12% of the face width instead of 3.5%.
    feather = max(16.0, face_width * 0.12)
    xs = np.arange(alpha.shape[1], dtype=np.float32)[None, :]
    neck_gate = np.clip((half_width[:, None] + feather - np.abs(xs - center)) / feather, 0.0, 1.0)
    # The gate must ENGAGE gradually: a binary row switch at neck_start put
    # full portrait hair one row above and body hair one row below - the
    # horizontal border line the owner circled at chin height (carol,
    # 2026-08-01). Ramp it in over 0.28 face-heights: long enough that the
    # side hair dissolves, short enough that a portrait's own clothing
    # cannot ghost onto the generated outfit further down.
    engage = np.clip((ys - neck_start) / max(1.0, face_height * 0.28), 0.0, 1.0)
    engage = engage * engage * (3.0 - 2.0 * engage)
    neck_gate = 1.0 - engage[:, None] * (1.0 - neck_gate)
    mask = np.clip(alpha * fade[:, None] * neck_gate, 0.0, 1.0)
    rgba = np.full((*mask.shape, 4), 255, dtype=np.uint8)
    rgba[:, :, 3] = np.round(mask * 255).astype(np.uint8)
    cv2.imwrite(destination, rgba)


def _seam_tone_match(body_path, keyframe, portrait_cutout, mask_path,
                     transform, face_bounds):
    """The live head is a supersampled portrait; the body plate is a softer
    generated render. Where the head mask hands one to the other, their
    low-frequency tone difference reads as a horizontal band through the
    hair no matter how wide the dissolve is (carol, 2026-08-01). Shift the
    body plate's low frequencies toward the warped portrait inside the
    handover zone, fading out with the portrait's own silhouette."""
    if not face_bounds:
        return
    body_rgba = cv2.imread(body_path, cv2.IMREAD_UNCHANGED)
    height, width = body_rgba.shape[:2]
    warped = cv2.warpAffine(
        keyframe, transform, (width, height), flags=cv2.INTER_AREA)
    silhouette = cv2.warpAffine(
        portrait_cutout[:, :, 3], transform, (width, height)
    ).astype(np.float32) / 255.0
    mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)[:, :, 3]
    handover = cv2.warpAffine(mask, transform, (width, height)
                              ).astype(np.float32) / 255.0
    face_width = max(24.0, float(face_bounds[2]))
    low_sigma = face_width * 0.30
    body_bgr = body_rgba[:, :, :3].astype(np.float32)
    body_alpha = body_rgba[:, :, 3].astype(np.float32) / 255.0

    def masked_blur(image, alpha):
        # alpha-normalized blur: backgrounds and transparent pixels carry
        # zero weight, so they can never leak brightness into the delta
        blurred = cv2.GaussianBlur(image * alpha[..., None], (0, 0), low_sigma)
        cover = cv2.GaussianBlur(alpha, (0, 0), low_sigma)
        return blurred / np.maximum(cover, 1e-3)[..., None]

    delta = np.clip(masked_blur(warped.astype(np.float32), silhouette)
                    - masked_blur(body_bgr, body_alpha), -36.0, 36.0)
    # Correct ONLY around the transition line: the band term peaks where
    # head and body mix half-and-half and is zero where either side owns
    # the pixel outright - a first version weighted by the whole mask
    # washed the neck and chest with portrait brightness.
    band = np.clip(handover * (1.0 - handover) * 4.0, 0.0, 1.0)
    weight = np.clip(cv2.GaussianBlur(band, (0, 0), face_width * 0.12) * 1.4,
                     0.0, 1.0)
    weight *= np.clip(silhouette * 1.5, 0.0, 1.0) * body_alpha
    # Hair columns only: the neck skin of the two renders already agrees,
    # and correcting it painted a faint light collar across the throat.
    center_x = face_bounds[0] + face_bounds[2] * 0.5
    xs = np.abs(np.arange(width, dtype=np.float32) - center_x) / face_width
    hair_side = np.clip((xs - 0.38) / 0.22, 0.0, 1.0)
    hair_side = hair_side * hair_side * (3.0 - 2.0 * hair_side)
    weight *= hair_side[None, :]
    body_rgba[:, :, :3] = np.clip(
        body_bgr + delta * weight[..., None], 0, 255).astype(np.uint8)
    cv2.imwrite(body_path, body_rgba)


def _alpha_bounds(image):
    points = cv2.findNonZero((image[:, :, 3] > 8).astype(np.uint8))
    if points is None:
        raise RuntimeError("the generated body cutout is empty")
    return [int(value) for value in cv2.boundingRect(points)]


def _identity_reference(avatar_dir):
    head = os.path.join(avatar_dir, "head.png")
    return head if os.path.isfile(head) else os.path.join(avatar_dir, "keyframe.png")


def _emit(progress, stage, value, label):
    if progress:
        progress(stage, value, label)


def _cached_view_source(cache_dir, view):
    if not os.path.isdir(cache_dir):
        return None
    prefix = f"source-{view}."
    return next((
        os.path.join(cache_dir, name)
        for name in sorted(os.listdir(cache_dir))
        if name.startswith(prefix) and os.path.isfile(os.path.join(cache_dir, name))
    ), None)


def supports_xai_edit(provider):
    """Whether this public provider descriptor may edit an existing body."""
    return bool(
        isinstance(provider, dict)
        and provider.get("name") == XAI_EDIT_PROVIDER
        and provider.get("model") == XAI_EDIT_MODEL
    )


def _body_metadata(avatar_dir):
    path = os.path.join(avatar_dir, "body", "body.json")
    try:
        with open(path, encoding="utf-8") as handle:
            metadata = json.load(handle)
    except (OSError, ValueError) as error:
        raise RuntimeError("generate a complete full-body set before editing it") from error
    if not isinstance(metadata, dict):
        raise RuntimeError("generate a complete full-body set before editing it")
    return metadata


def _body_source(avatar_dir, metadata, view):
    body_dir = os.path.join(avatar_dir, "body")
    body_root = os.path.realpath(body_dir)
    record = (metadata.get("views") or {}).get(view) or {}
    name = os.path.basename(str(record.get("source") or ""))
    candidate = os.path.join(body_dir, name) if name else ""
    if (candidate and os.path.isfile(candidate)
            and not os.path.islink(candidate)
            and os.path.commonpath((body_root, os.path.realpath(candidate))) == body_root):
        return candidate
    prefix = f"source-{view}."
    candidates = [
        os.path.join(body_dir, item)
        for item in sorted(os.listdir(body_dir))
        if (item.startswith(prefix)
            and os.path.isfile(os.path.join(body_dir, item))
            and not os.path.islink(os.path.join(body_dir, item))
            and os.path.commonpath((
                body_root, os.path.realpath(os.path.join(body_dir, item)))) == body_root)
    ] if os.path.isdir(body_dir) else []
    if len(candidates) == 1:
        return candidates[0]
    raise RuntimeError(f"the current {view} source plate is missing")


def _edit_instruction(value):
    instruction = _clean(value, 600)
    if len(instruction) < 4:
        raise ValueError("describe the full-body change in at least four characters")
    from . import wardrobe
    if wardrobe._assigns_gold(instruction):
        raise ValueError("gold styling is not allowed in a full-body edit")
    if wardrobe._assigns_excessive_accessories(instruction):
        raise ValueError("excessive accessories are not allowed in a full-body edit")
    return instruction


def _edit_prompt(instruction, view):
    """A bounded, view-aware prompt for one member of a matched edit set."""
    if view not in BODY_VIEWS:
        raise ValueError(f"unknown full-body view: {view}")
    from . import wardrobe
    reference_contract = {
        "front": (
            "Reference 1 is the approved FRONT body plate. Reference 2 is the "
            "canonical identity head."
        ),
        "side": (
            "Reference 1 is the approved RIGHT-SIDE body plate. Reference 2 is "
            "the newly edited FRONT plate and is the authority for the requested "
            "wardrobe change. Reference 3 is the canonical identity head."
        ),
        "back": (
            "Reference 1 is the approved BACK body plate. Reference 2 is the "
            "newly edited FRONT plate and is the authority for the requested "
            "wardrobe change. Reference 3 is the canonical identity head."
        ),
    }[view]
    view_contract = {
        "front": "Keep a true straight-on front view.",
        "side": "Keep a true 90-degree right-side profile.",
        "back": "Keep a true back view with the face completely out of view.",
    }[view]
    return f"""Precisely edit one existing full-body turnaround plate.

REFERENCES — {reference_contract}

REQUESTED CHANGE — {instruction}

EDIT CONTRACT — Apply only the requested visual change, then preserve everything else from Reference 1: the exact adult person, identity, apparent age, skin tone, hairstyle, body proportions, naturally long but realistic legs, pose, hand placement, foot placement, garment fit, materials, lighting, camera height, 3:4 canvas, full-body framing, and clean studio backdrop. {view_contract} Return exactly one person and one complete figure with both hands and both feet visible and clear silhouette margins. Do not crop, zoom, rotate, add text, add props, or redesign the face. Keep the mouth neutral and closed. The three plates must remain one coherent matched turnaround.

IDENTITY LOCK — Use the identity-head reference only to preserve identity and hair. Never paste a floating portrait, enlarge the head, alter facial anatomy, beautify, de-age, or change eyewear.

LOCAL CUTOUT CONTRACT — Keep the backdrop simple and high-contrast for local background removal. No green or green cast anywhere. No white or off-white wardrobe or footwear. Never use cobalt; substitute ultramarine. Preserve fine hair edges without smoke, veils, particles, shadows, furniture, or scenery.

GOLD AND ACCESSORIES — {wardrobe.ACCESSORY_RULE}

DECENCY AND RIG — Opaque public attire only: no nudity, lingerie, bare midriff, sheer fabric, exposed intimate areas, or extreme plunging neckline. Both hands stay empty. Nothing may be held, carried, slung, or hooked on the body."""


def _install_sources(avatar_dir, sources, provider, options, log=print,
                     progress=None, edit_receipt=None, keep_previous=False):
    """Run local cutout/identity QA and atomically install three raw plates."""
    keyframe_path = os.path.join(avatar_dir, "keyframe.png")
    keyframe = cv2.imread(keyframe_path)
    if keyframe is None:
        raise RuntimeError("avatar keyframe is missing")
    identity_reference = _identity_reference(avatar_dir)
    if not os.path.isfile(identity_reference):
        raise RuntimeError("avatar identity head is missing")
    for view in BODY_VIEWS:
        if not os.path.isfile(str(sources.get(view) or "")):
            raise RuntimeError(f"the generated {view} body source is missing")

    stage = tempfile.mkdtemp(prefix=".body-stage-", dir=avatar_dir)
    try:
        staged_sources = {}
        for view in BODY_VIEWS:
            extension = os.path.splitext(sources[view])[1].lower() or ".png"
            staged_sources[view] = os.path.join(stage, f"source-{view}{extension}")
            shutil.copy2(sources[view], staged_sources[view])
        front_extension = os.path.splitext(staged_sources["front"])[1]
        shutil.copy2(
            staged_sources["front"], os.path.join(stage, "source" + front_extension))

        log("removing all three backgrounds locally with macOS Vision")
        view_metadata = {}
        view_images = {}
        purposes = {
            "front": "standing runtime body",
            "side": "Horizon Walk image reference",
            "back": "turn-around continuity reference",
        }
        for view_index, view in enumerate(BODY_VIEWS):
            _emit(
                progress, "cutout", .64 + view_index * .05,
                f"Cutting out {view} full-body view")
            body_path = os.path.join(stage, f"body-{view}.png")
            if not cutout.render(
                    staged_sources[view], body_path, log=log, tight=True):
                raise RuntimeError(f"local person cutout failed for the {view} view")
            body_rgba = cv2.imread(body_path, cv2.IMREAD_UNCHANGED)
            if body_rgba is None or body_rgba.ndim != 3 or body_rgba.shape[2] != 4:
                raise RuntimeError(f"generated {view} body did not produce an RGBA plate")
            height, width = body_rgba.shape[:2]
            view_images[view] = body_rgba
            view_metadata[view] = {
                "image": os.path.basename(body_path),
                "source": os.path.basename(staged_sources[view]),
                "width": int(width),
                "height": int(height),
                "bounds": _alpha_bounds(body_rgba),
                "purpose": purposes[view],
            }
        shutil.copy2(os.path.join(stage, "body-front.png"), os.path.join(stage, "body.png"))

        log("locking the calibrated face onto the generated front body")
        _emit(progress, "identity", .80, "Locking the calibrated face to the front view")
        transform, alignment, key_landmarks = _face_transform(
            keyframe, view_images["front"][:, :, :3])
        portrait_cutout_path = os.path.join(stage, "portrait-cutout.png")
        if not cutout.render(keyframe_path, portrait_cutout_path, log=lambda _message: None):
            raise RuntimeError("could not build the identity overlay mask")
        portrait_cutout = cv2.imread(portrait_cutout_path, cv2.IMREAD_UNCHANGED)
        _head_mask(portrait_cutout, key_landmarks, os.path.join(stage, "head-mask.png"))
        _seam_tone_match(
            os.path.join(stage, "body.png"), keyframe, portrait_cutout,
            os.path.join(stage, "head-mask.png"), transform,
            alignment.get("face_bounds"))
        os.remove(portrait_cutout_path)

        height, width = view_images["front"].shape[:2]
        face_transform = [
            [round(float(value), 7) for value in row]
            for row in transform
        ]
        view_metadata["front"]["face_transform"] = face_transform
        view_metadata["front"]["alignment"] = alignment
        metadata = {
            "v": 3,
            "image": "body.png",
            "head_mask": "head-mask.png",
            "identity_reference": os.path.basename(identity_reference),
            "width": int(width),
            "height": int(height),
            "bounds": _alpha_bounds(view_images["front"]),
            "face_transform": face_transform,
            "alignment": alignment,
            "turnaround": list(BODY_VIEWS),
            "views": view_metadata,
            "motion_reference": {
                "walk_view": "side",
                "walk_source": view_metadata["side"]["source"],
                "idle_view": "front",
                "idle_source": view_metadata["front"]["source"],
                "move_view": "front",
                "move_source": view_metadata["front"]["source"],
            },
            "provider": provider,
            "options": {
                "style": options.get("style", "photorealistic"),
                "pose": options.get("pose", "relaxed"),
                "prompt": _direction(options),
                "outfit": _clean(options.get("outfit"), 500),
                "notes": _clean(options.get("notes"), 600),
            },
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        if edit_receipt:
            metadata["edit"] = dict(edit_receipt)
        with open(os.path.join(stage, "body.json"), "w") as handle:
            json.dump(metadata, handle, indent=1)

        destination = os.path.join(avatar_dir, "body")
        backup = destination + ".previous"
        if os.path.exists(backup):
            shutil.rmtree(backup)
        if os.path.exists(destination):
            os.replace(destination, backup)
        try:
            os.replace(stage, destination)
            stage = None
        except Exception:
            if not os.path.exists(destination) and os.path.exists(backup):
                os.replace(backup, destination)
            raise
        if not keep_previous:
            shutil.rmtree(backup, ignore_errors=True)
        return metadata
    finally:
        if stage and os.path.exists(stage):
            shutil.rmtree(stage, ignore_errors=True)


def build(avatar_dir, options, log=print, progress=None):
    identity_reference = _identity_reference(avatar_dir)
    if not os.path.isfile(identity_reference):
        raise RuntimeError("avatar identity head is missing")
    provider_config, provider = image_provider_selection()
    prompts = {view: _prompt(options, view=view) for view in BODY_VIEWS}
    with open(identity_reference, "rb") as handle:
        identity_digest = hashlib.sha256(handle.read()).hexdigest()
    signature = hashlib.sha256(
        (provider["name"] + "\n" + str(provider.get("model")) + "\n" +
         identity_digest + "\n" + "\n--- VIEW ---\n".join(
             prompts[view] for view in BODY_VIEWS)).encode("utf-8")
    ).hexdigest()
    cache_dir = os.path.join(avatar_dir, ".body-cache")
    cache_signature = os.path.join(cache_dir, "signature")
    cache_matches = False
    if os.path.isfile(cache_signature):
        with open(cache_signature) as handle:
            cache_matches = handle.read().strip() == signature
    if not cache_matches:
        shutil.rmtree(cache_dir, ignore_errors=True)
        os.makedirs(cache_dir, mode=0o700)
        with open(cache_signature, "w") as handle:
            handle.write(signature)
    cached = {
        view: _cached_view_source(cache_dir, view)
        for view in BODY_VIEWS
    }
    provider_stage = tempfile.mkdtemp(prefix=".body-provider-", dir=avatar_dir)
    try:
        log(f"using OpenClam image provider: {provider['title']}")
        sources = {}
        for view_index, view in enumerate(BODY_VIEWS):
            generated = cached[view]
            if generated:
                log(f"reusing the generated {view} body plate after a local QA retry")
            else:
                _emit(
                    progress, "generation", .14 + view_index * .18,
                    f"Generating {view} full-body view")
                log(f"generating {view} full body from the canonical HD head")
                references = [identity_reference]
                if view != "front":
                    references.append(sources["front"])
                provider_dir = os.path.join(provider_stage, view)
                os.makedirs(provider_dir, mode=0o700)
                generated = media_gen.generate_image_edit_sync(
                    prompts[view], references, provider_config,
                    aspect_ratio="3:4", quality="high",
                    output_dir=provider_dir,
                    file_name=f"body-source-{view}")
                extension = os.path.splitext(generated)[1].lower() or ".png"
                cached_path = os.path.join(cache_dir, f"source-{view}{extension}")
                shutil.copy2(generated, cached_path)
                generated = cached_path
            sources[view] = generated
        metadata = _install_sources(
            avatar_dir, sources, provider, options, log=log, progress=progress)
        shutil.rmtree(cache_dir, ignore_errors=True)
        return metadata
    finally:
        shutil.rmtree(provider_stage, ignore_errors=True)


def edit(avatar_dir, instruction, log=print, progress=None):
    """Edit a matched three-view set through xAI Image 2.0 only.

    The provider receives the current local sources and identity head. Canonical
    files are replaced only after all three provider results pass the same local
    cutout and face-lock gates as a newly generated body.
    """
    instruction = _edit_instruction(instruction)
    provider_config, provider = image_provider_selection()
    if not supports_xai_edit(provider):
        raise RuntimeError(
            "Full-body editing requires xAI Grok Imagine Image 2.0 as the "
            "selected Image provider")
    current = _body_metadata(avatar_dir)
    current_sources = {
        view: _body_source(avatar_dir, current, view)
        for view in BODY_VIEWS
    }
    identity_reference = _identity_reference(avatar_dir)
    if not os.path.isfile(identity_reference):
        raise RuntimeError("avatar identity head is missing")
    provider_stage = tempfile.mkdtemp(prefix=".body-edit-provider-", dir=avatar_dir)
    edited = {}
    try:
        log(f"using {provider['title']} to edit the matched full-body set")
        for view_index, view in enumerate(BODY_VIEWS):
            _emit(
                progress, "editing", .10 + view_index * .18,
                f"Editing {view} full-body view")
            references = [current_sources[view]]
            if view != "front":
                references.append(edited["front"])
            references.append(identity_reference)
            output_dir = os.path.join(provider_stage, view)
            os.makedirs(output_dir, mode=0o700)
            edited[view] = media_gen.generate_image_edit_sync(
                _edit_prompt(instruction, view), references, provider_config,
                aspect_ratio="3:4", quality="high", output_dir=output_dir,
                file_name=f"body-edit-{view}")
        options = dict(current.get("options") or {})
        body_path = os.path.join(avatar_dir, "body", "body.png")
        with open(body_path, "rb") as handle:
            source_body_sha = hashlib.sha256(handle.read()).hexdigest()
        receipt = {
            "provider": provider,
            "scope": "front+side+back",
            "instruction_sha256": hashlib.sha256(
                instruction.encode("utf-8")).hexdigest(),
            "source_body_sha256": source_body_sha,
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        return _install_sources(
            avatar_dir, edited, provider, options, log=log, progress=progress,
            edit_receipt=receipt, keep_previous=True)
    finally:
        shutil.rmtree(provider_stage, ignore_errors=True)


def commit_previous(avatar_dir):
    shutil.rmtree(os.path.join(avatar_dir, "body.previous"), ignore_errors=True)


def restore_previous(avatar_dir):
    """Restore the pre-edit body after a manifest/runtime transaction fails."""
    destination = os.path.join(avatar_dir, "body")
    previous = destination + ".previous"
    if not os.path.isdir(previous):
        return False
    failed = destination + ".failed-edit"
    shutil.rmtree(failed, ignore_errors=True)
    if os.path.exists(destination):
        os.replace(destination, failed)
    try:
        os.replace(previous, destination)
    except Exception:
        if not os.path.exists(destination) and os.path.exists(failed):
            os.replace(failed, destination)
        raise
    shutil.rmtree(failed, ignore_errors=True)
    return True


def remove(avatar_dir):
    shutil.rmtree(os.path.join(avatar_dir, "body"), ignore_errors=True)
    shutil.rmtree(os.path.join(avatar_dir, ".body-cache"), ignore_errors=True)
