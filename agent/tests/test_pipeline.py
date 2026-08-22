import asyncio
import json
from dataclasses import replace
from unittest.mock import MagicMock

import httpx
import pytest
from aiohttp import web
from livekit import rtc
from livekit.agents import inference, stt
from livekit.agents.voice.agent_session import (
    DEFAULT_EXPRESSIVE_OPTIONS,
    resolve_expressive_options,
)
from livekit.plugins import anthropic, deepgram, elevenlabs, google, openai, xai
from livekit.plugins.xai import stt as xai_stt_plugin
from test_contract import (
    all_xai_claim_payload,
    claim_payload,
    envelope_for,
    profile_payload,
)

from openclam_livekit_agent import pipeline as pipeline_module
from openclam_livekit_agent.contract import (
    ClaimedSession,
    ModelSource,
    SessionProfile,
    StageCredential,
    StageName,
    StageSelection,
    XaiAuthMode,
)
from openclam_livekit_agent.main import OpenClamVoiceAgent, create_session
from openclam_livekit_agent.pipeline import (
    MANAGED_LLM,
    MANAGED_STT,
    MANAGED_TTS,
    MANAGED_TTS_OPTIONS,
    MANAGED_TTS_VOICE,
    MANAGED_TTS_VOICES,
    XAI_CLI_AUTHENTICATE_RESPONSE,
    XAI_CLI_CLIENT_IDENTIFIER,
    XAI_CLI_CLIENT_MODE,
    XAI_CLI_CLIENT_VERSION,
    XAI_CLI_PROXY_BASE_URL,
    XAI_CLI_PROXY_MODEL,
    XAI_CLI_TOKEN_AUTH,
    XAI_STT_ENDPOINTING_MS,
    XAI_STT_SMART_TURN_THRESHOLD,
    XAI_STT_SMART_TURN_TIMEOUT_MS,
    XAI_STT_VAD_THRESHOLD,
    PipelineConfigurationError,
    create_pipeline,
)


def claim_for(payload: dict) -> ClaimedSession:
    envelope = envelope_for(payload["profile"])
    payload["lease_id"] = envelope.lease_id
    payload["profile_hash"] = envelope.profile_hash
    return ClaimedSession.from_payload(payload, expected=envelope)


def managed_claim(voice: str = MANAGED_TTS_VOICE) -> ClaimedSession:
    profile = {
        "llm": {
            "source": "managed",
            "provider": "livekit",
            "model": MANAGED_LLM,
        },
        "stt": {
            "source": "managed",
            "provider": "livekit",
            "model": MANAGED_STT,
            "language": "multi",
        },
        "tts": {
            "source": "managed",
            "provider": "livekit",
            "model": MANAGED_TTS,
            "voice": voice,
        },
        "persona": {"name": "OpenClam", "instructions": "Be warm."},
    }
    envelope = envelope_for(profile)
    return ClaimedSession.from_payload(
        {
            "schema_version": 1,
            "lease_id": envelope.lease_id,
            "profile_hash": envelope.profile_hash,
            "profile": profile,
            "credentials": {},
        },
        expected=envelope,
    )


def test_managed_default_is_all_livekit_inference_and_expressive() -> None:
    pipeline = create_pipeline(managed_claim())
    assert isinstance(pipeline.llm, inference.LLM)
    assert isinstance(pipeline.stt, inference.STT)
    assert isinstance(pipeline.tts, inference.TTS)
    assert isinstance(pipeline.expressive, dict)
    assert pipeline.private_expressive_markup_enabled is True
    assert pipeline.preemptive_generation_enabled is True
    assert MANAGED_TTS_VOICE == "933563129e564b19a115bedd57b7406a"
    assert pipeline.tts._opts.voice == MANAGED_TTS_VOICE
    instructions = OpenClamVoiceAgent(
        pipeline=pipeline,
        persona_name="OpenClam",
        persona="Be warm.",
        room=MagicMock(spec=rtc.Room),
    ).instructions
    assert isinstance(instructions, str)
    assert "only the private LiveKit expressive tags" in instructions
    assert "This session has no expressive-markup processor" not in instructions


