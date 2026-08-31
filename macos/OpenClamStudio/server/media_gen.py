"""Direct, standalone media and prompt generation for OpenClam Studio.

The caller supplies a lane from OpenClam's local configuration. Secrets are
materialised by ``providers.load()`` from macOS Keychain and are held only for
the duration of the provider request.  This module deliberately has no managed
provider, companion-app, preference-file, or local gateway fallback.
"""
from __future__ import annotations

import asyncio
import base64
import json
import math
import mimetypes
import os
import re
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

import httpx


OUT_DIR = os.path.abspath(os.path.expanduser(os.environ.get(
    "OPENCLAM_DOWNLOADS_DIR", "~/Downloads/OpenClam Studio")))

IMAGE_PROVIDERS = frozenset({
    "openai", "gemini", "xai", "stability", "bfl",
    "together_image", "recraft",
})
IMAGE_EDIT_PROVIDERS = frozenset({"openai", "gemini", "xai"})
VIDEO_PROVIDERS = frozenset({"openai", "gemini", "xai", "luma", "runway"})
# The avatar motion contract is tested against xAI's documented image-to-video
# REST shape. Other video lanes remain available for ordinary text-to-video,
# but are not silently used for identity-sensitive avatar animation.
AVATAR_VIDEO_PROVIDERS = frozenset({"xai"})
TEXT_PROVIDERS = frozenset({
    "openai", "xai", "gemini", "anthropic", "openrouter", "ollama",
})
VISION_TEXT_PROVIDERS = frozenset({
    "openai", "xai", "gemini", "anthropic", "openrouter",
})

# Exact, reviewed image-model IDs.  Do not accept a family prefix here: a
# similarly named chat, video, retired, or future model may have a different
# endpoint contract.  The two older xAI IDs remain explicit compatibility
# choices; 2.0 is the current Imagine image generation/editing model.
OPENAI_IMAGE_MODELS = frozenset({
    "gpt-image-2",
    "gpt-image-1",  # explicit saved-config compatibility; never a new default
})
XAI_IMAGE_MODELS = frozenset({
    "grok-imagine-image-2.0",
    "grok-imagine-image",
    "grok-imagine-image-quality",
})
IMAGE_MODEL_ALLOWLISTS = {
    "openai": OPENAI_IMAGE_MODELS,
    "xai": XAI_IMAGE_MODELS,
}

_IMAGE_REQUEST_TIMEOUT = 300
_IMAGE_DOWNLOAD_TIMEOUT = 120
_MAX_IMAGE_INPUT_BYTES = 20 * 1024 * 1024
_MAX_IMAGE_OUTPUT_BYTES = 64 * 1024 * 1024
_MAX_IMAGE_PROMPT_CHARS = 32_000
_MAX_PROVIDER_ERROR_BYTES = 64 * 1024
# Imagine 2.0 rejects oversized prompts before generation.  Full-body briefs
# are assembled from user/model text plus deterministic identity and rig rules,
# so enforce the observed 8 KiB compatibility ceiling locally and count bytes,
# not characters (CJK and emoji occupy more than one UTF-8 byte).
_IMAGE_PROMPT_BYTE_LIMITS = {
    ("xai", "grok-imagine-image-2.0"): 8 * 1024,
}
_MAX_VIDEO_PROMPT_CHARS = 32_000
# xAI rejects an oversized Imagine Video prompt as a bare HTTP 400 before it
# creates a request id.  Motion briefs include deterministic identity and
# plate contracts, so enforce the service-compatible UTF-8 budget locally.
_XAI_VIDEO_PROMPT_MAX_BYTES = 4_096
_MAX_VIDEO_INPUT_BYTES = 50 * 1024 * 1024
_MAX_VIDEO_OUTPUT_BYTES = 512 * 1024 * 1024
_OPENAI_IMAGE_QUALITIES = frozenset({"auto", "low", "medium", "high"})
_XAI_IMAGE_2_QUALITIES = frozenset({"low", "medium"})
_XAI_IMAGE_RESOLUTIONS = frozenset({"1k", "2k"})
_XAI_IMAGE_ASPECT_RATIOS = frozenset({
    "auto", "1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3",
    "2:1", "1:2", "19.5:9", "9:19.5", "20:9", "9:20",
})
_XAI_IMAGE_DOWNLOAD_HOSTS = frozenset({"imgen.x.ai"})
_XAI_VIDEO_DOWNLOAD_HOSTS = frozenset({"vidgen.x.ai"})
_XAI_OAUTH_ALIAS_LOCK = threading.RLock()
_BFL_POLL_ORIGINS = frozenset({
    "https://api.bfl.ai",
    "https://api.eu.bfl.ai",
    "https://api.us.bfl.ai",
})

_BASES = {
    ("llm", "openai"): "https://api.openai.com/v1",
    ("llm", "xai"): "https://api.x.ai/v1",
    ("llm", "gemini"): "https://generativelanguage.googleapis.com/v1beta",
    ("llm", "anthropic"): "https://api.anthropic.com/v1",
    ("llm", "openrouter"): "https://openrouter.ai/api/v1",
    ("llm", "ollama"): "http://127.0.0.1:11434",
    ("image", "openai"): "https://api.openai.com/v1",
    ("image", "xai"): "https://api.x.ai/v1",
    ("image", "gemini"): "https://generativelanguage.googleapis.com/v1beta",
    ("image", "stability"): "https://api.stability.ai",
    ("image", "bfl"): "https://api.bfl.ai",
    ("image", "together_image"): "https://api.together.xyz/v1",
    ("image", "recraft"): "https://external.api.recraft.ai/v1",
    ("video", "openai"): "https://api.openai.com/v1",
    ("video", "xai"): "https://api.x.ai/v1",
    ("video", "gemini"): "https://generativelanguage.googleapis.com/v1beta",
    ("video", "luma"): "https://api.lumalabs.ai/dream-machine/v1",
    ("video", "runway"): "https://api.dev.runwayml.com/v1",
}

_FALLBACK_MODELS = {
    ("llm", "openai"): "gpt-5-mini",
    ("llm", "xai"): "grok-4.6",
    ("llm", "gemini"): "gemini-2.5-flash",
    ("llm", "anthropic"): "claude-sonnet-5",
    ("llm", "openrouter"): "openai/gpt-5-mini",
    # Provider-scoped image fallbacks apply only after the user explicitly
    # selects that provider.  A missing provider remains fail-closed.
    ("image", "openai"): "gpt-image-2",
    ("image", "xai"): "grok-imagine-image-2.0",
    ("image", "gemini"): "gemini-3.1-flash-image",
    ("video", "openai"): "sora-2",
    ("video", "xai"): "grok-imagine-video",
    ("video", "gemini"): "veo-3.1-fast-generate-001",
}


def _providers():
    """Import lazily so studio-only tests can replace the provider helper."""
    try:
        import providers
    except ModuleNotFoundError:
        server_dir = os.path.dirname(os.path.abspath(__file__))
        if server_dir not in sys.path:
            sys.path.insert(0, server_dir)
        import providers
    return providers


