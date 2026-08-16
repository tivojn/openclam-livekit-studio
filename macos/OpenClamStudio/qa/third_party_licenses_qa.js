const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function resourceEntry(packageJson, from, to) {
  return packageJson.build.extraResources.find(
    (entry) => entry.from === from && entry.to === to,
  );
}

const generated = spawnSync(
  process.execPath,
  [path.join(root, 'scripts', 'stage-livekit-assets.mjs')],
  { cwd: root, encoding: 'utf8' },
);
assert.equal(generated.status, 0, generated.stderr || generated.stdout);

const licenses = path.join(root, 'LICENSES');
const expectedLicenseFiles = [
  'FFmpeg-SOURCE-OFFER.md',
  'LIVEKIT_CLIENT_APACHE-2.0.txt',
  'LIVEKIT_UMD_BUNDLED_LICENSES.txt',
  'LIVEKIT_UMD_MANIFEST.json',
  'OPENCV_BUNDLED_CODEC_LICENSES.txt',
];
for (const file of expectedLicenseFiles) {
  assert.ok(fs.statSync(path.join(licenses, file)).size > 0, `${file} is missing`);
}

const manifest = JSON.parse(
  fs.readFileSync(path.join(licenses, 'LIVEKIT_UMD_MANIFEST.json'), 'utf8'),
);
assert.equal(manifest.schema_version, 1);
assert.equal(
  sha256(path.join(root, manifest.umd.relative_path)),
  manifest.umd.sha256,
  'LiveKit UMD hash must match its generated notice manifest',
);
assert.equal(
  sha256(path.join(root, manifest.top_level_license.relative_path)),
  manifest.top_level_license.sha256,
  'LiveKit top-level Apache license hash must match its manifest',
);
assert.equal(
  sha256(path.join(root, manifest.bundled_license_file.relative_path)),
  manifest.bundled_license_file.sha256,
  'LiveKit bundled license inventory hash must match its manifest',
);

assert.deepEqual(
  manifest.packages.map((entry) => entry.name).sort(),
  [
    '@bufbuild/protobuf',
    '@livekit/mutex',
    '@livekit/protocol',
    'events',
    'jose',
    'loglevel',
    'sdp',
    'sdp-transform',
    'tslib',
    'typed-emitter',
    'webrtc-adapter',
  ].sort(),
);
assert.deepEqual(
  manifest.packages.filter((entry) => entry.source_mapped).map((entry) => entry.name).sort(),
  [
    '@bufbuild/protobuf',
    '@livekit/mutex',
    'events',
    'jose',
    'loglevel',
    'sdp',
    'sdp-transform',
    'webrtc-adapter',
  ].sort(),
);

const sourceOffer = fs.readFileSync(path.join(licenses, 'FFmpeg-SOURCE-OFFER.md'), 'utf8');
for (const required of [
  'ffmpeg-7.1.5.tar.xz',
  'OpenClam-Studio-FFmpeg-7.1.5-Source.tar.xz',
  'de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f',
  'at least three years',
  'prepare-ffmpeg-source-release-asset.sh',
]) {
  assert.ok(sourceOffer.includes(required), `FFmpeg source offer is missing ${required}`);
}

const opencvLicenses = path.join(licenses, 'OPENCV_BUNDLED_CODEC_LICENSES.txt');
assert.equal(
  sha256(opencvLicenses),
  '6ab9f8dfa6c5d0c20a5fcc679ed5f428a191017870d265eae775c54ed0ab1c8d',
  'review the codec license inventory whenever the pinned OpenCV source changes',
);
const opencvText = fs.readFileSync(opencvLicenses, 'utf8');
for (const required of [
  'This software is based in part on the work of the Independent JPEG Group.',
  '3rdparty/libjpeg-turbo/LICENSE.md',
  '3rdparty/libjpeg-turbo/README.ijg',
  '3rdparty/libpng/LICENSE',
  '3rdparty/openjpeg/LICENSE',
  '3rdparty/zlib/LICENSE',
]) {
  assert.ok(opencvText.includes(required), `OpenCV codec inventory is missing ${required}`);
}

const notices = fs.readFileSync(path.join(root, 'THIRD_PARTY_NOTICES.md'), 'utf8');
for (const required of [
  'requirements-electron.lock',
  'OpenCV 4.12.0',
  'LIVEKIT_UMD_BUNDLED_LICENSES.txt',
  'FFmpeg-SOURCE-OFFER.md',
  'contains a PyTorch resolution',
  'Kokoro, Misaki,',
  'are likewise not redistributed',
]) {
  assert.ok(notices.includes(required), `third-party notice is missing ${required}`);
}
assert.ok(!notices.includes('requirements-backend.lock'));
assert.ok(!notices.includes('Notable projects include'));

const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
assert.deepEqual(
  resourceEntry(packageJson, 'LICENSES', 'docs/LICENSES')?.filter,
  ['*.md', '*.txt', '*.json'],
);
assert.ok(resourceEntry(
  packageJson,
  'requirements-electron.txt',
  'docs/runtime/requirements-electron.txt',
));
assert.ok(resourceEntry(
  packageJson,
  'requirements-electron.lock',
  'docs/runtime/requirements-electron.lock',
));
assert.ok(resourceEntry(packageJson, 'package-lock.json', 'docs/runtime/package-lock.json'));
assert.deepEqual(
  resourceEntry(packageJson, '.electron-ffmpeg', 'backend/bin')?.filter,
  ['ffmpeg', 'LICENSE.LGPLv2.1.txt'],
);

if (process.argv[2]) {
  const application = path.resolve(process.argv[2]);
  const resources = application.endsWith('.app')
    ? path.join(application, 'Contents', 'Resources')
    : application;
  for (const file of expectedLicenseFiles) {
    const packaged = path.join(resources, 'docs', 'LICENSES', file);
    assert.equal(sha256(packaged), sha256(path.join(licenses, file)), `${file} changed in package`);
  }
  for (const file of ['requirements-electron.txt', 'requirements-electron.lock', 'package-lock.json']) {
    assert.ok(fs.statSync(path.join(resources, 'docs', 'runtime', file)).size > 0);
  }
  assert.ok(fs.statSync(path.join(resources, 'backend', 'bin', 'LICENSE.LGPLv2.1.txt')).size > 0);
}

console.log('third-party license/package QA passed');
