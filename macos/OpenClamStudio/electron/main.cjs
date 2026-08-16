'use strict';

const {
  app,
  BrowserWindow,
  Menu,
  Tray,
  dialog,
  globalShortcut,
  ipcMain,
  nativeImage,
  powerMonitor,
  screen,
  session,
  shell,
} = require('electron');
const { spawn, execFile, execFileSync } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const {
  boundsForPetZoom,
  boundsForPetZoomAtAnchor,
  clampPetZoom,
  dockedPetBounds,
  fitPetZoomToArea,
  petZoomAnchor,
  petZoomSize,
  roamSizeForZoom,
} = require('./pet-window-bounds.cjs');
const { effectivePetAlwaysOnTop } = require('./pet-window-level.cjs');
const {
  AvatarStore,
  AvatarStoreError,
  normalizeError: normalizeAvatarStoreError,
} = require('./avatar-store.cjs');

const HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const START_TIMEOUT_MS = 120_000;
const APP_ID = 'com.lionheart.openclam.macos';
const APP_NAME = 'OpenClam Studio';
const AUTH_HEADER = 'X-OpenClam-Token';
const LIVEKIT_BROKER_URL = 'https://openclam-livekit-pilot-broker.openclam-live.workers.dev/v1/live-talk/sessions';
const LIVEKIT_SERVER_HOST = 'openclam-live-voice-kse86f6p.livekit.cloud';

app.setName(APP_NAME);
app.setAppUserModelId(APP_ID);

// The local renderer and the loopback-only Python service authenticate each
// other with a persistent random token scoped to this standalone app.
function persistentBackendToken() {
  const tokenPath = path.join(app.getPath('userData'), 'backend-auth-token');
  try {
    const existing = fs.readFileSync(tokenPath, 'utf8').trim();
    if (/^[0-9a-f]{64}$/.test(existing)) return existing;
  } catch {}
  const fresh = randomBytes(32).toString('hex');
  try {
    fs.mkdirSync(path.dirname(tokenPath), { recursive: true });
    fs.writeFileSync(tokenPath, fresh, { mode: 0o600 });
  } catch {}
  return fresh;
}
const backendToken = persistentBackendToken();

let port = Number(process.env.OPENCLAM_PORT || DEFAULT_PORT);
let backend = null;
let ownsBackend = false;
let quitting = false;
let mainWindow = null;
let settingsWindow = null;
let bubbleWindow = null;
let appearanceWindow = null;
let bubbleTimer = null;
let pendingBubble = '';
let tray = null;
let state = null;
let saveTimer = null;
let backendLog = null;
let petDrag = null;
// Chat-bar control rectangles (window-local), reported by each renderer while
// its bar is visible. The cursor tracker claims these AUTHORITATIVELY: the
// renderer-side alpha claim rides rAF -> hysteresis -> IPC, and any stall in
// that chain used to read as clicks falling through to the app below.
let petControlRects = [];
let buddyControlRects = [];
let petPointerTimer = null;
const pointerLastSent = { pet: null, buddy: null };
let petPointerInteractive = null;
let petPointerDebugAt = 0;
let petRoamTimer = null;
let preDockBounds = null;
let petRoamRuntime = null;
let petRoamHoverGate = { armed: false, inside: false };
let petZoomGesture = null;
let appearancePushAt = 0;
let petMotionReady = false;
let liveTalkActive = false;
let avatarStoreInstance = null;
const avatarStoreJobs = new Map();
let petMotionProfile = {
  walkSpeed: 64,
  cycleSeconds: 1.1,
  cycleDistance: 70.4,
  travelOffsets: [],
};
// The second on-desk avatar ("buddy"): its own window on the LEFT screen
// edge, mirroring the active avatar's right-side behaviour. Its state is
// deliberately in-memory only - the server's companion.json is the source of
// truth for WHICH avatar sits on the left desk, and everything else resets
// with the window.
let buddyWindow = null;
let buddySlug = null;
let buddyRoam = false;
let buddyRoamTimer = null;
let buddyRoamRuntime = null;
let buddyMotionReady = false;
let buddyMotionProfile = {
  walkSpeed: 64,
  cycleSeconds: 1.1,
  cycleDistance: 70.4,
  travelOffsets: [],
};
let buddyDrag = null;
let buddyPointerInteractive = null;
let buddyOpacity = null; // null follows state.petOpacity
const PET_VIEWS = new Set(['full', 'three-quarter', 'half', 'bust', 'head', 'face']);
const PET_BASE_SIZE = Object.freeze({ width: 560, height: 760 });
const PET_NORMAL_MINIMUM = Object.freeze({ width: 140, height: 190 });
const PET_ZOOM_RANGE = Object.freeze({ min: 0.25, max: 4 });
const PET_DOCK_MARGIN = 28;
const PET_ROAM_SIZE = Object.freeze({ width: 250, height: 340 });
const PET_ROAM_MINIMUM = Object.freeze({ width: 96, height: 130 });
const PET_ROAM_ZOOM_RANGE = Object.freeze({ min: 0.5, max: 3 });
const PET_ROAM_MIN_SPEED = 42;
const PET_ROAM_MAX_SPEED = 150;
const PET_LEDGE_HOLD_MS = 9000;
const PET_INTERACTION_COOLDOWN_MS = 1400;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const baseUrl = () => `http://${HOST}:${port}`;

// Entering Horizon Walk resizes and repositions the transparent pet window.
// That geometry change can put the avatar underneath a cursor that never
// moved, which is not an intentional hover. Require one observed leave before
// a later re-entry may pause roaming; real hover remains available afterward.
function observeRoamPointer(gate, inside) {
  const next = gate && typeof gate === 'object' ? gate : { armed: false, inside: false };
  next.inside = Boolean(inside);
  if (!next.armed && !next.inside) next.armed = true;
  return next;
}

function roamHoverCanEngage(engaged, gate) {
  return !engaged || Boolean(gate && gate.armed && gate.inside);
}

const codeRoot = () => app.isPackaged
  ? path.join(process.resourcesPath, 'backend')
  : path.resolve(__dirname, '..');
const dataRoot = () => process.env.OPENCLAM_DATA_DIR || (app.isPackaged
  ? path.join(app.getPath('userData'), 'backend-data')
  : codeRoot());
const statePath = () => path.join(app.getPath('userData'), 'window-state.json');
const logPath = () => path.join(app.getPath('userData'), 'backend.log');

function ensureDataRoot() {
  fs.mkdirSync(dataRoot(), { recursive: true, mode: 0o700 });
}

function resolveMotionAsset(slug, relativePath) {
  if (!/^[a-z0-9](?:[a-z0-9-]{0,62})$/.test(String(slug || ''))) {
    throw new Error('Invalid avatar.');
  }
  const root = fs.realpathSync(path.join(dataRoot(), 'avatars', slug, 'motion'));
  const requested = String(relativePath || '').split(path.win32.sep).join('/');
  if (!requested || path.isAbsolute(requested)) throw new Error('Invalid motion asset.');
  const source = fs.realpathSync(path.resolve(root, requested));
  if (!source.startsWith(`${root}${path.sep}`)) throw new Error('Invalid motion asset.');
  if (!fs.statSync(source).isFile()) throw new Error('Motion asset is unavailable.');
  return source;
}

async function saveMotionAsset(event, asset = {}) {
  const source = resolveMotionAsset(asset.slug, asset.relativePath);
  const requestedName = path.basename(String(asset.defaultName || path.basename(source)));
  const defaultName = requestedName && requestedName !== '.' ? requestedName : path.basename(source);
  const extension = path.extname(defaultName).slice(1);
  const options = {
    title: 'Save motion asset',
    buttonLabel: 'Save',
    defaultPath: path.join(app.getPath('downloads'), defaultName),
    properties: ['createDirectory', 'showOverwriteConfirmation'],
    filters: extension ? [{ name: `${extension.toUpperCase()} file`, extensions: [extension] }] : [],
  };
  const owner = BrowserWindow.fromWebContents(event.sender);
  const result = owner
    ? await dialog.showSaveDialog(owner, options)
    : await dialog.showSaveDialog(options);
  if (result.canceled || !result.filePath) return { saved: false, canceled: true };
  if (path.resolve(result.filePath) !== source) {
    await fs.promises.copyFile(source, result.filePath);
  }
  return { saved: true, canceled: false, filePath: result.filePath };
}

function avatarStore() {
  if (!avatarStoreInstance) {
    avatarStoreInstance = new AvatarStore({
      cacheRoot: path.join(app.getPath('userData'), 'avatar-store-v1'),
    });
  }
  return avatarStoreInstance;
}

function avatarStoreSender(event) {
  return Boolean(settingsWindow && !settingsWindow.isDestroyed()
    && event && event.sender === settingsWindow.webContents);
}

function avatarStoreFailure(error) {
  const normalized = normalizeAvatarStoreError(error);
  const messages = {
    cancelled: 'Download cancelled.',
    catalog_invalid: 'The Avatar Store catalog did not pass validation.',
    catalog_unavailable: 'Connect to the internet to load the Avatar Store.',
    download_oversized: 'The avatar download is larger than the verified catalog allows.',
    integrity_failed: 'This avatar did not pass verification. Nothing was installed.',
    network_refused: 'The download left the verified OpenClam GitHub source and was stopped.',
    network_failed: 'Could not reach the Avatar Store. Check your connection and try again.',
    import_failed: 'The downloaded avatar is not a valid OpenClam Mac package.',
  };
  return {code: normalized.code, error: messages[normalized.code] || messages.network_failed};
}

async function avatarStoreLocalSlugs() {
  try {
    const response = await fetch(`${baseUrl()}/api/avatars`, {
      headers: {[AUTH_HEADER]: backendToken},
    });
    const payload = await response.json();
    if (!response.ok || !Array.isArray(payload.avatars)) return new Set();
    return new Set(payload.avatars.map((avatar) => String(avatar.slug || '')));
  } catch { return new Set(); }
}

async function avatarStoreCatalog(event, options = {}) {
  if (!avatarStoreSender(event)) return {ok: false, error: 'Avatar Store is available in Settings.'};
  try {
    const store = avatarStore();
    const [{catalog, source, warning}, localSlugs] = await Promise.all([
      store.catalog({force: options && options.force === true}),
      avatarStoreLocalSlugs(),
    ]);
    const installations = store.readInstallations();
    const items = await Promise.all(catalog.entries.map(async (entry) => {
      const record = installations[entry.id];
      const hasRecordedInstall = Boolean(record && localSlugs.has(record.slug));
      const installed = Boolean(hasRecordedInstall && record.version >= entry.version);
      const updateAvailable = Boolean(hasRecordedInstall && record.version < entry.version);
      return {
        id: entry.id,
        name: entry.name,
        author: entry.author,
        version: entry.version,
        bytes: entry.variants['macos-full'].bytes,
        cached: await store.packageCached(entry),
        installed,
        updateAvailable,
        installedVersion: hasRecordedInstall ? record.version : 0,
        installedSlug: installed ? record.slug : '',
      };
    }));
    return {ok: true, source, warning, items};
  } catch (error) {
    return {ok: false, ...avatarStoreFailure(error), items: []};
  }
}

async function avatarStoreThumbnail(event, identifier) {
  if (!avatarStoreSender(event)) return {ok: false, error: 'Avatar Store is available in Settings.'};
  try {
    return {ok: true, ...await avatarStore().thumbnail(String(identifier || ''))};
  } catch (error) {
    return {ok: false, ...avatarStoreFailure(error)};
  }
}

function postAvatarStoreProgress(sender, payload) {
  if (!sender || sender.isDestroyed()) return;
  sender.send('openclam:avatar-store-progress', payload);
}

async function importAvatarStorePackage(file, entry) {
  const form = new FormData();
  const blob = await fs.openAsBlob(file, {type: 'application/vnd.openclam.avatar+zip'});
  form.append('archive', blob, `${entry.id}-Mac.avtr`);
  const response = await fetch(`${baseUrl()}/api/avatar/import`, {
    method: 'POST',
    headers: {[AUTH_HEADER]: backendToken},
    body: form,
  });
  let payload = {};
  try { payload = await response.json(); } catch {}
  if (!response.ok || payload.detail || payload.error || !payload.slug) {
    throw new AvatarStoreError('import_failed', String(
      payload.detail || payload.error || `avatar import failed (HTTP ${response.status})`));
  }
  return payload;
}

async function downloadAvatarStoreItem(event, identifier) {
  if (!avatarStoreSender(event)) return {ok: false, error: 'Avatar Store is available in Settings.'};
  const id = String(identifier || '');
  if (avatarStoreJobs.has(id)) return {ok: false, code: 'busy', error: 'This avatar is already downloading.'};
  const controller = new AbortController();
  const job = {controller, sender: event.sender, phase: 'preparing'};
  avatarStoreJobs.set(id, job);
  try {
    let lastProgressAt = 0;
    let lastProgressPercent = -1;
    let lastProgressPhase = '';
    const download = await avatarStore().download(id, {
      signal: controller.signal,
      onProgress: (progress) => {
        job.phase = progress.phase;
        const now = Date.now();
        const percent = Math.max(0, Math.min(100, Number(progress.percent) || 0));
        if (progress.phase !== lastProgressPhase || percent === 0 || percent === 100
            || percent > lastProgressPercent && now - lastProgressAt >= 80) {
          lastProgressAt = now;
          lastProgressPercent = percent;
          lastProgressPhase = progress.phase;
          postAvatarStoreProgress(event.sender, {...progress, percent});
        }
      },
    });
    if (controller.signal.aborted) {
      throw new AvatarStoreError('cancelled', 'Download cancelled.');
    }
    job.phase = 'installing';
    postAvatarStoreProgress(event.sender, {
      id,
      phase: 'installing',
      loaded: download.entry.variants['macos-full'].bytes,
      total: download.entry.variants['macos-full'].bytes,
      percent: 100,
      cached: download.fromCache,
    });
    const imported = await importAvatarStorePackage(download.file, download.entry);
    await avatarStore().recordInstallation(download.entry, imported.slug);
    postAvatarStoreProgress(event.sender, {
      id,
      phase: 'complete',
      loaded: download.entry.variants['macos-full'].bytes,
      total: download.entry.variants['macos-full'].bytes,
      percent: 100,
      cached: download.fromCache,
    });
    return {
      ok: true,
      id,
      slug: imported.slug,
      name: imported.name || download.entry.name,
      status: imported.status || 'ready',
      cached: download.fromCache,
    };
  } catch (error) {
    const failure = avatarStoreFailure(error);
    postAvatarStoreProgress(event.sender, {id, phase: failure.code === 'cancelled' ? 'cancelled' : 'failed',
      percent: 0, loaded: 0, total: 0, error: failure.error});
    return {ok: false, ...failure};
  } finally {
    if (avatarStoreJobs.get(id) === job) avatarStoreJobs.delete(id);
  }
}

function cancelAvatarStoreItem(event, identifier) {
  if (!avatarStoreSender(event)) return false;
  const job = avatarStoreJobs.get(String(identifier || ''));
  if (!job || job.sender !== event.sender
      || !['preparing', 'downloading'].includes(job.phase)) return false;
  job.controller.abort();
  return true;
}

function cancelAllAvatarStoreJobs() {
  for (const job of avatarStoreJobs.values()) job.controller.abort();
  avatarStoreJobs.clear();
}