@pytest.mark.parametrize(
    "voice",
    [
        "bf322df2096a46f18c579d0baa36f41d",
        "536d3a5e000945adb7038665781a4aca",
        "9a9cf47702da476aa4629e2506d4a857",
        "79d0bd3e4e5444b18f7b6d89b5927bf1",
        "e3cd384158934cc9a01029cd7d278634",
        "933563129e564b19a115bedd57b7406a",
        "b347db033a6549378b48d00acb0d06cd",
    ],
)
def test_managed_fish_accepts_each_reviewed_voice(voice: str) -> None:
    pipeline = create_pipeline(managed_claim(voice))

    assert {
        "bf322df2096a46f18c579d0baa36f41d",
        "536d3a5e000945adb7038665781a4aca",
        "9a9cf47702da476aa4629e2506d4a857",
        "79d0bd3e4e5444b18f7b6d89b5927bf1",
        "e3cd384158934cc9a01029cd7d278634",
        "933563129e564b19a115bedd57b7406a",
        "b347db033a6549378b48d00acb0d06cd",
    } == MANAGED_TTS_VOICES
    assert isinstance(pipeline.tts, inference.TTS)
    assert pipeline.tts._opts.voice == voice
    assert pipeline.tts._opts.extra_kwargs == MANAGED_TTS_OPTIONS


def test_managed_fish_uses_quality_first_expressive_sampling() -> None:
    pipeline = create_pipeline(managed_claim())

    assert isinstance(pipeline.tts, inference.TTS)
    assert pipeline.tts._opts.extra_kwargs == MANAGED_TTS_OPTIONS
    assert pipeline.tts._opts.extra_kwargs == {
        "latency": "balanced",
        "temperature": 0.85,
    }


def test_managed_fish_resolves_strong_natural_expressive_prompt() -> None:
    pipeline = create_pipeline(managed_claim())

    assert isinstance(pipeline.tts, inference.TTS)
    assert isinstance(pipeline.expressive, dict)
    resolved = resolve_expressive_options(
        pipeline.expressive,
        provider_key=pipeline.tts.markup._provider_key(),
        default=DEFAULT_EXPRESSIVE_OPTIONS,
    )
    markup_guide = pipeline.tts.markup.llm_instructions(
        speech_steering=resolved["speech_steering"]
    )
    prompt = resolved["tts_instructions_template"].render(
        modality=None,
        data={"tts": {"markup": {"llm_instructions": markup_guide}}},
    )

    assert "Give every sentence its own emotion marker" in prompt
    assert "Make emotional contrast clearly audible" in prompt
    assert "one emotion marker at the start of every spoken sentence" in prompt
    assert "never add written stage directions" in prompt
    assert "Use one fitting prosody marker" not in prompt
    assert (
        pipeline.tts.markup.convert('<expr type="expression" label="excited"/> Great!')
        == "[very excited] Great!"
    )


@pytest.mark.parametrize(
    ("provider", "expected_type"),
    [
        ("openai", openai.responses.LLM),
        ("xai", xai.responses.LLM),
        ("gemini", google.LLM),
        ("anthropic", anthropic.LLM),
    ],
)
def test_byok_llm_plugins_receive_per_job_keys(
    provider: str, expected_type: type
) -> None:
    payload = claim_payload()
    payload["profile"]["llm"]["provider"] = provider
    payload["profile"]["llm"]["model"] = {
        "openai": "gpt-5.4-mini",
        "xai": "grok-4.3",
        "gemini": "gemini-3.5-flash",
        "anthropic": "claude-sonnet-4-6",
    }[provider]
    pipeline = create_pipeline(claim_for(payload))
    assert isinstance(pipeline.llm, expected_type)


def test_openai_responses_disables_provider_storage() -> None:
    pipeline = create_pipeline(claim_for(claim_payload()))
    assert isinstance(pipeline.llm, openai.responses.LLM)
    assert pipeline.llm._opts.store is False


@pytest.mark.parametrize(
    "model",
    ["gpt-5.4-mini", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"],
)
def test_openai_models_explicitly_disable_reasoning_for_voice_latency(
    model: str,
) -> None:
    payload = claim_payload()
    payload["profile"]["llm"]["model"] = model

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.llm, openai.responses.LLM)
    assert pipeline.llm._opts.model == model
    assert pipeline.llm._opts.reasoning == {"effort": "none"}


