"""Source-authoritative alpha cleanup and release gates for body plates.

The full-body source is generated on a deliberately uniform white plate.  The
macOS Vision person mask is a useful semantic prior, but it can still label the
white opening between an arm and waist, or the white opening inside a pump, as
part of the person.  Those errors are almost invisible on white and glaring on
a dark desktop.

This module never guesses foreground from alpha alone.  It removes only pixels
that the retained provider source proves are the studio plate, then audits the
result.  A separate conservative source-shadow gate rejects ambiguous floor
shadows instead of trying to cut around anatomy.  That distinction is what
keeps pale skin, shaded white fabric, limbs, and one-pixel heel stems intact.
"""

import cv2
import numpy as np


STRICT_PLATE_MIN_RGB = 245
STRICT_PLATE_MAX_SPREAD = 8
NEAR_PLATE_MIN_RGB = 228
NEAR_PLATE_MAX_SPREAD = 18
MIN_WHITE_BORDER_RATIO = 0.60
VISIBLE_ALPHA = 24
OPAQUE_ALPHA = 128
FLOOR_SHADOW_MIN_PIXELS = 20
FLOOR_SHADOW_MIN_ALPHA_MASS = 10.0
WHITE_MATTE_MIN_PIXELS = 8
WHITE_MATTE_MIN_ALPHA_MASS = 4.0
WHITE_MATTE_MAX_DISTANCE = 7.0
WHITE_MATTE_MAX_RMS = 12.0
SHOE_FLARE_MIN_RGB = 180
SHOE_FLARE_MAX_RGB = 242
SHOE_FLARE_MAX_SPREAD = 12
# Compact shoe-adjacent remnants are provider-limited and feed a motion model
# rather than appearing as the standing runtime plate.  Keep the hard gate for
# material pale blocks, but tolerate a sub-display-pixel contact fleck instead
# of repeatedly redrawing an otherwise approved turnaround.
SHOE_FLARE_MICRO_MIN_PIXELS = 56
SHOE_FLARE_MICRO_MIN_ALPHA_MASS = 32.0
SHOE_FLARE_MICRO_MIN_DEPTH_RATIO = 0.25


def _validate(source, rgba):
    if (source is None or rgba is None or source.ndim != 3
            or source.shape[2] < 3 or rgba.ndim != 3
            or rgba.shape[2] != 4 or source.shape[:2] != rgba.shape[:2]):
        raise ValueError("body source and RGBA cutout dimensions differ")


def _strict_plate(source):
    """Pixels indistinguishable from the provider's pure-white source plate."""
    color = source[:, :, :3].astype(np.int16)
    minimum = np.min(color, axis=2)
    spread = np.max(color, axis=2) - minimum
    return (
        (minimum >= STRICT_PLATE_MIN_RGB)
        & (spread <= STRICT_PLATE_MAX_SPREAD)
    )


def _near_plate(source):
    """Very bright neutral resampling of the promised white source plate."""
    color = source[:, :, :3].astype(np.int16)
    minimum = np.min(color, axis=2)
    spread = np.max(color, axis=2) - minimum
    return (minimum >= NEAR_PLATE_MIN_RGB) & (spread <= NEAR_PLATE_MAX_SPREAD)


def _plate_contract(source):
    """Return whether the provider supplied the promised uniform white plate."""
    strict = _strict_plate(source)
    border = np.zeros(strict.shape, dtype=bool)
    width = max(2, round(min(strict.shape) * 0.02))
    border[:width] = True
    border[-width:] = True
    border[:, :width] = True
    border[:, -width:] = True
    ratio = float(np.mean(strict[border]))
    return {
        "valid": ratio >= MIN_WHITE_BORDER_RATIO,
        "strict_white_border_ratio": round(ratio, 5),
    }


def _border_labels(labels):
    values = np.unique(np.concatenate((
        labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1],
    )))
    return values[values > 0]


def _component_records(mask, alpha):
    count, labels, statistics, centroids = cv2.connectedComponentsWithStats(
        mask.astype(np.uint8), connectivity=8)
    records = []
    for label in range(1, count):
        x, y, width, height, source_area = [
            int(value) for value in statistics[label]
        ]
        label_roi = labels[y:y + height, x:x + width]
        component_roi = label_roi == label
        alpha_roi = alpha[y:y + height, x:x + width]
        pixels = int(np.count_nonzero(
            component_roi & (alpha_roi >= VISIBLE_ALPHA)))
        mass = float(np.sum(
            alpha_roi[component_roi].astype(np.float64)) / 255.0)
        records.append({
            "label": label,
            "visible_pixels": pixels,
            "alpha_mass": mass,
            "source_area": source_area,
            "bounds": [x, y, width, height],
            "centroid": [
                round(float(centroids[label][0]), 3),
                round(float(centroids[label][1]), 3),
            ],
        })
    return labels, records


def _record_mask(labels, record):
    """Materialise one component only; records never retain full-frame masks."""
    return labels == record["label"]


