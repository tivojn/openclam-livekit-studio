import hashlib
import json
from pathlib import Path

import pytest

from openclam_livekit_agent.contract import (
    _CATALOG_SELECTIONS,
    ClaimedSession,
    ContractError,
    DispatchEnvelope,
    ModelSource,
    SessionProfile,
    StageCredential,
    StageName,
    XaiAuthMode,
)

EXPECTED_CATALOG_SELECTIONS = {
    StageName.LLM: frozenset(
        {
            ("managed", "livekit", "google/gemma-4-31b-it", None, None),
            ("byok", "anthropic", "claude-haiku-4-5", None, None),
            ("byok", "anthropic", "claude-sonnet-4-6", None, None),
            ("byok", "gemini", "gemini-3.5-flash", None, None),
            ("byok", "gemini", "gemini-3.5-flash-lite", None, None),
            ("byok", "gemini", "gemini-3.6-flash", None, None),
            ("byok", "openai", "gpt-5.4-mini", None, None),
            ("byok", "openai", "gpt-5.6-luna", None, None),
            ("byok", "openai", "gpt-5.6-sol", None, None),
            ("byok", "openai", "gpt-5.6-terra", None, None),
            ("byok", "xai", "grok-4.3", None, None),
            ("byok", "xai", "grok-4.5", None, None),
        }
    ),
    StageName.STT: frozenset(
        {
            *(
                (source, provider, model, None, language)
                for source, provider, model, languages in (
                    ("managed", "livekit", "deepgram/nova-3", ("multi", "en", "zh")),
                    ("byok", "deepgram", "nova-3", ("multi", "en", "zh")),
                    (
                        "byok",
                        "elevenlabs",
                        "scribe_v2_realtime",
                        ("multi", "en", "zh"),
                    ),
                    ("byok", "openai", "gpt-4o-transcribe", ("en", "zh")),
                    (
                        "byok",
                        "openai",
                        "gpt-4o-mini-transcribe",
                        ("en", "zh"),
                    ),
                    ("byok", "openai", "whisper-1", ("en", "zh")),
                    # xAI recognizes only its documented 25-language set and
                    # excludes Chinese. `en` is the pinned plugin's required
                    # inverse-text-formatting hint, not a capability claim.
                    ("byok", "xai", "grok-transcribe", ("en",)),
                )
                for language in languages
            ),
        }
    ),
    StageName.TTS: frozenset(
        {
            *(
                ("managed", "livekit", "fishaudio/s2.1-pro", voice, None)
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
                ("byok", "elevenlabs", "eleven_flash_v2_5", voice, None)
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
            *(
                (
                    "byok",
                    "gemini",
                    "gemini-3.1-flash-tts-preview",
                    voice,
                    None,
                )
                for voice in ("Sadachbia", "Kore")
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


def profile_payload() -> dict:
    return {
        "llm": {
            "source": "byok",
            "provider": "openai",
            "model": "gpt-5.4-mini",
        },
        "stt": {
            "source": "managed",
            "provider": "livekit",
            "model": "deepgram/nova-3",
            "language": "multi",
        },
        "tts": {
            "source": "byok",
            "provider": "gemini",
            "model": "gemini-3.1-flash-tts-preview",
            "voice": "Sadachbia",
        },
        "persona": {
            "name": "Captain Ayer",
            "instructions": "Be perceptive, concise, and warm.",
        },
    }


def envelope_for(
    profile: dict | None = None, *, lease_id: str = "a" * 32
) -> DispatchEnvelope:
    profile = profile or profile_payload()
    digest = hashlib.sha256(
        (
            json.dumps(
                profile,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            )
            + "\n"
            + lease_id
        ).encode("utf-8")
    ).hexdigest()
    return DispatchEnvelope(lease_id=lease_id, profile_hash=digest)


def claim_payload(profile: dict | None = None) -> dict:
    profile = profile or profile_payload()
    envelope = envelope_for(profile)
    return {
        "schema_version": 1,
        "lease_id": envelope.lease_id,
        "profile_hash": envelope.profile_hash,
        "profile": profile,
        "credentials": {
            "llm": {"api_key": "openai-test-key"},
            "tts": {"api_key": "google-test-key"},
        },
    }


def all_xai_claim_payload(
    auth_mode: str = "oauth2",
    bearer: str = "one-global-xai-bearer",
) -> dict:
    profile = profile_payload()
    profile["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-4.5",
    }
    profile["stt"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-transcribe",
        "language": "en",
    }
    profile["tts"] = {
        "source": "byok",
        "provider": "xai",
        "model": "xai-tts",
        "voice": "ara",
        "language": "auto",
    }
    payload = claim_payload(profile)
    payload["credentials"] = {
        stage: {"api_key": bearer, "auth_mode": auth_mode}
        for stage in ("llm", "stt", "tts")
    }
    return payload


def test_dispatch_accepts_only_opaque_lease_and_hash() -> None:
    envelope = envelope_for()
    raw = json.dumps(
        {
            "schema_version": 1,
            "lease_id": envelope.lease_id,
            "profile_hash": envelope.profile_hash,
        }
    )
    assert DispatchEnvelope.from_metadata(raw) == envelope

    leaked = json.loads(raw)
    leaked["api_key"] = "must-not-be-here"
    with pytest.raises(ContractError, match="unknown fields"):
        DispatchEnvelope.from_metadata(json.dumps(leaked))


def test_agent_catalog_is_the_exact_reviewed_superset() -> None:
    assert _CATALOG_SELECTIONS == EXPECTED_CATALOG_SELECTIONS


def test_agent_catalog_matches_the_canonical_cross_tier_fixture() -> None:
    fixture_path = (
        Path(__file__).resolve().parents[2]
        / "contracts"
        / "live-talk-approved-tuples-v1.json"
    )
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    assert fixture["schema_version"] == 1

    # The shared normalization is a six-field tuple with null for absent
    # voice/language, sorted after replacing null with an empty string.
    fixture_tuples = fixture["tuples"]

    def sort_key(row: list[str | None]) -> tuple[str, ...]:
        return tuple("" if value is None else value for value in row)

    assert fixture_tuples == sorted(fixture_tuples, key=sort_key)

    agent_tuples = [
        [stage.value, *selection]
        for stage, selections in _CATALOG_SELECTIONS.items()
        for selection in selections
    ]
    assert sorted(agent_tuples, key=sort_key) == fixture_tuples


@pytest.mark.parametrize(
    ("stage", "selection"),
    [
        (stage, selection)
        for stage, selections in EXPECTED_CATALOG_SELECTIONS.items()
        for selection in selections
    ],
)
def test_every_reviewed_catalog_tuple_parses(
    stage: StageName, selection: tuple[str, str, str, str | None, str | None]
) -> None:
    payload = profile_payload()
    source, provider, model, voice, language = selection
    value = {"source": source, "provider": provider, "model": model}
    if voice is not None:
        value["voice"] = voice
    if language is not None:
        value["language"] = language
    payload[stage.value] = value

    parsed = SessionProfile.from_payload(payload)

    assert parsed.to_payload()[stage.value] == value


def test_claim_integrity_and_exact_byok_stage_credentials() -> None:
    envelope = envelope_for()
    claim = ClaimedSession.from_payload(claim_payload(), expected=envelope)
    assert claim.profile.llm.source is ModelSource.BYOK
    assert claim.profile.stt.source is ModelSource.MANAGED
    assert claim.key_for(StageName.LLM) == "openai-test-key"

    missing = claim_payload()
    del missing["credentials"]["tts"]
    with pytest.raises(ContractError, match="do not match"):
        ClaimedSession.from_payload(missing, expected=envelope)


def test_legacy_missing_xai_mode_is_strictly_canonicalized_to_api_key() -> None:
    profile = profile_payload()
    profile["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-4.3",
    }
    payload = claim_payload(profile)

    claim = ClaimedSession.from_payload(payload, expected=envelope_for(profile))

    assert claim.xai_auth_mode_for(StageName.LLM) is XaiAuthMode.API_KEY
    assert claim.credentials[StageName.LLM].auth_mode is XaiAuthMode.API_KEY


@pytest.mark.parametrize("auth_mode", ["api_key", "oauth2"])
def test_explicit_xai_auth_modes_parse_without_exposing_bearer(
    auth_mode: str,
) -> None:
    profile = profile_payload()
    profile["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-4.5",
    }
    payload = claim_payload(profile)
    payload["credentials"]["llm"] = {
        "api_key": "sentinel-xai-bearer",
        "auth_mode": auth_mode,
    }

    claim = ClaimedSession.from_payload(payload, expected=envelope_for(profile))

    assert claim.xai_auth_mode_for(StageName.LLM).value == auth_mode
    assert "sentinel-xai-bearer" not in repr(claim)
    assert "sentinel-xai-bearer" not in repr(claim.credentials[StageName.LLM])


@pytest.mark.parametrize("bad_mode", ["hybrid", "", None, 1, True])
def test_xai_rejects_unknown_or_non_string_auth_modes(bad_mode: object) -> None:
    profile = profile_payload()
    profile["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-4.3",
    }
    payload = claim_payload(profile)
    payload["credentials"]["llm"]["auth_mode"] = bad_mode

    with pytest.raises(ContractError, match="xAI auth mode"):
        ClaimedSession.from_payload(payload, expected=envelope_for(profile))


@pytest.mark.parametrize("auth_mode", ["api_key", "oauth2", "hybrid"])
def test_non_xai_credentials_reject_every_auth_mode(auth_mode: str) -> None:
    payload = claim_payload()
    payload["credentials"]["llm"]["auth_mode"] = auth_mode

    with pytest.raises(ContractError, match="only valid for xAI"):
        ClaimedSession.from_payload(payload, expected=envelope_for())


@pytest.mark.parametrize("auth_mode", ["api_key", "oauth2"])
def test_all_xai_stages_require_and_accept_one_global_credential(
    auth_mode: str,
) -> None:
    payload = all_xai_claim_payload(auth_mode)
    claim = ClaimedSession.from_payload(
        payload, expected=envelope_for(payload["profile"])
    )

    assert {claim.xai_auth_mode_for(stage) for stage in StageName} == {
        XaiAuthMode(auth_mode)
    }
    assert {claim.key_for(stage) for stage in StageName} == {"one-global-xai-bearer"}


def test_legacy_and_explicit_xai_api_key_stages_canonicalize_globally() -> None:
    payload = all_xai_claim_payload("api_key")
    del payload["credentials"]["llm"]["auth_mode"]

    claim = ClaimedSession.from_payload(
        payload, expected=envelope_for(payload["profile"])
    )

    assert all(
        claim.xai_auth_mode_for(stage) is XaiAuthMode.API_KEY for stage in StageName
    )


@pytest.mark.parametrize(
    ("field", "value"),
    [("api_key", "different-xai-bearer"), ("auth_mode", "api_key")],
)
def test_agent_rejects_different_xai_bearer_or_mode(
    field: str,
    value: str,
) -> None:
    payload = all_xai_claim_payload("oauth2")
    payload["credentials"]["stt"][field] = value

    with pytest.raises(ContractError, match="one global"):
        ClaimedSession.from_payload(payload, expected=envelope_for(payload["profile"]))


def test_direct_contract_object_cannot_smuggle_string_auth_mode() -> None:
    payload = all_xai_claim_payload()
    original = ClaimedSession.from_payload(
        payload, expected=envelope_for(payload["profile"])
    )
    credentials = dict(original.credentials)
    credentials[StageName.STT] = StageCredential(
        api_key="one-global-xai-bearer",
        auth_mode="oauth2",  # type: ignore[arg-type]
    )
    direct = ClaimedSession(
        lease_id=original.lease_id,
        profile_hash=original.profile_hash,
        profile=original.profile,
        credentials=credentials,
    )

    with pytest.raises(ContractError, match="xAI auth mode"):
        direct.validate_xai_auth_contract()


def test_profile_hash_is_recursive_canonical_json() -> None:
    payload = profile_payload()
    profile = SessionProfile.from_payload(payload)
    assert profile.digest(lease_id="a" * 32) == envelope_for(payload).profile_hash
    assert profile.digest(lease_id="a" * 32) != profile.digest(lease_id="b" * 32)

    payload["persona"]["instructions"] = "Changed"
    mismatched = claim_payload(payload)
    mismatched["profile_hash"] = envelope_for(profile_payload()).profile_hash
    with pytest.raises(ContractError, match="integrity"):
        ClaimedSession.from_payload(
            mismatched, expected=envelope_for(profile_payload())
        )


@pytest.mark.parametrize(
    ("stage", "mutation", "message"),
    [
        ("llm", {"provider": "https://attacker.example"}, "provider"),
        ("stt", {"voice": "not-allowed"}, "cannot select a voice"),
        ("tts", {"source": "managed", "provider": "xai"}, "must use LiveKit"),
    ],
)
def test_profile_rejects_unsafe_or_inconsistent_fields(
    stage: str, mutation: dict, message: str
) -> None:
    payload = profile_payload()
    payload[stage].update(mutation)
    with pytest.raises(ContractError, match=message):
        SessionProfile.from_payload(payload)


def test_persona_is_bounded() -> None:
    payload = profile_payload()
    payload["persona"]["instructions"] = "x" * 4097
    with pytest.raises(ContractError, match="too large"):
        SessionProfile.from_payload(payload)

    payload["persona"]["instructions"] = "   "
    with pytest.raises(ContractError, match="avatar instructions"):
        SessionProfile.from_payload(payload)


def test_persona_name_matches_broker_eighty_character_limit() -> None:
    payload = profile_payload()
    payload["persona"]["name"] = "A" * 80
    assert SessionProfile.from_payload(payload).persona.name == "A" * 80

    payload["persona"]["name"] = "A" * 81
    with pytest.raises(ContractError, match="avatar name"):
        SessionProfile.from_payload(payload)


@pytest.mark.parametrize(
    ("stage", "mutation"),
    [
        ("llm", {"model": "gpt-5.4"}),
        ("llm", {"model": "gpt-5.6"}),
        (
            "llm",
            {"provider": "anthropic", "model": "claude-sonnet-5"},
        ),
        ("llm", {"language": "en"}),
        ("stt", {"language": "fr"}),
        (
            "stt",
            {
                "source": "byok",
                "provider": "openai",
                "model": "gpt-4o-transcribe",
                "language": "fr",
            },
        ),
        ("tts", {"voice": "attacker-selected-voice"}),
        ("tts", {"language": "en"}),
        (
            "tts",
            {
                "provider": "xai",
                "model": "xai-tts",
                "voice": "ara",
                "language": "en",
            },
        ),
        (
            "tts",
            {
                "source": "managed",
                "provider": "livekit",
                "model": "fishaudio/s2.1-pro",
                "voice": "unreviewed-managed-voice",
            },
        ),
        (
            "tts",
            {
                "provider": "openai",
                "model": "tts-1",
                "voice": "nova",
            },
        ),
        (
            "tts",
            {
                "provider": "elevenlabs",
                "model": "eleven_multilingual_v2",
                "voice": "EXAVITQu4vr4xnSDxMaL",
            },
        ),
        (
            "tts",
            {
                "provider": "gemini",
                "model": "gemini-2.5-flash-preview-tts",
                "voice": "Kore",
            },
        ),
    ],
)
def test_profile_rejects_every_tuple_outside_closed_catalog(
    stage: str, mutation: dict
) -> None:
    payload = profile_payload()
    payload[stage].update(mutation)
    with pytest.raises(ContractError, match="approved provider catalog"):
        SessionProfile.from_payload(payload)


def test_api_key_limit_matches_broker_and_repr_never_contains_secrets() -> None:
    accepted = claim_payload()
    accepted["credentials"]["llm"]["api_key"] = "s" * 4_096
    accepted["credentials"]["tts"]["api_key"] = "sentinel-tts-secret"
    claim = ClaimedSession.from_payload(accepted, expected=envelope_for())
    assert len(claim.key_for(StageName.LLM)) == 4_096
    assert "sentinel-tts-secret" not in repr(claim)
    assert "sentinel-tts-secret" not in repr(claim.credentials[StageName.TTS])

    rejected = claim_payload()
    rejected["credentials"]["llm"]["api_key"] = "s" * 4_097
    with pytest.raises(ContractError, match="API credential"):
        ClaimedSession.from_payload(rejected, expected=envelope_for())