def _xai_oauth_manager():
    # ``app.py`` can run either as ``server.app`` or from the server directory.
    # Reuse whichever OAuth module the app loaded first so its process-only
    # development credential is never split across ``xai_oauth`` and
    # ``server.xai_oauth`` module instances.
    with _XAI_OAUTH_ALIAS_LOCK:
        top_level = sys.modules.get("xai_oauth")
        packaged = sys.modules.get("server.xai_oauth")
        loaded = [value for value in (top_level, packaged) if value is not None]
        if any(bool(getattr(getattr(value, "__spec__", None),
                            "_initializing", False)) for value in loaded):
            # Never expose or overwrite a partially initialized module. A
            # subsequent request can retry after Python finishes the import.
            raise RuntimeError("xai_oauth_import_in_progress")
        manager = top_level or packaged
        if manager is None:
            try:
                from . import xai_oauth as manager
            except (ImportError, ValueError):
                import xai_oauth as manager
        # Assignment (rather than setdefault) repairs a process where both
        # import spellings were already loaded as distinct module objects.
        sys.modules["xai_oauth"] = manager
        sys.modules["server.xai_oauth"] = manager
        parent = sys.modules.get("server")
        if parent is not None:
            # ``from server import xai_oauth`` consults the package attribute,
            # which can otherwise retain the duplicate module even after the
            # two sys.modules aliases have been repaired.
            setattr(parent, "xai_oauth", manager)
        return manager


def _openai_account_manager():
    try:
        from . import openai_account
    except (ImportError, ValueError):
        import openai_account
    return openai_account


def _openai_uses_chatgpt():
    manager = _openai_account_manager()
    return manager.auth_mode() == manager.CHATGPT_MODE


async def _xai_api_auth():
    """Resolve exactly the globally selected xAI mode, with no fallback."""
    manager = _xai_oauth_manager()
    resolved = await manager.resolve_auth()
    return (manager.XAI_API_BASE,
            resolved.headers(manager.API_TARGET),
            resolved.bearer_token,
            resolved.mode)


def _safe_error(value, secret=""):
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if secret:
        text = text.replace(secret, "[redacted]")
    text = re.sub(
        r"(?i)(authorization|api[_ -]?key|(?:access|refresh|id)[_ -]?token|token)"
        r"\s*[\"']?\s*[:=]\s*[\"']?\s*(?:bearer\s+)?[^\s,;}\"']+",
        r"\1=[redacted]", text)
    text = re.sub(r"(?i)([?&]key=)[^&\s]+", r"\1[redacted]", text)
    text = re.sub(
        r"\b(?:sk|gsk)[-_][A-Za-z0-9_-]{8,}\b|"
        r"\bxai[-_](?!oauth(?:_|-))[A-Za-z0-9_-]{8,}\b",
        "[redacted]", text)
    return text[:700]


def _http_failure(provider, response, secret=""):
    status = getattr(response, "status_code", "?")
    try:
        detail = response.text
    except Exception:
        detail = ""
    detail = _safe_error(detail, secret)
    label = provider.replace("_", " ").title()
    if status in (401, 403):
        # xAI can arrive here through either the explicitly selected API-key
        # session or the shared OAuth session.  Never misdiagnose an OAuth
        # reconnect as a bad API key.
        reason = ("authentication was rejected" if provider == "xai"
                  else "the API key was rejected")
    elif status == 429:
        reason = "the account is being rate-limited"
    elif status == 404:
        reason = "the configured model or endpoint was not found"
    else:
        reason = detail or "the provider refused the request"
    return RuntimeError(f"{label}: {reason} (HTTP {status})")


def _require_no_redirect(provider, response, secret="", max_bytes=0):
    status = int(getattr(response, "status_code", 0) or 0)
    if 300 <= status < 400:
        raise RuntimeError(
            f"{provider.replace('_', ' ').title()}: the provider tried to "
            "redirect a protected media request")
    if status < 200 or status >= 300:
        raise _http_failure(provider, response, secret)
    if max_bytes:
        headers = getattr(response, "headers", {}) or {}
        length = str(headers.get("content-length") or "")
        try:
            content = response.content or b""
        except Exception:
            content = b""
        if ((length.isdigit() and int(length) > max_bytes)
                or (isinstance(content, (bytes, bytearray))
                    and len(content) > max_bytes)):
            raise RuntimeError(
                f"{provider.replace('_', ' ').title()}: the provider returned "
                "an oversized response")


async def _bounded_media_request(client, method, url, *, provider,
                                 max_bytes, secret="", **kwargs):
    """Read provider data incrementally; never buffer beyond the lane cap."""
    stream = getattr(client, "stream", None)
    if callable(stream):
        async with stream(method, url, **kwargs) as upstream:
            status = int(upstream.status_code)
            if status < 200 or status >= 400:
                # A streamed Response has no .text until its body is read.
                # Raising first silently discarded every provider diagnostic,
                # including xAI's explanation of a rejected video request.
                # Read only a small bounded error body, never response headers.
                # Discard oversized diagnostics entirely: a truncated secret
                # could otherwise evade exact-value redaction.
                limit = (min(max_bytes, _MAX_PROVIDER_ERROR_BYTES)
                         if max_bytes else _MAX_PROVIDER_ERROR_BYTES)
                length = str(upstream.headers.get("content-length") or "")
                oversized = RuntimeError(
                    f"{provider.replace('_', ' ').title()}: the provider returned "
                    f"an oversized error response (HTTP {status})")
                if length.isdigit() and int(length) > limit:
                    raise oversized
                error_data = bytearray()
                async for chunk in upstream.aiter_bytes():
                    if len(chunk) > limit - len(error_data):
                        raise oversized
                    error_data.extend(chunk)
                raise _http_failure(
                    provider, httpx.Response(status, content=bytes(error_data)), secret)
            _require_no_redirect(provider, upstream, secret, max_bytes)
            data = bytearray()
            async for chunk in upstream.aiter_bytes():
                if len(chunk) > max_bytes - len(data):
                    raise RuntimeError(
                        f"{provider.replace('_', ' ').title()}: the provider "
                        "returned an oversized response")
                data.extend(chunk)
            # ``aiter_bytes`` has already decoded Content-Encoding. Carrying
            # the upstream gzip/deflate header into a new Response makes
            # httpx decode the JSON a second time. Length/transfer headers
            # also describe the wire representation, not these decoded bytes.
            decoded_headers = {
                str(name): str(value)
                for name, value in upstream.headers.items()
                if str(name).lower() not in {
                    "content-encoding", "content-length", "transfer-encoding"
                }
            }
            return httpx.Response(
                upstream.status_code, headers=decoded_headers, content=bytes(data))
    # Unit-test clients intentionally expose only verb methods. Runtime httpx
    # always takes the bounded streaming branch.
    sender = getattr(client, method.lower())
    response = await sender(url, **kwargs)
    _require_no_redirect(provider, response, secret, max_bytes)
    return response


def _require_api_key_auth(provider, config):
    """Reject lane-local OAuth/token material before global auth resolution."""
    declared = []
    for field in ("auth_method", "credential_type"):
        value = config.get(field)
        if value not in (None, ""):
            declared.append(str(value).strip().lower())
    auth = config.get("auth")
    if isinstance(auth, dict):
        for field in ("selected_method", "method", "credential_type", "type"):
            value = auth.get(field)
            if value not in (None, ""):
                declared.append(str(value).strip().lower())
    elif auth not in (None, ""):
        declared.append(str(auth).strip().lower())
    def token_shaped_field(name):
        field = re.sub(r"[^a-z0-9]", "", str(name or "").lower())
        return (
            "oauth" in field or "accesstoken" in field
            or "refreshtoken" in field or field == "token"
            or field.endswith("token")
            or field in {
                "auth", "bearer", "authorization", "authorizationheader",
                "authorizationcode", "clientid", "clientsecret",
                "codeverifier", "redirecturi", "scope", "scopes",
                "tokenendpoint", "authorizationendpoint",
            })

    def contains_token_field(value, root=False):
        if isinstance(value, dict):
            for name, child in value.items():
                if root and str(name) in {
                        "api_key", "auth_method", "credential_type"}:
                    continue
                if token_shaped_field(name) or contains_token_field(child):
                    return True
        elif isinstance(value, list):
            return any(contains_token_field(child) for child in value)
        return False

    if (any(method != "api_key" for method in declared)
            or contains_token_field(config, root=True)):
        label = provider.replace("_", " ").title()
        if provider in {"xai", "openai"}:
            raise RuntimeError(
                f"{provider} authentication is selected globally; remove lane OAuth or "
                "token fields and choose the shared account mode in Settings")
        raise RuntimeError(
            f"{label} image inference supports API-key authentication only")


