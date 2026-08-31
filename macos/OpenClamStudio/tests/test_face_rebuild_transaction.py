"""A rejected canonical-head rebuild must leave the published avatar usable."""
from contextlib import ExitStack
import json
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import build, export, visemes


def _image(value):
    return np.full((96, 96, 3), value, dtype=np.uint8)


def _metrics(medium="illustration"):
    return {
        "yaw": 0.0,
        "pitch": 0.0,
        "roll": 0.0,
        "foreshortening": 1.0,
        "mouth_width_px": 180.0,
        "source_medium": medium,
        "warnings": [],
    }


def _write(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(payload)


def _read(path):
    with open(path, "rb") as handle:
        return handle.read()


def _ready_fixture(directory, medium="photograph"):
    """Install one complete ready avatar whose every authored lane is distinct."""
    cv2.imwrite(os.path.join(directory, "source.png"), _image(19))
    cv2.imwrite(os.path.join(directory, "source-keyframe.png"), _image(63))
    cv2.imwrite(os.path.join(directory, "head.png"), _image(31))
    cv2.imwrite(os.path.join(directory, "keyframe.png"), _image(47))
    _write(os.path.join(directory, "raw", "old-render.bin"), b"old raw")
    _write(os.path.join(directory, "visemes", "old-bank.bin"), b"old bank")
    _write(os.path.join(directory, "diag", "old-qa.bin"), b"old qa")
    _write(os.path.join(directory, "preview.mp4"), b"old preview")
    _write(os.path.join(directory, "sheet.jpg"), b"old sheet")
    _write(os.path.join(directory, "body", "front.png"), b"old body")
    _write(os.path.join(directory, "motion", "walk.rgba"), b"old motion")
    _write(os.path.join(directory, ".body-cache", "approved.bin"), b"body cache")
    _write(os.path.join(directory, ".motion-cache", "approved.bin"), b"motion cache")
    return {
        "slug": "transaction-avatar",
        "name": "Transaction Avatar",
        "status": "ready",
        "source": "source.png",
        "source_keyframe": "source-keyframe.png",
        "source_keyframe_medium": medium,
        "source_metrics": _metrics(medium),
        "metrics": _metrics(medium),
        "head": {
            "image": "head.png",
            "source_medium": medium,
            "remove_headwear": False,
            "headwear_policy": "preserve",
        },
        "body": {"front": "body/front.png", "identity": "old-head"},
        "motion": {"walk": "motion/walk.rgba", "identity": "old-head"},
        "preview": "preview.mp4",
        "sheet": "sheet.jpg",
        "progress": {"done": len(visemes.ORDER),
                     "total": len(visemes.ORDER), "stage": "done"},
    }


def _install_successful_build_mocks(stack):
    """Let build_avatar reach its destructive publication boundary cheaply."""
    def generate_head(_source, destination, **_kwargs):
        cv2.imwrite(destination, _image(211))
        return destination

    def prepare_head(_source, destination, **kwargs):
        # Keep the refreshed source crop visibly different from the staged head
        # crop so rollback assertions prove the right file was restored.
        value = 109 if os.path.basename(destination).startswith(
            ".source-keyframe") else 193
        cv2.imwrite(destination, _image(value))
        return _metrics(kwargs.get("source_medium") or "illustration")

    def generate_set(_keyframe, raw_dir, **_kwargs):
        paths = {}
        for name in visemes.ORDER:
            path = os.path.join(raw_dir, f"v_{name}.png")
            cv2.imwrite(path, _image(127))
            paths[name] = path
        return paths

    def compose_all(_keyframe, _raw, output, **kwargs):
        _write(os.path.join(output, "new-bank.bin"), b"new bank")
        _write(os.path.join(kwargs["diag_dir"], "new-qa.bin"), b"new qa")
        return ([{
            "name": name, "resid_px": 0.0, "outside_delta": 0.0,
        } for name in visemes.SPEECH_ORDER], {})

    def preview(_output, path, **_kwargs):
        _write(path, b"new preview")

    def sheet(_output, _keyframe, path, **_kwargs):
        _write(path, b"new sheet")

    stack.enter_context(mock.patch.object(
        build.generate, "default_head_provider",
        return_value={"name": "test", "model": "test"}))
    stack.enter_context(mock.patch.object(
        build.generate, "generate_head", side_effect=generate_head))
    stack.enter_context(mock.patch.object(
        build.prep, "build_keyframe", side_effect=prepare_head))
    stack.enter_context(mock.patch.object(
        build.generate, "generate_set", side_effect=generate_set))
    stack.enter_context(mock.patch.object(
        build.measure, "th_tongue_issue", return_value=None))
    stack.enter_context(mock.patch.object(
        build.rig, "from_manifest", return_value={}))
    stack.enter_context(mock.patch.object(
        build.compose, "compose_all", side_effect=compose_all))
    stack.enter_context(mock.patch.object(
        build.measure, "audit", return_value=([], [])))
    stack.enter_context(mock.patch.object(
        build.render, "preview", side_effect=preview))
    stack.enter_context(mock.patch.object(
        build.render, "contact_sheet", side_effect=sheet))
    stack.enter_context(mock.patch.object(
        export, "preflight_stylized_blink", return_value=None))


def _assert_authored_set_restored(testcase, directory, prior, error):
    restored = build.read_manifest("transaction-avatar")
    testcase.assertEqual(restored["status"], "ready")
    testcase.assertEqual(restored["head"], prior["head"])
    testcase.assertEqual(restored["body"], prior["body"])
    testcase.assertEqual(restored["motion"], prior["motion"])
    testcase.assertEqual(
        restored["source_metrics"]["source_medium"], "photograph")
    testcase.assertNotIn("source_medium_override", restored)
    testcase.assertIn(error, restored["error"])
    testcase.assertEqual(
        int(cv2.imread(os.path.join(directory, "source-keyframe.png"))[0, 0, 0]),
        63)
    for path, payload in (
            ("body/front.png", b"old body"),
            ("motion/walk.rgba", b"old motion"),
            (".body-cache/approved.bin", b"body cache"),
            (".motion-cache/approved.bin", b"motion cache")):
        testcase.assertEqual(_read(os.path.join(directory, path)), payload, path)
    testcase.assertFalse(any(
        name.startswith(".face-rebuild-") for name in os.listdir(directory)))
    for relative in build.FACE_REBUILD_TRANSIENTS:
        testcase.assertFalse(os.path.exists(os.path.join(directory, relative)))


class FaceRebuildTransactionTests(unittest.TestCase):
    def test_unusable_blink_restores_face_before_invalidating_body_and_motion(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            prior = _ready_fixture(directory)
            stack.enter_context(mock.patch.object(
                build, "adir", return_value=directory))
            build.write_manifest("transaction-avatar", prior)
            _install_successful_build_mocks(stack)
            stack.enter_context(mock.patch.object(
                export, "preflight_stylized_blink",
                side_effect=export.StylizedBlinkNotReady(
                    "closed eyelid does not cover the character's eye")))
            invalidate = stack.enter_context(mock.patch.object(
                build, "_defer_face_rebuild_artifact",
                wraps=build._defer_face_rebuild_artifact))

            with self.assertRaisesRegex(
                    export.StylizedBlinkNotReady, "closed eyelid"):
                build.build_avatar(
                    "transaction-avatar", source_medium="3d render",
                    log=lambda _message: None)

            invalidate.assert_not_called()
            _assert_authored_set_restored(
                self, directory, prior, "closed eyelid")

    def test_manifest_restore_has_no_pre_unlink_crash_window(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "adir", return_value=directory):
            prior = _ready_fixture(directory, medium="illustration")
            build.write_manifest("transaction-avatar", prior)
            transaction = build._begin_face_rebuild_transaction(
                directory, prior)
            interrupted = dict(prior)
            interrupted["status"] = "building"
            build.write_manifest("transaction-avatar", interrupted)

            live_manifest = os.path.join(directory, "manifest.json")
            saved_manifest = os.path.join(
                transaction["backup"], "manifest.json")
            real_replace = build.os.replace

            def fail_manifest_swap(source, destination):
                if source == saved_manifest and destination == live_manifest:
                    raise OSError("simulated manifest swap interruption")
                return real_replace(source, destination)

            with mock.patch.object(
                    build.os, "replace", side_effect=fail_manifest_swap):
                with self.assertRaisesRegex(
                        OSError, "manifest swap interruption"):
                    build._restore_face_rebuild_transaction(
                        directory, transaction)

            # os.replace failed before its atomic commit, so the current
            # manifest remains readable.  The rollback snapshot and journal
            # also remain available for the next startup attempt.
            self.assertEqual(
                "building", build.read_manifest("transaction-avatar")["status"])
            self.assertTrue(os.path.isfile(saved_manifest))
            self.assertTrue(os.path.isfile(os.path.join(
                transaction["backup"], build._FACE_REBUILD_JOURNAL)))

    def test_recovery_scan_finds_journal_when_live_manifest_is_missing(self):
        with tempfile.TemporaryDirectory() as registry_root, \
                mock.patch.object(build, "AVATARS", registry_root):
            directory = os.path.join(registry_root, "transaction-avatar")
            os.mkdir(directory)
            with mock.patch.object(build, "adir", return_value=directory):
                prior = _ready_fixture(directory, medium="3d render")
                build.write_manifest("transaction-avatar", prior)
                transaction = build._begin_face_rebuild_transaction(
                    directory, prior)
                os.remove(os.path.join(directory, "manifest.json"))

                self.assertEqual(
                    ["transaction-avatar"],
                    build.face_rebuild_recovery_slugs())
                self.assertEqual(
                    ["restored"],
                    build.recover_face_rebuild_transactions(
                        "transaction-avatar", log=lambda _message: None))
                self.assertEqual(
                    "ready", build.read_manifest(
                        "transaction-avatar")["status"])
                self.assertFalse(os.path.exists(transaction["backup"]))

    def test_restart_recovery_restores_every_source_lane_after_crash(self):
        for medium in ("photograph", "illustration", "3d render"):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(build, "adir", return_value=directory):
                prior = _ready_fixture(directory, medium=medium)
                build.write_manifest("transaction-avatar", prior)
                transaction = build._begin_face_rebuild_transaction(
                    directory, prior)
                build._set_face_rebuild_transaction_phase(
                    transaction, "building")

                # Simulate a killed process after the new face overwrote its
                # live files and the old body/source crop were displaced.
                cv2.imwrite(os.path.join(directory, "head.png"), _image(211))
                cv2.imwrite(os.path.join(directory, "keyframe.png"), _image(193))
                _write(os.path.join(directory, "raw", "new-render.bin"),
                       b"new raw")
                _write(os.path.join(directory, "visemes", "new-bank.bin"),
                       b"new bank")
                for relative in build.FACE_REBUILD_DERIVED_ARTIFACTS:
                    build._defer_face_rebuild_artifact(
                        directory, transaction, relative)
                build._defer_face_rebuild_artifact(
                    directory, transaction, "source-keyframe.png")
                interrupted = dict(prior)
                interrupted.update(
                    status="building",
                    head={"image": "head.png", "source_medium": medium},
                    body=None,
                    motion=None,
                )
                build.write_manifest("transaction-avatar", interrupted)

                outcomes = build.recover_face_rebuild_transactions(
                    "transaction-avatar", log=lambda _message: None)

                self.assertEqual(["restored"], outcomes)
                restored = build.read_manifest("transaction-avatar")
                self.assertEqual("ready", restored["status"])
                self.assertEqual(medium,
                                 restored["head"]["source_medium"])
                self.assertEqual(prior["body"], restored["body"])
                self.assertEqual(prior["motion"], restored["motion"])
                self.assertEqual(
                    int(cv2.imread(os.path.join(
                        directory, "head.png"))[0, 0, 0]), 31)
                self.assertEqual(
                    int(cv2.imread(os.path.join(
                        directory, "source-keyframe.png"))[0, 0, 0]), 63)
                self.assertEqual(
                    _read(os.path.join(directory, "body", "front.png")),
                    b"old body")
                self.assertEqual(
                    _read(os.path.join(directory, "motion", "walk.rgba")),
                    b"old motion")
                self.assertFalse(any(
                    name.startswith(".face-rebuild-")
                    for name in os.listdir(directory)))

    def test_restart_recovery_never_overwrites_a_new_ready_runtime(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "adir", return_value=directory):
            prior = _ready_fixture(directory, medium="illustration")
            build.write_manifest("transaction-avatar", prior)
            transaction = build._begin_face_rebuild_transaction(
                directory, prior)
            build._set_face_rebuild_transaction_phase(transaction, "building")
            for relative in build.FACE_REBUILD_DERIVED_ARTIFACTS:
                build._defer_face_rebuild_artifact(
                    directory, transaction, relative)
            build._defer_face_rebuild_artifact(
                directory, transaction, "source-keyframe.png")

            # This is the successfully published replacement.  The process
            # died after the ready manifest commit but before backup cleanup.
            cv2.imwrite(os.path.join(directory, "head.png"), _image(221))
            cv2.imwrite(os.path.join(directory, "keyframe.png"), _image(223))
            cv2.imwrite(
                os.path.join(directory, "source-keyframe.png"), _image(225))
            _write(os.path.join(directory, "raw", "current-render.bin"),
                   b"current raw")
            _write(os.path.join(directory, "visemes", "current-bank.bin"),
                   b"current bank")
            _write(os.path.join(directory, "body", "front.png"),
                   b"current body")
            _write(os.path.join(directory, "motion", "walk.rgba"),
                   b"current motion")
            current = dict(prior)
            current.update(
                status="ready",
                head={"image": "head.png", "source_medium": "illustration",
                      "prompt_version": 999},
                body={"front": "body/front.png", "identity": "new-head"},
                motion={"walk": "motion/walk.rgba", "identity": "new-head"},
            )
            build.write_manifest("transaction-avatar", current)

            outcomes = build.recover_face_rebuild_transactions(
                "transaction-avatar", log=lambda _message: None)

            self.assertEqual(["kept-current"], outcomes)
            self.assertEqual(
                221, int(cv2.imread(os.path.join(
                    directory, "head.png"))[0, 0, 0]))
            self.assertEqual(
                225, int(cv2.imread(os.path.join(
                    directory, "source-keyframe.png"))[0, 0, 0]))
            self.assertEqual(
                b"current body",
                _read(os.path.join(directory, "body", "front.png")))
            self.assertEqual(
                b"current motion",
                _read(os.path.join(directory, "motion", "walk.rgba")))
            saved = build.read_manifest("transaction-avatar")
            self.assertEqual(999, saved["head"]["prompt_version"])
            self.assertEqual("new-head", saved["body"]["identity"])
            self.assertFalse(any(
                name.startswith(".face-rebuild-")
                for name in os.listdir(directory)))

    def test_incomplete_snapshot_is_cleaned_without_touching_ready_avatar(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "adir", return_value=directory):
            current = _ready_fixture(directory, medium="3d render")
            current["head"]["prompt_version"] = 77
            build.write_manifest("transaction-avatar", current)
            orphan = os.path.join(directory, ".face-rebuild-interrupted-copy")
            os.makedirs(orphan)
            cv2.imwrite(os.path.join(orphan, "head.png"), _image(7))
            before_head = _read(os.path.join(directory, "head.png"))
            before_manifest = build.read_manifest("transaction-avatar")

            outcomes = build.recover_face_rebuild_transactions(
                "transaction-avatar", log=lambda _message: None)

            self.assertEqual(["kept-current"], outcomes)
            self.assertEqual(before_head, _read(os.path.join(
                directory, "head.png")))
            self.assertEqual(before_manifest,
                             build.read_manifest("transaction-avatar"))
            self.assertFalse(os.path.exists(orphan))

    def test_restart_recovery_refuses_unknown_deferred_artifacts(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "adir", return_value=directory):
            prior = _ready_fixture(directory, medium="illustration")
            build.write_manifest("transaction-avatar", prior)
            transaction = build._begin_face_rebuild_transaction(
                directory, prior)
            journal = os.path.join(
                transaction["backup"], build._FACE_REBUILD_JOURNAL)
            with open(journal, encoding="utf-8") as handle:
                payload = json.load(handle)
            payload["deferred"]["private.keep"] = True
            with open(journal, "w", encoding="utf-8") as handle:
                json.dump(payload, handle)
            _write(os.path.join(directory, "private.keep"), b"do not touch")
            interrupted = dict(prior)
            interrupted["status"] = "building"
            build.write_manifest("transaction-avatar", interrupted)

            outcomes = build.recover_face_rebuild_transactions(
                "transaction-avatar", log=lambda _message: None)

            self.assertEqual(["unrecoverable"], outcomes)
            self.assertEqual(
                b"do not touch", _read(os.path.join(directory, "private.keep")))
            self.assertTrue(os.path.isdir(transaction["backup"]))

    def test_failed_headwear_toggle_restores_face_body_and_motion(self):
        with tempfile.TemporaryDirectory() as directory:
            old_head = _image(31)
            old_keyframe = _image(47)
            cv2.imwrite(os.path.join(directory, "head.png"), old_head)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), old_keyframe)
            cv2.imwrite(
                os.path.join(directory, "source-keyframe.png"), _image(63))
            _write(os.path.join(directory, "raw", "old-render.bin"), b"old raw")
            _write(os.path.join(directory, "visemes", "old-bank.bin"), b"old bank")
            _write(os.path.join(directory, "diag", "old-qa.bin"), b"old qa")
            _write(os.path.join(directory, "preview.mp4"), b"old preview")
            _write(os.path.join(directory, "sheet.jpg"), b"old sheet")
            _write(os.path.join(directory, "body", "front.png"), b"old body")
            _write(os.path.join(directory, "motion", "walk.rgba"), b"old motion")
            _write(os.path.join(directory, ".body-cache", "approved.bin"), b"body cache")
            _write(os.path.join(directory, ".motion-cache", "approved.bin"), b"motion cache")

            prior = {
                "slug": "transaction-avatar",
                "name": "Transaction Avatar",
                "status": "ready",
                "source_keyframe": "source-keyframe.png",
                "source_metrics": _metrics(),
                "metrics": _metrics(),
                "head": {
                    "image": "head.png",
                    "source_medium": "illustration",
                    "remove_headwear": False,
                    "headwear_policy": "preserve",
                },
                "body": {"front": "body/front.png", "identity": "old-head"},
                "motion": {"walk": "motion/walk.rgba", "identity": "old-head"},
                "preview": "preview.mp4",
                "sheet": "sheet.jpg",
                "progress": {"done": len(visemes.ORDER),
                             "total": len(visemes.ORDER), "stage": "done"},
            }

            repair = {
                "kind": "viseme_fallback",
                "profile": {},
                "changes": [],
                "rejected_items": ["ah"],
                "reasons": ["ah has no composable speech plate"],
            }

            def generate_head(_source, destination, **_kwargs):
                cv2.imwrite(destination, _image(211))
                return destination

            def prepare_head(_source, destination, **_kwargs):
                cv2.imwrite(destination, _image(193))
                return _metrics()

            def generate_set(_keyframe, raw_dir, **_kwargs):
                _write(os.path.join(raw_dir, "new-render.bin"), b"new raw")
                return {
                    name: os.path.join(raw_dir, f"v_{name}.png")
                    for name in visemes.ORDER
                }

            def reject_composition(_keyframe, _raw, output, **kwargs):
                _write(os.path.join(output, "new-bank.bin"), b"new bank")
                _write(os.path.join(kwargs["diag_dir"], "new-qa.bin"), b"new qa")
                raise build.CalibrationRejected(
                    "required speech shape ah was rejected", repair)

            with mock.patch.object(build, "adir", return_value=directory):
                build.write_manifest("transaction-avatar", prior)
                with mock.patch.object(
                        build.generate, "default_head_provider",
                        return_value={"name": "test", "model": "test"}), \
                        mock.patch.object(
                            build.generate, "generate_head",
                            side_effect=generate_head), \
                        mock.patch.object(
                            build.prep, "build_keyframe",
                            side_effect=prepare_head), \
                        mock.patch.object(
                            build.generate, "generate_set",
                            side_effect=generate_set), \
                        mock.patch.object(
                            build.measure, "th_tongue_issue",
                            return_value=None), \
                        mock.patch.object(
                            build.compose, "compose_all",
                            side_effect=reject_composition):
                    with self.assertRaisesRegex(
                            build.CalibrationRejected,
                            "required speech shape ah"):
                        build.build_avatar(
                            "transaction-avatar",
                            remove_headwear=True,
                            log=lambda _message: None)

                restored = build.read_manifest("transaction-avatar")

            self.assertEqual(restored["status"], "ready")
            self.assertEqual(restored["head"], prior["head"])
            self.assertEqual(restored["body"], prior["body"])
            self.assertEqual(restored["motion"], prior["motion"])
            self.assertEqual(restored["rig_repair"], repair)
            self.assertIn("required speech shape ah", restored["error"])
            np.testing.assert_array_equal(
                cv2.imread(os.path.join(directory, "head.png")), old_head)
            np.testing.assert_array_equal(
                cv2.imread(os.path.join(directory, "keyframe.png")),
                old_keyframe)
            self.assertEqual(
                _read(os.path.join(directory, "raw", "old-render.bin")),
                b"old raw")
            self.assertEqual(
                _read(os.path.join(directory, "visemes", "old-bank.bin")),
                b"old bank")
            self.assertEqual(
                _read(os.path.join(directory, "diag", "old-qa.bin")),
                b"old qa")
            self.assertFalse(
                os.path.exists(os.path.join(directory, "raw", "new-render.bin")))
            self.assertFalse(
                os.path.exists(os.path.join(directory, "visemes", "new-bank.bin")))
            self.assertFalse(
                os.path.exists(os.path.join(directory, "diag", "new-qa.bin")))
            for path in (
                    "body/front.png", "motion/walk.rgba",
                    ".body-cache/approved.bin", ".motion-cache/approved.bin"):
                self.assertTrue(os.path.isfile(os.path.join(directory, path)), path)
            self.assertFalse(any(
                name.startswith(".face-rebuild-")
                for name in os.listdir(directory)))
            for relative in build.FACE_REBUILD_TRANSIENTS:
                self.assertFalse(os.path.exists(os.path.join(directory, relative)))

    def test_source_keyframe_replace_failure_restores_entire_authored_set(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            prior = _ready_fixture(directory)
            stack.enter_context(mock.patch.object(build, "adir", return_value=directory))
            build.write_manifest("transaction-avatar", prior)
            _install_successful_build_mocks(stack)
            real_replace = build.os.replace

            def fail_source_keyframe(source, destination):
                if os.path.basename(source) == ".source-keyframe.override.png":
                    raise OSError("source-keyframe replace failed")
                return real_replace(source, destination)

            stack.enter_context(mock.patch.object(
                build.os, "replace", side_effect=fail_source_keyframe))
            with self.assertRaisesRegex(OSError, "source-keyframe replace failed"):
                build.build_avatar(
                    "transaction-avatar", source_medium="illustration",
                    log=lambda _message: None)
            _assert_authored_set_restored(
                self, directory, prior, "source-keyframe replace failed")

    def test_body_or_motion_invalidation_failure_restores_every_prior_lane(self):
        for failing_name in ("body", "motion"):
            with self.subTest(failing_name=failing_name), \
                    tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
                prior = _ready_fixture(directory)
                stack.enter_context(mock.patch.object(
                    build, "adir", return_value=directory))
                build.write_manifest("transaction-avatar", prior)
                _install_successful_build_mocks(stack)
                real_defer = build._defer_face_rebuild_artifact

                def fail_invalidation(root, transaction, path):
                    name = os.path.basename(os.path.normpath(path))
                    if name == failing_name:
                        raise OSError(f"{failing_name} invalidation failed")
                    return real_defer(root, transaction, path)

                stack.enter_context(mock.patch.object(
                    build, "_defer_face_rebuild_artifact",
                    side_effect=fail_invalidation))
                with self.assertRaisesRegex(
                        OSError, f"{failing_name} invalidation failed"):
                    build.build_avatar(
                        "transaction-avatar", source_medium="illustration",
                        log=lambda _message: None)
                _assert_authored_set_restored(
                    self, directory, prior,
                    f"{failing_name} invalidation failed")

    def test_final_manifest_failure_restores_source_body_motion_and_face(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            prior = _ready_fixture(directory)
            stack.enter_context(mock.patch.object(build, "adir", return_value=directory))
            build.write_manifest("transaction-avatar", prior)
            _install_successful_build_mocks(stack)
            real_write_manifest = build.write_manifest
            failed = [False]

            def fail_final_manifest(slug, payload):
                is_final = (
                    payload.get("status") == "ready"
                    and "body" not in payload
                    and "motion" not in payload
                    and payload.get("source_medium_override") == "illustration")
                if is_final and not failed[0]:
                    failed[0] = True
                    raise OSError("final manifest write failed")
                return real_write_manifest(slug, payload)

            stack.enter_context(mock.patch.object(
                build, "write_manifest", side_effect=fail_final_manifest))
            with self.assertRaisesRegex(OSError, "final manifest write failed"):
                build.build_avatar(
                    "transaction-avatar", source_medium="illustration",
                    log=lambda _message: None)
            self.assertTrue(failed[0])
            _assert_authored_set_restored(
                self, directory, prior, "final manifest write failed")

    def test_failed_rollback_manifest_write_retains_recovery_transaction(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            prior = _ready_fixture(directory)
            stack.enter_context(mock.patch.object(build, "adir", return_value=directory))
            build.write_manifest("transaction-avatar", prior)
            _install_successful_build_mocks(stack)
            real_write_manifest = build.write_manifest
            final_failed = [False]

            def fail_commit_and_restore(slug, payload):
                is_candidate_commit = (
                    payload.get("status") == "ready"
                    and "body" not in payload
                    and "motion" not in payload
                    and payload.get("source_medium_override") == "illustration")
                is_restored_manifest = (
                    final_failed[0]
                    and payload.get("status") == "ready"
                    and payload.get("body") == prior["body"]
                    and payload.get("motion") == prior["motion"])
                if is_candidate_commit:
                    final_failed[0] = True
                    raise OSError("final manifest write failed")
                if is_restored_manifest:
                    raise OSError("rollback manifest write failed")
                return real_write_manifest(slug, payload)

            stack.enter_context(mock.patch.object(
                build, "write_manifest", side_effect=fail_commit_and_restore))
            with self.assertRaisesRegex(OSError, "rollback manifest write failed"):
                build.build_avatar(
                    "transaction-avatar", source_medium="illustration",
                    log=lambda _message: None)

            transactions = [
                name for name in os.listdir(directory)
                if name.startswith(".face-rebuild-")]
            self.assertEqual(1, len(transactions))
            backup = os.path.join(directory, transactions[0])
            self.assertTrue(os.path.isdir(backup))
            # The restore transaction moves its original manifest back into
            # the live avatar before trying to append failure diagnostics.
            # Thus even a persistent diagnostic-write failure leaves the
            # known-good manifest in place while preserving transaction debris
            # for forensic recovery rather than silently deleting it.
            saved = build.read_manifest("transaction-avatar")
            self.assertEqual(prior["head"], saved["head"])
            self.assertEqual(prior["body"], saved["body"])
            self.assertEqual(prior["motion"], saved["motion"])


if __name__ == "__main__":
    unittest.main()
