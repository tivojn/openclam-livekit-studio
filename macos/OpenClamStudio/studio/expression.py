"""Micro-expression layers synthesised from the keyframe alone.

A face whose mouth and eyelids move while everything else is frozen does not
read as alive - it reads as a corpse being puppeteered, and the strongest single
cause is the DEAD STARE.  Real eyes never hold still: they micro-saccade a few
times a second, drift between fixations, and look away when their owner is
thinking.  Second cause is the frozen brow: humans raise and knit their brows
constantly while speaking, and a brow that never moves over a mouth that does is
profoundly wrong.

Neither needs a generated image.  Both are small, local deformations of tissue
that is already in the keyframe:

  gaze - the iris is a rigid disc sliding across a featureless white sclera.
         Warp it: displacement is constant inside the iris and decays to zero
         before the lid margins, so the iris translates rigidly, the sclera
         compresses on one side and stretches on the other (invisible - it has
         no texture to betray it), and the lids do not move at all.

  brow  - a slab of skin that slides vertically, dragging the lid skin below it
         and fading out into the forehead above.  Raises are arch-weighted;
         lowers are weighted to the medial end and pull slightly inward, which
         is what corrugator actually does.

The forehead, cheek and infraorbital bands are separate feathered tissue layers.
They bake to small RGBA sprite strips, like the eyelids in blink.py.  Runtime
interpolates adjacent tissue states instead of snapping between them.  A
viseme-indexed smile strip moves each photographed mouth as one piece, keeping
the tongue, teeth and lips coherent while smile/laughter lifts both corners
without widening the mouth. Draw order is base -> smile -> forehead -> brow -> cheek -> gaze
-> under-eye -> lid.
"""
import numpy as np, cv2
from . import face
from .blink import EYE, BROW, SIDES, UPPER, LOWER, _line, _box

IRIS = {"r": 468, "l": 473}                       # refined-landmark iris centres
IRIS_RING = {"r": [469, 470, 471, 472], "l": [474, 475, 476, 477]}
NOSE_X = 1                                        # nose tip: tells medial from lateral

# The resting gaze is locked to the lens, and the counter-rotation that holds
# that lock while the head moves is under a pixel and a half - one degree of
# eye rotation is only ~0.73px on this face.  So the CENTRE of the grid stays
# small and fine, quarter-pixel pitch, and the runtime snaps to the nearest
# state instead of blending: at that pitch the quantisation is invisible and
# the limbus is never cross-dissolved with itself.
#
# The FLANKS exist for directed attention - the eyes following the cursor.
# A glance that reads as "looking left" needs the iris to actually travel the
# sclera, several pixels, not a micro-tremor.  Out there the pitch coarsens:
# a directed glance is a saccade, and saccades jump.
GAZE_DX = ([-9.0, -7.5, -6.0, -4.8, -3.6, -2.4] +
           [round(-1.5 + 0.25 * i, 3) for i in range(13)] +
           [2.4, 3.6, 4.8, 6.0, 7.5, 9.0])                    # +-9px
GAZE_DY = [-3.5, -2.5, -1.5, -0.75, -0.375, 0.0, 0.375, 0.75, 1.5, 2.5, 3.5]
# Brow offsets, negative = knitted.  Subtle-anchor range, not big acting: half a
# pixel apart so the runtime can snap here too rather than ghost the brow hair.
# Dense near neutral for idle micro-motion, then real reach: a human brow
# raise is ~8-14px at this scale, and the old +3.5px ceiling was measured
# live (2026-08-01) as imperceptible - the whole upper face read as frozen
# however hard the runtime gestured.
BROW_DY = [-5.0, -3.5, -2.0, -1.0, 0.0, 0.75, 1.5, 2.5, 4.0, 6.0,
           8.0, 10.0, 12.0, 14.0]
# The second brow axis: horizontal set, in px toward the nose. Negative
# spreads the brows apart, positive squeezes them into a light furrow -
# so the pair can knit or open independently of the raise.
BROW_SQ = [-3.0, 0.0, 4.0]
# Cheek raise, in px of lift at the lower lid margin.  Small on purpose - this
# is the warmth cue that rides under speech, not a smile.
CHEEK_UP = [0.0, 0.8, 1.6, 2.45, 3.3]
# Smile/laughter is not an eyelid or cheek pose. These states add only
# lip-corner lift (AU12) while preserving each viseme's width and aperture.
# The spoken smile target is exactly .18. Publish that exact photographic
# state so a held smile is one sharp plate rather than a permanent cross-fade
# between neutral and .34 (which ghosts the lip edge and reads as blur).
SMILE_STATES = [0.0, 0.18, 0.34, 0.68, 1.0]
EMOTION_MOUTH_STATES = [0.0, 0.34, 0.68, 1.0]
EMOTION_MOUTHS = ("sorrow", "horror", "anger")