function executable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolvePython() {
  const candidates = [
    process.env.OPENCLAM_PYTHON,
    path.join(codeRoot(), '.venv', 'bin', 'python'),
    path.join(process.resourcesPath, 'python', 'bin', 'python'),
    path.join(dataRoot(), '.venv', 'bin', 'python'),
    '/opt/homebrew/bin/python3',
    '/usr/local/bin/python3',
    '/usr/bin/python3',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (executable(candidate)) return candidate;
  }
  try {
    const found = execFileSync('/usr/bin/which', ['python3'], { encoding: 'utf8' }).trim();
    if (found && executable(found)) return found;
  } catch {
    // Report one useful error below.
  }
  throw new Error(
    'No Python backend found. Set OPENCLAM_PYTHON or run scripts/setup-electron-backend.sh.',
  );
}

function requestJson(pathname, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const request = http.get({
      host: HOST,
      port,
      path: pathname,
      headers: { [AUTH_HEADER]: backendToken },
    }, (response) => {
      let raw = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        if (raw.length < 1_000_000) raw += chunk;
      });
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) return resolve(null);
        try { return resolve(JSON.parse(raw)); } catch { return resolve(null); }
      });
    });
    request.setTimeout(timeoutMs, () => request.destroy());
    request.on('error', () => resolve(null));
  });
}

async function openClamMetadata(timeoutMs = 1500) {
  const metadata = await requestJson('/api/meta', timeoutMs);
  return metadata && metadata.app_id === APP_ID ? metadata : null;
}

async function isOpenClamBackend(timeoutMs = 1500) {
  return Boolean(await openClamMetadata(timeoutMs));
}

function portInUse(candidate) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host: HOST, port: candidate });
    socket.setTimeout(500);
    socket.once('connect', () => { socket.destroy(); resolve(true); });
    socket.once('timeout', () => { socket.destroy(); resolve(false); });
    socket.once('error', () => resolve(false));
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once('error', reject);
    server.listen(0, HOST, () => {
      const address = server.address();
      const selected = typeof address === 'object' ? address.port : DEFAULT_PORT;
      server.close(() => resolve(selected));
    });
  });
}

async function choosePort() {
  if (!await portInUse(port)) return;
  if (process.env.OPENCLAM_PORT) {
    throw new Error(`Requested backend port ${port} is already in use.`);
  }
  port = await freePort();
}

function backendEnvironment() {
  const root = codeRoot();
  const data = dataRoot();
  const inherited = { ...process.env };
  // A packaged macOS app must never inherit a plaintext-vault escape hatch.
  // Provider credentials stay in OpenClam's Keychain service.
  delete inherited.OPENCLAM_VAULT_FILE;
  // The signed build owns its OAuth application identity. Never let a launch
  // environment substitute another application's public client ID.
  delete inherited.OPENCLAM_XAI_OAUTH_CLIENT_ID;
  return {
    ...inherited,
    PYTHONUNBUFFERED: '1',
    PYTHONDONTWRITEBYTECODE: '1',
    TOKENIZERS_PARALLELISM: 'false',
    OPENCLAM_DATA_DIR: data,
    OPENCLAM_CONFIG: path.join(data, 'config.json'),
    OPENCLAM_FACE_MODEL: path.join(root, 'models', 'face_landmarker.task'),
    OPENCLAM_CUTOUT_HELPER: path.join(
      app.isPackaged ? process.resourcesPath : root,
      app.isPackaged ? 'native' : '.electron-native',
      'person-cutout',
    ),
    OPENCLAM_NO_RVM: '1',
    OPENCLAM_PACKAGED: app.isPackaged ? '1' : '0',
    OPENCLAM_AUTH_TOKEN: backendToken,
    OPENCLAM_LIVEKIT_BROKER_URL: LIVEKIT_BROKER_URL,
    OPENCLAM_LIVEKIT_SERVER_HOST: LIVEKIT_SERVER_HOST,
    PATH: [
      path.join(root, 'bin'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
      process.env.PATH || '',
    ].join(path.delimiter),
  };
}

function writeBackendLog(chunk) {
  if (!backendLog) {
    fs.mkdirSync(path.dirname(logPath()), { recursive: true });
    backendLog = fs.createWriteStream(logPath(), { flags: 'a', mode: 0o600 });
    try { fs.chmodSync(logPath(), 0o600); } catch {}
  }
  backendLog.write(chunk);
}

// A window that is not destroyed can still have a disposed RENDER FRAME:
// during quit, and in the gap between a reload tearing the old frame down
// and the new one existing. send() then spams the console with "Render
// frame was disposed before WebFrameMain could be accessed", and the
// rapid event sources can print it on every restart. The try/catch below
// never silenced it: Electron
// LOGS that error from inside send() rather than throwing, and
// isDestroyed() stays false because the webContents outlive the frame.
// The only working move is to know the renderer is gone BEFORE calling
// send - the quitting flag covers shutdown, and the two events below mark
// a window whose frame died under it.
const watchedRenderers = new WeakSet();
const deadRenderers = new WeakSet();
function post(window, channel, payload) {
  if (quitting) return;
  if (!window || window.isDestroyed()) return;
  const contents = window.webContents;
  if (!contents || contents.isDestroyed() || deadRenderers.has(contents)) return;
  if (!watchedRenderers.has(contents)) {
    watchedRenderers.add(contents);
    contents.once('destroyed', () => deadRenderers.add(contents));
    contents.on('render-process-gone', () => deadRenderers.add(contents));
    // A reload brings a fresh renderer up on the same webContents; the
    // window is speakable again the moment the new frame finishes.
    contents.on('did-finish-load', () => deadRenderers.delete(contents));
  }
  try {
    contents.send(channel, payload);
  } catch (error) {
    // The frame went away between the check and the call. Nothing to do,
    // and nothing worth saying: the renderer is gone, so was the message.
  }
}

function stopBackend() {
  if (!backend || !ownsBackend) return;
  backend.removeAllListeners('exit');
  backend.kill('SIGTERM');
  backend = null;
  ownsBackend = false;
}

async function startBackend() {
  ensureDataRoot();
  await choosePort();

  const python = resolvePython();
  // The Python service is an app-private component. The iOS product is
  // independent and never discovers or connects to it.
  const args = [
    '-B', '-W', 'ignore', '-m', 'uvicorn', 'server.app:app',
    '--host', HOST, '--port', String(port),
  ];
  writeBackendLog(`\n\n[Electron ${new Date().toISOString()}] ${python} ${args.join(' ')}\n`);
  backend = spawn(python, args, {
    cwd: codeRoot(),
    env: backendEnvironment(),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  ownsBackend = true;
  backend.stdout.on('data', writeBackendLog);
  backend.stderr.on('data', writeBackendLog);
  backend.once('exit', (code, signal) => {
    writeBackendLog(`[backend exited] code=${code} signal=${signal}\n`);
    backend = null;
    ownsBackend = false;
    if (!quitting && mainWindow && !mainWindow.isDestroyed()) {
      post(mainWindow, 'openclam:state', shellState());
    }
  });

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await isOpenClamBackend(2000)) return;
    if (!backend) break;
    await sleep(500);
  }
  stopBackend();
  throw new Error(`The Python backend did not start. See ${logPath()}`);
}

function defaultState() {
  return {
    alwaysOnTop: true,
    petMode: true,
    petOpacity: 1,
    // Full body out of the box: the half view read as "her legs are
    // missing" on a fresh install, and the feet/leg click affordances
    // (dim, walk) need the whole figure on screen (owner, 2026-08-02).
    petView: 'full',
    // 60% across the board: the full-size character crowded the desktop,
    // and 60% keeps the 720p-capped animation frames near 1:1 on screen.
    petZoom: 0.6,
    petRoamZoom: 0.6,
    appearanceDefaultVersion: 4,
    petClickThrough: true,
    petLocked: false,
    petRoam: false,
    petHomeBounds: null,
    bounds: { width: 560, height: 760 },
  };
}

function petClickThroughPreference(saved, fallback = true) {
  // A missing value is a first-run/legacy-without-a-choice state. An actual
  // boolean, including false, is a user preference and must survive updates.
  return Object.hasOwn(saved, 'petClickThrough')
    && typeof saved.petClickThrough === 'boolean'
    ? saved.petClickThrough : Boolean(fallback);
}

function loadState() {
  try {
    const defaults = defaultState();
    const saved = JSON.parse(fs.readFileSync(statePath(), 'utf8'));
    const next = { ...defaults, ...saved, bounds: { ...defaults.bounds, ...(saved.bounds || {}) } };
    next.petClickThrough = petClickThroughPreference(saved, defaults.petClickThrough);
    // Retired integration fields are deliberately not carried into this
    // standalone app's runtime or its next saved state.
    for (const key of Object.keys(next)) {
      if (!Object.hasOwn(defaults, key)) delete next[key];
    }
    // One-time adoptions of tuned appearance defaults. v1: full opacity,
    // 60% walk. v2 (2026-07-31):
    // the standing character also defaults to 60%.
    if (Number(saved.appearanceDefaultVersion || 0) < 1) {
      next.petOpacity = 1;
      next.petRoamZoom = 0.6;
    }
    if (Number(saved.appearanceDefaultVersion || 0) < 2) {
      next.petZoom = 0.6;
      next.appearanceDefaultVersion = 2;
    }
    // v3 (2026-08-02): click-through-the-gaps ships ON when no preference
    // exists. `petClickThroughPreference` deliberately preserves an explicit
    // saved false; an update must never silently reverse the user's toggle.
    if (Number(saved.appearanceDefaultVersion || 0) < 3) {
      next.appearanceDefaultVersion = 3;
    }
    // v4 (2026-08-02): whole figure by default. The 'half' view on a new
    // install looked like a bug ("legs are missing") and hid the feet/leg
    // click targets. Still a per-user choice in the View menu afterwards.
    if (Number(saved.appearanceDefaultVersion || 0) < 4) {
      next.petView = 'full';
      next.appearanceDefaultVersion = 4;
    }
    next.petOpacity = Math.max(0, Math.min(1, Number(next.petOpacity) || 0));
    next.petZoom = clampPetZoom(next.petZoom, PET_ZOOM_RANGE);
    next.petRoamZoom = clampPetZoom(next.petRoamZoom, PET_ROAM_ZOOM_RANGE);
    next.petView = PET_VIEWS.has(next.petView) ? next.petView : defaults.petView;
    next.petRoam = Boolean(next.petRoam);
    next.petHomeBounds = next.petHomeBounds && typeof next.petHomeBounds === 'object'
      ? next.petHomeBounds : null;
    return next;
  } catch {
    return defaultState();
  }
}

function saveStateSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    if (!state.petRoam) state.bounds = mainWindow.getBounds();
    fs.mkdirSync(path.dirname(statePath()), { recursive: true });
    fs.writeFileSync(statePath(), JSON.stringify(state, null, 2), { mode: 0o600 });
  }, 180);
}

function visibleBounds(bounds) {
  if (!bounds || !Number.isFinite(bounds.x) || !Number.isFinite(bounds.y)) return bounds;
  const display = screen.getDisplayMatching(bounds);
  const area = display.workArea;
  const intersects = bounds.x < area.x + area.width
    && bounds.x + bounds.width > area.x
    && bounds.y < area.y + area.height
    && bounds.y + bounds.height > area.y;
  return intersects ? bounds : { width: bounds.width, height: bounds.height };
}

function shellState() {
  let onBattery = false;
  try { onBattery = powerMonitor.isOnBattery(); } catch {}
  return {
    onBattery,
    alwaysOnTop: Boolean(state && state.alwaysOnTop),
    backendOwned: ownsBackend,
    backendUrl: baseUrl(),
    packaged: app.isPackaged,
    pet: {
      enabled: Boolean(state && state.petMode),
      opacity: Number(state && state.petOpacity),
      view: (state && state.petView) || 'half',
      zoom: Number(state && state.petZoom) || 1,
      roamZoom: Number(state && state.petRoamZoom) || 1,
      clickThrough: Boolean(state && state.petClickThrough),
      locked: Boolean(state && state.petLocked),
      roam: Boolean(state && state.petRoam),
      motionReady: petMotionReady,
      motionProfile: { ...petMotionProfile },
    },
  };
}

function broadcastState() {
  const value = shellState();
  for (const window of [mainWindow, settingsWindow, appearanceWindow]) {
    post(window, 'openclam:state', value);
  }
  // The second on-desk avatar sees the same state with its own roam,
  // opacity, and motion profile spliced in.
  pushBuddyState();
  buildTrayMenu();
}

// The appearance panel has to track a live pinch without paying for a tray
// rebuild on every frame, so it gets its own cheap, throttled push.
function pushAppearanceState(force = false) {
  if (!appearanceWindow || appearanceWindow.isDestroyed()) return;
  const now = Date.now();
  if (!force && now - appearancePushAt < 70) return;
  appearancePushAt = now;
  post(appearanceWindow, 'openclam:state', shellState());
}

function settingsIsVisible() {
  return Boolean(settingsWindow && !settingsWindow.isDestroyed()
    && settingsWindow.isVisible() && !settingsWindow.isMinimized());
}

function applyPetWindowLevel(window, roaming, settingsVisible = settingsIsVisible()) {
  if (!window || window.isDestroyed()) return;
  const alwaysOnTop = effectivePetAlwaysOnTop({
    settingsVisible,
    userAlwaysOnTop: state && state.alwaysOnTop,
    roaming,
  });
  window.setAlwaysOnTop(alwaysOnTop, 'floating');
  window.setVisibleOnAllWorkspaces(alwaysOnTop, { visibleOnFullScreen: true });
}

function syncPetWindowLevels(settingsVisible = settingsIsVisible()) {
  applyPetWindowLevel(mainWindow, state && state.petRoam, settingsVisible);
  applyPetWindowLevel(buddyWindow, buddyRoam, settingsVisible);
}

function protectSettingsFromPetOverlay() {
  if (!settingsIsVisible()) return;
  syncPetWindowLevels(true);
  // Keep Settings above an inactive pet without making it globally floating.
  // If a pet is the focused window, however, that focus came from an explicit
  // interaction (notably a click in its chat composer). Re-focusing Settings
  // here would leave the textarea with a DOM caret but send every keystroke to
  // Settings. Only raise Settings while it is already the key window.
  const focused = BrowserWindow.getFocusedWindow();
  if (focused !== settingsWindow) return;
  settingsWindow.moveTop();
}

function applyAlwaysOnTop(value) {
  state.alwaysOnTop = Boolean(value);
  syncPetWindowLevels();
  saveStateSoon();
  broadcastState();
  return shellState();
}

function setPetHit(interactive, reason = 'renderer') {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const value = Boolean(interactive);
  if (petPointerInteractive === value) return;
  petPointerInteractive = value;
  if (process.env.OPENCLAM_DEBUG_HIT) {
    console.error(`[pet-hit] interactive=${value} reason=${reason}`);
  }
  const ignore = state.petClickThrough && !value;
  mainWindow.setIgnoreMouseEvents(ignore, { forward: true });
}

function stopPetPointerTracking() {
  if (petPointerTimer) clearInterval(petPointerTimer);
  petPointerTimer = null;
  petPointerInteractive = null;
}

