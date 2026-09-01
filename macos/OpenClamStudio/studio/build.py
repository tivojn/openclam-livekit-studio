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
import os, re, json, time, shutil, datetime, threading, traceback, tempfile, copy, uuid, hashlib
import errno
import fcntl
import stat
from contextlib import contextmanager
from . import anatomy, prep, generate, compose, render, visemes, measure, rig, face

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
_FACE_BUILD_LOCK = ".face-build.lock"
_FACE_BUILD_LOCK_FD_ENV = "OPENCLAM_FACE_BUILD_LOCK_FD"


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


@contextmanager
def avatar_face_build_lock(slug, blocking=True):
    """Serialize one avatar's face mutation across backend processes.

    The HTTP backend deliberately runs face generation in a child Python
    process.  If Electron restarts the backend while that child is still
    alive, an in-memory ``threading.Lock`` disappears with the old parent and
    the new backend could otherwise roll back the child's transaction while
    it is still writing.  ``flock`` is owned by the open file description and
    is released by the kernel on clean exit *or* process death, so it also
    covers abrupt packaged-app restarts without a stale-lock cleanup protocol.

    The yielded value is the locked descriptor, which a parent process can
    explicitly pass to its worker.  Non-blocking callers receive ``None``
    instead of inspecting or recovering an avatar that is still being mutated
    by a surviving worker.
    """
    directory = adir(slug)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, _FACE_BUILD_LOCK)
    flags = os.O_CREAT | os.O_RDWR
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    acquired = False
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise RuntimeError("avatar face-build lock is not a regular file")
        os.fchmod(descriptor, 0o600)
        operation = fcntl.LOCK_EX
        if not blocking:
            operation |= fcntl.LOCK_NB
        try:
            fcntl.flock(descriptor, operation)
            acquired = True
        except OSError as error:
            busy = error.errno in {
                errno.EACCES, errno.EAGAIN,
                getattr(errno, "EWOULDBLOCK", errno.EAGAIN),
            }
            if blocking or not busy:
                raise
        yield descriptor if acquired else None
    finally:
        # Do not call LOCK_UN: a worker may have inherited this same open file
        # description.  Closing our copy releases an ordinary local lease, but
        # deliberately leaves an inherited lease held until the last worker
        # copy exits (including after its backend parent has died).
        os.close(descriptor)


def inherited_avatar_face_build_lock(slug):
    """Whether this CLI worker inherited its parent's verified lock lease.

    The descriptor is intentionally not unlocked or closed here.  ``flock``
    state is shared by inherited copies of the same open file description;
    the child merely keeps that lease alive if its backend parent exits.
    """
    raw = str(os.environ.get(_FACE_BUILD_LOCK_FD_ENV) or "").strip()
    if not raw:
        return False
    try:
        descriptor = int(raw)
        locked = os.fstat(descriptor)
        expected = os.stat(
            os.path.join(adir(slug), _FACE_BUILD_LOCK),
            follow_symlinks=False)
    except (OSError, TypeError, ValueError):
        return False
    return (
        stat.S_ISREG(locked.st_mode)
        and stat.S_ISREG(expected.st_mode)
        and locked.st_dev == expected.st_dev
        and locked.st_ino == expected.st_ino
    )


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


SOURCE_MEDIUM_OVERRIDES = frozenset({
    "photograph", "illustration", "3d render",
})


def normalise_source_medium_override(value):
    """Return one canonical owner-selected source lane, or ``None`` for Auto."""
    if value is None or not str(value).strip():
        return None
    medium = str(value).strip().lower()
    if medium not in SOURCE_MEDIUM_OVERRIDES:
        raise ValueError(
            "source medium must be photograph, illustration, or 3d render")
    return medium


def apply_source_medium_override(manifest, value):
    """Make an explicit owner choice authoritative while retaining evidence.

    ``source_metrics.source_medium`` is the compatibility field consumed by
    every existing face/body/export/cutout route.  The top-level override makes
    intent unambiguous, while ``detected_source_medium`` preserves what the
    heuristic originally observed for diagnostics and future classifier work.
    """
    medium = normalise_source_medium_override(value)
    if medium is None:
        return manifest
    if not isinstance(manifest, dict):
        raise ValueError("avatar manifest is invalid")
    raw_current_override = str(
        manifest.get("source_medium_override") or "").strip().lower()
    current_override = (raw_current_override
                        if raw_current_override in SOURCE_MEDIUM_OVERRIDES
                        else None)
    report = manifest.get("source_metrics")
    if not isinstance(report, dict):
        report = {}
    else:
        report = copy.deepcopy(report)
    previous_medium = _source_medium(report)
    if "detected_source_medium" not in report:
        # Only treat the current effective value as detector evidence when it
        # was not itself written by an earlier owner override.
        if current_override is None:
            report["detected_source_medium"] = str(
                report.get("source_medium") or "unknown")
    report["source_medium"] = medium
    report["source_medium_source"] = "user"
    manifest["source_metrics"] = report
    manifest["source_medium_override"] = medium
    manifest.pop("source_medium_repair", None)
    if previous_medium != medium:
        # The immutable source crop was authored under the old lane.  A 2-D
        # correction in particular may need to restore wide hair or headwear
        # that a photographic face crop excluded.  The face worker stages a
        # replacement and publishes it only after the rebuilt face passes.
        manifest["source_keyframe_refresh_required"] = True
    # Before the first generated head, ``metrics`` is the intake report too.
    # Keep the legacy/UI fallback synchronized without overwriting ready head
    # measurements on a later correction.
    if manifest.get("status") == "draft" and isinstance(
            manifest.get("metrics"), dict):
        draft_metrics = copy.deepcopy(manifest["metrics"])
        if "detected_source_medium" not in draft_metrics:
            draft_metrics["detected_source_medium"] = str(
                draft_metrics.get("source_medium") or "unknown")
        draft_metrics["source_medium"] = medium
        draft_metrics["source_medium_source"] = "user"
        manifest["metrics"] = draft_metrics
    return manifest


