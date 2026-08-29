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

from studio import anatomy, blink, build, compose, export, expression, face, measure, render, rig
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
                    '"head_handoff_version":2,'
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
            self.assertEqual(2, published["body"]["head_handoff_version"])
            self.assertTrue(os.path.isfile(
                os.path.join(runtime_dir, "head-clear-mask.png")))

    def test_stylized_head_handoff_version_is_explicit_and_fails_closed(self):
        base = {
            "v": 3,
            "head_composite": "replace",
            "head_clear_mask": "head-clear-mask.png",
        }
        legacy = export._runtime_body_metadata(base)
        self.assertNotIn("head_handoff_version", legacy)

        current = export._runtime_body_metadata({
            **base,
            "head_handoff_version": export.STYLIZED_HEAD_HANDOFF_VERSION,
        })
        self.assertEqual(
            export.STYLIZED_HEAD_HANDOFF_VERSION,
            current["head_handoff_version"])

        # Reject bool/string aliases and every unreviewed version.  Runtime
        # must never infer the new feather semantics from a legacy clear mask.
        for marker in (True, "2", 1, 3):
            candidate = export._runtime_body_metadata({
                **base, "head_handoff_version": marker,
            })
            self.assertNotIn("head_handoff_version", candidate)


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
                        "photo runtime invoked permissive intake")) as intake, \
                mock.patch.object(
                    export, "_harmonic_stylized_skin",
                    side_effect=AssertionError(
                        "photo runtime invoked stylized skin fill")) as fill:
            os.makedirs(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), _image())
            result = export._publish_stylized_blink_source(
                _image(), directory, {
                    "r": {"box": [8, 8, 16, 12]},
                    "l": {"box": [38, 8, 16, 12]},
                }, directory, "photograph", log=lambda _message: None)
        self.assertIsNone(result)
        intake.assert_not_called()
        fill.assert_not_called()

    def test_harmonic_stylized_skin_has_no_disk_or_radial_seam(self):
        height, width = 84, 112
        grid_y, grid_x = np.mgrid[:height, :width]
        # Each channel is a linear skin-lighting field.  A correct discrete
        # harmonic fill reconstructs it exactly; a radial inpaint/fitted disk
        # leaves a measurable circular residual in the eye interior.
        expected = np.dstack((
            72.0 + grid_x * .34 + grid_y * .08,
            112.0 + grid_x * .24 + grid_y * .15,
            174.0 + grid_x * .18 + grid_y * .11,
        )).astype(np.uint8)
        canonical = expected.copy()
        cv2.ellipse(canonical, (56, 42), (26, 20), 0, 0, 360,
                    (246, 246, 246), -1)
        cv2.ellipse(canonical, (56, 42), (26, 20), 0, 0, 360,
                    (18, 18, 18), 3)
        cv2.circle(canonical, (56, 42), 7, (8, 8, 8), -1)
        mask = np.zeros((height, width), np.uint8)
        cv2.ellipse(mask, (56, 42), (29, 23), 0, 0, 360, 255, -1)

        filled = export._harmonic_stylized_skin(canonical, mask > 0)

        self.assertIsNotNone(filled)
        error = np.abs(
            filled.astype(np.int16) - expected.astype(np.int16)
        ).max(2)
        self.assertLessEqual(
            float(np.percentile(error[mask > 0], 99)), 1.0,
            "a linear canonical skin field must not become a circular disk",
        )
        self.assertTrue(np.array_equal(
            filled[mask == 0], canonical[mask == 0]
        ), "harmonic reconstruction may change only the full-eye mask")

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
                self.assertLessEqual(
                    int(plate[0, 0, 3]), 24,
                    "the crop edge may contain only the canonical seam feather",
                )
                self.assertGreater(int(plate[plate.shape[0] // 2,
                                             plate.shape[1] // 2, 3]), 250)
                x, y, width, height = result[side]["box"]
                neutral_patch = key[y:y + height, x:x + width]
                neutral_hsv = cv2.cvtColor(neutral_patch, cv2.COLOR_BGR2HSV)
                open_sclera = (
                    (neutral_hsv[:, :, 1] < 40)
                    & (neutral_hsv[:, :, 2] > 200)
                )
                self.assertGreater(
                    int(np.count_nonzero(open_sclera)), 30,
                    "fixture must contain an oversized authored sclera",
                )
                self.assertGreaterEqual(
                    int(np.min(plate[:, :, 3][open_sclera])), 250,
                    "the semantic plate must fully occlude every open-eye pixel",
                )
                opacity = plate[:, :, 3].astype(np.float32)[:, :, None] / 255.0
                rendered = np.clip(
                    plate[:, :, :3].astype(np.float32) * opacity
                    + neutral_patch.astype(np.float32) * (1.0 - opacity),
                    0,
                    255,
                ).astype(np.uint8)
                rendered_hsv = cv2.cvtColor(rendered, cv2.COLOR_BGR2HSV)
                remaining_sclera = (
                    (rendered_hsv[:, :, 1] < 72)
                    & (rendered_hsv[:, :, 2] > 155)
                    & open_sclera
                )
                self.assertEqual(
                    0,
                    int(np.count_nonzero(remaining_sclera)),
                    "a closed cartoon eye must not retain a smaller white eye",
                )
                feather = (plate[:, :, 3] > 2) & (plate[:, :, 3] < 24)
                if np.any(feather):
                    self.assertLessEqual(int(np.max(np.abs(
                        plate[:, :, :3][feather].astype(np.int16)
                        - neutral_patch[feather].astype(np.int16)))), 2)
                self.assertEqual(
                    f"assets/stylized-blink-{side}.png",
                    result[side]["src"])

    def test_stylized_blink_retries_stable_global_when_local_lid_is_clipped(self):
        key = np.full((80, 96, 3), (70, 100, 150), np.uint8)
        for centre in ((25, 26), (69, 26)):
            cv2.ellipse(key, centre, (12, 10), 0, 0, 360,
                        (245, 245, 245), -1)
            cv2.circle(key, centre, 3, (10, 10, 10), -1)
        shut = np.full_like(key, (70, 100, 150))
        cv2.line(shut, (15, 31), (35, 31), (20, 20, 20), 3,
                 cv2.LINE_AA)
        cv2.line(shut, (59, 31), (79, 31), (20, 20, 20), 3,
                 cv2.LINE_AA)
        landmarks = _landmarks(96)
        identity = np.array([[1., 0., 0.], [0., 1., 0.]])
        # This deliberately moves the authored lid above the bounded local
        # crop.  Publication may recover only from the already stability-gated
        # global affine, not by weakening the lid topology threshold.
        clipped_local = np.array([[1., 0., 0.], [0., 1., -18.]])
        logs = []
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
                    mock.patch.object(
                        export.cv2, "estimateAffinePartial2D",
                        return_value=(clipped_local, None)), \
                    mock.patch.object(export.blink, "_aperture",
                                      side_effect=[20., 4., 20., 4.]):
                result = export._publish_stylized_blink_source(
                    key, directory, {
                        "r": {"box": [14, 18, 22, 17]},
                        "l": {"box": [58, 18, 22, 17]},
                    }, runtime, "3d render", log=logs.append)

            self.assertEqual("semantic-eye-switch", result["mode"])
            self.assertEqual(2, sum(
                "using stable global lid alignment" in message
                for message in logs
            ))
            for side in blink.SIDES:
                self.assertTrue(os.path.isfile(os.path.join(
                    runtime, f"stylized-blink-{side}.png"
                )))

    def test_global_lid_fallback_keeps_foreign_art_gate_fail_closed(self):
        key = np.full((80, 96, 3), (70, 100, 150), np.uint8)
        for centre in ((25, 26), (69, 26)):
            cv2.ellipse(key, centre, (12, 10), 0, 0, 360,
                        (245, 245, 245), -1)
            cv2.circle(key, centre, 3, (10, 10, 10), -1)
        shut = np.full_like(key, (70, 100, 150))
        cv2.line(shut, (15, 31), (35, 31), (20, 20, 20), 3)
        cv2.line(shut, (59, 31), (79, 31), (20, 20, 20), 3)
        # Keep the shard separate from the valid lower lid so topology can
        # succeed and the post-fallback foreign-art gate itself is exercised.
        cv2.rectangle(shut, (19, 22), (31, 25), (5, 5, 5), -1)
        landmarks = _landmarks(96)
        identity = np.array([[1., 0., 0.], [0., 1., 0.]])
        clipped_local = np.array([[1., 0., 0.], [0., 1., -18.]])
        logs = []
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
                    mock.patch.object(
                        export.cv2, "estimateAffinePartial2D",
                        return_value=(clipped_local, None)), \
                    mock.patch.object(export.blink, "_aperture",
                                      side_effect=[20., 4., 20., 4.]):
                result = export._publish_stylized_blink_source(
                    key, directory, {
                        "r": {"box": [14, 18, 22, 17]},
                        "l": {"box": [58, 18, 22, 17]},
                    }, runtime, "illustration", log=logs.append)

            self.assertIsNone(result)
            self.assertTrue(any(
                "contains foreign dark art" in message for message in logs
            ))
            self.assertFalse(any(
                os.path.isfile(os.path.join(
                    runtime, f"stylized-blink-{side}.png"
                ))
                for side in blink.SIDES
            ))

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

    def test_smile_build_records_per_viseme_horizontal_registration(self):
        key_landmarks = _landmarks(100)
        angles = np.linspace(0.0, np.pi * 2.0, len(face.OUTER_LIP),
                             endpoint=False)
        key_landmarks[face.OUTER_LIP, 0] = 53.0 + np.cos(angles) * 10.0
        key_landmarks[face.OUTER_LIP, 1] = 50.0 + np.sin(angles) * 3.0
        shifted = key_landmarks.copy()
        shifted[face.OUTER_LIP, 0] -= 12.5
        key = _image(100)
        with mock.patch.object(
                expression.face, "detect",
                side_effect=[(key_landmarks, None), (shifted, None)]), \
                mock.patch.object(expression, "_smile_box",
                                  return_value=[35, 44, 30, 16]), \
                mock.patch.object(expression, "_smile_patch",
                                  return_value=np.zeros((16, 30, 4), np.uint8)):
            result = expression.build_smile(
                key, key_landmarks, [("sil", key), ("aa", key)],
                states=[0], log=lambda _message: None)

        self.assertEqual(result["viseme_x_offsets"], {"sil": 0.0, "aa": 7.0})
        self.assertEqual(
            result["viseme_x_offsets"]["aa"],
            round(.35 * np.ptp(key_landmarks[face.OUTER_LIP, 0]), 4),
            "registration is bounded by the canonical mouth width",
        )

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
                        "stylized_mouth": {
                            "box": [20, 22, 24, 14],
                            "basis": "canonical-outer-lip-v1",
                            "viseme_x_offsets": {"sil": 0.0, "aa": 6.25},
                        },
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
                if expects_key:
                    with open(os.path.join(runtime, "manifest.json")) as handle:
                        refreshed_manifest = json.load(handle)
                    self.assertEqual(
                        refreshed_manifest["stylized_mouth"]["viseme_x_offsets"],
                        {"sil": 0.0, "aa": 6.25},
                    )

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
        self.assertIn("manifest.stylized_mouth.viseme_x_offsets", source)
        self.assertNotIn("runtimeBox(manifest && manifest.smile)", source)
        self.assertIn("blend >= .5", source)
        self.assertIn("const stylizedMouthMaskAlpha", source)
        self.assertIn("const stylizedMouthToneShift", source)
        self.assertIn("const authoredHeadHandoffReady", source)
        self.assertIn(
            "body.head_handoff_version === STYLIZED_HEAD_HANDOFF_VERSION",
            source)
        self.assertIn("? preserveMaskAlpha(matte.data)", source)
        self.assertIn("const stylizedEmotionMouthSample", source)
        self.assertIn("const stylizedEmotionMouthPlacement", source)
        self.assertIn("drawStylizedEmotionMouthSample(", source)
        self.assertIn("prepareStylizedMouthMask(width, height)", source)
        self.assertIn("stripBlendContext.globalCompositeOperation = 'destination-in'", source)
        self.assertIn("weight: (1 - blend) * (1 - strength.mix)", source)
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
        mouth_mask = re.search(
            r"(const stylizedMouthMaskAlpha = \(x, y, width, height\) => \{"
            r"[\s\S]*?\n    \};)", source)
        tone_shift = re.search(
            r"(const stylizedMouthToneShift = \(source, target, limit = 24\) => \("
            r"[\s\S]*?\n    \);)", source)
        difference_alpha = re.search(
            r"(const stylizedMouthDifferenceAlpha = \(maximumDelta, spatialAlpha\)"
            r" => \([\s\S]*?\n    \);)", source)
        preserve_mask = re.search(
            r"(const preserveMaskAlpha = pixels => \{[\s\S]*?\n    \};)",
            source)
        handoff_ready = re.search(
            r"(const authoredHeadHandoffReady = \(body, clearMask, authoredMask\)"
            r" => Boolean\([\s\S]*?\n      && body\.head_clear_mask"
            r" && clearMask && authoredMask\);)", source)
        legacy_handoff_ready = re.search(
            r"(const legacyStylizedHeadHandoffReady = \(\n"
            r"      runtime, body, clearMask, authoredMask\) => Boolean\("
            r"[\s\S]*?\n      && runtimeBox\(runtime\.stylized_mouth\)\);)", source)
        emotion_sample = re.search(
            r"(const stylizedEmotionMouthSample = \(\n"
            r"      states, rows, amount, emotionIndex, oldName, newName, blend\)"
            r" => \{[\s\S]*?\n    \};)", source)
        self.assertIsNotNone(selector)
        self.assertIsNotNone(policy)
        self.assertIsNotNone(mouth_mask)
        self.assertIsNotNone(tone_shift)
        self.assertIsNotNone(difference_alpha)
        self.assertIsNotNone(preserve_mask)
        self.assertIsNotNone(handoff_ready)
        self.assertIsNotNone(legacy_handoff_ready)
        self.assertIsNotNone(emotion_sample)
        script = f"""
          'use strict';
          const STYLIZED_HEAD_HANDOFF_VERSION = 2;
          const expressionSmoothStep = value => {{
            const amount = Math.max(0, Math.min(1, Number(value) || 0));
            return amount * amount * (3 - 2 * amount);
          }};
          const nearestIndex = (values, target) => values.reduce(
            (best, value, index) => Math.abs(value - target)
              < Math.abs(values[best] - target) ? index : best, 0);
          const runtimeBox = value => Array.isArray(value && value.box)
            && value.box.length === 4 ? value.box.map(Number) : null;
          const isStylizedFaceRuntime = value =>
            value && value.source_medium === '3d render';
          {selector.group(1)}
          {policy.group(1)}
          {mouth_mask.group(1)}
          {tone_shift.group(1)}
          {difference_alpha.group(1)}
          {preserve_mask.group(1)}
          {handoff_ready.group(1)}
          {legacy_handoff_ready.group(1)}
          {emotion_sample.group(1)}
          const oldImage = {{ id: 'old' }};
          const newImage = {{ id: 'new' }};
          const alphaPixels = new Uint8ClampedArray([
            1, 2, 3, 17, 4, 5, 6, 128
          ]);
          const alphaCount = preserveMaskAlpha(alphaPixels);
          process.stdout.write(JSON.stringify({{
            mouth: [
              selectStylizedVisemeImage(oldImage, newImage, .49).id,
              selectStylizedVisemeImage(oldImage, newImage, .50).id
            ],
            mouthMask: [
              stylizedMouthMaskAlpha(49, 51, 100, 100),
              stylizedMouthMaskAlpha(49, 0, 100, 100),
              stylizedMouthMaskAlpha(0, 0, 100, 100)
            ],
            toneShift: stylizedMouthToneShift(
              [100, 200, 250], [160, 150, 0]),
            differenceAlpha: [
              stylizedMouthDifferenceAlpha(6, 1),
              stylizedMouthDifferenceAlpha(42, 1),
              stylizedMouthDifferenceAlpha(255, 0)
            ],
            preservedMask: {{ count: alphaCount, pixels: Array.from(alphaPixels) }},
            handoff: [
              authoredHeadHandoffReady({{
                head_composite: 'replace', head_clear_mask: 'clear.png'
              }}, {{}}, {{}}),
              authoredHeadHandoffReady({{
                head_composite: 'replace', head_clear_mask: 'clear.png',
                head_handoff_version: 2
              }}, {{}}, {{}}),
              authoredHeadHandoffReady({{
                head_composite: 'replace', head_clear_mask: 'clear.png',
                head_handoff_version: 3
              }}, {{}}, {{}})
            ],
            legacyHandoff: [
              legacyStylizedHeadHandoffReady({{
                source_medium: '3d render',
                stylized_mouth: {{ basis: 'canonical-outer-lip-v1', box: [1, 2, 3, 4] }}
              }}, {{
                head_composite: 'replace', head_clear_mask: 'clear.png'
              }}, {{}}, {{}}),
              legacyStylizedHeadHandoffReady({{
                source_medium: '3d render',
                stylized_mouth: {{ basis: 'canonical-outer-lip-v1', box: [1, 2, 3, 4] }}
              }}, {{
                head_composite: 'replace', head_clear_mask: 'clear.png',
                head_handoff_version: 1
              }}, {{}}, {{}})
            ],
            emotion: [
              stylizedEmotionMouthSample(
                [0, .34, .68, 1], ['sil', 'aa'], .52, 2,
                'sil', 'aa', .49),
              stylizedEmotionMouthSample(
                [0, .34, .68, 1], ['sil', 'aa'], .52, 2,
                'sil', 'aa', .50)
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
        self.assertGreater(observed["mouthMask"][0], .99)
        self.assertLess(observed["mouthMask"][1], .01)
        self.assertEqual(0, observed["mouthMask"][2])
        self.assertEqual([24, -24, -24], observed["toneShift"])
        self.assertEqual([0, 1, 0], observed["differenceAlpha"])
        self.assertEqual(2, observed["preservedMask"]["count"])
        self.assertEqual(
            [255, 255, 255, 17, 255, 255, 255, 128],
            observed["preservedMask"]["pixels"])
        self.assertEqual([False, True, False], observed["handoff"])
        self.assertEqual([True, False], observed["legacyHandoff"])
        self.assertEqual([
            {"state": 2, "row": 4, "weight": 1},
            {"state": 2, "row": 5, "weight": 1},
        ], observed["emotion"])
        self.assertEqual([
            "static-canonical", "static-canonical",
            "stylized-closed", "photo-strip",
        ], observed["lids"])


if __name__ == "__main__":
    unittest.main()