function startPetPointerTracking() {
  stopPetPointerTracking();
  // One timer feeds every pet window (the main avatar and, when present, the
  // second on-desk avatar): each gets cursor coordinates in its own local
  // space and manages its own hit-testing/click-through flag.
  petPointerTimer = setInterval(() => {
    const point = screen.getCursorScreenPoint();
    for (const target of [
      { key: 'pet', window: () => mainWindow, setHit: setPetHit,
        rects: () => petControlRects, dragging: () => petDrag },
      { key: 'buddy', window: () => buddyWindow, setHit: setBuddyHit,
        rects: () => buddyControlRects, dragging: () => buddyDrag },
    ]) {
      const window = target.window();
      if (!window || window.isDestroyed() || !window.isVisible()) continue;
      const bounds = window.getBounds();
      const inside = point.x >= bounds.x && point.x < bounds.x + bounds.width
        && point.y >= bounds.y && point.y < bounds.y + bounds.height;
      // Coordinates are sent even outside the window (they go negative or
      // past the edge) so the renderer's gaze can follow the cursor across
      // the desktop; `inside` keeps the hit-testing semantics unchanged.
      const localPoint = {
        x: point.x - bounds.x, y: point.y - bounds.y, inside,
      };
      if (target.key === 'pet' && state.petRoam && petRoamRuntime) {
        petRoamHoverGate = observeRoamPointer(petRoamHoverGate, inside);
      }
      // A stationary cursor sends nothing: 31 IPC messages a second per
      // window for an unmoved point was pure heat (2026-08-01 power
      // audit). Movement or an inside-flip sends immediately; a 250ms
      // heartbeat keeps the renderer's staleness checks honest.
      const previous = pointerLastSent[target.key];
      const sendNow = !previous
        || Math.abs(localPoint.x - previous.x) >= 1
        || Math.abs(localPoint.y - previous.y) >= 1
        || localPoint.inside !== previous.inside
        || Date.now() - previous.at > 250;
      if (sendNow) pointerLastSent[target.key] = { ...localPoint, at: Date.now() };
      if (!state.petClickThrough) {
        // The window is always interactive, but the gaze still needs the
        // cursor, so the feed keeps flowing in this branch too.
        target.setHit(true, 'click-through-off');
        if (sendNow) post(window, 'openclam:pet-pointer', localPoint);
        continue;
      }
      if (sendNow) post(window, 'openclam:pet-pointer', localPoint);
      // A drag in flight owns the window. The cursor legitimately outruns
      // the moving bounds, and forcing click-through in that gap lost the
      // mouseup that would have ended the drag - the renderer's pointer
      // feed then stayed frozen behind its dragging guard and the window
      // went permanently deaf to clicks (hover kept working via forwarded
      // moves, which is exactly the confusing symptom).
      if (target.dragging()) { target.setHit(true, 'drag-pinned'); continue; }
      // The chat controls are claimed HERE, from the same 32ms poll that
      // already knows the cursor and the bounds. This path has no renderer
      // dependency, so a paused rAF or a stuck flag can no longer leave
      // the call control or the input field passing clicks to the desktop.
      const rects = target.rects();
      const overControls = inside && rects.some((r) =>
        localPoint.x >= r.x && localPoint.x <= r.x + r.w
        && localPoint.y >= r.y && localPoint.y <= r.y + r.h);
      if (overControls) { target.setHit(true, 'controls'); continue; }
      if (!inside) target.setHit(false, 'outside-window');
    }
  }, 32);
  petPointerTimer.unref?.();
}

function applyPetOpacity(value, reveal = true) {
  const opacity = Math.max(0, Math.min(1, Number(value) || 0));
  state.petOpacity = opacity;
  if (mainWindow && !mainWindow.isDestroyed()) {
    if (opacity <= 0.001) mainWindow.hide();
    else {
      mainWindow.setOpacity(opacity);
      if (reveal) mainWindow.showInactive();
    }
  }
  // Until the second avatar takes its own opacity (a chest/foot double-tap
  // on its window), it follows the primary's.
  if (buddyOpacity === null && buddyWindow && !buddyWindow.isDestroyed()) {
    if (opacity <= 0.001) buddyWindow.hide();
    else {
      buddyWindow.setOpacity(opacity);
      if (reveal) buddyWindow.showInactive();
    }
  }
  saveStateSoon();
  broadcastState();
  return shellState();
}

function applyPetView(value) {
  if (!PET_VIEWS.has(value)) return shellState();
  state.petView = value;
  saveStateSoon();
  broadcastState();
  return shellState();
}

function petBoundsForZoom(value) {
  if (!mainWindow || mainWindow.isDestroyed()) return null;
  const zoom = Math.max(PET_ZOOM_RANGE.min,
    Math.min(PET_ZOOM_RANGE.max, Number(value) || 1));
  const current = mainWindow.getBounds();
  return boundsForPetZoom(
    current, PET_BASE_SIZE, PET_NORMAL_MINIMUM, zoom);
}

function applyPetZoom(value) {
  petZoomGesture = null;
  state.petZoom = clampPetZoom(value, PET_ZOOM_RANGE);
  if (!state.petRoam) {
    const bounds = petBoundsForZoom(state.petZoom);
    if (bounds) {
      mainWindow.setBounds(bounds, false);
      state.bounds = { ...bounds };
    }
  }
  saveStateSoon();
  broadcastState();
  return shellState();
}

function petRoamSize(zoom) {
  const requested = zoom === undefined ? (state && state.petRoamZoom) : zoom;
  return roamSizeForZoom(
    PET_ROAM_SIZE, PET_ROAM_MINIMUM, clampPetZoom(requested, PET_ROAM_ZOOM_RANGE));
}

// The roaming figure - and especially the edge idle held at a screen
// corner - must never leave the screen: at most she fills the work area
// top to bottom, feet above the Dock, crown at the menu bar, width
// scaling with the height (owner rule 2026-08-01: a tall roam zoom pushed
// the head past the screen top because the window is bottom-anchored).
function clampRoamSizeToArea(size, area) {
  if (size.height <= area.height) return size;
  const scale = area.height / size.height;
  return {
    width: Math.max(1, Math.round(size.width * scale)),
    height: Math.round(area.height),
  };
}

function resizePetRoamWindow(zoom) {
  if (!mainWindow || mainWindow.isDestroyed()) return null;
  const area = petRoamDisplay().workArea;
  const size = clampRoamSizeToArea(petRoamSize(zoom), area);
  const bounds = mainWindow.getBounds();
  const centre = bounds.x + bounds.width / 2;
  const rightEdge = area.x + area.width - size.width;
  const x = Math.round(Math.max(area.x, Math.min(rightEdge, centre - size.width / 2)));
  const y = Math.round(area.y + area.height - size.height + 2);
  mainWindow.setMinimumSize(size.width, size.height);
  mainWindow.setBounds({ x, y, width: size.width, height: size.height }, false);
  if (petRoamRuntime) petRoamRuntime.x = x;
  return size;
}

function applyPetRoamZoom(value) {
  state.petRoamZoom = clampPetZoom(value, PET_ROAM_ZOOM_RANGE);
  if (state.petRoam) resizePetRoamWindow(state.petRoamZoom);
  saveStateSoon();
  broadcastState();
  return shellState();
}

// Pinch feedback: resize on every frame the renderer sends, persist and
// broadcast once the gesture ends. Roaming pinches retune the animation box.
function applyPetZoomLive(payload) {
  if (!mainWindow || mainWindow.isDestroyed()) return shellState();
  const data = payload && typeof payload === 'object' ? payload : { value: payload };
  const phase = data.phase === 'start' || data.phase === 'end' ? data.phase : 'move';
  if (state.petRoam) {
    state.petRoamZoom = clampPetZoom(data.value, PET_ROAM_ZOOM_RANGE);
    resizePetRoamWindow(state.petRoamZoom);
  } else {
    if (phase === 'start' || !petZoomGesture) {
      petZoomGesture = { anchor: petZoomAnchor(mainWindow.getBounds()) };
    }
    state.petZoom = clampPetZoom(data.value, PET_ZOOM_RANGE);
    const bounds = boundsForPetZoomAtAnchor(
      petZoomGesture.anchor, PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom);
    mainWindow.setBounds(bounds, false);
    state.bounds = { ...bounds };
  }
  if (phase !== 'end') {
    pushAppearanceState();
    return shellState();
  }
  petZoomGesture = null;
  saveStateSoon();
  broadcastState();
  return shellState();
}

function applyPetClickThrough(value) {
  state.petClickThrough = Boolean(value);
  setPetHit(!state.petClickThrough);
  saveStateSoon();
  broadcastState();
  return shellState();
}

function applyPetLock(value) {
  state.petLocked = Boolean(value);
  petDrag = null;
  saveStateSoon();
  broadcastState();
  return shellState();
}

function petRoamDisplay() {
  if (petRoamRuntime) {
    const active = screen.getAllDisplays().find(
      (display) => display.id === petRoamRuntime.displayId);
    if (active) return active;
  }
  const home = state.petHomeBounds || state.bounds;
  if (home && Number.isFinite(home.x) && Number.isFinite(home.y)) {
    return screen.getDisplayMatching(home);
  }
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
}

function roamMotionState(runtime) {
  const mode = String(runtime && runtime.mode || 'idle');
  // `stand` is the interaction pause, not a visual clip. Preserve the clip
  // that was visible when the pause began so a ledge hover keeps Edge Idle
  // anchored to that edge while a walking hover holds its Walk frame.
  const presentationMode = mode === 'stand'
    ? String(runtime && runtime.resumeMode || 'walk') : mode;
  return {
    enabled: true,
    mode,
    presentationMode,
    direction: Number(runtime && runtime.direction) || 1,
    phase: (Number(runtime && runtime.stride) || 0) % 1,
    edge: presentationMode.startsWith('ledge-')
      ? presentationMode.slice('ledge-'.length) : null,
  };
}

function sendPetRoamMotion(payload = null) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const value = payload || (petRoamRuntime ? roamMotionState(petRoamRuntime)
    : { enabled: false, mode: 'idle', direction: 1, phase: 0, edge: null });
  post(mainWindow, 'openclam:pet-roam-motion', value);
}

function motionTravelAt(profile, phase) {
  const cycleDistance = Number(profile.cycleDistance)
    || Number(profile.walkSpeed) * Number(profile.cycleSeconds);
  const offsets = Array.isArray(profile.travelOffsets) ? profile.travelOffsets : [];
  const wrapped = ((Number(phase) || 0) % 1 + 1) % 1;
  if (offsets.length < 2) return wrapped * cycleDistance;
  const position = wrapped * offsets.length;
  const index = Math.min(offsets.length - 1, Math.floor(position));
  const fraction = position - index;
  const current = offsets[index];
  const next = index + 1 < offsets.length ? offsets[index + 1] : cycleDistance;
  return current + (next - current) * fraction;
}

function motionTravelDelta(profile, previousPhase, nextPhase) {
  const cycleDistance = Number(profile.cycleDistance)
    || Number(profile.walkSpeed) * Number(profile.cycleSeconds);
  const previous = motionTravelAt(profile, previousPhase);
  const next = motionTravelAt(profile, nextPhase);
  return nextPhase >= previousPhase ? next - previous : cycleDistance - previous + next;
}

function tickPetRoam() {
  if (!state.petRoam || !petRoamRuntime || !mainWindow || mainWindow.isDestroyed()) {
    if (petRoamTimer) clearInterval(petRoamTimer);
    petRoamTimer = null;
    return;
  }
  const now = Date.now();
  const elapsed = Math.max(0, Math.min(0.1, (now - petRoamRuntime.lastAt) / 1000));
  petRoamRuntime.lastAt = now;
  const display = petRoamDisplay();
  const area = display.workArea;
  const bounds = mainWindow.getBounds();
  const minimumX = area.x;
  const maximumX = area.x + area.width - bounds.width;
  const dockLineY = Math.round(area.y + area.height - bounds.height + 2);
  let x = Number.isFinite(petRoamRuntime.x) ? petRoamRuntime.x : bounds.x;

  if (petRoamRuntime.mode === 'stand') {
    x = Math.max(minimumX, Math.min(maximumX, x));
    if (!petRoamRuntime.engaged && now >= petRoamRuntime.resumeAt) {
      petRoamRuntime.mode = petRoamRuntime.resumeMode || 'walk';
      if (petRoamRuntime.mode.startsWith('ledge-')) {
        petRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
      }
      petRoamRuntime.resumeMode = 'walk';
    } else {
      petRoamRuntime.x = x;
      mainWindow.setPosition(Math.round(x), dockLineY, false);
      sendPetRoamMotion();
      return;
    }
  }
  if (petRoamRuntime.mode === 'walk') {
    const previousStride = petRoamRuntime.stride;
    petRoamRuntime.stride = (petRoamRuntime.stride
      + elapsed / Math.max(0.1, petRoamRuntime.cycleSeconds)) % 1;
    const travelled = motionTravelDelta(
      petRoamRuntime, previousStride, petRoamRuntime.stride);
    x += petRoamRuntime.direction * travelled;
    if (x >= maximumX) {
      x = maximumX;
      petRoamRuntime.mode = 'ledge-right';
      petRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
    } else if (x <= minimumX) {
      x = minimumX;
      petRoamRuntime.mode = 'ledge-left';
      petRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
    }
  } else if (petRoamRuntime.mode.startsWith('ledge-')) {
    const right = petRoamRuntime.mode === 'ledge-right';
    x = right ? maximumX : minimumX;
    if (now >= petRoamRuntime.holdUntil) {
      petRoamRuntime.direction = right ? -1 : 1;
      petRoamRuntime.mode = 'walk';
    }
  }

  petRoamRuntime.x = x;
  mainWindow.setPosition(Math.round(x), dockLineY, false);
  sendPetRoamMotion();
}

function startPetRoamMotion() {
  if (!state.petRoam || !petMotionReady || !mainWindow || mainWindow.isDestroyed()) return;
  if (petRoamTimer) clearInterval(petRoamTimer);
  petRoamHoverGate = { armed: false, inside: false };
  const display = petRoamDisplay();
  const area = display.workArea;
  const home = state.petHomeBounds || state.bounds || {};
  const size = clampRoamSizeToArea(petRoamSize(), area);
  const maximumX = area.x + area.width - size.width;
  const homeCenter = Number.isFinite(home.x) && Number.isFinite(home.width)
    ? home.x + home.width / 2 : area.x + area.width / 2;
  const startX = Math.round(Math.max(area.x, Math.min(
    maximumX, homeCenter - size.width / 2)));
  const startY = Math.round(area.y + area.height - size.height + 2);
  const direction = startX > area.x + area.width / 2 ? -1 : 1;

  mainWindow.setResizable(false);
  mainWindow.setMinimumSize(size.width, size.height);
  mainWindow.setBounds({
    x: startX,
    y: startY,
    width: size.width,
    height: size.height,
  }, false);
  applyPetWindowLevel(mainWindow, true);
  if (state.petOpacity > 0.001) mainWindow.showInactive();

  petRoamRuntime = {
    displayId: display.id,
    x: startX,
    direction,
    mode: 'walk',
    stride: 0,
    holdUntil: 0,
    engaged: false,
    resumeAt: 0,
    resumeMode: 'walk',
    walkSpeed: petMotionProfile.walkSpeed,
    cycleSeconds: petMotionProfile.cycleSeconds,
    cycleDistance: petMotionProfile.cycleDistance,
    travelOffsets: [...petMotionProfile.travelOffsets],
    lastAt: Date.now(),
  };
  sendPetRoamMotion();
  petRoamTimer = setInterval(tickPetRoam, 32);
  petRoamTimer.unref?.();
}

