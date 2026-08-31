"""Backend health must identify the same version as the installed app."""
import ast
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def backend_version_reader(backend):
    # Isolate the production reader, avoiding app import/startup, user config,
    # credentials, and optional ML dependencies in this packaging regression.
    source = ROOT / "server/app.py"
    tree = ast.parse(source.read_text(encoding="utf-8"))
    function = next(node for node in tree.body
                    if isinstance(node, ast.FunctionDef)
                    and node.name == "_app_version")
    namespace = {"os": os, "json": json,
                 "__file__": str(backend / "server/app.py")}
    isolated = ast.Module(body=[function], type_ignores=[])
    exec(compile(ast.fix_missing_locations(isolated), str(source), "exec"), namespace)
    return namespace["_app_version"]


class PackagedVersionMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openclam-version-qa-")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "OpenClam Studio.app"
        self.backend = self.app / "Contents/Resources/backend"
        (self.backend / "server").mkdir(parents=True)
        self.canonical = ROOT / "package.json"
        self.metadata = json.loads(self.canonical.read_text(encoding="utf-8"))
        self.version = self.metadata["version"]
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": self.metadata["build"]["appId"],
            "CFBundleShortVersionString": self.version,
        }))

    def stage_metadata(self):
        self.assertEqual(self.metadata["build"]["afterPack"],
                         "scripts/package-backend-metadata.cjs")
        result = self.run_pack_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.backend / "package.json"
        return target

    def run_pack_hook(self, *, omit_asar_metadata=False, asar_version=None,
                      builder_version=None):
        # Exercise the actual ASAR writer/reader and production afterPack
        # hook, not a hand-copied stand-in for electron-builder resources.
        probe = r"""
const fs = require('node:fs/promises');
const path = require('node:path');
(async () => {
  const [root, app, omitMetadata, asarVersion, builderVersion] = process.argv.slice(1);
  const metadata = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const resources = path.join(app, 'Contents', 'Resources');
  const fixture = path.join(path.dirname(app), 'asar-fixture');
  await fs.mkdir(fixture, {recursive:true});
  await fs.writeFile(path.join(fixture, 'fixture.txt'), 'ASAR fixture');
  if (omitMetadata !== 'true') {
    await fs.writeFile(path.join(fixture, 'package.json'), JSON.stringify({
      name:metadata.name, main:metadata.main, version:asarVersion || metadata.version,
    }));
  }
  const asar = await import('@electron/asar');
  await asar.createPackage(fixture, path.join(resources, 'app.asar'));
  const hook = require(path.join(root, metadata.build.afterPack));
  await hook({appOutDir:path.dirname(app), electronPlatformName:'darwin', packager:{
    info:{projectDir:root}, appInfo:{version:builderVersion || metadata.version},
    getResourcesDir:() => resources,
  }});
  console.log(JSON.parse(asar.extractFile(path.join(resources, 'app.asar'),
    'package.json').toString('utf8')).version);
})().catch(error => { console.error(error.message); process.exitCode=1; });
"""
        return subprocess.run([
            "node", "-e", probe, str(ROOT), str(self.app),
            str(omit_asar_metadata).lower(), asar_version or "", builder_version or "",
        ], cwd=ROOT, capture_output=True, text=True, timeout=20)

    def test_resource_mapping_makes_production_reader_return_canonical_version(self):
        target = self.stage_metadata()
        self.assertEqual(target.read_bytes(), self.canonical.read_bytes())
        self.assertEqual(backend_version_reader(self.backend)(), self.version)

    def test_reader_uses_packaged_metadata_not_build_host_or_data_directory(self):
        target = self.stage_metadata()
        # This arbitrary fixture version is not a production version source.
        fixture_version = "99.88.77"
        fixture = dict(self.metadata, version=fixture_version)
        target.write_text(json.dumps(fixture), encoding="utf-8")
        self.assertEqual(backend_version_reader(self.backend)(), fixture_version)

    def test_missing_metadata_reproduces_blank_health_version(self):
        self.assertEqual(backend_version_reader(self.backend)(), "")

    def test_after_pack_rejects_missing_electron_metadata(self):
        result = self.run_pack_hook(omit_asar_metadata=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("package.json", result.stderr)
        self.assertFalse((self.backend / "package.json").exists())

    def test_after_pack_rejects_version_changed_during_packaging(self):
        result = self.run_pack_hook(builder_version="99.88.77")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version changed", result.stderr)
        self.assertFalse((self.backend / "package.json").exists())

    def test_after_pack_rejects_stale_asar_version(self):
        result = self.run_pack_hook(asar_version="99.88.77")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("metadata disagree: version", result.stderr)
        self.assertFalse((self.backend / "package.json").exists())

    def test_pinned_builder_keeps_package_json_in_main_file_set(self):
        probe = r"""
const fs = require('node:fs');
const path = require('node:path');
const {getFileMatchers, getMainFileMatchers} = require('app-builder-lib/out/fileMatcher');
const root = process.cwd();
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const destination = path.join(process.argv[1], 'app');
function included(config) {
  const options = {defaultSrc:root, macroExpander:value=>value,
    customBuildOptions:config.mac, globalOutDir:destination};
  const exclusions = [];
  for (const category of ['extraResources', 'extraFiles']) {
    for (const matcher of getFileMatchers(config, category, destination, options) || []) {
      matcher.computeParsedPatterns(exclusions, root);
    }
  }
  const platform = {info:{config, projectDir:root, buildResourcesDir:'build',
    isPrepackedAppAsar:false, debugLogger:{isEnabled:false}}};
  const mainMatchers = getMainFileMatchers(root, destination, value=>value,
    config.mac, platform, destination, false);
  for (const matcher of mainMatchers) matcher.excludePatterns = exclusions;
  const file = path.join(root, 'package.json');
  return mainMatchers.some(matcher=>matcher.createFilter()(file, fs.statSync(file)));
}
const current = included(structuredClone(pkg.build));
const broken = structuredClone(pkg.build);
broken.extraResources.push({from:'package.json', to:'backend/package.json'});
console.log(JSON.stringify({current, priorCollision:included(broken)}));
"""
        result = subprocess.run(["node", "-e", probe, self.temporary.name],
                                cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         {"current": True, "priorCollision": False})

    def run_release_metadata_gate(self):
        source = (ROOT / "scripts/release-macos.sh").read_text(encoding="utf-8")
        def function(name):
            start = source.index(f"{name}() {{\n")
            end = source.index("\n}\n", start) + 3
            return source[start:end]
        # Execute only the real pure validators, never the build/sign/install
        # script entry point. Each check uses an isolated temporary fake app.
        probe = "set -eu\n" + "\n".join(function(name) for name in (
            "fail", "require_sha256", "verify_bundle_metadata"))
        probe += '\nverify_bundle_metadata "$1" "$2" "fixture-app"\n'
        environment = dict(os.environ,
            APP_ID=self.metadata["build"]["appId"],
            PACKAGE_METADATA_SHA=hashlib.sha256(self.canonical.read_bytes()).hexdigest())
        return subprocess.run(["/bin/bash", "-c", probe, "metadata-qa",
                               str(self.app), self.version],
                              env=environment, capture_output=True, text=True, timeout=10)

    @unittest.skipUnless(sys.platform == "darwin", "release uses macOS plutil")
    def test_release_gate_accepts_canonical_backend_metadata(self):
        self.stage_metadata()
        result = self.run_release_metadata_gate()
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "release uses macOS plutil")
    def test_release_gate_rejects_missing_backend_metadata(self):
        result = self.run_release_metadata_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backend package metadata is missing", result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "release uses macOS plutil")
    def test_release_gate_rejects_stale_backend_metadata(self):
        target = self.stage_metadata()
        fixture = dict(self.metadata, version="99.88.77")
        target.write_text(json.dumps(fixture), encoding="utf-8")
        result = self.run_release_metadata_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backend package metadata SHA-256 mismatch", result.stderr)


class ReleaseStagedRuntimeReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openclam-reuse-qa-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        self.source = (ROOT / "scripts/release-macos.sh").read_text(encoding="utf-8")

    def run_stage(self, reuse):
        def function(name):
            start = self.source.index(f"{name}() {{\n")
            end = self.source.index("\n}\n", start) + 3
            return self.source[start:end]
        probe = "set -eu\n" + "\n".join(function(name) for name in (
            "fail", "require_executable", "stage_release_backend"))
        probe += '\nnpm() { echo "NPM:$*"; }\nstage_release_backend\n'
        environment = dict(os.environ, PROJECT_ROOT=str(self.project),
                           REUSE_STAGED_RUNTIME=str(int(reuse)))
        return subprocess.run(["/bin/bash", "-c", probe], env=environment,
                              capture_output=True, text=True, timeout=10)

    def make_stage(self):
        for name in (".electron-python-runtime/bin/python", ".electron-ffmpeg/ffmpeg",
                     ".electron-ffmpeg/ffprobe", ".electron-site-packages/cv2/__init__.py"):
            file = self.project / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("fixture\n", encoding="utf-8")
            file.chmod(0o755)

    def test_default_release_still_stages_backend(self):
        result = self.run_stage(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NPM:run stage:backend", result.stdout)

    def test_reuse_skips_only_staging_with_required_resources_present(self):
        self.make_stage()
        result = self.run_stage(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("NPM:", result.stdout)
        self.assertIn("all release audits remain mandatory", result.stdout)
        for audit in ("npm run check", "npm run check:privacy", "npm audit",
                      "npm run stage:openclaw", 'qa/staged_runtime_qa.py "$PROJECT_ROOT"',
                      'qa/packaged_runtime_qa.py "$APP_PATH"',
                      'submit_and_require_accepted "$APP_ZIP"',
                      'submit_and_require_accepted "$DMG_PATH"'):
            self.assertIn(audit, self.source)

    def test_reuse_fails_closed_when_staged_directory_is_missing(self):
        result = self.run_stage(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required staged runtime directory", result.stderr)

    def test_reuse_fails_closed_when_staged_executable_is_missing(self):
        self.make_stage()
        (self.project / ".electron-ffmpeg/ffprobe").unlink()
        result = self.run_stage(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required executable is unavailable", result.stderr)


if __name__ == "__main__":
    unittest.main()