def set_source_medium_override(slug, value):
    """Persist a validated owner choice when no face rebuild is required."""
    manifest = read_manifest(slug)
    if not manifest:
        raise ValueError(f"unknown avatar: {slug}")
    apply_source_medium_override(manifest, value)
    return write_manifest(slug, manifest)


def create_avatar(image_path, name=None, slug=None, source_medium=None):
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
            allow_stylized=True, source_medium=source_medium)
        shutil.copy2(source_key, key)

        manifest = dict(
            slug=slug, name=name,
            created=datetime.datetime.now().isoformat(timespec="seconds"),
            source=os.path.basename(src), source_keyframe="source-keyframe.png",
            keyframe="keyframe.png",
            status="draft", progress=dict(done=0, total=len(visemes.ORDER)),
            # Preserve the original intake evidence immediately.  Older
            # builds created this field only after generating a canonical
            # head, which let an ambiguous legacy cartoon later inherit the
            # generated head's (usually photographic) detector route.
            source_metrics=copy.deepcopy(metrics), metrics=metrics,
            warnings=metrics.get("warnings", []),
            visemes=[], preview=None, sheet=None, log=[])
        selected_medium = normalise_source_medium_override(source_medium)
        if selected_medium:
            # prep already stamped the effective/detected pair.  This explicit
            # field survives future schema migrations and generated-head
            # metrics replacing the legacy ``metrics`` report.
            manifest["source_medium_override"] = selected_medium
        manifest["source_keyframe_medium"] = _source_medium(metrics)
        return write_manifest(slug, manifest)
    except Exception:
        # This directory was reserved by this call and cannot contain a prior
        # avatar.  A rejected upload must not leave source-only ghosts that
        # consume names and appear in future maintenance scans.
        shutil.rmtree(d, ignore_errors=True)
        raise


# ---------------------------------------------------------------- build

RIG_ARTIFACTS = ("visemes", "diag", "runtime", "preview.mp4", "sheet.jpg")


