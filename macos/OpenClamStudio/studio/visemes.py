"""Viseme catalog + prompt construction.

Three lessons are baked into these prompts:

1.  POSE.  gpt-image-2 draws mouths on a FRONTAL prior, so a turned keyframe
    yields mouths in the wrong perspective.  Build avatars from a front-facing
    source; `pose_clause()` states the measured pose so a turned one degrades
    gracefully.

2.  PLACE OF ARTICULATION.  Naming only the letter produced tongue errors - the
    model drew a TH/L tongue for alveolar D and N.  Every prompt names the
    articulator position AND names the wrong shape to exclude.  Naming the shape
    to exclude is what stopped it.

3.  AMPLITUDE.  Textbook articulation descriptions describe CITATION FORM - a
    phoneme pronounced in isolation for a phonetics class.  Fed to an image
    model they produce a face that is shouting: the first pass measured an AH
    aperture of 0.56 of mouth width, where relaxed conversation is ~0.22, and an
    FF that bared teeth like a snarl instead of gently tucking the lip.  So the
    amplitude governor below is stated up front, and every shape carries an
    explicit opening measured against a feature the model can actually see -
    the thickness of the subject's own lower lip.  `TARGETS` holds the same
    numbers for the QA pass, so the prompt and the verifier cannot drift apart.
"""

PHOTO_HEADWEAR_STATE_LOCK = (
    "HEADWEAR STATE LOCK - preserve the exact canonical headwear state shown "
    "in the input photograph. If the subject wears a hat, cap, bandana, "
    "headband, headscarf, helmet, crown, tiara, hair ornament, or other "
    "head-attached item, keep its exact shape, placement, scale, angle, "
    "material, colors, markings, and relationship to the hair. If the subject "
    "is bare-headed, keep the subject bare-headed. Do not add, remove, replace, "
    "redesign, recolor, resize, or reposition any headwear.\n\n"
)


BASE = (
    "Edit this portrait photograph. This is a LIP-SYNC SPEECH SHAPE (viseme) frame "
    "for a talking-head animation, so the ONLY thing that may change is natural "
    "speech articulation below the eyes: lips, mouth, jaw, chin, philtrum, mouth "
    "corners, adjacent lower-cheek tissue and nasolabial folds.\n\n"
    "ABSOLUTELY UNCHANGED, pixel for pixel: the person's identity and facial bone "
    "structure, head position, head angle, head size, camera framing and distance, "
    "crop, eyes, eyebrows, eyelids, gaze direction, nose, ears, hairline, hair, "
    "jewellery, clothing, neckline, shoulders, skin tone, freckles, makeup, "
    "lighting direction, shadows, colour grade and background.\n\n"
    "DO NOT re-frame, re-crop, zoom, rotate, re-pose, re-light or re-render the "
    "image. DO NOT beautify, smooth or retouch the skin. Do not add an emotion or "
    "a smile; permit only the subtle lower-face muscle movement physically caused "
    "by the requested sound. Keep photographic realism with visible skin texture "
    "and pores.\n\n"
) + PHOTO_HEADWEAR_STATE_LOCK

AMPLITUDE = (
    "AMPLITUDE - THE SINGLE MOST IMPORTANT CONSTRAINT:\n"
    "This is QUIET CONVERSATIONAL SPEECH at close range - the small, efficient, "
    "almost lazy mouth movement of a composed adult talking calmly to one person "
    "sitting across a desk. It is NOT singing, NOT shouting, NOT calling out, NOT "
    "stage or theatrical diction, and NOT an exaggerated phonetics-textbook diagram "
    "of the sound. The jaw barely moves. The lips move a few millimetres, not "
    "centimetres. Her expression stays calm and composed throughout - no grimace, "
    "no snarl, no baring of the teeth and no exaggerated strain. The cheeks and "
    "chin may move subtly when the jaw or mouth corners physically pull them.\n"
    "Keep the change SMALL and UNDERSTATED. If you are unsure, make it SMALLER. An "
    "over-articulated mouth looks like the person is yelling and is a failure.\n\n"
    "BUT THERE IS A FLOOR - small does not mean closed. Unless this shape is "
    "explicitly a closed-lip shape, the mouth must stay clearly DISTINGUISHABLE "
    "from the closed resting mouth: its defining feature - the gap, the teeth "
    "contact, the rounding, the slit - must be visible at a glance. Shrink the "
    "movement; never delete it.\n\n"
)

