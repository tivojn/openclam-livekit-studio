"""Head and viseme rendering through OpenClam's direct image provider lane."""
import os, hashlib, shutil, tempfile, time
from concurrent.futures import ThreadPoolExecutor

import cv2
try:
    import media_gen
except ModuleNotFoundError:  # package-style test/import outside server/app.py
    from server import media_gen

from . import visemes

MAX_WORKERS = 4
RETRIES = 2
HEAD_PROMPT_VERSION = 3
HEAD_PROMPT = """Create an ultra-high-definition square identity head reference from the supplied photo.

IDENTITY — preserve the exact same adult person's facial identity, skull and facial proportions, skin tone and texture, apparent age, hairline, hairstyle, eyebrows, eye shape and color, nose, lips, ears, and distinctive natural features. Do not beautify, de-age, stylize, or redesign the person.

EYEWEAR — if the supplied photo shows the person wearing eyeglasses, those glasses are part of their identity. Keep the exact same pair on the face: same frame shape, rim style, frame thickness, frame color and material, temple arms, lens shape and any lens tint, sitting at the same position on the nose and ears. Never remove them, never swap them for a different pair, and never render an unglassed version of this person. If the supplied photo shows no eyeglasses, do not add any.

FRAMING — show only the complete head and hair, centered and fully visible, with at most a very small neutral upper-neck transition below the jaw. No shoulders, collarbones, chest, torso, arms, or hands. No clothing of any kind, jewelry, earrings, hats, headwear, headphones, other accessories, props, or text anywhere in the image — eyeglasses already worn in the supplied photo are the single exception and must be kept exactly as described above. Do not crop the hair, chin, jaw, or ears.

POSE — face the camera straight on with an upright head, eyes naturally open, and a neutral closed mouth. Preserve realistic asymmetry. Use even soft studio light and a plain neutral background with clean separation around every hair edge.

This is a reusable identity asset for facial animation and later full-body image editing, not a fashion portrait or profile photograph."""


def _file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def default_head_provider():
    from . import body
    return body.default_provider()


def generate_head(reference, destination, provider=None, quality="high",
                  timeout=1800, log=print, overwrite=False, pose_note="",
                  keep=""):
    """Create and cache the canonical head-only identity asset used downstream.

    pose_note carries a measured correction ("previous attempt: yaw -9.1deg
    ...") appended to the prompt when a frontality retry runs - tilted
    source selfies (rachel, 2026-08-01: pitch 23, roll 18, foreshortening
    0.56) otherwise keep their tilt and degrade every mouth stage after."""
    from . import body
    provider_config, selected = body.image_provider_selection()
    if provider and (provider.get("name"), provider.get("model")) != \
            (selected.get("name"), selected.get("model")):
        raise RuntimeError(
            "the OpenClam image provider changed during this avatar build; retry it")
    provider = selected
    # keep carries the owner's add-on ("keep his bandana"). A head plate
    # normalises the face, and normalising quietly removed the very things
    # that made a character recognisable (owner, 2026-08-04). It joins the
    # signature below, so changing it correctly re-renders.
    prompt = HEAD_PROMPT + pose_note
    if keep:
        prompt += f"\nMUST KEEP from the source portrait: {keep}"

    signature = hashlib.sha256((
        f"v{HEAD_PROMPT_VERSION}\n{provider['name']}\n{provider.get('model')}\n"
        f"{quality}\n{prompt}\n" + _file_digest(reference)
    ).encode("utf-8")).hexdigest()
    signature_file = destination + ".prompt"
    if not overwrite and os.path.isfile(destination) and os.path.getsize(destination) > 4096:
        try:
            with open(signature_file) as handle:
                if handle.read().strip() == signature:
                    log("reusing canonical HD head")
                    return destination
        except OSError:
            pass

    os.makedirs(os.path.dirname(destination), exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".head-provider-", dir=os.path.dirname(destination))
    last_error = ""
    try:
        for attempt in range(1, RETRIES + 2):
            try:
                rendered = media_gen.generate_image_edit_sync(
                    prompt, [reference], provider_config,
                    aspect_ratio="1:1", quality=quality,
                    output_dir=stage, file_name="head")
            except Exception as error:
                last_error = str(error)
                rendered = None
            image = cv2.imread(rendered, cv2.IMREAD_COLOR) if rendered else None
            if image is not None and min(image.shape[:2]) >= 512:
                temporary = destination + ".tmp.png"
                if not cv2.imwrite(temporary, image, [cv2.IMWRITE_PNG_COMPRESSION, 3]):
                    raise RuntimeError("could not save the canonical HD head")
                os.replace(temporary, destination)
                with open(signature_file, "w") as handle:
                    handle.write(signature)
                log("canonical HD head ready")
                return destination
            log(f"  head: attempt {attempt} failed ({last_error[-220:] or 'no usable output image'})")
            time.sleep(2 * attempt)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    raise RuntimeError(
        "could not create the canonical HD head" +
        (f": {last_error[-500:]}" if last_error else ""))