def _source_medium(report):
    """Return only a reviewed source-medium branch.

    Runtime detector selection is a security/quality boundary, not a free-form
    styling hint.  Corrupt, future, and legacy photo manifests therefore stay
    on the strict photographic detector.  Only stored, explicit art-media
    labels can opt into the topology-gated stylized path.
    """
    report = report if isinstance(report, dict) else {}
    medium = str(report.get("source_medium") or "").strip().lower()
    aliases = {
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
    if medium in aliases:
        return aliases[medium]
    legacy = str(report.get("source_mode") or "").strip().lower()
    if not medium and legacy.startswith("stylized"):
        return "illustration"
    return "photograph"


def _medium_needs_local_reclassification(manifest):
    """Whether an old manifest lacks a reviewed original-medium decision.

    Explicit photographs and explicit stylized media are authoritative.  A
    missing/empty/``unknown`` label is eligible for a fresh local inspection;
    malformed reports and arbitrary future labels remain fail-closed rather
    than being guessed from generated head/body metadata.
    """
    if not isinstance(manifest, dict):
        return False
    report = None
    for key in ("source_metrics", "metrics"):
        if key not in manifest:
            continue
        report = manifest.get(key)
        if not isinstance(report, dict):
            return False
        break
    if report is None:
        return True
    raw_medium = str(report.get("source_medium") or "").strip().lower()
    legacy_mode = str(report.get("source_mode") or "").strip().lower()
    if raw_medium in ("", "unknown") and not legacy_mode:
        return True
    if not raw_medium and legacy_mode.startswith("stylized"):
        return False
    # Includes explicit photograph, reviewed art aliases, and corrupt/future
    # values.  Only the first two route anywhere; the last remains strict.
    return False


def _original_avatar_image(directory, manifest):
    """Load one registry-owned original image without accepting path escapes."""
    root = os.path.abspath(directory)
    for key in ("source", "source_keyframe", "keyframe"):
        value = manifest.get(key) if isinstance(manifest, dict) else None
        if not isinstance(value, str) or not value.strip():
            continue
        candidate = os.path.abspath(os.path.join(root, value))
        try:
            if os.path.commonpath((root, candidate)) != root:
                continue
        except ValueError:
            continue
        if not os.path.isfile(candidate):
            continue
        try:
            return os.path.relpath(candidate, root), prep.read_image_bgr(candidate)
        except (OSError, ValueError):
            continue
    return None, None


def repair_source_medium_from_source(slug, manifest=None, log=None):
    """Repair only missing/unknown legacy medium evidence from local pixels.

    The repair never trusts names, prompts, provider output, head metadata, or
    wardrobe selections.  It reruns the same topology-gated intake detector on
    the registry-owned original source/keyframe and persists a stylized result
    only when the classifier produces an explicit whitelisted art medium.
    Anything photographic, uncertain, unreadable, malformed, or corrupt stays
    on the strict photographic path.
    """
    current = copy.deepcopy(manifest if manifest is not None
                            else read_manifest(slug))
    # The owner has resolved the ambiguity.  Never let a later maintenance
    # scan replace that decision with a fresh heuristic result.
    if str(current.get("source_medium_override") or "").strip().lower() \
            in SOURCE_MEDIUM_OVERRIDES:
        return current
    if not _medium_needs_local_reclassification(current):
        return current
    image_name, image = _original_avatar_image(adir(slug), current)
    if image is None:
        return current
    try:
        landmarks, _transform, metadata = face.detect_for_intake(image)
    except Exception:
        # Migration is best-effort.  An unavailable model or unreadable legacy
        # codec must leave the avatar on the existing strict route, not prevent
        # the owner from opening calibration/body tools.
        return current
    if landmarks is None or not isinstance(metadata, dict):
        return current
    raw_medium = str(metadata.get("source_medium") or "").strip().lower()
    medium = _source_medium({"source_medium": raw_medium})
    if medium == "photograph" or raw_medium in ("", "unknown", "photograph"):
        return current

    original_report = current.get("source_metrics")
    if isinstance(original_report, dict):
        repaired_report = copy.deepcopy(original_report)
    elif (not isinstance(current.get("head"), dict) and
          isinstance(current.get("metrics"), dict)):
        # A draft's metrics still describe the source.  A ready legacy build's
        # metrics describe its generated head and must not be relabelled.
        repaired_report = copy.deepcopy(current["metrics"])
    else:
        repaired_report = {}
    for key in ("detection_mode", "detection_crop", "topology",
                "source_medium", "medium_score", "medium_features"):
        if key in metadata:
            repaired_report[key] = copy.deepcopy(metadata[key])
    current["source_metrics"] = repaired_report
    previous = None
    if isinstance(original_report, dict):
        previous = original_report.get("source_medium")
    current["source_medium_repair"] = {
        "method": "local-topology-and-visual-v1",
        "image": image_name,
        "previous": previous,
        "source_medium": medium,
    }
    write_manifest(slug, current)
    if log:
        log(f"locally reclassified legacy source as {medium} from {image_name}")
    return current


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


def _row_satisfies_viseme_contract(row, target_name):
    """Return whether measured pixels are safe when used as ``target_name``.

    A donor being acceptable for *its own* phoneme is not enough.  RR, for
    example, deliberately targets a narrower mouth than DD; copying a narrow
    RR plate into DD can therefore preserve the exact width failure the local
    repair is meant to remove.  Evaluate the donor's actual composed geometry
    against the destination contract instead.
    """
    if not isinstance(row, dict) or target_name not in visemes.TARGETS:
        return False
    try:
        ratio = float(row["ratio"])
        width_ratio = float(row["width_ratio"])
    except (KeyError, TypeError, ValueError):
        return False
    max_ratio, want_width = visemes.TARGETS[target_name]
    return (
        measure._aperture_within_limit(ratio, float(max_ratio))
        and abs(width_ratio - float(want_width)) <= 0.12
    )


def _stage_safe_visemes(
        raw_dir, rejected, emit, measurements=None, require_proof=False):
    """Replace irreparable speech plates in a disposable raw stage.

    ``measurements`` are the already-composed rows returned by
    :func:`measure.audit`.  Stylized builds require this proof so a merely
    nearby phoneme can never be copied unless its pixels also satisfy the
    destination viseme's aperture and width contract.  The legacy unproved
    path remains available for photographic builds and old local callers.
    """
    unsafe = {str(row.get("name") or "") for row in (rejected or [])}
    measured = {
        str(row.get("name") or ""): row
        for row in (measurements or []) if isinstance(row, dict)
    }
    repairs = {}
    for name in visemes.SPEECH_ORDER:
        if name not in unsafe or name not in SAFE_VISEME_DONORS:
            continue
        donor_name = next((candidate for candidate in SAFE_VISEME_DONORS[name]
                           if candidate not in unsafe
                           and _raw_render_path(raw_dir, candidate)
                           and (not require_proof or
                                _row_satisfies_viseme_contract(
                                    measured.get(candidate), name))), None)
        if not donor_name:
            if require_proof:
                emit(f"  {name}: no retained donor is proven safe for the "
                     "destination articulation contract")
            continue
        donor = _raw_render_path(raw_dir, donor_name)
        _replace_staged_render(raw_dir, name, donor)
        repairs[name] = donor_name
        donor_label = "target-verified" if require_proof else "nearby"
        emit(f"  {name}: generated plate stayed unsafe or uncomposable "
             f"- using {donor_label} {donor_name} speech plate in this private "
             "rebuild")
    return repairs


def _stage_safe_consonants(
        raw_dir, rejected, emit, measurements=None, require_proof=False):
    """Compatibility wrapper for the original consonant-only repair API."""
    return _stage_safe_visemes(
        raw_dir, rejected, emit, measurements=measurements,
        require_proof=require_proof)


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
    manifest = repair_source_medium_from_source(
        slug, manifest=manifest, log=log)
    profile = rig.normalize(profile)
    gaps = raw_render_gaps(slug)
    directory = adir(slug)
    source_report = manifest.get("source_metrics") or manifest.get("metrics") or {}
    source_medium = _source_medium(source_report)
    allow_stylized = source_medium != "photograph"
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
            profile=profile, allow_stylized=allow_stylized,
            source_medium=source_medium)
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
                allow_stylized=allow_stylized, source_medium=source_medium)
            aperture, over = measure.audit(
                stage_keyframe, stage_visemes, log=emit,
                names=visemes.SPEECH_ORDER,
                allow_stylized=allow_stylized)
            hard_overs = _hard_articulation_rows(over)
            if hard_overs:
                local_viseme_repairs.update(_stage_safe_consonants(
                    stage_raw, hard_overs, emit, measurements=aperture,
                    require_proof=allow_stylized))
                if local_viseme_repairs:
                    report, key_metrics = compose.compose_all(
                        stage_keyframe, stage_raw, stage_visemes,
                        diag_dir=stage_diag, log=emit, profile=profile,
                        allow_stylized=allow_stylized, source_medium=source_medium)
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