FACIAL_COUPLING = (
    "LOWER-FACE MUSCLE COUPLING - AVOID THE PASTED-ON MOUTH LOOK:\n"
    "Do not animate an isolated oval around the lips. Let each mouth corner pull "
    "the immediately adjacent cheek tissue; let jaw opening move the chin and "
    "lower-cheek volume; let spreading or rounding shift the philtrum and nearby "
    "nasolabial folds by a tiny anatomically plausible amount. Closed bilabial "
    "shapes should produce almost no cheek motion; open and rounded vowels may "
    "produce more, but still at quiet-conversation scale. Keep all motion below "
    "the lower eyelids. The eyes, brows, nose bridge and overall emotion remain "
    "unchanged. Preserve pores, freckles and fold texture rather than smoothing "
    "or redrawing the skin.\n\n"
)

DENTAL_CONTINUITY = (
    "DENTAL CONTINUITY - FIXED ANATOMY:\n"
    "Her UPPER AND LOWER dental rows are equally identity-bearing fixed anatomy. "
    "Across every mouth shape, preserve the SAME tooth count, incisor widths, spacing, "
    "edge contours, natural ivory colour and tiny individual irregularities in BOTH "
    "rows. The upper row is rigidly attached to the skull and stays fixed on screen. "
    "The lower row is rigidly attached to the moving jaw and may move only as one unit "
    "with that jaw; individual lower teeth must never slide, scale, tilt or regenerate. "
    "Only the lips and jaw change how much of either row is revealed. Do not hide a "
    "naturally visible lower incisal edge in shadow, but do not force teeth into a "
    "closed-lip shape or invent extras. Preserve the reference enamel exactly: DO NOT "
    "whiten, brighten, bleach, recolour or make either row unnaturally uniform.\n\n"
)

ORAL_RENDERING = (
    "ORAL SHADING - NATURAL, SOFT AND LOW-CONTRAST:\n"
    "Do not draw or trace a dark line along the inner lip contour. Do not add black "
    "outlines around the lips, teeth or gums. Define every boundary with soft natural "
    "tonal transitions, not ink-like edges. The visible oral interior is softly lit "
    "warm rose or muted burgundy, never black, charcoal or a flat dark fill. Keep any "
    "rear-mouth shadow small and graduated. When both dental rows are visible, their "
    "meeting slit is a soft low-contrast occlusion, never a dark horizontal stripe. "
    "Keep visible lower incisors clean and naturally ivory rather than merging them "
    "into the cavity shadow.\n\n"
)

CLOSER = ("\n\nRender only that anatomically coupled lower-face articulation, at "
          "the small conversational scale described above. Everything else in the "
          "frame must be identical to the input image.")
BLINK_CLOSER = ("\n\nRender only that relaxed blink. Everything else in the frame must "
                "be identical to the input image.")

