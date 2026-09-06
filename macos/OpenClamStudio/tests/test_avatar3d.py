"""3D avatar packages: GLB validation, viseme coverage, and runtime publish."""
from __future__ import annotations

import io
import json
import os
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if os.path.join(PROJECT, "server") not in sys.path:
    sys.path.insert(0, os.path.join(PROJECT, "server"))
if PROJECT not in sys.path:
    sys.path.insert(0, PROJECT)

import avatar3d  # noqa: E402
from studio import build  # noqa: E402


def make_glb(document: dict, binary: bytes = b"\0\0\0\0") -> bytes:
    payload = json.dumps(document).encode("utf-8")
    payload += b" " * (-len(payload) % 4)
    binary += b"\0" * (-len(binary) % 4)
    body = struct.pack("<II", len(payload), 0x4E4F534A) + payload
    body += struct.pack("<II", len(binary), 0x004E4942) + binary
    return struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body


def rigged_document(target_names, joints=("hips", "spine_01", "neck_01", "head")):
    nodes = [{"name": name} for name in joints] + [{"name": "Face", "mesh": 0, "skin": 0}]
    return {
        "asset": {"version": "2.0", "generator": "test"},
        "nodes": nodes,
        "skins": [{"joints": list(range(len(joints)))}],
        "meshes": [{
            "name": "Face",
            "extras": {"targetNames": list(target_names)},
            "primitives": [{
                "attributes": {"POSITION": 0},
                "targets": [{"POSITION": 0} for _ in target_names],
            }],
        }],
        "accessors": [{"componentType": 5126, "count": 3, "type": "VEC3"}],
        "buffers": [{"byteLength": 4}],
    }


OCULUS = ["vrc.v_sil", "vrc.v_pp", "vrc.v_ff", "vrc.v_th", "vrc.v_dd", "vrc.v_kk",
          "vrc.v_ch", "vrc.v_ss", "vrc.v_nn", "vrc.v_rr", "vrc.v_aa", "vrc.v_ee",
          "vrc.v_ih", "vrc.v_oh", "vrc.v_ou", "eyeBlinkLeft", "eyeBlinkRight"]


def png_bytes(size=256):
    from PIL import Image
    buffer = io.BytesIO()
    Image.new("RGB", (size, size), (200, 40, 60)).save(buffer, "PNG")
    return buffer.getvalue()


class TemporaryRegistry:
    """Point studio.build at an empty avatar root for one test."""

    def __enter__(self):
        self.directory = tempfile.mkdtemp(prefix="openclam-3d-")
        self.patches = [
            patch.object(build, "ROOT", self.directory),
            patch.object(build, "AVATARS", os.path.join(self.directory, "avatars")),
            patch.object(build, "ACTIVE", os.path.join(self.directory, "active.json")),
            patch.object(build, "COMPANION", os.path.join(self.directory, "companion.json")),
        ]
        for item in self.patches:
            item.start()
        return self.directory

    def __exit__(self, *_):
        for item in self.patches:
            item.stop()
        import shutil
        shutil.rmtree(self.directory, ignore_errors=True)


