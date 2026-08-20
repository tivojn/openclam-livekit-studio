"""Portrait-aware full-body art direction.

The Full Body Studio used to ship ONE hardcoded fashion paragraph for every
avatar. That paragraph was written for a photoreal adult woman in tailored
separates, so it was wrong for most uploads: it dressed a game hero in office
separates, and it told a stylised anime portrait to keep "real skin texture".

This module reads the uploaded portrait through OpenClam's selected direct
vision LLM and writes the art direction FOR THAT SUBJECT - medium,
presentation, apparent age, implied profession, and existing style register
all steer the brief. A photoreal fashion subject gets silhouette, palette and
jewellery discipline; a game or fantasy character gets costume, armour,
material and lighting detail instead.

Four rules are structural rather than stylistic, so they are enforced in code
after the model writes: BELIEVABLE LONG-LEG EDITORIAL PROPORTIONS, NO HEAVY
LAYERS, NO BAGGY TROUSERS, and NOTHING IN THE HANDS. The middle two protect the
silhouette the runtime rig depends on - bulky outerwear hides the shoulder line
the face is mapped onto, and wide slouchy legs break the walk cycle's stride
read. The last breaks every downstream pose: a
handbag welded to one hand cannot wave, point, or swing through a walk cycle,
and a carried prop re-appears inconsistently across the front/side/back
turnaround. The model is told, and the result is then checked.

Everything degrades to the static preset: no vision model, no network, bad JSON,
or a banned garment surviving the rewrite all fall back rather than fail the
build.
"""
import base64
import datetime
import hashlib
import json
import os
import re
import tempfile

import cv2
try:
    import media_gen
except ModuleNotFoundError:  # package-style test/import outside server/app.py
    from server import media_gen


CACHE_NAME = ".wardrobe.json"
CACHE_VERSION = 4
ANALYSIS_EDGE = 768
PROMPT_LIMIT = 3200

# Garments that break the runtime rig rather than merely look wrong. Kept as
# whole words so "overcoat" is caught but "coated" is not.
BANNED_PATTERNS = (
    r"heav(?:y|ily)\s+layer", r"heavy\s+outerwear", r"thick\s+layer",
    r"layered\s+heav", r"bulk(?:y|ier)", r"padded\s+(?:coat|jacket|parka)",
    r"puffer", r"parka", r"overcoat", r"greatcoat", r"duffel\s+coat",
    r"trench\s*coat", r"poncho", r"cloak", r"shawl", r"cape\b",
    r"bagg(?:y|ie)", r"slouch(?:y|ed)", r"wide[-\s]?leg", r"palazzo",
    r"harem\s+pant", r"parachute\s+pant", r"cargo\s+pant", r"oversized\s+pant",
    r"loose[-\s]?fit(?:ting)?\s+(?:pant|trouser|jean)",
    # Carried props: a bag welded to one hand cannot survive the turnaround or
    # any downstream pose, so nothing may be held, slung, or hooked on an arm.
    r"\bbags?\b", r"handbag", r"\bpurse\b", r"\bclutch\b", r"\btotes?\b",
    r"\bsatchel\b", r"briefcase", r"backpack", r"rucksack", r"crossbody",
    r"\bumbrella\b", r"holding\s+(?:a|an|the|any)\b", r"\bhand-?held\b",
    r"in\s+(?:her|his|their|one)\s+hands?\b",
)
BANNED = tuple(re.compile(pattern, re.IGNORECASE) for pattern in BANNED_PATTERNS)

SILHOUETTE_RULE = (
    "Never use heavy layering, bulky outerwear, capes, or padded coats, and never "
    "use baggy, slouchy, wide-leg, or oversized trousers: the silhouette must stay "
    "clean and readable from shoulder to ankle."
)

PROPORTION_RULE = (
    "Give the adult figure believable supermodel-calibre editorial proportions: "
    "tall, poised, and sculpted, with naturally long legs and a balanced "
    "torso-to-leg ratio. Long must never become exaggerated: no stretched limbs, "
    "tiny torso, pinched waist, warped hips, knees, or ankles, or impossible height."
)

