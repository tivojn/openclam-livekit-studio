from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

SCHEMA_VERSION = 1
MAX_METADATA_BYTES = 1024
MAX_PERSONA_BYTES = 4096
MAX_API_KEY_LENGTH = 4096

_LEASE_ID = re.compile(r"^[a-f0-9]{32}$")
_HASH = re.compile(r"^[a-f0-9]{64}$")
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")


class ContractError(ValueError):
    """The broker or dispatch payload did not match the trusted contract."""


class ModelSource(StrEnum):
    MANAGED = "managed"
    BYOK = "byok"


class XaiAuthMode(StrEnum):
    API_KEY = "api_key"
    OAUTH2 = "oauth2"


class StageName(StrEnum):
    LLM = "llm"
    STT = "stt"
    TTS = "tts"


# This is a second, agent-side copy of the broker's reviewed catalog. The
# credential broker is the first enforcement boundary; this closed tuple set
# ensures that a compromised or accidentally loosened broker still cannot feed
# arbitrary provider configuration into plugin constructors.
_CATALOG_SELECTIONS: dict[
    StageName, frozenset[tuple[str, str, str, str | None, str | None]]
] = {
    StageName.LLM: frozenset(
        {
            ("managed", "livekit", "google/gemma-4-31b-it", None, None),
            ("byok", "anthropic", "claude-haiku-4-5", None, None),
            ("byok", "anthropic", "claude-sonnet-4-6", None, None),
            ("byok", "gemini", "gemini-3.6-flash", None, None),
            ("byok", "gemini", "gemini-3.5-flash", None, None),
            ("byok", "gemini", "gemini-3.5-flash-lite", None, None),
            ("byok", "openai", "gpt-5.4-mini", None, None),
            ("byok", "openai", "gpt-5.6-luna", None, None),
            ("byok", "openai", "gpt-5.6-terra", None, None),
            ("byok", "openai", "gpt-5.6-sol", None, None),
            ("byok", "xai", "grok-4.3", None, None),
            ("byok", "xai", "grok-4.5", None, None),
        }
    ),
    StageName.STT: frozenset(
        {
            *(
                ("managed", "livekit", "deepgram/nova-3", None, language)
                for language in ("multi", "en", "zh")
            ),
            *(
                ("byok", "deepgram", "nova-3", None, language)
                for language in ("multi", "en", "zh")
            ),
            *(
                (
                    "byok",
                    "elevenlabs",
                    "scribe_v2_realtime",
                    None,
                    language,
                )
                for language in ("multi", "en", "zh")
            ),
            *(
                ("byok", "openai", model, None, language)
                for model in (
                    "gpt-4o-transcribe",
                    "gpt-4o-mini-transcribe",
                    "whisper-1",
                )
                for language in ("en", "zh")
            ),
            ("byok", "xai", "grok-transcribe", None, "en"),
        }
    ),
    StageName.TTS: frozenset(
        {
            *(
                (
                    "managed",
                    "livekit",
                    "fishaudio/s2.1-pro",
                    voice,
                    None,
                )
                for voice in (
                    "bf322df2096a46f18c579d0baa36f41d",
                    "536d3a5e000945adb7038665781a4aca",
                    "9a9cf47702da476aa4629e2506d4a857",
                    "79d0bd3e4e5444b18f7b6d89b5927bf1",
                    "e3cd384158934cc9a01029cd7d278634",
                    "933563129e564b19a115bedd57b7406a",
                    "b347db033a6549378b48d00acb0d06cd",
                )
            ),
            (
                "byok",
                "deepgram",
                "aura-2-andromeda-en",
                "aura-2-andromeda-en",
                None,
            ),
            *(
                (
                    "byok",
                    "elevenlabs",
                    "eleven_flash_v2_5",
                    voice,
                    None,
                )
                for voice in (
                    "EXAVITQu4vr4xnSDxMaL",
                    "JBFqnCBsd6RMkjVDRZzb",
                )
            ),
            (
                "byok",
                "elevenlabs",
                "eleven_multilingual_v2",
                "JBFqnCBsd6RMkjVDRZzb",
                None,
            ),
            (
                "byok",
                "gemini",
                "gemini-3.1-flash-tts-preview",
                "Sadachbia",
                None,
            ),
            (
                "byok",
                "gemini",
                "gemini-3.1-flash-tts-preview",
                "Kore",
                None,
            ),
            *(
                ("byok", "openai", model, "alloy", None)
                for model in ("gpt-4o-mini-tts", "tts-1", "tts-1-hd")
            ),
            *(
                ("byok", "xai", "xai-tts", voice, "auto")
                for voice in ("ara", "eve", "leo", "rex", "sal")
            ),
        }
    ),
}