@pytest.mark.parametrize(
    ("model", "expected_effort"),
    [("grok-4.3", "none"), ("grok-4.5", "low")],
)
def test_xai_models_use_reviewed_reasoning_effort(
    model: str, expected_effort: str
) -> None:
    payload = claim_payload()
    payload["profile"]["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": model,
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.llm, xai.responses.LLM)
    assert pipeline.llm._opts.model == model
    assert pipeline.llm._opts.reasoning == {"effort": expected_effort}


@pytest.mark.asyncio
async def test_xai_oauth_llm_uses_exact_pinned_cli_proxy_contract_and_closes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "id": "chatcmpl-openclam-test",
                "object": "chat.completion",
                "created": 1,
                "model": XAI_CLI_PROXY_MODEL,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "Ready."},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            },
            request=request,
        )

    production_http_client = pipeline_module._new_xai_oauth_http_client()
    assert production_http_client.follow_redirects is False
    assert production_http_client._trust_env is False
    assert production_http_client.timeout == httpx.Timeout(
        connect=15.0, read=30.0, write=15.0, pool=5.0
    )
    await production_http_client.aclose()

    mock_http_client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        follow_redirects=False,
        trust_env=False,
    )
    monkeypatch.setattr(
        pipeline_module,
        "_new_xai_oauth_http_client",
        lambda: mock_http_client,
    )
    monkeypatch.setattr(pipeline_module.platform, "system", lambda: "Linux")
    monkeypatch.setattr(pipeline_module.platform, "machine", lambda: "x86_64")
    bearer = "sentinel-oauth-access-token"
    selected_model = "grok-4.5"
    payload = claim_payload()
    payload["profile"]["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": selected_model,
    }
    payload["credentials"]["llm"] = {
        "api_key": bearer,
        "auth_mode": "oauth2",
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.llm, openai.LLM)
    assert not isinstance(pipeline.llm, xai.responses.LLM)
    assert pipeline.llm._opts.model == XAI_CLI_PROXY_MODEL
    assert str(pipeline.llm._client.base_url) == f"{XAI_CLI_PROXY_BASE_URL}/"
    assert pipeline.llm._client.max_retries == 0

    completion = await pipeline.llm._client.chat.completions.create(
        model=pipeline.llm._opts.model,
        messages=[{"role": "user", "content": "Hello"}],
    )
    assert completion.choices[0].message.content == "Ready."
    assert len(requests) == 1
    request = requests[0]
    assert str(request.url) == ("https://cli-chat-proxy.grok.com/v1/chat/completions")
    assert request.headers["authorization"] == f"Bearer {bearer}"
    assert request.headers["accept"] == "text/event-stream"
    assert request.headers["user-agent"] == "grok-shell/1.0.4 (linux; x86_64)"
    assert request.headers["x-xai-token-auth"] == XAI_CLI_TOKEN_AUTH
    assert request.headers["x-authenticateresponse"] == XAI_CLI_AUTHENTICATE_RESPONSE
    assert request.headers["x-grok-client-identifier"] == XAI_CLI_CLIENT_IDENTIFIER
    assert request.headers["x-grok-client-mode"] == XAI_CLI_CLIENT_MODE
    assert request.headers["x-grok-client-version"] == XAI_CLI_CLIENT_VERSION
    assert XAI_CLI_CLIENT_VERSION == "1.0.4"
    assert request.headers["x-grok-model-override"] == selected_model
    body = json.loads(request.content)
    assert body["model"] == XAI_CLI_PROXY_MODEL
    assert selected_model not in request.content.decode("utf-8")

    assert mock_http_client.is_closed is False
    await pipeline.llm.aclose()
    assert mock_http_client.is_closed is True
    await pipeline.llm.aclose()


