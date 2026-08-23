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

// The old rail chat shortcut is now a local avatar carousel. Chat/PTT remains
// discoverable before an avatar exists through the canvas/menu and the empty
// card, without creating another Live Talk surface.
assert.equal((source.match(/id="avatarCarouselButton"/g) || []).length, 1);
assert.equal((source.match(/id="chatButton"/g) || []).length, 0);
assert.equal((source.match(/id="emptyChat"/g) || []).length, 1);
assert.match(source, /aria-label="Switch to next avatar"/);
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
const opaqueChatDockRule = [...source.matchAll(/#chatDock\s*\{([^}]+)\}/g)]
  .map(match => match[1])
  .find(rule => rule.includes('rgba(24, 24, 24, .985)'));
assert.ok(opaqueChatDockRule, 'final chat dock surface rule must remain identifiable');
assert.match(opaqueChatDockRule, /-webkit-backdrop-filter:\s*none;/);
assert.match(opaqueChatDockRule, /backdrop-filter:\s*none;/);
assert.match(opaqueChatDockRule, /box-shadow:\s*none;/,
  'transparent Electron windows must not draw a square filter or shadow halo around the rounded dock');
assert.match(source, /#conversation \{[\s\S]{0,140}max-height: min\(31dvh, 280px, calc\(100dvh - 152px\)\);/,
  'Conversation history must use a compact content-driven cap with internal scrolling');
assert.match(source, /@media \(max-width: 520px\) \{[\s\S]{0,440}#emptyState \{[\s\S]{0,160}padding: 14px calc\(var\(--pet-rail-reserve\) - 6px\) 12px 12px;/,
  'Compact onboarding must preserve the shared right-rail clearance');
assert.match(source, /document\.getElementById\('emptyChat'\)\.addEventListener\('click', \(\) => openChat\(true\)\)/);
assert.match(source, /composer\.addEventListener\('pointerdown',[\s\S]{0,180}shell\.focusPetWindow\(\)/,
  'Clicking the composer must activate its transparent pet window before typing');
const persistentSecondaryRule = [...source.matchAll(/html\.pet-mode #rail \.secondary\s*\{([^}]+)\}/g)]
  .map(match => match[1]).at(-1);
assert.ok(persistentSecondaryRule, 'normal pet mode must define persistent Moves and Walk controls');
assert.match(persistentSecondaryRule, /opacity:\s*1;/);
assert.match(persistentSecondaryRule, /visibility:\s*visible;/);
assert.match(persistentSecondaryRule, /pointer-events:\s*auto;/);
assert.doesNotMatch(source, /html\.pet-mode(?:[^\n{]*) #rail \.secondary\s*\{[^}]*opacity:\s*0;/,
  'normal pet mode must not fade the secondary rail buttons out');

const avatarCarouselSource = inline[1].match(
  /(const avatarCarouselCandidates = listing =>[\s\S]*?\n    };)\n\n    const setAvatarCarouselAvailability/,
);
assert.ok(avatarCarouselSource, 'avatar carousel ordering must remain independently testable');
const avatarCarousel = new Function(
  `'use strict'; ${avatarCarouselSource[1]}; return { avatarCarouselCandidates, nextAvatarInCarousel };`,
)();
const avatarListing = {
  active: 'ara', companion: 'ayer',
  avatars: [
    { slug: 'draft', status: 'draft', has_runtime: true },
    { slug: 'broken', status: 'ready', has_runtime: false },
    { slug: 'george', name: 'George', status: 'ready', has_runtime: true },
    { slug: 'ayer', name: 'Ayer', status: 'ready', has_runtime: true },
    { slug: 'ara', name: 'Ara', status: 'ready', has_runtime: true },
  ],
};
assert.deepEqual(
  avatarCarousel.avatarCarouselCandidates(avatarListing).map(avatar => avatar.slug),
  ['ara', 'ayer', 'george'],
  'only complete ready runtimes may enter the deterministic carousel',
);
assert.equal(avatarCarousel.nextAvatarInCarousel(avatarListing).slug, 'ayer');
assert.equal(avatarCarousel.nextAvatarInCarousel(
  { ...avatarListing, active: 'george' },
).slug, 'ara', 'the primary carousel must wrap');
assert.equal(avatarCarousel.nextAvatarInCarousel(avatarListing, true).slug, 'george',
  'the companion carousel must skip the primary avatar');
assert.equal(avatarCarousel.nextAvatarInCarousel({
  active: 'ara', avatars: [{ slug: 'ara', status: 'ready', has_runtime: true }],
}), null, 'a carousel with no alternative must disable itself');
assert.match(source, /const path = isCompanion \? '\/api\/avatar\/companion' : '\/api\/avatar\/activate';/);
assert.match(source, /const changed = isCompanion \? shell\.companionChanged : shell\.avatarChanged;/);
assert.equal((source.match(/avatarCarouselButton\.addEventListener\('click', cycleAvatar\)/g) || []).length, 1);
assert.doesNotMatch(source, /avatarCarouselButton\.addEventListener\('click',[\s\S]{0,100}openChat/,
  'the replacement carousel control must not retain the old chat action');

// Ordinary chat, hold-to-talk, explicit read-aloud, and the LiveKit room all
// stay on authenticated same-origin routes (Electron injects the auth header).
for (const route of ['/reply', '/stt', '/say', '/api/livekit/session']) {
  assert.ok(source.includes(`'${route}'`), `missing same-origin route ${route}`);
}
for (const route of ['/api/openclaw/agents', '/api/openclaw/turn']) {
  assert.ok(source.includes(`'${route}'`), `missing same-origin OpenClaw route ${route}`);
}
assert.equal((source.match(/id="agentModeSelect"/g) || []).length, 1);
assert.match(source, /async function submitTurn\(text\)[\s\S]{0,260}selectedOpenClawAgent\(\)/,
  'the Mac composer must switch between local and OpenClaw agents without changing screens');
assert.match(source, /const createWorkTimeline = \(\) =>/);
assert.match(source, /event\.type === 'work'[\s\S]{0,100}updateWorkTimeline/);
assert.match(source, /event\.type === 'attachment'[\s\S]{0,120}appendOpenClawAttachment/);
assert.match(source, /textContent = step\.title/,
  'work details must use text nodes rather than executable markup');
assert.doesNotMatch(source, /innerHTML\s*=\s*step\./,
  'OpenClaw work updates must never write untrusted HTML');
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

// Agent feedback is first-class Mac text: native selection remains enabled,
// every complete response exposes whole-entry Copy and Read Aloud, and a
// partial selection can be copied or quoted into the existing composer. Ask
// AI must prepare a draft only; it never starts a turn on the user's behalf.
assert.match(source, /\.bubble \{[\s\S]{0,360}unicode-bidi: plaintext;[\s\S]{0,120}user-select: text;/);
assert.match(source, /id="composer"[^>]*maxlength="12000"[^>]*dir="auto"/);
assert.match(source, /id="selectionActions" role="toolbar" aria-label="Selected response actions"/);
assert.match(source, /id="selectionCopy"[^>]*>Copy<\/button>/);
assert.match(source, /id="selectionAskAI"[^>]*aria-keyshortcuts="Meta\+Shift\+A Control\+Shift\+A">Ask AI<\/button>/);
assert.match(source, /role === 'assistant' && text && options\.readable !== false[\s\S]{0,1500}'Copy this response'[\s\S]{0,1500}'Read this response aloud'/);
assert.match(source, /conversation\.addEventListener\('contextmenu',[\s\S]{0,220}feedbackSelectionCandidate\(getSelection\(\)\)[\s\S]{0,220}showSelectionActions\(candidate\)/);
assert.match(source, /navigator\.clipboard[\s\S]{0,180}navigator\.clipboard\.writeText\(text\)/);
assert.match(source, /document\.execCommand\('copy'\)/,
  'copy must retain a selection-preserving fallback when Clipboard permission is unavailable');
assert.match(source, /Selected text copied\./);
assert.match(source, /Selection added\. Add your question, then send\./);

const responseDraftSource = inline[1].match(
  /(const safeUTF16Prefix =[\s\S]*?const selectionToolbarPoint =[\s\S]*?\n    \};)\n\n    const feedbackSelectionCandidate/,
);
assert.ok(responseDraftSource, 'selected-response draft helpers must remain independently testable');
const responseDraft = new Function(
  `'use strict'; ${responseDraftSource[1]}; return { `
    + 'safeUTF16Prefix, formatSelectedFeedback, composeAskAIDraft, selectionToolbarPoint };',
)();

const multilingualSelection = '第一行：保留中文。\nمرحبا بالعالم 👩🏽‍💻';
assert.deepEqual(
  responseDraft.formatSelectedFeedback(multilingualSelection),
  {
    text: '> 第一行：保留中文。\n> مرحبا بالعالم 👩🏽‍💻\n\nAsk about this selection: ',
    truncated: false,
  },
  'CJK, RTL, emoji, and line boundaries must survive quoting exactly',
);
const preservedDraft = responseDraft.composeAskAIDraft(
  'Keep my existing draft.', multilingualSelection, 12000,
);
assert.equal(preservedDraft.inserted, true);
assert.equal(preservedDraft.truncated, false);
assert.ok(preservedDraft.value.startsWith('Keep my existing draft.\n\n> 第一行'));
assert.ok(preservedDraft.value.endsWith('Ask about this selection: '));
assert.ok(responseDraft.composeAskAIDraft('Existing\n\n', 'selected').value
  .startsWith('Existing\n\n> selected'),
  'an existing paragraph break must not grow every time Ask AI is used');

const longSelection = `${'内容🙂مرحبا '.repeat(2000)}final`;
const boundedDraft = responseDraft.composeAskAIDraft('Existing', longSelection, 256);
assert.equal(boundedDraft.inserted, true);
assert.equal(boundedDraft.truncated, true);
assert.ok(boundedDraft.value.length <= 256,
  'the quoted selection must respect the real textarea maxlength');
assert.match(boundedDraft.value, /\n> …\n\nAsk about this selection: $/);
assert.doesNotMatch(boundedDraft.value, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/,
  'long selection clipping must never leave a broken UTF-16 surrogate');
assert.deepEqual(
  responseDraft.composeAskAIDraft('x'.repeat(12000), 'selected', 12000),
  { value: 'x'.repeat(12000), inserted: false, truncated: true },
  'a full draft must remain byte-for-byte unchanged instead of silently deleting text',
);

assert.deepEqual(
  responseDraft.selectionToolbarPoint(
    { left: 120, right: 180, top: 100, bottom: 120 },
    { width: 100, height: 30 },
    { left: 50, top: 50, width: 300, height: 200 },
  ),
  { x: 50, y: 12 },
);
assert.deepEqual(
  responseDraft.selectionToolbarPoint(
    { left: -200, right: -100, top: 52, bottom: 70 },
    { width: 100, height: 30 },
    { left: 50, top: 50, width: 300, height: 200 },
  ),
  { x: 8, y: 28 },
  'the contextual toolbar must stay inside a compact pet window',
);

const askSelectedSource = inline[1].match(
  /(const askAIAboutSelectedFeedback = \(\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(askSelectedSource, 'Ask AI selection behavior must remain inspectable');
assert.match(askSelectedSource[1], /composer\.value = drafted\.value/);
assert.match(askSelectedSource[1], /composer\.setSelectionRange\(composer\.value\.length, composer\.value\.length\)/);
assert.doesNotMatch(askSelectedSource[1], /submitTurn|submitComposer|postJSON|dispatchEvent/,
  'Ask AI may fill and focus the composer but must never send automatically');

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

// Brows and the infraorbital band must be speech-coupled independently of
// lip sync. The motion scheduler picks held, eased random targets rather than
// frame-by-frame noise, and it collapses to a stable face for reduced motion.
const speechExpressionSource = inline[1].match(
  /(const speechExpressionAt = \(now, speaking, state, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(speechExpressionSource,
  'upper-face speech scheduler must remain independently testable');
const randomValues = [.1, .3, .7, .2, .8, .4, .6, .5];
let randomIndex = 0;
const deterministicMath = Object.create(Math);
deterministicMath.random = () => randomValues[randomIndex++ % randomValues.length];
const speechExpressionAt = new Function(
  'Math',
  `'use strict'; ${speechExpressionSource[1]}; return speechExpressionAt;`,
)(deterministicMath);
const upperFaceState = {
  mode: 'idle', started: 0, duration: 1, nextAt: 0,
  from: { brow: 0, underEye: 0, squeeze: 0, asymmetry: 0 },
  to: { brow: 0, underEye: 0, squeeze: 0, asymmetry: 0 },
  value: { brow: 0, underEye: 0, squeeze: 0, asymmetry: 0 },
};
assert.deepEqual(
  speechExpressionAt(0, true, upperFaceState, true),
  { brow: 0, underEye: 0, squeeze: 0, asymmetry: 0 },
  'reduced motion must hold upper-face layers still even during speech',
);
speechExpressionAt(0, true, upperFaceState, false);
const firstUpperFace = speechExpressionAt(420, true, upperFaceState, false);
assert.ok(firstUpperFace.brow > 0 && firstUpperFace.underEye > 0,
  'speech must animate both brow and under-eye targets');
speechExpressionAt(1100, true, upperFaceState, false);
const laterUpperFace = speechExpressionAt(1200, true, upperFaceState, false);
assert.notEqual(laterUpperFace.brow, firstUpperFace.brow,
  'upper-face phrase targets must vary instead of looping mechanically');
speechExpressionAt(1600, false, upperFaceState, false);
assert.deepEqual(
  speechExpressionAt(2000, false, upperFaceState, false),
  { brow: 0, underEye: 0, squeeze: 0, asymmetry: 0 },
  'upper-face speech motion must settle back to a still idle state',
);
assert.match(source, /const LIVE_RIG_KEY = 'openclam-live-rig';/,
  'the calibration panel must be able to preview live brow/under-eye targets');
assert.match(source, /for \(const key of \['brows', 'eyebags'\]\)/);
assert.match(source, /const eyebagGain = rigExpressionGain\('eyebags', 35, 35\);/);
assert.match(source, /const upperFaceSpeaking = speaking && !reducedMotion\.matches;/);

// Reduced Motion covers the decorative blink path as well as speech targets:
// otherwise the blink-fed under-eye strip continues animating even though the
// speech scheduler is correctly still.  The next blink stays deferred while
// the preference is active, so opting back in cannot resume half a blink.
const blinkAmountSource = inline[1].match(
  /(const blinkAmount = \(now, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(blinkAmountSource, 'blink helper must expose a reduced-motion gate');
const blinkProbe = new Function(
  'Math',
  `'use strict'; let blinkStartedAt = 0; let nextBlinkAt = 0; ${blinkAmountSource[1]};`
    + 'return { blinkAmount, state: () => ({ blinkStartedAt, nextBlinkAt }) };',
)(deterministicMath);
assert.equal(blinkProbe.blinkAmount(100, true), 0,
  'Reduced Motion must suppress a pending eyelid/under-eye blink');
assert.equal(blinkProbe.state().blinkStartedAt, 0);
assert.ok(blinkProbe.state().nextBlinkAt >= 1100,
  'Reduced Motion must defer rather than preserve an in-progress blink');
assert.equal(blinkProbe.blinkAmount(200, true), 0);
assert.ok(blinkProbe.state().nextBlinkAt >= 1200);
assert.match(source, /const blink = blinkAmount\(now, reducedMotion\.matches\);/,
  'the face compositor must pass the preference into the blink/under-eye path');

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
const motionPhaseAtSource = inline[1].match(
  /(const motionPhaseAt = \(state, clip, epochMs\) => \{[\s\S]*?\n    \};)/,
);
const motionFrameSource = inline[1].match(
  /(const motionFrame = \(clip, now, phase = null\) => \{[\s\S]*?\n    \};)/,
);
const beginMotionPresentationSource = inline[1].match(
  /(const beginMotionPresentation = \(kind, edge, clip\) => \{[\s\S]*?\n    \};)/,
);
const idleVideoFramesSource = inline[1].match(
  /(const idleVideoFrames = \(clip, frozen = false\) => \{[\s\S]*?\n    \};)/,
);
const drawMotionSource = inline[1].match(
  /(const drawMotion = \(kind, now, edge = null\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(motionPhaseAtSource, 'Walk phase clock must remain independently testable');
assert.ok(motionFrameSource, 'sprite frame selector must remain independently testable');
assert.ok(beginMotionPresentationSource, 'motion entry/reset helper must remain independently testable');
assert.ok(idleVideoFramesSource, 'Edge Idle seam handoff must remain independently testable');
assert.ok(drawMotionSource, 'motion painter must remain independently testable');
const motionPhaseAt = new Function(
  `'use strict'; ${motionPhaseAtSource[1]}; return motionPhaseAt;`,
)();
const cadenceClip = {frames: 72, fps: 24, cycle_seconds: 3};
const cadenceState = {enabled: true, mode: 'walk', phase: 0, sampledAt: 1000};
assert.equal(Math.floor(motionPhaseAt(cadenceState, cadenceClip, 1042) * 72), 1);
assert.equal(Math.floor(motionPhaseAt(cadenceState, cadenceClip, 1084) * 72), 2,
  'the renderer must advance a 24fps Walk between IPC phase packets');
assert.equal(motionPhaseAt({...cadenceState, mode: 'stand'}, cadenceClip, 1084), 0,
  'hover pause must freeze the exact held Walk phase');
assert.ok(Math.abs(motionPhaseAt(
  {...cadenceState, phase: .99}, cadenceClip, 1200) - (7 / 300)) < 1e-9,
  'phase extrapolation must wrap and cap stale IPC packets safely');

// With phase packets arriving only every 32ms, the local clock must still
// present every atlas cell in order at a 60Hz display cadence. A 24fps frame
// naturally occupies two or three display refreshes—never one or four.
const cadenceFrames = [];
for (let refresh = 0; refresh <= 180; refresh += 1) {
  const epoch = 1000 + refresh * (1000 / 60);
  const packetAt = 1000 + Math.floor((epoch - 1000) / 32) * 32;
  const state = {
    enabled: true, mode: 'walk', sampledAt: packetAt,
    phase: ((packetAt - 1000) / 3000) % 1,
  };
  cadenceFrames.push(Math.floor(motionPhaseAt(state, cadenceClip, epoch) * 72) % 72);
}
for (let index = 1; index < cadenceFrames.length; index += 1) {
  const delta = (cadenceFrames[index] - cadenceFrames[index - 1] + 72) % 72;
  assert.ok(delta === 0 || delta === 1,
    `Walk frame sequence must never reverse or skip (delta ${delta})`);
}
const completeRuns = [];
for (let index = 0; index < cadenceFrames.length;) {
  let end = index + 1;
  while (end < cadenceFrames.length && cadenceFrames[end] === cadenceFrames[index]) end += 1;
  if (index > 0 && end < cadenceFrames.length) completeRuns.push(end - index);
  index = end;
}
assert.ok(completeRuns.every(length => length === 2 || length === 3),
  `24fps frame holds at 60Hz must be 2–3 refreshes, got ${completeRuns}`);
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
  'motionPhaseAt', 'beginMotionPresentation', 'clearStage',
  `'use strict'; let paintedMotionKey = ''; ${motionFrameSource[1]}; ${drawMotionSource[1]}; return drawMotion;`,
)(walkMotion, () => ({ x: 0, y: 0, scale: 1 }),
  { enabled: true, mode: 'walk', direction: 1, phase: 0.5, sampledAt: performance.timeOrigin },
  paintContext, 1, 200, motionPhaseAt, kind => `${kind}:`, () => {});
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

// Moves remains one-shot, but Edge Idle continuously hands off between two
// one-shot decoders. Eight 12fps frames dissolve the bad endpoint seam and the
// outgoing decoded frame covers the incoming seek, so neither a jump nor a
// blank standing plate can flash.
assert.match(source, /video\.loop = false;/);
assert.match(source, /const IDLE_SEAM_BLEND_SECONDS = 2 \/ 3;/);
assert.match(source, /if \(kind === 'idle' && loaded\.video\)[\s\S]{0,900}loaded\.loopVideo = loopVideo;/);
assert.match(drawMotionSource[1], /idleVideoFrames\(clip, frozen\)/);
assert.match(drawMotionSource[1], /clip\.video\.paused && !clip\.video\.ended/,
  'an ended Move must never auto-replay');
assert.match(drawMotionSource[1], /roamState\.enabled && roamState\.mode === 'stand'/,
  'hovering a ledge must freeze its decoded Edge Idle frame');
assert.match(drawMotionSource[1], /clip\.posterImage/,
  'a decoded poster must cover presentation-entry seek latency');
const resetCalls = [];
const idleVideo = {
  paused: false,
  pause() { this.paused = true; resetCalls.push('pause'); },
  play() { this.paused = false; resetCalls.push('play'); return Promise.resolve(); },
  set currentTime(value) { this._currentTime = value; resetCalls.push(`seek:${value}`); },
  get currentTime() { return this._currentTime || 0; },
};
const idleClip = {video: idleVideo};
const presentationEntry = new Function(
  'motion',
  `'use strict'; let presentedMotionKey = ''; let paintedMotionKey = 'old'; `
    + `${beginMotionPresentationSource[1]}; return { beginMotionPresentation, state: () => ({presentedMotionKey, paintedMotionKey}) };`,
)({idle: idleClip});
presentationEntry.beginMotionPresentation('idle', 'left', idleClip);
presentationEntry.beginMotionPresentation('idle', 'left', idleClip);
assert.deepEqual(resetCalls, ['pause', 'seek:0', 'play'],
  'the same ledge must not restart Edge Idle on every paint');
presentationEntry.beginMotionPresentation('idle', 'right', idleClip);
assert.deepEqual(resetCalls, ['pause', 'seek:0', 'play', 'pause', 'seek:0', 'play'],
  'a new ledge presentation must deterministically restart from frame zero');

const clipVideos = clip => [clip && clip.video, clip && clip.loopVideo].filter(Boolean);
const idleVideoFrames = new Function(
  'IDLE_SEAM_BLEND_SECONDS', 'clipVideos',
  `'use strict'; ${idleVideoFramesSource[1]}; return idleVideoFrames;`,
)(2 / 3, clipVideos);
const seamCalls = [];
const seamVideo = name => ({
  name, duration: 6, readyState: 4, seeking: false, paused: true, ended: false,
  _currentTime: 0,
  pause() { this.paused = true; seamCalls.push(`${name}:pause`); },
  play() { this.paused = false; seamCalls.push(`${name}:play`); return Promise.resolve(); },
  set currentTime(value) { this._currentTime = value; seamCalls.push(`${name}:seek:${value}`); },
  get currentTime() { return this._currentTime; },
});
const seamA = seamVideo('a');
const seamB = seamVideo('b');
seamA.paused = false;
seamA._currentTime = 5.5;
const seamClip = {
  video: seamA, loopVideo: seamB,
  idlePlayback: {active: 0, fading: false, mix: 0},
};
assert.deepEqual(idleVideoFrames(seamClip).map(value => value.alpha), [1, 0],
  'the incoming decoder must begin invisibly over the outgoing decoded frame');
seamB._currentTime = 1 / 3;
assert.deepEqual(idleVideoFrames(seamClip).map(value => value.alpha), [.5, .5],
  'the bad seam must crossfade instead of jumping last-to-first');
seamB._currentTime = .66;
assert.deepEqual(idleVideoFrames(seamClip), [{video: seamB, alpha: 1}],
  'the warmed incoming decoder must become the sole active stream');
assert.equal(seamClip.idlePlayback.active, 1);
seamB._currentTime = 5.5;
idleVideoFrames(seamClip);
seamA._currentTime = .66;
assert.deepEqual(idleVideoFrames(seamClip), [{video: seamA, alpha: 1}],
  'Edge Idle must continue into a second seamless loop, not freeze');
assert.equal(seamClip.idlePlayback.active, 0);
idleVideoFrames(seamClip, true);
assert.ok(seamA.paused && seamB.paused,
  'hover pause must freeze both sides of a seam handoff');

let replayCalls = 0;
const endedVideo = {
  readyState: 4, seeking: false, paused: true, ended: true,
  play() { replayCalls += 1; return Promise.resolve(); },
  pause() {},
};
const endedPaints = [];
const endedContext = {
  save() {}, restore() {}, setTransform() {}, translate() {}, scale() {},
  drawImage(...args) { endedPaints.push(args); },
};
const endedPainter = new Function(
  'motion', 'cameraFor', 'roamState', 'context', 'pixelRatio', 'innerWidth',
  'motionPhaseAt', 'beginMotionPresentation', 'clearStage',
  `'use strict'; let paintedMotionKey = ''; ${motionFrameSource[1]}; ${drawMotionSource[1]}; return drawMotion;`,
)(
  {move: {video: endedVideo, fps: 12, frames: 73, frame_width: 20, frame_height: 30, bounds: [0, 0, 20, 30]}},
  () => ({x: 0, y: 0, scale: 1}),
  {enabled: true, mode: 'idle', direction: 1}, endedContext, 1, 200,
  motionPhaseAt, () => 'move:', () => {},
);
assert.equal(endedPainter('move', 7000), true);
assert.equal(endedPaints.length, 1, 'the final decoded Move frame must remain visible');
assert.equal(replayCalls, 0, 'the final decoded Move frame must not restart');

const motionFrameDelaySource = inline[1].match(
  /(const motionFrameDelay = \(clip, frozen = false\) => \{[\s\S]*?\n    \};)/,
);
const standbyFrameDelaySource = inline[1].match(
  /(const standbyFrameDelay = \(now, state = \{\}, onBattery = false\) => \{[\s\S]*?\n    \};)/,
);
const advanceFrameClockSource = inline[1].match(
  /(const advanceFrameClock = \(previous, now, delay\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(motionFrameDelaySource, 'source-frame cadence policy must remain independently testable');
assert.ok(standbyFrameDelaySource, 'standing cadence policy must remain independently testable');
assert.ok(advanceFrameClockSource, 'fractional render clock must remain independently testable');
const motionFrameDelay = new Function(
  `'use strict'; ${motionFrameDelaySource[1]}; return motionFrameDelay;`,
)();
const standbyFrameDelay = new Function(
  'STANDBY_GAZE_SETTLE_MS', 'STANDBY_MAINTENANCE_MS',
  `'use strict'; ${standbyFrameDelaySource[1]}; return standbyFrameDelay;`,
)(420, 250);
const advanceFrameClock = new Function(
  `'use strict'; ${advanceFrameClockSource[1]}; return advanceFrameClock;`,
)();
assert.ok(Math.abs(motionFrameDelay({fps: 24}) - (1000 / 24)) < 1e-9,
  'Horizon Walk must paint at its 24fps source cadence, not duplicate at 60fps');
assert.ok(Math.abs(motionFrameDelay({fps: 12}) - (1000 / 12)) < 1e-9,
  'Edge Idle must paint at its 12fps source cadence, not duplicate at 60fps');
assert.equal(motionFrameDelay({fps: 12}, true), 250,
  'a frozen hover/ended Move must reduce to a low-rate maintenance frame');
assert.equal(standbyFrameDelay(1000), 250,
  'a truly still standing avatar must paint at only 4fps');
assert.equal(standbyFrameDelay(1000, {blink: true}), 32,
  'an active blink must immediately restore smooth AC cadence');
assert.equal(standbyFrameDelay(1000, {blink: true}, true), 50,
  'an active blink must retain smooth battery cadence');
assert.equal(standbyFrameDelay(1000, {pointerAt: 700}), 32,
  'moving gaze must stay smooth during its settling window');
assert.equal(standbyFrameDelay(1120, {pointerAt: 700}), 250,
  'a settled stationary gaze must return to 4fps maintenance');
for (const state of [{micro: true}, {release: true}, {viseme: true}]) {
  assert.equal(standbyFrameDelay(1000, state), 32,
    'short facial transitions must retain conversational cadence');
}
let renderDeadline = 1000;
let dueFrames = 1;
for (let refresh = 1; refresh < 60; refresh += 1) {
  const tick = advanceFrameClock(renderDeadline, 1000 + refresh * (1000 / 60), 1000 / 24);
  if (tick.due) { dueFrames += 1; renderDeadline = tick.next; }
}
assert.equal(dueFrames, 24,
  'fractional 24fps cadence on a 60Hz display must not round down to 20fps');
let standbyDeadline = 1000;
let standbyFrames = 1;
for (let refresh = 1; refresh < 60; refresh += 1) {
  const tick = advanceFrameClock(standbyDeadline,
    1000 + refresh * (1000 / 60), standbyFrameDelay(1000));
  if (tick.due) { standbyFrames += 1; standbyDeadline = tick.next; }
}
assert.equal(standbyFrames, 4,
  'an unchanged standing avatar must schedule exactly four paints per second');
assert.match(source, /at: changed \? performance\.now\(\) : pointer\.at,/,
  'stationary pointer heartbeats must not renew the fast gaze lane');
assert.match(source, /if \(changed\) lastFrame = 0;/,
  'real pointer motion must make its gaze paint due on the next refresh');
assert.doesNotMatch(source, /recordingAnimation/,
  'the recording meter must share the renderer clock instead of owning a second perpetual rAF');

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
const roamPresentationSignatureSource = inline[1].match(
  /(const roamPresentationSignature = value => \[[\s\S]*?\n    \]\.join\(':'\);)/,
);
assert.ok(roamPresentationSignatureSource,
  'roam presentation changes must remain independently classifiable');
const roamPresentationSignature = new Function(
  `'use strict'; ${roamPresentationSignatureSource[1]}; return roamPresentationSignature;`,
)();
assert.notEqual(
  roamPresentationSignature({enabled: true, mode: 'walk', direction: 1}),
  roamPresentationSignature({enabled: true, mode: 'ledge-right', direction: 1, edge: 'right'}),
);
assert.match(source,
  /if \(nextPresentationKey !== roamPresentationKey\) lastFrame = 0;/,
  'walk/ledge handoffs must make the render clock due immediately');
assert.equal(advanceFrameClock(0, 1200, 1000 / 24).due, true,
  'a reset transition clock must paint on the next display refresh');
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
    + `let petHit = false; let lastHitSent = 0; let avatarZoomGesture = null; ${updateHitSource[1]}; `
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

// Resizing around a stationary cursor can move the figure away from that
// cursor. A live pinch therefore pins the Electron hit claim until release,
// then immediately re-runs ordinary alpha classification without waiting for
// another cursor movement or heartbeat.
const zoomHitCalls = [];
const zoomHitLifecycle = new Function(
  'shell', 'overControls', 'pointer', 'paintedAvatarAt', 'root', 'markActivity', 'performance',
  `'use strict'; let dragging = false; let ptt = null; let avatarHit = false; `
    + `let petHit = false; let lastHitSent = 0; let avatarZoomGesture = { frame: 0 }; `
    + `${updateHitSource[1]}; `
    + `return { update: () => updateHit(true), release: () => { avatarZoomGesture = null; updateHit(true); } };`,
)(
  { setPetHit: value => zoomHitCalls.push(value) }, () => false,
  { x: 50, y: 50, inside: true }, () => false,
  { classList: { toggle() {} } }, () => {}, { now: () => 1000 },
);
zoomHitLifecycle.update();
zoomHitLifecycle.release();
assert.deepEqual(zoomHitCalls, [true, false],
  'pinch must stay interactive after alpha moves away, then refresh to click-through on release');
assert.match(source, /avatarZoomGesture = \{ frame: 0 \};\n        updateHit\(true\);\n        publishAvatarZoom\('start'\);/,
  'the interaction pin must reach Electron before the first resize packet');
assert.match(source, /avatarZoomGesture = null;[\s\S]{0,260}publishAvatarZoom\('end'\);[\s\S]{0,320}updateHit\(true\);/,
  'ending a pinch must release its pin and refresh alpha hit testing');
assert.match(source, /if \(!ready\) \{ clearStage\(\); setAvatarOnlyMotion\(false\); return; \}/);
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

// Cursor attention uses the full desktop feed, but saturates before the edge
// of the calibrated iris atlas and eases there rather than teleporting. The
// alpha hit flag is intentionally absent from this math: it still governs
// interaction, while off-window coordinates are allowed to govern gaze.
const cursorGazeTargetSource = inline[1].match(
  /(const cursorGazeTarget = \(point, anchor, ranges, viewport\) => \{[\s\S]*?\n    \};)/,
);
const smoothCursorGazeSource = inline[1].match(
  /(const smoothCursorGaze = \(state, target, now, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(cursorGazeTargetSource, 'bounded cursor-gaze geometry must remain independently testable');
assert.ok(smoothCursorGazeSource, 'cursor-gaze easing must remain independently testable');
const cursorGazeTarget = new Function(
  `'use strict'; ${cursorGazeTargetSource[1]}; return cursorGazeTarget;`,
)();
const smoothCursorGaze = new Function(
  `'use strict'; ${smoothCursorGazeSource[1]}; return smoothCursorGaze;`,
)();
const gazeAnchor = { x: 100, y: 100 };
const gazeRanges = { x: 2, y: 1 };
const gazeViewport = { width: 500, height: 700 };
assert.deepEqual(
  cursorGazeTarget({ seen: false, x: -900, y: 900 }, gazeAnchor, gazeRanges, gazeViewport),
  { x: 0, y: 0 },
  'the face must hold centre until a real cursor sample arrives',
);
const nearbyGaze = cursorGazeTarget(
  { seen: true, x: 164, y: 212 }, gazeAnchor, gazeRanges, gazeViewport);
assert.ok(nearbyGaze.x > 1.2 && nearbyGaze.y > .5,
  'a nearby cursor must produce an obvious glance, not a sub-atlas twitch');
const farGaze = cursorGazeTarget(
  { seen: true, x: -10_000, y: 10_000 }, gazeAnchor, gazeRanges, gazeViewport);
assert.ok(farGaze.x >= -2 && farGaze.x <= 2 && farGaze.y >= -1 && farGaze.y <= 1,
  'a cursor on another display must remain anatomically atlas-bounded');
const easedGazeState = { x: 0, y: 0, at: 0 };
const firstGaze = smoothCursorGaze(easedGazeState, nearbyGaze, 16, false);
assert.ok(firstGaze.x > 0 && firstGaze.x < nearbyGaze.x,
  'cursor gaze must start promptly but cannot teleport');
for (let frame = 2; frame <= 30; frame += 1) {
  smoothCursorGaze(easedGazeState, nearbyGaze, frame * 16, false);
}
assert.ok(Math.abs(easedGazeState.x - nearbyGaze.x) < .01,
  'cursor gaze must settle cleanly on its target');
const reducedGaze = smoothCursorGaze({ x: 0, y: 0, at: 1 }, nearbyGaze, 17, true);
assert.deepEqual(reducedGaze, nearbyGaze,
  'reduced motion must remove autonomous easing without disabling cursor control');
assert.match(source, /Coordinates are sent even outside the window|point\.seen/);

// Speaking motion is deliberately quieter than idle life. Lip sync and face
// composition remain separate, so calming the body cannot flatten the mouth.
const bodyMotionSource = inline[1].match(
  /(const bodyMotionAt = \(now, speaking, state, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(bodyMotionSource, 'body-motion envelope must remain independently testable');
const bodyMotionAt = new Function(
  `'use strict'; ${bodyMotionSource[1]}; return bodyMotionAt;`,
)();
let speakingSway = 0;
let speakingBreath = 0;
let idleSway = 0;
const steadySpeechState = { speechBlend: 1, at: 1 };
const steadyIdleState = { speechBlend: 0, at: 1 };
for (let time = 25; time <= 20_000; time += 25) {
  const speaking = bodyMotionAt(time, true, steadySpeechState, false);
  const idle = bodyMotionAt(time, false, steadyIdleState, false);
  speakingSway = Math.max(speakingSway, Math.abs(speaking.sway));
  speakingBreath = Math.max(speakingBreath, Math.abs(speaking.breathe - 1));
  idleSway = Math.max(idleSway, Math.abs(idle.sway));
}
assert.ok(speakingSway <= .001351, `speaking sway is too large: ${speakingSway}`);
assert.ok(speakingBreath <= .000901, `speaking breath is too large: ${speakingBreath}`);
assert.ok(idleSway > speakingSway * 4,
  'speech must be substantially calmer than the avatar\'s unhurried idle life');
let transitionSnap = 0;
for (let start = 500; start <= 20_000; start += 25) {
  const transitionState = { speechBlend: 0, at: start };
  const idleState = { speechBlend: 0, at: start };
  const transition = bodyMotionAt(start + 16, true, transitionState, false);
  const idle = bodyMotionAt(start + 16, false, idleState, false);
  transitionSnap = Math.max(transitionSnap, Math.abs(transition.sway - idle.sway));
}
assert.ok(transitionSnap < .00043,
  `speech onset must crossfade instead of phase-snapping the silhouette: ${transitionSnap}`);
const transitionState = { speechBlend: 0, at: 1000 };
bodyMotionAt(1016, true, transitionState, false);
assert.ok(transitionState.speechBlend > 0 && transitionState.speechBlend < .08,
  'speech attack must begin promptly without jumping directly to its envelope');
for (let frame = 2; frame <= 100; frame += 1) {
  bodyMotionAt(1000 + frame * 16, true, transitionState, false);
}
assert.ok(transitionState.speechBlend > .99, 'speech envelope must settle fully');
bodyMotionAt(2616, false, transitionState, false);
assert.ok(transitionState.speechBlend > .9 && transitionState.speechBlend < 1,
  'speech release must ease back to idle instead of snapping');
const reducedBodyState = { speechBlend: 0, at: 0 };
assert.deepEqual(
  bodyMotionAt(1234, true, reducedBodyState, true),
  { sway: 0, breathe: 1 },
);
assert.equal(reducedBodyState.speechBlend, 1);
assert.match(source, /liveAudioSpeaking = Boolean\(\n        live && live\.remoteAudioState && live\.remoteAudioState\.speaking\)/,
  'the authoritative Live Talk audio meter must select the quiet speech envelope');
assert.match(source, /Boolean\(agentSpeaking \|\| speechSource \|\| liveAudioSpeaking\)/);
assert.match(source, /bodyMotionState, reducedMotion\.matches\)/);
assert.match(source, /composeHead\(now\);/,
  'calming the silhouette must not bypass reactive face and lip composition');

// Electron reports a macOS trackpad pinch as Ctrl+wheel. Only that modifier
// path changes size; ordinary scrolling is left alone. Values use the same
// canonical stand/roam bounds as the persisted main-process geometry.
const pinchZoomSource = inline[1].match(
  /(const pinchZoomValue = \(current, event, range, viewportHeight\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(pinchZoomSource, 'pinch zoom transform must remain independently testable');
const pinchZoomValue = new Function(
  `'use strict'; ${pinchZoomSource[1]}; return pinchZoomValue;`,
)();
assert.equal(pinchZoomValue(1, { ctrlKey: false, deltaY: -30 }, { min: .25, max: 4 }, 800), 1,
  'ordinary wheel input must never resize the avatar');
assert.ok(pinchZoomValue(1, { ctrlKey: true, deltaY: -20, deltaMode: 0 }, { min: .25, max: 4 }, 800) > 1);
assert.ok(pinchZoomValue(1, { ctrlKey: true, deltaY: 20, deltaMode: 0 }, { min: .25, max: 4 }, 800) < 1);
assert.equal(pinchZoomValue(3, { ctrlKey: true, deltaY: -100, deltaMode: 2 }, { min: .25, max: 4 }, 800), 4);
assert.equal(pinchZoomValue(.6, { ctrlKey: true, deltaY: 100, deltaMode: 2 }, { min: .5, max: 3 }, 800), .5);
assert.match(source, /if \(!event\.ctrlKey \|\| !shell \|\| typeof shell\.setPetZoomLive !== 'function'/,
  'the renderer must accept only Chromium\'s pinch-shaped modifier wheel');
const paintedAvatarSource = inline[1].match(
  /(const paintedAvatarAt = point => \{[\s\S]*?\n    \};)/,
);
assert.ok(paintedAvatarSource, 'fresh alpha acceptance must remain independently testable');
const sampledPixels = [];
const paintedAvatarAt = new Function(
  'ready', 'innerWidth', 'innerHeight', 'context', 'pixelRatio',
  `'use strict'; ${paintedAvatarSource[1]}; return paintedAvatarAt;`,
)(true, 100, 100, {
  getImageData: (...args) => { sampledPixels.push(args); return { data: [0, 0, 0, 19] }; },
}, 2);
assert.equal(paintedAvatarAt({ x: 10.5, y: 20.5, inside: true }), true);
assert.deepEqual(sampledPixels, [[21, 41, 1, 1]],
  'pinch acceptance must sample the current device-pixel under the cursor');
assert.equal(paintedAvatarAt({ x: -1, y: 20, inside: true }), false);
assert.equal(paintedAvatarAt({ x: 10, y: 20, inside: false }), false);
assert.match(source, /const freshAvatarHit = avatarHit \|\| paintedAvatarAt\(/);
assert.match(source, /if \(!avatarZoomGesture && !freshAvatarHit\) return;/,
  'pinch sizing must begin only over a cached or freshly sampled avatar pixel');
assert.match(source, /publishAvatarZoom\('start'\)/);
assert.match(source, /publishAvatarZoom\('move'\)/);
assert.match(source, /publishAvatarZoom\('end'\)/);
assert.match(source, /canvas\.addEventListener\('wheel', handleAvatarPinch, \{ passive: false \}\)/);

// Double-click affordances use source-body regions only after the exact
// canvas pixel passes alpha hit-testing: head = Moves, chest = Opacity +,
// upper leg = Walk, and lower calf/foot = Opacity −.
const avatarDoubleClickSource = inline[1].match(
  /(const avatarBodyDoubleClickAction = \(local, geometry\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(avatarDoubleClickSource, 'body-relative double-click policy must remain independently testable');
const avatarBodyDoubleClickAction = new Function(
  `'use strict'; ${avatarDoubleClickSource[1]}; return avatarBodyDoubleClickAction;`,
)();
const clickGeometry = {
  hasBody: true, width: 100, height: 100,
  metadata: { bounds: [20, 0, 60, 100], alignment: { face_bounds: [40, 5, 20, 20] } },
};
assert.equal(avatarBodyDoubleClickAction({ x: 50, y: 10 }, clickGeometry), 'move');
assert.equal(avatarBodyDoubleClickAction({ x: 50, y: 35 }, clickGeometry), 'opacity-up');
assert.equal(avatarBodyDoubleClickAction({ x: 50, y: 60 }, clickGeometry), 'walk');
assert.equal(avatarBodyDoubleClickAction({ x: 50, y: 90 }, clickGeometry), 'opacity-down');
assert.equal(avatarBodyDoubleClickAction({ x: 10, y: 35 }, clickGeometry), null,
  'an arm-height click outside the chest must not change opacity');
assert.equal(avatarBodyDoubleClickAction({ x: 50, y: 10 }, {
  ...clickGeometry, hasBody: false,
}), 'move', 'a face-only avatar keeps the head gesture');
const steppedOpacitySource = inline[1].match(
  /(const steppedAvatarOpacity = \(current, direction\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(steppedOpacitySource, 'opacity steps must remain independently testable');
const steppedAvatarOpacity = new Function(
  `'use strict'; ${steppedOpacitySource[1]}; return steppedAvatarOpacity;`,
)();
assert.equal(steppedAvatarOpacity(.5, 1), .62);
assert.equal(steppedAvatarOpacity(.5, -1), .38);
assert.equal(steppedAvatarOpacity(.98, 1), 1);
assert.equal(steppedAvatarOpacity(.15, -1), .15);
assert.match(source, /if \(!geometry \|\| !paintedAvatarAt\(\{ \.\.\.point, inside: true \}\)\) return null;/,
  'transparent gaps must never acquire a body-region gesture');
assert.match(source, /else if \(action === 'opacity-up'\) void adjustAvatarOpacity\(1\);/);
assert.match(source, /else if \(action === 'opacity-down'\) void adjustAvatarOpacity\(-1\);/);
assert.match(source, /const state = await shell\.setPetOpacity\(next\);/);
assert.match(source, /canvas\.addEventListener\('dblclick', event => \{\n      clearTimeout\(avatarTapTimer\);/,
  'the first click must not open and resize chat underneath a double-click gesture');
assert.match(source, /avatarTapTimer = setTimeout\(\(\) => \{[\s\S]{0,180}openChat\(false\);[\s\S]{0,80}\}, 300\);/,
  'an ordinary body click must still open chat after the double-click arbitration window');

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
  'setPetOpacity',
  'setPetZoomLive',
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

// Keeping an edited draft must append the exact unsent content to the real
// conversation/history pair. It must not invoke the reply route, and modal
// keyboard handling must remain isolated from global push-to-talk behavior.
const draftPersistenceSource = inline[1].match(
  /(const emailDraftText = \(recipient, subject, body\) => \[[\s\S]*?const retainEmailDraft = \(historyEntries, recipient, subject, body, limit = 24\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(draftPersistenceSource, 'email-draft persistence must remain independently testable');
const draftPersistence = new Function(
  `'use strict'; ${draftPersistenceSource[1]}; return { emailDraftText, retainEmailDraft };`,
)();
const draftHistory = Array.from({ length: 24 }, (_, index) => ({ role: 'user', content: `old-${index}` }));
const retainedDraft = draftPersistence.retainEmailDraft(
  draftHistory,
  '陈女士 <chen@example.invalid>',
  'مرحبا — 项目更新',
  '第一行 👩🏽‍💻\nالسطر الثاني',
);
assert.equal(draftHistory.length, 24, 'draft retention must respect the existing bounded history');
assert.deepEqual(draftHistory.at(-1), { role: 'assistant', content: retainedDraft });
assert.equal(
  retainedDraft,
  'Unsent email draft\nTo: 陈女士 <chen@example.invalid>\nSubject: مرحبا — 项目更新\n\n第一行 👩🏽‍💻\nالسطر الثاني',
  'draft retention must preserve edited CJK, RTL, emoji, and line breaks exactly',
);
assert.match(source, /keep\.addEventListener\('click', \(\) => \{[\s\S]{0,260}retainEmailDraft\(history, recipient\.value, subject\.value, body\.value\)[\s\S]{0,180}addMessage\('assistant', retained\)/,
  'Keep in chat must append the edited draft to history and the visible conversation');
assert.match(source, /notify\('Unsent draft kept in this conversation\.'\)/,
  'draft retention must provide friendly confirmation');
assert.match(source, /panel\.setAttribute\('aria-labelledby', 'emailReviewTitle'\)/);
assert.match(source, /const background = \[\.\.\.document\.body\.children\][\s\S]{0,260}entry\.element\.inert = true/,
  'the modal must make its background inert');
assert.match(source, /entry\.element\.inert = entry\.inert \|\| \(avatarOnlyMotion && motionChrome\.includes\(entry\.element\)\)/,
  'closing the modal must restore prior inert state without undoing avatar-only motion');
assert.match(source, /event\.key !== 'Tab'[\s\S]{0,560}last\.focus\(\)[\s\S]{0,220}first\.focus\(\)/,
  'Tab and Shift-Tab must remain trapped within the email review');
assert.match(source, /panel\.addEventListener\('keydown',[\s\S]{0,120}event\.code === 'Space'\) event\.stopPropagation\(\)/,
  'Space inside the draft must never start global push to talk');
assert.match(source, /previousFocus\.focus\(\{ preventScroll: true \}\)/,
  'closing the review must restore the prior keyboard focus');

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