def _require_lane(kind, config, allowed):
    if not isinstance(config, dict):
        raise RuntimeError(f"OpenClam {kind} settings are missing")
    provider = str(config.get("provider") or "").strip()
    helper = _providers()
    spec = helper.spec(kind, provider) or {}
    if not provider or spec.get("managed"):
        raise RuntimeError(
            f"Choose a direct {kind} provider in OpenClam Settings before continuing")
    if provider not in allowed:
        choices = ", ".join(sorted(allowed))
        raise RuntimeError(
            f"{spec.get('label') or provider} is not approved for this {kind} workflow; "
            f"choose one of: {choices}")
    if kind == "image" and provider in IMAGE_MODEL_ALLOWLISTS:
        _require_api_key_auth(provider, config)
    # xAI's credential comes only from xai_oauth.resolve_auth().  A legacy
    # lane key may still be present in memory after config migration, but is
    # deliberately ignored and can never choose or replace the global mode.
    globally_resolved = provider == "xai" or (
        kind == "image" and provider == "openai" and _openai_uses_chatgpt())
    key = "" if globally_resolved else str(config.get("api_key") or "").strip()
    if spec.get("key") and not globally_resolved and not key:
        raise RuntimeError(
            f"{spec.get('label') or provider} needs an API key in OpenClam Settings")
    return provider, key, spec


def selected_config(kind, allowed):
    """Return the selected Keychain-materialised lane and public metadata."""
    helper = _providers()
    config = dict((helper.load().get(kind) or {}))
    provider, _key, spec = _require_lane(kind, config, frozenset(allowed))
    model = _model(kind, provider, config)
    if kind == "image":
        _require_avatar_model(kind, provider, model)
    public = {
        "name": provider,
        "title": spec.get("label") or provider.replace("_", " ").title(),
        "model": model,
        "route": f"direct:{provider}",
        "direct": True,
    }
    return config, public


def _base(kind, provider, config):
    approved = _BASES[(kind, provider)]
    supplied = str(config.get("base_url") or "").strip().rstrip("/")
    if not supplied:
        return approved
    parsed = urlsplit(supplied)
    expected = urlsplit(approved)
    # Avatar media carries a person's likeness. Keep these calls on the
    # reviewed vendor origin instead of accepting an arbitrary relay URL.
    same_origin = (
        parsed.scheme == expected.scheme
        and parsed.hostname == expected.hostname
        and (parsed.port or (443 if parsed.scheme == "https" else 80))
        == (expected.port or (443 if expected.scheme == "https" else 80))
    )
    if provider == "ollama":
        same_origin = (
            parsed.scheme == "http"
            and parsed.hostname in {"127.0.0.1", "localhost"}
            and (parsed.port or 80) == 11434
            and parsed.path.rstrip("/") == "")
    elif supplied != approved:
        same_origin = False
    if not same_origin or parsed.username or parsed.password:
        raise RuntimeError(
            f"OpenClam's {provider} {kind} workflow only connects to its approved endpoint")
    return supplied


def _model(kind, provider, config):
    configured = str(config.get("model") or "").strip()
    if configured:
        return configured
    return _FALLBACK_MODELS.get((kind, provider), "")


def _require_avatar_model(kind, provider, model):
    allowed = IMAGE_MODEL_ALLOWLISTS.get(provider) if kind == "image" else None
    if allowed is not None:
        compatible = model in allowed
    elif kind == "video" and provider == "xai":
        compatible = model in {"grok-imagine-video", "grok-imagine-video-1.5"}
    else:
        families = {
            ("image", "gemini"): r"^gemini-.+-image(?:$|-)",
        }
        pattern = families.get((kind, provider))
        # Non-avatar generation providers have their own endpoint adapters;
        # this check only owns the explicitly reviewed avatar model lanes.
        compatible = bool(model) if pattern is None else bool(
            re.fullmatch(pattern, model, re.IGNORECASE))
    if not compatible:
        label = provider.replace("_", " ").title()
        raise RuntimeError(
            f"Choose a compatible {label} {kind} model in OpenClam Settings")


def _require_xai_video_model(mode, model):
    allowed = ({"grok-imagine-video-1.5", "grok-imagine-video"}
               if mode == "image_to_video" else {"grok-imagine-video"})
    if model not in allowed:
        if mode == "image_to_video":
            detail = "image-to-video model"
        elif mode == "edit":
            detail = "video-editing model (grok-imagine-video)"
        else:
            detail = "text-to-video model (grok-imagine-video)"
        raise RuntimeError(f"Choose the supported xAI {detail} in Settings")


def _out(prefix, suffix, output_dir=None, file_name=None):
    directory = os.path.abspath(output_dir or OUT_DIR)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(file_name or "")).strip(".-")
    name = safe_name or f"{prefix}-{int(time.time() * 1000)}"
    return os.path.join(directory, name + suffix)


def _write(prefix, suffix, data, output_dir=None, file_name=None):
    path = _out(prefix, suffix, output_dir, file_name)
    temporary = path + ".part"
    with open(temporary, "wb") as handle:
        handle.write(data)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return path


def _image_mime(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return ""


def _image_suffix(data, declared_mime=""):
    detected = _image_mime(data)
    if not detected:
        raise RuntimeError("the provider returned unsupported or invalid image bytes")
    declared = str(declared_mime or "").split(";", 1)[0].strip().lower()
    if declared and declared not in {"image/png", "image/jpeg", "image/webp"}:
        raise RuntimeError("the provider returned an unsupported image content type")
    if declared and declared != detected:
        raise RuntimeError("the provider returned image bytes with a mismatched content type")
    return {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}[detected]


def _read_image_input(path):
    target = os.path.abspath(os.fspath(path))
    try:
        size = os.path.getsize(target)
    except OSError as exc:
        raise RuntimeError("avatar image editing needs readable reference images") from exc
    if size <= 0 or size > _MAX_IMAGE_INPUT_BYTES:
        raise RuntimeError("each reference image must be between 1 byte and 20 MiB")
    with open(target, "rb") as handle:
        data = handle.read(_MAX_IMAGE_INPUT_BYTES + 1)
    if len(data) != size or len(data) > _MAX_IMAGE_INPUT_BYTES:
        raise RuntimeError("each reference image must be at most 20 MiB")
    mime = _image_mime(data)
    if not mime:
        raise RuntimeError("reference images must be PNG, JPEG, or WebP files")
    return Path(target).name, data, mime


def _mime(path):
    # Media adapters outside the image workflow still use extension-based MIME
    # discovery.  Image uploads use ``_read_image_input`` and content sniffing.
    return mimetypes.guess_type(os.fspath(path))[0] or "image/png"


def _data_uri(path):
    _name, data, mime = _read_image_input(path)
    encoded = base64.b64encode(data).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def _upload_part(path):
    return _read_image_input(path)


async def _download(url, prefix, suffix, headers=None, output_dir=None,
                    file_name=None):
    parsed = urlsplit(str(url or ""))
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.port not in (None, 443)):
        raise RuntimeError("the provider returned an unsafe download address")
    maximum = _MAX_IMAGE_OUTPUT_BYTES if prefix == "image" \
        else _MAX_VIDEO_OUTPUT_BYTES
    async with httpx.AsyncClient(
            timeout=_IMAGE_DOWNLOAD_TIMEOUT, follow_redirects=False,
            trust_env=False) as client:
        response = await _bounded_media_request(
            client, "GET", url, headers=headers or {}, provider="media download",
            max_bytes=maximum)
        data = response.content
        if len(data) < 4096:
            raise RuntimeError("the provider returned an unusably small media file")
        if prefix == "image":
            if len(data) > _MAX_IMAGE_OUTPUT_BYTES:
                raise RuntimeError("the provider returned an oversized image file")
            declared = str(
                (getattr(response, "headers", {}) or {}).get("content-type") or "")
            suffix = _image_suffix(data, declared)
        return _write(prefix, suffix, data, output_dir, file_name)


