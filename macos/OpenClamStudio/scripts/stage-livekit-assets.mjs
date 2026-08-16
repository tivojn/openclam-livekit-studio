import { copyFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { generateLiveKitLicenseBundle } from './generate-livekit-license-bundle.mjs';

const project = join(dirname(fileURLToPath(import.meta.url)), '..');
const destination = join(project, 'web', 'vendor');

mkdirSync(destination, { recursive: true });
copyFileSync(
  join(project, 'node_modules', 'livekit-client', 'dist', 'livekit-client.umd.js'),
  join(destination, 'livekit-client.umd.js'),
);
copyFileSync(
  join(project, 'assets', 'live-talk-connection.wav'),
  join(destination, 'live-talk-connection.wav'),
);
generateLiveKitLicenseBundle();