HANDS_RULE = (
    "The subject carries nothing at all: both hands stay completely empty and "
    "clearly visible, with no bag, handbag, clutch, purse, tote, backpack, "
    "briefcase, phone, cup, umbrella, weapon, or any other held prop, and nothing "
    "slung over a shoulder, hooked on an elbow, or worn across the body."
)

# Appended to every finished brief. Kept out of the ban check, since the rules
# name the very garments and props they forbid.
STRUCTURAL_RULE = f"{PROPORTION_RULE} {SILHOUETTE_RULE} {HANDS_RULE}"

# OpenClam's full-body plate currently has a hard no-green contract because the
# downstream alpha pass can erase green wardrobe. Emerald remains part of the
# owner's broader house palette, but the plate prompt has to substitute it until
# that extraction contract changes. This is explicit instead of silently
# turning the requested emerald into some arbitrary colour.
COLOR_RULE = (
    "Use exactly one hero colour from fuchsia, scarlet, coral, ultramarine, or "
    "camel, plus exactly one restrained accent and quiet black, charcoal, taupe, "
    "or chocolate neutrals. Never use cobalt. Emerald belongs to the house "
    "palette but is unavailable on OpenClam cutout plates because green damages "
    "alpha extraction; substitute ultramarine if emerald is requested."
)

ACCESSORY_RULE = (
    "Gold is forbidden everywhere in the wardrobe and styling: no gold; no "
    "gold-tone or gold-plated finishes; no gilded or gilt jewellery, hardware, "
    "buttons, buckles, zippers, trim, thread, embroidery, footwear, or garment "
    "accents. "
    "No yellow, rose, or white gold. Accessories are optional and omission is "
    "preferred. If used, allow at most one small, understated accessory choice "
    "in silver, platinum, or a restrained neutral stone; a simple pair of studs "
    "counts as one choice. No statement jewellery; no layered necklaces or "
    "chains; no stacked rings, bracelets, or bangles; no multiple-earring "
    "clusters or ear stacks; no oversized pendants or brooches; no ornate belts, "
    "decorative body chains, or "
    "accessory clutter."
)

LUXURY_FINISH_RULE = (
    "Keep the silhouette structured, sensual, and polished, never revealing for "
    "its own sake: no bare midriff, sheer fabric, or extreme plunging neckline. "
    "Preserve the existing hairstyle while giving it a sleek editorial finish; "
    "use luminous real skin texture, defined brows, and restrained, "
    "presentation-appropriate grooming. The final test is tailored authority, "
    "editorial sensuality, and zero fast-fashion noise."
)

FEMININE_RULE = (
    "For a feminine-presenting photographic subject, use the design discipline of "
    "Saint Laurent power tailoring, Dior wrap blazers, The Row or Khaite "
    "minimalism, Chanel tweed, Bottega Veneta leather garments, or a close-cut "
    "Max Mara camel coat. Finish with elegant heels of at least 90mm in the spirit "
    "of Christian Louboutin, Manolo Blahnik, Gianvito Rossi, or Aquazzura. Keep "
    "makeup restrained; for evening choose either a smoky eye or a bold lip, never "
    "both."
)

MASCULINE_RULE = (
    "For a masculine-presenting photographic subject, use the design discipline of "
    "Saint Laurent or Tom Ford power tailoring, Dior Men precision, The Row "
    "minimalism, Bottega Veneta leather garments, Zegna or Loro Piana refinement, "
    "or a close-cut camel coat. Finish with polished loafers, Oxfords, Derbies, or "
    "sharp ankle boots in the spirit of Berluti, John Lobb, Edward Green, Saint "
    "Laurent, or Bottega Veneta. Never assign pumps, stilettos, or high heels to "
    "this masculine branch. Use polished natural grooming, clean skin texture, "
    "defined brows, and carefully finished hair or facial hair; never force a "
    "feminine evening-makeup direction onto the subject."
)

ANDROGYNOUS_RULE = (
    "For an androgynous or visually ambiguous photographic subject, do not infer a "
    "gender identity. Preserve the presentation visible in the reference through "
    "architectural Saint Laurent, Dior, The Row, Khaite, or Bottega Veneta "
    "tailoring, and finish with polished loafers or sharp ankle boots rather than "
    "defaulting to heels. Preserve the reference's visible grooming and makeup "
    "language instead of imposing a feminine or masculine beauty code."
)