# Illustration edits need a genuinely separate rendering contract. Adding a
# short "keep the style" suffix to the photographic prompt is not sufficient:
# the photo contract explicitly asks for pores, natural enamel, soft tonal
# boundaries and no ink-like edges. Those instructions make an image model
# repaint anime, comic and toon-rendered faces even when the final sentence
# asks it not to. The articulation descriptions below remain shared; these
# blocks change only the medium, identity and rendering rules around them.
STYLIZED_BASE = (
    "Edit this illustrated character head. This is a LIP-SYNC SPEECH SHAPE "
    "(viseme) frame for a talking-head animation, so the ONLY thing that may "
    "change is the requested speech articulation below the eyes: lips, mouth, "
    "jaw, chin, mouth corners and the immediately connected lower-cheek shapes.\n\n"
    "ABSOLUTELY UNCHANGED: the character identity, face silhouette and "
    "proportions, head position, head angle, head size, camera framing and "
    "distance, crop, eyes, eyebrows, eyelids, gaze, nose, ears, hairline, hair, "
    "identity-bearing headwear and accessories, neck and shoulders, lighting "
    "and background. Preserve the source medium, linework, line weight, edge "
    "treatment, palette, color fills, texture and shading language exactly.\n\n"
    "DO NOT re-frame, re-crop, zoom, rotate, re-pose, re-light, beautify, "
    "smooth, restyle or redraw the character. Do not convert the illustration "
    "to another medium and do not add realistic surface detail absent from the "
    "source. Do not add an emotion or a smile; permit only the subtle "
    "lower-face movement required by the requested sound.\n\n"
)

STYLIZED_AMPLITUDE = (
    "AMPLITUDE - THE SINGLE MOST IMPORTANT CONSTRAINT:\n"
    "This is QUIET CONVERSATIONAL SPEECH at close range, with small and "
    "efficient mouth movement. It is NOT singing, shouting, stage diction or "
    "an exaggerated pronunciation diagram. The jaw barely moves and the "
    "character's neutral expression stays unchanged: no grimace, snarl, "
    "bared-teeth emotion or strain. Keep the change SMALL and UNDERSTATED. If "
    "unsure, make it smaller.\n\n"
    "BUT THERE IS A FLOOR - unless this is explicitly a closed-lip shape, its "
    "defining gap, tooth contact, rounding or slit must remain distinguishable "
    "from the closed resting mouth. Shrink the movement; never delete it.\n\n"
)

STYLIZED_FACIAL_COUPLING = (
    "CONNECTED LOWER-FACE DESIGN - AVOID A PASTED-ON MOUTH:\n"
    "Do not replace an isolated oval around the lips. Let the mouth corners, "
    "jaw, chin and immediately adjacent lower-cheek shapes move together by "
    "the smallest amount the source design supports. Keep every change below "
    "the lower eyelids. Preserve simplified geometry when the source is "
    "simplified; do not invent folds, wrinkles, gradients or texture that the "
    "illustration does not use.\n\n"
)

STYLIZED_DENTAL_CONTINUITY = (
    "MOUTH-DESIGN CONTINUITY - FIXED CHARACTER ART:\n"
    "Preserve the character's established teeth, tongue, lip and oral-interior "
    "design across every mouth shape. If teeth are individual shapes, keep the "
    "same count, spacing, palette and outlines; if they are a simplified band "
    "or block, keep that same simplification. The lower teeth move only with "
    "the jaw. Do not invent extra teeth, gums, tongue detail, highlights or "
    "realistic dental anatomy absent from the reference.\n\n"
)

STYLIZED_ORAL_RENDERING = (
    "SOURCE-MEDIUM ORAL RENDERING:\n"
    "Render the lips, teeth, tongue and mouth interior with the exact graphic "
    "vocabulary already present in the input. Preserve its linework, flat or "
    "graded fills, edge softness, palette and level of detail. A dark cavity, "
    "hard contour or simplified tooth band is correct when the source uses it; "
    "do not replace those choices with a different rendering style.\n\n"
)

STYLIZED_CLOSER = (
    "\n\nRender only that connected lower-face articulation at the small "
    "conversational scale described above. Any anatomical color or shading "
    "wording describes placement only; the source illustration's own palette, "
    "linework and rendering language always control the final pixels. Everything "
    "else in the frame must remain identical to the input image."
)

