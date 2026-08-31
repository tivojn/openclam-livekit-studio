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

from . import body_alpha, body_proportion, cutout, face


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
_MIN_GENERATED_FACE_AXIS_FRACTION = 0.90
# Handoff v2 shipped before the medium-aware curved jaw boundary: in
# particular, a soft-3-D source could retain too much of its rendered neck and
# expose a second chin at runtime.  Never infer the corrected geometry merely
# from ``head_clear_mask`` because existing v2 bodies already carry that asset.
# V3 added the medium-aware jaw but still used different canvas-dependent
# lateral fields for the portrait and body. V4 authors both in face geometry.
# Every newly authored stylized body gets this explicit current marker.
STYLIZED_HEAD_HANDOFF_VERSION = 4
SOFT_3D_NECK_REGISTRATION_VERSION = 1
SOFT_3D_JAW_BAND_REPAIR_VERSION = 1
DEFAULT_BODY_PROMPT = (
    "Create a photorealistic couture-level full-body wardrobe with tailored "
    "authority, professional editorial polish, and zero fast-fashion noise. Read only "
    "the subject's visible feminine, masculine, or androgynous presentation; "
    "do not claim a gender identity and never force a gendered shoe or beauty "
    "code when the presentation is uncertain. Use vivid fuchsia as the single "
    "hero colour, with at most one quiet black, charcoal, taupe, or chocolate "
    "grounding neutral. Keep the hero clear, bright, saturated, and luminous, "
    "never dusty, muddy, muted, greyed, or near-black. Ban every blue-family colour from wardrobe, footwear, accessories, props, backdrop, and light cast, including cobalt, "
    "ultramarine, navy, royal blue, sapphire, azure, cerulean, indigo, cyan, "
    "teal, turquoise, aqua, and periwinkle. Green is also unavailable in those "
    "styling and scene elements because it damages alpha extraction. Preserve "
    "natural eye and hair colour. Substitute vivid fuchsia, scarlet, or coral. "
    "Let the hero "
    "or its tonal family dominate visible fabric; use zero or one small accent "
    "and never divide the figure into three competing colour blocks. Resolve one "
    "complete outfit with one dominant silhouette and a deliberate uninterrupted "
    "line from shoulder to shoe. Use only opaque, fashionable lightweight "
    "fabric, never midweight or medium-weight, with fluid drape and crisp seam "
    "tension. Keep the silhouette structured, authoritative, and polished: no bare "
    "midriff, sheer fabric, or extreme plunging neckline. Keep accessories "
    "minimal and understated, never ornate, layered, stacked, or visually busy. "
    "Preserve the existing hairstyle with a sleek finish, luminous real skin "
    "texture, defined brows, and presentation-appropriate grooming. Keep "
    "everything opaque and suitable "
    "for public view: no nudity, lingerie, or exposed intimate areas. Both hands "
    "stay empty and clearly visible; nothing is held, carried, or slung on the "
    "body."
)


class GeneratedBodyIdentityError(RuntimeError):
    """A generated plate that cannot safely receive the calibrated identity."""


class GeneratedBodyAlphaError(RuntimeError):
    """A generated plate that cannot produce a safe transparent runtime body."""


class GeneratedBodyProportionError(RuntimeError):
    """A generated body that misses an explicitly requested fashion proportion."""


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


_STYLISED_SOURCE_MEDIA = {
    "game art": "game art",
    "game-art": "game art",
    "anime": "anime",
    "illustration": "illustration",
    "illustrated": "illustration",
    "cartoon": "illustration",
    "drawing": "illustration",
    "3d render": "3d render",
    "3d-render": "3d render",
    "soft-3d": "3d render",
}


def _normalise_source_medium(value, legacy_mode=None):
    """Whitelist the local detector branch; every unknown value is a photo."""
    medium = _clean(value, 40).lower()
    if medium in _STYLISED_SOURCE_MEDIA:
        return _STYLISED_SOURCE_MEDIA[medium]
    legacy = _clean(legacy_mode, 40).lower()
    if not medium and legacy.startswith("stylized"):
        return "illustration"
    return "photograph"


def _stored_source_medium(avatar_dir):
    """Read only intake/build evidence stored with the avatar.

    Body style and wardrobe-planner output are user/provider presentation
    choices.  They are never authority to lower face or alpha gates.  The
    original intake report wins when present; older projects may fall back to
    their stored canonical-head report.  Missing, malformed, ``unknown`` and
    arbitrary values all remain photographic.
    """
    try:
        with open(os.path.join(avatar_dir, "manifest.json"),
                  encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError, TypeError):
        return "photograph"
    if not isinstance(manifest, dict):
        return "photograph"
    for key in ("source_metrics", "metrics"):
        if key not in manifest:
            continue
        report = manifest.get(key)
        if not isinstance(report, dict):
            return "photograph"
        return _normalise_source_medium(
            report.get("source_medium"), report.get("source_mode"))
    head = manifest.get("head")
    if isinstance(head, dict) and "source_medium" in head:
        return _normalise_source_medium(head.get("source_medium"))
    return "photograph"


def _allow_stylized_source(avatar_dir):
    """Enable permissive local geometry only from stored intake evidence."""
    return _stored_source_medium(avatar_dir) != "photograph"


def _source_override_options(avatar_dir, options):
    """Apply only an explicit owner category to full-body authoring options.

    Automatic classification keeps the historical, independently selectable
    treatment behavior.  A manual choice is different: it exists specifically
    to prevent a heuristic mistake from sending body prompts, alpha QA, neck
    alignment, motion, and packaging down conflicting lanes.
    """
    try:
        with open(os.path.join(avatar_dir, "manifest.json"),
                  encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError, TypeError):
        return dict(options or {})
    raw = (manifest.get("source_medium_override")
           if isinstance(manifest, dict) else None)
    medium = str(raw or "").strip().lower()
    if medium not in {"photograph", "illustration", "3d render"}:
        return dict(options or {})
    result = dict(options or {})
    result["medium"] = medium
    compatible = {
        "photograph": {"photorealistic", "editorial"},
        "illustration": {"illustrated", "anime"},
        "3d render": {"soft-3d"},
    }
    defaults = {
        "photograph": "photorealistic",
        "illustration": "illustrated",
        "3d render": "soft-3d",
    }
    if result.get("style") not in compatible[medium]:
        result["style"] = defaults[medium]
    return result


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
    # A one-axis cutoff made a perfectly usable 82x112 face fail a nominal
    # 84x100 target forever. Judge actual face detail, while keeping a lower
    # floor on both axes so a very narrow or flat detection cannot buy its way
    # through with area alone. The landmark-fit gate below remains authoritative
    # for shape/alignment quality.
    required_area = required_width * required_height
    minimum_width = max(
        1, int(np.ceil(required_width * _MIN_GENERATED_FACE_AXIS_FRACTION)))
    minimum_height = max(
        1, int(np.ceil(required_height * _MIN_GENERATED_FACE_AXIS_FRACTION)))
    face_area = face_width * face_height
    if (face_width < minimum_width
            or face_height < minimum_height
            or face_area < required_area):
        return (
            "generated head is too small for a crisp identity lock "
            f"({face_width}x{face_height}px; need detail equivalent to "
            f"{required_width}x{required_height}px, with neither axis below "
            f"{minimum_width}x{minimum_height}px)")

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
    remove_headwear = bool(options.get("remove_headwear", False))
    headwear_rule = (
        wardrobe.REMOVE_HEADWEAR_RULE if remove_headwear
        else wardrobe.SOURCE_HEADWEAR_RULE)
    accessory_rule = (
        wardrobe.REMOVE_HEADWEAR_ACCESSORY_RULE if remove_headwear
        else wardrobe.ACCESSORY_RULE)
    # Cached house prompts carry deterministic negative clauses which must name
    # every forbidden item. Remove those exact app-authored rules before checking
    # only the owner's/model's editable prose for contradictory assignments.
    editable_direction = direction
    fixed_rules = (
        wardrobe.ACCESSORY_RULE,
        wardrobe.REMOVE_HEADWEAR_ACCESSORY_RULE,
        wardrobe.SOURCE_HEADWEAR_RULE,
        wardrobe.REMOVE_HEADWEAR_RULE,
        wardrobe.AESTHETIC_COHERENCE_RULE,
        wardrobe.FASHION_FABRIC_RULE,
        wardrobe.STRUCTURAL_RULE,
        wardrobe.LUXURY_FINISH_RULE,
        wardrobe.COLOR_RULE,
        wardrobe.STYLISED_RULE,
        presentation_rule,
    ) + tuple(
        wardrobe.resolved_color_rule(hero) for hero in wardrobe.HERO_COLORS
    )
    for fixed_rule in fixed_rules:
        editable_direction = editable_direction.replace(fixed_rule, " ")
    if presentation != "feminine" and wardrobe._assigns_feminine_heels(
            editable_direction):
        raise ValueError(
            "the full-body direction assigns feminine heels to a "
            "non-feminine presentation")
    if presentation != "feminine" and wardrobe._assigns_feminine_garment(
            editable_direction):
        raise ValueError(
            "the full-body direction assigns a feminine garment to a "
            "non-feminine presentation")
    if wardrobe._assigns_gold(editable_direction):
        raise ValueError("the full-body direction assigns forbidden gold styling")
    if wardrobe._assigns_excessive_accessories(editable_direction):
        raise ValueError("the full-body direction assigns excessive accessories")
    if wardrobe._assigns_heavy_styling(editable_direction):
        raise ValueError(
            "the full-body direction assigns heavy fabric or throat-covering knitwear")
    if wardrobe._assigns_blue(editable_direction):
        raise ValueError(
            "the full-body direction assigns a forbidden blue-family colour")
    if wardrobe._assigns_green(editable_direction):
        raise ValueError(
            "the full-body direction assigns a forbidden green-family colour")
    if presentation == "feminine":
        if wardrobe._assigns_long_feminine_hem(editable_direction):
            raise ValueError(
                "the full-body direction assigns a feminine hem at or below the knee")
        if wardrobe._assigns_too_short_feminine_hem(editable_direction):
            raise ValueError(
                "the full-body direction assigns an upper-thigh or mini feminine hem")
        if wardrobe._assigns_immodest_office_style(editable_direction):
            raise ValueError(
                "the full-body direction assigns non-office feminine styling")
        if wardrobe._assigns_non_killer_feminine_footwear(editable_direction):
            raise ValueError(
                "the full-body direction assigns non-stiletto feminine footwear")
    conflicts = wardrobe.aesthetic_conflicts(editable_direction)
    if conflicts:
        raise ValueError(
            "the full-body direction fails aesthetic coherence: "
            + "; ".join(conflicts))
    # Wardrobe's cached brief ends with deterministic house and rig clauses.
    # This plate wrapper carries those clauses itself, so remove their exact
    # duplicates before adding the view-specific identity/turnaround contract.
    stylised = medium in {"game art", "anime", "illustration", "3d render"}
    repeated_rules = [
        presentation_rule, wardrobe.AESTHETIC_COHERENCE_RULE,
        wardrobe.FASHION_FABRIC_RULE,
        wardrobe.ACCESSORY_RULE, wardrobe.REMOVE_HEADWEAR_ACCESSORY_RULE,
        wardrobe.SOURCE_HEADWEAR_RULE,
        wardrobe.REMOVE_HEADWEAR_RULE, wardrobe.STRUCTURAL_RULE,
    ]
    house_section = ""
    if not stylised:
        selected_color_rule = wardrobe.resolved_color_rule(
            wardrobe._hero_from_text(direction))
        repeated_rules += [
            wardrobe.COLOR_RULE, selected_color_rule,
            wardrobe.LUXURY_FINISH_RULE,
        ]
        house_section = (
            "\n\nHOUSE STYLE — " + selected_color_rule + " "
            + wardrobe.AESTHETIC_COHERENCE_RULE + " "
            + wardrobe.FASHION_FABRIC_RULE + " "
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
            "Create canonical RIGHT-SIDE: nose, chest, knees, and toes point exactly "
            "camera-right in true 90-degree profile, never front/three-quarter. Reference 1 "
            "owns identity; Reference 2 (approved front) owns wardrobe, proportions, "
            "materials, color, headwear geometry, accessories, and garment length."
        ),
        "back": (
            "Create canonical BACK: back of head, shoulders, spine, hips, knees, and heels "
            "face camera; face fully hidden, with no over-shoulder turn. Reference 1 owns "
            "identity/hair; Reference 2 (approved front) owns wardrobe, proportions, "
            "materials, color, headwear geometry, accessories, and garment length."
        ),
    }[view]
    # Keep the deterministic contract compact. xAI Imagine enforces an 8 KiB
    # request ceiling, and side/back view instructions are longer than front.
    # Repeating the same ban in several paragraphs used to leave under 256
    # bytes for the owner's actual art direction and made a valid three-view
    # build fail before reaching the provider. Each non-negotiable now appears
    # once, leaving a useful editable budget for every view/presentation branch.
    prompt = f"""Create one vertical 3:4 full-body {view}-view plate of the exact same adult person.

TURNAROUND — matched FRONT / RIGHT-SIDE / BACK; one complete figure, never triptych, split, duplicate, inset, or diagram. Keep pose, limbs, outfit, scale, and camera height fixed; rotate only the camera.

IDENTITY LOCK — preserve face, skull, skin, hair, brows, eyes, nose, lips, ears, age, and eyeglasses; never remove them. If absent, add none. Apply HEADWEAR OVERRIDE below. Neutral closed mouth; never beautify, de-age, or redesign. Head upright; neck centred.

VIEW — {view_text}

COMPOSITION — complete figure, hair through both feet, 7% clear margin. Waist-height long-lens camera with minimal distortion. Use a {pose_text}. Complete anatomical hands, legs, and footwear; no crop, props, furniture, or text.

PROPORTION TARGET — high-fashion runway-supermodel silhouette, roughly 7.5 to 8 heads tall; crown-to-chin 12.5 to 13.3 percent of standing height. Never copy the oversized head scale of the close-up reference. Hair and retained headwear stay within the clear margin. Adult-width shoulders, compact torso, long sculpted legs just over half-height. Reject stretched limbs, head-heavy silhouette, or warped anatomy.

CARRY NOTHING — both hands are completely empty and visible. No bag, handbag, clutch, purse, tote, backpack, briefcase, phone, cup, umbrella, weapon, staff, or other held object; no strap or pouch on shoulder, elbow, or body.

NO GOLD AND MINIMAL ACCESSORIES — {accessory_rule}

EDITABLE ART DIRECTION — {direction}{house_section}

PRESENTATION AND FOOTWEAR — this plate uses only the {presentation} branch inferred from the reference; it is visible styling, not a claim about gender identity. {presentation_rule}

DECENCY FLOOR — tasteful opaque public clothing: no nudity, lingerie, bare midriff, sheer fabric, exposed intimate areas, extreme plunging neckline, or vulgar styling. Read as professional, polished, proper, and fashionable.

STYLE — {style_text}. Match the head's lighting, colour temperature, realism, and texture. Avoid airbrushed skin, plastic fabric, exaggerated anatomy, or game UI styling.

NO BLUE / NO COBALT — forbid every blue-family colour in newly designed wardrobe, footwear, accessories, props, backdrop, and light cast: cobalt, ultramarine, navy, royal blue, sapphire, azure, cerulean, indigo, cyan, teal, turquoise, aqua, periwinkle, and blue-violet. Preserve natural eye and hair colour. Substitute vivid fuchsia, scarlet, or coral.

NO GREEN — no green clothing; never green or green-tinted props, backdrop, or light cast; substitute a different color. Green corrupts alpha.

NO WHITE WARDROBE — no white/off-white garments, no white shoes or soles. They dissolve into the cutout backdrop. Substitute a clearly non-white, non-green color.

HEADWEAR OVERRIDE — {headwear_rule}

SOURCE PLATE—Uniform RGB-255 white continues behind and beneath the figure. Flat frontal light; the figure casts nothing. White touches every outsole edge, both sides of each heel stem, and every body/clothing gap. Return only figure and white."""
    return _fit_full_body_prompt(prompt)


