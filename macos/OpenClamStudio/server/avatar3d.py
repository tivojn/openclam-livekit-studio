"""3D avatars: one self-contained glTF binary driven by the viseme track.

A 3D avatar is a registry entry whose source is a rigged GLB with facial
morph targets instead of a portrait and generated sprite banks.  Its runtime
bundle is the same GLB plus a small manifest that declares ``renderer: "3d"``;
the desktop page loads that manifest exactly as it loads a 2D bundle and then
hands the model to ``web/avatar3d.js``.

The lip-sync data path is unchanged: Kokoro/ElevenLabs/Edge timing still
produces the Oculus/Meta XR 15-target track, and the renderer maps each viseme
onto the model's own targets (``vrc.v_aa``, ``viseme_aa``, ARKit recipes...).

Nothing here decodes geometry.  The GLB is parsed only far enough to verify
the container, refuse packages that need decoders the app does not ship, and
report which visemes the model can express.
"""
from __future__ import annotations

import datetime
import json
import math
import os
import re
import shutil
import struct
import tempfile

MODEL_NAME = "model.glb"
MAX_MODEL_BYTES = 256 * 1024 * 1024
MAX_THUMBNAIL_BYTES = 4 * 1024 * 1024
RENDER_WIDTH, RENDER_HEIGHT = 1024, 1536
RUNTIME_KIND = "3d"
# app.py assigns its bundle version here at import; standalone callers (tests,
# CLI import) fall back to 1, which the app then republishes on activation.
RUNTIME_VERSION = 1

VISEMES = ["sil", "PP", "FF", "TH", "DD", "kk", "CH", "SS",
           "nn", "RR", "aa", "E", "ih", "oh", "ou"]

# Keep in sync with VISEME_ALIASES in web/avatar3d.js (lower-case).
VISEME_ALIASES = {
    "sil": ("vrc.v_sil", "v_sil", "viseme_sil", "sil"),
    "PP": ("vrc.v_pp", "v_pp", "viseme_pp", "pp"),
    "FF": ("vrc.v_ff", "v_ff", "viseme_ff", "ff"),
    "TH": ("vrc.v_th", "v_th", "viseme_th", "th"),
    "DD": ("vrc.v_dd", "v_dd", "viseme_dd", "dd"),
    "kk": ("vrc.v_kk", "v_kk", "viseme_kk", "kk"),
    "CH": ("vrc.v_ch", "v_ch", "viseme_ch", "ch"),
    "SS": ("vrc.v_ss", "v_ss", "viseme_ss", "ss"),
    "nn": ("vrc.v_nn", "v_nn", "viseme_nn", "nn"),
    "RR": ("vrc.v_rr", "v_rr", "viseme_rr", "rr"),
    "aa": ("vrc.v_aa", "v_aa", "viseme_aa", "aa", "a", "fcl_mth_a"),
    "E": ("vrc.v_ee", "vrc.v_e", "v_ee", "v_e", "viseme_e", "viseme_ee",
          "ee", "e", "fcl_mth_e"),
    "ih": ("vrc.v_ih", "v_ih", "viseme_ih", "viseme_i", "ih", "i", "fcl_mth_i"),
    "oh": ("vrc.v_oh", "v_oh", "viseme_oh", "viseme_o", "oh", "o", "fcl_mth_o"),
    "ou": ("vrc.v_ou", "v_ou", "viseme_ou", "viseme_u", "ou", "u", "fcl_mth_u"),
}
# The ARKit shape that carries each viseme's look when no target exists.  The
# renderer blends a few more (see VISEME_RECIPES in web/avatar3d.js); this
# table only decides whether the approximation is worth reporting as usable.
VISEME_RECIPE_SHAPES = {
    "sil": (),
    "PP": ("mouthclose", "mouthpressleft"),
    "FF": ("mouthrolllower",),
    "TH": ("tongueout",),
    "DD": ("jawopen",),
    "kk": ("jawopen",),
    "CH": ("mouthfunnel",),
    "SS": ("mouthstretchleft",),
    "nn": ("jawopen",),
    "RR": ("mouthfunnel",),
    "aa": ("jawopen",),
    "E": ("mouthstretchleft", "jawopen"),
    "ih": ("mouthsmileleft", "jawopen"),
    "oh": ("mouthfunnel",),
    "ou": ("mouthpucker",),
}
BLINK_ALIASES = ("eyeblinkleft", "vrc.blink_left", "blink_l", "blink_left",
                 "blink", "fcl_eye_close", "fcl_eye_close_l")