@pytest.mark.parametrize("auth_mode", ["api_key", "oauth2"])
def test_xai_direct_stt_and_tts_receive_selected_mode_bearer(
    auth_mode: str,
) -> None:
    bearer = f"xai-{auth_mode}-selected-bearer"
    payload = claim_payload()
    payload["profile"]["llm"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-4.3",
    }
    payload["profile"]["stt"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-transcribe",
        "language": "en",
    }
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": "xai",
        "model": "xai-tts",
        "voice": "ara",
        "language": "auto",
    }
    payload["credentials"] = {
        stage: {"api_key": bearer, "auth_mode": auth_mode}
        for stage in ("llm", "stt", "tts")
    }

    pipeline = create_pipeline(claim_for(payload))

    if auth_mode == "api_key":
        assert isinstance(pipeline.llm, xai.responses.LLM)
    else:
        assert isinstance(pipeline.llm, openai.LLM)
    assert isinstance(pipeline.stt, xai.STT)
    assert isinstance(pipeline.tts, xai.TTS)
    assert pipeline.stt._api_key == bearer
    assert pipeline.tts._api_key == bearer
    assert pipeline.stt._opts.endpointing == XAI_STT_ENDPOINTING_MS
    assert pipeline.stt._opts.vad_threshold == XAI_STT_VAD_THRESHOLD
    assert pipeline.stt._opts.smart_turn == XAI_STT_SMART_TURN_THRESHOLD
    assert pipeline.stt._opts.smart_turn_timeout == XAI_STT_SMART_TURN_TIMEOUT_MS
    assert pipeline.preemptive_generation_enabled is False
    if auth_mode == "oauth2":
        asyncio.run(pipeline.llm.aclose())


