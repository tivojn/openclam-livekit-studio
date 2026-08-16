'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');
const inline = source.match(/<script>\s*([\s\S]*?)\s*<\/script>\s*<\/body>/);

assert.ok(inline, 'desktop renderer must contain one inline application script');
assert.doesNotThrow(() => new Function(inline[1]), 'desktop renderer JavaScript must parse');

// The renderer is a Mac-only OpenClam surface. It must not grow any of the
// inherited phone, discovery, external-app, or direct realtime roads back.
for (const forbidden of [
  /window\.vivieen/i,
  /\bEnConvo\b/i,
  /\bSolo\b/,
  /\brelay\b/i,
  /\biPhone\b/i,
  /\bPocket Mirror\b/i,
  /\bphone pairing\b/i,
  /viv:/i,
  /webkit\.messageHandlers/i,
  /\/live\/voice/i,
  /direct realtime/i,
  /mailto:/i,
  /contacts_search/i,
  /apple.?mail/i,
  /api[_ -]?key/i,
]) {
  assert.doesNotMatch(source, forbidden);
}

assert.match(source, /const shell = window\.openclam/);
assert.doesNotMatch(source, /location\.protocol\s*===/);
assert.doesNotMatch(source, /navigator\.userAgent/);

// One right-rail phone control owns the full call/hang-up lifecycle.
assert.equal((source.match(/id="liveTalkButton"/g) || []).length, 1);
assert.match(source, /data-state="idle" aria-label="Start Live Talk"/);
assert.match(source, /setLiveButton\('connected'\)/);
assert.match(source, /if \(live\) stopLiveTalk\('ended'\); else startLiveTalk\(\)/);

