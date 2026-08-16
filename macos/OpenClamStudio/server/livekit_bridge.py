"""Server-side bridge from the local Mac app to OpenClam's LiveKit broker.

The renderer never receives the broker bearer or provider API keys.  It asks
this loopback FastAPI process for a one-time LiveKit participant token; this
module resolves Keychain-held secrets, posts them directly to the shared
Cloudflare broker, and returns only that validated connection response.

The allowed model/voice/language surface is not duplicated here.  Both the
development checkout and the packaged app read the same versioned tuple
fixture used by the broker and agent.
"""
from __future__ import annotations

import asyncio
import copy
import json
import os
import re
from functools import lru_cache
from pathlib import Path
from typing import Awaitable, Callable, Mapping
from urllib.parse import urlsplit

import httpx


CONTRACT_NAME = "live-talk-approved-tuples-v1.json"
STAGES = ("llm", "stt", "tts")
SOURCES = ("managed", "byok")
MAX_BROKER_RESPONSE_BYTES = 16_384
MAX_PARTICIPANT_TOKEN_BYTES = 16_000
MAX_PROVIDER_KEY_BYTES = 4_096
MAX_PERSONA_NAME_BYTES = 80
MAX_PERSONA_INSTRUCTIONS_BYTES = 4_096
SESSION_PATH = "/v1/live-talk/sessions"
BROKER_URL_ENV = "OPENCLAM_LIVEKIT_BROKER_URL"
SERVER_HOST_ENV = "OPENCLAM_LIVEKIT_SERVER_HOST"

# Standalone source checkout and packaged app: contracts beside server. Cross-
# project parity belongs in tests; runtime never reaches into a parent suite.
_HERE = Path(__file__).resolve().parent
CONTRACT_CANDIDATES = (_HERE.parent / "contracts" / CONTRACT_NAME,)

MANAGED_DEFAULT = {
    "llm": {
        "source": "managed",
        "provider": "livekit",
        "model": "google/gemma-4-31b-it",
    },
    "stt": {
        "source": "managed",
        "provider": "livekit",
        "model": "deepgram/nova-3",
        "language": "multi",
    },
    "tts": {
        "source": "managed",
        "provider": "livekit",
        "model": "fishaudio/s2.1-pro",
        "voice": "933563129e564b19a115bedd57b7406a",
    },
}

DEFAULT_CONFIG = {
    "broker_url": "",
    "expected_server_host": "",
    "pilot_app_token": "",
    **copy.deepcopy(MANAGED_DEFAULT),
}

_DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


class LiveKitBridgeError(Exception):
    """A deliberately low-information error safe to return to the renderer."""

    def __init__(self, code: str, status_code: int = 422):
        super().__init__(code)
        self.code = code
        self.status_code = status_code


def _contract_path() -> Path:
    for candidate in CONTRACT_CANDIDATES:
        if candidate.is_file():
            return candidate
    raise LiveKitBridgeError("livekit_catalog_unavailable", 500)


def _tuple_from_row(row: object) -> tuple[str, str, str, str, str | None, str | None]:
    if not isinstance(row, list) or len(row) != 6:
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    stage, source, provider, model, voice, language = row
    if stage not in STAGES or source not in SOURCES:
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    if not all(isinstance(value, str) and value for value in (provider, model)):
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    if voice is not None and (not isinstance(voice, str) or not voice):
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    if language is not None and (not isinstance(language, str) or not language):
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    return stage, source, provider, model, voice, language


@lru_cache(maxsize=1)
def _contract() -> tuple[int, tuple[tuple[str, str, str, str, str | None, str | None], ...]]:
    try:
        with _contract_path().open(encoding="utf-8") as handle:
            document = json.load(handle)
    except LiveKitBridgeError:
        raise
    except Exception as error:
        raise LiveKitBridgeError("livekit_catalog_invalid", 500) from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    rows = document.get("tuples")
    if not isinstance(rows, list):
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    tuples = tuple(_tuple_from_row(row) for row in rows)
    if len(tuples) != len(set(tuples)):
        raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    allowed = set(tuples)
    for stage, selection in MANAGED_DEFAULT.items():
        if _selection_tuple(stage, selection) not in allowed:
            raise LiveKitBridgeError("livekit_catalog_invalid", 500)
    return 1, tuples