ARKIT_52 = {
    "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft",
    "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft", "eyeBlinkRight",
    "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight",
    "eyeSquintRight", "eyeWideRight", "jawForward", "jawLeft", "jawRight",
    "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthRight",
    "mouthLeft", "mouthSmileLeft", "mouthSmileRight", "mouthFrownRight",
    "mouthFrownLeft", "mouthDimpleLeft", "mouthDimpleRight",
    "mouthStretchLeft", "mouthStretchRight", "mouthRollLower",
    "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthPressLeft",
    "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthUpperUpLeft", "mouthUpperUpRight", "browDownLeft", "browDownRight",
    "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff",
    "cheekSquintLeft", "cheekSquintRight", "noseSneerLeft", "noseSneerRight",
    "tongueOut",
}
# Extensions that need a decoder the renderer does not ship.
UNSUPPORTED_EXTENSIONS = {
    "KHR_draco_mesh_compression", "EXT_meshopt_compression",
    "KHR_texture_basisu",
}


class ModelError(ValueError):
    """The uploaded file is not a GLB the renderer can use."""


def is_3d(manifest) -> bool:
    return isinstance(manifest, dict) and manifest.get("renderer") == RUNTIME_KIND


# ---------------------------------------------------------------- inspection

def _read_glb_json(path):
    size = os.path.getsize(path)
    if size < 20:
        raise ModelError("file is too small to be a GLB")
    if size > MAX_MODEL_BYTES:
        raise ModelError(
            f"model is {size / 1e6:.0f} MB; the limit is {MAX_MODEL_BYTES // (1024 * 1024)} MB. "
            "Run scripts/prepare-3d-avatar.py to shrink textures and unused shape keys.")
    with open(path, "rb") as handle:
        magic, version, length = struct.unpack("<4sII", handle.read(12))
        if magic != b"glTF":
            raise ModelError("not a binary glTF (.glb) file")
        if version != 2:
            raise ModelError(f"unsupported glTF container version {version}")
        if length > size:
            raise ModelError("GLB header length exceeds the file size")
        chunk_length, chunk_type = struct.unpack("<II", handle.read(8))
        if chunk_type != 0x4E4F534A:            # 'JSON'
            raise ModelError("GLB is missing its JSON chunk")
        if chunk_length > 64 * 1024 * 1024 or chunk_length > length:
            raise ModelError("GLB JSON chunk is implausibly large")
        try:
            document = json.loads(handle.read(chunk_length).decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise ModelError(f"GLB JSON chunk is invalid: {error}") from error
    if not isinstance(document, dict):
        raise ModelError("GLB JSON chunk is not an object")
    return document, size


def inspect_glb(path) -> dict:
    """Validate the container and summarise what the renderer can drive."""
    document, size = _read_glb_json(path)
    asset = document.get("asset") or {}
    if str(asset.get("version", "")).split(".")[0] != "2":
        raise ModelError("only glTF 2.0 assets are supported")
    required = set(document.get("extensionsRequired") or [])
    blocked = sorted(required & UNSUPPORTED_EXTENSIONS)
    if blocked:
        raise ModelError(
            "model requires " + ", ".join(blocked)
            + "; export without mesh compression or Basis textures")
    for buffer in document.get("buffers") or []:
        uri = str(buffer.get("uri") or "")
        if uri and not uri.startswith("data:"):
            raise ModelError("model references an external buffer; export as a single .glb")
    for image in document.get("images") or []:
        uri = str(image.get("uri") or "")
        if uri and not uri.startswith("data:"):
            raise ModelError("model references an external texture; export as a single .glb")
    meshes = document.get("meshes") or []
    targets = set()
    morph_meshes = 0
    for mesh in meshes:
        names = ((mesh.get("extras") or {}).get("targetNames")) if isinstance(mesh, dict) else None
        primitives = mesh.get("primitives") or [] if isinstance(mesh, dict) else []
        has_targets = any(p.get("targets") for p in primitives if isinstance(p, dict))
        if not has_targets:
            continue
        morph_meshes += 1
        if isinstance(names, list):
            targets.update(str(name) for name in names)
        else:
            for primitive in primitives:
                extras = (primitive.get("extras") or {}) if isinstance(primitive, dict) else {}
                if isinstance(extras.get("targetNames"), list):
                    targets.update(str(name) for name in extras["targetNames"])
    nodes = document.get("nodes") or []
    joints = []
    for skin in document.get("skins") or []:
        for index in skin.get("joints") or []:
            if isinstance(index, int) and 0 <= index < len(nodes):
                joints.append(str(nodes[index].get("name") or f"joint{index}"))
    return {
        "bytes": size,
        "generator": str(asset.get("generator") or ""),
        "meshes": len(meshes),
        "morph_meshes": morph_meshes,
        "targets": sorted(targets),
        "joints": joints,
        "images": len(document.get("images") or []),
        "extensions": sorted(set(document.get("extensionsUsed") or [])),
        "animations": len(document.get("animations") or []),
    }


def viseme_coverage(target_names) -> dict:
    """Which OpenClam visemes the model expresses, and how."""
    lowered = {str(name).lower() for name in target_names}
    direct, recipe, missing = {}, [], []
    for viseme in VISEMES:
        match = next((alias for alias in VISEME_ALIASES[viseme] if alias in lowered), None)
        if match:
            direct[viseme] = match
        elif viseme == "sil" or any(shape in lowered for shape in VISEME_RECIPE_SHAPES[viseme]):
            recipe.append(viseme)
        else:
            missing.append(viseme)
    return {
        "direct": direct,
        "recipe": recipe,
        "missing": missing,
        "blink": any(alias in lowered for alias in BLINK_ALIASES),
        "arkit": sum(1 for name in ARKIT_52 if name.lower() in lowered),
    }


def _warnings(report, coverage):
    warnings = []
    if not report["targets"]:
        warnings.append(
            "no facial morph targets: the mouth cannot move; add viseme or ARKit shape keys")
    elif coverage["missing"]:
        warnings.append(
            "no target for viseme(s) " + ", ".join(coverage["missing"])
            + "; those sounds will fall back to the nearest available shape")
    elif not coverage["direct"]:
        warnings.append(
            "no dedicated viseme targets; lips are approximated from ARKit shapes")
    if not coverage["blink"]:
        warnings.append("no blink target; the eyes will stay open")
    if not report["joints"]:
        warnings.append("no skeleton; the head cannot follow the cursor")
    if report["bytes"] > 96 * 1024 * 1024:
        warnings.append(
            f"model is {report['bytes'] / 1e6:.0f} MB; loading will be slow on first activation")
    return warnings


# ---------------------------------------------------------------- registry

def _registry():
    from studio import build
    return build


def _clean_name(value, fallback="3D Avatar"):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value or "")).strip()[:120]
    return text or fallback


