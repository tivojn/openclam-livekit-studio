"""Standalone chat, speech, transcription, and credential behavior."""
import asyncio
import base64
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import credentials
import providers as P


class DirectProviderDefaultsTests(unittest.TestCase):
    def setUp(self):
        P._routes.clear()

    def test_fresh_install_defaults_to_local_chat_speech_and_transcription(self):
        self.assertEqual(
            {kind: P.DEFAULTS[kind]["provider"] for kind in ("llm", "tts", "stt")},
            {"llm": "ollama", "tts": "system", "stt": "mlx_whisper"},
        )
        self.assertEqual(P.DEFAULTS["image"]["provider"], "")
        self.assertEqual(P.DEFAULTS["video"]["provider"], "")

    def test_catalog_contains_no_managed_desktop_gateway(self):
        for kind, rows in P.catalog().items():
            self.assertFalse(any(row.get("managed") for row in rows), kind)
        self.assertEqual("Ollama", P.spec("llm", "ollama")["label"])
        self.assertEqual("macOS say", P.spec("tts", "system")["label"])

    def test_signed_app_never_advertises_unbundled_kokoro(self):
        with patch.object(P, "PACKAGED_RUNTIME", True):
            self.assertNotIn("kokoro", {row["id"] for row in P.catalog()["tts"]})
            self.assertIsNone(P.spec("tts", "kokoro"))
            with self.assertRaisesRegex(RuntimeError, "not included in the signed app"):
                P._kokoro({})

    def test_keyed_provider_refuses_model_listing_before_a_key_exists(self):
        with self.assertRaisesRegex(RuntimeError, "API key is required"):
            asyncio.run(P.list_models("llm", {"provider": "openai", "api_key": ""}))

    def test_unknown_provider_fails_before_any_network_request(self):
        with self.assertRaisesRegex(RuntimeError, "Choose a direct language model"):
            asyncio.run(P.chat([], {"provider": "retired-gateway"}))
        with self.assertRaisesRegex(RuntimeError, "Choose a direct speaking voice"):
            asyncio.run(P.speak("hello", {"provider": "retired-gateway"}))
        with self.assertRaisesRegex(RuntimeError, "Choose a direct speech recognizer"):
            asyncio.run(P.hear(b"audio", "take.webm", {"provider": "retired-gateway"}))

    def test_speech_language_catalogs_are_closed_and_provider_specific(self):
        self.assertEqual(
            "multi", P.stt_language_catalog("deepgram")["default_language"]
        )
        self.assertEqual(
            {"multi", "en", "zh"},
            {row["id"] for row in P.stt_language_catalog("deepgram")["languages"]},
        )
        xai = P.stt_language_catalog("xai")
        self.assertEqual("auto", xai["default_language"])
        self.assertEqual(26, len(xai["languages"]))
        self.assertNotIn("zh", {row["id"] for row in xai["languages"]})
        with self.assertRaisesRegex(RuntimeError, "does not support Chinese"):
            P.validate_stt_language("xai", "zh")

    def test_deepgram_auto_transcription_explicitly_uses_multi(self):
        observed = {}

        class Response:
            @staticmethod
            def raise_for_status():
                return None

            @staticmethod
            def json():
                return {"results": {"channels": [{"alternatives": [
                    {"transcript": "你好 hello"},
                ]}]}}

        class Client:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return False

            async def post(self, url, **kwargs):
                observed["url"] = url
                observed.update(kwargs)
                return Response()

        with patch.object(P.httpx, "AsyncClient", return_value=Client()):
            transcript = asyncio.run(P._hear_direct(
                b"audio", "take.webm", {
                    "provider": "deepgram",
                    "model": "nova-3",
                    "api_key": "deepgram-key",
                    "language": "auto",
                }
            ))

        self.assertEqual("你好 hello", transcript)
        self.assertEqual("https://api.deepgram.com/v1/listen", observed["url"])
        self.assertEqual(
            {"model": "nova-3", "smart_format": "true", "language": "multi"},
            observed["params"],
        )
        self.assertEqual("Token deepgram-key", observed["headers"]["Authorization"])

    def test_platform_key_inheritance_is_memory_only(self):
        config = {
            "llm": {"provider": "gemini", "api_key": ""},
            "image": {"provider": "together_image", "api_key": ""},
            "keys": {"gemini": "gemini-key", "together": "together-key"},
        }
        inherited = P._inherit_platform_keys(config)
        self.assertEqual("gemini-key", inherited["llm"]["api_key"])
        self.assertEqual("together-key", inherited["image"]["api_key"])
        self.assertEqual("together", P.platform_of("together_image"))

    def test_redaction_never_returns_provider_or_livekit_secrets(self):
        masked = P.redacted({
            "llm": {"provider": "openai", "api_key": "provider-secret"},
            "tts": {"provider": "system", "api_key": ""},
            "stt": {"provider": "mlx_whisper", "api_key": ""},
            "image": {"provider": "", "api_key": ""},
            "video": {"provider": "", "api_key": ""},
            "keys": {"openai": "platform-secret"},
            "live": {"api_key": "retired-secret"},
            "livekit": {"pilot_app_token": "pilot-secret"},
        })
        self.assertEqual("", masked["llm"]["api_key"])
        self.assertTrue(masked["llm"]["has_key"])
        self.assertEqual({"openai": ""}, masked["keys"])
        self.assertEqual({"openai": True}, masked["has_keys"])
        self.assertEqual("", masked["livekit"]["pilot_app_token"])
        self.assertTrue(masked["livekit"]["has_pilot_app_token"])
        self.assertNotIn("live", masked)

    def test_config_file_never_persists_absorbed_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            vault_path = os.path.join(directory, "vault.json")
            original_migrated = P._migrated[0]
            original_vault = credentials._TEST_VAULT_FILE
            credentials._TEST_VAULT_FILE = vault_path
            credentials._memo.clear()
            P._migrated[0] = False
            try:
                with patch.object(P, "CONFIG", config_path):
                    P._write_config_file({
                        **P.DEFAULTS,
                        "llm": {**P.DEFAULTS["llm"], "provider": "openai",
                                "api_key": "plain-secret"},
                    })
                    loaded = P.load()
                persisted = Path(config_path).read_text(encoding="utf-8")
            finally:
                credentials._TEST_VAULT_FILE = original_vault
                credentials._memo.clear()
                P._migrated[0] = original_migrated
            self.assertEqual("plain-secret", loaded["llm"]["api_key"])
            self.assertNotIn("plain-secret", persisted)
            self.assertIn(credentials.MARKER, persisted)


