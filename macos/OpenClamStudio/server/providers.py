"""Think, speak, hear - swappable between local models and cloud vendors.

No vendor SDKs. Every cloud provider here is a plain JSON-over-HTTP API and
there are only four request shapes in the whole file (OpenAI-compatible,
Anthropic, Gemini, Ollama), so httpx covers all of them. Four SDKs would be
~400MB of transitive dependencies to send the same POST bodies, and each one
would pin its own httpx.

Model IDs are live-discovered where the provider exposes the relevant list
endpoint. Image generation also carries a small reviewed current/compatibility
catalogue so first-time setup can name the exact generation-and-edit contracts
before the user supplies a key.

One thing genuinely changes with the provider: LIP-SYNC ACCURACY. Kokoro is a
StyleTTS2 derivative that predicts a per-phoneme frame count and upsamples by
it, so its own duration array IS a forced alignment - exact, free, no second
model. Cloud voices return audio and nothing else. See align.py for what is
done about that; the honest summary is that local Kokoro is sample-accurate and
everything else is estimated. The UI says so.
"""
import os, io, json, base64, tempfile, subprocess, threading, asyncio, re, time, hashlib, math
import numpy as np
import httpx

from livekit_bridge import DEFAULT_CONFIG as LIVEKIT_DEFAULT_CONFIG

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_ROOT = os.path.abspath(os.environ.get("OPENCLAM_DATA_DIR", CODE_ROOT))
CONFIG = os.path.abspath(os.environ.get(
    "OPENCLAM_CONFIG", os.path.join(DATA_ROOT, "config.json")))
MLX_WHISPER_MODEL_ID = "mlx-community/whisper-small-mlx-4bit"
MLX_WHISPER_MODEL_REVISION = "f1da4c67f2ee8b6e763b974e149aa65d5b7658b7"
MLX_WHISPER_LICENSE_REVISION = "e58f28804528831904c3b6f2c0e473f346223433"
MLX_WHISPER_MODEL_DIR = "whisper-small-mlx-4bit"
MLX_WHISPER_MANIFEST = "openclam-model-manifest.json"
PACKAGED_RUNTIME = os.environ.get("OPENCLAM_PACKAGED") == "1"
MLX_WHISPER_FILES = {
    "config.json": {
        "size": 339,
        "sha256": "d414b27f911c1c416a90525a0f856e0dc1c9e38632a833ca8dd05c58b3d8a01a",
    },
    "weights.npz": {
        "size": 196537352,
        "sha256": "ca6659298fe7550468ff0fc49dea7442615d9a53d1ce087aaded1b7627451998",
    },
    "LICENSE.openai-whisper-MIT.txt": {
        "size": 1063,
        "sha256": "b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d",
    },
}
SR = 24000
_lock = threading.Lock()
_route_lock = threading.Lock()
_model_lock = threading.Lock()
_cache = {"tts": None}
_routes = {}
_verified_mlx_models = {}


# ---------------------------------------------------------------- config

DEFAULTS = {
    "llm": {"provider": "ollama", "model": "",
            "base_url": "", "api_key": "", "temperature": 0.8, "max_tokens": 160},
    "tts": {"provider": "system", "model": "", "voice": "",
            "base_url": "", "api_key": "", "speed": 1.0},
    "stt": {"provider": "mlx_whisper",
            "model": MLX_WHISPER_MODEL_ID,
            "base_url": "", "api_key": "", "language": "auto"},
    # Media generation is intentionally unconfigured on first launch. It is
    # never routed through another desktop app or a managed fallback: the
    # user must choose one of the direct providers below and store its key.
    "image": {"provider": "", "model": "",
              "base_url": "", "api_key": "", "size": "1024x1024"},
    "video": {"provider": "", "model": "",
              "base_url": "", "api_key": "", "seconds": 5,
              # xAI's Grok Imagine takes a resolution; 1080p needs
              # grok-imagine-video-1.5 (measured 2026-08-04).
              "resolution": "1080p"},
    # Live talk has one implementation: the hardened LiveKit broker bridge.
    "livekit": json.loads(json.dumps(LIVEKIT_DEFAULT_CONFIG)),
    "persona": {
        "name": "OpenClam",
        "system": (
            "You are OpenClam, a warm and capable personal AI assistant. "
            "You are SPEAKING ALOUD through a voice interface, so keep every reply to "
            "1-3 short sentences. Never use lists, markdown, headings, bullet points or "
            "emoji. Be direct and natural, and say clearly when you are uncertain. "
            "Talk like a person talking, not like written prose.")},
}

# These are the only top-level settings owned by this standalone app. Avatar
# state lives in avatar manifests; retired cross-app blocks must not survive a
# config migration or get written back through a generic partial save.
CONFIG_BLOCKS = frozenset((*DEFAULTS, "ui", "keys", "key_checks"))
_normalization_pending = [False]
LIVEKIT_STT_DEFAULT_MIGRATION_KEY = "livekit_stt_auto_multilingual_v1"

# Image inference is deliberately narrower than the app's language-model
# integrations. These are the exact reviewed generation/edit contracts, not
# prefixes: a similarly named preview or future model may use different fields.
STRICT_IMAGE_MODELS = {
    "openai": frozenset({"gpt-image-2", "gpt-image-1"}),
    "xai": frozenset({
        "grok-imagine-image-2.0",
        "grok-imagine-image",
        "grok-imagine-image-quality",
    }),
}
RECOMMENDED_IMAGE_MODELS = {
    "openai": "gpt-image-2",
    "xai": "grok-imagine-image-2.0",
}
PINNED_IMAGE_BASES = {
    "openai": "https://api.openai.com/v1",
    "gemini": "https://generativelanguage.googleapis.com/v1beta",
    "xai": "https://api.x.ai/v1",
    "stability": "https://api.stability.ai",
    "bfl": "https://api.bfl.ai",
    "together_image": "https://api.together.xyz/v1",
    "recraft": "https://external.api.recraft.ai/v1",
}
XAI_API_BASE = "https://api.x.ai/v1"
XAI_CLI_PROXY_BASE = "https://cli-chat-proxy.grok.com/v1"
XAI_OAUTH_LLM_MODELS = ("grok-4.6", "grok-build")
XAI_STT_LANGUAGE_CODES = (
    "ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi", "id",
    "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru",
    "es", "sv", "th", "tr", "vi",
)
STT_LANGUAGE_LABELS = {
    "auto": "Automatic language detection",
    "multi": "Auto multilingual · Chinese + English",
    "ar": "Arabic", "cs": "Czech", "da": "Danish", "nl": "Dutch",
    "en": "English", "fil": "Filipino", "fr": "French", "de": "German",
    "hi": "Hindi", "id": "Indonesian", "it": "Italian", "ja": "Japanese",
    "ko": "Korean", "mk": "Macedonian", "ms": "Malay", "fa": "Persian",
    "pl": "Polish", "pt": "Portuguese", "ro": "Romanian", "ru": "Russian",
    "es": "Spanish", "sv": "Swedish", "th": "Thai", "tr": "Turkish",
    "vi": "Vietnamese", "zh": "Chinese",
}
_MAX_XAI_RESPONSE_BYTES = 4 * 1024 * 1024
_MAX_XAI_TEXT_CHARS = 128_000
_MAX_XAI_INPUT_CHARS = 1_000_000
_MAX_XAI_IMAGE_DATA_CHARS = 32 * 1024 * 1024
_MAX_STREAMED_LLM_BYTES = 4 * 1024 * 1024
_MAX_STREAMED_LLM_TEXT_CHARS = 64_000
_API_KEY_METHODS = frozenset({"api_key", "api-key", "apikey"})


def stt_language_catalog(provider):
    """Return the closed language picker for one direct PTT provider."""
    if provider == "mlx_whisper":
        default, codes = "auto", ("auto", "en", "zh")
        automatic_label = "Auto multilingual · local Whisper"
    elif provider == "deepgram":
        default, codes = "multi", ("multi", "en", "zh")
        automatic_label = STT_LANGUAGE_LABELS["multi"]
    elif provider == "xai":
        default, codes = "auto", ("auto", *XAI_STT_LANGUAGE_CODES)
        automatic_label = "Automatic · 25 languages, no Chinese"
    else:
        default, codes = "auto", ("auto", "en", "zh")
        automatic_label = STT_LANGUAGE_LABELS["auto"]
    choices = [
        {
            "id": code,
            "label": automatic_label if code == default else STT_LANGUAGE_LABELS[code],
        }
        for code in codes
    ]
    return {"default_language": default, "languages": choices}


def validate_stt_language(provider, language):
    selected = str(language or stt_language_catalog(provider)["default_language"]).strip()
    # Older provider-neutral PTT settings stored `auto` for Deepgram. Nova-3's
    # reviewed multilingual wire value is `multi`; canonicalize that one
    # equivalent legacy value rather than dropping the whole saved provider.
    if provider == "deepgram" and selected == "auto":
        selected = "multi"
    allowed = {row["id"] for row in stt_language_catalog(provider)["languages"]}
    if selected not in allowed:
        if provider == "xai" and selected == "zh":
            raise RuntimeError(
                "xAI Grok Transcribe does not support Chinese. Choose local Whisper "
                "Auto multilingual or Deepgram Auto multilingual before recording."
            )
        raise RuntimeError(
            "Choose a supported speech-recognition language for this provider"
        )
    return selected


def _xai_oauth_manager():
    """Load the one Keychain-backed xAI auth authority lazily.

    Provider lanes never inspect or infer xAI credentials themselves.  This
    keeps an explicitly selected API-key session from being mixed with OAuth,
    and keeps an OAuth failure from falling back to a saved API key.
    """
    try:
        import xai_oauth
    except ModuleNotFoundError:
        from server import xai_oauth
    return xai_oauth


def _validate_xai_base_override(config):
    supplied = str((config or {}).get("base_url") or "").strip().rstrip("/")
    if supplied and supplied != XAI_API_BASE:
        raise RuntimeError("xAI requests only connect to the approved HTTPS endpoint")


async def _resolve_xai_auth(*, model="", cli_for_oauth=False):
    """Return the fixed base, manager-built headers, and redaction secret."""
    manager = _xai_oauth_manager()
    resolved = await manager.resolve_auth()
    if cli_for_oauth and resolved.mode == manager.OAUTH2_MODE:
        headers = resolved.headers(manager.CLI_PROXY_TARGET, model=model)
        return manager.XAI_CLI_PROXY_BASE, headers, resolved.bearer_token, resolved.mode
    headers = resolved.headers(manager.API_TARGET)
    return manager.XAI_API_BASE, headers, resolved.bearer_token, resolved.mode


def _require_xai_response(response, action="request",
                          max_bytes=_MAX_XAI_RESPONSE_BYTES):
    status = int(getattr(response, "status_code", 0) or 0)
    if 300 <= status < 400:
        raise RuntimeError(f"xAI tried to redirect the protected {action}")
    if status < 200 or status >= 300:
        if status in (401, 403):
            reason = "authentication was rejected"
        elif status == 429:
            reason = "the account is being rate-limited"
        elif status == 404:
            reason = "the selected model or endpoint was not found"
        else:
            reason = "the provider refused the request"
        raise RuntimeError(f"xAI: {reason} (HTTP {status})")
    headers = getattr(response, "headers", {}) or {}
    length = str(headers.get("content-length") or "")
    if length.isdigit() and int(length) > max_bytes:
        raise RuntimeError(f"xAI returned an oversized {action}")
    try:
        content = response.content or b""
    except Exception:
        content = b""
    if isinstance(content, (bytes, bytearray)) and len(content) > max_bytes:
        raise RuntimeError(f"xAI returned an oversized {action}")


async def _xai_bounded_request(client, method, url, *, action="request",
                               max_bytes=_MAX_XAI_RESPONSE_BYTES, **kwargs):
    """Read a protected xAI response incrementally under a hard byte cap."""
    stream = getattr(client, "stream", None)
    if callable(stream):
        async with stream(method, url, **kwargs) as upstream:
            _require_xai_response(upstream, action, max_bytes)
            data = bytearray()
            async for chunk in upstream.aiter_bytes():
                data.extend(chunk)
                if len(data) > max_bytes:
                    raise RuntimeError(f"xAI returned an oversized {action}")
            # ``aiter_bytes`` yields decoded content. Do not preserve wire
            # encoding/length headers on the reconstructed in-memory response
            # or httpx will try to decompress the JSON a second time.
            decoded_headers = {
                str(name): str(value)
                for name, value in upstream.headers.items()
                if str(name).lower() not in {
                    "content-encoding", "content-length", "transfer-encoding"
                }
            }
            return httpx.Response(
                upstream.status_code, headers=decoded_headers, content=bytes(data))
    # Focused mocked clients use verb-specific methods; production httpx
    # always takes the streaming branch above.
    sender = getattr(client, method.lower())
    response = await sender(url, **kwargs)
    _require_xai_response(response, action, max_bytes)
    return response