function stopPetRoamMotion(restore = true) {
  if (petRoamTimer) clearInterval(petRoamTimer);
  petRoamTimer = null;
  petRoamRuntime = null;
  petRoamHoverGate = { armed: false, inside: false };
  sendPetRoamMotion({ enabled: false, mode: 'idle', direction: 1, phase: 0, edge: null });
  if (!mainWindow || mainWindow.isDestroyed()) return;

  mainWindow.setResizable(true);
  mainWindow.setMinimumSize(PET_NORMAL_MINIMUM.width, PET_NORMAL_MINIMUM.height);
  if (restore) {
    const remembered = visibleBounds(state.petHomeBounds || state.bounds) || {};
    const width = Math.max(PET_NORMAL_MINIMUM.width, Number(remembered.width) || 560);
    const height = Math.max(PET_NORMAL_MINIMUM.height, Number(remembered.height) || 760);
    let x = Number(remembered.x);
    let y = Number(remembered.y);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
      x = area.x + area.width - width - 28;
      y = area.y + area.height - height - 28;
    }
    mainWindow.setBounds({ x: Math.round(x), y: Math.round(y), width, height }, false);
    state.bounds = mainWindow.getBounds();
  }
  applyPetWindowLevel(mainWindow, false);
  if (restore) applyPetZoom(state.petZoom);
}

function normalizeMotionProfile(value, current) {
  const payload = value && typeof value === 'object' ? value : { ready: Boolean(value) };
  const ready = Boolean(payload.ready);
  const requestedSpeed = Number(payload.walkSpeed);
  const requestedCycle = Number(payload.cycleSeconds);
  const walkSpeed = Number.isFinite(requestedSpeed)
    ? Math.max(PET_ROAM_MIN_SPEED, Math.min(PET_ROAM_MAX_SPEED, requestedSpeed))
    : current.walkSpeed;
  const cycleSeconds = Number.isFinite(requestedCycle)
    ? Math.max(0.5, Math.min(2.5, requestedCycle))
    : current.cycleSeconds;
  const requestedDistance = Number(payload.cycleDistance);
  const cycleDistance = Number.isFinite(requestedDistance)
    ? Math.max(10, Math.min(PET_ROAM_MAX_SPEED * 2.5, requestedDistance))
    : walkSpeed * cycleSeconds;
  const requestedOffsets = Array.isArray(payload.travelOffsets)
    ? payload.travelOffsets.map(Number).filter(Number.isFinite).slice(0, 96) : [];
  const travelOffsets = requestedOffsets.length >= 2
    ? requestedOffsets.reduce((values, value) => {
      values.push(Math.max(values.at(-1) || 0, Math.min(cycleDistance, value)));
      return values;
    }, []) : [];
  const profile = { walkSpeed, cycleSeconds, cycleDistance, travelOffsets };
  const changed = Math.abs(profile.walkSpeed - current.walkSpeed) > 0.01
    || Math.abs(profile.cycleSeconds - current.cycleSeconds) > 0.001
    || Math.abs(profile.cycleDistance - current.cycleDistance) > 0.01
    || JSON.stringify(profile.travelOffsets) !== JSON.stringify(current.travelOffsets);
  return { ready, profile, changed };
}

function setPetMotionReady(value) {
  const { ready, profile: nextProfile, changed: profileChanged } =
    normalizeMotionProfile(value, petMotionProfile);
  petMotionProfile = nextProfile;
  if (petRoamRuntime) {
    petRoamRuntime.walkSpeed = nextProfile.walkSpeed;
    petRoamRuntime.cycleSeconds = nextProfile.cycleSeconds;
    petRoamRuntime.cycleDistance = nextProfile.cycleDistance;
    petRoamRuntime.travelOffsets = [...nextProfile.travelOffsets];
  }
  if (petMotionReady === ready && !profileChanged) return shellState();
  petMotionReady = ready;
  if (!ready && state.petRoam) {
    state.petRoam = false;
    stopPetRoamMotion(true);
    state.petHomeBounds = null;
    saveStateSoon();
  } else if (ready && state.petRoam) {
    startPetRoamMotion();
  }
  broadcastState();
  return shellState();
}

function setPetEngaged(value) {
  if (!state.petRoam || !petRoamRuntime || !mainWindow || mainWindow.isDestroyed()) return;
  const engaged = Boolean(value);
  if (!roamHoverCanEngage(engaged, petRoamHoverGate)) return;
  if (petRoamRuntime.engaged === engaged) return;
  petRoamRuntime.engaged = engaged;
  if (engaged) {
    if (petRoamRuntime.mode !== 'stand') {
      petRoamRuntime.resumeMode = petRoamRuntime.mode.startsWith('ledge-')
        ? petRoamRuntime.mode : 'walk';
      if (petRoamRuntime.mode === 'ledge-right') petRoamRuntime.direction = -1;
      if (petRoamRuntime.mode === 'ledge-left') petRoamRuntime.direction = 1;
    }
    petRoamRuntime.mode = 'stand';
    petRoamRuntime.resumeAt = Number.POSITIVE_INFINITY;
    const area = petRoamDisplay().workArea;
    const bounds = mainWindow.getBounds();
    const x = Math.max(area.x, Math.min(area.x + area.width - bounds.width, bounds.x));
    petRoamRuntime.x = x;
    mainWindow.setPosition(Math.round(x),
      Math.round(area.y + area.height - bounds.height + 2), false);
  } else {
    petRoamRuntime.resumeAt = Date.now() + PET_INTERACTION_COOLDOWN_MS;
  }
  sendPetRoamMotion();
}

function applyPetRoam(value) {
  const enabled = Boolean(value);
  if (enabled && !petMotionReady) return shellState();
  if (enabled) {
    const home = mainWindow && !mainWindow.isDestroyed()
      ? mainWindow.getBounds() : state.bounds;
    if (!state.petRoam || !state.petHomeBounds) {
      state.bounds = { ...home };
      state.petHomeBounds = { ...home };
    }
    state.petRoam = true;
    if (!mainWindow || mainWindow.isDestroyed()) createMainWindow();
    startPetRoamMotion();
  } else {
    state.petRoam = false;
    stopPetRoamMotion(true);
    state.petHomeBounds = null;
  }
  petDrag = null;
  saveStateSoon();
  broadcastState();
  return shellState();
}

// ---------------------------------------------------------------- buddy
// The second on-desk avatar. Same page, same gestures, its own window: it
// docks and idles against the LEFT screen edge, mirroring the active
// avatar's right corner, and runs its own roam engine so both can walk the
// desktop independently.

function isBuddySender(event) {
  return Boolean(buddyWindow && !buddyWindow.isDestroyed()
    && event.sender === buddyWindow.webContents);
}

function buddyOpacityValue() {
  return buddyOpacity === null ? state.petOpacity : buddyOpacity;
}

function buddyShellState() {
  const value = shellState();
  value.pet = {
    ...value.pet,
    opacity: buddyOpacityValue(),
    roam: buddyRoam,
    motionReady: buddyMotionReady,
    motionProfile: { ...buddyMotionProfile },
  };
  return value;
}

function pushBuddyState() {
  if (!buddyWindow || buddyWindow.isDestroyed()) return;
  post(buddyWindow, 'openclam:state', buddyShellState());
}

function setBuddyHit(interactive) {
  if (!buddyWindow || buddyWindow.isDestroyed()) return;
  const value = Boolean(interactive);
  if (buddyPointerInteractive === value) return;
  buddyPointerInteractive = value;
  buddyWindow.setIgnoreMouseEvents(state.petClickThrough && !value, { forward: true });
}

function buddyStartupBounds() {
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const zoom = clampPetZoom(
    fitPetZoomToArea(
      PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom, area, PET_DOCK_MARGIN),
    PET_ZOOM_RANGE);
  const size = petZoomSize(PET_BASE_SIZE, PET_NORMAL_MINIMUM, zoom);
  return dockedPetBounds(size, area, PET_DOCK_MARGIN, 'left');
}

function dockBuddy() {
  // Mirrors the main pet's stillness dock: flush against the LEFT work-area
  // edge, feet just above the Dock, so the idle lean rests on a real edge.
  if (!buddyWindow || buddyWindow.isDestroyed() || buddyRoam || state.petLocked) return;
  const area = screen.getDisplayMatching(buddyWindow.getBounds()).workArea;
  const size = petZoomSize(PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom);
  buddyWindow.setBounds(dockedPetBounds(size, area, 0, 'left'), false);
}

function buddyRoamDisplay() {
  if (buddyRoamRuntime) {
    const active = screen.getAllDisplays().find(
      (display) => display.id === buddyRoamRuntime.displayId);
    if (active) return active;
  }
  if (buddyWindow && !buddyWindow.isDestroyed()) {
    return screen.getDisplayMatching(buddyWindow.getBounds());
  }
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
}

function sendBuddyRoamMotion(payload = null) {
  if (!buddyWindow || buddyWindow.isDestroyed()) return;
  const value = payload || (buddyRoamRuntime ? roamMotionState(buddyRoamRuntime)
    : { enabled: false, mode: 'idle', direction: 1, phase: 0, edge: null });
  post(buddyWindow, 'openclam:pet-roam-motion', value);
}

function tickBuddyRoam() {
  if (!buddyRoam || !buddyRoamRuntime || !buddyWindow || buddyWindow.isDestroyed()) {
    if (buddyRoamTimer) clearInterval(buddyRoamTimer);
    buddyRoamTimer = null;
    return;
  }
  const now = Date.now();
  const elapsed = Math.max(0, Math.min(0.1, (now - buddyRoamRuntime.lastAt) / 1000));
  buddyRoamRuntime.lastAt = now;
  const area = buddyRoamDisplay().workArea;
  const bounds = buddyWindow.getBounds();
  const minimumX = area.x;
  const maximumX = area.x + area.width - bounds.width;
  const dockLineY = Math.round(area.y + area.height - bounds.height + 2);
  let x = Number.isFinite(buddyRoamRuntime.x) ? buddyRoamRuntime.x : bounds.x;

  if (buddyRoamRuntime.mode === 'stand') {
    x = Math.max(minimumX, Math.min(maximumX, x));
    if (!buddyRoamRuntime.engaged && now >= buddyRoamRuntime.resumeAt) {
      buddyRoamRuntime.mode = buddyRoamRuntime.resumeMode || 'walk';
      if (buddyRoamRuntime.mode.startsWith('ledge-')) {
        buddyRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
      }
      buddyRoamRuntime.resumeMode = 'walk';
    } else {
      buddyRoamRuntime.x = x;
      buddyWindow.setPosition(Math.round(x), dockLineY, false);
      sendBuddyRoamMotion();
      return;
    }
  }
  if (buddyRoamRuntime.mode === 'walk') {
    const previousStride = buddyRoamRuntime.stride;
    buddyRoamRuntime.stride = (buddyRoamRuntime.stride
      + elapsed / Math.max(0.1, buddyRoamRuntime.cycleSeconds)) % 1;
    const travelled = motionTravelDelta(
      buddyRoamRuntime, previousStride, buddyRoamRuntime.stride);
    x += buddyRoamRuntime.direction * travelled;
    if (x >= maximumX) {
      x = maximumX;
      buddyRoamRuntime.mode = 'ledge-right';
      buddyRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
    } else if (x <= minimumX) {
      x = minimumX;
      buddyRoamRuntime.mode = 'ledge-left';
      buddyRoamRuntime.holdUntil = now + PET_LEDGE_HOLD_MS;
    }
  } else if (buddyRoamRuntime.mode.startsWith('ledge-')) {
    const right = buddyRoamRuntime.mode === 'ledge-right';
    x = right ? maximumX : minimumX;
    if (now >= buddyRoamRuntime.holdUntil) {
      buddyRoamRuntime.direction = right ? -1 : 1;
      buddyRoamRuntime.mode = 'walk';
    }
  }

  buddyRoamRuntime.x = x;
  buddyWindow.setPosition(Math.round(x), dockLineY, false);
  sendBuddyRoamMotion();
}

function startBuddyRoamMotion() {
  if (!buddyRoam || !buddyMotionReady || !buddyWindow || buddyWindow.isDestroyed()) return;
  if (buddyRoamTimer) clearInterval(buddyRoamTimer);
  const display = buddyRoamDisplay();
  const area = display.workArea;
  const home = buddyWindow.getBounds();
  const size = clampRoamSizeToArea(petRoamSize(), area);
  const maximumX = area.x + area.width - size.width;
  const homeCenter = Number.isFinite(home.x) && Number.isFinite(home.width)
    ? home.x + home.width / 2 : area.x + area.width / 2;
  const startX = Math.round(Math.max(area.x, Math.min(
    maximumX, homeCenter - size.width / 2)));
  const startY = Math.round(area.y + area.height - size.height + 2);
  const direction = startX > area.x + area.width / 2 ? -1 : 1;

  buddyWindow.setResizable(false);
  buddyWindow.setMinimumSize(size.width, size.height);
  buddyWindow.setBounds({
    x: startX,
    y: startY,
    width: size.width,
    height: size.height,
  }, false);
  applyPetWindowLevel(buddyWindow, true);
  if (buddyOpacityValue() > 0.001) buddyWindow.showInactive();

  buddyRoamRuntime = {
    displayId: display.id,
    x: startX,
    direction,
    mode: 'walk',
    stride: 0,
    holdUntil: 0,
    engaged: false,
    resumeAt: 0,
    resumeMode: 'walk',
    walkSpeed: buddyMotionProfile.walkSpeed,
    cycleSeconds: buddyMotionProfile.cycleSeconds,
    cycleDistance: buddyMotionProfile.cycleDistance,
    travelOffsets: [...buddyMotionProfile.travelOffsets],
    lastAt: Date.now(),
  };
  sendBuddyRoamMotion();
  buddyRoamTimer = setInterval(tickBuddyRoam, 32);
  buddyRoamTimer.unref?.();
}

function stopBuddyRoamMotion(restore = true) {
  if (buddyRoamTimer) clearInterval(buddyRoamTimer);
  buddyRoamTimer = null;
  buddyRoamRuntime = null;
  sendBuddyRoamMotion({ enabled: false, mode: 'idle', direction: 1, phase: 0, edge: null });
  if (!buddyWindow || buddyWindow.isDestroyed()) return;
  buddyWindow.setResizable(true);
  buddyWindow.setMinimumSize(PET_NORMAL_MINIMUM.width, PET_NORMAL_MINIMUM.height);
  if (restore) buddyWindow.setBounds(buddyStartupBounds(), false);
  applyPetWindowLevel(buddyWindow, false);
}

function applyBuddyRoam(value) {
  const enabled = Boolean(value);
  if (enabled && !buddyMotionReady) return buddyShellState();
  buddyRoam = enabled;
  if (enabled) startBuddyRoamMotion();
  else stopBuddyRoamMotion(true);
  buddyDrag = null;
  pushBuddyState();
  return buddyShellState();
}