async def _download_xai_image(url, declared_mime="", output_dir=None,
                              file_name=None):
    parsed = urlsplit(str(url or ""))
    if (parsed.scheme != "https" or parsed.hostname not in _XAI_IMAGE_DOWNLOAD_HOSTS
            or parsed.username or parsed.password or parsed.port not in (None, 443)):
        raise RuntimeError("xAI returned an unapproved image download address")
    async with httpx.AsyncClient(
            timeout=_IMAGE_DOWNLOAD_TIMEOUT, follow_redirects=False,
            trust_env=False) as client:
        response = await _bounded_media_request(
            client, "GET", url,
            headers={"User-Agent": "OpenClam-Studio/1.0"},
            provider="xAI image download", max_bytes=_MAX_IMAGE_OUTPUT_BYTES)
        data = response.content
        if len(data) < 4096 or len(data) > _MAX_IMAGE_OUTPUT_BYTES:
            raise RuntimeError("xAI returned an unusable image file")
        response_mime = str(
            (getattr(response, "headers", {}) or {}).get("content-type") or "")
        suffix = _image_suffix(data, response_mime or declared_mime)
        return _write("image", suffix, data, output_dir, file_name)


def _bfl_poll_address(url):
    """Allow credentials only to BFL's three current documented API origins."""
    try:
        parsed = urlsplit(str(url or ""))
        origin = f"{parsed.scheme}://{parsed.hostname}"
        if parsed.port not in (None, 443):
            origin += f":{parsed.port}"
    except (TypeError, ValueError):
        raise RuntimeError("BFL returned an unsafe polling address") from None
    if (origin not in _BFL_POLL_ORIGINS or parsed.username or parsed.password
            or parsed.fragment or not parsed.path.startswith("/")):
        raise RuntimeError("BFL returned an unsafe polling address")
    return str(url)


async def _download_bfl_image(url, output_dir=None, file_name=None):
    try:
        parsed = urlsplit(str(url or ""))
        approved = bool(re.fullmatch(
            r"delivery\.[a-z0-9-]{1,63}\.bfl\.ai",
            str(parsed.hostname or "").lower()))
        safe = (parsed.scheme == "https" and approved and not parsed.username
                and not parsed.password and parsed.port in (None, 443)
                and not parsed.fragment)
    except (TypeError, ValueError):
        safe = False
    if not safe:
        raise RuntimeError("BFL returned an unapproved image download address")
    # Signed delivery URLs never receive the x-key used for polling.
    return await _download(
        url, "image", ".jpg", {"User-Agent": "OpenClam-Studio/1.0"},
        output_dir, file_name)


def _generic_image_result(payload):
    """Compatibility parser for non-OpenAI/xAI image adapters."""
    urls = []
    blobs = []

    def visit(value):
        if isinstance(value, dict):
            kind = str(value.get("type") or "").lower()
            for key in ("b64_json", "bytesBase64Encoded", "imageBytes"):
                candidate = value.get(key)
                if isinstance(candidate, str) and len(candidate) > 100:
                    blobs.append(candidate)
            if kind in {"image", "output_image"}:
                candidate = value.get("data")
                if isinstance(candidate, str) and len(candidate) > 100:
                    blobs.append(candidate)
            candidate = value.get("url")
            if isinstance(candidate, str) and candidate.startswith("https://"):
                urls.append(candidate)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(payload)
    return (blobs[0] if blobs else ""), (urls[0] if urls else ""), ""


def _image_result(provider, payload):
    """Parse only the documented response envelope for reviewed providers."""
    if provider not in {"openai", "xai"}:
        return _generic_image_result(payload)
    if not isinstance(payload, dict):
        raise RuntimeError(f"{provider} returned an invalid image response")
    items = payload.get("data")
    if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
        raise RuntimeError(f"{provider} returned an invalid image response")
    item = items[0]
    blob = item.get("b64_json")
    url = item.get("url")
    mime = str(item.get("mime_type") or "").strip().lower()
    blob = blob if isinstance(blob, str) and blob else ""
    url = url if isinstance(url, str) and url else ""
    if provider == "openai":
        if not blob or url:
            raise RuntimeError("openai returned an invalid GPT Image response")
        return blob, "", mime
    if bool(blob) == bool(url):
        raise RuntimeError("xai returned an ambiguous or empty image response")
    if url:
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or parsed.hostname not in _XAI_IMAGE_DOWNLOAD_HOSTS
                or parsed.username or parsed.password or parsed.port not in (None, 443)):
            raise RuntimeError("xAI returned an unapproved image download address")
    return blob, url, mime


