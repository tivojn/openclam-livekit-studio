'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const pkg = JSON.parse(read('package.json'));
const release = read('scripts/release-macos.sh');
const openClawStager = read('scripts/stage-openclaw-plugin.sh');
const ffmpegStager = read('scripts/stage-electron-ffmpeg.sh');
const opencvStager = read('scripts/stage-electron-opencv.sh');
const opencvBuildInfoHook = read('scripts/opencv-cmake-hooks/STATUS_DUMP_EXTRA.cmake');
const nativePathAudit = read('scripts/audit-native-build-paths.py');
const opencvSourceSanitizer = read('scripts/sanitize-opencv-source-build-paths.py');
const deploymentAudit = read('scripts/audit-macos-deployment-targets.py');
const credentials = read('server/credentials.py');
const xaiOauth = read('server/xai_oauth.py');
const serverApp = read('server/app.py');
const bodyAuthoring = read('studio/body.py');
const settings = read('web/settings.html');
const main = read('electron/main.cjs');
const avatarStore = read('electron/avatar-store.cjs');
const readme = read('README.md');
const privacy = read('PRIVACY.md');
const security = read('SECURITY.md');

for (const required of [
  'XAI_EDIT_PROVIDER = "xai"',
  'XAI_EDIT_MODEL = "grok-imagine-image-2.0"',
  'if not supports_xai_edit(provider):',
  'instruction_sha256',
  'keep_previous=True',
  'def restore_previous(avatar_dir):',
]) assert.ok(bodyAuthoring.includes(required),
  `Full-body xAI edit trust boundary is missing ${required}`);
for (const required of [
  '@app.post("/api/avatar/body/edit")',
  'if not body.supports_xai_edit(provider):',
  '_reserve_job(\n        request.slug, "body-edit"',
  '_BODY_EDIT_TRANSACTION_DIRNAME = ".body-edit-transaction"',
  'def _begin_body_edit_transaction(slug):',
  'def _recover_body_edit_transaction(slug, log=print):',
  '_restore_tree_snapshot(',
  '_restore_file_snapshot(',
  '_publish_runtime_atomic(slug, log=writer, keep_previous=True)',
  '_set_body_edit_transaction_phase(slug, "committed")',
  '_finish_committed_body_edit(slug, log=writer)',
]) assert.ok(serverApp.includes(required),
  `Full-body edit route is missing ${required}`);
assert.ok(
  serverApp.indexOf('_publish_runtime_atomic(slug, log=writer, keep_previous=True)') <
  serverApp.indexOf('_finish_committed_body_edit(slug, log=writer)'),
  'Edited body archival/cleanup must follow successful runtime publication');
assert.ok(settings.includes("provider.name === 'xai' && provider.model === 'grok-imagine-image-2.0'"));
assert.ok(settings.includes("api('/api/avatar/body/edit'"));

assert.equal(pkg.scripts.dist, 'scripts/release-macos.sh');
assert.equal(pkg.build.forceCodeSigning, true);
assert.equal(pkg.build.mac.identity, 'THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)');
assert.equal(pkg.build.mac.notarize, false);
assert.deepEqual(pkg.build.mac.target, ['dmg']);
assert.equal(pkg.build.dmg.artifactName, 'OpenClam-Studio-${version}-${arch}.${ext}');
for (const required of [
  'BUILD_ROOT="$TEMP_ROOT/source"',
  '/bin/cp -R -p -- "$PLUGIN_ROOT/src" "$BUILD_ROOT/src"',
  'npm ci --ignore-scripts --no-audit --no-fund',
  'cd "$BUILD_ROOT"',
]) assert.ok(openClawStager.includes(required),
  `OpenClaw release staging is missing clean-clone build gate ${required}`);
assert.doesNotMatch(openClawStager, /cd "\$PLUGIN_ROOT"\s*\n\s*npm run build/,
  'OpenClaw release staging must not depend on developer node_modules');
for (const excluded of [
  '!electron/native/**',
  '!node_modules/**/src/**',
  '!node_modules/**/*.map',
]) {
  assert.ok(pkg.build.files.includes(excluded),
    `packaging must exclude source-only artifact ${excluded}`);
}
assert.match(avatarStore, /const AVATAR_STORE_AVAILABLE = false;/,
  'The v1.0.1 Avatar Store release gate must stay closed');