STYLIZED_BLINK_PROMPT = (
    "Edit this illustrated character head. This is a BLINK frame for a "
    "talking-head animation, so the ONLY thing that may change is the eyes.\n\n"
    "Close BOTH EYELIDS FULLY in a relaxed blink, using the character's existing "
    "eyelid, lash, line and shading design. Preserve the established eye size, "
    "spacing and angle. Do not squeeze the eyes, wrinkle the nose, move the "
    "eyebrows or invent crease detail absent from the source.\n\n"
    "ABSOLUTELY UNCHANGED: the mouth and lips, character identity and face "
    "silhouette, head pose and size, framing, crop, eyebrows, nose, ears, hair, "
    "identity-bearing headwear and accessories, neck and shoulders, lighting "
    "and background. Preserve the source medium, linework, line weight, edge "
    "treatment, palette, fills, texture and shading language exactly. Do not "
    "re-frame, re-pose, re-light, retouch, restyle or convert the illustration "
    "to another medium."
    "\n\nRender only that relaxed blink. Everything else in the frame must be "
    "identical to the input image."
)

# name -> (phoneme group, articulation, opening spec)
# The opening is expressed against the subject's own lower lip thickness, which
# is a feature the model can see in the reference; absolute units mean nothing to it.
SHAPES = {
 "closed": ("rest / silence",
    "Lips gently and naturally CLOSED in a relaxed neutral rest position, a soft "
    "natural lip seam. Jaw closed. No teeth and no tongue visible. The lips must NOT "
    "be pressed hard or compressed - that is the P/B/M shape, not this one.",
    "No gap at all between the lips."),

 "PP": ("p, b, m",
    "Lips closed together for the consonant P/B/M, the lip line very slightly "
    "compressed and a touch flatter than at rest. Jaw closed. No teeth, no tongue, "
    "no opening whatsoever.",
    "No gap at all. The compression is SUBTLE - just perceptibly firmer than the "
    "resting mouth, with no hard tension ridge, no white pressure marks and no "
    "rolling of the lips inward."),

 "FF": ("f, v",
    "Labiodental F/V: the LOWER LIP comes up to rest LIGHTLY AGAINST THE EDGE OF THE "
    "UPPER FRONT TEETH. Only the very bottom edge of the upper front teeth touches the "
    "lower lip - a soft contact, as in the quiet 'f' of the word 'often'. The tongue is "
    "NOT visible. The lips must NOT be rounded.",
    "The visible gap is a HAIRLINE - about one tenth of her lower lip's thickness. "
    "CRITICAL: the mouth must NOT be pulled wide, the upper lip must NOT curl or lift "
    "to expose the gum line, and the teeth must NOT be bared. This is a soft, almost "
    "closed mouth - it must not look like a snarl, a sneer or an angry word."),

 "TH": ("th",
    "Interdental TH: the very TIP OF THE TONGUE shows as a small flat pink sliver "
    "BETWEEN THE UPPER AND LOWER FRONT TEETH, only just reaching the lip line. This is "
    "the ONLY shape where the tongue reaches the lips. The tongue must stay centred, "
    "must NOT loll out onto the lower lip and must NOT curl to either side.",
    "The lips part by about ONE THIRD of her lower lip's thickness - a small gap. Only "
    "a sliver of tongue shows; the jaw stays nearly closed."),

 "DD": ("d, t",
    "Alveolar consonant D/T: the TONGUE TIP IS PRESSED UP AGAINST THE RIDGE BEHIND THE "
    "UPPER FRONT TEETH so the tongue is HIDDEN INSIDE THE MOUTH. A small softly "
    "shadowed warm gap and the edge of the upper teeth show. The tongue must NOT "
    "protrude, must NOT rest on "
    "the lower lip, must NOT cross the lip line and must NOT lean to either side. This "
    "is NOT a TH shape and NOT an L shape.",
    "The lips part by about ONE THIRD of her lower lip's thickness. Jaw almost closed."),

 "nn": ("n, l",
    "Alveolar nasal N: the TONGUE TIP IS PRESSED UP ON THE RIDGE BEHIND THE UPPER FRONT "
    "TEETH and is HIDDEN INSIDE THE MOUTH. The tongue must NOT protrude past the teeth, "
    "must NOT rest on the lower lip and must NOT curl sideways. NOT a TH shape, NOT an L.",
    "The lips are barely parted - about one fifth of her lower lip's thickness, just "
    "enough to read as open. Jaw effectively closed."),

 "kk": ("k, g",
    "Velar K/G: the BACK of the tongue rises toward the soft palate deep inside the "
    "mouth while the TONGUE TIP RESTS LOW BEHIND THE LOWER FRONT TEETH and is not "
    "visible at the lip line. Lips neutral, neither spread nor rounded.",
    "The lips part by a little under HALF her lower lip's thickness - a small relaxed "
    "oval. The jaw must NOT drop."),

 "CH": ("ch, j, sh",
    "Postalveolar CH/SH/J: lips eased slightly FORWARD into a small soft rounded "
    "opening, teeth close together behind them, the tongue bunched high and completely "
    "hidden. The lips must NOT be spread sideways.",
    "The lips part by about ONE FIFTH of her lower lip's thickness. The forward push is "
    "SLIGHT - the mouth stays about nine tenths of its normal width. Do NOT pucker "
    "strongly and do NOT drop the jaw."),

 "SS": ("s, z",
    "Sibilant S/Z: the TEETH ARE ALMOST TOUCHING behind lips that are only just parted, "
    "showing a NARROW HORIZONTAL SLIT with the upper and lower front teeth nearly "
    "together behind it. The tongue is completely HIDDEN behind the teeth.",
    "The gap is a HAIRLINE - about one tenth of her lower lip's thickness. The jaw must "
    "NOT drop, the lips must NOT stretch wide, and NO tongue may be visible."),

 "RR": ("r",
    "American R: lips very slightly rounded with a small opening, corners drawn a little "
    "inward, the tongue BUNCHED AND RETRACTED in the middle of the mouth, touching "
    "nothing and not visible. This must NOT be a round OH shape and must NOT be a tight "
    "kiss-like OO.",
    "The lips part by about ONE FIFTH of her lower lip's thickness. The rounding is "
    "gentle - the mouth stays about nine tenths of its normal width."),

 "ah": ("a as in father",
    "Open vowel AH: the jaw eases down into a soft open oval, lips relaxed and neither "
    "spread nor pursed, the edge of the upper front teeth just visible at the top of the "
    "opening. The tongue is completely hidden below and behind the lower front teeth: "
    "NO tongue surface, tip, or side may be visible anywhere in the opening.",
    "THIS IS THE WIDEST SHAPE IN THE WHOLE SET AND IT IS STILL SMALL. The lips part by "
    "roughly the THICKNESS OF HER LOWER LIP and NO MORE - the relaxed 'ah' of ordinary "
    "conversation, not a yawn, not a shout, not an open-wide-for-the-doctor mouth. The "
    "chin must barely drop and the cheeks must stay relaxed."),

 "eh": ("e as in bed",
    "Mid vowel EH: jaw slightly open, lips very slightly spread horizontally, the edge "
    "of the upper front teeth visible, with the tongue fully hidden behind the lower "
    "teeth. Not as open as AH, not as "
    "spread as EE.",
    "The lips part by about HALF her lower lip's thickness - roughly half the AH "
    "opening. The spreading is barely perceptible."),

 "ih": ("i as in sit / ee",
    "Close front vowel IH/EE: lips slightly spread horizontally, jaw barely open so the "
    "teeth stay close together, a narrow slit with the upper teeth just showing. The lips "
    "must NOT be rounded.",
    "The lips part by about ONE THIRD of her lower lip's thickness. The spread is SLIGHT "
    "- the mouth is only a fraction wider than neutral. Do NOT stretch it into a grin, do "
    "NOT tense the mouth corners and do NOT expose the gums."),

 "oh": ("o as in go",
    "Rounded vowel OH: lips softly ROUNDED, eased a little forward, the opening slightly "
    "taller than it is wide, the inside of the mouth softly shadowed warm rose rather "
    "than black.",
    "The lips part by about TWO THIRDS of her lower lip's thickness. The rounding is "
    "MODERATE - the mouth stays about 85 percent of its normal width. Do NOT pinch it "
    "into a small tight circle and do NOT drop the jaw."),

 "oo": ("u as in boot / w",
    "Close rounded vowel OO/W: lips gently pursed into a small soft round shape and eased "
    "forward. Smaller and more forward than the OH shape.",
    "The opening is small - about one tenth of her lower lip's thickness. The purse is "
    "GENTLE: the mouth stays about four fifths of its normal width. Do NOT pinch the lips "
    "into a tiny kiss, do NOT hollow the cheeks and do NOT push the lips far forward."),

 "blink": ("eye blink", "__BLINK__", ""),
}

