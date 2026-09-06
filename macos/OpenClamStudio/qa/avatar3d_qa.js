'use strict';

// The 3D avatar path must stay a strict add-on: one module script on the
// renderer page, a CSP-compatible vendored three.js, and viseme names that
// match the Python track generator exactly.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');

const index = read('web/index.html');
const settings = read('web/settings.html');
const moduleSource = read('web/avatar3d.js');
const app = read('server/app.py');
const server3d = read('server/avatar3d.py');
const visemesPy = read('server/visemes.py');
const pkg = JSON.parse(read('package.json'));

// One module script, same origin, no import map and no CDN.
assert.equal((index.match(/<script type="module" src="\/avatar3d\.js"><\/script>/g) || []).length, 1);
assert.doesNotMatch(index, /type="importmap"/);
assert.doesNotMatch(moduleSource, /https?:\/\//);
for (const specifier of moduleSource.matchAll(/from\s+'([^']+)'/g)) {
  assert.match(specifier[1], /^\/(?:vendor\/three\/[A-Za-z.]+|avatar3d-options)\.js$/,
    `avatar3d.js may only import bundled 3D modules, saw ${specifier[1]}`);
}
execFileSync(process.execPath, ['--input-type=module', '--check'], { input: moduleSource });

// The renderer exposes exactly the surface the page consumes.
assert.match(moduleSource, /window\.OpenClamAvatar3D = Object\.freeze\(/);
assert.match(moduleSource, /new Event\('openclam-avatar3d-ready'\)/);
for (const method of ['load', 'render', 'layout', 'snapshot', 'dispose', 'resize']) {
  assert.match(moduleSource, new RegExp(`^  (?:async )?${method}\\(`, 'm'), `Avatar3D must define ${method}()`);
}

// Viseme names match server/visemes.py in order.
const pyList = visemesPy.match(/VISEMES = \[([\s\S]*?)\]/)[1].match(/"([^"]+)"/g).map(v => v.slice(1, -1));
const jsList = moduleSource.match(/const VISEMES = \[([\s\S]*?)\];/)[1].match(/'([^']+)'/g).map(v => v.slice(1, -1));
const py3dList = server3d.match(/VISEMES = \[([\s\S]*?)\]/)[1].match(/"([^"]+)"/g).map(v => v.slice(1, -1));
assert.deepEqual(jsList, pyList);
assert.deepEqual(py3dList, pyList);
for (const viseme of pyList) {
  assert.match(moduleSource, new RegExp(`^  ${viseme}: \\[`, 'm'), `JS alias table lacks ${viseme}`);
  assert.match(server3d, new RegExp(`^    "${viseme}": \\(`, 'm'), `Python alias table lacks ${viseme}`);
}

