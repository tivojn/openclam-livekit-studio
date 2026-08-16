import asyncio
import contextlib
import copy
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))

import credentials
import livekit_bridge as LK
import providers as P


PILOT_TOKEN = "pilot-" + "p" * 40
PARTICIPANT_TOKEN = "participant-token"
EXPECTED_HOST = "openclam-test.livekit.cloud"
DEPLOYMENT_ENV = {
    LK.BROKER_URL_ENV: "https://openclam-broker.example/v1/live-talk/sessions",
    LK.SERVER_HOST_ENV: EXPECTED_HOST,
}


def managed_config():
    config = copy.deepcopy(LK.DEFAULT_CONFIG)
    config.update({
        "broker_url": "https://openclam-broker.example/v1/live-talk/sessions",
        "expected_server_host": EXPECTED_HOST,
    })
    return config


def success_response(request, **overrides):
    body = {
        "server_url": f"wss://{EXPECTED_HOST}",
        "participant_token": PARTICIPANT_TOKEN,
    }
    body.update(overrides)
    return httpx.Response(201, json=body, request=request)


def route_test_application():
    """Load the FastAPI module without importing the optional avatar ML stack.

    These tests exercise only local auth, LiveKit routes, and fixed resources.
    Production imports the real studio.rig; the tiny stand-in supplies only the
    constants evaluated while app.py declares unrelated rig request models.
    """
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
    name = f"_openclam_livekit_route_app_{id(fake_studio)}"
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(ROOT, "server", "app.py")
    )
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {
        "studio": fake_studio,
        "studio.rig": fake_rig,
        name: module,
    }):
        spec.loader.exec_module(module)
    return module