def _white_subject_ambiguity(source, alpha, component, alpha_labels):
    """Identify a likely white garment without destructively accepting it.

    White/off-white wardrobe is forbidden by the generation contract because
    exact-white fabric is not separable from the plate with pixel evidence
    alone.  If an exact-white island has a shaded-white surround *and* belongs
    to an alpha component with clearly coloured/dark anatomy, preserve it and
    hard-reject the plate for regeneration.  A detached gray plate bridge has
    no such source-confirmed anatomy and remains safe to remove.
    """
    # Tiny white flecks are contour contamination or specular detail, never a
    # meaningful garment region. This guard also avoids repeated full-frame
    # colour work on highly fragmented antialiased silhouettes.
    if int(np.count_nonzero(component)) < 24:
        return False
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    ring = cv2.dilate(component.astype(np.uint8), kernel, iterations=1).astype(bool)
    ring &= ~component
    opaque_ring = ring & (alpha >= OPAQUE_ALPHA)
    opaque_count = int(np.count_nonzero(opaque_ring))
    if opaque_count < 16:
        return False
    hsv = cv2.cvtColor(source[:, :, :3], cv2.COLOR_BGR2HSV)
    shaded_white = (
        (hsv[:, :, 2] >= 175)
        & (hsv[:, :, 1] <= 45)
        & ~_strict_plate(source)
    )
    supporting = int(np.count_nonzero(opaque_ring & shaded_white))
    if supporting < 16 or supporting / opaque_count < 0.55:
        return False
    alpha_component_ids = np.unique(alpha_labels[component])
    alpha_component_ids = alpha_component_ids[alpha_component_ids > 0]
    if not alpha_component_ids.size:
        return False
    color = source[:, :, :3].astype(np.int16)
    maximum = np.max(color, axis=2)
    spread = maximum - np.min(color, axis=2)
    confirmed_subject = ((spread >= 18) & (maximum <= 252)) | (maximum <= 180)
    same_alpha_component = np.isin(alpha_labels, alpha_component_ids)
    return int(np.count_nonzero(same_alpha_component & confirmed_subject)) >= 32


def _small_dark_specular(
        source, alpha, component, *, maximum=None, strict_plate=None):
    """Allow an opaque patent-leather reflection, not a white body gap.

    Tiny exact-white glints are safe when an opaque dark material encloses
    them. A real patent-pump reflection can be a larger, irregular near-white
    island, so that second case is allowed only when most of the island is not
    exact plate white and its fill is visibly non-rectangular. Those two
    constraints keep an enclosed pure-white shoe opening on the repair path.
    """
    ys, xs = np.nonzero(component)
    if not len(xs):
        return False
    width = int(xs.max() - xs.min() + 1)
    height = int(ys.max() - ys.min() + 1)
    area = int(len(xs))
    tiny_glint = area <= 64 and width <= 12 and height <= 12
    if not tiny_glint:
        if area > 256 or width > 24 or height > 28:
            return False
        fill_ratio = area / max(1, width * height)
        if fill_ratio > 0.82:
            return False
        if strict_plate is None:
            strict_plate = _strict_plate(source)
        if float(np.mean(strict_plate[component])) > 0.40:
            return False
    if float(np.mean(alpha[component] >= OPAQUE_ALPHA)) < 0.80:
        return False
    kernel_size = 7 if tiny_glint else 9
    ring = cv2.dilate(
        component.astype(np.uint8),
        cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (kernel_size, kernel_size)),
        iterations=1,
    ).astype(bool) & ~component
    opaque_ring = ring & (alpha >= OPAQUE_ALPHA)
    opaque_count = int(np.count_nonzero(opaque_ring))
    if opaque_count < 12:
        return False
    if maximum is None:
        maximum = np.max(source[:, :, :3], axis=2)
    dark_support = int(np.count_nonzero(opaque_ring & (maximum <= 80)))
    return dark_support >= 12 and dark_support / opaque_count >= 0.60


def _small_skin_specular(
        source, alpha, component, *, minimum=None, maximum=None, spread=None):
    """Allow a pin-size white highlight enclosed by opaque pale skin."""
    ys, xs = np.nonzero(component)
    if not len(xs):
        return False
    width = int(xs.max() - xs.min() + 1)
    height = int(ys.max() - ys.min() + 1)
    area = int(len(xs))
    if area > 16 or width > 5 or height > 5:
        return False
    if float(np.mean(alpha[component] >= OPAQUE_ALPHA)) < 0.80:
        return False
    ring = cv2.dilate(
        component.astype(np.uint8),
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
        iterations=1,
    ).astype(bool) & ~component
    opaque_ring = ring & (alpha >= OPAQUE_ALPHA)
    opaque_count = int(np.count_nonzero(opaque_ring))
    if opaque_count < 12:
        return False
    if minimum is None or maximum is None or spread is None:
        color = source[:, :, :3].astype(np.int16)
        minimum = np.min(color, axis=2)
        maximum = np.max(color, axis=2)
        spread = maximum - minimum
    pale_chromatic_support = (
        (minimum >= 120)
        & (maximum <= 252)
        & (spread >= 18)
    )
    supporting = int(np.count_nonzero(opaque_ring & pale_chromatic_support))
    return supporting >= 12 and supporting / opaque_count >= 0.65