def generate_one(keyframe, name, out_dir, yaw=None, roll=None,
                 model=None, quality="high", credentials=None,
                 timeout=1800, log=print, overwrite=False,
                 _provider_config=None, prompt_note=""):
    os.makedirs(out_dir, exist_ok=True)
    prompt = visemes.prompt_for(name, yaw, roll)
    if prompt_note:
        prompt += "\n\nQA CORRECTION FROM THE PREVIOUS ATTEMPT:\n" + str(prompt_note)
    if _provider_config is None:
        from . import body
        _provider_config, public = body.image_provider_selection()
        _provider_config = dict(_provider_config)
        _provider_config["model"] = (
            _provider_config.get("model") or public.get("model") or "")
    else:
        _provider_config = dict(_provider_config)
    if model:
        _provider_config["model"] = str(model)
    provider_receipt = "\n".join((
        str(_provider_config.get("provider") or ""),
        str(_provider_config.get("model") or ""),
        str(quality),
    ))
    sig = hashlib.sha1(
        (provider_receipt + "\n" + prompt + "\n" +
         _file_digest(keyframe)).encode("utf-8")
    ).hexdigest()[:12]
    sig_file = os.path.join(out_dir, f".{name}.prompt")

    # A cached render is only valid for the prompt that produced it.  Keying the
    # cache on filename alone let an edited prompt silently reuse a stale frame,
    # which is exactly how a calibration pass can appear to do nothing.
    if not overwrite:
        cached = None
        for ext in (".png", ".jpg", ".jpeg", ".webp"):
            q = os.path.join(out_dir, f"v_{name}{ext}")
            if os.path.exists(q) and os.path.getsize(q) > 4096:
                cached = q
                break
        if cached:
            have = ""
            if os.path.exists(sig_file):
                with open(sig_file) as fh:
                    have = fh.read().strip()
            if have == sig:
                log(f"  {name:7s} reusing existing render")
                return cached
            log(f"  {name:7s} prompt changed - re-rendering")
    last = ""
    for attempt in range(1, RETRIES + 2):
        try:
            rendered = media_gen.generate_image_edit_sync(
                prompt, [keyframe], _provider_config,
                aspect_ratio="1:1", quality=quality,
                output_dir=out_dir, file_name=f"v_{name}")
        except Exception as ex:
            last = f"{type(ex).__name__}: {ex}"
            rendered = None
        if rendered and os.path.isfile(rendered) and os.path.getsize(rendered) > 4096:
            with open(sig_file, "w") as fh:
                fh.write(sig)
            return rendered
        log(f"  {name}: attempt {attempt} failed ({last.strip()[-220:] or 'no output file'})")
        time.sleep(2 * attempt)
    return None


def generate_set(keyframe, out_dir, yaw=None, roll=None, names=None,
                 workers=MAX_WORKERS, log=print, on_done=None, **kw):
    names = names or visemes.ORDER
    os.makedirs(out_dir, exist_ok=True)
    results = {}
    from . import body
    provider_config, public = body.image_provider_selection()
    provider_config = dict(provider_config)
    provider_config["model"] = (
        provider_config.get("model") or public.get("model") or "")

    def task(n):
        t0 = time.time()
        p = generate_one(
            keyframe, n, out_dir, yaw, roll, log=log,
            _provider_config=provider_config, **kw)
        log(f"  {n:7s} {'rendered' if p else 'FAILED  '} in {time.time()-t0:5.1f}s")
        results[n] = p
        if on_done:
            on_done(n, p)
        return p

    with ThreadPoolExecutor(max_workers=workers) as ex:
        list(ex.map(task, names))
    return results