STYLISED_RULE = (
    "For game art, anime, illustration, or 3D subjects, preserve the reference's "
    "existing costume register, palette hierarchy, essential non-gold ornament, "
    "grooming, and visible "
    "feminine, masculine, or androgynous presentation. Raise its material and cut "
    "quality without importing literal fashion-house tailoring, jewellery, makeup, "
    "or footwear. Never use cobalt or gold and never add accessory clutter. Do not "
    "replace a fantasy or heroic costume with office wear, and keep every essential "
    "costume element and shoe presentation-appropriate."
)

COBALT_PATTERN = re.compile(r"\bcobalt\b", re.IGNORECASE)
GOLD_PATTERN = re.compile(
    r"\b(?:gold|gilded|gilt)\b|"
    r"\bgolden\s+(?=(?:metal|jewell?ery|jewellery|hardware|button|buckle|"
    r"zipper|trim|thread|embroidery|accent|chain|necklace|earring|bracelet|"
    r"bangle|cuff|ring|brooch|watch|pendant|belt|shoe|heel|fabric|leather)\b)",
    re.IGNORECASE,
)
EXCESSIVE_ACCESSORY_PATTERN = re.compile(
    r"\bstatement\s+(?:piece|jewell?ery|jewellery|accessor(?:y|ies)|necklace|"
    r"earrings?|cuff|watch|brooch|pendant)\b|"
    r"\b(?:excessive|layered|stacked|multiple|oversized|chunky|heavy|ornate)\s+"
    r"(?:(?:silver|platinum|stone|diamond|gemstone|pearl|metal|leather|"
    r"crystal|beaded|jewelled|jeweled)\s+)?"
    r"(?:accessor(?:y|ies)|jewell?ery|jewellery|necklaces?|chains?|earrings?|"
    r"rings?|bracelets?|bangles?|pendants?|brooches?|belts?)\b|"
    r"\bmultiple[-\s]+earrings?(?:\s+clusters?)?\b|"
    r"\bear\s+stacks?\b|"
    r"\b(?:jewell?ery|jewellery|accessory)\s+sets?\b|"
    r"\b(?:necklace|chain|ring|bracelet|bangle)\s+stack\b|"
    r"\baccessory\s+clutter\b",
    re.IGNORECASE,
)

# Prompt text is authoring data, so policy migrations must never rewrite it on
# disk.  These fingerprints identify prompts emitted by retired OpenClam house
# templates.  They let the read/generation boundary remove the obsolete clauses
# without silently sanitising a new owner-authored request for gold.
LEGACY_PROMPT_MARKERS = (
    "real-looking gold, platinum, and stones",
    "add exactly one statement detail",
    "jewellery restrained to small matching stud earrings",
)
LEGACY_ACCESSORY_SENTENCE_PATTERN = re.compile(
    r"\badd\s+exactly\s+one\s+statement\s+detail\b|"
    r"\b(?:jewelry|jewellery)\s+restrained\s+to\s+small\s+matching\s+stud\s+"
    r"earrings\b",
    re.IGNORECASE,
)
MASCULINE_HEEL_PATTERN = re.compile(
    r"\b(?:heels?|high[-\s]?heels?|pumps?|stilettos?|d['’]?orsay|"
    r"\d{2,3}\s*mm\s*heels?)\b",
    re.IGNORECASE,
)


def _assigns_forbidden_term(text, pattern):
    """True when a matched styling term is assigned rather than prohibited."""
    text = text or ""
    for match in pattern.finditer(text):
        prefix = text[max(0, match.start() - 64):match.start()].lower()
        suffix = text[match.end():match.end() + 48].lower()
        if re.search(r"\bnon[-\s]?$", prefix) or re.match(
                r"[-\s]+free\b", suffix):
            continue
        if re.search(
                r"(?:\bno\b|\bnever\b|\bwithout\b|\bavoid\b|\bban(?:ned)?\b|"
                r"\b(?:remove|eliminate|delete|replace|simplify)\b|"
                r"\bdo\s+not\s+(?:assign|use|wear|add|include)\b)"
                r"(?:[^.!?;:]|,(?!\s*(?:but|instead))){0,46}$",
                prefix):
            continue
        if re.match(
                r"\s+(?:is|are|remains?|must\s+be)\s+"
                r"(?:forbidden|banned|excluded|not\s+allowed)\b",
                suffix):
            continue
        return True
    return False


