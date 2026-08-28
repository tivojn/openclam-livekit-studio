"""Avatar registry + build orchestrator.

An avatar is a self-contained folder:

    avatars/<slug>/
        source.png        the photo the user uploaded
        source-keyframe.png immutable crop of the uploaded photo
        head.png          generated head-only identity reference
        keyframe.png      face-centred 1024 square built from head.png
        raw/v_*.png       untouched generator output (kept for re-composing)
        visemes/v_*.jpg   pose-locked, mouth-only composites - the shipping bank
        preview.mp4       cross-blended demo sentence
        sheet.jpg         mouth-zoom contact sheet of the whole bank
        diag/             masks, landmark overlay, per-shape metrics
        manifest.json     status, metrics, warnings, build log

Swapping the avatar is therefore just pointing `active.json` at another slug -
nothing else in the project is avatar-specific.
"""
import os, re, json, time, shutil, datetime, threading, traceback, tempfile, copy, uuid
from . import anatomy, prep, generate, compose, render, visemes, measure, rig

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath(os.environ.get("OPENCLAM_DATA_DIR", CODE_ROOT))
AVATARS = os.path.join(ROOT, "avatars")
ACTIVE = os.path.join(ROOT, "active.json")
# The optional second on-desk avatar. It renders in its own desktop window,
# mirrored to the LEFT screen edge while the active avatar owns the right.
COMPANION = os.path.join(ROOT, "companion.json")
_locks = {}
_write_lock = threading.Lock()   # progress callbacks fire from worker threads
_SLUG = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62})$")


def valid_slug(slug):
    return isinstance(slug, str) and bool(_SLUG.fullmatch(slug))


def slugify(s):
    value = re.sub(r"[^a-zA-Z0-9]+", "-", (s or "avatar").strip()).strip("-").lower()
    return (value[:63].rstrip("-") or "avatar")


def adir(slug):
    if not valid_slug(slug):
        raise ValueError("invalid avatar slug")
    root = os.path.abspath(AVATARS)
    full = os.path.abspath(os.path.join(root, slug))
    if os.path.commonpath((root, full)) != root:
        raise ValueError("avatar path escapes the registry")
    return full


def manifest_path(slug):
    return os.path.join(adir(slug), "manifest.json")


def read_manifest(slug):
    try:
        with open(manifest_path(slug)) as f:
            return json.load(f)
    except Exception:
        return None