# QA targets: (max aperture / mouth-width ratio, expected width vs neutral).
# Same numbers the prompts describe, so the verifier and the prompt agree.
TARGETS = {
 "closed": (0.03, 1.00), "PP": (0.03, 0.98), "FF": (0.06, 1.00),
 "TH":  (0.09, 1.00), "DD": (0.09, 1.00), "nn": (0.06, 1.00),
 "kk": (0.11, 1.00), "CH": (0.08, 0.90), "SS": (0.06, 1.00),
 "RR":  (0.07, 0.90), "ah": (0.24, 0.97), "eh": (0.14, 1.00),
 "ih":  (0.10, 1.03), "oh": (0.17, 0.85), "oo": (0.06, 0.82),
 "blink": (0.03, 1.00),
}


# Pass-3 calibration: pass 2 undershot these six. Same conversational scale,
# raised just far enough that each shape stays legible next to the closed mouth.
OPENING_OVERRIDE = {
 'FF': (
    "The gap stays small - about one fifth of her lower lip's thickness - but THE "
    "EDGE OF THE UPPER FRONT TEETH MUST BE VISIBLE resting on the lower lip, or the "
    "shape is indistinguishable from a closed mouth. The mouth must NOT be pulled "
    "wide, the upper lip must NOT curl up to expose the gum line, and the teeth must "
    "NOT be bared - no snarl, no sneer, no anger."),
 'SS': (
    "The lips part just enough to show a NARROW HORIZONTAL SLIT with the white edges "
    "of the upper and lower front teeth VISIBLE behind it - about one fifth of her "
    "lower lip's thickness. The slit must be clearly visible; do not close the mouth. "
    "The jaw must NOT drop and NO tongue may show."),
 'kk': (
    "The lips part by about ONE THIRD of her lower lip's thickness into a small "
    "relaxed oval with a clear softly shadowed warm opening behind it. Small, but "
    "unmistakably open. The jaw must NOT drop far."),
 'ah': (
    "This is the WIDEST shape in the set, so it must read as clearly open - while "
    "still being a conversational opening, never a yawn or a shout. The lips part by "
    "about THREE QUARTERS of the thickness of her lower lip, showing the edge of the "
    "upper front teeth and a softly lit warm oral space below. The chin drops only "
    "slightly; nearby lower-cheek tissue follows the jaw without strain."),
 'eh': (
    "The lips part by about HALF her lower lip's thickness - clearly less open than "
    "AH, but clearly MORE open than the narrow EE/IH shape. The edge of the upper "
    "teeth shows. The horizontal spread is barely perceptible."),
 'oh': (
    "The lips part by about HALF her lower lip's thickness into a clearly ROUNDED "
    "opening - the rounding must be obvious at a glance. The mouth stays about 85 "
    "percent of its normal width. Do NOT pinch it into a small tight circle and do "
    "NOT drop the jaw."),
}