def _assigns_gold(text):
    return _assigns_forbidden_term(text, GOLD_PATTERN)


def _assigns_excessive_accessories(text):
    return _assigns_forbidden_term(text, EXCESSIVE_ACCESSORY_PATTERN)


def _assigns_feminine_heels(text):
    """True only for a positive heel assignment, not a prohibition.

    Model prose often repeats a safety instruction such as "no high heels".
    Treating the noun alone as an assignment made a correct masculine brief fall
    back to the preset. We inspect the short phrase before each hit so explicit
    negatives remain allowed while positive footwear directions still fail closed.
    """
    for match in MASCULINE_HEEL_PATTERN.finditer(text or ""):
        prefix = (text or "")[max(0, match.start() - 52):match.start()].lower()
        if re.search(
                r"(?:\bno\b|\bnever\b|\bwithout\b|\bavoid\b|"
                r"\bdo\s+not\s+(?:assign|use|wear|add)\b)"
                r"(?:[^.!?;:]|,(?!\s*(?:but|instead))){0,38}$",
                prefix):
            continue
        return True
    return False

SYSTEM = (
    "You are a senior costume designer and fashion director. You look at one "
    "reference portrait and write the wardrobe brief for a full-body character "
    "plate of that exact person.\n\n"
    "Return STRICT JSON only, no prose and no code fence, with these keys:\n"
    '"presentation" - the visible styling presentation: feminine, masculine, '
    "or androgynous. This describes the image and is not a claim about the "
    "person's gender identity.\n"
    '"age_band" - young adult, adult, or mature.\n'
    '"medium" - photograph, game art, anime, illustration, or 3d render.\n'
    '"register" - three to six words naming the aesthetic, e.g. "fashion-forward "'
    'contemporary womenswear" or "mythic Chinese action-game hero".\n'
    '"profession" - the implied role or profession, or "unspecified".\n'
    '"palette" - three to five concrete colours read from the portrait.\n'
    '"direction" - the wardrobe and styling brief itself, 90 to 150 words, '
    "written as instructions to an image model.\n\n"
    "RULES FOR \"direction\":\n"
    "1. Match the MEDIUM. A photograph gets real fabrics, tailoring and "
    "photographic realism. Game art, anime, or 3d art gets high-detail costume, "
    "armour, ornament, material breakdown, and dramatic practical or rim lighting "
    "instead of everyday clothing.\n"
    "2. Match the PERSON'S VISIBLE PRESENTATION, apparent age, and existing "
    "style register. Do not infer gender identity and do not default every "
    "subject to womenswear, menswear, or office separates.\n"
    "3. Match the STYLE already visible, then raise it to couture level. Use a "
    "cutter's language, substantial fabrics with believable behaviour, crisp "
    "internal structure, and realistic seam tension. A heroic or fantasy "
    "subject should read powerful through costume detail, armour, weathering, "
    "and ornament rather than literal ready-to-wear.\n"
    f"4. PHOTOGRAPHIC COLOUR: {COLOR_RULE} For a stylised subject, preserve "
    "the reference costume's palette hierarchy instead; never use cobalt.\n"
    "5. PHOTOGRAPHIC FASHION BRANCHES: choose exactly ONE branch from the "
    "visible presentation. Do not mix their footwear rules.\n"
    f"   FEMININE: {FEMININE_RULE}\n"
    f"   MASCULINE: {MASCULINE_RULE}\n"
    f"   ANDROGYNOUS OR AMBIGUOUS: {ANDROGYNOUS_RULE}\n"
    f"6. GOLD AND ACCESSORIES FOR EVERY MEDIUM: {ACCESSORY_RULE}\n"
    f"7. PHOTOGRAPHIC LUXURY FINISH: {LUXURY_FINISH_RULE}\n"
    f"8. BODY PROPORTIONS: {PROPORTION_RULE}\n"
    "9. HARD BAN: never heavy layering, bulky or padded outerwear, puffers, "
    "parkas, trench coats, capes, cloaks or shawls; and never baggy, slouchy, "
    "wide-leg, cargo, or oversized trousers. Keep trousers, skirts and armour "
    "greaves fitted and the full silhouette readable from shoulder to ankle.\n"
    "10. HARD BAN: the subject carries NOTHING. Never mention, describe, or imply "
    "a bag, handbag, clutch, purse, tote, backpack, briefcase, phone, cup, "
    "umbrella, weapon, staff, or any other held or carried object, and never "
    "sling a bag or strap over a shoulder, an elbow, or across the body. Both "
    "hands stay empty. Carried props break the pose rig and cannot survive the "
    "front/side/back turnaround.\n"
    "11. Clothing stays opaque and suitable for public view: no nudity, lingerie, "
    "bare midriff, sheer fabric, exposed intimate areas, extreme plunging "
    "neckline, or vulgar styling. Allure comes from structure, fit, and "
    "confidence, never exposure.\n"
    "12. Never redesign the face, hairstyle, skin tone, or identity. Beauty notes "
    "control finish only: keep the existing hair shape, real skin texture, and "
    "eyeglasses exactly as shown. Write wardrobe, materials, palette, accessories, "
    "footwear, and medium-appropriate rendering detail."
)

