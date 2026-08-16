from __future__ import annotations

import platform
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

import aiohttp
import httpx
import openai as openai_sdk
from livekit.agents import inference, llm, stt, tts
from livekit.plugins import anthropic, deepgram, elevenlabs, google, openai, xai

from .contract import (
    ClaimedSession,
    ContractError,
    ModelSource,
    StageName,
    StageSelection,
    XaiAuthMode,
    validate_catalog_selection,
)

MANAGED_LLM = "google/gemma-4-31b-it"
MANAGED_STT = "deepgram/nova-3"
MANAGED_TTS = "fishaudio/s2.1-pro"
MANAGED_TTS_VOICE = "933563129e564b19a115bedd57b7406a"
XAI_CLI_PROXY_BASE_URL = "https://cli-chat-proxy.grok.com/v1"
XAI_CLI_PROXY_MODEL = "grok-build"
XAI_CLI_TOKEN_AUTH = "xai-grok-cli"
# Audited from xai-org/grok-build revision
# eb267feff13129e568df38fb6fdf0ceb65f735d6. Production Grok Build releases
# inject GROK_VERSION at compile time; 1.0.3 is only that revision's Cargo
# fallback, while the current stable/alpha wire version is 1.0.4. The proxy
# returns HTTP 426 when this release stamp is absent or stale.
XAI_CLI_CLIENT_VERSION = "1.0.4"
XAI_CLI_CLIENT_IDENTIFIER = "grok-shell"
XAI_CLI_AUTHENTICATE_RESPONSE = "authenticate-response"
XAI_CLI_CLIENT_MODE = "headless"
XAI_API_HOST = "api.x.ai"
XAI_STT_PATH = "/v1/stt"
XAI_TTS_PATH = "/v1/tts"
MANAGED_TTS_VOICES = frozenset(
    {
        "bf322df2096a46f18c579d0baa36f41d",
        "536d3a5e000945adb7038665781a4aca",
        "9a9cf47702da476aa4629e2506d4a857",
        "79d0bd3e4e5444b18f7b6d89b5927bf1",
        "e3cd384158934cc9a01029cd7d278634",
        "933563129e564b19a115bedd57b7406a",
        "b347db033a6549378b48d00acb0d06cd",
    }
)
MANAGED_TTS_OPTIONS = {
    # Keep Fish on its balanced streaming path so first audio arrives within
    # LiveKit Inference's stall deadline. A modest sampling increase still makes
    # delivery contrast more audible without pushing the voice into unstable or
    # theatrical output.
    "latency": "balanced",
    "temperature": 0.85,
}

GEMINI_TTS_INSTRUCTIONS = (
    "Synthesize only the quoted transcript. Perform it as a warm, emotionally "
    "perceptive one-to-one conversation, not narration. Let meaning drive clearly "
    "audible changes in warmth, energy, pace, pitch, pauses, and emphasis. Preserve "
    "every spoken word exactly; do not read these directions aloud or become "
    "theatrical."
)

EXPRESSIVE_OPTIONS = {
    "speech_steering": {
        "disfluencies": True,
        "nonverbal_sounds": True,
        "pace": "normal",
    },
    "tts_instructions_append": (
        "Make emotional contrast clearly audible while staying like a natural "
        "one-to-one conversation. Follow the Fish guide's one emotion marker at "
        "the start of every spoken sentence: choose a specific label that fits "
        "its meaning, repeat it while the feeling holds, and switch it when the "
        "feeling shifts. Use emphasis or a deliberate mid-sentence pause on the "
        "key beat of emotionally meaningful replies. Keep tone wrappers and "
        "non-verbal sounds sparse; never add written stage directions, read "
        "marker names aloud, become melodramatic, or laugh at neutral or serious "
        "content."
    ),
}


class PipelineConfigurationError(RuntimeError):
    pass


class _XaiOAuthLLM(openai.LLM):
    """Chat Completions LLM that owns its pinned xAI OAuth SDK client."""

    def __init__(
        self,
        *,
        client: openai_sdk.AsyncOpenAI,
    ) -> None:
        super().__init__(
            model=XAI_CLI_PROXY_MODEL,
            client=client,
            max_completion_tokens=700,
        )
        self._openclam_oauth_client = client
        self._openclam_oauth_client_closed = False

    async def aclose(self) -> None:
        try:
            await super().aclose()
        finally:
            if not self._openclam_oauth_client_closed:
                self._openclam_oauth_client_closed = True
                await self._openclam_oauth_client.close()


