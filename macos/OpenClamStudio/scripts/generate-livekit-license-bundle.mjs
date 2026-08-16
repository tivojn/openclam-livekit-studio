import { createHash } from 'node:crypto';
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = join(dirname(fileURLToPath(import.meta.url)), '..');
const nodeModules = join(project, 'node_modules');
const outputDirectory = join(project, 'LICENSES');
const liveKitRoot = join(nodeModules, 'livekit-client');
const umdPath = join(liveKitRoot, 'dist', 'livekit-client.umd.js');
const sourceMapPath = `${umdPath}.map`;

const expectedSourceMappedPackages = new Map([
  ['@bufbuild/protobuf', '1.10.1'],
  ['@livekit/mutex', '1.1.1'],
  ['events', '3.3.0'],
  ['jose', '6.2.3'],
  ['loglevel', '1.9.2'],
  ['sdp', '3.2.2'],
  ['sdp-transform', '2.15.0'],
  ['webrtc-adapter', '9.0.6'],
]);

const packageLicenses = [
  {
    name: '@bufbuild/protobuf',
    installedVersion: '1.10.1',
    bundledVersion: '1.10.1',
    license: '(Apache-2.0 AND BSD-3-Clause)',
    sourceMapped: true,
  },
  {
    name: '@livekit/mutex',
    installedVersion: '1.1.1',
    bundledVersion: '1.1.1',
    license: 'Apache-2.0',
    licenseFile: 'LICENSE',
    licenseSha256: '09e8a9bcec8067104652c168685ab0931e7868f9c8284b66f5ae6edae5f1130b',
    sourceMapped: true,
  },
  {
    name: '@livekit/protocol',
    installedVersion: '1.50.4',
    bundledVersion: '1.50.4',
    license: 'Apache-2.0',
    licenseFile: 'LICENSE',
    licenseSha256: 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
    sourceMapped: false,
  },
  {
    name: 'events',
    installedVersion: '3.3.0',
    bundledVersion: '3.3.0',
    license: 'MIT',
    licenseFile: 'LICENSE',
    licenseSha256: '631987b7616a325a5b97566c232418481ddf7dbb5ecadefb991e791876cc2599',
    sourceMapped: true,
  },
  {
    name: 'jose',
    installedVersion: '6.2.8',
    bundledVersion: '6.2.3',
    license: 'MIT',
    licenseFile: 'LICENSE.md',
    licenseSha256: '8078b0829d6c3e9ecde2f003e1966e4cad3efc6e7a640efbab0313cc166b1af1',
    sourceMapped: true,
    note: 'The published UMD was built with 6.2.3. Its MIT text is byte-identical to the checked 6.2.8 install used to source this notice.',
  },
  {
    name: 'loglevel',
    installedVersion: '1.9.2',
    bundledVersion: '1.9.2',
    license: 'MIT',
    licenseFile: 'LICENSE-MIT',
    licenseSha256: '18e8cf5f0dbaf13d9562e93b9bef79aff2acff18fab698c2d589d2159375a1f9',
    sourceMapped: true,
  },
  {
    name: 'sdp',
    installedVersion: '3.2.2',
    bundledVersion: '3.2.2',
    license: 'MIT',
    licenseFile: 'LICENSE',
    licenseSha256: '798e82590af6a84bfbde3d6bb0fb9162c519edf16122404fea00acefdc55cbd9',
    sourceMapped: true,
  },
  {
    name: 'sdp-transform',
    installedVersion: '2.15.0',
    bundledVersion: '2.15.0',
    license: 'MIT',
    licenseFile: 'LICENSE',
    licenseSha256: '653b7af11548d1bf4a73d0d9dcca68d709d2b78633088b75332c02d739559afa',
    sourceMapped: true,
  },
  {
    name: 'tslib',
    installedVersion: '2.8.1',
    bundledVersion: '2.8.1',
    license: '0BSD',
    licenseFile: 'LICENSE.txt',
    licenseSha256: '210b19e543130388c68654b7497e967119ce17145f66ab7d85688fbd70f08751',
    sourceMapped: false,
  },
  {
    name: 'typed-emitter',
    installedVersion: '2.1.0',
    bundledVersion: '2.1.0',
    license: 'MIT',
    licenseFile: 'LICENSE',
    licenseSha256: 'dfab9450d2bf4112af202be012c098a06e91248156961c2d45fd1fd1894ae2ff',
    sourceMapped: false,
  },
  {
    name: 'webrtc-adapter',
    installedVersion: '9.0.6',
    bundledVersion: '9.0.6',
    license: 'BSD-3-Clause',
    licenseFile: 'LICENSE.md',
    licenseSha256: '00a46c6cfc219593b97586398b477e188391556e70487225d3ff9d60ccda6dce',
    sourceMapped: true,
  },
];

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function packageRoot(name) {
  return join(nodeModules, ...name.split('/'));
}

