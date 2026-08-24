'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const main = read('electron/main.cjs');
const preload = read('electron/preload.cjs');
const avatarStore = read('electron/avatar-store.cjs');
const secondaryPreloads = [
  read('electron/appearance-preload.cjs'),
  read('electron/bubble-preload.cjs'),
  read('electron/menu-preload.cjs'),
].join('\n');
const shellSource = `${main}\n${preload}\n${avatarStore}\n${secondaryPreloads}`;
const settings = read('web/settings.html');
const entitlements = read('build/entitlements.mac.plist');

// Standalone means there is no device discovery, LAN bind, relay, external
// app audio capture, or synthesized keyboard event hidden behind the UI.
for (const forbidden of [
  /enconvo/i,
  /0\.0\.0\.0/,
  /networkInterfaces/,
  /remoteAccess/,
  /Pair iPhone/i,
  /iPhone on This Network/i,
  /key-tap/i,
  /pet-voice-key/i,
  /get-enconvo-samples/i,
  /set-enconvo-monitor/i,
  /trigger-enconvo-voice/i,
]) {
  assert.doesNotMatch(shellSource, forbidden);
}

for (const removed of [
  'electron/enconvo-audio-monitor.cjs',
  'electron/native/enconvo_audio_tap.swift',
  'electron/native/key_tap.swift',
]) {
  assert.equal(fs.existsSync(path.join(root, removed)), false, `${removed} must stay removed`);
}

// The only local service route is an authenticated loopback uvicorn process.
assert.match(main, /const HOST = '127\.0\.0\.1';/);
assert.match(main, /'server\.app:app'/);
assert.match(main, /'--host', HOST, '--port', String\(port\)/);
assert.match(main, /const AUTH_HEADER = 'X-OpenClam-Token';/);
assert.match(main, /details\.requestHeaders\[AUTH_HEADER\] = backendToken/);
assert.match(main, /const APP_ID = 'com\.lionheart\.openclam\.macos';/);
assert.match(main, /const DEV_APP_ID = `\$\{APP_ID\}\.dev`;/);
assert.match(main, /app\.setPath\('userData', path\.join\(app\.getPath\('appData'\), DEV_APP_NAME\)\)/,
  'source runs must use an independent single-instance lock and shell state');