BLINK_PROMPT = (
    "Edit this portrait photograph. This is a BLINK frame for a talking-head "
    "animation, so the ONLY thing that may change is the eyes.\n\n"
    "Close BOTH EYELIDS FULLY and naturally, as in the middle of a relaxed blink - "
    "smooth closed lids, the lash line resting on the lower lid, a natural soft "
    "eyelid crease. Do not squeeze the eyes shut, do not wrinkle the nose, do not "
    "raise or lower the eyebrows.\n\n"
    "ABSOLUTELY UNCHANGED, pixel for pixel: the mouth and lips, identity and facial "
    "bone structure, head position, head angle, head size, camera framing, crop, "
    "eyebrows, nose, ears, hair, jewellery, clothing, shoulders, skin tone, freckles, "
    "makeup, lighting, colour grade and background. Do not re-frame, re-pose, "
    "re-light or retouch. Keep photographic realism with visible skin texture.\n\n"
    + PHOTO_HEADWEAR_STATE_LOCK + BLINK_CLOSER)

ORDER = ["closed", "PP", "FF", "TH", "DD", "nn", "kk", "CH", "SS", "RR",
         "ah", "eh", "ih", "oh", "oo", "blink"]
SPEECH_ORDER = [name for name in ORDER if name != "blink"]