def _run_sync(awaitable):
    """Run provider work from both studio worker threads and async tests."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(awaitable)
    result = []
    failure = []

    def runner():
        try:
            result.append(asyncio.run(awaitable))
        except BaseException as exc:  # propagate in the caller's thread
            failure.append(exc)

    thread = threading.Thread(target=runner, name="openclam-provider", daemon=True)
    thread.start()
    thread.join()
    if failure:
        raise failure[0]
    return result[0]


# ---------------------------------------------------------------- prompt/vision

async def generate_text(system, user_text, config, image_b64=None,
                        max_tokens=900):
    allowed = VISION_TEXT_PROVIDERS if image_b64 else TEXT_PROVIDERS
    provider, key, _spec = _require_lane("llm", config, allowed)
    base = _base("llm", provider, config)
    model = _model("llm", provider, config)
    if not model:
        raise RuntimeError(f"Choose a {provider} language model in OpenClam Settings")
    maximum = max(64, min(int(max_tokens), 4096))
    if provider == "xai":
        content = [{"type": "text", "text": str(user_text)}]
        if image_b64:
            if not isinstance(image_b64, str) or len(image_b64) > 30 * 1024 * 1024:
                raise RuntimeError("xAI vision input is too large")
            content.append({
                "type": "image_url",
                "image_url": {"url": "data:image/jpeg;base64," + image_b64,
                              "detail": "high"},
            })
        lane = dict(config)
        lane["max_tokens"] = maximum
        return await _providers()._xai_chat_direct(
            [{"role": "user", "content": content}], lane, system)
    try:
        async with httpx.AsyncClient(timeout=180) as client:
            if provider == "gemini":
                parts = [{"text": user_text}]
                if image_b64:
                    parts.append({"inlineData": {
                        "mimeType": "image/jpeg", "data": image_b64}})
                request = {
                    "contents": [{"role": "user", "parts": parts}],
                    "systemInstruction": {"parts": [{"text": system}]},
                    "generationConfig": {"maxOutputTokens": maximum},
                }
                response = await client.post(
                    f"{base}/models/{model}:generateContent",
                    headers={"x-goog-api-key": key}, json=request)
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                candidates = response.json().get("candidates") or [{}]
                blocks = (candidates[0].get("content") or {}).get("parts") or []
                return "".join(str(block.get("text") or "") for block in blocks).strip()

            if provider == "anthropic":
                content = [{"type": "text", "text": user_text}]
                if image_b64:
                    content.append({
                        "type": "image",
                        "source": {"type": "base64", "media_type": "image/jpeg",
                                   "data": image_b64},
                    })
                response = await client.post(
                    f"{base}/messages",
                    headers={"x-api-key": key,
                             "anthropic-version": "2023-06-01"},
                    json={"model": model, "system": system,
                          "messages": [{"role": "user", "content": content}],
                          "max_tokens": maximum})
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                return "".join(
                    str(block.get("text") or "")
                    for block in response.json().get("content") or []).strip()

            if provider == "ollama":
                response = await client.post(
                    f"{base}/api/chat",
                    json={"model": model, "stream": False, "think": False,
                          "messages": [
                              {"role": "system", "content": system},
                              {"role": "user", "content": user_text},
                          ], "options": {"num_predict": maximum}})
                if response.status_code >= 400:
                    raise _http_failure(provider, response)
                return str((response.json().get("message") or {}).get("content") or "").strip()

            content = [{"type": "text", "text": user_text}]
            if image_b64:
                content.append({
                    "type": "image_url",
                    "image_url": {"url": "data:image/jpeg;base64," + image_b64,
                                  "detail": "high"},
                })
            headers = {"Authorization": f"Bearer {key}",
                       "Content-Type": "application/json"}
            request = {
                "model": model,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": content},
                ],
                "max_completion_tokens": maximum,
            }
            response = await client.post(
                f"{base}/chat/completions", headers=headers, json=request)
            if response.status_code == 400 and "max_completion_tokens" in response.text:
                request["max_tokens"] = request.pop("max_completion_tokens")
                response = await client.post(
                    f"{base}/chat/completions", headers=headers, json=request)
            if response.status_code >= 400:
                raise _http_failure(provider, response, key)
            choices = response.json().get("choices") or [{}]
            return str((choices[0].get("message") or {}).get("content") or "").strip()
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"{provider}: {_safe_error(exc, key)}") from exc


def generate_text_sync(system, user_text, config, image_b64=None,
                       max_tokens=900):
    text = _run_sync(generate_text(system, user_text, config, image_b64, max_tokens))
    if not text:
        raise RuntimeError("the selected language model returned an empty response")
    return text


# ---------------------------------------------------------------- image

async def _save_image_response(provider, payload, output_dir=None,
                               file_name=None):
    blob, url, declared_mime = _image_result(provider, payload)
    if blob:
        if len(blob) > ((_MAX_IMAGE_OUTPUT_BYTES + 2) // 3) * 4:
            raise RuntimeError(f"{provider} returned an oversized image")
        try:
            data = base64.b64decode(blob, validate=True)
        except Exception as exc:
            raise RuntimeError(f"{provider} returned invalid image data") from exc
        if len(data) < 4096:
            raise RuntimeError(f"{provider} returned an unusably small image")
        if len(data) > _MAX_IMAGE_OUTPUT_BYTES:
            raise RuntimeError(f"{provider} returned an oversized image")
        suffix = _image_suffix(data, declared_mime)
        return _write("image", suffix, data, output_dir, file_name)
    if url:
        if provider == "xai":
            return await _download_xai_image(
                url, declared_mime, output_dir, file_name)
        headers = {"User-Agent": "OpenClam-Studio/1.0"}
        return await _download(
            url, "image", ".png", headers, output_dir, file_name)
    raise RuntimeError(f"{provider} returned no image")


def _image_prompt(prompt):
    if not isinstance(prompt, str):
        raise RuntimeError("image generation needs a text prompt")
    value = prompt.strip()
    if not value:
        raise RuntimeError("image generation needs a text prompt")
    if len(value) > _MAX_IMAGE_PROMPT_CHARS:
        raise RuntimeError("image prompts must be at most 32,000 characters")
    return value


def _require_image_prompt_limit(prompt, provider, model):
    maximum = _IMAGE_PROMPT_BYTE_LIMITS.get((provider, model))
    if maximum is None:
        return
    actual = len(prompt.encode("utf-8"))
    if actual > maximum:
        label = "Grok Imagine Image 2.0" if provider == "xai" else model
        raise RuntimeError(
            f"{label} prompts must be at most {maximum:,} UTF-8 bytes "
            f"(received {actual:,}); shorten the art direction and try again")


def _openai_image_size(value, model="gpt-image-2"):
    # GPT Image 2 documents ``auto`` as the default for both size and quality.
    # Keep the released GPT Image 1 lane's previous explicit square/high shape
    # so opening an existing project cannot silently change its output profile.
    default = "auto" if model == "gpt-image-2" else "1024x1024"
    size = str(value or default).strip().lower()
    if size == "auto":
        return size
    if model == "gpt-image-1" and size not in {
            "1024x1024", "1536x1024", "1024x1536"}:
        raise RuntimeError(
            "GPT Image 1 compatibility mode supports 1024x1024, 1536x1024, "
            "1024x1536, or auto")
    match = re.fullmatch(r"([1-9][0-9]{2,3})x([1-9][0-9]{2,3})", size)
    if not match:
        raise RuntimeError("GPT Image 2 size must be auto or WIDTHxHEIGHT")
    width, height = (int(part) for part in match.groups())
    pixels = width * height
    if (width > 3840 or height > 3840 or width % 16 or height % 16
            or max(width, height) / min(width, height) > 3
            or pixels < 655_360 or pixels > 8_294_400):
        raise RuntimeError("GPT Image 2 size is outside the supported bounds")
    return f"{width}x{height}"


def _openai_image_quality(value, model="gpt-image-2"):
    default = "auto" if model == "gpt-image-2" else "high"
    quality = str(value or default).strip().lower()
    if quality not in _OPENAI_IMAGE_QUALITIES:
        raise RuntimeError("GPT Image 2 quality must be auto, low, medium, or high")
    return quality


def _aspect_ratio_for_size(value):
    size = str(value or "auto").strip().lower()
    match = re.fullmatch(r"([1-9][0-9]{2,3})x([1-9][0-9]{2,3})", size)
    if not match:
        return "1:1" if size != "auto" else "auto"
    width, height = (int(part) for part in match.groups())
    divisor = math.gcd(width, height)
    return f"{width // divisor}:{height // divisor}"


def _xai_image_options(model, config, aspect_ratio=None):
    aspect = str(
        aspect_ratio or config.get("aspect_ratio") or "auto").strip().lower()
    if aspect not in _XAI_IMAGE_ASPECT_RATIOS:
        raise RuntimeError("xAI image aspect ratio is not supported")
    resolution = str(config.get("resolution") or "1k").strip().lower()
    if resolution not in _XAI_IMAGE_RESOLUTIONS:
        raise RuntimeError("xAI image resolution must be 1k or 2k")
    options = {"aspect_ratio": aspect, "resolution": resolution}
    quality = str(config.get("quality") or "").strip().lower()
    if model == "grok-imagine-image-2.0":
        quality = quality or "medium"
        if quality not in _XAI_IMAGE_2_QUALITIES:
            raise RuntimeError("Grok Imagine Image 2.0 quality must be low or medium")
        options["quality"] = quality
    elif quality:
        raise RuntimeError(
            "xAI's quality parameter is only supported by grok-imagine-image-2.0")
    return options


async def generate_image(prompt, config, output_dir=None, file_name=None):
    prompt = _image_prompt(prompt)
    provider, key, _spec = _require_lane("image", config, IMAGE_PROVIDERS)
    base = _base("image", provider, config)
    model = _model("image", provider, config)
    _require_avatar_model("image", provider, model)
    _require_image_prompt_limit(prompt, provider, model)
    if provider == "openai" and _openai_uses_chatgpt():
        data = await _openai_account_manager().generate_image_async(
            prompt, aspect_ratio=_aspect_ratio_for_size(config.get("size")),
            quality=config.get("quality") or "high")
        return _write("image", ".png", data, output_dir, file_name)
    reviewed_options = {}
    if provider == "openai":
        reviewed_options = {
            "size": _openai_image_size(config.get("size"), model),
            "quality": _openai_image_quality(config.get("quality"), model),
            "background": "opaque",
            "output_format": "png",
        }
    elif provider == "xai":
        reviewed_options = _xai_image_options(model, config)
        reviewed_options["response_format"] = "b64_json"
    auth_secret = key
    try:
        xai_headers = None
        if provider == "xai":
            resolved_base, xai_headers, auth_secret, _mode = await _xai_api_auth()
            if resolved_base != base:
                raise RuntimeError("xAI authentication resolved an unapproved endpoint")
        async with httpx.AsyncClient(
                timeout=_IMAGE_REQUEST_TIMEOUT, follow_redirects=False,
                trust_env=False) as client:
            if provider in {"openai", "xai", "together_image", "recraft"}:
                request = {"model": model, "prompt": prompt, "n": 1}
                if provider == "openai":
                    request.update(reviewed_options)
                elif provider == "xai":
                    request.update(reviewed_options)
                elif provider == "together_image":
                    request["response_format"] = "b64_json"
                request_url = f"{base}/images/generations"
                request_headers = (
                    {**xai_headers, "Content-Type": "application/json"}
                    if provider == "xai" else
                    {"Authorization": f"Bearer {key}",
                     "Content-Type": "application/json"})
                if provider == "xai":
                    response = await _bounded_media_request(
                        client, "POST", request_url,
                        provider=provider, secret=auth_secret,
                        max_bytes=96 * 1024 * 1024,
                        headers=request_headers, json=request)
                else:
                    response = await client.post(
                        request_url,
                        headers=request_headers, json=request)
                _require_no_redirect(
                    provider, response, auth_secret,
                    96 * 1024 * 1024 if provider == "xai" else 0)
                return await _save_image_response(
                    provider, response.json(), output_dir, file_name)

            if provider == "gemini":
                request = {
                    "model": model,
                    "input": [{"type": "text", "text": prompt}],
                    "response_format": {
                        "type": "image", "mime_type": "image/png",
                        "aspect_ratio": "1:1", "image_size": "1K",
                    },
                }
                response = await client.post(
                    f"{base}/interactions", headers={"x-goog-api-key": key},
                    json=request)
                _require_no_redirect(provider, response, key)
                return await _save_image_response(
                    provider, response.json(), output_dir, file_name)

            if provider == "stability":
                response = await client.post(
                    f"{base}/v2beta/stable-image/generate/core",
                    headers={"Authorization": f"Bearer {key}", "Accept": "image/*"},
                    files={"prompt": (None, prompt), "output_format": (None, "png")})
                _require_no_redirect(provider, response, key)
                return _write("image", ".png", response.content, output_dir, file_name)

            if provider == "bfl":
                response = await _bounded_media_request(
                    client, "POST", f"{base}/v1/{model or 'flux-pro-1.1'}",
                    provider=provider, secret=key, max_bytes=4 * 1024 * 1024,
                    headers={"x-key": key}, json={"prompt": prompt})
                _require_no_redirect(provider, response, key, 4 * 1024 * 1024)
                poll = _bfl_poll_address(response.json().get("polling_url"))
                for _attempt in range(90):
                    await asyncio.sleep(2)
                    status = await _bounded_media_request(
                        client, "GET", poll, provider=provider, secret=key,
                        max_bytes=4 * 1024 * 1024, headers={"x-key": key})
                    _require_no_redirect(provider, status, key, 4 * 1024 * 1024)
                    body = status.json()
                    if body.get("status") == "Ready":
                        url = str((body.get("result") or {}).get("sample") or "")
                        return await _download_bfl_image(
                            url, output_dir=output_dir, file_name=file_name)
                    if body.get("status") in {
                            "Error", "Content Moderated", "Request Moderated"}:
                        raise RuntimeError(f"BFL: {body.get('status')}")
                raise RuntimeError("BFL image generation timed out")
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"{provider}: {_safe_error(exc, auth_secret)}") from exc


def _image_size(aspect_ratio):
    if aspect_ratio in {"3:2", "4:3", "16:9"}:
        return "1536x1024"
    if aspect_ratio in {"2:3", "3:4", "4:5", "9:16"}:
        return "1024x1536"
    return "1024x1024"


async def generate_image_edit(prompt, references, config, aspect_ratio="1:1",
                              quality="high", output_dir=None,
                              file_name=None):
    prompt = _image_prompt(prompt)
    paths = [os.path.abspath(os.fspath(path)) for path in references]
    if not paths or any(not os.path.isfile(path) for path in paths):
        raise RuntimeError("avatar image editing needs readable reference images")
    provider, key, _spec = _require_lane(
        "image", config, IMAGE_EDIT_PROVIDERS)
    base = _base("image", provider, config)
    model = _model("image", provider, config)
    _require_avatar_model("image", provider, model)
    _require_image_prompt_limit(prompt, provider, model)
    maximum_references = ({"grok-imagine-image-2.0": 5}.get(model, 3)
                          if provider == "xai" else
                          {"openai": 16, "gemini": 14}[provider])
    if len(paths) > maximum_references:
        raise RuntimeError(
            f"{provider} image editing accepts at most {maximum_references} references")
    if provider == "openai" and _openai_uses_chatgpt():
        data = await _openai_account_manager().generate_image_async(
            prompt, paths, aspect_ratio=aspect_ratio,
            quality=config.get("quality") or quality)
        return _write("image", ".png", data, output_dir, file_name)
    image_inputs = [_read_image_input(path) for path in paths]
    reviewed_options = {}
    if provider == "xai":
        reviewed_options = _xai_image_options(model, config, aspect_ratio)
    elif provider == "openai":
        reviewed_options = {
            "size": _openai_image_size(_image_size(aspect_ratio), model),
            "quality": _openai_image_quality(
                config.get("quality") or quality, model),
            "background": "opaque",
            "output_format": "png",
        }
        if model == "gpt-image-1":
            reviewed_options["input_fidelity"] = "high"
    auth_secret = key
    try:
        xai_headers = None
        if provider == "xai":
            resolved_base, xai_headers, auth_secret, _mode = await _xai_api_auth()
            if resolved_base != base:
                raise RuntimeError("xAI authentication resolved an unapproved endpoint")
        async with httpx.AsyncClient(
                timeout=_IMAGE_REQUEST_TIMEOUT, follow_redirects=False,
                trust_env=False) as client:
            if provider == "xai":
                images = [{
                    "type": "image_url",
                    "url": f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}",
                } for _name, data, mime in image_inputs]
                request = {"model": model, "prompt": prompt,
                           "response_format": "b64_json"}
                request["image" if len(images) == 1 else "images"] = (
                    images[0] if len(images) == 1 else images)
                request.update(reviewed_options)
                response = await _bounded_media_request(
                    client, "POST", f"{base}/images/edits",
                    provider=provider, secret=auth_secret,
                    max_bytes=96 * 1024 * 1024,
                    headers={**xai_headers, "Content-Type": "application/json"},
                    json=request)
                _require_no_redirect(provider, response, auth_secret,
                                     96 * 1024 * 1024)
                return await _save_image_response(
                    provider, response.json(), output_dir, file_name)

            if provider == "openai":
                files = [
                    ("image[]", item)
                    for item in image_inputs
                ]
                data = {
                    "model": model, "prompt": prompt,
                    **reviewed_options,
                }
                # GPT Image 2 always processes references at high fidelity and
                # rejects this field.  The saved gpt-image-1 compatibility
                # choice still supports and benefits from it.
                response = await client.post(
                    f"{base}/images/edits",
                    headers={"Authorization": f"Bearer {key}"},
                    data=data, files=files)
                _require_no_redirect(provider, response, key)
                return await _save_image_response(
                    provider, response.json(), output_dir, file_name)

            if provider == "gemini":
                inputs = [{"type": "text", "text": prompt}]
                for _name, image_data, mime in image_inputs:
                    inputs.append({"type": "image", "mime_type": mime,
                                   "data": base64.b64encode(image_data).decode("ascii")})
                request = {
                    "model": model, "input": inputs,
                    "response_format": {
                        "type": "image", "mime_type": "image/png",
                        "aspect_ratio": aspect_ratio or "1:1",
                        "image_size": "2K",
                    },
                }
                response = await client.post(
                    f"{base}/interactions", headers={"x-goog-api-key": key},
                    json=request)
                _require_no_redirect(provider, response, key)
                return await _save_image_response(
                    provider, response.json(), output_dir, file_name)
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"{provider}: {_safe_error(exc, auth_secret)}") from exc


def generate_image_edit_sync(prompt, references, config, aspect_ratio="1:1",
                             quality="high", output_dir=None, file_name=None):
    return _run_sync(generate_image_edit(
        prompt, references, config, aspect_ratio, quality, output_dir, file_name))


# ---------------------------------------------------------------- video

async def _poll(client, method, url, headers, is_done, every=5, cap=900,
                provider="video", secret=""):
    started = time.monotonic()
    while time.monotonic() - started < cap:
        await asyncio.sleep(every)
        response = await _bounded_media_request(
            client, method, url, headers=headers, provider=provider,
            secret=secret, max_bytes=4 * 1024 * 1024)
        body = response.json()
        if is_done(body):
            return body
    raise RuntimeError(f"{provider} video generation timed out")


def _video_prompt(prompt):
    value = str(prompt or "").strip()
    if not value:
        raise RuntimeError("video generation needs a text prompt")
    if len(value) > _MAX_VIDEO_PROMPT_CHARS:
        raise RuntimeError("video prompts must be at most 32,000 characters")
    return value


def _xai_video_prompt(prompt):
    value = _video_prompt(prompt)
    if len(value.encode("utf-8")) > _XAI_VIDEO_PROMPT_MAX_BYTES:
        raise RuntimeError(
            "xAI video prompts must be at most 4,096 UTF-8 bytes")
    return value


def _read_video_input(path):
    target = os.path.abspath(os.fspath(path))
    try:
        size = os.path.getsize(target)
    except OSError as exc:
        raise RuntimeError("video editing needs a readable source video") from exc
    if size <= 0 or size > _MAX_VIDEO_INPUT_BYTES:
        raise RuntimeError("video editing accepts source videos up to 50 MiB")
    with open(target, "rb") as handle:
        data = handle.read(_MAX_VIDEO_INPUT_BYTES + 1)
    if len(data) != size or len(data) > _MAX_VIDEO_INPUT_BYTES:
        raise RuntimeError("video editing accepts source videos up to 50 MiB")
    if Path(target).suffix.lower() != ".mp4" \
            or len(data) < 12 or data[4:8] != b"ftyp":
        raise RuntimeError("xAI video editing accepts MP4 source files only")
    duration = _mp4_duration_seconds(data)
    if duration <= 0 or duration > 8.7:
        raise RuntimeError("xAI video editing accepts MP4 clips up to 8.7 seconds")
    return data, "video/mp4"


def _mp4_boxes(data, start=0, end=None):
    end = min(len(data), len(data) if end is None else end)
    offset = max(0, start)
    while offset + 8 <= end:
        size = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        header = 8
        if size == 1:
            if offset + 16 > end:
                return
            size = int.from_bytes(data[offset + 8:offset + 16], "big")
            header = 16
        elif size == 0:
            size = end - offset
        if size < header or offset + size > end:
            return
        yield kind, offset + header, offset + size
        offset += size


def _mp4_duration_seconds(data):
    for kind, payload, box_end in _mp4_boxes(data):
        if kind != b"moov":
            continue
        for child, child_payload, child_end in _mp4_boxes(data, payload, box_end):
            if child != b"mvhd" or child_payload >= child_end:
                continue
            version = data[child_payload]
            if version == 0 and child_payload + 20 <= child_end:
                timescale = int.from_bytes(
                    data[child_payload + 12:child_payload + 16], "big")
                duration = int.from_bytes(
                    data[child_payload + 16:child_payload + 20], "big")
            elif version == 1 and child_payload + 32 <= child_end:
                timescale = int.from_bytes(
                    data[child_payload + 20:child_payload + 24], "big")
                duration = int.from_bytes(
                    data[child_payload + 24:child_payload + 32], "big")
            else:
                continue
            if timescale:
                return duration / timescale
    raise RuntimeError("xAI video editing could not verify the MP4 duration")


def _video_data_uri(path):
    data, mime = _read_video_input(path)
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


async def _download_xai_video(url, output_dir=None, file_name=None):
    try:
        parsed = urlsplit(str(url or ""))
        safe = (parsed.scheme == "https"
                and parsed.hostname in _XAI_VIDEO_DOWNLOAD_HOSTS
                and not parsed.username and not parsed.password
                and parsed.port in (None, 443) and not parsed.fragment)
    except (TypeError, ValueError):
        safe = False
    if not safe:
        raise RuntimeError("xAI returned an unapproved video download address")
    async with httpx.AsyncClient(
            timeout=_IMAGE_DOWNLOAD_TIMEOUT, follow_redirects=False,
            trust_env=False) as client:
        response = await _bounded_media_request(
            client, "GET", url,
            headers={"User-Agent": "OpenClam-Studio/1.0"},
            provider="xAI video download", max_bytes=_MAX_VIDEO_OUTPUT_BYTES)
        length = str((getattr(response, "headers", {}) or {}).get(
            "content-length") or "")
        if length.isdigit() and int(length) > _MAX_VIDEO_OUTPUT_BYTES:
            raise RuntimeError("xAI returned an oversized video file")
        data = response.content
        if len(data) < 4096 or len(data) > _MAX_VIDEO_OUTPUT_BYTES:
            raise RuntimeError("xAI returned an unusable video file")
        content_type = str((getattr(response, "headers", {}) or {}).get(
            "content-type") or "").split(";", 1)[0].lower()
        if content_type and content_type not in {"video/mp4", "application/octet-stream"}:
            raise RuntimeError("xAI returned an unsupported video content type")
        return _write("video", ".mp4", data, output_dir, file_name)


async def _execute_xai_video_job(endpoint, request, config, output_dir=None,
                                 file_name=None):
    if endpoint not in {"generations", "edits"}:
        raise RuntimeError("xAI video endpoint is not approved")
    base = _base("video", "xai", config)
    resolved_base, headers, secret, _mode = await _xai_api_auth()
    if resolved_base != base:
        raise RuntimeError("xAI authentication resolved an unapproved endpoint")
    async with httpx.AsyncClient(
            timeout=900, follow_redirects=False, trust_env=False) as client:
        try:
            response = await _bounded_media_request(
                client, "POST", f"{base}/videos/{endpoint}",
                provider="xai", secret=secret, max_bytes=4 * 1024 * 1024,
                headers=headers, json=request)
        except RuntimeError as exc:
            raise RuntimeError(
                f"xAI video submission failed: {_safe_error(exc, secret)}") from exc
        _require_no_redirect("xai", response, secret, 4 * 1024 * 1024)
        job = response.json().get("request_id") or response.json().get("id")
        job = str(job or "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", job):
            raise RuntimeError("xAI accepted the video job but returned no safe request id")
        try:
            body = await _poll(
                client, "GET", f"{base}/videos/{job}", headers,
                lambda value: value.get("status") not in {"pending", "processing"},
                provider="xai", secret=secret)
        except RuntimeError as exc:
            raise RuntimeError(
                f"xAI video polling failed: {_safe_error(exc, secret)}") from exc
    if body.get("status") != "done":
        raise RuntimeError(f"xAI video generation {body.get('status') or 'failed'}")
    url = str((body.get("video") or {}).get("url") or "")
    if not url:
        raise RuntimeError("xAI completed the video but returned no file")
    return await _download_xai_video(url, output_dir, file_name)


async def _xai_video(prompt, config, image=None, aspect_ratio=None,
                     duration=None, resolution=None, output_dir=None,
                     file_name=None):
    provider, _key, _spec = _require_lane("video", config, {"xai"})
    model = _model("video", provider, config)
    _require_xai_video_model("image_to_video" if image else "text", model)
    request = {
        "model": model,
        "prompt": _xai_video_prompt(prompt),
        "duration": max(1, min(int(duration or config.get("seconds") or 6), 15)),
        "resolution": str(resolution or config.get("resolution") or "720p"),
    }
    if aspect_ratio:
        request["aspect_ratio"] = aspect_ratio
    if image:
        request["image"] = {"url": _data_uri(image)}
    return await _execute_xai_video_job(
        "generations", request, config, output_dir, file_name)


async def generate_video_edit(prompt, video, config, output_dir=None,
                              file_name=None):
    """Edit one bounded local video through xAI's pinned /videos/edits API."""
    provider, _key, _spec = _require_lane("video", config, {"xai"})
    model = _model("video", provider, config)
    _require_xai_video_model("edit", model)
    request = {
        "model": model,
        "prompt": _xai_video_prompt(prompt),
        "video": {"url": _video_data_uri(video)},
    }
    return await _execute_xai_video_job(
        "edits", request, config, output_dir, file_name)