async def _reject_xai_speech_redirect(
    _session: aiohttp.ClientSession,
    _trace_config_ctx: object,
    params: aiohttp.TraceRequestRedirectParams,
) -> None:
    params.response.close()
    raise aiohttp.ClientConnectionError("xAI speech redirect rejected")


class _HardenedXaiSpeechSession:
    """Lazy, origin-pinned aiohttp session for the xAI speech plugins."""

    def __init__(self, expected_path: str) -> None:
        if expected_path not in {XAI_STT_PATH, XAI_TTS_PATH}:
            raise ValueError("invalid xAI speech path")
        self.expected_path = expected_path
        self._client: aiohttp.ClientSession | None = None
        self._closed = False

    @property
    def closed(self) -> bool:
        return self._closed or (self._client is not None and self._client.closed)

    def _ensure_client(self) -> aiohttp.ClientSession:
        if self._closed:
            raise RuntimeError("xAI speech session is closed")
        if self._client is None:
            trace = aiohttp.TraceConfig()
            trace.on_request_redirect.append(_reject_xai_speech_redirect)
            self._client = aiohttp.ClientSession(
                trust_env=False,
                cookie_jar=aiohttp.DummyCookieJar(),
                trace_configs=[trace],
                timeout=aiohttp.ClientTimeout(
                    total=None,
                    connect=15.0,
                    sock_connect=15.0,
                ),
            )
        return self._client

    async def ws_connect(self, url: object, **kwargs: Any) -> object:
        try:
            parsed = urlsplit(str(url))
            port = parsed.port
        except ValueError as exc:
            raise PipelineConfigurationError("invalid xAI speech endpoint") from exc
        if not (
            parsed.scheme == "wss"
            and parsed.hostname == XAI_API_HOST
            and parsed.username is None
            and parsed.password is None
            and port in (None, 443)
            and parsed.path == self.expected_path
            and not parsed.fragment
        ):
            raise PipelineConfigurationError("invalid xAI speech endpoint")
        if kwargs.get("proxy") is not None or kwargs.get("proxy_auth") is not None:
            raise PipelineConfigurationError("xAI speech proxies are disabled")
        kwargs["proxy"] = None
        return await self._ensure_client().ws_connect(url, **kwargs)

    async def close(self) -> None:
        self._closed = True
        if self._client is not None and not self._client.closed:
            await self._client.close()


class _OwnedXaiSTT(xai.STT):
    def __init__(
        self,
        *,
        speech_session: _HardenedXaiSpeechSession,
        **kwargs: Any,
    ) -> None:
        self._openclam_speech_session = speech_session
        super().__init__(http_session=speech_session, **kwargs)

    async def aclose(self) -> None:
        try:
            await super().aclose()
        finally:
            await self._openclam_speech_session.close()


class _OwnedXaiTTS(xai.TTS):
    def __init__(
        self,
        *,
        speech_session: _HardenedXaiSpeechSession,
        **kwargs: Any,
    ) -> None:
        self._openclam_speech_session = speech_session
        super().__init__(http_session=speech_session, **kwargs)

    async def aclose(self) -> None:
        try:
            await super().aclose()
        finally:
            await self._openclam_speech_session.close()


@dataclass(frozen=True, slots=True)
class Pipeline:
    llm: llm.LLM = field(repr=False)
    stt: stt.STT = field(repr=False)
    tts: tts.TTS = field(repr=False)
    expressive: bool | dict[str, Any]
    private_expressive_markup_enabled: bool


def create_pipeline(claim: ClaimedSession) -> Pipeline:
    try:
        # Payload parsing enforces this first. Repeat it for callers that build
        # frozen contract objects directly in-process.
        claim.validate_xai_auth_contract()
    except ContractError as exc:
        raise PipelineConfigurationError(str(exc)) from exc
    language_model = _build_llm(claim.profile.llm, claim)
    recognizer = _build_stt(claim.profile.stt, claim)
    speech = _build_tts(claim.profile.tts, claim)
    # Agents 1.6.x translates expressive markup only for supported Inference TTS.
    expressive: bool | dict[str, Any] = (
        EXPRESSIVE_OPTIONS if isinstance(speech, inference.TTS) else False
    )
    private_expressive_markup_enabled = (
        claim.profile.tts.source is ModelSource.MANAGED
        and isinstance(speech, inference.TTS)
        and bool(expressive)
    )
    return Pipeline(
        llm=language_model,
        stt=recognizer,
        tts=speech,
        expressive=expressive,
        private_expressive_markup_enabled=private_expressive_markup_enabled,
    )