USER_TEXT = (
    "Analyse this reference portrait and write the full-body wardrobe brief for "
    "this exact subject. Return the strict JSON object only."
)


def _clean(value, maximum=PROMPT_LIMIT):
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value or ""))
    return re.sub(r"\s+", " ", value).strip()[:maximum]


def migrate_legacy_prompt(
        value, *, stored=False, ensure_rule=False, maximum=PROMPT_LIMIT):
    """Return a policy-safe projection of an old OpenClam-authored prompt.

    This is deliberately pure: ``.wardrobe.json`` and ``body/body.json`` remain
    byte-for-byte untouched.  ``stored`` is reserved for those persisted,
    app-authored sources.  Without it, only a retired house-template fingerprint
    enables migration, so a new manual request for gold is left intact and the
    normal fail-closed validator rejects it.
    """
    maximum = max(1, int(maximum))
    prompt = _clean(value, maximum)
    if not prompt:
        return _clean(ACCESSORY_RULE, maximum) if ensure_rule else ""

    legacy_source = stored or any(
        marker in prompt.lower() for marker in LEGACY_PROMPT_MARKERS)

    # Deduplicate either spelling of the current fixed rule.  The first release
    # omitted "No" before yellow/rose/white gold; recognise that exact generated
    # form as data from this app, not as a fresh positive owner instruction.
    buggy_rule = ACCESSORY_RULE.replace(
        "No yellow, rose, or white gold.",
        "yellow, rose, or white gold.",
    )
    had_policy = ACCESSORY_RULE in prompt or buggy_rule in prompt
    if not legacy_source and ACCESSORY_RULE in prompt:
        return prompt
    if not legacy_source and buggy_rule in prompt:
        return _clean(prompt.replace(buggy_rule, ACCESSORY_RULE), maximum)
    prompt = prompt.replace(ACCESSORY_RULE, " ").replace(buggy_rule, " ")
    prompt = _clean(prompt, maximum)

    if legacy_source:
        kept = []
        for sentence in re.split(r"(?<=[.!?])\s+", prompt):
            sentence = sentence.strip()
            if not sentence:
                continue
            if (LEGACY_ACCESSORY_SENTENCE_PATTERN.search(sentence)
                    or _assigns_gold(sentence)
                    or _assigns_excessive_accessories(sentence)):
                continue
            kept.append(sentence)
        prompt = _clean(" ".join(kept), maximum)

    if not (legacy_source or had_policy or ensure_rule):
        return prompt

    # The fixed rule, rather than migrated prose, owns the end of the budget.
    # Keeping it intact also makes repeated API/UI projections idempotent.
    room = max(0, maximum - len(ACCESSORY_RULE) - 1)
    prompt = _clean(prompt, room)
    return _clean(f"{prompt} {ACCESSORY_RULE}", maximum)


def banned_terms(text):
    """Every rig-breaking garment named in the text, for logs and tests."""
    found = []
    for pattern in BANNED:
        match = pattern.search(text or "")
        if match and match.group(0).lower() not in found:
            found.append(match.group(0).lower())
    return found


def _preference(_key):
    """Retired compatibility hook; standalone OpenClam reads no preferences."""
    return {}