def generate_video_edit_sync(prompt, video, config, output_dir=None,
                             file_name=None):
    return _run_sync(generate_video_edit(
        prompt, video, config, output_dir, file_name))


async def generate_video(prompt, config, output_dir=None, file_name=None):
    provider, key, _spec = _require_lane("video", config, VIDEO_PROVIDERS)
    if provider == "xai":
        return await _xai_video(
            prompt, config, duration=config.get("seconds"),
            resolution=config.get("resolution"), output_dir=output_dir,
            file_name=file_name)
    base = _base("video", provider, config)
    model = _model("video", provider, config)
    seconds = max(1, min(int(config.get("seconds") or 5), 20))
    try:
        async with httpx.AsyncClient(
                timeout=900, follow_redirects=False, trust_env=False) as client:
            if provider == "openai":
                headers = {"Authorization": f"Bearer {key}"}
                response = await client.post(
                    f"{base}/videos", headers=headers,
                    json={"model": model, "prompt": prompt,
                          "seconds": str(seconds)})
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                job = response.json().get("id")
                body = await _poll(
                    client, "GET", f"{base}/videos/{job}", headers,
                    lambda value: value.get("status") in {"completed", "failed"},
                    provider=provider, secret=key)
                if body.get("status") != "completed":
                    raise RuntimeError(f"OpenAI video generation {body.get('status')}")
                content = await client.get(
                    f"{base}/videos/{job}/content", headers=headers)
                if content.status_code >= 400:
                    raise _http_failure(provider, content, key)
                return _write(
                    "video", ".mp4", content.content, output_dir, file_name)

            if provider == "gemini":
                response = await client.post(
                    f"{base}/models/{model}:predictLongRunning",
                    headers={"x-goog-api-key": key},
                    json={"instances": [{"prompt": prompt}]})
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                operation = str(response.json().get("name") or "")
                body = await _poll(
                    client, "GET", f"{base}/{operation}",
                    {"x-goog-api-key": key}, lambda value: value.get("done"),
                    provider=provider, secret=key)
                samples = (((body.get("response") or {})
                            .get("generateVideoResponse") or {})
                           .get("generatedSamples") or [])
                url = str(((samples[0].get("video") or {}).get("uri")
                           if samples else "") or "")
                return await _download(
                    url, "video", ".mp4", {"x-goog-api-key": key},
                    output_dir, file_name)

            if provider == "luma":
                headers = {"Authorization": f"Bearer {key}"}
                response = await client.post(
                    f"{base}/generations", headers=headers,
                    json={"prompt": prompt, "model": model or "ray-2"})
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                job = response.json().get("id")
                body = await _poll(
                    client, "GET", f"{base}/generations/{job}", headers,
                    lambda value: value.get("state") in {"completed", "failed"},
                    provider=provider, secret=key)
                if body.get("state") != "completed":
                    raise RuntimeError(
                        f"Luma: {body.get('failure_reason') or 'generation failed'}")
                return await _download(
                    str((body.get("assets") or {}).get("video") or ""),
                    "video", ".mp4", output_dir=output_dir,
                    file_name=file_name)

            if provider == "runway":
                headers = {"Authorization": f"Bearer {key}",
                           "X-Runway-Version": "2024-11-06"}
                response = await client.post(
                    f"{base}/text_to_video", headers=headers,
                    json={"model": model or "veo3.1_fast", "promptText": prompt,
                          "duration": seconds, "ratio": "1280:720"})
                if response.status_code >= 400:
                    raise _http_failure(provider, response, key)
                job = response.json().get("id")
                body = await _poll(
                    client, "GET", f"{base}/tasks/{job}", headers,
                    lambda value: value.get("status") in {"SUCCEEDED", "FAILED"},
                    provider=provider, secret=key)
                if body.get("status") != "SUCCEEDED":
                    raise RuntimeError(
                        f"Runway: {body.get('failure') or 'generation failed'}")
                output = body.get("output") or []
                return await _download(
                    output[0] if output else "", "video", ".mp4",
                    output_dir=output_dir, file_name=file_name)
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"{provider}: {_safe_error(exc, key)}") from exc


async def generate_video_from_image(prompt, image, config, aspect_ratio,
                                    duration=6, resolution="720p",
                                    output_dir=None, file_name=None):
    if not os.path.isfile(image):
        raise RuntimeError("avatar motion needs a readable source keyframe")
    _require_lane("video", config, AVATAR_VIDEO_PROVIDERS)
    return await _xai_video(
        prompt, config, image=image, aspect_ratio=aspect_ratio,
        duration=duration, resolution=resolution, output_dir=output_dir,
        file_name=file_name)


def generate_video_from_image_sync(prompt, image, config, aspect_ratio,
                                   duration=6, resolution="720p",
                                   output_dir=None, file_name=None):
    return _run_sync(generate_video_from_image(
        prompt, image, config, aspect_ratio, duration, resolution,
        output_dir, file_name))