def _xai_catalog_fields():
    return {
        "auth_scope": "global",
        "auth_modes": ["api_key", "oauth2"],
        "auth": {
            "api_key": {
                "supported": True,
                "status": "supported",
                "label": "API key",
            },
            "oauth": {
                "supported": True,
                "status": "supported_via_grok_build_compatibility",
                "label": "Grok Build compatibility",
                "reason": (
                    "Uses OpenClam's one shared OAuth session created with "
                    "xAI's public Grok Build client identity. OpenClam is "
                    "independent and is not sponsored, endorsed, or partnered "
                    "by xAI."
                ),
            },
        },
    }


def _normalised_field_name(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def _is_token_shaped_image_field(name):
    """Identify unsupported OAuth/bearer material at any nesting depth."""
    field = _normalised_field_name(name)
    return (
        "oauth" in field
        or "accesstoken" in field
        or "refreshtoken" in field
        or field == "token"
        or field.endswith("token")
        or field in {
            "auth", "authmethod", "bearer", "credentialtype", "selectedmethod",
            "apikey", "authorization", "authorizationheader", "authorizationcode",
            "clientid", "clientsecret", "codeverifier", "redirecturi",
            "scope", "scopes", "tokenendpoint", "authorizationendpoint",
        }
    )


def _contains_token_shaped_image_field(value, root=False):
    if isinstance(value, dict):
        for name, child in value.items():
            if root and str(name) in {"api_key", "auth_method", "credential_type"}:
                continue
            if _is_token_shaped_image_field(name):
                return True
            if _contains_token_shaped_image_field(child):
                return True
    elif isinstance(value, list):
        return any(_contains_token_shaped_image_field(child) for child in value)
    return False


def _strip_token_shaped_image_fields(value, root=False):
    dirty = False
    if isinstance(value, dict):
        for name in list(value):
            if root and str(name) in {"api_key", "auth_method", "credential_type"}:
                continue
            if _is_token_shaped_image_field(name):
                value.pop(name, None)
                dirty = True
            else:
                dirty = _strip_token_shaped_image_fields(value[name]) or dirty
    elif isinstance(value, list):
        for child in value:
            dirty = _strip_token_shaped_image_fields(child) or dirty
    return dirty


def _image_auth_is_api_key_only(block):
    if not isinstance(block, dict):
        return True
    for field in ("auth_method", "credential_type"):
        declared = str(block.get(field) or "").strip().lower()
        if declared and declared not in _API_KEY_METHODS:
            return False
    # Authentication state belongs in the top-level api_key/Keychain lane.
    # Nested auth dictionaries can otherwise hide an access token under an
    # innocuous-looking parent and bypass the normal secret-field sweep.
    if "auth" in block:
        return False
    return not _contains_token_shaped_image_field(block, root=True)


def _require_image_api_key_auth(block):
    if not _image_auth_is_api_key_only(block):
        if str((block or {}).get("provider") or "").strip() == "xai":
            raise RuntimeError(
                "xAI authentication is selected globally; remove image-lane "
                "OAuth or token fields and use the shared xAI sign-in")
        raise RuntimeError(
            "Image inference supports API-key authentication only; remove "
            "OAuth or token credentials")


def _normalise_legacy_image_block(block):
    """Make old image settings safe and usable with a newly pasted API key."""
    if not isinstance(block, dict):
        return False
    dirty = False
    unsupported_auth = not _image_auth_is_api_key_only(block)
    if "auth" in block:
        block.pop("auth", None)
        dirty = True
    dirty = _strip_token_shaped_image_fields(block, root=True) or dirty
    for field in ("auth_method", "credential_type"):
        declared = str(block.get(field) or "").strip().lower()
        if not declared:
            if field in block:
                block.pop(field, None)
                dirty = True
        elif declared in _API_KEY_METHODS:
            if block.get(field) != "api_key":
                block[field] = "api_key"
                dirty = True
        else:
            block.pop(field, None)
            dirty = True
    provider = str(block.get("provider") or "").strip()
    if unsupported_auth:
        # A legacy OAuth flow sometimes wrote its bearer into the field now
        # reserved for provider API keys. Its declared credential type makes
        # that value ambiguous, so clear it instead of relabelling the bearer
        # as an API key. The lane remains selected and asks for a fresh key.
        if block.get("api_key"):
            block["api_key"] = "__clear__"
            dirty = True
        if provider and block.get("auth_method") != "api_key":
            block["auth_method"] = "api_key"
            dirty = True
    allowed = STRICT_IMAGE_MODELS.get(provider)
    if allowed is not None:
        model = str(block.get("model") or "").strip()
        # Only a truly blank saved choice gets the reviewed default. Preserve
        # a nonblank retired/unknown ID so Settings can label it unsupported
        # and require an explicit replacement instead of silently switching
        # the user's model or billing contract.
        if not model:
            block["model"] = RECOMMENDED_IMAGE_MODELS[provider]
            dirty = True
    elif not provider and block.get("model"):
        block["model"] = ""
        dirty = True
    # Every image provider has a reviewed, built-in HTTPS origin. A legacy
    # endpoint is never retained, even when it happens to equal that origin;
    # runtime code reads only PINNED_IMAGE_BASES.
    if block.get("base_url"):
        block["base_url"] = ""
        dirty = True
    return dirty


def _pinned_image_base(provider, supplied=""):
    """Return the reviewed image origin and reject every endpoint override."""
    approved = str(PINNED_IMAGE_BASES.get(provider) or "").rstrip("/")
    if not approved.startswith("https://"):
        raise RuntimeError(
            "Choose a direct image provider with an approved HTTPS API endpoint")
    candidate = str(supplied or "").strip().rstrip("/")
    if candidate and candidate != approved:
        raise RuntimeError(
            "Image model discovery only connects to the provider's "
            "approved HTTPS API endpoint")
    return approved


def _validate_image_update(update, current):
    """Reject new unsupported credentials/models while legacy files migrate."""
    if not isinstance(update, dict):
        return
    _require_image_api_key_auth(update)
    raw_provider = update.get("provider") \
        if "provider" in update else (current or {}).get("provider")
    provider = str(raw_provider or "").strip()
    allowed = STRICT_IMAGE_MODELS.get(provider)
    if "model" in update:
        model = str(update.get("model") or "").strip()
        if allowed is not None and model and model not in allowed:
            raise RuntimeError("Choose an exact supported image model")
    if "base_url" in update:
        supplied = update.get("base_url")
        if provider or str(supplied or "").strip():
            _pinned_image_base(provider, supplied)
    elif provider and provider not in PINNED_IMAGE_BASES:
        _pinned_image_base(provider)


def _validated_image_runtime_base(block):
    """Validate a direct image request before constructing an HTTP client."""
    _require_image_api_key_auth(block)
    provider = str((block or {}).get("provider") or "").strip()
    base = _pinned_image_base(provider, (block or {}).get("base_url"))
    exact = STRICT_IMAGE_MODELS.get(provider)
    selected = str((block or {}).get("model") or "").strip()
    if exact is not None and selected and selected not in exact:
        raise RuntimeError("Choose an exact supported image model")
    return base


def _merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        if k == "key_checks":
            out[k] = v      # verdicts replace wholesale: a retired row's
            continue        # green tick must actually disappear from disk
        out[k] = _merge(base[k], v) if isinstance(v, dict) and isinstance(base.get(k), dict) else v
    return out


def _migrate_legacy_managed_livekit_stt_default(config):
    """Move only the exact old managed-English default to multilingual.

    The durable marker makes this a one-time upgrade. Once it exists, a user
    can deliberately select managed English and it remains untouched. BYOK
    English and every other provider/model/language tuple are never changed.
    """
    if not isinstance(config, dict):
        return False
    ui = config.get("ui")
    if not isinstance(ui, dict):
        ui = {}
        config["ui"] = ui
    if ui.get(LIVEKIT_STT_DEFAULT_MIGRATION_KEY) is True:
        return False
    livekit = config.get("livekit")
    stt = livekit.get("stt") if isinstance(livekit, dict) else None
    if stt == {
        "source": "managed",
        "provider": "livekit",
        "model": "deepgram/nova-3",
        "language": "en",
    }:
        stt["language"] = "multi"
    ui[LIVEKIT_STT_DEFAULT_MIGRATION_KEY] = True
    return True


def _read_config_file():
    dirty = False
    try:
        with open(CONFIG) as f:
            config = _merge(DEFAULTS, json.load(f))
    except Exception:
        config = json.loads(json.dumps(DEFAULTS))
    # Old installations may still hold removed provider choices. Normalize
    # them before secrets are materialised so no obsolete local gateway or
    # realtime block can be reactivated by persisted state.
    for kind in ("llm", "tts", "stt", "image", "video"):
        block = config.get(kind)
        provider = block.get("provider") if isinstance(block, dict) else ""
        if provider and not spec(kind, provider):
            config[kind] = json.loads(json.dumps(DEFAULTS[kind]))
            dirty = True
    # Unsupported image OAuth/token fields predate the API-key-only contract.
    # Remove them during the same atomic migration that retires old providers,
    # and give only a truly blank strict-model lane its reviewed default. A
    # nonblank unsupported ID stays visible until the user replaces it.
    dirty = _normalise_legacy_image_block(config.get("image")) or dirty
    dirty = _migrate_legacy_managed_livekit_stt_default(config) or dirty
    for name in list(config):
        if name not in CONFIG_BLOCKS:
            config.pop(name, None)
            dirty = True
    if dirty:
        _normalization_pending[0] = True
    return config


_migrated = [False]


# One key per platform (#25). The owner pasted the same xAI key into
# Think, Create, and Live voice separately - six paste boxes for one
# secret. config["keys"] holds one key per platform; a lane whose block
# has no key of its own inherits the platform key for its provider here,
# at load, in memory only - the file never learns the inherited value,
# exactly like the vault's materialised secrets. An explicit lane key
# still wins. The aliases collapse family ids onto their platform.
_PLATFORM_ALIASES = {"minimax_llm": "minimax", "together_image": "together"}


def platform_of(provider):
    return _PLATFORM_ALIASES.get(provider or "", provider or "")


def _inherit_platform_keys(cfg):
    keys = cfg.get("keys")
    if not isinstance(keys, dict) or not keys:
        return cfg
    for kind in ("llm", "tts", "stt", "image", "video"):
        block = cfg.get(kind)
        if isinstance(block, dict) and not block.get("api_key"):
            inherited = keys.get(platform_of(block.get("provider"))) or ""
            if inherited:
                block["api_key"] = inherited
    return cfg


def load():
    """Secrets live in the vault (macOS Keychain), the file keeps only
    markers, and load() hands back a config with the real values woven in -
    memory only, so no call site changed and no key touches disk again."""
    import credentials
    with _lock:
        cfg = _read_config_file()
        moved = False
        if not _migrated[0] or _normalization_pending[0]:
            moved = credentials.absorb(cfg)
        if moved or _normalization_pending[0]:
            # Sweep plaintext secrets into Keychain and retire stale blocks in
            # the same atomic rewrite. A removed secret must not linger in an
            # old config file simply because no current lane needed migration.
            _write_config_file(cfg)
            _normalization_pending[0] = False
        _migrated[0] = True
    return _inherit_platform_keys(credentials.materialise(cfg))


def load_livekit_nonsecret():
    """Read only the non-secret LiveKit settings without touching Keychain.

    This is used while composing response CSP headers, where a Keychain lookup
    on every local asset request would be both wasteful and unnecessary.
    """
    block = (_read_config_file().get("livekit") or {})
    out = json.loads(json.dumps(block)) if isinstance(block, dict) else {}
    out.pop("pilot_app_token", None)
    out.pop("has_pilot_app_token", None)
    return out


def _write_config_file(cfg):
    directory = os.path.dirname(CONFIG)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, tmp = tempfile.mkstemp(prefix=".openclam-config-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(cfg, handle, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def save(cfg, *, replace_livekit=False):
    """Merge-and-write, so a UI that posts only the TTS block cannot wipe the
    API key sitting in the STT block. Incoming plaintext keys are swept into
    the vault before anything is written; the file only ever sees markers.

    Live Talk is the one nested block whose validated value may deliberately
    omit a stale field during migration.  Its settings routes opt into a
    wholesale replacement so the generic deep merge cannot resurrect that
    field from disk.  The write-only pilot token marker is carried forward
    when no token update was supplied, preserving the Keychain credential
    without copying secret material into the replacement block.
    """
    import credentials
    with _lock:
        cur = _read_config_file()
        try:
            _validate_image_update(
                (cfg or {}).get("image") if isinstance(cfg, dict) else None,
                cur.get("image") or {},
            )
        except Exception:
            # Do not let a rejected new request strand a legacy OAuth secret
            # that the read-side migration already removed in memory.
            if _normalization_pending[0]:
                credentials.absorb(cur)
                _write_config_file(cur)
                _normalization_pending[0] = False
            raise
        new = _merge(cur, cfg)
        if replace_livekit:
            incoming_livekit = (cfg or {}).get("livekit") \
                if isinstance(cfg, dict) else None
            if not isinstance(incoming_livekit, dict):
                raise ValueError(
                    "replace_livekit requires a complete LiveKit block"
                )
            replacement = json.loads(json.dumps(incoming_livekit))
            current_livekit = cur.get("livekit")
            current_token = current_livekit.get("pilot_app_token") \
                if isinstance(current_livekit, dict) else ""
            if "pilot_app_token" not in replacement and current_token:
                replacement["pilot_app_token"] = current_token
            new["livekit"] = replacement
        _normalise_legacy_image_block(new.get("image"))
        credentials.absorb(new)
        _write_config_file(new)
        _normalization_pending[0] = False
        if (cur.get("tts") or {}) != (new.get("tts") or {}):
            _cache["tts"] = None         # voice or engine changed, drop the pipeline
    return credentials.materialise(new)


def redacted(cfg):
    """Never send a key back to the browser - only whether one is stored."""
    out = json.loads(json.dumps(cfg))
    _normalise_legacy_image_block(out.get("image"))
    for k in ("llm", "tts", "stt", "image", "video"):
        block = out.setdefault(k, {})
        if block.get("api_key") and block.get("api_key") != "__clear__":
            block["api_key"] = ""
            block["has_key"] = True
        else:
            block["api_key"] = ""
            block["has_key"] = False
    out.pop("live", None)
    livekit = out.setdefault("livekit", {})
    livekit["has_pilot_app_token"] = bool(livekit.get("pilot_app_token"))
    livekit["pilot_app_token"] = ""
    # The platform keyring (#25): same write-only contract as the lanes -
    # the browser learns which platforms hold a key, never the key.
    keys = out.get("keys") if isinstance(out.get("keys"), dict) else {}
    out["keys"] = {name: "" for name in keys}
    out["has_keys"] = {name: bool(value) for name, value in keys.items()}
    return out


# ---------------------------------------------------------------- catalogue

# base_url is the default endpoint; `openai_shape` means /v1/chat/completions,
# /v1/models, /v1/audio/* all behave identically, which is most of the market.
PROVIDERS = {
    "llm": [
        dict(id="ollama", label="Ollama", local=True, key=False,
             base="http://localhost:11434", note=(
                 "Local and Ollama Cloud models. Refresh lists models already added "
                 "to this Ollama installation, not the full online catalog. Enter "
                 "another tag directly; cloud tags require Ollama sign-in.")),
        dict(id="openai", label="OpenAI", key=True, base="https://api.openai.com/v1"),
        dict(id="anthropic", label="Anthropic", key=True, base="https://api.anthropic.com/v1"),
        dict(id="gemini", label="Google Gemini", key=True,
             base="https://generativelanguage.googleapis.com/v1beta"),
        dict(id="xai", label="xAI Grok", key=True, base=XAI_API_BASE,
             **_xai_catalog_fields()),
        dict(id="groq", label="Groq", key=True, base="https://api.groq.com/openai/v1"),
        dict(id="deepseek", label="DeepSeek", key=True, base="https://api.deepseek.com/v1"),
        dict(id="openrouter", label="OpenRouter", key=True, base="https://openrouter.ai/api/v1"),
        # The OpenAI wire shape is the market's lingua franca - one adapter
        # can support the providers that expose the same direct contract.
        dict(id="mistral", label="Mistral", key=True, base="https://api.mistral.ai/v1"),
        dict(id="together", label="Together AI", key=True, base="https://api.together.xyz/v1"),
        dict(id="fireworks", label="Fireworks", key=True,
             base="https://api.fireworks.ai/inference/v1"),
        dict(id="perplexity", label="Perplexity", key=True, base="https://api.perplexity.ai"),
        dict(id="moonshot", label="Moonshot Kimi", key=True, base="https://api.moonshot.ai/v1"),
        dict(id="qwen", label="Alibaba Qwen", key=True,
             base="https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        dict(id="zhipu", label="Zhipu GLM", key=True,
             base="https://open.bigmodel.cn/api/paas/v4"),
        dict(id="minimax_llm", label="MiniMax", key=True, base="https://api.minimax.io/v1"),
        dict(id="cerebras", label="Cerebras", key=True, base="https://api.cerebras.ai/v1"),
        dict(id="nvidia", label="NVIDIA NIM", key=True,
             base="https://integrate.api.nvidia.com/v1"),
        dict(id="lmstudio", label="LM Studio", local=True, key=False,
             base="http://localhost:1234/v1", note="Local OpenAI-compatible server."),
        dict(id="custom", label="Custom (OpenAI-compatible)", key=False, base="",
             note="Any server that speaks /v1/chat/completions."),
    ],
    "tts": [
        dict(id="system", label="macOS say", local=True, key=False, base="",
             note="Built into macOS and available without an account."),
        dict(id="kokoro", label="Kokoro 82M", local=True, key=False, base="",
             note="Local, and the only engine with exact lip-sync - it reports its own "
                  "per-phoneme durations.", exact=True),
        dict(id="edge", label="Edge TTS", key=False, base="",
             note="Free Microsoft voices. Ships word boundaries, so lip-sync is good."),
        dict(id="elevenlabs", label="ElevenLabs", key=True, base="https://api.elevenlabs.io/v1",
             note="Returns character-level timestamps, so lip-sync stays tight."),
        dict(id="xai", label="xAI Grok", key=True, base=XAI_API_BASE,
             **_xai_catalog_fields(),
             note="Grok's voices, with character timestamps - lip-sync stays "
                  "tight."),
        dict(id="openai", label="OpenAI", key=True, base="https://api.openai.com/v1",
             note="Audio only - mouth timing is estimated from the text."),
        dict(id="gemini", label="Google Gemini", key=True,
             base="https://generativelanguage.googleapis.com/v1beta",
             note="Audio only - mouth timing is estimated from the text."),
        dict(id="deepgram", label="Deepgram Aura", key=True,
             base="https://api.deepgram.com/v1",
             note="Audio only - mouth timing is estimated from the text."),
        dict(id="cartesia", label="Cartesia Sonic", key=True,
             base="https://api.cartesia.ai",
             note="Audio only - mouth timing is estimated from the text."),
    ],
    "stt": [
        dict(id="mlx_whisper", label="Whisper (MLX, local)", local=True, key=False, base="",
             **stt_language_catalog("mlx_whisper"),
             note="Bundled 4-bit multilingual model. Runs fully offline on the Metal GPU; "
                  "the app never downloads a model while listening. Auto multilingual "
                  "detects Chinese, English, and other Whisper languages."),
        dict(id="soniox", label="Soniox Realtime", key=True, base="",
             **stt_language_catalog("soniox"),
             note="Direct realtime dictation; the API key remains in Keychain."),
        dict(id="openai", label="OpenAI", key=True, base="https://api.openai.com/v1",
             **stt_language_catalog("openai")),
        dict(id="xai", label="xAI Grok", key=True, base=XAI_API_BASE,
             **_xai_catalog_fields(),
             **stt_language_catalog("xai"),
             note="Grok automatically recognizes exactly 25 documented languages: "
                  "Arabic, Czech, Danish, Dutch, English, Filipino, French, German, "
                  "Hindi, Indonesian, Italian, Japanese, Korean, Macedonian, Malay, "
                  "Persian, Polish, Portuguese, Romanian, Russian, Spanish, Swedish, "
                  "Thai, Turkish, and Vietnamese. Chinese is not supported; choose "
                  "local Whisper or Deepgram for Chinese."),
        dict(id="groq", label="Groq", key=True, base="https://api.groq.com/openai/v1",
             **stt_language_catalog("groq"),
             note="Whisper large v3, very fast."),
        dict(id="gemini", label="Google Gemini", key=True,
             base="https://generativelanguage.googleapis.com/v1beta",
             **stt_language_catalog("gemini")),
        dict(id="deepgram", label="Deepgram Nova", key=True,
             base="https://api.deepgram.com/v1",
             **stt_language_catalog("deepgram"),
             note="Nova-3 Auto multilingual supports Chinese and English code-switching."),
        dict(id="elevenlabs", label="ElevenLabs Scribe", key=True,
             base="https://api.elevenlabs.io/v1",
             **stt_language_catalog("elevenlabs")),
        dict(id="custom", label="Custom (OpenAI-compatible)", key=False, base="",
             **stt_language_catalog("custom")),
    ],
    # Media generation has direct providers only. A blank default is
    # deliberate: generation refuses to run until one is configured.
    "image": [
        dict(id="openai", label="OpenAI Images", key=True,
             base="https://api.openai.com/v1",
             capabilities={"generation": True, "editing": True},
             auth={
                 "api_key": {
                     "supported": True, "status": "supported",
                     "label": "API key",
                 },
                 "oauth": {
                     "supported": False,
                     "status": "unsupported_by_public_inference_api",
                     "label": "OAuth sign-in",
                     "reason": (
                         "OpenAI's public Images API does not offer an end-user "
                         "OAuth sign-in flow. Enterprise workload identity is "
                         "server-side and is not a personal sign-in."
                     ),
                 },
             },
             recommended_model="gpt-image-2",
             models=[
                 {"id": "gpt-image-2", "label": "GPT Image 2",
                  "recommended": True, "generation": True, "editing": True},
                 {"id": "gpt-image-1",
                  "label": "GPT Image 1 · compatibility",
                  "recommended": False, "generation": True, "editing": True},
             ],
             image_options={
                 "sizes": [
                     "1024x1024", "1536x1024", "1024x1536",
                     "2048x2048", "2048x1152", "3840x2160",
                     "2160x3840", "auto",
                 ],
                 "qualities": ["low", "medium", "high", "auto"],
                 "default_size": "auto",
                 "default_quality": "auto",
             },
             note=(
                 "GPT Image 2 generates and edits images. Reference-image edits "
                 "always use high input fidelity."
             )),
        dict(id="gemini", label="Google Gemini Image", key=True,
             base="https://generativelanguage.googleapis.com/v1beta",
             note="Native Gemini image models, including gemini-3.1-flash-image."),
        dict(id="xai", label="xAI Grok Imagine", key=True,
             base=XAI_API_BASE,
             auth_scope="global", auth_modes=["api_key", "oauth2"],
             capabilities={"generation": True, "editing": True},
             auth={
                 "api_key": {
                     "supported": True, "status": "supported",
                     "label": "API key",
                 },
                 "oauth": {
                     "supported": True,
                     "status": "supported_via_grok_build_compatibility",
                     "label": "Grok Build compatibility",
                     "reason": (
                         "Uses OpenClam's one shared OAuth session created with "
                         "xAI's public Grok Build client identity. OpenClam is "
                         "independent and is not sponsored, endorsed, or "
                         "partnered by xAI."
                     ),
                 },
             },
             recommended_model="grok-imagine-image-2.0",
             models=[
                 {"id": "grok-imagine-image-2.0",
                  "label": "Grok Imagine Image 2.0", "recommended": True,
                  "generation": True, "editing": True},
                 {"id": "grok-imagine-image-quality",
                  "label": "Grok Imagine Image Quality · compatibility",
                  "recommended": False, "generation": True, "editing": True},
                 {"id": "grok-imagine-image",
                  "label": "Grok Imagine Image · compatibility",
                  "recommended": False, "generation": True, "editing": True},
             ],
             image_options={
                 "aspect_ratios": [
                     "1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3",
                     "2:1", "1:2", "19.5:9", "9:19.5", "20:9", "9:20", "auto",
                 ],
                 "resolutions": ["1k", "2k"],
                 "qualities": ["low", "medium"],
                 "default_aspect_ratio": "1:1",
                 "default_resolution": "1k",
                 "default_quality": "medium",
             },
             note=(
                 "Grok Imagine Image 2.0 generates and edits images with up to "
                 "five reference images. Older Imagine model IDs remain visible "
                 "for existing projects."
             )),
        dict(id="stability", label="Stability AI", key=True,
             base="https://api.stability.ai"),
        dict(id="bfl", label="Black Forest Labs FLUX", key=True,
             base="https://api.bfl.ai"),
        dict(id="together_image", label="Together AI (FLUX)", key=True,
             base="https://api.together.xyz/v1"),
        dict(id="recraft", label="Recraft", key=True,
             base="https://external.api.recraft.ai/v1"),
    ],
    "video": [
        dict(id="xai", label="xAI Grok Imagine", key=True,
             base=XAI_API_BASE, **_xai_catalog_fields(),
             capabilities={"generation": True, "editing": True},
             recommended_model="grok-imagine-video",
             models=[
                 {"id": "grok-imagine-video", "recommended": True,
                  "text_to_video": True, "image_to_video": True,
                  "editing": True},
                 {"id": "grok-imagine-video-1.5", "recommended": False,
                  "text_to_video": False, "image_to_video": True,
                  "editing": False},
             ],
             note="Use grok-imagine-video for text generation and editing. "
                  "Grok Imagine Video 1.5 is an image-to-video model and adds "
                  "1080p output."),
        dict(id="openai", label="OpenAI Sora", key=True,
             base="https://api.openai.com/v1"),
        dict(id="gemini", label="Google Veo", key=True,
             base="https://generativelanguage.googleapis.com/v1beta"),
        dict(id="luma", label="Luma Dream Machine", key=True,
             base="https://api.lumalabs.ai/dream-machine/v1"),
        dict(id="runway", label="Runway", key=True, base="https://api.dev.runwayml.com/v1"),
    ],
}

OPENAI_SHAPE = {"openai", "xai", "groq", "deepseek", "openrouter", "lmstudio", "custom",
                "mistral", "together", "fireworks", "perplexity", "moonshot",
                "qwen", "zhipu", "minimax_llm", "cerebras", "nvidia"}


def spec(kind, pid):
    for p in PROVIDERS[kind]:
        if p["id"] == pid and not (
                PACKAGED_RUNTIME and kind == "tts" and pid == "kokoro"):
            return p
    return None


def _base(kind, c):
    s = spec(kind, c.get("provider")) or {}
    return (c.get("base_url") or s.get("base") or "").rstrip("/")


def catalog():
    return {
        kind: [
            dict(value) for value in values
            if not (PACKAGED_RUNTIME and kind == "tts" and value["id"] == "kokoro")
        ]
        for kind, values in PROVIDERS.items()
    }


def _safe_error(text):
    text = (text or "").strip().replace("\n", " ")
    text = re.sub(
        r"(?i)(api[_ -]?key|authorization|bearer|access[_ -]?token|"
        r"refresh[_ -]?token|oauth[_ -]?token|client[_ -]?secret)\s*[:=]\s*"
        r"(?:bearer\s+)?[^\s,;}]+", r"\1=[redacted]", text)
    text = re.sub(
        r"\b(?:sk|gsk)[-_][A-Za-z0-9_-]{8,}\b|"
        r"\bxai[-_](?!oauth(?:_|-))[A-Za-z0-9_-]{8,}\b",
        "[redacted]", text)
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[redacted]", text)
    return text[-500:] or "Provider command failed"


def safe_error(error, limit=300):
    return _safe_error(str(error))[-limit:]


def failure_hint(error):
    """One plain clause naming why a provider call failed. The bubble is the
    only surface the user sees; a bare 'not answering' once hid an Ollama
    Cloud 402 (out of credit) for a whole evening."""
    text = str(error)
    match = re.search(r"[\s']([45]\d{2})[\s']", f" {text} ")
    status = int(match.group(1)) if match else 0
    if status in (401, 403):
        return "the provider rejected the API key"
    if status == 402:
        return "the provider wants payment or sign-in for this model"
    if status == 404:
        return "the provider does not know this model"
    if status == 410:
        return "the provider no longer serves this model"
    if status == 429:
        return "the provider is rate-limiting"
    if status >= 500:
        return "the provider is having an outage"
    lowered = text.lower()
    if "timeout" in lowered or "timed out" in lowered:
        return "the request timed out"
    if "connect" in lowered:
        return "the endpoint is unreachable"
    return ""


def _route_begin(kind, mapped):
    route = {
        "provider": mapped.get("provider") or "",
        "model": mapped.get("model") or "",
        "display": mapped.get("display") or "Direct provider",
        "command_key": mapped.get("command_key") or "",
        "state": "routing",
        "started_at": time.time(),
    }
    with _route_lock:
        _routes[kind] = route


def _route_finish(kind, state, **details):
    with _route_lock:
        route = dict(_routes.get(kind) or {})
        route.update(details)
        route["state"] = state
        route["finished_at"] = time.time()
        _routes[kind] = route


def _route_observe_model(kind, model):
    """Replace the requested model with a provider-returned runtime receipt.

    Ollama includes the model that actually served every chat response. Keeping
    that value in the route receipt gives the renderer an authoritative label;
    the generated prose is never evidence of which model ran.
    """
    observed = str(model or "").strip()
    if not observed:
        return
    with _route_lock:
        route = dict(_routes.get(kind) or {})
        if not route:
            return
        requested = str(route.get("requested_model") or route.get("model") or "").strip()
        if requested and requested != observed:
            route["requested_model"] = requested
        route["model"] = observed
        provider = route.get("provider") or ""
        provider_spec = spec(kind, provider) or {}
        label = provider_spec.get("label") or provider.replace("_", " ").title()
        if provider == "ollama" and requested.endswith(":cloud"):
            route["display"] = f"Ollama Cloud · {observed} (requested {requested})"
        else:
            route["display"] = " · ".join(value for value in (label, observed) if value)
        _routes[kind] = route


def last_route(kind):
    with _route_lock:
        return json.loads(json.dumps(_routes.get(kind) or {}))


def _direct_route(kind, config):
    provider = config.get("provider") or ""
    provider_spec = spec(kind, provider) or {}
    details = []
    if config.get("model"):
        details.append(str(config["model"]))
    if kind == "tts" and config.get("voice"):
        details.append(str(config["voice"]))
    label = provider_spec.get("label") or provider.replace("_", " ").title()
    return {
        "provider": provider,
        "model": config.get("model") or "",
        "display": " · ".join([label, *details]),
        "command_key": "",
    }


# ---------------------------------------------------------------- model lists

# The one Grok voice roster for the direct Speak lane.
XAI_VOICES = [
    {"id": "eve", "name": "Eve · warm, expressive"},
    {"id": "ara", "name": "Ara · bright, upbeat"},
    {"id": "leo", "name": "Leo · steady, male"},
    {"id": "rex", "name": "Rex · deep, male"},
    {"id": "sal", "name": "Sal · neutral, calm"},
]
OPENAI_TTS_VOICES = [
    "alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin",
    "nova", "onyx", "sage", "shimmer", "verse",
]
GEMINI_TTS_VOICES = [
    "Achernar", "Aoede", "Autonoe", "Callirrhoe", "Charon", "Despina",
    "Enceladus", "Erinome", "Fenrir", "Gacrux", "Iapetus", "Kore", "Laomedeia",
    "Leda", "Orus", "Puck", "Pulcherrima", "Rasalgethi", "Sadachbia", "Sadaltager",
    "Schedar", "Sulafat", "Umbriel", "Vindemiatrix", "Zephyr", "Zubenelgenubi",
]


def _filter_models(kind, provider, values):
    values = sorted(set(str(value) for value in values if value))
    if kind == "llm":
        # Exclusion only, never a name allowlist: a prefix list ages the
        # moment the vendor ships a new family (OpenAI's gpt-* allowlist
        # would have hidden every non-gpt-named model). Drop what clearly
        # is not a chat model and keep everything else.
        excluded = ("audio", "realtime", "tts", "transcribe", "whisper", "embedding",
                    "image", "moderation", "dall-e", "sora", "davinci", "babbage")
        return [value for value in values
                if not any(word in value.lower() for word in excluded)]
    if kind == "tts" and provider == "openai":
        return [value for value in values
                if "tts" in value.lower() or "audio" in value.lower()]
    if kind == "stt" and provider in {"openai", "groq", "custom"}:
        return [value for value in values
                if "transcribe" in value.lower() or "whisper" in value.lower()]
    if kind == "image":
        exact = STRICT_IMAGE_MODELS.get(provider)
        if exact is not None:
            return [value for value in values if value in exact]
        checks = {
            "gemini": lambda value: value.startswith("gemini-") and "-image" in value,
            "together_image": lambda value: "flux" in value,
            "stability": lambda value: any(
                family in value for family in ("stable-image", "stable-diffusion", "sd3")),
            "bfl": lambda value: "flux" in value,
            "recraft": lambda value: value.startswith("recraft"),
        }
        check = checks.get(provider)
        return [value for value in values if check(value.lower())] if check else values
    if kind == "video":
        checks = {
            "openai": lambda value: value.startswith("sora"),
            "xai": lambda value: value in {
                "grok-imagine-video", "grok-imagine-video-1.5"},
            "gemini": lambda value: value.startswith("veo-"),
            "luma": lambda value: value.startswith("ray"),
            "runway": lambda value: any(
                family in value for family in ("gen-", "gen_", "veo")),
        }
        check = checks.get(provider)
        return [value for value in values if check(value.lower())] if check else values
    return values


async def list_models(kind, c):
    """Ask the provider what it actually offers after credentials are accepted."""
    if not isinstance(c, dict):
        raise RuntimeError(f"Choose a direct {kind} provider in OpenClam Settings")
    p = c.get("provider")
    provider_spec = spec(kind, p) or {}
    if not provider_spec:
        raise RuntimeError(f"Choose a direct {kind} provider in OpenClam Settings")
    if kind == "image":
        # Authentication, exact strict-model selection, and the immutable
        # provider origin are all checked before an HTTP client exists.
        base = _validated_image_runtime_base(c)
    else:
        base = _base(kind, c)
    key = c.get("api_key") or ""
    if provider_spec.get("key") and p != "xai" and not key:
        raise RuntimeError(f"{provider_spec.get('label', p)} API key is required")
    try:
        if p == "xai":
            _validate_xai_base_override(c)
            model = (str(c.get("model") or "").strip()
                     or FALLBACK_MODEL.get("xai", "grok-4.6"))
            base, headers, _secret, _mode = await _resolve_xai_auth(
                model=model, cli_for_oauth=(kind == "llm"))
            if kind == "llm" and _mode == _xai_oauth_manager().OAUTH2_MODE:
                # The Grok Build session contract does not document /models.
                # Resolve the selected credential, then show only the reviewed
                # native-session catalogue without probing an assumed route.
                return list(XAI_OAUTH_LLM_MODELS)
            path = {
                "image": "/image-generation-models",
                "tts": "/tts/voices",
            }.get(kind, "/models")
            async with httpx.AsyncClient(
                    timeout=20, follow_redirects=False, trust_env=False) as x:
                r = await _xai_bounded_request(
                    x, "GET", f"{base}{path}", headers=headers,
                    action="model discovery")
            payload = r.json()
            if kind == "tts":
                rows = payload.get("voices") or []
                return [str(row.get("voice_id") or row.get("id") or "")
                        for row in rows if isinstance(row, dict)
                        and (row.get("voice_id") or row.get("id"))]
            if kind == "stt":
                # The STT wire contract has no selectable model field.  The
                # authenticated /models call above is solely a non-billable
                # credential check for the Settings lane.
                return ["grok-transcribe"]
            rows = payload.get("models", []) if path != "/models" \
                else payload.get("data", [])
            values = [row.get("id") for row in rows if isinstance(row, dict)]
            return _filter_models(kind, p, values)
        async with httpx.AsyncClient(timeout=20, follow_redirects=False) as x:
            if p == "ollama":
                r = await x.get(f"{base or 'http://localhost:11434'}/api/tags")
                r.raise_for_status()
                return sorted(m["name"] for m in r.json().get("models", []))
            if p == "anthropic":
                r = await x.get(f"{base}/models", headers={
                    "x-api-key": key, "anthropic-version": "2023-06-01"})
                r.raise_for_status()
                return [m["id"] for m in r.json().get("data", [])]
            if p == "gemini":
                r = await x.get(f"{base}/models", params={"key": key, "pageSize": 200})
                r.raise_for_status()
                out = []
                for model in r.json().get("models", []):
                    methods = model.get("supportedGenerationMethods") or []
                    name = model["name"].split("/")[-1]
                    if kind in {"llm", "stt"} and "generateContent" not in methods:
                        continue
                    if kind == "tts" and "tts" not in name.lower():
                        continue
                    if kind in {"llm", "stt"} and any(
                            word in name.lower() for word in ("tts", "embedding", "imagen", "veo")):
                        continue
                    out.append(name)
                return _filter_models(kind, p, out)
            if p == "elevenlabs":
                r = await x.get(f"{base}/voices", headers={"xi-api-key": key})
                r.raise_for_status()
                return [f"{v['voice_id']}  ({v.get('name', '')})"
                        for v in r.json().get("voices", [])]
            if p == "edge":
                return await _edge_voices()
            if p == "system":
                out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
                return [line.split()[0] for line in out.splitlines() if line.strip()]
            if p == "soniox":
                # Listing doubles as the credentials check everywhere else,
                # so prove the key with a real handshake first.
                await _soniox_validate(c)
                return ["stt-rt-v5"]
            if p == "mlx_whisper":
                return [MLX_WHISPER_MODEL_ID]
            if p == "kokoro":
                return ["af_aoede", "af_heart", "af_bella", "af_nicole", "af_sarah",
                        "af_sky", "am_adam", "am_michael", "bf_emma", "bf_isabella",
                        "bm_george", "bm_lewis"]
            h = {"Authorization": f"Bearer {key}"} if key else {}
            model_path = "/models"
            r = await x.get(f"{base}{model_path}", headers=h)
            r.raise_for_status()
            payload = r.json()
            rows = payload.get("models", []) if model_path != "/models" \
                else payload.get("data", [])
            values = [model["id"] for model in rows]
            return _filter_models(kind, p, values)
    except httpx.HTTPStatusError as exc:
        # The raw httpx message buries the status behind a docs URL and the
        # tail-keeping redactor then keeps only the URL - say what actually
        # failed, plainly.
        status = exc.response.status_code
        if status in (401, 403):
            reason = "the provider rejected this API key"
        elif status == 404:
            reason = "no models endpoint at this address - check the Endpoint field"
        elif status == 429:
            reason = "the provider is rate-limiting this key - try again shortly"
        else:
            reason = "the provider refused the request"
        raise RuntimeError(f"{p}: {reason} (HTTP {status})") from exc
    except Exception as exc:
        raise RuntimeError(f"{p}: {_safe_error(str(exc))}") from exc


async def list_choices(kind, c):
    p = c.get("provider")
    if kind != "tts":
        return {"models": await list_models(kind, c), "voices": []}
    if p == "elevenlabs":
        base, key = _base(kind, c), c.get("api_key") or ""
        if not key:
            raise RuntimeError("ElevenLabs API key is required")
        async with httpx.AsyncClient(timeout=20) as client:
            voice_response, model_response = await asyncio.gather(
                client.get(f"{base}/voices", headers={"xi-api-key": key}),
                client.get(f"{base}/models", headers={"xi-api-key": key}))
            voice_response.raise_for_status()
            model_response.raise_for_status()
        voices = [f"{voice['voice_id']}  ({voice.get('name', '')})"
                  for voice in voice_response.json().get("voices", [])]
        model_payload = model_response.json()
        model_rows = model_payload if isinstance(model_payload, list) else \
            model_payload.get("models", [])
        models = [row.get("model_id") or row.get("id") for row in model_rows]
        return {"models": sorted(value for value in models if value), "voices": voices}
    if p in {"kokoro", "edge", "system"}:
        return {"models": [], "voices": await list_models(kind, c)}
    if p == "xai":
        # /v1/tts/voices is both the credential check and the current voice
        # roster. There is no separate selectable TTS model.
        return {"models": [], "voices": await list_models(kind, c)}
    models = await list_models(kind, c)
    voices = OPENAI_TTS_VOICES if p == "openai" else \
        GEMINI_TTS_VOICES if p == "gemini" else []
    return {"models": models, "voices": voices}


async def _edge_voices():
    try:
        import edge_tts
        vs = await edge_tts.list_voices()
        return sorted(v["ShortName"] for v in vs)
    except Exception:
        return ["en-US-AvaNeural", "en-US-EmmaNeural", "en-US-JennyNeural",
                "en-GB-SoniaNeural", "en-US-AndrewNeural", "en-US-BrianNeural"]


# ---------------------------------------------------------------- think

async def chat(messages, c, system=""):
    if not spec("llm", c.get("provider")):
        raise RuntimeError("Choose a direct language model in OpenClam Settings")
    _route_begin("llm", _direct_route("llm", c))
    try:
        text = await _chat_direct(messages, c, system)
        if not text:
            raise RuntimeError("the selected model returned an empty response")
        _route_finish("llm", "success")
        return text
    except Exception:
        _route_finish("llm", "failed")
        raise


async def chat_stream(messages, c, system=""):
    """Yield cumulative assistant text while retaining the direct-route receipt.

    Cumulative snapshots make provider-specific delta formats an internal
    detail and let clients safely replace one ephemeral bubble. The caller
    persists and speaks only the final snapshot.
    """
    if not spec("llm", c.get("provider")):
        raise RuntimeError("Choose a direct language model in OpenClam Settings")
    _route_begin("llm", _direct_route("llm", c))
    latest = ""
    try:
        async for snapshot in _chat_direct_stream(messages, c, system):
            snapshot = str(snapshot or "")
            if len(snapshot) > _MAX_STREAMED_LLM_TEXT_CHARS:
                raise RuntimeError("the selected model returned an oversized response")
            if snapshot != latest:
                latest = snapshot
                yield latest
        if not latest.strip():
            raise RuntimeError("the selected model returned an empty response")
        _route_finish("llm", "success")
    except Exception:
        _route_finish("llm", "failed")
        raise


# A provider with a key but no model chosen is the commonest way to a
# dead chat: the request goes out with model:"" and the provider rejects
# it, which surfaced as "ROUTE FAILED - my model is not answering" with
# nothing naming the actual cause (owner, xAI, 2026-08-03). Picking the
# house model is better than failing, and the UI still shows what ran.
FALLBACK_MODEL = {
    "openai": "gpt-5-mini", "xai": "grok-4.6", "anthropic": "claude-sonnet-5",
    "gemini": "gemini-2.5-flash", "groq": "llama-3.3-70b-versatile",
    "deepseek": "deepseek-chat", "mistral": "mistral-small-latest",
    "openrouter": "openai/gpt-5-mini", "moonshot": "kimi-k2-0905-preview",
    "cerebras": "llama-3.3-70b", "together": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    "fireworks": "accounts/fireworks/models/llama-v3p3-70b-instruct",
    "perplexity": "sonar", "qwen": "qwen-plus", "zhipu": "glm-4.6",
    "minimax_llm": "MiniMax-Text-01", "nvidia": "meta/llama-3.3-70b-instruct",
}


def _safe_https_citation(value):
    value = str(value or "").strip()
    if not value or len(value) > 2048:
        return ""
    try:
        from urllib.parse import urlsplit
        parsed = urlsplit(value)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username
                or parsed.password or parsed.port not in (None, 443)):
            return ""
    except (TypeError, ValueError):
        return ""
    return value


def _clean_xai_citation_links(text):
    def replace(match):
        url = _safe_https_citation(match.group(2))
        return f"[[{match.group(1)}]]({url})" if url else f"[{match.group(1)}]"
    return re.sub(r"\[\[(\d{1,3})\]\]\(([^)]+)\)", replace, str(text or ""))


def _xai_responses_text(payload):
    """Parse only final assistant text and inert HTTPS citation metadata."""
    if not isinstance(payload, dict):
        raise RuntimeError("xAI returned an invalid Responses payload")
    texts, citations = [], []
    rows = payload.get("output") or []
    if not isinstance(rows, list) or len(rows) > 128:
        raise RuntimeError("xAI returned an invalid Responses payload")
    for row in rows:
        if not isinstance(row, dict) or row.get("type") != "message":
            continue
        content = row.get("content") or []
        if not isinstance(content, list) or len(content) > 256:
            raise RuntimeError("xAI returned an invalid Responses payload")
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "output_text":
                continue
            value = block.get("text")
            if isinstance(value, str):
                texts.append(value)
            annotations = block.get("annotations") or []
            if isinstance(annotations, list):
                for annotation in annotations[:128]:
                    if not isinstance(annotation, dict):
                        continue
                    if annotation.get("type") not in {"url_citation", "citation"}:
                        continue
                    nested = annotation.get("url_citation")
                    url = _safe_https_citation(
                        annotation.get("url")
                        or (nested.get("url") if isinstance(nested, dict) else "")
                    )
                    if url:
                        citations.append(url)
    top = payload.get("citations") or []
    if isinstance(top, list):
        for citation in top[:128]:
            value = citation.get("url") if isinstance(citation, dict) else citation
            url = _safe_https_citation(value)
            if url:
                citations.append(url)
    text = _clean_xai_citation_links("".join(texts).strip())
    if len(text) > _MAX_XAI_TEXT_CHARS:
        raise RuntimeError("xAI returned an oversized text response")
    unique = list(dict.fromkeys(citations))[:12]
    missing = [url for url in unique if url not in text]
    if missing:
        suffix = "\n\nSources: " + " ".join(
            f"[{index}]({url})" for index, url in enumerate(missing, 1))
        text += suffix
    return text


def _xai_chat_completion_text(payload):
    if not isinstance(payload, dict):
        raise RuntimeError("xAI returned an invalid chat response")
    choices = payload.get("choices") or []
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise RuntimeError("xAI returned an invalid chat response")
    content = (choices[0].get("message") or {}).get("content")
    if isinstance(content, list):
        content = "".join(
            str(block.get("text") or "") for block in content[:256]
            if isinstance(block, dict) and block.get("type") in {"text", "output_text"}
        )
    text = str(content or "").strip()
    if len(text) > _MAX_XAI_TEXT_CHARS:
        raise RuntimeError("xAI returned an oversized text response")
    return text


def _xai_stream_text(response, responses_api=False):
    raw = getattr(response, "content", b"") or b""
    if len(raw) > _MAX_XAI_RESPONSE_BYTES:
        raise RuntimeError("xAI returned an oversized streaming response")
    text = raw.decode("utf-8", "strict") if isinstance(raw, bytes) else str(raw)
    deltas, completed = [], None
    for line in text.splitlines()[:50_000]:
        if not line.startswith("data:"):
            continue
        value = line[5:].strip()
        if not value or value == "[DONE]":
            continue
        try:
            event = json.loads(value)
        except (TypeError, json.JSONDecodeError):
            continue
        kind = str(event.get("type") or "") if isinstance(event, dict) else ""
        if kind == "response.completed":
            completed = event.get("response") or event
        elif kind in {"response.output_text.delta", "response.refusal.delta"}:
            delta = event.get("delta")
            if isinstance(delta, str):
                deltas.append(delta)
        else:
            choices = event.get("choices") or [] if isinstance(event, dict) else []
            if choices and isinstance(choices[0], dict):
                delta = (choices[0].get("delta") or {}).get("content")
                if isinstance(delta, str):
                    deltas.append(delta)
    if completed is not None and responses_api:
        return _xai_responses_text(completed)
    result = "".join(deltas).strip()
    if len(result) > _MAX_XAI_TEXT_CHARS:
        raise RuntimeError("xAI returned an oversized streaming response")
    return result


def _xai_responses_input(messages):
    output = []
    for message in messages:
        role = str(message.get("role") or "user")
        content = message.get("content")
        if isinstance(content, str):
            output.append({"role": role, "content": content})
            continue
        blocks = []
        for block in content:
            if block.get("type") in {"text", "input_text"}:
                blocks.append({"type": "input_text", "text": block["text"]})
            elif block.get("type") in {"image_url", "input_image"}:
                image = block.get("image_url")
                url = image.get("url") if isinstance(image, dict) else image
                url = url or block.get("image_url") or block.get("url")
                blocks.append({"type": "input_image", "image_url": url})
        output.append({"role": role, "content": blocks})
    return output


def _bounded_xai_messages(messages, initial_text_chars=0):
    if not isinstance(messages, (list, tuple)) or len(messages) > 128:
        raise RuntimeError("xAI chat accepts at most 128 messages")
    output = []
    text_total = max(0, int(initial_text_chars))
    image_total, image_count = 0, 0
    for message in messages:
        if not isinstance(message, dict):
            raise RuntimeError("xAI chat received an invalid message")
        role = str(message.get("role") or "")
        if role not in {"user", "assistant"}:
            raise RuntimeError("xAI chat supports user and assistant messages")
        content = message.get("content")
        if isinstance(content, str):
            text_total += len(content)
            if len(content) > _MAX_XAI_TEXT_CHARS:
                raise RuntimeError("an xAI chat message is too long")
            output.append({"role": role, "content": content})
            continue
        if not isinstance(content, list) or len(content) > 64:
            raise RuntimeError("xAI chat received invalid message content")
        blocks = []
        for block in content:
            if not isinstance(block, dict):
                raise RuntimeError("xAI chat received invalid message content")
            kind = str(block.get("type") or "")
            if kind in {"text", "input_text"}:
                value = str(block.get("text") or "")
                if len(value) > _MAX_XAI_TEXT_CHARS:
                    raise RuntimeError("an xAI chat message is too long")
                text_total += len(value)
                blocks.append({"type": "text", "text": value})
                continue
            if kind not in {"image_url", "input_image"}:
                raise RuntimeError("xAI chat received unsupported message content")
            image = block.get("image_url")
            url = image.get("url") if isinstance(image, dict) else image
            url = url or block.get("url")
            if (not isinstance(url, str) or not url.startswith("data:image/")
                    or ";base64," not in url):
                raise RuntimeError("xAI vision accepts bounded image data URLs")
            image_count += 1
            image_total += len(url)
            if image_count > 4 or image_total > _MAX_XAI_IMAGE_DATA_CHARS:
                raise RuntimeError("xAI vision input is too large")
            blocks.append({"type": "image_url", "image_url": {"url": url}})
        output.append({"role": role, "content": blocks})
    if text_total > _MAX_XAI_INPUT_CHARS:
        raise RuntimeError("xAI chat input is too large")
    return output


async def _xai_chat_direct(messages, c, system=""):
    _validate_xai_base_override(c)
    model = (c.get("model") or "").strip() or FALLBACK_MODEL["xai"]
    if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,160}", model):
        raise RuntimeError("Choose a valid xAI model")
    system = str(system or "")
    if len(system) > _MAX_XAI_TEXT_CHARS:
        raise RuntimeError("the xAI system instruction is too long")
    messages = _bounded_xai_messages(messages, len(system))
    maxtok = max(1, min(int(c.get("max_tokens", 160)), 4096))
    try:
        temperature = float(c.get("temperature", 0.8))
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Choose an xAI temperature from 0 to 2") from exc
    if not math.isfinite(temperature) or not 0 <= temperature <= 2:
        raise RuntimeError("Choose an xAI temperature from 0 to 2")
    use_search = bool(c.get("web_search", False))
    base, headers, _secret, mode = await _resolve_xai_auth(
        model=model, cli_for_oauth=True)
    oauth_mode = mode == _xai_oauth_manager().OAUTH2_MODE
    headers = {**headers, "Content-Type": "application/json"}
    if oauth_mode:
        # Grok Build's sampler requests an SSE response explicitly.  Keep this
        # on the OAuth proxy lane only; API-key requests retain the public API
        # client's ordinary JSON negotiation.
        headers["Accept"] = "text/event-stream"
    if oauth_mode and model not in XAI_OAUTH_LLM_MODELS:
        raise RuntimeError(
            "Choose a supported Grok model for the shared xAI sign-in")
    if use_search:
        request = {
            "model": "grok-build" if oauth_mode else model,
            "input": _xai_responses_input(messages),
            "tools": [{"type": "web_search"}],
            "max_output_tokens": maxtok,
        }
        if system:
            request["instructions"] = system
        if oauth_mode:
            request["stream"] = True
    else:
        request = {
            # The CLI proxy routes by x-grok-model-override. Its documented
            # body remains grok-build even when another reviewed model is
            # selected; API-key mode sends the selected public API model.
            "model": "grok-build" if oauth_mode else model,
            "messages": ([{"role": "system", "content": system}] if system else [])
                        + list(messages or []),
            "temperature": temperature,
            "max_completion_tokens": maxtok,
            "stream": oauth_mode,
        }
    endpoint = "/responses" if use_search else "/chat/completions"
    async with httpx.AsyncClient(
            timeout=180, follow_redirects=False, trust_env=False) as client:
        response = await _xai_bounded_request(
            client, "POST", f"{base}{endpoint}", headers=headers, json=request,
            action="language-model response")
    if oauth_mode:
        return _xai_stream_text(response, responses_api=use_search)
    payload = response.json()
    return _xai_responses_text(payload) if use_search else _xai_chat_completion_text(payload)