def _llm_route():
    """OpenClam's Keychain-materialised direct vision lane."""
    config, public = media_gen.selected_config(
        "llm", media_gen.VISION_TEXT_PROVIDERS)
    return config, public.get("model") or ""


def _encoded_reference(image_path):
    """Downscale before upload: the brief needs the look, not the megapixels."""
    image = cv2.imread(image_path, cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError("could not read the identity portrait")
    height, width = image.shape[:2]
    longest = max(height, width)
    if longest > ANALYSIS_EDGE:
        scale = ANALYSIS_EDGE / float(longest)
        image = cv2.resize(
            image, (max(1, int(round(width * scale))), max(1, int(round(height * scale)))),
            interpolation=cv2.INTER_AREA)
    ok, buffer = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 88])
    if not ok:
        raise RuntimeError("could not encode the identity portrait")
    return base64.b64encode(buffer.tobytes()).decode("ascii")


def _chat(route, model, encoded):
    config = dict(route)
    if model:
        config["model"] = str(model)
    return media_gen.generate_text_sync(
        SYSTEM, USER_TEXT, config, image_b64=encoded, max_tokens=900)


def _normalise_presentation(value):
    """Normalise visible styling without claiming a person's gender identity."""
    value = _clean(value, 40).lower()
    if value in {"feminine", "female", "woman", "women"}:
        return "feminine"
    if value in {"masculine", "male", "man", "men"}:
        return "masculine"
    return "androgynous"


def _presentation_rule(presentation, medium):
    medium = _clean(medium, 40).lower()
    if medium in {"game art", "anime", "illustration", "3d render"}:
        return STYLISED_RULE
    return {
        "feminine": FEMININE_RULE,
        "masculine": MASCULINE_RULE,
        "androgynous": ANDROGYNOUS_RULE,
    }[_normalise_presentation(presentation)]


def _parse(text):
    body_text = re.sub(r"^```(?:json)?|```$", "", text.strip(),
                       flags=re.IGNORECASE | re.MULTILINE).strip()
    try:
        parsed = json.loads(body_text)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", body_text, re.DOTALL)
        if not match:
            raise RuntimeError("the vision model did not return JSON")
        parsed = json.loads(match.group(0))
    if not isinstance(parsed, dict):
        raise RuntimeError("the vision model did not return a JSON object")
    direction = _clean(parsed.get("direction"), PROMPT_LIMIT - 600)
    if len(direction) < 60:
        raise RuntimeError("the vision model returned an unusably short brief")
    palette = parsed.get("palette")
    if isinstance(palette, list):
        palette = ", ".join(str(value) for value in palette if value)
    traits = {
        "presentation": _normalise_presentation(parsed.get("presentation")),
        "age_band": _clean(parsed.get("age_band"), 40),
        "medium": _clean(parsed.get("medium"), 40),
        "register": _clean(parsed.get("register"), 90),
        "profession": _clean(parsed.get("profession"), 90),
        "palette": _clean(palette, 140),
    }
    return direction, traits


def _finalise(direction, presentation="androgynous", medium="photograph"):
    """Refuse anything that broke a hard ban, then append the structural rules.

    The check runs on the model's own words BEFORE the rules are appended: the
    rules have to name the banned garments and props to forbid them, so checking
    the joined text would flag the cure as the disease.
    """
    violations = banned_terms(direction)
    if violations:
        raise RuntimeError(
            "the vision model kept a banned garment: " + ", ".join(violations))
    if COBALT_PATTERN.search(direction or ""):
        raise RuntimeError("the vision model kept the banned colour cobalt")
    if _assigns_gold(direction):
        raise RuntimeError("the vision model kept the banned material or colour gold")
    if _assigns_excessive_accessories(direction):
        raise RuntimeError("the vision model kept excessive accessories")
    # A missing classifier becomes the presentation-neutral branch. This is a
    # safe fallback for PromptSmith and the static preset: it never defaults an
    # unknown or masculine portrait to feminine heels.
    presentation = _normalise_presentation(presentation)
    if presentation in {"masculine", "androgynous"} and \
            _assigns_feminine_heels(direction):
        raise RuntimeError(
            "the vision model assigned feminine heels to a non-feminine subject")

    stylised = _clean(medium, 40).lower() in {
        "game art", "anime", "illustration", "3d render",
    }
    suffix_rules = (
        [STYLISED_RULE, ACCESSORY_RULE, STRUCTURAL_RULE]
        if stylised else
        [COLOR_RULE, _presentation_rule(presentation, medium),
         ACCESSORY_RULE, LUXURY_FINISH_RULE, STRUCTURAL_RULE]
    )
    suffix = " ".join(suffix_rules)
    # Keep every deterministic house/rig rule intact. The model's prose is the
    # only part allowed to yield when a provider ignores the requested length.
    room = max(60, PROMPT_LIMIT - len(suffix) - 2)
    direction = _clean(direction, room)
    if not direction.endswith((".", "!", "?")):
        direction += "."
    return _clean(f"{direction} {suffix}", PROMPT_LIMIT)