@pytest.mark.asyncio
@pytest.mark.parametrize("auth_mode", ["api_key", "oauth2"])
async def test_xai_speech_transport_is_origin_pinned_proxy_free_and_owned(
    auth_mode: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("HTTPS_PROXY", "http://attacker-proxy.example")
    monkeypatch.setenv("ALL_PROXY", "http://attacker-proxy.example")
    pipeline = create_pipeline(claim_for(all_xai_claim_payload(auth_mode=auth_mode)))
    stt_session = pipeline.stt._openclam_speech_session
    tts_session = pipeline.tts._openclam_speech_session

    assert pipeline.stt._session is stt_session
    assert pipeline.tts._session is tts_session
    assert stt_session.expected_path == pipeline_module.XAI_STT_PATH
    assert tts_session.expected_path == pipeline_module.XAI_TTS_PATH
    assert stt_session._client is None
    assert tts_session._client is None

    bearer = "one-global-xai-bearer"
    stt_calls = []
    tts_calls = []
    stt_websocket = object()
    tts_websocket = object()

    async def fake_stt_ws_connect(url, **kwargs):
        stt_calls.append((url, kwargs))
        return stt_websocket

    async def fake_tts_ws_connect(url, **kwargs):
        tts_calls.append((url, kwargs))
        return tts_websocket

    with monkeypatch.context() as speech_patch:
        speech_patch.setattr(stt_session, "ws_connect", fake_stt_ws_connect)
        speech_patch.setattr(tts_session, "ws_connect", fake_tts_ws_connect)
        raw_stt_stream = object.__new__(xai_stt_plugin.SpeechStream)
        raw_stt_stream._session = stt_session
        raw_stt_stream._opts = pipeline.stt._opts
        raw_stt_stream._api_key = bearer
        raw_stt_stream._conn_options = MagicMock(timeout=1.0)

        assert await raw_stt_stream._connect_ws() is stt_websocket
        assert await pipeline.tts._connect_ws(1.0, pipeline.tts._opts) is tts_websocket

    assert stt_calls[0][0] == "wss://api.x.ai/v1/stt"
    assert stt_calls[0][1]["headers"] == {"Authorization": f"Bearer {bearer}"}
    stt_parameters = dict(stt_calls[0][1]["params"])
    assert stt_parameters["endpointing"] == str(XAI_STT_ENDPOINTING_MS)
    assert stt_parameters["vad_threshold"] == str(XAI_STT_VAD_THRESHOLD)
    assert stt_parameters["smart_turn"] == str(XAI_STT_SMART_TURN_THRESHOLD)
    assert stt_parameters["smart_turn_timeout"] == str(
        XAI_STT_SMART_TURN_TIMEOUT_MS
    )
    assert tts_calls[0][0].startswith("wss://api.x.ai/v1/tts?")
    assert tts_calls[0][1]["headers"] == {"Authorization": f"Bearer {bearer}"}

    clients = [stt_session._ensure_client(), tts_session._ensure_client()]
    for client in clients:
        assert client.trust_env is False
        assert isinstance(client.cookie_jar, pipeline_module.aiohttp.DummyCookieJar)
        assert len(client.trace_configs) == 1
        assert list(client.trace_configs[0].on_request_redirect) == [
            pipeline_module._reject_xai_speech_redirect
        ]

    redirect_params = MagicMock()
    redirect_params.response = MagicMock()
    with pytest.raises(
        pipeline_module.aiohttp.ClientConnectionError,
        match="redirect rejected",
    ):
        await pipeline_module._reject_xai_speech_redirect(None, None, redirect_params)
    redirect_params.response.close.assert_called_once_with()

    with pytest.raises(PipelineConfigurationError, match="endpoint"):
        await stt_session.ws_connect(
            "wss://attacker.example/v1/stt",
            headers={"Authorization": "Bearer must-not-leak"},
        )
    with pytest.raises(PipelineConfigurationError, match="proxies"):
        await tts_session.ws_connect(
            "wss://api.x.ai/v1/tts?voice=ara",
            proxy="http://attacker-proxy.example",
        )

    assert all(not client.closed for client in clients)
    await pipeline.stt.aclose()
    await pipeline.tts.aclose()
    await pipeline.llm.aclose()
    assert all(client.closed for client in clients)


@pytest.mark.asyncio
async def test_xai_timeout_endpoints_two_questions_as_two_complete_turns() -> None:
    pipeline = create_pipeline(claim_for(all_xai_claim_payload()))
    events: list[stt.SpeechEvent] = []

    class EventChannel:
        def send_nowait(self, event: stt.SpeechEvent) -> None:
            events.append(event)

    stream = object.__new__(xai_stt_plugin.SpeechStream)
    stream._opts = pipeline.stt._opts
    stream._event_ch = EventChannel()
    stream._request_id = "two-turn-proof"
    stream._speaking = False
    stream._emitted_chunk_final = False

    def emit_timeout_bounded_turn(text: str) -> None:
        stream._process_stream_event(
            {
                "type": "transcript.partial",
                "text": text,
                "words": [],
                "language": "en",
                "is_final": True,
                "speech_final": False,
            }
        )
        # This is the utterance-final event xAI guarantees no later than the
        # configured Smart Turn timeout. The pinned plugin suppresses the
        # duplicate text while still emitting the required end-of-speech.
        stream._process_stream_event(
            {
                "type": "transcript.partial",
                "text": text,
                "words": [],
                "language": "en",
                "is_final": True,
                "speech_final": True,
            }
        )

    emit_timeout_bounded_turn("What is your name?")
    emit_timeout_bounded_turn("How are you today?")

    assert [event.type for event in events] == [
        stt.SpeechEventType.START_OF_SPEECH,
        stt.SpeechEventType.FINAL_TRANSCRIPT,
        stt.SpeechEventType.END_OF_SPEECH,
        stt.SpeechEventType.START_OF_SPEECH,
        stt.SpeechEventType.FINAL_TRANSCRIPT,
        stt.SpeechEventType.END_OF_SPEECH,
    ]
    assert [
        event.alternatives[0].text
        for event in events
        if event.type == stt.SpeechEventType.FINAL_TRANSCRIPT
    ] == ["What is your name?", "How are you today?"]

    session = create_session(pipeline)
    assert session.options.preemptive_generation["enabled"] is False


@pytest.mark.asyncio
async def test_xai_speech_session_rejects_a_real_redirect_before_target(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    target_hits = 0

    async def redirect(_request: web.Request) -> web.Response:
        raise web.HTTPFound(location="/target")

    async def target(_request: web.Request) -> web.Response:
        nonlocal target_hits
        target_hits += 1
        return web.Response(text="must-not-be-reached")

    app = web.Application()
    app.router.add_get("/redirect", redirect)
    app.router.add_get("/target", target)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    assert site._server is not None
    port = site._server.sockets[0].getsockname()[1]
    monkeypatch.setenv("HTTP_PROXY", "http://attacker-proxy.example")

    speech_session = pipeline_module._HardenedXaiSpeechSession(
        pipeline_module.XAI_STT_PATH
    )
    client = speech_session._ensure_client()
    try:
        with pytest.raises(
            pipeline_module.aiohttp.ClientConnectionError,
            match="redirect rejected",
        ):
            await client.get(f"http://127.0.0.1:{port}/redirect")
        assert target_hits == 0
        assert client.trust_env is False
    finally:
        await speech_session.close()
        await runner.cleanup()


def test_pipeline_rejects_directly_constructed_inconsistent_xai_credentials() -> None:
    original = claim_for(all_xai_claim_payload())
    credentials = dict(original.credentials)
    credentials[StageName.STT] = StageCredential(
        api_key="different-xai-bearer",
        auth_mode=XaiAuthMode.OAUTH2,
    )
    inconsistent = ClaimedSession(
        lease_id=original.lease_id,
        profile_hash=original.profile_hash,
        profile=original.profile,
        credentials=credentials,
    )

    with pytest.raises(PipelineConfigurationError, match="one global"):
        create_pipeline(inconsistent)


@pytest.mark.parametrize(
    "model", ["gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.6-flash"]
)
def test_gemini_llm_models_reach_the_exact_plugin_constructor(model: str) -> None:
    payload = claim_payload()
    payload["profile"]["llm"] = {
        "source": "byok",
        "provider": "gemini",
        "model": model,
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.llm, google.LLM)
    assert pipeline.llm._opts.model == model


@pytest.mark.parametrize("model", ["claude-sonnet-4-6", "claude-haiku-4-5"])
def test_anthropic_llm_models_reach_the_exact_plugin_constructor(model: str) -> None:
    payload = claim_payload()
    payload["profile"]["llm"] = {
        "source": "byok",
        "provider": "anthropic",
        "model": model,
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.llm, anthropic.LLM)
    assert pipeline.llm._opts.model == model


@pytest.mark.parametrize(
    ("provider", "model", "expected_type"),
    [
        ("openai", "gpt-4o-mini-transcribe", openai.STT),
        ("xai", "grok-transcribe", xai.STT),
        ("deepgram", "nova-3", deepgram.STT),
        ("elevenlabs", "scribe_v2_realtime", elevenlabs.STT),
    ],
)
def test_byok_stt_plugins_are_stage_scoped(
    provider: str, model: str, expected_type: type
) -> None:
    payload = claim_payload()
    payload["profile"]["stt"] = {
        "source": "byok",
        "provider": provider,
        "model": model,
        "language": "en",
    }
    payload["credentials"]["stt"] = {"api_key": "stt-provider-key"}
    pipeline = create_pipeline(claim_for(payload))
    assert isinstance(pipeline.stt, expected_type)


@pytest.mark.parametrize(
    "model", ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
)
def test_openai_stt_models_reach_the_non_realtime_constructor(model: str) -> None:
    payload = claim_payload()
    payload["profile"]["stt"] = {
        "source": "byok",
        "provider": "openai",
        "model": model,
        "language": "zh",
    }
    payload["credentials"]["stt"] = {"api_key": "stt-provider-key"}

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.stt, openai.STT)
    assert pipeline.stt.model == model
    assert pipeline.stt._opts.languages == ["zh"]
    assert pipeline.stt.capabilities.streaming is False


def test_xai_stt_keeps_en_formatting_hint_without_claiming_chinese_support() -> None:
    payload = claim_payload()
    payload["profile"]["stt"] = {
        "source": "byok",
        "provider": "xai",
        "model": "grok-transcribe",
        "language": "en",
    }
    payload["credentials"]["stt"] = {"api_key": "stt-provider-key"}

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.stt, xai.STT)
    # Recognition is automatic only within xAI's documented 25-language set.
    # This required value is the plugin's inverse-text-formatting hint; it must
    # never be changed to auto, multi, or zh (Chinese is not supported).
    assert pipeline.stt._opts.language == "en"