def _detect(image, label, allow_stylized=False):
    height, width = image.shape[:2]
    regions = [(0, 0, width, height)]
    if height > width:
        regions += [(0, 0, width, int(height * fraction)) for fraction in (0.58, 0.46, 0.38)]
    for x, y, region_width, region_height in regions:
        crop = image[y:y + region_height, x:x + region_width]
        for scale in (1.0, 2.0, 3.5):
            candidate = crop if scale == 1.0 else cv2.resize(
                crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_LANCZOS4)
            if allow_stylized:
                landmarks, _transform, _metadata = face.detect_for_intake(
                    candidate)
            else:
                landmarks, _transform = face.detect(candidate)
            if landmarks is not None:
                landmarks = landmarks / scale
                landmarks[:, 0] += x
                landmarks[:, 1] += y
                return landmarks
    raise RuntimeError(f"no face detected in the {label}")


def _stylized_neck_center(body_image, face_bounds):
    """Return the centre of the narrow neck silhouette below a cartoon face.

    Cartoon face landmarks are useful for scale, but their horizontal centre
    can be biased by a large hat, oversized eyes, or asymmetric hair.  The
    body cutout is the authoritative signal for where the head must meet the
    shoulders.  Sample the jaw-to-shoulder band, retain plausible dense neck
    rows, and use the narrowest fifth so widening shoulders cannot pull the
    result sideways.

    The helper accepts either the RGBA cutout used by the body pipeline or a
    BGR cutout whose transparent pixels have already been zeroed.  Returning
    ``(None, metadata)`` is intentionally safe: the caller falls back to the
    established canvas-centre anchor rather than guessing.
    """
    if (body_image is None or body_image.ndim != 3
            or body_image.shape[2] not in (3, 4)
            or not isinstance(face_bounds, (list, tuple))
            or len(face_bounds) != 4):
        return None, {"applied": False, "reason": "invalid inputs"}
    face_x, face_y, face_width, face_height = [float(v) for v in face_bounds]
    if (not all(np.isfinite(v) for v in (
            face_x, face_y, face_width, face_height))
            or face_width < 8.0 or face_height < 8.0):
        return None, {"applied": False, "reason": "invalid face bounds"}

    if body_image.shape[2] == 4:
        foreground = body_image[:, :, 3] > 8
    else:
        # Cutout RGB is zero outside its alpha support.  Requiring any channel
        # above four tolerates antialiasing without mistaking a black hair or
        # garment interior for a separate silhouette component.
        foreground = np.any(body_image[:, :, :3] > 4, axis=2)

    height, width = foreground.shape
    start = max(0, int(np.floor(face_y + face_height * 0.72)))
    stop = min(height, int(np.ceil(face_y + face_height * 1.20)) + 1)
    expected = face_x + face_width * 0.5
    minimum_span = max(6.0, face_width * 0.18)
    maximum_span = min(float(width), face_width * 1.60)
    candidates = []
    for row in range(start, stop):
        columns = np.flatnonzero(foreground[row])
        if columns.size < minimum_span:
            continue
        left = float(columns[0])
        right = float(columns[-1])
        span = right - left + 1.0
        if not minimum_span <= span <= maximum_span:
            continue
        density = float(columns.size) / span
        centre = (left + right) * 0.5
        if density < 0.55 or abs(centre - expected) > face_width * 0.75:
            continue
        candidates.append((span, centre, row))
    if len(candidates) < 5:
        return None, {
            "applied": False,
            "reason": "neck silhouette was not measurable",
            "candidate_rows": len(candidates),
        }

    candidates.sort(key=lambda item: (item[0], item[2]))
    retained_count = max(5, int(np.ceil(len(candidates) * 0.20)))
    retained = candidates[:retained_count]
    centres = np.asarray([item[1] for item in retained], dtype=np.float64)
    spans = np.asarray([item[0] for item in retained], dtype=np.float64)
    rows = [int(item[2]) for item in retained]
    centre = float(np.median(centres))
    return centre, {
        "applied": True,
        "method": "narrow-body-silhouette",
        "target_x": round(centre, 3),
        "row_range": [min(rows), max(rows)],
        "median_span": round(float(np.median(spans)), 3),
        "candidate_rows": len(candidates),
    }


def _face_transform(keyframe, body_image, allow_stylized=False):
    body_bgr = body_image[:, :, :3] \
        if body_image is not None and body_image.ndim == 3 \
        else body_image
    key_landmarks = _detect(
        keyframe, "identity portrait", allow_stylized=allow_stylized)
    try:
        body_landmarks = _detect(
            body_bgr, "generated body", allow_stylized=allow_stylized)
    except RuntimeError as error:
        raise GeneratedBodyIdentityError(str(error)) from error
    source = key_landmarks[face.RIGID].astype(np.float32)
    target = body_landmarks[face.RIGID].astype(np.float32)
    transform, inliers = cv2.estimateAffinePartial2D(
        source, target, method=cv2.LMEDS, refineIters=20)
    if transform is None:
        raise GeneratedBodyIdentityError(
            "could not align the original face to the generated body")
    projected = cv2.transform(source[None, :, :], transform)[0]
    residual = np.linalg.norm(projected - target, axis=1)
    oval = body_landmarks[face.FACE_OVAL]
    x, y, width, height = cv2.boundingRect(np.round(oval).astype(np.int32))
    scale = float(np.sqrt(transform[0, 0] ** 2 + transform[0, 1] ** 2))
    failure = _head_alignment_failure(
        scale, (x, y, width, height), body_image.shape, residual)
    if failure:
        raise GeneratedBodyIdentityError(failure)
    detected_rotation = float(np.degrees(np.arctan2(
        transform[1, 0], transform[0, 0])))
    neck_alignment = None
    if allow_stylized:
        # Cartoon/3-D landmark topology is intentionally permissive, but its
        # rigid points are not a trustworthy roll estimator.  In particular,
        # large stylized eyes can make MediaPipe report a 20–25 degree affine
        # rotation for an image whose eye line, nose and neck are visibly
        # upright.  Baking that false rotation into the body handoff creates a
        # detached diagonal neck in every renderer.  Preserve the robust fit's
        # scale and placement at the rigid-face centroid while locking the
        # canonical head to zero roll.  Photographs retain the measured
        # similarity transform unchanged.
        # Canonical avatar heads are authored around the portrait canvas
        # centre.  Keeping that exact point fixed is also stable when the
        # stylized detector's rigid landmark centroid is biased by oversized
        # eyes or an asymmetric hat.
        anchor = np.array([
            keyframe.shape[1] * 0.5,
            keyframe.shape[0] * 0.5,
        ], dtype=np.float64)
        mapped_anchor = np.asarray(transform, dtype=np.float64) @ np.array(
            [float(anchor[0]), float(anchor[1]), 1.0], dtype=np.float64)
        transform = np.array([
            [scale, 0.0, mapped_anchor[0] - scale * float(anchor[0])],
            [0.0, scale, mapped_anchor[1] - scale * float(anchor[1])],
        ], dtype=np.float64)
        # A level head can still look detached when its neck is translated to
        # a landmark-biased facial centre instead of the torso.  Re-anchor only
        # horizontal translation to the cutout's narrow neck rows; keep scale
        # and vertical placement from the robust face fit.  This is stylized-
        # only: photographic faces retain their measured affine unchanged.
        target_neck_x, neck_alignment = _stylized_neck_center(
            body_image, (x, y, width, height))
        if target_neck_x is not None:
            old_target_x = float(
                transform[0, 0] * anchor[0] + transform[0, 2])
            maximum_shift = max(8.0, min(
                float(body_image.shape[1]) * 0.08,
                float(width) * 0.55,
            ))
            shift = float(target_neck_x - old_target_x)
            if abs(shift) <= maximum_shift:
                transform[0, 2] = (
                    float(target_neck_x) - scale * float(anchor[0]))
                neck_alignment.update({
                    "source_x": round(float(anchor[0]), 3),
                    "shift_x": round(shift, 3),
                })
            else:
                neck_alignment = {
                    "applied": False,
                    "reason": "neck correction exceeded safety limit",
                    "target_x": round(float(target_neck_x), 3),
                    "shift_x": round(shift, 3),
                    "maximum_shift": round(maximum_shift, 3),
                }
    receipt = {
        "residual_median_px": round(float(np.median(residual)), 3),
        "residual_max_px": round(float(np.max(residual)), 3),
        "scale": round(scale, 5),
        "face_bounds": [int(x), int(y), int(width), int(height)],
        "upright_lock": bool(allow_stylized),
        "detected_rotation_degrees": round(detected_rotation, 4),
    }
    if allow_stylized:
        receipt["neck_alignment"] = neck_alignment or {
            "applied": False,
            "reason": "neck silhouette was not measured",
        }
    return transform, receipt, key_landmarks