// The page branches once on the manifest and never bypasses the 2D checks.
assert.match(index, /const is3DRuntime = value => Boolean\(value && typeof value === 'object'\s*&& value\.renderer === '3d'/);
assert.match(index, /if \(is3DRuntime\(manifest\)\) \{\s*await loadAvatar3D\(\);\s*return;\s*\}/);
assert.match(index, /const drawAvatar = \(now, presentation = ''\) => \{\s*if \(avatar3d\) \{\s*drawAvatar3D\(now, presentation\);\s*return;\s*\}/);
assert.match(index, /if \(avatar3d\) return avatar3dFrameDelay\(now\);/);
assert.match(index, /disposeAvatar3D\(\);/);
// The 3D draw reuses the shared timing, blink, gaze and camera helpers.
for (const helper of ['desiredViseme(now)', 'blinkAmounts(now, reduce)', 'cursorGazeTarget(pointer',
  'smoothCursorGaze(avatar3dGazeState', 'bodyMotionAt(now, speaking', 'cameraFor(previewMetadata, logicalWidth, logicalHeight)',
  "chatWindowMotionFit('idle', previewMetadata", 'avatar3d.render(now, {']) {
  const block = index.slice(index.indexOf('const drawAvatar3D ='), index.indexOf('const avatar3dFrameDelay'));
  assert.ok(block.includes(helper), `drawAvatar3D must use ${helper}`);
}

// Server: upload, thumbnail, static routes, runtime branch and studio guards.
for (const route of ['@app.post("/api/avatar/upload3d")', '@app.post("/api/avatar/thumb3d")',
  '@app.get("/avatar3d.js")', '@app.get("/vendor/three/{name}")']) {
  assert.equal((app.match(new RegExp(route.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length, 1, route);
}
assert.match(app, /AVATAR3D\.RUNTIME_VERSION = RUNTIME_VERSION/);
assert.match(app, /if AVATAR3D\.is_3d\(reg\(\)\.read_manifest\(slug\)\):\n\s+# A 3D avatar's runtime/);
assert.ok((app.match(/_reject_3d\(/g) || []).length >= 5, 'portrait-only studio routes must reject 3D avatars');
assert.match(server3d, /UNSUPPORTED_EXTENSIONS = \{[\s\S]*KHR_draco_mesh_compression/);
// iPhone hand-off: the export route accepts ios-3d only for 3D avatars, the
// export transcodes WebP, and the shared schema documents the package shape.
assert.match(app, /variant: str = Query\(pattern=r"\^\(\?:macos-full\|ios-light\|ios-3d\)\$"\)/);
assert.match(app, /if variant == AVATAR3D\.IOS_VARIANT:/);
assert.match(server3d, /def export_ios_3d\(slug, destination/);
assert.match(server3d, /def transcode_textures_for_ios\(/);
assert.match(server3d, /IOS_MAX_MODEL_BYTES = 256 \* 1024 \* 1024/);
assert.match(settings, /data-act="export-ios3d"/);
const schema = JSON.parse(read('../../shared/avatar-package-v2/ios-3d-v5.schema.json'));
assert.equal(schema.properties.version.const, 5);
assert.equal(schema.properties.variant.const, 'ios-3d');
assert.deepEqual(schema.$defs.visemeList.items.enum, pyList);

// Settings: import control and a 3D card without portrait-only actions.
assert.equal((settings.match(/id="import3D"/g) || []).length, 1);
assert.equal((settings.match(/id="glbFile" accept="\.glb"/g) || []).length, 1);
assert.match(settings, /api\('\/api\/avatar\/upload3d'/);
assert.match(settings, /if \(a\.renderer === '3d'\) return card3D\(a\);/);
const card3D = settings.slice(settings.indexOf('function card3D('), settings.indexOf('function card('));
for (const forbidden of ['data-act="build"', 'data-act="calibrate"', 'data-act="body"',
  'data-act="pipeline"', 'data-act="export-ios"', 'data-act="export-macos"']) {
  assert.ok(!card3D.includes(forbidden), `3D card must not offer ${forbidden}`);
}
for (const required of ['data-act="activate"', 'data-act="companion"', 'data-act="persona"', 'data-act="delete"']) {
  assert.ok(card3D.includes(required), `3D card must offer ${required}`);
}

// Packaging: staged modules ship, the stager runs before start/test/pack.
assert.equal(pkg.scripts['stage:three'], 'node scripts/stage-three-assets.mjs');
for (const script of ['prestart', 'predev', 'pretest', 'pack']) {
  assert.match(pkg.scripts[script], /stage:three/, `${script} must stage three.js`);
}
const web = pkg.build.extraResources.find(entry => entry.from === 'web');
assert.ok(web.filter.includes('avatar3d.js'));
assert.ok(web.filter.includes('avatar3d-options.js'));
assert.ok(app.includes('@app.get("/avatar3d-options.js")'));
assert.ok(web.filter.includes('vendor/three/*.js'));
assert.match(pkg.devDependencies.three, /^\d+\.\d+\.\d+$/, 'three must be pinned exactly');
const stager = read('scripts/stage-three-assets.mjs');
assert.match(stager, /THREE_MIT\.txt/);
assert.match(read('THIRD_PARTY_NOTICES.md'), /three\.js/);
if (fs.existsSync(path.join(root, 'web', 'vendor', 'three'))) {
  for (const file of ['three.module.js', 'three.core.js', 'GLTFLoader.js', 'RoomEnvironment.js']) {
    const staged = read(`web/vendor/three/${file}`);
    assert.doesNotMatch(staged, /from\s+'three'/, `${file} must not keep a bare 'three' import`);
  }
}

console.log('3D avatar renderer, routes, settings card and packaging verified.');