def _file_sha256(path):
    if not path or not os.path.isfile(path):
        return ""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


FACE_REBUILD_ARTIFACTS = (
    "head.png",
    "keyframe.png",
    "raw",
    "visemes",
    "diag",
    "preview.mp4",
    "sheet.jpg",
    # Publish the restored descriptor only after every file it names is back.
    "manifest.json",
)

FACE_REBUILD_TRANSIENTS = (
    ".head-keyframe.png",
    ".head-keyframe.png.best",
    "head.png.best",
    ".source-keyframe.override.png",
)

# These large authored sets are not copied into a ready-face rebuild snapshot.
# Once the replacement face has passed every visual gate, they are displaced
# into the transaction directory with a same-volume rename and remain there
# until the replacement manifest has committed.  The caches belong to the
# same authored identity and therefore follow their canonical directories.
FACE_REBUILD_DERIVED_ARTIFACTS = (
    "body",
    ".body-cache",
    "motion",
    ".motion-cache",
)
_FACE_REBUILD_DEFERRED_DIR = "deferred"
_FACE_REBUILD_JOURNAL = "transaction.json"
_FACE_REBUILD_JOURNAL_VERSION = 1


def _fsync_face_rebuild_directory(directory):
    """Best-effort durability barrier for an avatar-local transaction."""
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_face_rebuild_journal(transaction):
    """Atomically persist enough state to finish rollback after a restart."""
    backup = os.path.abspath(transaction["backup"])
    directory = os.path.abspath(transaction["directory"])
    if os.path.commonpath((directory, backup)) != directory or backup == directory:
        raise RuntimeError("face rebuild journal path is invalid")
    payload = {
        "v": _FACE_REBUILD_JOURNAL_VERSION,
        "phase": str(transaction.get("phase") or "prepared"),
        "present": list(transaction.get("present") or ()),
        "manifest": copy.deepcopy(transaction.get("manifest") or {}),
        "deferred": dict(transaction.get("deferred") or {}),
    }
    descriptor, temporary = tempfile.mkstemp(
        prefix=".transaction-", dir=backup)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=1)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(backup, _FACE_REBUILD_JOURNAL))
        _fsync_face_rebuild_directory(backup)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def _set_face_rebuild_transaction_phase(transaction, phase):
    if transaction is None:
        return
    transaction["phase"] = str(phase)
    _write_face_rebuild_journal(transaction)


def _copy_face_rebuild_artifact(source, destination):
    """Copy one registry-owned artifact without following a symlink.

    A rebuild transaction is a safety boundary, not an import path.  Refusing
    unexpected links prevents a damaged registry from making the backup walk
    outside the avatar directory while still keeping the ordinary file/tree
    copy deliberately simple and portable.
    """
    if os.path.islink(source):
        raise RuntimeError(
            f"cannot transactionally rebuild linked artifact: "
            f"{os.path.basename(source)}")
    if os.path.isdir(source):
        shutil.copytree(source, destination, symlinks=True)
    elif os.path.isfile(source):
        shutil.copy2(source, destination)


def _begin_face_rebuild_transaction(directory, manifest):
    """Privately snapshot the published talking face before a full rebuild.

    Draft avatars have nothing usable to preserve.  A ready avatar does: its
    generated canonical head and the retained raw/composited plates are one
    authored set, while body and motion metadata in the manifest point at that
    exact identity.  The face files are therefore backed up as a unit before a
    new head or keyframe can be staged.  Body, motion, and the immutable source
    keyframe are displaced later by same-volume rename only after the new face
    has passed every gate; they remain recoverable until the new manifest is
    durably published.
    """
    if not isinstance(manifest, dict) or manifest.get("status") != "ready":
        return None
    backup = tempfile.mkdtemp(prefix=".face-rebuild-", dir=directory)
    present = []
    try:
        for relative in FACE_REBUILD_ARTIFACTS:
            source = os.path.join(directory, relative)
            if not os.path.exists(source):
                continue
            _copy_face_rebuild_artifact(
                source, os.path.join(backup, relative))
            present.append(relative)
        transaction = {
            "backup": backup,
            "directory": os.path.abspath(directory),
            "present": tuple(present),
            "manifest": copy.deepcopy(manifest),
            "deferred": {},
            "phase": "prepared",
            "settled": None,
        }
        _write_face_rebuild_journal(transaction)
        return transaction
    except Exception:
        shutil.rmtree(backup, ignore_errors=True)
        raise


def _face_rebuild_artifact_paths(directory, transaction, path):
    """Return validated live/backup paths for one deferred authored artifact."""
    root = os.path.abspath(directory)
    live = os.path.abspath(
        path if os.path.isabs(path) else os.path.join(root, path))
    if os.path.commonpath((root, live)) != root or live == root:
        raise RuntimeError("face rebuild artifact escapes the avatar directory")
    relative = os.path.relpath(live, root)
    backup = os.path.abspath(os.path.join(
        transaction["backup"], _FACE_REBUILD_DEFERRED_DIR, relative))
    transaction_root = os.path.abspath(transaction["backup"])
    if os.path.commonpath((transaction_root, backup)) != transaction_root:
        raise RuntimeError("face rebuild backup path is invalid")
    return relative, live, backup