class InspectTests(unittest.TestCase):
    def write(self, data):
        handle = tempfile.NamedTemporaryFile(suffix=".glb", delete=False)
        handle.write(data)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_reports_targets_joints_and_full_direct_coverage(self):
        report = avatar3d.inspect_glb(self.write(make_glb(rigged_document(OCULUS))))
        self.assertEqual(report["morph_meshes"], 1)
        self.assertEqual(report["joints"], ["hips", "spine_01", "neck_01", "head"])
        self.assertEqual(len(report["targets"]), len(OCULUS))
        coverage = avatar3d.viseme_coverage(report["targets"])
        self.assertEqual(sorted(coverage["direct"]), sorted(avatar3d.VISEMES))
        self.assertEqual(coverage["missing"], [])
        self.assertTrue(coverage["blink"])
        self.assertEqual(coverage["direct"]["E"], "vrc.v_ee")

    def test_arkit_only_models_are_approximated_not_rejected(self):
        coverage = avatar3d.viseme_coverage(["jawOpen", "mouthFunnel", "mouthPucker",
                                             "eyeBlinkLeft", "mouthClose"])
        self.assertEqual(coverage["direct"], {})
        self.assertIn("aa", coverage["recipe"])
        self.assertIn("ou", coverage["recipe"])
        self.assertIn("PP", coverage["recipe"])
        self.assertIn("FF", coverage["missing"])

    def test_rejects_non_glb_and_wrong_version(self):
        with self.assertRaises(avatar3d.ModelError):
            avatar3d.inspect_glb(self.write(b"not a model at all, definitely not"))
        bad = make_glb(rigged_document(OCULUS))
        bad = b"glTF" + struct.pack("<I", 1) + bad[8:]
        with self.assertRaises(avatar3d.ModelError):
            avatar3d.inspect_glb(self.write(bad))

    def test_rejects_decoders_the_renderer_lacks_and_external_files(self):
        draco = rigged_document(OCULUS)
        draco["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        with self.assertRaisesRegex(avatar3d.ModelError, "draco"):
            avatar3d.inspect_glb(self.write(make_glb(draco)))
        external = rigged_document(OCULUS)
        external["images"] = [{"uri": "skin.png"}]
        with self.assertRaisesRegex(avatar3d.ModelError, "external texture"):
            avatar3d.inspect_glb(self.write(make_glb(external)))


class RegistryTests(unittest.TestCase):
    def test_create_publish_ensure_and_thumbnail(self):
        with TemporaryRegistry() as root:
            model = os.path.join(root, "tia.glb")
            with open(model, "wb") as handle:
                handle.write(make_glb(rigged_document(OCULUS)))
            manifest = avatar3d.create_avatar(model, "Tia Test", log=lambda *_: None)
            slug = manifest["slug"]
            self.assertEqual(slug, "tia-test")
            self.assertEqual(manifest["status"], "ready")
            self.assertTrue(avatar3d.is_3d(manifest))
            self.assertEqual(manifest["progress"], {"done": 15, "total": 15})
            self.assertEqual(manifest["warnings"], [])
            directory = build.adir(slug)
            self.assertTrue(os.path.isfile(os.path.join(directory, "model.glb")))
            self.assertTrue(os.path.isfile(os.path.join(directory, "keyframe.png")))
            runtime = os.path.join(directory, "runtime")
            with open(os.path.join(runtime, "manifest.json")) as handle:
                published = json.load(handle)
            self.assertEqual(published["renderer"], "3d")
            self.assertEqual(published["model"], "assets/model.glb")
            self.assertEqual(published["visemes"], avatar3d.VISEMES)
            self.assertTrue(published["thumbnail_pending"])
            self.assertTrue(os.path.isfile(os.path.join(runtime, "model.glb")))

            # A current runtime is reused; a stale version is republished.
            self.assertEqual(avatar3d.ensure_runtime(slug, log=lambda *_: None), runtime)
            with patch.object(avatar3d, "RUNTIME_VERSION", avatar3d.RUNTIME_VERSION + 1):
                avatar3d.ensure_runtime(slug, log=lambda *_: None)
                with open(os.path.join(runtime, "manifest.json")) as handle:
                    self.assertEqual(json.load(handle)["v"], avatar3d.RUNTIME_VERSION)

            avatar3d.set_thumbnail(slug, png_bytes())
            self.assertTrue(build.read_manifest(slug)["thumbnail_ready"])
            with open(os.path.join(runtime, "manifest.json")) as handle:
                self.assertFalse(json.load(handle)["thumbnail_pending"])
            with self.assertRaises(ValueError):
                avatar3d.set_thumbnail(slug, b"\x89PNG not really")

    def test_rejected_models_leave_no_directory_behind(self):
        with TemporaryRegistry() as root:
            model = os.path.join(root, "flat.glb")
            document = rigged_document([], joints=())
            document.pop("skins")
            document["meshes"][0]["primitives"][0].pop("targets")
            with open(model, "wb") as handle:
                handle.write(make_glb(document))
            with self.assertRaises(avatar3d.ModelError):
                avatar3d.create_avatar(model, "Static Prop", log=lambda *_: None)
            self.assertEqual(os.listdir(build.AVATARS) if os.path.isdir(build.AVATARS) else [], [])

    def test_portrait_avatars_are_not_3d(self):
        self.assertFalse(avatar3d.is_3d({"slug": "x", "status": "ready"}))
        self.assertFalse(avatar3d.is_3d(None))


if __name__ == "__main__":
    unittest.main()


class IOSExportTests(unittest.TestCase):
    def test_export_ios_3d_package_transcodes_webp_and_writes_manifest(self):
        import zipfile
        import io
        from PIL import Image
        with TemporaryRegistry() as root:
            # A GLB with one WebP texture referenced through EXT_texture_webp.
            buffer = io.BytesIO()
            Image.new("RGBA", (8, 8), (200, 30, 30, 128)).save(buffer, "WEBP")
            webp = buffer.getvalue()
            document = rigged_document(OCULUS)
            document["buffers"] = [{"byteLength": len(webp)}]
            document["bufferViews"] = [{"buffer": 0, "byteOffset": 0, "byteLength": len(webp)}]
            document["images"] = [{"mimeType": "image/webp", "bufferView": 0, "name": "skin"}]
            document["textures"] = [{"extensions": {"EXT_texture_webp": {"source": 0}}}]
            document["extensionsUsed"] = ["EXT_texture_webp"]
            document["extensionsRequired"] = ["EXT_texture_webp"]
            document["accessors"] = []
            model = os.path.join(root, "webp.glb")
            with open(model, "wb") as handle:
                handle.write(make_glb(document, webp))
            manifest = avatar3d.create_avatar(model, "Web Pea", log=lambda *_: None)
            avatar3d.set_thumbnail(manifest["slug"], png_bytes(),
                                   layout={"bounds": [10, 20, 900, 1400],
                                           "faceBounds": [400, 90, 210, 210]})
            destination = os.path.join(root, "out.avtr")
            exported = avatar3d.export_ios_3d(manifest["slug"], destination, log=lambda *_: None)
            self.assertEqual(exported["variant"], "ios-3d")
            self.assertEqual(exported["version"], 5)
            self.assertEqual(exported["model"]["faceBounds"], {"x": 400, "y": 90, "width": 210, "height": 210})
            self.assertEqual(exported["model"]["visemes"]["missing"], [])
            with zipfile.ZipFile(destination) as archive:
                names = sorted(archive.namelist())
                self.assertEqual(names, ["assets/model.glb", "assets/thumbnail.png", "manifest.json"])
                shipped = json.loads(archive.read("manifest.json"))
                self.assertEqual(shipped, exported)
                glb = archive.read("assets/model.glb")
                self.assertEqual(len(glb), exported["model"]["byteCount"])
                import hashlib
                self.assertEqual(hashlib.sha256(glb).hexdigest(), exported["model"]["sha256"])
                thumb = archive.read("assets/thumbnail.png")
                with Image.open(io.BytesIO(thumb)) as image:
                    self.assertEqual(image.size, (512, 512))
            # The shipped model carries a PNG (alpha kept) and no WebP extension.
            path = os.path.join(root, "shipped.glb")
            with open(path, "wb") as handle:
                handle.write(glb)
            shipped_document, binary = avatar3d._glb_parts(path)
            self.assertEqual(shipped_document["images"][0]["mimeType"], "image/png")
            self.assertEqual(shipped_document["textures"][0]["source"], 0)
            self.assertNotIn("extensions", shipped_document["textures"][0])
            self.assertNotIn("extensionsUsed", shipped_document)
            self.assertNotIn("extensionsRequired", shipped_document)
            view = shipped_document["bufferViews"][0]
            self.assertTrue(binary[view["byteOffset"]:view["byteOffset"] + 8].startswith(b"\x89PNG"))

    def test_export_refuses_portrait_avatars(self):
        import avatar_package
        with TemporaryRegistry():
            with patch.object(build, "read_manifest", return_value={"slug": "p", "status": "ready"}):
                with self.assertRaises(avatar_package.AvatarPackageError):
                    avatar3d.export_ios_3d("p", "/dev/null/out.avtr", log=lambda *_: None)