function packageMetadata(name) {
  return JSON.parse(readFileSync(join(packageRoot(name), 'package.json'), 'utf8'));
}

function sourceMappedPackage(source) {
  const marker = '/node_modules/';
  const markerIndex = source.lastIndexOf(marker);
  const pnpmMatch = source.match(/\/\.pnpm\/([^/]+)\/node_modules\//u);
  if (markerIndex < 0 || pnpmMatch === null) return null;
  const pathParts = source.slice(markerIndex + marker.length).split('/');
  const name = pathParts[0].startsWith('@')
    ? `${pathParts[0]}/${pathParts[1]}`
    : pathParts[0];
  const pnpmToken = pnpmMatch[1];
  const version = pnpmToken.slice(pnpmToken.lastIndexOf('@') + 1);
  return { name, version };
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
}

function extractBufVarintLicense(sourceMap) {
  const index = sourceMap.sources.findIndex((source) =>
    source.endsWith('@bufbuild/protobuf/dist/esm/google/varint.js'));
  if (index < 0 || typeof sourceMap.sourcesContent?.[index] !== 'string') {
    throw new Error('Buf varint source/license is missing from the LiveKit UMD source map');
  }
  const commentLines = [];
  for (const line of sourceMap.sourcesContent[index].split('\n')) {
    if (!line.startsWith('//')) break;
    commentLines.push(line.replace(/^\/\/ ?/u, ''));
  }
  const text = `${commentLines.join('\n').trim()}\n`;
  if (!text.includes('Copyright 2008 Google Inc.') ||
      !text.includes('Redistribution and use in source and binary forms')) {
    throw new Error('Buf BSD-3-Clause attribution could not be verified');
  }
  return text;
}

export function generateLiveKitLicenseBundle() {
  const liveKitMetadata = packageMetadata('livekit-client');
  assertEqual(liveKitMetadata.version, '2.21.0', 'livekit-client version');
  assertEqual(liveKitMetadata.license, 'Apache-2.0', 'livekit-client license');

  const umd = readFileSync(umdPath);
  const sourceMap = JSON.parse(readFileSync(sourceMapPath, 'utf8'));
  const observed = new Map();
  for (const source of sourceMap.sources) {
    const entry = sourceMappedPackage(source);
    if (entry === null) continue;
    const previous = observed.get(entry.name);
    if (previous !== undefined && previous !== entry.version) {
      throw new Error(`multiple bundled versions of ${entry.name}: ${previous}, ${entry.version}`);
    }
    observed.set(entry.name, entry.version);
  }
  assertEqual(
    JSON.stringify([...observed.entries()].sort()),
    JSON.stringify([...expectedSourceMappedPackages.entries()].sort()),
    'LiveKit UMD source-mapped dependency set',
  );

  const apacheText = readFileSync(join(liveKitRoot, 'LICENSE'), 'utf8');
  assertEqual(
    sha256(apacheText),
    '09e8a9bcec8067104652c168685ab0931e7868f9c8284b66f5ae6edae5f1130b',
    'livekit-client Apache license hash',
  );
  const topLevelLicenseName = 'LIVEKIT_CLIENT_APACHE-2.0.txt';
  const bundleName = 'LIVEKIT_UMD_BUNDLED_LICENSES.txt';
  const manifestName = 'LIVEKIT_UMD_MANIFEST.json';

  const sections = [
    'LiveKit client UMD bundled dependency licenses',
    '================================================',
    '',
    'Generated deterministically from livekit-client 2.21.0, its published UMD',
    'source map, checked package metadata, and checked publisher license files.',
    'Packages that are declared by the SDK but not retained as separate source-map',
    'paths are included conservatively.',
    '',
  ];
  const manifestPackages = [];
  const bufBsdText = extractBufVarintLicense(sourceMap);

  for (const entry of packageLicenses) {
    const metadata = packageMetadata(entry.name);
    assertEqual(metadata.version, entry.installedVersion, `${entry.name} installed version`);
    assertEqual(metadata.license, entry.license, `${entry.name} license expression`);
    if (entry.sourceMapped) {
      assertEqual(observed.get(entry.name), entry.bundledVersion, `${entry.name} bundled version`);
    }

    let licenseText;
    let licenseSource;
    if (entry.name === '@bufbuild/protobuf') {
      licenseText = [
        'Apache License 2.0 (applies to all files except google/varint.js)',
        '-----------------------------------------------------------------',
        '',
        apacheText.trim(),
        '',
        'BSD-3-Clause attribution (google/varint.js)',
        '--------------------------------------------',
        '',
        bufBsdText.trim(),
        '',
      ].join('\n');
      licenseSource = 'LiveKit UMD source map plus checked Apache-2.0 text';
    } else {
      licenseText = readFileSync(join(packageRoot(entry.name), entry.licenseFile), 'utf8');
      assertEqual(sha256(licenseText), entry.licenseSha256, `${entry.name} license hash`);
      licenseSource = `node_modules/${entry.name}/${entry.licenseFile}`;
    }

    sections.push(
      `${entry.name} ${entry.bundledVersion} — ${entry.license}`,
      '-'.repeat(Math.min(78, entry.name.length + entry.bundledVersion.length + entry.license.length + 5)),
      '',
    );
    if (entry.note) sections.push(entry.note, '');
    sections.push(licenseText.trim(), '');
    manifestPackages.push({
      name: entry.name,
      bundled_version: entry.bundledVersion,
      installed_license_source_version: entry.installedVersion,
      license_expression: entry.license,
      source_mapped: entry.sourceMapped,
      license_source: licenseSource,
      license_text_sha256: sha256(`${licenseText.trim()}\n`),
      ...(entry.note ? { note: entry.note } : {}),
    });
  }

  const bundleText = `${sections.join('\n').trim()}\n`;
  const manifest = {
    schema_version: 1,
    generated_from: 'livekit-client@2.21.0 published UMD and source map',
    umd: {
      relative_path: 'web/vendor/livekit-client.umd.js',
      sha256: sha256(umd),
    },
    top_level_license: {
      relative_path: `LICENSES/${topLevelLicenseName}`,
      sha256: sha256(apacheText),
    },
    bundled_license_file: {
      relative_path: `LICENSES/${bundleName}`,
      sha256: sha256(bundleText),
    },
    packages: manifestPackages,
  };

  mkdirSync(outputDirectory, { recursive: true });
  writeFileSync(join(outputDirectory, topLevelLicenseName), apacheText, 'utf8');
  writeFileSync(join(outputDirectory, bundleName), bundleText, 'utf8');
  writeFileSync(join(outputDirectory, manifestName), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  return manifest;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const manifest = generateLiveKitLicenseBundle();
  process.stdout.write(
    `Generated checked LiveKit notices for ${manifest.packages.length} bundled or declared dependencies.\n`,
  );
}