def neck(lm):
    """Where the head pivots on the neck, in keyframe px.

    Idle head movement is the head turning ON THE NECK, so it has to TAPER: the
    crown swings furthest, the chin much less, the shoulders barely at all.
    Translating the whole frame instead - head, shoulders, jacket, backdrop as
    one block - is what makes a talking head look stiff-necked; it reads as the
    camera moving, and a nod is not a nod if the shoulders come with it.

    Because a rigid rotation about a pivot is LINEAR in y, that taper is an
    affine transform: one draw call, no bands, no seams, and the foreshortening
    of a nod (chin moves less than brow, so the face shortens) falls out of it
    for free.  `ref` is where the taper equals 1 - the eyes, since the gaze
    counter-rotation is derived at exactly that height.
    """
    chin = float(lm[face.CHIN][:, 1].max())
    top = float(lm[face.FACE_OVAL][:, 1].min())
    eye = float(0.5 * (lm[IRIS["r"]][1] + lm[IRIS["l"]][1]))
    return dict(ref=round(eye, 1),
                pivot=round(chin + 0.38 * (chin - top), 1),
                x=round(float(lm[NOSE_X][0]), 1))


def _smoothstep(a, b, x):
    t = np.clip((x - a) / max(b - a, 1e-6), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# ---- laughter mouth -------------------------------------------------------

def _smile_box(shape, lm):
    """One stable mouth patch shared by every viseme row in the atlas."""
    H, W = shape[:2]
    left = np.asarray(lm[face.MOUTH_L], np.float32)
    right = np.asarray(lm[face.MOUTH_R], np.float32)
    width = max(float(np.linalg.norm(right - left)), 8.0)
    centre = 0.5 * (left + right)
    x0 = max(0, int(np.floor(centre[0] - .82 * width)))
    x1 = min(W, int(np.ceil(centre[0] + .82 * width)))
    y0 = max(0, int(np.floor(centre[1] - .43 * width)))
    y1 = min(H, int(np.ceil(centre[1] + .48 * width)))
    return [x0, y0, max(1, x1 - x0), max(1, y1 - y0)]


def _mouth_warp_patch(image, lm, amount, box, controls):
    """Apply one coherent four-anchor deformation to a photographed viseme."""
    x0, y0, bw, bh = [int(v) for v in box]
    left = np.asarray(lm[face.MOUTH_L], np.float32)
    right = np.asarray(lm[face.MOUTH_R], np.float32)
    width = max(float(np.linalg.norm(right - left)), 8.0)
    centre = 0.5 * (left + right)
    xs = np.arange(x0, x0 + bw, dtype=np.float32)
    ys = np.arange(y0, y0 + bh, dtype=np.float32)
    gx, gy = np.meshgrid(xs, ys)
    dx = np.zeros((bh, bw), np.float32)
    dy = np.zeros((bh, bw), np.float32)
    for point, move_x, move_y, sigma in controls:
        weight = np.exp(-.5 * (((gx - point[0]) / max(sigma, 1.0)) ** 2
                               + ((gy - point[1]) / max(sigma, 1.0)) ** 2))
        dx += weight.astype(np.float32) * float(move_x) * float(amount)
        dy += weight.astype(np.float32) * float(move_y) * float(amount)

    warped = cv2.remap(
        image,
        (gx - dx).astype(np.float32),
        (gy - dy).astype(np.float32),
        cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_REPLICATE,
    )
    base = image[y0:y0 + bh, x0:x0 + bw]

    # Full coverage around the lip corners, then a wide photographic feather.
    # Every strength state, including neutral, owns the same alpha envelope so
    # adjacent-state interpolation remains true premultiplied RGBA blending.
    rx = max(.80 * width, 1.0)
    ry = max(.43 * width, 1.0)
    radius = np.sqrt(((gx - centre[0]) / rx) ** 2
                     + ((gy - (centre[1] + .015 * width)) / ry) ** 2)
    alpha = np.clip(1.0 - _smoothstep(.72, 1.0, radius), 0.0, 1.0)
    oval = face.hull_mask(image.shape, lm, face.FACE_OVAL)
    oval = cv2.GaussianBlur(oval, (0, 0), max(1.0, width * .018))
    alpha *= oval[y0:y0 + bh, x0:x0 + bw].astype(np.float32) / 255.0
    rgb = np.where(alpha[..., None] > 1e-3, warped, base)
    return np.dstack([rgb.astype(np.uint8), (alpha * 255).astype(np.uint8)])


def _smile_patch(image, lm, amount, box):
    """Lift both photographed lip corners without changing mouth size.

    Smile and laughter intentionally share this one lower-face action.  The
    mouth keeps the current viseme's width, aperture, teeth and tongue; only
    the two corners rise.  Brows, cheeks, eyelids and forehead remain runtime-
    neutral, so a smile never turns into a different whole-face identity.
    """
    left = np.asarray(lm[face.MOUTH_L], np.float32)
    right = np.asarray(lm[face.MOUTH_R], np.float32)
    width = max(float(np.linalg.norm(right - left)), 8.0)
    # The full-strength atlas has generous travel; the runtime uses a restrained
    # fractional blend. Zero horizontal and mid-lip displacement is deliberate:
    # it prevents a spoken vowel from becoming wider or more open during joy.
    controls = (
        (left, 0.0, -0.180 * width, .235 * width),
        (right, 0.0, -0.180 * width, .235 * width),
    )
    return _mouth_warp_patch(image, lm, amount, box, controls)


def _emotion_mouth_patch(image, lm, emotion, amount, box):
    """Give sorrow, horror and anger distinct lower-face action units."""
    left = np.asarray(lm[face.MOUTH_L], np.float32)
    right = np.asarray(lm[face.MOUTH_R], np.float32)
    upper = np.asarray(lm[0], np.float32)
    lower = np.asarray(lm[17], np.float32)
    width = max(float(np.linalg.norm(right - left)), 8.0)
    aperture = float(np.linalg.norm(lower - upper)) / width
    open_gate = float(_smoothstep(.025, .115, aperture))
    if emotion == "sorrow":
        # AU15 + AU17: corners depress and draw slightly inward while the lower
        # lip/chin rises. This gives grief a readable frown between phonemes.
        controls = (
            (left, .045 * width, .155 * width, .255 * width),
            (right, -.045 * width, .155 * width, .255 * width),
            (upper, 0.0, .010 * width, .205 * width),
            (lower, 0.0, -.034 * width, .225 * width),
        )
    elif emotion == "horror":
        # AU20 + AU26: lips stretch laterally and the jaw drops. The aperture
        # follows vowels most, but retains a small recoil on closed consonants.
        jaw_gate = .32 + .68 * open_gate
        controls = (
            (left, -.060 * width, .040 * width, .255 * width),
            (right, .060 * width, .040 * width, .255 * width),
            (upper, 0.0, -.034 * width * jaw_gate, .205 * width),
            (lower, 0.0, .115 * width * jaw_gate, .225 * width),
        )
    elif emotion == "anger":
        # AU10/AU15/AU25 snarl: preserve the speaker's normal mouth width while
        # the corners turn down and the lips part moderately with the source
        # viseme. This is the midpoint between the pinched and oversized trials.
        controls = (
            (left, 0.0, .065 * width, .255 * width),
            (right, 0.0, .065 * width, .255 * width),
            (upper, 0.0, -.050 * width, .205 * width),
            (lower, 0.0, .045 * width * (.35 + .65 * open_gate), .225 * width),
        )
    else:
        raise ValueError(f"unknown emotion mouth: {emotion}")
    return _mouth_warp_patch(image, lm, amount, box, controls)


def build_smile(key, key_lm, visemes, states=None, log=print):
    """Build a row-major ``viseme x smile-strength`` RGBA mouth atlas.

    ``visemes`` is a sequence of ``(runtime_name, BGR_frame)`` pairs.  The
    fixed keyframe box makes every row the same size, while per-frame landmarks
    ensure the deformation follows that viseme's actual lips and jaw.
    """
    strengths = list(SMILE_STATES if states is None else states)
    box = _smile_box(key.shape, key_lm)
    try:
        key_lip = np.asarray(key_lm[face.OUTER_LIP], np.float64)
        key_centre_x = float(key_lip[:, 0].mean())
        # Registration is deliberately horizontal only.  A viseme's vertical
        # lip centre legitimately moves as its jaw opens, while provider-made
        # cartoon frames can drift sideways by tens of pixels.
        offset_limit = min(96.0, max(4.0, float(np.ptp(key_lip[:, 0])) * .35))
    except (IndexError, TypeError, ValueError):
        key_centre_x = None
        offset_limit = 0.0
    patches, names, x_offsets = [], [], {}
    for name, image in visemes:
        lm, _ = face.detect(image)
        if lm is None:
            lm = key_lm
            log(f"  smile {name}: landmarks unavailable; using registered keyframe geometry")
        runtime_name = str(name)
        names.append(runtime_name)
        offset = 0.0
        if key_centre_x is not None and runtime_name != "sil":
            try:
                lip = np.asarray(lm[face.OUTER_LIP], np.float64)
                candidate = key_centre_x - float(lip[:, 0].mean())
                if np.isfinite(candidate):
                    offset = float(np.clip(candidate, -offset_limit, offset_limit))
            except (IndexError, TypeError, ValueError):
                pass
        x_offsets[runtime_name] = round(offset, 4)
        patches.extend(_smile_patch(image, lm, strength, box)
                       for strength in strengths)
    log(f"  laughter mouth: {len(names)} visemes x {len(strengths)} states, "
        f"patch {box[2]}x{box[3]}")
    return dict(states=[round(float(v), 4) for v in strengths],
                visemes=names, box=box, patches=patches,
                viseme_x_offsets=x_offsets)


def build_emotion_mouths(key, key_lm, visemes, states=None, log=print):
    """Build ``emotion x viseme x strength`` lower-face states."""
    strengths = list(EMOTION_MOUTH_STATES if states is None else states)
    box = _smile_box(key.shape, key_lm)
    detected, names = [], []
    for name, image in visemes:
        lm, _ = face.detect(image)
        detected.append((image, key_lm if lm is None else lm))
        names.append(str(name))
    patches = [
        _emotion_mouth_patch(image, lm, emotion, strength, box)
        for emotion in EMOTION_MOUTHS
        for image, lm in detected
        for strength in strengths
    ]
    log(f"  emotion mouth: {len(EMOTION_MOUTHS)} emotions x {len(names)} visemes "
        f"x {len(strengths)} states, patch {box[2]}x{box[3]}")
    return dict(states=[round(float(v), 4) for v in strengths],
                emotions=list(EMOTION_MOUTHS), visemes=names,
                box=box, patches=patches)


def _iris(lm, side):
    c = lm[IRIS[side]]
    r = float(np.linalg.norm(lm[IRIS_RING[side]] - c, axis=1).mean())
    return c, r


# ---- gaze ------------------------------------------------------------------

def _eyeball_mask(shape, lm, side, s):
    """The wet eye inset from lid margins, with lash contours hard-protected."""
    mask = face.hull_mask(shape, lm, EYE[side])
    kernel_size = max(int(3 * s) | 1, 3)
    mask = cv2.erode(mask, np.ones((kernel_size, kernel_size), np.uint8))
    alpha = cv2.GaussianBlur(mask, (0, 0), 2.6 * s).astype(np.float32) / 255.0

    guard = np.zeros(shape[:2], np.uint8)
    thickness = max(int(7 * s) | 1, 3)
    for contour in (UPPER[side], LOWER[side]):
        points = np.rint(lm[contour]).astype(np.int32).reshape(-1, 1, 2)
        cv2.polylines(guard, [points], False, 255, thickness=thickness,
                      lineType=cv2.LINE_AA)
    # A hard-zeroed guard is a tear line under a 9px iris shift: the warp
    # shears the iris across the cliff in single-pixel steps - the
    # 'ruptured iris' measured live 2026-08-01 on EVERY avatar's extreme
    # gaze tiles. Soft-lift the guard instead, so motion decays over a few
    # pixels into the lashes; the lash line itself still holds at zero.
    soft_guard = cv2.GaussianBlur(guard, (0, 0), 2.2 * s).astype(np.float32) / 255.0
    alpha *= np.clip(1.0 - soft_guard * 1.15, 0.0, 1.0)
    return alpha


def gaze_state(key, lm, side, dx, dy, s, box, ball):
    x0, y0, bw, bh = box
    c, r = _iris(lm, side)
    xs = np.arange(x0, x0 + bw, dtype=np.float32)
    ys = np.arange(y0, y0 + bh, dtype=np.float32)
    gx, gy = np.meshgrid(xs, ys)
    d = np.sqrt((gx - c[0]) ** 2 + (gy - c[1]) ** 2)

    # Rigid out past the limbus - the iris edge is the one hard edge in
    # there and a partial warp across it would ghost. The landmark ring
    # tracks only the VISIBLE iris (clipped by the lids), so it
    # under-measures the physical disc; a rigid zone at 1.15r ended inside
    # the real iris and moved only part of it - the rupture's root cause
    # (diagnosed by the user, 2026-08-01). Scope generously instead:
    # everything within 1.45r travels as ONE body, and the decay reaches
    # deep into sclera where a blend is invisible.
    w = 1.0 - _smoothstep(1.45 * r, 2.3 * r, d)
    w = (w * ball[y0:y0 + bh, x0:x0 + bw]).astype(np.float32)   # and 0 at the lid margins

    warped = cv2.remap(key, (gx - dx * w).astype(np.float32),
                       (gy - dy * w).astype(np.float32),
                       cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
    base = key[y0:y0 + bh, x0:x0 + bw]
    # Only claim the pixels that actually moved.
    a = np.clip(w * 1.6, 0.0, 1.0).astype(np.float32)
    rgb = np.where(a[..., None] > 1e-3, warped, base)
    return np.dstack([rgb.astype(np.uint8), (a * 255).astype(np.uint8)])


# ---- brow ------------------------------------------------------------------

def _brow_alpha(shape, lm, side, s):
    m = face.hull_mask(shape, lm, BROW[side], dilate=int(17 * s) | 1)
    return cv2.GaussianBlur(m, (0, 0), 7 * s).astype(np.float32) / 255.0


def brow_state(key, lm, side, dy, s, box, alpha, sq=0.0):
    x0, y0, bw, bh = box
    b = lm[BROW[side]]
    bx0, bx1 = float(b[:, 0].min()), float(b[:, 0].max())
    btop, bbot = float(b[:, 1].min()), float(b[:, 1].max())
    lash = float(_line(lm[UPPER[side]], np.linspace(bx0, bx1, 12)).min())
    medial_right = lm[NOSE_X][0] > 0.5 * (bx0 + bx1)   # which end points at the nose

    xs = np.arange(x0, x0 + bw, dtype=np.float32)
    ys = np.arange(y0, y0 + bh, dtype=np.float32)

    # along the brow: 0 at the medial end, 1 at the tail
    u = np.clip((xs - bx0) / max(bx1 - bx0, 1.0), 0.0, 1.0)
    if medial_right:
        u = 1.0 - u
    if dy >= 0:
        h = 0.55 + 0.45 * np.sin(np.pi * np.clip(u, 0, 1) ** 0.85)   # arch-weighted lift
        # A raised, knitted brow is the signature of grief: the medial end
        # rises while the tail stays comparatively quiet.  The old atlas used
        # the same smooth arch for joy, sorrow and surprise, so all three read
        # as a generic attentive face even when the runtime selected different
        # values.  Reuse the positive squeeze axis as a local, image-free
        # sadness shape; a spread brow (fear/surprise) keeps the open arch.
        grief = np.clip(sq / max(BROW_SQ[-1], 1e-6), 0.0, 1.0) \
            * np.clip(dy / max(BROW_DY[-1], 1e-6), 0.0, 1.0)
        medial_lift = 1.0 - 0.58 * u
        h = h * (1.0 - grief) + medial_lift * grief
        sway = np.zeros_like(u)
    else:
        h = 1.0 - 0.5 * u                                            # corrugator: medial
        sway = (1.0 - u) * (0.35 if medial_right else -0.35)
    h = h * (1.0 - _smoothstep(1.0, 1.22, np.abs(xs - 0.5 * (bx0 + bx1))
                               / max(0.5 * (bx1 - bx0), 1.0)))

    # across the brow: full over the hair, fading into the forehead and dying
    # before the lash line so it never fights the eyelid layer
    span = max(bbot - btop, 6.0)
    # _smoothstep needs ascending edges (its denominator is clamped to 1e-6,
    # so reversed edges collapse into a hard step at the first edge). This
    # call shipped reversed for months: the envelope read 1.0 in the
    # forehead and 0.0 over the brow hair, and every baked brow strip came
    # out ~15% opaque - flicking through 42 invisible tiles.
    up = _smoothstep(btop - 1.7 * span, btop - 0.35 * span, ys)
    dn = 1.0 - _smoothstep(bbot + 0.15 * span, lash - 4.0 * s, ys)
    v = np.clip(np.minimum(up, dn), 0.0, 1.0)

    W = (v[:, None] * h[None, :]).astype(np.float32)
    gx, gy = np.meshgrid(xs, ys)
    # The squeeze axis: the whole brow slides toward (+) or away from (-)
    # the nose, strongest at the medial end - a knit or an open, fully
    # independent of the raise.
    # The original 2.4px squeeze was a micro-expression target.  At Chat/Talk
    # bust scale it became sub-pixel and could not distinguish sorrow/anger
    # from neutral.  Double the baked tissue travel while preserving the
    # stable public control grid and interpolation semantics.
    medial_pull = (sq if medial_right else -sq) * 2.0 \
        * (1.0 - 0.45 * u)[None, :]
    warped = cv2.remap(key,
                       (gx - (sway[None, :] * v[:, None]) * abs(dy)
                        - medial_pull * v[:, None]).astype(np.float32),
                       (gy - dy * W).astype(np.float32),
                       cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
    base = key[y0:y0 + bh, x0:x0 + bw]
    a = (np.clip(W * 1.6, 0.0, 1.0) * alpha[y0:y0 + bh, x0:x0 + bw]).astype(np.float32)
    rgb = np.where(a[..., None] > 1e-3, warped, base)
    return np.dstack([rgb.astype(np.uint8), (a * 255).astype(np.uint8)])


# ---- forehead / glabella ---------------------------------------------------

def _forehead_weight(shape, lm, side, s):
    """A compact forehead band coupled to one brow, including the glabella.

    The old brow patch ended a few pixels above the brow hair, so a moving brow
    sat on an entirely frozen forehead.  This band reaches upward without
    touching hair and overlaps its sibling only through a very soft medial
    feather.  It is deliberately narrower than half the face: the two patches
    cannot stamp nose, eye or opposite-cheek pixels over one another.
    """
    H, W = shape[:2]
    b = np.asarray(lm[BROW[side]], np.float32)
    oval = np.asarray(lm[face.FACE_OVAL], np.float32)
    nose_x = float(lm[NOSE_X][0])
    bx0, bx1 = float(b[:, 0].min()), float(b[:, 0].max())
    btop, bbot = float(b[:, 1].min()), float(b[:, 1].max())
    span = max(bx1 - bx0, 8.0 * s)
    crown = float(oval[:, 1].min())
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)

    lateral = bx0 if 0.5 * (bx0 + bx1) < nose_x else bx1
    left, right = sorted((lateral, nose_x))
    horizontal = _smoothstep(left - .18 * span, left + .03 * span, xs) * (
        1.0 - _smoothstep(right - .03 * span, right + .18 * span, xs))
    top = crown + .16 * max(btop - crown, 1.0)
    vertical = _smoothstep(top, top + .14 * max(btop - top, 1.0), ys) * (
        1.0 - _smoothstep(btop - .12 * span, bbot + .22 * span, ys))
    weight = horizontal * vertical
    inside = face.hull_mask(shape, lm, face.FACE_OVAL)
    inside = cv2.erode(inside, cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (max(3, int(7 * s) | 1),) * 2))
    weight *= cv2.GaussianBlur(inside, (0, 0), 4.0 * s).astype(np.float32) / 255.0
    return np.clip(weight, 0.0, 1.0).astype(np.float32)


def forehead_state(key, lm, side, dy, s, box, weight, sq=0.0):
    """Move forehead tissue with the brow and reveal restrained expression lines."""
    x0, y0, bw, bh = box
    b = np.asarray(lm[BROW[side]], np.float32)
    nose_x = float(lm[NOSE_X][0])
    btop = float(b[:, 1].min())
    span = max(float(b[:, 0].max() - b[:, 0].min()), 8.0 * s)
    xs = np.arange(x0, x0 + bw, dtype=np.float32)
    ys = np.arange(y0, y0 + bh, dtype=np.float32)
    gx, gy = np.meshgrid(xs, ys)
    Wl = weight[y0:y0 + bh, x0:x0 + bw]
    # Skin nearest the brow follows most; the crown remains almost fixed.
    proximity = _smoothstep(y0, btop, gy)
    travel = Wl * (.24 + .76 * proximity)
    medial = np.exp(-0.5 * ((gx - nose_x) / max(.22 * span, 2.0)) ** 2)
    direction = 1.0 if 0.5 * (b[:, 0].min() + b[:, 0].max()) < nose_x else -1.0
    warped = cv2.remap(
        key,
        (gx - direction * sq * medial * travel * .42).astype(np.float32),
        (gy - dy * travel * .58).astype(np.float32),
        cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE,
    )
    # cv2.remap returns the dimensions of its coordinate maps.  ``gx``/``gy``
    # are already local to this patch, so slicing the result by global face
    # coordinates produces an empty array whenever the forehead is not at the
    # image origin.
    patch = warped.astype(np.float32)

    # Bare forehead skin can move while looking pixel-identical. Reinforce only
    # the source's own fine texture. Do not invent horizontal wrinkle bands:
    # three fixed Gaussian lines used to be stamped at the same relative
    # heights on every raised-brow state. At close-up scale those perfectly
    # parallel bands read as drawn-on seams (and made smooth/younger foreheads
    # age abruptly). The photographed texture still follows the brow warp, so
    # naturally present creases remain and move with the tissue.
    source_patch = key[y0:y0 + bh, x0:x0 + bw].astype(np.float32)
    detail = source_patch - cv2.GaussianBlur(source_patch, (0, 0), 2.2 * s)
    activity = min(1.0, abs(float(dy)) / 7.0 + abs(float(sq)) / 3.5)
    patch += detail * (.18 + .34 * activity) * Wl[..., None]
    shade = np.zeros((bh, bw), np.float32)
    # A positive squeeze may reveal the vertical glabella/corrugator pair.
    # Unlike the removed horizontal bands, this stays local to the nose root
    # and is anatomically coupled to the squeeze axis rather than brow height.
    if sq > .35:
        for offset in (-.07, .07):
            line_x = nose_x + offset * span
            shade -= np.exp(-0.5 * ((gx - line_x) / max(1.1 * s, .8)) ** 2) \
                * medial * min(9.0, sq * 2.8)
    patch += shade[..., None] * Wl[..., None]
    patch = np.clip(patch, 0, 255).astype(np.uint8)
    alpha = np.clip(Wl * 1.22, 0.0, 1.0)
    return np.dstack([patch, (alpha * 255).astype(np.uint8)])


# ---- cheek -----------------------------------------------------------------
# A cheek raise is the micro-expression that reads as warmth, and the obvious
# way to build it - warp the cheek - does not work.  Bare cheek skin has no
# texture, so a 2px shift of it is literally invisible; the same warp that sells
# the iris (hard limbus) and the brow (hair) buys nothing here.
#
# What actually shows a cheek raise in a portrait is the STRUCTURE ALONG ITS TOP
# EDGE: the lower lid margin lifts, the lash line rises with it, the infraorbital
# crease moves and deepens.  So this layer is anchored on the lower lid and fades
# downward over the malar eminence, rather than being centred on the cheek.

def _cheek_weight(shape, lm, side, s, avoid=None):
    H, W = shape[:2]
    c, _ = _iris(lm, side)
    corners = np.array([lm[face.MOUTH_L], lm[face.MOUTH_R]], np.float32)
    mc = corners[int(np.argmin(np.abs(corners[:, 0] - c[0])))]   # same-side corner
    lat = 1.0 if c[0] > lm[NOSE_X][0] else -1.0                  # which way is lateral
    span = float(np.linalg.norm(mc - c))

    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = float(c[0] + lat * 0.10 * span), float(c[1] + 0.34 * span)
    rho = np.sqrt(((xs - cx) / (0.62 * span)) ** 2 + ((ys - cy) / (0.52 * span)) ** 2)
    w = 1.0 - _smoothstep(0.45, 1.0, rho)

    # ride the lower lid margin, and stop dead above it so the eyeball layer
    # underneath is never disturbed
    low = lm[LOWER[side]]
    lidy = _line(low, np.clip(xs[0], float(low[:, 0].min()), float(low[:, 0].max())))
    below = ys - lidy[None, :]
    w = w * _smoothstep(2.0 * s, 9.0 * s, below)

    # Keep the malar patch on its own side of the face and away from the nose.
    # The previous ellipse reached the alar base and lower eye, which made a
    # five-state snap look like a detachable cheek pasted over the portrait.
    away_from_nose = (xs - float(lm[NOSE_X][0])) * lat
    w *= _smoothstep(.10 * span, .24 * span, away_from_nose)

    # and stay clear of whatever the viseme frames repaint, or this stamps
    # keyframe pixels over a moving mouth
    if avoid is None:
        avoid = face.hull_mask(shape, lm, face.OUTER_LIP,
                              dilate=int(34 * s) | 1).astype(np.float32) / 255.0
    # dilate BEFORE blurring, so the soft ramp sits entirely outside the region
    # the visemes touch.  Blurring alone leaves alpha ~0.5 along the boundary -
    # which is exactly the feather band where a stale patch would show.
    kk = int(20 * s) | 1
    avoid = cv2.dilate(avoid, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kk, kk)))
    w = w * (1.0 - cv2.GaussianBlur(avoid, (0, 0), 6 * s))
    oval = face.hull_mask(shape, lm, face.FACE_OVAL)      # hull_mask only dilates
    k = int(12 * s) | 1
    oval = cv2.erode(oval, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    w = w * (cv2.GaussianBlur(oval, (0, 0), 5 * s).astype(np.float32) / 255.0)
    return np.clip(w, 0.0, 1.0).astype(np.float32), lat


def cheek_state(key, up, s, box, w, lat):
    x0, y0, bw, bh = box
    xs = np.arange(x0, x0 + bw, dtype=np.float32)
    ys = np.arange(y0, y0 + bh, dtype=np.float32)
    gx, gy = np.meshgrid(xs, ys)
    Wl = w[y0:y0 + bh, x0:x0 + bw]
    warped = cv2.remap(key,
                       (gx + lat * 0.22 * up * Wl).astype(np.float32),   # slightly medial
                       (gy + up * Wl).astype(np.float32),                # and up
                       cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
    base = key[y0:y0 + bh, x0:x0 + bw]
    a = np.clip(Wl * 1.5, 0.0, 1.0)
    rgb = np.where(a[..., None] > 1e-3, warped, base)
    return np.dstack([rgb.astype(np.uint8), (a * 255).astype(np.uint8)])


# ---- eyebag ----------------------------------------------------------------
# The infraorbital triangle - the "eyebag" band between the lower lash line
# and the malar cheek mass - was the one patch of face no layer touched: the
# cheek weight is centred lower on the malar, the eye layer stops at the
# lid, and the band between them sat frozen through speech (owner, rachel
# 2026-08-01: "that's the only place not responsive changing during talk").
# On a real face this skin bunches with every smile-adjacent phoneme, so it
# gets its own thin layer riding the cheek envelope: same warp mechanics as
# the cheek (up and slightly medial), anchored just under the lash line and
# dying out half an eye-width down.

EYEBAG_UP = [0.0, 0.5, 1.0, 1.6, 2.3]


def _eyebag_weight(shape, lm, side, s):
    H, W = shape[:2]
    low = lm[LOWER[side]]
    x0, x1 = float(low[:, 0].min()), float(low[:, 0].max())
    width = max(x1 - x0, 1.0)
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    lidy = _line(low, np.clip(xs[0], x0, x1))
    below = ys - lidy[None, :]
    # full just below the lash line - never above it, so the eyeball and
    # lid layers are undisturbed - fading out ~0.6 eye-widths down where
    # the cheek layer takes over
    v = _smoothstep(1.5 * s, 6.0 * s, below) * (
        1.0 - _smoothstep(0.28 * width, 0.60 * width, below))
    u = 1.0 - _smoothstep(0.50 * width, 0.72 * width,
                          np.abs(xs - (x0 + x1) * 0.5))
    w = v * u
    oval = face.hull_mask(shape, lm, face.FACE_OVAL)
    w = w * (cv2.GaussianBlur(oval, (0, 0), 5 * s).astype(np.float32) / 255.0)
    return np.clip(w, 0.0, 1.0).astype(np.float32)


# ---- build -----------------------------------------------------------------

def build(key, lm=None, dxs=None, dys=None, brow_dys=None, ups=None,
          avoid=None, log=print):
    """-> dict(gaze={dxs,dys,<side>:...}, brow={dys,...}, cheek={ups,...})

    `avoid` is an optional float mask of pixels the viseme frames repaint; the
    cheek layer is forced to zero there.  Pass the measured one when you have
    the viseme bank to hand - it is exact, where a dilated lip hull is a guess.
    """
    if lm is None:
        lm, _ = face.detect(key)
    if lm is None:
        raise ValueError("no face landmarks on keyframe")
    dxs = list(GAZE_DX if dxs is None else dxs)
    dys = list(GAZE_DY if dys is None else dys)
    bdys = list(BROW_DY if brow_dys is None else brow_dys)
    cups = list(CHEEK_UP if ups is None else ups)
    H, W = key.shape[:2]
    s = max(H, W) / 1024.0
    # The travel table was tuned on a wide reference eye (iris r ~= 17px at
    # 1024). The warp is rigid only inside 1.15r, so on a smaller iris a
    # +-9px shift drags the iris edge past the rigid zone and TEARS it
    # (measured live 2026-08-01: extreme-gaze tiles with fractured irises
    # on a narrow-eyed subject). Scale the whole table to this face; the
    # renderer follows the manifest values, so the eyes simply travel as
    # far as THIS anatomy allows.
    radius = min(_iris(lm, side)[1] for side in SIDES) / s
    travel = min(1.0, max(0.45, radius / 17.0))
    if travel < 1.0:
        dxs = [round(dx * travel, 2) for dx in dxs]
        dys = [round(dy * travel, 2) for dy in dys]
        log(f"  gaze travel scaled to {travel:.2f}x (iris r {radius:.1f}px)")

    out = dict(gaze=dict(dxs=dxs, dys=dys),
               brow=dict(dys=bdys, sqs=list(BROW_SQ)),
               forehead=dict(dys=bdys, sqs=list(BROW_SQ)),
               cheek=dict(ups=cups),
               eyebag=dict(ups=list(EYEBAG_UP)))
    for side in SIDES:
        c, r = _iris(lm, side)
        ball = _eyeball_mask(key.shape, lm, side, s)
        box = _box(ball, int(7 * s), key.shape)
        out["gaze"][side] = dict(
            box=[int(v) for v in box],
            patches=[gaze_state(key, lm, side, dx, dy, s, box, ball)
                     for dy in dys for dx in dxs])       # row-major: dy outer
        log(f"  gaze {side}: iris r={r:.1f}px, {len(dxs)}x{len(dys)} states, "
            f"patch {box[2]}x{box[3]}")

        alpha = _brow_alpha(key.shape, lm, side, s)
        bbox = _box(alpha, int(6 * s), key.shape)
        out["brow"][side] = dict(
            box=[int(v) for v in bbox],
            patches=[brow_state(key, lm, side, dy, s, bbox, alpha, sq=sq)
                     for sq in BROW_SQ for dy in bdys])   # row-major: sq outer
        log(f"  brow {side}: {len(bdys)}x{len(BROW_SQ)} states, "
            f"patch {bbox[2]}x{bbox[3]}")

        fw = _forehead_weight(key.shape, lm, side, s)
        fbox = _box(fw, int(4 * s), key.shape)
        out["forehead"][side] = dict(
            box=[int(v) for v in fbox],
            patches=[forehead_state(key, lm, side, dy, s, fbox, fw, sq=sq)
                     for sq in BROW_SQ for dy in bdys])
        log(f"  forehead {side}: {len(bdys)}x{len(BROW_SQ)} states, "
            f"patch {fbox[2]}x{fbox[3]}")

        cw, lat = _cheek_weight(key.shape, lm, side, s, avoid)
        cbox = _box(cw, int(4 * s), key.shape)
        out["cheek"][side] = dict(
            box=[int(v) for v in cbox],
            patches=[cheek_state(key, u, s, cbox, cw, lat) for u in cups])
        log(f"  cheek {side}: {len(cups)} states, patch {cbox[2]}x{cbox[3]}")

        ew = _eyebag_weight(key.shape, lm, side, s)
        ebox = _box(ew, int(4 * s), key.shape)
        out["eyebag"][side] = dict(
            box=[int(v) for v in ebox],
            patches=[cheek_state(key, u, s, ebox, ew, lat)
                     for u in EYEBAG_UP])
        log(f"  eyebag {side}: {len(EYEBAG_UP)} states, "
            f"patch {ebox[2]}x{ebox[3]}")
    return out


def paste(frame, layer, side, i, alpha=1.0):
    """Draw state `i` of one side onto a BGR frame (preview/QA only)."""
    if i < 0 or alpha <= 0:
        return frame
    x, y, w, h = layer[side]["box"]
    p = layer[side]["patches"][i]
    a = (p[..., 3:4].astype(np.float32) / 255.0) * float(alpha)
    roi = frame[y:y + h, x:x + w].astype(np.float32)
    frame[y:y + h, x:x + w] = np.clip(
        roi * (1 - a) + p[..., :3].astype(np.float32) * a, 0, 255).astype(np.uint8)
    return frame


def nearest(values, v):
    return min(range(len(values)), key=lambda i: abs(values[i] - v))


def paste_snap(frame, layer, side, values, v, row=0):
    """Nearest baked state. Blending two baked warps is a cross-dissolve, which
    doubles every hard edge inside the patch; the grids are fine enough that
    snapping is both sharper and, at a quarter of a pixel, invisible."""
    return paste(frame, layer, side, row * len(values) + nearest(values, v), 1.0)


def strip(patches):
    return np.vstack(patches)