EYE_SHAPES = {"blink"}


def pose_clause(yaw, roll):
    if yaw is None:
        return ""
    if abs(yaw) < 6 and abs(roll) < 6:
        return ("The head faces the camera STRAIGHT ON, perfectly frontal and level. "
                "Draw the mouth SYMMETRICALLY about the vertical midline, with both "
                "mouth corners the same distance from the centre of the philtrum.\n\n")
    side = "her left" if yaw > 0 else "her right"
    return (f"IMPORTANT: the head is TURNED about {abs(yaw):.0f} degrees toward {side} "
            f"and tilted about {abs(roll):.0f} degrees. The mouth must be drawn in that "
            f"same perspective - foreshortened toward the far cheek, NOT symmetric and "
            f"NOT straight-to-camera.\n\n")


def stylized_pose_clause(yaw, roll):
    """Pose wording for characters without assuming gender or realism."""
    if yaw is None:
        return ""
    if abs(yaw) < 6 and abs(roll) < 6:
        return ("The head faces the camera STRAIGHT ON, perfectly frontal and level. "
                "Draw the mouth SYMMETRICALLY about the vertical midline, with both "
                "mouth corners the same distance from the centre of the philtrum.\n\n")
    side = "the character's left" if yaw > 0 else "the character's right"
    return (f"IMPORTANT: the head is TURNED about {abs(yaw):.0f} degrees toward "
            f"{side} and tilted about {abs(roll):.0f} degrees. Draw the mouth in "
            f"that same illustrated perspective - foreshortened toward the far "
            f"cheek, NOT symmetric and NOT straight-to-camera.\n\n")


def _is_stylized_medium(source_medium):
    value = str(source_medium or "photo").strip().lower()
    # Intake normalises rendered/cartoon-like sources to these labels.  They
    # are not photographs: routing them through the photographic prompt asks
    # the provider to invent pores, realistic eyelids and realistic dental
    # texture.  That produced Luffy's pasted-looking mouth and a tiny made-up
    # blink inside his established oversized eyes.  Keep this list aligned
    # with export._STYLIZED_SOURCE_MEDIA while accepting descriptive suffixes
    # such as "3d render / game character".
    if value.startswith(("3d render", "3d-render", "soft-3d",
                         "game art", "game-art")):
        return True
    return value.startswith((
        "stylized", "illustration", "illustrated", "cartoon", "anime",
        "comic", "drawing", "drawn", "painting", "painted", "toon"))