// Chat/PTT must be discoverable before an avatar exists. The onboarding layer
// stays below the rail and composer, and both the rail and card expose one
// explicit entry point without creating another Live Talk surface.
assert.equal((source.match(/id="chatButton"/g) || []).length, 1);
assert.equal((source.match(/id="emptyChat"/g) || []).length, 1);
assert.match(source, /aria-label="Open Chat and Push to Talk"/);
assert.match(source, /Chat &amp; Push to Talk/);
assert.match(source, /#emptyState \{[\s\S]{0,100}z-index: 25;/);
assert.match(source, /#chatDock \{[\s\S]{0,100}z-index: 35;/);
assert.match(source, /--pet-rail-reserve:\s*calc\(var\(--pet-edge\) \+ var\(--pet-rail-size\) \+ var\(--pet-rail-gap\)\)/,
  'Desktop geometry must define one shared right-rail reservation');
assert.match(source, /#emptyCard \{[\s\S]{0,120}width: min\(430px, 100%\);/,
  'The onboarding card must size inside the rail-cleared canvas');
assert.match(source, /#emptyState \{[\s\S]{0,220}inset: 8px;[\s\S]{0,220}border-radius: var\(--pet-surface-radius\);/,
  'The final empty-avatar surface must be rounded inside the transparent pet window');
assert.match(source, /#chatDock \{[\s\S]{0,320}right: var\(--pet-rail-reserve\);[\s\S]{0,320}border-radius: var\(--pet-surface-radius\);/,
  'Conversation shell must reserve the rail and expose one rounded outer surface');
assert.match(source, /#conversation \{[\s\S]{0,140}max-height: min\(31dvh, 280px, calc\(100dvh - 152px\)\);/,
  'Conversation history must use a compact content-driven cap with internal scrolling');
assert.match(source, /@media \(max-width: 520px\) \{[\s\S]{0,440}#emptyState \{[\s\S]{0,160}padding: 14px calc\(var\(--pet-rail-reserve\) - 6px\) 12px 12px;/,
  'Compact onboarding must preserve the shared right-rail clearance');
assert.match(source, /document\.getElementById\('emptyChat'\)\.addEventListener\('click', \(\) => openChat\(true\)\)/);
assert.match(source, /composer\.addEventListener\('pointerdown',[\s\S]{0,180}shell\.focusPetWindow\(\)/,
  'Clicking the composer must activate its transparent pet window before typing');

// Ordinary chat, hold-to-talk, explicit read-aloud, and the LiveKit room all
// stay on authenticated same-origin routes (Electron injects the auth header).
for (const route of ['/reply', '/stt', '/say', '/api/livekit/session']) {
  assert.ok(source.includes(`'${route}'`), `missing same-origin route ${route}`);
}
assert.match(source, /new library\.Room\(\{ adaptiveStream: true, dynacast: true \}\)/);
assert.match(source, /localParticipant\.setMicrophoneEnabled\(true\)/);
assert.match(source, /RoomEvent\.TranscriptionReceived/);
assert.match(source, /RoomEvent\.ParticipantDisconnected/);
assert.match(source, /agents\.length > 1/);
assert.match(source, /agents\.length === 0/);
assert.match(source, /more than one agent joined the call/);
assert.match(source, /waitForSoleAgent\(session/);
assert.match(source, /\/live-talk-connection\.wav/);
assert.match(source, /startConnectionSound\(session\)/);
assert.match(source, /stopConnectionSound\(session\)/);
assert.match(source, /room\.disconnect\(\)\.catch\(\(\) => \{\}\)/);
assert.match(source, /RoomEvent\.AudioPlaybackStatusChanged/);
assert.doesNotMatch(source, /room\.startAudio\(\)\.catch\(/,
  'Live Talk must not silently continue after speaker playback fails');
assert.match(source, /const liveTalkConnectionError = error => \{/);
assert.match(source, /detail\.includes\('livekit_selection_not_allowed'\)/);
assert.match(source, /This saved Live Talk combination is no longer supported\. Choose one approved option for each stage, then save Live Talk\./);
assert.match(source, /\\blivekit_\[a-z0-9_\]\+\\b\/i\.test\(detail\)/);
assert.match(source, /Live Talk could not connect\. Check the Live Talk choices and credentials in Settings, then try again\./);
assert.match(source, /notify\(liveTalkConnectionError\(error\)\)/);
assert.doesNotMatch(source, /notify\(`Live Talk could not connect: \$\{String\(error\.message/,
  'Live Talk must not expose backend machine codes as the recovery message');
assert.doesNotMatch(source, /createMediaElementSource\(element\)/,
  'A media-element source created before LiveKit assigns srcObject can meter silence');

// Exercise the remote-audio lifecycle itself. Receiving transcripts is not
// evidence that WebRTC audio is rendered: LiveKit must own an attached media
// element. A silent Web Audio monitor reads the exact remote MediaStreamTrack
// without rerouting or doubling that element's audible output, and is fully
// disconnected when the publication ends.
const releaseAudioSource = inline[1].match(
  /(const releaseAgentAudioAttachment = attachment => \{[\s\S]*?\n    \};)/,
);
const attachAudioSource = inline[1].match(
  /(const attachAgentAudio = \(session, track, participant\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(releaseAudioSource, 'remote-audio release helper must remain independently testable');
assert.ok(attachAudioSource, 'remote-audio attachment helper must remain independently testable');
const audioCalls = [];
const audioElements = [];
const audioAnalyser = { name: 'mouth-meter' };
class MediaStreamMock {
  constructor(tracks) { this.tracks = [...tracks]; }
  getTracks() { return [...this.tracks]; }
}
const documentMock = {
  body: { append: element => audioCalls.push(['append', element]) },
  createElement: kind => {
    assert.equal(kind, 'audio');
    const element = {
      autoplay: false,
      hidden: false,
      srcObject: { active: true },
      setAttribute: (...args) => audioCalls.push(['attribute', ...args]),
      pause: () => audioCalls.push(['pause', element]),
      remove: () => audioCalls.push(['remove', element]),
    };
    audioElements.push(element);
    return element;
  },
};
const sourceNode = {
  connect: node => audioCalls.push(['connect', node]),
  disconnect: () => audioCalls.push(['disconnect']),
};
const ensureAudioGraphMock = () => ({
  createMediaStreamSource: stream => {
    audioCalls.push(['media-stream-source', stream]);
    return sourceNode;
  },
});
const roomAudioReadyMock = session => audioCalls.push(['ready', session]);
const notifyMock = message => audioCalls.push(['notify', message]);
const audioSession = { audioAttachments: new Map() };
const remoteTrack = {
  sid: 'TR_audio',
  mediaStreamTrack: { id: 'browser-audio-track' },
  attach: element => audioCalls.push(['attach', element]),
  detach: element => audioCalls.push(['detach', element]),
};
const audioLifecycle = new Function(
  'document', 'MediaStream', 'ensureAudioGraph', 'audioAnalyser', 'notify', 'roomAudioReady', 'live',
  `'use strict'; ${releaseAudioSource[1]}; ${attachAudioSource[1]}; `
    + 'return { attachAgentAudio, releaseAgentAudioAttachment };',
)(documentMock, MediaStreamMock, ensureAudioGraphMock, audioAnalyser, notifyMock, roomAudioReadyMock, audioSession);
audioLifecycle.attachAgentAudio(audioSession, remoteTrack, { isAgent: true });
assert.equal(audioSession.audioAttachments.size, 1);
assert.equal(audioSession.audioAttachments.get('TR_audio').track, remoteTrack);
assert.equal(audioSession.audioAttachments.get('TR_audio').element, audioElements[0]);
assert.deepEqual(audioCalls.slice(1, 7).map(call => call[0]),
  ['append', 'attach', 'media-stream-source', 'connect', 'ready']);
const monitoredStream = audioSession.audioAttachments.get('TR_audio').stream;
assert.ok(monitoredStream instanceof MediaStreamMock);
assert.deepEqual(monitoredStream.getTracks(), [remoteTrack.mediaStreamTrack],
  'the mouth meter must receive the same remote track that LiveKit plays');
assert.deepEqual(audioCalls.find(call => call[0] === 'connect'), ['connect', audioAnalyser],
  'the remote monitor must feed the mouth analyser, not the speaker destination');
audioLifecycle.releaseAgentAudioAttachment(audioSession.audioAttachments.get('TR_audio'));
assert.equal(audioCalls.some(call => call[0] === 'detach'), true);
assert.equal(audioCalls.some(call => call[0] === 'disconnect'), true);
assert.equal(audioCalls.some(call => call[0] === 'pause'), true);
assert.equal(audioCalls.some(call => call[0] === 'remove'), true);
assert.equal(audioElements[0].srcObject, null);

// Live Talk lip sync must follow the samples in that attached playback path.
// Active-speaker notifications are a useful semantic hint, but arrive too late
// and too coarsely to drive a mouth; a wall-clock viseme carousel is unrelated
// to the phonetic rhythm the user actually hears.
const liveMouthSyncSource = source.match(
  /\/\* live-mouth-sync:start \*\/([\s\S]*?)\/\* live-mouth-sync:end \*\//,
);
assert.ok(liveMouthSyncSource, 'sample-driven Live Talk mouth helpers must remain independently testable');
const mouthSync = new Function(
  `'use strict'; ${liveMouthSyncSource[1]}; return { `
    + 'makeReactiveMouthState, measureAudioSignal, classifyAudioViseme, reactiveAudioViseme, '
    + 'makeLiveTalkAudioState, liveTalkAudioTransition, '
    + 'LIVE_MOUTH_RELEASE_MS, LIVE_MOUTH_DWELL_MS, LIVE_TALK_STATUS_RELEASE_MS };',
)();
const fullVisemes = ['sil', 'PP', 'FF', 'TH', 'DD', 'kk', 'CH', 'SS', 'nn', 'RR', 'aa', 'E', 'ih', 'oh', 'ou'];
const silentWave = new Uint8Array(1024).fill(128);
const lowVoiceWave = Uint8Array.from({ length: 1024 }, (_, index) =>
  128 + Math.round(20 * Math.sin(index * Math.PI / 8)));
const lowVoiceSpectrum = new Uint8Array(512);
lowVoiceSpectrum.fill(210, 2, 12);
const silentSignal = mouthSync.measureAudioSignal(silentWave, new Uint8Array(512), 48000);
const lowVoiceSignal = mouthSync.measureAudioSignal(lowVoiceWave, lowVoiceSpectrum, 48000);
assert.equal(silentSignal.rms, 0);
assert.ok(lowVoiceSignal.rms > .05, 'time-domain samples must produce a useful mouth envelope');
assert.ok(lowVoiceSignal.low > lowVoiceSignal.mid && lowVoiceSignal.low > lowVoiceSignal.high,
  'frequency bands must describe the sound currently reaching the Mac output');

const mouthState = mouthSync.makeReactiveMouthState();
const rounded = { ...lowVoiceSignal, rms: .03, relative: .8, low: .8, mid: .35, high: .1, centroid: .2, zcr: .03 };
const opened = mouthSync.reactiveAudioViseme(mouthState, rounded, 100, fullVisemes);
assert.notEqual(opened, 'sil', 'real playback energy must open the mouth immediately');
assert.equal(mouthSync.reactiveAudioViseme(mouthState, silentSignal, 120, fullVisemes), opened,
  'a sub-phoneme gap must not chatter the mouth shut');
assert.equal(
  mouthSync.reactiveAudioViseme(mouthState, silentSignal, 100 + mouthSync.LIVE_MOUTH_RELEASE_MS, fullVisemes),
  'sil',
  'the mouth must close on the audio envelope instead of waiting for active-speaker state',
);

// The same attached remote-audio samples own the Live Talk status lifecycle.
// A short mouth release keeps lip sync responsive, while a longer status
// release bridges ordinary phrase pauses and eventually restores connected.
const liveStatusState = mouthSync.makeLiveTalkAudioState();
assert.equal(mouthSync.liveTalkAudioTransition(liveStatusState, silentSignal, 0), null,
  'an attached but silent remote track must not claim the agent is speaking');
assert.equal(mouthSync.liveTalkAudioTransition(liveStatusState, rounded, 100), 'speaking',
  'audible remote playback must make speaking status immediate');
assert.equal(mouthSync.liveTalkAudioTransition(liveStatusState, silentSignal, 360), 'speaking',
  'a normal pause inside a phrase must not flicker back to connected');
assert.equal(
  mouthSync.liveTalkAudioTransition(liveStatusState, silentSignal, 100 + mouthSync.LIVE_TALK_STATUS_RELEASE_MS),
  'connected',
  'sustained remote silence must release a completed response back to connected',
);
assert.equal(mouthSync.liveTalkAudioTransition(liveStatusState, silentSignal, 900), null,
  'quiet connected frames must not overwrite other lifecycle status text');
assert.equal(liveStatusState.speaking, false);
const reducedVisemes = ['sil', 'FF', 'TH', 'nn', 'RR', 'aa', 'E', 'ih', 'ou'];
assert.equal(
  mouthSync.classifyAudioViseme({ relative: .55, low: .1, mid: .2, high: .7, centroid: .7, zcr: .2 }, reducedVisemes),
  'FF',
  'sample classification must degrade to an available light-avatar viseme',
);
assert.doesNotMatch(source, /Math\.floor\(now \/ 105\)/,
  'Live Talk must not rotate mouth shapes by unrelated wall-clock time');
assert.doesNotMatch(source, /ActiveSpeakersChanged[\s\S]{0,220}currentViseme = 'sil'/,
  'a delayed active-speaker packet must not override samples still being played');
assert.match(source, /audioAnalyser\.getByteFrequencyData\(audioFrequencyData\)/);
assert.match(source, /speechSource \|\| hasAttachedAgentAudio\(\)/);
assert.match(source, /if \(live\) syncLiveTalkAudioStatus\(live, now\)/,
  'the render loop must apply the exact samples measured for reactive visemes to Live Talk status');
assert.match(source, /live !== session \|\| session\.ending \|\| !session\.agentReady \|\| !session\.audioAttachments\.size/,
  'audio status must be scoped to an attached, ready, current Live Talk session');
assert.match(source, /RoomEvent\.ActiveSpeakersChanged[\s\S]{0,180}agentSpeaking = participants\.some\(participant => participant\.isAgent\)/,
  'LiveKit active-speaker semantics must continue to drive body expression independently');
assert.match(source, /RoomEvent\.Reconnecting[\s\S]{0,180}session\.agentReady = false;[\s\S]{0,180}Live Talk · reconnecting…/,
  'remote audio status must remain gated while the room is reconnecting');
assert.match(source, /function stopLiveTalk\(reason\) \{[\s\S]{0,100}live = null;[\s\S]{0,120}session\.ending = true;/,
  'stopping the call must invalidate audio status before attachments are released');
const transcriptSource = inline[1].match(
  /(const handleTranscript = \(session, segments, participant\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(transcriptSource, 'Live Talk transcript handler must remain independently inspectable');
assert.doesNotMatch(transcriptSource[1], /Live Talk · speaking/,
  'assistant interim text is not proof that remote audio is still playing');
assert.match(transcriptSource[1], /else if \(role === 'user'\)/,
  'user interim transcript feedback must remain visible');
assert.match(source, /audioMonitorGain\.gain\.value = 0/,
  'the shared analyser branch must remain inaudible while still being rendered');
assert.match(source, /source\.connect\(graph\.destination\)/,
  'regular timed speech must retain one explicit audible destination');

// A regular request must not create a second LLM/TTS lane while Live Talk owns
// the microphone and speaker. The composer keeps its text for after hang-up.
assert.match(source, /Hang up Live Talk before sending a regular chat message/);
assert.match(source, /Hang up Live Talk before playing a separate read-aloud voice/);
assert.match(source, /sendButton\.disabled = !composer\.value\.trim\(\) \|\| Boolean\(turnController\) \|\| Boolean\(live\)/);

// The calibrated face bank, body transform, pointer-aware gaze, and all three
// motion clips are consumed directly from the current runtime manifest.
for (const capability of [
  'assets/manifest.json',
  'manifest.body.face_transform',
  "['eyes', 'gaze', 'brow', 'cheek', 'eyebag']",
  "['walk', 'idle', 'move']",
  'manifest.eyes.states',
  'manifest.gaze.dxs',
  'manifest.brow.dys',
  'motionPlaybackProfile',
  'edge_anchors',
]) {
  assert.ok(source.includes(capability), `missing avatar runtime capability: ${capability}`);
}

// Horizon Walk and either Edge Idle road are avatar-only presentation states.
// A rendered frame is the authority: missing assets/failures restore the UI,
// and Moves deliberately keeps the controls visible.
assert.match(source, /html\.avatar-only-motion #rail[\s\S]{0,160}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /html\.avatar-only-motion #chatDock,[\s\S]{0,220}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /html\.avatar-only-motion #emptyState[\s\S]{0,160}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /transition-duration: 160ms;/);
assert.match(source, /@media \(prefers-reduced-motion: reduce\)[\s\S]{0,700}html\.avatar-only-motion #rail/);

const presentedMotionSource = inline[1].match(
  /(const drawPresentedMotion = \(kind, now, edge = null\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(presentedMotionSource, 'motion presentation classifier must remain independently testable');
const presentationStates = [];
const renderedKinds = new Map([['walk', true], ['idle', true], ['move', true], ['failed', false]]);
const drawPresentedMotion = new Function(
  'drawMotion', 'setAvatarOnlyMotion',
  `'use strict'; ${presentedMotionSource[1]}; return drawPresentedMotion;`,
)(kind => renderedKinds.get(kind) || false, active => presentationStates.push(Boolean(active)));
assert.equal(drawPresentedMotion('walk', 10), true);
assert.equal(drawPresentedMotion('idle', 20, 'left'), true);
assert.equal(drawPresentedMotion('move', 30), true);
assert.equal(drawPresentedMotion('failed', 40), false);
assert.deepEqual(presentationStates, [true, true, false, false],
  'only successfully rendered Walk/Idle frames may hide desktop chrome');

// Exercise a real sprite-backed Horizon Walk frame rather than accepting a
// stubbed true result as evidence. The main process phase chooses a different
// atlas cell and a successfully painted walk frame activates pure-alpha mode.
const motionFrameSource = inline[1].match(
  /(const motionFrame = \(clip, now, phase = null\) => \{[\s\S]*?\n    \};)/,
);
const drawMotionSource = inline[1].match(
  /(const drawMotion = \(kind, now, edge = null\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(motionFrameSource, 'sprite frame selector must remain independently testable');
assert.ok(drawMotionSource, 'motion painter must remain independently testable');
const paintedFrames = [];
const paintContext = {
  save() {}, restore() {}, setTransform() {}, translate() {}, scale() {},
  drawImage(...args) { paintedFrames.push(args); },
};
const walkSheet = { image: { name: 'walk-atlas' }, first: 0, count: 4, columns: 2, rows: 2 };
const walkMotion = {
  walk: {
    fps: 4, frames: 4, frame_width: 20, frame_height: 30,
    bounds: [0, 0, 20, 30], sheets: [walkSheet],
  },
};
const spritePainter = new Function(
  'motion', 'cameraFor', 'roamState', 'context', 'pixelRatio', 'innerWidth',
  `'use strict'; ${motionFrameSource[1]}; ${drawMotionSource[1]}; return drawMotion;`,
)(walkMotion, () => ({ x: 0, y: 0, scale: 1 }),
  { enabled: true, mode: 'walk', direction: 1, phase: 0.5 }, paintContext, 1, 200);
assert.equal(spritePainter('walk', 0), true);
assert.equal(paintedFrames.length, 1);
assert.deepEqual(paintedFrames[0].slice(1, 5), [0, 30, 20, 30],
  'phase 0.5 must paint atlas frame 2, not leave the standing plate onscreen');
const successfulWalkChrome = [];
const successfulWalk = new Function(
  'drawMotion', 'setAvatarOnlyMotion',
  `'use strict'; ${presentedMotionSource[1]}; return drawPresentedMotion;`,
)(spritePainter, active => successfulWalkChrome.push(active));
assert.equal(successfulWalk('walk', 0), true);
assert.deepEqual(successfulWalkChrome, [true],
  'a successfully painted Horizon Walk frame must suppress the chrome');

// A real hover pauses screen travel in `stand`, but it remains part of the
// Horizon Walk presentation: hold the current atlas frame and keep chrome
// hidden. Edge ledges retain their dedicated idle clip.
const roamMotionKindSource = inline[1].match(
  /(const roamMotionKind = \(mode, presentationMode = null\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(roamMotionKindSource, 'roam presentation mode classifier must remain independently testable');
const roamMotionKind = new Function(
  `'use strict'; ${roamMotionKindSource[1]}; return roamMotionKind;`,
)();
assert.equal(roamMotionKind('walk'), 'walk');
assert.equal(roamMotionKind('stand'), 'walk',
  'hover pause must hold a Walk frame instead of restoring the static avatar');
assert.equal(roamMotionKind('stand', 'ledge-left'), 'idle',
  'hover pause at the left ledge must hold Edge Idle, not switch to Walk');
assert.equal(roamMotionKind('stand', 'ledge-right'), 'idle',
  'hover pause at the right ledge must hold Edge Idle, not switch to Walk');
assert.equal(roamMotionKind('ledge-left'), 'idle');
assert.equal(roamMotionKind('ledge-right'), 'idle');
assert.equal(roamMotionKind('idle'), null);
assert.match(source, /if \(roamState\.enabled\) \{[\s\S]{0,360}const kind = roamMotionKind\(roamState\.mode, roamState\.presentationMode\);[\s\S]{0,220}drawPresentedMotion\(kind, now, roamState\.edge \|\| side\)/,
  'every enabled roam mode must pass through the avatar-only motion presenter');

// Chat and rail hit areas are hidden presentation chrome, not reasons to pin
// the roaming engine in `stand`. Only the painted avatar (or active audio)
// may engage it after Horizon Walk has been requested.
const engagementSource = inline[1].match(
  /(function syncPetEngagement\(\) \{[\s\S]*?\n    \})/,
);
assert.ok(engagementSource, 'roam engagement policy must remain independently testable');
const engagementCalls = [];
const engagementRoot = { classList: { contains: name => name === 'chat-open' } };
const engagement = new Function(
  'shell', 'roamState', 'shellState', 'root', 'avatarHit', 'ptt', 'speechSource',
  'agentSpeaking',
  `'use strict'; let petEngaged = false; ${engagementSource[1]}; `
    + 'return { syncPetEngagement, value: () => petEngaged };',
)(
  { setPetEngaged: value => engagementCalls.push(value) },
  { enabled: true, mode: 'walk' }, { pet: { roam: true } }, engagementRoot,
  false, null, null, false,
);
engagement.syncPetEngagement();
assert.deepEqual(engagementCalls, [],
  'an open-but-hidden composer must not immediately stop Horizon Walk');

const updateHitSource = inline[1].match(
  /(function updateHit\(force\) \{[\s\S]*?\n    \})\n\n    function syncPetEngagement/,
);
assert.ok(updateHitSource, 'figure/chrome hit classifier must remain independently testable');
const hitCalls = [];
const hoverClasses = [];
const hitClassifier = new Function(
  'shell', 'overControls', 'pointer', 'ready', 'innerWidth', 'innerHeight',
  'context', 'pixelRatio', 'root', 'markActivity', 'performance',
  `'use strict'; let dragging = false; let ptt = null; let avatarHit = false; `
    + `let petHit = false; let lastHitSent = 0; ${updateHitSource[1]}; `
    + 'return { updateHit, avatar: () => avatarHit };',
)(
  { setPetHit: value => hitCalls.push(value) }, () => true,
  { x: 50, y: 50, inside: true }, true, 100, 100,
  { getImageData: () => ({ data: [0, 0, 0, 255] }) }, 1,
  { classList: { toggle: (name, active) => hoverClasses.push([name, active]) } },
  () => {}, { now: () => 1000 },
);
hitClassifier.updateHit(true);
assert.deepEqual(hitCalls, [true], 'visible chrome must remain clickable');
assert.equal(hitClassifier.avatar(), false,
  'hovering a rail/composer control must not masquerade as avatar engagement');
assert.deepEqual(hoverClasses, [['avatar-hover', false]]);
assert.match(source, /if \(!ready\) \{ setAvatarOnlyMotion\(false\); return; \}/);
assert.match(source, /setAvatarOnlyMotion\(false\);\n      drawAvatar\(now\);/,
  'manual stop, natural end, and failed motion must return to the regular avatar surface');
assert.match(source, /if \(avatarOnlyMotion\) return \[\];/,
  'hidden chrome must leave shell hit-testing and control rectangles immediately');

// Exercise focus/inert lifecycle with a draft in the real composer helper.
// Text and selection survive, duplicate frames are idempotent, and focus is
// restored only on the first frame after presentation has genuinely ended.
const presentationLifecycleSource = inline[1].match(
  /(const motionChrome = \[statusLine, rail, chatDock, emptyState, toast\];[\s\S]*?\n    \};)\n\n    const openChat/,
);
assert.ok(presentationLifecycleSource, 'avatar-only lifecycle helper must remain independently testable');
const presentationClasses = new Set(['chat-open']);
const presentationRoot = {
  classList: {
    contains: name => presentationClasses.has(name),
    toggle: (name, active) => active ? presentationClasses.add(name) : presentationClasses.delete(name),
  },
};
const presentationChrome = Array.from({ length: 5 }, () => ({ inert: false }));
const composerDraft = {
  value: 'unfinished draft',
  selectionStart: 2,
  selectionEnd: 9,
  selectionDirection: 'forward',
  blurCalls: 0,
  focusCalls: 0,
  blur() { this.blurCalls += 1; presentationDocument.activeElement = null; },
  focus() { this.focusCalls += 1; presentationDocument.activeElement = this; },
  setSelectionRange(start, end, direction) { this.restoredSelection = [start, end, direction]; },
};
const presentationDocument = { activeElement: composerDraft, querySelectorAll: () => [] };
const scheduledFocus = [];
const controlReports = [];
const cancelledRecordings = [];
const presentationLifecycle = new Function(
  'root', 'statusLine', 'rail', 'chatDock', 'emptyState', 'toast', 'composer', 'document',
  'requestAnimationFrame', 'reportControlRects', 'stopRecording', 'initialPtt',
  `'use strict'; let avatarOnlyMotion = false; let composerFocusBeforeMotion = null; let ptt = initialPtt; `
    + `${presentationLifecycleSource[1]}; return { setAvatarOnlyMotion, active: () => avatarOnlyMotion };`,
)(
  presentationRoot, ...presentationChrome, composerDraft, presentationDocument,
  callback => scheduledFocus.push(callback), force => controlReports.push(force),
  cancel => cancelledRecordings.push(cancel), { recording: true },
);
presentationLifecycle.setAvatarOnlyMotion(true);
assert.equal(presentationLifecycle.active(), true);
assert.equal(presentationClasses.has('avatar-only-motion'), true);
assert.equal(presentationChrome.every(element => element.inert), true);
assert.equal(composerDraft.blurCalls, 1);
assert.equal(composerDraft.value, 'unfinished draft');
assert.deepEqual(cancelledRecordings, [true]);
assert.deepEqual(controlReports, [true]);
presentationLifecycle.setAvatarOnlyMotion(true);
assert.deepEqual(controlReports, [true], 'looping animation frames must not repeat lifecycle effects');
presentationLifecycle.setAvatarOnlyMotion(false);
assert.equal(presentationChrome.every(element => !element.inert), true);
assert.equal(composerDraft.focusCalls, 0, 'focus must wait until after motion has ended');
assert.equal(scheduledFocus.length, 1);
scheduledFocus.shift()();
assert.equal(composerDraft.focusCalls, 1);
assert.deepEqual(composerDraft.restoredSelection, [2, 9, 'forward']);
assert.equal(composerDraft.value, 'unfinished draft');
assert.match(source, /if \(avatarOnlyMotion\) \{ event\.preventDefault\(\); return; \}/);
assert.match(source, /async function startRecording\(\) \{\n      if \(avatarOnlyMotion \|\| ptt \|\| live \|\| turnController\) return;/);

// Transparent-window behavior stays explicit and bounded to local shell APIs.
for (const bridge of [
  'onPetPointer',
  'onPetRoamMotion',
  'onPetMoves',
  'setPetControlRects',
  'setPetHit',
  'setPetEngaged',
  'beginPetDrag',
  'movePetDrag',
  'endPetDrag',
  'showPetMenu',
]) {
  assert.ok(source.includes(bridge), `missing desktop shell bridge: ${bridge}`);
}

// The sole Live Talk tool is review-only: exact schema, caller/session/final
// transcript checks, replay defense, and two local actions with no send path.
assert.match(source, /openclam\.prepareEmailDraft\.v1/);
assert.match(source, /exactObject\(rootValue, \['schema_version', 'request_id', 'spoken_request', 'tool'\]\)/);
assert.match(source, /agents\[0\]\.identity === invocation\.callerIdentity/);
assert.match(source, /session\.latestFinalUserTranscript/);
assert.match(source, /waitForMatchingFinalUserTurn/);
assert.match(source, /Math\.min\(5000, Math\.max\(0, timeout - 1500\)\)/);
assert.match(source, /!trustedEmailInvocation\(session, invocation, timeout\)/);
assert.match(source, /replayedEmailRequests\.has\(request\.request_id\)/);
assert.match(source, /warning\.textContent = 'Unsent/);
assert.match(source, /keep\.textContent = 'Keep in chat'/);
assert.match(source, /copy\.textContent = 'Copy draft'/);
assert.doesNotMatch(source, /prepareEmailDraft[\s\S]{0,9000}(openURL|sendMail|sendEmail|mailClient)/i);

// Exercise the renderer's own fail-closed wording policy instead of copying it
// into this test. Quoted, negated, and reported requests cannot stage a draft.
const emailPolicy = inline[1].match(
  /(const canonicalWords =[\s\S]*?const explicitEmailRequest =[\s\S]*?\n    };)\n\n    const exactObject/,
);
assert.ok(emailPolicy, 'email authorization policy must remain independently testable');
const explicitEmailRequest = new Function(
  `'use strict'; ${emailPolicy[1]}; return explicitEmailRequest;`,
)();
assert.equal(explicitEmailRequest('Email Emma', 'Emma'), true);
assert.equal(explicitEmailRequest('Please write an email to Emma about lunch', 'Emma'), true);
for (const unsafeRequest of [
  '“Email Emma”',
  'Email Emma, no',
  'Email Emma, she said',
  "Email Emma, but I can't",
  "Don't email Emma",
  'Read email Emma',
]) {
  assert.equal(
    explicitEmailRequest(unsafeRequest, 'Emma'),
    false,
    `unsafe email wording accepted: ${unsafeRequest}`,
  );
}

// LiveKit can deliver one spoken turn as several independently-final segments.
// The RPC must bind against their authoritative joined turn, then reset after
// the assistant closes that turn instead of trusting only the last fragment.
const turnAssembly = inline[1].match(
  /(const appendFinalUserTurnSegment = \(session, text\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(turnAssembly, 'final user turn assembly helper must remain independently testable');
const appendFinalUserTurnSegment = new Function(
  `'use strict'; ${turnAssembly[1]}; return appendFinalUserTurnSegment;`,
)();
const splitTurn = { finalUserTurnSegments: [], userTurnOpen: false, latestFinalUserTranscript: '' };
for (const segment of ['Email Emma', 'Subject.', 'Project update.', 'Message,', 'please review the schedule.']) {
  appendFinalUserTurnSegment(splitTurn, segment);
}
assert.equal(
  splitTurn.latestFinalUserTranscript,
  'Email Emma Subject. Project update. Message, please review the schedule.',
);
splitTurn.userTurnOpen = false;
appendFinalUserTurnSegment(splitTurn, 'Yes, send it.');
assert.equal(splitTurn.latestFinalUserTranscript, 'Yes, send it.');

// Keyboard and assistive labels cover the main desktop verbs.
assert.match(source, /event\.metaKey \|\| event\.ctrlKey/);
assert.match(source, /event\.code === 'Space'/);
assert.match(source, /event\.key === 'Escape'/);
assert.match(source, /aria-label="Hold to talk"/);
assert.match(source, /aria-label="Message"/);
assert.match(source, /prefers-reduced-motion/);

console.log('OpenClam desktop renderer QA passed');