def _defer_face_rebuild_artifact(directory, transaction, path):
    """Displace one live artifact without deleting it before manifest commit.

    Ready-avatar rebuilds use an avatar-local transaction directory, so
    ``os.replace`` is an atomic same-volume rename even for multi-gigabyte body
    and motion trees.  Draft avatars have no rollback contract and retain the
    historical direct-removal behavior.
    """
    if transaction is None:
        live = path if os.path.isabs(path) else os.path.join(directory, path)
        _remove_artifact(live)
        return False
    relative, live, backup = _face_rebuild_artifact_paths(
        directory, transaction, path)
    deferred = transaction.setdefault("deferred", {})
    if relative in deferred:
        return bool(deferred[relative])
    if not os.path.lexists(live):
        deferred[relative] = False
        _write_face_rebuild_journal(transaction)
        return False
    os.makedirs(os.path.dirname(backup), mode=0o700, exist_ok=True)
    os.replace(live, backup)
    deferred[relative] = True
    _write_face_rebuild_journal(transaction)
    return True


def _restore_face_rebuild_transaction(directory, transaction):
    """Atomically put every previously published authored artifact back."""
    present = set(transaction.get("present") or ())
    backup = transaction["backup"]
    # Restore displaced body/motion/source-keyframe state before publishing the
    # old manifest that names it.  Reverse order mirrors the invalidation order
    # and keeps a partially restored transaction recoverable if the filesystem
    # itself fails during rollback.
    for relative, existed in reversed(tuple(
            (transaction.get("deferred") or {}).items())):
        _relative, live, displaced = _face_rebuild_artifact_paths(
            directory, transaction, relative)
        # A prior restore attempt may already have moved this backup into the
        # live path before crashing.  In that case the missing displaced copy
        # is positive evidence to keep the live artifact, not delete it.
        if existed and os.path.lexists(displaced):
            _remove_artifact(live)
            os.makedirs(os.path.dirname(live), mode=0o700, exist_ok=True)
            os.replace(displaced, live)
        elif not existed:
            _remove_artifact(live)
    for relative in FACE_REBUILD_ARTIFACTS:
        live = os.path.join(directory, relative)
        saved = os.path.join(backup, relative)
        if relative in present and os.path.lexists(saved):
            if os.path.isdir(saved) and not os.path.islink(saved):
                # Python cannot atomically replace a populated directory.
                # These authored trees remain restart-recoverable in the
                # transaction, but must be cleared before the same-volume
                # rename just as before.
                _remove_artifact(live)
                os.replace(saved, live)
            else:
                # Regular files -- most importantly manifest.json -- can and
                # must replace their live counterpart directly.  Pre-unlinking
                # the manifest creates a crash window in which startup cannot
                # discover the avatar at all.  os.replace is the atomic commit
                # here and also safely overwrites an existing regular file.
                os.replace(saved, live)
                if relative == "manifest.json":
                    _fsync_face_rebuild_directory(directory)
        elif relative not in present:
            _remove_artifact(live)
    for relative in FACE_REBUILD_TRANSIENTS:
        _remove_artifact(os.path.join(directory, relative))
    return copy.deepcopy(transaction["manifest"])


def _commit_face_rebuild_transaction(transaction):
    if transaction:
        transaction["phase"] = "committed"
        transaction["settled"] = "committed"
        # The ready manifest is already the durable commit point.  A journal
        # refresh is useful if the process dies before cleanup, but failure to
        # write this redundant marker must not roll a successful build back.
        try:
            _write_face_rebuild_journal(transaction)
        except OSError:
            pass


def _finish_face_rebuild_transaction(transaction):
    # Never discard the only rollback copy after a failed restore.  A settled
    # transaction has either committed its replacement manifest or restored
    # the complete previous authored set and manifest.
    if transaction and transaction.get("settled"):
        shutil.rmtree(transaction.get("backup") or "", ignore_errors=True)


def _read_face_rebuild_journal(directory, backup):
    """Load a current or pre-journal transaction without trusting its paths."""
    directory = os.path.abspath(directory)
    backup = os.path.abspath(backup)
    if (os.path.commonpath((directory, backup)) != directory
            or backup == directory or os.path.islink(backup)):
        raise RuntimeError("face rebuild recovery path is invalid")

    payload = None
    journal_path = os.path.join(backup, _FACE_REBUILD_JOURNAL)
    try:
        with open(journal_path, encoding="utf-8") as handle:
            candidate = json.load(handle)
        if (isinstance(candidate, dict)
                and candidate.get("v") == _FACE_REBUILD_JOURNAL_VERSION):
            payload = candidate
    except (OSError, ValueError):
        pass

    # 1.0.12 and earlier left the snapshot itself but no journal.  Its copied
    # manifest is sufficient to recover transactions that had not already
    # moved the manifest back during an interrupted rollback.
    if payload is None:
        try:
            with open(os.path.join(backup, "manifest.json"),
                      encoding="utf-8") as handle:
                prior_manifest = json.load(handle)
        except (OSError, ValueError) as error:
            raise RuntimeError(
                "face rebuild transaction has no recoverable journal") from error
        payload = {
            "v": 0,
            "phase": "legacy",
            "manifest": prior_manifest,
            "present": [
                relative for relative in FACE_REBUILD_ARTIFACTS
                if os.path.lexists(os.path.join(backup, relative))
            ],
            "deferred": {},
        }

    manifest = payload.get("manifest")
    if not isinstance(manifest, dict) or manifest.get("status") != "ready":
        raise RuntimeError("face rebuild recovery manifest is not a ready avatar")
    present = payload.get("present")
    if not isinstance(present, list) or any(
            relative not in FACE_REBUILD_ARTIFACTS for relative in present):
        raise RuntimeError("face rebuild recovery artifact list is invalid")
    deferred = payload.get("deferred")
    if not isinstance(deferred, dict) or any(
            not isinstance(relative, str) or type(existed) is not bool
            for relative, existed in deferred.items()):
        raise RuntimeError("face rebuild recovery deferred list is invalid")

    source_keyframe = str(
        manifest.get("source_keyframe") or "source-keyframe.png")
    allowed_deferred = set(FACE_REBUILD_DERIVED_ARTIFACTS)
    allowed_deferred.add(source_keyframe)
    if any(relative not in allowed_deferred for relative in deferred):
        raise RuntimeError("face rebuild recovery contains an unknown artifact")

    transaction = {
        "backup": backup,
        "directory": directory,
        "present": tuple(present),
        "manifest": copy.deepcopy(manifest),
        "deferred": dict(deferred),
        "phase": str(payload.get("phase") or "prepared"),
        "settled": None,
    }
    # A process can die between the same-volume rename and the journal update.
    # Discover only the finite artifact lanes this rebuild is allowed to move.
    candidates = tuple(FACE_REBUILD_DERIVED_ARTIFACTS) + (source_keyframe,)
    for relative in candidates:
        try:
            _relative, _live, displaced = _face_rebuild_artifact_paths(
                directory, transaction, relative)
        except (OSError, ValueError, RuntimeError):
            continue
        if os.path.lexists(displaced):
            transaction["deferred"][relative] = True
    # Validate every journal path even if its displaced copy was already moved
    # back by a previous partial restore.
    for relative in tuple(transaction["deferred"]):
        _face_rebuild_artifact_paths(directory, transaction, relative)
    return transaction