def test_elevenlabs_multilingual_selection_uses_auto_detection() -> None:
    payload = claim_payload()
    payload["profile"]["stt"] = {
        "source": "byok",
        "provider": "elevenlabs",
        "model": "scribe_v2_realtime",
        "language": "multi",
    }
    payload["credentials"]["stt"] = {"api_key": "stt-provider-key"}

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.stt, elevenlabs.STT)
    assert pipeline.stt._opts.language_code is None


@pytest.mark.parametrize(
    ("provider", "model", "voice", "expected_type"),
    [
        ("openai", "gpt-4o-mini-tts", "alloy", openai.TTS),
        ("xai", "xai-tts", "ara", xai.TTS),
        (
            "gemini",
            "gemini-3.1-flash-tts-preview",
            "Sadachbia",
            google.beta.GeminiTTS,
        ),
        (
            "deepgram",
            "aura-2-andromeda-en",
            "aura-2-andromeda-en",
            deepgram.TTS,
        ),
        (
            "elevenlabs",
            "eleven_flash_v2_5",
            "EXAVITQu4vr4xnSDxMaL",
            elevenlabs.TTS,
        ),
    ],
)
def test_byok_tts_is_direct_and_not_livekit_expressive(
    provider: str, model: str, voice: str, expected_type: type
) -> None:
    payload = claim_payload()
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": provider,
        "model": model,
        "voice": voice,
    }
    if provider == "xai":
        payload["profile"]["tts"]["language"] = "auto"
    pipeline = create_pipeline(claim_for(payload))
    assert isinstance(pipeline.tts, expected_type)
    assert pipeline.expressive is False
    assert pipeline.private_expressive_markup_enabled is False
    instructions = OpenClamVoiceAgent(
        pipeline=pipeline,
        persona_name="OpenClam",
        persona="Be warm.",
        room=MagicMock(spec=rtc.Room),
    ).instructions
    assert isinstance(instructions, str)
    assert "This session has no expressive-markup processor" in instructions
    assert "only the private LiveKit expressive tags" not in instructions


