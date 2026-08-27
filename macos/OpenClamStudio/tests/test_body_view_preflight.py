"""Provider-cost and transaction regressions for body view preflights."""

import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body


class BodyViewPreflightTests(unittest.TestCase):
    def test_side_alpha_retries_once_then_stops_before_back_and_preserves_front(self):
        config = {
            "provider": "openai", "model": "gpt-image-2", "api_key": "x",
        }
        public = {
            "name": "openai", "title": "OpenAI Images",
            "model": "gpt-image-2", "route": "direct:openai", "direct": True,
        }

        def generate(_prompt, _references, _lane, **options):
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((180, 120, 3), 160, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            installed = os.path.join(directory, "body")
            os.makedirs(installed)
            sentinel = os.path.join(installed, "approved-body.txt")
            with open(sentinel, "w") as handle:
                handle.write("keep approved body")

            def cutout(_source, destination, **_options):
                rgba = np.zeros((180, 120, 4), np.uint8)
                rgba[10:170, 20:100, :3] = 160
                rgba[10:170, 20:100, 3] = 255
                return bool(cv2.imwrite(destination, rgba))

            def reject_alpha(_source, rgba):
                return rgba, {
                    "valid": False,
                    "reason": "floor shadow",
                }

            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), mock.patch.object(
                            body.media_gen, "generate_image_edit_sync",
                            side_effect=generate) as provider_call, mock.patch.object(
                            body, "_preflight_front_source",
                            return_value={"valid": True}), mock.patch.object(
                                body.cutout, "render", side_effect=cutout), \
                    mock.patch.object(
                        body.body_alpha, "refine", side_effect=reject_alpha), \
                    mock.patch.object(body, "_install_sources") as install_call:
                with self.assertRaisesRegex(
                        body.GeneratedBodyAlphaError, "floor shadow"):
                    body.build(
                        directory,
                        {"style": "editorial", "pose": "relaxed"},
                        log=lambda _message: None)

            # Front is accepted once. Side is rejected twice. Back is never
            # requested and the installed body is never touched.
            self.assertEqual(3, provider_call.call_count)
            install_call.assert_not_called()
            self.assertTrue(os.path.isfile(sentinel))
            with open(sentinel) as handle:
                self.assertEqual("keep approved body", handle.read())
            cache = os.path.join(directory, ".body-cache")
            self.assertTrue(os.path.isfile(os.path.join(cache, "signature")))
            self.assertTrue(os.path.isfile(os.path.join(cache, "source-front.png")))
            self.assertFalse(os.path.exists(os.path.join(cache, "source-side.png")))
            self.assertFalse(os.path.exists(os.path.join(cache, "source-back.png")))
            attempts = os.listdir(os.path.join(
                directory, "diag", "body-rejections"))
            self.assertEqual(
                2, len([name for name in attempts if name.endswith("-side-alpha")]))

    def test_back_first_rejection_then_pass_preserves_front_and_side(self):
        config = {
            "provider": "openai", "model": "gpt-image-2", "api_key": "x",
        }
        public = {
            "name": "openai", "title": "OpenAI Images",
            "model": "gpt-image-2", "route": "direct:openai", "direct": True,
        }
        provider_calls = []

        def generate(prompt, references, _lane, **options):
            provider_calls.append({
                "prompt": prompt,
                "references": tuple(references),
                "file_name": options["file_name"],
            })
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            value = 30 + len(provider_calls) * 20
            cv2.imwrite(path, np.full((180, 120, 3), value, np.uint8))
            return path

        back_gates = []

        def preflight(_avatar_dir, _source, view, **_options):
            if view == "back":
                back_gates.append(view)
                if len(back_gates) == 1:
                    raise body.GeneratedBodyAlphaError(
                        "neutral floor or contact shadow remains; "
                        "white/off-white subject detail is ambiguous against "
                        "the plate; shoe reflection touches the heel")
            return {"valid": True}

        installed_sources = {}

        def install(_avatar_dir, sources, *_args, **_kwargs):
            for view, source in sources.items():
                with open(source, "rb") as handle:
                    installed_sources[view] = handle.read()
            return {"installed": True}

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), mock.patch.object(
                        body.media_gen, "generate_image_edit_sync",
                        side_effect=generate) as provider_call, mock.patch.object(
                            body, "_preflight_front_source",
                            return_value={"valid": True}), mock.patch.object(
                                body, "_preflight_alpha_source",
                                side_effect=preflight) as alpha_gate, \
                    mock.patch.object(
                        body, "_install_sources", side_effect=install):
                result = body.build(
                    directory,
                    {"style": "editorial", "pose": "relaxed"},
                    log=lambda _message: None)

            self.assertEqual({"installed": True}, result)
            self.assertEqual(4, provider_call.call_count)
            self.assertEqual(3, alpha_gate.call_count)
            self.assertEqual(["back", "back"], back_gates)
            self.assertEqual(
                ["body-source-front", "body-source-side", "body-source-back",
                 "body-source-back-alpha-retry"],
                [call["file_name"] for call in provider_calls])
            # Both back calls see the exact accepted front cache path, and no
            # regeneration touched either accepted source.
            self.assertEqual(
                provider_calls[2]["references"], provider_calls[3]["references"])
            self.assertEqual(3, len(installed_sources))
            self.assertFalse(os.path.exists(os.path.join(directory, ".body-cache")))

            original = provider_calls[2]["prompt"]
            retried = provider_calls[3]["prompt"]
            self.assertNotIn("ALPHA QA RETRY", original)
            self.assertIn("ALPHA QA RETRY", retried)
            self.assertIn("Remove every floor, wall, contact", retried)
            self.assertIn("clearly non-white material", retried)
            self.assertIn("footwear dark, matte, and non-reflective", retried)
            self.assertLessEqual(
                len(retried.encode("utf-8")), body.FULL_BODY_PROMPT_MAX_BYTES)

    def test_two_rejected_backs_fail_without_losing_resumable_front_and_side(self):
        config = {
            "provider": "openai", "model": "gpt-image-2", "api_key": "x",
        }
        public = {
            "name": "openai", "title": "OpenAI Images",
            "model": "gpt-image-2", "route": "direct:openai", "direct": True,
        }
        generated_names = []

        def generate(_prompt, _references, _lane, **options):
            generated_names.append(options["file_name"])
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            value = 25 + len(generated_names) * 30
            cv2.imwrite(path, np.full((180, 120, 3), value, np.uint8))
            return path

        reject_back = {"enabled": True}
        back_gate_count = []

        def preflight(_avatar_dir, _source, view, **_options):
            if view == "back":
                back_gate_count.append(view)
                if reject_back["enabled"]:
                    raise body.GeneratedBodyAlphaError(
                        "neutral floor, wall, or contact shadow remains")
            return {"valid": True}

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            installed = os.path.join(directory, "body")
            os.makedirs(installed)
            sentinel = os.path.join(installed, "approved-body.txt")
            with open(sentinel, "w") as handle:
                handle.write("never replace with a rejected turnaround")

            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), mock.patch.object(
                        body.media_gen, "generate_image_edit_sync",
                        side_effect=generate) as provider_call, mock.patch.object(
                            body, "_preflight_front_source",
                            return_value={"valid": True}), mock.patch.object(
                                body, "_preflight_alpha_source",
                                side_effect=preflight), mock.patch.object(
                                    body, "_install_sources",
                                    return_value={"installed": True}) as install_call:
                options = {"style": "editorial", "pose": "relaxed"}
                with self.assertRaisesRegex(
                        body.GeneratedBodyAlphaError, "contact shadow"):
                    body.build(directory, options, log=lambda _message: None)

                self.assertEqual(4, provider_call.call_count)
                self.assertEqual(2, len(back_gate_count))
                install_call.assert_not_called()
                self.assertTrue(os.path.isfile(sentinel))
                cache = os.path.join(directory, ".body-cache")
                self.assertTrue(os.path.isfile(os.path.join(cache, "signature")))
                self.assertTrue(os.path.isfile(
                    os.path.join(cache, "source-front.png")))
                self.assertTrue(os.path.isfile(
                    os.path.join(cache, "source-side.png")))
                self.assertFalse(os.path.exists(
                    os.path.join(cache, "source-back.png")))

                # Same intent/signature resumes from the exact accepted cache;
                # only the missing back provider call is paid for next time.
                reject_back["enabled"] = False
                provider_call.reset_mock()
                install_call.reset_mock()
                result = body.build(directory, options, log=lambda _message: None)
                self.assertEqual({"installed": True}, result)
                self.assertEqual(1, provider_call.call_count)
                self.assertEqual(
                    "body-source-back",
                    provider_call.call_args.kwargs["file_name"])
                install_call.assert_called_once()

    def test_retry_remediation_is_failure_specific_and_does_not_mutate_prompt(self):
        prompt = body._prompt(
            {"style": "editorial", "pose": "relaxed"}, "side")
        original = prompt[:]
        shadow = body._alpha_retry_prompt(
            prompt, "neutral floor or contact shadow remains", "side")
        near_white = body._alpha_retry_prompt(
            prompt,
            "near-white plate contamination; white/off-white subject detail "
            "is ambiguous against the plate", "side")

        self.assertEqual(original, prompt)
        self.assertIn("Remove every floor, wall, contact", shadow)
        self.assertIn(
            "approved front footwear's exact colour and material", shadow)
        self.assertIn("never invent pale or metallic heel hardware", shadow)
        self.assertNotIn("clearly non-white material", shadow)
        self.assertIn("clearly non-white material", near_white)
        self.assertIn("footwear dark, matte, and non-reflective", near_white)
        for candidate in (shadow, near_white):
            self.assertLessEqual(
                len(candidate.encode("utf-8")),
                body.FULL_BODY_PROMPT_MAX_BYTES)


if __name__ == "__main__":
    unittest.main()