def _placeholder_keyframe(path, name):
    """A card face until the renderer posts its first real snapshot."""
    from PIL import Image, ImageDraw
    size = 1024
    image = Image.new("RGB", (size, size), (27, 29, 36))
    draw = ImageDraw.Draw(image)
    draw.ellipse((size * .3, size * .18, size * .7, size * .58), fill=(58, 63, 78))
    draw.rounded_rectangle((size * .2, size * .62, size * .8, size * .98),
                           radius=int(size * .08), fill=(58, 63, 78))
    initials = "".join(part[0] for part in name.split()[:2] if part).upper() or "3D"
    box = draw.textbbox((0, 0), initials)
    draw.text(((size - box[2]) / 2, size * .36 - box[3] / 2), initials,
              fill=(226, 228, 236))
    image.save(path, "PNG")
    os.chmod(path, 0o600)


def runtime_manifest(source, *, thumbnail_pending=False):
    """The bundle manifest the page loads from ``assets/manifest.json``."""
    return {
        "v": RUNTIME_VERSION,
        "renderer": RUNTIME_KIND,
        "w": int(source.get("render_width") or RENDER_WIDTH),
        "h": int(source.get("render_height") or RENDER_HEIGHT),
        "avatar": {"slug": source["slug"], "name": source.get("name") or source["slug"]},
        "model": f"assets/{MODEL_NAME}",
        "model_bytes": int(source.get("model_bytes") or 0),
        "visemes": list(VISEMES),
        "frames": {},
        "viseme_coverage": source.get("viseme_coverage") or {},
        "pose": source.get("pose") or "relaxed",
        "yaw": float(source.get("yaw") or 0.0),
        "source_medium": "3d render",
        "thumbnail_pending": bool(thumbnail_pending),
        "built": datetime.datetime.now().isoformat(timespec="seconds"),
    }