def recover_face_rebuild_transactions(slug, log=print):
    """Recover abandoned face rebuilds before exposing an avatar after launch.

    A ready live manifest that differs from the transaction's prior manifest
    is a successfully committed (or subsequently repaired) runtime and always
    wins.  Building/error/missing manifests are rolled back from the newest
    complete snapshot.  This prevents stale recovery debris from overwriting a
    newer good face while still repairing a process crash at any build stage.
    """
    directory = adir(slug)
    if not os.path.isdir(directory):
        return []
    entries = [
        entry for entry in os.scandir(directory)
        if entry.name.startswith(".face-rebuild-")
        and entry.is_dir(follow_symlinks=False)
    ]
    entries.sort(key=lambda entry: entry.stat(follow_symlinks=False).st_mtime,
                 reverse=True)
    outcomes = []
    for entry in entries:
        try:
            transaction = _read_face_rebuild_journal(
                directory, entry.path)
            current = read_manifest(slug)
            prior = transaction["manifest"]
            if (isinstance(current, dict)
                    and current.get("status") == "ready"
                    and current != prior):
                shutil.rmtree(entry.path, ignore_errors=True)
                outcomes.append("kept-current")
                if log:
                    log("removed a stale face-rebuild snapshot; the current "
                        "ready avatar was kept")
                continue

            restored = _restore_face_rebuild_transaction(
                directory, transaction)
            restored["status"] = "ready"
            write_manifest(slug, restored)
            transaction["settled"] = "restored"
            shutil.rmtree(entry.path, ignore_errors=True)
            outcomes.append("restored")
            if log:
                log("restored the last published face after an interrupted "
                    "face rebuild")
        except Exception as error:
            current = read_manifest(slug)
            if isinstance(current, dict) and current.get("status") == "ready":
                # A journal-less directory can only be an interrupted snapshot
                # made before live mutation, or legacy debris whose ready live
                # avatar is the only authoritative state left.  Never replace
                # that state with an unproven partial backup.
                shutil.rmtree(entry.path, ignore_errors=True)
                outcomes.append("kept-current")
                if log:
                    log(f"removed incomplete {entry.name}; kept the current "
                        f"ready avatar ({error})")
            else:
                outcomes.append("unrecoverable")
                if log:
                    log(f"could not recover {entry.name}: {error}")
    return outcomes


def face_rebuild_recovery_slugs():
    """List avatar directories containing a recoverable face journal.

    ``list_avatars`` intentionally exposes only directories with readable
    manifests.  Recovery cannot use that public listing exclusively: an older
    rollback could be interrupted after unlinking manifest.json and before
    restoring its snapshot.  Scan only validated avatar directories and only
    finite transaction markers, so startup can repair that exact state without
    broadening the registry surface.
    """
    os.makedirs(AVATARS, mode=0o700, exist_ok=True)
    result = []
    for avatar in os.scandir(AVATARS):
        if (not valid_slug(avatar.name)
                or not avatar.is_dir(follow_symlinks=False)):
            continue
        recoverable = False
        try:
            transactions = os.scandir(avatar.path)
        except OSError:
            continue
        with transactions:
            for transaction in transactions:
                if (not transaction.name.startswith(".face-rebuild-")
                        or not transaction.is_dir(follow_symlinks=False)):
                    continue
                try:
                    markers = os.scandir(transaction.path)
                except OSError:
                    continue
                with markers:
                    if any(
                            marker.name in {
                                _FACE_REBUILD_JOURNAL, "manifest.json",
                            }
                            and marker.is_file(follow_symlinks=False)
                            for marker in markers):
                        recoverable = True
                        break
        if recoverable:
            result.append(avatar.name)
    return sorted(result)