assert.match(main, /OPENCLAM_LIVEKIT_BROKER_URL: LIVEKIT_BROKER_URL/);
assert.match(main, /OPENCLAM_LIVEKIT_SERVER_HOST: LIVEKIT_SERVER_HOST/);
assert.match(main, /delete inherited\.OPENCLAM_VAULT_FILE/);
assert.match(main, /app\.setName\(APP_NAME\)/);
assert.doesNotMatch(main, /'Vivieen'|"Vivieen"|`Vivieen/);
assert.doesNotMatch(main, /Recover Companion|Hide Companion/);

// The desktop avatar system remains intact: two protected transparent pet
// windows, full-body movement/edge idle, local chat/PTT entry, Live Talk,
// settings, and AVTR export.
for (const required of [
  'function createMainWindow()',
  'function setChatMode(value)',
  'function chatWindowBounds()',
  'function showChat()',
  'function createBuddyWindow(slug)',
  'function startPetRoamMotion()',
  'function startBuddyRoamMotion()',
  'PET_LEDGE_HOLD_MS',
  "post(chatWindow, 'openclam:pet-chat')",
  "post(mainWindow, 'openclam:live-toggle')",
  "ipcMain.on('openclam:live-active'",
  "ipcMain.handle('openclam:export-avatar'",
  "ipcMain.handle('openclam:avatar-store-catalog'",
  "ipcMain.handle('openclam:avatar-store-thumbnail'",
  "ipcMain.handle('openclam:avatar-store-download'",
  "ipcMain.handle('openclam:avatar-store-cancel'",
  "ipcMain.handle('openclam:set-pet-opacity'",
  "ipcMain.handle('openclam:set-chat-mode'",
  "ipcMain.handle('openclam:show-chat'",
  "ipcMain.handle('openclam:avatar-changed'",
  "ipcMain.handle('openclam:companion-changed'",
  'function openSettings()',
  'function guardNavigation(window, kind)',
]) {
  assert.ok(main.includes(required), `missing shell capability: ${required}`);
}
for (const required of [
  "showChat: () => ipcRenderer.invoke('openclam:show-chat')",
  "setChatMode: (value) => ipcRenderer.invoke('openclam:set-chat-mode', Boolean(value))",
  "avatarStoreCatalog: (options) => ipcRenderer.invoke('openclam:avatar-store-catalog'",
  "avatarStoreThumbnail: (id) => ipcRenderer.invoke('openclam:avatar-store-thumbnail'",
  "downloadAvatarStoreItem: (id) => ipcRenderer.invoke('openclam:avatar-store-download'",
  "cancelAvatarStoreItem: (id) => ipcRenderer.invoke('openclam:avatar-store-cancel'",
  "onAvatarStoreProgress: (callback) => subscribe('openclam:avatar-store-progress'",
  "copySettingsText: (value) => ipcRenderer.invoke(",
]) assert.ok(preload.includes(required), `missing Avatar Store bridge: ${required}`);
assert.match(main, /const CHAT_MODE_MINIMUM = Object\.freeze\(\{ width: 760, height: 600 \}\);/,
  'Chat\/Talk mode must remain a readable full-window surface');
assert.match(main, /const START_IN_CHAT_MODE = process\.argv\.includes\('--chat'\);/,
  'source runs need an explicit Chat\/Talk launch option');
assert.match(main, /interfaceMode: 'avatar'/,
  'Avatar and Chat\/Talk must share one persisted mode authority');
assert.match(main, /state\.interfaceMode = 'chat'/);
assert.match(main, /state\.interfaceMode = 'avatar'/);
assert.match(main, /createMainWindow\(\);\n  if \(START_IN_CHAT_MODE \|\| state\.interfaceMode === 'chat'\) setChatMode\(true\);/,
  'the --chat option or saved mode must open the normal Chat\/Talk window');
assert.match(main, /title: `\$\{app\.getName\(\)\} · Chat\/Talk`/,
  'development windows must identify the current source app rather than looking like the mounted release');
assert.match(main, /mainWindow\.on\('page-title-updated', event => event\.preventDefault\(\)\)/,
  'renderer page titles must not overwrite the source app identity');
assert.match(main, /chatWindow\.on\('page-title-updated', event => event\.preventDefault\(\)\)/,
  'the Chat\/Talk window must retain the source app identity');
assert.match(main, /function createChatWindow\(\)[\s\S]{0,1000}frame: true,[\s\S]{0,250}transparent: false,[\s\S]{0,350}resizable: true/,
  'Chat\/Talk must be a standard, opaque, resizable macOS application window');
assert.match(main, /function setChatMode\(value\)[\s\S]{0,1400}mainWindow\.hide\(\);[\s\S]{0,120}createChatWindow\(\)[\s\S]{0,1000}mainWindow\.showInactive\(\)/,
  'mode switching must move between the normal chat window and standby companion');
assert.match(main, /chatMode,\s*chatCloseUp,\s*desktopCloseUp,/,
  'the renderer must receive the canvas-specific close-up presentation');
assert.match(main, /function standbyCompanionMode\(\)[\s\S]{0,260}if \(chatMode\) \{[\s\S]{0,160}chatCloseUp = false;[\s\S]{0,100}return;/,
  'Standby Size must reset the avatar inside Chat\/Talk without closing its window');
assert.match(main, /function deskCompanionMode\(\)[\s\S]{0,240}if \(chatMode\) \{[\s\S]{0,100}chatCloseUp = !chatCloseUp;[\s\S]{0,100}return;/,
  'Close-Up Companion must toggle the chat-window canvas without revealing the desktop pet');
const closeUpMode = main.match(/function deskCompanionMode\(\) \{([\s\S]*?)\n\}\n\nfunction openSettings/);
assert.ok(closeUpMode, 'Close-Up Companion must remain independently auditable');
assert.match(closeUpMode[1], /companionHold = \{ zoom: state\.petZoom, bounds: mainWindow\.getBounds\(\) \};[\s\S]{0,160}desktopCloseUp = true;/,
  'Avatar-mode Close-Up Companion must preserve and switch renderer presentation state');
assert.match(closeUpMode[1], /screen\.getDisplayMatching\(mainWindow\.getBounds\(\)\)\.bounds[\s\S]{0,120}mainWindow\.setBounds\(bounds, false\)/,
  'Avatar-mode Close-Up must use the selected display as its canvas');
assert.ok(!closeUpMode[1].includes('state.petZoom = PET_ZOOM_RANGE.max'),
  'Close-Up must not create a GPU-unsafe oversized transparent window');
const avatarMenu = main.match(/function showPetMenu\(\) \{([\s\S]*?)\n\}\n\nfunction createTray/);
assert.ok(avatarMenu, 'Avatar mode must retain one focused right-click menu');
for (const label of ['Open Chat/Talk', 'Live Talk', 'Horizon Walk', 'Moves',
  'Standby Size', 'Close-Up Companion', 'Always on Top', 'Character Studio…']) {
  assert.ok(avatarMenu[1].includes(label), `missing meaningful Avatar menu item: ${label}`);
}
for (const retired of ['React', 'Rest', 'Click-Through Gaps', 'Click Through Empty Space',
  'Lock Position', 'Hide Avatar']) {
  assert.ok(!avatarMenu[1].includes(`name: '${retired}'`),
    `legacy Avatar menu item must stay removed: ${retired}`);
}
assert.match(main, /ipcMain\.handle\('openclam:copy-settings-text', writeSettingsClipboard\)/);
assert.match(main, /if \(!avatarStoreSender\(event\)[\s\S]*clipboard\.writeText\(text\);/,
  'clipboard writes must be settings-only, bounded, and write-only');
assert.match(main, /fs\.openAsBlob\(file, \{type: 'application\/vnd\.openclam\.avatar\+zip'\}\)/,
  'Store packages must stream into the existing bounded AVTR import route');
assert.match(main, /\/api\/avatar\/import/);
assert.match(main, /job\.phase = 'installing';/,
  'Avatar Store must close its cancellation window before local AVTR import');
assert.match(main,
  /!\['preparing', 'downloading'\]\.includes\(job\.phase\)\) return false;/,
  'Cancel must be refused once verification or installation begins');
assert.match(main, /record\.version >= entry\.version/,
  'An already-installed catalog version must not be offered as a downgrade');
assert.match(main, /record\.version < entry\.version/,
  'A newer catalog version must be identified explicitly for the UI');
assert.ok((main.match(/contextIsolation: true/g) || []).length >= 4);
assert.ok((main.match(/nodeIntegration: false/g) || []).length >= 4);
assert.ok((main.match(/sandbox: true/g) || []).length >= 4);
assert.ok((main.match(/webSecurity: true/g) || []).length >= 4);

// Settings remains an ordinary macOS window. Both pet windows temporarily
// drop from their floating level while it is visible, then hide/minimize/
// closed restores the user's or roaming always-on-top behavior. Restoring
// Settings lowers the pets again without taking focus from an active composer.
assert.match(main, /function protectSettingsFromPetOverlay\(\)/);
assert.match(main, /BrowserWindow\.getFocusedWindow\(\)/);
assert.match(main, /settingsWindow\.isVisible\(\) && !settingsWindow\.isMinimized\(\)/,
  'A minimized Settings window must not keep either pet de-elevated');
assert.match(main, /if \(focused !== settingsWindow\) return;\s*settingsWindow\.moveTop\(\)/);
assert.match(main, /settingsWindow\.moveTop\(\)/);
assert.doesNotMatch(main, /focused !== settingsWindow\) settingsWindow\.focus\(\)/,
  'An intentional click in the pet composer must not hand keyboard focus back to Settings');
assert.match(main, /settingsWindow\.on\('show', protectSettingsFromPetOverlay\)/);
assert.match(main, /settingsWindow\.on\('hide', \(\) => syncPetWindowLevels\(false\)\)/);
assert.match(main, /settingsWindow\.on\('minimize', \(\) => syncPetWindowLevels\(false\)\)/);
assert.match(main, /settingsWindow\.on\('restore', protectSettingsFromPetOverlay\)/);
assert.match(main, /settingsWindow\.on\('closed',[\s\S]{0,120}syncPetWindowLevels\(\)/);
assert.doesNotMatch(main, /settingsWindow\.setAlwaysOnTop\(/);

// Transparent body gaps are a permanent interaction invariant, not a toggle.
assert.doesNotMatch(main, /petClickThrough|set-pet-click-through|applyPetClickThrough/,
  'Avatar gap click-through must not be exposed as mutable product state');
assert.doesNotMatch(preload, /setPetClickThrough|set-pet-click-through/,
  'The renderer must not receive a click-through preference API');
assert.match(main, /const ignore = !value;\s*mainWindow\.setIgnoreMouseEvents\(ignore, \{ forward: true \}\);/,
  'Transparent pixels must always pass input to the layer underneath');
assert.match(main, /buddyWindow\.setIgnoreMouseEvents\(!value, \{ forward: true \}\);/,
  'The second avatar must share the same permanent gap behavior');
assert.match(main, /function setChatMode\(value\)[\s\S]{0,1000}if \(next && liveTalkActive\)/,
  'An active Live Talk must keep the lip-sync renderer in Avatar mode');
assert.match(main, /const dragCursorPoint = \(point\) => \{[\s\S]{0,260}screen\.getCursorScreenPoint\(\)/,
  'Desktop dragging must use Electron global cursor coordinates');

// An inactive transparent pet accepts the first composer click, then the
// renderer explicitly makes that pet the key window so macOS sends it text.
assert.match(preload, /focusPetWindow: \(\) => ipcRenderer\.send\('openclam:pet-focus'\)/);
assert.match(main, /ipcMain\.on\('openclam:pet-focus',[\s\S]{0,900}app\.focus\(\{ steal: true \}\);\s*window\.focus\(\);/);
assert.match(main, /mainWindow\.once\('ready-to-show',[\s\S]{0,420}mainWindow\.showInactive\(\);/,
  'The automatic pet reveal must not take key focus from cold-launch Settings');
assert.doesNotMatch(main, /mainWindow\.once\('ready-to-show',[\s\S]{0,420}mainWindow\.show\(\);/,
  'Only an explicit user action may activate the pet window');

// Starting Walk changes the window geometry. A stationary cursor that winds
// up over the resized avatar must not count as a hover; after one real leave,
// a later re-entry may still pause the walk normally.
const hoverHelpers = main.match(
  /(function observeRoamPointer\(gate, inside\) \{[\s\S]*?\n\})\n\n(function roamHoverCanEngage\(engaged, gate\) \{[\s\S]*?\n\})/,
);
assert.ok(hoverHelpers, 'Walk hover activation gate must remain independently testable');
const hoverGate = new Function(
  `'use strict'; ${hoverHelpers[1]}\n${hoverHelpers[2]}; `
    + 'return { observeRoamPointer, roamHoverCanEngage };',
)();
let activationGate = { armed: false, inside: false };
activationGate = hoverGate.observeRoamPointer(activationGate, true);
assert.equal(hoverGate.roamHoverCanEngage(true, activationGate), false,
  'window resize under a stationary cursor must not cancel a new Walk');
activationGate = hoverGate.observeRoamPointer(activationGate, false);
assert.equal(hoverGate.roamHoverCanEngage(true, activationGate), false,
  'a cursor outside the roam window cannot engage it');
activationGate = hoverGate.observeRoamPointer(activationGate, true);
assert.equal(hoverGate.roamHoverCanEngage(true, activationGate), true,
  'intentional leave and re-entry must restore normal hover pause');
assert.equal(hoverGate.roamHoverCanEngage(false, { armed: false, inside: true }), true,
  'disengagement must always be allowed so the walk cannot remain pinned');
assert.match(main, /function startPetRoamMotion\(\)[\s\S]{0,220}petRoamHoverGate = \{ armed: false, inside: false \};/,
  'each Walk activation must begin with a fresh hover gate');
assert.match(main, /target\.key === 'pet'[\s\S]{0,180}observeRoamPointer\(petRoamHoverGate, inside\)/,
  'the main-process cursor feed must arm hover only from observed geometry');
assert.match(main, /function setPetEngaged\(value\)[\s\S]{0,240}!roamHoverCanEngage\(engaged, petRoamHoverGate\)/,
  'the roam engine must enforce the activation gate before entering stand');

// A pause at either ledge must preserve Edge Idle and its anchor. `stand`
// remains the engine's pause state; presentation metadata is carried beside
// it, so resumeMode and the existing cooldown/resume behavior stay untouched.
const roamMotionStateSource = main.match(
  /(function roamMotionState\(runtime\) \{[\s\S]*?\n\})\n\nfunction sendPetRoamMotion/,
);
assert.ok(roamMotionStateSource, 'roam motion payload helper must remain independently testable');
const roamMotionState = new Function(
  `'use strict'; ${roamMotionStateSource[1]}; return roamMotionState;`,
)();
assert.deepEqual(roamMotionState({ mode: 'stand', resumeMode: 'walk', direction: -1, stride: 1.25, lastAt: 1234 }), {
  enabled: true, mode: 'stand', presentationMode: 'walk', direction: -1, phase: .25, sampledAt: 1234, edge: null,
});
assert.deepEqual(roamMotionState({ mode: 'stand', resumeMode: 'ledge-left', direction: 1, stride: .4, lastAt: 2345 }), {
  enabled: true, mode: 'stand', presentationMode: 'ledge-left', direction: 1, phase: .4, sampledAt: 2345, edge: 'left',
});
assert.deepEqual(roamMotionState({ mode: 'stand', resumeMode: 'ledge-right', direction: -1, stride: .6, lastAt: 3456 }), {
  enabled: true, mode: 'stand', presentationMode: 'ledge-right', direction: -1, phase: .6, sampledAt: 3456, edge: 'right',
});
assert.match(main, /function sendPetRoamMotion[\s\S]{0,240}roamMotionState\(petRoamRuntime\)/,
  'the active avatar must send preserved stand presentation metadata');
assert.match(main, /function sendBuddyRoamMotion[\s\S]{0,240}roamMotionState\(buddyRoamRuntime\)/,
  'the second avatar must preserve the same stand presentation semantics');
assert.match(main, /petRoamRuntime\.resumeMode = petRoamRuntime\.mode\.startsWith\('ledge-'\)[\s\S]{0,320}petRoamRuntime\.mode = 'stand'/,
  'engaging at a ledge must preserve that ledge as the resume/presentation origin');

// Motion metadata is authoritative. Long, smooth loops must not be squeezed
// into the old 2.5-second shell default or lose the tail of their trajectory.
const normalizeMotionProfileSource = main.match(
  /(function normalizeMotionProfile\(value, current\) \{[\s\S]*?\n\})\n\nfunction setPetMotionReady/,
);
assert.ok(normalizeMotionProfileSource,
  'motion profile normalization must remain independently testable');
const normalizeMotionProfile = new Function(
  'PET_ROAM_MIN_SPEED', 'PET_ROAM_MAX_SPEED',
  'PET_ROAM_MAX_CYCLE_SECONDS', 'PET_ROAM_MAX_PROFILE_FRAMES',
  `'use strict'; ${normalizeMotionProfileSource[1]}; return normalizeMotionProfile;`,
)(42, 150, 6, 160);
const currentProfile = { walkSpeed: 64, cycleSeconds: 1.1, cycleDistance: 70.4, travelOffsets: [] };
const threeSecond = normalizeMotionProfile({
  ready: true, walkSpeed: 48.9, cycleSeconds: 3,
  cycleDistance: 146.7, travelOffsets: Array.from({length: 72}, (_, index) => index * 2),
}, currentProfile).profile;
assert.equal(threeSecond.cycleSeconds, 3,
  'a 72-frame 24fps Walk must remain a three-second cycle');
assert.equal(threeSecond.cycleDistance, 146.7);
assert.equal(threeSecond.travelOffsets.length, 72);
const longCycle = normalizeMotionProfile({
  cycleSeconds: 5.2, walkSpeed: 80, cycleDistance: 400,
  travelOffsets: Array.from({length: 125}, (_, index) => index * 3),
}, currentProfile).profile;
assert.equal(longCycle.cycleSeconds, 5.2);
assert.equal(longCycle.travelOffsets.length, 125,
  'a supported 5.2-second traversal must retain its complete phase profile');
assert.equal(normalizeMotionProfile({cycleSeconds: 99}, currentProfile).profile.cycleSeconds, 6,
  'hostile cycle metadata must remain bounded');

// Walk keeps native-window travel at display cadence, while stationary ledge
// and hover states sleep. Renderer phase IPC is independently throttled to
// 32ms and state transitions still publish immediately.
const roamMotionSignatureSource = main.match(
  /(function roamMotionSignature\(value\) \{[\s\S]*?\n\})\n\n(function shouldSendRoamMotion\(runtime, value, now = Date\.now\(\), force = false\) \{[\s\S]*?\n\})/,
);
const roamTickDelaySource = main.match(
  /(function roamTickDelay\(runtime, now = Date\.now\(\)\) \{[\s\S]*?\n\})\n\nfunction sendPetRoamMotion/,
);
assert.ok(roamMotionSignatureSource, 'roam IPC gate must remain independently testable');
assert.ok(roamTickDelaySource, 'roam timer cadence must remain independently testable');
const roamPower = new Function(
  'PET_ROAM_TICK_MS', 'PET_ROAM_REST_TICK_MS', 'PET_ROAM_IPC_MS',
  `'use strict'; ${roamMotionSignatureSource[1]}\n${roamMotionSignatureSource[2]}\n`
    + `${roamTickDelaySource[1]}; return { shouldSendRoamMotion, roamTickDelay };`,
)(16, 250, 32);
const delivery = {motionSignature: '', motionSentAt: 0};
const walkingPacket = {enabled: true, mode: 'walk', presentationMode: 'walk', direction: 1, edge: null};
assert.equal(roamPower.shouldSendRoamMotion(delivery, walkingPacket, 1000), true);
assert.equal(roamPower.shouldSendRoamMotion(delivery, walkingPacket, 1016), false,
  'duplicate 60Hz walk IPC must be collapsed');
assert.equal(roamPower.shouldSendRoamMotion(delivery, walkingPacket, 1032), true,
  'the local phase clock must still receive a 32ms correction');
const ledgePacket = {enabled: true, mode: 'ledge-right', presentationMode: 'ledge-right', direction: 1, edge: 'right'};
assert.equal(roamPower.shouldSendRoamMotion(delivery, ledgePacket, 1048), true,
  'entering Edge Idle must publish immediately');
assert.equal(roamPower.shouldSendRoamMotion(delivery, ledgePacket, 5000), false,
  'a stationary ledge must not stream redundant IPC indefinitely');
assert.equal(roamPower.roamTickDelay({mode: 'walk'}, 1000), 16);
assert.equal(roamPower.roamTickDelay({mode: 'ledge-right', holdUntil: 9000}, 1000), 250);
assert.equal(roamPower.roamTickDelay({mode: 'ledge-right', holdUntil: 9010}, 9000), 16,
  'the sleeping ledge timer must wake near its transition deadline');
assert.match(main, /petRoamTimer = setTimeout\(\(\) => \{[\s\S]{0,120}tickPetRoam\(\)/);
assert.match(main, /buddyRoamTimer = setTimeout\(\(\) => \{[\s\S]{0,120}tickBuddyRoam\(\)/);
assert.doesNotMatch(main, /setInterval\(tick(?:Pet|Buddy)Roam/,
  'stationary roam states must not retain the old 60Hz interval');

// Renderer bridges expose only the OpenClam app-local control surface.
assert.match(preload, /exposeInMainWorld\('openclam', api\)/);
assert.doesNotMatch(preload, /vivieen/i);
for (const required of [
  'onPetChat',
  'onLiveToggle',
  'setLiveTalk',
  'exportAvatar',
  'saveMotionAsset',
  'setPetOpacity',
  'setPetRoam',
  'avatarChanged',
  'companionChanged',
]) {
  assert.ok(preload.includes(required), `missing renderer bridge: ${required}`);
}
assert.ok(fs.existsSync(path.join(root, 'electron/native/person_cutout.swift')));

// Settings expose one explicit independent LiveKit cascade and one local,
// authenticated OpenClaw-to-iPhone pairing surface. Broker and project host
// remain signed-build pins, while provider secrets stay write-only.
for (const id of ['livekit-llm', 'livekit-stt', 'livekit-tts', 'livekit-save']) {
  assert.match(settings, new RegExp(`id=["']${id}["']`));
}
assert.match(settings, /fetch\('\/api\/livekit\/config'|api\('\/api\/livekit\/config'/);
assert.match(settings, /readonly[\s\S]{0,120}livekit-server-host|livekit-server-host[\s\S]{0,120}readonly/);
for (const forbidden of [/Your iPhone/i, /Vivieen Keys/i]) {
  assert.doesNotMatch(settings, forbidden);
}
assert.match(settings, /id="openclaw-pairing-card"/);
assert.match(settings, /\/api\/openclaw\/pairing/);
assert.match(settings, /id="openclaw-install"/);
assert.match(settings, /\/api\/openclaw\/install/);

// PTT and Live Talk need microphone input. The explicit composer camera action
// needs camera input; no Apple Events automation or Accessibility entitlement
// survives the standalone cut.
assert.match(entitlements, /com\.apple\.security\.device\.audio-input/);
assert.match(entitlements, /com\.apple\.security\.device\.camera/);
assert.doesNotMatch(entitlements, /automation\.apple-events|accessibility/i);

console.log('standalone Electron shell QA passed');