@dataclass(frozen=True, slots=True)
class DispatchEnvelope:
    lease_id: str
    profile_hash: str

    @classmethod
    def from_metadata(cls, raw: str | None) -> DispatchEnvelope:
        if not raw:
            raise ContractError("missing session dispatch metadata")
        if len(raw.encode("utf-8")) > MAX_METADATA_BYTES:
            raise ContractError("session dispatch metadata is too large")

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ContractError("session dispatch metadata is not valid JSON") from exc
        if not isinstance(payload, dict):
            raise ContractError("session dispatch metadata must be an object")
        if set(payload) != {"schema_version", "lease_id", "profile_hash"}:
            raise ContractError("session dispatch metadata has unknown fields")
        if payload["schema_version"] != SCHEMA_VERSION:
            raise ContractError("unsupported session dispatch schema")

        lease_id = payload.get("lease_id")
        profile_hash = payload.get("profile_hash")
        if not isinstance(lease_id, str) or not _LEASE_ID.fullmatch(lease_id):
            raise ContractError("invalid credential lease identifier")
        if not isinstance(profile_hash, str) or not _HASH.fullmatch(profile_hash):
            raise ContractError("invalid session profile hash")
        return cls(lease_id=lease_id, profile_hash=profile_hash)


@dataclass(frozen=True, slots=True)
class StageSelection:
    source: ModelSource
    provider: str
    model: str
    voice: str | None = None
    language: str | None = None

    @classmethod
    def from_payload(cls, stage: StageName, payload: object) -> StageSelection:
        if not isinstance(payload, dict):
            raise ContractError(f"{stage.value} selection must be an object")
        allowed = {"source", "provider", "model", "voice", "language"}
        if set(payload) - allowed:
            raise ContractError(f"{stage.value} selection has unknown fields")

        try:
            source = ModelSource(payload.get("source"))
        except (TypeError, ValueError) as exc:
            raise ContractError(f"invalid {stage.value} source") from exc

        provider = _safe_identifier(payload.get("provider"), f"{stage.value} provider")
        model = _safe_identifier(payload.get("model"), f"{stage.value} model")
        voice = _optional_identifier(payload.get("voice"), f"{stage.value} voice")
        language = _optional_identifier(
            payload.get("language"), f"{stage.value} language"
        )
        if stage is not StageName.TTS and voice is not None:
            raise ContractError(f"{stage.value} cannot select a voice")
        if source is ModelSource.MANAGED and provider != "livekit":
            raise ContractError(f"managed {stage.value} must use LiveKit")
        if source is ModelSource.BYOK and provider == "livekit":
            raise ContractError(f"BYOK {stage.value} needs a provider")
        selection = cls(
            source=source,
            provider=provider,
            model=model,
            voice=voice,
            language=language,
        )
        validate_catalog_selection(stage, selection)
        return selection

    def to_payload(self) -> dict[str, str]:
        payload = {
            "source": self.source.value,
            "provider": self.provider,
            "model": self.model,
        }
        if self.voice is not None:
            payload["voice"] = self.voice
        if self.language is not None:
            payload["language"] = self.language
        return payload


@dataclass(frozen=True, slots=True)
class Persona:
    name: str
    instructions: str = field(repr=False)

    @classmethod
    def from_payload(cls, payload: object) -> Persona:
        if not isinstance(payload, dict) or set(payload) != {"name", "instructions"}:
            raise ContractError("invalid avatar persona")
        name = payload.get("name")
        instructions = payload.get("instructions")
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80:
            raise ContractError("invalid avatar name")
        if not isinstance(instructions, str):
            raise ContractError("invalid avatar instructions")
        if len(instructions.encode("utf-8")) > MAX_PERSONA_BYTES:
            raise ContractError("avatar instructions are too large")
        instructions = instructions.strip()
        if not instructions:
            raise ContractError("invalid avatar instructions")
        return cls(name=name.strip(), instructions=instructions)

    def to_payload(self) -> dict[str, str]:
        return {"name": self.name, "instructions": self.instructions}