def _compact_supported_highlights(source, alpha):
    """Return near-white detail that source context proves belongs to subject."""
    near_visible = _near_plate(source) & (alpha >= VISIBLE_ALPHA)
    labels, records = _component_records(near_visible, alpha)
    color = source[:, :, :3].astype(np.int16)
    minimum = np.min(color, axis=2)
    maximum = np.max(color, axis=2)
    spread = maximum - minimum
    strict = _strict_plate(source)
    mask = np.zeros(alpha.shape, dtype=bool)
    protected = []
    for record in records:
        left, top, width, height = record["bounds"]
        # Both supported-highlight classes are compact. Reject impossible
        # candidates from metadata before materialising even a small ROI; a
        # high-resolution plate can contain hundreds of one-pixel components.
        if (
                record["source_area"] > 256
                or width > 24
                or height > 28):
            continue
        margin = 5
        y0 = max(0, top - margin)
        y1 = min(alpha.shape[0], top + height + margin)
        x0 = max(0, left - margin)
        x1 = min(alpha.shape[1], left + width + margin)
        roi = np.s_[y0:y1, x0:x1]
        component = labels[roi] == record["label"]
        kind = ""
        if _small_dark_specular(
                source[roi], alpha[roi], component,
                maximum=maximum[roi], strict_plate=strict[roi]):
            kind = "dark-specular"
        elif _small_skin_specular(
                source[roi], alpha[roi], component,
                minimum=minimum[roi], maximum=maximum[roi],
                spread=spread[roi]):
            kind = "skin-specular"
        if not kind:
            continue
        mask[roi] |= component
        protected.append({
            "label": record["label"],
            "kind": kind,
            "bounds": record["bounds"],
            "visible_pixels": record["visible_pixels"],
        })
    return labels, mask, protected


def _replacement_head_region(mask, alpha):
    """Validate the caller's body-space canonical-head replacement region.

    This is intentionally an opt-in input.  Photographic bodies and legacy
    callers pass no region, so their white-garment and plate gates retain the
    exact reviewed behaviour.  The stylized front-body pipeline supplies only
    the facial-oval core that the runtime later removes before drawing the
    calibrated head.
    """
    if mask is None:
        return None
    region = np.asarray(mask, dtype=bool)
    if region.shape != alpha.shape:
        raise ValueError(
            "replacement head region and body alpha dimensions differ")
    return region


def _plate_leaks(source, rgba, *, replacement_head_mask=None):
    """Classify strict-white alpha as repairable plate or protected detail."""
    alpha = rgba[:, :, 3]
    replacement_head = _replacement_head_region(
        replacement_head_mask, alpha)
    plate = _strict_plate(source)
    source_labels_count, source_labels = cv2.connectedComponents(
        plate.astype(np.uint8), connectivity=8)
    exterior_labels = set(
        int(value) for value in _border_labels(source_labels)
    ) if source_labels_count > 1 else set()
    # Segment only plate pixels that Vision actually retained.  Segmenting the
    # complete source plate would make its giant border component swallow an
    # exact-white sleeve or dress highlight merely because the garment touches
    # the white backdrop in RGB space.  Alpha-positive islands retain the
    # topological distinction between a semantic-mask leak and real clothing.
    visible_labels, records = _component_records(
        plate & (alpha >= VISIBLE_ALPHA), alpha)
    highlight_labels, highlight_candidates, highlight_records = (
        _compact_supported_highlights(source, alpha))
    _alpha_count, alpha_labels = cv2.connectedComponents(
        (alpha >= VISIBLE_ALPHA).astype(np.uint8), connectivity=8)
    exterior_remove = np.zeros(alpha.shape, dtype=bool)
    enclosed_remove = np.zeros(alpha.shape, dtype=bool)
    protected = np.zeros(alpha.shape, dtype=bool)
    ambiguity_block = np.zeros(alpha.shape, dtype=bool)
    exterior_failures = []
    enclosed_failures = []
    ambiguous_white = []
    protected_white = []
    height = alpha.shape[0]
    for record in records:
        component = _record_mask(visible_labels, record)
        source_component_labels = np.unique(source_labels[component])
        is_exterior = any(
            int(label) in exterior_labels for label in source_component_labels
            if int(label) > 0)
        # A compact source-supported reflection is more specific evidence than
        # the broad white-garment ambiguity heuristic. Keep it only when its
        # strict-white core is not connected to the exterior source plate.
        if not is_exterior and np.any(highlight_candidates & component):
            protected |= component
            continue
        white_ambiguity = _white_subject_ambiguity(
            source, alpha, component, alpha_labels)
        if white_ambiguity:
            # Flat cartoon eyes can be a large exact-white island surrounded
            # by shaded sclera, which deliberately resembles the otherwise
            # forbidden white-garment signature.  Accept it only when every
            # pixel lies inside the body-space region that the stylized runtime
            # erases before drawing the canonical animated head.  Protect that
            # complete region from near-white edge checks because none of it is
            # published from the generated body.  Clothing remains outside the
            # region and therefore keeps the hard rejection below.
            if (replacement_head is not None
                    and bool(np.all(replacement_head[component]))):
                protected |= replacement_head
                protected_white.append({
                    "kind": "canonical-head-replacement",
                    "bounds": record["bounds"],
                    "visible_pixels": record["visible_pixels"],
                })
                continue
            alpha_component_ids = np.unique(alpha_labels[component])
            alpha_component_ids = alpha_component_ids[alpha_component_ids > 0]
            ambiguity_block |= np.isin(alpha_labels, alpha_component_ids)
            ambiguous_white.append({
                "bounds": record["bounds"],
                "visible_pixels": record["visible_pixels"],
                "alpha_mass": round(record["alpha_mass"], 3),
            })
            continue
        if is_exterior:
            # A source pixel proven to be the exterior white plate is never a
            # legitimate antialiased foreground pixel. Remove even one-pixel
            # visible runs; retaining them creates a white zipper on dark UI.
            exterior_remove |= component
            exterior_failures.append({
                "bounds": record["bounds"],
                "visible_pixels": record["visible_pixels"],
                "alpha_mass": round(record["alpha_mass"], 3),
            })
            continue

        # Teeth, catchlights, and pale facial detail can be exact white.  Body
        # negative-space defects occur below the head; exclude the upper fifth.
        if record["centroid"][1] < height * 0.20:
            protected |= component
            protected_white.append({
                "kind": "face-detail",
                "bounds": record["bounds"],
                "visible_pixels": record["visible_pixels"],
            })
            continue
        enclosed_remove |= component
        enclosed_failures.append({
            "bounds": record["bounds"],
            "source_area": record["source_area"],
            "opaque_pixels": int(np.count_nonzero(
                component & (alpha >= OPAQUE_ALPHA))),
            "alpha_mass": round(record["alpha_mass"], 3),
        })
    # A glossy reflection may be near-white without containing a strict-white
    # core. Add its complete source-supported component after the strict pass.
    # Any candidate intersecting a proven plate leak or ambiguous garment is
    # discarded rather than partially protected.
    conflicts = exterior_remove | enclosed_remove | ambiguity_block
    conflict_labels = np.unique(highlight_labels[conflicts])
    conflict_labels = conflict_labels[conflict_labels > 0]
    safe_highlights = highlight_candidates & ~np.isin(
        highlight_labels, conflict_labels)
    protected |= safe_highlights
    safe_labels = set(int(value) for value in np.unique(
        highlight_labels[safe_highlights]) if int(value) > 0)
    for item in highlight_records:
        if int(item["label"]) not in safe_labels:
            continue
        protected_white.append({
            key: value for key, value in item.items() if key != "label"
        })
    return {
        "exterior_mask": exterior_remove,
        "enclosed_mask": enclosed_remove,
        "protected_mask": protected,
        "supported_highlight_mask": safe_highlights,
        "ambiguity_block_mask": ambiguity_block,
        "exterior": exterior_failures,
        "enclosed": enclosed_failures,
        "ambiguous_white": ambiguous_white,
        "protected_white": protected_white,
    }