class LiveKitCatalogTests(unittest.TestCase):
    def test_vendored_contract_matches_suite_contract_when_both_exist(self):
        local = Path(ROOT) / "contracts" / LK.CONTRACT_NAME
        suite = Path(ROOT).parents[1] / "contracts" / LK.CONTRACT_NAME
        self.assertTrue(local.is_file())
        if suite.is_file():
            self.assertEqual(local.read_bytes(), suite.read_bytes())

    def test_catalog_is_the_canonical_tuple_fixture_exactly(self):
        with LK._contract_path().open(encoding="utf-8") as handle:
            fixture = json.load(handle)
        actual = []
        catalog = LK.catalog()
        for stage in LK.STAGES:
            for selection in catalog["stages"][stage]:
                actual.append([
                    stage,
                    selection["source"],
                    selection["provider"],
                    selection["model"],
                    selection.get("voice"),
                    selection.get("language"),
                ])
        self.assertEqual(catalog["schema_version"], fixture["schema_version"])
        self.assertEqual(actual, fixture["tuples"])

    def test_packaged_backend_contract_fallback_reads_the_same_fixture(self):
        source = LK._contract_path().read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            packaged = Path(directory) / "backend" / "contracts" / LK.CONTRACT_NAME
            packaged.parent.mkdir(parents=True)
            packaged.write_bytes(source)
            missing = Path(directory) / "checkout" / LK.CONTRACT_NAME
            with patch.object(LK, "CONTRACT_CANDIDATES", (missing, packaged)):
                LK._contract.cache_clear()
                try:
                    self.assertEqual(LK._contract_path(), packaged)
                    self.assertEqual(LK.catalog()["schema_version"], 1)
                finally:
                    LK._contract.cache_clear()

    def test_managed_defaults_are_explicit_closed_choices(self):
        config = LK.validated_config({})
        self.assertEqual(
            {stage: config[stage] for stage in LK.STAGES},
            LK.MANAGED_DEFAULT,
        )

    def test_selection_rejects_unknown_tuple_and_extra_parameters(self):
        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_selection_not_allowed"
        ):
            LK.validated_selection("llm", {
                "source": "byok",
                "provider": "openai",
                "model": "future-unreviewed-model",
            })
        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_selection_not_allowed"
        ):
            LK.validated_selection("llm", {
                "source": "byok",
                "provider": "openai",
                "model": "gpt-5.6-luna",
                "temperature": 2,
            })

    def test_connection_config_rejects_non_https_or_wrong_path(self):
        for endpoint in (
            "http://openclam-broker.example/v1/live-talk/sessions",
            "https://openclam-broker.example/other",
            "https://user@openclam-broker.example/v1/live-talk/sessions",
            "https://openclam-broker.example/v1/live-talk/sessions?key=x",
            "https://openclam-broker.example:444/v1/live-talk/sessions",
        ):
            config = managed_config()
            config["broker_url"] = endpoint
            with self.subTest(endpoint=endpoint), self.assertRaises(
                LK.LiveKitBridgeError
            ):
                LK.validated_config(config)

    def test_deployment_hosts_are_pinned_and_renderer_updates_are_rejected(self):
        attacker = managed_config()
        attacker["broker_url"] = (
            "https://attacker.example/v1/live-talk/sessions"
        )
        attacker["expected_server_host"] = "attacker.livekit.cloud"
        pinned = LK.deployment_config(attacker, DEPLOYMENT_ENV, True)
        self.assertEqual(pinned["broker_url"], DEPLOYMENT_ENV[LK.BROKER_URL_ENV])
        self.assertEqual(
            pinned["expected_server_host"], DEPLOYMENT_ENV[LK.SERVER_HOST_ENV]
        )
        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_deployment_config_read_only"
        ):
            LK.prepare_config_update(
                managed_config(),
                {"broker_url": attacker["broker_url"]},
                allow_connection_fields=False,
            )

    def test_session_requires_both_trusted_deployment_pins(self):
        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_not_configured"
        ):
            LK.deployment_config(managed_config(), {}, True)

    def test_persisted_managed_tts_drops_only_impossible_stale_language(self):
        stale = managed_config()
        stale["tts"]["voice"] = "536d3a5e000945adb7038665781a4aca"
        stale["tts"]["language"] = "auto"
        migrated = LK.deployment_config(stale, DEPLOYMENT_ENV, True)
        self.assertEqual(migrated["tts"], {
            "source": "managed",
            "provider": "livekit",
            "model": "fishaudio/s2.1-pro",
            "voice": "536d3a5e000945adb7038665781a4aca",
        })

        wrong_voice = managed_config()
        wrong_voice["tts"]["voice"] = "unreviewed-managed-voice"
        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_selection_not_allowed"
        ):
            LK.deployment_config(wrong_voice, DEPLOYMENT_ENV, True)

    def test_settings_save_repairs_stale_persisted_livekit_tuple(self):
        stale = managed_config()
        stale["tts"]["voice"] = "536d3a5e000945adb7038665781a4aca"
        stale["tts"]["language"] = "auto"
        incoming = {
            stage: copy.deepcopy(LK.MANAGED_DEFAULT[stage])
            for stage in LK.STAGES
        }
        incoming["tts"]["voice"] = "536d3a5e000945adb7038665781a4aca"
        repaired = LK.prepare_config_update(
            stale, incoming, allow_connection_fields=False
        )
        self.assertEqual(repaired["tts"], incoming["tts"])
        self.assertNotIn("language", repaired["tts"])