@dataclass(frozen=True, slots=True)
class SessionProfile:
    llm: StageSelection
    stt: StageSelection
    tts: StageSelection
    persona: Persona

    @classmethod
    def from_payload(cls, payload: object) -> SessionProfile:
        if not isinstance(payload, dict):
            raise ContractError("session profile must be an object")
        if set(payload) != {"llm", "stt", "tts", "persona"}:
            raise ContractError("session profile has unknown fields")
        return cls(
            llm=StageSelection.from_payload(StageName.LLM, payload["llm"]),
            stt=StageSelection.from_payload(StageName.STT, payload["stt"]),
            tts=StageSelection.from_payload(StageName.TTS, payload["tts"]),
            persona=Persona.from_payload(payload["persona"]),
        )

    def to_payload(self) -> dict[str, object]:
        return {
            "llm": self.llm.to_payload(),
            "stt": self.stt.to_payload(),
            "tts": self.tts.to_payload(),
            "persona": self.persona.to_payload(),
        }

    def digest(self, *, lease_id: str) -> str:
        if not _LEASE_ID.fullmatch(lease_id):
            raise ContractError("invalid credential lease identifier")
        salted_profile = (
            _canonical_json(self.to_payload()) + b"\n" + lease_id.encode("ascii")
        )
        return hashlib.sha256(salted_profile).hexdigest()


@dataclass(frozen=True, slots=True)
class StageCredential:
    api_key: str = field(repr=False)
    auth_mode: XaiAuthMode | None = None

    @classmethod
    def from_payload(
        cls,
        stage: StageName,
        selection: StageSelection,
        payload: object,
    ) -> StageCredential:
        if not isinstance(payload, dict):
            raise ContractError(f"invalid {stage.value} credential")
        if selection.provider == "xai":
            if set(payload) - {"api_key", "auth_mode"} or "api_key" not in payload:
                raise ContractError(f"invalid {stage.value} credential")
            try:
                # Broker-canonical leases include this field. Missing means a
                # legacy iOS xAI API-key lease and must never imply OAuth.
                auth_mode = XaiAuthMode(payload.get("auth_mode", "api_key"))
            except (TypeError, ValueError) as exc:
                raise ContractError(f"invalid {stage.value} xAI auth mode") from exc
        else:
            if set(payload) != {"api_key"}:
                raise ContractError(f"{stage.value} auth mode is only valid for xAI")
            auth_mode = None
        api_key = payload.get("api_key")
        if not isinstance(api_key, str) or not 8 <= len(api_key) <= MAX_API_KEY_LENGTH:
            raise ContractError(f"invalid {stage.value} API credential")
        if any(character.isspace() for character in api_key):
            raise ContractError(f"invalid {stage.value} API credential")
        return cls(api_key=api_key, auth_mode=auth_mode)