def file_revision(path):
    stat = os.stat(path)
    return f"{stat.st_mtime_ns:x}-{stat.st_size:x}"


def served_manifest(path):
    """Identify the actual model on disk without hashing a large GLB per GET."""
    with open(path) as handle:
        manifest = json.load(handle)
    if not is_3d(manifest):
        return None
    manifest["model_revision"] = file_revision(os.path.join(os.path.dirname(path), MODEL_NAME))
    return manifest


def publish_runtime(slug, log=print):
    """(Re)write the runtime bundle atomically from the source model."""
    registry = _registry()
    source = registry.read_manifest(slug)
    if not is_3d(source):
        raise ValueError("not a 3D avatar")
    directory = registry.adir(slug)
    model = os.path.join(directory, MODEL_NAME)
    if not os.path.isfile(model):
        raise ValueError("3D avatar source model is missing")
    live = os.path.join(directory, "runtime")
    pending = not bool(source.get("thumbnail_ready"))
    staged = tempfile.mkdtemp(prefix=".runtime-stage-", dir=directory)
    try:
        target = os.path.join(staged, MODEL_NAME)
        try:
            os.link(model, target)
        except OSError:
            shutil.copyfile(model, target)
        with open(os.path.join(staged, "manifest.json"), "w") as handle:
            manifest = runtime_manifest(source, thumbnail_pending=pending)
            manifest["source_revision"] = file_revision(model)
            json.dump(manifest, handle, indent=1)
        previous = live + ".previous"
        shutil.rmtree(previous, ignore_errors=True)
        if os.path.exists(live):
            os.replace(live, previous)
        os.replace(staged, live)
        staged = None
        shutil.rmtree(previous, ignore_errors=True)
        log(f"published 3D runtime for {slug}")
    finally:
        if staged and os.path.exists(staged):
            shutil.rmtree(staged, ignore_errors=True)
    return live


def ensure_runtime(slug, log=print):
    """Return the runtime directory, publishing it when absent or stale."""
    registry = _registry()
    live = os.path.join(registry.adir(slug), "runtime")
    manifest_path = os.path.join(live, "manifest.json")
    try:
        with open(manifest_path) as handle:
            manifest = json.load(handle)
        current = (
            is_3d(manifest)
            and int(manifest.get("v") or 0) >= RUNTIME_VERSION
            and os.path.isfile(os.path.join(live, MODEL_NAME))
            and manifest.get("source_revision") == file_revision(os.path.join(registry.adir(slug), MODEL_NAME))
        )
    except (OSError, ValueError):
        current = False
    if current:
        return live
    return publish_runtime(slug, log=log)


def create_avatar(model_path, name=None, *, original_name="", log=print):
    """Register an uploaded GLB and publish its runtime immediately.

    Unlike portraits there is nothing to generate: the model already carries
    its mouth shapes, so a 3D avatar is ``ready`` the moment it is validated.
    """
    registry = _registry()
    report = inspect_glb(model_path)
    coverage = viseme_coverage(report["targets"])
    if not report["targets"] and not report["joints"]:
        raise ModelError("model has neither morph targets nor a skeleton; nothing can animate")
    name = _clean_name(
        name or os.path.splitext(os.path.basename(original_name or model_path))[0])
    slug, directory = registry._reserve_avatar_directory(registry.slugify(name))
    try:
        destination = os.path.join(directory, MODEL_NAME)
        shutil.copyfile(model_path, destination)
        os.chmod(destination, 0o600)
        _placeholder_keyframe(os.path.join(directory, "keyframe.png"), name)
        manifest = {
            "slug": slug,
            "name": name,
            "renderer": RUNTIME_KIND,
            "created": datetime.datetime.now().isoformat(timespec="seconds"),
            "status": "ready",
            "model": MODEL_NAME,
            "model_bytes": report["bytes"],
            "model_report": {
                key: report[key] for key in (
                    "generator", "meshes", "morph_meshes", "images", "extensions",
                    "animations")
            },
            "target_count": len(report["targets"]),
            "joint_count": len(report["joints"]),
            "viseme_coverage": coverage,
            "warnings": _warnings(report, coverage),
            "source_medium_override": "3d render",
            "progress": {"done": len(VISEMES), "total": len(VISEMES)},
            "visemes": list(VISEMES),
            "thumbnail_ready": False,
            "pose": "relaxed",
            "yaw": 0.0,
        }
        registry.write_manifest(slug, manifest)
        publish_runtime(slug, log=log)
        return registry.read_manifest(slug)
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise


def set_thumbnail(slug, png_bytes, layout=None):
    """Store the renderer's first face snapshot as the card keyframe.

    ``layout`` is the renderer's projected figure and face rectangles in its
    logical portrait, kept for the iPhone export's framing metadata.
    """
    from PIL import Image
    import io
    registry = _registry()
    manifest = registry.read_manifest(slug)
    if not is_3d(manifest):
        raise ValueError("not a 3D avatar")
    if not png_bytes or len(png_bytes) > MAX_THUMBNAIL_BYTES:
        raise ValueError("thumbnail is missing or larger than 4 MB")
    try:
        with Image.open(io.BytesIO(png_bytes)) as image:
            image.verify()
    except Exception as error:
        raise ValueError("thumbnail is not a readable PNG") from error
    with Image.open(io.BytesIO(png_bytes)) as image:
        if image.format != "PNG":
            raise ValueError("thumbnail must be a PNG")
        width, height = image.size
        if not (64 <= width <= 2048 and 64 <= height <= 2048):
            raise ValueError("thumbnail must be between 64 and 2048 px")
        rgb = image.convert("RGB")
        directory = registry.adir(slug)
        temporary = os.path.join(directory, ".keyframe.tmp.png")
        rgb.save(temporary, "PNG")
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(directory, "keyframe.png"))
    for entry in os.listdir(directory):
        if entry.startswith("thumb-") and entry.endswith(".jpg"):
            try:
                os.remove(os.path.join(directory, entry))
            except OSError:
                pass
    manifest["thumbnail_ready"] = True
    if isinstance(layout, dict):
        clean = {}
        for key in ("bounds", "faceBounds"):
            try:
                values = [float(v) for v in layout.get(key) or []]
            except (TypeError, ValueError):
                values = []
            if len(values) == 4 and all(math.isfinite(v) for v in values) \
                    and values[2] > 0 and values[3] > 0:
                clean[key] = values
        if clean:
            manifest["layout"] = clean
    registry.write_manifest(slug, manifest)
    runtime_path = os.path.join(directory, "runtime", "manifest.json")
    try:
        with open(runtime_path) as handle:
            runtime = json.load(handle)
        runtime["thumbnail_pending"] = False
        temporary = runtime_path + ".tmp"
        with open(temporary, "w") as handle:
            json.dump(runtime, handle, indent=1)
        os.replace(temporary, runtime_path)
    except (OSError, ValueError):
        pass
    return manifest


# ---------------------------------------------------------------- iPhone export

IOS_VARIANT = "ios-3d"
IOS_VERSION = 5
IOS_MAX_MODEL_BYTES = 64 * 1024 * 1024
IOS_MAX_ARCHIVE_BYTES = 80 * 1024 * 1024
IOS_THUMBNAIL_SIZE = 512
DEFAULT_LAYOUT = {
    "bounds": [0.0, 0.0, float(RENDER_WIDTH), float(RENDER_HEIGHT)],
    "faceBounds": [RENDER_WIDTH * .3, RENDER_HEIGHT * .04,
                   RENDER_WIDTH * .4, RENDER_HEIGHT * .16],
}


def _glb_parts(path):
    with open(path, "rb") as handle:
        magic, version, length = struct.unpack("<4sII", handle.read(12))
        if magic != b"glTF" or version != 2:
            raise ModelError("not a glTF 2.0 binary")
        json_length, json_type = struct.unpack("<II", handle.read(8))
        if json_type != 0x4E4F534A:
            raise ModelError("GLB is missing its JSON chunk")
        document = json.loads(handle.read(json_length).decode("utf-8"))
        binary = b""
        if handle.tell() < length:
            bin_length, bin_type = struct.unpack("<II", handle.read(8))
            if bin_type != 0x004E4942:
                raise ModelError("GLB has an unexpected second chunk")
            binary = handle.read(bin_length)
    return document, binary


