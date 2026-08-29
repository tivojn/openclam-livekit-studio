"""OpenClam Studio - one local process for chat, voice, and avatar creation.

The avatar studio used to be a separate server on another port. Merging it in
is not tidying: the runtime has to be able to SWAP the face while it is running,
and two processes with two views of which avatar is active is exactly how you
end up serving a manifest that describes a different head than the sprites.

Assets are no longer a folder of files inside web/. Each avatar owns its own
runtime bundle at avatars/<slug>/runtime/, and /assets/* resolves through the
active slug on every request. Activating a face is therefore one atomic write
to active.json, and no file is ever copied over another.
"""
import os, sys, json, base64, tempfile, threading, time, shutil, subprocess, secrets, asyncio
import datetime, re
from contextlib import asynccontextmanager
from posixpath import normpath as posix_normpath
os.environ["PATH"] = os.pathsep.join(filter(None, (
    "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", ""))))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)

import numpy as np
from fastapi import (FastAPI, UploadFile, File, Form, HTTPException, Query,
                     WebSocket, WebSocketDisconnect)
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

import providers as P
import credentials
import xai_oauth
import openai_account
import openclaw_pairing
import openclaw_acp
import livekit_bridge as LK
import avatar_package as AVTR
import align
from studio import rig

WEB = os.path.join(ROOT, "web")


@asynccontextmanager
async def lifespan(_application):
    _start()
    yield


app = FastAPI(title="OpenClam Studio", lifespan=lifespan)
APP_ID = "com.lionheart.openclam.macos"


def _app_version():
    """The build the owner is actually running. package.json is the one
    place the version is authored, so read it there rather than keeping a
    second copy that can drift (owner, 2026-08-05)."""
    try:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "package.json")) as handle:
            return str(json.load(handle).get("version") or "")
    except Exception:
        return ""


APP_VERSION = _app_version()
AUTH_TOKEN = os.environ.get("OPENCLAM_AUTH_TOKEN", "")
# Changes every engine start so long-lived renderer windows can detect a
# restarted backend and reload against the current route surface.
BOOT_ID = secrets.token_hex(4)
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
MAX_AUDIO_BYTES = 25 * 1024 * 1024
MAX_TTS_TEXT_CHARS = 15_000
MAX_TTS_TEXT_BYTES = 15_000
SLUG_PATTERN = r"^[a-z0-9](?:[a-z0-9-]{0,62})$"
# img/media allow https so chat cards can show pictures and play video the
# model links to; scripts stay same-origin only.
CSP = ("default-src 'self'; img-src 'self' data: blob: https:; "
       "media-src 'self' blob: https:; "
       "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
       # 'self' does not cover the ws: scheme, and live dictation streams
       # over a local WebSocket to this same server.
       "connect-src 'self' ws://127.0.0.1:* ws://localhost:*{livekit_origins}; "
       "font-src 'self' data:; frame-src 'self' blob:; object-src 'none'; "
       "base-uri 'none'; form-action 'self'; frame-ancestors 'none'")


def _content_security_policy():
    """Permit only the configured LiveKit Cloud websocket, never broad wss:."""
    livekit_origins = ""
    try:
        config = LK.deployment_config(P.load_livekit_nonsecret())
        expected_host = config.get("expected_server_host") or ""
        if expected_host:
            # livekit-client fetches the regional routing document over HTTPS
            # before it opens the signalling WebSocket. Keep both transports
            # pinned to the exact reviewed deployment host.
            livekit_origins = (
                f" https://{expected_host} wss://{expected_host}"
            )
    except LK.LiveKitBridgeError:
        # A malformed/manual config edit fails closed.  The settings endpoint
        # will report the specific safe validation error when it is opened.
        pass
    return CSP.format(livekit_origins=livekit_origins)


def _security_headers(response):
    # Pages are never cached: WKWebView happily served a stale renderer
    # across three debugging rounds (2026-08-02). Assets carry their own
    # cache-busting revs; the HTML must always be current.
    if str(response.headers.get("content-type", "")).startswith("text/html"):
        response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = _content_security_policy()
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    response.headers["Permissions-Policy"] = "camera=(self), geolocation=(), microphone=(self)"
    return response


def _client_token(source):
    """The per-install token injected by the loopback-only Electron shell."""
    return source.headers.get("x-openclam-token", "")


@app.middleware("http")
async def security_headers(request, call_next):
    if not AUTH_TOKEN:
        return _security_headers(JSONResponse(
            {"error": "local_auth_not_configured"},
            status_code=503,
            headers={"Cache-Control": "no-store"},
        ))
    if not secrets.compare_digest(_client_token(request), AUTH_TOKEN):
        return _security_headers(JSONResponse(
            {"error": "forbidden"},
            status_code=403,
            headers={"Cache-Control": "no-store"},
        ))
    origin = request.headers.get("origin", "")
    if request.method not in {"GET", "HEAD", "OPTIONS"} and origin:
        allowed_origin = f"{request.url.scheme}://{request.url.netloc}"
        if origin != allowed_origin:
            response = JSONResponse(
                {"error": "cross-origin request rejected"},
                status_code=403,
                headers={"Cache-Control": "no-store"},
            )
            return _security_headers(response)
    response = await call_next(request)
    # This also covers framework-generated request-validation errors before an
    # OAuth handler runs, so user/device codes can never enter a shared cache.
    if request.url.path.startswith("/api/") or request.url.path == "/health":
        response.headers["Cache-Control"] = "no-store"
    return _security_headers(response)


_state = {"warm": False, "warming": ""}
_jobs = {}                      # slug -> live build/calibration state
_jlock = threading.Lock()


def _reserve_job(slug, kind, label="Queued"):
    with _jlock:
        current = _jobs.get(slug)
        if current and not current.get("done"):
            return None
        job_id = secrets.token_hex(12)
        _jobs[slug] = dict(
            id=job_id, phase=label, done=False, error="", log=[], kind=kind,
            progress={"stage": "queued", "value": 0.0, "label": label})
        # A NEW attempt of the same kind is the only thing that retires the
        # last failure of that kind - not merely the next job of any kind,
        # or the automatic publish that follows a build would erase the
        # explanation before anyone read it.
        _failures.pop((slug, kind), None)
    _build_log_write(slug, f"=== {kind} started: {label}")
    return job_id


def _finish_job(slug, job_id, error=""):
    kind = ""
    with _jlock:
        job = _jobs.get(slug)
        if not job or job.get("id") != job_id:
            # The record was already replaced. The failure still happened,
            # and it is still the answer to "why did nothing arrive".
            if error:
                _failures[(slug, "")] = {
                    "kind": "", "error": str(error),
                    "when": datetime.datetime.now().isoformat(timespec="seconds"),
                }
            return
        kind = str(job.get("kind") or "")
        job["error"] = str(error or job.get("error") or "")
        job["done"] = True
        if job["error"]:
            _failures[(slug, kind)] = {
                "kind": kind, "error": job["error"],
                "when": datetime.datetime.now().isoformat(timespec="seconds"),
            }
    if error:
        _build_log_write(slug, f"=== {kind or 'job'} FAILED: {error}")
    else:
        _build_log_write(slug, f"=== {kind or 'job'} finished")


def _last_failure(slug):
    """The most recent failed build for this avatar, whatever ran since."""
    with _jlock:
        rows = [row for (key, _), row in _failures.items() if key == slug]
    if not rows:
        return None
    return sorted(rows, key=lambda row: row.get("when") or "")[-1]


def _already_running(slug):
    with _jlock:
        current = dict(_jobs.get(slug) or {})
    return {
        "started": False,
        "reason": "already building",
        "job_id": current.get("id"),
        "kind": current.get("kind"),
    }


def reg():
    from studio import build as _r
    return _r


# ---------------------------------------------------------------- avatars

def runtime_dir(slug):
    return os.path.join(reg().adir(slug), "runtime")


def _runtime_manifest(directory):
    manifest_path = os.path.join(directory, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise ValueError("runtime manifest is missing")
    with open(manifest_path) as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict):
        raise ValueError("runtime manifest is not an object")
    return manifest


def _runtime_asset(directory, reference):
    if not isinstance(reference, str) or not reference.startswith("assets/"):
        raise ValueError("runtime asset reference is invalid")
    root = os.path.abspath(directory)
    asset = os.path.abspath(os.path.join(root, reference[len("assets/"):]))
    if os.path.commonpath((root, asset)) != root:
        raise ValueError("runtime asset escapes its bundle")
    if not os.path.isfile(asset) or os.path.getsize(asset) <= 0:
        raise ValueError(f"runtime asset is missing: {reference}")


def _validate_runtime_bundle(directory, expect_motion=None):
    manifest = _runtime_manifest(directory)
    runtime_motion = manifest.get("motion")
    if expect_motion is False and runtime_motion:
        raise ValueError("runtime still contains motion after removal")
    available = []
    if runtime_motion:
        if not isinstance(runtime_motion, dict):
            raise ValueError("runtime motion metadata is missing")
        for kind in ("walk", "idle", "move"):
            clip = runtime_motion.get(kind)
            if not clip:
                continue
            if not isinstance(clip, dict) or not (
                    clip.get("sheets") or clip.get("alpha_stream")):
                raise ValueError(f"runtime {kind} clip assets are missing")
            if clip.get("alpha_stream"):
                _runtime_asset(directory, clip["alpha_stream"])
            if clip.get("alpha_stream_hevc"):
                _runtime_asset(directory, clip["alpha_stream_hevc"])
            for sheet in clip.get("sheets") or []:
                _runtime_asset(directory, sheet.get("image"))
            if clip.get("poster"):
                _runtime_asset(directory, clip["poster"])
            available.append(kind)
    if expect_motion is True and not available:
        raise ValueError("runtime motion metadata is missing")
    return manifest


def _recover_runtime_swap(slug):
    live = runtime_dir(slug)
    previous = live + ".previous"
    if not os.path.exists(live) and os.path.isdir(previous):
        _validate_runtime_bundle(previous)
        os.replace(previous, live)
    return live


def active_slug():
    try:
        return reg().get_active()
    except Exception:
        return None


RUNTIME_VERSION = 22  # v22: sharp held smile/laughter plate at exact 18% lift


def ensure_runtime(slug, log=print):
    """An avatar is only usable once it has a runtime bundle. Build one on demand
    rather than at activation time, so importing an old avatar folder works.
    Bundles from an older exporter are republished the same way, so asset
    upgrades (like the widened gaze grid) reach existing avatars without a
    manual rebuild."""
    d = _recover_runtime_swap(slug)
    manifest_path = os.path.join(d, "manifest.json")
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, encoding="utf-8") as handle:
                version = int((json.load(handle) or {}).get("v") or 0)
        except (OSError, ValueError):
            version = 0
        if version >= RUNTIME_VERSION:
            return d
        log(f"runtime bundle is v{version}; republishing as v{RUNTIME_VERSION}")
        try:
            _publish_runtime_atomic(slug, log=log)
            return d
        except Exception as error:
            log(f"runtime refresh failed, keeping v{version}: {error}")
            return d
    from studio import export
    log("publishing runtime bundle")
    export.export(slug, d, log=log)
    return d


# Punctuation that opens or closes a machine payload - never a sentence
# worth putting on screen as the current phase.
_PHASE_NOISE = "{}[]()\"',^"


def _phase_headline(line):
    """The part of a worker line worth showing as the status, if any."""
    text = line.strip()
    if not text:
        return ""
    # The one JSON line that IS the message: "error": "...".
    hit = re.match(r'^"?(?:error|detail|message)"?\s*:\s*"?(.+?)"?,?$', text)
    if hit:
        return hit.group(1)
    if text[0] in _PHASE_NOISE:
        return ""
    return text


# The last failure per avatar, kept OUTSIDE _jobs so it survives the next
# job. _reserve_job replaces _jobs[slug] wholesale, so a failed build's
# error and its whole log were destroyed by whatever ran next - which is
# how a four-minute failure became "it never showed me any error message,
# it just didn't deliver" (owner, 2026-08-04).
_failures = {}


def _build_log_path(slug):
    try:
        return os.path.join(reg().adir(slug), "build.log")
    except Exception:
        return ""


def _build_log_write(slug, line):
    """One build line, on disk, timestamped. Memory forgets; this does not."""
    path = _build_log_path(slug)
    if not path:
        return
    try:
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{stamp}  {line}\n")
        # Bounded: a build log is for the last few builds, not forever.
        if os.path.getsize(path) > 512_000:
            with open(path, encoding="utf-8") as handle:
                tail = handle.readlines()[-2000:]
            with open(path, "w", encoding="utf-8") as handle:
                handle.writelines(tail)
    except Exception:
        pass


def jlog(slug, phase=None):
    with _jlock:
        j = _jobs.setdefault(slug, {"log": [], "phase": "", "done": False, "error": ""})
        if phase:
            j["phase"] = phase
    if phase:
        _build_log_write(slug, f"--- {phase}")

    def w(msg):
        line = str(msg).rstrip()
        if not line:
            return
        with _jlock:
            j["log"].append(line)
            del j["log"][:-400]
            # A provider that fails prints a multi-line JSON blob, and the
            # LAST line of it is "})" - so the status read "})" while the
            # sentence that said what went wrong scrolled past unseen
            # (owner: is this normal, 2026-08-04). Show the headline.
            headline = _phase_headline(line)
            if headline:
                j["phase"] = headline[:120]
        print(f"[avatar:{slug}] {line}", flush=True)
        _build_log_write(slug, line)
    return w


def _job_progress(slug, stage, value, label, job_id=None):
    payload = {
        "stage": str(stage),
        "value": max(0.0, min(1.0, float(value))),
        "label": str(label),
    }
    with _jlock:
        job = _jobs.get(slug)
        if job_id and (not job or job.get("id") != job_id):
            return
        if not job:
            job = _jobs.setdefault(
                slug, {"log": [], "phase": "", "done": False, "error": ""})
        job["progress"] = payload
        job["phase"] = payload["label"]


def _run_avatar_worker(args, log):
    process = subprocess.Popen(
        [sys.executable, "-W", "ignore", *args],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    for line in process.stdout:
        log(line.rstrip())
    code = process.wait()
    if code:
        raise RuntimeError(f"avatar worker exited with status {code}")


def _build_thread(slug, shapes=None, notes="", remove_headwear=None):
    w = jlog(slug, "starting")
    with _jlock:
        _jobs[slug].update(done=False, error="", log=[])
    try:
        build_args = ["-m", "studio.build", "build", slug]
        if shapes:
            build_args.extend(["--shapes", *shapes])
        if notes:
            build_args.extend(["--keep", notes])
        if remove_headwear is True:
            build_args.append("--remove-headwear")
        elif remove_headwear is False:
            build_args.append("--preserve-headwear")
        _run_avatar_worker(build_args, w)
        d = runtime_dir(slug)
        if os.path.isdir(d):
            shutil.rmtree(d)
        w("publishing runtime bundle")
        _run_avatar_worker(["-m", "studio.export", slug, "--dest", d], w)
        w("ready")
    except Exception as e:
        with _jlock:
            _jobs[slug]["error"] = str(e)
        w(f"FAILED: {e}")
    finally:
        with _jlock:
            _jobs[slug]["done"] = True


def _recompose_thread(slug, profile):
    w = jlog(slug, "calibrating")
    with _jlock:
        _jobs[slug].update(
            done=False, error="", log=[], kind="calibration",
            progress={"stage": "starting", "value": .02,
                      "label": "Starting calibration"})
    try:
        reg().recompose_avatar(
            slug, profile, log=w,
            progress=lambda stage, value, label:
                _job_progress(slug, stage, value, label))
        w("ready")
    except Exception as e:
        with _jlock:
            _jobs[slug]["error"] = str(e)
            repair = getattr(e, "repair", None)
            if isinstance(repair, dict):
                _jobs[slug]["repair"] = repair
        w(f"FAILED: {e}")
    finally:
        with _jlock:
            _jobs[slug]["done"] = True


def _publish_runtime_atomic(slug, log=print, keep_previous=False):
    from studio import export
    directory = reg().adir(slug)
    _recover_runtime_swap(slug)
    staged = tempfile.mkdtemp(prefix=".runtime-stage-", dir=directory)
    live = runtime_dir(slug)
    previous = live + ".previous"
    try:
        blink_source = os.path.join(directory, "visemes", "v_blink.jpg")
        if os.path.isfile(blink_source):
            export.export(slug, staged, log=log)
        elif os.path.isfile(os.path.join(live, "manifest.json")):
            shutil.copytree(live, staged, dirs_exist_ok=True)
            export.publish_pet_assets(slug, staged, log=log)
        else:
            raise ValueError("avatar has neither source visemes nor a published runtime")
        expect_motion = os.path.isfile(
            os.path.join(directory, "motion", "motion.json"))
        _validate_runtime_bundle(staged, expect_motion=expect_motion)
        shutil.rmtree(previous, ignore_errors=True)
        if os.path.exists(live):
            os.replace(live, previous)
        try:
            os.replace(staged, live)
            staged = None
            _validate_runtime_bundle(live, expect_motion=expect_motion)
        except Exception:
            shutil.rmtree(live, ignore_errors=True)
            if os.path.exists(previous):
                os.replace(previous, live)
            raise
        if not keep_previous:
            shutil.rmtree(previous, ignore_errors=True)
    except Exception:
        if not os.path.exists(live) and os.path.exists(previous):
            os.replace(previous, live)
        raise
    finally:
        if staged and os.path.exists(staged):
            shutil.rmtree(staged, ignore_errors=True)


_BODY_EDIT_TRANSACTION_DIRNAME = ".body-edit-transaction"
_BODY_EDIT_TRANSACTION_VERSION = 1
_BODY_EDIT_TRANSACTION_PHASES = frozenset({
    "prepared", "body-installed", "state-written", "committed",
})


def _body_edit_transaction_dir(directory):
    return os.path.join(directory, _BODY_EDIT_TRANSACTION_DIRNAME)


def _fsync_directory(directory):
    """Best-effort durability for an atomic rename's parent directory."""
    descriptor = None
    try:
        descriptor = os.open(directory, os.O_RDONLY)
        os.fsync(descriptor)
    except OSError:
        # Some packaged/runtime filesystems do not permit directory fsync.
        # The atomic rename still provides process-failure safety there.
        pass
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _write_private_json(path, payload):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    temporary = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=1)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        _fsync_directory(os.path.dirname(path))
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def _copy_private_file(source, destination):
    if os.path.islink(source) or not os.path.isfile(source):
        raise RuntimeError("body-edit snapshot source is not a regular file")
    shutil.copy2(source, destination)
    os.chmod(destination, 0o600)