class LiveKitSessionTests(unittest.TestCase):
    def run_session(self, config, handler, getter, xai_resolver=None):
        return asyncio.run(LK.create_session(
            config,
            "Captain Ayer",
            "You are Captain Ayer. Be concise.",
            secret_getter=getter,
            transport=httpx.MockTransport(handler),
            deployment_environment=DEPLOYMENT_ENV,
            xai_auth_resolver=xai_resolver,
        ))

    def test_managed_session_sends_no_provider_credentials(self):
        captured = {}
        accounts = []

        def getter(account):
            accounts.append(account)
            return PILOT_TOKEN if account == "livekit.pilot_app_token" else ""

        def handler(request):
            captured["request"] = request
            captured["body"] = json.loads(request.content)
            return success_response(request)

        result = self.run_session(managed_config(), handler, getter)

        self.assertEqual(result, {
            "server_url": f"wss://{EXPECTED_HOST}",
            "participant_token": PARTICIPANT_TOKEN,
        })
        self.assertEqual(accounts, ["livekit.pilot_app_token"])
        self.assertEqual(captured["body"]["credentials"], {})
        self.assertEqual(captured["body"]["profile"]["persona"], {
            "name": "Captain Ayer",
            "instructions": "You are Captain Ayer. Be concise.",
        })
        self.assertNotIn("metadata", captured["body"])
        self.assertEqual(
            captured["request"].headers["authorization"],
            f"Bearer {PILOT_TOKEN}",
        )
        self.assertEqual(captured["request"].headers["cache-control"], "no-store")
        self.assertNotIn("cookie", captured["request"].headers)

    def test_byok_session_reuses_platform_keychain_accounts_per_stage(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "openai", "model": "gpt-5.6-luna",
        }
        config["stt"] = {
            "source": "byok", "provider": "deepgram", "model": "nova-3",
            "language": "multi",
        }
        config["tts"] = {
            "source": "byok", "provider": "gemini",
            "model": "gemini-3.1-flash-tts-preview", "voice": "Kore",
        }
        secrets = {
            "keys.openai": "openai-provider-key",
            "keys.deepgram": "deepgram-provider-key",
            "keys.gemini": "gemini-provider-key",
            "livekit.pilot_app_token": PILOT_TOKEN,
        }
        captured = {}

        def handler(request):
            captured.update(json.loads(request.content))
            return success_response(request)

        result = self.run_session(config, handler, secrets.get)
        self.assertEqual(result["participant_token"], PARTICIPANT_TOKEN)
        self.assertEqual(captured["credentials"], {
            "llm": {"api_key": "openai-provider-key"},
            "stt": {"api_key": "deepgram-provider-key"},
            "tts": {"api_key": "gemini-provider-key"},
        })
        self.assertNotIn("pilot_app_token", json.dumps(captured))

    def test_missing_byok_key_fails_before_network(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "openai", "model": "gpt-5.6-luna",
        }
        network_calls = []

        def handler(request):
            network_calls.append(request)
            return success_response(request)

        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_missing_openai_key"
        ):
            self.run_session(
                config,
                handler,
                lambda account: PILOT_TOKEN
                if account == "livekit.pilot_app_token" else "",
            )
        self.assertEqual(network_calls, [])

    def test_xai_global_auth_mode_is_reused_for_every_live_talk_stage(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "xai", "model": "grok-4.5",
        }
        config["stt"] = {
            "source": "byok", "provider": "xai", "model": "grok-transcribe",
            "language": "en",
        }
        config["tts"] = {
            "source": "byok", "provider": "xai", "model": "xai-tts",
            "voice": "rex", "language": "auto",
        }
        captured = {}
        resolved_calls = []
        getter_calls = []

        class Resolved:
            mode = "oauth2"
            bearer_token = "oauth-access-token-for-live-talk"

        async def resolver():
            resolved_calls.append(True)
            return Resolved()

        def getter(account):
            getter_calls.append(account)
            return PILOT_TOKEN if account == "livekit.pilot_app_token" else ""

        def handler(request):
            captured.update(json.loads(request.content))
            return success_response(request)

        result = self.run_session(
            config, handler, getter, xai_resolver=resolver
        )
        self.assertEqual(result["participant_token"], PARTICIPANT_TOKEN)
        self.assertEqual(resolved_calls, [True])
        self.assertEqual(getter_calls, ["livekit.pilot_app_token"])
        self.assertEqual(captured["credentials"], {
            "llm": {
                "api_key": Resolved.bearer_token,
                "auth_mode": "oauth2",
            },
            "stt": {
                "api_key": Resolved.bearer_token,
                "auth_mode": "oauth2",
            },
            "tts": {
                "api_key": Resolved.bearer_token,
                "auth_mode": "oauth2",
            },
        })

    def test_xai_api_key_mode_uses_same_global_resolver_without_fallback(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "xai", "model": "grok-4.5",
        }
        captured = {}

        class Resolved:
            mode = "api_key"
            bearer_token = "xai-global-api-key"

        async def resolver():
            return Resolved()

        def handler(request):
            captured.update(json.loads(request.content))
            return success_response(request)

        self.run_session(
            config,
            handler,
            lambda account: PILOT_TOKEN,
            xai_resolver=resolver,
        )
        self.assertEqual(captured["credentials"], {
            "llm": {
                "api_key": Resolved.bearer_token,
                "auth_mode": "api_key",
            },
        })

    def test_xai_payload_never_infers_mode_or_reads_legacy_keychain_value(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "xai", "model": "grok-4.5",
        }
        keychain_calls = []

        def getter(account):
            keychain_calls.append(account)
            return "legacy-xai-key-that-must-not-be-used"

        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_xai_auth_unavailable"
        ):
            LK.session_payload(
                config,
                "Captain Ayer",
                "You are Captain Ayer. Be concise.",
                getter,
                xai_bearer="oauth-access-token",
            )
        self.assertEqual(keychain_calls, [])

    def test_invalid_resolved_xai_mode_stops_before_broker_without_fallback(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "xai", "model": "grok-4.5",
        }
        network_calls = []
        keychain_calls = []

        class Resolved:
            mode = "hybrid"
            bearer_token = "must-not-leave-the-mac"

        async def resolver():
            return Resolved()

        def getter(account):
            keychain_calls.append(account)
            return "fallback-must-not-be-read"

        def handler(request):
            network_calls.append(request)
            return success_response(request)

        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_xai_auth_unavailable"
        ):
            self.run_session(
                config, handler, getter, xai_resolver=resolver
            )
        self.assertEqual(network_calls, [])
        self.assertEqual(keychain_calls, [])

    def test_xai_auth_failure_stops_before_broker_and_never_falls_back(self):
        config = managed_config()
        config["llm"] = {
            "source": "byok", "provider": "xai", "model": "grok-4.5",
        }
        network_calls = []
        keychain_calls = []

        async def resolver():
            raise RuntimeError("oauth refresh contained sensitive details")

        def getter(account):
            keychain_calls.append(account)
            return PILOT_TOKEN if account == "livekit.pilot_app_token" else \
                "must-not-be-used-as-fallback"

        def handler(request):
            network_calls.append(request)
            return success_response(request)

        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_xai_auth_unavailable"
        ):
            self.run_session(
                config, handler, getter, xai_resolver=resolver
            )
        self.assertEqual(network_calls, [])
        self.assertEqual(keychain_calls, [])

    def test_redirect_is_never_followed(self):
        calls = []

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(
                307,
                headers={"Location": "https://attacker.example/capture"},
                request=request,
            )

        with self.assertRaisesRegex(
            LK.LiveKitBridgeError, "livekit_broker_redirect_rejected"
        ):
            self.run_session(
                managed_config(), handler,
                lambda account: PILOT_TOKEN,
            )
        self.assertEqual(calls, [managed_config()["broker_url"]])

    def test_response_server_must_be_exact_expected_wss_host_and_443(self):
        bad_urls = (
            "ws://openclam-test.livekit.cloud",
            "wss://other.livekit.cloud",
            "wss://openclam-test.livekit.cloud:444",
            "wss://openclam-test.livekit.cloud/room",
            "wss://openclam-test.livekit.cloud/?secret=x",
            "wss://user@openclam-test.livekit.cloud",
            "wss://OPENCLAM-TEST.livekit.cloud",
        )
        for server_url in bad_urls:
            def handler(request, value=server_url):
                return success_response(request, server_url=value)

            with self.subTest(server_url=server_url), self.assertRaisesRegex(
                LK.LiveKitBridgeError, "livekit_broker_response_invalid"
            ):
                self.run_session(
                    managed_config(), handler, lambda account: PILOT_TOKEN
                )

        def explicit_443(request):
            return success_response(
                request, server_url=f"wss://{EXPECTED_HOST}:443"
            )

        result = self.run_session(
            managed_config(), explicit_443, lambda account: PILOT_TOKEN
        )
        self.assertEqual(result["server_url"], f"wss://{EXPECTED_HOST}:443")

    def test_response_token_is_bounded_and_response_shape_is_exact(self):
        bodies = (
            {"server_url": f"wss://{EXPECTED_HOST}", "participant_token": ""},
            {
                "server_url": f"wss://{EXPECTED_HOST}",
                "participant_token": "x" * (LK.MAX_PARTICIPANT_TOKEN_BYTES + 1),
            },
            {
                "server_url": f"wss://{EXPECTED_HOST}",
                "participant_token": PARTICIPANT_TOKEN,
                "unexpected": True,
            },
        )
        for body in bodies:
            def handler(request, value=body):
                return httpx.Response(201, json=value, request=request)

            with self.subTest(body_keys=list(body)), self.assertRaisesRegex(
                LK.LiveKitBridgeError, "livekit_broker_response_invalid"
            ):
                self.run_session(
                    managed_config(), handler, lambda account: PILOT_TOKEN
                )

    def test_secrets_are_not_logged_or_returned(self):
        config = managed_config()
        config["tts"] = {
            "source": "byok", "provider": "xai", "model": "xai-tts",
            "voice": "rex", "language": "auto",
        }
        provider_key = "xai-provider-secret"
        sink = io.StringIO()

        class Resolved:
            mode = "api_key"
            bearer_token = provider_key

        async def resolver():
            return Resolved()

        def getter(account):
            return provider_key if account == "keys.xai" else PILOT_TOKEN

        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            result = self.run_session(
                config, success_response, getter, xai_resolver=resolver
            )
        visible = sink.getvalue() + json.dumps(result)
        self.assertNotIn(provider_key, visible)
        self.assertNotIn(PILOT_TOKEN, visible)


