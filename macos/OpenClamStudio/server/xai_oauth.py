"""Secure xAI OAuth compatibility for the macOS app.

This module owns the complete credential boundary for a device-code flow using
the public client identity embedded in xAI's Grok Build.  The renderer receives
the user code and verification URL, but never the device code, access token,
refresh token, or Keychain account.

OAuth is an explicit global authentication mode.  API-key and OAuth
credentials are never inferred from one another and there is no silent
fallback between them.  OpenClam is an independent client: compatibility with
Grok Build's public OAuth identity does not import Grok Build credentials,
claim an OpenClam registration, or imply an xAI partnership.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import datetime
import json
import math
import os
import re
import secrets
import tempfile
import threading
import time
from dataclasses import dataclass, field
from typing import Literal
from urllib.parse import urlsplit

import httpx

try:
    import credentials
except ModuleNotFoundError:  # package import in tests and embedded runtimes
    from . import credentials


AUTH_ORIGIN = "https://auth.x.ai"
DEVICE_AUTHORIZATION_ENDPOINT = f"{AUTH_ORIGIN}/oauth2/device/code"
TOKEN_ENDPOINT = f"{AUTH_ORIGIN}/oauth2/token"
REVOCATION_ENDPOINT = f"{AUTH_ORIGIN}/oauth2/revoke"

# Audited against xAI's public Grok Build source at the pinned revision below:
# https://github.com/xai-org/grok-build/blob/eb267feff13129e568df38fb6fdf0ceb65f735d6/
#   crates/codegen/xai-grok-shell/src/auth/config.rs
#
# This is intentionally a compatibility identity, not an OpenClam-owned OAuth
# registration. It is public configuration rather than a secret. Production
# never accepts an environment/config override; a release gate rejects any
# drift in the identity, scopes, or audited upstream revision.
GROK_BUILD_COMPAT_SOURCE_REVISION = (
    "eb267feff13129e568df38fb6fdf0ceb65f735d6"
)
GROK_BUILD_COMPAT_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
# Grok Build can replace its Cargo package version at release time through the
# compile-time GROK_VERSION value.  The pinned source package falls back to
# 1.0.3, but xAI's current stable/alpha release channel is stamped 1.0.4; the
# CLI proxy rejects the fallback as stale with HTTP 426.  Pin the released
# wire value rather than the source-package fallback.
GROK_BUILD_COMPAT_CLIENT_VERSION = "1.0.4"
GROK_BUILD_COMPAT_CLIENT_IDENTIFIER = "grok-shell"
GROK_BUILD_COMPAT_AUTHENTICATE_RESPONSE = "authenticate-response"
GROK_BUILD_COMPAT_CLIENT_MODE = "interactive"
GROK_BUILD_COMPAT_USER_AGENT = (
    f"grok-shell/{GROK_BUILD_COMPAT_CLIENT_VERSION} (macos; aarch64)"
)

SCOPES = (
    "openid",
    "profile",
    "email",
    "offline_access",
    "grok-cli:access",
    "api:access",
    "conversations:read",
    "conversations:write",
    "workspaces:read",
    "workspaces:write",
)

API_KEY_MODE = "api_key"
OAUTH2_MODE = "oauth2"
DISCONNECTED_MODE = "disconnected"
SELECTABLE_MODES = frozenset((API_KEY_MODE, OAUTH2_MODE))

API_TARGET = "api"
CLI_PROXY_TARGET = "cli_proxy"
XAI_API_BASE = "https://api.x.ai/v1"
XAI_CLI_PROXY_BASE = "https://cli-chat-proxy.grok.com/v1"

OAUTH_CREDENTIAL_ACCOUNT = "xai.oauth2"
AUTH_MODE_ACCOUNT = "xai.auth_mode"
API_KEY_ACCOUNT = "keys.xai"
DATA_ROOT = credentials.application_data_root(
    os.path.dirname(os.path.dirname(__file__)))
DEV_MODE_FILE = os.path.join(DATA_ROOT, "xai-account.json")

EARLY_REFRESH_SECONDS = 300
MAX_TOKEN_LIFETIME_SECONDS = 7 * 24 * 60 * 60
MAX_RESPONSE_BYTES = 64 * 1024
MAX_TOKEN_BYTES = 64 * 1024
MAX_PENDING_SECONDS = 60 * 60
MIN_POLL_INTERVAL = 1
MAX_POLL_INTERVAL = 30

INDEPENDENCE_NOTICE = (
    "Grok Build compatibility uses xAI's public Grok Build OAuth client "
    "identity. OpenClam remains independent: it does not import Grok Build "
    "credentials, claim an OpenClam registration, or imply an xAI partnership. "
    "Compatibility depends on xAI continuing to accept that public identity; "
    "API-key mode remains separate."
)

_CLIENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9._~-]{10,200}$")
_MODEL_PATTERN = re.compile(r"^[A-Za-z0-9._:/-]{1,160}$")
_FLOW_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{20,80}$")
_ALLOWED_VERIFICATION_HOSTS = frozenset(("auth.x.ai", "accounts.x.ai"))
_FIXED_ENDPOINTS = frozenset((
    DEVICE_AUTHORIZATION_ENDPOINT,
    TOKEN_ENDPOINT,
    REVOCATION_ENDPOINT,
))


class XaiOAuthError(RuntimeError):
    """An intentionally safe, stable error for the local API boundary."""

    code = "xai_oauth_protocol_error"
    status_code = 502

    def __init__(self, code: str | None = None, status_code: int | None = None):
        self.code = code or self.code
        self.status_code = status_code or self.status_code
        # RuntimeError's representation contains only the stable code, never
        # response bodies, token values, URLs with codes, or HTTP form data.
        super().__init__(self.code)


class XaiOAuthNotConnected(XaiOAuthError):
    code = "xai_oauth_not_connected"
    status_code = 409


class XaiOAuthReconnectRequired(XaiOAuthError):
    code = "xai_oauth_reconnect_required"
    status_code = 401


class XaiOAuthTransientError(XaiOAuthError):
    code = "xai_oauth_unavailable"
    status_code = 503


class XaiOAuthStorageError(XaiOAuthError):
    code = "xai_oauth_storage_unavailable"
    status_code = 503


@dataclass(frozen=True, slots=True)
class ResolvedAuth:
    """One explicitly selected xAI bearer.

    ``repr=False`` and slots keep accidental logging/serialization from
    exposing the bearer.  Callers should use ``headers`` rather than assemble
    target-specific identity headers themselves.
    """

    mode: Literal["api_key", "oauth2"]
    bearer_token: str = field(repr=False)

    def headers(self, target: str, model: str | None = None) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {self.bearer_token}"}
        if target == API_TARGET:
            return headers
        if target != CLI_PROXY_TARGET:
            raise XaiOAuthError("xai_auth_target_invalid", 500)
        if self.mode != OAUTH2_MODE:
            # The CLI proxy accepts the xAI session-token contract, not a
            # pay-as-you-go console API key selected in API-key mode.
            raise XaiOAuthError("xai_auth_target_invalid", 409)
        headers["X-XAI-Token-Auth"] = "xai-grok-cli"
        headers["x-grok-client-version"] = GROK_BUILD_COMPAT_CLIENT_VERSION
        headers["x-grok-client-identifier"] = (
            GROK_BUILD_COMPAT_CLIENT_IDENTIFIER
        )
        headers["x-authenticateresponse"] = (
            GROK_BUILD_COMPAT_AUTHENTICATE_RESPONSE
        )
        headers["x-grok-client-mode"] = GROK_BUILD_COMPAT_CLIENT_MODE
        headers["User-Agent"] = GROK_BUILD_COMPAT_USER_AGENT
        if model is not None:
            model = str(model).strip()
            if not _MODEL_PATTERN.fullmatch(model):
                raise XaiOAuthError("xai_model_invalid", 422)
            headers["x-grok-model-override"] = model
        return headers


@dataclass(frozen=True, slots=True)
class _OAuthCredential:
    access_token: str = field(repr=False)
    refresh_token: str = field(repr=False)
    expires_at: float
    token_type: str
    scope: str
    client_id: str


@dataclass(slots=True)
class _PendingDeviceFlow:
    device_code: str = field(repr=False)
    client_id: str
    operation_generation: int
    expires_at: float
    interval: int
    next_poll_at: float


_pending_lock = threading.Lock()
_pending_flows: dict[str, _PendingDeviceFlow] = {}
_refresh_lock = threading.Lock()
_refresh_flight: concurrent.futures.Future | None = None
_credential_state_lock = threading.RLock()
_credential_generation = 0
_device_operation_generation = 0

# In-process test seams.  Production code never assigns either value and they
# cannot be influenced by an inherited environment variable.
_TEST_TRANSPORT: httpx.AsyncBaseTransport | None = None
_TEST_CLOCK = None
_TEST_CLIENT_ID: str | None = None
_DEV_SESSION_CREDENTIAL: _OAuthCredential | None = None


def _dev_session_only() -> bool:
    """Unsigned development keeps OAuth solely in this backend process.

    A signed release has a stable Keychain identity and persists its refresh
    record there. The npm/Electron development host does not: attempting to
    reuse an item created by another signature returns errSecAuthFailed. Do
    not weaken or rewrite that item's ACL and never spill OAuth JSON onto
    disk. Development consent therefore lasts only until the app restarts.
    """
    return credentials.development_session_only()


def _dev_mode_read() -> str:
    try:
        with open(DEV_MODE_FILE, encoding="utf-8") as handle:
            value = json.load(handle).get("auth_mode")
    except (OSError, ValueError, TypeError, AttributeError):
        value = ""
    return value if value in SELECTABLE_MODES else API_KEY_MODE


def _dev_mode_write(mode: str) -> None:
    directory = os.path.dirname(DEV_MODE_FILE)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".xai-account-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump({"auth_mode": mode}, handle)
        os.chmod(temporary, 0o600)
        os.replace(temporary, DEV_MODE_FILE)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def _mode_put(mode: str) -> None:
    if _dev_session_only():
        try:
            _dev_mode_write(mode)
        except OSError:
            raise XaiOAuthStorageError() from None
    else:
        _vault_put(AUTH_MODE_ACCOUNT, mode)


def _clear_credential() -> None:
    global _DEV_SESSION_CREDENTIAL
    if _dev_session_only():
        _DEV_SESSION_CREDENTIAL = None
    else:
        _vault_clear(OAUTH_CREDENTIAL_ACCOUNT)


def _now() -> float:
    return float(_TEST_CLOCK() if _TEST_CLOCK is not None else time.time())


def _device_operation_generation_snapshot() -> int:
    with _credential_state_lock:
        return _device_operation_generation


def client_id() -> str:
    # Production accepts only the audited compatibility identity embedded in
    # signed source. Environment/config input must never replace it. Tests
    # inject a non-secret fixture in-process.
    value = str(
        GROK_BUILD_COMPAT_CLIENT_ID
        if _TEST_CLIENT_ID is None
        else _TEST_CLIENT_ID
    ).strip()
    if not _CLIENT_ID_PATTERN.fullmatch(value):
        raise XaiOAuthError("xai_oauth_client_config_invalid", 503)
    return value


def _oauth_client_available() -> bool:
    try:
        client_id()
    except XaiOAuthError:
        return False
    return True


def _vault_get(account: str) -> str:
    try:
        return credentials.get(account)
    except Exception:
        raise XaiOAuthStorageError() from None


def _vault_put(account: str, value: str) -> None:
    try:
        credentials.put(account, value)
    except Exception:
        raise XaiOAuthStorageError() from None


def _vault_clear(account: str) -> None:
    try:
        credentials.clear(account)
    except Exception:
        raise XaiOAuthStorageError() from None


def _valid_token(value, *, required: bool) -> str:
    token = value if isinstance(value, str) else ""
    try:
        encoded = token.encode("utf-8")
    except UnicodeEncodeError:
        encoded = b""
    if (required and not encoded) or len(encoded) > MAX_TOKEN_BYTES:
        raise XaiOAuthReconnectRequired()
    if any(
        character.isspace()
        or ord(character) < 0x20
        or ord(character) == 0x7F
        for character in token
    ):
        raise XaiOAuthReconnectRequired()
    return token


def _scope_string(value) -> str:
    if isinstance(value, list):
        value = " ".join(str(item) for item in value)
    value = str(value or " ".join(SCOPES)).strip()
    if len(value) > 2048 or any(ord(character) < 0x20 for character in value):
        raise XaiOAuthReconnectRequired()
    return value


def _serialize_credential(credential: _OAuthCredential) -> str:
    return json.dumps({
        "version": 1,
        "issuer": AUTH_ORIGIN,
        "client_id": credential.client_id,
        "access_token": credential.access_token,
        "refresh_token": credential.refresh_token,
        "expires_at": credential.expires_at,
        "token_type": credential.token_type,
        "scope": credential.scope,
    }, separators=(",", ":"), sort_keys=True)


def _load_credential() -> _OAuthCredential | None:
    if _dev_session_only():
        return _DEV_SESSION_CREDENTIAL
    raw = _vault_get(OAUTH_CREDENTIAL_ACCOUNT)
    if not raw:
        return None
    if len(raw.encode("utf-8", "ignore")) > MAX_RESPONSE_BYTES:
        raise XaiOAuthReconnectRequired()
    try:
        value = json.loads(raw)
        expires_at = float(value["expires_at"])
    except (TypeError, ValueError, KeyError, json.JSONDecodeError):
        raise XaiOAuthReconnectRequired() from None
    if not isinstance(value, dict) or value.get("version") != 1:
        raise XaiOAuthReconnectRequired()
    if value.get("issuer") != AUTH_ORIGIN or value.get("client_id") != client_id():
        raise XaiOAuthReconnectRequired()
    if not math.isfinite(expires_at) or expires_at <= 0:
        raise XaiOAuthReconnectRequired()
    token_type = str(value.get("token_type") or "Bearer")
    if token_type.lower() != "bearer":
        raise XaiOAuthReconnectRequired()
    return _OAuthCredential(
        access_token=_valid_token(value.get("access_token"), required=True),
        refresh_token=_valid_token(value.get("refresh_token"), required=False),
        expires_at=expires_at,
        token_type="Bearer",
        scope=_scope_string(value.get("scope")),
        client_id=value["client_id"],
    )


def _store_credential(credential: _OAuthCredential) -> None:
    global _DEV_SESSION_CREDENTIAL
    if _dev_session_only():
        _DEV_SESSION_CREDENTIAL = credential
        return
    # One JSON value is one atomic Keychain item: access and rotating refresh
    # credentials cannot drift into mismatched records.
    _vault_put(OAUTH_CREDENTIAL_ACCOUNT, _serialize_credential(credential))


def auth_mode() -> str:
    if _dev_session_only():
        return _dev_mode_read()
    value = _vault_get(AUTH_MODE_ACCOUNT)
    if not value:
        return API_KEY_MODE
    if value in SELECTABLE_MODES or value == DISCONNECTED_MODE:
        return value
    # A malformed local value never triggers credential inference.
    return DISCONNECTED_MODE


def set_auth_mode(mode: str) -> dict:
    global _credential_generation, _device_operation_generation
    if mode not in SELECTABLE_MODES:
        raise XaiOAuthError("xai_auth_mode_invalid", 422)
    if mode == OAUTH2_MODE:
        # Never persist a mode that the signed build cannot actually use.
        client_id()
    with _credential_state_lock:
        # A mode change is an explicit routing decision. Any older consent
        # poll or refresh must not be allowed to overwrite it afterward.
        _credential_generation += 1
        _device_operation_generation += 1
        with _pending_lock:
            _pending_flows.clear()
        _mode_put(mode)
    return status()


def _iso_time(timestamp: float | None) -> str | None:
    if not timestamp:
        return None
    try:
        return datetime.datetime.fromtimestamp(
            timestamp, tz=datetime.timezone.utc
        ).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError):
        return None


def status() -> dict:
    mode = auth_mode()
    persistence = "session" if _dev_session_only() else "keychain"
    try:
        api_key = _vault_get(API_KEY_ACCOUNT)
    except XaiOAuthStorageError:
        # An unsigned development session may not inspect a Keychain item
        # owned by the signed release. That says nothing about the OAuth
        # session held in this process and must not block its status panel.
        if not _dev_session_only():
            raise
        api_key = ""
    has_api_key = bool(api_key)
    try:
        api_key_usable = bool(_valid_token(api_key, required=True))
    except XaiOAuthReconnectRequired:
        api_key_usable = False
    oauth_available = _oauth_client_available()
    credential = None
    invalid_credential = False
    if oauth_available:
        try:
            credential = _load_credential()
        except XaiOAuthReconnectRequired:
            invalid_credential = True
    else:
        # A prior development build may have stored a credential under a
        # different client identity. Do not parse, refresh, or treat it as
        # connected when this build's pinned compatibility identity is invalid.
        invalid_credential = bool(_vault_get(OAUTH_CREDENTIAL_ACCOUNT))

    oauth_refreshable = bool(credential and credential.refresh_token)
    oauth_unexpired = bool(credential and credential.expires_at > _now())
    oauth_connected = bool(credential and (oauth_unexpired or oauth_refreshable))

    if mode == API_KEY_MODE:
        connected = api_key_usable
        state = "connected" if connected else "disconnected"
    elif mode == OAUTH2_MODE:
        connected = oauth_connected
        if connected:
            state = "connected"
        elif credential or invalid_credential:
            state = "expired"
        else:
            state = "disconnected"
    else:
        connected = False
        state = "disconnected"

    return {
        "provider": "xai",
        "auth_mode": mode,
        "state": state,
        "connected": connected,
        "has_api_key": has_api_key,
        "oauth": {
            "available": oauth_available,
            "connected": oauth_connected,
            "refreshable": oauth_refreshable,
            "expires_at": _iso_time(credential.expires_at if credential else None),
            # Public capability metadata only. This lets the renderer explain
            # why an unsigned source launch requires a fresh consent after a
            # restart without ever reading or exposing credential material.
            "persistence": persistence,
        },
        "independent_notice": INDEPENDENCE_NOTICE,
    }


def _http_client() -> httpx.AsyncClient:
    options = {
        "timeout": httpx.Timeout(20.0, connect=8.0),
        "follow_redirects": False,
        "trust_env": False,
        "headers": {
            "Accept": "application/json",
            "Cache-Control": "no-store",
            "User-Agent": "OpenClam-Studio/xAI-OAuth",
        },
    }
    if _TEST_TRANSPORT is not None:
        options["transport"] = _TEST_TRANSPORT
    return httpx.AsyncClient(**options)


def _assert_fixed_endpoint(endpoint: str) -> None:
    parsed = urlsplit(endpoint)
    if (
        endpoint not in _FIXED_ENDPOINTS
        or parsed.scheme != "https"
        or parsed.hostname != "auth.x.ai"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
        or parsed.query
        or parsed.fragment
    ):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)


async def _post_form(endpoint: str, form: dict[str, str], *, empty_ok=False):
    _assert_fixed_endpoint(endpoint)
    try:
        async with _http_client() as client:
            async with client.stream(
                "POST",
                endpoint,
                data=form,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            ) as response:
                status_code = response.status_code
                if 300 <= status_code < 400:
                    # Never follow an OAuth-server redirect while form data
                    # contains a device code, refresh token, or access token.
                    raise XaiOAuthError("xai_oauth_protocol_error", 502)
                if status_code >= 500:
                    raise XaiOAuthTransientError()
                if status_code == 429:
                    raise XaiOAuthError("xai_oauth_rate_limited", 429)
                content = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(content) + len(chunk) > MAX_RESPONSE_BYTES:
                        raise XaiOAuthError("xai_oauth_protocol_error", 502)
                    content.extend(chunk)
    except (httpx.RequestError, TimeoutError):
        raise XaiOAuthTransientError() from None

    if not content and empty_ok and 200 <= status_code < 300:
        return status_code, {}
    try:
        body = json.loads(content)
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
        raise XaiOAuthError("xai_oauth_protocol_error", 502) from None
    if not isinstance(body, dict):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    return status_code, body


def _safe_verification_uri(value, *, required: bool) -> str | None:
    if value in (None, "") and not required:
        return None
    if not isinstance(value, str) or len(value) > 2048:
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in _ALLOWED_VERIFICATION_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
    ):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    return value


def _positive_int(value, minimum: int, maximum: int) -> int:
    if isinstance(value, bool):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    if isinstance(value, float) and not value.is_integer():
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    if isinstance(value, str) and not re.fullmatch(r"[0-9]+", value):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise XaiOAuthError("xai_oauth_protocol_error", 502) from None
    if parsed < minimum or parsed > maximum:
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    return parsed


def _provider_error(body: dict) -> str:
    value = body.get("error")
    return value if isinstance(value, str) and len(value) <= 80 else ""


async def start_device_login() -> dict:
    global _device_operation_generation
    # Snapshot before the first await. A mode switch, logout, or explicit
    # cancel that happens while xAI is issuing the device code must retire this
    # operation instead of letting its late response resurrect a consent flow.
    operation_generation = _device_operation_generation_snapshot()
    cid = client_id()
    status_code, body = await _post_form(DEVICE_AUTHORIZATION_ENDPOINT, {
        "client_id": cid,
        "scope": " ".join(SCOPES),
    })
    if not (200 <= status_code < 300):
        error = _provider_error(body)
        if error in ("invalid_client", "unauthorized_client"):
            raise XaiOAuthError("xai_oauth_client_rejected", 502)
        raise XaiOAuthError("xai_oauth_protocol_error", 502)

    try:
        device_code = _valid_token(body.get("device_code"), required=True)
    except XaiOAuthReconnectRequired:
        raise XaiOAuthError("xai_oauth_protocol_error", 502) from None
    user_code = body.get("user_code")
    if (
        not isinstance(user_code, str)
        or not user_code
        or len(user_code) > 64
        or any(ord(character) < 0x20 for character in user_code)
    ):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    verification_uri = _safe_verification_uri(
        body.get("verification_uri"), required=True
    )
    verification_uri_complete = _safe_verification_uri(
        body.get("verification_uri_complete"), required=False
    )
    expires_in = _positive_int(body.get("expires_in"), 30, MAX_PENDING_SECONDS)
    interval = _positive_int(body.get("interval", 5), MIN_POLL_INTERVAL,
                             MAX_POLL_INTERVAL)
    now = _now()
    flow_id = secrets.token_urlsafe(24)
    pending = _PendingDeviceFlow(
        device_code=device_code,
        client_id=cid,
        operation_generation=operation_generation,
        expires_at=now + expires_in,
        interval=interval,
        next_poll_at=now + interval,
    )
    with _credential_state_lock:
        if operation_generation != _device_operation_generation:
            raise XaiOAuthError("xai_oauth_flow_not_found", 404)
        # Claim a new operation epoch before publishing the flow. This also
        # makes two concurrent starts deterministic: the first valid response
        # wins and the later response cannot replace it with an older request.
        _device_operation_generation += 1
        pending.operation_generation = _device_operation_generation
        with _pending_lock:
            # One global auth mode needs at most one global consent attempt. A
            # new attempt explicitly replaces a stale/abandoned one.
            _pending_flows.clear()
            _pending_flows[flow_id] = pending

    return {
        "flow_id": flow_id,
        "state": "pending",
        "user_code": user_code,
        "verification_uri": verification_uri,
        "verification_uri_complete": verification_uri_complete,
        "expires_at": _iso_time(pending.expires_at),
        "interval": interval,
    }


def _credential_from_response(
    body: dict, *, cid: str, previous_refresh_token: str = ""
) -> _OAuthCredential:
    try:
        access_token = _valid_token(body.get("access_token"), required=True)
        refresh_token = _valid_token(
            body.get("refresh_token") or previous_refresh_token, required=False
        )
    except XaiOAuthReconnectRequired:
        raise XaiOAuthError("xai_oauth_protocol_error", 502) from None
    # Never invent or extend an access-token lifetime.  A token response that
    # omits its server-granted lifetime is unusable at this security boundary.
    if "expires_in" not in body:
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    expires_in = _positive_int(body.get("expires_in"), 1,
                               MAX_TOKEN_LIFETIME_SECONDS)
    token_type = str(body.get("token_type") or "Bearer")
    if token_type.lower() != "bearer":
        raise XaiOAuthError("xai_oauth_protocol_error", 502)
    try:
        scope = _scope_string(body.get("scope"))
    except XaiOAuthReconnectRequired:
        raise XaiOAuthError("xai_oauth_protocol_error", 502) from None
    return _OAuthCredential(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_at=_now() + expires_in,
        token_type="Bearer",
        scope=scope,
        client_id=cid,
    )


def _drop_pending(flow_id: str) -> None:
    with _pending_lock:
        _pending_flows.pop(flow_id, None)


async def poll_device_login(flow_id: str) -> dict:
    if not isinstance(flow_id, str) or not _FLOW_ID_PATTERN.fullmatch(flow_id):
        raise XaiOAuthError("xai_oauth_flow_not_found", 404)
    now = _now()
    with _pending_lock:
        pending = _pending_flows.get(flow_id)
        if pending is None:
            raise XaiOAuthError("xai_oauth_flow_not_found", 404)
        if now >= pending.expires_at:
            _pending_flows.pop(flow_id, None)
            raise XaiOAuthError("xai_oauth_device_expired", 410)
        if now < pending.next_poll_at:
            return {
                "state": "pending",
                "retry_after": max(1, math.ceil(pending.next_poll_at - now)),
            }
        # Claim this poll before yielding to the network so concurrent renderer
        # requests cannot duplicate a token exchange.
        pending.next_poll_at = now + pending.interval

    status_code, body = await _post_form(TOKEN_ENDPOINT, {
        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        "device_code": pending.device_code,
        "client_id": pending.client_id,
    })
    with _credential_state_lock:
        with _pending_lock:
            current = _pending_flows.get(flow_id)
            if (
                pending.operation_generation != _device_operation_generation
                or current is not pending
            ):
                _pending_flows.pop(flow_id, None)
                raise XaiOAuthError("xai_oauth_flow_not_found", 404)
    error = _provider_error(body)
    if error == "authorization_pending":
        return {"state": "pending", "retry_after": pending.interval}
    if error == "slow_down":
        with _pending_lock:
            current = _pending_flows.get(flow_id)
            if current is not None:
                current.interval = min(MAX_POLL_INTERVAL, current.interval + 5)
                current.next_poll_at = _now() + current.interval
                interval = current.interval
            else:
                interval = pending.interval
        return {"state": "pending", "retry_after": interval}
    if error == "access_denied":
        _drop_pending(flow_id)
        raise XaiOAuthError("xai_oauth_access_denied", 403)
    if error in ("expired_token", "invalid_grant"):
        _drop_pending(flow_id)
        raise XaiOAuthError("xai_oauth_device_expired", 410)
    if error in ("invalid_client", "unauthorized_client"):
        _drop_pending(flow_id)
        raise XaiOAuthError("xai_oauth_client_rejected", 502)
    if error or not (200 <= status_code < 300):
        raise XaiOAuthError("xai_oauth_protocol_error", 502)

    credential = _credential_from_response(body, cid=pending.client_id)
    with _credential_state_lock:
        with _pending_lock:
            if (
                pending.operation_generation != _device_operation_generation
                or _pending_flows.get(flow_id) is not pending
            ):
                _pending_flows.pop(flow_id, None)
                raise XaiOAuthError("xai_oauth_flow_not_found", 404)
            # Keep the flow current through the atomic Keychain record write;
            # another poll cannot retire the flow between the final check and
            # the credential commit.
            _store_credential(credential)
            _mode_put(OAUTH2_MODE)
            _pending_flows.pop(flow_id, None)
    connected = status()
    connected["state"] = "connected"
    return connected


async def _refresh(credential: _OAuthCredential) -> str:
    # A preceding refresh (for example on another request path) may already
    # have replaced the record before this task got scheduled.
    with _credential_state_lock:
        generation = _credential_generation
        try:
            current = _load_credential()
        except XaiOAuthReconnectRequired:
            current = None
        if current is None:
            raise XaiOAuthReconnectRequired()
        if current.access_token != credential.access_token:
            if current.expires_at - _now() > EARLY_REFRESH_SECONDS:
                return current.access_token
            credential = current

    status_code, body = await _post_form(TOKEN_ENDPOINT, {
        "grant_type": "refresh_token",
        "refresh_token": credential.refresh_token,
        "client_id": credential.client_id,
    })
    error = _provider_error(body)
    if error in ("invalid_grant", "invalid_client", "unauthorized_client"):
        with _credential_state_lock:
            try:
                current = _load_credential()
            except XaiOAuthReconnectRequired:
                current = None
            if (
                generation == _credential_generation
                and current is not None
                and current.access_token == credential.access_token
                and current.refresh_token == credential.refresh_token
            ):
                _clear_credential()
        raise XaiOAuthReconnectRequired()
    if error or not (200 <= status_code < 300):
        raise XaiOAuthTransientError()
    refreshed = _credential_from_response(
        body,
        cid=credential.client_id,
        previous_refresh_token=credential.refresh_token,
    )
    with _credential_state_lock:
        if generation != _credential_generation:
            raise XaiOAuthReconnectRequired()
        try:
            current = _load_credential()
        except XaiOAuthReconnectRequired:
            current = None
        if current is None:
            raise XaiOAuthReconnectRequired()
        if (
            current.access_token != credential.access_token
            or current.refresh_token != credential.refresh_token
        ):
            if current.expires_at - _now() > EARLY_REFRESH_SECONDS:
                return current.access_token
            raise XaiOAuthReconnectRequired()
        _store_credential(refreshed)
    return refreshed.access_token


async def _single_flight_refresh(credential: _OAuthCredential) -> str:
    global _refresh_flight
    loop = asyncio.get_running_loop()
    with _refresh_lock:
        flight = _refresh_flight
        owner = flight is None or flight.done()
        if owner:
            flight = concurrent.futures.Future()
            _refresh_flight = flight

    if owner:
        task = loop.create_task(_refresh(credential))

        def complete(completed):
            global _refresh_flight
            try:
                result = completed.result()
            except asyncio.CancelledError:
                if not flight.done():
                    flight.set_exception(XaiOAuthTransientError())
            except BaseException as error:
                if not flight.done():
                    flight.set_exception(error)
            else:
                if not flight.done():
                    flight.set_result(result)
            finally:
                with _refresh_lock:
                    if _refresh_flight is flight:
                        _refresh_flight = None

        task.add_done_callback(complete)

    # concurrent.futures.Future is the loop-neutral rendezvous. Shielding its
    # per-loop wrapper prevents one cancelled lane from cancelling rotation for
    # all other threads/event loops.
    return await asyncio.shield(asyncio.wrap_future(flight, loop=loop))


async def get_access_token() -> str:
    credential = _load_credential()
    if credential is None:
        raise XaiOAuthNotConnected()
    remaining = credential.expires_at - _now()
    if remaining > EARLY_REFRESH_SECONDS:
        return credential.access_token
    if credential.refresh_token:
        return await _single_flight_refresh(credential)
    if remaining > 0:
        return credential.access_token
    raise XaiOAuthReconnectRequired()


async def resolve_auth() -> ResolvedAuth:
    mode = auth_mode()
    if mode == API_KEY_MODE:
        key = _vault_get(API_KEY_ACCOUNT)
        if not key:
            raise XaiOAuthNotConnected("xai_api_key_missing", 409)
        try:
            key = _valid_token(key, required=True)
        except XaiOAuthReconnectRequired:
            raise XaiOAuthNotConnected("xai_api_key_missing", 409) from None
        return ResolvedAuth(mode=API_KEY_MODE, bearer_token=key)
    if mode == OAUTH2_MODE:
        return ResolvedAuth(mode=OAUTH2_MODE,
                            bearer_token=await get_access_token())
    raise XaiOAuthNotConnected()


async def logout() -> dict:
    global _credential_generation, _device_operation_generation
    with _credential_state_lock:
        selected_mode = auth_mode()
        try:
            credential = _load_credential()
        except XaiOAuthReconnectRequired:
            credential = None
        except XaiOAuthError as error:
            if error.code != "xai_oauth_client_config_invalid":
                raise
            credential = None
        # Invalidate every device exchange and refresh that started before
        # this logout, then clear locally before any best-effort network call.
        _credential_generation += 1
        _device_operation_generation += 1
        with _pending_lock:
            _pending_flows.clear()
        _clear_credential()
        # Logout changes credential state, never the user's explicit routing
        # choice. In particular an OAuth logout must not silently activate an
        # existing pay-as-you-go API key.
        _mode_put(selected_mode)

    revoked = False
    token = ""
    token_type_hint = ""
    if credential is not None:
        token = credential.refresh_token or credential.access_token
        token_type_hint = (
            "refresh_token" if credential.refresh_token else "access_token"
        )
    if token:
        try:
            status_code, _body = await _post_form(REVOCATION_ENDPOINT, {
                "token": token,
                "token_type_hint": token_type_hint,
                "client_id": credential.client_id,
            }, empty_ok=True)
            revoked = 200 <= status_code < 300
        except XaiOAuthError:
            # Local logout must succeed even while offline or if server-side
            # revocation has already happened.
            revoked = False

    result = status()
    result["revoked"] = revoked
    return result


def cancel_device_login() -> dict:
    """Cancel the one global device-consent operation without changing auth.

    Advancing a dedicated device-operation epoch also retires a device-code
    request that has not returned yet. It intentionally does not advance the
    credential generation, so cancelling consent cannot disrupt an unrelated
    refresh for an already connected OAuth session.
    """
    global _device_operation_generation
    with _credential_state_lock:
        _device_operation_generation += 1
        with _pending_lock:
            _pending_flows.clear()
    result = status()
    result["device_flow_cancelled"] = True
    return result


def _reset_for_tests() -> None:
    """Clear process-only coordination state; never touches the Keychain."""
    global _credential_generation, _device_operation_generation, _refresh_flight
    global _DEV_SESSION_CREDENTIAL
    with _credential_state_lock:
        _credential_generation = 0
        _device_operation_generation = 0
        with _pending_lock:
            _pending_flows.clear()
    with _refresh_lock:
        _refresh_flight = None
    _DEV_SESSION_CREDENTIAL = None