def _build_llm(selection: StageSelection, claim: ClaimedSession) -> llm.LLM:
    _require_catalog_selection(StageName.LLM, selection)
    if selection.source is ModelSource.MANAGED:
        _require_managed(selection, model=MANAGED_LLM)
        return inference.LLM(model=selection.model)
    key = claim.key_for(StageName.LLM)
    if selection.provider == "openai":
        return openai.responses.LLM(
            model=selection.model,
            api_key=key,
            store=False,
            # Agents 1.6.9 predates the GPT-5.6 model literals, so its automatic
            # reasoning configuration does not recognize these reviewed IDs.
            # Set the low-latency voice-chat behavior explicitly for every
            # approved OpenAI model instead of relying on that stale table.
            reasoning={"effort": "none"},
            max_output_tokens=700,
        )
    if selection.provider == "xai":
        if claim.xai_auth_mode_for(StageName.LLM) is XaiAuthMode.OAUTH2:
            return _build_xai_oauth_llm(selection, key)
        return xai.responses.LLM(
            model=selection.model,
            api_key=key,
            # Grok 4.5 documents low/medium/high reasoning. The retained 4.3
            # tuple already uses and has been tested with reasoning disabled.
            reasoning={"effort": "low" if selection.model == "grok-4.5" else "none"},
            max_output_tokens=700,
        )
    if selection.provider == "gemini":
        return google.LLM(
            model=selection.model,
            api_key=key,
            max_output_tokens=700,
        )
    if selection.provider == "anthropic":
        return anthropic.LLM(
            model=selection.model,
            api_key=key,
            max_tokens=700,
        )
    raise AssertionError("unreachable LLM provider")


def _build_stt(selection: StageSelection, claim: ClaimedSession) -> stt.STT:
    _require_catalog_selection(StageName.STT, selection)
    if selection.source is ModelSource.MANAGED:
        _require_managed(selection, model=MANAGED_STT)
        return inference.STT(
            model=selection.model,
            language=selection.language or "multi",
        )
    key = claim.key_for(StageName.STT)
    language = selection.language or "en"
    if selection.provider == "openai":
        return openai.STT(
            model=selection.model,
            api_key=key,
            language=language,
            use_realtime=False,
        )
    if selection.provider == "xai":
        # Both explicit modes use xAI's direct speech API with bearer
        # authorization; only the OAuth LLM transport differs.
        claim.xai_auth_mode_for(StageName.STT)
        return _OwnedXaiSTT(
            speech_session=_HardenedXaiSpeechSession(XAI_STT_PATH),
            api_key=key,
            language=language,
            enable_interim_results=True,
        )
    if selection.provider == "deepgram":
        return deepgram.STT(
            model=selection.model,
            api_key=key,
            language=language,
            interim_results=True,
            mip_opt_out=True,
        )
    if selection.provider == "elevenlabs":
        return elevenlabs.STT(
            model=selection.model,
            api_key=key,
            # `multi` means provider-side automatic language detection. The
            # ElevenLabs API represents that by omitting the language code.
            language_code=None if language == "multi" else language,
            enable_logging=False,
        )
    raise AssertionError("unreachable STT provider")


