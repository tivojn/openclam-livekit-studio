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
    # Cached house prompts carry deterministic negative clauses which must name
    # every forbidden item. Remove those exact app-authored rules before checking
    # only the owner's/model's editable prose for contradictory assignments.
    editable_direction = direction
    fixed_rules = (
        wardrobe.ACCESSORY_RULE,
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
        wardrobe.ACCESSORY_RULE, wardrobe.STRUCTURAL_RULE,
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
            "Create the canonical RIGHT-SIDE view. The nose, chest, knees, and toes point "
            "exactly camera-right in a true 90-degree profile; do not drift toward front or "
            "three-quarter. Reference 1 owns identity. Reference 2, the approved front, owns "
            "wardrobe, body proportions, materials, color, accessories, and garment length."
        ),
        "back": (
            "Create the canonical BACK view. The back of the head, shoulders, spine, hips, "
            "knees, and heels face the camera while the face remains completely out of view; "
            "do not turn the head over a shoulder. Reference 1 owns identity and hair. "
            "Reference 2, the approved front, owns wardrobe, body proportions, materials, color, "
            "accessories, and garment length."
        ),
    }[view]
    # Keep the deterministic contract compact. xAI Imagine enforces an 8 KiB
    # request ceiling, and side/back view instructions are longer than front.
    # Repeating the same ban in several paragraphs used to leave under 256
    # bytes for the owner's actual art direction and made a valid three-view
    # build fail before reaching the provider. Each non-negotiable now appears
    # once, leaving a useful editable budget for every view/presentation branch.
    prompt = f"""Create one vertical 3:4 full-body {view}-view plate of the exact same adult person.

TURNAROUND — matched FRONT / RIGHT-SIDE / BACK. One complete figure only—no triptych, split screen, duplicate, inset, or diagram. Keep one stationary pose, limbs, outfit, scale, and camera height; rotate only the camera.

IDENTITY LOCK — preserve the face, skull, skin, hair, brows, eyes, nose, lips, ears, and apparent age. If eyeglasses are present, preserve them exactly; never remove them. If absent, add none. Use a neutral closed mouth; never beautify, de-age, or redesign.

VIEW — {view_text}

COMPOSITION — complete figure, hair through both feet, with 7% clear margin. Camera at waist height, long portrait lens, minimal perspective distortion. Use a {pose_text}. Hands, legs, and footwear are complete and anatomical; no crop, props, furniture, or text.

PROPORTION TARGET — unmistakable high-fashion runway-supermodel silhouette, roughly 7.5 to 8 heads tall. Never copy the oversized head scale of the close-up identity reference. Crown-to-chin is 12.5 to 13.3 percent of standing height. Keep hair inside that head envelope, shoulders adult-width, long sculpted legs just over half-height, and the torso compact. Reject stretched limbs, a head-heavy silhouette, or warped anatomy.

CARRY NOTHING — both hands are completely empty and visible. No bag, handbag, clutch, purse, tote, backpack, briefcase, phone, cup, umbrella, weapon, staff, or other held object; no strap or pouch on shoulder, elbow, or body.

NO GOLD AND MINIMAL ACCESSORIES — {wardrobe.ACCESSORY_RULE}

EDITABLE ART DIRECTION — {direction}{house_section}

PRESENTATION AND FOOTWEAR — this plate uses only the {presentation} branch inferred from the reference; it is visible styling, not a claim about gender identity. {presentation_rule}

DECENCY FLOOR — tasteful opaque public clothing: no nudity, lingerie, bare midriff, sheer fabric, exposed intimate areas, extreme plunging neckline, or vulgar styling. Read as professional, polished, proper, and fashionable.

STYLE — {style_text}. Match the head's lighting, colour temperature, realism, and texture. Avoid airbrushed skin, plastic fabric, exaggerated anatomy, or game UI styling.

NO BLUE / NO COBALT — forbid every blue-family colour in wardrobe, footwear, accessories, props, backdrop, and light cast, including cobalt, ultramarine, navy, royal blue, sapphire, azure, cerulean, indigo, cyan, teal, turquoise, aqua, periwinkle, and blue-violet. Preserve natural eye and hair colour. Substitute vivid fuchsia, scarlet, or coral.

NO GREEN — never green or green-tinted: no green clothing, props, backdrop, or light cast; substitute a different color. Green corrupts alpha.

NO WHITE WARDROBE — no white/off-white garments and absolutely no white shoes or soles. They dissolve into the light cutout backdrop. Substitute a clearly non-white, non-green color.

SOURCE PLATE—Uniform RGB-255 white continues behind and beneath the figure. Flat frontal light; the figure casts nothing. White touches every outsole edge, both sides of each heel stem, and every body/clothing gap. Return only figure and white."""
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
    try:
        body_landmarks = _detect(body_image, "generated body")
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
    return transform, {
        "residual_median_px": round(float(np.median(residual)), 3),
        "residual_max_px": round(float(np.max(residual)), 3),
        "scale": round(scale, 5),
        "face_bounds": [int(x), int(y), int(width), int(height)],
    }, key_landmarks


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
        cutout_path = os.path.join(stage, "front.png")
        if not cutout.render(source, cutout_path, log=log, tight=True):
            raise RuntimeError("local person cutout failed for the front view")
        body_rgba = cv2.imread(cutout_path, cv2.IMREAD_UNCHANGED)
        if (body_rgba is None or body_rgba.ndim != 3
                or body_rgba.shape[2] != 4):
            raise RuntimeError(
                "generated front body did not produce an RGBA plate")
        body_rgba, alpha_quality = body_alpha.refine(source_bgr, body_rgba)
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
        _transform, alignment, _landmarks = _face_transform(
            keyframe, body_rgba[:, :, :3])
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