class ImageConfigSecurityTests(unittest.TestCase):
    def test_legacy_oauth_fields_are_removed_and_the_lane_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            vault_path = os.path.join(directory, "vault.json")
            original_migrated = P._migrated[0]
            original_pending = P._normalization_pending[0]
            original_vault = credentials._TEST_VAULT_FILE
            credentials._TEST_VAULT_FILE = vault_path
            credentials._memo.clear()
            P._migrated[0] = True
            P._normalization_pending[0] = False
            try:
                with patch.object(P, "CONFIG", config_path):
                    P._write_config_file({
                        **P.DEFAULTS,
                        "image": {
                            **P.DEFAULTS["image"],
                            "provider": "openai",
                            "model": "gpt-image-2-preview",
                            "base_url": "https://relay.example/v1",
                            "auth_method": "oauth2_user",
                            "credential_type": "access_token",
                            "api_key": "legacy-bearer-hidden-as-api-key",
                            "access_token": "legacy-access-secret",
                            "refresh_token": "legacy-refresh-secret",
                            "bearer": "legacy-literal-bearer-secret",
                            "metadata": {
                                "bearer": "legacy-nested-bearer-secret",
                            },
                            "auth": {
                                "selected_method": "oauth2",
                                "client_secret": "legacy-client-secret",
                            },
                        },
                    })
                    loaded = P.load()
                    persisted = Path(config_path).read_text(encoding="utf-8")
                    vault = Path(vault_path).read_text(encoding="utf-8") \
                        if Path(vault_path).exists() else ""
            finally:
                credentials._TEST_VAULT_FILE = original_vault
                credentials._memo.clear()
                P._migrated[0] = original_migrated
                P._normalization_pending[0] = original_pending

        image = loaded["image"]
        self.assertEqual("openai", image["provider"])
        self.assertEqual("gpt-image-2-preview", image["model"])
        self.assertEqual("api_key", image["auth_method"])
        self.assertEqual("", image["api_key"])
        self.assertEqual("", image["base_url"])
        for forbidden in (
                "access_token", "refresh_token", "bearer",
                "credential_type", "auth"):
            self.assertNotIn(forbidden, image)
        self.assertNotIn("bearer", image.get("metadata", {}))
        on_disk = persisted + vault
        for secret in (
                "legacy-access-secret", "legacy-refresh-secret",
                "legacy-client-secret", "legacy-bearer-hidden-as-api-key",
                "legacy-literal-bearer-secret",
                "legacy-nested-bearer-secret",
                "relay.example"):
            self.assertNotIn(secret, on_disk)
        with patch.object(P.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "exact supported image model"):
            asyncio.run(P.list_models("image", image))
        client.assert_not_called()

    def test_blank_strict_image_model_alone_gets_the_reviewed_default(self):
        for provider, expected in P.RECOMMENDED_IMAGE_MODELS.items():
            block = {"provider": provider, "model": "", "base_url": ""}
            with self.subTest(provider=provider):
                self.assertTrue(P._normalise_legacy_image_block(block))
                self.assertEqual(expected, block["model"])

    def test_every_image_provider_strips_legacy_origin_and_rejects_override(self):
        rows = P.catalog()["image"]
        for row in rows:
            provider = row["id"]
            block = {
                "provider": provider,
                "model": row.get("recommended_model", "saved-model"),
                "base_url": "https://legacy-relay.example/v1",
            }
            with self.subTest(provider=provider, phase="legacy migration"):
                self.assertTrue(P._normalise_legacy_image_block(block))
                self.assertEqual("", block["base_url"])

        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            with patch.object(P, "CONFIG", config_path):
                P._write_config_file(P.DEFAULTS)
                for row in rows:
                    provider = row["id"]
                    with self.subTest(provider=provider, phase="incoming save"), \
                         self.assertRaisesRegex(RuntimeError, "approved HTTPS"):
                        P.save({"image": {
                            "provider": provider,
                            "model": row.get("recommended_model", "saved-model"),
                            "base_url": "https://attacker.example/v1",
                        }})
                persisted = Path(config_path).read_text(encoding="utf-8")
        self.assertNotIn("attacker.example", persisted)
        self.assertNotIn("legacy-relay.example", persisted)

    def test_save_rejects_unsupported_image_auth_and_unknown_exact_model(self):
        cases = (
            {"provider": "openai", "model": "gpt-image-2",
             "auth_method": "oauth2_user", "access_token": "secret"},
            {"provider": "xai", "model": "grok-imagine-image-2.0",
             "auth": {"selected_method": "oauth2", "refresh_token": "secret"}},
            {"provider": "gemini", "model": "gemini-3.1-flash-image",
             "bearer": "literal-bearer-secret"},
            {"provider": "recraft", "model": "recraft-v3",
             "metadata": {"bearer": "nested-bearer-secret"}},
            {"provider": "openai", "model": "gpt-image-2-preview",
             "auth_method": "api_key"},
            {"provider": "xai", "model": "grok-imagine-image-2.0",
             "auth_method": "api_key", "base_url": "https://relay.example/v1"},
        )
        with tempfile.TemporaryDirectory() as directory:
            config_path = os.path.join(directory, "config.json")
            with patch.object(P, "CONFIG", config_path):
                P._write_config_file(P.DEFAULTS)
                for image in cases:
                    with self.subTest(image=image), self.assertRaises(RuntimeError):
                        P.save({"image": image})
                persisted = Path(config_path).read_text(encoding="utf-8")
        self.assertNotIn("secret", persisted)
        self.assertNotIn("literal-bearer-secret", persisted)
        self.assertNotIn("nested-bearer-secret", persisted)
        self.assertNotIn("relay.example", persisted)
        self.assertNotIn("gpt-image-2-preview", persisted)

    def test_redaction_drops_token_shaped_image_fields_at_every_depth(self):
        masked = P.redacted({
            "image": {
                "provider": "xai", "model": "grok-imagine-image-2.0",
                "api_key": "api-key-secret", "auth_method": "oauth2_user",
                "oauth_token": "oauth-secret",
                "bearer": "literal-bearer-secret",
                "metadata": {
                    "refreshToken": "refresh-secret",
                    "bearer": "nested-bearer-secret",
                    "auth_method": "oauth2",
                    "api_key": "nested-api-key-secret",
                },
                "auth": {"access_token": "access-secret"},
            },
        })
        encoded = json.dumps(masked)
        for secret in (
                "api-key-secret", "oauth-secret", "refresh-secret", "access-secret",
                "nested-api-key-secret", "literal-bearer-secret",
                "nested-bearer-secret"):
            self.assertNotIn(secret, encoded)
        self.assertNotIn("oauth_token", masked["image"])
        self.assertNotIn("bearer", masked["image"])
        self.assertNotIn("auth", masked["image"])
        self.assertNotIn("refreshToken", masked["image"].get("metadata", {}))
        self.assertNotIn("bearer", masked["image"].get("metadata", {}))
        self.assertEqual("api_key", masked["image"]["auth_method"])

    def test_direct_image_check_rejects_bearer_before_payload_builder(self):
        generated = AsyncMock()
        fake_media_gen = types.SimpleNamespace(generate_image=generated)
        secret = "direct-literal-bearer-secret"
        with patch.dict(sys.modules, {"media_gen": fake_media_gen}):
            result = asyncio.run(P.test("image", {
                "provider": "gemini",
                "model": "gemini-3.1-flash-image",
                "api_key": "provider-key",
                "bearer": secret,
            }))
        self.assertFalse(result["ok"])
        generated.assert_not_awaited()
        self.assertNotIn(secret, json.dumps(result))