def _build_tts(selection: StageSelection, claim: ClaimedSession) -> tts.TTS:
    _require_catalog_selection(StageName.TTS, selection)
    if selection.source is ModelSource.MANAGED:
        _require_managed(selection, model=MANAGED_TTS)
        voice = selection.voice or MANAGED_TTS_VOICE
        if voice not in MANAGED_TTS_VOICES:
            raise PipelineConfigurationError("invalid LiveKit-managed voice profile")
        return inference.TTS(
            model=selection.model,
            voice=voice,
            language=selection.language or "en",
            extra_kwargs=MANAGED_TTS_OPTIONS,
        )
    key = claim.key_for(StageName.TTS)
    voice = selection.voice
    if not voice:
        raise PipelineConfigurationError("selected BYOK voice is missing")
    if selection.provider == "openai":
        if selection.model != "gpt-4o-mini-tts":
            # tts-1 and tts-1-hd do not support prompt-based delivery
            # instructions; omitting the argument also omits it on the wire.
            return openai.TTS(
                model=selection.model,
                voice=voice,
                api_key=key,
            )
        return openai.TTS(
            model=selection.model,
            voice=voice,
            api_key=key,
            instructions=(
                "Speak warmly and conversationally with natural emotional variation."
            ),
        )
    if selection.provider == "xai":
        claim.xai_auth_mode_for(StageName.TTS)
        return _OwnedXaiTTS(
            speech_session=_HardenedXaiSpeechSession(XAI_TTS_PATH),
            voice=voice,
            language=selection.language or "auto",
            api_key=key,
            optimize_streaming_latency=1,
        )
    if selection.provider == "gemini":
        return google.beta.GeminiTTS(
            model=selection.model,
            voice_name=voice,
            api_key=key,
            instructions=GEMINI_TTS_INSTRUCTIONS,
        )
    if selection.provider == "deepgram":
        # Deepgram encodes the voice in the Aura model identifier.
        if voice != selection.model:
            raise PipelineConfigurationError("Deepgram voice must match its model")
        return deepgram.TTS(model=selection.model, api_key=key, mip_opt_out=True)
    if selection.provider == "elevenlabs":
        return elevenlabs.TTS(
            model=selection.model,
            voice_id=voice,
            api_key=key,
            enable_logging=False,
        )
    raise AssertionError("unreachable TTS provider")


def _build_xai_oauth_llm(
    selection: StageSelection,
    bearer_token: str,
) -> llm.LLM:
    # This origin and public Grok CLI contract are fixed by the signed agent;
    # no lease/profile value can alter the destination. Redirects and ambient
    # proxy environment variables are deliberately disabled for bearer safety.
    http_client = _new_xai_oauth_http_client()
    client = openai_sdk.AsyncOpenAI(
        api_key=bearer_token,
        base_url=XAI_CLI_PROXY_BASE_URL,
        max_retries=0,
        http_client=http_client,
        default_headers={
            "Accept": "text/event-stream",
            "User-Agent": _xai_cli_user_agent(),
            "X-XAI-Token-Auth": XAI_CLI_TOKEN_AUTH,
            "x-authenticateresponse": XAI_CLI_AUTHENTICATE_RESPONSE,
            "x-grok-client-identifier": XAI_CLI_CLIENT_IDENTIFIER,
            "x-grok-client-mode": XAI_CLI_CLIENT_MODE,
            "x-grok-client-version": XAI_CLI_CLIENT_VERSION,
            "x-grok-model-override": selection.model,
        },
    )
    return _XaiOAuthLLM(client=client)


def _xai_cli_user_agent() -> str:
    system = platform.system().lower()
    os_name = {
        "darwin": "macos",
        "windows": "windows",
    }.get(system, system or "unknown")
    machine = platform.machine().lower()
    arch = {
        "arm64": "aarch64",
        "aarch64": "aarch64",
        "amd64": "x86_64",
        "x86_64": "x86_64",
    }.get(machine, machine or "unknown")
    return f"grok-shell/{XAI_CLI_CLIENT_VERSION} ({os_name}; {arch})"


def _new_xai_oauth_http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(connect=15.0, read=30.0, write=15.0, pool=5.0),
        follow_redirects=False,
        trust_env=False,
        limits=httpx.Limits(
            max_connections=20,
            max_keepalive_connections=20,
            keepalive_expiry=120,
        ),
    )


def _require_catalog_selection(stage: StageName, selection: StageSelection) -> None:
    try:
        validate_catalog_selection(stage, selection)
    except ContractError as exc:
        raise PipelineConfigurationError(str(exc)) from exc


def _require_managed(
    selection: StageSelection,
    *,
    model: str,
) -> None:
    if selection.provider != "livekit" or selection.model != model:
        raise PipelineConfigurationError("invalid LiveKit-managed model profile")
    try:
        # Defensive assertion for callers constructing objects outside parsing.
        if selection.source is not ModelSource.MANAGED:
            raise ContractError("managed profile source mismatch")
    except ContractError as exc:
        raise PipelineConfigurationError(str(exc)) from exc