def _preflight_alpha_source(avatar_dir, source, view, log=print):
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
        cutout_path = os.path.join(stage, f"{view}.png")
        if not cutout.render(source, cutout_path, log=log, tight=True):
            raise RuntimeError(f"local person cutout failed for the {view} view")
        body_rgba = cv2.imread(cutout_path, cv2.IMREAD_UNCHANGED)
        if (body_rgba is None or body_rgba.ndim != 3
                or body_rgba.shape[2] != 4):
            raise RuntimeError(
                f"generated {view} body did not produce an RGBA plate")
        refined, alpha_quality = body_alpha.refine(source_bgr, body_rgba)
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


def _composite_head_proportion_failure(body_image, mask_path, transform,
                                       face_bounds):
    """Return a user-facing failure when the final live overlay is oversized."""
    if not face_bounds:
        return "generated face alignment is missing"
    person_bounds = _alpha_bounds(body_image)
    person_width = max(1.0, float(person_bounds[2]))
    person_height = max(1.0, float(person_bounds[3]))
    _face_x, _face_y, face_width, face_height = [float(v) for v in face_bounds]
    face_width_ratio = face_width / person_width
    face_height_ratio = face_height / person_height
    if face_width_ratio > 0.43 or face_height_ratio > 0.15:
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
    if width_ratio > 0.76 or height_ratio > 0.22:
        return (
            "live head silhouette is too large for the body "
            f"({width_ratio:.3f} wide, {height_ratio:.3f} tall)")
    return None


def _runtime_composite_preview(body_path, keyframe, mask_path, transform,
                               destination):
    """Bake the same standing head/body stack shown by the desktop runtime."""
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
    alpha = warped[:, :, 3:4].astype(np.float32) / 255.0
    composite = body_rgba.copy()
    composite[:, :, :3] = np.round(
        warped[:, :, :3].astype(np.float32) * alpha
        + body_rgba[:, :, :3].astype(np.float32) * (1.0 - alpha)
    ).astype(np.uint8)
    composite[:, :, 3] = np.maximum(body_rgba[:, :, 3], warped[:, :, 3])
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

LOCAL CUTOUT CONTRACT — Uniform RGB-255 white continues behind and beneath the figure. Flat frontal light; the figure casts nothing. White touches every outsole edge, both sides of each heel stem, and every body/clothing gap. Return only figure and white. No green or green cast; no blue/green styling. No white or off-white wardrobe or footwear. Preserve fine hair and heel edges without smoke, veils, particles, reflections, halo, gray fringe, furniture, or scenery.

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
            source_bgr = cv2.imread(staged_sources[view], cv2.IMREAD_COLOR)
            if source_bgr is None:
                raise RuntimeError(f"generated {view} body source could not be decoded")
            body_rgba, alpha_quality = body_alpha.refine(source_bgr, body_rgba)
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
        transform, alignment, key_landmarks = _face_transform(
            keyframe, view_images["front"][:, :, :3])
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
        if not cutout.render(keyframe_path, portrait_cutout_path, log=lambda _message: None):
            raise RuntimeError("could not build the identity overlay mask")
        portrait_cutout = cv2.imread(portrait_cutout_path, cv2.IMREAD_UNCHANGED)
        head_mask_path = os.path.join(stage, "head-mask.png")
        _head_mask(portrait_cutout, key_landmarks, head_mask_path)
        face_bounds = alignment.get("face_bounds")
        if face_bounds:
            _constrain_head_mask(
                head_mask_path, view_images["front"], transform, face_bounds)
            proportion_failure = _composite_head_proportion_failure(
                view_images["front"], head_mask_path, transform, face_bounds)
            if proportion_failure:
                raise GeneratedBodyIdentityError(proportion_failure)
        _seam_tone_match(
            os.path.join(stage, "body.png"), keyframe, portrait_cutout,
            head_mask_path, transform,
            face_bounds)
        preview_name = None
        if face_bounds:
            preview_name = "body-composite.png"
            _runtime_composite_preview(
                os.path.join(stage, "body.png"), keyframe, head_mask_path,
                transform, os.path.join(stage, preview_name))
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
        stored_style = options.get("style") \
            if options.get("style") in STYLES else "photorealistic"
        stored_presentation, stored_medium, _stored_rule = \
            _presentation_context(options, stored_style)
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
                # Persist the exact visible-presentation branch that produced
                # this turnaround.  Without it, a later edit/regeneration fell
                # back to neutral and could lose the male/no-heels contract or
                # reject an already-approved feminine office brief.
                "presentation": stored_presentation,
                "medium": stored_medium,
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
                        avatar_dir, generated, view, log=log)
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
                        avatar_dir, generated, view, log=log)
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