def _selection_tuple(
    stage: str,
    value: Mapping[str, object],
) -> tuple[str, str, str, str, str | None, str | None]:
    allowed_fields = {"source", "provider", "model", "voice", "language"}
    required_fields = {"source", "provider", "model"}
    if set(value) - allowed_fields or not required_fields.issubset(value):
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    source = value.get("source")
    provider = value.get("provider")
    model = value.get("model")
    voice = value.get("voice")
    language = value.get("language")
    if source not in SOURCES or not isinstance(provider, str) or not provider \
            or not isinstance(model, str) or not model:
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    if voice is not None and (not isinstance(voice, str) or not voice):
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    if language is not None and (not isinstance(language, str) or not language):
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    return stage, source, provider, model, voice, language


def validated_selection(stage: str, value: object) -> dict:
    if stage not in STAGES or not isinstance(value, Mapping):
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    selected = _selection_tuple(stage, value)
    if selected not in set(_contract()[1]):
        raise LiveKitBridgeError("livekit_selection_not_allowed")
    _, source, provider, model, voice, language = selected
    result = {"source": source, "provider": provider, "model": model}
    if voice is not None:
        result["voice"] = voice
    if language is not None:
        result["language"] = language
    return result


def _migrate_persisted_selection(stage: str, value: object) -> object:
    """Remove only optional fields that cannot exist for this saved lane.

    Older builds could retain ``language`` while switching a TTS lane from
    xAI to LiveKit managed, or ``voice`` while switching an STT lane.  Those
    stale fields make an otherwise exact approved tuple impossible and leave
    both Settings and Live Talk unable to repair the saved choice.  Migration
    is deliberately narrow: source/provider/model are never changed, and an
    optional value is removed only when *every* approved row for that exact
    base tuple has ``null`` in that position.  A wrong voice or language for a
    lane that supports that field therefore remains rejected.
    """
    if stage not in STAGES or not isinstance(value, Mapping):
        return value
    migrated = dict(value)
    source = migrated.get("source")
    provider = migrated.get("provider")
    model = migrated.get("model")
    rows = [
        row for row in _contract()[1]
        if row[0] == stage and row[1] == source
        and row[2] == provider and row[3] == model
    ]
    if not rows:
        return value
    for field, index in (("voice", 4), ("language", 5)):
        if field in migrated and all(row[index] is None for row in rows):
            migrated.pop(field, None)
    return migrated


def _migrate_persisted_config(config: object) -> dict:
    source = dict(config) if isinstance(config, Mapping) else {}
    for stage in STAGES:
        if stage in source:
            source[stage] = _migrate_persisted_selection(stage, source[stage])
    return source


def catalog() -> dict:
    version, tuples = _contract()
    stages = {stage: [] for stage in STAGES}
    for stage, source, provider, model, voice, language in tuples:
        selection = {"source": source, "provider": provider, "model": model}
        if voice is not None:
            selection["voice"] = voice
        if language is not None:
            selection["language"] = language
        stages[stage].append(selection)
    return {
        "schema_version": version,
        "managed_default": copy.deepcopy(MANAGED_DEFAULT),
        "stages": stages,
    }


def _valid_dns_host(value: str) -> bool:
    if value != value.lower() or len(value.encode("utf-8")) > 253:
        return False
    labels = value.split(".")
    return len(labels) >= 2 and all(_DNS_LABEL.fullmatch(label) for label in labels)