def _floor_shadow(source, rgba):
    """Conservative source evidence for floor, contact, or wall shadows.

    Neutral anatomy is ambiguous, so this function never edits it.  It rejects
    only elongated, low-chroma runs whose geometry and weak attachment match a
    cast shadow.  A horizontal gray loafer remains valid when it has a broad
    attachment to a real foot; a thin shadow attached only to a heel does not.
    """
    alpha = rgba[:, :, 3]
    if not _plate_contract(source)["valid"]:
        return {"mask": np.zeros(alpha.shape, bool), "components": []}
    points = cv2.findNonZero((alpha >= VISIBLE_ALPHA).astype(np.uint8))
    if points is None:
        return {"mask": np.zeros(alpha.shape, bool), "components": []}
    _person_x, person_y, person_width, person_height = cv2.boundingRect(points)
    # Contact shadows can sit above the lowest stiletto tip. Audit the complete
    # bottom 18% rather than only the final 4% of the alpha bounds.
    floor_start = min(
        alpha.shape[0] - 1, int(round(person_y + person_height * 0.82)))

    color = source[:, :, :3].astype(np.int16)
    minimum = np.min(color, axis=2)
    maximum = np.max(color, axis=2)
    spread = maximum - minimum
    shadow_tone = (
        (minimum >= 52)
        & (maximum <= 230)
        & (spread <= 12)
        & (alpha >= VISIBLE_ALPHA)
    )
    subject_core = (
        ((spread >= 18) & (maximum <= 252))
        | (maximum <= 48)
    ) & (alpha >= VISIBLE_ALPHA)
    labels, records = _component_records(shadow_tone, alpha)
    mask = np.zeros(alpha.shape, dtype=bool)
    failures = []
    for record in records:
        left, top, width, component_height = record["bounds"]
        if (
                record["visible_pixels"] < FLOOR_SHADOW_MIN_PIXELS
                and record["alpha_mass"] <= FLOOR_SHADOW_MIN_ALPHA_MASS):
            continue
        component = _record_mask(labels, record)
        ring = cv2.dilate(
            component.astype(np.uint8), np.ones((3, 3), np.uint8),
            iterations=1).astype(bool) & ~component
        contact = ring & subject_core
        contact_y, contact_x = np.nonzero(contact)
        x_span = (
            int(contact_x.max() - contact_x.min() + 1)
            if len(contact_x) else 0)
        y_span = (
            int(contact_y.max() - contact_y.min() + 1)
            if len(contact_y) else 0)
        horizontal = (
            width >= max(20, round(person_width * 0.10))
            and width >= component_height * 2.4
        )
        weak_foot_attachment = x_span / max(1, width) < 0.30
        component_alpha = alpha[component]
        translucent = (
            float(np.median(component_alpha)) < 240
            or float(np.mean(component_alpha >= 240)) < 0.50
        )
        floor_shadow = (
            top + component_height >= floor_start
            and horizontal
            # A detached shadow has weak contact. A broad shadow directly
            # under a sole has broad contact but remains translucent; a real
            # gray loafer has opaque interior and broad ankle attachment.
            and (weak_foot_attachment or translucent)
        )
        vertical = (
            component_height >= max(20, round(person_height * 0.15))
            and component_height >= width * 2.4
            and width <= max(16, round(person_width * 0.15))
        )
        values = maximum[component]
        uniform = bool(len(values)) and float(np.std(values)) <= 8.0
        row_positions = np.unique(np.nonzero(component)[0])
        row_tones = np.array([
            float(np.median(maximum[row][component[row]]))
            for row in row_positions
        ], dtype=np.float64)
        smooth_gradient = False
        if len(row_tones) >= 8:
            axis = row_positions.astype(np.float64)
            slope, offset = np.polyfit(axis, row_tones, 1)
            residual = row_tones - (slope * axis + offset)
            changes = np.diff(row_tones)
            monotonic = max(
                float(np.mean(changes >= -1.0)),
                float(np.mean(changes <= 1.0)),
            ) >= 0.90
            smooth_gradient = monotonic and float(np.std(residual)) <= 5.0
        wall_shadow = (
            top < floor_start
            and vertical
            and translucent
            and (uniform or smooth_gradient)
            and y_span / max(1, component_height) >= 0.30
        )
        detached_elongated = (
            not len(contact_x)
            and max(width / max(1, component_height),
                    component_height / max(1, width)) >= 1.8
        )
        kind = (
            "floor-contact" if floor_shadow else
            "wall-contact" if wall_shadow else
            "detached-neutral" if detached_elongated else
            ""
        )
        if kind:
            mask |= component
            failures.append({
                "kind": kind,
                "bounds": record["bounds"],
                "visible_pixels": record["visible_pixels"],
                "alpha_mass": round(record["alpha_mass"], 3),
                "subject_contact_x_ratio": round(x_span / max(1, width), 4),
                "subject_contact_y_ratio": round(
                    y_span / max(1, component_height), 4),
            })

    # Vision can assign a dark fuzzy shoe shadow the same semantic component as
    # a black pump, so source-tone components above may merge it into anatomy.
    # Audit the translucent extension separately: legitimate shoe/heel AA hugs
    # the solid core within one pixel, while a cast smear forms a broad run at
    # least one diagonal pixel farther into the floor plate.
    rows = np.arange(alpha.shape[0])[:, None]
    solid = alpha >= 192
    distance_from_solid = cv2.distanceTransform(
        (~solid).astype(np.uint8), cv2.DIST_L2, 5)
    fuzzy = (
        (alpha >= VISIBLE_ALPHA)
        & (alpha < 192)
        & (rows >= floor_start)
        & (distance_from_solid >= 1.4)
        & (maximum <= 230)
        & (spread <= 18)
    )
    fuzzy_labels, fuzzy_records = _component_records(fuzzy, alpha)
    for record in fuzzy_records:
        _left, _top, width, component_height = record["bounds"]
        broad = (
            width >= max(12, round(person_width * 0.08))
            and width >= component_height * 1.8
        )
        material = (
            record["visible_pixels"] >= 16
            or record["alpha_mass"] > 8.0
        )
        component = _record_mask(fuzzy_labels, record)
        max_distance = float(np.max(distance_from_solid[component]))
        extends_beyond_normal_aa = max_distance >= 3.0
        if not broad or not material or not extends_beyond_normal_aa:
            continue
        # Avoid duplicate reporting when the neutral-component gate already
        # caught the exact same source shadow.
        if np.any(mask & component):
            continue
        mask |= component
        failures.append({
            "kind": "fuzzy-floor-contact",
            "bounds": record["bounds"],
            "visible_pixels": record["visible_pixels"],
            "alpha_mass": round(record["alpha_mass"], 3),
            "max_distance_from_solid": round(max_distance, 3),
        })

    # A semantic person mask can retain a compact, almost opaque reflection
    # directly beneath a black shoe.  Unlike the broad/translucent floor
    # shadows above, this failure is triangular rather than elongated and can
    # therefore look like a pale wedge glued to the outsole on dark UI.  It is
    # not safe to cut an opaque neutral shape by geometry alone, so hard-reject
    # the source for regeneration.  Requiring a material-size component at the
    # foot, exterior white-plate exposure, and nearby dark footwear keeps
    # patent highlights (enclosed by the shoe), skin highlights, and fine heel
    # stems out of this rule.
    pale_flare_tone = (
        (minimum >= SHOE_FLARE_MIN_RGB)
        & (maximum <= SHOE_FLARE_MAX_RGB)
        & (spread <= SHOE_FLARE_MAX_SPREAD)
        & (alpha >= VISIBLE_ALPHA)
    )
    flare_labels, flare_records = _component_records(pale_flare_tone, alpha)
    near_plate = _near_plate(source)
    flare_min_pixels = max(64, round(person_width * 0.30))
    micro_flare_min_pixels = max(
        SHOE_FLARE_MICRO_MIN_PIXELS, round(person_width * 0.16))
    flare_min_height = max(6, round(person_height * 0.01))
    flare_min_width = max(8, round(person_width * 0.06))
    dark_footwear = (maximum <= 80) & (alpha >= VISIBLE_ALPHA)
    distance_from_transparent = cv2.distanceTransform(
        (alpha >= VISIBLE_ALPHA).astype(np.uint8), cv2.DIST_L2, 5)
    flare_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    for record in flare_records:
        left, top, width, component_height = record["bounds"]
        if top + component_height < floor_start:
            continue
        component = _record_mask(flare_labels, record)
        if np.any(mask & component):
            continue
        macro_flare = (
            record["visible_pixels"] >= flare_min_pixels
            and width >= flare_min_width
            and component_height >= flare_min_height
        )
        # The real side-view regression is not one broad shadow. Two compact
        # opaque plate islands remain under/inside the pumps (roughly 40 px
        # apiece), so a macro-only area threshold misses both. A micro flare
        # must have real two-dimensional thickness inside the semantic alpha;
        # ordinary one-pixel heel stems and silhouette antialiasing never do.
        # The stricter exterior-plate checks below then distinguish the island
        # from a patent-leather highlight enclosed by its dark shoe.
        visible_pixels = max(1, record["visible_pixels"])
        deep_pixels = int(np.count_nonzero(
            component & (distance_from_transparent >= 2.0)))
        depth_ratio = deep_pixels / visible_pixels
        aspect_ratio = max(
            width / max(1, component_height),
            component_height / max(1, width),
        )
        micro_flare = (
            record["visible_pixels"] >= micro_flare_min_pixels
            and record["alpha_mass"] >= SHOE_FLARE_MICRO_MIN_ALPHA_MASS
            and width >= 4
            and component_height >= 4
            and aspect_ratio <= 2.5
            and depth_ratio >= SHOE_FLARE_MICRO_MIN_DEPTH_RATIO
        )
        if not macro_flare and not micro_flare:
            continue
        ring = cv2.dilate(
            component.astype(np.uint8), flare_kernel,
            iterations=1).astype(bool) & ~component
        ring_pixels = int(np.count_nonzero(ring))
        visible_ring = ring & (alpha >= VISIBLE_ALPHA)
        visible_ring_pixels = int(np.count_nonzero(visible_ring))
        exterior_plate = ring & near_plate & (alpha < VISIBLE_ALPHA)
        exterior_plate_pixels = int(np.count_nonzero(exterior_plate))
        dark_support_pixels = int(np.count_nonzero(ring & dark_footwear))
        exterior_ratio = exterior_plate_pixels / max(1, ring_pixels)
        dark_support_ratio = dark_support_pixels / max(1, visible_ring_pixels)
        minimum_exterior_ratio = (
            0.50 if micro_flare and not macro_flare else 0.30)
        minimum_dark_support = 5 if micro_flare and not macro_flare else 8
        minimum_dark_ratio = 0.12 if micro_flare and not macro_flare else 0.08
        if (
                exterior_ratio < minimum_exterior_ratio
                or dark_support_pixels < minimum_dark_support
                or dark_support_ratio < minimum_dark_ratio):
            continue
        mask |= component
        failures.append({
            "kind": "pale-shoe-flare",
            "scale": "micro" if micro_flare and not macro_flare else "macro",
            "bounds": record["bounds"],
            "visible_pixels": record["visible_pixels"],
            "alpha_mass": round(record["alpha_mass"], 3),
            "interior_depth_ratio": round(depth_ratio, 4),
            "exterior_plate_ring_ratio": round(exterior_ratio, 4),
            "dark_footwear_ring_ratio": round(dark_support_ratio, 4),
        })
    return {"mask": mask, "components": failures}