function setBuddyEngaged(value) {
  if (!buddyRoam || !buddyRoamRuntime || !buddyWindow || buddyWindow.isDestroyed()) return;
  const engaged = Boolean(value);
  if (buddyRoamRuntime.engaged === engaged) return;
  buddyRoamRuntime.engaged = engaged;
  if (engaged) {
    if (buddyRoamRuntime.mode !== 'stand') {
      buddyRoamRuntime.resumeMode = buddyRoamRuntime.mode.startsWith('ledge-')
        ? buddyRoamRuntime.mode : 'walk';
      if (buddyRoamRuntime.mode === 'ledge-right') buddyRoamRuntime.direction = -1;
      if (buddyRoamRuntime.mode === 'ledge-left') buddyRoamRuntime.direction = 1;
    }
    buddyRoamRuntime.mode = 'stand';
    buddyRoamRuntime.resumeAt = Number.POSITIVE_INFINITY;
    const area = buddyRoamDisplay().workArea;
    const bounds = buddyWindow.getBounds();
    const x = Math.max(area.x, Math.min(area.x + area.width - bounds.width, bounds.x));
    buddyRoamRuntime.x = x;
    buddyWindow.setPosition(Math.round(x),
      Math.round(area.y + area.height - bounds.height + 2), false);
  } else {
    buddyRoamRuntime.resumeAt = Date.now() + PET_INTERACTION_COOLDOWN_MS;
  }
  sendBuddyRoamMotion();
}

function setBuddyMotionReady(value) {
  const { ready, profile, changed } = normalizeMotionProfile(value, buddyMotionProfile);
  buddyMotionProfile = profile;
  if (buddyRoamRuntime) {
    buddyRoamRuntime.walkSpeed = profile.walkSpeed;
    buddyRoamRuntime.cycleSeconds = profile.cycleSeconds;
    buddyRoamRuntime.cycleDistance = profile.cycleDistance;
    buddyRoamRuntime.travelOffsets = [...profile.travelOffsets];
  }
  if (buddyMotionReady === ready && !changed) return;
  buddyMotionReady = ready;
  if (!ready && buddyRoam) {
    buddyRoam = false;
    stopBuddyRoamMotion(true);
  } else if (ready && buddyRoam) {
    startBuddyRoamMotion();
  }
  pushBuddyState();
}

function applyBuddyOpacity(value) {
  buddyOpacity = Math.max(0, Math.min(1, Number(value) || 0));
  if (buddyWindow && !buddyWindow.isDestroyed()) {
    if (buddyOpacity <= 0.001) buddyWindow.hide();
    else {
      buddyWindow.setOpacity(buddyOpacity);
      buddyWindow.showInactive();
    }
  }
  pushBuddyState();
  return buddyShellState();
}

async function removeBuddyFromDesk() {
  try {
    await fetch(`${baseUrl()}/api/avatar/companion`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', [AUTH_HEADER]: backendToken },
      body: JSON.stringify({ slug: '' }),
    });
  } catch {
    // The window closes regardless; the server re-syncs on the next launch.
  }
  closeBuddyWindow();
}

function showBuddyMenu() {
  if (!buddyWindow || buddyWindow.isDestroyed()) return;
  showMenuWindow([
    { name: 'Second avatar', hint: buddySlug || '', enabled: false },
    { type: 'separator' },
    { name: 'Talk', hint: 'hold head', enabled: false },
    { name: 'Walk', hint: '2×tap leg', enabled: false },
    { name: 'Opacity +', hint: '2×tap chest', enabled: false },
    { name: 'Opacity −', hint: '2×tap foot', enabled: false },
    { type: 'separator' },
    {
      name: buddyRoam ? 'Return to standing' : 'Start walking',
      enabled: buddyMotionReady || buddyRoam,
      click: () => applyBuddyRoam(!buddyRoam),
    },
    { name: 'Moves', hint: '2×tap hair', click: () => {
      if (buddyWindow && !buddyWindow.isDestroyed()) {
        post(buddyWindow, 'openclam:pet-moves');
      }
    } },
    { type: 'separator' },
    { name: 'Remove from desk', click: () => { removeBuddyFromDesk(); } },
  ]);
}

function createBuddyWindow(slug) {
  if (buddyWindow && !buddyWindow.isDestroyed()) {
    if (buddySlug === slug) {
      buddyWindow.webContents.reloadIgnoringCache();
      return;
    }
    closeBuddyWindow();
  }
  buddySlug = slug;
  buddyRoam = false;
  buddyMotionReady = false;
  buddyDrag = null;
  buddyPointerInteractive = null;
  buddyWindow = new BrowserWindow({
    ...buddyStartupBounds(),
    minWidth: PET_NORMAL_MINIMUM.width,
    minHeight: PET_NORMAL_MINIMUM.height,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    roundedCorners: false,
    hasShadow: false,
    resizable: true,
    enableLargerThanScreen: true,
    fullscreenable: false,
    skipTaskbar: true,
    acceptFirstMouse: true,
    title: APP_NAME,
    webPreferences: {
      backgroundThrottling: false,
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  buddyWindow.setOpacity(buddyOpacityValue() > 0 ? buddyOpacityValue() : 0.5);
  setBuddyHit(false);
  applyPetWindowLevel(buddyWindow, buddyRoam);
  guardNavigation(buddyWindow, 'buddy');
  buddyWindow.loadURL(`${baseUrl()}/c/${slug}/?electron=1&companion=1&side=left`
    + `&app=${encodeURIComponent(app.getVersion())}`);
  buddyWindow.once('ready-to-show', () => {
    if (buddyOpacityValue() > 0.001) buddyWindow.showInactive();
  });
  buddyWindow.on('show', protectSettingsFromPetOverlay);
  buddyWindow.on('focus', protectSettingsFromPetOverlay);
  buddyWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      buddyWindow.hide();
    }
  });
  buddyWindow.on('closed', () => {
    if (buddyRoamTimer) clearInterval(buddyRoamTimer);
    buddyRoamTimer = null;
    buddyRoamRuntime = null;
    buddyWindow = null;
    buddySlug = null;
    buddyRoam = false;
    buddyMotionReady = false;
  });
}

function closeBuddyWindow() {
  stopBuddyRoamMotion(false);
  if (buddyWindow && !buddyWindow.isDestroyed()) buddyWindow.destroy();
  buddyWindow = null;
  buddySlug = null;
  buddyRoam = false;
  buddyMotionReady = false;
  buddyDrag = null;
  buddyPointerInteractive = null;
}

// The server's companion.json decides which avatar sits on the left desk;
// the shell just mirrors it. Called at boot and whenever settings changes it.
async function syncBuddyFromServer() {
  const metadata = await openClamMetadata(3000);
  const slug = metadata ? metadata.companion : buddySlug;
  if (slug) createBuddyWindow(slug);
  else closeBuddyWindow();
  return slug || null;
}

function guardNavigation(window, kind) {
  window.webContents.on('will-navigate', (event, target) => {
    let targetUrl;
    try { targetUrl = new URL(target); } catch { event.preventDefault(); return; }
    if (targetUrl.origin !== baseUrl()) {
      event.preventDefault();
      if (targetUrl.protocol === 'https:') shell.openExternal(target).catch(() => {});
      return;
    }
    if (kind === 'main') {
      if (targetUrl.pathname === '/settings') {
        event.preventDefault();
        openSettings();
      }
      return;
    }
    // Character Studio and the appearance popover are single documents. Any
    // in-place navigation replaces the entire UI with whatever was linked - a
    // stray <a href> to a .mp4 once swapped the studio for a bare video player
    // with no way back. Nothing in these windows may leave its own page.
    if (targetUrl.pathname !== `/${kind}`) event.preventDefault();
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    let targetUrl;
    try { targetUrl = new URL(url); } catch { return { action: 'deny' }; }
    if (targetUrl.protocol === 'https:') shell.openExternal(url).catch(() => {});
    return { action: 'deny' };
  });
  window.webContents.on('before-input-event', (event, input) => {
    if (input.meta && input.key === ',') {
      event.preventDefault();
      openSettings();
    }
  });
}

function speechBubbleDisplay() {
  if (petRoamRuntime) return petRoamDisplay();
  if (mainWindow && !mainWindow.isDestroyed()) return screen.getDisplayMatching(mainWindow.getBounds());
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
}

function positionSpeechBubble() {
  if (!bubbleWindow || bubbleWindow.isDestroyed()) return;
  const area = speechBubbleDisplay().workArea;
  const width = Math.min(820, Math.max(440, area.width - 96));
  // A long reply (a story, a briefing) gets a taller card before it starts
  // scrolling; short spoken lines keep the compact one.
  const tall = (pendingBubble || '').length > 420;
  const height = Math.min(tall ? 440 : 300,
    Math.max(220, Math.round(area.height * (tall ? 0.42 : 0.28))));
  bubbleWindow.setBounds({
    x: Math.round(area.x + (area.width - width) / 2),
    y: Math.round(area.y + (area.height - height) * 0.42),
    width,
    height,
  }, false);
}

function sendPendingBubble() {
  if (!pendingBubble || !bubbleWindow || bubbleWindow.isDestroyed()) return;
  positionSpeechBubble();
  post(bubbleWindow, 'openclam:bubble-text', { text: pendingBubble });
  bubbleWindow.showInactive();
}

/* The pet right-click menu is our own window, not a native Menu: macOS
   reserves a menu's right-hand column for keyboard accelerators, so the
   gesture hints ("2×tap leg") could never right-align there. Each spec item
   is { name, hint, type, checked, enabled, submenu, click }; clicks stay in
   this process, keyed by generated ids. */
let menuWindow = null;
let menuActions = new Map();
let menuDismiss = null;
let menuAnchor = { x: 0, y: 0 };
let menuSequence = 0;

function closeMenuWindow(runDismiss = true) {
  const window = menuWindow;
  menuWindow = null;
  menuActions = new Map();
  const dismiss = menuDismiss;
  menuDismiss = null;
  if (window && !window.isDestroyed()) window.destroy();
  if (runDismiss && typeof dismiss === 'function') dismiss();
}