class ModelCatalogueTests(unittest.TestCase):
    def test_image_catalog_marks_current_models_and_auth_capabilities(self):
        openai = P.spec("image", "openai")
        xai = P.spec("image", "xai")
        image_rows = P.catalog()["image"]

        self.assertEqual(
            {row["id"]: row["base"] for row in image_rows},
            P.PINNED_IMAGE_BASES,
        )
        self.assertTrue(all(
            base.startswith("https://") for base in P.PINNED_IMAGE_BASES.values()
        ))

        self.assertEqual("gpt-image-2", openai["recommended_model"])
        self.assertEqual(
            ["gpt-image-2", "gpt-image-1"],
            [model["id"] for model in openai["models"]],
        )
        self.assertEqual("grok-imagine-image-2.0", xai["recommended_model"])
        self.assertEqual(
            [
                "grok-imagine-image-2.0",
                "grok-imagine-image-quality",
                "grok-imagine-image",
            ],
            [model["id"] for model in xai["models"]],
        )
        for provider in (openai, xai):
            with self.subTest(provider=provider["id"]):
                self.assertEqual(
                    {"generation": True, "editing": True},
                    provider["capabilities"],
                )
                self.assertTrue(provider["auth"]["api_key"]["supported"])
                self.assertEqual(
                    "supported", provider["auth"]["api_key"]["status"]
                )
                self.assertTrue(provider["auth"]["oauth"]["reason"])
                self.assertTrue(all(
                    model["generation"] and model["editing"]
                    for model in provider["models"]
                ))
        self.assertFalse(openai["auth"]["oauth"]["supported"])
        self.assertEqual(
            "unsupported_by_public_inference_api",
            openai["auth"]["oauth"]["status"],
        )
        self.assertTrue(xai["auth"]["oauth"]["supported"])
        self.assertEqual("supported_via_grok_build_compatibility",
                         xai["auth"]["oauth"]["status"])
        self.assertEqual("global", xai["auth_scope"])
        self.assertEqual(["api_key", "oauth2"], xai["auth_modes"])
        self.assertEqual("auto", openai["image_options"]["default_size"])
        self.assertEqual("auto", openai["image_options"]["default_quality"])
        self.assertEqual(["1k", "2k"], xai["image_options"]["resolutions"])
        self.assertEqual(["low", "medium"], xai["image_options"]["qualities"])
        for kind, rows in P.catalog().items():
            matches = [row for row in rows if row["id"] == "xai"]
            if not matches:
                continue
            with self.subTest(kind=kind):
                self.assertEqual("global", matches[0]["auth_scope"])
                self.assertEqual(["api_key", "oauth2"], matches[0]["auth_modes"])
                self.assertTrue(matches[0]["auth"]["oauth"]["supported"])

    def test_language_model_filter_excludes_media_and_realtime_models(self):
        values = P._filter_models("llm", "openai", [
            "gpt-5-mini", "gpt-image-1", "gpt-realtime", "text-embedding-3",
        ])
        self.assertEqual(["gpt-5-mini"], values)

    def test_media_filters_accept_only_models_for_the_selected_modality(self):
        self.assertEqual(
            ["gpt-image-1", "gpt-image-2"],
            P._filter_models(
                "image", "openai",
                ["gpt-5-mini", "gpt-image-1", "gpt-image-2",
                 "gpt-image-1.5", "gpt-image-2-preview"],
            ),
        )
        self.assertEqual(
            ["grok-imagine-image", "grok-imagine-image-2.0",
             "grok-imagine-image-quality"],
            P._filter_models(
                "image", "xai",
                ["grok-4", "grok-imagine-video-1.5",
                 "grok-imagine-image-2.0", "grok-imagine-image",
                 "grok-imagine-image-quality", "grok-imagine-image-2.0-preview"],
            ),
        )
        self.assertEqual(
            ["gemini-3.1-flash-image"],
            P._filter_models("image", "gemini", [
                "gemini-3.1-flash", "gemini-3.1-flash-image", "imagen-4",
            ]),
        )
        self.assertEqual(
            ["sora-2"],
            P._filter_models("video", "openai", ["gpt-image-1", "sora-2"]),
        )
        self.assertEqual(
            ["veo-3.1-generate-preview"],
            P._filter_models("video", "gemini", [
                "gemini-3.1-flash-image", "veo-3.1-generate-preview",
            ]),
        )

    def test_system_voice_choices_are_presented_as_voices_not_models(self):
        with patch.object(
            P, "list_models", new=AsyncMock(return_value=["Ava", "Samantha"])
        ):
            choices = asyncio.run(P.list_choices("tts", {"provider": "system"}))
        self.assertEqual([], choices["models"])
        self.assertEqual(["Ava", "Samantha"], choices["voices"])

    def test_xai_image_discovery_uses_the_image_generation_catalogue(self):
        observed = {}

        class Response:
            status_code = 200

            @staticmethod
            def raise_for_status():
                return None

            @staticmethod
            def json():
                return {"models": [
                    {"id": "grok-4"},
                    {"id": "grok-imagine-video-1.5"},
                    {"id": "grok-imagine-image-2.0"},
                    {"id": "grok-imagine-image"},
                ]}

        class Client:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return None

            async def get(self, url, **kwargs):
                observed["url"] = url
                observed["headers"] = kwargs.get("headers")
                return Response()

        with patch.object(P.httpx, "AsyncClient", return_value=Client()), \
             patch.object(P, "_resolve_xai_auth", new=AsyncMock(return_value=(
                 P.XAI_API_BASE, {"Authorization": "Bearer global-xai-key"},
                 "global-xai-key", "api_key"))):
            models = asyncio.run(P.list_models("image", {
                "provider": "xai", "api_key": "xai-test-key",
            }))

        self.assertEqual(
            "https://api.x.ai/v1/image-generation-models", observed["url"]
        )
        self.assertEqual(
            {"Authorization": "Bearer global-xai-key"}, observed["headers"]
        )
        self.assertEqual(
            ["grok-imagine-image", "grok-imagine-image-2.0"], models
        )

    def test_image_discovery_rejects_auth_origin_and_model_before_client(self):
        cases = (
            {"provider": "openai", "model": "gpt-image-2",
             "api_key": "key", "auth_method": "oauth2_user"},
            {"provider": "xai", "model": "grok-imagine-image-2.0",
             "api_key": "key", "auth": {"selected_method": "oauth2"}},
            {"provider": "openai", "model": "gpt-image-2",
             "api_key": "key", "access_token": "not-an-api-key"},
            {"provider": "gemini", "model": "gemini-3.1-flash-image",
             "api_key": "key", "bearer": "literal-bearer-secret"},
            {"provider": "recraft", "model": "recraft-v3",
             "api_key": "key", "metadata": {"bearer": "nested-secret"}},
            {"provider": "xai", "model": "grok-imagine-image-2.0",
             "api_key": "key", "base_url": "https://relay.example/v1"},
            {"provider": "openai", "model": "gpt-image-2-preview",
             "api_key": "key"},
        )
        for config in cases:
            with self.subTest(config=config), \
                 patch.object(P.httpx, "AsyncClient") as client, \
                 self.assertRaises(RuntimeError):
                asyncio.run(P.list_models("image", config))
            client.assert_not_called()

    def test_every_image_discovery_origin_is_pinned_without_redirects(self):
        for row in P.catalog()["image"]:
            provider = row["id"]
            canonical = row["base"]
            config = {
                "provider": provider,
                "model": row.get("recommended_model", ""),
                "api_key": "provider-test-key",
                "auth_method": "api_key",
            }

            with self.subTest(provider=provider, phase="reject override"), \
                 patch.object(P.httpx, "AsyncClient") as client, \
                 self.assertRaisesRegex(RuntimeError, "approved HTTPS"):
                asyncio.run(P.list_models("image", {
                    **config,
                    "base_url": "https://attacker.example/v1",
                }))
            client.assert_not_called()

            observed = {}

            class Response:
                status_code = 200

                @staticmethod
                def raise_for_status():
                    return None

                @staticmethod
                def json():
                    if provider == "xai":
                        return {"models": [
                            {"id": "grok-imagine-image-2.0"},
                        ]}
                    if provider == "gemini":
                        return {"models": [{
                            "name": "models/gemini-3.1-flash-image",
                            "supportedGenerationMethods": ["generateContent"],
                        }]}
                    return {"data": []}

            class Client:
                async def __aenter__(self):
                    return self

                async def __aexit__(self, *_args):
                    return None

                async def get(self, url, **kwargs):
                    observed["url"] = url
                    observed["kwargs"] = kwargs
                    return Response()

            with self.subTest(provider=provider, phase="canonical request"), \
                 patch.object(
                     P.httpx, "AsyncClient", return_value=Client()
                 ) as client, \
                 patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                     return_value=(
                         P.XAI_API_BASE,
                         {"Authorization": "Bearer global-xai-key"},
                         "global-xai-key", "api_key"))):
                asyncio.run(P.list_models("image", {
                    **config,
                    "base_url": canonical + "/",
                }))

            expected_client = {"timeout": 20, "follow_redirects": False}
            if provider == "xai":
                expected_client["trust_env"] = False
            client.assert_called_once_with(**expected_client)
            expected_path = "/image-generation-models" \
                if provider == "xai" else "/models"
            self.assertEqual(canonical + expected_path, observed["url"])

    def test_openai_image_discovery_is_pinned_and_exact(self):
        observed = {}

        class Response:
            @staticmethod
            def raise_for_status():
                return None

            @staticmethod
            def json():
                return {"data": [
                    {"id": "gpt-image-2"},
                    {"id": "gpt-image-1"},
                    {"id": "gpt-image-2-preview"},
                    {"id": "gpt-image-1.5"},
                ]}

        class Client:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return None

            async def get(self, url, **kwargs):
                observed["url"] = url
                observed["headers"] = kwargs.get("headers")
                return Response()

        with patch.object(P.httpx, "AsyncClient", return_value=Client()) as client:
            models = asyncio.run(P.list_models("image", {
                "provider": "openai", "model": "gpt-image-2",
                "api_key": "openai-test-key",
                "base_url": "https://api.openai.com/v1/",
                "auth_method": "api_key",
            }))

        client.assert_called_once_with(timeout=20, follow_redirects=False)
        self.assertEqual("https://api.openai.com/v1/models", observed["url"])
        self.assertEqual(
            {"Authorization": "Bearer openai-test-key"}, observed["headers"]
        )
        self.assertEqual(["gpt-image-1", "gpt-image-2"], models)


