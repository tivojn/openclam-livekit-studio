import asyncio
import base64
import hashlib
import hmac
import json

import httpx
import pytest
from test_contract import claim_payload, envelope_for

from openclam_livekit_agent import broker as broker_module
from openclam_livekit_agent.broker import (
    MAX_CLAIM_RESPONSE_BYTES,
    BrokerConfiguration,
    BrokerError,
    _claim_http_client,
    _read_bounded_claim_response,
    claim_session,
)
from openclam_livekit_agent.contract import DispatchEnvelope


@pytest.mark.asyncio
async def test_claim_uses_agent_auth_and_does_not_put_keys_in_request() -> None:
    envelope = envelope_for()

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == f"/v1/credential-leases/{envelope.lease_id}/claim"
        timestamp = request.headers["x-openclam-timestamp"]
        nonce = request.headers["x-openclam-nonce"]
        signature = request.headers["x-openclam-signature"]
        body = json.loads(request.content)
        assert body == {
            "schema_version": 1,
            "room_name": "openclam-lk-test",
            "agent_name": "openclam-livekit-pilot",
            "profile_hash": envelope.profile_hash,
        }
        assert "key" not in request.content.decode().lower()
        body_hash = hashlib.sha256(request.content).hexdigest()
        canonical = (
            f"{timestamp}\n{nonce}\nPOST\n{request.url.path}\n{body_hash}".encode()
        )
        expected_signature = (
            base64.urlsafe_b64encode(
                hmac.new(("z" * 40).encode(), canonical, hashlib.sha256).digest()
            )
            .decode()
            .rstrip("=")
        )
        assert hmac.compare_digest(signature, expected_signature)
        return httpx.Response(200, json=claim_payload())

    claim = await claim_session(
        envelope,
        room_name="openclam-lk-test",
        configuration=BrokerConfiguration(
            base_url="https://broker.example/", agent_token="z" * 40
        ),
        transport=httpx.MockTransport(handler),
    )
    assert claim.lease_id == envelope.lease_id


@pytest.mark.asyncio
async def test_claim_discards_remote_error_body() -> None:
    envelope = envelope_for()
    secret = "provider-secret-that-must-not-surface"
    body_was_read = False

    class SecretErrorStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            nonlocal body_was_read
            body_was_read = True
            yield secret.encode()

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(500, stream=SecretErrorStream())

    with pytest.raises(BrokerError) as error:
        await claim_session(
            envelope,
            room_name="openclam-lk-test",
            configuration=BrokerConfiguration(
                base_url="https://broker.example/", agent_token="z" * 40
            ),
            transport=httpx.MockTransport(handler),
        )
    assert secret not in str(error.value)
    assert body_was_read is False


@pytest.mark.asyncio
async def test_claim_client_disables_redirects_and_environment_proxies() -> None:
    client = _claim_http_client(httpx.MockTransport(lambda _: httpx.Response(200)))
    try:
        assert client.follow_redirects is False
        assert client._trust_env is False
    finally:
        await client.aclose()


@pytest.mark.asyncio
async def test_claim_streaming_cap_rejects_overflow_before_buffering() -> None:
    envelope = envelope_for()
    chunks_read = 0

    class OverflowStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            nonlocal chunks_read
            for chunk in (b"x" * 32_768, b"y" * 32_768, b"z"):
                chunks_read += 1
                yield chunk

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, stream=OverflowStream())

    with pytest.raises(BrokerError, match="too large"):
        await claim_session(
            envelope,
            room_name="openclam-lk-test",
            configuration=BrokerConfiguration(
                base_url="https://broker.example/", agent_token="z" * 40
            ),
            transport=httpx.MockTransport(handler),
        )
    assert chunks_read == 3


@pytest.mark.asyncio
async def test_claim_streaming_cap_accepts_exactly_sixty_four_kibibytes() -> None:
    response = httpx.Response(
        200,
        content=b"x" * MAX_CLAIM_RESPONSE_BYTES,
    )

    body = await _read_bounded_claim_response(response)

    assert len(body) == MAX_CLAIM_RESPONSE_BYTES


@pytest.mark.asyncio
async def test_claim_rejects_oversized_content_length_without_reading_body() -> None:
    envelope = envelope_for()
    body_was_read = False

    class MustNotReadStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            nonlocal body_was_read
            body_was_read = True
            yield b"must-not-be-read"

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"Content-Length": str(MAX_CLAIM_RESPONSE_BYTES + 1)},
            stream=MustNotReadStream(),
        )

    with pytest.raises(BrokerError, match="too large"):
        await claim_session(
            envelope,
            room_name="openclam-lk-test",
            configuration=BrokerConfiguration(
                base_url="https://broker.example/", agent_token="z" * 40
            ),
            transport=httpx.MockTransport(handler),
        )
    assert body_was_read is False


@pytest.mark.asyncio
async def test_claim_total_deadline_stops_a_drip_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    envelope = envelope_for()

    class DripStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            await asyncio.sleep(0.1)
            yield b"{}"

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, stream=DripStream())

    monkeypatch.setattr(broker_module, "CLAIM_TOTAL_DEADLINE_SECONDS", 0.01)
    with pytest.raises(BrokerError, match="temporarily unavailable"):
        await claim_session(
            envelope,
            room_name="openclam-lk-test",
            configuration=BrokerConfiguration(
                base_url="https://broker.example/", agent_token="z" * 40
            ),
            transport=httpx.MockTransport(handler),
        )


@pytest.mark.parametrize(
    "url",
    [
        "http://broker.example",
        "https://user@broker.example",
        "https://:password@broker.example",
        "https://broker.example?secret=bad",
        "https://broker.example/path",
        "https://broker.example:444",
        "https://BROKER.example",
        "https://127.0.0.1",
        "https://localhost",
    ],
)
def test_environment_rejects_non_public_or_credential_bearing_url(
    monkeypatch: pytest.MonkeyPatch, url: str
) -> None:
    monkeypatch.setenv("OPENCLAM_BROKER_URL", url)
    monkeypatch.setenv("OPENCLAM_BROKER_AGENT_TOKEN", "z" * 40)
    with pytest.raises(BrokerError):
        BrokerConfiguration.from_environment()


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("https://broker.example", "https://broker.example/"),
        ("https://broker.example/", "https://broker.example/"),
        ("https://broker.example:443", "https://broker.example:443/"),
    ],
)
def test_environment_accepts_only_an_exact_https_deployment_origin(
    monkeypatch: pytest.MonkeyPatch,
    url: str,
    expected: str,
) -> None:
    monkeypatch.setenv("OPENCLAM_BROKER_URL", url)
    monkeypatch.setenv("OPENCLAM_BROKER_AGENT_TOKEN", "z" * 40)

    assert BrokerConfiguration.from_environment().base_url == expected


def test_direct_broker_configuration_cannot_bypass_origin_validation() -> None:
    with pytest.raises(BrokerError, match="public HTTPS origin"):
        BrokerConfiguration(
            base_url="https://attacker.example/capture",
            agent_token="z" * 40,
        )


def test_envelope_type_is_opaque() -> None:
    envelope = DispatchEnvelope(lease_id="b" * 32, profile_hash="c" * 64)
    assert "api" not in repr(envelope).lower()


def test_broker_configuration_repr_hides_agent_auth_secret() -> None:
    secret = "sentinel-agent-auth-secret-123456789"
    configuration = BrokerConfiguration(
        base_url="https://broker.example/",
        agent_token=secret,
    )
    assert secret not in repr(configuration)