@pytest.mark.parametrize("voice", ["ara", "eve", "leo", "rex", "sal"])
def test_xai_tts_uses_each_reviewed_voice(voice: str) -> None:
    payload = claim_payload()
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": "xai",
        "model": "xai-tts",
        "voice": voice,
        "language": "auto",
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.tts, xai.TTS)
    assert pipeline.tts._opts.voice == voice
    assert pipeline.tts._opts.language == "auto"


@pytest.mark.parametrize("voice", ["Sadachbia", "Kore"])
def test_gemini_tts_uses_each_reviewed_voice(voice: str) -> None:
    payload = claim_payload()
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": "gemini",
        "model": "gemini-3.1-flash-tts-preview",
        "voice": voice,
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.tts, google.beta.GeminiTTS)
    assert pipeline.tts._opts.voice_name == voice


@pytest.mark.parametrize(
    ("model", "expects_instructions"),
    [
        ("gpt-4o-mini-tts", True),
        ("tts-1", False),
        ("tts-1-hd", False),
    ],
)
def test_openai_tts_omits_unsupported_instructions(
    model: str, expects_instructions: bool
) -> None:
    payload = claim_payload()
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": "openai",
        "model": model,
        "voice": "alloy",
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.tts, openai.TTS)
    assert pipeline.tts.model == model
    assert (pipeline.tts._opts.instructions is not None) is expects_instructions


@pytest.mark.parametrize(
    ("model", "voice"),
    [
        ("eleven_flash_v2_5", "EXAVITQu4vr4xnSDxMaL"),
        ("eleven_flash_v2_5", "JBFqnCBsd6RMkjVDRZzb"),
        ("eleven_multilingual_v2", "JBFqnCBsd6RMkjVDRZzb"),
    ],
)
def test_elevenlabs_tts_uses_only_reviewed_model_voice_pairs(
    model: str, voice: str
) -> None:
    payload = claim_payload()
    payload["profile"]["tts"] = {
        "source": "byok",
        "provider": "elevenlabs",
        "model": model,
        "voice": voice,
    }

    pipeline = create_pipeline(claim_for(payload))

    assert isinstance(pipeline.tts, elevenlabs.TTS)
    assert pipeline.tts.model == model
    assert pipeline.tts._opts.voice_id == voice


def test_pipeline_rechecks_catalog_for_directly_constructed_objects() -> None:
    original = managed_claim()
    unsupported = StageSelection(
        source=ModelSource.BYOK,
        provider="anthropic",
        model="not-an-stt-model",
        language="en",
    )
    profile = replace(original.profile, stt=unsupported)
    claim = ClaimedSession(
        lease_id=original.lease_id,
        profile_hash=original.profile_hash,
        profile=profile,
        credentials={StageName.STT: StageCredential(api_key="anthropic-test-key")},
    )
    with pytest.raises(PipelineConfigurationError, match="approved provider catalog"):
        create_pipeline(claim)


def test_profile_payload_does_not_accept_base_urls() -> None:
    payload = profile_payload()
    payload["llm"]["base_url"] = "https://key-thief.example"
    with pytest.raises(Exception, match="unknown fields"):
        SessionProfile.from_payload(payload)


def test_pipeline_repr_does_not_recurse_into_secret_bearing_plugins() -> None:
    payload = claim_payload()
    payload["credentials"]["llm"]["api_key"] = "sentinel-plugin-key"
    pipeline = create_pipeline(claim_for(payload))
    assert "sentinel-plugin-key" not in repr(pipeline)