class XaiDualAuthProviderTests(unittest.TestCase):
    class Response:
        def __init__(self, payload=None, content=b"", status=200):
            self._payload = payload or {}
            self.content = content
            self.status_code = status
            self.text = content.decode("utf-8", "replace") if content else ""

        def json(self):
            return self._payload

    class Client:
        response = None
        calls = []
        init = None

        def __init__(self, **kwargs):
            type(self).init = kwargs

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

        async def post(self, url, **kwargs):
            type(self).calls.append(("POST", url, kwargs))
            return type(self).response

        async def get(self, url, **kwargs):
            type(self).calls.append(("GET", url, kwargs))
            return type(self).response

    def setUp(self):
        self.Client.calls = []
        self.Client.init = None
        self.Client.response = None

    def _auth(self, mode, model="grok-4.6"):
        if mode == "oauth2":
            return (
                P.XAI_CLI_PROXY_BASE,
                {"Authorization": "Bearer oauth-token",
                 "X-XAI-Token-Auth": "xai-grok-cli",
                 "x-grok-client-version": "1.0.4",
                 "x-grok-client-identifier": "grok-shell",
                 "x-authenticateresponse": "authenticate-response",
                 "x-grok-client-mode": "interactive",
                 "User-Agent": "grok-shell/1.0.4 (macos; aarch64)",
                 "x-grok-model-override": model},
                "oauth-token", mode,
            )
        return (P.XAI_API_BASE,
                {"Authorization": "Bearer api-key-token"},
                "api-key-token", mode)

    def test_api_key_chat_and_search_use_public_api_without_cli_headers(self):
        cases = (
            (False, "/chat/completions", {
                "choices": [{"message": {"content": "plain answer"}}],
            }, "plain answer"),
            (True, "/responses", {
                "output": [{"type": "message", "role": "assistant",
                            "content": [{"type": "output_text",
                                         "text": "searched",
                                         "annotations": [
                                             {"type": "url_citation",
                                              "url": "https://docs.x.ai/source"},
                                             {"type": "url_citation",
                                              "url": "http://unsafe.example"},
                                         ]}]}],
            }, "searched"),
        )
        for search, path, payload, expected in cases:
            self.Client.calls = []
            self.Client.response = self.Response(payload=payload)
            config = {"provider": "xai", "model": "grok-4.6",
                      "web_search": search, "api_key": "ignored-lane-key"}
            with self.subTest(search=search), \
                 patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                     return_value=self._auth("api_key"))), \
                 patch.object(P.httpx, "AsyncClient", self.Client):
                text = asyncio.run(P._xai_chat_direct(
                    [{"role": "user", "content": "hello"}], config, "be brief"))
            method, url, kwargs = self.Client.calls[0]
            self.assertEqual("POST", method)
            self.assertEqual(P.XAI_API_BASE + path, url)
            self.assertEqual("Bearer api-key-token",
                             kwargs["headers"]["Authorization"])
            self.assertNotIn("X-XAI-Token-Auth", kwargs["headers"])
            self.assertNotIn("x-authenticateresponse", kwargs["headers"])
            self.assertNotIn("Accept", kwargs["headers"])
            self.assertEqual("grok-4.6", kwargs["json"]["model"])
            self.assertIn(expected, text)
            if search:
                self.assertEqual([{"type": "web_search"}],
                                 kwargs["json"]["tools"])
                self.assertNotIn("unsafe.example", text)
                self.assertIn("https://docs.x.ai/source", text)
            self.assertIs(self.Client.init["follow_redirects"], False)
            self.assertIs(self.Client.init["trust_env"], False)

    def test_oauth_chat_uses_exact_cli_proxy_contract_and_streaming(self):
        event = {"choices": [{"delta": {"content": "oauth answer"}}]}
        stream = f"data: {json.dumps(event)}\n\ndata: [DONE]\n".encode()
        self.Client.response = self.Response(content=stream)
        with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                 return_value=self._auth("oauth2", "grok-4.6"))), \
             patch.object(P.httpx, "AsyncClient", self.Client):
            text = asyncio.run(P._xai_chat_direct(
                [{"role": "user", "content": "hello"}],
                {"provider": "xai", "model": "grok-4.6"}))
        _method, url, kwargs = self.Client.calls[0]
        self.assertEqual(
            "https://cli-chat-proxy.grok.com/v1/chat/completions", url)
        self.assertEqual("grok-build", kwargs["json"]["model"])
        self.assertIs(kwargs["json"]["stream"], True)
        self.assertEqual("xai-grok-cli",
                         kwargs["headers"]["X-XAI-Token-Auth"])
        self.assertEqual("grok-4.6",
                         kwargs["headers"]["x-grok-model-override"])
        self.assertEqual("1.0.4",
                         kwargs["headers"]["x-grok-client-version"])
        self.assertEqual("grok-shell",
                         kwargs["headers"]["x-grok-client-identifier"])
        self.assertEqual("authenticate-response",
                         kwargs["headers"]["x-authenticateresponse"])
        self.assertEqual("interactive",
                         kwargs["headers"]["x-grok-client-mode"])
        self.assertEqual("grok-shell/1.0.4 (macos; aarch64)",
                         kwargs["headers"]["User-Agent"])
        self.assertEqual("text/event-stream", kwargs["headers"]["Accept"])
        self.assertEqual("oauth answer", text)

    def test_oauth_web_search_uses_proxy_responses_and_safe_final_payload(self):
        completed = {
            "type": "response.completed",
            "response": {"output": [{
                "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "fresh result",
                             "annotations": [{"type": "url_citation",
                                              "url": "https://x.ai/news"}]}],
            }]},
        }
        stream = f"data: {json.dumps(completed)}\n\ndata: [DONE]\n".encode()
        self.Client.response = self.Response(content=stream)
        with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                 return_value=self._auth("oauth2", "grok-4.6"))), \
             patch.object(P.httpx, "AsyncClient", self.Client):
            text = asyncio.run(P._xai_chat_direct(
                [{"role": "user", "content": "latest news"}],
                {"provider": "xai", "model": "grok-4.6",
                 "web_search": True}))
        _method, url, kwargs = self.Client.calls[0]
        self.assertEqual(
            "https://cli-chat-proxy.grok.com/v1/responses", url)
        self.assertEqual("grok-build", kwargs["json"]["model"])
        self.assertEqual([{"type": "web_search"}], kwargs["json"]["tools"])
        self.assertIs(kwargs["json"]["stream"], True)
        self.assertEqual("text/event-stream", kwargs["headers"]["Accept"])
        self.assertIn("fresh result", text)
        self.assertIn("https://x.ai/news", text)

    def test_oauth_model_choices_are_fixed_and_never_probe_assumed_route(self):
        with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                 return_value=self._auth("oauth2", "grok-4.6"))), \
             patch.object(P.httpx, "AsyncClient") as client:
            models = asyncio.run(P.list_models(
                "llm", {"provider": "xai", "model": "grok-4.6"}))
        self.assertEqual(list(P.XAI_OAUTH_LLM_MODELS), models)
        client.assert_not_called()

    def test_voice_and_transcription_use_api_origin_in_both_modes(self):
        for mode in ("api_key", "oauth2"):
            with self.subTest(mode=mode, lane="tts"):
                self.Client.calls = []
                audio = base64.b64encode(b"mock-mp3").decode()
                self.Client.response = self.Response(payload={
                    "audio": audio, "content_type": "audio/mpeg",
                    "audio_timestamps": {
                        "graph_chars": ["h", "i"],
                        "graph_times": [[0, .1], [.1, .2]],
                    },
                })
                direct = (P.XAI_API_BASE,
                          {"Authorization": f"Bearer {mode}-token"},
                          f"{mode}-token", mode)
                with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                         return_value=direct)), \
                     patch.object(P.httpx, "AsyncClient", self.Client), \
                     patch.object(P, "_ff", return_value=np.zeros(10, np.float32)):
                    _samples, alignment = asyncio.run(P._speak_direct(
                        "hi", {"provider": "xai", "voice": "eve",
                               "language": "en-US"}))
                _method, url, kwargs = self.Client.calls[0]
                self.assertEqual("https://api.x.ai/v1/tts", url)
                self.assertEqual({"Authorization": f"Bearer {mode}-token",
                                  "Content-Type": "application/json"},
                                 kwargs["headers"])
                self.assertEqual({
                    "text": "hi", "voice_id": "eve", "language": "en-US",
                    "with_timestamps": True,
                }, kwargs["json"])
                self.assertEqual("chars", alignment[0])
                self.assertIs(self.Client.init["follow_redirects"], False)
                self.assertIs(self.Client.init["trust_env"], False)

            with self.subTest(mode=mode, lane="stt"):
                self.Client.calls = []
                self.Client.response = self.Response(payload={"text": "heard"})
                with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                         return_value=direct)), \
                     patch.object(P.httpx, "AsyncClient", self.Client):
                    text = asyncio.run(P._hear_direct(
                        b"audio", "take.webm", {"provider": "xai"}))
                _method, url, kwargs = self.Client.calls[0]
                self.assertEqual("https://api.x.ai/v1/stt", url)
                self.assertEqual({"Authorization": f"Bearer {mode}-token"},
                                 kwargs["headers"])
                self.assertEqual({}, kwargs["data"])
                self.assertEqual("heard", text)
                self.assertIs(self.Client.init["follow_redirects"], False)
                self.assertIs(self.Client.init["trust_env"], False)

    def test_xai_transcription_explicit_language_sends_formatting_fields(self):
        self.Client.response = self.Response(payload={"text": "bonjour"})
        direct = (P.XAI_API_BASE, {"Authorization": "Bearer token"},
                  "token", "api_key")
        with patch.object(P, "_resolve_xai_auth", new=AsyncMock(
                 return_value=direct)), \
             patch.object(P.httpx, "AsyncClient", self.Client):
            text = asyncio.run(P._hear_direct(
                b"audio", "take.webm",
                {"provider": "xai", "language": "fr"}))

        _method, url, kwargs = self.Client.calls[0]
        self.assertEqual("https://api.x.ai/v1/stt", url)
        self.assertEqual({"language": "fr", "format": "true"}, kwargs["data"])
        self.assertEqual("bonjour", text)

    def test_xai_transcription_rejects_chinese_before_auth_or_network(self):
        resolver = AsyncMock()
        with patch.object(P, "_resolve_xai_auth", new=resolver), \
             patch.object(P.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "does not support Chinese"):
            asyncio.run(P._hear_direct(
                b"audio", "take.webm",
                {"provider": "xai", "language": "zh"}))

        resolver.assert_not_awaited()
        client.assert_not_called()

    def test_xai_tts_rejects_character_or_utf8_byte_overflow_pre_network(self):
        for text in ("x" * 15_001, "你" * 5_001):
            resolver = AsyncMock()
            with self.subTest(length=len(text)), \
                 patch.object(P, "_resolve_xai_auth", new=resolver), \
                 patch.object(P.httpx, "AsyncClient") as client, \
                 self.assertRaisesRegex(RuntimeError, "15,000"):
                asyncio.run(P._speak_direct(
                    text, {"provider": "xai", "voice": "eve",
                           "language": "auto"}))
            resolver.assert_not_awaited()
            client.assert_not_called()

    def test_xai_chat_bounds_total_input_and_oauth_model_before_client(self):
        resolver = AsyncMock()
        messages = [
            {"role": "user", "content": "x" * 128_000}
            for _ in range(8)
        ]
        with patch.object(P, "_resolve_xai_auth", new=resolver), \
             patch.object(P.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "input is too large"):
            asyncio.run(P._xai_chat_direct(
                messages, {"provider": "xai", "model": "grok-4.6"}))
        resolver.assert_not_awaited()
        client.assert_not_called()

        resolver = AsyncMock(return_value=self._auth(
            "oauth2", "unreviewed-grok-model"))
        with patch.object(P, "_resolve_xai_auth", new=resolver), \
             patch.object(P.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "supported Grok model"):
            asyncio.run(P._xai_chat_direct(
                [{"role": "user", "content": "hello"}],
                {"provider": "xai", "model": "unreviewed-grok-model"}))
        resolver.assert_awaited_once()
        client.assert_not_called()

    def test_xai_stream_reader_stops_at_hard_response_cap(self):
        class Upstream:
            status_code = 200
            headers = {}

            @property
            def content(self):
                raise RuntimeError("stream was not buffered")

            async def aiter_bytes(self):
                yield b"abc"
                yield b"def"

        class StreamContext:
            async def __aenter__(self):
                return Upstream()

            async def __aexit__(self, *_args):
                return False

        class StreamClient:
            def stream(self, method, url, **kwargs):
                self.call = (method, url, kwargs)
                return StreamContext()

        client = StreamClient()
        with self.assertRaisesRegex(RuntimeError, "oversized"):
            asyncio.run(P._xai_bounded_request(
                client, "POST", "https://api.x.ai/v1/tts",
                max_bytes=5, action="test response"))
        self.assertEqual("POST", client.call[0])

    def test_xai_stream_reader_drops_consumed_content_encoding_headers(self):
        decoded = b'{"ok":true}'

        class Upstream:
            status_code = 200
            headers = {
                "content-encoding": "gzip",
                "content-length": "100",
                "transfer-encoding": "chunked",
                "x-provider-request": "retained",
            }

            async def aiter_bytes(self):
                # httpx has already decompressed this payload.
                yield decoded

        class StreamContext:
            async def __aenter__(self):
                return Upstream()

            async def __aexit__(self, *_args):
                return False

        class StreamClient:
            def stream(self, method, url, **kwargs):
                return StreamContext()

        response = asyncio.run(P._xai_bounded_request(
            StreamClient(), "POST", "https://api.x.ai/v1/tts",
            max_bytes=1024, action="test response"))

        self.assertEqual({"ok": True}, response.json())
        self.assertNotIn("content-encoding", response.headers)
        self.assertNotIn("transfer-encoding", response.headers)
        self.assertEqual(str(len(decoded)), response.headers["content-length"])
        self.assertEqual("retained", response.headers["x-provider-request"])


