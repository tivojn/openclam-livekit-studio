'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

// extraResources sources are excluded from app.asar by electron-builder.
// Copying package.json through that list removes Electron's own required
// package metadata. afterPack runs after assembly and BEFORE code signing.
module.exports = async function packageBackendMetadata(context) {
  const { packager, appOutDir } = context;
  const source = path.join(packager.info.projectDir, 'package.json');
  const canonical = await fs.readFile(source);
  const metadata = JSON.parse(canonical.toString('utf8'));
  if (!metadata.version || metadata.version !== packager.appInfo.version) {
    throw new Error('Canonical package version changed during packaging');
  }

  const resources = packager.getResourcesDir(appOutDir);
  const asar = await import('@electron/asar');
  const electronMetadata = JSON.parse(asar.extractFile(
    path.join(resources, 'app.asar'), 'package.json').toString('utf8'));
  for (const field of ['name', 'version', 'main']) {
    if (!metadata[field] || metadata[field] !== electronMetadata[field]) {
      throw new Error(`Electron and backend package metadata disagree: ${field}`);
    }
  }
  const target = path.join(resources, 'backend', 'package.json');
  await fs.mkdir(path.dirname(target), { recursive: true });
  // Write the exact canonical bytes, not a separately maintained version.
  await fs.writeFile(target, canonical, { mode: 0o644 });
  if (!(await fs.readFile(target)).equals(canonical)) {
    throw new Error('Packaged backend metadata does not match canonical package.json');
  }
};
