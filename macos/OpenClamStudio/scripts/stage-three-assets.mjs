// Stage the reviewed three.js runtime for the 3D avatar renderer.
//
// The renderer page is served by the loopback backend under a strict CSP
// (`script-src 'self'`), so no CDN and no import map. The published ES
// modules are copied into web/vendor/three with their bare `'three'`
// specifiers rewritten to sibling-relative paths, which lets Chromium load
// them as plain module scripts from this origin.
import { cspSafeBasis } from './basis-csp-glue.mjs';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = join(dirname(fileURLToPath(import.meta.url)), '..');
const threeRoot = join(project, 'node_modules', 'three');
const destination = join(project, 'web', 'vendor', 'three');
const licenses = join(project, 'LICENSES');

const packageInfo = JSON.parse(readFileSync(join(threeRoot, 'package.json'), 'utf8'));

// Only these files ship. GLTFLoader pulls two helpers from examples/jsm; the
// KTX2/Basis is used for locally derived GPU textures. DRACO and meshopt
// remain absent, and imports requiring those are rejected during validation.
const modules = [
  ['build/three.core.js', 'three.core.js'],
  ['build/three.module.js', 'three.module.js'],
  ['examples/jsm/loaders/GLTFLoader.js', 'GLTFLoader.js'],
  ['examples/jsm/loaders/KTX2Loader.js', 'KTX2Loader.js'],
  ['examples/jsm/utils/WorkerPool.js', 'WorkerPool.js'],
  ['examples/jsm/libs/ktx-parse.module.js', 'ktx-parse.module.js'],
  ['examples/jsm/libs/zstddec.module.js', 'zstddec.module.js'],
  ['examples/jsm/math/ColorSpaces.js', 'ColorSpaces.js'],
  ['examples/jsm/utils/BufferGeometryUtils.js', 'BufferGeometryUtils.js'],
  ['examples/jsm/utils/SkeletonUtils.js', 'SkeletonUtils.js'],
  ['examples/jsm/environments/RoomEnvironment.js', 'RoomEnvironment.js'],
];

mkdirSync(destination, { recursive: true });
mkdirSync(licenses, { recursive: true });

for (const [source, target] of modules) {
  let text = readFileSync(join(threeRoot, source), 'utf8');
  text = text
    .replace(/from\s+'three'/g, "from './three.module.js'")
    .replace(/from\s+'\.\.\/(?:utils|libs|math)\/([A-Za-z.-]+)\.js'/g, "from './$1.js'");
  const remaining = [...text.matchAll(/^\s*(?:import|export)[^;]*?from\s+'([^']+)'/gm)]
    .map(match => match[1])
    .filter(specifier => !specifier.startsWith('./'));
  if (remaining.length) {
    throw new Error(`unexpected external import left in ${source}: ${remaining.join(', ')}`);
  }
  writeFileSync(join(destination, target), text);
}

writeFileSync(join(destination,'basis_transcoder.js'),cspSafeBasis(readFileSync(join(threeRoot,'examples/jsm/libs/basis/basis_transcoder.js'),'utf8')));
copyFileSync(join(threeRoot,'examples/jsm/libs/basis/basis_transcoder.wasm'),join(destination,'basis_transcoder.wasm'));
copyFileSync(join(threeRoot, 'LICENSE'), join(licenses, 'THREE_MIT.txt'));
writeFileSync(join(destination, 'MANIFEST.json'), JSON.stringify({
  name: 'three',
  version: packageInfo.version,
  license: packageInfo.license,
  files: [...modules.map(([, target]) => target),'basis_transcoder.js','basis_transcoder.wasm'],
}, null, 2) + '\n');

console.log(`Staged three ${packageInfo.version} (${modules.length} modules) into web/vendor/three.`);