def preset_prompt():
    from . import body
    return _clean(
        f"{body.DEFAULT_BODY_PROMPT} {ACCESSORY_RULE} {STRUCTURAL_RULE}",
        PROMPT_LIMIT,
    )


def _identity_reference(avatar_dir):
    head = os.path.join(avatar_dir, "head.png")
    if os.path.isfile(head):
        return head
    keyframe = os.path.join(avatar_dir, "keyframe.png")
    if os.path.isfile(keyframe):
        return keyframe
    raise RuntimeError("avatar identity portrait is missing")


def _digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _read_cache(avatar_dir, digest):
    try:
        with open(os.path.join(avatar_dir, CACHE_NAME)) as handle:
            cached = json.load(handle)
    except Exception:
        return None
    if (not isinstance(cached, dict)
            or cached.get("version") not in {3, CACHE_VERSION}
            or cached.get("digest") != digest):
        return None
    prompt = _clean(cached.get("prompt"), PROMPT_LIMIT)
    if len(prompt) < 60:
        return None
    legacy = cached.get("version") == 3
    prompt = migrate_legacy_prompt(
        prompt, stored=legacy, ensure_rule=True)
    editable = prompt.replace(ACCESSORY_RULE, " ")
    # A current cache was produced after the policy gate and must never require
    # silent cleanup.  Reject corruption or hand-edited policy violations so the
    # normal tailor/fallback path runs; only the explicitly legacy v3 source is
    # eligible for deterministic read-time migration.
    if (_assigns_gold(editable)
            or _assigns_excessive_accessories(editable)):
        return None
    traits = cached.get("traits")
    return {
        "prompt": prompt,
        "source": "tailored",
        "traits": traits if isinstance(traits, dict) else {},
        "cached": True,
        "migrated": legacy,
    }


def _write_cache(avatar_dir, payload):
    directory = os.path.abspath(avatar_dir)
    descriptor, temporary = tempfile.mkstemp(prefix=".wardrobe-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(payload, handle, indent=1)
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(directory, CACHE_NAME))
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def cached_prompt(avatar_dir):
    """The stored tailored brief, or None. Never calls a model."""
    try:
        return _read_cache(avatar_dir, _digest(_identity_reference(avatar_dir)))
    except Exception:
        return None


def tailored_prompt(avatar_dir, refresh=False, log=None):
    """Portrait-specific art direction, falling back to the static preset."""
    def note(message):
        if log:
            log(message)

    try:
        reference = _identity_reference(avatar_dir)
        digest = _digest(reference)
    except Exception as error:
        return {"prompt": preset_prompt(), "source": "preset",
                "traits": {}, "error": str(error)[:300]}

    if not refresh:
        cached = _read_cache(avatar_dir, digest)
        if cached:
            return cached

    try:
        route, model = _llm_route()
        direction, traits = _parse(_chat(route, model, _encoded_reference(reference)))
        prompt = _finalise(
            direction, traits.get("presentation"), traits.get("medium"))
    except Exception as error:
        note(f"portrait-tailored prompt unavailable, using the preset: {error}")
        return {"prompt": preset_prompt(), "source": "preset",
                "traits": {}, "error": str(error)[:300]}

    payload = {
        "version": CACHE_VERSION,
        "digest": digest,
        "prompt": prompt,
        "traits": traits,
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    try:
        _write_cache(avatar_dir, payload)
    except Exception:
        pass
    note("composed a portrait-tailored full-body prompt")
    return {"prompt": prompt, "source": "tailored", "traits": traits, "cached": False}