def _plate_connected_neutral_fringe(
        source, baseline_alpha, plate_seed, blocked=None):
    """Extend a proven plate leak through its neutral compressed/shadow fringe.

    The core gate deliberately uses an almost exact-white definition.  Around a
    real provider gap, resampling can grade that same plate slightly below
    white. Deleting only the exact-white core leaves a conspicuous pale island
    on a dark desktop. Growth is restricted to near-white source pixels; it can
    never flood through charcoal/gray clothing or black shoe/heel detail.
    """
    walkable = _near_plate(source) & (baseline_alpha >= VISIBLE_ALPHA)
    if blocked is not None:
        if blocked.shape != baseline_alpha.shape:
            raise ValueError("blocked body alpha mask dimensions differ")
        protected = cv2.dilate(
            blocked.astype(np.uint8),
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
            iterations=1,
        ).astype(bool)
        walkable &= ~protected
    # White/off-white wardrobe is blocked above, and compact face/specular
    # details are explicitly protected. Every remaining near-plate alpha pixel
    # is source-proven background contamination, including fragmented one-pixel
    # islands with no strict-white seed. Removing the full set prevents dotted
    # zipper halos that a connected-component minimum would miss.
    return walkable & ~plate_seed


def _white_matte_edges(source, rgba, blocked=None):
    """Find chromatic silhouette pixels still preblended with white plate.

    Generated sources are ordinary opaque RGB images on white. Vision supplies
    a semantic alpha, but retaining the already blended edge RGB and applying
    alpha again creates a pale zipper on dark backgrounds. For the narrow
    silhouette band only, fit each pixel to its nearest opaque interior colour
    mixed with white. This is colour evidence, not an alpha erosion heuristic.
    """
    alpha = rgba[:, :, 3]
    visible = alpha >= VISIBLE_ALPHA
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    interior = cv2.erode(
        visible.astype(np.uint8), kernel, iterations=1).astype(bool)
    core = interior & (alpha >= 240) & ~_near_plate(source)
    if blocked is not None:
        if blocked.shape != alpha.shape:
            raise ValueError("blocked body matte mask dimensions differ")
        protected_margin = cv2.dilate(
            blocked.astype(np.uint8),
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)),
            iterations=1,
        ).astype(bool)
        core &= ~protected_margin
    else:
        protected_margin = np.zeros(alpha.shape, dtype=bool)
    if not np.any(core):
        return {
            "mask": np.zeros(alpha.shape, dtype=bool),
            "nearest_bgr": rgba[:, :, :3].copy(),
            "visible_pixels": 0,
            "alpha_mass": 0.0,
            "components": 0,
            "median_white_mix": 0.0,
            "p95_white_mix": 0.0,
        }

    distance, labels = cv2.distanceTransformWithLabels(
        (~core).astype(np.uint8), cv2.DIST_L2, 5,
        labelType=cv2.DIST_LABEL_PIXEL)
    core_y, core_x = np.nonzero(core)
    core_labels = labels[core]
    lookup_size = int(np.max(labels)) + 1
    lookup_y = np.zeros(lookup_size, dtype=np.int32)
    lookup_x = np.zeros(lookup_size, dtype=np.int32)
    lookup_y[core_labels] = core_y
    lookup_x[core_labels] = core_x
    nearest = rgba[lookup_y[labels], lookup_x[labels], :3]

    edge_band = visible & ~interior & ~protected_margin
    candidate = edge_band & (distance <= WHITE_MATTE_MAX_DISTANCE)
    observed = rgba[:, :, :3].astype(np.float32)
    foreground = nearest.astype(np.float32)
    denominator = 255.0 - foreground
    useful_channel = denominator >= 20.0
    useful_count = np.sum(useful_channel, axis=2)
    ratio = np.zeros(observed.shape, dtype=np.float32)
    np.divide(
        observed - foreground, denominator,
        out=ratio, where=useful_channel)
    white_mix = np.sum(
        np.where(useful_channel, ratio, 0.0), axis=2
    ) / np.maximum(1, useful_count)
    white_mix = np.clip(white_mix, 0.0, 1.0)
    predicted = (
        foreground * (1.0 - white_mix[:, :, None])
        + 255.0 * white_mix[:, :, None]
    )
    rms = np.sqrt(np.mean(np.square(observed - predicted), axis=2))
    mask = (
        candidate
        & (useful_count >= 2)
        & (white_mix >= 0.08)
        & (white_mix <= 0.97)
        & (rms <= WHITE_MATTE_MAX_RMS)
    )
    pixels = int(np.count_nonzero(mask))
    alpha_mass = float(np.sum(alpha[mask].astype(np.float64)) / 255.0)
    component_count = 0
    if pixels:
        component_count = int(cv2.connectedComponents(
            mask.astype(np.uint8), connectivity=8)[0] - 1)
        mixes = white_mix[mask]
        median_mix = float(np.median(mixes))
        p95_mix = float(np.quantile(mixes, 0.95))
    else:
        median_mix = 0.0
        p95_mix = 0.0
    return {
        "mask": mask,
        "nearest_bgr": nearest,
        "visible_pixels": pixels,
        "alpha_mass": alpha_mass,
        "components": component_count,
        "median_white_mix": median_mix,
        "p95_white_mix": p95_mix,
    }


