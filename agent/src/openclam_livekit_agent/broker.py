from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import time
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlsplit

import httpx

from .contract import ClaimedSession, ContractError, DispatchEnvelope

MAX_CLAIM_RESPONSE_BYTES = 64 * 1024
CLAIM_TOTAL_DEADLINE_SECONDS = 8.0
_DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


class BrokerError(RuntimeError):
    """A safe, non-secret-bearing credential broker failure."""


@dataclass(frozen=True, slots=True)
class BrokerConfiguration:
    base_url: str
    agent_token: str = field(repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "base_url", _validated_broker_origin(self.base_url))
        if len(self.agent_token) < 32:
            raise BrokerError("OPENCLAM_BROKER_AGENT_TOKEN is not configured")

    @classmethod
    def from_environment(cls) -> BrokerConfiguration:
        base_url = os.getenv("OPENCLAM_BROKER_URL", "").strip()
        agent_token = os.getenv("OPENCLAM_BROKER_AGENT_TOKEN", "").strip()
        return cls(base_url=base_url, agent_token=agent_token)


async def claim_session(
    envelope: DispatchEnvelope,
    *,
    room_name: str,
    configuration: BrokerConfiguration | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ClaimedSession:
    configuration = configuration or BrokerConfiguration.from_environment()
    path = f"/v1/credential-leases/{envelope.lease_id}/claim"
    url = urljoin(
        configuration.base_url,
        path.removeprefix("/"),
    )
    body = json.dumps(
        {
            "schema_version": 1,
            "room_name": room_name,
            "agent_name": "openclam-livekit-pilot",
            "profile_hash": envelope.profile_hash,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    timestamp = str(int(time.time()))
    nonce = _base64url(secrets.token_bytes(18))
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = f"{timestamp}\n{nonce}\nPOST\n{path}\n{body_hash}".encode()
    signature = _base64url(
        hmac.new(configuration.agent_token.encode(), canonical, hashlib.sha256).digest()
    )

    async def request_claim() -> bytes:
        async with (
            _claim_http_client(transport) as client,
            client.stream(
                "POST",
                url,
                headers={
                    "Accept": "application/json",
                    "Accept-Encoding": "identity",
                    "Content-Type": "application/json",
                    "X-OpenClam-Timestamp": timestamp,
                    "X-OpenClam-Nonce": nonce,
                    "X-OpenClam-Signature": signature,
                },
                content=body,
            ) as response,
        ):
            if response.status_code != 200:
                # Never buffer a remote error body; it may contain internal
                # diagnostics or reflected credential material.
                raise BrokerError("credential lease could not be claimed")
            return await _read_bounded_claim_response(response)

    try:
        response_body = await asyncio.wait_for(
            request_claim(), timeout=CLAIM_TOTAL_DEADLINE_SECONDS
        )
    except BrokerError:
        raise
    except (asyncio.TimeoutError, httpx.HTTPError) as exc:
        raise BrokerError("credential service is temporarily unavailable") from exc

    try:
        payload = json.loads(response_body)
        return ClaimedSession.from_payload(payload, expected=envelope)
    except (ValueError, ContractError) as exc:
        raise BrokerError("credential lease response was invalid") from exc


def _claim_http_client(
    transport: httpx.AsyncBaseTransport | None,
) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(8.0, connect=3.0),
        follow_redirects=False,
        trust_env=False,
        transport=transport,
    )


async def _read_bounded_claim_response(response: httpx.Response) -> bytes:
    content_length = response.headers.get("content-length")
    if content_length is not None:
        try:
            declared_length = int(content_length)
        except ValueError as exc:
            raise BrokerError("credential lease response was invalid") from exc
        if declared_length < 0:
            raise BrokerError("credential lease response was invalid")
        if declared_length > MAX_CLAIM_RESPONSE_BYTES:
            raise BrokerError("credential lease response is too large")

    body = bytearray()
    async for chunk in response.aiter_bytes(chunk_size=8 * 1024):
        if len(body) + len(chunk) > MAX_CLAIM_RESPONSE_BYTES:
            raise BrokerError("credential lease response is too large")
        body.extend(chunk)
    return bytes(body)


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def _valid_public_dns_host(host: str) -> bool:
    if host != host.lower() or len(host.encode("utf-8")) > 253:
        return False
    labels = host.split(".")
    if len(labels) < 2 or not all(_DNS_LABEL.fullmatch(label) for label in labels):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return True
    return False


def _validated_broker_origin(value: object) -> str:
    if not isinstance(value, str):
        raise BrokerError("OPENCLAM_BROKER_URL must be a public HTTPS origin")
    base_url = value.strip()
    try:
        parsed = urlsplit(base_url)
        port = parsed.port
    except ValueError as exc:
        raise BrokerError("OPENCLAM_BROKER_URL must be a public HTTPS origin") from exc
    host = parsed.hostname or ""
    authority = host if port is None else f"{host}:{port}"
    if not (
        parsed.scheme == "https"
        and _valid_public_dns_host(host)
        and parsed.username is None
        and parsed.password is None
        and port in (None, 443)
        and parsed.netloc == authority
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
    ):
        raise BrokerError("OPENCLAM_BROKER_URL must be a public HTTPS origin")
    return base_url.rstrip("/") + "/"