async def _stream_json_events(response, *, sse=True,
                              max_bytes=_MAX_STREAMED_LLM_BYTES):
    """Decode bounded one-line JSON events from SSE or NDJSON responses."""
    length = str((getattr(response, "headers", {}) or {}).get("content-length") or "")
    if length.isdigit() and int(length) > max_bytes:
        raise RuntimeError("the selected model returned an oversized response")
    consumed = 0
    async for line in response.aiter_lines():
        consumed += len(line.encode("utf-8")) + 1
        if consumed > max_bytes:
            raise RuntimeError("the selected model returned an oversized response")
        value = line.strip()
        if not value or (sse and not value.startswith("data:")):
            continue
        if sse:
            value = value[5:].strip()
        if not value or value == "[DONE]":
            continue
        try:
            event = json.loads(value)
        except (TypeError, json.JSONDecodeError) as error:
            raise RuntimeError("the selected model returned an invalid stream") from error
        if not isinstance(event, dict):
            raise RuntimeError("the selected model returned an invalid stream")
        yield event


def _openai_stream_delta(event):
    choices = event.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return ""
    content = (choices[0].get("delta") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            str(block.get("text") or "") for block in content[:256]
            if isinstance(block, dict)
            and block.get("type") in {"text", "output_text"}
        )
    return ""