def _decontaminate_white_matte(source, rgba, blocked=None):
    """Replace white-preblended edge RGB while preserving alpha exactly."""
    evidence = _white_matte_edges(source, rgba, blocked=blocked)
    output = rgba.copy()
    output[:, :, :3][evidence["mask"]] = evidence["nearest_bgr"][
        evidence["mask"]]
    return output, evidence


def quality(
        source, rgba, *, baseline_alpha=None, baseline_highlights=None,
        replacement_head_mask=None):
    """Audit one final body cutout and return JSON-safe hard-gate metrics."""
    _validate(source, rgba)
    contract = _plate_contract(source)
    plate = _plate_leaks(
        source, rgba, replacement_head_mask=replacement_head_mask)
    shadow = _floor_shadow(source, rgba)
    alpha = rgba[:, :, 3]
    protected = plate["protected_mask"] | plate["ambiguity_block_mask"]
    protected_margin = cv2.dilate(
        protected.astype(np.uint8),
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
        iterations=1,
    ).astype(bool)
    residual_near_plate = (
        _near_plate(source) & (alpha > 0) & ~protected_margin)
    visible_near_plate = residual_near_plate & (alpha >= VISIBLE_ALPHA)
    residual_near_plate_pixels = int(np.count_nonzero(residual_near_plate))
    visible_near_plate_pixels = int(np.count_nonzero(visible_near_plate))
    residual_near_plate_mass = float(
        np.sum(alpha[residual_near_plate].astype(np.float64)) / 255.0)
    visible_near_plate_mass = float(
        np.sum(alpha[visible_near_plate].astype(np.float64)) / 255.0)
    matte = _white_matte_edges(source, rgba, blocked=protected)
    material_white_matte = (
        matte["visible_pixels"] >= WHITE_MATTE_MIN_PIXELS
        or matte["alpha_mass"] >= WHITE_MATTE_MIN_ALPHA_MASS
    )
    detail_loss = 0
    if baseline_alpha is not None:
        if baseline_alpha.shape != alpha.shape:
            raise ValueError("baseline and final body alpha dimensions differ")
        # Only strict/near-white source plate is authorised for repair. Pale
        # skin, charcoal fabric, gray footwear, black heel stems, and every
        # other non-plate source pixel remain protected—even one pixel wide.
        # Reconstruct compact source-supported highlights from the *baseline*
        # alpha so deleting one cannot hide it from this preservation audit.
        if baseline_highlights is None:
            _highlight_labels, baseline_highlights, _highlight_records = (
                _compact_supported_highlights(source, baseline_alpha))
        elif baseline_highlights.shape != alpha.shape:
            raise ValueError(
                "baseline highlight and final body alpha dimensions differ")
        source_subject = ~_near_plate(source) | baseline_highlights
        lost = (
            (baseline_alpha >= VISIBLE_ALPHA)
            & (alpha < VISIBLE_ALPHA)
            & source_subject
        )
        detail_loss = int(np.count_nonzero(lost))
    valid = (
        contract["valid"]
        and not plate["exterior"]
        and not plate["enclosed"]
        and not plate["ambiguous_white"]
        and not shadow["components"]
        and residual_near_plate_pixels == 0
        and not material_white_matte
        and detail_loss == 0
    )
    reasons = []
    if not contract["valid"]:
        reasons.append(
            "provider source is not the required uniform pure-white plate")
    if plate["exterior"]:
        reasons.append("source-plate white leaked through an exterior body gap")
    if plate["enclosed"]:
        reasons.append("source-plate white filled an enclosed body or shoe gap")
    if plate["ambiguous_white"]:
        reasons.append(
            "white/off-white subject detail is ambiguous against the plate; "
            "regenerate in a compliant non-white wardrobe")
    if shadow["components"]:
        shadow_kinds = {item["kind"] for item in shadow["components"]}
        if "pale-shoe-flare" in shadow_kinds:
            reasons.append(
                "opaque pale floor/shoe flare remains beneath footwear; "
                "regenerate this view")
        if shadow_kinds - {"pale-shoe-flare"}:
            reasons.append(
                "neutral floor, wall, or contact shadow remains in body alpha")
    if residual_near_plate_pixels:
        if visible_near_plate_pixels:
            detail = (
                f"{visible_near_plate_pixels} visible px; "
                f"{residual_near_plate_pixels} total px; "
                f"alpha mass {residual_near_plate_mass:.3f}")
        else:
            # ``VISIBLE_ALPHA`` is the component-analysis threshold, not a
            # promise that lower alpha is literally invisible on dark UI.
            # Keep the zero-residual hard gate, but never emit the misleading
            # and apparently contradictory phrase ``0 visible px``.
            detail = (
                f"{residual_near_plate_pixels} sub-threshold px; "
                f"alpha mass {residual_near_plate_mass:.3f}")
        reasons.append(
            "near-white plate contamination remains on the antialiased body edge "
            f"({detail})")
    if material_white_matte:
        reasons.append(
            "chromatic subject edge remains preblended with white plate "
            f"({matte['visible_pixels']}px)")
    if detail_loss:
        reasons.append(
            f"source-supported skin, limb, shoe, or heel detail lost ({detail_loss}px)")
    return {
        "available": contract["valid"],
        "valid": valid,
        "reason": (
            "body gaps are transparent and source-supported details are intact"
            if valid else "; ".join(reasons)
        ),
        "exterior_plate_components": plate["exterior"],
        "enclosed_plate_components": plate["enclosed"],
        "ambiguous_white_subject_components": plate["ambiguous_white"],
        "protected_white_detail_components": plate["protected_white"],
        "floor_shadow_components": shadow["components"],
        "residual_near_plate_pixels": residual_near_plate_pixels,
        "residual_near_plate_alpha_mass": round(
            residual_near_plate_mass, 3),
        "visible_near_plate_edge_pixels": visible_near_plate_pixels,
        "visible_near_plate_alpha_mass": round(visible_near_plate_mass, 3),
        "white_matte_edge_pixels": matte["visible_pixels"],
        "white_matte_edge_alpha_mass": round(matte["alpha_mass"], 3),
        "white_matte_edge_components": matte["components"],
        "white_matte_median_mix": round(matte["median_white_mix"], 4),
        "white_matte_p95_mix": round(matte["p95_white_mix"], 4),
        "lost_source_subject_pixels": detail_loss,
        "strict_white_border_ratio": contract["strict_white_border_ratio"],
    }