class DirectRoutingTests(unittest.TestCase):
    def setUp(self):
        P._routes.clear()

    def test_chat_success_and_failure_update_the_route_receipt(self):
        config = {"provider": "ollama", "model": "qwen-test:latest"}
        with patch.object(P, "_chat_direct", new=AsyncMock(return_value="direct")):
            result = asyncio.run(P.chat([{"role": "user", "content": "hello"}], config))
        self.assertEqual("direct", result)
        self.assertEqual("success", P.last_route("llm")["state"])
        self.assertEqual("qwen-test:latest", P.last_route("llm")["model"])

        with patch.object(
            P, "_chat_direct", new=AsyncMock(side_effect=RuntimeError("offline"))
        ):
            with self.assertRaisesRegex(RuntimeError, "offline"):
                asyncio.run(P.chat([], config))
        self.assertEqual("failed", P.last_route("llm")["state"])

    def test_speech_success_and_failure_update_the_route_receipt(self):
        config = {"provider": "system", "voice": "Samantha", "speed": 1.0}
        output = (np.zeros(240, np.float32), None)
        with patch.object(P, "_speak_direct", new=AsyncMock(return_value=output)):
            samples, alignment = asyncio.run(P.speak("hello", config))
        self.assertEqual(240, samples.size)
        self.assertIsNone(alignment)
        self.assertEqual("success", P.last_route("tts")["state"])

        with patch.object(
            P, "_speak_direct", new=AsyncMock(side_effect=RuntimeError("voice offline"))
        ):
            with self.assertRaisesRegex(RuntimeError, "voice offline"):
                asyncio.run(P.speak("hello", config))
        self.assertEqual("failed", P.last_route("tts")["state"])

    def test_transcription_success_and_failure_update_the_route_receipt(self):
        config = {"provider": "mlx_whisper", "model": P.DEFAULTS["stt"]["model"]}
        with patch.object(P, "_hear_direct", new=AsyncMock(return_value="heard")):
            self.assertEqual("heard", asyncio.run(P.hear(b"audio", "take.wav", config)))
        self.assertEqual("success", P.last_route("stt")["state"])

        with patch.object(
            P, "_hear_direct", new=AsyncMock(side_effect=RuntimeError("decoder offline"))
        ):
            with self.assertRaisesRegex(RuntimeError, "decoder offline"):
                asyncio.run(P.hear(b"audio", "take.wav", config))
        self.assertEqual("failed", P.last_route("stt")["state"])

    def test_local_mlx_transcription_uses_a_private_temporary_take(self):
        observed = {}

        def run_ffmpeg(command, **_kwargs):
            Path(command[-1]).write_bytes(b"wav")
            return types.SimpleNamespace(returncode=0, stderr="")

        def read_audio(path, **kwargs):
            observed["path"] = path
            observed["exists"] = os.path.isfile(path)
            observed["read_kwargs"] = kwargs
            return np.zeros(16000, np.float32), 16000

        def transcribe(audio, **kwargs):
            observed["audio"] = audio
            observed["kwargs"] = kwargs
            return {"text": "local transcript"}

        fake_mlx = types.SimpleNamespace(transcribe=transcribe)
        fake_soundfile = types.SimpleNamespace(read=read_audio)
        config = {
            "provider": "mlx_whisper", "model": P.DEFAULTS["stt"]["model"],
            "language": "auto",
        }
        with patch.dict(sys.modules, {
                 "mlx_whisper": fake_mlx, "soundfile": fake_soundfile,
             }), \
             patch.object(P, "resolve_mlx_whisper_model",
                          return_value="/bundled/whisper-small-mlx-4bit"), \
             patch.object(P.subprocess, "run", side_effect=run_ffmpeg):
            result = asyncio.run(P._hear_direct(b"take", "voice.webm", config))
        self.assertEqual("local transcript", result)
        self.assertTrue(observed["exists"])
        self.assertFalse(os.path.exists(observed["path"]))
        self.assertEqual("float32", observed["read_kwargs"]["dtype"])
        self.assertEqual((16000,), observed["audio"].shape)
        self.assertIsNone(observed["kwargs"]["language"])
        self.assertEqual(
            "/bundled/whisper-small-mlx-4bit",
            observed["kwargs"]["path_or_hf_repo"],
        )

    def test_local_mlx_wav_input_never_overwrites_its_source(self):
        observed = {}

        def run_ffmpeg(command, **_kwargs):
            observed["source"] = command[command.index("-i") + 1]
            observed["output"] = command[-1]
            self.assertNotEqual(observed["source"], observed["output"])
            Path(observed["output"]).write_bytes(b"decoded")
            return types.SimpleNamespace(returncode=0, stderr="")

        fake_mlx = types.SimpleNamespace(
            transcribe=lambda *_args, **_kwargs: {"text": "wav transcript"}
        )
        fake_soundfile = types.SimpleNamespace(
            read=lambda *_args, **_kwargs: (np.zeros(16000, np.float32), 16000)
        )
        config = {
            "provider": "mlx_whisper", "model": P.DEFAULTS["stt"]["model"],
            "language": "en",
        }
        with patch.dict(sys.modules, {
                 "mlx_whisper": fake_mlx, "soundfile": fake_soundfile,
             }), \
             patch.object(P, "resolve_mlx_whisper_model",
                          return_value="/bundled/whisper-small-mlx-4bit"), \
             patch.object(P.subprocess, "run", side_effect=run_ffmpeg):
            result = asyncio.run(P._hear_direct(b"wav", "known.wav", config))
        self.assertEqual("wav transcript", result)
        self.assertTrue(observed["source"].endswith("input.wav"))
        self.assertTrue(observed["output"].endswith("decoded.wav"))

    def test_macos_system_speech_uses_the_selected_voice_and_speed(self):
        observed = {}

        def say(command, **_kwargs):
            observed["command"] = command
            Path(command[command.index("-o") + 1]).write_bytes(b"aiff")
            return types.SimpleNamespace(returncode=0, stderr="")

        expected = np.zeros(120, np.float32)
        with patch.object(P.subprocess, "run", side_effect=say), \
             patch.object(P, "_ff", return_value=expected):
            result = P._system_say("Hello", "Samantha", 1.25)
        self.assertIs(result, expected)
        self.assertIn("Samantha", observed["command"])
        self.assertEqual("225", observed["command"][observed["command"].index("-r") + 1])
        self.assertEqual("Hello", observed["command"][-1])


class ErrorSafetyTests(unittest.TestCase):
    def test_provider_errors_redact_bearers_and_api_keys(self):
        text = P.safe_error(
            "Authorization: Bearer example-sensitive-value api_key=private-value "
            "bearer: literal-bearer-value"
        )
        self.assertNotIn("sensitive-value", text)
        self.assertNotIn("private-value", text)
        self.assertNotIn("literal-bearer-value", text)
        self.assertIn("[redacted]", text)

    def test_failure_hint_names_common_actionable_causes(self):
        self.assertEqual("the provider rejected the API key", P.failure_hint("HTTP 401"))
        self.assertEqual("the provider is rate-limiting", P.failure_hint("HTTP 429"))
        self.assertEqual("the request timed out", P.failure_hint("request timed out"))
        self.assertEqual("the endpoint is unreachable", P.failure_hint("connect failed"))
        self.assertEqual("", P.failure_hint("something novel"))


if __name__ == "__main__":
    unittest.main()
