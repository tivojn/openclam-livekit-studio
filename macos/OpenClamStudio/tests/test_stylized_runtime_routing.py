"""Regression coverage for strict-photo vs topology-gated stylized routing.

Illustrated avatars need the bounded ``detect_for_intake`` fallback after the
provider has produced a canonical head.  Photographic avatars must never opt
into that lower-threshold route implicitly.  These tests exercise the shared
runtime helpers and both build orchestration paths so a future call-site
addition cannot quietly weaken photo QA.
"""
import json
import os
import re
import subprocess
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import anatomy, blink, build, compose, export, face, measure, render, rig
from studio import visemes


class _StopAfterRouting(RuntimeError):
    pass


def _image(size=64):
    return np.full((size, size, 3), 127, np.uint8)


def _landmarks(size=64):
    # Routing tests do not inspect topology.  A finite 478-point sentinel makes
    # identity assertions clearer than a MagicMock and remains safe if a
    # consumer computes a mouth box before the next patched boundary.
    points = np.full((478, 2), size * 0.5, np.float32)
    points[:, 0] += np.linspace(-4.0, 4.0, len(points), dtype=np.float32)
    points[:, 1] += np.linspace(-3.0, 3.0, len(points), dtype=np.float32)
    return points


def _metrics(medium):
    return {
        "yaw": 0.0,
        "pitch": 0.0,
        "roll": 0.0,
        "foreshortening": 1.0,
        "mouth_width_px": 180.0,
        "source_medium": medium,
        "warnings": [],
    }