def refine(source, rgba, *, replacement_head_mask=None):
    """Remove only proven plate pixels, then run the body hard gate.

    Cast shadows are reported but deliberately not cut: a dark neutral pixel
    touching a shoe can be either shadow or anatomy.  The caller must regenerate
    that provider plate instead of accepting a destructive guess.
    """
    _validate(source, rgba)
    baseline = rgba[:, :, 3].copy()
    plate = _plate_leaks(
        source, rgba, replacement_head_mask=replacement_head_mask)
    output = rgba.copy()
    strict_remove = plate["exterior_mask"] | plate["enclosed_mask"]
    blocked = plate["protected_mask"] | plate["ambiguity_block_mask"]
    fringe_remove = _plate_connected_neutral_fringe(
        source, baseline, strict_remove, blocked=blocked)
    protected_margin = cv2.dilate(
        blocked.astype(np.uint8),
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
        iterations=1,
    ).astype(bool)
    faint_plate_remove = (
        _near_plate(source)
        & (baseline > 0)
        & (baseline < VISIBLE_ALPHA)
        & ~protected_margin
    )
    remove = strict_remove | fringe_remove | faint_plate_remove
    output[:, :, 3][remove] = 0
    output[:, :, :3][output[:, :, 3] == 0] = 0
    output, matte_repair = _decontaminate_white_matte(
        source, output, blocked=blocked)
    report = quality(
        source, output, baseline_alpha=baseline,
        baseline_highlights=plate["supported_highlight_mask"],
        replacement_head_mask=replacement_head_mask)
    report["repaired_exterior_plate_components"] = plate["exterior"]
    report["repaired_enclosed_plate_components"] = plate["enclosed"]
    report["preserved_ambiguous_white_subject_components"] = (
        plate["ambiguous_white"])
    report["removed_plate_fringe_pixels"] = int(np.count_nonzero(
        fringe_remove & (baseline > 0)))
    report["removed_faint_plate_pixels"] = int(np.count_nonzero(
        faint_plate_remove))
    report["removed_plate_pixels"] = int(np.count_nonzero(remove & (baseline > 0)))
    report["decontaminated_white_matte_pixels"] = matte_repair["visible_pixels"]
    report["decontaminated_white_matte_alpha_mass"] = round(
        matte_repair["alpha_mass"], 3)
    return output, report