def _canonical_head_replacement_core(body_shape, transform, key_landmarks):
    """Return the guaranteed body-space core of the runtime head replacement.

    ``_head_mask`` contains the complete canonical facial oval and expands it
    before feathering.  Projecting that same oval with the saved body transform
    therefore gives a conservative subset of the pixels the stylized runtime
    removes.  Alpha QA may safely exempt a component only when every one of its
    pixels lies in this core; hair, wardrobe, floor, and silhouette edges remain
    under the unchanged hard gates.
    """
    height, width = body_shape[:2]
    region = np.zeros((height, width), dtype=np.uint8)
    oval = key_landmarks[face.FACE_OVAL].astype(np.float32)
    projected = cv2.transform(
        oval[None, :, :], np.asarray(transform, dtype=np.float32))[0]
    hull = cv2.convexHull(np.round(projected).astype(np.int32))
    cv2.fillConvexPoly(region, hull, 1)
    return region.astype(bool)


def _body_proportion_report(body_rgba, face_bounds, options, log=print):
    """Measure and enforce an explicitly requested editorial/runway ratio."""
    report = body_proportion.assess(body_rgba, face_bounds, options)
    failure = body_proportion.failure(report)
    if failure:
        raise GeneratedBodyProportionError(failure)
    if report.get("measurable"):
        log(
            "  body proportion ready: "
            f"{report['apparent_heads_tall']:.2f} apparent heads tall")
    return report


