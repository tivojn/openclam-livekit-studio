"""Direct PTT and realtime-dictation contracts for standalone OpenClam."""
import asyncio
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import providers


class DirectDictationDefaults(unittest.TestCase):
    def test_local_whisper_is_the_fresh_default(self):
        self.assertEqual("mlx_whisper", providers.DEFAULTS["stt"]["provider"])
        self.assertEqual(
            "mlx-community/whisper-small-mlx-4bit",
            providers.DEFAULTS["stt"]["model"],
        )
        self.assertEqual("mlx_whisper", providers.PROVIDERS["stt"][0]["id"])
        self.assertEqual(
            [providers.MLX_WHISPER_MODEL_ID],
            asyncio.run(providers.list_models("stt", providers.DEFAULTS["stt"])),
        )

    def test_public_model_id_resolves_to_a_checked_packaged_directory(self):
        config = b'{"fixture": true}'
        weights = b"small offline weights"
        records = {
            "config.json": {
                "size": len(config), "sha256": hashlib.sha256(config).hexdigest(),
            },
            "weights.npz": {
                "size": len(weights), "sha256": hashlib.sha256(weights).hexdigest(),
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "models" / providers.MLX_WHISPER_MODEL_DIR
            bundle.mkdir(parents=True)
            (bundle / "config.json").write_bytes(config)
            (bundle / "weights.npz").write_bytes(weights)
            with mock.patch.object(providers, "MLX_WHISPER_FILES", records):
                manifest = providers._expected_mlx_whisper_manifest()
            (bundle / providers.MLX_WHISPER_MANIFEST).write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            with mock.patch.object(providers, "CODE_ROOT", str(root)), \
                 mock.patch.object(providers, "MLX_WHISPER_FILES", records), \
                 mock.patch.object(providers, "_verified_mlx_models", {}):
                resolved = providers.resolve_mlx_whisper_model(
                    providers.MLX_WHISPER_MODEL_ID
                )
        self.assertEqual(str(bundle), resolved)

    def test_missing_bundle_fails_before_mlx_can_download_a_repository(self):
        transcribe = mock.Mock(side_effect=AssertionError("must not be called"))
        fake_mlx = mock.Mock(transcribe=transcribe)
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(providers, "CODE_ROOT", directory), \
             mock.patch.dict(sys.modules, {"mlx_whisper": fake_mlx}):
            with self.assertRaisesRegex(RuntimeError, "PTT never downloads models"):
                asyncio.run(providers._hear_direct(
                    b"take", "voice.webm", providers.DEFAULTS["stt"]
                ))
        transcribe.assert_not_called()

    def test_unbundled_public_model_id_is_rejected_without_lookup(self):
        with self.assertRaisesRegex(RuntimeError, "runtime model downloads are disabled"):
            providers.resolve_mlx_whisper_model(
                "mlx-community/whisper-large-v3-turbo"
            )

    def test_staging_manifest_is_pinned_to_exact_downloads(self):
        manifest = json.loads((
            ROOT / "scripts" / "whisper-small-mlx-4bit.manifest.json"
        ).read_text(encoding="utf-8"))
        self.assertEqual(providers._expected_mlx_whisper_manifest(), manifest)
        self.assertEqual(
            {"config.json", "weights.npz", "LICENSE.openai-whisper-MIT.txt"},
            set(manifest["files"]),
        )
        self.assertEqual(
            providers.MLX_WHISPER_LICENSE_REVISION,
            manifest["license_source"]["revision"],
        )
        script = (ROOT / "scripts" / "fetch-face-model.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(providers.MLX_WHISPER_MODEL_REVISION, script)
        self.assertIn("$WHISPER_REVISION/$name?download=true", script)
        self.assertIn("$temp_base/openclam-whisper-stage.XXXXXX", script)
        self.assertNotIn('$STAGE_DIR/.whisper-small-mlx-4bit.XXXXXX', script)
        self.assertIn("verify_model_stage_layout", script)
        self.assertIn("LICENSE.openai-whisper-MIT.txt", script)
        self.assertNotIn("snapshot_download", script)

    def test_soniox_is_an_explicit_direct_realtime_choice(self):
        soniox = providers.spec("stt", "soniox")
        self.assertTrue(soniox["key"])
        self.assertFalse(soniox.get("managed", False))

    def test_soniox_config_normalises_to_a_realtime_model(self):
        config = providers._soniox_config(
            {"api_key": "key", "model": "stt-async-v5", "language": "ko"}
        )
        self.assertEqual("stt-rt-v5", config["model"])
        self.assertEqual(["ko"], config["language_hints"])
        self.assertNotIn(
            "language_hints",
            providers._soniox_config({"api_key": "key", "language": "auto"}),
        )

    def test_empty_audio_validation_proves_auth_but_other_errors_escape(self):
        async def validate(error):
            with mock.patch.object(providers, "_soniox_stream", side_effect=error):
                return await providers._soniox_validate({"api_key": "key"})

        self.assertTrue(asyncio.run(validate(RuntimeError("No audio received."))))
        with self.assertRaisesRegex(RuntimeError, "Incorrect API key"):
            asyncio.run(validate(RuntimeError("Incorrect API key provided.")))

    def test_batch_soniox_uses_the_same_socket_and_records_the_route(self):
        take = b"a" * 70_000
        config = {
            "provider": "soniox", "api_key": "provider-key",
            "model": "stt-rt-v5", "language": "auto",
        }
        stream = mock.AsyncMock(return_value="heard clearly")
        with mock.patch.object(providers, "_soniox_stream", new=stream):
            text = asyncio.run(providers.hear(take, "take.webm", config))
        self.assertEqual("heard clearly", text)
        sent_config, frames = stream.await_args.args
        self.assertEqual("stt-rt-v5", sent_config["model"])
        self.assertEqual([65_536, 4_464], [len(frame) for frame in frames])
        self.assertEqual("success", providers.last_route("stt")["state"])

    def test_model_listing_validates_soniox_before_returning_the_choice(self):
        config = {
            "provider": "soniox", "api_key": "provider-key",
            "model": "stt-rt-v5",
        }
        with mock.patch.object(
            providers, "_soniox_validate", new=mock.AsyncMock(return_value=True)
        ) as validate:
            models = asyncio.run(providers.list_models("stt", config))
        validate.assert_awaited_once_with(config)
        self.assertEqual(["stt-rt-v5"], models)


class LocalStreamBridgeContract(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "server" / "app.py").read_text(encoding="utf-8")

    def test_stream_reads_only_the_selected_direct_soniox_lane(self):
        marker = self.source.index("def _soniox_stream_config")
        window = self.source[marker:marker + 500]
        self.assertIn('config.get("provider") != "soniox"', window)
        self.assertIn('not config.get("api_key")', window)
        self.assertIn("P._soniox_config(config)", window)
        self.assertNotIn("global_default", window)

    def test_websocket_is_local_auth_protected_and_ptt_batch_route_remains(self):
        self.assertIn('@app.post("/stt")', self.source)
        self.assertIn('@app.websocket("/stt/stream")', self.source)
        marker = self.source.index('@app.websocket("/stt/stream")')
        window = self.source[marker:marker + 700]
        self.assertIn("compare_digest", window)
        self.assertIn("_client_token(client)", window)

    def test_websocket_runtime_dependency_is_pinned(self):
        for name in ("requirements-backend.txt", "requirements-electron.txt"):
            self.assertIn("websockets", (ROOT / name).read_text(encoding="utf-8"))

    def test_startup_warmup_resolves_the_bundled_model_before_transcribing(self):
        marker = self.source.index("def _warm()")
        window = self.source[marker:marker + 1200]
        self.assertIn("P.resolve_mlx_whisper_model", window)
        self.assertNotIn('path_or_hf_repo=cfg["stt"]["model"]', window)


if __name__ == "__main__":
    unittest.main()