def _write_glb(path, document, binary):
    payload = json.dumps(document, separators=(",", ":")).encode("utf-8")
    payload += b" " * (-len(payload) % 4)
    binary = bytes(binary) + b"\0" * (-len(binary) % 4)
    body = struct.pack("<II", len(payload), 0x4E4F534A) + payload
    body += struct.pack("<II", len(binary), 0x004E4942) + binary
    with open(path, "wb") as handle:
        handle.write(struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body)


def transcode_textures_for_ios(source, destination, *, jpeg_quality=88):
    """Rewrite WebP textures as PNG/JPEG so Apple's glTF loaders decode them.

    The desktop renderer reads ``EXT_texture_webp``; the iPhone path goes
    through GLTFKit2 and ImageIO, which ignore that extension. Every image
    keeps its slot, textures point at plain ``source`` entries, and the binary
    buffer is repacked so no stale WebP bytes ride along.
    """
    import io
    from PIL import Image
    document, binary = _glb_parts(source)
    views = document.get("bufferViews") or []
    images = document.get("images") or []
    replacements = {}
    for index, image in enumerate(images):
        if "bufferView" not in image:
            continue
        if str(image.get("mimeType") or "").lower() != "image/webp":
            continue
        view = views[image["bufferView"]]
        start = int(view.get("byteOffset", 0))
        raw = binary[start:start + int(view["byteLength"])]
        with Image.open(io.BytesIO(raw)) as decoded:
            has_alpha = decoded.mode in ("RGBA", "LA") or "transparency" in decoded.info
            out = io.BytesIO()
            if has_alpha:
                decoded.convert("RGBA").save(out, "PNG", optimize=True)
                mime = "image/png"
            else:
                decoded.convert("RGB").save(out, "JPEG", quality=jpeg_quality, optimize=True)
                mime = "image/jpeg"
        replacements[image["bufferView"]] = out.getvalue()
        image["mimeType"] = mime
    for texture in document.get("textures") or []:
        extensions = texture.get("extensions") or {}
        webp = extensions.pop("EXT_texture_webp", None)
        if webp and "source" in webp:
            texture["source"] = webp["source"]
        if not extensions:
            texture.pop("extensions", None)
    for key in ("extensionsUsed", "extensionsRequired"):
        if key in document:
            document[key] = [e for e in document[key] if e != "EXT_texture_webp"]
            if not document[key]:
                del document[key]
    repacked = bytearray()
    for index, view in enumerate(views):
        data = replacements.get(index)
        if data is None:
            start = int(view.get("byteOffset", 0))
            data = binary[start:start + int(view["byteLength"])]
        repacked += b"\0" * (-len(repacked) % 4)
        view["byteOffset"] = len(repacked)
        view["byteLength"] = len(data)
        repacked += data
    if document.get("buffers"):
        document["buffers"][0]["byteLength"] = len(repacked)
        document["buffers"][0].pop("uri", None)
    _write_glb(destination, document, bytes(repacked))
    return {"transcoded": len(replacements), "bytes": os.path.getsize(destination)}


def _layout(source):
    layout = source.get("layout") if isinstance(source.get("layout"), dict) else {}
    def box(value, fallback):
        try:
            values = [float(v) for v in value]
            if len(values) == 4 and values[2] > 0 and values[3] > 0:
                return values
        except (TypeError, ValueError):
            pass
        return list(fallback)
    return {
        "bounds": box(layout.get("bounds"), DEFAULT_LAYOUT["bounds"]),
        "faceBounds": box(layout.get("faceBounds"), DEFAULT_LAYOUT["faceBounds"]),
    }