def _archive_rejected_body_alpha(
        avatar_dir, source, refined_rgba, report, view):
    """Retain private alpha evidence without publishing a rejected plate.

    Provider sources normally live in ``.body-cache``, which is deliberately
    invalidated after any failed preflight.  Losing the exact rejected image
    made repeated side-view failures impossible to distinguish from a false
    positive.  Keep a bounded, owner-local diagnostic copy under ``diag``;
    nothing in the runtime/body installer reads this directory.
    """
    if view not in BODY_VIEWS:
        raise RuntimeError(f"unknown generated body view: {view}")
    if not os.path.isfile(source):
        raise RuntimeError(f"generated {view} body source is missing")
    if (refined_rgba is None or refined_rgba.ndim != 3
            or refined_rgba.shape[2] != 4):
        raise RuntimeError(
            f"generated {view} body diagnostic is not an RGBA plate")

    rejected_root = os.path.join(avatar_dir, "diag", "body-rejections")
    os.makedirs(rejected_root, mode=0o700, exist_ok=True)
    os.chmod(rejected_root, 0o700)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
    destination = os.path.join(rejected_root, f"{stamp}-{view}-alpha")
    stage = tempfile.mkdtemp(prefix=".rejected-body-", dir=rejected_root)
    try:
        extension = os.path.splitext(source)[1].lower()
        if extension not in {".png", ".jpg", ".jpeg", ".webp"}:
            extension = ".bin"
        archived_source = os.path.join(stage, f"source{extension}")
        shutil.copyfile(source, archived_source)
        os.chmod(archived_source, 0o600)

        refined_path = os.path.join(stage, "refined.png")
        if not cv2.imwrite(refined_path, refined_rgba):
            raise RuntimeError("could not write rejected body RGBA diagnostic")
        os.chmod(refined_path, 0o600)

        source_digest = hashlib.sha256()
        with open(source, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                source_digest.update(chunk)
        manifest = {
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
            "view": view,
            "source_file": os.path.basename(archived_source),
            "source_sha256": source_digest.hexdigest(),
            "refined_file": "refined.png",
            "installed": False,
            "alpha_quality": report,
        }
        report_path = os.path.join(stage, "report.json")
        with open(report_path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(report_path, 0o600)
        os.chmod(stage, 0o700)
        os.replace(stage, destination)
        stage = ""

        # Diagnostics are evidence, not a second asset library.  Retain only
        # the newest twelve complete attempts to keep provider retries bounded.
        attempts = sorted(
            entry for entry in os.listdir(rejected_root)
            if not entry.startswith(".")
            and os.path.isdir(os.path.join(rejected_root, entry)))
        for stale in attempts[:-12]:
            shutil.rmtree(os.path.join(rejected_root, stale), ignore_errors=True)
        return destination
    finally:
        if stage:
            shutil.rmtree(stage, ignore_errors=True)


def _archive_rejected_body_proportion(
        avatar_dir, source, report, alignment=None, refined_rgba=None,
        alpha_quality=None):
    """Retain private evidence for a front plate rejected on proportions.

    The front proportion gate runs before side/back generation, while its
    provider source is still held only in the disposable body cache.  Preserve
    the exact source plus the JSON-safe measurement/alignment metadata so a
    rejected head/body ratio can be audited after that cache is invalidated.
    Rejected evidence is diagnostic-only and is never read by the body
    installer or runtime.
    """
    if not os.path.isfile(source):
        raise RuntimeError("generated front body source is missing")
    if refined_rgba is not None and (
            refined_rgba.ndim != 3 or refined_rgba.shape[2] != 4):
        raise RuntimeError(
            "generated front body diagnostic is not an RGBA plate")

    rejected_root = os.path.join(avatar_dir, "diag", "body-rejections")
    os.makedirs(rejected_root, mode=0o700, exist_ok=True)
    os.chmod(rejected_root, 0o700)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
    destination = os.path.join(
        rejected_root, f"{stamp}-front-proportion")
    stage = tempfile.mkdtemp(prefix=".rejected-body-", dir=rejected_root)
    try:
        extension = os.path.splitext(source)[1].lower()
        if extension not in {".png", ".jpg", ".jpeg", ".webp"}:
            extension = ".bin"
        archived_source = os.path.join(stage, f"source{extension}")
        shutil.copyfile(source, archived_source)
        os.chmod(archived_source, 0o600)

        refined_name = None
        if refined_rgba is not None:
            refined_name = "refined.png"
            refined_path = os.path.join(stage, refined_name)
            if not cv2.imwrite(refined_path, refined_rgba):
                raise RuntimeError(
                    "could not write rejected body RGBA diagnostic")
            os.chmod(refined_path, 0o600)

        source_digest = hashlib.sha256()
        with open(source, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                source_digest.update(chunk)
        manifest = {
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
            "view": "front",
            "rejection_kind": "body-proportion",
            "source_file": os.path.basename(archived_source),
            "source_sha256": source_digest.hexdigest(),
            "refined_file": refined_name,
            "installed": False,
            "proportion_quality": report,
            "alignment": alignment if isinstance(alignment, dict) else None,
            "alpha_quality": (
                alpha_quality if isinstance(alpha_quality, dict) else None),
        }
        report_path = os.path.join(stage, "report.json")
        with open(report_path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(report_path, 0o600)
        os.chmod(stage, 0o700)
        os.replace(stage, destination)
        stage = ""

        attempts = sorted(
            entry for entry in os.listdir(rejected_root)
            if not entry.startswith(".")
            and os.path.isdir(os.path.join(rejected_root, entry)))
        for stale in attempts[:-12]:
            shutil.rmtree(os.path.join(rejected_root, stale), ignore_errors=True)
        return destination
    finally:
        if stage:
            shutil.rmtree(stage, ignore_errors=True)


def _render_body_cutout(source, destination, view, *, allow_stylized, log=print):
    """Translate an ambiguous cartoon plate into a targeted view rejection.

    This diagnostic never erases authored white details. Only classified
    cartoon body plates opt in; photographic sources use the exact original
    Vision call and pixel path, and portrait/identity extraction is unchanged.
    """
    kwargs = {"log": log, "tight": True, "allow_stylized": allow_stylized}
    if allow_stylized:
        kwargs["reject_enclosed_plate"] = True
    try:
        return cutout.render(source, destination, **kwargs)
    except cutout.AmbiguousStylizedPlateError as error:
        raise GeneratedBodyAlphaError(
            f"generated {view} body failed alpha QA: {error}") from error


def _preflight_front_source(avatar_dir, source, options, log=print):
    """Reject an unsafe/head-heavy front before paying for side and back.

    The authoritative install repeats these checks after all three views exist.
    This early pass is a provider-cost guard: side and back inherit the front's
    scale, so generating them after a failed front can never rescue the set.
    """
    keyframe = cv2.imread(os.path.join(avatar_dir, "keyframe.png"))
    source_bgr = cv2.imread(source, cv2.IMREAD_COLOR)
    if keyframe is None:
        raise RuntimeError("avatar keyframe is missing")
    if source_bgr is None:
        raise RuntimeError("generated front body source could not be decoded")
    stage = tempfile.mkdtemp(prefix=".body-front-preflight-", dir=avatar_dir)
    try:
        allow_stylized = _allow_stylized_source(avatar_dir)
        cutout_path = os.path.join(stage, "front.png")
        if not _render_body_cutout(
                source, cutout_path, "front", log=log,
                allow_stylized=allow_stylized):
            raise RuntimeError("local person cutout failed for the front view")
        body_rgba = cv2.imread(cutout_path, cv2.IMREAD_UNCHANGED)
        if (body_rgba is None or body_rgba.ndim != 3
                or body_rgba.shape[2] != 4):
            raise RuntimeError(
                "generated front body did not produce an RGBA plate")
        # Only an explicitly stylized front receives the runtime's
        # replacement-head exemption.  Compute it from the exact canonical
        # transform before alpha QA; photographic and unknown media retain the
        # original gate and call order below.
        identity = None
        replacement_head = None
        if allow_stylized:
            identity = _face_transform(
                keyframe, body_rgba, allow_stylized=True)
            replacement_head = _canonical_head_replacement_core(
                body_rgba.shape, identity[0], identity[2])
        body_rgba, alpha_quality = body_alpha.refine(
            source_bgr, body_rgba,
            replacement_head_mask=replacement_head,
            verified_stylized=allow_stylized)
        if not alpha_quality["valid"]:
            try:
                archived = _archive_rejected_body_alpha(
                    avatar_dir, source, body_rgba, alpha_quality, "front")
                log(f"  archived rejected front alpha diagnostic at {archived}")
            except Exception as diagnostic_error:
                # Diagnostic retention must never replace the real QA failure.
                log(
                    "  could not archive rejected front alpha diagnostic: "
                    f"{diagnostic_error}")
            raise GeneratedBodyAlphaError(
                "generated front body failed alpha QA: "
                f"{alpha_quality['reason']}")
        if identity is None:
            identity = _face_transform(
                keyframe, body_rgba[:, :, :3],
                allow_stylized=allow_stylized)
        _transform, alignment, _landmarks = identity
        proportion_quality = body_proportion.assess(
            body_rgba, alignment.get("face_bounds"), options)
        proportion_failure = body_proportion.failure(proportion_quality)
        if proportion_failure:
            try:
                archived = _archive_rejected_body_proportion(
                    avatar_dir, source, proportion_quality,
                    alignment=alignment, refined_rgba=body_rgba,
                    alpha_quality=alpha_quality)
                log(
                    "  archived rejected front proportion diagnostic at "
                    f"{archived}")
            except Exception as diagnostic_error:
                # Diagnostic retention cannot replace or obscure the hard gate.
                log(
                    "  could not archive rejected front proportion "
                    f"diagnostic: {diagnostic_error}")
            raise GeneratedBodyProportionError(proportion_failure)
        if proportion_quality.get("measurable"):
            log(
                "  body proportion ready: "
                f"{proportion_quality['apparent_heads_tall']:.2f} "
                "apparent heads tall")
        return proportion_quality
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def _preflight_alpha_source(
        avatar_dir, source, view, options=None, log=print):
    """Reject an unsafe generated view before requesting the next plate.

    Front has a stronger identity/proportion preflight.  Side and back still
    need the same source-authoritative alpha gate before the coherent
    turnaround proceeds; the authoritative installer repeats the gate for all
    three views before it atomically replaces the installed body.
    """
    if view not in BODY_VIEWS:
        raise RuntimeError(f"unknown generated body view: {view}")
    source_bgr = cv2.imread(source, cv2.IMREAD_COLOR)
    if source_bgr is None:
        raise RuntimeError(f"generated {view} body source could not be decoded")
    stage = tempfile.mkdtemp(
        prefix=f".body-{view}-alpha-preflight-", dir=avatar_dir)
    try:
        allow_stylized = _allow_stylized_source(avatar_dir)
        cutout_path = os.path.join(stage, f"{view}.png")
        if not _render_body_cutout(
                source, cutout_path, view, log=log,
                allow_stylized=allow_stylized):
            raise RuntimeError(f"local person cutout failed for the {view} view")
        body_rgba = cv2.imread(cutout_path, cv2.IMREAD_UNCHANGED)
        if (body_rgba is None or body_rgba.ndim != 3
                or body_rgba.shape[2] != 4):
            raise RuntimeError(
                f"generated {view} body did not produce an RGBA plate")
        refined, alpha_quality = body_alpha.refine(
            source_bgr, body_rgba,
            verified_stylized=allow_stylized,
            stylized_turnaround_view=(view if allow_stylized else None))
        if not alpha_quality["valid"]:
            try:
                archived = _archive_rejected_body_alpha(
                    avatar_dir, source, refined, alpha_quality, view)
                log(
                    f"  archived rejected {view} alpha diagnostic at "
                    f"{archived}")
            except Exception as diagnostic_error:
                # A full disk or diagnostic encoding problem cannot turn an
                # unsafe source into a pass or obscure the hard-gate reason.
                log(
                    f"  could not archive rejected {view} alpha diagnostic: "
                    f"{diagnostic_error}")
            raise GeneratedBodyAlphaError(
                f"generated {view} body failed alpha QA: "
                f"{alpha_quality['reason']}")
        return alpha_quality
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def _identity_cutout(
        keyframe_path, keyframe, destination, allow_stylized, log=print,
        landmarks=None):
    """Build the temporary identity colour source used by ``_head_mask``.

    Vision person segmentation is meaningful for a photographic portrait, but
    on an oversized cartoon head it can return a tiny arbitrary body fragment.
    Explicitly stylized rigs first use the local border-connected plate
    extractor.  That preserves the canonical hat, hair, ears, jaw, and neck as
    one silhouette; keeping only the facial oval left the generated body's ears
    and chin underneath and produced doubled anatomy at close-up scale.

    A failed or implausible stylized matte still falls back to opaque BGRA.  The
    caller's stylized mask author then detects that fallback and reverts to the
    conservative facial-oval mask, so a segmentation failure can never turn the
    whole portrait square into a replacement layer.
    """
    if allow_stylized:
        rendered_ok = cutout.render(
            keyframe_path, destination, log=log, tight=True,
            allow_stylized=True)
        rendered = cv2.imread(destination, cv2.IMREAD_UNCHANGED) \
            if rendered_ok else None
        if _stylized_identity_cutout_is_safe(rendered, landmarks):
            return rendered
        opaque = np.dstack((
            keyframe,
            np.full(keyframe.shape[:2], 255, np.uint8),
        ))
        if not cv2.imwrite(destination, opaque):
            raise RuntimeError("could not write the stylized identity overlay")
        return opaque
    if not cutout.render(keyframe_path, destination, log=log):
        raise RuntimeError("could not build the identity overlay mask")
    rendered = cv2.imread(destination, cv2.IMREAD_UNCHANGED)
    if rendered is None or rendered.ndim != 3 or rendered.shape[2] != 4:
        raise RuntimeError("identity overlay mask is not RGBA")
    return rendered


def _stylized_identity_cutout_is_safe(image, landmarks=None):
    """Reject arbitrary/tiny cartoon mattes before they become head geometry."""
    if (image is None or image.ndim != 3 or image.shape[2] != 4
            or min(image.shape[:2]) < 16):
        return False
    alpha = image[:, :, 3]
    foreground = alpha > 8
    coverage = float(np.mean(foreground))
    points = cv2.findNonZero(foreground.astype(np.uint8))
    if points is None or not (0.02 <= coverage <= 0.90):
        return False
    _x, _y, width, height = cv2.boundingRect(points)
    if (width < image.shape[1] * 0.18
            or height < image.shape[0] * 0.18):
        return False
    if landmarks is None:
        return True
    oval = np.asarray(landmarks, dtype=np.float32)[face.FACE_OVAL]
    valid = (
        (oval[:, 0] >= 0) & (oval[:, 0] < image.shape[1])
        & (oval[:, 1] >= 0) & (oval[:, 1] < image.shape[0])
    )
    if int(np.sum(valid)) < max(8, len(face.FACE_OVAL) // 2):
        return False
    samples = np.round(oval[valid]).astype(np.int32)
    samples[:, 0] = np.clip(samples[:, 0], 0, image.shape[1] - 1)
    samples[:, 1] = np.clip(samples[:, 1], 0, image.shape[0] - 1)
    if float(np.mean(alpha[samples[:, 1], samples[:, 0]] > 8)) < 0.82:
        return False
    hull_gate = np.zeros(alpha.shape, dtype=np.uint8)
    cv2.fillConvexPoly(
        hull_gate, cv2.convexHull(np.round(oval).astype(np.int32)), 1)
    hull_area = int(np.sum(hull_gate))
    if hull_area <= 0:
        return False
    return float(np.sum(foreground & (hull_gate > 0))) / hull_area >= 0.82


def _head_mask(cutout_image, landmarks, destination):
    alpha = cutout_image[:, :, 3].astype(np.float32) / 255.0
    oval = landmarks[face.FACE_OVAL]
    chin = float(np.max(oval[:, 1]))
    top = float(np.min(oval[:, 1]))
    left, right = float(np.min(oval[:, 0])), float(np.max(oval[:, 0]))
    center = (left + right) * 0.5
    face_width = max(1.0, right - left)
    face_height = max(1.0, chin - top)
    # The animation bank needs the original eyes, brows, cheeks, and mouth—not
    # the entire square portrait.  Keeping every pixel above the chin made a
    # voluminous close-up hairstyle replace the generated plate's much narrower
    # head silhouette, even though the facial landmarks themselves aligned.
    # Build a softly expanded facial oval so the generated plate continues to
    # own skull/hair size while the calibrated identity remains fully animated.
    face_gate = np.zeros(alpha.shape, dtype=np.uint8)
    hull = cv2.convexHull(np.round(oval).astype(np.int32))
    cv2.fillConvexPoly(face_gate, hull, 255)
    expansion = max(9, int(round(face_width * 0.11)))
    if expansion % 2 == 0:
        expansion += 1
    face_gate = cv2.dilate(
        face_gate,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (expansion, expansion)),
    )
    face_gate = cv2.GaussianBlur(
        face_gate, (0, 0), max(2.0, face_width * 0.035)
    ).astype(np.float32) / 255.0
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
    mask = np.clip(
        alpha * face_gate * fade[:, None] * neck_gate, 0.0, 1.0)
    rgba = np.full((*mask.shape, 4), 255, dtype=np.uint8)
    rgba[:, :, 3] = np.round(mask * 255).astype(np.uint8)
    cv2.imwrite(destination, rgba)


def _stylized_jaw_handoff(shape, projected_oval, feather_px=None):
    """Return one curved, one-sided head-to-body handoff field.

    ``FACE_OVAL`` is an ordered closed contour.  Its lower convex chain is the
    jaw seen in the coordinate space supplied by the caller (portrait space
    while authoring the overlay, body space while authoring the clear mask).
    The returned support is solid on the head side of that chain, then falls to
    zero over a Euclidean signed-distance feather on the neck side.  Both
    stylized assets use this helper so a second, row-based chin cutoff cannot
    create a collar-shaped edge.
    """
    height, width = [int(value) for value in shape[:2]]
    oval = np.asarray(projected_oval, dtype=np.float32).reshape(-1, 2)
    if (height <= 0 or width <= 0 or len(oval) < 3
            or not np.all(np.isfinite(oval))):
        raise RuntimeError("the stylized jaw handoff geometry is invalid")

    hull = cv2.convexHull(oval).reshape(-1, 2)
    if len(hull) < 3:
        raise RuntimeError("the stylized jaw handoff geometry is degenerate")
    left_index = int(np.argmin(hull[:, 0]))
    right_index = int(np.argmax(hull[:, 0]))

    def hull_path(step):
        points = [hull[left_index]]
        index = left_index
        while index != right_index:
            index = (index + step) % len(hull)
            points.append(hull[index])
            if len(points) > len(hull) + 1:
                raise RuntimeError("the stylized jaw contour is invalid")
        points = np.asarray(points, dtype=np.float32)
        if points[0, 0] > points[-1, 0]:
            points = points[::-1]
        order = np.argsort(points[:, 0], kind="stable")
        points = points[order]
        unique_x = []
        lower_y = []
        for x_value in np.unique(points[:, 0]):
            ys = points[points[:, 0] == x_value, 1]
            unique_x.append(float(x_value))
            lower_y.append(float(np.max(ys)))
        return np.asarray(unique_x), np.asarray(lower_y)

    paths = [hull_path(1), hull_path(-1)]
    left = float(np.min(oval[:, 0]))
    right = float(np.max(oval[:, 0]))
    if right - left < 2.0:
        raise RuntimeError("the stylized jaw handoff is too narrow")
    sample_x = np.linspace(left, right, 129, dtype=np.float32)
    scores = [
        float(np.mean(np.interp(sample_x, path_x, path_y)))
        for path_x, path_y in paths
    ]
    jaw_x, jaw_y = paths[int(np.argmax(scores))]

    xs = np.arange(width, dtype=np.float32)
    boundary = np.interp(xs, jaw_x, jaw_y).astype(np.float32)
    # Continue the jaw beyond its hinges without letting that continuation
    # descend indefinitely across a full-body plate.  A one-way diagonal is
    # acceptable in a tightly cropped portrait, but in body space it eventually
    # classifies shoulders (and then torso) as part of the head.  Make a shallow
    # outward turn just past each ear, then rise toward the oval's crown row
    # within an anatomy-relative lateral extent.  Never use an image edge for
    # that extent: the head overlay is authored in portrait space, whereas its
    # eraser is authored on the wider full-body canvas.  Edge-relative fields
    # disagree after projection and cut a transparent notch through loose hair
    # (Celine's viewer-left forelock).  A face-width extent gives both callers
    # the same geometry and still keeps distant shoulders outside the head.
    jaw_rise = max(
        1.0,
        float(np.max(jaw_y) - 0.5 * (jaw_y[0] + jaw_y[-1])),
    )
    face_width = max(1.0, right - left)
    outer_drop = float(min(jaw_rise * 0.25, face_width * 0.12))
    turn_distance = float(max(1.0, face_width * 0.18))
    return_distance = float(max(turn_distance + 1.0, face_width * 0.72))
    crown_row = float(np.min(oval[:, 1]))

    def shoulder_safe_continuation(distance, hinge_y):
        distance = np.asarray(distance, dtype=np.float32)
        near = hinge_y + outer_drop * distance / turn_distance
        far_progress = np.clip(
            (distance - turn_distance) / (return_distance - turn_distance),
            0.0, 1.0)
        far = (hinge_y + outer_drop) + (
            crown_row - (hinge_y + outer_drop)) * far_progress
        return np.where(distance <= turn_distance, near, far)

    left_columns = xs < jaw_x[0]
    right_columns = xs > jaw_x[-1]
    left_distance = jaw_x[0] - xs[left_columns]
    right_distance = xs[right_columns] - jaw_x[-1]
    boundary[left_columns] = shoulder_safe_continuation(
        left_distance, jaw_y[0])
    boundary[right_columns] = shoulder_safe_continuation(
        right_distance, jaw_y[-1])

    head_side = (
        np.arange(height, dtype=np.float32)[:, None]
        <= boundary[None, :]
    )
    inside = cv2.distanceTransform(
        head_side.astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    outside = cv2.distanceTransform(
        (~head_side).astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    signed_distance = inside - outside
    if feather_px is None:
        feather_px = float(np.clip((right - left) * 0.12, 10.0, 16.0))
    feather_px = float(np.clip(feather_px, 1.0, max(height, width)))
    progress = np.clip(
        (signed_distance + feather_px) / feather_px, 0.0, 1.0)
    support = progress * progress * (3.0 - 2.0 * progress)
    return support.astype(np.float32), head_side, {
        "feather_px": feather_px,
        "boundary_min_y": float(np.min(boundary)),
        "boundary_max_y": float(np.max(boundary)),
    }


def _stylized_handoff_feather(projected_face_width, source_medium=None):
    """Choose the authored jaw feather without conflating cartoon media.

    A flat illustration benefits from the established, wider overlap: it keeps
    a black ink jaw continuous over the generated neck even when the two
    silhouettes differ by a few pixels.  A soft-3-D portrait is different.  Its
    source matte commonly contains a rendered neck below the anatomical jaw;
    carrying the same wide overlap onto the body produces a second shaded chin
    contour.  Keep that central overlap short while retaining the complete
    lateral hair/hat silhouette above the same curved jaw boundary.

    The value is expressed in *projected body pixels*.  Callers authoring a
    portrait-space mask convert it back through the face affine so both masks
    describe the same visible-width handoff.
    """
    width = max(1.0, float(projected_face_width))
    medium = _normalise_source_medium(source_medium)
    if medium == "3d render":
        return float(np.clip(width * 0.06, 6.0, 12.0)), "soft-3d-jaw-v1"
    return float(np.clip(width * 0.12, 10.0, 16.0)), "illustration-jaw-v2"


def _stylized_head_mask(
        cutout_image, landmarks, destination, transform=None,
        source_medium=None):
    """Author a complete, identity-owned cartoon head silhouette.

    Above the jaw, the validated local matte owns the whole canonical head:
    hat/hair, ears, cheeks, and chin.  A curved jaw-distance feather hands the
    neck to the body without carrying a bust or source clothing onto the
    approved full-body wardrobe.  An opaque-square fallback is routed through
    the legacy oval author instead of ever becoming a square runtime layer.
    """
    if not _stylized_identity_cutout_is_safe(cutout_image, landmarks):
        _head_mask(cutout_image, landmarks, destination)
        return "face-oval-fallback"
    alpha = cutout_image[:, :, 3].astype(np.float32) / 255.0
    oval = np.asarray(landmarks, dtype=np.float32)[face.FACE_OVAL]
    face_width = max(1.0, float(np.ptp(oval[:, 0])))
    feather_px, _handoff_profile = _stylized_handoff_feather(
        face_width, source_medium)
    if transform is not None:
        affine = np.asarray(transform, dtype=np.float64)
        projected = cv2.transform(
            oval[None, :, :], affine.astype(np.float32))[0]
        projected_width = max(1.0, float(np.ptp(projected[:, 0])))
        projected_feather, _handoff_profile = _stylized_handoff_feather(
            projected_width, source_medium)
        scale = float(np.sqrt(abs(np.linalg.det(affine[:, :2]))))
        feather_px = projected_feather / max(scale, 1e-6)
    support, _head_side, _handoff = _stylized_jaw_handoff(
        alpha.shape, oval, feather_px=feather_px)
    mask = np.clip(alpha * support, 0.0, 1.0)
    rgba = np.full((*mask.shape, 4), 255, dtype=np.uint8)
    rgba[:, :, 3] = np.round(mask * 255).astype(np.uint8)
    if not cv2.imwrite(destination, rgba):
        raise RuntimeError("the stylized identity overlay mask could not be written")
    return "full-silhouette"


def _neck_row_edge(image, row, left, right):
    """Measure a strong RGB contour with a bounded subpixel peak fit."""
    pixels = image[row, :, :3].astype(np.float32)
    pixels = cv2.GaussianBlur(pixels[None, :, :], (5, 1), .8)[0]
    gradient = pixels[1:] - pixels[:-1]
    strength = np.linalg.norm(gradient, axis=1) / np.sqrt(3.0)
    index = left + int(np.argmax(strength[left:right]))
    position = float(index)
    if 0 < index < len(strength) - 1:
        a, b, c = strength[index - 1:index + 2]
        denominator = a - 2.0 * b + c
        if denominator < -1e-4:
            position += float(np.clip(
                .5 * (a - c) / denominator, -.5, .5))
    return position, float(strength[index]), gradient[index]


def _register_soft_3d_neck_seam(
        body_image, keyframe, head_mask, transform, key_landmarks,
        *, source_medium=None):
    """Register a proven *interior* donor-neck edge to the identity head.

    A soft-3D portrait and its generated body can have slightly different neck
    contours. Fading one edge out while the other fades in makes a visible
    lateral step, even with an upright head and a single chin. Do not move the
    approved face, extend its shaded chin, or blur both contours together.
    Instead, align only the small donor RGB neighbourhood where corresponding
    neck/hair edges are visible inside the authored jaw handoff.

    This is deliberately not a skin-colour or silhouette heuristic. At least
    three consecutive, strong, same-direction RGB edge matches must agree on
    a bounded offset. Only wholly opaque interior pixels may be resampled;
    the alpha silhouette, source portrait and masks stay byte-identical. The
    correction fades back to the original donor below the short jaw seam.
    Ambiguous, large or exterior mismatches are left unchanged, not erased.
    Both the photographic and ink-illustration paths are exact no-ops.
    """
    receipt = {
        "version": SOFT_3D_NECK_REGISTRATION_VERSION,
        "source_medium": _normalise_source_medium(source_medium),
        "applied": False,
        "changed_rgb_pixels": 0,
        "alpha_unchanged": True,
        "edges": [],
    }
    if receipt["source_medium"] != "3d render":
        receipt["reason"] = "not-soft-3d"
        return body_image, receipt
    affine = np.asarray(transform, dtype=np.float64)
    if (body_image is None or body_image.ndim != 3
            or body_image.shape[2] != 4 or body_image.dtype != np.uint8
            or keyframe is None or keyframe.ndim != 3
            or keyframe.shape[2] < 3 or head_mask is None
            or head_mask.ndim != 2
            or head_mask.shape != keyframe.shape[:2]
            or affine.shape != (2, 3) or not np.all(np.isfinite(affine))):
        raise RuntimeError("soft-3D neck registration inputs are invalid")
    oval = np.asarray(key_landmarks, dtype=np.float32)[face.FACE_OVAL]
    if not np.all(np.isfinite(oval)):
        raise RuntimeError("soft-3D neck registration landmarks are invalid")
    projected = cv2.transform(oval[None], affine.astype(np.float32))[0]
    face_width = float(np.ptp(projected[:, 0]))
    height, width = body_image.shape[:2]
    if face_width < 32 or min(height, width) < 16:
        receipt["reason"] = "insufficient-neck-resolution"
        return body_image, receipt
    centre = float((np.min(projected[:, 0]) + np.max(projected[:, 0])) / 2)
    chin = float(np.max(projected[:, 1]))
    start = max(1, int(np.floor(chin - face_width * .18)))
    stop = min(height - 1, int(np.ceil(chin + face_width * .09)))
    if start >= stop:
        receipt["reason"] = "neck-outside-canvas"
        return body_image, receipt
    canonical = cv2.warpAffine(
        keyframe[:, :, :3], affine, (width, height), flags=cv2.INTER_AREA)
    coverage = cv2.warpAffine(
        head_mask, affine, (width, height), flags=cv2.INTER_LINEAR
    ).astype(np.float32) / 255.0
    displacement = np.zeros((height, width), np.float32)
    rows = np.arange(height, dtype=np.float32)
    columns = np.arange(width, dtype=np.float32)

    def smoothstep(value):
        value = np.clip(value, 0.0, 1.0)
        return value * value * (3.0 - 2.0 * value)

    for side, minimum, maximum in (
            ("viewer-left", -.40, -.12), ("viewer-right", .12, .40)):
        left = max(2, int(centre + face_width * minimum))
        right = min(width - 2, int(centre + face_width * maximum))
        if right <= left:
            continue
        samples = []
        for row in range(start, stop):
            source_x, source_strength, source_gradient = _neck_row_edge(
                canonical, row, left, right)
            donor_x, donor_strength, donor_gradient = _neck_row_edge(
                body_image, row, left, right)
            amount = float(np.interp(source_x, columns, coverage[row]))
            agreement = float(np.dot(source_gradient, donor_gradient) / max(
                1e-5, np.linalg.norm(source_gradient)
                * np.linalg.norm(donor_gradient)))
            offset = source_x - donor_x
            if (.1 <= amount <= .9
                    and min(source_strength, donor_strength) >= 12.0
                    and agreement >= .92
                    and abs(offset) <= min(8.0, face_width * .06)):
                samples.append((row, source_x, donor_x, offset))
        edge_receipt = {
            "side": side, "matching_rows": len(samples), "applied": False,
        }
        receipt["edges"].append(edge_receipt)
        if (len(samples) < 3 or any(
                after[0] - before[0] != 1
                for before, after in zip(samples, samples[1:]))):
            edge_receipt["reason"] = "insufficient-consecutive-correspondence"
            continue
        offsets = np.asarray([sample[3] for sample in samples])
        offset = float(np.median(offsets))
        spread = float(np.max(np.abs(offsets - offset)))
        if abs(offset) < .8:
            edge_receipt["reason"] = "already-aligned"
            continue
        if spread > 1.75:
            edge_receipt["reason"] = "ambiguous-offset"
            continue
        first_row, last_row = samples[0][0], samples[-1][0]
        # Keep this local to the jaw-to-neck junction, not the collar or chest.
        # Below the overlap, smoothly restore the authored body in a few rows.
        final_row = max(last_row + 5.0, chin + face_width * .02)
        vertical = smoothstep((rows - (first_row - 4)) / 4) * (
            1.0 - smoothstep(
                (rows - (last_row + 1)) / (final_row - (last_row + 1))))
        donor_x = float(np.median([sample[2] for sample in samples]))
        contour = donor_x + offset * vertical
        plateau = max(3.0, face_width * .035)
        feather = max(5.0, face_width * .10)
        horizontal = 1.0 - smoothstep(
            (np.abs(columns[None] - contour[:, None]) - plateau) / feather)
        flow = offset * vertical[:, None] * horizontal
        affected = np.abs(flow) > .001
        # Include interpolation's source support, not just destination pixels.
        padding = int(np.ceil(abs(offset))) + 1
        support = cv2.dilate(
            affected.astype(np.uint8),
            np.ones((1, 2 * padding + 1), np.uint8)).astype(bool)
        if np.any(body_image[:, :, 3][support] < 250):
            edge_receipt["reason"] = "not-opaque-interior"
            continue
        displacement += flow
        edge_receipt.update({
            "applied": True,
            "offset_x": round(offset, 6),
            "max_offset_spread": round(spread, 6),
            "donor_edge_x": round(donor_x, 6),
            "matching_row_bounds": [first_row, last_row],
            "correction_row_bounds": [first_row - 4, round(final_row, 6)],
        })
    affected = np.abs(displacement) > .001
    if not np.any(affected):
        receipt["reason"] = "no-proven-interior-seam-offset"
        return body_image, receipt
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    corrected = cv2.remap(
        body_image[:, :, :3], xx - displacement, yy, cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE)
    result = body_image.copy()
    result[:, :, :3][affected] = corrected[affected]
    changed = np.any(result[:, :, :3] != body_image[:, :, :3], axis=2)
    changed_y, changed_x = np.nonzero(changed)
    receipt["applied"] = bool(len(changed_y))
    receipt["changed_rgb_pixels"] = int(len(changed_y))
    if len(changed_y):
        receipt["changed_rgb_bounds"] = [
            int(changed_x.min()), int(changed_y.min()),
            int(changed_x.max() - changed_x.min() + 1),
            int(changed_y.max() - changed_y.min() + 1),
        ]
    return result, receipt


def _repair_soft_3d_jaw_band(
        body_image, head_mask, head_clear_mask, transform, face_bounds,
        *, source_medium=None, neck_handoff=None):
    """Repair a proven donor-jaw remnant in an existing v5 neck handoff.

    This is an explicit maintenance operation, not a general skin retouch or
    a new face/body registration. Some older anatomical-jaw recomposites
    retained two or three rows of the donor's pale chin *inside* the identity
    head's feather. The authored alpha pair is correct, but its partially
    visible RGB leaves a second, stair-stepped jaw contour at large zoom.

    Only the known v5 repair provenance is eligible. A continuous lower-jaw
    arc must have a rapid, monotonic head feather, a same-direction bright
    RGB step within that feather, and a smooth opaque donor-neck continuation
    immediately below it. Extrapolate that local shading solely into the
    detected remnant. Never change alpha, the head, either mask, the affine,
    the actual donor neck below the step, or earlier lateral registration.
    Ambiguous sources are left unchanged with an explicit diagnostic reason.
    Photographic and 2D paths, and ordinary new exports, are exact no-ops.
    """
    receipt = {
        "version": SOFT_3D_JAW_BAND_REPAIR_VERSION,
        "source_medium": _normalise_source_medium(source_medium),
        "method": "proven-v5-donor-jaw-band-rgb-only",
        "applied": False,
        "changed_rgb_pixels": 0,
        "alpha_unchanged": True,
        "head_masks_and_transform_unchanged": True,
    }
    if receipt["source_medium"] != "3d render":
        receipt["reason"] = "not-soft-3d"
        return body_image, receipt
    handoff = neck_handoff if isinstance(neck_handoff, dict) else {}
    if (handoff.get("v") != 5
            or handoff.get("method") != "anatomical-jaw-plus-local-neck-recomposite"
            or handoff.get("body_owns_neck") is not True
            or handoff.get("provider_face_contour_removed") is not True):
        receipt["reason"] = "not-known-v5-neck-recomposite"
        return body_image, receipt
    try:
        affine = np.asarray(transform, dtype=np.float64)
        bounds = np.asarray(face_bounds, dtype=np.float64)
        feather = float(handoff.get("body_feather_px", 0))
    except (ValueError, TypeError):
        raise RuntimeError("soft-3D jaw-band repair metadata is invalid") from None
    if (body_image is None or body_image.ndim != 3
            or body_image.shape[2] != 4 or body_image.dtype != np.uint8
            or head_mask is None or head_mask.ndim != 2
            or head_mask.dtype != np.uint8
            or head_clear_mask is None or head_clear_mask.ndim != 2
            or head_clear_mask.dtype != np.uint8
            or head_clear_mask.shape != body_image.shape[:2]
            or affine.shape != (2, 3) or not np.all(np.isfinite(affine))
            or bounds.shape != (4,) or not np.all(np.isfinite(bounds))
            or not np.isfinite(feather) or not 3 <= feather <= 12):
        raise RuntimeError("soft-3D jaw-band repair inputs are invalid")
    # The known repair's upright, positive-scale mapping is essential to the
    # vertical continuation test. Do not reinterpret tilted or mirrored data.
    if (min(affine[0, 0], affine[1, 1]) <= 0
            or max(abs(affine[0, 1]), abs(affine[1, 0])) > 1e-5):
        receipt["reason"] = "not-upright-neck-handoff"
        return body_image, receipt
    height, width = body_image.shape[:2]
    face_x, face_y, face_width, face_height = bounds
    if min(face_width, face_height) < 48:
        receipt["reason"] = "insufficient-jaw-resolution"
        return body_image, receipt
    left = max(1, int(np.ceil(face_x + face_width * .1)))
    right = min(width - 1, int(np.floor(face_x + face_width * .9)))
    top = max(1, int(np.floor(face_y + face_height * .5)))
    bottom = min(height - 6, int(np.ceil(face_y + face_height + feather)))
    if left >= right or top >= bottom:
        receipt["reason"] = "jaw-outside-canvas"
        return body_image, receipt
    coverage = cv2.warpAffine(
        head_mask, affine, (width, height), flags=cv2.INTER_LINEAR
    ).astype(np.float32) / 255.0
    max_tail = int(np.ceil(feather)) + 2
    samples = []
    fit_t = np.arange(1, 5, dtype=np.float64)
    for column in range(left, right + 1):
        cleared = np.flatnonzero(head_clear_mask[top:bottom, column] >= 250)
        if not len(cleared):
            continue
        anchor = top + int(cleared[-1])
        if anchor + max_tail + 5 >= height or coverage[anchor, column] < .96:
            continue
        transition = coverage[anchor:anchor + max_tail + 1, column]
        zeros = np.flatnonzero(transition <= .02)
        if (not len(zeros) or not 3 <= zeros[0] <= max_tail
                or np.any(np.diff(transition[:int(zeros[0]) + 1]) > .015)):
            continue
        end = anchor + int(zeros[0])
        if np.any(head_clear_mask[anchor + 1:end + 1, column] > 4):
            continue
        rgb = body_image[anchor + 1:end + 1, column, :3].astype(np.float64)
        drops = rgb[:-1] - rgb[1:]
        if not len(drops):
            continue
        index = int(np.argmax(drops.mean(axis=1)))
        edge = anchor + 1 + index
        delta = drops[index]
        if (not .25 <= coverage[edge, column] <= .85
                or np.min(delta) < 4 or np.mean(delta) < 12
                or np.max(delta) > 150 or not 1 <= edge - anchor <= max_tail - 2):
            continue
        support = body_image[anchor:edge + 5, column, 3]
        if np.any(support < 250):
            continue
        neck = body_image[edge + 1:edge + 5, column, :3].astype(np.float64)
        slope, intercept = np.polyfit(fit_t, neck, 1)
        error = float(np.max(np.abs(fit_t[:, None] * slope + intercept - neck)))
        # A shadow or hair boundary in the support cannot be used as a smooth
        # neck continuation. Keep this extrapolation shorter than its support.
        if error > 2.5 or np.max(np.abs(slope)) > 8:
            continue
        rows = np.arange(anchor, edge + 1)
        prediction = (rows - edge)[:, None] * slope + intercept
        original = body_image[rows, column, :3].astype(np.float64)
        if (np.min(prediction) < 0 or np.max(prediction) > 255
                or np.mean(original[-1] - prediction[-1]) < 12
                or np.any(original[-1] - prediction[-1] < 2)):
            continue
        samples.append({
            "x": column, "anchor": anchor, "edge": edge,
            "step_mean": float(np.mean(delta)), "fit_error": error,
            "replacement": np.rint(prediction).astype(np.uint8),
        })
    # Isolated highlights or disconnected mouth/hair edges are not a residual
    # jaw. Require one coherent arc spanning the central chin with both sides.
    runs = []
    for sample in samples:
        if (not runs or sample["x"] != runs[-1][-1]["x"] + 1
                or abs(sample["edge"] - runs[-1][-1]["edge"]) > 2):
            runs.append([])
        runs[-1].append(sample)
    centre = face_x + face_width * .5
    eligible = [run for run in runs if (
        len(run) >= max(16, int(np.ceil(face_width * .25)))
        and run[0]["x"] <= centre - face_width * .1
        and run[-1]["x"] >= centre + face_width * .1)]
    receipt["candidate_columns"] = len(samples)
    if len(eligible) != 1:
        receipt["reason"] = "no-single-proven-residual-jaw-arc"
        return body_image, receipt
    arc = eligible[0]
    edge_rows = np.asarray([sample["edge"] for sample in arc])
    middle = edge_rows[len(arc) // 3:len(arc) * 2 // 3]
    if (np.max(middle) - min(edge_rows[0], edge_rows[-1]) < face_width * .04
            or np.max(middle) < np.max(edge_rows) - 2):
        receipt["reason"] = "residual-not-lower-jaw-shaped"
        return body_image, receipt
    result = body_image.copy()
    for sample in arc:
        result[sample["anchor"]:sample["edge"] + 1, sample["x"], :3] = (
            sample["replacement"])
    changed_y, changed_x = np.nonzero(
        np.any(result[:, :, :3] != body_image[:, :, :3], axis=2))
    receipt.update({
        "applied": bool(len(changed_y)),
        "reason": "proven-donor-jaw-band-replaced",
        "changed_rgb_pixels": int(len(changed_y)),
        "changed_rgb_bounds": [
            int(changed_x.min()), int(changed_y.min()),
            int(changed_x.max() - changed_x.min() + 1),
            int(changed_y.max() - changed_y.min() + 1)],
        "arc_columns": len(arc),
        "maximum_neck_fit_error": round(max(s["fit_error"] for s in arc), 6),
        "minimum_observed_step": round(min(s["step_mean"] for s in arc), 6),
        "body_neck_below_step_unchanged": True,
        "bands": [[s["x"], s["anchor"], s["edge"]] for s in arc],
        "visual_review_required": True,
    })
    return result, receipt


def _stylized_head_clear_mask(
        body_image, mask_path, transform, key_landmarks, face_bounds,
        destination, source_medium=None):
    """Build the body-space eraser for doubled cartoon face anatomy.

    The canonical silhouette itself is always cleared.  On the head side we
    additionally clear a conservative dilation of the aligned oval, just far
    enough to remove generated ears, cheek outlines, and the second chin that
    can sit outside the canonical matte.  Both regions stop on the shared
    curved jaw boundary, leaving the generated neck intact beneath its feather.
    """
    if (body_image is None or body_image.ndim != 3
            or body_image.shape[2] != 4 or not face_bounds):
        raise RuntimeError("the stylized body clear mask inputs are invalid")
    portrait_mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)
    if (portrait_mask is None or portrait_mask.ndim != 3
            or portrait_mask.shape[2] != 4):
        raise RuntimeError("the stylized identity overlay mask is invalid")
    height, width = body_image.shape[:2]
    warped = cv2.warpAffine(
        portrait_mask[:, :, 3], np.asarray(transform, dtype=np.float64),
        (width, height), flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    projected = cv2.transform(
        np.asarray(key_landmarks, dtype=np.float32)[face.FACE_OVAL][None, :, :],
        np.asarray(transform, dtype=np.float32))[0]
    face_width = float(face_bounds[2])
    handoff_feather, handoff_profile = _stylized_handoff_feather(
        max(1.0, float(np.ptp(projected[:, 0]))), source_medium)
    handoff, head_side, handoff_quality = _stylized_jaw_handoff(
        (height, width), projected, feather_px=handoff_feather)
    canonical = (warped > 4) & head_side
    anatomy = np.zeros((height, width), dtype=np.uint8)
    cv2.fillConvexPoly(
        anatomy, cv2.convexHull(np.round(projected).astype(np.int32)), 255)
    radius = max(3, int(round(face_width * 0.18)))
    kernel_size = radius * 2 + 1
    anatomy = cv2.dilate(
        anatomy,
        cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (kernel_size, kernel_size)))
    # The generated donor can carry a larger or vertically shifted hat/hair
    # silhouette than the canonical animation head. Clearing only the exact
    # canonical support leaves that donor crown or brim visible behind it as a
    # second head. Full-silhouette replacement therefore clears donor alpha on
    # the solid head side of the shared jaw field. Photographic soft blending
    # never authors or consumes this clear mask.
    donor_silhouette = (
        head_side & (body_image[:, :, 3] > 8) & ~canonical)
    donor_anatomy = (
        (anatomy > 0) & head_side & (body_image[:, :, 3] > 8)
        & ~canonical)
    # Clear the body beneath fully opaque canonical art, and hard-clear donor
    # anatomy that protrudes outside that art on the head side.  The signed-
    # distance feather itself is deliberately excluded: there the overlay is
    # source-over and the generated body remains the opaque backing layer.
    source_gate = np.clip(
        (warped.astype(np.float32) - 252.0) / 3.0, 0.0, 1.0)
    source_gate = source_gate * source_gate * (3.0 - 2.0 * source_gate)
    protrusion = donor_silhouette | donor_anatomy
    clear_strength = np.maximum(
        protrusion.astype(np.float32), source_gate * head_side)
    clear_alpha = np.round(clear_strength * 255.0).astype(np.uint8)
    rgba = np.full((height, width, 4), 255, dtype=np.uint8)
    rgba[:, :, 3] = clear_alpha
    if not cv2.imwrite(destination, rgba):
        raise RuntimeError("the stylized body clear mask could not be written")
    transform_receipt = [
        [round(float(value), 7) for value in row]
        for row in np.asarray(transform, dtype=np.float64)
    ]
    feather = (handoff > 0.0) & ~head_side
    feather_points = cv2.findNonZero(feather.astype(np.uint8))
    if feather_points is None:
        handoff_row_range = []
    else:
        _x, handoff_y, _width, handoff_height = cv2.boundingRect(feather_points)
        handoff_row_range = [
            int(handoff_y), int(handoff_y + handoff_height - 1)]
    return {
        "canonical_pixels": int(np.sum(clear_alpha > 4)),
        "silhouette_pixels": int(np.sum(donor_silhouette)),
        "anatomy_pixels": int(np.sum(donor_anatomy)),
        "handoff_row_range": handoff_row_range,
        "handoff_pixels_preserved": int(np.sum(
            feather & (body_image[:, :, 3] > 8) & (clear_alpha < 5))),
        "handoff_feather_px": round(
            float(handoff_quality["feather_px"]), 3),
        "handoff_profile": handoff_profile,
        "source_medium": _normalise_source_medium(source_medium),
        "jaw_boundary_row_range": [
            int(np.floor(handoff_quality["boundary_min_y"])),
            int(np.ceil(handoff_quality["boundary_max_y"])),
        ],
        "face_transform": transform_receipt,
        "bounds": _alpha_bounds(rgba),
    }


def _constrain_head_mask(mask_path, body_image, transform, face_bounds):
    """Keep the live identity overlay inside the generated head silhouette.

    The landmark transform correctly sizes the *face*, but a close portrait can
    carry hair almost edge-to-edge across its square canvas.  Warping that full
    alpha matte onto a narrow full-body plate makes the hair (and therefore the
    perceived head) much wider than the generated figure.  Project the body
    silhouette back into portrait space and intersect it with the authored mask;
    a small feather preserves antialiased hair edges without allowing a new,
    larger silhouette to replace the approved plate.
    """
    if not face_bounds:
        return
    mask_rgba = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)
    if (mask_rgba is None or mask_rgba.ndim != 3
            or mask_rgba.shape[2] != 4 or body_image.ndim != 3
            or body_image.shape[2] != 4):
        raise RuntimeError("the identity overlay mask is invalid")
    body_alpha = body_image[:, :, 3]
    allowed_body = body_alpha
    inverse = cv2.invertAffineTransform(np.asarray(transform, dtype=np.float64))
    allowed_portrait = cv2.warpAffine(
        allowed_body,
        inverse,
        (mask_rgba.shape[1], mask_rgba.shape[0]),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    mask_rgba[:, :, 3] = np.minimum(mask_rgba[:, :, 3], allowed_portrait)
    if not cv2.imwrite(mask_path, mask_rgba):
        raise RuntimeError("the identity overlay mask could not be written")


def _composite_head_proportion_failure(
        body_image, mask_path, transform, face_bounds,
        verified_stylized=False):
    """Return a user-facing failure when the final live overlay is oversized."""
    if not face_bounds:
        return "generated face alignment is missing"
    person_bounds = _alpha_bounds(body_image)
    person_width = max(1.0, float(person_bounds[2]))
    person_height = max(1.0, float(person_bounds[3]))
    _face_x, _face_y, face_width, face_height = [float(v) for v in face_bounds]
    face_width_ratio = face_width / person_width
    face_height_ratio = face_height / person_height
    face_width_limit = 0.58 if verified_stylized else 0.43
    face_height_limit = 0.26 if verified_stylized else 0.15
    if (face_width_ratio > face_width_limit
            or face_height_ratio > face_height_limit):
        return (
            "generated head is too large for the body "
            f"(face ratios {face_width_ratio:.3f} wide, "
            f"{face_height_ratio:.3f} tall)")

    mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)
    if mask is None or mask.ndim != 3 or mask.shape[2] != 4:
        return "the identity overlay mask is invalid"
    warped = cv2.warpAffine(
        mask[:, :, 3], np.asarray(transform, dtype=np.float64),
        (body_image.shape[1], body_image.shape[0]), flags=cv2.INTER_LINEAR)
    points = cv2.findNonZero((warped > 8).astype(np.uint8))
    if points is None:
        return "the identity overlay mask is empty"
    _x, _y, overlay_width, overlay_height = cv2.boundingRect(points)
    width_ratio = overlay_width / person_width
    height_ratio = overlay_height / person_height
    overlay_width_limit = 1.15 if verified_stylized else 0.76
    overlay_height_limit = 0.40 if verified_stylized else 0.22
    if (width_ratio > overlay_width_limit
            or height_ratio > overlay_height_limit):
        return (
            "live head silhouette is too large for the body "
            f"({width_ratio:.3f} wide, {height_ratio:.3f} tall)")
    return None


def _runtime_composite_preview(body_path, keyframe, mask_path, transform,
                               destination, replace=False,
                               clear_mask_path=None):
    """Bake the same standing head/body stack shown by the desktop runtime.

    Photographic rigs retain the established soft source-over blend.  Explicit
    stylized rigs use a separately-authored body-space clear mask first, so the
    generated plate cannot show a second jaw, cheek, or pair of ears beneath
    the canonical cartoon head.
    """
    body_rgba = cv2.imread(body_path, cv2.IMREAD_UNCHANGED)
    mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)
    if (body_rgba is None or body_rgba.ndim != 3 or body_rgba.shape[2] != 4
            or mask is None or mask.ndim != 3 or mask.shape[2] != 4):
        raise RuntimeError("the standing composite assets are invalid")
    portrait = cv2.cvtColor(keyframe, cv2.COLOR_BGR2BGRA)
    portrait[:, :, 3] = mask[:, :, 3]
    warped = cv2.warpAffine(
        portrait, np.asarray(transform, dtype=np.float64),
        (body_rgba.shape[1], body_rgba.shape[0]),
        flags=cv2.INTER_AREA, borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0, 0))
    source_alpha = warped[:, :, 3:4].astype(np.float32) / 255.0
    if not replace:
        composite = body_rgba.copy()
        composite[:, :, :3] = np.round(
            warped[:, :, :3].astype(np.float32) * source_alpha
            + body_rgba[:, :, :3].astype(np.float32)
            * (1.0 - source_alpha)
        ).astype(np.uint8)
        composite[:, :, 3] = np.maximum(
            body_rgba[:, :, 3], warped[:, :, 3])
    else:
        clear_mask = cv2.imread(clear_mask_path, cv2.IMREAD_UNCHANGED) \
            if clear_mask_path else None
        if (clear_mask is None or clear_mask.ndim != 3
                or clear_mask.shape[2] != 4
                or clear_mask.shape[:2] != body_rgba.shape[:2]):
            raise RuntimeError("the stylized body clear mask is invalid")
        clear_alpha = clear_mask[:, :, 3:4].astype(np.float32) / 255.0
        body_alpha = (
            body_rgba[:, :, 3:4].astype(np.float32) / 255.0
            * (1.0 - clear_alpha))
        out_alpha = source_alpha + body_alpha * (1.0 - source_alpha)
        premultiplied = (
            warped[:, :, :3].astype(np.float32) * source_alpha
            + body_rgba[:, :, :3].astype(np.float32) * body_alpha
            * (1.0 - source_alpha))
        composite = np.zeros_like(body_rgba)
        composite[:, :, :3] = np.round(
            premultiplied / np.maximum(out_alpha, 1e-6)
        ).clip(0, 255).astype(np.uint8)
        composite[:, :, 3] = np.round(
            out_alpha[:, :, 0] * 255.0).clip(0, 255).astype(np.uint8)
        composite[composite[:, :, 3] == 0, :3] = 0
    if not cv2.imwrite(destination, composite):
        raise RuntimeError("the standing composite preview could not be written")


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


def _discard_cached_view_source(cache_dir, view):
    """Remove one rejected provider plate without invalidating accepted views."""
    if view not in BODY_VIEWS or not os.path.isdir(cache_dir):
        return
    prefix = f"source-{view}."
    for name in os.listdir(cache_dir):
        path = os.path.join(cache_dir, name)
        if name.startswith(prefix) and os.path.isfile(path):
            os.remove(path)


def _alpha_retry_remediation(reason, view):
    """Return one concise, failure-specific provider correction.

    This is an internal one-shot repair instruction.  It never mutates the
    owner's saved art direction or weakens the unchanged local alpha gate.
    """
    if view not in {"side", "back"}:
        raise ValueError(f"alpha provider retry is unavailable for {view}")
    lowered = str(reason or "").lower()
    corrections = []
    if "enclosed white silhouette slit" in lowered:
        corrections.append(
            "Keep loose hair curls/strands separated from the main silhouette "
            "so every white background channel opens visibly to the exterior "
            "plate; do not trap white crescents inside the hair. Preserve the "
            "original eyes, teeth, face, hair colour, and clothing without "
            "repainting white anatomy.")
    if view == "side":
        corrections.append(
            "Reproduce the approved front footwear's exact colour and "
            "material continuously through every outsole and the complete "
            "heel stem; never invent pale or metallic heel hardware, trim, "
            "undersoles, support pieces, specular fragments, or detached "
            "material.")
    if any(term in lowered for term in (
            "shadow", "floor", "wall", "contact", "ambient-occlusion")):
        corrections.append(
            "Remove every floor, wall, contact, cast, and ambient-occlusion "
            "shadow; RGB-255 white must touch every outsole and both sides "
            "of each heel stem.")
    if any(term in lowered for term in (
            "near-white", "near white", "off-white", "white/off-white",
            "plate contamination", "ambiguous against the plate",
            "preblended with white", "source-plate white")):
        corrections.append(
            "Replace plate-like white or off-white subject detail with a "
            "clearly non-white material and leave every silhouette gap pure "
            "white, crisp, and halo-free.")
    if any(term in lowered for term in (
            "shoe", "footwear", "heel", "sole", "reflection", "reflective",
            "highlight", "white/off-white", "ambiguous against the plate")):
        corrections.append(
            "Keep footwear dark, matte, and non-reflective with no pale trim "
            "or white specular patch; preserve complete soles and fine heel "
            "stems.")
    if not corrections:
        corrections.append(
            "Return one complete figure on a perfectly uniform RGB-255 white "
            "plate with clean transparent-ready gaps and no halo or scenery.")
    continuity = (
        "the exact approved front reference" if view == "side" else
        "the exact approved front and already matched side continuity")
    return (
        f"ALPHA QA RETRY — Regenerate only this {view} plate. Preserve "
        f"{continuity}, pose, proportions, outfit, and camera. "
        + " ".join(corrections)
    )


def _alpha_retry_prompt(prompt, reason, view):
    """Append retry remediation while retaining the provider byte ceiling."""
    remediation = _alpha_retry_remediation(reason, view)
    return _fit_full_body_prompt(f"{prompt}\n\n{remediation}")


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


def _edit_prompt(instruction, view, remove_headwear=False):
    """A bounded, view-aware prompt for one member of a matched edit set."""
    if view not in BODY_VIEWS:
        raise ValueError(f"unknown full-body view: {view}")
    from . import wardrobe
    headwear_rule = (
        wardrobe.REMOVE_HEADWEAR_RULE if bool(remove_headwear)
        else wardrobe.SOURCE_HEADWEAR_RULE)
    accessory_rule = (
        wardrobe.REMOVE_HEADWEAR_ACCESSORY_RULE if bool(remove_headwear)
        else wardrobe.ACCESSORY_RULE)
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
        "front": (
            "True straight-on front; level eyes, upright head, neck centred "
            "on torso."
        ),
        "side": "Keep a true 90-degree right-side profile.",
        "back": "Keep a true back view with the face completely out of view.",
    }[view]
    return f"""Precisely edit one existing full-body turnaround plate.

REFERENCES — {reference_contract}

REQUESTED CHANGE — {instruction}

EDIT CONTRACT — Apply only the requested visual change, then preserve everything else from Reference 1: the exact adult person, identity, apparent age, skin tone, hairstyle, body proportions, naturally long but realistic legs, pose, hand placement, foot placement, garment fit, materials, lighting, camera height, 3:4 canvas, full-body framing, and clean studio backdrop. {view_contract} Return exactly one person and one complete figure with both hands and both feet visible and clear silhouette margins. Do not crop, zoom, rotate, add text, add props, or redesign the face. Keep the mouth neutral and closed. The three plates must remain one coherent matched turnaround.

IDENTITY LOCK — Use the identity-head reference only to preserve identity, hair, eyewear, and the structured headwear state. Never paste a floating portrait, enlarge the head, alter facial anatomy, beautify, de-age, or change eyewear.

LOCAL CUTOUT CONTRACT — Uniform RGB-255 white continues behind and beneath the figure. Flat frontal light; the figure casts nothing. White touches every outsole edge, both sides of each heel stem, and every body/clothing gap. Return only figure and white. No green or green cast; no blue/green styling. No white or off-white wardrobe or footwear. Preserve fine hair and heel edges without smoke, veils, particles, reflections, halo, gray fringe, furniture, or scenery.

GOLD AND ACCESSORIES — {accessory_rule}

DECENCY AND RIG — Opaque public attire only: no nudity, lingerie, bare midriff, sheer fabric, exposed intimate areas, or extreme plunging neckline. Both hands stay empty. Nothing may be held, carried, slung, or hooked on the body.

HEADWEAR OVERRIDE — {headwear_rule}"""


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
    stored_style = options.get("style") \
        if options.get("style") in STYLES else "photorealistic"
    stored_presentation, _requested_medium, _stored_rule = \
        _presentation_context(options, stored_style)
    stored_medium = _stored_source_medium(avatar_dir)
    allow_stylized = stored_medium != "photograph"
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
        front_identity = None
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
            if not _render_body_cutout(
                    staged_sources[view], body_path, view, log=log,
                    allow_stylized=allow_stylized):
                raise RuntimeError(f"local person cutout failed for the {view} view")
            body_rgba = cv2.imread(body_path, cv2.IMREAD_UNCHANGED)
            if body_rgba is None or body_rgba.ndim != 3 or body_rgba.shape[2] != 4:
                raise RuntimeError(f"generated {view} body did not produce an RGBA plate")
            source_bgr = cv2.imread(staged_sources[view], cv2.IMREAD_COLOR)
            if source_bgr is None:
                raise RuntimeError(f"generated {view} body source could not be decoded")
            replacement_head = None
            if view == "front" and allow_stylized:
                front_identity = _face_transform(
                    keyframe, body_rgba, allow_stylized=True)
                replacement_head = _canonical_head_replacement_core(
                    body_rgba.shape, front_identity[0], front_identity[2])
            body_rgba, alpha_quality = body_alpha.refine(
                source_bgr, body_rgba,
                replacement_head_mask=replacement_head,
                verified_stylized=allow_stylized,
                stylized_turnaround_view=(
                    view if allow_stylized and view != "front" else None))
            if not alpha_quality["valid"]:
                raise GeneratedBodyAlphaError(
                    f"generated {view} body failed alpha QA: "
                    f"{alpha_quality['reason']}")
            if not cv2.imwrite(body_path, body_rgba):
                raise RuntimeError(f"refined {view} body alpha could not be written")
            log(
                f"  {view} body alpha ready: "
                f"{alpha_quality['removed_plate_pixels']} proven plate pixels removed")
            height, width = body_rgba.shape[:2]
            view_images[view] = body_rgba
            view_metadata[view] = {
                "image": os.path.basename(body_path),
                "source": os.path.basename(staged_sources[view]),
                "width": int(width),
                "height": int(height),
                "bounds": _alpha_bounds(body_rgba),
                "purpose": purposes[view],
                "alpha_quality": alpha_quality,
            }
        shutil.copy2(os.path.join(stage, "body-front.png"), os.path.join(stage, "body.png"))

        log("locking the calibrated face onto the generated front body")
        _emit(progress, "identity", .80, "Locking the calibrated face to the front view")
        if front_identity is None:
            front_identity = _face_transform(
                keyframe, view_images["front"][:, :, :3],
                allow_stylized=allow_stylized)
        transform, alignment, key_landmarks = front_identity
        proportion_quality = body_proportion.assess(
            view_images["front"], alignment.get("face_bounds"), options)
        proportion_failure = body_proportion.failure(proportion_quality)
        if proportion_failure:
            try:
                archived = _archive_rejected_body_proportion(
                    avatar_dir, staged_sources["front"], proportion_quality,
                    alignment=alignment,
                    refined_rgba=view_images["front"],
                    alpha_quality=view_metadata["front"]["alpha_quality"])
                log(
                    "  archived rejected front proportion diagnostic at "
                    f"{archived}")
            except Exception as diagnostic_error:
                # Retention remains subordinate to the authoritative hard gate.
                log(
                    "  could not archive rejected front proportion "
                    f"diagnostic: {diagnostic_error}")
            raise GeneratedBodyProportionError(proportion_failure)
        if proportion_quality.get("measurable"):
            log(
                "  body proportion ready: "
                f"{proportion_quality['apparent_heads_tall']:.2f} "
                "apparent heads tall")
        alignment["body_proportion"] = proportion_quality
        portrait_cutout_path = os.path.join(stage, "portrait-cutout.png")
        portrait_cutout = _identity_cutout(
            keyframe_path, keyframe, portrait_cutout_path, allow_stylized,
            log=lambda _message: None, landmarks=key_landmarks)
        head_mask_path = os.path.join(stage, "head-mask.png")
        head_composite = "blend"
        if allow_stylized:
            head_mask_mode = _stylized_head_mask(
                portrait_cutout, key_landmarks, head_mask_path,
                transform=transform, source_medium=stored_medium)
            head_composite = "replace" \
                if head_mask_mode == "full-silhouette" else "blend"
        else:
            _head_mask(portrait_cutout, key_landmarks, head_mask_path)
        face_bounds = alignment.get("face_bounds")
        clear_mask_path = None
        clear_mask_quality = None
        if face_bounds:
            if head_composite == "replace":
                clear_mask_path = os.path.join(stage, "head-clear-mask.png")
                clear_mask_quality = _stylized_head_clear_mask(
                    view_images["front"], head_mask_path, transform,
                    key_landmarks, face_bounds, clear_mask_path,
                    source_medium=stored_medium)
            else:
                _constrain_head_mask(
                    head_mask_path, view_images["front"], transform,
                    face_bounds)
            proportion_failure = _composite_head_proportion_failure(
                view_images["front"], head_mask_path, transform, face_bounds,
                verified_stylized=allow_stylized)
            if proportion_failure:
                raise GeneratedBodyIdentityError(proportion_failure)
        neck_registration = None
        if head_composite == "replace" and stored_medium == "3d render":
            authored_mask = cv2.imread(head_mask_path, cv2.IMREAD_UNCHANGED)
            registered, neck_registration = _register_soft_3d_neck_seam(
                view_images["front"], keyframe, authored_mask[:, :, 3],
                transform, key_landmarks, source_medium=stored_medium)
            if neck_registration["applied"]:
                view_images["front"] = registered
                for image_name in ("body.png", "body-front.png"):
                    if not cv2.imwrite(os.path.join(stage, image_name), registered):
                        raise RuntimeError(
                            "the registered soft-3D neck could not be written")
                log("  registered the soft-3D neck edge without moving the face")
            view_metadata["front"]["neck_registration"] = neck_registration
        if head_composite != "replace":
            _seam_tone_match(
                os.path.join(stage, "body.png"), keyframe, portrait_cutout,
                head_mask_path, transform,
                face_bounds)
        preview_name = None
        if face_bounds:
            preview_name = "body-composite.png"
            _runtime_composite_preview(
                os.path.join(stage, "body.png"), keyframe, head_mask_path,
                transform, os.path.join(stage, preview_name),
                replace=head_composite == "replace",
                clear_mask_path=clear_mask_path)
        os.remove(portrait_cutout_path)

        height, width = view_images["front"].shape[:2]
        face_transform = [
            [round(float(value), 7) for value in row]
            for row in transform
        ]
        view_metadata["front"]["face_transform"] = face_transform
        view_metadata["front"]["alignment"] = alignment
        if preview_name:
            view_metadata["front"]["preview_image"] = preview_name
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
                "style": stored_style,
                "pose": options.get("pose", "relaxed"),
                "prompt": _direction(options),
                "outfit": _clean(options.get("outfit"), 500),
                "notes": _clean(options.get("notes"), 600),
                # Structured identity policy. The generated canonical head is
                # the visual authority, while this receipt keeps body edits
                # and future motion generation from reversing the owner's
                # explicit preserve/remove choice.
                "remove_headwear": bool(
                    options.get("remove_headwear", False)),
                # Persist the exact visible-presentation branch that produced
                # this turnaround.  Without it, a later edit/regeneration fell
                # back to neutral and could lose the male/no-heels contract or
                # reject an already-approved feminine office brief.
                "presentation": stored_presentation,
                "medium": stored_medium,
            },
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        if head_composite == "replace":
            metadata["head_composite"] = "replace"
            metadata["head_clear_mask"] = "head-clear-mask.png"
            metadata["head_clear_quality"] = clear_mask_quality
            metadata["head_handoff_version"] = \
                STYLIZED_HEAD_HANDOFF_VERSION
            if neck_registration is not None:
                metadata["neck_registration"] = neck_registration
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
    options = _source_override_options(avatar_dir, options)
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

        def generate_view(view, prompt, retry=False):
            label = f"{view}-alpha-retry" if retry else view
            provider_dir = os.path.join(provider_stage, label)
            os.makedirs(provider_dir, mode=0o700)
            references = [identity_reference]
            if view != "front":
                references.append(sources["front"])
            generated_source = media_gen.generate_image_edit_sync(
                prompt, references, provider_config,
                aspect_ratio="3:4", quality="high",
                output_dir=provider_dir,
                file_name=(
                    f"body-source-{view}-alpha-retry" if retry else
                    f"body-source-{view}"))
            extension = os.path.splitext(generated_source)[1].lower() or ".png"
            _discard_cached_view_source(cache_dir, view)
            cached_path = os.path.join(cache_dir, f"source-{view}{extension}")
            shutil.copy2(generated_source, cached_path)
            return cached_path

        for view_index, view in enumerate(BODY_VIEWS):
            generated = cached[view]
            if generated:
                log(f"reusing the generated {view} body plate after a local QA retry")
            else:
                _emit(
                    progress, "generation", .14 + view_index * .18,
                    f"Generating {view} full-body view")
                log(f"generating {view} full body from the canonical HD head")
                generated = generate_view(view, prompts[view])
            sources[view] = generated
            try:
                if view == "front":
                    _preflight_front_source(
                        avatar_dir, generated, options, log=log)
                else:
                    _preflight_alpha_source(
                        avatar_dir, generated, view, options, log=log)
            except GeneratedBodyAlphaError as alpha_error:
                if view == "front":
                    shutil.rmtree(cache_dir, ignore_errors=True)
                    log(
                        "discarded the rejected generated front; the next try "
                        "will render a fresh turnaround")
                    raise
                # A side/back alpha defect does not invalidate the exact front
                # (or an already accepted side). Retry only the rejected view,
                # once, against the same coherent references and signature.
                _discard_cached_view_source(cache_dir, view)
                _emit(
                    progress, "generation", .14 + view_index * .18,
                    f"Repairing {view} full-body alpha plate")
                log(
                    f"generated {view} failed alpha QA; regenerating only "
                    "that view once with a targeted correction")
                retry_prompt = _alpha_retry_prompt(
                    prompts[view], str(alpha_error), view)
                try:
                    generated = generate_view(view, retry_prompt, retry=True)
                    sources[view] = generated
                    _preflight_alpha_source(
                        avatar_dir, generated, view, options, log=log)
                except Exception:
                    # Never leave a rejected retry eligible for cache reuse.
                    # The earlier accepted members and signature remain exact,
                    # so the next same-intent build can resume coherently.
                    _discard_cached_view_source(cache_dir, view)
                    log(
                        f"discarded the second rejected generated {view}; "
                        "retained the accepted earlier turnaround views")
                    raise
            except RuntimeError:
                # Every plate belongs to one coherent generated turnaround.
                # Reusing any of it after a preflight rejection can reproduce
                # the unsafe view or mismatch a freshly generated replacement.
                # Plain decode/cutout RuntimeErrors invalidate it as well as the
                # typed alpha, identity, and proportion failures.
                shutil.rmtree(cache_dir, ignore_errors=True)
                log(
                    f"discarded the rejected generated {view}; the next try "
                    "will render a fresh turnaround")
                raise
        try:
            metadata = _install_sources(
                avatar_dir, sources, provider, options, log=log,
                progress=progress)
        except (
                GeneratedBodyIdentityError,
                GeneratedBodyAlphaError,
                GeneratedBodyProportionError):
            # Side/back plates are generated from the rejected front plate. A
            # retry must therefore render one fresh coherent turnaround instead
            # of reusing the same doomed cache indefinitely.
            shutil.rmtree(cache_dir, ignore_errors=True)
            log(
                "discarded the rejected generated turnaround; the next try "
                "will render fresh views")
            raise
        shutil.rmtree(cache_dir, ignore_errors=True)
        return metadata
    finally:
        shutil.rmtree(provider_stage, ignore_errors=True)


def regenerate_view(avatar_dir, view, log=print, progress=None):
    """Repair only a rejected cartoon side/back plate, not the approved front.

    The caller must own the existing body-edit transaction and publish/reconcile
    afterward. This function does not change the avatar manifest, motion files
    or their provenance: a Walk tied to a replaced side remains tied to its
    original source and the normal reconciliation must invalidate it.
    """
    if view not in ("side", "back"):
        raise ValueError("targeted alpha repair supports only side or back")
    if not _allow_stylized_source(avatar_dir):
        raise ValueError("targeted alpha repair requires a classified cartoon")
    current = _body_metadata(avatar_dir)
    options = _source_override_options(
        avatar_dir, dict(current.get("options") or {}))
    sources = {
        name: _body_source(avatar_dir, current, name) for name in BODY_VIEWS
    }
    identity_reference = _identity_reference(avatar_dir)
    if not os.path.isfile(identity_reference):
        raise RuntimeError("avatar identity head is missing")
    try:
        _preflight_alpha_source(
            avatar_dir, sources[view], view, options, log=log)
    except GeneratedBodyAlphaError as error:
        rejection = str(error)
    else:
        raise RuntimeError(
            f"the current {view} already passes alpha QA; "
            "no regeneration was requested")

    provider_config, provider = image_provider_selection()
    prompt = _alpha_retry_prompt(_prompt(options, view=view), rejection, view)
    # Keep both the approved front and this view's existing character/wardrobe
    # as visual references. Only the rejected view is sent for replacement.
    references = [identity_reference, sources["front"], sources[view]]
    if view == "back":
        references.append(sources["side"])
    with open(sources[view], "rb") as handle:
        original_sha = hashlib.sha256(handle.read()).hexdigest()
    provider_stage = tempfile.mkdtemp(
        prefix=f".body-{view}-repair-provider-", dir=avatar_dir)
    try:
        _emit(progress, "generation", .16, f"Repairing only {view} body alpha")
        log(f"regenerating only rejected {view}; keeping approved front and head")
        generated = media_gen.generate_image_edit_sync(
            prompt, references, provider_config,
            aspect_ratio="3:4", quality="high", output_dir=provider_stage,
            file_name=f"body-source-{view}-alpha-repair")
        _preflight_alpha_source(
            avatar_dir, generated, view, options, log=log)
        replacement_sources = dict(sources)
        replacement_sources[view] = generated
        receipt = {
            "provider": provider,
            "scope": view,
            "operation": "targeted-alpha-repair",
            "rejected_source_sha256": original_sha,
            "reason": rejection,
            "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        return _install_sources(
            avatar_dir, replacement_sources, provider, options, log=log,
            progress=progress, edit_receipt=receipt, keep_previous=True)
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
    remove_headwear = bool(
        (current.get("options") or {}).get("remove_headwear", False))
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
                _edit_prompt(
                    instruction, view,
                    remove_headwear=remove_headwear),
                references, provider_config,
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