def _copy_private_tree(source, destination):
    if os.path.islink(source) or not os.path.isdir(source):
        raise RuntimeError("body-edit snapshot source is not a regular directory")
    for root, directories, files in os.walk(source):
        for name in directories + files:
            if os.path.islink(os.path.join(root, name)):
                raise RuntimeError("body-edit snapshots do not follow symbolic links")
    shutil.copytree(source, destination, dirs_exist_ok=True)


def _read_body_edit_journal(directory):
    transaction = _body_edit_transaction_dir(directory)
    path = os.path.join(transaction, "transaction.json")
    try:
        with open(path, encoding="utf-8") as handle:
            journal = json.load(handle)
    except (OSError, ValueError) as error:
        raise RuntimeError(
            "an unfinished full-body edit has unreadable recovery data") from error
    if (not isinstance(journal, dict)
            or journal.get("v") != _BODY_EDIT_TRANSACTION_VERSION
            or journal.get("phase") not in _BODY_EDIT_TRANSACTION_PHASES):
        raise RuntimeError("an unfinished full-body edit has invalid recovery data")
    return journal


def _begin_body_edit_transaction(slug):
    """Persist exact pre-edit state before any canonical authoring mutation."""
    directory = reg().adir(slug)
    transaction = _body_edit_transaction_dir(directory)
    if os.path.exists(transaction):
        _recover_body_edit_transaction(slug)
    stage = tempfile.mkdtemp(
        prefix=".body-edit-transaction-stage-", dir=directory)
    try:
        os.chmod(stage, 0o700)
        manifest = os.path.join(directory, "manifest.json")
        motion = os.path.join(directory, "motion")
        library_index = os.path.join(directory, "library", "library.json")
        runtime = runtime_dir(slug)
        journal = {
            "v": _BODY_EDIT_TRANSACTION_VERSION,
            "slug": slug,
            "phase": "prepared",
            "manifest_existed": os.path.isfile(manifest),
            "motion_existed": os.path.isdir(motion),
            "library_index_existed": os.path.isfile(library_index),
            "runtime_existed": os.path.isdir(runtime),
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        if journal["manifest_existed"]:
            _copy_private_file(manifest, os.path.join(stage, "manifest.json"))
        if journal["motion_existed"]:
            _copy_private_tree(motion, os.path.join(stage, "motion"))
        if journal["library_index_existed"]:
            _copy_private_file(
                library_index, os.path.join(stage, "library.json"))
        _write_private_json(os.path.join(stage, "transaction.json"), journal)
        os.replace(stage, transaction)
        stage = None
        _fsync_directory(directory)
        return journal
    finally:
        if stage and os.path.exists(stage):
            shutil.rmtree(stage, ignore_errors=True)


def _set_body_edit_transaction_phase(slug, phase):
    if phase not in _BODY_EDIT_TRANSACTION_PHASES:
        raise ValueError(f"invalid body-edit transaction phase: {phase}")
    directory = reg().adir(slug)
    journal = _read_body_edit_journal(directory)
    if journal.get("slug") != slug:
        raise RuntimeError("body-edit recovery data belongs to another avatar")
    journal["phase"] = phase
    journal["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    _write_private_json(
        os.path.join(_body_edit_transaction_dir(directory), "transaction.json"),
        journal)
    return journal


def _replace_tree_from_snapshot(snapshot, destination):
    """Atomically copy a retained tree into place without consuming it."""
    parent = os.path.dirname(destination)
    stage = tempfile.mkdtemp(prefix=".body-edit-restore-", dir=parent)
    displaced = None
    try:
        _copy_private_tree(snapshot, stage)
        if os.path.exists(destination):
            displaced = (
                destination + ".body-edit-displaced-" + secrets.token_hex(4))
            os.replace(destination, displaced)
        try:
            os.replace(stage, destination)
            stage = None
        except Exception:
            if (not os.path.exists(destination) and displaced
                    and os.path.exists(displaced)):
                os.replace(displaced, destination)
                displaced = None
            raise
        if displaced:
            shutil.rmtree(displaced, ignore_errors=True)
            displaced = None
        _fsync_directory(parent)
    finally:
        if stage and os.path.exists(stage):
            shutil.rmtree(stage, ignore_errors=True)
        if displaced and os.path.exists(displaced):
            # A restored destination is authoritative. A displaced tree is
            # only the failed/new state and must never replace it afterward.
            shutil.rmtree(displaced, ignore_errors=True)


def _restore_file_snapshot(snapshot, destination, existed):
    if not existed:
        try:
            os.remove(destination)
        except FileNotFoundError:
            pass
        return
    if not os.path.isfile(snapshot) or os.path.islink(snapshot):
        raise RuntimeError("body-edit file snapshot is missing")
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    temporary = destination + ".body-edit-restore-" + secrets.token_hex(4)
    try:
        shutil.copy2(snapshot, temporary)
        os.replace(temporary, destination)
        _fsync_directory(os.path.dirname(destination))
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def _restore_tree_snapshot(snapshot, destination, existed):
    if not existed:
        shutil.rmtree(destination, ignore_errors=True)
        return
    if not os.path.isdir(snapshot) or os.path.islink(snapshot):
        raise RuntimeError("body-edit directory snapshot is missing")
    _replace_tree_from_snapshot(snapshot, destination)


def _finish_committed_body_edit(slug, log=print):
    """Complete cleanup for a committed edit; safe to repeat after a crash."""
    from studio import body, library
    directory = reg().adir(slug)
    try:
        library.archive_body(directory)
    except Exception as archive_error:
        # Canonical body/manifest/runtime are already committed. Status sync
        # retries this idempotent archive, so do not roll back a working edit.
        log(f"could not archive the edited body set: {archive_error}")
    shutil.rmtree(os.path.join(directory, ".body-cache"), ignore_errors=True)
    body.commit_previous(directory)
    shutil.rmtree(runtime_dir(slug) + ".previous", ignore_errors=True)
    shutil.rmtree(_body_edit_transaction_dir(directory), ignore_errors=True)
    _fsync_directory(directory)


def _recover_body_edit_transaction(slug, log=print):
    """Roll back or finish one persisted body edit after interruption."""
    from studio import body
    directory = reg().adir(slug)
    transaction = _body_edit_transaction_dir(directory)
    if not os.path.isdir(transaction):
        return None
    journal = _read_body_edit_journal(directory)
    if journal.get("slug") != slug:
        raise RuntimeError("body-edit recovery data belongs to another avatar")
    if journal["phase"] == "committed":
        _finish_committed_body_edit(slug, log=log)
        return "committed"

    previous_body = os.path.join(directory, "body.previous")
    canonical_body = os.path.join(directory, "body")
    if os.path.isdir(previous_body):
        _replace_tree_from_snapshot(previous_body, canonical_body)
    elif journal["phase"] != "prepared":
        raise RuntimeError("the pre-edit body recovery snapshot is missing")

    _restore_tree_snapshot(
        os.path.join(transaction, "motion"),
        os.path.join(directory, "motion"),
        bool(journal.get("motion_existed")))
    _restore_file_snapshot(
        os.path.join(transaction, "manifest.json"),
        os.path.join(directory, "manifest.json"),
        bool(journal.get("manifest_existed")))
    _restore_file_snapshot(
        os.path.join(transaction, "library.json"),
        os.path.join(directory, "library", "library.json"),
        bool(journal.get("library_index_existed")))

    live = runtime_dir(slug)
    previous_runtime = live + ".previous"
    if os.path.isdir(previous_runtime):
        _replace_tree_from_snapshot(previous_runtime, live)
    elif not journal.get("runtime_existed"):
        shutil.rmtree(live, ignore_errors=True)

    body.commit_previous(directory)
    shutil.rmtree(previous_runtime, ignore_errors=True)
    shutil.rmtree(transaction, ignore_errors=True)
    _fsync_directory(directory)
    log("recovered the previous full-body authoring state")
    return "rolled-back"


def _recover_body_edit_transaction_if_idle(slug, log=print):
    """Never mistake an active worker's journal for a crashed transaction."""
    with _jlock:
        current = _jobs.get(slug) or {}
        if current and not current.get("done"):
            return None
    return _recover_body_edit_transaction(slug, log=log)


def _body_stage(slug, options, w, progress):
    """Generate the three body plates and publish them. Shared by the
    standalone body job and the one-click pipeline; raises on failure."""
    from studio import body, library, motion
    # Older packaged builds did not always preserve source-medium evidence at
    # intake.  Repair only missing/unknown labels from the registry-owned
    # original before body.py chooses its strict versus stylized alpha gates.
    reg().repair_source_medium_from_source(slug, log=w)
    _recover_body_edit_transaction(slug, log=w)
    # The canonical talking head owns this choice. A standalone body request
    # must not silently put a removed hat back on, or drop a preserved one.
    options = dict(options or {})
    canonical_manifest = reg().read_manifest(slug) or {}
    canonical_head = canonical_manifest.get("head") or {}
    if "remove_headwear" in canonical_head:
        options["remove_headwear"] = bool(canonical_head["remove_headwear"])
    progress("generation", .12, "Generating front, side, and back bodies")
    metadata = body.build(
        reg().adir(slug), options, log=w, progress=progress)
    motion.remove(reg().adir(slug))
    for slot in ("walk", "idle"):
        library.clear_active(reg().adir(slug), slot)
    manifest = reg().read_manifest(slug) or {}
    manifest["body"] = metadata
    manifest.pop("motion", None)
    reg().write_manifest(slug, manifest)
    try:
        library.archive_body(reg().adir(slug))
    except Exception as archive_error:
        w(f"could not archive the body set: {archive_error}")
    progress("runtime", .86, "Publishing transparent companion")
    _publish_runtime_atomic(slug, log=w)


def _body_thread(slug, options):
    w = jlog(slug, "starting full-body generation")
    with _jlock:
        _jobs[slug].update(
            done=False, error="", log=[], kind="body",
            progress={"stage": "provider", "value": .03,
                      "label": "Reading OpenClam image provider"})
    try:
        _body_stage(slug, options, w,
                    lambda stage, value, label:
                        _job_progress(slug, stage, value, label))
        _job_progress(slug, "done", 1.0, "Three full-body views ready")
        w("front, side, and back full-body companion plates ready")
    except Exception as error:
        with _jlock:
            _jobs[slug]["error"] = str(error)
        w(f"FAILED: {error}")
    finally:
        with _jlock:
            _jobs[slug]["done"] = True


def _body_edit_stage(slug, instruction, writer, progress):
    """Edit one coherent turnaround and publish it as an undoable body set."""
    from studio import body, library
    directory = reg().adir(slug)
    _recover_body_edit_transaction(slug, log=writer)
    # Preserve the exact current body and all canonical motion sets before the
    # journal snapshot. This durable library copy is the user's visible undo;
    # the journal remains the byte-exact crash/exception rollback source.
    library.sync_canonical(directory)
    previous_manifest = reg().read_manifest(slug) or {}
    _begin_body_edit_transaction(slug)
    try:
        metadata = body.edit(
            directory, instruction, log=writer, progress=progress)
        _set_body_edit_transaction_phase(slug, "body-installed")
        manifest = dict(previous_manifest)
        manifest["body"] = metadata
        _apply_motion_metadata(
            manifest, library.reconcile_motion_with_body(directory))
        reg().write_manifest(slug, manifest)
        _set_body_edit_transaction_phase(slug, "state-written")
        progress("runtime", .92, "Publishing edited transparent companion")
        _publish_runtime_atomic(slug, log=writer, keep_previous=True)
        # From this durable marker onward body, motion, manifest, and runtime
        # are a coherent committed state. Recovery finishes archive/cleanup
        # rather than reverting a successfully published edit.
        _set_body_edit_transaction_phase(slug, "committed")
        _finish_committed_body_edit(slug, log=writer)
        return metadata
    except Exception as error:
        rollback_errors = []
        try:
            _recover_body_edit_transaction(slug, log=writer)
        except Exception as rollback_error:
            rollback_errors.append(f"exact rollback: {rollback_error}")
        failure = str(error)
        if rollback_errors:
            failure = f"{failure}; {'; '.join(rollback_errors)}"
        raise RuntimeError(failure) from error


def _body_edit_thread(slug, instruction, job_id):
    writer = jlog(slug, "editing the matched full-body set")
    with _jlock:
        job = _jobs.get(slug)
        if not job or job.get("id") != job_id:
            return
        job.update(
            done=False, error="", log=[], kind="body-edit",
            progress={"stage": "provider", "value": .03,
                      "label": "Preparing xAI full-body edit"})
    failure = ""
    try:
        _body_edit_stage(
            slug, instruction, writer,
            lambda stage, value, label: _job_progress(
                slug, stage, value, label, job_id=job_id))
        _job_progress(
            slug, "done", 1.0, "Edited full-body set ready", job_id=job_id)
        writer("front, side, and back edits passed local identity lock")
    except Exception as error:
        failure = str(error)
        # The instruction is authoring input, not diagnostic telemetry. A
        # provider may echo it in an HTTP error body, so remove both literal
        # and JSON-escaped forms before the job record/build log persists it.
        for private_value in {
                instruction,
                json.dumps(instruction, ensure_ascii=False)[1:-1]}:
            if private_value:
                failure = failure.replace(
                    private_value, "[full-body edit instruction redacted]")
        writer(f"FAILED: {failure}")
    finally:
        _finish_job(slug, job_id, failure)


def _motion_stage(slug, kinds, idle_pose, walk_style, move_style, writer,
                  progress, reference_path=None):
    """Generate motion takes and publish them, rolling back a half-replaced
    bank on failure. Shared by the standalone motion job and the one-click
    pipeline; raises on failure."""
    from studio import motion
    previous_manifest = reg().read_manifest(slug) or {}
    motion_replaced = False
    runtime_published = False
    try:
        metadata = motion.build(
            reg().adir(slug),
            pose_reference=reference_path,
            idle_pose=idle_pose,
            kinds=kinds,
            walk_style=walk_style,
            move_style=move_style,
            log=writer,
            progress=progress,
            keep_previous=True,
        )
        motion_replaced = True
        manifest = dict(previous_manifest)
        manifest["motion"] = metadata
        reg().write_manifest(slug, manifest)
        progress("runtime", .94, "Publishing alpha motion")
        _publish_runtime_atomic(slug, log=writer)
        runtime_published = True
        motion.commit_pending_build(reg().adir(slug))
        try:
            from studio import library
            for archived_kind in tuple(kinds or ("walk", "idle")):
                library.archive_motion(reg().adir(slug), archived_kind)
        except Exception as archive_error:
            writer(f"could not archive the motion set: {archive_error}")
    except Exception as error:
        failure = str(error)
        rollback_errors = []
        if motion_replaced and not runtime_published:
            try:
                motion.rollback_pending_build(reg().adir(slug))
            except Exception as rollback_error:
                rollback_errors.append(f"motion rollback: {rollback_error}")
            try:
                reg().write_manifest(slug, previous_manifest)
            except Exception as rollback_error:
                rollback_errors.append(f"manifest rollback: {rollback_error}")
        if rollback_errors:
            failure = f"{failure}; {'; '.join(rollback_errors)}"
        raise RuntimeError(failure) from error


def _motion_thread(
        slug, reference_path, job_id, idle_pose=None,
        kinds=None, walk_style=None, move_style=None):
    writer = jlog(slug, "starting desktop motion generation")
    with _jlock:
        job = _jobs.get(slug)
        if not job or job.get("id") != job_id:
            if reference_path:
                try:
                    os.remove(reference_path)
                except FileNotFoundError:
                    pass
            return
        job.update(
            done=False, error="", log=[], kind="motion",
            progress={"stage": "provider", "value": .03,
                      "label": "Reading OpenClam media providers"})
    failure = ""
    try:
        _motion_stage(
            slug, kinds, idle_pose, walk_style, move_style, writer,
            lambda stage, value, label: _job_progress(
                slug, stage, value, label, job_id=job_id),
            reference_path=reference_path)
        selected = tuple(kinds or ("walk", "idle"))
        kind_labels = {"walk": "Horizon Walk", "idle": "Edge Idle",
                       "move": "Show Me Some Moves"}
        label = " and ".join(kind_labels[k] for k in selected)
        _job_progress(
            slug, "done", 1.0, f"{label} ready", job_id=job_id)
        writer(f"{label} and standing interaction are ready")
    except Exception as error:
        failure = str(error)
        writer(f"FAILED: {failure}")
    finally:
        if reference_path:
            try:
                os.remove(reference_path)
            except FileNotFoundError:
                pass
        _finish_job(slug, job_id, failure)


_PIPELINE_BODY_MEDIA = {
    "photograph": "photorealistic",
    "game art": "illustrated",
    "game-art": "illustrated",
    "anime": "anime",
    "illustration": "illustrated",
    "illustrated": "illustrated",
    "cartoon": "illustrated",
    "drawing": "illustrated",
    "3d render": "soft-3d",
    "3d-render": "soft-3d",
    "soft-3d": "soft-3d",
}


def _pipeline_source_medium(report):
    """Whitelist one stored intake report; unknown values are photographs.

    This deliberately mirrors the build/export trust boundary.  Planner prose,
    body style, and a future arbitrary label may never opt a project into the
    more permissive stylized face/body paths.
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


def _pipeline_manifest_source_medium(manifest):
    """Return the first authoritative stored report, or ``None`` if absent.

    Presence is intentional: a malformed/empty ``source_metrics`` report fails
    closed to photograph instead of falling through to generated-head metrics.
    """
    if not isinstance(manifest, dict):
        return None
    for key in ("source_metrics", "metrics"):
        if key in manifest:
            return _pipeline_source_medium(manifest.get(key))
    return None


def _pipeline_body_medium(body_traits, manifest):
    """Retain a rig's proven medium when wardrobe planning falls back.

    The generated prose may be rejected for a bag, colour, or garment without
    invalidating the independent source classifier.  Prefer the canonical head
    source metrics, then generated-head metrics as a legacy fallback, then a
    validated planner trait, and fail closed to photograph.  A provider may
    normalize a stylized head enough that the local head classifier calls the
    generated plate a photograph; that must not erase the medium the owner
    actually uploaded.
    """
    stored_medium = _pipeline_manifest_source_medium(manifest)
    if stored_medium is not None:
        return stored_medium
    # Legacy projects with neither intake nor generated-head evidence may use
    # a validated wardrobe result for presentation only. Unknown prose still
    # fails closed and never selects a stylized detector by itself.
    trait_medium = _pipeline_source_medium({
        "source_medium": body_traits.get("medium")
        if isinstance(body_traits, dict) else None,
    })
    return trait_medium


def _pipeline_face_needs_rebuild(manifest, notes, remove_headwear):
    """Return whether one-click must rebuild the talking-face bundle.

    Ready legacy heads are not silently reused after a prompt/policy upgrade.
    The decision deliberately keys the expected prompt version from original
    source evidence before generated-head metrics, matching the body and
    package routing boundaries.
    """
    if not isinstance(manifest, dict) or manifest.get("status") != "ready":
        return True
    if str(notes or "").strip():
        return True

    head = manifest.get("head")
    if not isinstance(head, dict):
        return True
    # These fields were introduced with the explicit preserve/remove contract.
    # Their absence is not equivalent to an intentional Preserve selection.
    if "remove_headwear" not in head or "headwear_policy" not in head:
        return True

    source_medium = _pipeline_manifest_source_medium(manifest) or "photograph"

    from studio import generate
    expected_version = generate.head_prompt_version(source_medium)
    try:
        stored_version = int(head.get("prompt_version"))
    except (TypeError, ValueError):
        return True
    if stored_version != expected_version:
        return True

    requested_remove = bool(remove_headwear)
    expected_policy = "remove" if requested_remove else "preserve"
    return (
        bool(head.get("remove_headwear")) != requested_remove
        or str(head.get("headwear_policy") or "").strip().lower()
        != expected_policy
    )


def _pipeline_thread(slug, job_id, notes="", remove_headwear=None):
    """One click, everything: talking face (if not built) -> full body ->
    walk, edge idle, and moves - sequentially, in one background job."""
    writer = jlog(slug, "one-click pipeline: face, full body, walk, idle, moves")
    with _jlock:
        job = _jobs.get(slug)
        if not job or job.get("id") != job_id:
            return
        job.update(
            done=False, error="", log=[], kind="pipeline",
            progress={"stage": "face", "value": .01,
                      "label": "One-click 1/3: talking face"})

    def band(base, span, prefix):
        def report(stage, value, label):
            fraction = max(0.0, min(1.0, float(value or 0.0)))
            _job_progress(slug, stage, base + fraction * span,
                          prefix + label, job_id=job_id)
        return report

    failure = ""
    try:
        from studio import motion, wardrobe
        manifest = reg().read_manifest(slug) or {}
        manifest = reg().repair_source_medium_from_source(
            slug, manifest=manifest, log=writer)
        previous_remove_headwear = bool(
            ((manifest.get("head") or {}).get("remove_headwear", False)))
        remove_headwear = (previous_remove_headwear
                           if remove_headwear is None
                           else bool(remove_headwear))
        # A keep-note CHANGES the head prompt, so the face that is already
        # built was made without it - skipping the face would have meant
        # the one thing the owner asked to keep never came back. The head
        # cache keys on the prompt, so this re-renders rather than reusing
        # (owner: his bandana is gone, 2026-08-04).
        rebuild_face = _pipeline_face_needs_rebuild(
            manifest, notes, remove_headwear)
        if rebuild_face:
            _job_progress(slug, "face", .02,
                          "One-click 1/3: building the talking face"
                          + (" with your notes" if notes else ""),
                          job_id=job_id)
            manifest = reg().build_avatar(
                slug, notes=notes, remove_headwear=remove_headwear) or {}
            if manifest.get("status") != "ready":
                raise RuntimeError(
                    manifest.get("error") or "the face build failed")
        _job_progress(slug, "face", .30,
                      "One-click 1/3: talking face ready", job_id=job_id)
        # Resumable: a re-click after a partial run picks up where it
        # stopped instead of regenerating finished stages.
        body_manifest_path = os.path.join(
            reg().adir(slug), "body", "body.json")
        if (reg().read_manifest(slug) or {}).get("body") \
                and os.path.isfile(body_manifest_path):
            writer("full body already built - skipping")
            _job_progress(slug, "body", .58,
                          "One-click 2/3: full body already built",
                          job_id=job_id)
        else:
            tailored = wardrobe.tailored_prompt(reg().adir(slug), log=writer)
            body_prompt = tailored.get("prompt") or wardrobe.preset_prompt()
            body_traits = tailored.get("traits") or {}
            body_medium = _pipeline_body_medium(body_traits, manifest)
            _body_stage(
                slug,
                BodyProfileInput(
                    style=_PIPELINE_BODY_MEDIA[body_medium],
                    prompt=body_prompt,
                    notes=notes,
                    remove_headwear=remove_headwear,
                    presentation=body_traits.get("presentation") or "androgynous",
                    medium=body_medium,
                ).model_dump(),
                writer,
                band(.30, .28, "One-click 2/3: "),
            )
        # The takes run ONE AT A TIME with backoff retries: firing all
        # three at once burst past xAI's 2-requests-per-second team limit
        # ("Too many requests", eve 2026-08-01) and one provider hiccup
        # killed the whole stage. A kind that still fails after retries is
        # reported and the pipeline moves on to the next.
        kind_labels = {"walk": "Horizon Walk", "idle": "Edge Idle",
                       "move": "Show Me Some Moves"}
        body_presentation = motion.body_presentation(reg().adir(slug))
        idle_pose = motion.resolve_idle_pose(
            None, "", presentation=body_presentation,
            remap_unsafe=True)
        walk_style = motion.resolve_walk_style(None, "")
        move_style = motion.resolve_move_style(None, "")
        existing = set((reg().read_manifest(slug) or {}).get("motion") or {})
        bands = {"walk": (.58, .14), "idle": (.72, .13), "move": (.85, .13)}
        motion_failures = {}
        for kind in ("walk", "idle", "move"):
            base, span = bands[kind]
            if kind in existing:
                writer(f"{kind} take already built - skipping")
                _job_progress(slug, kind, base + span,
                              f"One-click 3/3: {kind_labels[kind]} already built",
                              job_id=job_id)
                continue
            for attempt in range(3):
                try:
                    _motion_stage(
                        slug, (kind,), idle_pose, walk_style, move_style,
                        writer,
                        band(base, span, f"One-click 3/3 {kind_labels[kind]}: "))
                    motion_failures.pop(kind, None)
                    break
                except Exception as take_error:
                    motion_failures[kind] = str(take_error)
                    if attempt < 2:
                        pause = 25 * (attempt + 1)
                        writer(f"{kind} take failed ({take_error}); "
                               f"retrying in {pause}s ({attempt + 1}/2)")
                        _job_progress(
                            slug, kind, base,
                            f"One-click 3/3 {kind_labels[kind]}: retrying "
                            f"in {pause}s", job_id=job_id)
                        time.sleep(pause)
        if len(motion_failures) == 3:
            raise RuntimeError(
                "all three motion takes failed - last error: "
                + motion_failures["move"])
        if motion_failures:
            failed = ", ".join(kind_labels[k] for k in motion_failures)
            done_label = (f"Ready with gaps - {failed} failed; regenerate "
                          f"from the Full Body Studio")
        else:
            done_label = "Everything ready - face, body, walk, idle, and moves"
        _job_progress(slug, "done", 1.0, done_label, job_id=job_id)
        writer("one-click pipeline complete"
               + (f" ({len(motion_failures)} take(s) failed)"
                  if motion_failures else ""))
    except Exception as error:
        failure = str(error)
        writer(f"FAILED: {failure}")
    finally:
        _finish_job(slug, job_id, failure)


@app.get("/api/avatars")
async def api_avatars():
    r = reg()
    out = []
    for a in r.list_avatars():
        s = a.get("slug")
        a["has_runtime"] = os.path.exists(os.path.join(runtime_dir(s), "manifest.json"))
        # Her own character, if she has been given one. The card edits it.
        a["persona"] = ((reg().read_manifest(s) or {}).get("persona")
                        or {}).get("system", "")
        with _jlock:
            j = _jobs.get(s)
        a["job"] = {
            "phase": j["phase"], "done": j["done"],
            "error": j["error"], "kind": j.get("kind", "build"),
            "progress": j.get("progress")
        } if j else None
        out.append(a)
    return {
        "avatars": out,
        "active": r.get_active(),
        "companion": r.get_companion(),
    }


@app.post("/api/avatar/upload")
async def api_upload(photo: UploadFile = File(...), name: str = Form("", max_length=120)):
    ext = os.path.splitext(photo.filename or "")[1].lower() or ".png"
    if ext not in (".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"):
        raise HTTPException(400, f"unsupported image type {ext}")
    raw = await photo.read(MAX_UPLOAD_BYTES + 1)
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "portrait exceeds the 20 MB upload limit")
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as handle:
        handle.write(raw)
        tmp = handle.name
    try:
        m = reg().create_avatar(tmp, name or os.path.splitext(photo.filename or "Avatar")[0])
    except Exception as e:
        raise HTTPException(400, str(e))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return m


class RenameRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    name: str = Field(min_length=1, max_length=120)


class PersonaRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    system: str = Field(default="", max_length=4000)


@app.post("/api/avatar/persona")
def api_avatar_persona(r: PersonaRequest):
    """Give one avatar a character of its own. Empty means "use the
    house persona", which is what every avatar did before this existed."""
    m = reg().read_manifest(r.slug)
    if not m:
        raise HTTPException(404, "unknown avatar")
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]+", " ", r.system).strip()
    if text:
        m["persona"] = {"system": text}
    else:
        m.pop("persona", None)
    reg().write_manifest(r.slug, m)
    return {"slug": r.slug, "system": text}


