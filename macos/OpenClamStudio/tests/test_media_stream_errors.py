"""Protected provider streaming errors retain bounded, redacted diagnostics."""
import gzip
import json
import unittest
from unittest import mock

import httpx

from server import media_gen


class _Chunks(httpx.AsyncByteStream):
    def __init__(self, chunks):
        self.chunks = chunks
        self.read_count = 0
        self.closed = False

    async def __aiter__(self):
        for chunk in self.chunks:
            self.read_count += 1
            yield chunk

    async def aclose(self):
        self.closed = True


class MediaStreamErrorTests(unittest.IsolatedAsyncioTestCase):
    async def _request(self, status, chunks, *, headers=None, limit=1024,
                       secret=""):
        stream = _Chunks(chunks)

        def respond(request):
            return httpx.Response(
                status, stream=stream, headers=headers, request=request)

        self.last_stream = stream
        async with httpx.AsyncClient(
                transport=httpx.MockTransport(respond)) as client:
            return await media_gen._bounded_media_request(
                client, "POST", "https://api.x.ai/v1/videos/generations",
                provider="xai", secret=secret, max_bytes=limit,
                json={"prompt": "offline diagnostic fixture"})

    async def test_real_streamed_400_preserves_provider_explanation(self):
        with self.assertRaisesRegex(
                RuntimeError, "invalid duration.*HTTP 400"):
            await self._request(
                400, [b'{"error":{"message":"invalid duration"}}'])
        self.assertEqual(self.last_stream.read_count, 1)
        self.assertTrue(self.last_stream.closed)

    async def test_streamed_json_diagnostics_redact_credentials_not_headers(self):
        # Fictional values deliberately do not use recognizable sk-/xai-
        # prefixes, so quoted JSON fields and the exact active secret must
        # both be protected.
        fields = {
            "message": "invalid input; echoed credential opaque-active-fixture",
            "access_token": "opaque-access-fixture",
            "refresh_token": "opaque-refresh-fixture",
            "id_token": "opaque-id-fixture",
            "api_key": "opaque-key-fixture",
            "Authorization": "Bearer opaque-authorization-fixture",
            "token": "opaque-token-fixture",
        }
        with self.assertRaises(RuntimeError) as raised:
            await self._request(
                400, [json.dumps(fields).encode()], limit=4096,
                headers={"x-provider-debug": "opaque-header-fixture"},
                secret="opaque-active-fixture")
        error = str(raised.exception)
        self.assertIn("invalid input", error)
        self.assertIn("[redacted]", error)
        self.assertNotIn("opaque-", error)
        self.assertNotIn("x-provider-debug", error)
        self.assertIn("HTTP 400", error)

    async def test_auth_error_stays_actionable_and_does_not_echo_body(self):
        with self.assertRaisesRegex(
                RuntimeError, "authentication was rejected.*HTTP 401") as raised:
            await self._request(401, [b'opaque-auth-diagnostic'])
        self.assertNotIn("opaque-auth-diagnostic", str(raised.exception))

    async def test_unbounded_chunked_error_stops_at_diagnostic_limit(self):
        cap = media_gen._MAX_PROVIDER_ERROR_BYTES
        with self.assertRaisesRegex(
                RuntimeError, "oversized error response.*HTTP 400") as raised:
            await self._request(
                400, [b'a' * cap, b'opaque-secret-prefix', b'never-read'],
                limit=4 * 1024 * 1024)
        self.assertEqual(self.last_stream.read_count, 2)
        self.assertTrue(self.last_stream.closed)
        self.assertNotIn("opaque-secret", str(raised.exception))
        self.assertLess(len(str(raised.exception)), 200)

    async def test_lane_limit_also_bounds_error_diagnostics(self):
        with self.assertRaisesRegex(RuntimeError, "oversized error response"):
            await self._request(400, [b'x' * 33, b'never-read'], limit=32)
        self.assertEqual(self.last_stream.read_count, 1)
        self.assertTrue(self.last_stream.closed)

    async def test_oversized_declared_error_closes_without_reading(self):
        with self.assertRaisesRegex(RuntimeError, "oversized error response"):
            await self._request(
                400, [b'never-read'], limit=32,
                headers={"content-length": "1000000000"})
        self.assertEqual(self.last_stream.read_count, 0)
        self.assertTrue(self.last_stream.closed)

    async def test_decompressed_error_cannot_bypass_limit(self):
        wire = gzip.compress(b'opaque-fixture-' * 1000)
        self.assertLess(len(wire), 512)
        with self.assertRaisesRegex(
                RuntimeError, "oversized error response.*HTTP 400") as raised:
            await self._request(
                400, [wire], limit=512,
                headers={"content-encoding": "gzip",
                         "content-length": str(len(wire))})
        self.assertTrue(self.last_stream.closed)
        self.assertNotIn("opaque-fixture", str(raised.exception))

    async def test_gzip_error_is_decoded_once(self):
        wire = gzip.compress(b'{"message":"unsupported image format"}')
        with self.assertRaisesRegex(
                RuntimeError, "unsupported image format.*HTTP 400"):
            await self._request(
                400, [wire], headers={"content-encoding": "gzip"})
        self.assertTrue(self.last_stream.closed)

    async def test_redirect_is_rejected_before_read_or_header_disclosure(self):
        with self.assertRaisesRegex(RuntimeError, "redirect") as raised:
            await self._request(
                302, [b'never-read'],
                headers={"location": "https://untrusted.invalid/opaque-secret"})
        self.assertEqual(self.last_stream.read_count, 0)
        self.assertTrue(self.last_stream.closed)
        self.assertNotIn("untrusted", str(raised.exception))
        self.assertNotIn("opaque-secret", str(raised.exception))

    async def test_success_preserves_decoded_json_and_response_bound(self):
        payload = {"request_id": "offline-fixture-id"}
        response = await self._request(
            200, [gzip.compress(json.dumps(payload).encode())],
            headers={"content-encoding": "gzip"})
        self.assertEqual(response.json(), payload)
        self.assertNotIn("content-encoding", response.headers)
        with self.assertRaisesRegex(RuntimeError, "oversized response"):
            await self._request(200, [b'x' * 33, b'never-read'], limit=32)
        self.assertEqual(self.last_stream.read_count, 1)
        self.assertTrue(self.last_stream.closed)

    async def test_video_submit_failure_is_labeled_without_secret(self):
        base = "https://api.x.ai/v1"
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(
                400, stream=_Chunks([b'{"error":"invalid duration"}']),
                request=request)))
        with (
                mock.patch.object(media_gen, "_base", return_value=base),
                mock.patch.object(
                    media_gen, "_xai_api_auth", new=mock.AsyncMock(
                        return_value=(base, {}, "opaque-active-fixture", "oauth2"))),
                mock.patch.object(media_gen.httpx, "AsyncClient", return_value=client),
                self.assertRaisesRegex(
                    RuntimeError, "video submission failed:.*invalid duration.*HTTP 400")):
            await media_gen._execute_xai_video_job("generations", {}, {})

    async def test_video_poll_failure_is_labeled_without_job_id_or_secret(self):
        base = "https://api.x.ai/v1"
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(
                200, json={"request_id": "private-job-fixture"}, request=request)))
        with (
                mock.patch.object(media_gen, "_base", return_value=base),
                mock.patch.object(
                    media_gen, "_xai_api_auth", new=mock.AsyncMock(
                        return_value=(base, {}, "opaque-active-fixture", "oauth2"))),
                mock.patch.object(media_gen.httpx, "AsyncClient", return_value=client),
                mock.patch.object(media_gen, "_poll", new=mock.AsyncMock(
                    side_effect=RuntimeError("Xai: job unavailable (HTTP 400)"))),
                self.assertRaisesRegex(
                    RuntimeError, "video polling failed:.*job unavailable.*HTTP 400") as raised):
            await media_gen._execute_xai_video_job("generations", {}, {})
        self.assertNotIn("private-job-fixture", str(raised.exception))
        self.assertNotIn("opaque-active-fixture", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