assert.match(avatarStore, /const RELEASE_ENDPOINT_POLICY = null;/,
  'A disabled release must not contain a production catalog endpoint');
assert.doesNotMatch(avatarStore, /tivojn\/openclam-avatar-store|const CATALOG_URL\s*=/,
  'The removed store repository must not remain reachable from production code');
assert.match(avatarStore, /function requireEndpointPolicy\(endpointPolicy\)/,
  'Every dormant generic store operation must require an explicit endpoint policy');
for (const host of [
  "const RAW_HOST = 'raw.githubusercontent.com';",
  "const RELEASE_HOST = 'github.com';",
  "'objects.githubusercontent.com'",
  "'release-assets.githubusercontent.com'",
]) assert.ok(avatarStore.includes(host), `Avatar Store is missing exact host pin ${host}`);
assert.doesNotMatch(avatarStore, /\*\.githubusercontent\.com|endsWith\(['"]githubusercontent\.com/,
  'Avatar Store must never trust a wildcard GitHub content host');
assert.match(avatarStore, /redirect: 'manual'/,
  'Every Avatar Store redirect must be inspected by the app');
assert.match(avatarStore, /kind === 'thumbnail' && isRawRepoUrl\(parsed, endpoints\)/,
  'A Mac AVTR redirect must not be allowed to become an arbitrary raw file');
assert.match(avatarStore, /RELEASE_REDIRECT_HOSTS\.has\(parsed\.hostname\)/,
  'Release asset redirects must use the exact reviewed object hosts');
for (const required of [
  "value.format !== 'openclam-avatar'",
  "safeText(value.author, 'avatar publisher')",
  "value.schemaVersion !== CATALOG_SCHEMA_VERSION",
  "variants['macos-full']",
  "digest.digest('hex') !== variant.sha256",
  "loaded !== variant.bytes",
  "mode: 0o700",
  "mode: 0o600",
]) assert.ok(avatarStore.includes(required), `Avatar Store trust gate is missing ${required}`);
for (const handler of [
  'async function avatarStoreCatalog(',
  'async function avatarStoreThumbnail(',
  'async function downloadAvatarStoreItem(',
]) {
  const start = main.indexOf(handler);
  const end = main.indexOf('\n}', start);
  const body = main.slice(start, end);
  assert.match(body, /if \(!AVATAR_STORE_AVAILABLE\)/,
    `${handler} must fail closed before any store or backend request`);
}
assert.match(main, /fs\.openAsBlob\(file, \{type: 'application\/vnd\.openclam\.avatar\+zip'\}\)/);
assert.match(main, /fetch\(`\$\{baseUrl\(\)\}\/api\/avatar\/import`/,
  'Verified Store bytes must still pass through the existing AVTR importer');
const ffmpegResource = pkg.build.extraResources.find(
  (resource) => resource.from === '.electron-ffmpeg');
assert.deepEqual(ffmpegResource && ffmpegResource.filter,
  ['ffmpeg', 'ffprobe', 'LICENSE.LGPLv2.1.txt']);
const contractResource = pkg.build.extraResources.find(
  (resource) => resource.from === 'contracts');
const openClawResource = pkg.build.extraResources.find(
  (resource) => resource.from === '.electron-openclaw-plugin');
assert.deepEqual(openClawResource && openClawResource.filter,
  ['openclam-channel.tgz', 'install-config.json']);
for (const contract of [
  'avatar-package-v2/README.md',
  'avatar-package-v2/manifest.schema.json',
  'avatar-package-v2/macos-full.schema.json',
  'avatar-package-v2/ios-light-v3.schema.json',
  'avatar-package-v2/ios-full-expression-v4.schema.json',
]) assert.ok(contractResource && contractResource.filter.includes(contract),
  `packaging must include portable avatar contract ${contract}`);
const iosFullExpressionV4Sha =
  '6a5011d520d160d4d66430576b5beac534bd24f84ed40f24531838906541a72d';
assert.ok(
  release.includes(`AVATAR_IOS_V4_SCHEMA_SHA='${iosFullExpressionV4Sha}'`),
  'macOS release must pin the reviewed iPhone full-expression v4 schema');
for (const required of [
  'require_sha256 contracts/avatar-package-v2/ios-full-expression-v4.schema.json',
  'require_sha256 "$APP_RESOURCES/backend/contracts/avatar-package-v2/ios-full-expression-v4.schema.json"',
]) assert.ok(release.includes(required),
  `macOS release must hash-check v4 schema at source and package boundary: ${required}`);
const sitePackagesResource = pkg.build.extraResources.find(
  (resource) => resource.from === '.electron-site-packages');
const studioResource = pkg.build.extraResources.find(
  (resource) => resource.from === 'studio');
for (const excluded of [
  '!**/conftest.py',
  '!**/pytest_plugin.py',
  '!absl/testing/**',
  '!aiohttp/test_utils.py',
  '!annotated_types/test_cases.py',
  '!click/testing.py',
  '!matplotlib/testing/**',
  '!mediapipe/tasks/python/genai/**/*_test.py',
  '!numba/core/datamodel/testing.py',
  '!numba/cuda/testing.py',
  '!numba/runtests.py',
  '!numba/testing/**',
  '!numpy/_core/*_tests.cpython-*.so',
  '!scipy/**/_test*.cpython-*.so',
  '!setuptools/command/test.py',
  '!sympy/testing/**',
]) {
  assert.ok(sitePackagesResource && sitePackagesResource.filter.includes(excluded),
    `packaging must exclude dependency test artifact ${excluded}`);
}
for (const excluded of ['!blink_qa.py', '!life_qa.py']) {
  assert.ok(studioResource && studioResource.filter.includes(excluded),
    `packaging must exclude first-party diagnostic ${excluded}`);
}
for (const excluded of [
  '!node_modules/livekit-client/src/test/**',
  '!node_modules/livekit-client/src/**/__snapshots__/**',
  '!node_modules/livekit-client/src/**/*.test.ts',
  '!node_modules/livekit-client/src/room/token-source/test-tokens.ts',
  '!node_modules/livekit-client/dist/src/test/**',
  '!node_modules/livekit-client/dist/ts4.2/test/**',
  '!node_modules/@livekit/mutex/src/index.test.ts',
  '!node_modules/@livekit/mutex/dist/index.test.d.ts',
  '!node_modules/@livekit/mutex/dist/index.test.d.ts.map',
]) {
  assert.ok(pkg.build.files.includes(excluded),
    `packaging must exclude JavaScript test artifact ${excluded}`);
}

const packagedRuntimeQa = read('qa/packaged_runtime_qa.py');
const stagedRuntimeQa = read('qa/staged_runtime_qa.py');
const alphaRuntimeQa = read('qa/ffmpeg_alpha_runtime_qa.py');
for (const required of [
  'require_clean_packaged_asar',
  'asar.listPackage',
  'asar.extractAll',
  "atOrBelow(entry, '/electron/native')",
  '/^\\/node_modules\\/(?:@[^/]+\\/)?[^/]+\\/src(?:\\/|$)/.test(entry)',
  "entry.endsWith('.map')",
  'livekit-client',
  '@livekit/mutex',
  'rxjs/testing',
  'TestScheduler',
  'FORBIDDEN_PACKAGED_TEST_ARTIFACTS',
  'studio/blink_qa.py',
  'studio/life_qa.py',
  'numpy/_core/*_tests.cpython-*.so',
  'scipy/**/_test*.cpython-*.so',
  'REQUIRED_RUNTIME_TEST_NAMED_MODULES',
  'anyio/_core/_testing.py',
  'jinja2/tests.py',
  'numpy/testing/__init__.py',
  'pyparsing/testing.py',
  'scipy/_external/array_api_extra/testing.py',
  'scipy/_lib/_testutils.py',
  'scipy/stats/_bws_test.py',
  'scipy/stats/_page_trend_test.py',
  'callable(scipy.stats.bws_test)',
  'callable(scipy.stats.page_trend_test)',
]) {
  assert.ok(packagedRuntimeQa.includes(required),
    `packaged runtime QA is missing test-artifact gate ${required}`);
}
for (const runtimeQa of [packagedRuntimeQa, stagedRuntimeQa]) {
  assert.ok(runtimeQa.includes('ffprobe'), 'runtime QA must require packaged ffprobe');
  assert.ok(runtimeQa.includes('verify_alpha_runtime'),
    'runtime QA must exercise provider-free HEVC-alpha conversion');
}
for (const required of [
  'hevc_videotoolbox', 'alpha_quality', 'trace_headers',
  'Alpha Channel Information', 'codec_tag_string',
]) assert.ok(alphaRuntimeQa.includes(required),
  `HEVC-alpha runtime QA is missing ${required}`);

for (const forbidden of [
  'import subprocess', 'subprocess.run', 'SECURITY_TOOL',
]) {
  assert.ok(!credentials.includes(forbidden), `credential vault exposes secrets through ${forbidden}`);
}
assert.doesNotMatch(credentials, /["']\/usr\/bin\/security["']/);
for (const required of [
  'Security.framework', 'CFDataCreate', 'SecItemCopyMatching', 'SecItemAdd',
  'SecItemUpdate', 'SecItemDelete', 'kSecUseAuthenticationUIFail',
  'STORAGE_ACCOUNT_PREFIX = "openclam-v2:"',
]) {
  assert.ok(credentials.includes(required), `credential vault is missing ${required}`);
}
assert.match(xaiOauth,
  /GROK_BUILD_COMPAT_CLIENT_ID\s*=\s*"b1a00492-073a-47ea-816f-4c329264a828"/,
  'source must pin the audited public Grok Build OAuth compatibility identity');
assert.match(xaiOauth,
  /GROK_BUILD_COMPAT_SOURCE_REVISION\s*=\s*\(\s*"eb267feff13129e568df38fb6fdf0ceb65f735d6"\s*\)/,
  'source must pin the audited upstream Grok Build revision');
assert.match(xaiOauth,
  /GROK_BUILD_COMPAT_CLIENT_VERSION\s*=\s*"1\.0\.4"/,
  'source must pin the released Grok Build inference client version');
for (const required of [
  'GROK_BUILD_COMPAT_CLIENT_IDENTIFIER = "grok-shell"',
  'GROK_BUILD_COMPAT_AUTHENTICATE_RESPONSE = "authenticate-response"',
  'GROK_BUILD_COMPAT_CLIENT_MODE = "interactive"',
]) {
  assert.ok(xaiOauth.includes(required),
    `source must pin the Grok Build proxy identity field ${required}`);
}
const expectedGrokBuildScopes = [
  'openid', 'profile', 'email', 'offline_access', 'grok-cli:access',
  'api:access', 'conversations:read', 'conversations:write',
  'workspaces:read', 'workspaces:write',
];
const scopesBlock = xaiOauth.match(/SCOPES\s*=\s*\(([\s\S]*?)\n\)/);
assert.ok(scopesBlock, 'source must define the pinned Grok Build OAuth scope tuple');
assert.deepEqual(
  [...scopesBlock[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]),
  expectedGrokBuildScopes,
  'source must pin the exact audited ten-scope Grok Build OAuth set');
assert.doesNotMatch(xaiOauth, /["']referrer["']\s*:/,
  'compatibility must not identify OpenClam requests as Grok Build');
assert.ok(!xaiOauth.includes('OPENCLAM_XAI_OAUTH_CLIENT_ID'),
  'production must not accept an environment-supplied OAuth client identity');
assert.ok(!xaiOauth.includes('GROK_OAUTH2_CLIENT_ID'),
  'production must not accept Grok Build environment overrides');
assert.ok(main.includes('delete inherited.OPENCLAM_XAI_OAUTH_CLIENT_ID;'),
  'Electron must strip any inherited OAuth client identity');
for (const [name, document] of [
  ['README', readme], ['privacy policy', privacy], ['security policy', security],
]) {
  assert.ok(document.includes('Grok Build compatibility'),
    `${name} must label the xAI OAuth mode as Grok Build compatibility`);
  assert.match(document, /API-key/i,
    `${name} must preserve the separate API-key alternative`);
  assert.doesNotMatch(document,
    /xAI-authorized OpenClam|OpenClam native client ID|xAI-issued or\s+explicitly authorized OpenClam/i,
    `${name} must not claim an OpenClam-owned xAI registration`);
}
assert.match(readme, /ten scopes/i,
  'README must disclose the pinned ten-scope compatibility surface');
assert.match(privacy, /ten scopes/i,
  'privacy policy must disclose the pinned ten-scope compatibility surface');
assert.match(security, /ten-scope/i,
  'security policy must disclose the pinned ten-scope compatibility surface');

const appEntitlements = read('build/entitlements.mac.plist');
assert.match(appEntitlements, /com\.apple\.security\.cs\.allow-jit/);
assert.match(appEntitlements, /com\.apple\.security\.device\.audio-input/);
assert.match(appEntitlements, /com\.apple\.security\.device\.camera/);
assert.doesNotMatch(appEntitlements, /allow-unsigned-executable-memory/);

const inheritedEntitlements = read('build/entitlements.mac.inherit.plist');
assert.match(inheritedEntitlements, /com\.apple\.security\.cs\.allow-jit/);
assert.match(inheritedEntitlements, /com\.apple\.security\.device\.audio-input/);
assert.match(inheritedEntitlements, /com\.apple\.security\.device\.camera/);
assert.match(inheritedEntitlements, /allow-unsigned-executable-memory/);

for (const required of [
  "NOTARY_PROFILE='OpenClamStudioNotary'",
  "IDENTITY_QUALIFIER='THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)'",
  "TEAM_ID='X7R8N6MMSU'",
  'XAI_OAUTH_CLIENT_VERIFIED=1',
  'GROK_BUILD_COMPAT_CLIENT_ID',
  'GROK_BUILD_COMPAT_SOURCE_REVISION',
  'b1a00492-073a-47ea-816f-4c329264a828',
  'eb267feff13129e568df38fb6fdf0ceb65f735d6',
  'audited Grok Build compatibility',
  'environment-supplied OAuth identity is prohibited',
  'xAI Grok Build compatibility identity audit failed',
  "APP_ID='com.lionheart.openclam.macos'",
  'CFBundleIdentifier',
  'CFBundleShortVersionString',
  'verify_bundle_metadata "$APP_PATH" "$PACKAGE_VERSION"',
  'EXPECTED_DMG_NAME="OpenClam-Studio-${PACKAGE_VERSION}-arm64.dmg"',
  'MOUNTED_APP_CANDIDATES=("$MOUNT_DIR"/*.app)',
  'notarytool history',
  'notarytool submit',
  '--wait --output-format json',
  "[[ \"$status\" == 'Accepted' ]]",
  'codesign --force --timestamp',
  'stapler staple -v "$APP_PATH"',
  'stapler validate -v "$APP_PATH"',
  'stapler staple -v "$DMG_PATH"',
  'stapler validate -v "$DMG_PATH"',
  'hdiutil verify "$DMG_PATH"',
  'spctl --assess --type open',
  'spctl --assess --type execute',
  'syspolicy_check notary-submission',
  'syspolicy_check distribution',
  'verify_distributable_app "$MOUNTED_APP"',
  'FINAL_HASH_WRITTEN=1',
  'mandatory release gate was skipped',
  'npm run check',
  'npm run check:privacy',
  'npm run stage:openclaw',
  'check:avatar intentionally remains a local diagnostic',
  'npm audit\n',
  'npm audit --omit=dev',
  'scripts/audit-macos-deployment-targets.py',
  '/usr/bin/lipo -archs',
  '/usr/bin/otool -L',
  "'--disable-network'",
  "/usr/lib/*|/System/Library/*",
  "*'--enable-gpl'*|*'--enable-nonfree'*",
  'GNU Lesser General Public',
  'h264_videotoolbox hevc_videotoolbox pcm_s16le',
  'aiff flac image2 matroska,webm mov,mp4,m4a,3gp,3g2,mj2 mp3 ogg rawvideo wav',
  'aac alac flac mjpeg mp3 opus pcm_f32be',
  'SOURCE_CHECKS_VERIFIED=1',
  'NATIVE_ARTIFACTS_VERIFIED=1',
  'require_exact_directory_files "$PROJECT_ROOT/.electron-ffmpeg"',
  'require_exact_directory_files "$APP_RESOURCES/backend/bin"',
  "FFMPEG_LICENSE_SHA='246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30'",
  "ICON_PNG_SHA='d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f'",
  "RINGTONE_SHA='471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4'",
  "LIVEKIT_CLIENT_SHA='a77a2f4c363e93099d7c135721c9ec81d6c5bacc691796dad799222e33cbfb31'",
  "LIVEKIT_TUPLES_SHA='ea285d07a250275c543a02647227f0dbf1890d099f245c0b90fac0d4515b8daf'",
  'PACKAGED_ASSETS_VERIFIED=1',
  'node qa/third_party_licenses_qa.js',
  'node qa/third_party_licenses_qa.js "$APP_PATH"',
  'SOURCE_LICENSES_VERIFIED=1',
  'PACKAGED_LICENSES_VERIFIED=1',
  'pip-audit==2.10.1',
  'qa/staged_runtime_qa.py',
  'qa/packaged_runtime_qa.py',
  'PYTHON_DEPENDENCIES_AUDITED=1',
  'STAGED_RUNTIME_VERIFIED=1',
  'PACKAGED_RUNTIME_VERIFIED=1',
  'STAGED_NATIVE_PATHS_VERIFIED=1',
  'PACKAGED_NATIVE_PATHS_VERIFIED=1',
  'scripts/audit-native-build-paths.py',
  '"$FFMPEG_PATH" "$FFPROBE_PATH" "$PROJECT_ROOT/.electron-site-packages/cv2"',
  '"$PROJECT_ROOT/.electron-native"',
  '"$APP_RESOURCES/backend/bin/ffprobe"',
  '"$APP_RESOURCES/python/lib/python3.12/site-packages/cv2"',
  '"$APP_RESOURCES/native"',
  "WHISPER_WEIGHTS_SHA='ca6659298fe7550468ff0fc49dea7442615d9a53d1ce087aaded1b7627451998'",
  "WHISPER_MANIFEST_SHA='fe8fcd4669ddde49085cbfda28f207ec715000ff37c8fa51197ab63fdef91e83'",
]) {
  assert.ok(release.includes(required), `missing mandatory release gate: ${required}`);
}
for (const required of [
  '--enable-ffprobe',
  '--enable-muxer=mov,mp4,null,pcm_s16le,wav',
  '--enable-bsf=hevc_metadata,trace_headers',
  '"-muxers": {"mov", "mp4", "null", "s16le", "wav"}',
  '"-encoders": {"h264_videotoolbox", "hevc_videotoolbox", "pcm_s16le"}',
  '"-demuxers": {',
  '"-bsfs": {"trace_headers"}',
  'if verify_ffmpeg; then',
  '"$ROOT/qa/ffmpeg_alpha_runtime_qa.py" "$OUT_DIR"',
  'expected = {"ffmpeg", "ffprobe", "LICENSE.LGPLv2.1.txt"}',
  'LICENSE_EXPECTED="246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30"',
  'rm -rf -- "$OUT_DIR"',
  'CLEAR_PREFIX="/opt/openclam/ffmpeg-$VERSION"',
  'make install DESTDIR="$DESTDIR"',
  'scripts/audit-native-build-paths.py',
]) {
  assert.ok(ffmpegStager.includes(required), `FFmpeg stager is missing fail-closed gate: ${required}`);
}
for (const required of [
  'CANONICAL_BUILD_ROOT="/usr/src/openclam/opencv-$VERSION"',
  'CANONICAL_INSTALL_PREFIX="/opt/openclam/opencv-$VERSION"',
  '-ffile-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT',
  '-fdebug-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT',
  '-fmacro-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT',
  '-DOPENCV_CMAKE_HOOKS_DIR="$ROOT/scripts/opencv-cmake-hooks"',
  'scripts/sanitize-opencv-source-build-paths.py',
  '-DCMAKE_INSTALL_PREFIX="$CANONICAL_INSTALL_PREFIX"',
  'DESTDIR="$DESTDIR" cmake --install "$BUILD"',
  'scripts/audit-native-build-paths.py',
  '--reject-prefix "$BUILD_ROOT"',
  '"$BUILD/opencv_data_config.hpp" "$BUILD/version_string.tmp"',
  '#define OPENCV_BUILD_DIR',
  '$CANONICAL_BUILD_ROOT/build',
]) {
  assert.ok(opencvStager.includes(required),
    `OpenCV stager is missing deterministic build-path control: ${required}`);
}
for (const required of [
  'UPSTREAM_LITERAL',
  'SANITIZED_LITERAL',
  '#define OPENCV_BUILD_DIR',
  '${CMAKE_BINARY_DIR}',
  '${OPENCLAM_CANONICAL_BUILD_ROOT}/build',
  'upstream_count != 1 or sanitized_count != 0',
  'text.replace(UPSTREAM_LITERAL, SANITIZED_LITERAL)',
  'OpenCV build-directory source literal drifted; refusing to patch',
]) {
  assert.ok(opencvSourceSanitizer.includes(required),
    `OpenCV source sanitizer is missing fail-closed rewrite: ${required}`);
}
for (const required of [
  'OPENCV_BUILD_INFO_STR',
  'OPENCLAM_NATIVE_BUILD_ROOT',
  'OPENCLAM_CANONICAL_BUILD_ROOT',
  'string(REPLACE',
  'CACHE INTERNAL "" FORCE',
  'OpenCV build information still contains a temporary build path',
]) {
  assert.ok(opencvBuildInfoHook.includes(required),
    `OpenCV build-info hook is missing fail-closed sanitization: ${required}`);
}
for (const required of [
  '/(?:private/)?var/folders/',
  'openclam-(?:ffmpeg|opencv)-build',
  '/TemporaryItems/',
  '--reject-prefix',
  'the exact native build root',
  'path.read_bytes()',
]) {
  assert.ok(nativePathAudit.includes(required),
    `native build-path audit is missing detector: ${required}`);
}
for (const [name, runtimeQa] of [
  ['staged runtime QA', stagedRuntimeQa],
  ['packaged runtime QA', packagedRuntimeQa],
]) {
  for (const required of [
    'audit-native-build-paths.py', 'SITE_PACKAGES / "cv2"', 'str(CUTOUT)',
  ]) {
    assert.ok(runtimeQa.includes(required), `${name} is missing native path gate: ${required}`);
  }
}
for (const required of [
  "lipo", "-archs",
  "Mach-O has no arm64 slice",
  "vtool", "-show-build",
  "Mach-O has no inspectable macOS deployment target",
]) {
  assert.ok(deploymentAudit.includes(required), `deployment audit is missing fail-closed gate: ${required}`);
}
assert.ok(release.lastIndexOf('/usr/bin/shasum -a 256')
  > release.lastIndexOf('stapler staple -v "$DMG_PATH"'));

for (const required of [
  "const UPDATE_TEAM_ID = 'X7R8N6MMSU';",
  "const UPDATE_APP_ID = 'com.lionheart.openclam.macos';",
  "const UPDATE_FAILED_APP = '/Applications/.OpenClam-Studio-failed.app';",
  'async function requireNotarizedDmg(dmgPath)',
  'async function requireNotarizedApp(appPath, expectedVersion)',
  'asset.name === expectedDmgName',
  "matchingDmgs.length > 1",
  "refusing an update that is not strictly newer",
  "readValue('CFBundleIdentifier')",
  "readValue('CFBundleShortVersionString')",
  'metadata.identifier !== UPDATE_APP_ID',
  'metadata.version !== expectedVersion',
  "['stapler', 'validate', '-v', dmgPath]",
  "'--assess', '--type', 'open', '--context', 'context:primary-signature'",
  "['stapler', 'validate', '-v', appPath]",
  "'--assess', '--type', 'execute', '--verbose=4', appPath",
  "['distribution', appPath, '--verbose']",
  'await requireNotarizedDmg(dmgPath);',
  'await requireNotarizedApp(newApp, latest);',
  'await requireNotarizedApp(staging, latest);',
  'function scheduleRollbackRetirement()',
  'scheduleRollbackRetirement();',
  "fs.writeFileSync(marker, 'ok\\n'",
  "'/usr/bin/pkill -x \"OpenClam Studio\"",
  "/bin/mv -- \"$previous\" \"$current\" || exit 1",
  "/usr/bin/open \"$current\"",
]) {
  assert.ok(main.includes(required), `updater is missing Gatekeeper gate: ${required}`);
}
assert.doesNotMatch(main, /open "\/Applications\/OpenClam Studio\.app"; sleep 5;/);

console.log('fail-closed macOS release and updater QA passed');