class LiveKitPersistenceAndAPITests(unittest.TestCase):
    def tearDown(self):
        credentials._memo.clear()
        credentials._TEST_VAULT_FILE = None
        credentials._TEST_NATIVE_KEYCHAIN = None
        P._migrated[0] = False

    def test_pilot_and_platform_keys_persist_only_as_keychain_markers(self):
        provider_key = "openai-persistence-secret"
        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            vault_path = os.path.join(directory, "test-vault.json")
            update = managed_config()
            update["pilot_app_token"] = PILOT_TOKEN
            with patch.object(P, "CONFIG", config_path), patch.object(
                credentials, "_TEST_VAULT_FILE", vault_path
            ):
                P.save({
                    "keys": {"openai": provider_key},
                    "livekit": update,
                })
                with open(config_path, encoding="utf-8") as handle:
                    on_disk = handle.read()
                self.assertNotIn(PILOT_TOKEN, on_disk)
                self.assertNotIn(provider_key, on_disk)
                self.assertIn(credentials.MARKER, on_disk)
                self.assertEqual(stat.S_IMODE(os.stat(config_path).st_mode), 0o600)

                public = P.redacted(P.load())
                self.assertEqual(public["livekit"]["pilot_app_token"], "")
                self.assertTrue(public["livekit"]["has_pilot_app_token"])
                self.assertEqual(public["keys"]["openai"], "")
                self.assertTrue(public["has_keys"]["openai"])
                safe = LK.public_config(
                    P.load()["livekit"], has_pilot_app_token=True
                )
                self.assertNotIn("pilot_app_token", safe)

    def test_keychain_namespace_write_and_delete_are_hardened(self):
        self.assertEqual(credentials.SERVICE, "com.lionheart.openclam.macos")
        self.assertEqual(credentials.STORAGE_ACCOUNT_PREFIX, "openclam-v2:")
        secret = "provider-secret-not-in-argv"
        account = "keys.test-provider"
        source = Path(credentials.__file__).read_text(encoding="utf-8")
        self.assertNotRegex(source, r'''["']/usr/bin/security["']''')
        self.assertNotIn("import subprocess", source)
        self.assertIn("SecItemCopyMatching", source)
        self.assertIn("SecItemUpdate", source)
        self.assertIn("SecItemDelete", source)

        class MemoryKeychain:
            def __init__(self):
                self.values = {}
                self.delete_error = None

            def get(self, name):
                return self.values.get(name, "")

            def put(self, name, value):
                self.values[name] = value

            def clear(self, name):
                if self.delete_error:
                    raise self.delete_error
                self.values.pop(name, None)

        backend = MemoryKeychain()
        with patch.object(credentials, "_is_mac", return_value=True), patch.object(
            credentials, "_TEST_NATIVE_KEYCHAIN", backend
        ):
            credentials.put(account, secret)
            credentials._memo.clear()
            self.assertEqual(credentials.get(account), secret)
            backend.delete_error = RuntimeError("OpenClam Keychain deletion failed")
            with self.assertRaisesRegex(RuntimeError, "deletion failed"):
                credentials.clear(account)
            self.assertEqual(credentials._memo[account], secret)
            backend.delete_error = None
            credentials.clear(account)
            self.assertEqual(credentials._memo[account], "")

    def test_inherited_vault_environment_cannot_disable_macos_keychain(self):
        with patch.object(credentials.sys, "platform", "darwin"), patch.dict(
            os.environ, {"VIVIEEN_VAULT_FILE": "/tmp/attacker-vault.json"}
        ):
            credentials._TEST_VAULT_FILE = None
            self.assertTrue(credentials._is_mac())

    def request(self, application, method, path, **kwargs):
        async def run():
            transport = httpx.ASGITransport(app=application.app)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://test"
            ) as client:
                return await client.request(method, path, **kwargs)
        return asyncio.run(run())

    def test_livekit_endpoints_are_local_auth_protected_and_redacted(self):
        application = route_test_application()
        self.assertEqual(application.APP_ID, "com.lionheart.openclam.macos")

        config = managed_config()
        with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
             patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
             patch.object(application.P, "load", return_value={"livekit": config}), \
             patch.object(
                 application.P, "load_livekit_nonsecret", return_value=config
             ), patch.object(application.credentials, "get", return_value=PILOT_TOKEN), \
             patch.object(application, "active_slug", return_value="captain-ayer"):
            rejected = self.request(
                application, "GET", "/api/livekit/config"
            )
            accepted = self.request(
                application,
                "GET",
                "/api/livekit/config",
                headers={"X-OpenClam-Token": "local-auth-token"},
            )
            repin = self.request(
                application,
                "POST",
                "/api/livekit/config",
                headers={"X-OpenClam-Token": "local-auth-token"},
                json={
                    "broker_url":
                        "https://attacker.example/v1/live-talk/sessions"
                },
            )
        self.assertEqual(rejected.status_code, 403)
        self.assertEqual(accepted.status_code, 200)
        encoded = accepted.text
        self.assertNotIn(PILOT_TOKEN, encoded)
        self.assertTrue(accepted.json()["config"]["has_pilot_app_token"])
        self.assertEqual(accepted.headers["cache-control"], "no-store")
        csp = accepted.headers["content-security-policy"]
        self.assertIn(f"https://{EXPECTED_HOST}", csp)
        self.assertIn(f"wss://{EXPECTED_HOST}", csp)
        connect_sources = next(
            directive.strip().split()[1:]
            for directive in csp.split(";")
            if directive.strip().startswith("connect-src ")
        )
        self.assertNotIn("https:", connect_sources)
        self.assertNotIn("wss:", connect_sources)
        self.assertEqual(repin.status_code, 422)
        self.assertEqual(
            repin.json()["detail"], "livekit_deployment_config_read_only"
        )

        with patch.object(application, "AUTH_TOKEN", ""), patch.object(
            application.P, "load_livekit_nonsecret", return_value=config
        ):
            unconfigured = self.request(
                application, "GET", "/api/livekit/config"
            )
        self.assertEqual(unconfigured.status_code, 503)
        self.assertEqual(unconfigured.json()["error"], "local_auth_not_configured")
        self.assertEqual(unconfigured.headers["cache-control"], "no-store")

    def test_saved_xai_tts_language_does_not_block_managed_ui_or_session(self):
        application = route_test_application()
        stale = managed_config()
        stale["tts"] = {
            "source": "managed",
            "provider": "livekit",
            "model": "fishaudio/s2.1-pro",
            "voice": "536d3a5e000945adb7038665781a4aca",
            "language": "auto",
        }
        session_configs = []

        async def create_session(config, _name, _instructions):
            session_configs.append(copy.deepcopy(config))
            return {
                "server_url": f"wss://{EXPECTED_HOST}",
                "participant_token": PARTICIPANT_TOKEN,
            }

        headers = {"X-OpenClam-Token": "local-auth-token"}
        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            vault_path = os.path.join(directory, "vault.json")
            stale["pilot_app_token"] = PILOT_TOKEN
            credentials._memo.clear()
            P._migrated[0] = False
            with patch.object(P, "CONFIG", config_path), patch.object(
                credentials, "_TEST_VAULT_FILE", vault_path
            ):
                P.save({
                    "livekit": stale,
                    "persona": {"name": "Samantha"},
                    "ui": {"design": "quiet"},
                })
                with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
                     patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
                     patch.object(
                         application, "_active_livekit_persona",
                         return_value=("Samantha", "Be helpful."),
                     ), patch.object(
                         application.LK, "create_session",
                         side_effect=create_session,
                     ):
                    opened = self.request(
                        application, "GET", "/api/livekit/config",
                        headers=headers,
                    )
                    started = self.request(
                        application, "POST", "/api/livekit/session",
                        headers=headers,
                    )
                    visible = opened.json()["config"]
                    saved = self.request(
                        application,
                        "POST",
                        "/api/livekit/config",
                        headers=headers,
                        json={stage: visible[stage] for stage in LK.STAGES},
                    )
                    restarted = self.request(
                        application, "POST", "/api/livekit/session",
                        headers=headers,
                    )

                    with open(config_path, encoding="utf-8") as handle:
                        on_disk = json.load(handle)
                    before_rejected_save = Path(config_path).read_bytes()
                    malformed = {
                        stage: copy.deepcopy(visible[stage])
                        for stage in LK.STAGES
                    }
                    malformed["tts"]["language"] = "auto"
                    rejected = self.request(
                        application,
                        "POST",
                        "/api/livekit/config",
                        headers=headers,
                        json=malformed,
                    )
                    self.assertEqual(
                        Path(config_path).read_bytes(), before_rejected_save
                    )
                    loaded = P.load()

        expected_tts = {
            "source": "managed",
            "provider": "livekit",
            "model": "fishaudio/s2.1-pro",
            "voice": "536d3a5e000945adb7038665781a4aca",
        }
        self.assertEqual(opened.status_code, 200)
        self.assertEqual(opened.json()["config"]["tts"], expected_tts)
        self.assertEqual(started.status_code, 200)
        self.assertEqual(session_configs[0]["tts"], expected_tts)
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(saved.json()["config"]["tts"], expected_tts)
        self.assertEqual(restarted.status_code, 200)
        self.assertEqual(session_configs[1]["tts"], expected_tts)
        self.assertEqual(on_disk["livekit"]["tts"], expected_tts)
        self.assertEqual(on_disk["livekit"]["broker_url"], "")
        self.assertEqual(on_disk["livekit"]["expected_server_host"], "")
        self.assertEqual(
            on_disk["livekit"]["pilot_app_token"], credentials.MARKER
        )
        self.assertEqual(on_disk["ui"], {"design": "quiet"})
        self.assertEqual(loaded["livekit"]["pilot_app_token"], PILOT_TOKEN)
        self.assertNotIn(PILOT_TOKEN, json.dumps(on_disk))
        self.assertNotIn(PILOT_TOKEN, opened.text + saved.text)
        self.assertEqual(rejected.status_code, 422)
        self.assertEqual(
            rejected.json()["detail"], "livekit_selection_not_allowed"
        )

    def test_local_state_apis_and_cross_origin_errors_are_no_store(self):
        application = route_test_application()
        config = managed_config()
        cfg = {
            "livekit": config,
            "ui": {"design": "quiet"},
        }
        headers = {"X-OpenClam-Token": "local-auth-token"}
        with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
             patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
             patch.object(application.P, "load", return_value=cfg), \
             patch.object(
                 application.P, "load_livekit_nonsecret", return_value=config
             ), patch.object(application, "active_slug", return_value=None), \
             patch.object(application.reg(), "get_companion", return_value=None):
            meta = self.request(
                application, "GET", "/api/meta", headers=headers
            )
            rejected = self.request(
                application,
                "POST",
                "/api/does-not-exist",
                headers={**headers, "Origin": "https://attacker.invalid"},
            )
        self.assertEqual(meta.status_code, 200)
        self.assertEqual(meta.headers["cache-control"], "no-store")
        self.assertEqual(rejected.status_code, 403)
        self.assertEqual(rejected.headers["cache-control"], "no-store")

    def test_secret_reveal_endpoint_is_retired(self):
        application = route_test_application()
        with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
             patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
             patch.object(
                 application.P, "load_livekit_nonsecret",
                 return_value=managed_config(),
             ), patch.object(
                 application.P, "load",
                 side_effect=AssertionError("must not materialise a secret"),
             ):
            response = self.request(
                application,
                "GET",
                "/api/reveal?path=keys.openai",
                headers={"X-OpenClam-Token": "local-auth-token"},
            )
        self.assertEqual(response.status_code, 404)
        self.assertNotIn("secret", response.text.lower())
        self.assertEqual(response.headers["cache-control"], "no-store")

    def test_missing_local_auth_also_closes_websockets(self):
        application = route_test_application()

        class Socket:
            headers = {}

            def __init__(self):
                self.closed = None

            async def close(self, code):
                self.closed = code

        dictation = Socket()
        with patch.object(application, "AUTH_TOKEN", ""):
            asyncio.run(application.stt_stream(dictation, pcm=0))
        self.assertEqual(dictation.closed, 4403)
        self.assertFalse(any(
            getattr(route, "path", "") == "/live/voice"
            for route in application.app.routes
        ))

    def test_session_route_uses_active_avatar_name_and_persona(self):
        application = route_test_application()

        config = managed_config()
        cfg = {
            "livekit": config,
            "persona": {"name": "House", "system": "House persona"},
        }

        class Registry:
            @staticmethod
            def read_manifest(slug):
                self.assertEqual(slug, "emma")
                return {
                    "name": "Emma",
                    "persona": {"system": "Emma's own persona"},
                }

        starter = AsyncMock(return_value={
            "server_url": f"wss://{EXPECTED_HOST}",
            "participant_token": PARTICIPANT_TOKEN,
        })
        with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
             patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
             patch.object(application.P, "load", return_value=cfg), \
             patch.object(
                 application.P, "load_livekit_nonsecret", return_value=config
             ), patch.object(application, "active_slug", return_value="emma"), \
             patch.object(application, "reg", return_value=Registry()), \
             patch.object(application.LK, "create_session", new=starter):
            response = self.request(
                application,
                "POST",
                "/api/livekit/session",
                headers={"X-OpenClam-Token": "local-auth-token"},
            )
        self.assertEqual(response.status_code, 200)
        starter.assert_awaited_once_with(
            config, "Emma", "Emma's own persona"
        )

    def test_pinned_renderer_resources_are_same_origin_no_store(self):
        application = route_test_application()

        with patch.dict(os.environ, DEPLOYMENT_ENV, clear=False), \
             patch.object(application, "AUTH_TOKEN", "local-auth-token"), \
             patch.object(
                 application.P,
                 "load_livekit_nonsecret",
                 return_value=managed_config(),
             ):
            headers = {"X-OpenClam-Token": "local-auth-token"}
            script = self.request(
                application, "GET", "/livekit-client.js", headers=headers
            )
            sound = self.request(
                application, "GET", "/live-talk-connection.wav", headers=headers
            )
        self.assertEqual(script.status_code, 200)
        self.assertIn("javascript", script.headers["content-type"])
        self.assertEqual(script.headers["cache-control"], "no-store")
        self.assertEqual(script.headers["x-content-type-options"], "nosniff")
        self.assertEqual(sound.status_code, 200)
        self.assertIn("audio/wav", sound.headers["content-type"])
        self.assertEqual(sound.headers["cache-control"], "no-store")


if __name__ == "__main__":
    unittest.main()