def _build_avatar_under_lock(
        slug, shapes=None, log=None, quality="high", notes="",
        remove_headwear=None, source_medium=None):
    d = adir(slug)
    # A previous daemon may have stopped after staging a replacement face.
    # Settle that transaction before taking a new snapshot of the avatar.
    recovery = recover_face_rebuild_transactions(slug, log=log)
    if "unrecoverable" in recovery:
        raise RuntimeError(
            "an interrupted face rebuild could not be recovered safely")
    m = read_manifest(slug)
    if not m:
        raise ValueError(f"unknown avatar: {slug}")
    requested_source_medium = normalise_source_medium_override(source_medium)
    # Automatic legacy repair retains its historical behavior.  An explicit
    # owner choice is applied only after the ready-avatar transaction has taken
    # its snapshot; otherwise a rejected rebuild restores a manifest that was
    # already relabelled while its published face/body/motion remain old-lane.
    if requested_source_medium is None:
        m = repair_source_medium_from_source(
            slug, manifest=m, log=log)
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
    previous_head_policy = bool(
        ((m.get("head") or {}).get("remove_headwear", False)))
    previous_head_medium = _source_medium({
        "source_medium": (m.get("head") or {}).get("source_medium")})
    # Missing means "keep this avatar's current policy". This matters for
    # repair/top-up calls that regenerate a subset of visemes without showing
    # the build preferences dialog. A brand-new/legacy avatar naturally falls
    # back to the safe Preserve default (False).
    remove_headwear = (previous_head_policy if remove_headwear is None
                       else bool(remove_headwear))
    names = list(shapes or visemes.ORDER)
    previous_head_digest = _file_sha256(os.path.join(d, "head.png"))
    unknown = sorted(set(names) - set(visemes.ORDER))
    if unknown:
        raise ValueError(f"unknown viseme shapes: {', '.join(unknown)}")

    rebuild_transaction = _begin_face_rebuild_transaction(d, m)
    try:
        _set_face_rebuild_transaction_phase(
            rebuild_transaction, "building")
        if requested_source_medium is not None:
            apply_source_medium_override(m, requested_source_medium)
        os.makedirs(raw, exist_ok=True); os.makedirs(out, exist_ok=True)

        m["status"] = "building"
        m["progress"] = dict(done=0, total=len(names), stage="render")
        m["log"] = []
        m.pop("error", None)      # a retry must not inherit the last failure
        write_manifest(slug, m)

        source_report = m.get("source_metrics") or m.get("metrics") or {}
        source_medium = _source_medium(source_report)
        source_keyframe = os.path.join(
            d, m.get("source_keyframe") or "source-keyframe.png")
        source_image = os.path.join(d, m.get("source") or "")
        build_source_keyframe = source_keyframe
        pending_source_keyframe = None
        if (m.get("source_keyframe_refresh_required")
                and os.path.isfile(source_image)):
            pending_source_keyframe = os.path.join(
                d, ".source-keyframe.override.png")
            prep.build_keyframe(
                source_image, pending_source_keyframe,
                allow_stylized=(source_medium != "photograph"),
                source_medium=source_medium)
            build_source_keyframe = pending_source_keyframe
        elif not os.path.isfile(source_keyframe):
            if os.path.isfile(source_image):
                prep.build_keyframe(
                    source_image, source_keyframe,
                    allow_stylized=(source_medium != "photograph"),
                    source_medium=source_medium)
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
                build_source_keyframe, head_path, provider=head_provider,
                log=emit, quality=quality, pose_note=pose_note,
                keep=notes, overwrite=bool(pose_attempt),
                source_medium=source_medium,
                remove_headwear=remove_headwear)
            head_metrics = prep.build_keyframe(
                head_path, staged_keyframe, diag_dir=diag,
                allow_stylized=(source_medium != "photograph"),
                source_medium=source_medium)
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
            remove_headwear=remove_headwear,
            headwear_policy=("remove" if remove_headwear else "preserve"),
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
            allow_stylized=(source_medium != "photograph"),
            source_medium=source_medium)

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
                allow_stylized=(source_medium != "photograph"),
                source_medium=source_medium)
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
                    _stage_safe_visemes(
                        safe_raw, failed_rows, emit,
                        measurements=aperture,
                        require_proof=(source_medium != "photograph")))
                if local_viseme_repairs:
                    report, kmet = compose.compose_all(
                        key, safe_raw, out, diag_dir=diag, log=emit,
                        profile=profile,
                        allow_stylized=(source_medium != "photograph"),
                        source_medium=source_medium)
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

        # A generated closed-eye plate is not sufficient: it must cover the
        # character's actual eyes without replacing their glasses/face. Check
        # the same semantic blink used by runtime export BEFORE committing
        # the replacement face or invalidating its approved body/motions.
        # The preflight is a no-op for the independent photograph pipeline.
        from . import export
        export.preflight_stylized_blink(d, source_medium, log=emit)

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
        # A body or motion take authored against another canonical head is not
        # a reusable asset.  Invalidate it only after the replacement talking
        # face has passed every gate, so a rejected rebuild never destroys the
        # last usable authored set. Owner notes can alter identity accessories
        # even when the provider happens to return byte-identical head pixels.
        current_head_digest = _file_sha256(head_path)
        derived_identity_changed = (
            previous_head_digest != current_head_digest
            or previous_head_policy != remove_headwear
            or previous_head_medium != source_medium
            or bool(str(notes or "").strip())
        )
        if derived_identity_changed and (m.get("body") or m.get("motion")):
            for relative in FACE_REBUILD_DERIVED_ARTIFACTS:
                _defer_face_rebuild_artifact(d, rebuild_transaction, relative)
            m.pop("body", None)
            m.pop("motion", None)
            emit("canonical head changed - cleared stale body and motion assets")
        if repair:
            m["rig_repair"] = repair
        else:
            m.pop("rig_repair", None)
        m["progress"] = dict(done=len(names), total=len(names), stage="done")
        if pending_source_keyframe:
            # A ready avatar needs its prior immutable crop retained until the
            # replacement manifest commits.  Draft avatars have no snapshot;
            # let os.replace perform its ordinary atomic overwrite there so a
            # failed replacement cannot delete an otherwise usable crop first.
            if rebuild_transaction:
                _defer_face_rebuild_artifact(
                    d, rebuild_transaction, source_keyframe)
            os.replace(pending_source_keyframe, source_keyframe)
            m["source_keyframe"] = os.path.basename(source_keyframe)
            m["source_keyframe_medium"] = source_medium
            m.pop("source_keyframe_refresh_required", None)
        # This is the transaction commit point.  Body, motion, their caches,
        # and the prior source keyframe remain in the avatar-local backup until
        # this atomic manifest replacement succeeds.
        write_manifest(slug, m)
        _commit_face_rebuild_transaction(rebuild_transaction)
    except Exception as e:
        emit("ERROR: " + str(e))
        emit(traceback.format_exc()[-1500:])
        structured_repair = getattr(e, "repair", None)
        if rebuild_transaction:
            # Restore the complete prior authored face and its manifest before
            # exposing the rejection.  Keeping status=ready means Chat/Talk,
            # calibration, the old body and every motion take remain usable;
            # re-raising makes the worker report a failed rebuild instead of
            # exporting the restored avatar as though the new build passed.
            failure_log = list(lines[-400:])
            m = _restore_face_rebuild_transaction(
                d, rebuild_transaction)
            m["status"] = "ready"
            m["error"] = str(e)
            m["log"] = failure_log
            if isinstance(structured_repair, dict):
                m["rig_repair"] = structured_repair
            else:
                m.pop("rig_repair", None)
            write_manifest(slug, m)
            # The rollback is settled only after the restored manifest is
            # durably published.  If that final write fails, retain the
            # transaction directory as the recoverable copy instead of
            # deleting the only known-good manifest in ``finally``.
            rebuild_transaction["settled"] = "restored"
            raise
        m["status"] = "error"
        m["error"] = str(e)
        if isinstance(structured_repair, dict):
            m["rig_repair"] = structured_repair
        write_manifest(slug, m)
    finally:
        for relative in FACE_REBUILD_TRANSIENTS:
            _remove_artifact(os.path.join(d, relative))
        _finish_face_rebuild_transaction(rebuild_transaction)
    return m


