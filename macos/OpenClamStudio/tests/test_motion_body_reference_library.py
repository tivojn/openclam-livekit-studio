"""Composite Walk receipts survive recomposition, but not changed references."""
import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import library


class MotionBodyReferenceLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.avatar = Path(self.temporary.name)
        self.body = self.avatar / "body"
        self.motion = self.avatar / "motion"
        self.body.mkdir()
        self.motion.mkdir()
        for view in ("front", "side", "back"):
            (self.body / f"source-{view}.png").write_bytes(view.encode())
        # These are the actual fresh Celine body/motion receipt shapes: the
        # body's legacy walk_source remains side, while the authored standard
        # Walk primary is front with side explicitly bound as supporting.
        self.body_metadata = {
            "v": 3,
            "views": {view: {"source": f"source-{view}.png"}
                      for view in ("front", "side", "back")},
            "motion_reference": {
                "walk_view": "side", "walk_source": "source-side.png",
                "idle_view": "front", "idle_source": "source-front.png",
                "move_view": "front", "move_source": "source-front.png",
            },
        }
        self.write_json(self.body / "body.json", self.body_metadata)
        self.write_json(self.avatar / "manifest.json", {
            "source_medium_override": "illustration",
        })
        self.walk_reference = dict(
            self.reference("front"), view="front+right-side",
            use="Horizon Walk front proportions, wardrobe, and color authority",
            supporting=[dict(self.reference("side"),
                             use="secondary side-body geometry only")],
        )
        self.metadata = {"v": 18, "body_references": {}}
        self.add_clip("walk", self.walk_reference)
        self.add_clip("idle", dict(self.reference("front"), view="front"))
        self.walk_id = library.archive_motion(str(self.avatar), "walk")
        self.idle_id = library.archive_motion(str(self.avatar), "idle")

    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value, indent=1))

    def reference(self, view):
        name = f"source-{view}.png"
        return {"file": name,
                "sha256": hashlib.sha256((self.body / name).read_bytes()).hexdigest()}

    def add_clip(self, kind, reference):
        (self.motion / f"{kind}-0.png").write_bytes(f"{kind}-sheet".encode())
        (self.motion / f"{kind}-alpha.mov").write_bytes(f"{kind}-alpha".encode())
        (self.motion / "raw").mkdir(exist_ok=True)
        (self.motion / "raw" / f"{kind}-source.mp4").write_bytes(
            f"{kind}-raw-video".encode())
        self.metadata[kind] = {
            "fps": 24 if kind == "walk" else 12,
            "frames": 52 if kind == "walk" else 73,
            "sheets": [{"image": f"{kind}-0.png", "first": 0, "count": 1}],
            "alpha_video": f"{kind}-alpha.mov",
            "source_medium": "illustration",
            "source_medium_quality": {
                "v": 1, "strict": True, "valid": True,
                "expected": "illustration", "available": True,
                "matching_samples": 2,
            },
        }
        self.metadata["body_references"][kind] = reference
        self.write_json(self.motion / "motion.json", self.metadata)

    def compatible(self, reference, kind="walk"):
        return library._motion_body_reference_compatible(
            str(self.avatar), kind, reference)

    def set_stored_reference(self, reference):
        self.metadata["body_references"]["walk"] = reference
        self.write_json(self.motion / "motion.json", self.metadata)
        path = (self.avatar / "library" / "motion" / "walk"
                / self.walk_id / "set.json")
        record = json.loads(path.read_text())
        record["body_reference"] = reference
        self.write_json(path, record)

    def assert_walk_rejected_by_all_entry_points(self):
        self.assertFalse(library.list_motion_sets(str(self.avatar), "walk")[0]["compatible"])
        with self.assertRaisesRegex(ValueError, "incompatible"):
            library.activate_motion(str(self.avatar), "walk", self.walk_id)
        metadata = library.reconcile_motion_with_body(str(self.avatar))
        self.assertNotIn("walk", metadata or {})
        self.assertFalse((self.motion / "raw" / "walk-source.mp4").exists())
        self.assertIsNone(library._read_index(str(self.avatar))["active"]["walk"])

    def test_unchanged_celine_recompose_retains_canonical_walk_byte_for_byte(self):
        before = {str(path.relative_to(self.motion)): path.read_bytes()
                  for path in self.motion.rglob("*") if path.is_file()}
        # The recompositor changes masks only; raw body plates are unchanged.
        (self.body / "head-mask.png").write_bytes(b"recomposed-mask-v4")
        (self.body / "head-clear-mask.png").write_bytes(b"recomposed-clear-v4")
        with mock.patch.object(library, "strip_canonical_motion",
                               wraps=library.strip_canonical_motion) as strip:
            metadata = library.reconcile_motion_with_body(str(self.avatar))
        strip.assert_not_called()
        self.assertEqual(metadata, self.metadata)
        self.assertEqual(before, {str(path.relative_to(self.motion)): path.read_bytes()
                                 for path in self.motion.rglob("*") if path.is_file()})
        self.assertEqual(library._read_index(str(self.avatar))["active"]["walk"],
                         self.walk_id)

    def test_unchanged_composite_archive_is_listed_and_can_activate(self):
        record = library.list_motion_sets(str(self.avatar), "walk")[0]
        self.assertTrue(record["compatible"])
        self.assertTrue(record["active"])
        library.strip_canonical_motion(str(self.avatar), "walk")
        activated = library.activate_motion(str(self.avatar), "walk", self.walk_id)
        self.assertEqual(activated["body_references"]["walk"], self.walk_reference)
        self.assertEqual((self.motion / "raw" / "walk-source.mp4").read_bytes(),
                         b"walk-raw-video")
        self.assertEqual(activated["idle"], self.metadata["idle"])

    def test_reconcile_restores_compatible_composite_archive(self):
        library.strip_canonical_motion(str(self.avatar), "walk")
        restored = library.reconcile_motion_with_body(str(self.avatar))
        self.assertEqual(restored["body_references"]["walk"], self.walk_reference)
        self.assertEqual((self.motion / "raw" / "walk-source.mp4").read_bytes(),
                         b"walk-raw-video")

    def test_changed_primary_front_rejects_canonical_and_archived_walk(self):
        (self.body / "source-front.png").write_bytes(b"different-front")
        self.assert_walk_rejected_by_all_entry_points()

    def test_changed_supporting_side_rejects_walk_but_retains_idle(self):
        idle_before = (self.motion / "raw" / "idle-source.mp4").read_bytes()
        (self.body / "source-side.png").write_bytes(b"repaired-side")
        self.assert_walk_rejected_by_all_entry_points()
        self.assertEqual((self.motion / "raw" / "idle-source.mp4").read_bytes(), idle_before)
        self.assertTrue(library.list_motion_sets(str(self.avatar), "idle")[0]["compatible"])

    def test_all_supporting_sources_must_match_not_any_matching_digest(self):
        reference = copy.deepcopy(self.walk_reference)
        reference["supporting"].append(self.reference("back"))
        self.assertTrue(self.compatible(reference))
        (self.body / "source-back.png").write_bytes(b"different-back")
        self.assertFalse(self.compatible(reference))

    def test_composite_requires_side_support_and_named_front_primary(self):
        variants = []
        for supporting in ([], None, {}, "source-side.png", [None],
                           [self.reference("front")], [self.reference("back")]):
            variants.append(dict(self.walk_reference, supporting=supporting))
        missing_support = copy.deepcopy(self.walk_reference)
        missing_support.pop("supporting")
        variants.append(missing_support)
        missing_primary = copy.deepcopy(self.walk_reference)
        missing_primary.pop("file")
        variants.append(missing_primary)
        variants.append(dict(self.walk_reference, **self.reference("side")))
        for reference in variants:
            with self.subTest(reference=reference):
                self.assertFalse(self.compatible(reference))
        self.assertFalse(self.compatible(self.walk_reference, kind="idle"))

    def test_missing_supporting_receipt_rejected_by_all_entry_points(self):
        reference = copy.deepcopy(self.walk_reference)
        reference.pop("supporting")
        self.set_stored_reference(reference)
        self.assert_walk_rejected_by_all_entry_points()

    def test_malformed_primary_and_supporting_hashes_are_rejected(self):
        for digest in (None, "", "front", "g" * 64, "0" * 64, [], 1):
            for primary in (True, False):
                reference = copy.deepcopy(self.walk_reference)
                target = reference if primary else reference["supporting"][0]
                target["sha256"] = digest
                with self.subTest(digest=digest, primary=primary):
                    self.assertFalse(self.compatible(reference))

    def test_unsafe_receipt_paths_are_never_basename_normalised(self):
        for name in ("../source-front.png", "body/source-front.png",
                     str(self.body / "source-front.png"), "..\\source-front.png",
                     "source-front.png\0", "C:source-front.png", "", None, []):
            reference = dict(self.walk_reference, file=name)
            with self.subTest(name=name):
                self.assertFalse(self.compatible(reference))
        reference = copy.deepcopy(self.walk_reference)
        reference["supporting"][0]["file"] = "../source-side.png"
        self.assertFalse(self.compatible(reference))

    def test_undeclared_file_with_matching_digest_is_not_a_source(self):
        (self.body / "head-mask.png").write_bytes(b"side")
        reference = copy.deepcopy(self.walk_reference)
        reference["supporting"][0]["file"] = "head-mask.png"
        self.set_stored_reference(reference)
        self.assert_walk_rejected_by_all_entry_points()

    def test_symlink_cannot_supply_a_matching_supporting_reference(self):
        external = self.avatar / "unrelated-side.png"
        external.write_bytes(b"side")
        (self.body / "source-side.png").unlink()
        (self.body / "source-side.png").symlink_to(external)
        self.assert_walk_rejected_by_all_entry_points()

    def test_duplicate_or_nested_supporting_references_are_rejected(self):
        for entry in (self.reference("side"),
                      dict(self.reference("back"), supporting=[])):
            reference = copy.deepcopy(self.walk_reference)
            reference["supporting"].append(entry)
            self.assertFalse(self.compatible(reference))

    def test_unsafe_current_body_declaration_does_not_resolve_by_basename(self):
        self.body_metadata["views"]["side"]["source"] = "../source-side.png"
        self.write_json(self.body / "body.json", self.body_metadata)
        self.assertFalse(self.compatible(self.walk_reference))

    def test_legacy_side_only_walk_ignores_front_changes_but_not_side_changes(self):
        reference = dict(self.reference("side"), view="side")
        self.set_stored_reference(reference)
        (self.body / "source-front.png").write_bytes(b"new-front")
        self.assertTrue(self.compatible(reference))
        self.assertTrue(library.list_motion_sets(str(self.avatar), "walk")[0]["compatible"])
        self.assertIn("walk", library.reconcile_motion_with_body(str(self.avatar)))
        self.assertIn("walk", library.activate_motion(str(self.avatar), "walk", self.walk_id))
        (self.body / "source-side.png").write_bytes(b"new-side")
        self.assert_walk_rejected_by_all_entry_points()

    def test_legacy_digest_only_move_uses_its_current_front(self):
        reference = {"sha256": self.reference("front")["sha256"]}
        self.assertTrue(self.compatible(reference, kind="move"))
        self.assertFalse(self.compatible(reference, kind="walk"))
        self.add_clip("move", reference)
        set_id = library.archive_motion(str(self.avatar), "move")
        self.assertTrue(library.list_motion_sets(str(self.avatar), "move")[0]["compatible"])
        self.assertIn("move", library.activate_motion(str(self.avatar), "move", set_id))

    def test_legacy_source_png_fallback_and_front_legacy_walk(self):
        self.write_json(self.body / "body.json", {"v": 1})
        (self.body / "source.png").write_bytes(b"legacy-front")
        (self.body / "source-front.png").unlink()
        (self.body / "source-side.png").unlink()
        digest = hashlib.sha256(b"legacy-front").hexdigest()
        self.assertTrue(self.compatible({"sha256": digest}))
        self.assertTrue(self.compatible({"file": "source.png", "sha256": digest,
                                         "view": "front-legacy"}))
        self.assertFalse(self.compatible(dict(self.walk_reference, sha256=digest)))

    def test_front_legacy_receipt_checks_front_and_unsafe_legacy_source_fails(self):
        reference = dict(self.reference("front"), view="front-legacy")
        self.assertTrue(self.compatible(reference))
        self.body_metadata["motion_reference"]["idle_source"] = "../source-front.png"
        self.write_json(self.body / "body.json", self.body_metadata)
        self.assertFalse(self.compatible(self.reference("front"), kind="idle"))

    def test_valid_body_references_do_not_bypass_medium_gate(self):
        path = (self.avatar / "library" / "motion" / "walk"
                / self.walk_id / "set.json")
        record = json.loads(path.read_text())
        record["clip"]["source_medium_quality"]["matching_samples"] = 0
        self.write_json(path, record)
        self.assertTrue(self.compatible(self.walk_reference))
        self.assertFalse(library.list_motion_sets(str(self.avatar), "walk")[0]["compatible"])
        with self.assertRaisesRegex(ValueError, "incompatible"):
            library.activate_motion(str(self.avatar), "walk", self.walk_id)


if __name__ == "__main__":
    unittest.main()