@app.post("/api/avatar/rename")
def api_avatar_rename(r: RenameRequest):
    name = re.sub(r"[\x00-\x1f\x7f]+", " ", r.name).strip()[:120]
    if not name:
        raise HTTPException(400, "name is empty")
    m = reg().read_manifest(r.slug)
    if not m:
        raise HTTPException(404, "unknown avatar")
    m["name"] = name
    return reg().write_manifest(r.slug, m)


class Slug(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    shapes: list[str] | None = None
    # What the owner asked to keep from the source portrait. Optional
    # everywhere; only the build paths read it.
    notes: str = Field(default="", max_length=600)
    # Preserve source-worn headwear by default. This opt-in switch is shared
    # by photo and stylized lanes but does not merge their render pipelines.
    remove_headwear: bool | None = None


def _rig_control_field(name):
    spec = rig.CONTROLS[name]
    return Field(default=spec["default"], ge=spec["minimum"], le=spec["maximum"])


def _dental_donor_field(row):
    return Field(default="auto",
                 pattern="^(auto|" + "|".join(rig.DENTAL_DONORS[row]) + ")$")


class RigProfileInput(BaseModel):
    lips: float = _rig_control_field("lips")
    jaw: float = _rig_control_field("jaw")
    cheeks: float = _rig_control_field("cheeks")
    eyebags: float = _rig_control_field("eyebags")
    brows: float = _rig_control_field("brows")
    forehead: float = _rig_control_field("forehead")
    nasolabial: float = _rig_control_field("nasolabial")
    nose: float = _rig_control_field("nose")
    teeth: float = _rig_control_field("teeth")
    upper_teeth_donor: str = _dental_donor_field("upper")
    lower_teeth_donor: str = _dental_donor_field("lower")
    teeth_lock: bool = True
    upper_teeth_lock: bool = True
    lower_teeth_lock: bool = True
    preset: str = Field(default="custom", pattern=r"^(natural|subtle|expressive|custom)$")


class RigRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    profile: RigProfileInput


class BodyProfileInput(BaseModel):
    style: str = Field(default="photorealistic", pattern=r"^(photorealistic|editorial|illustrated|anime|soft-3d)$")
    pose: str = Field(default="relaxed", pattern=r"^(relaxed|confident|friendly|formal|casual)$")
    prompt: str = Field(default="", max_length=4000)
    outfit: str = Field(default="", max_length=500)
    notes: str = Field(default="", max_length=600)
    remove_headwear: bool = False
    # Visible styling inferred from the uploaded reference. This is not a
    # gender-identity field; it exists so the final plate includes one footwear
    # branch instead of mentioning feminine and masculine directions together.
    presentation: str = Field(
        default="androgynous",
        pattern=r"^(feminine|masculine|androgynous)$",
    )
    medium: str = Field(
        default="photograph",
        pattern=r"^(photograph|game art|anime|illustration|3d render)$",
    )


class BodyRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    profile: BodyProfileInput


class BodyEditRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    instruction: str = Field(min_length=4, max_length=600)


class BodyPromptRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    refresh: bool = False


class MotionRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(default="both", pattern=r"^(walk|idle|move|both)$")
    walk_style: str = Field(default="office", max_length=40)
    walk_prompt: str = Field(default="", max_length=2400)
    pose: str = Field(default="back-heel", max_length=40)
    pose_prompt: str = Field(default="", max_length=2400)
    move_style: str = Field(default="viral", max_length=40)
    move_prompt: str = Field(default="", max_length=2400)


class MotionRemoveRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(default="both", pattern=r"^(walk|idle|move|both)$")


SET_ID_PATTERN = r"^[a-z0-9][a-z0-9-]{0,80}$"


class MotionSetRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(pattern=r"^(walk|idle|move)$")
    set_id: str = Field(pattern=SET_ID_PATTERN)


class BodySetRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    set_id: str = Field(pattern=SET_ID_PATTERN)


def _motion_asset_catalog(slug, directory, motion_metadata):
    motion_root = os.path.join(directory, "motion")
    catalog = {"walk": [], "idle": [], "move": [], "shared": []}
    seen = set()

    def add(kind, relative, role, stage, label, order, extra=None):
        relative = str(relative or "").replace("\\", "/").lstrip("/")
        if not relative or relative in seen:
            return
        full = _safe_file(motion_root, relative)
        if not full:
            return
        extension = os.path.splitext(relative)[1].lower()
        media_type = (
            "video" if extension in {".mp4", ".mov", ".webm", ".m4v"} else
            "image" if extension in {".png", ".jpg", ".jpeg", ".webp"} else
            "json" if extension == ".json" else "file"
        )
        stat = os.stat(full)
        record = {
            "kind": kind,
            "role": role,
            "stage": stage,
            "label": label,
            "order": order,
            "name": os.path.basename(relative),
            "relative_path": relative,
            "media_type": media_type,
            "size": stat.st_size,
            "modified": int(stat.st_mtime),
        }
        if extra:
            record.update({key: value for key, value in extra.items()
                           if value is not None})
        catalog[kind].append(record)
        seen.add(relative)

    for kind in ("walk", "idle", "move"):
        clip = motion_metadata.get(kind) or {}
        if not clip:
            continue
        title = "Horizon Walk" if kind == "walk" else "Edge Idle"
        add(
            kind, f"raw/{kind}-keyframe.png", "keyframe", "01 · Keyframe",
            f"{title} generated keyframe", 10)
        add(
            kind, f"raw/{kind}-source.mp4", "raw-video", "02 · Raw I2V",
            "Raw xAI image-to-video", 20)
        for sheet_index, sheet in enumerate(clip.get("sheets") or []):
            name = os.path.basename(str(sheet.get("image") or ""))
            add(
                kind, name, "alpha-frames", "03 · Alpha frames",
                f"Transparent frame atlas {sheet_index + 1}", 30 + sheet_index,
                {
                    "frame_first": sheet.get("first", sheet.get("start", 0)),
                    "frame_count": sheet.get("count", sheet.get("frames")),
                    "columns": sheet.get("columns"),
                    "rows": sheet.get("rows"),
                    "frame_width": clip.get("frame_width"),
                    "frame_height": clip.get("frame_height"),
                    "fps": clip.get("fps"),
                })
        add(
            kind, os.path.basename(str(clip.get("poster") or f"{kind}-poster.png")),
            "poster", "04 · Loop poster", "Transparent loop poster", 70)
        add(
            kind,
            os.path.basename(str(clip.get("alpha_video") or f"{kind}-alpha.mov")),
            "alpha-video", "05 · Alpha video",
            "Final transparent animation", 80,
            {"frame_count": clip.get("frames"), "fps": clip.get("fps")})
        catalog[kind].sort(key=lambda asset: (asset["order"], asset["name"]))

    add(
        "shared", "motion.json", "receipt", "06 · Production receipt",
        "Motion metadata and quality receipt", 90)
    return catalog


@app.get("/api/avatar/rig")
async def api_rig(slug: str = Query(pattern=SLUG_PATTERN)):
    registry = reg()
    manifest = registry.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    manifest = registry.repair_source_medium_from_source(
        slug, manifest=manifest)
    if manifest.get("status") != "ready":
        raise HTTPException(400, "build this avatar before calibrating it")
    from studio import body, compose, face, rig
    import cv2
    directory = registry.adir(slug)
    keyframe = cv2.imread(os.path.join(directory, "keyframe.png"))
    if keyframe is None:
        raise HTTPException(400, "avatar keyframe is missing")
    # Facial calibration is a read-only view of the same authored keyframe
    # used by the build/runtime pipeline.  Explicitly classified artwork may
    # need the bounded, topology-gated crop detector even after a successful
    # build (large cartoon eyes and headwear sit outside MediaPipe's human
    # full-frame prior).  Route from the original stored intake evidence, not
    # from a UI/body style hint.  Missing, malformed, unknown and photographic
    # reports therefore remain on the strict detector.
    allow_stylized = body._allow_stylized_source(directory)
    if allow_stylized:
        landmarks, _, _metadata = face.detect_for_intake(keyframe)
    else:
        landmarks, _ = face.detect(keyframe)
    if landmarks is None:
        raise HTTPException(400, "no face detected in avatar keyframe")
    profile = rig.from_manifest(manifest)
    masks, face_mask = compose._masks(keyframe, landmarks, profile)
    alpha, _ = compose._alpha_ring(
        masks["mouth"], face_mask,
        max(keyframe.shape[:2]) / 1024.0, profile)
    payload = rig.inspector_payload(landmarks, keyframe.shape)
    payload["weights"] = rig.sampled_weights(alpha, landmarks)
    payload["profile"] = profile
    payload["schema"] = rig.public_schema()
    gaps = registry.raw_render_gaps(slug)
    payload["raw_gaps"] = gaps
    payload["can_recompose"] = not gaps
    payload["uses_generation"] = False
    # A first build can finish with a locally repairable articulation gate.
    # Hand its structured slider plan to the same calibration room used by a
    # rejected rebuild; never make the owner decode a build log.
    payload["repair"] = manifest.get("rig_repair")
    payload["preview_visemes"] = [
        name for name in ("closed", "ah", "eh", "oo")
        if os.path.isfile(os.path.join(
            directory, "visemes", f"v_{name}.jpg"))
    ]
    # One enamel scan per row serves both the donor dropdown (every
    # candidate frame with its detected pixel count) and the election the
    # overlay draws - honoring the profile's saved donor overrides.
    viseme_dir = os.path.join(directory, "visemes")
    dental = dict(donor=None, donors={}, rows={}, contours=[],
                  candidates={}, overrides={})
    for row in compose.DENTAL_ROWS:
        candidates = compose._scan_tooth_donors(
            viseme_dir, row, allow_stylized=allow_stylized)
        dental["candidates"][row] = [
            dict(name=name, pixels=pixels)
            for name, _, _, _, pixels in candidates]
        choice = profile.get(f"{row}_teeth_donor", "auto")
        dental["overrides"][row] = choice
        selected = compose._elect_tooth_donor(candidates, row, choice)
        if selected is None:
            continue
        donor_name, _, _, master = selected
        height, width = master.shape
        contours, _ = cv2.findContours(
            master, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        normalized = [[
            [round(float(point[0][0] / width), 6),
             round(float(point[0][1] / height), 6)]
            for point in contour]
            for contour in contours if len(contour) >= 3]
        dental["donors"][row] = donor_name
        dental["rows"][row] = dict(donor=donor_name, contours=normalized)
        dental["contours"].extend(normalized)
    dental["donor"] = dental["donors"].get("upper")
    payload["dental"] = dental
    return payload


@app.post("/api/avatar/recompose")
async def api_recompose(request: RigRequest):
    registry = reg()
    manifest = registry.read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    if manifest.get("status") != "ready":
        raise HTTPException(400, "avatar is not ready for calibration")
    profile_data = (request.profile.model_dump()
                    if hasattr(request.profile, "model_dump")
                    else request.profile.dict())
    from studio import rig
    try:
        profile = rig.normalize(profile_data)
    except ValueError as error:
        raise HTTPException(422, str(error))
    gaps = registry.raw_render_gaps(request.slug)
    if gaps:
        raise HTTPException(
            400, "retained expression renders are incomplete: " +
            ", ".join(gaps))
    with _jlock:
        job = _jobs.get(request.slug)
        if job and not job["done"]:
            return {"started": False, "reason": "already building"}
        _jobs[request.slug] = dict(
            phase="Queued", done=False, error="", log=[], kind="calibration",
            progress={"stage": "queued", "value": 0.0,
                      "label": "Queued"})
    threading.Thread(
        target=_recompose_thread,
        args=(request.slug, profile), daemon=True).start()
    return {"started": True, "slug": request.slug,
            "kind": "calibration", "uses_generation": False}


@app.post("/api/avatar/build")
async def api_build(b: Slug):
    if b.shapes:
        unknown = sorted(set(b.shapes) - set(reg().visemes.ORDER))
        if unknown:
            raise HTTPException(422, f"unknown viseme shapes: {', '.join(unknown)}")
    with _jlock:
        j = _jobs.get(b.slug)
        if j and not j["done"]:
            return {"started": False, "reason": "already building"}
    threading.Thread(target=_build_thread,
                     args=(b.slug, b.shapes, b.notes, b.remove_headwear),
                     daemon=True).start()
    return {"started": True, "slug": b.slug}


@app.get("/api/avatar/body")
async def api_body(slug: str = Query(pattern=SLUG_PATTERN)):
    _recover_body_edit_transaction_if_idle(slug)
    manifest = reg().read_manifest(slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    from studio import body
    try:
        provider = body.default_provider()
        provider_error = None
    except Exception as error:
        provider = None
        provider_error = str(error)
    try:
        video_provider = body.default_video_provider()
        video_provider_error = None
    except Exception as error:
        video_provider = None
        video_provider_error = str(error)
    directory = reg().adir(slug)
    body_metadata = body.public_body_metadata(manifest.get("body") or {})
    motion_metadata = manifest.get("motion") or {}
    body_views = body_metadata.get("views") or {}
    has_turnaround = all(
        isinstance(body_views.get(view), dict) and
        os.path.isfile(os.path.join(
            directory, "body",
            os.path.basename(str(body_views[view].get("image") or ""))))
        for view in ("front", "side", "back")
    )
    def has_motion_clip(kind):
        clip = motion_metadata.get(kind) or {}
        sheets = clip.get("sheets") or []
        return bool(sheets) and all(
            os.path.isfile(os.path.join(
                directory, "motion", os.path.basename(str(sheet.get("image") or ""))))
            for sheet in sheets
        )

    has_walk = has_motion_clip("walk")
    has_idle = has_motion_clip("idle")
    has_move = has_motion_clip("move")
    body_edit_sources_ready = False
    body_edit_source_error = ""
    try:
        authored_body = body._body_metadata(directory)
        for view in body.BODY_VIEWS:
            body._body_source(directory, authored_body, view)
        body_edit_sources_ready = True
    except (RuntimeError, ValueError, OSError) as error:
        body_edit_source_error = str(error)
    body_edit_available = bool(
        has_turnaround and body_edit_sources_ready and provider
        and body.supports_xai_edit(provider))
    if not has_turnaround:
        body_edit_reason = "Generate Front, Side, and Back before editing."
    elif not body_edit_sources_ready:
        body_edit_reason = (
            body_edit_source_error
            or "The retained Front, Side, and Back source plates are missing.")
    elif provider_error:
        body_edit_reason = provider_error
    elif not body.supports_xai_edit(provider):
        body_edit_reason = (
            "Choose xAI Grok Imagine Image 2.0 under AI & Voice → Image "
            "to edit an existing full-body set.")
    else:
        body_edit_reason = ""
    from studio import library
    with _jlock:
        current_job = dict(_jobs.get(slug) or {})
    if not current_job or current_job.get("done"):
        try:
            # Adopt pre-library avatars only while canonical state is stable.
            # During a live edit the body has a deliberate pre-commit window;
            # archiving it here would expose a set whose runtime later failed.
            library.sync_canonical(directory)
        except Exception as sync_error:
            print(f"[avatar:{slug}] library sync failed: {sync_error}", flush=True)
    job = current_job if current_job and (
        str(current_job.get("kind") or "").startswith("body") or
        str(current_job.get("kind") or "").startswith("motion")) else None
    from studio import wardrobe
    cached_prompt = wardrobe.cached_prompt(directory)
    return {
        "body": body_metadata or None,
        "motion": manifest.get("motion"),
        "motion_assets": _motion_asset_catalog(
            slug, directory, motion_metadata),
        "motion_sets": {
            kind: library.list_motion_sets(directory, kind)
            for kind in ("walk", "idle", "move")
        },
        "body_sets": library.list_body_sets(directory),
        "has_body": os.path.isfile(os.path.join(directory, "body", "body.json")),
        "has_turnaround": has_turnaround,
        "has_motion": has_walk or has_idle or has_move,
        "has_walk": has_walk,
        "has_idle": has_idle,
        "has_move": has_move,
        "provider": provider,
        "provider_error": provider_error,
        "body_edit_available": body_edit_available,
        "body_edit_sources_ready": body_edit_sources_ready,
        "body_edit_reason": body_edit_reason,
        "video_provider": video_provider,
        "video_provider_error": video_provider_error,
        "default_prompt": (cached_prompt or {}).get(
            "prompt") or wardrobe.preset_prompt(),
        "prompt_source": (cached_prompt or {}).get("source") or "preset",
        "prompt_traits": (cached_prompt or {}).get("traits") or {},
        "job": job,
    }


@app.post("/api/avatar/body/prompt")
async def api_body_prompt(request: BodyPromptRequest):
    """Compose art direction from the uploaded portrait itself.

    Kept off the status route because it calls a vision model: the modal opens
    on the cached or preset text immediately and upgrades in place.
    """
    if not reg().read_manifest(request.slug):
        raise HTTPException(404, "avatar not found")
    from studio import wardrobe
    directory = reg().adir(request.slug)
    result = await asyncio.to_thread(
        wardrobe.tailored_prompt, directory, request.refresh)
    return {
        "prompt": result.get("prompt") or wardrobe.preset_prompt(),
        "source": result.get("source") or "preset",
        "traits": result.get("traits") or {},
        "error": result.get("error") or "",
    }


BODY_PROMPT_PROGRESS_STAGES = frozenset({
    "portrait", "cache", "planning", "analysis", "validation",
    "composition", "saving", "fallback", "complete",
})


@app.post("/api/avatar/body/prompt/stream")
async def api_body_prompt_stream(request: BodyPromptRequest):
    """Stream closed, non-sensitive stages while portrait art is composed."""
    if not reg().read_manifest(request.slug):
        raise HTTPException(404, "avatar not found")
    from studio import wardrobe
    directory = reg().adir(request.slug)

    async def events():
        queue = asyncio.Queue()
        loop = asyncio.get_running_loop()

        def progress(stage):
            if stage in BODY_PROMPT_PROGRESS_STAGES:
                loop.call_soon_threadsafe(queue.put_nowait, ("progress", stage))

        async def compose():
            try:
                result = await asyncio.to_thread(
                    wardrobe.tailored_prompt, directory,
                    refresh=request.refresh, progress=progress)
                await queue.put(("result", result))
            except Exception:
                await queue.put(("error", None))

        task = asyncio.create_task(compose())
        try:
            while True:
                kind, value = await queue.get()
                if kind == "progress":
                    payload = {"type": "progress", "stage": value}
                elif kind == "result":
                    result = value or {}
                    payload = {
                        "type": "result",
                        "prompt": result.get("prompt") or wardrobe.preset_prompt(),
                        "source": result.get("source") or "preset",
                        "traits": result.get("traits") or {},
                        "error": result.get("error") or "",
                    }
                else:
                    payload = {
                        "type": "error",
                        "message": "Could not finish the portrait art direction.",
                    }
                yield json.dumps(
                    payload, separators=(",", ":"), ensure_ascii=False
                ) + "\n"
                if kind in {"result", "error"}:
                    break
        finally:
            if not task.done():
                task.cancel()

    return StreamingResponse(
        events(), media_type="application/x-ndjson",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


class PromptExpandRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(pattern=r"^(body|walk|idle|move)$")
    gist: str = Field(min_length=4, max_length=600)
    # The prompt already in the field. Given one, the expander REVISES it
    # rather than starting over.
    base: str = Field(default="", max_length=4000)


@app.post("/api/avatar/prompt/expand")
async def api_prompt_expand(request: PromptExpandRequest):
    """Expand a rough gist into a field-ready prompt via the selected LLM.

    Serves the AI-draft buttons on the full-body prompt and the custom walk
    and Edge Idle prompt fields; the portrait rides along so the direction
    suits the actual subject.
    """
    if not reg().read_manifest(request.slug):
        raise HTTPException(404, "avatar not found")
    from studio import promptsmith
    directory = reg().adir(request.slug)
    try:
        prompt = await asyncio.to_thread(
            promptsmith.expand, request.kind, request.gist, directory,
            request.base)
    except Exception as error:
        raise HTTPException(400, str(error))
    return {"prompt": prompt, "kind": request.kind}


@app.get("/api/media/defaults")
async def api_media_defaults():
    from studio import body

    result = {}
    for kind, resolver in (
        ("image", body.default_provider),
        ("video", body.default_video_provider),
    ):
        try:
            result[kind] = {"available": True, "provider": resolver(), "error": ""}
        except Exception as error:
            result[kind] = {"available": False, "provider": None, "error": str(error)}
    return result


@app.post("/api/avatar/body/generate")
async def api_body_generate(request: BodyRequest):
    _recover_body_edit_transaction_if_idle(request.slug)
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    if manifest.get("status") != "ready":
        raise HTTPException(400, "build this avatar before generating a body")
    job_id = _reserve_job(request.slug, "body")
    if not job_id:
        return _already_running(request.slug)
    profile = (request.profile.model_dump()
               if hasattr(request.profile, "model_dump")
               else request.profile.dict())
    try:
        threading.Thread(
            target=_body_thread,
            args=(request.slug, profile), daemon=True).start()
    except Exception as error:
        _finish_job(request.slug, job_id, error)
        raise
    return {
        "started": True, "slug": request.slug, "kind": "body",
        "job_id": job_id}


@app.post("/api/avatar/body/edit")
async def api_body_edit(request: BodyEditRequest):
    _recover_body_edit_transaction_if_idle(request.slug)
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    if manifest.get("status") != "ready":
        raise HTTPException(400, "build this avatar before editing its body")
    with _jlock:
        current_job = _jobs.get(request.slug) or {}
        already_running = bool(current_job and not current_job.get("done"))
    if already_running:
        return _already_running(request.slug)
    from studio import body
    try:
        provider = body.default_provider()
    except Exception as error:
        raise HTTPException(409, str(error)) from error
    if not body.supports_xai_edit(provider):
        raise HTTPException(
            409,
            "Choose xAI Grok Imagine Image 2.0 under AI & Voice → Image "
            "before editing a full-body set.")
    try:
        metadata = body._body_metadata(reg().adir(request.slug))
        for view in body.BODY_VIEWS:
            body._body_source(reg().adir(request.slug), metadata, view)
        instruction = body._edit_instruction(request.instruction)
    except (RuntimeError, ValueError) as error:
        raise HTTPException(422, str(error)) from error
    job_id = _reserve_job(
        request.slug, "body-edit", "Preparing xAI full-body edit")
    if not job_id:
        return _already_running(request.slug)
    try:
        threading.Thread(
            target=_body_edit_thread,
            args=(request.slug, instruction, job_id), daemon=True).start()
    except Exception as error:
        _finish_job(request.slug, job_id, error)
        raise
    return {
        "started": True, "slug": request.slug, "kind": "body-edit",
        "job_id": job_id}


def _recut_thread(slug, kind, job_id):
    writer = jlog(slug, f"re-cutting the retained {kind} take")
    previous_manifest = reg().read_manifest(slug) or {}
    motion_replaced = False
    runtime_published = False
    failure = ""
    try:
        from studio import motion, library
        metadata = motion.recut(
            reg().adir(slug), kind, log=writer,
            progress=lambda stage, value, label: _job_progress(
                slug, stage, value, label, job_id=job_id))
        motion_replaced = True
        manifest = dict(previous_manifest)
        manifest["motion"] = metadata
        reg().write_manifest(slug, manifest)
        _job_progress(
            slug, "runtime", .94, "Publishing alpha motion", job_id=job_id)
        _publish_runtime_atomic(slug, log=writer)
        runtime_published = True
        motion.commit_pending_build(reg().adir(slug))
        try:
            library.archive_motion(reg().adir(slug), kind)
        except Exception as archive_error:
            writer(f"could not archive the re-cut set: {archive_error}")
        _job_progress(slug, "done", 1.0, f"{kind} re-cut ready", job_id=job_id)
        writer(f"{kind} re-cut is live")
    except Exception as error:
        failure = str(error)
        if motion_replaced and not runtime_published:
            try:
                from studio import motion
                motion.rollback_pending_build(reg().adir(slug))
                reg().write_manifest(slug, previous_manifest)
            except Exception as rollback_error:
                failure = f"{failure}; rollback: {rollback_error}"
        writer(f"FAILED: {failure}")
    finally:
        _finish_job(slug, job_id, failure)


def _repair_thread(slug, kind, frame, mode, note, job_id, frame_end=None):
    writer = jlog(slug, f"repairing {kind} frame {frame}")
    previous_manifest = reg().read_manifest(slug) or {}
    motion_replaced = False
    runtime_published = False
    failure = ""
    try:
        from studio import motion, library
        metadata = motion.repair_frame(
            reg().adir(slug), kind, frame, mode=mode, note=note, log=writer,
            frame_end=frame_end,
            progress=lambda stage, value, label: _job_progress(
                slug, stage, value, label, job_id=job_id))
        motion_replaced = True
        manifest = dict(previous_manifest)
        manifest["motion"] = metadata
        reg().write_manifest(slug, manifest)
        _job_progress(
            slug, "runtime", .94, "Publishing alpha motion", job_id=job_id)
        _publish_runtime_atomic(slug, log=writer)
        runtime_published = True
        motion.commit_pending_build(reg().adir(slug))
        try:
            library.archive_motion(reg().adir(slug), kind)
        except Exception as archive_error:
            writer(f"could not archive the repaired set: {archive_error}")
        _job_progress(
            slug, "done", 1.0, f"{kind} frame {frame} repaired", job_id=job_id)
    except Exception as error:
        failure = str(error)
        if motion_replaced and not runtime_published:
            try:
                from studio import motion
                motion.rollback_pending_build(reg().adir(slug))
                reg().write_manifest(slug, previous_manifest)
            except Exception as rollback_error:
                failure = f"{failure}; rollback: {rollback_error}"
        writer(f"FAILED: {failure}")
    finally:
        _finish_job(slug, job_id, failure)


class MotionRepairRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(pattern=r"^(walk|idle|move)$")
    frame: int = Field(ge=0, le=4096)
    frame_end: int | None = Field(default=None, ge=0, le=4096)
    mode: str = Field(default="patch", pattern=r"^(patch|drop)$")
    note: str = Field(default="", max_length=200)


class PipelineRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    # What the owner wants kept from the source portrait - a bandana, an
    # earring, a scar. Rides with the house prompt, never replaces it.
    notes: str = Field(default="", max_length=600)
    remove_headwear: bool | None = None


@app.post("/api/avatar/pipeline")
async def api_pipeline(request: PipelineRequest):
    """One click, everything: build the face if needed, then the full body,
    then walk + edge idle + moves - one sequential background job."""
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    job_id = _reserve_job(request.slug, "pipeline",
                          "One-click: face, body, walk, idle, moves")
    if not job_id:
        return _already_running(request.slug)
    try:
        threading.Thread(
            target=_pipeline_thread,
            args=(request.slug, job_id, request.notes,
                  request.remove_headwear), daemon=True).start()
    except BaseException as error:
        _finish_job(request.slug, job_id, getattr(error, "detail", error))
        raise
    return {"started": True, "slug": request.slug, "kind": "pipeline",
            "job_id": job_id}


@app.post("/api/avatar/motion/repair")
async def api_motion_repair(request: MotionRepairRequest):
    """Fix ONE flagged frame: patch it from its loop neighbours, or drop
    it. Works on the packed lossless frames - no generation, no re-matte."""
    if not reg().read_manifest(request.slug):
        raise HTTPException(404, "avatar not found")
    job_id = _reserve_job(
        request.slug, "motion",
        f"Repairing {request.kind} frame {request.frame}")
    if not job_id:
        return _already_running(request.slug)
    try:
        threading.Thread(
            target=_repair_thread,
            args=(request.slug, request.kind, request.frame, request.mode,
                  request.note, job_id, request.frame_end),
            daemon=True).start()
    except BaseException as error:
        _finish_job(request.slug, job_id, getattr(error, "detail", error))
        raise
    return {"started": True, "slug": request.slug, "kind": request.kind,
            "frame": request.frame, "frame_end": request.frame_end,
            "mode": request.mode, "job_id": job_id}


class MotionRecutRequest(BaseModel):
    slug: str = Field(pattern=SLUG_PATTERN)
    kind: str = Field(pattern=r"^(walk|idle|move)$")


@app.post("/api/avatar/motion/recut")
async def api_motion_recut(request: MotionRecutRequest):
    """Reprocess the retained raw take through the current local pipeline -
    no generation spend; how existing sets pick up matte upgrades."""
    slug = request.slug
    if not reg().read_manifest(slug):
        raise HTTPException(404, "avatar not found")
    raw = os.path.join(
        reg().adir(slug), "motion", "raw", f"{request.kind}-source.mp4")
    if not os.path.isfile(raw):
        raise HTTPException(400, "no retained raw take for this clip; generate first")
    job_id = _reserve_job(
        slug, "motion", f"Re-cutting {request.kind} from the retained take")
    if not job_id:
        return _already_running(slug)
    try:
        threading.Thread(
            target=_recut_thread, args=(slug, request.kind, job_id),
            daemon=True).start()
    except BaseException as error:
        _finish_job(slug, job_id, getattr(error, "detail", error))
        raise
    return {"started": True, "slug": slug, "kind": request.kind,
            "job_id": job_id}


@app.post("/api/avatar/motion/generate")
async def api_motion_generate(request: MotionRequest):
    slug = request.slug
    manifest = reg().read_manifest(slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    directory = reg().adir(slug)
    if not os.path.isfile(os.path.join(directory, "body", "body.json")):
        raise HTTPException(400, "generate a full body before creating motion")
    from studio import motion
    body_presentation = motion.body_presentation(directory)
    kinds = (
        ("walk", "idle") if request.kind == "both" else (request.kind,)
    )
    try:
        walk_style = (
            motion.resolve_walk_style(request.walk_style, request.walk_prompt)
            if "walk" in kinds else None
        )
        idle_pose = (
            motion.resolve_idle_pose(
                request.pose, request.pose_prompt,
                presentation=body_presentation, remap_unsafe=True)
            if "idle" in kinds else None
        )
        move_style = (
            motion.resolve_move_style(request.move_style, request.move_prompt)
            if "move" in kinds else None
        )
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    kind_labels = {"walk": "Horizon Walk", "idle": "Edge Idle",
                   "move": "Show Me Some Moves"}
    label = "Validating " + " and ".join(kind_labels[k] for k in kinds)
    job_id = _reserve_job(slug, "motion", label)
    if not job_id:
        return _already_running(slug)
    try:
        threading.Thread(
            target=_motion_thread,
            args=(slug, None, job_id, idle_pose, kinds, walk_style, move_style),
            daemon=True).start()
    except BaseException as error:
        _finish_job(slug, job_id, getattr(error, "detail", error))
        raise
    return {
        "started": True, "slug": slug, "kind": request.kind,
        "job_id": job_id,
        "pose": idle_pose["id"] if idle_pose else None,
        "pose_remapped": bool(
            idle_pose and request.pose and request.pose != idle_pose["id"]),
        "body_presentation": body_presentation,
        "walk_style": walk_style["id"] if walk_style else None,
        "move_style": move_style["id"] if move_style else None,
    }


@app.post("/api/avatar/motion/remove")
async def api_motion_remove(request: MotionRemoveRequest):
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    kind = getattr(request, "kind", "both")
    label = (
        "Removing Horizon Walk" if kind == "walk" else
        "Removing Edge Idle" if kind == "idle" else
        "Removing desktop motion"
    )
    job_id = _reserve_job(request.slug, "motion-remove", label)
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import library, motion
        metadata = motion.remove(reg().adir(request.slug), kind)
        for slot in ("walk", "idle") if kind == "both" else (kind,):
            library.clear_active(reg().adir(request.slug), slot)
        if metadata:
            manifest["motion"] = metadata
        else:
            manifest.pop("motion", None)
        reg().write_manifest(request.slug, manifest)
        _publish_runtime_atomic(
            request.slug, log=jlog(request.slug, label.lower()))
        return {"removed": True, "slug": request.slug, "kind": kind}
    except Exception as error:
        failure = str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


def _apply_motion_metadata(manifest, metadata):
    if metadata:
        manifest["motion"] = metadata
    else:
        manifest.pop("motion", None)


@app.post("/api/avatar/motion/set/activate")
async def api_motion_set_activate(request: MotionSetRequest):
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    title = "Horizon Walk" if request.kind == "walk" else "Edge Idle"
    job_id = _reserve_job(
        request.slug, "motion-set", f"Switching {title} set")
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import library, motion
        directory = reg().adir(request.slug)
        sets = {record["id"]: record
                for record in library.list_motion_sets(directory, request.kind)}
        record = sets.get(request.set_id)
        if not record:
            raise HTTPException(404, f"unknown {request.kind} set")
        if not record["compatible"]:
            raise HTTPException(
                409, f"this {title} set was generated for a different body set")
        if request.kind == "idle" and not motion.idle_pose_allowed(
                record.get("pose"), motion.body_presentation(directory)):
            raise HTTPException(
                422,
                "this heel-specific Edge Idle set is available only for a "
                "feminine-presenting body; generate Side lean for the active body")
        metadata = library.activate_motion(
            directory, request.kind, request.set_id)
        _apply_motion_metadata(manifest, metadata)
        reg().write_manifest(request.slug, manifest)
        _publish_runtime_atomic(
            request.slug, log=jlog(request.slug, f"switching {title.lower()}"))
        return {"activated": True, "slug": request.slug,
                "kind": request.kind, "set_id": request.set_id}
    except Exception as error:
        failure = getattr(error, "detail", None) or str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


@app.post("/api/avatar/motion/set/remove")
async def api_motion_set_remove(request: MotionSetRequest):
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    title = "Horizon Walk" if request.kind == "walk" else "Edge Idle"
    job_id = _reserve_job(
        request.slug, "motion-set", f"Deleting a {title} set")
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import library
        directory = reg().adir(request.slug)
        try:
            was_active = library.remove_motion_set(
                directory, request.kind, request.set_id)
        except ValueError as error:
            raise HTTPException(404, str(error))
        if was_active:
            metadata = library.strip_canonical_motion(directory, request.kind)
            fallback = library.newest_compatible_motion_set(
                directory, request.kind)
            if fallback:
                metadata = library.activate_motion(
                    directory, request.kind, fallback)
            _apply_motion_metadata(manifest, metadata)
            reg().write_manifest(request.slug, manifest)
            _publish_runtime_atomic(
                request.slug,
                log=jlog(request.slug, f"deleting a {title.lower()} set"))
        return {"removed": True, "slug": request.slug, "kind": request.kind,
                "set_id": request.set_id, "was_active": was_active}
    except Exception as error:
        failure = getattr(error, "detail", None) or str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


@app.post("/api/avatar/body/set/activate")
async def api_body_set_activate(request: BodySetRequest):
    _recover_body_edit_transaction_if_idle(request.slug)
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    job_id = _reserve_job(request.slug, "body-set", "Switching body set")
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import library
        directory = reg().adir(request.slug)
        try:
            manifest["body"] = library.activate_body(directory, request.set_id)
        except ValueError as error:
            raise HTTPException(404, str(error))
        _apply_motion_metadata(
            manifest, library.reconcile_motion_with_body(directory))
        reg().write_manifest(request.slug, manifest)
        _publish_runtime_atomic(
            request.slug, log=jlog(request.slug, "switching body set"))
        return {"activated": True, "slug": request.slug,
                "set_id": request.set_id}
    except Exception as error:
        failure = getattr(error, "detail", None) or str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


@app.post("/api/avatar/body/set/remove")
async def api_body_set_remove(request: BodySetRequest):
    _recover_body_edit_transaction_if_idle(request.slug)
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    job_id = _reserve_job(request.slug, "body-set", "Deleting a body set")
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import body, library, motion
        directory = reg().adir(request.slug)
        try:
            was_active = library.remove_body_set(directory, request.set_id)
        except ValueError as error:
            raise HTTPException(404, str(error))
        if was_active:
            fallback = library.newest_body_set(directory)
            if fallback:
                manifest["body"] = library.activate_body(directory, fallback)
                _apply_motion_metadata(
                    manifest, library.reconcile_motion_with_body(directory))
            else:
                body.remove(directory)
                motion.remove(directory)
                for slot in ("walk", "idle"):
                    library.clear_active(directory, slot)
                manifest.pop("body", None)
                manifest.pop("motion", None)
            reg().write_manifest(request.slug, manifest)
            _publish_runtime_atomic(
                request.slug, log=jlog(request.slug, "deleting a body set"))
        return {"removed": True, "slug": request.slug,
                "set_id": request.set_id, "was_active": was_active}
    except Exception as error:
        failure = getattr(error, "detail", None) or str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


@app.post("/api/avatar/body/remove")
async def api_body_remove(request: Slug):
    _recover_body_edit_transaction_if_idle(request.slug)
    manifest = reg().read_manifest(request.slug)
    if not manifest:
        raise HTTPException(404, "avatar not found")
    job_id = _reserve_job(request.slug, "body-remove", "Removing full body")
    if not job_id:
        raise HTTPException(409, "avatar generation is still running")
    failure = ""
    try:
        from studio import body, library, motion
        body.remove(reg().adir(request.slug))
        motion.remove(reg().adir(request.slug))
        for slot in ("walk", "idle", "body"):
            library.clear_active(reg().adir(request.slug), slot)
        manifest.pop("body", None)
        manifest.pop("motion", None)
        reg().write_manifest(request.slug, manifest)
        _publish_runtime_atomic(
            request.slug, log=jlog(request.slug, "publishing portrait mode"))
        return {"removed": True, "slug": request.slug}
    except Exception as error:
        failure = str(error)
        raise
    finally:
        _finish_job(request.slug, job_id, failure)


@app.get("/api/avatar/progress")
async def api_progress(slug: str = Query(pattern=SLUG_PATTERN)):
    m = reg().read_manifest(slug) or {}
    with _jlock:
        j = _jobs.get(slug) or {"log": [], "phase": "", "done": True, "error": ""}
        j = dict(j)
    # The last failure rides along even when the job that failed is long
    # gone, so coming back to the page still answers "what happened".
    return {"manifest": m, "job": j, "last_failure": _last_failure(slug)}


def _publish_runtime(slug, label):
    """ensure_runtime with a job entry that actually completes. jlog alone
    creates a done=False job that nothing ever finishes, which left avatar
    cards stuck on 'publishing 100%' with disabled buttons until restart."""
    job_id = _reserve_job(slug, "publish", label)
    if not job_id:
        raise RuntimeError("avatar generation is still running")
    writer = jlog(slug, label)
    try:
        ensure_runtime(slug, log=writer)
    except Exception as error:
        _finish_job(slug, job_id, error)
        raise
    _finish_job(slug, job_id)


@app.post("/api/avatar/activate")
async def api_activate(b: Slug):
    _recover_body_edit_transaction_if_idle(b.slug)
    r = reg()
    m = r.read_manifest(b.slug) or {}
    if m.get("status") != "ready":
        raise HTTPException(400, "build this avatar before activating it")
    try:
        _publish_runtime(b.slug, "publishing")
    except Exception as e:
        raise HTTPException(400, f"could not publish runtime: {e}")
    r.set_active(b.slug)
    if r.get_companion() == b.slug:
        # One local avatar cannot occupy both desk windows at once.
        r.set_companion(None)
    return {"active": b.slug, "companion": r.get_companion()}


class CompanionRequest(BaseModel):
    slug: str = Field(default="", max_length=64)


@app.post("/api/avatar/companion")
async def api_companion(request: CompanionRequest):
    """Choose an optional second Mac-local desk avatar.

    This is local presentation state only. It does not pair or synchronize
    with another device or service.
    """
    registry = reg()
    slug = request.slug.strip()
    if not slug:
        registry.set_companion(None)
        return {"companion": None}
    if not re.fullmatch(SLUG_PATTERN, slug):
        raise HTTPException(422, "invalid avatar slug")
    _recover_body_edit_transaction_if_idle(slug)
    manifest = registry.read_manifest(slug) or {}
    if manifest.get("status") != "ready":
        raise HTTPException(400, "build this avatar before adding it to the desk")
    if slug == active_slug():
        raise HTTPException(
            400, "this avatar is already active; choose a different second avatar"
        )
    try:
        _publish_runtime(slug, "publishing second avatar")
    except Exception as error:
        raise HTTPException(400, f"could not publish runtime: {error}") from error
    registry.set_companion(slug)
    return {"companion": slug}


def _discard_temporary(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _avatar_is_busy(slug):
    with _jlock:
        job = _jobs.get(slug) or {}
        return bool(job and not job.get("done"))


@app.get("/api/avatar/export")
async def api_avatar_export(
    slug: str = Query(pattern=SLUG_PATTERN),
    variant: str = Query(pattern=r"^(?:macos-full|ios-light)$"),
):
    """Create one explicit AVTR file; this never synchronizes app state."""
    registry = reg()
    manifest = registry.read_manifest(slug)
    if not isinstance(manifest, dict):
        raise HTTPException(404, "avatar not found")
    if _avatar_is_busy(slug):
        raise HTTPException(409, "wait for avatar generation to finish")
    _recover_body_edit_transaction_if_idle(slug)
    manifest = registry.read_manifest(slug)
    if not isinstance(manifest, dict):
        raise HTTPException(404, "avatar not found")
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".openclam-{variant}-", suffix=".avtr"
    )
    os.close(descriptor)
    try:
        if variant == AVTR.MAC_VARIANT:
            await asyncio.to_thread(
                AVTR.export_macos_full,
                slug,
                registry.adir(slug),
                temporary,
            )
        else:
            runtime = await asyncio.to_thread(ensure_runtime, slug)
            await asyncio.to_thread(
                AVTR.export_ios_light,
                slug,
                str(manifest.get("name") or slug),
                registry.adir(slug),
                runtime,
                temporary,
                require_full_expression=True,
            )
    except AVTR.AvatarPackageError as error:
        _discard_temporary(temporary)
        raise HTTPException(422, str(error)) from error
    except Exception as error:
        _discard_temporary(temporary)
        raise HTTPException(422, "avatar export could not be created") from error
    return FileResponse(
        temporary,
        media_type="application/vnd.openclam.avatar+zip",
        filename=f"{slug}-{variant}.avtr",
        headers={"Cache-Control": "no-store"},
        background=BackgroundTask(_discard_temporary, temporary),
    )


@app.post("/api/avatar/import")
async def api_avatar_import(archive: UploadFile = File(...)):
    """Import a complete Mac authoring AVTR after bounded private staging."""
    if not str(archive.filename or "").lower().endswith(".avtr"):
        raise HTTPException(422, "choose a .avtr avatar file")
    descriptor, temporary = tempfile.mkstemp(
        prefix=".openclam-import-", suffix=".avtr"
    )
    written = 0
    try:
        with os.fdopen(descriptor, "wb") as output:
            while True:
                chunk = await archive.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > AVTR.MAX_MAC_ARCHIVE_BYTES:
                    raise AVTR.AvatarPackageError("avatar archive is too large")
                output.write(chunk)
        if not written:
            raise AVTR.AvatarPackageError("avatar archive is empty")
        os.chmod(temporary, 0o600)
        result = await asyncio.to_thread(
            AVTR.import_macos_full, temporary, reg().AVATARS
        )
        return JSONResponse(result, headers={"Cache-Control": "no-store"})
    except AVTR.AvatarPackageError as error:
        raise HTTPException(422, str(error)) from error
    except Exception as error:
        raise HTTPException(422, "invalid OpenClam Mac avatar archive") from error
    finally:
        await archive.close()
        _discard_temporary(temporary)


@app.get("/api/avatar/thumb")
async def api_avatar_thumb(slug: str = Query(...), size: int = Query(320)):
    """A card-sized face, made once and kept.

    The carousel used to pull the full 1024px keyframe for every avatar -
    well over a megabyte each, so opening the deck crawled (owner,
    2026-08-03). This is the same face at card size, cached on disk after
    the first request and reused between Studio sessions."""
    import cv2
    r = reg()
    if slug not in {a["slug"] for a in r.list_avatars()}:
        raise HTTPException(404, "no such avatar")
    size = max(64, min(512, int(size)))
    cache = os.path.join(r.AVATARS, slug, f"thumb-{size}.jpg")
    if not os.path.isfile(cache):
        source = None
        for name in ("keyframe.png", "source-keyframe.png", "source.jpg"):
            candidate = os.path.join(r.AVATARS, slug, name)
            if os.path.isfile(candidate):
                source = candidate
                break
        if not source:
            raise HTTPException(404, "no face to show")
        image = cv2.imread(source, cv2.IMREAD_COLOR)
        if image is None:
            raise HTTPException(404, "unreadable face")
        height, width = image.shape[:2]
        side = min(height, width)
        # Square on the face, which sits in the upper middle of a portrait.
        x0 = max(0, (width - side) // 2)
        crop = image[0:side, x0:x0 + side]
        thumb = cv2.resize(crop, (size, size), interpolation=cv2.INTER_AREA)
        cv2.imwrite(cache, thumb, [int(cv2.IMWRITE_JPEG_QUALITY), 86])
    return FileResponse(cache, media_type="image/jpeg",
                        headers={"Cache-Control": "public, max-age=604800"})


@app.post("/api/avatar/delete")
async def api_delete(b: Slug):
    r = reg()
    if r.get_active() == b.slug:
        raise HTTPException(400, "that avatar is active - activate another one first")
    r.delete_avatar(b.slug)
    return {"deleted": b.slug}


def _safe_file(root, relative):
    root = os.path.abspath(root)
    full = os.path.abspath(os.path.join(root, relative))
    try:
        inside = os.path.commonpath((root, full)) == root
    except ValueError:
        inside = False
    return full if inside and os.path.isfile(full) else None


@app.get("/files/{path:path}")
async def api_files(path: str):
    full = _safe_file(reg().AVATARS, path)
    if not full:
        raise HTTPException(404, "not found")
    return FileResponse(full, headers={"Cache-Control": "no-store"})


@app.get("/assets/{path:path}")
async def api_assets(path: str):
    """Resolved per request against the active avatar, so switching a face needs
    no file copy and no restart - just a page reload."""
    s = active_slug()
    if not s:
        raise HTTPException(404, "no active avatar")
    full = _safe_file(runtime_dir(s), path)
    if not full:
        raise HTTPException(404, "not found")
    return FileResponse(full, headers={"Cache-Control": "no-store"})


# ---------------------------------------------------------------- settings

@app.get("/api/meta")
async def api_meta():
    return {
        "app_id": APP_ID,
        "active": active_slug(),
        "companion": reg().get_companion(),
        "design": ((P.load().get("ui") or {}).get("design") or "quiet"),
    }


@app.get("/api/config")
async def api_config():
    return {"config": P.redacted(P.load()), "catalog": P.catalog(),
            "routes": {kind: P.last_route(kind) for kind in ("llm", "tts", "stt")},
            "active": active_slug()}


@app.get("/api/openclaw/pairing")
async def api_openclaw_pairing_status():
    try:
        return await asyncio.to_thread(openclaw_pairing.status)
    except openclaw_pairing.OpenClawPairingError as error:
        raise HTTPException(503, str(error)) from error


@app.post("/api/openclaw/pairing")
async def api_openclaw_pairing_create():
    try:
        return await asyncio.to_thread(openclaw_pairing.create_pairing_code)
    except openclaw_pairing.OpenClawPairingError as error:
        raise HTTPException(409, str(error)) from error


class OpenClawInstallRequest(BaseModel):
    setup_key: str = Field(default="", max_length=256)


@app.post("/api/openclaw/install")
async def api_openclaw_install(request: OpenClawInstallRequest):
    try:
        return await asyncio.to_thread(
            openclaw_pairing.install_channel,
            request.setup_key,
        )
    except openclaw_pairing.OpenClawPairingError as error:
        raise HTTPException(409, str(error)) from error


@app.get("/api/openclaw/agents")
async def api_openclaw_agents():
    try:
        return {"agents": await asyncio.to_thread(openclaw_acp.public_agents)}
    except openclaw_acp.OpenClawACPError as error:
        raise HTTPException(503, str(error)) from error


class OpenClawTurnRequest(BaseModel):
    agent_id: str = Field(min_length=1, max_length=64)
    session_id: str = Field(min_length=32, max_length=32)
    prompt: str = Field(min_length=1, max_length=12_000)
    input_handles: list[str] = Field(default_factory=list, max_length=8)


@app.post("/api/openclaw/uploads")
async def api_openclaw_uploads(
    agent_id: str = Form(..., min_length=1, max_length=64),
    session_id: str = Form(..., min_length=32, max_length=32),
    files: list[UploadFile] = File(...),
):
    if not files or len(files) > openclaw_acp.MAX_INPUT_FILES:
        raise HTTPException(400, "Attach between 1 and 8 files.")
    os.makedirs(P.DATA_ROOT, mode=0o700, exist_ok=True)
    staged: list[dict[str, object]] = []
    total = 0
    try:
        for upload in files:
            temporary = tempfile.NamedTemporaryFile(
                prefix="openclam-upload-", dir=P.DATA_ROOT, delete=False
            )
            temporary_path = temporary.name
            try:
                while True:
                    chunk = await upload.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > openclaw_acp.MAX_INPUT_TOTAL_BYTES:
                        raise HTTPException(413, "Keep attached files below 64 MB per message.")
                    temporary.write(chunk)
                temporary.close()
                try:
                    staged.append(await asyncio.to_thread(
                        openclaw_acp.stage_upload,
                        temporary_path,
                        upload.filename or "OpenClam file",
                        upload.content_type or "application/octet-stream",
                        agent_id,
                        session_id,
                    ))
                except openclaw_acp.OpenClawACPError as error:
                    raise HTTPException(400, str(error)) from error
            finally:
                temporary.close()
                try:
                    os.unlink(temporary_path)
                except FileNotFoundError:
                    pass
                await upload.close()
    except Exception:
        for attachment in staged:
            handle = attachment.get("handle")
            if isinstance(handle, str):
                await asyncio.to_thread(openclaw_acp.delete_upload, handle)
        raise
    return {"attachments": staged}


@app.post("/api/openclaw/turn")
async def api_openclaw_turn(request: OpenClawTurnRequest):
    async def events():
        try:
            async for event in openclaw_acp.stream_turn(
                request.agent_id,
                request.session_id,
                request.prompt,
                request.input_handles,
            ):
                yield json.dumps(
                    event, separators=(",", ":"), ensure_ascii=False
                ) + "\n"
        except openclaw_acp.OpenClawACPError as error:
            yield json.dumps(
                {"type": "error", "message": str(error)},
                separators=(",", ":"),
            ) + "\n"

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


@app.get("/api/openclaw/artifacts/{handle}")
async def api_openclaw_artifact(handle: str):
    path = openclaw_acp.artifact_path(handle)
    if not path:
        raise HTTPException(404, "OpenClaw file is no longer available")
    return FileResponse(
        path,
        filename=os.path.basename(path),
        headers={"Cache-Control": "no-store"},
    )


@app.get("/api/openclaw/uploads/{handle}")
async def api_openclaw_upload(handle: str):
    path = openclaw_acp.upload_path(handle)
    if not path:
        raise HTTPException(404, "Attached file is no longer available")
    return FileResponse(
        path,
        filename=os.path.basename(path),
        headers={"Cache-Control": "no-store"},
    )


class XaiOAuthPollRequest(BaseModel):
    flow_id: str = Field(min_length=1, max_length=256)


class XaiOAuthModeRequest(BaseModel):
    mode: str = Field(min_length=1, max_length=32)


class OpenAIAccountModeRequest(BaseModel):
    mode: str = Field(min_length=1, max_length=32)


def _openai_account_response(payload):
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


def _openai_account_error(error):
    raise HTTPException(
        getattr(error, "status_code", 502),
        getattr(error, "code", "openai_account_failed"),
        headers={"Cache-Control": "no-store"},
    )


@app.get("/api/openai/account/status")
async def api_openai_account_status():
    try:
        return _openai_account_response(openai_account.status())
    except openai_account.OpenAIAccountError as error:
        _openai_account_error(error)


@app.post("/api/openai/account/mode")
async def api_openai_account_mode(body: OpenAIAccountModeRequest):
    try:
        return _openai_account_response(openai_account.set_auth_mode(body.mode))
    except openai_account.OpenAIAccountError as error:
        _openai_account_error(error)


@app.post("/api/openai/account/login")
async def api_openai_account_login():
    try:
        return _openai_account_response(openai_account.start_login())
    except openai_account.OpenAIAccountError as error:
        _openai_account_error(error)


@app.post("/api/openai/account/logout")
async def api_openai_account_logout():
    try:
        return _openai_account_response(openai_account.logout())
    except openai_account.OpenAIAccountError as error:
        _openai_account_error(error)


def _xai_oauth_error(error):
    raise HTTPException(
        error.status_code,
        error.code,
        headers={"Cache-Control": "no-store"},
    )


def _xai_oauth_response(payload):
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.get("/api/xai/oauth/status")
async def api_xai_oauth_status():
    try:
        return _xai_oauth_response(xai_oauth.status())
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


@app.post("/api/xai/oauth/device/start")
async def api_xai_oauth_device_start():
    try:
        return _xai_oauth_response(await xai_oauth.start_device_login())
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


@app.post("/api/xai/oauth/device/poll")
async def api_xai_oauth_device_poll(body: XaiOAuthPollRequest):
    try:
        return _xai_oauth_response(
            await xai_oauth.poll_device_login(body.flow_id)
        )
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


@app.post("/api/xai/oauth/device/cancel")
async def api_xai_oauth_device_cancel():
    try:
        return _xai_oauth_response(xai_oauth.cancel_device_login())
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


@app.post("/api/xai/oauth/mode")
async def api_xai_oauth_mode(body: XaiOAuthModeRequest):
    try:
        return _xai_oauth_response(xai_oauth.set_auth_mode(body.mode))
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


@app.post("/api/xai/oauth/logout")
async def api_xai_oauth_logout():
    try:
        return _xai_oauth_response(await xai_oauth.logout())
    except xai_oauth.XaiOAuthError as error:
        _xai_oauth_error(error)


def _livekit_error(error):
    raise HTTPException(
        error.status_code,
        error.code,
        headers={"Cache-Control": "no-store"},
    )


def _credential_availability(account):
    try:
        return "available" if credentials.get(account) else "missing"
    except RuntimeError:
        # The unsigned source host deliberately has no claim on a signed app
        # Keychain item; its actionable state is simply to paste a session
        # token. A signed build should instead tell the owner to unlock the
        # credential store rather than pretending the item is absent.
        return "missing" if credentials.development_session_only() \
            else "unavailable"


def _livekit_public_config(cfg=None):
    if cfg is None:
        livekit = P.load_livekit_nonsecret()
    elif isinstance(cfg, dict) and isinstance(cfg.get("livekit"), dict):
        livekit = cfg.get("livekit") or {}
    else:
        livekit = cfg if isinstance(cfg, dict) else {}
    credential_state = _credential_availability(
        "livekit.pilot_app_token"
    )
    public = LK.public_config(
        LK.deployment_config(livekit),
        credential_state == "available",
    )
    # The unsigned source host intentionally cannot share the signed app's
    # Keychain identity.  Tell Settings the truth so it never promises that a
    # development-only token will survive a restart.  This is response-only;
    # the field is rejected if a renderer tries to write it back.
    public["credential_persistence"] = (
        "session" if credentials.development_session_only() else "keychain"
    )
    public["credential_state"] = credential_state
    return public


@app.get("/api/livekit/catalog")
async def api_livekit_catalog():
    try:
        return JSONResponse(
            LK.catalog(), headers={"Cache-Control": "no-store"}
        )
    except LK.LiveKitBridgeError as error:
        _livekit_error(error)


@app.get("/api/livekit/config")
async def api_livekit_config():
    try:
        return JSONResponse(
            {
                "config": _livekit_public_config(),
                "catalog": LK.catalog(),
                "active": active_slug(),
            },
            headers={"Cache-Control": "no-store"},
        )
    except LK.LiveKitBridgeError as error:
        _livekit_error(error)


@app.post("/api/livekit/config")
async def api_livekit_config_set(body: dict):
    try:
        current = P.load_nonsecret()
        update = LK.prepare_config_update(
            current.get("livekit") or {}, body,
            allow_connection_fields=False,
        )
        saved = P.save(
            {"livekit": update},
            replace_livekit=True,
            materialise_result=False,
        )
        return JSONResponse(
            {"config": _livekit_public_config(saved), "catalog": LK.catalog()},
            headers={"Cache-Control": "no-store"},
        )
    except LK.LiveKitBridgeError as error:
        _livekit_error(error)
    except RuntimeError:
        _livekit_error(LK.LiveKitBridgeError(
            "livekit_credential_store_unavailable", 503
        ))


def _active_livekit_persona(cfg):
    slug = active_slug()
    manifest = reg().read_manifest(slug) if slug else {}
    manifest = manifest if isinstance(manifest, dict) else {}
    name = (str(manifest.get("name") or "").strip()
            or str((cfg.get("persona") or {}).get("name") or "").strip()
            or str(slug or "OpenClam"))
    return name, effective_persona(cfg)


@app.post("/api/livekit/session")
async def api_livekit_session():
    try:
        # Resolve the one pilot token and only the provider credentials selected
        # for this call inside LK.create_session().  An unrelated saved provider
        # key must never make a managed Live Talk call fail before preflight.
        cfg = P.load_nonsecret()
        name, instructions = _active_livekit_persona(cfg)
        livekit_config = LK.deployment_config(
            cfg.get("livekit") or {}, require_connection=True
        )
        connection = await LK.create_session(
            livekit_config, name, instructions
        )
        return JSONResponse(connection, headers={"Cache-Control": "no-store"})
    except LK.LiveKitBridgeError as error:
        _livekit_error(error)


@app.get("/api/reveal")
async def api_reveal(path: str):
    """Retired: Keychain material is write-only from renderer processes."""
    raise HTTPException(
        404, "not found", headers={"Cache-Control": "no-store"}
    )


@app.post("/api/config")
async def api_config_set(body: dict):
    # An empty api_key from the UI means "unchanged", never "erase" - the browser
    # is never sent the stored key, so it cannot echo one back.
    cur = P.load()
    if "live" in body:
        raise HTTPException(
            422, "legacy realtime settings were removed; use LiveKit Live Talk"
        )
    body.pop("has_keys", None)  # response-only Keychain presence summary
    unsupported = set(body) - P.CONFIG_BLOCKS
    if unsupported:
        raise HTTPException(422, "unsupported OpenClam settings block")
    for k in ("llm", "tts", "stt", "image", "video"):
        blk = body.get(k)
        if not isinstance(blk, dict):
            continue
        blk.pop("has_key", None)
        if "provider" in blk and blk.get("provider") \
                and not P.spec(k, blk.get("provider")):
            raise HTTPException(422, f"unsupported direct {k} provider")
        provider_changed = bool(blk.get("provider")) and \
            blk.get("provider") != (cur.get(k) or {}).get("provider")
        if k == "stt":
            selected_provider = blk.get("provider") \
                or (cur.get("stt") or {}).get("provider")
            if provider_changed and "language" not in blk:
                blk["language"] = P.stt_language_catalog(
                    selected_provider
                )["default_language"]
            selected_language = blk.get("language")
            if selected_language is None:
                selected_language = (cur.get("stt") or {}).get("language")
            try:
                blk["language"] = P.validate_stt_language(
                    selected_provider, selected_language
                )
            except RuntimeError as error:
                raise HTTPException(422, str(error)) from error
        requested_key = blk.get("api_key")
        if requested_key == "__clear__" or (provider_changed and not requested_key):
            # "__clear__" rides through to the vault, which deletes the
            # Keychain entry - not just the marker in the file.
            blk["api_key"] = "__clear__"
        elif not requested_key:
            blk.pop("api_key", None)
    # The platform keyring (#25): empty means "unchanged", __clear__ rides
    # through to the vault, and the has_keys echo never touches the file.
    keyring = body.get("keys")
    if isinstance(keyring, dict):
        for name in list(keyring):
            if not keyring[name]:
                keyring.pop(name)
        # "Pasted once" has to MEAN once. A lane that already held a key of
        # its own shadowed the platform key forever - the owner pasted a
        # good Soniox key into the keyring and Hear went on failing with
        # the stale one it was still holding (owner, 2026-08-05). Saving a
        # platform key retires the lane keys it replaces; a lane key set in
        # this same save is a deliberate override and survives.
        # "__adopt__" means: keep the platform key you already hold, and
        # make it authoritative. The browser is never given a stored key,
        # so without this the owner would have to re-paste a key they had
        # already pasted just to retire the lane keys shadowing it.
        adopt = [n for n, v in keyring.items() if v == "__adopt__"]
        for name in adopt:
            keyring.pop(name)
        for name, value in list(keyring.items()) + [(n, "") for n in adopt]:
            if value == "__clear__":
                continue
            for kind in ("llm", "tts", "stt", "image", "video"):
                lane = body.get(kind) if isinstance(body.get(kind), dict) \
                    else (cur.get(kind) or {})
                provider = lane.get("provider") or (cur.get(kind) or {}).get("provider")
                if P.platform_of(provider) != name:
                    continue
                asked = body.get(kind)
                if isinstance(asked, dict) and asked.get("api_key") \
                        and asked["api_key"] != "__clear__":
                    continue          # they typed one HERE; that one wins
                block = body.setdefault(kind, {})
                if isinstance(block, dict):
                    block["api_key"] = "__clear__"
    # The durable Check state: a green tick answers for one specific stored
    # key, so a pasted or cleared platform key retires that row's verdict.
    # The handler always writes the FULL dict (and _merge replaces it
    # wholesale) so a retired verdict really leaves the file.
    checks = {n: v for n, v in (cur.get("key_checks") or {}).items()
              if isinstance(v, dict)}
    incoming_checks = body.pop("key_checks", None)
    if isinstance(keyring, dict):
        for name, value in keyring.items():
            if value:                  # a paste or "__clear__"; adopt was
                checks.pop(name, None)  # popped above and keeps its verdict
    if isinstance(incoming_checks, dict):
        for name, verdict in incoming_checks.items():
            if isinstance(verdict, dict):
                checks[name] = {"ok": bool(verdict.get("ok")),
                                "at": str(verdict.get("at") or "")[:32],
                                "error": str(verdict.get("error") or "")[:160]}
            elif verdict is None:
                checks.pop(name, None)
    body["key_checks"] = checks
    livekit = body.get("livekit")
    if livekit is not None:
        try:
            body["livekit"] = LK.prepare_config_update(
                cur.get("livekit") or {}, livekit,
                allow_connection_fields=False,
            )
        except LK.LiveKitBridgeError as error:
            _livekit_error(error)
    new = P.save(body, replace_livekit=livekit is not None)
    if (new.get("stt") or {}).get("provider") != (cur.get("stt") or {}).get("provider") or \
       (new.get("tts") or {}).get("provider") != (cur.get("tts") or {}).get("provider"):
        _state["warm"] = False
        threading.Thread(target=_warm, daemon=True).start()
    return {"config": P.redacted(new)}


def _with_key(kind, blk):
    """Reuse a stored key only for the same provider; a provider with no
    key of its own still inherits the platform keyring, so switching a
    lane to a keyed provider validates before the lane is ever saved."""
    cfg_all = P.load()
    cur = cfg_all.get(kind) or {}
    incoming = blk or {}
    incoming_provider = incoming.get("provider") or cur.get("provider")
    same_provider = incoming_provider == cur.get("provider")
    out = dict(cur) if same_provider else {"provider": incoming_provider}
    out.update({k: v for k, v in incoming.items()
                if k != "has_key" and v not in (None, "")})
    if same_provider and not out.get("api_key"):
        out["api_key"] = cur.get("api_key", "")
    if not out.get("api_key"):
        keys = cfg_all.get("keys") if isinstance(cfg_all.get("keys"), dict) else {}
        inherited = keys.get(P.platform_of(out.get("provider"))) or ""
        if inherited:
            out["api_key"] = inherited
    return out


def _with_explicit_xai_auth(cfg):
    """xAI's one global mode owns its bearer, not the lane config.

    Removing a materialised legacy/per-lane key here prevents model loading
    and connection checks from accidentally bypassing the selected OAuth
    mode.  The provider resolves either ``keys.xai`` or the refreshed OAuth
    bearer through xai_oauth.resolve_auth().
    """
    if P.platform_of(cfg.get("provider")) != "xai":
        return cfg
    cfg = dict(cfg)
    cfg.pop("api_key", None)
    return cfg


def _with_explicit_global_auth(kind, cfg):
    cfg = _with_explicit_xai_auth(cfg)
    if (kind in {"llm", "image"}
            and P.platform_of(cfg.get("provider")) == "openai"
            and openai_account.auth_mode() == openai_account.CHATGPT_MODE):
        cfg = dict(cfg)
        cfg.pop("api_key", None)
    return cfg


@app.post("/api/models")
async def api_models(body: dict):
    kind = body.get("kind", "llm")
    if kind not in ("llm", "tts", "stt", "image", "video"):
        raise HTTPException(400, "unknown model kind")
    cfg = _with_key(kind, body.get("cfg"))
    platform = P.platform_of(cfg.get("provider"))
    is_xai = platform == "xai"
    is_openai_chatgpt = bool(
        kind in {"llm", "image"}
        and platform == "openai"
        and openai_account.auth_mode() == openai_account.CHATGPT_MODE
    )
    cfg = _with_explicit_global_auth(kind, cfg)
    provider_spec = P.spec(kind, cfg.get("provider")) or {}
    if (provider_spec.get("key") and not cfg.get("api_key")
            and not is_xai and not is_openai_chatgpt):
        return JSONResponse({"error": "Enter an API key before loading models.",
                             "models": [], "voices": [], "ready": False,
                             "validated": False,
                             "provider_contacted": False}, 200)
    try:
        # xAI's OAuth chat contract has no documented /models route. Its
        # provider adapter therefore returns a reviewed local catalogue after
        # resolving the selected OAuth credential. That makes the menu ready,
        # but it does not prove entitlement to the selected model; the Test
        # action (or first chat) performs that exact provider call.
        local_oauth_catalog = bool(
            is_xai and kind == "llm"
            and xai_oauth.auth_mode() == xai_oauth.OAUTH2_MODE
        )
        choices = await P.list_choices(kind, cfg)
        if local_oauth_catalog:
            return {
                **choices,
                "ready": True,
                "validated": False,
                "provider_contacted": False,
                "readiness": "reviewed_local_catalog",
                "detail": (
                    "OAuth session ready. These are OpenClam's reviewed xAI "
                    "OAuth choices; use Test to check the exact selected model."
                ),
            }
        return {
            **choices,
            "ready": True,
            "validated": True,
            "provider_contacted": True,
            "readiness": "provider_catalog",
        }
    except Exception as e:
        return JSONResponse({"error": P.safe_error(e), "models": [], "voices": [],
                             "ready": False, "validated": False,
                             "provider_contacted": False}, 200)


@app.post("/api/test")
async def api_test(body: dict):
    kind = body.get("kind", "llm")
    cfg = _with_explicit_global_auth(kind, _with_key(kind, body.get("cfg")))
    result = await P.test(kind, cfg)
    if kind == "llm":
        result["route"] = P.last_route("llm")
    return result


# ---------------------------------------------------------------- chat

def _warm():
    """Only load what the current settings will actually use. A user on cloud
    providers should not wait for Kokoro and Whisper to page in."""
    cfg = P.load()
    try:
        if (cfg["stt"]["provider"]) == "mlx_whisper":
            _state["warming"] = "whisper"
            import mlx_whisper
            mlx_whisper.transcribe(
                np.zeros(16000, np.float32),
                path_or_hf_repo=P.resolve_mlx_whisper_model(
                    cfg["stt"].get("model")
                ),
                language="en",
            )
        tts_cfg = cfg["tts"]
        if tts_cfg["provider"] == "kokoro":
            _state["warming"] = "kokoro"
            voice = tts_cfg.get("voice") or "af_heart"
            speed = float(tts_cfg.get("speed") or 1.0)
            list(P._kokoro(tts_cfg)("Ready.", voice=voice, speed=speed))
        _state["warming"] = ""
        _state["warm"] = True
        print("[openclam] warm", flush=True)
    except Exception as e:
        _state["warming"] = ""
        _state["warm"] = True          # cloud-only setups have nothing to warm
        print("[openclam] warmup skipped:", P.safe_error(e), flush=True)


def _start():
    recovery_failed = set()
    try:
        avatars = reg().list_avatars()
    except Exception as error:
        avatars = []
        print("[openclam] body-edit recovery scan failed:", error, flush=True)
    for avatar in avatars:
        slug = avatar.get("slug")
        if not slug:
            continue
        try:
            _recover_body_edit_transaction(
                slug,
                log=lambda message, current=slug: print(
                    f"[avatar:{current}] {message}", flush=True))
        except Exception as error:
            recovery_failed.add(slug)
            print(
                f"[avatar:{slug}] body-edit recovery failed: {error}",
                flush=True)
    s = active_slug()
    if s and s not in recovery_failed:
        try:
            ensure_runtime(s)
        except Exception as e:
            print("[openclam] runtime bundle missing:", e, flush=True)
    threading.Thread(target=_warm, daemon=True).start()
    threading.Thread(target=_warm_media_tools, daemon=True).start()


def _warm_media_tools():
    """The first run of a Homebrew binary can stall for a minute while the
    system vets it - long enough that an agent's first video shipped as an
    unplayable card. Pay that cost here, not inside somebody's first reply."""
    for name in ("ffprobe", "ffmpeg"):
        found = shutil.which(name)
        if not found:
            continue
        try:
            subprocess.run([found, "-version"], capture_output=True,
                           timeout=240, stdin=subprocess.DEVNULL)
        except Exception:
            pass


@app.get("/health")
async def health():
    cfg = P.load()
    ok = False
    try:
        await P.list_models("llm", cfg["llm"])
        ok = True
    except Exception:
        pass

    def label(kind):
        block = cfg[kind]
        detail = block.get("voice") if kind == "tts" else block.get("model")
        return f"{block.get('provider') or 'not configured'} / {detail or 'default'}"

    return {"app_id": APP_ID, "boot": BOOT_ID, "version": APP_VERSION,
            "design": ((cfg.get("ui") or {}).get("design") or "quiet"),
            "theme": ((cfg.get("ui") or {}).get("theme") or ""),
            "warm": _state["warm"], "warming": _state["warming"],
            "ollama": cfg["llm"].get("provider") == "ollama" and ok,
            "provider_ok": ok, "llm_ok": ok,
            "llm": label("llm"), "voice": label("tts"), "ears": label("stt"),
            "last_llm": P.last_route("llm"), "avatar": active_slug()}


@app.post("/stt")
async def stt(audio: UploadFile = File(...)):
    cfg = P.load()["stt"]
    raw = await audio.read(MAX_AUDIO_BYTES + 1)
    if len(raw) > MAX_AUDIO_BYTES:
        raise HTTPException(413, "recording exceeds the 25 MB upload limit")
    try:
        return {"text": await P.hear(raw, audio.filename or "a.webm", cfg)}
    except Exception as e:
        print("[openclam] stt failed:", P.safe_error(e), flush=True)
        return {"text": "", "error": P.safe_error(e, 200)}


# ------------------------------------------------------------ live dictation
# Hold-to-talk streams here for word-by-word dictation into the input field.
# The bridge speaks Soniox's realtime WebSocket protocol server-side (the
# API key never reaches the renderer) and forwards MediaRecorder's webm
# chunks as-is - Soniox's audio_format "auto" decodes the container. If the
# dictation default is not a Soniox realtime model, the endpoint reports
# unavailable and the client falls back to batch interim transcription.

SONIOX_RT_URL = "wss://stt-rt.soniox.com/transcribe-websocket"


def _soniox_stream_config():
    config = P.load().get("stt") or {}
    if config.get("provider") != "soniox" or not config.get("api_key"):
        return None
    return P._soniox_config(config)


@app.websocket("/stt/stream")
async def stt_stream(client: WebSocket, pcm: int = Query(0)):
    # The http auth middleware does not run for websocket scopes, so the
    # token check happens here; Electron injects the header on the upgrade.
    if not AUTH_TOKEN or not secrets.compare_digest(
            _client_token(client), AUTH_TOKEN):
        await client.close(code=4403)
        return
    await client.accept()
    try:
        config = await asyncio.to_thread(_soniox_stream_config)
    except Exception as e:
        config = None
        print("[openclam] dictation stream config failed:", P.safe_error(e), flush=True)
    if not config:
        await client.send_json({"error": "realtime dictation unavailable",
                                "finished": True})
        await client.close()
        return
    # Native clients may send raw PCM16 rather than a media container. In
    # that case the query parameter declares the sample rate explicitly.
    if pcm:
        config = dict(config, audio_format="pcm_s16le",
                      sample_rate=max(8000, min(48000, int(pcm))),
                      num_channels=1)
    import websockets
    finals = []
    try:
        async with websockets.connect(
                SONIOX_RT_URL, max_size=1 << 22, open_timeout=10) as upstream:
            await upstream.send(json.dumps(config))

            async def pump_audio():
                while True:
                    data = await client.receive_bytes()
                    if not data:
                        # End-of-take. Soniox's docs accept "an empty binary
                        # or text frame", but measured live only the empty
                        # TEXT frame finalises - empty binary just times out.
                        await upstream.send("")
                        return
                    await upstream.send(data)

            audio_task = asyncio.create_task(pump_audio())
            try:
                async for message in upstream:
                    payload = json.loads(message)
                    if payload.get("error_code") or payload.get("error_message"):
                        await client.send_json({
                            "error": str(payload.get("error_message")
                                         or "provider error")[:200],
                            "finished": True})
                        return
                    interim = []
                    for token in payload.get("tokens") or []:
                        text = str(token.get("text") or "")
                        if token.get("is_final"):
                            finals.append(text)
                        else:
                            interim.append(text)
                    text = ("".join(finals) + "".join(interim)).strip()
                    if payload.get("finished"):
                        await client.send_json({
                            "finished": True,
                            "final": "".join(finals).strip() or text})
                        return
                    await client.send_json({"text": text})
            finally:
                audio_task.cancel()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print("[openclam] dictation stream failed:", P.safe_error(e), flush=True)
        try:
            await client.send_json({"error": P.safe_error(e, 200),
                                    "finished": True})
        except Exception:
            pass
    finally:
        try:
            await client.close()
        except Exception:
            pass


@app.get("/live-worklet.js")
async def live_worklet():
    return FileResponse(
        os.path.join(WEB, "live-worklet.js"),
        media_type="application/javascript",
        headers={"Cache-Control": "no-store"})


@app.get("/livekit-client.js")
async def livekit_client_script():
    path = os.path.join(WEB, "vendor", "livekit-client.umd.js")
    if not os.path.isfile(path):
        raise HTTPException(404, "LiveKit client is not installed")
    return FileResponse(
        path,
        media_type="application/javascript",
        headers={"Cache-Control": "no-store"},
    )


@app.get("/live-talk-connection.wav")
async def live_talk_connection_sound():
    path = os.path.join(WEB, "vendor", "live-talk-connection.wav")
    if not os.path.isfile(path):
        raise HTTPException(404, "Live Talk connection sound is not installed")
    return FileResponse(
        path,
        media_type="audio/wav",
        headers={"Cache-Control": "no-store"},
    )


class Turn(BaseModel):
    history: list
    # Live Talk already owns the audible TTS lane. Its trusted foreground turn
    # bridge requests the same text/media result without paying for or producing
    # a second, discarded local voice. Existing chat and PTT requests omit this
    # strict, opt-in field and retain audio synthesis by default.
    suppress_local_tts: bool = Field(default=False, strict=True)


# Direct media tools for ordinary local chat. Live Talk tools are owned by
# the shared LiveKit agent and never pass through this prompt contract.
_OWN_TOOLS = (
    "\n\nYou can create media. To do it, put ONE of these on its own line "
    "and end your reply there - the result is attached for you:\n"
    "<<openclam:image detailed description of the picture>>\n"
    "<<openclam:video detailed description of the clip>>\n"
    "Use them only when the user asks for a picture/image/photo or a "
    "video/clip. Never mention the directive syntax.")
_OWN_TOOL_CALL = re.compile(r"<<openclam:(image|video)\s+(.+?)>>", re.S)

def effective_persona(cfg=None):
    """Who she is right now.

    A face and a character are the same thing to whoever is talking to
    her: put Captain Sparrow on the desk and he should answer as Sparrow,
    not as the house assistant wearing his face (owner, 2026-08-04). The
    ACTIVE avatar's own persona wins; the global one is the fallback for
    every avatar that has not been given one, so an empty field keeps
    today's behaviour exactly.
    """
    cfg = cfg if cfg is not None else P.load()
    house = ((cfg.get("persona") or {}).get("system") or "").strip()
    slug = active_slug()
    if not slug:
        return house
    manifest = reg().read_manifest(slug) or {}
    mine = ((manifest.get("persona") or {}).get("system") or "").strip()
    return mine or house


def _llm_runtime_identity(cfg):
    """Give the model the host-selected identity without trusting self-report.

    A language model may identify itself as a product seen during training.
    OpenClam knows the actual route, so questions about the running model must
    be answered from configuration and the provider receipt instead.
    """
    block = (cfg or {}).get("llm") or {}
    provider = str(block.get("provider") or "").strip()
    model = str(block.get("model") or P.FALLBACK_MODEL.get(provider, "")).strip()
    if not provider or not model:
        return ""
    safe_provider = re.sub(r"[^A-Za-z0-9._:/@+ -]", "?", provider)[:80]
    safe_model = re.sub(r"[^A-Za-z0-9._:/@+ -]", "?", model)[:200]
    label = str((P.spec("llm", provider) or {}).get("label") or safe_provider)
    return (
        "\n\nHOST RUNTIME FACT: OpenClam is routing this reply through "
        f"{label} using the exact model identifier {safe_model}. If asked which "
        "language model is running, report that provider and identifier exactly. "
        "Do not substitute a model or product name remembered from training."
    )


def _direct_chat_system(cfg, now=None):
    now = now or datetime.datetime.now().astimezone()
    return (effective_persona(cfg) + _OWN_TOOLS + _llm_runtime_identity(cfg)
            + "\n\nRIGHT NOW it is " + now.strftime("%A %Y-%m-%dT%H:%M %Z")
            + ". Compute every relative date from this.")


_GENERATED_FILES = {}
_GENERATED_MEDIA_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic",
    ".mp4", ".m4v", ".mov", ".webm", ".mp3", ".m4a", ".wav",
}


def _share_generated_file(path):
    """Mint an authenticated, process-local handle for one generated file."""
    real = os.path.realpath(os.fspath(path))
    if not os.path.isfile(real) or os.path.splitext(real)[1].lower() \
            not in _GENERATED_MEDIA_SUFFIXES:
        return ""
    handle = secrets.token_urlsafe(18)
    _GENERATED_FILES[handle] = real
    return f"api/generated/{handle}"


@app.get("/api/generated/{handle}")
async def api_generated_file(handle: str):
    path = _GENERATED_FILES.get(handle)
    if not path or not os.path.isfile(path):
        raise HTTPException(404, "generated file is no longer available")
    return FileResponse(path, headers={"Cache-Control": "no-store"})


@app.post("/reply")
async def reply(t: Turn):
    cfg = P.load()
    msgs = list(t.history[-12:])
    # The brain has no clock of its own: without this it books "tomorrow"
    # against its training-time sense of the date (sim, 2026-08-07).
    system = _direct_chat_system(cfg)
    try:
        text = await P.chat(msgs, cfg["llm"], system=system)
    except Exception as e:
        print("[openclam] llm failed:", P.safe_error(e), flush=True)
        hint = P.failure_hint(e)
        text = (f"My model is not answering — {hint}. Check the provider in Settings."
                if hint else
                "My model is not answering. Check the provider in Settings.")
    if not text:
        text = "I lost that thread for a second. Say it again?"
    return await _finish_direct_reply(text, cfg)


def _stream_visible_reply(raw_text):
    """Hide private media directives while their tokens are still arriving."""
    text = _OWN_TOOL_CALL.sub("", str(raw_text or ""))
    marker = text.rfind("<<")
    if marker >= 0:
        tail = text[marker:].lower()
        prefixes = ("<<openclam:image", "<<openclam:video")
        if any(prefix.startswith(tail) for prefix in prefixes) \
                or tail.startswith("<<openclam:"):
            text = text[:marker]
    return text.rstrip()


async def _finish_direct_reply(text, cfg, *, suppress_local_tts: bool = False):
    import media_gen
    cards = []
    call = _OWN_TOOL_CALL.search(text)
    if call:
        kind, prompt = call.group(1), call.group(2).strip()
        text = _OWN_TOOL_CALL.sub("", text).strip()
        try:
            if kind == "image":
                made = await media_gen.generate_image(prompt, cfg["image"])
            else:
                made = await media_gen.generate_video(prompt, cfg["video"])
            url = _share_generated_file(made)
            if url:
                cards.append({"url": url, "name": prompt[:60]})
            if not text:
                text = "Here it is." if kind == "image" else \
                       "Here's the clip."
        except Exception as error:
            detail = P.safe_error(error, 140)
            print("[openclam] media generation failed:", detail, flush=True)
            text = (text + " " if text else "") + \
                f"(I tried to make the {kind}, but the provider said: {detail})"
    result = await _say(text, cfg) if text and not suppress_local_tts else \
        {"text": "", "audio": "", "track": [], "dur": 0.0, "tier": "none"}
    if text and suppress_local_tts:
        result["text"] = text
    result["media"] = cards
    result["llm_route"] = P.last_route("llm")
    return result


@app.post("/reply/stream")
async def reply_stream(t: Turn):
    cfg = P.load()
    msgs = list(t.history[-12:])
    system = _direct_chat_system(cfg)

    async def events():
        raw_text = ""
        visible_text = ""
        try:
            async for snapshot in P.chat_stream(msgs, cfg["llm"], system=system):
                raw_text = snapshot
                visible = _stream_visible_reply(snapshot)
                if visible and visible != visible_text:
                    visible_text = visible
                    yield json.dumps(
                        {"type": "text", "text": visible},
                        separators=(",", ":"), ensure_ascii=False,
                    ) + "\n"
        except Exception as error:
            print("[openclam] streamed llm failed:", P.safe_error(error), flush=True)
            hint = P.failure_hint(error)
            raw_text = (f"My model is not answering — {hint}. Check the provider in Settings."
                        if hint else
                        "My model is not answering. Check the provider in Settings.")
            visible_text = raw_text
            yield json.dumps(
                {"type": "text", "text": visible_text},
                separators=(",", ":"), ensure_ascii=False,
            ) + "\n"
        if not raw_text:
            raw_text = "I lost that thread for a second. Say it again?"
        result = await _finish_direct_reply(
            raw_text,
            cfg,
            suppress_local_tts=t.suppress_local_tts,
        )
        yield json.dumps(
            {"type": "complete", **result},
            separators=(",", ":"), ensure_ascii=False,
        ) + "\n"

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


class Say(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TTS_TEXT_CHARS, strict=True)


def _tts_text_error(text):
    if not isinstance(text, str) or not text.strip():
        return "Speech text must not be empty"
    if len(text) > MAX_TTS_TEXT_CHARS or len(text.encode("utf-8")) > MAX_TTS_TEXT_BYTES:
        return "Speech text exceeds the 15000-byte limit"
    return ""


@app.post("/say")
async def say(s: Say):
    error = _tts_text_error(s.text)
    if error:
        raise HTTPException(status_code=413, detail=error)
    return await _say(s.text, P.load())


async def _say(text, cfg):
    error = _tts_text_error(text)
    if error:
        return {"text": str(text or ""), "audio": "", "track": [], "dur": 0.0,
                "tier": "none", "error": error}
    try:
        y, al = await P.speak(text, cfg["tts"])
        track, dur, tier = align.build(text, y, al)
        wav = P.to_wav(y)
    except Exception as e:
        print("[openclam] tts failed:", P.safe_error(e), flush=True)
        return {"text": text, "audio": "", "track": [], "dur": 0.0,
                "tier": "none", "error": P.safe_error(e, 200)}
    return {"text": text, "audio": base64.b64encode(wav).decode(),
            "track": track, "dur": dur, "tier": tier}


# ---------------------------------------------------------------- pages

@app.get("/")
async def index():
    return HTMLResponse(open(os.path.join(WEB, "index.html")).read(),
                        headers={"Cache-Control": "no-store"})


# The pet page addressed to ONE avatar rather than "the active one". The page
# is served under /c/<slug>/ so its relative "assets/..." references resolve
# to the per-slug asset route below - the renderer needs no URL changes. This
# is how the second on-desk avatar window renders its own runtime while the
# main window keeps following the active avatar.
@app.get("/c/{slug}/")
async def companion_page(slug: str):
    if not re.fullmatch(SLUG_PATTERN, slug):
        raise HTTPException(404, "not found")
    if not os.path.isfile(os.path.join(runtime_dir(slug), "manifest.json")):
        raise HTTPException(404, "this avatar has no runtime bundle")
    return HTMLResponse(open(os.path.join(WEB, "index.html")).read(),
                        headers={"Cache-Control": "no-store"})


@app.get("/c/{slug}/assets/{path:path}")
async def companion_assets(slug: str, path: str):
    if not re.fullmatch(SLUG_PATTERN, slug):
        raise HTTPException(404, "not found")
    full = _safe_file(runtime_dir(slug), path)
    if not full:
        raise HTTPException(404, "not found")
    return FileResponse(full, headers={"Cache-Control": "no-store"})


@app.get("/bubble")
async def bubble():
    return HTMLResponse(open(os.path.join(WEB, "bubble.html")).read(),
                        headers={"Cache-Control": "no-store"})


@app.get("/menu")
async def pet_menu():
    return HTMLResponse(open(os.path.join(WEB, "menu.html")).read(),
                        headers={"Cache-Control": "no-store"})


@app.get("/appearance")
async def appearance():
    return HTMLResponse(open(os.path.join(WEB, "appearance.html")).read(),
                        headers={"Cache-Control": "no-store"})


@app.get("/settings")
async def settings():
    return HTMLResponse(open(os.path.join(WEB, "settings.html")).read(),
                        headers={"Cache-Control": "no-store"})