async def _xai_chat_direct_stream(messages, c, system=""):
    _validate_xai_base_override(c)
    model = (c.get("model") or "").strip() or FALLBACK_MODEL["xai"]
    if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,160}", model):
        raise RuntimeError("Choose a valid xAI model")
    system = str(system or "")
    if len(system) > _MAX_XAI_TEXT_CHARS:
        raise RuntimeError("the xAI system instruction is too long")
    messages = _bounded_xai_messages(messages, len(system))
    maxtok = max(1, min(int(c.get("max_tokens", 160)), 4096))
    try:
        temperature = float(c.get("temperature", 0.8))
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Choose an xAI temperature from 0 to 2") from exc
    if not math.isfinite(temperature) or not 0 <= temperature <= 2:
        raise RuntimeError("Choose an xAI temperature from 0 to 2")
    use_search = bool(c.get("web_search", False))
    base, headers, _secret, mode = await _resolve_xai_auth(
        model=model, cli_for_oauth=True)
    oauth_mode = mode == _xai_oauth_manager().OAUTH2_MODE
    if oauth_mode and model not in XAI_OAUTH_LLM_MODELS:
        raise RuntimeError("Choose a supported Grok model for the shared xAI sign-in")
    headers = {
        **headers,
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    if use_search:
        request = {
            "model": "grok-build" if oauth_mode else model,
            "input": _xai_responses_input(messages),
            "tools": [{"type": "web_search"}],
            "max_output_tokens": maxtok,
            "stream": True,
        }
        if system:
            request["instructions"] = system
    else:
        request = {
            "model": "grok-build" if oauth_mode else model,
            "messages": ([{"role": "system", "content": system}] if system else [])
                        + list(messages or []),
            "temperature": temperature,
            "max_completion_tokens": maxtok,
            "stream": True,
        }
    endpoint = "/responses" if use_search else "/chat/completions"
    latest = ""
    async with httpx.AsyncClient(
            timeout=180, follow_redirects=False, trust_env=False) as client:
        async with client.stream(
                "POST", f"{base}{endpoint}", headers=headers, json=request) as response:
            _require_xai_response(response, "language-model response")
            async for event in _stream_json_events(
                    response, max_bytes=_MAX_XAI_RESPONSE_BYTES):
                kind = str(event.get("type") or "")
                if kind in {"response.output_text.delta", "response.refusal.delta"}:
                    delta = event.get("delta")
                    if isinstance(delta, str):
                        latest += delta
                elif kind == "response.completed" and use_search:
                    completed = event.get("response") or event
                    final = _xai_responses_text(completed)
                    if final:
                        latest = final
                else:
                    latest += _openai_stream_delta(event)
                if len(latest) > _MAX_XAI_TEXT_CHARS:
                    raise RuntimeError("xAI returned an oversized streaming response")
                if latest:
                    yield latest


async def _chat_direct_stream(messages, c, system=""):
    p = c.get("provider")
    if p == "xai":
        async for snapshot in _xai_chat_direct_stream(messages, c, system):
            yield snapshot
        return
    base, key = _base("llm", c), c.get("api_key") or ""
    model = (c.get("model") or "").strip() or FALLBACK_MODEL.get(p, "")
    temp = float(c.get("temperature", 0.8))
    maxtok = int(c.get("max_tokens", 160))
    latest = ""

    async with httpx.AsyncClient(timeout=180) as client:
        if p == "ollama":
            msgs = ([{"role": "system", "content": system}] if system else []) + messages
            async with client.stream(
                    "POST", f"{base or 'http://localhost:11434'}/api/chat", json={
                        "model": model, "messages": msgs, "stream": True, "think": False,
                        "options": {"temperature": temp, "num_predict": maxtok}}) as response:
                response.raise_for_status()
                async for event in _stream_json_events(response, sse=False):
                    _route_observe_model("llm", event.get("model"))
                    latest += str((event.get("message") or {}).get("content") or "")
                    if latest:
                        yield latest
            return

        if p == "anthropic":
            async with client.stream("POST", f"{base}/messages", headers={
                    "x-api-key": key, "anthropic-version": "2023-06-01",
                    "content-type": "application/json", "accept": "text/event-stream"}, json={
                        "model": model, "max_tokens": maxtok, "temperature": temp,
                        "system": system, "messages": messages, "stream": True}) as response:
                response.raise_for_status()
                async for event in _stream_json_events(response):
                    if event.get("type") == "content_block_start":
                        block = event.get("content_block") or {}
                        if isinstance(block, dict) and block.get("type") == "text":
                            latest += str(block.get("text") or "")
                    elif event.get("type") == "content_block_delta":
                        delta = event.get("delta") or {}
                        if isinstance(delta, dict) and delta.get("type") == "text_delta":
                            latest += str(delta.get("text") or "")
                    elif event.get("type") == "error":
                        raise RuntimeError("Anthropic could not complete the streamed response")
                    if latest:
                        yield latest
            return

        if p == "gemini":
            contents = [{"role": "model" if m["role"] == "assistant" else "user",
                         "parts": [{"text": m["content"]}]} for m in messages]
            body = {"contents": contents,
                    "generationConfig": {"temperature": temp, "maxOutputTokens": maxtok}}
            if system:
                body["systemInstruction"] = {"parts": [{"text": system}]}
            async with client.stream(
                    "POST", f"{base}/models/{model}:streamGenerateContent",
                    params={"key": key, "alt": "sse"}, json=body) as response:
                response.raise_for_status()
                async for event in _stream_json_events(response):
                    candidates = event.get("candidates") or []
                    if candidates and isinstance(candidates[0], dict):
                        parts = (candidates[0].get("content") or {}).get("parts") or []
                        latest += "".join(
                            str(part.get("text") or "") for part in parts[:256]
                            if isinstance(part, dict)
                        )
                    if latest:
                        yield latest
            return

        msgs = ([{"role": "system", "content": system}] if system else []) + messages
        headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        body = {"model": model, "messages": msgs, "temperature": temp,
                "max_completion_tokens": maxtok, "stream": True}
        async with client.stream(
                "POST", f"{base}/chat/completions", headers=headers, json=body) as response:
            if response.status_code == 400:
                await response.aread()
            else:
                response.raise_for_status()
                async for event in _stream_json_events(response):
                    latest += _openai_stream_delta(event)
                    if latest:
                        yield latest
                return
        body.pop("max_completion_tokens", None)
        body["max_tokens"] = maxtok
        async with client.stream(
                "POST", f"{base}/chat/completions", headers=headers, json=body) as response:
            response.raise_for_status()
            async for event in _stream_json_events(response):
                latest += _openai_stream_delta(event)
                if latest:
                    yield latest


async def _chat_direct(messages, c, system=""):
    p = c.get("provider")
    if p == "xai":
        return await _xai_chat_direct(messages, c, system)
    base, key = _base("llm", c), c.get("api_key") or ""
    model = (c.get("model") or "").strip() or FALLBACK_MODEL.get(p, "")
    temp = float(c.get("temperature", 0.8))
    maxtok = int(c.get("max_tokens", 160))

    async with httpx.AsyncClient(timeout=180) as x:
        if p == "ollama":
            msgs = ([{"role": "system", "content": system}] if system else []) + messages
            r = await x.post(f"{base or 'http://localhost:11434'}/api/chat", json={
                "model": model, "messages": msgs, "stream": False, "think": False,
                "options": {"temperature": temp, "num_predict": maxtok}})
            r.raise_for_status()
            payload = r.json()
            _route_observe_model("llm", payload.get("model"))
            return (payload.get("message", {}).get("content") or "").strip()

        if p == "anthropic":
            r = await x.post(f"{base}/messages", headers={
                "x-api-key": key, "anthropic-version": "2023-06-01",
                "content-type": "application/json"}, json={
                "model": model, "max_tokens": maxtok, "temperature": temp,
                "system": system, "messages": messages})
            r.raise_for_status()
            return "".join(b.get("text", "") for b in r.json().get("content", [])).strip()

        if p == "gemini":
            contents = [{"role": "model" if m["role"] == "assistant" else "user",
                         "parts": [{"text": m["content"]}]} for m in messages]
            body = {"contents": contents,
                    "generationConfig": {"temperature": temp, "maxOutputTokens": maxtok}}
            if system:
                body["systemInstruction"] = {"parts": [{"text": system}]}
            r = await x.post(f"{base}/models/{model}:generateContent",
                             params={"key": key}, json=body)
            r.raise_for_status()
            cands = r.json().get("candidates") or [{}]
            parts = (cands[0].get("content") or {}).get("parts") or []
            return "".join(q.get("text", "") for q in parts).strip()

        # OpenAI-compatible
        msgs = ([{"role": "system", "content": system}] if system else []) + messages
        h = {"Content-Type": "application/json"}
        if key:
            h["Authorization"] = f"Bearer {key}"
        r = await x.post(f"{base}/chat/completions", headers=h, json={
            "model": model, "messages": msgs,
            "temperature": temp, "max_completion_tokens": maxtok})
        if r.status_code == 400:            # older servers reject the newer field name
            r = await x.post(f"{base}/chat/completions", headers=h, json={
                "model": model, "messages": msgs,
                "temperature": temp, "max_tokens": maxtok})
        r.raise_for_status()
        ch = r.json().get("choices") or [{}]
        return ((ch[0].get("message") or {}).get("content") or "").strip()


# ---------------------------------------------------------------- audio utils

def _ff(raw, in_ext):
    """Anything -> float32 mono at SR. Every engine returns a different container
    (mp3, aiff, raw PCM, opus); normalising here means the browser, the viseme
    track and the duration all see one format."""
    extension = in_ext if re.fullmatch(r"\.[a-z0-9]{1,8}", in_ext or "") else ".bin"
    with tempfile.TemporaryDirectory(prefix="openclam-audio-") as work_dir:
        src = os.path.join(work_dir, f"input{extension}")
        dst = os.path.join(work_dir, "output.wav")
        with open(src, "wb") as handle:
            handle.write(raw)
        result = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", src,
             "-ar", str(SR), "-ac", "1", dst], capture_output=True, text=True)
        if result.returncode or not os.path.isfile(dst):
            raise RuntimeError(safe_error(result.stderr or "audio conversion failed"))
        import soundfile as sf
        samples, _ = sf.read(dst, dtype="float32")
        return np.asarray(samples).reshape(-1)