function showMenuWindow(spec, onDismiss = null) {
  closeMenuWindow(false);
  menuAnchor = screen.getCursorScreenPoint();
  menuDismiss = onDismiss;
  const serialize = (items) => items.filter(Boolean).map((item) => {
    if (item.type === 'separator') return { type: 'separator' };
    const entry = {
      id: '', name: String(item.name || ''), hint: String(item.hint || ''),
      type: item.type || 'normal', checked: Boolean(item.checked),
      enabled: item.enabled !== false, submenu: null,
    };
    if (typeof item.click === 'function') {
      entry.id = `m${++menuSequence}`;
      menuActions.set(entry.id, item.click);
    }
    if (Array.isArray(item.submenu)) entry.submenu = serialize(item.submenu);
    return entry;
  });
  const payload = serialize(spec);
  // Born larger than any menu ever measures, so the first layout is never
  // squeezed by the shell; the real size arrives from the renderer.
  menuWindow = new BrowserWindow({
    x: menuAnchor.x, y: menuAnchor.y, width: 440, height: 720, show: false,
    frame: false, transparent: true, backgroundColor: '#00000000',
    roundedCorners: false, hasShadow: false, resizable: false, movable: false,
    minimizable: false, maximizable: false, fullscreenable: false,
    skipTaskbar: true, acceptFirstMouse: true, alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, 'menu-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  menuWindow.setAlwaysOnTop(true, 'pop-up-menu');
  menuWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  guardNavigation(menuWindow, 'menu');
  menuWindow.loadURL(`${baseUrl()}/menu?electron=1`);
  menuWindow.webContents.once('did-finish-load', () => {
    if (menuWindow && !menuWindow.isDestroyed()) {
      // Chromium persists page zoom PER ORIGIN: a zoomed Settings page (same
      // 127.0.0.1 origin) silently zooms this window too, so the menu renders
      // larger than it measured and the window clips its corners and last
      // row. The menu is never user-zoomable - pin it to 1.
      menuWindow.webContents.setZoomFactor(1);
      menuWindow.webContents.setVisualZoomLevelLimits(1, 1);
      post(menuWindow, 'openclam:menu-spec', payload);
    }
  });
  // Anywhere else takes focus -> the menu is dismissed, like a native one.
  menuWindow.on('blur', () => closeMenuWindow());
}

function createSpeechBubbleWindow() {
  if (bubbleWindow && !bubbleWindow.isDestroyed()) return bubbleWindow;
  bubbleWindow = new BrowserWindow({
    width: 760,
    height: 260,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    roundedCorners: false,
    hasShadow: false,
    resizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    focusable: false,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, 'bubble-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  bubbleWindow.setAlwaysOnTop(true, 'floating');
  bubbleWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // Interactive (but never focusable): long markdown replies scroll, and a
  // wheel can only reach a window that accepts mouse events.
  guardNavigation(bubbleWindow, 'bubble');
  bubbleWindow.loadURL(`${baseUrl()}/bubble?electron=1`);
  bubbleWindow.webContents.once('did-finish-load', sendPendingBubble);
  bubbleWindow.on('closed', () => { bubbleWindow = null; });
  return bubbleWindow;
}

function showSpeechBubble(value) {
  // Newlines survive: the bubble renders markdown, and collapsing every run
  // of whitespace to one space used to flatten lists, fences, and headings
  // into an unparseable single line.
  const text = String(value || '').replace(/\r\n?/g, '\n')
    .replace(/\n{3,}/g, '\n\n').trim().slice(0, 2000);
  clearTimeout(bubbleTimer);
  bubbleTimer = null;
  pendingBubble = text;
  if (!text) {
    if (bubbleWindow && !bubbleWindow.isDestroyed()) bubbleWindow.hide();
    return;
  }
  const window = createSpeechBubbleWindow();
  if (!window.webContents.isLoadingMainFrame()) sendPendingBubble();
  const visibleMs = Math.max(5000, Math.min(18_000, 3500 + text.length * 48));
  bubbleTimer = setTimeout(() => {
    pendingBubble = '';
    if (bubbleWindow && !bubbleWindow.isDestroyed()) bubbleWindow.hide();
  }, visibleMs);
  bubbleTimer.unref?.();
}

function holdSpeechBubble(reading) {
  // The cursor is on the bubble: someone is reading or scrolling, so the
  // auto-hide waits. Leaving grants a short grace, then the card goes.
  clearTimeout(bubbleTimer);
  bubbleTimer = null;
  if (reading) return;
  if (!pendingBubble) {
    if (bubbleWindow && !bubbleWindow.isDestroyed()) bubbleWindow.hide();
    return;
  }
  bubbleTimer = setTimeout(() => {
    pendingBubble = '';
    if (bubbleWindow && !bubbleWindow.isDestroyed()) bubbleWindow.hide();
  }, 4000);
  bubbleTimer.unref?.();
}

function positionAppearanceWindow() {
  if (!appearanceWindow || appearanceWindow.isDestroyed()) return;
  const point = screen.getCursorScreenPoint();
  const area = screen.getDisplayNearestPoint(point).workArea;
  const [width, height] = appearanceWindow.getSize();
  let x = Math.round(point.x - width / 2);
  let y = Math.round(point.y + 18);
  if (y + height > area.y + area.height) y = Math.round(point.y - height - 18);
  x = Math.max(area.x + 8, Math.min(area.x + area.width - width - 8, x));
  y = Math.max(area.y + 8, Math.min(area.y + area.height - height - 8, y));
  appearanceWindow.setPosition(x, y, false);
}

function createAppearanceWindow() {
  if (appearanceWindow && !appearanceWindow.isDestroyed()) return appearanceWindow;
  appearanceWindow = new BrowserWindow({
    width: 390,
    height: 316,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    roundedCorners: true,
    hasShadow: true,
    resizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    title: `${APP_NAME} Appearance`,
    webPreferences: {
      preload: path.join(__dirname, 'appearance-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  appearanceWindow.setAlwaysOnTop(true, 'floating');
  appearanceWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  guardNavigation(appearanceWindow, 'appearance');
  appearanceWindow.loadURL(`${baseUrl()}/appearance?electron=1`);
  appearanceWindow.on('blur', () => appearanceWindow?.hide());
  appearanceWindow.on('closed', () => { appearanceWindow = null; });
  return appearanceWindow;
}

function showAppearanceWindow() {
  const window = createAppearanceWindow();
  positionAppearanceWindow();
  window.show();
  window.focus();
  pushAppearanceState(true);
}

// Every launch starts from the bottom-right corner of the work area, at a
// zoom that fits on screen. A pinch once left the companion larger than the
// display and pinned under the Dock; restoring the saved corner would bring
// that stuck state back, so the saved x/y is deliberately ignored here.
function startupPetBounds() {
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  state.petZoom = clampPetZoom(
    fitPetZoomToArea(
      PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom, area, PET_DOCK_MARGIN),
    PET_ZOOM_RANGE);
  const size = petZoomSize(PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom);
  return dockedPetBounds(size, area, PET_DOCK_MARGIN);
}

function createMainWindow() {
  const bounds = startupPetBounds();
  state.bounds = { ...bounds };
  mainWindow = new BrowserWindow({
    ...bounds,
    minWidth: PET_NORMAL_MINIMUM.width,
    minHeight: PET_NORMAL_MINIMUM.height,
    show: false,
    frame: false,
    transparent: true,
    // Zooming the overlay legitimately grows the window taller than the
    // display (the lower body hangs off-screen); without this macOS
    // silently clamps every resize to the screen and re-frames her.
    enableLargerThanScreen: true,
    backgroundColor: '#00000000',
    roundedCorners: false,
    hasShadow: false,
    resizable: true,
    enableLargerThanScreen: true,
    fullscreenable: false,
    skipTaskbar: true,
    acceptFirstMouse: true,
    title: APP_NAME,
    webPreferences: {
      backgroundThrottling: false,
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  mainWindow.setOpacity(state.petOpacity > 0 ? state.petOpacity : 0.5);
  petPointerInteractive = null;
  setPetHit(false);
  startPetPointerTracking();
  applyAlwaysOnTop(state.alwaysOnTop);
  guardNavigation(mainWindow, 'main');
  mainWindow.loadURL(`${baseUrl()}/?electron=1&app=${encodeURIComponent(app.getVersion())}`);
  mainWindow.once('ready-to-show', () => {
    if (state.petRoam && petMotionReady) startPetRoamMotion();
    else applyPetZoom(state.petZoom);
    // Startup is an ambient reveal, not an interaction. Settings may have
    // opened while the pet renderer was loading, so never make the pet key
    // here; explicit chat clicks activate it through openclam:pet-focus.
    if (state.petOpacity > 0.001) mainWindow.showInactive();
  });
  mainWindow.on('show', protectSettingsFromPetOverlay);
  mainWindow.on('focus', protectSettingsFromPetOverlay);
  mainWindow.on('move', () => { if (!state.petRoam) saveStateSoon(); });
  mainWindow.on('resize', () => { if (!state.petRoam) saveStateSoon(); });
  mainWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
  mainWindow.on('closed', () => {
    stopPetPointerTracking();
    stopPetRoamMotion(false);
    mainWindow = null;
  });
}

function showMain() {
  if (!mainWindow || mainWindow.isDestroyed()) createMainWindow();
  if (settingsWindow && !settingsWindow.isDestroyed()) settingsWindow.hide();
  if (state.petOpacity <= 0.001) {
    state.petOpacity = 0.5;
    saveStateSoon();
  }
  mainWindow.setOpacity(state.petOpacity);
  mainWindow.show();
  mainWindow.focus();
  broadcastState();
}

function recoverCompanion() {
  if (!mainWindow || mainWindow.isDestroyed()) createMainWindow();
  // Reset the zoom before anything re-applies it: keeping the current size
  // once "recovered" a pinch-blown window to a spot still off every edge.
  // Recovery is the safe reset: whole figure, and a zoom that provably
  // fits this display - blind zoom=1 (560x760) overflowed short screens
  // now that enableLargerThanScreen removed the OS clamp.
  state.petView = 'full';
  state.petZoom = 1;
  if (state.petRoam) {
    state.petRoam = false;
    stopPetRoamMotion(true);
    state.petHomeBounds = null;
  }
  state.petOpacity = 0.5;
  state.petClickThrough = false;
  state.petLocked = false;
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const area = display.workArea;
  state.petZoom = clampPetZoom(
    fitPetZoomToArea(
      PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom, area, PET_DOCK_MARGIN),
    PET_ZOOM_RANGE);
  const size = petZoomSize(PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom);
  mainWindow.setBounds(dockedPetBounds(size, area, PET_DOCK_MARGIN));
  state.bounds = mainWindow.getBounds();
  mainWindow.setOpacity(0.5);
  // Through setPetHit so the interactive flag stays honest: a direct
  // setIgnoreMouseEvents here desyncs the dedupe and later claims no-op.
  petPointerInteractive = null;
  setPetHit(true, 'recover');
  mainWindow.show();
  mainWindow.focus();
  saveStateSoon();
  broadcastState();
}

function installRecoveryShortcut() {
  const accelerator = 'CommandOrControl+Shift+0';
  if (!globalShortcut.register(accelerator, () => {
    companionHold = null;
    recoverCompanion();
    applyPetOpacity(1);
  })) {
    writeBackendLog(`[shortcut unavailable] ${accelerator}\n`);
  }
  // Cmd+Shift+9: enlarge to a big (max-zoom) overlay and slide her into
  // the bottom-right corner - head and shoulders on screen, the rest of
  // the FULL body hanging below the display. View is never touched, so
  // nothing is ever cropped (owner, final semantics 2026-08-02). A
  // second press restores the exact prior zoom and bounds.
  const companion = 'CommandOrControl+Shift+9';
  if (!globalShortcut.register(companion, deskCompanionMode)) {
    writeBackendLog(`[shortcut unavailable] ${companion}\n`);
  }
}

let companionHold = null;
function deskCompanionMode() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (companionHold) {
    const hold = companionHold;
    companionHold = null;
    state.petZoom = hold.zoom;
    mainWindow.setBounds(hold.bounds, false);
    state.bounds = { ...hold.bounds };
    saveStateSoon();
    broadcastState();
    return;
  }
  if (state.petRoam) applyPetRoam(false);
  companionHold = { zoom: state.petZoom, bounds: mainWindow.getBounds() };
  applyPetOpacity(1);
  const area = screen.getDisplayMatching(mainWindow.getBounds()).workArea;
  state.petZoom = PET_ZOOM_RANGE.max;
  const size = petZoomSize(PET_BASE_SIZE, PET_NORMAL_MINIMUM, state.petZoom);
  // Matched to the owner's reference: crown ~a third down the screen,
  // face centred ~84% across, hair spilling past the right edge, body
  // running off the bottom.
  const bounds = {
    x: Math.round(area.x + area.width * 0.84 - size.width / 2),
    y: Math.round(area.y + area.height * 0.23),
    width: size.width,
    height: size.height,
  };
  mainWindow.setBounds(bounds, false);
  state.bounds = { ...bounds };
  if (state.petOpacity > 0.001) mainWindow.showInactive();
  saveStateSoon();
  broadcastState();
}

function openSettings() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    syncPetWindowLevels();
    settingsWindow.focus();
    return;
  }
  settingsWindow = new BrowserWindow({
    width: 1080,
    height: 790,
    minWidth: 760,
    minHeight: 620,
    show: false,
    title: `${APP_NAME} Settings`,
    backgroundColor: '#181818',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  guardNavigation(settingsWindow, 'settings');
  settingsWindow.loadURL(`${baseUrl()}/settings?electron=1&app=${encodeURIComponent(app.getVersion())}`);
  settingsWindow.once('ready-to-show', () => {
    settingsWindow.show();
    settingsWindow.focus();
  });
  settingsWindow.on('show', protectSettingsFromPetOverlay);
  settingsWindow.on('hide', () => syncPetWindowLevels(false));
  settingsWindow.on('minimize', () => syncPetWindowLevels(false));
  settingsWindow.on('restore', protectSettingsFromPetOverlay);
  settingsWindow.on('closed', () => {
    cancelAllAvatarStoreJobs();
    settingsWindow = null;
    syncPetWindowLevels();
  });
}

function trayImage() {
  // This monochrome menu-bar mark is derived from the same iOS OpenClam icon
  // as the app bundle, with @2x/@3x siblings for Retina displays.
  const icon = path.join(__dirname, 'tray-icon.png');
  if (fs.existsSync(icon)) {
    const image = nativeImage.createFromPath(icon);
    if (!image.isEmpty()) return image;
  }
  const file = path.join(__dirname, 'trayTemplate.png');
  if (fs.existsSync(file)) {
    const image = nativeImage.createFromPath(file).resize({ width: 18, height: 18 });
    image.setTemplateImage(true);
    return image;
  }
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><path fill="black" d="M9 1.4c-3.25 0-5.9 2.7-5.9 6.05 0 2.15 1.08 4.04 2.72 5.1L4.9 16.6l4.1-2.12 4.1 2.12-.92-4.05a6.1 6.1 0 0 0 2.72-5.1C14.9 4.1 12.25 1.4 9 1.4Zm-2.45 5.7a1.05 1.05 0 1 1 0-2.1 1.05 1.05 0 0 1 0 2.1Zm4.9 0a1.05 1.05 0 1 1 0-2.1 1.05 1.05 0 0 1 0 2.1ZM9 11.8c-1.6 0-2.8-.82-3.25-1.8h6.5c-.45.98-1.65 1.8-3.25 1.8Z"/></svg>';
  const image = nativeImage.createFromDataURL(
    `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`,
  );
  image.setTemplateImage(true);
  return image;
}

function buildTrayMenu() {
  if (!tray) return;
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: mainWindow && mainWindow.isVisible() ? 'Hide Avatar' : 'Show Avatar', click: () => {
      if (mainWindow && mainWindow.isVisible()) mainWindow.hide(); else showMain();
    } },
    { label: 'Settings…', accelerator: 'CommandOrControl+,', click: openSettings },
    { label: 'Size & Opacity…', click: showAppearanceWindow },
    { type: 'separator' },
    { label: 'Always on Top', type: 'checkbox', checked: state.alwaysOnTop,
      click: (item) => applyAlwaysOnTop(item.checked) },
    { label: petMotionReady ? 'Horizon Walk Along Dock' : 'Horizon Walk · Generate Motion First',
      type: 'checkbox', checked: state.petRoam, enabled: petMotionReady,
      click: (item) => applyPetRoam(item.checked) },
    { label: 'Click Through Empty Space', type: 'checkbox', checked: state.petClickThrough,
      click: (item) => applyPetClickThrough(item.checked) },
    { label: 'Lock Position', type: 'checkbox', checked: state.petLocked,
      enabled: !state.petRoam, click: (item) => applyPetLock(item.checked) },
    { label: 'Recover Avatar', accelerator: 'CommandOrControl+Shift+0', click: recoverCompanion },
    { label: 'Restart Voice Engine', enabled: ownsBackend, click: restartBackend },
    { type: 'separator' },
    // Which build am I actually running? A question the owner should
    // never have to guess at (2026-08-05).
    { label: `${APP_NAME} ${app.getVersion()}`, enabled: false },
    { label: 'Check for Updates…', click: () => { void checkForUpdates(true); } },
    { label: `Quit ${APP_NAME}`, accelerator: 'CommandOrControl+Q', click: () => app.quit() },
  ]));
}

function petViewItems() {
  const views = [
    ['Full Body', 'full'],
    ['Three-Quarter', 'three-quarter'],
    ['Half Body', 'half'],
    ['Bust', 'bust'],
    ['Head & Shoulders', 'head'],
    ['Face', 'face'],
  ];
  return views.map(([label, value]) => ({
    name: label,
    type: 'radio',
    checked: state.petView === value,
    click: () => applyPetView(value),
  }));
}

function showPetMenu() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  // Name on the left, the gesture that does the same thing on the right.
  showMenuWindow([
    { name: 'Talk', hint: 'hold head or type',
      click: () => {
        mainWindow.show();
        mainWindow.focus();
        post(mainWindow, 'openclam:pet-chat');
      } },
    { name: liveTalkActive ? 'End live talk' : 'Live talk',
      hint: liveTalkActive ? 'hang up now' : 'realtime voice',
      click: () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
          post(mainWindow, 'openclam:live-toggle');
        }
      } },
    { type: 'separator' },
    { name: state.petRoam ? 'Walking' : 'Walk',
      hint: !petMotionReady ? 'generate first'
        : state.petRoam ? 'hover to stop' : '2×tap leg',
      type: 'checkbox', checked: state.petRoam, enabled: petMotionReady,
      click: () => applyPetRoam(!state.petRoam) },
    { name: 'Moves', hint: '2×tap hair', click: () => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        post(mainWindow, 'openclam:pet-moves');
      }
    } },
    { name: 'React', hint: 'tap arm or chest', enabled: false },
    { name: 'Rest', hint: 'still for 10s', enabled: false },
    { type: 'separator' },
    { name: 'Opacity +', hint: '2×tap chest',
      click: () => applyPetOpacity(Math.min(1, state.petOpacity + 0.12)) },
    { name: 'Opacity −', hint: '2×tap foot',
      click: () => applyPetOpacity(Math.max(0.15, state.petOpacity - 0.12)) },
    { name: 'Size & Opacity…', click: showAppearanceWindow },
    { name: 'View', enabled: !state.petRoam, submenu: petViewItems() },
    { type: 'separator' },
    { name: 'Click-Through Gaps', type: 'checkbox', checked: state.petClickThrough,
      click: () => applyPetClickThrough(!state.petClickThrough) },
    { name: 'Lock Position', type: 'checkbox', checked: state.petLocked,
      enabled: !state.petRoam, click: () => applyPetLock(!state.petLocked) },
    { name: 'Always on Top', type: 'checkbox', checked: state.alwaysOnTop,
      click: () => applyAlwaysOnTop(!state.alwaysOnTop) },
    { type: 'separator' },
    { name: 'Character Studio…', click: openSettings },
    { name: 'Check for Updates…', click: () => { void checkForUpdates(true); } },
    { name: 'Hide Avatar', click: () => mainWindow.hide() },
    { name: `Quit ${APP_NAME}`, click: () => app.quit() },
  ], () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    const point = screen.getCursorScreenPoint();
    const bounds = mainWindow.getBounds();
    post(mainWindow, 'openclam:pet-pointer', {
      x: point.x - bounds.x,
      y: point.y - bounds.y,
      inside: point.x >= bounds.x && point.x < bounds.x + bounds.width
        && point.y >= bounds.y && point.y < bounds.y + bounds.height,
    });
  });
}

function createTray() {
  tray = new Tray(trayImage());
  tray.setToolTip(APP_NAME);
  tray.on('click', () => {
    if (mainWindow && mainWindow.isVisible()) mainWindow.hide(); else showMain();
  });
  buildTrayMenu();
}