def _validated_endpoint(raw_value: object) -> str:
    if not isinstance(raw_value, str):
        raise LiveKitBridgeError("livekit_broker_url_invalid")
    value = raw_value.strip()
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise LiveKitBridgeError("livekit_broker_url_invalid") from error
    host = parsed.hostname or ""
    authority = host if port is None else f"{host}:{port}"
    if not (
        parsed.scheme == "https"
        and _valid_dns_host(host)
        and parsed.username is None
        and parsed.password is None
        and port in (None, 443)
        and parsed.netloc == authority
        and parsed.path == SESSION_PATH
        and not parsed.query
        and not parsed.fragment
    ):
        raise LiveKitBridgeError("livekit_broker_url_invalid")
    return value


def _validated_expected_host(raw_value: object) -> str:
    if not isinstance(raw_value, str):
        raise LiveKitBridgeError("livekit_server_host_invalid")
    value = raw_value.strip()
    if not _valid_dns_host(value):
        raise LiveKitBridgeError("livekit_server_host_invalid")
    return value


def _valid_secret(value: str, minimum: int, maximum: int) -> bool:
    size = len(value.encode("utf-8"))
    return minimum <= size <= maximum and not any(
        character.isspace() or ord(character) < 32 or ord(character) == 127
        for character in value
    )


def validated_config(config: object, require_connection: bool = False) -> dict:
    source = config if isinstance(config, Mapping) else {}
    result = copy.deepcopy(DEFAULT_CONFIG)
    result["broker_url"] = str(source.get("broker_url") or "").strip()
    result["expected_server_host"] = str(
        source.get("expected_server_host") or ""
    ).strip()
    result["pilot_app_token"] = ""
    for stage in STAGES:
        result[stage] = validated_selection(stage, source.get(stage, result[stage]))

    endpoint = result["broker_url"]
    expected_host = result["expected_server_host"]
    if endpoint or expected_host:
        if not endpoint or not expected_host:
            raise LiveKitBridgeError("livekit_connection_config_incomplete")
        result["broker_url"] = _validated_endpoint(endpoint)
        result["expected_server_host"] = _validated_expected_host(expected_host)
    elif require_connection:
        raise LiveKitBridgeError("livekit_not_configured")
    return result


def deployment_config(
    config: object,
    environment: Mapping[str, str] | None = None,
    require_connection: bool = False,
) -> dict:
    """Overlay the signed shell's deployment pins onto user-owned choices.

    Broker and LiveKit hosts are executable trust decisions because provider
    credentials are sent to the former and participant tokens connect to the
    latter.  They therefore come only from the Electron-launched backend
    environment, never from renderer-writable config.json.
    """
    environment = os.environ if environment is None else environment
    source = _migrate_persisted_config(config)
    source["broker_url"] = str(environment.get(BROKER_URL_ENV) or "").strip()
    source["expected_server_host"] = str(
        environment.get(SERVER_HOST_ENV) or ""
    ).strip()
    return validated_config(source, require_connection=require_connection)


def prepare_config_update(
    current: object,
    incoming: object,
    allow_connection_fields: bool = True,
) -> dict:
    if not isinstance(incoming, Mapping):
        raise LiveKitBridgeError("livekit_config_invalid")
    allowed = {
        "broker_url", "expected_server_host", "pilot_app_token",
        "has_pilot_app_token", *STAGES,
    }
    if set(incoming) - allowed:
        raise LiveKitBridgeError("livekit_config_invalid")

    connection_fields = {"broker_url", "expected_server_host"}
    if not allow_connection_fields and set(incoming) & connection_fields:
        raise LiveKitBridgeError("livekit_deployment_config_read_only")

    current_source = _migrate_persisted_config(current)
    if not allow_connection_fields:
        # Retire values written by pre-pin builds instead of preserving a
        # renderer-controlled trust decision in config.json.
        current_source["broker_url"] = ""
        current_source["expected_server_host"] = ""
    current_config = validated_config(current_source)
    merged = copy.deepcopy(current_config)
    mutable_fields = (*STAGES,)
    if allow_connection_fields:
        mutable_fields = ("broker_url", "expected_server_host", *mutable_fields)
    for field in mutable_fields:
        if field in incoming:
            merged[field] = incoming[field]
    normalized = validated_config(merged)

    token = incoming.get("pilot_app_token")
    if token not in (None, ""):
        if token == "__clear__":
            normalized["pilot_app_token"] = token
        elif not isinstance(token, str) or not _valid_secret(token, 32, 4_096):
            raise LiveKitBridgeError("livekit_pilot_token_invalid")
        else:
            normalized["pilot_app_token"] = token
    else:
        normalized.pop("pilot_app_token", None)
    return normalized