def to_wav(y):
    import soundfile as sf
    peak = float(np.max(np.abs(y))) if len(y) else 0.0
    if peak > 0:
        y = (y / peak) * 0.92
    buf = io.BytesIO()
    sf.write(buf, y.astype(np.float32), SR, format="WAV", subtype="PCM_16")
    return buf.getvalue()


# ---------------------------------------------------------------- speak

def _kokoro(c):
    if PACKAGED_RUNTIME:
        raise RuntimeError(
            "Kokoro is not included in the signed app; choose macOS say, Edge TTS, "
            "or a direct cloud voice"
        )
    with _lock:
        if _cache["tts"] is None:
            from kokoro import KPipeline
            _cache["tts"] = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    return _cache["tts"]


def _system_say(text, voice, speed):
    with tempfile.TemporaryDirectory(prefix="openclam-say-") as work_dir:
        aiff = os.path.join(work_dir, "speech.aiff")
        cmd = ["say", "-o", aiff]
        if voice:
            cmd += ["-v", voice]
        cmd += ["-r", str(int(180 * speed)), text]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode or not os.path.isfile(aiff):
            raise RuntimeError(safe_error(result.stderr or "macOS speech failed"))
        with open(aiff, "rb") as handle:
            raw = handle.read()
    return _ff(raw, ".aiff")