class RuntimeDetectorRoutingTests(unittest.TestCase):
    HELPERS = (
        (compose, compose._detect_composition_face),
        (measure, measure._detect),
        (anatomy, anatomy._detect),
        (blink, blink._detect),
    )

    def test_photo_defaults_use_only_the_strict_detector(self):
        image = _image()
        landmarks, transform = _landmarks(), np.eye(4)
        for module, helper in self.HELPERS:
            with self.subTest(module=module.__name__), \
                    mock.patch.object(
                        module.face, "detect",
                        return_value=(landmarks, transform)) as strict, \
                    mock.patch.object(
                        module.face, "detect_for_intake",
                        side_effect=AssertionError(
                            "photo runtime invoked permissive intake")) as intake:
                found, found_transform = helper(image)
            self.assertIs(found, landmarks)
            self.assertIs(found_transform, transform)
            strict.assert_called_once_with(image)
            intake.assert_not_called()

    def test_stylized_helpers_use_the_topology_gated_intake_api(self):
        image = _image()
        landmarks, transform = _landmarks(), np.eye(4)
        metadata = {"detection_mode": "crop-fallback",
                    "topology": {"face_area": 0.2}}
        for module, helper in self.HELPERS:
            with self.subTest(module=module.__name__), \
                    mock.patch.object(
                        module.face, "detect",
                        side_effect=AssertionError(
                            "stylized runtime skipped its approved fallback")) as strict, \
                    mock.patch.object(
                        module.face, "detect_for_intake",
                        return_value=(landmarks, transform, metadata)) as intake:
                found, found_transform = helper(image, allow_stylized=True)
            self.assertIs(found, landmarks)
            self.assertIs(found_transform, transform)
            intake.assert_called_once_with(image)
            strict.assert_not_called()

    def test_runtime_modules_never_start_low_threshold_detector_directly(self):
        # detect_for_intake owns the crop bounds and _stylized_mesh_quality
        # topology gate.  Runtime modules may call that API, never the raw
        # low-threshold detector beneath it.
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        for name in ("compose", "measure", "anatomy", "blink", "render",
                     "export", "build"):
            with self.subTest(module=name):
                with open(os.path.join(root, "studio", f"{name}.py"),
                          encoding="utf-8") as handle:
                    source = handle.read()
                self.assertNotIn("stylized_detector(", source)
                self.assertNotIn("_detect_with(", source)

    def test_contact_sheet_routes_photo_and_stylized_keyframes_explicitly(self):
        image = _image(96)
        landmarks = _landmarks(96)
        with tempfile.TemporaryDirectory() as directory:
            key = os.path.join(directory, "keyframe.png")
            cv2.imwrite(key, image)
            for allow_stylized in (False, True):
                with self.subTest(allow_stylized=allow_stylized), \
                        mock.patch.object(
                            face, "detect",
                            return_value=(landmarks, np.eye(4))) as strict, \
                        mock.patch.object(
                            face, "detect_for_intake",
                            return_value=(landmarks, np.eye(4), {
                                "topology": {"face_area": 0.2}})) as intake:
                    result = render.contact_sheet(
                        directory, key, os.path.join(directory, "sheet.jpg"),
                        allow_stylized=allow_stylized)
                self.assertIsNone(result)  # no plates were needed for routing
                self.assertEqual(strict.call_count, 0 if allow_stylized else 1)
                self.assertEqual(intake.call_count, 1 if allow_stylized else 0)

    def test_preview_forwards_detection_mode_to_blink_builder(self):
        image = _image()
        with tempfile.TemporaryDirectory() as directory:
            viseme_dir = os.path.join(directory, "visemes")
            os.makedirs(viseme_dir)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), image)
            cv2.imwrite(os.path.join(viseme_dir, "v_blink.jpg"), image)
            for allow_stylized in (False, True):
                with self.subTest(allow_stylized=allow_stylized), \
                        mock.patch.object(render, "render_frames",
                                          return_value=[image.copy()]), \
                        mock.patch.object(render.blinkmod, "build",
                                          return_value={}) as build_blink, \
                        mock.patch.object(render, "blink_overlay"), \
                        mock.patch.object(render, "write_video",
                                          return_value="preview.mp4"):
                    render.preview(
                        viseme_dir, os.path.join(directory, "preview.mp4"),
                        allow_stylized=allow_stylized)
                self.assertEqual(
                    build_blink.call_args.kwargs["allow_stylized"],
                    allow_stylized)

    def test_runtime_export_keeps_photo_strict_and_opts_in_illustrations(self):
        image, landmarks = _image(), _landmarks()
        with tempfile.TemporaryDirectory() as directory:
            viseme_dir = os.path.join(directory, "visemes")
            os.makedirs(viseme_dir)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), image)
            cv2.imwrite(os.path.join(viseme_dir, "v_blink.jpg"), image)
            for medium, expected in (
                    ("photograph", False),
                    ("unknown", False),
                    ("corrupt-future-value", False),
                    ("illustration", True)):
                manifest = {
                    "status": "ready",
                    "source_metrics": {"source_medium": medium},
                }
                with self.subTest(medium=medium), \
                        mock.patch.object(export.reg, "adir",
                                          return_value=directory), \
                        mock.patch.object(export, "NAME_MAP", {}), \
                        mock.patch.object(export.blink, "build",
                                          return_value={}) as build_blink, \
                        mock.patch.object(
                            export.face, "detect",
                            return_value=(landmarks, np.eye(4))) as strict, \
                        mock.patch.object(
                            export.face, "detect_for_intake",
                            return_value=(landmarks, np.eye(4), {
                                "topology": {"face_area": 0.2}})) as intake, \
                        mock.patch.object(
                            export.expression, "build",
                            side_effect=_StopAfterRouting):
                    with self.assertRaises(_StopAfterRouting):
                        export.export(
                            "routing-avatar", os.path.join(directory, "runtime"),
                            source_dir=directory, manifest_data=manifest,
                            log=lambda _message: None)
                self.assertEqual(
                    build_blink.call_args.kwargs["allow_stylized"], expected)
                self.assertEqual(strict.call_count, 0 if expected else 1)
                self.assertEqual(intake.call_count, 1 if expected else 0)

    def test_pet_runtime_cutout_uses_declared_source_medium(self):
        for medium, expected in (
                ("photograph", False),
                ("unknown", False),
                ("corrupt-future-value", False),
                ("illustration", True)):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory:
                runtime_dir = os.path.join(directory, "runtime")
                os.makedirs(runtime_dir)
                with open(os.path.join(runtime_dir, "manifest.json"),
                          "w", encoding="utf-8") as handle:
                    handle.write('{"v": %d}' % export.RUNTIME_VERSION)
                manifest = {
                    "status": "ready",
                    "source_metrics": {"source_medium": medium},
                }
                with mock.patch.object(export.reg, "adir",
                                       return_value=directory), \
                        mock.patch.object(export.reg, "read_manifest",
                                          return_value=manifest), \
                        mock.patch.object(export.cutout, "render",
                                          return_value={}) as render_cutout, \
                        mock.patch.object(export, "_publish_motion",
                                          return_value=None):
                    export.publish_pet_assets(
                        "routing-avatar", runtime_dir=runtime_dir,
                        log=lambda _message: None)
                self.assertEqual(
                    render_cutout.call_args.kwargs["allow_stylized"],
                    expected)

    def test_pet_runtime_publishes_body_space_head_clear_mask_only_when_authored(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime_dir = os.path.join(directory, "runtime")
            body_dir = os.path.join(directory, "body")
            os.makedirs(runtime_dir)
            os.makedirs(body_dir)
            with open(os.path.join(runtime_dir, "manifest.json"), "w") as handle:
                handle.write('{"v": %d}' % export.RUNTIME_VERSION)
            for name in ("body.png", "head-mask.png", "head-clear-mask.png"):
                cv2.imwrite(os.path.join(body_dir, name),
                            np.full((16, 16, 4), 255, np.uint8))
            with open(os.path.join(body_dir, "body.json"), "w") as handle:
                handle.write(
                    '{"image":"body.png","head_mask":"head-mask.png",'
                    '"head_composite":"replace",'
                    '"head_clear_mask":"head-clear-mask.png"}')
            manifest = {
                "status": "ready",
                "source_metrics": {"source_medium": "anime"},
            }
            with mock.patch.object(export.reg, "adir", return_value=directory), \
                    mock.patch.object(export.reg, "read_manifest",
                                      return_value=manifest), \
                    mock.patch.object(export.cutout, "render", return_value={}), \
                    mock.patch.object(export, "_publish_body_extras"), \
                    mock.patch.object(export, "_publish_motion", return_value=None):
                export.publish_pet_assets(
                    "routing-avatar", runtime_dir=runtime_dir,
                    log=lambda _message: None)
            with open(os.path.join(runtime_dir, "manifest.json")) as handle:
                published = json.load(handle)
            self.assertEqual(
                "assets/head-clear-mask.png",
                published["body"]["head_clear_mask"])
            self.assertTrue(os.path.isfile(
                os.path.join(runtime_dir, "head-clear-mask.png")))


class BuildRoutingTests(unittest.TestCase):
    def test_source_medium_whitelist_fails_closed(self):
        for value, expected in (
                (None, "photograph"),
                ("", "photograph"),
                ("unknown", "photograph"),
                ("photograph", "photograph"),
                ("photo", "photograph"),
                ("corrupt-future-value", "photograph"),
                ("illustration", "illustration"),
                ("anime", "anime"),
                ("soft-3d", "3d render")):
            with self.subTest(value=value):
                self.assertEqual(
                    expected, build._source_medium({"source_medium": value}))
        self.assertEqual(
            "illustration", build._source_medium({"source_mode": "stylized"}))
        self.assertEqual(
            "photograph", build._source_medium({
                "source_medium": "unknown",
                "source_mode": "stylized-cartoon",
            }))

    def test_export_original_source_report_precedes_generated_head(self):
        for report, head_medium, expected in (
                ({"source_medium": "photograph"}, "illustration", "photograph"),
                ({"source_medium": "illustration"},
                 "corrupt-future-value", "illustration"),
                ({"source_mode": "stylized-cartoon"},
                 "photograph", "illustration")):
            with self.subTest(report=report, head_medium=head_medium):
                self.assertEqual(expected, export._source_medium({
                    "source_metrics": report,
                    "head": {"source_medium": head_medium},
                }))

    def test_export_corrupt_original_report_fails_closed_without_fallback(self):
        for report in (
                {"source_medium": "unknown"},
                {"source_medium": "corrupt-future-value"},
                {},
                "damaged-report"):
            with self.subTest(report=report):
                self.assertEqual("photograph", export._source_medium({
                    "source_metrics": report,
                    "metrics": {"source_medium": "illustration"},
                    "head": {"source_medium": "illustration"},
                }))

    def test_export_legacy_head_medium_is_used_only_without_source_report(self):
        self.assertEqual("illustration", export._source_medium({
            "head": {"source_medium": "illustration"},
        }))

    def test_recreated_source_keyframe_respects_declared_medium(self):
        # Regression: this recovery path formerly hardcoded
        # allow_stylized=True before source_medium was read, so a photo draft
        # could silently enter the permissive detector after cache loss.
        for medium, expected in (
                ("photograph", False),
                ("unknown", False),
                ("corrupt-future-value", False),
                ("illustration", True)):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory:
                source = os.path.join(directory, "source.png")
                cv2.imwrite(source, _image())
                manifest = {
                    "slug": "routing-avatar",
                    "status": "draft",
                    "source": "source.png",
                    "source_metrics": {"source_medium": medium},
                }

                def prepare(_source, destination, **_kwargs):
                    cv2.imwrite(destination, _image())
                    return _metrics(medium)

                with mock.patch.object(build, "adir", return_value=directory), \
                        mock.patch.object(build, "read_manifest",
                                          return_value=manifest), \
                        mock.patch.object(build, "write_manifest",
                                          side_effect=lambda _slug, data: data), \
                        mock.patch.object(build.prep, "build_keyframe",
                                          side_effect=prepare) as prepare_key, \
                        mock.patch.object(
                            build.generate, "default_head_provider",
                            side_effect=_StopAfterRouting):
                    result = build.build_avatar(
                        "routing-avatar", log=lambda _message: None)

                self.assertEqual(result["status"], "error")
                self.assertEqual(
                    prepare_key.call_args.kwargs["allow_stylized"], expected)

    def test_full_build_propagates_medium_to_every_face_runtime_stage(self):
        for medium, expected in (
                ("photograph", False),
                ("unknown", False),
                ("corrupt-future-value", False),
                ("illustration", True)):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory:
                source_key = os.path.join(directory, "source-keyframe.png")
                cv2.imwrite(source_key, _image())
                cv2.imwrite(os.path.join(directory, "keyframe.png"), _image())
                manifest = {
                    "slug": "routing-avatar",
                    "status": "draft",
                    "source_keyframe": "source-keyframe.png",
                    "source_metrics": {"source_medium": medium},
                }

                def generate_head(_source, destination, **_kwargs):
                    cv2.imwrite(destination, _image())
                    return destination

                def prepare_head(_source, destination, **_kwargs):
                    cv2.imwrite(destination, _image())
                    return _metrics(medium)

                def generate_set(_key, _raw, **_kwargs):
                    return {name: os.path.join(directory, f"{name}.png")
                            for name in visemes.ORDER}

                report = [dict(name=name, resid_px=0.0,
                               outside_delta=0.0)
                          for name in visemes.ORDER]
                with mock.patch.object(build, "adir", return_value=directory), \
                        mock.patch.object(build, "read_manifest",
                                          return_value=manifest), \
                        mock.patch.object(build, "write_manifest",
                                          side_effect=lambda _slug, data: data), \
                        mock.patch.object(build.generate, "default_head_provider",
                                          return_value={"name": "test",
                                                        "model": "test"}), \
                        mock.patch.object(build.generate, "generate_head",
                                          side_effect=generate_head), \
                        mock.patch.object(build.prep, "build_keyframe",
                                          side_effect=prepare_head) as prepare_key, \
                        mock.patch.object(build.generate, "generate_set",
                                          side_effect=generate_set), \
                        mock.patch.object(build.measure, "th_tongue_issue",
                                          return_value=None) as tongue, \
                        mock.patch.object(build.compose, "compose_all",
                                          return_value=(report, {})) as compose_all, \
                        mock.patch.object(build.measure, "audit",
                                          return_value=([], [])) as audit, \
                        mock.patch.object(build.render, "preview") as preview, \
                        mock.patch.object(build.render,
                                          "contact_sheet") as contact_sheet:
                    result = build.build_avatar(
                        "routing-avatar", log=lambda _message: None)

                self.assertEqual(result["status"], "ready")
                self.assertEqual(
                    prepare_key.call_args.kwargs["allow_stylized"], expected)
                self.assertEqual(
                    tongue.call_args.kwargs["allow_stylized"], expected)
                self.assertTrue(compose_all.call_args_list)
                self.assertTrue(all(
                    call.kwargs["allow_stylized"] == expected
                    for call in compose_all.call_args_list))
                self.assertTrue(audit.call_args_list)
                self.assertTrue(all(
                    call.kwargs["allow_stylized"] == expected
                    for call in audit.call_args_list))
                self.assertEqual(
                    preview.call_args.kwargs["allow_stylized"], expected)
                self.assertEqual(
                    contact_sheet.call_args.kwargs["allow_stylized"], expected)

    def test_recompose_propagates_medium_through_all_stages(self):
        for medium, expected in (
                ("photograph", False),
                ("unknown", False),
                ("corrupt-future-value", False),
                ("illustration", True)):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory:
                os.makedirs(os.path.join(directory, "raw"))
                cv2.imwrite(os.path.join(directory, "keyframe.png"), _image())
                manifest = {
                    "slug": "routing-avatar",
                    "status": "ready",
                    "source_metrics": {"source_medium": medium},
                }
                report = [dict(name=name, resid_px=0.0,
                               outside_delta=0.0)
                          for name in visemes.ORDER]
                qa = {
                    "structure_warnings": [],
                    "dental_warnings": [],
                }
                with mock.patch.object(build, "adir", return_value=directory), \
                        mock.patch.object(build, "read_manifest",
                                          return_value=manifest), \
                        mock.patch.object(build, "raw_render_gaps",
                                          return_value=[]), \
                        mock.patch.object(build, "_stage_safe_th",
                                          return_value=False), \
                        mock.patch.object(build.compose, "compose_all",
                                          return_value=(report, {})) as compose_all, \
                        mock.patch.object(build.measure, "audit",
                                          return_value=([], [])) as audit, \
                        mock.patch.object(build.render, "preview") as preview, \
                        mock.patch.object(build.render,
                                          "contact_sheet") as contact_sheet, \
                        mock.patch.object(build.anatomy, "validate",
                                          return_value=qa) as validate, \
                        mock.patch.object(build.anatomy, "summary",
                                          return_value="ok"), \
                        mock.patch("studio.export.export") as export_runtime, \
                        mock.patch.object(build, "_snapshot_live",
                                          return_value="snapshot"), \
                        mock.patch.object(build, "_publish_stage"):
                    build.recompose_avatar(
                        "routing-avatar", rig.normalize(),
                        log=lambda _message: None)

                self.assertTrue(all(
                    call.kwargs["allow_stylized"] == expected
                    for call in compose_all.call_args_list))
                self.assertTrue(all(
                    call.kwargs["allow_stylized"] == expected
                    for call in audit.call_args_list))
                self.assertEqual(
                    preview.call_args.kwargs["allow_stylized"], expected)
                self.assertEqual(
                    contact_sheet.call_args.kwargs["allow_stylized"], expected)
                self.assertEqual(
                    validate.call_args.kwargs["allow_stylized"], expected)
                exported_manifest = export_runtime.call_args.kwargs["manifest_data"]
                self.assertEqual(
                    exported_manifest["source_metrics"]["source_medium"], medium)


class StylizedRendererAssetTests(unittest.TestCase):
    def test_photo_blink_export_never_enters_stylized_detector(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(
                    export.face, "detect_for_intake",
                    side_effect=AssertionError(
                        "photo runtime invoked permissive intake")) as intake:
            os.makedirs(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), _image())
            result = export._publish_stylized_blink_source(
                _image(), directory, {
                    "r": {"box": [8, 8, 16, 12]},
                    "l": {"box": [38, 8, 16, 12]},
                }, directory, "photograph", log=lambda _message: None)
        self.assertIsNone(result)
        intake.assert_not_called()

    def test_stylized_blink_export_accepts_closed_sclera_despite_noisy_mesh(self):
        key = np.full((80, 96, 3), (70, 100, 150), np.uint8)
        cv2.ellipse(key, (25, 26), (12, 10), 0, 0, 360,
                    (245, 245, 245), -1)
        cv2.ellipse(key, (69, 26), (12, 10), 0, 0, 360,
                    (245, 245, 245), -1)
        cv2.circle(key, (25, 26), 3, (10, 10, 10), -1)
        cv2.circle(key, (69, 26), 3, (10, 10, 10), -1)
        # A provider-authored closed cartoon eye has no white sclera.  Keep
        # the canonical skin colour and draw only one clean lower-lid stroke;
        # unlike a dark rectangle, this exercises the semantic topology gate.
        shut = np.full_like(key, (70, 100, 150))
        cv2.line(shut, (15, 31), (35, 31), (20, 20, 20), 3,
                 cv2.LINE_AA)
        cv2.line(shut, (59, 31), (79, 31), (20, 20, 20), 3,
                 cv2.LINE_AA)
        landmarks = _landmarks(96)
        with tempfile.TemporaryDirectory() as directory:
            raw = os.path.join(directory, "raw")
            runtime = os.path.join(directory, "runtime")
            os.makedirs(raw)
            cv2.imwrite(os.path.join(raw, "v_blink.png"), shut)
            with mock.patch.object(
                    export.face, "detect_for_intake",
                    return_value=(landmarks, np.eye(4), {})) as intake, \
                    mock.patch.object(
                        export.cv2, "estimateAffine2D",
                        return_value=(np.array([[1., 0., 0.],
                                                [0., 1., 0.]]), None)), \
                    mock.patch.object(
                        export.cv2, "estimateAffinePartial2D",
                        return_value=(np.array([[1., 0., 0.],
                                                [0., 1., 0.]]), None)), \
                    mock.patch.object(
                        export.blink, "_aperture",
                        # The two real retained Luffys measure .815 and .655
                        # on their noisier sides even though 100% and 98.6% of
                        # the white sclera disappear.  Exercise both values.
                        side_effect=[20., 16.3, 20., 13.1]):
                result = export._publish_stylized_blink_source(
                    key, directory, {
                        "r": {"box": [14, 18, 22, 17]},
                        "l": {"box": [58, 18, 22, 17]},
                    }, runtime, "3d render", log=lambda _message: None)

            self.assertEqual("semantic-eye-switch", result["mode"])
            self.assertEqual(3, intake.call_count)
            for side in blink.SIDES:
                plate = cv2.imread(
                    os.path.join(runtime, f"stylized-blink-{side}.png"),
                    cv2.IMREAD_UNCHANGED)
                self.assertIsNotNone(plate)
                self.assertEqual(4, plate.shape[2])
                self.assertEqual(0, int(plate[0, 0, 3]))
                self.assertGreater(int(plate[plate.shape[0] // 2,
                                             plate.shape[1] // 2, 3]), 250)
                x, y, width, height = result[side]["box"]
                neutral_patch = key[y:y + height, x:x + width]
                feather = (plate[:, :, 3] > 2) & (plate[:, :, 3] < 24)
                if np.any(feather):
                    self.assertLessEqual(int(np.max(np.abs(
                        plate[:, :, :3][feather].astype(np.int16)
                        - neutral_patch[feather].astype(np.int16)))), 2)
                self.assertEqual(
                    f"assets/stylized-blink-{side}.png",
                    result[side]["src"])

    def test_stylized_blink_rejects_foreign_dark_art_in_eye_plate(self):
        key = np.full((80, 96, 3), (70, 100, 150), np.uint8)
        for centre in ((25, 26), (69, 26)):
            cv2.ellipse(key, centre, (12, 10), 0, 0, 360,
                        (245, 245, 245), -1)
            cv2.circle(key, centre, 3, (10, 10, 10), -1)
        shut = np.full_like(key, (70, 100, 150))
        cv2.line(shut, (15, 31), (35, 31), (20, 20, 20), 3)
        cv2.line(shut, (59, 31), (79, 31), (20, 20, 20), 3)
        # Simulate the provider-shifted hair shard that caused the old 3-D
        # blink plate's circular patch and black-hole eye on a dark canvas.
        cv2.rectangle(shut, (22, 14), (28, 36), (5, 5, 5), -1)
        landmarks = _landmarks(96)
        identity = np.array([[1., 0., 0.], [0., 1., 0.]])
        with tempfile.TemporaryDirectory() as directory:
            raw = os.path.join(directory, "raw")
            runtime = os.path.join(directory, "runtime")
            os.makedirs(raw)
            cv2.imwrite(os.path.join(raw, "v_blink.png"), shut)
            with mock.patch.object(
                    export.face, "detect_for_intake",
                    return_value=(landmarks, np.eye(4), {})), \
                    mock.patch.object(export.cv2, "estimateAffine2D",
                                      return_value=(identity, None)), \
                    mock.patch.object(export.cv2, "estimateAffinePartial2D",
                                      return_value=(identity, None)), \
                    mock.patch.object(export.blink, "_aperture",
                                      side_effect=[20., 4., 20., 4.]):
                result = export._publish_stylized_blink_source(
                    key, directory, {
                        "r": {"box": [14, 18, 22, 17]},
                        "l": {"box": [58, 18, 22, 17]},
                    }, runtime, "illustration", log=lambda _message: None)
            self.assertIsNone(result)

    def test_stylized_mouth_geometry_is_lip_only(self):
        landmarks = _landmarks(100)
        angles = np.linspace(0.0, np.pi * 2.0, len(face.OUTER_LIP),
                             endpoint=False)
        landmarks[face.OUTER_LIP, 0] = 50.0 + np.cos(angles) * 10.0
        landmarks[face.OUTER_LIP, 1] = 50.0 + np.sin(angles) * 3.0
        geometry = export._stylized_mouth_geometry((100, 100, 3), landmarks)
        self.assertEqual("canonical-outer-lip-v1", geometry["basis"])
        self.assertEqual([35, 44, 30, 16], geometry["box"])
        mouth = geometry["box"]
        # Oversized cartoon sclerae can sit immediately above the lips.  The
        # canonical lip box must have zero intersection with either one.
        for eye in ([12, 8, 28, 36], [60, 8, 28, 36]):
            overlap_width = max(
                0, min(mouth[0] + mouth[2], eye[0] + eye[2])
                - max(mouth[0], eye[0]))
            overlap_height = max(
                0, min(mouth[1] + mouth[3], eye[1] + eye[3])
                - max(mouth[1], eye[1]))
            self.assertEqual(0, overlap_width * overlap_height)

    def test_pet_refresh_uses_canonical_neutral_only_for_stylized_runtime(self):
        key = np.full((48, 64, 3), (50, 110, 180), np.uint8)
        provider_neutral = np.full((48, 64, 3), (180, 90, 40), np.uint8)
        for medium, expects_key in (("illustration", True),
                                    ("photograph", False)):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory:
                runtime = os.path.join(directory, "runtime")
                os.makedirs(runtime)
                cv2.imwrite(os.path.join(directory, "keyframe.png"), key)
                cv2.imwrite(os.path.join(runtime, "sil_open.jpg"),
                            provider_neutral)
                with open(os.path.join(runtime, "manifest.json"), "w") as handle:
                    json.dump({
                        "v": export.RUNTIME_VERSION,
                        "frames": {"sil": {"open": "assets/sil_open.jpg"}},
                        "eyes": {},
                    }, handle)
                source_manifest = {
                    "status": "ready",
                    "source_metrics": {"source_medium": medium},
                }
                with mock.patch.object(export.reg, "adir",
                                       return_value=directory), \
                        mock.patch.object(export.reg, "read_manifest",
                                          return_value=source_manifest), \
                        mock.patch.object(
                            export.face, "detect_for_intake",
                            return_value=(_landmarks(64), np.eye(4), {})), \
                        mock.patch.object(export.cutout, "render",
                                          return_value={}), \
                        mock.patch.object(export, "_publish_motion",
                                          return_value=None), \
                        mock.patch.object(
                            export, "_publish_stylized_blink_source",
                            return_value=None):
                    export.publish_pet_assets(
                        "routing-avatar", runtime_dir=runtime,
                        log=lambda _message: None)
                refreshed = cv2.imread(os.path.join(runtime, "sil_open.jpg"))
                target = key if expects_key else provider_neutral
                self.assertLess(float(np.mean(np.abs(
                    refreshed.astype(np.int16) - target.astype(np.int16)))), 2.0)

    def test_web_renderer_narrows_cartoon_motion_but_preserves_photo_branch(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(root, "web", "index.html"),
                  encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn("const isStylizedFaceRuntime", source)
        self.assertIn("Object.prototype.hasOwnProperty.call(runtime, 'source_medium')", source)
        self.assertIn("drawStylizedVisemePatch(faceContext", source)
        self.assertIn("const neutralImage = visemeImages.get('sil')", source)
        self.assertIn("manifest && manifest.stylized_mouth", source)
        self.assertNotIn("runtimeBox(manifest && manifest.smile)", source)
        self.assertIn("blend >= .5", source)
        self.assertIn("Photorealistic runtimes retain the reviewed full-frame crossfade", source)
        self.assertIn("manifest.stylized_blink.mode === 'semantic-eye-switch'", source)
        self.assertIn("closure >= .78", source)
        self.assertIn("eyelidPolicy === 'photo-strip'", source)
        self.assertNotIn("expressionSmoothStep((eyelidClosure - .70) / .12)", source)

    def test_web_stylized_switches_are_executable_and_fail_closed(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(root, "web", "index.html"),
                  encoding="utf-8") as handle:
            source = handle.read()
        selector = re.search(
            r"(const selectStylizedVisemeImage = \(oldImage, newImage, blend\)"
            r" => \([\s\S]*?\n    \);)", source)
        policy = re.search(
            r"(const faceEyelidPolicy = \(stylized, stylizedBlinkReady, closure\)"
            r" => \{[\s\S]*?\n    \};)", source)
        self.assertIsNotNone(selector)
        self.assertIsNotNone(policy)
        script = f"""
          'use strict';
          {selector.group(1)}
          {policy.group(1)}
          const oldImage = {{ id: 'old' }};
          const newImage = {{ id: 'new' }};
          process.stdout.write(JSON.stringify({{
            mouth: [
              selectStylizedVisemeImage(oldImage, newImage, .49).id,
              selectStylizedVisemeImage(oldImage, newImage, .50).id
            ],
            lids: [
              faceEyelidPolicy(true, false, 1),
              faceEyelidPolicy(true, true, .77),
              faceEyelidPolicy(true, true, .78),
              faceEyelidPolicy(false, false, 1)
            ]
          }}));
        """
        output = subprocess.check_output(
            ["node", "-e", script], text=True, cwd=root)
        observed = json.loads(output)
        self.assertEqual(["old", "new"], observed["mouth"])
        self.assertEqual([
            "static-canonical", "static-canonical",
            "stylized-closed", "photo-strip",
        ], observed["lids"])


if __name__ == "__main__":
    unittest.main()