def write_manifest(slug, m):
    """Atomic and thread-safe: worker threads report progress concurrently, so a
    shared temp filename would let one thread rename the file out from under
    another."""
    with _write_lock:
        os.makedirs(adir(slug), mode=0o700, exist_ok=True)
        m["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
        tmp = f"{manifest_path(slug)}.{os.getpid()}.{threading.get_ident()}.tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(m, f, indent=1)
            os.chmod(tmp, 0o600)
            os.replace(tmp, manifest_path(slug))
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    return m


def list_avatars():
    os.makedirs(AVATARS, mode=0o700, exist_ok=True)
    out = []
    for slug in sorted(os.listdir(AVATARS)):
        if valid_slug(slug) and os.path.isdir(adir(slug)):
            m = read_manifest(slug)
            if m:
                out.append(m)
    active = get_active()
    for m in out:
        m["active"] = (m["slug"] == active)
    return out


def get_active():
    try:
        with open(ACTIVE) as f:
            slug = json.load(f).get("slug")
        return slug if valid_slug(slug) else None
    except Exception:
        return None


def set_active(slug):
    if not os.path.isdir(adir(slug)):
        raise ValueError(f"unknown avatar: {slug}")
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    descriptor, tmp = tempfile.mkstemp(prefix=".active-", dir=ROOT)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(dict(slug=slug,
                           set_at=datetime.datetime.now().isoformat(timespec="seconds")),
                      handle, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, ACTIVE)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return slug


def get_companion():
    try:
        with open(COMPANION) as f:
            slug = json.load(f).get("slug")
        return slug if valid_slug(slug) else None
    except Exception:
        return None


def set_companion(slug):
    """Set (or with None/empty, clear) the second on-desk avatar."""
    if not slug:
        try:
            os.remove(COMPANION)
        except OSError:
            pass
        return None
    if not os.path.isdir(adir(slug)):
        raise ValueError(f"unknown avatar: {slug}")
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    descriptor, tmp = tempfile.mkstemp(prefix=".companion-", dir=ROOT)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(dict(slug=slug,
                           set_at=datetime.datetime.now().isoformat(timespec="seconds")),
                      handle, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, COMPANION)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return slug


def delete_avatar(slug):
    shutil.rmtree(adir(slug), ignore_errors=True)
    if get_active() == slug:
        try:
            os.remove(ACTIVE)
        except OSError:
            pass
    if get_companion() == slug:
        set_companion(None)


# ---------------------------------------------------------------- create

def _reserve_avatar_directory(requested_slug):
    """Atomically reserve a unique avatar directory and return (slug, path)."""
    os.makedirs(AVATARS, mode=0o700, exist_ok=True)
    base, index = requested_slug, 2
    slug = requested_slug
    while True:
        directory = adir(slug)
        try:
            # os.mkdir is the reservation.  Unlike check-then-makedirs, two
            # simultaneous uploads can never acquire the same directory.
            os.mkdir(directory, mode=0o700)
            return slug, directory
        except FileExistsError:
            suffix = f"-{index}"
            slug = f"{base[:63 - len(suffix)].rstrip('-')}{suffix}"
            index += 1


def create_avatar(image_path, name=None, slug=None):
    """Register an uploaded face image and prepare its keyframe. No generation yet -
    this returns fast so the UI can show the crop and any pose warnings first."""
    name = name or os.path.splitext(os.path.basename(image_path))[0]
    name = re.sub(r"[\x00-\x1f\x7f]+", " ", str(name)).strip()[:120] or "Avatar"
    slug = slugify(slug or name)
    slug, d = _reserve_avatar_directory(slug)
    try:
        ext = os.path.splitext(image_path)[1].lower()
        if ext in prep.HEIC_EXTENSIONS:
            # Everything downstream reads the stored source with OpenCV, which
            # has no HEIC codec - so the source of record becomes a PNG.
            src = os.path.join(d, "source.png")
            prep.decode_heic(image_path, src)
        else:
            src = os.path.join(d, "source" + ext)
            if os.path.abspath(image_path) != os.path.abspath(src):
                shutil.copyfile(image_path, src)
        os.chmod(src, 0o600)

        source_key = os.path.join(d, "source-keyframe.png")
        key = os.path.join(d, "keyframe.png")
        metrics = prep.build_keyframe(
            src, source_key, diag_dir=os.path.join(d, "diag"),
            allow_stylized=True)
        shutil.copy2(source_key, key)

        return write_manifest(slug, dict(
            slug=slug, name=name,
            created=datetime.datetime.now().isoformat(timespec="seconds"),
            source=os.path.basename(src), source_keyframe="source-keyframe.png",
            keyframe="keyframe.png",
            status="draft", progress=dict(done=0, total=len(visemes.ORDER)),
            metrics=metrics, warnings=metrics.get("warnings", []),
            visemes=[], preview=None, sheet=None, log=[]))
    except Exception:
        # This directory was reserved by this call and cannot contain a prior
        # avatar.  A rejected upload must not leave source-only ghosts that
        # consume names and appear in future maintenance scans.
        shutil.rmtree(d, ignore_errors=True)
        raise


# ---------------------------------------------------------------- build

RIG_ARTIFACTS = ("visemes", "diag", "runtime", "preview.mp4", "sheet.jpg")


def _source_medium(report):
    """Read new medium metadata while accepting early cartoon draft manifests."""
    report = report or {}
    medium = str(report.get("source_medium") or "").strip().lower()
    if medium:
        return medium
    legacy = str(report.get("source_mode") or "").strip().lower()
    if legacy.startswith("stylized"):
        return "illustration"
    return "photograph"


def _band_suggestion(keys):
    """Human guidance for a red line: the green band of each named slider."""
    parts = []
    for key in keys:
        spec = rig.CONTROLS.get(key)
        if not spec:
            continue
        parts.append(f"{spec['label']} {spec.get('safe_minimum', 0):.0f}–"
                     f"{spec.get('safe_maximum', 100):.0f}%")
    return ", ".join(parts) or "ease the sliders toward their green bands"


def _articulation_failure(row):
    if row["ratio"] > row["max_ratio"]:
        return (f"{row['name']} aperture {row['ratio']:.3f} exceeds "
                f"{row['max_ratio']:.2f}")
    minimum = row["want_width"] - 0.12
    maximum = row["want_width"] + 0.12
    return (f"{row['name']} width {row['width_ratio']:.2f}x neutral is outside "
            f"{minimum:.2f}-{maximum:.2f} (target {row['want_width']:.2f})")


HARD_APERTURE_MULTIPLIER = 1.35
HARD_WIDTH_ERROR = 0.18


class CalibrationRejected(RuntimeError):
    """A staged calibration failed without touching the published avatar.

    `repair` is deliberately JSON-safe so the server can hand the recovery
    straight to Facial calibration instead of making a non-technical owner
    translate an anatomy error back into slider values.
    """

    def __init__(self, message, repair):
        super().__init__(message)
        self.repair = repair


def _hard_articulation_rows(rows):
    """Only reject a clearly broken bank; landmark-scale near misses advise."""
    result = []
    for row in rows:
        aperture_limit = (float(row["max_ratio"]) * HARD_APERTURE_MULTIPLIER
                          + measure.APERTURE_DETECTOR_EPSILON)
        width_error = abs(float(row["width_ratio"]) -
                          float(row["want_width"]))
        if (float(row["ratio"]) > aperture_limit or
                width_error > HARD_WIDTH_ERROR):
            result.append(row)
    return result


def _repair_value(profile, key, wanted):
    """Clamp an automatic repair to the control's validated green band."""
    spec = rig.CONTROLS[key]
    low = float(spec.get("safe_minimum", spec["minimum"]))
    high = float(spec.get("safe_maximum", spec["maximum"]))
    step = float(spec.get("step") or 1.0)
    value = max(low, min(high, float(wanted)))
    return round(round(value / step) * step, 3)


def articulation_repair(profile, rejected):
    """Turn measured mouth failures into a conservative editable profile.

    Aperture is primarily jaw travel, with a smaller lip contribution. Width
    belongs to lips and nasolabial motion. The calculation moves only those
    controls and never crosses their validated bands; the UI shows every
    change before the owner chooses the one-click retry or edits it manually.
    """
    current = rig.normalize(profile)
    suggested = copy.deepcopy(current)
    rejected = list(rejected or [])
    aperture = [row for row in rejected
                if float(row["ratio"]) > float(row["max_ratio"])
                + measure.APERTURE_DETECTOR_EPSILON]
    width = [row for row in rejected
             if abs(float(row["width_ratio"]) -
                    float(row["want_width"])) > 0.12]

    if aperture:
        # Aim a little inside the limit so detector jitter does not immediately
        # reject the retry. Jaw carries most of vertical opening; lips retain
        # enough motion to keep consonants readable.
        factor = min(float(row["max_ratio"]) /
                     max(float(row["ratio"]), 1e-6) for row in aperture)
        factor = max(.45, min(.92, factor * .94))
        suggested["jaw"] = _repair_value(
            current, "jaw", current["jaw"] * factor)
        suggested["lips"] = _repair_value(
            current, "lips", current["lips"] * (.72 + .28 * factor))

    if width:
        too_wide = [row for row in width
                    if float(row["width_ratio"]) >
                    float(row["want_width"]) + .12]
        too_narrow = [row for row in width
                      if float(row["width_ratio"]) <
                      float(row["want_width"]) - .12]
        if too_wide:
            factor = min(float(row["want_width"]) /
                         max(float(row["width_ratio"]), 1e-6)
                         for row in too_wide)
            suggested["lips"] = _repair_value(
                current, "lips", min(suggested["lips"],
                                     current["lips"] * factor * .96))
            suggested["nasolabial"] = _repair_value(
                current, "nasolabial", current["nasolabial"] * factor)
        if too_narrow and not too_wide:
            factor = max(float(row["want_width"]) /
                         max(float(row["width_ratio"]), 1e-6)
                         for row in too_narrow)
            suggested["lips"] = _repair_value(
                current, "lips", current["lips"] * min(1.16, factor))
            suggested["nasolabial"] = _repair_value(
                current, "nasolabial",
                current["nasolabial"] * min(1.12, factor))

    suggested["preset"] = "custom"
    changes = []
    reasons = [_articulation_failure(row) for row in rejected]
    for key in ("jaw", "lips", "nasolabial"):
        before, after = current[key], suggested[key]
        if before != after:
            changes.append(dict(
                control=key, label=rig.CONTROLS[key]["label"],
                before=before, after=after))
    return dict(
        kind="articulation", profile=suggested, changes=changes,
        rejected_items=[row["name"] for row in rejected], reasons=reasons,
    )


# A tilted source selfie must not become a tilted avatar: the canonical
# head is prompted frontal, but providers sometimes keep the source pose
# (rachel, 2026-08-01: yaw -9.1, pitch 23, roll 18, foreshortening 0.56 -
# and every mouth stage after degrades: viseme transfer, landmark accuracy,
# the dental band). Measured limits; outside them the head regenerates with
# a corrective note, best candidate wins, and a stubborn tilt ships with an
# ADVISORY - never a block.
FRONTAL_YAW = 8.0
FRONTAL_ROLL = 6.0
FRONTAL_PITCH = (-6.0, 16.0)
FRONTAL_FORESHORTENING = 0.85


def _frontality_issues(metrics):
    issues = []
    yaw = float(metrics.get("yaw") or 0.0)
    roll = float(metrics.get("roll") or 0.0)
    pitch = float(metrics.get("pitch") or 0.0)
    depth = float(metrics.get("foreshortening") or 1.0)
    if abs(yaw) > FRONTAL_YAW:
        issues.append(f"yaw {yaw:+.1f}deg (want within +/-{FRONTAL_YAW:.0f})")
    if abs(roll) > FRONTAL_ROLL:
        issues.append(f"roll {roll:+.1f}deg (want within +/-{FRONTAL_ROLL:.0f})")
    if not FRONTAL_PITCH[0] <= pitch <= FRONTAL_PITCH[1]:
        issues.append(f"pitch {pitch:+.1f}deg (want {FRONTAL_PITCH[0]:.0f}"
                      f"..{FRONTAL_PITCH[1]:.0f})")
    if depth < FRONTAL_FORESHORTENING:
        issues.append(f"foreshortening {depth:.2f} "
                      f"(want >= {FRONTAL_FORESHORTENING:.2f})")
    return issues


def _frontality_score(metrics):
    yaw = abs(float(metrics.get("yaw") or 0.0)) / FRONTAL_YAW
    roll = abs(float(metrics.get("roll") or 0.0)) / FRONTAL_ROLL
    pitch = float(metrics.get("pitch") or 0.0)
    pitch_excess = max(FRONTAL_PITCH[0] - pitch, pitch - FRONTAL_PITCH[1], 0.0) / 10.0
    depth = max(0.0, FRONTAL_FORESHORTENING
                - float(metrics.get("foreshortening") or 1.0)) / 0.10
    return yaw + roll + pitch_excess + depth


def raw_render_gaps(slug):
    raw_dir = os.path.join(adir(slug), "raw")
    return [name for name in visemes.ORDER
            if not _raw_render_path(raw_dir, name)]


def _raw_render_path(raw_dir, name):
    for extension in ("png", "jpg"):
        path = os.path.join(raw_dir, f"v_{name}.{extension}")
        if os.path.isfile(path):
            return path
    return None


def _stage_safe_th(raw_dir, emit):
    """Keep a malformed generated tongue out of a local rebuild.

    Retained generator files remain untouched.  Recomposition works from a
    private copy and substitutes a centred, hidden-tongue consonant only when
    the TH-specific pixel/landmark check finds the conspicuous lateral defect.
    """
    th_path = _raw_render_path(raw_dir, "TH")
    issue = measure.th_tongue_issue(th_path)
    if not issue:
        return False
    donor = _raw_render_path(raw_dir, "DD") or _raw_render_path(raw_dir, "SS")
    if not donor:
        raise CalibrationRejected(
            "TH tongue is off-centre and no safe hidden-tongue plate is available",
            dict(kind="tongue", profile=None, changes=[],
                 rejected_items=["TH"], reasons=[
                     f"Tongue offset {issue['offset']:+.2f} mouth widths"
                 ]),
        )
    shutil.copy2(donor, th_path)
    emit("  TH tongue is off-centre "
         f"({issue['offset']:+.2f} mouth widths) - using the centred, "
         "hidden-tongue consonant fallback in this rebuild")
    return True


SAFE_VISEME_DONORS = {
    # Every speech shape has a conservative neighbouring family.  These are
    # deliberately ordinary generated plates, not a synthetic repaint: when a
    # provider result remains anatomically unsafe or cannot be composed, the
    # first build may substitute one of these only in its disposable raw copy.
    # The paid provider render in raw/ is retained byte-for-byte for diagnosis
    # or a future rebuild.
    "closed": ("PP", "FF"),
    "PP": ("closed", "FF"),
    "FF": ("SS", "closed", "ih"),
    "TH": ("FF", "RR", "closed"),
    "DD": ("RR", "ih", "closed"),
    # IH and closed preserve the near-neutral width NN requires. RR is
    # deliberately narrower (target 0.90) and can keep a broken NN below its
    # hard 0.82x width floor even after the fallback.
    "nn": ("ih", "closed", "RR"),
    "kk": ("ih", "RR", "closed"),
    "CH": ("RR", "FF", "closed"),
    "SS": ("FF", "RR", "closed"),
    "RR": ("closed", "ih", "FF"),
    "ah": ("eh", "ih", "closed"),
    "eh": ("ih", "ah", "closed"),
    "ih": ("closed", "FF", "eh"),
    "oh": ("DD", "ih", "closed"),
    # Cartoon providers often draw OO wider rather than rounder.  Neutral is
    # the safest narrow fallback; DD/PP can be wider than OO's hard ceiling.
    "oo": ("closed", "DD", "RR", "PP"),
}

# Backward-compatible name used by older local tests and rollback manifests.
SAFE_CONSONANT_DONORS = SAFE_VISEME_DONORS


def _required_speech_gaps(report):
    published = {str(row.get("name") or "") for row in (report or [])}
    return [name for name in visemes.SPEECH_ORDER if name not in published]


def _replace_staged_render(raw_dir, target_name, donor_path):
    """Install a donor in a disposable raw directory with a valid suffix."""
    donor_extension = os.path.splitext(donor_path)[1].lower()
    if donor_extension not in {".png", ".jpg"}:
        donor_extension = ".png"
    target = os.path.join(raw_dir, f"v_{target_name}{donor_extension}")
    # If the failed provider plate used the other extension, remove it from the
    # private stage so _raw_render_path cannot select it ahead of the donor.
    for extension in (".png", ".jpg"):
        stale = os.path.join(raw_dir, f"v_{target_name}{extension}")
        if stale != target and os.path.isfile(stale):
            os.unlink(stale)
    shutil.copy2(donor_path, target)
    return target


def _stage_safe_visemes(raw_dir, rejected, emit):
    """Replace irreparable or uncomposable speech plates in a private stage."""
    unsafe = {str(row.get("name") or "") for row in (rejected or [])}
    repairs = {}
    for name in visemes.SPEECH_ORDER:
        if name not in unsafe or name not in SAFE_VISEME_DONORS:
            continue
        donor_name = next((candidate for candidate in SAFE_VISEME_DONORS[name]
                           if candidate not in unsafe
                           and _raw_render_path(raw_dir, candidate)), None)
        if not donor_name:
            continue
        donor = _raw_render_path(raw_dir, donor_name)
        _replace_staged_render(raw_dir, name, donor)
        repairs[name] = donor_name
        emit(f"  {name}: generated plate stayed unsafe or uncomposable "
             f"- using nearby {donor_name} speech plate in this private rebuild")
    return repairs


def _stage_safe_consonants(raw_dir, rejected, emit):
    """Compatibility wrapper for the original consonant-only repair API."""
    return _stage_safe_visemes(raw_dir, rejected, emit)


def _apply_recorded_stage_repairs(raw_dir, repairs, emit):
    """Reapply private donor repairs recorded by the last good publish.

    The retained generator outputs remain untouched in the avatar directory.
    Recomposition starts from a disposable copy, so a previously approved
    consonant fallback must be restored there before the first articulation
    audit; otherwise every slider-only rebuild rediscovers the same malformed
    source plates and needlessly lowers the owner's calibration again.
    """
    applied = {}
    for target_name, donor_name in dict(repairs or {}).items():
        if target_name not in SAFE_VISEME_DONORS:
            continue
        if donor_name not in SAFE_VISEME_DONORS[target_name]:
            continue
        donor = _raw_render_path(raw_dir, donor_name)
        if not donor:
            continue
        _replace_staged_render(raw_dir, target_name, donor)
        applied[target_name] = donor_name
        emit(f"  {target_name}: restoring the published {donor_name} safety "
             "plate in this private rebuild")
    return applied


def _remove_artifact(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.remove(path)


def _snapshot_live(slug, prefix="rollback.rig"):
    directory = adir(slug)
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    name = f"{prefix}-{stamp}"
    destination = os.path.join(directory, name)
    if os.path.exists(destination):
        destination += f"-{uuid.uuid4().hex[:6]}"
        name = os.path.basename(destination)
    os.makedirs(destination)
    for artifact in RIG_ARTIFACTS:
        source = os.path.join(directory, artifact)
        target = os.path.join(destination, artifact)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        elif os.path.isfile(source):
            shutil.copy2(source, target)
    manifest_file = os.path.join(directory, "manifest.json")
    if os.path.isfile(manifest_file):
        shutil.copy2(
            manifest_file, os.path.join(destination, "manifest.json"))
    return name


def _publish_stage(slug, stage_dir, manifest):
    directory = adir(slug)
    missing = [artifact for artifact in RIG_ARTIFACTS
               if not os.path.exists(os.path.join(stage_dir, artifact))]
    if missing:
        raise RuntimeError(f"staging is incomplete: {', '.join(missing)}")
    displaced = tempfile.mkdtemp(prefix=".rig-live-", dir=directory)
    live_manifest = os.path.join(directory, "manifest.json")
    displaced_manifest = os.path.join(displaced, "manifest.json")
    moved_new = []
    try:
        if os.path.isfile(live_manifest):
            os.replace(live_manifest, displaced_manifest)
        for artifact in RIG_ARTIFACTS:
            live = os.path.join(directory, artifact)
            if os.path.exists(live):
                os.replace(live, os.path.join(displaced, artifact))
        for artifact in RIG_ARTIFACTS:
            staged = os.path.join(stage_dir, artifact)
            os.replace(staged, os.path.join(directory, artifact))
            moved_new.append(artifact)
        write_manifest(slug, manifest)
    except Exception:
        for artifact in moved_new:
            _remove_artifact(os.path.join(directory, artifact))
        for artifact in RIG_ARTIFACTS:
            previous = os.path.join(displaced, artifact)
            if os.path.exists(previous):
                os.replace(previous, os.path.join(directory, artifact))
        if os.path.exists(live_manifest):
            os.unlink(live_manifest)
        if os.path.isfile(displaced_manifest):
            os.replace(displaced_manifest, live_manifest)
        raise
    finally:
        shutil.rmtree(displaced, ignore_errors=True)


def recompose_avatar(slug, profile, log=print, progress=None):
    manifest = read_manifest(slug)
    if not manifest or manifest.get("status") != "ready":
        raise ValueError(f"{slug} is not ready for calibration")
    profile = rig.normalize(profile)
    gaps = raw_render_gaps(slug)
    directory = adir(slug)
    source_report = manifest.get("source_metrics") or manifest.get("metrics") or {}
    allow_stylized = _source_medium(source_report) != "photograph"
    recorded_repairs = dict(manifest.get("local_viseme_repairs") or {})
    unrecoverable_gaps = []
    for name in gaps:
        donor_name = recorded_repairs.get(name)
        if (name not in SAFE_VISEME_DONORS or
                donor_name not in SAFE_VISEME_DONORS[name] or
                not _raw_render_path(os.path.join(directory, "raw"), donor_name)):
            unrecoverable_gaps.append(name)
    if unrecoverable_gaps:
        raise ValueError(
            f"missing retained renders: {', '.join(unrecoverable_gaps)}")
    stage = tempfile.mkdtemp(prefix=".rig-stage-", dir=directory)
    lines = []

    def emit(message):
        text = str(message)
        lines.append(text)
        log(text)

    def advance(stage_name, value, message):
        if progress:
            progress(stage_name, value, message)
        emit(message)

    try:
        stage_visemes = os.path.join(stage, "visemes")
        stage_diag = os.path.join(stage, "diag")
        stage_runtime = os.path.join(stage, "runtime")
        stage_raw = os.path.join(stage, "raw")
        stage_keyframe = os.path.join(stage, "keyframe.png")
        local_viseme_repairs = {}
        shutil.copy2(
            os.path.join(directory, "keyframe.png"), stage_keyframe)
        shutil.copytree(os.path.join(directory, "raw"), stage_raw)
        local_viseme_repairs.update(_apply_recorded_stage_repairs(
            stage_raw, recorded_repairs, emit))
        _stage_safe_th(stage_raw, emit)
        advance("compose", .08, "Recomposing retained local renders")
        report, key_metrics = compose.compose_all(
            stage_keyframe, stage_raw,
            stage_visemes, diag_dir=stage_diag, log=emit,
            profile=profile, allow_stylized=allow_stylized)
        expected = len(visemes.ORDER)
        if len(report) != expected:
            raise AssertionError(
                f"staged bank has {len(report)} of {expected} required shapes")
        advance("articulation", .48, "Checking mouth articulation")
        aperture, over = measure.audit(
            stage_keyframe, stage_visemes, log=emit,
            names=visemes.SPEECH_ORDER,
            allow_stylized=allow_stylized)
        hard_overs = _hard_articulation_rows(over)
        if hard_overs:
            repair = articulation_repair(profile, hard_overs)
            changed = ", ".join(
                f"{row['label']} {row['before']:.0f}%->{row['after']:.0f}%"
                for row in repair["changes"])
            emit("REJECTED unsafe articulation: " + ", ".join(
                _articulation_failure(row) for row in hard_overs))
            emit("Applying the safe slider retry locally: " +
                 (changed or "review the highlighted controls"))
            profile = repair["profile"]
            report, key_metrics = compose.compose_all(
                stage_keyframe, stage_raw, stage_visemes,
                diag_dir=stage_diag, log=emit, profile=profile,
                allow_stylized=allow_stylized)
            aperture, over = measure.audit(
                stage_keyframe, stage_visemes, log=emit,
                names=visemes.SPEECH_ORDER,
                allow_stylized=allow_stylized)
            hard_overs = _hard_articulation_rows(over)
            if hard_overs:
                local_viseme_repairs.update(_stage_safe_consonants(
                    stage_raw, hard_overs, emit))
                if local_viseme_repairs:
                    report, key_metrics = compose.compose_all(
                        stage_keyframe, stage_raw, stage_visemes,
                        diag_dir=stage_diag, log=emit, profile=profile,
                        allow_stylized=allow_stylized)
                    aperture, over = measure.audit(
                        stage_keyframe, stage_visemes, log=emit,
                        names=visemes.SPEECH_ORDER,
                        allow_stylized=allow_stylized)
                    hard_overs = _hard_articulation_rows(over)
            if hard_overs:
                repair = articulation_repair(profile, hard_overs)
                raise CalibrationRejected(
                    "Unsafe mouth articulation remains in " +
                    ", ".join(row["name"] for row in hard_overs), repair)
            emit("automatic local articulation repair passed")
        # Near misses remain advisory: the gate is for clearly broken anatomy,
        # not a detector wobble or a deliberate personal calibration.
        experimental = anatomy._experimental_keys(profile)
        soft_overs = list(over)
        for row in soft_overs:
            emit(f"  ADVISORY {row['name']} runs {row['ratio']:.3f} against "
                 f"target {row['max_ratio']:.2f} - published with this "
                 "experimental calibration")
        if experimental:
            emit(f"  ADVISORY experimental targets in play - "
                 f"{_band_suggestion(experimental)}")
        advance("preview", .58, "Rendering local preview")
        render.preview(
            stage_visemes, os.path.join(stage, "preview.mp4"),
            allow_stylized=allow_stylized)
        render.contact_sheet(
            stage_visemes, stage_keyframe,
            os.path.join(stage, "sheet.jpg"),
            allow_stylized=allow_stylized)
        advance("anatomy", .70, "Running anatomy QA")
        qa = anatomy.validate(
            stage_keyframe, stage_visemes, profile, diag_dir=stage_diag,
            allow_stylized=allow_stylized)
        emit("anatomy QA passed: " + anatomy.summary(qa))
        for warning in ((qa.get("structure_warnings") or [])
                        + (qa.get("dental_warnings") or [])):
            emit(f"  ADVISORY {warning}")
        worst_residual = max(row["resid_px"] for row in report)
        worst_drift = max(row["outside_delta"] for row in report)
        next_manifest = copy.deepcopy(manifest)
        next_manifest.update(
            status="ready",
            visemes=report,
            keyframe_metrics=key_metrics,
            aperture=aperture,
            over_articulated=[row["name"] for row in soft_overs],
            preview="preview.mp4",
            sheet="sheet.jpg",
            rig_profile=profile,
            rig_qa=qa,
            rebuild_mode="local_recompose",
            local_viseme_repairs=local_viseme_repairs,
            quality=dict(worst_resid_px=worst_residual,
                         worst_off_region_delta=worst_drift,
                         shapes=len(report), missing=[]),
            progress=dict(done=len(report), total=len(report),
                          stage="done"),
            log=lines[-400:],
        )
        next_manifest.pop("error", None)
        next_manifest.pop("rig_repair", None)
        from . import export
        advance("runtime", .78, "Exporting runtime sprite strips")
        export.export(
            slug, stage_runtime, log=emit, source_dir=stage,
            manifest_data=next_manifest)
        advance("snapshot", .93, "Snapshotting the published avatar for rollback")
        rollback_name = _snapshot_live(slug)
        next_manifest["last_rollback"] = rollback_name
        advance("publish", .97,
                f"Publishing calibrated runtime; rollback {rollback_name}")
        next_manifest["log"] = lines[-400:]
        _publish_stage(slug, stage, next_manifest)
        if progress:
            progress("done", 1.0, "Published")
        return read_manifest(slug)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def build_avatar(slug, shapes=None, log=None, quality="high", notes=""):
    d = adir(slug)
    m = read_manifest(slug)
    if not m:
        raise ValueError(f"unknown avatar: {slug}")
    lines = []

    def emit(msg):
        lines.append(str(msg))
        m["log"] = lines[-400:]
        if log:
            log(msg)
        else:
            print(msg, flush=True)

    key = os.path.join(d, "keyframe.png")
    raw, out = os.path.join(d, "raw"), os.path.join(d, "visemes")
    diag = os.path.join(d, "diag")
    os.makedirs(raw, exist_ok=True); os.makedirs(out, exist_ok=True)
    names = list(shapes or visemes.ORDER)
    unknown = sorted(set(names) - set(visemes.ORDER))
    if unknown:
        raise ValueError(f"unknown viseme shapes: {', '.join(unknown)}")

    m["status"] = "building"
    m["progress"] = dict(done=0, total=len(names), stage="render")
    m["log"] = []
    m.pop("error", None)          # a retry must not inherit the last failure
    write_manifest(slug, m)

    try:
        source_report = m.get("source_metrics") or m.get("metrics") or {}
        source_medium = _source_medium(source_report)
        source_keyframe = os.path.join(
            d, m.get("source_keyframe") or "source-keyframe.png")
        if not os.path.isfile(source_keyframe):
            source_image = os.path.join(d, m.get("source") or "")
            if os.path.isfile(source_image):
                prep.build_keyframe(
                    source_image, source_keyframe,
                    allow_stylized=(source_medium != "photograph"))
            else:
                shutil.copy2(key, source_keyframe)
            m["source_keyframe"] = os.path.basename(source_keyframe)

        m["progress"] = dict(done=0, total=len(names), stage="head")
        write_manifest(slug, m)
        emit("creating canonical HD head-only identity reference...")
        head_path = os.path.join(d, "head.png")
        head_provider = generate.default_head_provider()
        staged_keyframe = os.path.join(d, ".head-keyframe.png")
        best = None
        pose_note = ""
        for pose_attempt in range(3):
            generate.generate_head(
                source_keyframe, head_path, provider=head_provider,
                log=emit, quality=quality, pose_note=pose_note,
                keep=notes, overwrite=bool(pose_attempt),
                source_medium=source_medium)
            head_metrics = prep.build_keyframe(
                head_path, staged_keyframe, diag_dir=diag,
                allow_stylized=(source_medium != "photograph"))
            issues = _frontality_issues(head_metrics)
            score = _frontality_score(head_metrics)
            if best is None or score < best[0]:
                shutil.copy2(head_path, head_path + ".best")
                shutil.copy2(staged_keyframe, staged_keyframe + ".best")
                best = (score, issues, head_metrics)
            if not issues:
                break
            emit(f"  head pose off-frontal: {'; '.join(issues)}"
                 + (f" - regenerating (retry {pose_attempt + 1}/2)"
                    if pose_attempt < 2 else ""))
            pose_note = (
                "\n\nPOSE CORRECTION - a previous attempt measured "
                + "; ".join(issues)
                + ". Render the head PERFECTLY FRONTAL this time: zero yaw, "
                  "zero roll, camera exactly at eye level with no upward or "
                  "downward tilt, both ears equally visible.")
        os.replace(head_path + ".best", head_path)
        os.replace(staged_keyframe + ".best", staged_keyframe)
        score, issues, head_metrics = best
        if issues:
            emit("ADVISORY head is not fully frontal after retries: "
                 + "; ".join(issues)
                 + " - mouth and dental quality may suffer; a straighter, "
                   "camera-level source photo gives the best result")
        os.replace(staged_keyframe, key)
        m.setdefault("source_metrics", copy.deepcopy(m.get("metrics") or {}))
        m["metrics"] = head_metrics
        m["head"] = dict(
            image="head.png",
            source=os.path.basename(source_keyframe),
            prompt_version=generate.head_prompt_version(source_medium),
            provider=head_provider.get("name"),
            model=head_provider.get("model"),
            source_medium=source_medium,
        )
        write_manifest(slug, m)

        yaw = m["metrics"].get("yaw")
        roll = m["metrics"].get("roll")
        emit(f"keyframe pose: yaw {yaw:+.1f} pitch {m['metrics'].get('pitch'):+.1f} "
             f"roll {roll:+.1f}, foreshortening {m['metrics']['foreshortening']:.2f}, "
             f"mouth {m['metrics']['mouth_width_px']:.0f}px")
        emit(f"rendering {len(names)} shapes ({generate.MAX_WORKERS} at a time)...")

        done = [0]
        def on_done(name, path):
            done[0] += 1
            m["progress"] = dict(done=done[0], total=len(names), stage="render", current=name)
            write_manifest(slug, m)

        got = generate.generate_set(key, raw, yaw=yaw, roll=roll, names=names,
                                    log=emit, on_done=on_done, quality=quality,
                                    source_medium=source_medium)
        missing = [n for n, p in got.items() if not p]
        if missing:
            emit(f"WARNING: no render for {', '.join(missing)}")

        # TH is the only plate allowed to show a tongue. A provider can follow
        # the instruction semantically while drawing that tongue visibly off
        # to one side. Detect the actual oral pixels, retry once with measured
        # feedback, then fail safe to a hidden-tongue alveolar plate rather
        # than ever publishing the conspicuous lateral-tongue defect.
        if "TH" in names and got.get("TH"):
            tongue_issue = measure.th_tongue_issue(
                got["TH"], allow_stylized=(source_medium != "photograph"))
            if tongue_issue:
                emit("  TH tongue is off-centre "
                     f"({tongue_issue['offset']:+.2f} mouth widths) - regenerating")
                corrected = generate.generate_one(
                    key, "TH", raw, yaw=yaw, roll=roll, quality=quality,
                    log=emit, overwrite=True,
                    source_medium=source_medium,
                    prompt_note=(
                        "The tongue in the previous TH plate was visibly lateral. "
                        "Show only a tiny, flat, perfectly centred tongue-tip sliver "
                        "on the facial midline. No tongue may touch either mouth corner."),
                )
                got["TH"] = corrected
                tongue_issue = measure.th_tongue_issue(
                    corrected,
                    allow_stylized=(source_medium != "photograph"))
                if tongue_issue:
                    donor = got.get("DD") or got.get("SS")
                    if not donor or not os.path.isfile(donor):
                        raise RuntimeError(
                            "TH tongue remained off-centre and no safe hidden-tongue "
                            "fallback plate is available")
                    safe_th = os.path.join(raw, "v_TH.png")
                    shutil.copy2(donor, safe_th)
                    got["TH"] = safe_th
                    emit("  TH retry remained malformed - using the centred, "
                         "hidden-tongue consonant fallback")

        emit("pose-locking and compositing...")
        m["progress"] = dict(done=len(names), total=len(names), stage="compose")
        write_manifest(slug, m)
        profile = rig.from_manifest(m)
        report, kmet = compose.compose_all(
            key, raw, out, diag_dir=diag, log=emit, profile=profile,
            allow_stylized=(source_medium != "photograph"))

        emit("checking mouth amplitude...")
        aperture, over = measure.audit(
            key, out, log=emit, names=visemes.SPEECH_ORDER,
            allow_stylized=(source_medium != "photograph"))
        if over:
            emit("over-articulated: " + ", ".join(r["name"] for r in over))
        hard_overs = _hard_articulation_rows(over)
        repair = articulation_repair(profile, hard_overs) if hard_overs else None
        local_viseme_repairs = {}
        if repair:
            changed = ", ".join(
                f"{row['label']} {row['before']:.0f}%->{row['after']:.0f}%"
                for row in repair["changes"])
            emit("calibration required before this bank is safe: " +
                 ", ".join(repair["rejected_items"]))
            emit("suggested safe slider retry: " +
                 (changed or "review the highlighted controls"))
            emit("applying the safe slider plan locally before publication...")
            profile = repair["profile"]
            report, kmet = compose.compose_all(
                key, raw, out, diag_dir=diag, log=emit, profile=profile,
                allow_stylized=(source_medium != "photograph"))
            aperture, over = measure.audit(
                key, out, log=emit, names=visemes.SPEECH_ORDER,
                allow_stylized=(source_medium != "photograph"))
            hard_overs = _hard_articulation_rows(over)

        # A provider file can exist yet be unusable (for example MediaPipe
        # cannot find a face in CH), so generation success alone is not enough.
        # Combine those report gaps with hard amplitude failures and repair all
        # of them in one private copy, excluding every failed plate as a donor.
        report_gaps = _required_speech_gaps(report)
        failed_rows = list(hard_overs) + [
            {"name": name} for name in report_gaps
            if name not in {row["name"] for row in hard_overs}
        ]
        if failed_rows:
            with tempfile.TemporaryDirectory(
                    prefix=".safe-visemes-", dir=d) as safe_raw:
                shutil.copytree(raw, safe_raw, dirs_exist_ok=True)
                local_viseme_repairs.update(
                    _stage_safe_visemes(safe_raw, failed_rows, emit))
                if local_viseme_repairs:
                    report, kmet = compose.compose_all(
                        key, safe_raw, out, diag_dir=diag, log=emit,
                        profile=profile,
                        allow_stylized=(source_medium != "photograph"))
                    aperture, over = measure.audit(
                        key, out, log=emit, names=visemes.SPEECH_ORDER,
                        allow_stylized=(source_medium != "photograph"))
                    hard_overs = _hard_articulation_rows(over)
                    report_gaps = _required_speech_gaps(report)

        if report_gaps:
            raise CalibrationRejected(
                "Required speech shapes remain missing or uncomposable: "
                + ", ".join(report_gaps),
                dict(kind="viseme_fallback", profile=profile, changes=[],
                     rejected_items=report_gaps,
                     reasons=[f"{name} has no composable speech plate"
                              for name in report_gaps]))
        if hard_overs:
            repair = articulation_repair(profile, hard_overs)
            raise CalibrationRejected(
                "Unsafe mouth articulation remains in "
                + ", ".join(row["name"] for row in hard_overs), repair)
        if failed_rows:
            repair = None
            emit("automatic local viseme repair passed all 15 speech shapes")
        elif repair:
            repair = None
            emit("automatic local articulation repair passed")

        emit("rendering preview...")
        m["progress"] = dict(done=len(names), total=len(names), stage="preview")
        write_manifest(slug, m)
        render.preview(
            out, os.path.join(d, "preview.mp4"),
            allow_stylized=(source_medium != "photograph"))
        render.contact_sheet(
            out, key, os.path.join(d, "sheet.jpg"),
            allow_stylized=(source_medium != "photograph"))

        worst = max((r["resid_px"] for r in report), default=0)
        drift = max((r["outside_delta"] for r in report), default=0)
        emit(f"done - {len(report)} shapes, worst rigid residual {worst:.2f}px, "
             f"worst off-region drift {drift:.4f}")

        m.update(status="ready", visemes=report, keyframe_metrics=kmet,
                 aperture=aperture, over_articulated=[r["name"] for r in over],
                 rig_profile=profile,
                 local_viseme_repairs=local_viseme_repairs,
                 preview="preview.mp4", sheet="sheet.jpg",
                 quality=dict(worst_resid_px=worst, worst_off_region_delta=drift,
                              shapes=len(report), missing=missing))
        if repair:
            m["rig_repair"] = repair
        else:
            m.pop("rig_repair", None)
        m["progress"] = dict(done=len(names), total=len(names), stage="done")
    except Exception as e:
        emit("ERROR: " + str(e))
        emit(traceback.format_exc()[-1500:])
        m["status"] = "error"
        m["error"] = str(e)
        structured_repair = getattr(e, "repair", None)
        if isinstance(structured_repair, dict):
            m["rig_repair"] = structured_repair
    write_manifest(slug, m)
    return m


def build_async(slug, **kw):
    if _locks.get(slug) and _locks[slug].is_alive():
        return False
    t = threading.Thread(target=build_avatar, args=(slug,), kwargs=kw, daemon=True)
    _locks[slug] = t
    t.start()
    return True


# ---------------------------------------------------------------- cli

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(prog="avatar-studio", description="Build a talking-head viseme bank from any portrait.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add", help="register a photo and prepare its keyframe")
    a.add_argument("image"); a.add_argument("--name"); a.add_argument("--slug")
    a.add_argument("--build", action="store_true", help="generate the full set right away")
    b = sub.add_parser("build", help="generate + compose + preview")
    b.add_argument("slug"); b.add_argument("--shapes", nargs="*")
    b.add_argument("--keep", default="",
                   help="what must survive the build, e.g. his bandana")
    sub.add_parser("list", help="list avatars")
    c = sub.add_parser("activate"); c.add_argument("slug")
    e = sub.add_parser("delete"); e.add_argument("slug")
    args = ap.parse_args()

    if args.cmd == "add":
        m = create_avatar(args.image, args.name, args.slug)
        print(f"{m['slug']}: keyframe ready")
        for w in m["warnings"]:
            print("  warning:", w)
        if args.build:
            build_avatar(m["slug"])
    elif args.cmd == "build":
        build_avatar(args.slug, shapes=args.shapes, notes=args.keep)
    elif args.cmd == "list":
        for m in list_avatars():
            print(f"{'*' if m.get('active') else ' '} {m['slug']:24s} {m['status']:9s} "
                  f"{len(m.get('visemes') or [])} shapes")
    elif args.cmd == "activate":
        print("active ->", set_active(args.slug))
    elif args.cmd == "delete":
        delete_avatar(args.slug); print("deleted", args.slug)