def _kokoro_audio(text, c, voice, speed):
    results = list(_kokoro(c)(text, voice=voice or "af_heart", speed=speed))
    output = []
    for result in results:
        audio = result.audio
        audio = audio.detach().cpu().numpy() if hasattr(audio, "detach") else np.asarray(audio)
        output.append(np.asarray(audio, dtype=np.float32).reshape(-1))
    samples = np.concatenate(output) if output else np.zeros(0, np.float32)
    return samples, ("kokoro", results)


async def speak(text, c):
    """-> (samples, alignment) where alignment is either Kokoro Result objects
    (exact), a word/char timing list, or None (estimate from the text)."""
    if not spec("tts", c.get("provider")):
        raise RuntimeError("Choose a direct speaking voice in OpenClam Settings")
    _route_begin("tts", _direct_route("tts", c))
    try:
        result = await _speak_direct(text, c)
        _route_finish("tts", "success")
        return result
    except Exception:
        _route_finish("tts", "failed")
        raise


async def _speak_direct(text, c):
    p = c.get("provider")
    base, key = _base("tts", c), c.get("api_key") or ""
    voice = c.get("voice") or ""
    model = c.get("model") or ""
    speed = float(c.get("speed", 1.0))

    # The synthesis leaves BLOCK - Kokoro is a torch forward, say and _ff
    # are subprocess.run - and speak() is awaited from the live-talk
    # socket loop. Run on the event loop they froze the mic: nothing read
    # audio during synthesis, so barge-in could not fire until she had
    # already finished the sentence (#24 prerequisite). to_thread keeps
    # the loop listening while the leaf grinds.
    if p == "kokoro":
        return await asyncio.to_thread(_kokoro_audio, text, c, voice, speed)

    if p == "system":
        return await asyncio.to_thread(_system_say, text, voice, speed), None

    if p == "edge":
        import edge_tts
        rate = f"{int(round((speed - 1) * 100)):+d}%"
        com = edge_tts.Communicate(text, voice or "en-US-AvaNeural", rate=rate)
        buf, words, sents = bytearray(), [], []
        async for ch in com.stream():
            t = ch.get("type")
            if t == "audio":
                buf += ch["data"]
            elif t == "WordBoundary":
                words.append((ch["offset"] / 1e7, ch["duration"] / 1e7, ch["text"]))
            elif t == "SentenceBoundary":
                sents.append((ch["offset"] / 1e7, ch["duration"] / 1e7, ch["text"]))
        y = await asyncio.to_thread(_ff, bytes(buf), ".mp3")
        # edge-tts 7.x streams SentenceBoundary and no WordBoundary at all, so
        # asking for the finer grain and assuming it arrived produced an EMPTY
        # track - a "timed" tier that was worse than the estimate it replaced.
        # Degrade one rung at a time instead of to nothing.
        if words:
            return y, ("words", words)
        if sents:
            return y, ("spans", sents)
        return y, None

    if p == "xai":
        _validate_xai_base_override(c)
        spoken = str(text or "")
        if (not spoken or len(spoken) > 15_000
                or len(spoken.encode("utf-8")) > 15_000):
            raise RuntimeError("xAI speech text must be 1 to 15,000 characters/bytes")
        language = str(c.get("language") or "auto").strip()
        if language != "auto" and not re.fullmatch(
                r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}", language):
            raise RuntimeError("Choose a supported xAI speech language")
        voice_id = str(voice or "eve").strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", voice_id):
            raise RuntimeError("Choose a supported xAI voice")
        base, headers, _secret, _mode = await _resolve_xai_auth()
        headers = {**headers, "Content-Type": "application/json"}
        request = {
            "text": spoken,
            "voice_id": voice_id,
            "language": language,
            "with_timestamps": True,
        }
        async with httpx.AsyncClient(
                timeout=180, follow_redirects=False, trust_env=False) as x:
            r = await _xai_bounded_request(
                x, "POST", f"{base}/tts", headers=headers, json=request,
                action="speech synthesis", max_bytes=96 * 1024 * 1024)
        payload = r.json()
        encoded = payload.get("audio")
        if not isinstance(encoded, str) or len(encoded) > 96 * 1024 * 1024:
            raise RuntimeError("xAI returned invalid speech audio")
        try:
            audio = base64.b64decode(encoded, validate=True)
        except Exception as exc:
            raise RuntimeError("xAI returned invalid speech audio") from exc
        if not audio or len(audio) > 64 * 1024 * 1024:
            raise RuntimeError("xAI returned invalid speech audio")
        content_type = str(payload.get("content_type") or "audio/mpeg").lower()
        extension = ".wav" if "wav" in content_type else ".mp3"
        y = await asyncio.to_thread(_ff, audio, extension)
        timestamps = payload.get("audio_timestamps") or {}
        chars, ranges = timestamps.get("graph_chars") or [], \
            timestamps.get("graph_times") or []
        alignment = []
        if isinstance(chars, list) and isinstance(ranges, list):
            for char, span in list(zip(chars, ranges))[:100_000]:
                if (isinstance(char, str) and isinstance(span, (list, tuple))
                        and len(span) == 2):
                    try:
                        alignment.append((char, float(span[0]), float(span[1])))
                    except (TypeError, ValueError):
                        continue
        return y, (("chars", alignment) if alignment else None)

    if p == "elevenlabs":
        vid = (voice or "").split()[0]
        async with httpx.AsyncClient(timeout=180) as x:
            r = await x.post(f"{base}/text-to-speech/{vid}/with-timestamps",
                             headers={"xi-api-key": key},
                             json={"text": text,
                                   "model_id": model or "eleven_turbo_v2_5"})
            r.raise_for_status()
            j = r.json()
        y = await asyncio.to_thread(_ff, base64.b64decode(j["audio_base64"]),
                                    ".mp3")
        al = j.get("alignment") or {}
        chars = list(zip(al.get("characters") or [],
                         al.get("character_start_times_seconds") or [],
                         al.get("character_end_times_seconds") or []))
        return y, (("chars", chars) if chars else None)

    if p == "gemini":
        async with httpx.AsyncClient(timeout=180) as x:
            r = await x.post(f"{base}/models/{model or 'gemini-2.5-flash-preview-tts'}:generateContent",
                             params={"key": key}, json={
                    "contents": [{"parts": [{"text": text}]}],
                    "generationConfig": {
                        "responseModalities": ["AUDIO"],
                        "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {
                            "voiceName": voice or "Kore"}}}}})
            r.raise_for_status()
            parts = r.json()["candidates"][0]["content"]["parts"]
        b = next(q["inlineData"]["data"] for q in parts if "inlineData" in q)
        pcm = np.frombuffer(base64.b64decode(b), dtype=np.int16).astype(np.float32) / 32768
        # Gemini returns headerless 24k mono PCM, which is already our rate
        return pcm, None

    if p == "deepgram":
        async with httpx.AsyncClient(timeout=180) as x:
            r = await x.post(
                f"{base}/speak",
                params={"model": model or voice or "aura-2-thalia-en",
                        "encoding": "linear16", "sample_rate": str(SR)},
                headers={"Authorization": f"Token {key}",
                         "Content-Type": "application/json"},
                json={"text": text})
            r.raise_for_status()
            return np.frombuffer(r.content, "<i2").astype(np.float32) / 32768.0, None

    if p == "cartesia":
        async with httpx.AsyncClient(timeout=180) as x:
            r = await x.post(
                f"{base}/tts/bytes",
                headers={"Authorization": f"Bearer {key}",
                         "Cartesia-Version": "2025-04-16"},
                json={"model_id": model or "sonic-3",
                      "transcript": text,
                      "voice": {"mode": "id",
                                "id": voice or "694f9389-aac1-45b6-b726-9d9369183238"},
                      "output_format": {"container": "raw",
                                        "encoding": "pcm_s16le",
                                        "sample_rate": SR}})
            r.raise_for_status()
            return np.frombuffer(r.content, "<i2").astype(np.float32) / 32768.0, None

    # OpenAI /v1/audio/speech (and anything that copies it)
    async with httpx.AsyncClient(timeout=180) as x:
        r = await x.post(f"{base}/audio/speech",
                         headers={"Authorization": f"Bearer {key}"},
                         json={"model": model or "gpt-4o-mini-tts",
                               "input": text, "voice": voice or "alloy",
                               "response_format": "wav", "speed": speed})
        r.raise_for_status()
        return await asyncio.to_thread(_ff, r.content, ".wav"), None