@dataclass(frozen=True, slots=True)
class ClaimedSession:
    lease_id: str
    profile_hash: str
    profile: SessionProfile
    credentials: dict[StageName, StageCredential] = field(repr=False)

    @classmethod
    def from_payload(
        cls, payload: object, *, expected: DispatchEnvelope
    ) -> ClaimedSession:
        if not isinstance(payload, dict):
            raise ContractError("credential lease response must be an object")
        if set(payload) != {
            "schema_version",
            "lease_id",
            "profile_hash",
            "profile",
            "credentials",
        }:
            raise ContractError("credential lease response has unknown fields")
        if payload["schema_version"] != SCHEMA_VERSION:
            raise ContractError("unsupported credential lease schema")
        if payload["lease_id"] != expected.lease_id:
            raise ContractError("credential lease identifier mismatch")
        if payload["profile_hash"] != expected.profile_hash:
            raise ContractError("credential lease profile mismatch")

        profile = SessionProfile.from_payload(payload["profile"])
        if profile.digest(lease_id=expected.lease_id) != expected.profile_hash:
            raise ContractError("credential lease profile integrity check failed")

        raw_credentials = payload["credentials"]
        if not isinstance(raw_credentials, dict):
            raise ContractError("credentials must be an object")
        stage_selections = {
            StageName.LLM: profile.llm,
            StageName.STT: profile.stt,
            StageName.TTS: profile.tts,
        }
        credentials: dict[StageName, StageCredential] = {}
        for raw_stage, raw_credential in raw_credentials.items():
            try:
                stage = StageName(raw_stage)
            except ValueError as exc:
                raise ContractError("credential lease has an unknown stage") from exc
            credentials[stage] = StageCredential.from_payload(
                stage, stage_selections[stage], raw_credential
            )
        expected_credentials = {
            stage
            for stage, selection in stage_selections.items()
            if selection.source is ModelSource.BYOK
        }
        if set(credentials) != expected_credentials:
            raise ContractError("credential stages do not match the session profile")
        claim = cls(
            lease_id=expected.lease_id,
            profile_hash=expected.profile_hash,
            profile=profile,
            credentials=credentials,
        )
        claim.validate_xai_auth_contract()
        return claim

    def key_for(self, stage: StageName) -> str:
        try:
            return self.credentials[stage].api_key
        except KeyError as exc:
            raise ContractError(f"missing {stage.value} credential") from exc

    def xai_auth_mode_for(self, stage: StageName) -> XaiAuthMode:
        selections = {
            StageName.LLM: self.profile.llm,
            StageName.STT: self.profile.stt,
            StageName.TTS: self.profile.tts,
        }
        selection = selections[stage]
        try:
            credential = self.credentials[stage]
        except KeyError as exc:
            raise ContractError(f"missing {stage.value} credential") from exc
        if selection.provider != "xai":
            raise ContractError(f"{stage.value} does not use xAI authentication")
        # Directly constructed objects can bypass payload parsing. Preserve the
        # legacy contract defensively: absent always means API key, never OAuth.
        if credential.auth_mode is None:
            return XaiAuthMode.API_KEY
        if not isinstance(credential.auth_mode, XaiAuthMode):
            raise ContractError(f"invalid {stage.value} xAI auth mode")
        return credential.auth_mode

    def validate_xai_auth_contract(self) -> None:
        selections = {
            StageName.LLM: self.profile.llm,
            StageName.STT: self.profile.stt,
            StageName.TTS: self.profile.tts,
        }
        global_mode: XaiAuthMode | None = None
        global_bearer: bytes | None = None
        for stage, credential in self.credentials.items():
            selection = selections[stage]
            if selection.provider != "xai":
                if credential.auth_mode is not None:
                    raise ContractError(
                        f"{stage.value} auth mode is only valid for xAI"
                    )
                continue
            if credential.auth_mode is None:
                mode = XaiAuthMode.API_KEY
            elif isinstance(credential.auth_mode, XaiAuthMode):
                mode = credential.auth_mode
            else:
                raise ContractError(f"invalid {stage.value} xAI auth mode")
            bearer = credential.api_key.encode("utf-8")
            if global_mode is None:
                global_mode = mode
                global_bearer = bearer
                continue
            if mode != global_mode or not hmac.compare_digest(
                global_bearer or b"", bearer
            ):
                raise ContractError(
                    "xAI stages must use one global authentication mode and bearer"
                )


def _safe_identifier(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not _SAFE_ID.fullmatch(value)
        or "://" in value
        or "@" in value
        or "?" in value
        or "#" in value
    ):
        raise ContractError(f"invalid {label}")
    return value


def validate_catalog_selection(stage: StageName, selection: StageSelection) -> None:
    key = (
        selection.source.value,
        selection.provider,
        selection.model,
        selection.voice,
        selection.language,
    )
    if key not in _CATALOG_SELECTIONS[stage]:
        raise ContractError(
            f"{stage.value} selection is not in the approved provider catalog"
        )


def _optional_identifier(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return _safe_identifier(value, label)


def _canonical_json(payload: object) -> bytes:
    return json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