def build_avatar(
        slug, shapes=None, log=None, quality="high", notes="",
        remove_headwear=None, source_medium=None):
    """Build one face while holding its process-wide mutation lease.

    Keep the lock outside transaction recovery and snapshot creation: a new
    backend can never restore an abandoned journal until the previous worker
    has either completed or died and the kernel has released its lease.
    """
    if inherited_avatar_face_build_lock(slug):
        return _build_avatar_under_lock(
            slug, shapes=shapes, log=log, quality=quality, notes=notes,
            remove_headwear=remove_headwear, source_medium=source_medium)
    with avatar_face_build_lock(slug, blocking=True) as descriptor:
        if descriptor is None:  # Blocking acquisition succeeds or raises.
            raise RuntimeError("could not acquire avatar face-build lock")
        return _build_avatar_under_lock(
            slug, shapes=shapes, log=log, quality=quality, notes=notes,
            remove_headwear=remove_headwear, source_medium=source_medium)


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
    a.add_argument(
        "--source-medium", choices=sorted(SOURCE_MEDIUM_OVERRIDES),
        help="owner-selected source category; omit to use local detection")
    a.add_argument("--build", action="store_true", help="generate the full set right away")
    b = sub.add_parser("build", help="generate + compose + preview")
    b.add_argument("slug"); b.add_argument("--shapes", nargs="*")
    b.add_argument(
        "--source-medium", choices=sorted(SOURCE_MEDIUM_OVERRIDES),
        help="override a mistaken source category before rebuilding")
    b.add_argument("--keep", default="",
                   help="what must survive the build, e.g. his bandana")
    b.add_argument("--remove-headwear", action="store_true", default=None,
                   help="remove source-worn hats/headwear instead of preserving them")
    b.add_argument("--preserve-headwear", action="store_false",
                   dest="remove_headwear", default=None,
                   help="preserve source-worn hats/headwear (the new-avatar default)")
    sub.add_parser("list", help="list avatars")
    c = sub.add_parser("activate"); c.add_argument("slug")
    e = sub.add_parser("delete"); e.add_argument("slug")
    args = ap.parse_args()

    if args.cmd == "add":
        m = create_avatar(
            args.image, args.name, args.slug,
            source_medium=args.source_medium)
        print(f"{m['slug']}: keyframe ready")
        for w in m["warnings"]:
            print("  warning:", w)
        if args.build:
            build_avatar(m["slug"])
    elif args.cmd == "build":
        build_avatar(
            args.slug, shapes=args.shapes, notes=args.keep,
            remove_headwear=args.remove_headwear,
            source_medium=args.source_medium)
    elif args.cmd == "list":
        for m in list_avatars():
            print(f"{'*' if m.get('active') else ' '} {m['slug']:24s} {m['status']:9s} "
                  f"{len(m.get('visemes') or [])} shapes")
    elif args.cmd == "activate":
        print("active ->", set_active(args.slug))
    elif args.cmd == "delete":
        delete_avatar(args.slug); print("deleted", args.slug)