# ---------------------------------------------------------------- hear


def _expected_mlx_whisper_manifest():
    return {
        "schema_version": 1,
        "model_id": MLX_WHISPER_MODEL_ID,
        "revision": MLX_WHISPER_MODEL_REVISION,
        "license_source": {
            "repository": "openai/whisper",
            "revision": MLX_WHISPER_LICENSE_REVISION,
            "path": "LICENSE",
        },
        "files": json.loads(json.dumps(MLX_WHISPER_FILES)),
    }


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_mlx_whisper_bundle(root):
    """Accept only the model files that the release build hash-checked.

    mlx_whisper treats any nonexistent path as a Hugging Face repository ID.
    Resolving and verifying the local directory before calling it is therefore
    the boundary that prevents an implicit network download from warmup or PTT.
    """
    root = os.path.abspath(root)
    expected_names = set(MLX_WHISPER_FILES) | {MLX_WHISPER_MANIFEST}
    try:
        entries = list(os.scandir(root))
        entry_names = {entry.name for entry in entries}
        regular_names = {
            entry.name for entry in entries if entry.is_file(follow_symlinks=False)
        }
        if (entry_names != expected_names or regular_names != expected_names
                or any(entry.is_symlink() for entry in entries)):
            raise ValueError("unexpected files")
        fingerprint = tuple(
            (name, os.stat(os.path.join(root, name), follow_symlinks=False).st_size,
             os.stat(os.path.join(root, name), follow_symlinks=False).st_mtime_ns)
            for name in sorted(expected_names)
        )
    except (OSError, ValueError) as error:
        raise RuntimeError("the bundled offline Whisper model is incomplete") from error

    with _model_lock:
        if _verified_mlx_models.get(root) == fingerprint:
            return root

    try:
        with open(os.path.join(root, MLX_WHISPER_MANIFEST), encoding="utf-8") as handle:
            manifest = json.load(handle)
        if manifest != _expected_mlx_whisper_manifest():
            raise ValueError("manifest mismatch")
        for name, record in MLX_WHISPER_FILES.items():
            path = os.path.join(root, name)
            if os.path.getsize(path) != record["size"]:
                raise ValueError(f"{name} size mismatch")
            if _sha256_file(path) != record["sha256"]:
                raise ValueError(f"{name} checksum mismatch")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("the bundled offline Whisper model failed verification") from error

    with _model_lock:
        _verified_mlx_models[root] = fingerprint
    return root