def _stylized_articulation(text):
    """Remove photo- and gender-specific wording from shared mouth geometry."""
    replacements = (
        ("A small softly shadowed warm gap", "A small source-style oral gap"),
        ("her lower lip's thickness", "the character's own lower-lip thickness"),
        ("HER LOWER LIP", "THE CHARACTER'S OWN LOWER LIP"),
        ("her lower lip", "the character's own lower lip"),
        ("a small softly shadowed warm gap", "a small source-style oral gap"),
        ("a clear softly shadowed warm opening", "a clear source-style opening"),
        ("a softly lit warm oral space", "an oral space drawn in the source style"),
        ("softly shadowed warm rose rather than black",
         "drawn with the source illustration's existing oral-interior palette"),
    )
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def _medium_neutral_contract(text):
    """Remove illustration assumptions while retaining medium preservation."""
    replacements = (
        ("Edit this illustrated character head", "Edit this supplied face image"),
        ("FIXED CHARACTER ART", "FIXED SOURCE DESIGN"),
        ("exact graphic vocabulary", "exact visual vocabulary"),
        ("same illustrated perspective", "same source perspective"),
        ("Draw the mouth", "Render the mouth"),
        ("THE CHARACTER'S OWN", "THE SUBJECT'S OWN"),
        ("the character's own", "the subject's own"),
        ("the character's", "the subject's"),
        ("the character", "the subject"),
        ("character identity", "subject identity"),
        ("character's", "subject's"),
        ("character", "subject"),
        ("source illustration's", "source image's"),
        ("source illustration", "source image"),
        ("illustration's", "image's"),
        ("illustration", "image"),
    )
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def _preserve_medium_prompt(name, yaw=None, roll=None):
    """Use a style-agnostic contract when local evidence is inconclusive."""
    if name in EYE_SHAPES:
        return _medium_neutral_contract(STYLIZED_BLINK_PROMPT)
    group, desc, opening = SHAPES[name]
    opening = OPENING_OVERRIDE.get(name, opening)
    desc = _stylized_articulation(desc)
    opening = _stylized_articulation(opening)
    prompt = (STYLIZED_BASE + STYLIZED_AMPLITUDE
              + STYLIZED_FACIAL_COUPLING + STYLIZED_DENTAL_CONTINUITY
              + STYLIZED_ORAL_RENDERING
              + stylized_pose_clause(yaw, roll)
              + f"MOUTH SHAPE TO RENDER - viseme '{name}' ({group}):\n"
              + f"{desc}\n\nHOW FAR THE MOUTH OPENS:\n{opening}"
              + STYLIZED_CLOSER)
    return _medium_neutral_contract(prompt)


def prompt_for(name, yaw=None, roll=None, source_medium="photo"):
    """Return a medium-aware edit prompt with canonical headwear locked.

    ``generate.generate_one`` includes the final prompt in its cache digest, so
    adding the photo headwear-state contract intentionally invalidates legacy
    photo plates that could silently lose or invent headwear. The stylized path
    already carries its own identity-bearing headwear lock.
    """
    medium = str(source_medium or "unknown").strip().lower()
    if medium in {"unknown", "uncertain", "preserve"}:
        return _preserve_medium_prompt(name, yaw, roll)
    if _is_stylized_medium(medium):
        if name in EYE_SHAPES:
            return STYLIZED_BLINK_PROMPT
        group, desc, opening = SHAPES[name]
        opening = OPENING_OVERRIDE.get(name, opening)
        desc = _stylized_articulation(desc)
        opening = _stylized_articulation(opening)
        return (STYLIZED_BASE + STYLIZED_AMPLITUDE
                + STYLIZED_FACIAL_COUPLING + STYLIZED_DENTAL_CONTINUITY
                + STYLIZED_ORAL_RENDERING
                + stylized_pose_clause(yaw, roll)
                + f"MOUTH SHAPE TO RENDER - viseme '{name}' ({group}):\n"
                + f"{desc}\n\nHOW FAR THE MOUTH OPENS:\n{opening}"
                + STYLIZED_CLOSER)

    # Keep the photographic rendering contract separate from the stylized
    # blocks. Its output is part of the photo-render cache signature.
    if name in EYE_SHAPES:
        return BLINK_PROMPT
    group, desc, opening = SHAPES[name]
    opening = OPENING_OVERRIDE.get(name, opening)
    return (BASE + AMPLITUDE + FACIAL_COUPLING + DENTAL_CONTINUITY + ORAL_RENDERING
            + pose_clause(yaw, roll)
            + f"MOUTH SHAPE TO RENDER - viseme '{name}' ({group}):\n{desc}\n\n"
            + f"HOW FAR THE MOUTH OPENS:\n{opening}" + CLOSER)
