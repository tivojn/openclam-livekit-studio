'use strict';

// Signing and stapling change the DMG after electron-builder first emits
// update metadata. Rebuild the sidecars from the verified final installer.
const fs = require('node:fs/promises');
const crypto = require('node:crypto');
const path = require('node:path');
const assert = require('node:assert/strict');

async function main() {
  const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
  const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const name = `OpenClam-Studio-${pkg.version}-arm64.dmg`;
  const file = path.join(root, 'dist-electron', name);
  const metadataPath = path.join(root, 'dist-electron', 'latest-mac.yml');
  const yaml = require(path.join(root, 'node_modules', 'js-yaml'));
  const { buildBlockMap } = require(path.join(root, 'node_modules', 'app-builder-lib',
    'out', 'targets', 'blockmap', 'blockmap.js'));
  const metadata = yaml.load(await fs.readFile(metadataPath, 'utf8'));
  assert.equal(metadata.version, pkg.version, 'update metadata version mismatch');
  assert.equal(metadata.files.length, 1, 'expected one Apple Silicon installer');
  assert.equal(metadata.files[0].url, name, 'update metadata installer mismatch');
  const receipt = (await fs.readFile(`${file}.sha256`, 'utf8')).trim();
  const digest = () => fs.readFile(file).then(bytes =>
    crypto.createHash('sha256').update(bytes).digest('hex'));
  const before = await digest();
  assert.equal(receipt, `${before}  ${name}`, 'final installer checksum mismatch');
  const info = await buildBlockMap(file, 'gzip', `${file}.blockmap`);
  assert.equal(await digest(), before, 'sidecar generation changed the installer');
  metadata.files[0] = { ...metadata.files[0], sha512: info.sha512, size: info.size };
  metadata.path = name;
  metadata.sha512 = info.sha512;
  await fs.writeFile(`${metadataPath}.tmp`, yaml.dump(metadata, { lineWidth: -1 }));
  await fs.rename(`${metadataPath}.tmp`, metadataPath);
  console.log('Final DMG blockmap and update metadata verified.');
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