def public_config(config: object, has_pilot_app_token: bool) -> dict:
    result = validated_config(config)
    result.pop("pilot_app_token", None)
    result["has_pilot_app_token"] = bool(has_pilot_app_token)
    return result


def _utf8_prefix(value: str, maximum: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= maximum:
        return value
    return encoded[:maximum].decode("utf-8", errors="ignore")


def _persona(name: object, instructions: object) -> dict:
    safe_name = _utf8_prefix(str(name or "").strip(), MAX_PERSONA_NAME_BYTES)
    safe_instructions = _utf8_prefix(
        str(instructions or "").strip(), MAX_PERSONA_INSTRUCTIONS_BYTES
    )
    if not safe_name or not safe_instructions:
        raise LiveKitBridgeError("livekit_persona_invalid")
    return {"name": safe_name, "instructions": safe_instructions}


def _secret(
    getter: Callable[[str], str],
    account: str,
    missing_code: str,
    minimum: int,
    maximum: int,
) -> str:
    try:
        value = getter(account) or ""
    except Exception as error:
        raise LiveKitBridgeError(missing_code) from error
    if not isinstance(value, str) or not _valid_secret(value, minimum, maximum):
        raise LiveKitBridgeError(missing_code)
    return value


def session_payload(
    config: object,
    persona_name: object,
    persona_instructions: object,
    secret_getter: Callable[[str], str],
    xai_bearer: str | None = None,
    xai_auth_mode: str | None = None,
) -> tuple[dict, str, str]:
    settings = validated_config(config, require_connection=True)
    credentials = {}
    for stage in STAGES:
        selection = settings[stage]
        if selection["source"] != "byok":
            continue
        provider = selection["provider"]
        if provider == "xai":
            if (
                xai_auth_mode not in {"api_key", "oauth2"}
                or not isinstance(xai_bearer, str)
                or not _valid_secret(xai_bearer, 8, MAX_PROVIDER_KEY_BYTES)
            ):
                # xAI has one explicit, global authentication mode. Never
                # infer or fall back to a differently stored Keychain value.
                raise LiveKitBridgeError("livekit_xai_auth_unavailable")
            api_key = xai_bearer
        else:
            api_key = _secret(
                secret_getter,
                f"keys.{provider}",
                f"livekit_missing_{provider}_key",
                8,
                MAX_PROVIDER_KEY_BYTES,
            )
        credentials[stage] = {
            "api_key": api_key,
            **({"auth_mode": xai_auth_mode} if provider == "xai" else {}),
        }
    pilot_token = _secret(
        secret_getter,
        "livekit.pilot_app_token",
        "livekit_pilot_token_missing",
        32,
        4_096,
    )
    payload = {
        "participant_name": "OpenClam User",
        "profile": {
            **{stage: settings[stage] for stage in STAGES},
            "persona": _persona(persona_name, persona_instructions),
        },
        "credentials": credentials,
    }
    return payload, settings["broker_url"], pilot_token


def _validated_server_url(raw_value: object, expected_host: str) -> str:
    if not isinstance(raw_value, str) or not raw_value.startswith("wss://"):
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502)
    try:
        parsed = urlsplit(raw_value)
        port = parsed.port
    except ValueError as error:
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502) from error
    authority = expected_host if port is None else f"{expected_host}:{port}"
    if not (
        parsed.scheme == "wss"
        and parsed.hostname == expected_host
        and parsed.username is None
        and parsed.password is None
        and port in (None, 443)
        and parsed.netloc == authority
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
    ):
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502)
    return raw_value


