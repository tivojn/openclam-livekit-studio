import asyncio
import importlib.util
import json
import os
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs

import httpx
import fastapi.dependencies.utils as fastapi_dependency_utils


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import credentials
import xai_oauth as XO


ACCESS = "access-" + "a" * 48
REFRESH = "refresh-" + "r" * 48
ROTATED_ACCESS = "access-" + "b" * 48
ROTATED_REFRESH = "refresh-" + "s" * 48


def response(request, status=200, body=None, headers=None):
    return httpx.Response(
        status,
        json=body,
        headers=headers,
        request=request,
    )


class XaiOAuthTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_vault = credentials._TEST_VAULT_FILE
        self.original_client_id = XO._TEST_CLIENT_ID
        XO._TEST_CLIENT_ID = "openclam-oauth-test-client"
        credentials._TEST_VAULT_FILE = os.path.join(
            self.temporary.name, "vault.json"
        )
        credentials._memo.clear()
        XO._reset_for_tests()
        XO._TEST_TRANSPORT = None
        self.now = 2_000_000_000.0
        XO._TEST_CLOCK = lambda: self.now

    def tearDown(self):
        XO._TEST_TRANSPORT = None
        XO._TEST_CLOCK = None
        XO._reset_for_tests()
        credentials._memo.clear()
        credentials._TEST_VAULT_FILE = self.original_vault
        XO._TEST_CLIENT_ID = self.original_client_id
        self.temporary.cleanup()

    def store_oauth(self, *, expires_in=1, refresh_token=REFRESH):
        XO._store_credential(XO._OAuthCredential(
            access_token=ACCESS,
            refresh_token=refresh_token,
            expires_at=self.now + expires_in,
            token_type="Bearer",
            scope=" ".join(XO.SCOPES),
            client_id=XO.client_id(),
        ))
        XO.set_auth_mode(XO.OAUTH2_MODE)

    async def test_explicit_mode_never_infers_or_falls_back(self):
        credentials.put(XO.API_KEY_ACCOUNT, "xai-" + "k" * 48)
        XO.set_auth_mode(XO.OAUTH2_MODE)
        with self.assertRaisesRegex(
            XO.XaiOAuthNotConnected, "xai_oauth_not_connected"
        ):
            await XO.resolve_auth()

        selected = XO.set_auth_mode(XO.API_KEY_MODE)
        resolved = await XO.resolve_auth()
        self.assertEqual(resolved.mode, XO.API_KEY_MODE)
        self.assertNotIn("xai-", repr(resolved))
        self.assertEqual(
            resolved.headers(XO.API_TARGET)["Authorization"],
            "Bearer " + "xai-" + "k" * 48,
        )
        with self.assertRaisesRegex(XO.XaiOAuthError, "xai_auth_target_invalid"):
            resolved.headers(XO.CLI_PROXY_TARGET)
        self.assertTrue(selected["connected"])

    async def test_cli_proxy_headers_pin_the_released_grok_build_contract(self):
        self.store_oauth(expires_in=3600)
        resolved = await XO.resolve_auth()
        headers = resolved.headers(XO.CLI_PROXY_TARGET, model="grok-4.6")
        self.assertEqual(headers["X-XAI-Token-Auth"], "xai-grok-cli")
        self.assertEqual(headers["x-grok-model-override"], "grok-4.6")
        self.assertEqual(headers["x-grok-client-version"], "1.0.4")
        self.assertEqual(headers["x-grok-client-identifier"], "grok-shell")
        self.assertEqual(
            headers["x-authenticateresponse"], "authenticate-response"
        )
        self.assertEqual(headers["x-grok-client-mode"], "interactive")
        self.assertEqual(
            headers["User-Agent"], "grok-shell/1.0.4 (macos; aarch64)"
        )
        api_headers = resolved.headers(XO.API_TARGET)
        for proxy_header in (
            "X-XAI-Token-Auth",
            "x-grok-client-version",
            "x-grok-client-identifier",
            "x-authenticateresponse",
            "x-grok-client-mode",
            "User-Agent",
        ):
            self.assertNotIn(proxy_header, api_headers)

    async def test_device_start_is_pinned_and_keeps_device_code_server_side(self):
        captured = []

        def handler(request):
            captured.append(request)
            return response(request, body={
                "device_code": "device-secret-" + "d" * 32,
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://accounts.x.ai/activate",
                "verification_uri_complete": (
                    "https://accounts.x.ai/activate?user_code=ABCD-EFGH"
                ),
                "expires_in": 900,
                "interval": 5,
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        result = await XO.start_device_login()
        request = captured[0]
        form = parse_qs(request.content.decode())

        self.assertEqual(str(request.url), XO.DEVICE_AUTHORIZATION_ENDPOINT)
        self.assertEqual(form["client_id"], ["openclam-oauth-test-client"])
        self.assertEqual(form["scope"], [
            "openid profile email offline_access grok-cli:access api:access "
            "conversations:read conversations:write "
            "workspaces:read workspaces:write"
        ])
        self.assertNotIn("referrer", form)
        serialized = json.dumps(result)
        self.assertNotIn("device-secret", serialized)
        self.assertNotIn("device_code", serialized)
        self.assertEqual(result["state"], "pending")
        self.assertEqual(len(XO._pending_flows), 1)

    async def test_production_uses_pinned_grok_build_compatibility_identity(self):
        with mock.patch.object(XO, "_TEST_CLIENT_ID", None), mock.patch.dict(
            os.environ,
            {
                "OPENCLAM_XAI_OAUTH_CLIENT_ID": "environment-must-not-win",
                "GROK_OAUTH2_CLIENT_ID": "grok-environment-must-not-win",
            },
            clear=False,
        ):
            self.assertEqual(
                XO.client_id(),
                "b1a00492-073a-47ea-816f-4c329264a828",
            )
            self.assertEqual(
                XO.GROK_BUILD_COMPAT_SOURCE_REVISION,
                "eb267feff13129e568df38fb6fdf0ceb65f735d6",
            )
            self.assertEqual(XO.GROK_BUILD_COMPAT_CLIENT_VERSION, "1.0.4")
            self.assertEqual(XO.SCOPES, (
                "openid", "profile", "email", "offline_access",
                "grok-cli:access", "api:access", "conversations:read",
                "conversations:write", "workspaces:read", "workspaces:write",
            ))
            current = XO.status()
            self.assertEqual(current["auth_mode"], XO.API_KEY_MODE)
            self.assertTrue(current["oauth"]["available"])
            self.assertFalse(current["connected"])
            selected = XO.set_auth_mode(XO.OAUTH2_MODE)
            self.assertEqual(selected["auth_mode"], XO.OAUTH2_MODE)
            self.assertFalse(selected["connected"])
        source = Path(XO.__file__).read_text()
        self.assertNotIn("OPENCLAM_XAI_OAUTH_CLIENT_ID", source)
        self.assertNotIn("GROK_OAUTH2_CLIENT_ID", source)
        self.assertNotIn('"referrer": "grok-build"', Path(XO.__file__).read_text())

    async def test_poll_success_persists_one_atomic_oauth_record_without_exposure(self):
        calls = []

        def handler(request):
            calls.append(request)
            if request.url.path.endswith("/device/code"):
                return response(request, body={
                    "device_code": "device-" + "d" * 32,
                    "user_code": "FISH-VOICE",
                    "verification_uri": "https://auth.x.ai/device",
                    "expires_in": 600,
                    "interval": 3,
                })
            return response(request, body={
                "access_token": ACCESS,
                "refresh_token": REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": " ".join(XO.SCOPES),
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        started = await XO.start_device_login()
        self.now += 3
        connected = await XO.poll_device_login(started["flow_id"])

        self.assertTrue(connected["connected"])
        self.assertEqual(connected["auth_mode"], XO.OAUTH2_MODE)
        safe = json.dumps(connected)
        self.assertNotIn(ACCESS, safe)
        self.assertNotIn(REFRESH, safe)

        with open(credentials._TEST_VAULT_FILE) as handle:
            vault = json.load(handle)
        self.assertEqual(
            set(vault), {XO.OAUTH_CREDENTIAL_ACCOUNT, XO.AUTH_MODE_ACCOUNT}
        )
        record = json.loads(vault[XO.OAUTH_CREDENTIAL_ACCOUNT])
        self.assertEqual(record["access_token"], ACCESS)
        self.assertEqual(record["refresh_token"], REFRESH)
        self.assertEqual(len(calls), 2)

    async def test_poll_throttles_locally_and_honours_slow_down(self):
        token_calls = 0

        def handler(request):
            nonlocal token_calls
            if request.url.path.endswith("/device/code"):
                return response(request, body={
                    "device_code": "device-" + "d" * 32,
                    "user_code": "ABCD-EFGH",
                    "verification_uri": "https://auth.x.ai/device",
                    "expires_in": 600,
                    "interval": 5,
                })
            token_calls += 1
            return response(request, 400, {"error": "slow_down"})

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        started = await XO.start_device_login()
        early = await XO.poll_device_login(started["flow_id"])
        self.assertEqual(early, {"state": "pending", "retry_after": 5})
        self.assertEqual(token_calls, 0)

        self.now += 5
        slowed = await XO.poll_device_login(started["flow_id"])
        self.assertEqual(slowed, {"state": "pending", "retry_after": 10})
        self.assertEqual(token_calls, 1)
        again = await XO.poll_device_login(started["flow_id"])
        self.assertEqual(again, {"state": "pending", "retry_after": 10})
        self.assertEqual(token_calls, 1)

    async def test_mode_switch_invalidates_an_in_flight_device_exchange(self):
        poll_entered = asyncio.Event()
        release_poll = asyncio.Event()

        async def handler(request):
            if request.url.path.endswith("/device/code"):
                return response(request, body={
                    "device_code": "device-" + "d" * 32,
                    "user_code": "ABCD-EFGH",
                    "verification_uri": "https://auth.x.ai/device",
                    "expires_in": 600,
                    "interval": 1,
                })
            poll_entered.set()
            await release_poll.wait()
            return response(request, body={
                "access_token": ACCESS,
                "refresh_token": REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        started = await XO.start_device_login()
        self.now += 1
        poll = asyncio.create_task(XO.poll_device_login(started["flow_id"]))
        await poll_entered.wait()

        credentials.put(XO.API_KEY_ACCOUNT, "xai-" + "k" * 48)
        switched = XO.set_auth_mode(XO.API_KEY_MODE)
        self.assertEqual(switched["auth_mode"], XO.API_KEY_MODE)
        release_poll.set()
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_flow_not_found"
        ):
            await poll
        self.assertEqual(XO.auth_mode(), XO.API_KEY_MODE)
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")

    async def test_start_snapshot_rejects_late_response_after_newer_decision(self):
        for decision in ("mode", "logout", "cancel"):
            with self.subTest(decision=decision):
                XO._reset_for_tests()
                XO.set_auth_mode(XO.OAUTH2_MODE)
                entered = asyncio.Event()
                release = asyncio.Event()

                async def handler(request):
                    entered.set()
                    await release.wait()
                    return response(request, body={
                        "device_code": "device-" + "d" * 32,
                        "user_code": "ABCD-EFGH",
                        "verification_uri": "https://auth.x.ai/device",
                        "expires_in": 600,
                        "interval": 1,
                    })

                XO._TEST_TRANSPORT = httpx.MockTransport(handler)
                started = asyncio.create_task(XO.start_device_login())
                await entered.wait()
                if decision == "mode":
                    XO.set_auth_mode(XO.API_KEY_MODE)
                elif decision == "logout":
                    await XO.logout()
                else:
                    cancelled = XO.cancel_device_login()
                    self.assertTrue(cancelled["device_flow_cancelled"])
                release.set()

                with self.assertRaisesRegex(
                    XO.XaiOAuthError, "xai_oauth_flow_not_found"
                ):
                    await started
                self.assertEqual(XO._pending_flows, {})

    async def test_concurrent_device_starts_cannot_replace_the_winning_flow(self):
        entered = [asyncio.Event(), asyncio.Event()]
        release = [asyncio.Event(), asyncio.Event()]
        calls = 0

        async def handler(request):
            nonlocal calls
            index = calls
            calls += 1
            entered[index].set()
            await release[index].wait()
            return response(request, body={
                "device_code": f"device-{index}-" + "d" * 32,
                "user_code": f"ABCD-EFG{index}",
                "verification_uri": "https://auth.x.ai/device",
                "expires_in": 600,
                "interval": 1,
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        first = asyncio.create_task(XO.start_device_login())
        await entered[0].wait()
        second = asyncio.create_task(XO.start_device_login())
        await entered[1].wait()
        release[0].set()
        winning = await first
        release[1].set()
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_flow_not_found"
        ):
            await second
        self.assertEqual(set(XO._pending_flows), {winning["flow_id"]})

    async def test_cancel_invalidates_an_in_flight_poll_without_storing_tokens(self):
        poll_entered = asyncio.Event()
        release_poll = asyncio.Event()

        async def handler(request):
            if request.url.path.endswith("/device/code"):
                return response(request, body={
                    "device_code": "device-" + "d" * 32,
                    "user_code": "ABCD-EFGH",
                    "verification_uri": "https://auth.x.ai/device",
                    "expires_in": 600,
                    "interval": 1,
                })
            poll_entered.set()
            await release_poll.wait()
            return response(request, body={
                "access_token": ACCESS,
                "refresh_token": REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO.set_auth_mode(XO.OAUTH2_MODE)
        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        started = await XO.start_device_login()
        self.now += 1
        poll = asyncio.create_task(XO.poll_device_login(started["flow_id"]))
        await poll_entered.wait()
        cancelled = XO.cancel_device_login()
        self.assertTrue(cancelled["device_flow_cancelled"])
        release_poll.set()
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_flow_not_found"
        ):
            await poll
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")

    async def test_device_cancel_does_not_interrupt_existing_session_refresh(self):
        self.store_oauth()
        refresh_entered = asyncio.Event()
        release_refresh = asyncio.Event()

        async def handler(request):
            refresh_entered.set()
            await release_refresh.wait()
            return response(request, body={
                "access_token": ROTATED_ACCESS,
                "refresh_token": ROTATED_REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        refresh = asyncio.create_task(XO.get_access_token())
        await refresh_entered.wait()
        XO.cancel_device_login()
        release_refresh.set()
        self.assertEqual(await refresh, ROTATED_ACCESS)

    async def test_redirect_is_rejected_without_forwarding_the_form(self):
        requests = []

        def handler(request):
            requests.append(request)
            return httpx.Response(
                302,
                headers={"Location": "https://attacker.example/collect"},
                request=request,
            )

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_protocol_error"
        ):
            await XO.start_device_login()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].url.host, "auth.x.ai")

    async def test_auth_response_is_stream_bounded(self):
        def handler(request):
            return httpx.Response(
                200,
                content=b"x" * (XO.MAX_RESPONSE_BYTES + 1),
                request=request,
            )

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_protocol_error"
        ):
            await XO.start_device_login()

    async def test_token_response_must_include_server_granted_lifetime(self):
        def handler(request):
            if request.url.path.endswith("/device/code"):
                return response(request, body={
                    "device_code": "device-" + "d" * 32,
                    "user_code": "ABCD-EFGH",
                    "verification_uri": "https://auth.x.ai/device",
                    "expires_in": 600,
                    "interval": 1,
                })
            return response(request, body={
                "access_token": ACCESS,
                "refresh_token": REFRESH,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        started = await XO.start_device_login()
        self.now += 1
        with self.assertRaisesRegex(
            XO.XaiOAuthError, "xai_oauth_protocol_error"
        ):
            await XO.poll_device_login(started["flow_id"])
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")

    async def test_bearers_with_whitespace_and_malformed_flow_ids_are_rejected(self):
        for invalid in ("xai key", "xai\tkey", "xai\nkey", "xai\u2003key"):
            credentials.put(XO.API_KEY_ACCOUNT, invalid)
            XO.set_auth_mode(XO.API_KEY_MODE)
            self.assertTrue(XO.status()["has_api_key"])
            self.assertFalse(XO.status()["connected"])
            with self.subTest(invalid=repr(invalid)), self.assertRaisesRegex(
                XO.XaiOAuthNotConnected, "xai_api_key_missing"
            ):
                await XO.resolve_auth()

        for flow_id in ("", "short", "a" * 81, "a" * 20 + "!", "a b" * 10):
            with self.subTest(flow_id=flow_id), self.assertRaisesRegex(
                XO.XaiOAuthError, "xai_oauth_flow_not_found"
            ):
                await XO.poll_device_login(flow_id)

    async def test_refresh_is_single_flight_and_rotates_the_refresh_token(self):
        self.store_oauth()
        calls = 0

        async def handler(request):
            nonlocal calls
            calls += 1
            await asyncio.sleep(0.02)
            form = parse_qs(request.content.decode())
            self.assertEqual(form["refresh_token"], [REFRESH])
            return response(request, body={
                "access_token": ROTATED_ACCESS,
                "refresh_token": ROTATED_REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        results = await asyncio.gather(*(
            XO.resolve_auth() for _index in range(6)
        ))

        self.assertEqual(calls, 1)
        self.assertEqual({item.bearer_token for item in results}, {ROTATED_ACCESS})
        stored = json.loads(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT))
        self.assertEqual(stored["refresh_token"], ROTATED_REFRESH)
        self.assertEqual(stored["access_token"], ROTATED_ACCESS)

    async def test_refresh_is_single_flight_across_event_loops(self):
        self.store_oauth()
        calls = 0
        calls_lock = threading.Lock()
        entered = threading.Event()
        release = threading.Event()
        barrier = threading.Barrier(3)
        results = [None, None]
        failures = []

        def handler(request):
            nonlocal calls
            with calls_lock:
                calls += 1
            entered.set()
            if not release.wait(timeout=5):
                raise RuntimeError("test refresh release timed out")
            return response(request, body={
                "access_token": ROTATED_ACCESS,
                "refresh_token": ROTATED_REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        def run(index):
            try:
                barrier.wait(timeout=5)
                results[index] = asyncio.run(XO.get_access_token())
            except BaseException as error:
                failures.append(error)

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        threads = [threading.Thread(target=run, args=(index,)) for index in range(2)]
        for thread in threads:
            thread.start()
        try:
            barrier.wait(timeout=5)
            self.assertTrue(await asyncio.to_thread(entered.wait, 5))
            # Give the other loop time to join the already-owned flight.
            await asyncio.sleep(0.03)
        finally:
            release.set()
        for thread in threads:
            await asyncio.to_thread(thread.join, 5)

        self.assertFalse(failures, failures)
        self.assertEqual(results, [ROTATED_ACCESS, ROTATED_ACCESS])
        self.assertEqual(calls, 1)

    async def test_cancelled_waiter_does_not_cancel_shared_refresh(self):
        self.store_oauth()
        entered = asyncio.Event()
        release = asyncio.Event()
        calls = 0

        async def handler(request):
            nonlocal calls
            calls += 1
            entered.set()
            await release.wait()
            return response(request, body={
                "access_token": ROTATED_ACCESS,
                "refresh_token": ROTATED_REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        abandoned = asyncio.create_task(XO.get_access_token())
        await entered.wait()
        abandoned.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await abandoned

        survivor = asyncio.create_task(XO.get_access_token())
        release.set()
        self.assertEqual(await survivor, ROTATED_ACCESS)
        self.assertEqual(calls, 1)

    async def test_in_flight_refresh_cannot_restore_tokens_after_logout(self):
        self.store_oauth()
        refresh_entered = asyncio.Event()
        release_refresh = asyncio.Event()

        async def handler(request):
            if request.url.path.endswith("/revoke"):
                return response(request, body={})
            refresh_entered.set()
            await release_refresh.wait()
            return response(request, body={
                "access_token": ROTATED_ACCESS,
                "refresh_token": ROTATED_REFRESH,
                "expires_in": 3600,
                "token_type": "Bearer",
            })

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        refresh = asyncio.create_task(XO.get_access_token())
        await refresh_entered.wait()
        logged_out = await XO.logout()
        self.assertEqual(logged_out["auth_mode"], XO.OAUTH2_MODE)
        self.assertFalse(logged_out["connected"])
        release_refresh.set()
        with self.assertRaises(XO.XaiOAuthReconnectRequired):
            await refresh
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")

    async def test_terminal_refresh_failure_requires_reconnect_and_clears_tokens(self):
        self.store_oauth()

        def handler(request):
            return response(request, 400, {"error": "invalid_grant"})

        XO._TEST_TRANSPORT = httpx.MockTransport(handler)
        with self.assertRaisesRegex(
            XO.XaiOAuthReconnectRequired, "xai_oauth_reconnect_required"
        ):
            await XO.get_access_token()
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")
        self.assertEqual(XO.auth_mode(), XO.OAUTH2_MODE)
        self.assertEqual(XO.status()["state"], "disconnected")

    async def test_logout_is_local_even_offline_and_never_switches_mode(self):
        self.store_oauth(expires_in=3600)

        def offline(request):
            raise httpx.ConnectError("offline", request=request)

        XO._TEST_TRANSPORT = httpx.MockTransport(offline)
        result = await XO.logout()
        self.assertFalse(result["revoked"])
        self.assertEqual(result["auth_mode"], XO.OAUTH2_MODE)
        self.assertFalse(result["connected"])
        self.assertEqual(credentials.get(XO.OAUTH_CREDENTIAL_ACCOUNT), "")

        credentials.put(XO.API_KEY_ACCOUNT, "xai-" + "k" * 48)
        self.store_oauth(expires_in=3600)
        result = await XO.logout()
        self.assertEqual(result["auth_mode"], XO.OAUTH2_MODE)
        self.assertFalse(result["connected"])
        with self.assertRaisesRegex(
            XO.XaiOAuthNotConnected, "xai_oauth_not_connected"
        ):
            await XO.resolve_auth()


def route_test_application():
    fake_studio = types.ModuleType("studio")
    fake_studio.__path__ = []
    fake_rig = types.ModuleType("studio.rig")
    fake_rig.CONTROLS = {
        name: {"default": 0, "minimum": 0, "maximum": 150}
        for name in (
            "lips", "jaw", "cheeks", "brows", "forehead",
            "nasolabial", "nose", "teeth",
        )
    }
    fake_rig.DENTAL_DONORS = {"upper": ("SS",), "lower": ("ih",)}
    fake_studio.rig = fake_rig
    name = f"_openclam_xai_oauth_route_app_{id(fake_studio)}"
    spec = importlib.util.spec_from_file_location(name, ROOT / "server" / "app.py")
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {
        "studio": fake_studio,
        "studio.rig": fake_rig,
        name: module,
    }), mock.patch.object(
        fastapi_dependency_utils,
        "ensure_multipart_is_installed",
        return_value=None,
    ):
        spec.loader.exec_module(module)
    return module


class XaiOAuthRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = route_test_application()

    def request(self, method, path, **kwargs):
        async def run():
            transport = httpx.ASGITransport(app=self.application.app)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://test"
            ) as client:
                return await client.request(method, path, **kwargs)
        return asyncio.run(run())

    def test_routes_are_registered_and_safe_responses_are_no_store(self):
        application = self.application
        paths = {route.path for route in application.app.routes}
        self.assertTrue({
            "/api/xai/oauth/status",
            "/api/xai/oauth/device/start",
            "/api/xai/oauth/device/poll",
            "/api/xai/oauth/device/cancel",
            "/api/xai/oauth/mode",
            "/api/xai/oauth/logout",
        }.issubset(paths))
        safe_status = {
            "provider": "xai",
            "auth_mode": "api_key",
            "state": "disconnected",
            "connected": False,
            "has_api_key": False,
            "oauth": {"available": True, "connected": False, "refreshable": False,
                      "expires_at": None},
            "independent_notice": XO.INDEPENDENCE_NOTICE,
        }
        with mock.patch.object(application.xai_oauth, "status",
                               return_value=safe_status):
            result = asyncio.run(application.api_xai_oauth_status())
        self.assertEqual(result.headers["cache-control"], "no-store")
        self.assertNotIn("token", result.body.decode())

    def test_cancel_route_requires_the_process_local_auth_token(self):
        safe_status = {
            "provider": "xai",
            "auth_mode": "oauth2",
            "state": "disconnected",
            "connected": False,
            "has_api_key": False,
            "oauth": {"available": True, "connected": False, "refreshable": False,
                      "expires_at": None},
            "independent_notice": XO.INDEPENDENCE_NOTICE,
            "device_flow_cancelled": True,
        }
        with mock.patch.object(
            self.application, "AUTH_TOKEN", "local-auth-token"
        ), mock.patch.object(
            self.application.xai_oauth, "cancel_device_login",
            return_value=safe_status,
        ) as cancel:
            rejected = self.request(
                "POST", "/api/xai/oauth/device/cancel"
            )
            accepted = self.request(
                "POST",
                "/api/xai/oauth/device/cancel",
                headers={"X-OpenClam-Token": "local-auth-token"},
            )
        self.assertEqual(rejected.status_code, 403)
        self.assertEqual(accepted.status_code, 200)
        self.assertEqual(accepted.headers["cache-control"], "no-store")
        self.assertTrue(accepted.json()["device_flow_cancelled"])
        cancel.assert_called_once_with()

    def test_model_and_test_routes_defer_xai_to_the_global_resolver(self):
        application = self.application
        legacy = {
            "provider": "xai",
            "api_key": "legacy-lane-key-must-not-pass",
        }
        with mock.patch.object(application, "_with_key", return_value=legacy), \
             mock.patch.object(
                 application.xai_oauth, "auth_mode",
                 return_value=XO.OAUTH2_MODE,
             ), \
             mock.patch.object(
                 application.P,
                 "list_choices",
                 new=mock.AsyncMock(return_value={"models": ["grok"]}),
             ) as choices:
            result = asyncio.run(application.api_models({"kind": "llm"}))
        self.assertTrue(result["ready"])
        self.assertFalse(result["validated"])
        self.assertFalse(result["provider_contacted"])
        self.assertEqual(result["readiness"], "reviewed_local_catalog")
        self.assertIn("exact selected model", result["detail"])
        self.assertNotIn("api_key", choices.await_args.args[1])

        with mock.patch.object(application, "_with_key", return_value=legacy), \
             mock.patch.object(
                 application.P,
                 "test",
                 new=mock.AsyncMock(return_value={"ok": True}),
             ) as provider_test:
            result = asyncio.run(application.api_test({"kind": "llm"}))
        self.assertEqual(result, {"ok": True})
        self.assertNotIn("api_key", provider_test.await_args.args[1])


if __name__ == "__main__":
    unittest.main()