async function restartBackend() {
  if (!ownsBackend) {
    await dialog.showMessageBox({
      type: 'info',
      message: `${APP_NAME} is using an engine started outside Electron.`,
      detail: `Restart it from the terminal, or quit that engine and reopen ${APP_NAME}.`,
    });
    return { ok: false, error: 'external backend' };
  }
  stopBackend();
  await sleep(350);
  try {
    await startBackend();
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.loadURL(`${baseUrl()}/?electron=1&app=${encodeURIComponent(app.getVersion())}`);
    }
    if (settingsWindow && !settingsWindow.isDestroyed()) {
      settingsWindow.loadURL(`${baseUrl()}/settings?electron=1&app=${encodeURIComponent(app.getVersion())}`);
    }
    broadcastState();
    return { ok: true };
  } catch (error) {
    dialog.showErrorBox('Voice engine failed to restart', String(error.message || error));
    return { ok: false, error: String(error.message || error) };
  }
}

function installIpc() {
  ipcMain.handle('openclam:get-state', (event) => (
    isBuddySender(event) ? buddyShellState() : shellState()));
  ipcMain.handle('openclam:save-motion-asset', saveMotionAsset);
  ipcMain.handle('openclam:avatar-store-catalog', avatarStoreCatalog);
  ipcMain.handle('openclam:avatar-store-thumbnail', avatarStoreThumbnail);
  ipcMain.handle('openclam:avatar-store-download', downloadAvatarStoreItem);
  ipcMain.handle('openclam:avatar-store-cancel', cancelAvatarStoreItem);
  ipcMain.handle('openclam:open-settings', () => { openSettings(); return shellState(); });
  ipcMain.handle('openclam:open-appearance', () => { showAppearanceWindow(); return shellState(); });
  ipcMain.handle('openclam:show-main', () => { showMain(); return shellState(); });
  ipcMain.handle('openclam:hide-main', () => { if (mainWindow) mainWindow.hide(); });
  ipcMain.handle('openclam:minimize', () => { if (mainWindow) mainWindow.minimize(); });
  ipcMain.handle('openclam:toggle-top', () => applyAlwaysOnTop(!state.alwaysOnTop));
  ipcMain.handle('openclam:pet-menu', (event) => {
    if (isBuddySender(event)) { showBuddyMenu(); return buddyShellState(); }
    showPetMenu();
    return shellState();
  });
  ipcMain.handle('openclam:set-pet-view', (_event, value) => applyPetView(value));
  ipcMain.handle('openclam:set-pet-opacity', (event, value) => (
    isBuddySender(event) ? applyBuddyOpacity(value) : applyPetOpacity(value)));
  // Zoom stays a main-avatar control: the second window shares the primary's
  // sizes so the pair keeps its left/right symmetry.
  ipcMain.handle('openclam:set-pet-zoom', (event, value) => (
    isBuddySender(event) ? buddyShellState() : applyPetZoom(value)));
  ipcMain.handle('openclam:set-pet-roam-zoom', (event, value) => (
    isBuddySender(event) ? buddyShellState() : applyPetRoamZoom(value)));
  ipcMain.on('openclam:pet-zoom-live', (event, payload) => {
    if (mainWindow && event.sender === mainWindow.webContents) applyPetZoomLive(payload);
  });
  ipcMain.handle('openclam:set-pet-click-through', (_event, value) => applyPetClickThrough(value));
  ipcMain.handle('openclam:set-pet-lock', (_event, value) => applyPetLock(value));
  ipcMain.handle('openclam:set-pet-roam', (event, value) => (
    isBuddySender(event) ? applyBuddyRoam(value) : applyPetRoam(value)));
  ipcMain.on('openclam:bubble-hold', (event, value) => {
    if (!bubbleWindow || event.sender !== bubbleWindow.webContents) return;
    holdSpeechBubble(Boolean(value));
  });
  ipcMain.on('openclam:show-speech-bubble', (event, value) => {
    if (isBuddySender(event)
        || (mainWindow && event.sender === mainWindow.webContents)) showSpeechBubble(value);
  });
  ipcMain.on('openclam:pet-motion-ready', (event, value) => {
    if (isBuddySender(event)) setBuddyMotionReady(value);
    else if (mainWindow && event.sender === mainWindow.webContents) setPetMotionReady(value);
  });
  ipcMain.on('openclam:pet-engaged', (event, value) => {
    if (isBuddySender(event)) setBuddyEngaged(value);
    else if (mainWindow && event.sender === mainWindow.webContents) setPetEngaged(value);
  });
  ipcMain.on('openclam:pet-hit', (event, value) => {
    if (isBuddySender(event)) setBuddyHit(Boolean(value));
    else if (mainWindow && event.sender === mainWindow.webContents) setPetHit(Boolean(value), 'renderer-alpha');
  });
  ipcMain.on('openclam:menu-size', (event, size) => {
    if (!menuWindow || menuWindow.isDestroyed()
        || event.sender !== menuWindow.webContents) return;
    // The renderer measures in CSS px; the window is sized in DIPs. With the
    // zoom pinned to 1 these agree, but scale by the live factor anyway so a
    // zoom that sneaks in can never clip the panel again.
    const zoom = menuWindow.webContents.getZoomFactor() || 1;
    const width = Math.max(160,
      Math.min(440, Math.round((Number(size && size.w) || 0) * zoom)));
    const height = Math.max(40,
      Math.min(720, Math.round((Number(size && size.h) || 0) * zoom)));
    const area = screen.getDisplayNearestPoint(menuAnchor).workArea;
    let x = menuAnchor.x;
    let y = menuAnchor.y;
    if (x + width > area.x + area.width - 8) x = Math.max(area.x + 8, menuAnchor.x - width);
    if (y + height > area.y + area.height - 8) {
      y = Math.max(area.y + 8, area.y + area.height - height - 8);
    }
    menuWindow.setBounds({ x: Math.round(x), y: Math.round(y), width, height }, false);
    menuWindow.show();
  });
  ipcMain.on('openclam:menu-action', (event, id) => {
    if (!menuWindow || event.sender !== menuWindow.webContents) return;
    const action = menuActions.get(String(id));
    closeMenuWindow();
    if (typeof action === 'function') action();
  });
  ipcMain.on('openclam:menu-close', (event) => {
    if (!menuWindow || event.sender !== menuWindow.webContents) return;
    closeMenuWindow();
  });
  ipcMain.on('openclam:pet-focus', (event) => {
    const window = isBuddySender(event) ? buddyWindow
      : (mainWindow && event.sender === mainWindow.webContents) ? mainWindow : null;
    if (!window || window.isDestroyed()) return;
    // Clicking the chat field must make this window KEY: acceptFirstMouse
    // delivers the click into an inactive window WITHOUT activating it, so
    // the caret never blinked and keystrokes stayed with the previous app
    // whenever OpenClam Studio was not already frontmost - the "randomly dead
    // input field". Stealing focus is exactly what a click in a text field
    // means.
    app.focus({ steal: true });
    window.focus();
  });
  ipcMain.on('openclam:pet-control-rects', (event, value) => {
    const rects = (Array.isArray(value) ? value : []).slice(0, 8)
      .map((r) => ({ x: Number(r && r.x), y: Number(r && r.y),
                     w: Number(r && r.w), h: Number(r && r.h) }))
      .filter((r) => [r.x, r.y, r.w, r.h].every(Number.isFinite) && r.w > 0 && r.h > 0);
    if (isBuddySender(event)) buddyControlRects = rects;
    else if (mainWindow && event.sender === mainWindow.webContents) petControlRects = rects;
  });
  ipcMain.handle('openclam:export-avatar', async (event, payload) => {
    const slug = String((payload && payload.slug) || '');
    if (!/^[a-z0-9](?:[a-z0-9-]{0,62})$/.test(slug)) return { saved: false, error: 'Invalid avatar.' };
    const variant = payload && payload.variant === 'ios-light' ? 'ios-light' : 'macos-full';
    const suggested = String((payload && payload.name) || slug)
      .replace(/[/\\:]+/g, '-').slice(0, 80) || slug;
    const { canceled, filePath } = await dialog.showSaveDialog({
      title: variant === 'ios-light' ? 'Export Avatar for iPhone' : 'Export Editable Mac Avatar',
      defaultPath: `${suggested}-${variant === 'ios-light' ? 'iPhone' : 'Mac'}.avtr`,
      filters: [{ name: 'OpenClam Avatar', extensions: ['avtr'] }],
    });
    if (canceled || !filePath) return { saved: false };
    try {
      const response = await fetch(
        `${baseUrl()}/api/avatar/export?slug=${encodeURIComponent(slug)}&variant=${variant}`,
        { headers: { [AUTH_HEADER]: backendToken } });
      if (!response.ok || !response.body) {
        return { saved: false, error: `Export failed (${response.status}).` };
      }
      const { Readable } = require('node:stream');
      const { pipeline } = require('node:stream/promises');
      await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(filePath));
      return { saved: true, path: filePath };
    } catch (error) {
      try { fs.unlinkSync(filePath); } catch (cleanupError) { /* partial file */ }
      return { saved: false, error: String(error.message || error) };
    }
  });
  ipcMain.on('openclam:pet-dock', (event) => {
    // The stillness idle leans on a screen edge, so the window settles in
    // its bottom corner above the Dock first - right for the active avatar,
    // left for the second one. Locked or roaming pets stay where they are
    // and idle in place.
    if (isBuddySender(event)) { dockBuddy(); return; }
    if (!mainWindow || event.sender !== mainWindow.webContents) return;
    if (state.petRoam || state.petLocked) return;
    const area = screen.getDisplayMatching(mainWindow.getBounds()).workArea;
    // The idle docks SMALL - roam scale, a colleague stepping aside, not
    // a full-size cutout parked in the corner (owner, 2026-08-02). The
    // held bounds come back on undock. Flush against the work area: any
    // dock margin becomes a phantom wall floating in air - she must rest
    // on the actual screen edge, feet just above the Dock.
    if (!preDockBounds) preDockBounds = mainWindow.getBounds();
    const size = clampRoamSizeToArea(petRoamSize(), area);
    const bounds = dockedPetBounds(size, area, 0);
    mainWindow.setMinimumSize(size.width, size.height);
    mainWindow.setBounds(bounds, false);
  });
  ipcMain.on('openclam:pet-undock', (event) => {
    if (!mainWindow || event.sender !== mainWindow.webContents) return;
    if (!preDockBounds) return;
    const bounds = preDockBounds;
    preDockBounds = null;
    if (state.petRoam || state.petLocked) return;
    mainWindow.setMinimumSize(PET_NORMAL_MINIMUM.width, PET_NORMAL_MINIMUM.height);
    mainWindow.setBounds(bounds, false);
    state.bounds = { ...bounds };
    saveStateSoon();
  });
  ipcMain.on('openclam:drag-start', (event, point) => {
    if (isBuddySender(event)) {
      if (state.petLocked || buddyRoam) return;
      buddyDrag = {
        x: Number(point && point.screenX) || 0,
        y: Number(point && point.screenY) || 0,
        bounds: buddyWindow.getBounds(),
      };
      return;
    }
    if (!mainWindow || event.sender !== mainWindow.webContents
        || state.petLocked || state.petRoam) return;
    petDrag = {
      x: Number(point && point.screenX) || 0,
      y: Number(point && point.screenY) || 0,
      bounds: mainWindow.getBounds(),
    };
  });
  // A malformed drag frame once reached setPosition and threw a native
  // "conversion failure" dialog in the main process (owner screenshot,
  // 2026-08-02). Coordinates are validated to safe int32 or dropped.
  const dragCoord = (base, screen, origin) => {
    const value = Math.round(Number(base) + (Number(screen) - Number(origin)));
    return Number.isFinite(value) && Math.abs(value) <= 0x7fffff ? value : null;
  };
  ipcMain.on('openclam:drag-move', (event, point) => {
    if (isBuddySender(event)) {
      if (!buddyDrag || state.petLocked || buddyRoam) return;
      const x = dragCoord(buddyDrag.bounds.x, point && point.screenX, buddyDrag.x);
      const y = dragCoord(buddyDrag.bounds.y, point && point.screenY, buddyDrag.y);
      if (x !== null && y !== null) {
        try { buddyWindow.setPosition(x, y, false); } catch {}
      }
      return;
    }
    if (!petDrag || !mainWindow || event.sender !== mainWindow.webContents
        || state.petLocked || state.petRoam) return;
    const x = dragCoord(petDrag.bounds.x, point && point.screenX, petDrag.x);
    const y = dragCoord(petDrag.bounds.y, point && point.screenY, petDrag.y);
    if (x !== null && y !== null) {
      try { mainWindow.setPosition(x, y, false); } catch {}
    }
  });
  ipcMain.on('openclam:drag-end', (event) => {
    if (isBuddySender(event)) { buddyDrag = null; return; }
    petDrag = null;
    saveStateSoon();
  });
  ipcMain.on('openclam:live-active', (_event, value) => {
    liveTalkActive = Boolean(value);
  });
  ipcMain.handle('openclam:avatar-changed', () => {
    if (state.petRoam) applyPetRoam(false);
    petMotionReady = false;
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.reloadIgnoringCache();
    // Activating the avatar that held the left desk vacates it server-side;
    // re-sync so the second window closes (or stays) accordingly.
    syncBuddyFromServer().catch(() => {});
    return true;
  });
  ipcMain.handle('openclam:companion-changed', () => syncBuddyFromServer());
  ipcMain.handle('openclam:restart-backend', restartBackend);
}

function installRequestAuthentication() {
  session.defaultSession.webRequest.onBeforeSendHeaders(
    { urls: ['<all_urls>'] },
    (details, callback) => {
      try {
        // WebSocket upgrades carry a ws:// origin, which never equals the
        // http:// base URL. Compare host and allow only http/ws to this local
        // backend so streaming PTT stays authenticated.
        const target = new URL(details.url);
        if (target.host === new URL(baseUrl()).host
            && (target.protocol === 'http:' || target.protocol === 'ws:')) {
          details.requestHeaders[AUTH_HEADER] = backendToken;
        }
      } catch {}
      callback({ requestHeaders: details.requestHeaders });
    },
  );
}

function installPermissions() {
  const allowedOrigin = baseUrl();
  const sameOrigin = (value) => {
    try { return new URL(value).origin === allowedOrigin; } catch { return false; }
  };
  const audioOnly = (details = {}) => {
    const mediaTypes = details.mediaTypes || [];
    return mediaTypes.length === 0 || mediaTypes.every((value) => value === 'audio');
  };
  session.defaultSession.setPermissionCheckHandler(
    (_webContents, permission, requestingOrigin, details) => (
      permission === 'media' && sameOrigin(requestingOrigin) && audioOnly(details)
    ),
  );
  session.defaultSession.setPermissionRequestHandler(
    (webContents, permission, callback, details = {}) => {
      const url = webContents.getURL();
      callback(permission === 'media' && sameOrigin(url)
        && (details.mediaTypes || []).length > 0 && audioOnly(details));
    },
  );
}