def _strict_json_object(data: bytes) -> dict:
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except Exception as error:
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502) from error
    if not isinstance(value, dict) or set(value) != {"server_url", "participant_token"}:
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502)
    return value


async def create_session(
    config: object,
    persona_name: object,
    persona_instructions: object,
    secret_getter: Callable[[str], str] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    deployment_environment: Mapping[str, str] | None = None,
    xai_auth_resolver: Callable[[], Awaitable[object]] | None = None,
) -> dict:
    if secret_getter is None:
        import credentials
        secret_getter = credentials.get
    pinned_config = deployment_config(
        config, deployment_environment, require_connection=True
    )
    xai_bearer = None
    xai_auth_mode = None
    if any(
        pinned_config[stage]["source"] == "byok"
        and pinned_config[stage]["provider"] == "xai"
        for stage in STAGES
    ):
        if xai_auth_resolver is None:
            import xai_oauth

            xai_auth_resolver = xai_oauth.resolve_auth
        try:
            resolved = await xai_auth_resolver()
            mode = getattr(resolved, "mode", "")
            candidate = getattr(resolved, "bearer_token", "")
        except Exception as error:
            raise LiveKitBridgeError("livekit_xai_auth_unavailable") from error
        if mode not in {"api_key", "oauth2"} or not isinstance(candidate, str) \
                or not _valid_secret(candidate, 8, MAX_PROVIDER_KEY_BYTES):
            raise LiveKitBridgeError("livekit_xai_auth_unavailable")
        xai_bearer = candidate
        xai_auth_mode = mode
    payload, endpoint, pilot_token = session_payload(
        pinned_config,
        persona_name,
        persona_instructions,
        secret_getter,
        xai_bearer=xai_bearer,
        xai_auth_mode=xai_auth_mode,
    )
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {pilot_token}",
        "Cache-Control": "no-store",
        "Content-Type": "application/json",
        "Pragma": "no-cache",
    }
    body = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    client_options = {
        "cookies": {},
        "follow_redirects": False,
        "timeout": httpx.Timeout(30.0),
        "trust_env": False,
    }
    if transport is not None:
        client_options["transport"] = transport
    try:
        # httpx timeouts are inactivity budgets per network operation.  The
        # outer deadline also stops a peer that drips one byte every 29s.
        async with asyncio.timeout(30):
            async with httpx.AsyncClient(**client_options) as client:
                async with client.stream(
                    "POST", endpoint, content=body, headers=headers
                ) as response:
                    if 300 <= response.status_code < 400:
                        raise LiveKitBridgeError(
                            "livekit_broker_redirect_rejected", 502
                        )
                    if response.status_code != 201:
                        raise LiveKitBridgeError("livekit_broker_rejected", 502)
                    length = response.headers.get("content-length")
                    if length is not None:
                        try:
                            if int(length) > MAX_BROKER_RESPONSE_BYTES:
                                raise LiveKitBridgeError(
                                    "livekit_broker_response_invalid", 502
                                )
                        except ValueError as error:
                            raise LiveKitBridgeError(
                                "livekit_broker_response_invalid", 502
                            ) from error
                    chunks = []
                    total = 0
                    async for chunk in response.aiter_bytes():
                        total += len(chunk)
                        if total > MAX_BROKER_RESPONSE_BYTES:
                            raise LiveKitBridgeError(
                                "livekit_broker_response_invalid", 502
                            )
                        chunks.append(chunk)
    except LiveKitBridgeError:
        raise
    except (httpx.RequestError, TimeoutError) as error:
        raise LiveKitBridgeError("livekit_broker_unreachable", 502) from error

    value = _strict_json_object(b"".join(chunks))
    server_url = _validated_server_url(
        value.get("server_url"), pinned_config["expected_server_host"]
    )
    token = value.get("participant_token")
    if not isinstance(token, str) or not token \
            or len(token.encode("utf-8")) > MAX_PARTICIPANT_TOKEN_BYTES:
        raise LiveKitBridgeError("livekit_broker_response_invalid", 502)
    return {"server_url": server_url, "participant_token": token}