def resolve_mlx_whisper_model(model=""):
    """Map the public settings ID to an already-staged local model directory.

    Installed builds carry it under backend/models. Source development uses
    the generated .electron-models directory produced explicitly by
    ``npm run fetch:model``. Neither path permits mlx_whisper's repository-ID
    fallback, so microphone audio can never trigger a model download.
    """
    selected = str(model or MLX_WHISPER_MODEL_ID)
    if selected != MLX_WHISPER_MODEL_ID:
        raise RuntimeError(
            f"This OpenClam build includes only {MLX_WHISPER_MODEL_ID}. "
            "Choose that offline model in Settings; runtime model downloads are disabled."
        )
    candidates = (
        os.path.join(CODE_ROOT, "models", MLX_WHISPER_MODEL_DIR),
        os.path.join(CODE_ROOT, ".electron-models", MLX_WHISPER_MODEL_DIR),
    )
    invalid = False
    for candidate in candidates:
        if not os.path.isdir(candidate):
            continue
        try:
            return _verify_mlx_whisper_bundle(candidate)
        except RuntimeError:
            invalid = True
    state = "failed verification" if invalid else "is missing"
    raise RuntimeError(
        f"The bundled offline Whisper model {state}. Reinstall OpenClam Studio. "
        "Source developers can run `npm run fetch:model`; PTT never downloads models."
    )


# The one realtime STT websocket endpoint; the /stt/stream bridge in
# server/app.py speaks the same protocol for live dictation.
SONIOX_RT_WSS = "wss://stt-rt.soniox.com/transcribe-websocket"


def _soniox_config(c):
    model = str(c.get("model") or "")
    if not model.startswith("stt-rt"):
        model = "stt-rt-v5"
    config = {"api_key": c.get("api_key") or "", "model": model,
              "audio_format": "auto"}
    language = str(c.get("language") or "")
    if language and language != "auto":
        config["language_hints"] = [language]
    return config


async def _soniox_stream(config, frames):
    """Run one take through Soniox realtime and return the final transcript.

    Measured live: finalisation requires an empty TEXT frame - the
    documented empty-binary alternative just times out.
    """
    import websockets
    finals = []
    async with websockets.connect(
            SONIOX_RT_WSS, max_size=1 << 22, open_timeout=10) as upstream:
        await upstream.send(json.dumps(config))
        for frame in frames:
            await upstream.send(frame)
        await upstream.send("")
        async for message in upstream:
            payload = json.loads(message)
            if payload.get("error_code") or payload.get("error_message"):
                raise RuntimeError(str(
                    payload.get("error_message") or "Soniox error")[:200])
            for token in payload.get("tokens") or []:
                if token.get("is_final"):
                    finals.append(str(token.get("text") or ""))
            if payload.get("finished"):
                break
    return "".join(finals).strip()


async def _soniox_validate(c):
    """A key is proven by a full round trip: config, end frame, response.

    An empty take draws "No audio received." - which means authentication
    already succeeded and the session reached the audio stage, so that
    specific complaint counts as a pass. A bad key fails before it.
    """
    try:
        await _soniox_stream(_soniox_config(c), [])
    except RuntimeError as error:
        if "no audio" in str(error).lower():
            return True
        raise
    return True


async def hear(raw, filename, c):
    if not spec("stt", c.get("provider")):
        raise RuntimeError("Choose a direct speech recognizer in OpenClam Settings")
    _route_begin("stt", _direct_route("stt", c))
    try:
        text = await _hear_direct(raw, filename, c)
        _route_finish("stt", "success")
        return text
    except Exception:
        _route_finish("stt", "failed")
        raise


async def _hear_direct(raw, filename, c):
    p = c.get("provider")
    base, key = _base("stt", c), c.get("api_key") or ""
    model = c.get("model") or ""
    # Reject a provider/language mismatch before opening a microphone upload
    # request. In particular, xAI automatic recognition excludes Chinese;
    # its language field is a formatting hint, not a capability override.
    lang = validate_stt_language(p, c.get("language"))

    if p == "soniox":
        if not key:
            raise RuntimeError("Soniox needs an API key")
        # One whole take through the realtime socket: the same protocol the
        # live-dictation bridge uses, so batch and streaming always agree.
        frames = [raw[start:start + 65536]
                  for start in range(0, len(raw), 65536)]
        return await _soniox_stream(_soniox_config(c), frames)

    if p == "mlx_whisper":
        import mlx_whisper
        local_model = resolve_mlx_whisper_model(model)
        extension = os.path.splitext(filename)[1].lower()
        if not re.fullmatch(r"\.[a-z0-9]{1,8}", extension or ""):
            extension = ".webm"
        with tempfile.TemporaryDirectory(prefix="openclam-whisper-") as work_dir:
            src = os.path.join(work_dir, f"input{extension}")
            wav = os.path.join(work_dir, "decoded.wav")
            with open(src, "wb") as handle:
                handle.write(raw)
            result = subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", src,
                 "-ar", "16000", "-ac", "1", wav], capture_output=True, text=True)
            if result.returncode or not os.path.isfile(wav):
                raise RuntimeError(safe_error(result.stderr or "audio conversion failed"))
            import soundfile as sf
            audio, sample_rate = sf.read(wav, dtype="float32")
            if sample_rate != 16000:
                raise RuntimeError("offline Whisper audio conversion returned the wrong rate")
            audio = np.asarray(audio, dtype=np.float32).reshape(-1)
            response = mlx_whisper.transcribe(
                audio, path_or_hf_repo=local_model,
                language=None if lang in ("", "auto") else lang)
            return (response.get("text") or "").strip()

    if p == "xai":
        _validate_xai_base_override(c)
        if not isinstance(raw, (bytes, bytearray)) or not raw \
                or len(raw) > 50 * 1024 * 1024:
            raise RuntimeError("xAI transcription accepts audio up to 50 MiB")
        base, headers, _secret, _mode = await _resolve_xai_auth()
        safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "-", os.path.basename(
            str(filename or "audio.webm")))[:160] or "audio.webm"
        # Recognition language is provider-side automatic within xAI's exact
        # 25-language list. Automatic mode omits both optional fields; an
        # explicit supported code enables xAI's inverse-text-formatting hint.
        # Never send `auto`, `multi`, or an unsupported language as if it
        # could expand recognition beyond that fixed list.
        data = {}
        if lang != "auto":
            data = {"language": lang, "format": "true"}
        async with httpx.AsyncClient(
                timeout=120, follow_redirects=False, trust_env=False) as x:
            r = await _xai_bounded_request(
                x, "POST", f"{base}/stt", headers=headers,
                files={"file": (safe_name, bytes(raw), "application/octet-stream")},
                data=data,
                action="speech transcription")
        text = str(r.json().get("text") or "").strip()
        if len(text) > _MAX_XAI_TEXT_CHARS:
            raise RuntimeError("xAI returned an oversized transcript")
        return text

    if p == "gemini":
        async with httpx.AsyncClient(timeout=120) as x:
            r = await x.post(f"{base}/models/{model or 'gemini-2.5-flash'}:generateContent",
                             params={"key": key}, json={"contents": [{"parts": [
                    {"text": "Transcribe this audio verbatim. Reply with the transcript only."},
                    {"inlineData": {"mimeType": "audio/webm",
                                    "data": base64.b64encode(raw).decode()}}]}]})
            r.raise_for_status()
            parts = (r.json()["candidates"][0].get("content") or {}).get("parts") or []
        return "".join(q.get("text", "") for q in parts).strip()

    # OpenAI-compatible multipart
    if p == "deepgram":
        params = {
            "model": model or "nova-3",
            "smart_format": "true",
            "language": "multi" if lang in ("auto", "multi") else lang,
        }
        async with httpx.AsyncClient(timeout=120) as x:
            r = await x.post(f"{base}/listen", params=params,
                             headers={"Authorization": f"Token {key}",
                                      "Content-Type": "application/octet-stream"},
                             content=raw)
            r.raise_for_status()
            alternatives = (((r.json().get("results") or {}).get("channels")
                             or [{}])[0].get("alternatives") or [{}])
            return (alternatives[0].get("transcript") or "").strip()

    if p == "elevenlabs":
        async with httpx.AsyncClient(timeout=120) as x:
            r = await x.post(f"{base}/speech-to-text",
                             headers={"xi-api-key": key},
                             files={"file": (filename or "audio.webm", raw)},
                             data={"model_id": model or "scribe_v1"})
            r.raise_for_status()
            return (r.json().get("text") or "").strip()

    files = {"file": (filename or "audio.webm", raw, "application/octet-stream")}
    data = {"model": model or "whisper-1"}
    if lang and lang != "auto":
        data["language"] = lang
    async with httpx.AsyncClient(timeout=120) as x:
        r = await x.post(f"{base}/audio/transcriptions",
                         headers={"Authorization": f"Bearer {key}"},
                         files=files, data=data)
        r.raise_for_status()
        return (r.json().get("text") or "").strip()


# ---------------------------------------------------------------- test

async def test(kind, c):
    try:
        if kind == "llm":
            t = await chat([{"role": "user", "content": "Reply with exactly: ok"}], c,
                           system="You reply with one word.")
            return dict(ok=True, detail=(t or "")[:80] or "empty reply")
        if kind == "tts":
            y, al = await speak("Testing, one two.", c)
            kind_of = al[0] if al else "estimated"
            return dict(ok=len(y) > 0,
                        detail=f"{len(y)/SR:.1f}s of audio, timing: {kind_of}")
        if kind == "stt":
            if c.get("provider") == "mlx_whisper":
                resolve_mlx_whisper_model(c.get("model"))
                return dict(ok=True, detail="bundled offline model verified")
            return dict(ok=bool(await list_models("stt", c)),
                        detail="credentials accepted")
        if kind == "image":
            # A real (tiny) render: the only test that proves the whole path.
            # Validate the request object before passing it to the direct
            # provider payload builder; unsupported bearer material must not
            # reach even a mocked provider call.
            _validated_image_runtime_base(c)
            import media_gen
            path = await media_gen.generate_image(
                "a single small blue circle on white, minimal test pattern", c)
            return dict(ok=os.path.isfile(path),
                        detail=f"rendered {os.path.getsize(path) // 1024} KB")
        if kind == "video":
            # Credentials only - a real render costs real money.
            import media_gen
            p = c.get("provider")
            if p == "xai":
                await list_models("video", c)
                return dict(ok=True, detail="credentials accepted")
            if not (c.get("api_key") or ""):
                return dict(ok=False, detail="no API key stored")
            checks = {
                "openai": ("https://api.openai.com/v1/models",
                           {"Authorization": f"Bearer {c.get('api_key')}"}),
                "gemini": ("https://generativelanguage.googleapis.com/v1beta/"
                           f"models?key={c.get('api_key')}", {}),
                "luma": ("https://api.lumalabs.ai/dream-machine/v1/generations"
                         "?limit=1",
                         {"Authorization": f"Bearer {c.get('api_key')}"}),
                "runway": ("https://api.dev.runwayml.com/v1/organization",
                           {"Authorization": f"Bearer {c.get('api_key')}",
                            "X-Runway-Version": "2024-11-06"}),
            }
            url, headers = checks.get(p, (None, None))
            if not url:
                return dict(ok=False, detail=f"unknown provider {p}")
            async with httpx.AsyncClient(timeout=30, follow_redirects=False) as x:
                r = await x.get(url, headers=headers)
                if 300 <= r.status_code < 400:
                    return dict(ok=False, detail="provider tried to redirect the check")
                return dict(ok=r.status_code < 400,
                            detail="credentials accepted" if r.status_code < 400
                            else f"provider said {r.status_code}")
    except Exception as e:
        return dict(ok=False, detail=safe_error(e))
    return dict(ok=False, detail="unknown check")