def export_ios_3d(slug, destination, log=print):
    """Write one ``ios-3d`` AVTR: manifest, thumbnail and the transcoded model."""
    import hashlib
    import io
    import zipfile
    from PIL import Image
    import avatar_package as AVTR
    registry = _registry()
    source = registry.read_manifest(slug)
    if not is_3d(source):
        raise AVTR.AvatarPackageError("only 3D avatars export as ios-3d packages")
    directory = registry.adir(slug)
    model = os.path.join(directory, MODEL_NAME)
    if not os.path.isfile(model):
        raise AVTR.AvatarPackageError("the avatar's model file is missing")
    descriptor, transcoded = tempfile.mkstemp(suffix=".glb")
    os.close(descriptor)
    try:
        transcode_textures_for_ios(model, transcoded)
        model_bytes = os.path.getsize(transcoded)
        if model_bytes > IOS_MAX_MODEL_BYTES:
            raise AVTR.AvatarPackageError(
                f"the iPhone model would be {model_bytes / 1e6:.0f} MB; the limit is "
                f"{IOS_MAX_MODEL_BYTES // (1024 * 1024)} MB. Re-run prepare-3d-avatar.py "
                "with smaller textures")
        with open(transcoded, "rb") as handle:
            model_sha = hashlib.sha256(handle.read()).hexdigest()
        keyframe = os.path.join(directory, "keyframe.png")
        with Image.open(keyframe) as image:
            side = min(image.size)
            left = (image.width - side) // 2
            crop = image.convert("RGB").crop((left, 0, left + side, side))
            crop = crop.resize((IOS_THUMBNAIL_SIZE, IOS_THUMBNAIL_SIZE), Image.LANCZOS)
            thumb = io.BytesIO()
            crop.save(thumb, "PNG", optimize=True)
            thumbnail = thumb.getvalue()
        report = inspect_glb(model)
        coverage = viseme_coverage(report["targets"])
        layout = _layout(source)
        bounds, face = layout["bounds"], layout["faceBounds"]
        identifier = AVTR._safe_identifier(slug)
        display_name = AVTR._safe_display_name(str(source.get("name") or slug))
        manifest = {
            "format": AVTR.FORMAT if hasattr(AVTR, "FORMAT") else "openclam-avatar",
            "version": IOS_VERSION,
            "variant": IOS_VARIANT,
            "id": identifier,
            "displayName": display_name,
            "sourceMedium": "3d render",
            "model": {
                "path": f"assets/{MODEL_NAME}",
                "sha256": model_sha,
                "byteCount": model_bytes,
                "mediaType": "model/gltf-binary",
                "frame": {"width": int(source.get("render_width") or RENDER_WIDTH),
                          "height": int(source.get("render_height") or RENDER_HEIGHT)},
                "bounds": {"x": bounds[0], "y": bounds[1], "width": bounds[2], "height": bounds[3]},
                "faceBounds": {"x": face[0], "y": face[1], "width": face[2], "height": face[3]},
                "visemes": {
                    "direct": sorted(coverage["direct"]),
                    "approximated": [v for v in coverage["recipe"] if v != "sil"],
                    "missing": coverage["missing"],
                },
            },
            "assets": {
                "thumbnail": {
                    "path": "assets/thumbnail.png",
                    "sha256": hashlib.sha256(thumbnail).hexdigest(),
                    "byteCount": len(thumbnail),
                    "mediaType": "image/png",
                    "width": IOS_THUMBNAIL_SIZE,
                    "height": IOS_THUMBNAIL_SIZE,
                },
            },
        }
        manifest_bytes = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")
        temporary = str(destination) + ".partial"
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_STORED) as archive:
            AVTR._write_zip_bytes(archive, "manifest.json", manifest_bytes, zipfile.ZIP_STORED)
            AVTR._write_zip_bytes(archive, "assets/thumbnail.png", thumbnail, zipfile.ZIP_STORED)
            from pathlib import Path
            AVTR._write_zip_file(archive, Path(transcoded), f"assets/{MODEL_NAME}", zipfile.ZIP_STORED)
        if os.path.getsize(temporary) > IOS_MAX_ARCHIVE_BYTES:
            os.remove(temporary)
            raise AVTR.AvatarPackageError("the iPhone package exceeds 80 MB")
        os.replace(temporary, destination)
        log(f"exported {identifier} as {IOS_VARIANT} ({os.path.getsize(destination) / 1e6:.1f} MB)")
        return manifest
    finally:
        if os.path.exists(transcoded):
            os.unlink(transcoded)