// ---------------------------------------------------------------- updates
// GitHub's latest release is the source of truth. Updates remain explicit:
// the user chooses whether to download/install the signed DMG.
const UPDATE_REPO = 'tivojn/openclam-livekit-studio';
const UPDATE_USER_AGENT = 'openclam-livekit-studio';
const UPDATE_TEAM_ID = 'X7R8N6MMSU';
const UPDATE_APP_ID = 'com.lionheart.openclam.macos';
const UPDATE_STAGING_APP = '/Applications/.OpenClam-Studio-update.app';
const UPDATE_RETIRED_APP = '/Applications/.OpenClam-Studio-previous.app';
const UPDATE_FAILED_APP = '/Applications/.OpenClam-Studio-failed.app';
let updatePromptedVersion = null;

function versionNewer(candidate, current) {
  const parse = (value) => String(value || '').replace(/^v/i, '')
    .split('.').map((part) => parseInt(part, 10) || 0);
  const a = parse(candidate);
  const b = parse(current);
  for (let i = 0; i < 3; i++) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  }
  return false;
}

async function checkForUpdates(interactive = false) {
  const current = app.getVersion();
  try {
    const response = await fetch(
      `https://api.github.com/repos/${UPDATE_REPO}/releases/latest`,
      { headers: { accept: 'application/vnd.github+json',
                   'user-agent': UPDATE_USER_AGENT } });
    if (!response.ok) throw new Error(`GitHub answered HTTP ${response.status}`);
    const release = await response.json();
    const latest = String(release.tag_name || '').replace(/^v/i, '');
    if (!/^\d+\.\d+\.\d+$/.test(latest)) {
      throw new Error('the release tag is not a supported semantic version');
    }
    if (!latest || !versionNewer(latest, current)) {
      if (interactive) {
        await dialog.showMessageBox({
          type: 'info',
          message: `${APP_NAME} ${current} is up to date.`,
          detail: 'You are on the newest released version.',
        });
      }
      return;
    }
    // The background check nags once per version per run; the menu item
    // always answers.
    if (!interactive && updatePromptedVersion === latest) return;
    updatePromptedVersion = latest;
    const expectedDmgName = `OpenClam-Studio-${latest}-arm64.dmg`;
    const matchingDmgs = (release.assets || [])
      .filter((asset) => asset.name === expectedDmgName);
    if (matchingDmgs.length > 1) throw new Error('the release has duplicate DMG assets');
    const dmg = matchingDmgs.length === 1 ? matchingDmgs[0] : null;
    const installedBundle = app.getAppPath().replace(/\.app\/.*$/, '.app');
    const canAutoInstall = Boolean(dmg) && app.isPackaged
      && installedBundle === `/Applications/${APP_NAME}.app`;
    const { response: choice } = await dialog.showMessageBox({
      type: 'info',
      message: `${APP_NAME} ${latest} is available`,
      detail: canAutoInstall
        ? `You are on ${current}. The update downloads the notarized release, `
          + `asks macOS to verify it, installs it, and relaunches ${APP_NAME}.`
        : `You are on ${current}. Download the new DMG, open it, and drag `
          + `${APP_NAME} into Applications to upgrade.`,
      buttons: [canAutoInstall ? 'Install Update' : 'Download Update', 'Later'],
      defaultId: 0,
      cancelId: 1,
    });
    if (choice !== 0) return;
    if (canAutoInstall) {
      try {
        await installUpdate(dmg, latest);
        return;   // unreachable in practice: installUpdate relaunches
      } catch (error) {
        writeBackendLog(`[auto-update failed] ${String((error && error.message) || error)}\n`);
        // Do not leave a rejected artifact sitting in app-controlled storage.
        fs.rmSync(path.join(app.getPath('userData'), 'updates'),
          { recursive: true, force: true });
        await dialog.showMessageBox({
          type: 'error',
          message: 'The update was not installed.',
          detail: `${String((error && error.message) || error)}\n\n`
            + 'OpenClam will not bypass signing, notarization, or Gatekeeper checks.',
        });
        return;
      }
    }
    await shell.openExternal((dmg && dmg.browser_download_url)
      || release.html_url
      || `https://github.com/${UPDATE_REPO}/releases/latest`);
  } catch (error) {
    writeBackendLog(`[update check failed] ${String((error && error.message) || error)}\n`);
    if (interactive) {
      await dialog.showMessageBox({
        type: 'info',
        message: 'Could not check for updates.',
        detail: String((error && error.message) || error),
      });
    }
  }
}

function execFileAsync(executable, args) {
  return new Promise((resolve, reject) => {
    execFile(executable, args, { maxBuffer: 1 << 22 }, (error, stdout, stderr) => {
      if (error) reject(new Error(String(stderr || error.message).slice(0, 300)));
      else resolve({ stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

async function codesignTeam(bundlePath) {
  // codesign prints its report on stderr.
  const { stderr } = await execFileAsync('/usr/bin/codesign', ['-dv', '--verbose=4', bundlePath]);
  const match = stderr.match(/TeamIdentifier=([A-Z0-9]+)/);
  if (!match || match[1] === 'not set') throw new Error('unsigned bundle');
  return match[1];
}

async function appBundleMetadata(appPath) {
  const infoPath = path.join(appPath, 'Contents', 'Info.plist');
  const readValue = async (key) => {
    const { stdout } = await execFileAsync('/usr/bin/plutil',
      ['-extract', key, 'raw', '-o', '-', infoPath]);
    return stdout.trim();
  };
  const [identifier, version] = await Promise.all([
    readValue('CFBundleIdentifier'), readValue('CFBundleShortVersionString')]);
  return { identifier, version };
}

async function requireNotarizedDmg(dmgPath) {
  // A stapled ticket makes the notarization decision verifiable even when the
  // Mac is offline. spctl then asks Gatekeeper to assess the signed disk image.
  await execFileAsync('/usr/bin/codesign', ['--verify', '--strict', dmgPath]);
  const team = await codesignTeam(dmgPath);
  if (team !== UPDATE_TEAM_ID) throw new Error('update DMG has the wrong signing team');
  await execFileAsync('/usr/bin/hdiutil', ['verify', dmgPath]);
  await execFileAsync('/usr/bin/xcrun', ['stapler', 'validate', '-v', dmgPath]);
  await execFileAsync('/usr/sbin/spctl', [
    '--assess', '--type', 'open', '--context', 'context:primary-signature',
    '--verbose=4', dmgPath,
  ]);
}

async function requireNotarizedApp(appPath, expectedVersion) {
  await execFileAsync('/usr/bin/codesign', ['--verify', '--deep', '--strict', appPath]);
  const team = await codesignTeam(appPath);
  if (team !== UPDATE_TEAM_ID) throw new Error('update app has the wrong signing team');
  const metadata = await appBundleMetadata(appPath);
  if (metadata.identifier !== UPDATE_APP_ID) {
    throw new Error('update app has the wrong bundle identifier');
  }
  if (metadata.version !== expectedVersion) {
    throw new Error(`update app version ${metadata.version || 'unknown'} does not match ${expectedVersion}`);
  }
  await execFileAsync('/usr/bin/xcrun', ['stapler', 'validate', '-v', appPath]);
  await execFileAsync('/usr/sbin/spctl', [
    '--assess', '--type', 'execute', '--verbose=4', appPath,
  ]);
  await execFileAsync('/usr/bin/syspolicy_check', ['distribution', appPath, '--verbose']);
}

async function installUpdate(asset, latest) {
  // Download → Gatekeeper/notarization verification → swap → relaunch.
  // The app never relies on the absence of a quarantine attribute: both the
  // outer DMG and nested app must carry valid Apple notary tickets.
  if (!/^\d+\.\d+\.\d+$/.test(latest) || !versionNewer(latest, app.getVersion())) {
    throw new Error('refusing an update that is not strictly newer');
  }
  showSpeechBubble(`Downloading ${APP_NAME} ${latest}. I will restart myself when it is ready.`);
  const updatesDir = path.join(app.getPath('userData'), 'updates');
  fs.rmSync(updatesDir, { recursive: true, force: true });
  fs.mkdirSync(updatesDir, { recursive: true, mode: 0o700 });
  const bootMarker = path.join(updatesDir, `boot-ok-${latest}`);
  const dmgPath = path.join(updatesDir, `OpenClam-Studio-${latest}.dmg`);
  const response = await fetch(asset.browser_download_url, {
    headers: { 'user-agent': UPDATE_USER_AGENT }, redirect: 'follow' });
  if (!response.ok) throw new Error(`download failed (HTTP ${response.status})`);
  const payload = Buffer.from(await response.arrayBuffer());
  if (asset.size && payload.length !== asset.size) {
    throw new Error(`download incomplete (${payload.length} of ${asset.size} bytes)`);
  }
  fs.writeFileSync(dmgPath, payload, { mode: 0o600 });
  await requireNotarizedDmg(dmgPath);

  const attach = await execFileAsync('/usr/bin/hdiutil',
    ['attach', dmgPath, '-nobrowse', '-readonly', '-plist']);
  const mount = (attach.stdout.match(/<key>mount-point<\/key>\s*<string>([^<]+)<\/string>/) || [])[1];
  if (!mount) throw new Error('could not mount the update image');
  try {
    const newApp = path.join(mount, `${APP_NAME}.app`);
    if (!fs.existsSync(newApp)) throw new Error(`no ${APP_NAME}.app in the update image`);
    await requireNotarizedApp(newApp, latest);
    // The current installation must have the pinned release team too. This
    // prevents an ad-hoc or differently signed build from becoming an update
    // trust anchor.
    const ownBundle = app.getAppPath().replace(/\.app\/.*$/, '.app');
    if (ownBundle !== `/Applications/${APP_NAME}.app`) {
      throw new Error('automatic updates require the standard Applications path');
    }
    const [ownTeam, newTeam] = await Promise.all([
      codesignTeam(ownBundle), codesignTeam(newApp)]);
    if (ownTeam !== UPDATE_TEAM_ID || newTeam !== UPDATE_TEAM_ID) {
      throw new Error('signature team does not match the pinned OpenClam release team');
    }
    showSpeechBubble('Installing the update. Back in a moment.');
    const staging = UPDATE_STAGING_APP;
    const retired = UPDATE_RETIRED_APP;
    fs.rmSync(staging, { recursive: true, force: true });
    fs.rmSync(retired, { recursive: true, force: true });
    fs.rmSync(UPDATE_FAILED_APP, { recursive: true, force: true });
    fs.rmSync(bootMarker, { force: true });
    await execFileAsync('/usr/bin/ditto', [newApp, staging]);
    await requireNotarizedApp(staging, latest);
    fs.renameSync(ownBundle, retired);
    try {
      fs.renameSync(staging, ownBundle);
    } catch (error) {
      // If the second half of the swap fails, put the still-running version
      // back immediately; the watchdog is started only after a complete swap.
      if (!fs.existsSync(ownBundle) && fs.existsSync(retired)) {
        fs.renameSync(retired, ownBundle);
      }
      throw error;
    }
  } finally {
    await execFileAsync('/usr/bin/hdiutil', ['detach', mount, '-quiet']).catch(() => {});
  }
  // A detached watchdog owns the rollback after this process exits. The new
  // build gets 60 seconds to keep its signed UI and backend alive for a
  // 30-second grace period and write the version-specific marker. If it does
  // not, the watchdog preserves the failed app, restores the prior build, and
  // opens it. Paths are fixed arguments, never interpolated into shell code.
  const watchdog = [
    'current="$1"', 'previous="$2"', 'failed="$3"', 'marker="$4"',
    '/bin/sleep 2',
    'launched=1',
    '/usr/bin/open "$current" || launched=0',
    'attempt=0',
    'while [ "$launched" -eq 1 ] && [ "$attempt" -lt 30 ]; do',
    '  if [ -f "$marker" ]; then',
    '    /bin/rm -rf -- "$previous"',
    '    /bin/rm -f -- "$marker"',
    '    exit 0',
    '  fi',
    '  /bin/sleep 2',
    '  attempt=$((attempt + 1))',
    'done',
    '/usr/bin/pkill -x "OpenClam Studio" >/dev/null 2>&1 || true',
    '/bin/sleep 2',
    'if [ -d "$previous" ]; then',
    '  if [ -e "$current" ]; then /bin/mv -- "$current" "$failed" || exit 1; fi',
    '  /bin/mv -- "$previous" "$current" || exit 1',
    '  /usr/bin/open "$current"',
    'fi',
  ].join('\n');
  spawn('/bin/sh', ['-c', watchdog, 'openclam-update-watchdog',
    '/Applications/OpenClam Studio.app', UPDATE_RETIRED_APP,
    UPDATE_FAILED_APP, bootMarker],
    { detached: true, stdio: 'ignore' }).unref();
  app.quit();
}

function scheduleRollbackRetirement() {
  if (!app.isPackaged || !app.getAppPath().startsWith('/Applications/')) return;
  const version = app.getVersion();
  if (!/^\d+\.\d+\.\d+$/.test(version)) return;
  const marker = path.join(app.getPath('userData'), 'updates', `boot-ok-${version}`);
  const timer = setTimeout(() => {
    const uiHealthy = mainWindow && !mainWindow.isDestroyed();
    const backendHealthy = backend && backend.exitCode === null && !backend.killed;
    if (!uiHealthy || !backendHealthy) return;
    try {
      fs.mkdirSync(path.dirname(marker), { recursive: true, mode: 0o700 });
      fs.writeFileSync(marker, 'ok\n', { mode: 0o600 });
    } catch (error) {
      writeBackendLog(`[update boot marker failed] ${String((error && error.message) || error)}\n`);
    }
  }, 30_000);
  timer.unref?.();
}

function scheduleUpdateChecks() {
  if (!app.isPackaged) return;   // dev runs track git, not releases
  setTimeout(() => { void checkForUpdates(); }, 15_000);
  const timer = setInterval(() => { void checkForUpdates(); }, 6 * 3600 * 1000);
  timer.unref?.();
}

async function boot() {
  state = loadState();
  installIpc();
  try {
    await startBackend();
  } catch (error) {
    await dialog.showMessageBox({
      type: 'error',
      message: `${APP_NAME} could not start its local engine.`,
      detail: `${error.message || error}\n\nBackend log: ${logPath()}`,
    });
    app.quit();
    return;
  }
  installRequestAuthentication();
  installPermissions();
  createMainWindow();
  createTray();
  installRecoveryShortcut();
  scheduleUpdateChecks();
  // Battery-aware pacing: the renderer halves its frame caps on battery.
  powerMonitor.on('on-battery', broadcastState);
  powerMonitor.on('on-ac', broadcastState);
  const metadata = await openClamMetadata(3000);
  if (!metadata || !metadata.active) openSettings();
  if (metadata && metadata.companion) createBuddyWindow(metadata.companion);
  scheduleRollbackRetirement();
}

const lock = app.requestSingleInstanceLock();
if (!lock) {
  app.quit();
} else {
  app.on('second-instance', showMain);
  app.whenReady().then(boot);
}

app.on('activate', showMain);
app.on('before-quit', () => {
  quitting = true;
  cancelAllAvatarStoreJobs();
  globalShortcut.unregisterAll();
  stopPetPointerTracking();
  closeBuddyWindow();
  clearTimeout(bubbleTimer);
  if (bubbleWindow && !bubbleWindow.isDestroyed()) bubbleWindow.destroy();
  if (appearanceWindow && !appearanceWindow.isDestroyed()) appearanceWindow.destroy();
  stopBackend();
  if (backendLog) backendLog.end();
});
app.on('window-all-closed', () => {
  // Tray application: closing the last window does not stop the voice engine.
});
