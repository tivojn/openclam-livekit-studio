'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');
const inlineScripts = [...source.matchAll(/<script>\s*([\s\S]*?)\s*<\/script>/g)];
const inline = inlineScripts.at(-1);
const buttonMarkup = id => {
  const match = source.match(new RegExp(`<button id="${id}"[\\s\\S]*?<\\/button>`));
  assert.ok(match, `${id} must exist`);
  return match[0];
};

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

// One right-rail waveform control owns the full call/hang-up lifecycle.
assert.equal((source.match(/id="liveTalkButton"/g) || []).length, 1);
assert.match(source, /data-state="idle" aria-label="Start Live Talk"/);
assert.match(source, /setLiveButton\('connected'\)/);
assert.match(source, /const toggleLiveTalk = \(\) => \{[\s\S]{0,120}if \(live\) stopLiveTalk\('ended'\);[\s\S]{0,80}else startLiveTalk\(\);/);

// The old rail chat shortcut is now a local avatar carousel. Chat/PTT remains
// discoverable before an avatar exists through the canvas/menu and the empty
// card, without creating another Live Talk surface.
assert.equal((source.match(/id="avatarCarouselButton"/g) || []).length, 1);
assert.equal((source.match(/id="avatarModeButton"/g) || []).length, 1);
assert.equal((source.match(/id="chatButton"/g) || []).length, 0);
assert.equal((source.match(/id="emptyChat"/g) || []).length, 1);
assert.match(source, /aria-label="Switch to next avatar"/);
assert.match(source, /aria-label="Switch to Avatar mode"/);
const displayModeMenu = source.match(
  /<div id="motionPicker"[^>]*aria-label="Avatar display mode"[^>]*>([\s\S]*?)<\/div>/,
);
assert.ok(displayModeMenu, 'the avatar rail must expose one display-mode menu');
const displayModeItems = [
  ['standbyButton', 'Standby', 'standby', 'symbol-standby'],
  ['closeUpButton', 'Close-up', 'close-up', 'symbol-close-up'],
  ['walkButton', 'Horizon Walk', 'horizon-walk', 'symbol-horizon-walk'],
  ['edgeIdleButton', 'Edge Idle', 'edge-idle', 'symbol-edge-idle'],
  ['movesButton', 'Moves', 'moves', 'symbol-moves'],
];
for (const [id, label, symbol, symbolClass] of displayModeItems) {
  const markup = buttonMarkup(id);
  assert.match(markup, /role="menuitemradio"/, `${id} must keep radio semantics`);
  assert.match(markup, new RegExp(`data-symbol="${symbol}"`), `${id} must expose its symbol name`);
  assert.match(markup, new RegExp(`class="sf-symbol ${symbolClass}"`), `${id} must use the approved glyph`);
  assert.match(markup, new RegExp(`<span class="rail-picker-label">${label}<\\/span>`), `${id} must keep its visible label`);
  assert.match(markup, /class="sf-symbol symbol-checkmark rail-picker-check"/, `${id} must reserve a trailing active check`);
}
assert.equal((displayModeMenu[1].match(/role="menuitemradio"/g) || []).length, 5,
  'the display-mode menu must contain exactly the five owner-approved modes');
assert.equal((source.match(/id="motionMenuButton"/g) || []).length, 1);
assert.match(buttonMarkup('motionMenuButton'), /class="sf-symbol symbol-standby"/,
  'one minimal figure glyph must own the complete display-mode menu');
for (const [id, symbolClass] of [
  ['liveTalkButton', 'symbol-waveform'],
  ['avatarCarouselButton', 'symbol-avatar-picker'],
  ['avatarModeButton', 'symbol-avatar-window'],
  ['speakerButton', 'symbol-speaker'],
  ['layerButton', 'symbol-thread-layer'],
  ['opacityButton', 'symbol-opacity'],
  ['mirrorButton', 'symbol-face-mirror'],
  ['settingsButton', 'symbol-settings'],
  ['railFoldButton', 'symbol-chevron-down'],
]) {
  assert.match(buttonMarkup(id), new RegExp(`class="sf-symbol ${symbolClass}`),
    `${id} must use the approved minimal SF Symbol`);
}
assert.match(buttonMarkup('liveTalkButton'), /class="sf-symbol symbol-stop"/,
  'connected Live Talk must swap from waveform to stop');
assert.match(buttonMarkup('speakerButton'), /class="sf-symbol symbol-stop"/,
  'active read-aloud must swap to stop');
assert.match(buttonMarkup('speakerButton'), /class="sf-symbol symbol-speaker-slash"/,
  'unavailable read-aloud must swap to speaker.slash');
assert.match(source, /Use the waveform control to start or end the current LiveKit conversation\./,
  'the Details panel must describe the visible Live Talk waveform control');
assert.match(buttonMarkup('layerButton'), /class="sf-symbol symbol-avatar-layer"/,
  'the layer toggle must expose the avatar-top state');
const activeDisplayModeSource = inline[1].match(
  /(const activeDisplayMode = \(\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(activeDisplayModeSource, 'display-mode classification must remain independently testable');
const classifyDisplayMode = (overrides = {}) => new Function(
  'manualMotionKind', 'shellState', 'idleDocked', 'moveUntil', 'performance',
  `'use strict'; ${activeDisplayModeSource[1]}; return activeDisplayMode();`,
)(
  overrides.manualMotionKind || null,
  overrides.shellState || {pet: {roam: false}, chatCloseUp: false, desktopCloseUp: false},
  Boolean(overrides.idleDocked), Number(overrides.moveUntil) || 0, {now: () => 100},
);
assert.equal(classifyDisplayMode(), 'standby');
assert.equal(classifyDisplayMode({shellState: {pet: {roam: false}, chatCloseUp: true}}), 'close-up');
assert.equal(classifyDisplayMode({shellState: {pet: {roam: true}}}), 'walk');
assert.equal(classifyDisplayMode({manualMotionKind: 'idle'}), 'edge-idle');
assert.equal(classifyDisplayMode({moveUntil: 200}), 'moves');
assert.match(source, /#topline \{ display: none !important; \}/,
  'avatar lifecycle status must not occupy a floating chip in Chat\/Talk');
assert.match(source, /id="chatHeaderNewButton"[^>]+aria-label="Start a new chat"[^>]*>[\s\S]{0,180}<svg/,
  'the compact task header must expose an accessible New chat action');
assert.match(source, /id="newChatButton"[^>]+>[\s\S]{0,620}<span>New chat<\/span>[\s\S]{0,260}<\/button>/,
  'the history drawer must expose a visible New chat label instead of a dark placeholder bar');
assert.match(source, /id="historySettingsButton"[^>]+>[\s\S]{0,760}<span>Settings<\/span>[\s\S]{0,40}<\/button>/,
  'the history sidebar must expose Settings');
assert.match(source, /<main id="chatWorkspace">[\s\S]*?<div id="conversation"/,
  'the live conversation must remain inside the central Codex-style task pane');
assert.match(source, /<aside id="workspaceInfoPanel" aria-label="Task details">/,
  'the desktop shell must expose a dedicated task-details pane');
assert.match(source, /grid-template-columns:\s*var\(--workspace-sidebar-track\) minmax\(0, 1fr\) var\(--workspace-info-track\)/,
  'wide Chat\/Talk mode must use the approved three-pane desktop geometry');
assert.match(source, /html\.workspace-sidebar-collapsed \{ --workspace-sidebar-track: 0px; \}/);
assert.match(source, /html\.workspace-info-collapsed \{ --workspace-info-track: 0px; \}/);
assert.match(source, /const setHistoryOpen = \(value, persist = true\) => \{/,
  'the left sidebar must have one persistent fold controller');
assert.match(source, /const applyWorkspaceInfoCollapsed = \(value, persist = true\) => \{/,
  'the task-details pane must have one persistent collapse controller');
assert.match(source, /id="workspaceInfoToggle"[^>]+aria-controls="workspaceInfoPanel"/,
  'the central header must keep an accessible right split-pane toggle');
assert.match(source, /id="chatHistoryButton"[^>]+aria-controls="chatHistoryPanel"/,
  'the central header must keep an accessible left split-pane toggle');
assert.match(source, /html\.chat-mode #settingsButton \{ display: none; \}/,
  'Settings belongs in the left sidebar, not a duplicate rail gear');
assert.match(source, /html\.chat-mode #rail\.rail-folded \.rail-fold \.sf-symbol \{ transform: rotate\(-90deg\); \}/,
  'the one visible folded-rail chevron must point right');
assert.match(source, /html\.chat-mode #rail \{ top: 66px; right: calc\(var\(--workspace-info-track\) \+ 14px\); \}/,
  'the avatar rail must stay inside the central pane and clear an open details pane');
assert.match(source, /html\.chat-mode \.message\.user \{[^}]*padding-right:\s*58px;/,
  'right-aligned user turns must reserve a real gutter for the floating avatar rail');
assert.match(source, /html\.chat-mode \.message\.assistant \{[^}]*flex-direction:\s*column;[^}]*align-items:\s*flex-start;/,
  'assistant response actions must sit directly beneath the response, not beside it');
assert.match(source, /html\.chat-mode \.message\.assistant \.response-actions \{[^}]*align-self:\s*flex-start;[^}]*justify-content:\s*flex-start;/,
  'Copy and Read Aloud must remain left-aligned under each assistant response');
assert.match(source, /#pendingAttachments \{[^}]*min-height:\s*42px;[^}]*scrollbar-width:\s*none;/,
  'staged attachments must remain visible without adding another scrollbar');
assert.match(source, /\.pending-attachment \{[^}]*border:\s*1px solid var\(--codex-border-heavy\);[^}]*color:\s*var\(--codex-text\);/,
  'attachment chips must have sufficient light- and dark-theme contrast');
assert.match(source, /const chatWorkspaceViewport = \(\) => \{/);
assert.match(source, /const chatAvatarSafeViewport = \(\{ reserveComposer = true, reserveRail = true \} = \{\}\) => \{/,
  'avatar fitting must derive a central-pane safe area instead of painting under controls');
assert.match(source, /right = Math\.min\(right, railRect\.left - 16\)/,
  'the avatar safe area must stop before the visible rail');
assert.match(source, /bottom = Math\.min\(bottom, composerRect\.top - 16\)/,
  'full-body and motion feet must stop above the floating composer');
assert.match(source, /return fullChat \|\| safeDesktop \? clampChatCameraFit\(fit, viewport\) : fit;/,
  'saved Standby placement must keep the head inside the usable chat or static desktop canvas');
assert.match(source, /chatAvatarSafeViewport\(\{ reserveComposer: true, reserveRail: true \}\)/,
  'chat Walk and Edge Idle must share the same rail/composer-safe canvas');
assert.match(source, /if \(chatScoped && kind === 'idle'\) \{[\s\S]{0,420}const viewport = chatAvatarSafeViewport\(\{ reserveComposer: true, reserveRail: true \}\);/,
  'per-frame Edge Idle anchoring must not regress to the raw rail-obscured workspace');
assert.match(source, /const syncChatWorkspaceGeometry = \(\) => \{/);
assert.match(source, /clip-path: inset\([\s\S]{0,220}--chat-workspace-left/,
  'avatar pixels must be clipped to the central workspace rather than either sidebar');
assert.doesNotMatch(source, /window\.prompt\('Type “rename” or “delete”/,
  'history actions must use a real menu instead of blocking prompts');
assert.match(source, /pin\.textContent = thread\.pinned \? 'Unpin' : 'Pin'/);
assert.match(source, /remove\.textContent = 'Delete'/);
assert.match(source, /\.history-thread:hover \.history-thread-more,[\s\S]{0,100}\.history-thread:focus-within \.history-thread-more/,
  'thread ellipses must appear only for hover or keyboard focus');
assert.doesNotMatch(source, /Start a chat, push to talk, or call your avatar/,
  'an empty thread must remain visually quiet instead of rendering a default instruction');
assert.match(source, /html:not\(\.chat-mode\) #topline,[\s\S]{0,220}html:not\(\.chat-mode\) #rail,[\s\S]{0,280}display: none !important;/,
  'Avatar mode must be one pure avatar surface without chat status or rail chrome');
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
  'Conversation shell must reserve the rail while keeping one shared geometry');
const compactChatDockRule = [...source.matchAll(/#chatDock\s*\{([^}]+)\}/g)]
  .map(match => match[1])
  .find(rule => rule.includes('right: var(--pet-rail-reserve)'));
assert.ok(compactChatDockRule, 'final compact chat dock rule must remain identifiable');
assert.match(compactChatDockRule, /background:\s*transparent;/);
assert.match(compactChatDockRule, /-webkit-backdrop-filter:\s*none;/);
assert.match(compactChatDockRule, /backdrop-filter:\s*none;/);
assert.match(compactChatDockRule, /box-shadow:\s*none;/,
  'compact composer must not draw a redundant outer rectangle or filter halo');
const composerRowRule = [...source.matchAll(/#composerRow\s*\{([^}]+)\}/g)]
  .map(match => match[1])
  .find(rule => rule.includes('align-items: end'));
assert.ok(composerRowRule, 'final composer row rule must remain identifiable');
assert.match(composerRowRule, /border:\s*0;/);
assert.match(composerRowRule, /background:\s*transparent;/);
assert.match(composerRowRule, /box-shadow:\s*none;/,
  'the textarea row must not draw a second shell inside the composer');
const composerShellMarkup = source.indexOf('<div id="composerShell">');
const recordingChipMarkup = source.indexOf('<div id="recordingChip"');
const composerRowMarkup = source.indexOf('<div id="composerRow">');
assert.ok(composerShellMarkup >= 0 && recordingChipMarkup > composerShellMarkup
  && recordingChipMarkup < composerRowMarkup,
  'push-to-talk state must live inside the composer rather than floating over the avatar');
assert.match(source, /html\.chat-mode #recordingChip \{[\s\S]{0,420}position:\s*static;[\s\S]{0,420}background:\s*var\(--codex-hover\);/,
  'chat-mode dictation feedback must be an integrated neutral composer row');
assert.match(source, /setDictationFeedback\('Transcribing…', 'busy'\)/);
assert.match(source, /setDictationFeedback\(`Could not transcribe:[\s\S]{0,140}'error', 5200\)/,
  'speech recognition failures must remain inside the composer');
assert.doesNotMatch(source, /notify\(`Could not transcribe:/,
  'speech recognition failures must not cover the avatar with a global dark toast');
assert.match(source, /const notify = \(text, duration = 4200\) => \{[\s\S]{0,520}threadNoticeNode\.className = 'thread-notice'/,
  'chat status must render as a quiet in-thread row instead of a dark global toast');
assert.match(source, /html\.chat-mode\.avatar-layer-top #stage \{[\s\S]{0,120}z-index:\s*32;/,
  'the avatar layer must actually composite above the thread at full opacity');
assert.match(source, /html\.chat-mode\.thread-layer-top #stage \{\s*z-index:\s*1;/,
  'thread-first mode must return the avatar beneath the scroll surface');
assert.match(source, /html\.chat-mode\.thread-layer-top #stage \{[^}]*filter:\s*none;/,
  'thread-first mode must not alter the opacity slider result with a canvas filter');
assert.match(source, /html\.chat-mode #chatDock,[\s\S]{0,900}background:\s*transparent;/,
  'thread-first mode must not composite a translucent wash over the avatar canvas');
assert.match(source, /html\.chat-mode #composerShell \{[^}]*background:\s*color-mix\(in srgb, var\(--codex-editor\) 62%, transparent\);[^}]*backdrop-filter:\s*blur\(6px\)/,
  'chat composer must remain translucent enough to reveal avatar motion beneath it');
assert.match(source, /html\.chat-mode \.message\.user \.bubble \{[^}]*background:\s*color-mix\(in srgb, var\(--codex-control\) 56%, transparent\);[^}]*backdrop-filter:\s*blur\(4px\)/,
  'chat user bubbles must remain translucent enough to reveal avatar motion beneath them');
assert.match(source, /canvas\.addEventListener\('pointerdown', event => \{[\s\S]{0,300}interactionLayer === 'avatar'[\s\S]{0,180}paintedAvatarAt\(/,
  'avatar-first drags must freshly hit-test the visible avatar before starting');
assert.match(source, /canvasGesture\.positionAdjusting = true;[\s\S]{0,100}root\.classList\.add\('position-adjusting'\)/,
  'a drag in any direction must reposition the front avatar layer');
assert.doesNotMatch(source, /opacityAdjusting/,
  'dragging must never be split into a competing vertical opacity gesture');
assert.match(source, /x: canvasGesture\.startOffset\.x \+ deltaX,[\s\S]{0,80}y: canvasGesture\.startOffset\.y \+ deltaY/,
  'the avatar must follow both cursor axes directly during drag');
assert.match(source, /canvas\.addEventListener\('wheel', handleAvatarPinch/,
  'Standby and every painted motion must share the avatar pinch path');
assert.match(source, /#conversation \{[\s\S]{0,180}height: min\(64dvh, 680px\);/,
  'Open conversation history must expose a full Work-style scrolling thread');
assert.match(source, /#chatDock:has\(#conversation:not\(:empty\)\)/,
  'Only a dock with real conversation content may draw the thread surface');
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
for (const route of ['/reply/stream', '/stt', '/say', '/api/livekit/session']) {
  assert.ok(source.includes(`'${route}'`), `missing same-origin route ${route}`);
}
assert.match(source, /fetch\('\/reply\/stream',[\s\S]{0,900}response\.body\.getReader\(\)/,
  'local Mac chat must consume the authenticated incremental reply stream');
assert.match(source, /appendAssistantActions\(liveReply\.row, answer, result\.llm_route\)/,
  'a completed local reply must show the authoritative runtime route receipt');
assert.match(source, /className = 'response-route'[\s\S]{0,180}runtime\.display/,
  'runtime model identity must come from route metadata rather than generated prose');
assert.match(source, /liveReply = addMessage\('assistant', '', \{ readable: false, persist: false \}\)/,
  'streamed text must use one ephemeral assistant bubble until completion');
assert.match(source, /event\.type === 'complete'[\s\S]{0,120}result = event/,
  'only an authoritative completion may finalize a local streamed turn');
const localStreamingSource = source.match(
  /async function submitLocalTurn\(text, options = \{\}\) \{([\s\S]*?)\n    async function submitTurn/,
);
assert.ok(localStreamingSource, 'local streaming chat implementation must remain inspectable');
assert.ok(
  localStreamingSource[1].indexOf("event.type === 'complete'")
    < localStreamingSource[1].indexOf('history.push({ role: \'assistant\''),
  'the final assistant message must enter history only after stream completion',
);
assert.ok(
  localStreamingSource[1].indexOf("event.type === 'complete'")
    < localStreamingSource[1].indexOf('playSpeech(result.audio'),
  'speech must wait for the authoritative completion rather than token deltas',
);
assert.match(localStreamingSource[1], /suppress_local_tts: Boolean\(options\.liveAgentBridge\)/,
  'delegated Live Talk turns must not synthesize a discarded second local voice');
assert.match(localStreamingSource[1], /result\.audio && !options\.liveAgentBridge/,
  'only ordinary local chat may play the local reply audio');
assert.match(localStreamingSource[1],
  /const latestAssistantTextBeforeTurn = latestAssistantText;[\s\S]*?liveReply\.row\.remove\(\);[\s\S]*?latestAssistantText = latestAssistantTextBeforeTurn;/,
  'a failed local stream must not leave its removed partial as the rail read-aloud target');
const openClawStreamingSource = inline[1].match(
  /(async function submitOpenClawTurn\(value, agentID, options = \{\}\) \{[\s\S]*?\n    \})/,
);
assert.ok(openClawStreamingSource,
  'the connected OpenClaw streaming turn must remain independently inspectable');
assert.match(openClawStreamingSource[1],
  /if \(!options\.liveAgentBridge\)[\s\S]{0,100}readAloud\(automaticSpokenProjection\(completedText\)\)/,
  'ordinary connected OpenClaw replies must use a bounded projection on the working TTS path');
assert.match(openClawStreamingSource[1],
  /if \(liveReply && liveReply\.row\.classList\.contains\('streaming'\)\)[\s\S]{0,100}liveReply\.row\.remove\(\)/,
  'aborted or failed streams must remove their partial assistant bubble');
assert.match(openClawStreamingSource[1],
  /const latestAssistantTextBeforeTurn = latestAssistantText;[\s\S]*?liveReply\.row\.remove\(\);[\s\S]*?latestAssistantText = latestAssistantTextBeforeTurn;/,
  'a failed OpenClaw stream must not leave its removed partial as the rail read-aloud target');
assert.match(openClawStreamingSource[1],
  /liveReply\.bubble\.textContent = completedText/,
  'the visible completed answer must remain full fidelity when automatic speech is bounded');
assert.match(openClawStreamingSource[1],
  /else setStatus\(live \? 'Live Talk · connected' : 'Ready', live \? 'live' : 'good'\);/,
  'delegated Live Talk actions must leave audible TTS ownership with the cloud voice agent');
const automaticProjectionSource = inline[1].match(
  /(const AUTOMATIC_TTS_MAX_BYTES = 3000;[\s\S]*?const automaticSpokenProjection = value => \{[\s\S]*?\n    \};)/,
);
assert.ok(automaticProjectionSource, 'automatic TTS projection must remain independently testable');
const automaticSpokenProjection = new Function(
  `'use strict'; ${automaticProjectionSource[1]}; return automaticSpokenProjection;`,
)();
assert.equal(automaticSpokenProjection('Short answer.'), 'Short answer.');
const longAutomaticSpeech = automaticSpokenProjection('界'.repeat(5000));
assert.ok(new TextEncoder().encode(longAutomaticSpeech).length <= 3000,
  'automatic speech must remain within its UTF-8 cost bound');
assert.ok(longAutomaticSpeech.endsWith('The rest is visible in chat.'),
  'truncated automatic speech must tell the user where the complete answer remains');
for (const route of ['/api/openclaw/agents', '/api/openclaw/turn', '/api/openclaw/uploads']) {
  assert.ok(source.includes(`'${route}'`), `missing same-origin OpenClaw route ${route}`);
}
assert.equal((source.match(/id="agentModeSelect"/g) || []).length, 1);
assert.match(source, /async function submitTurn\(text, options = \{\}\)[\s\S]{0,300}selectedOpenClawAgent\(\)/,
  'the Mac composer must switch between local and OpenClaw agents without changing screens');
assert.match(source, /keepAvatarMode: !root\.classList\.contains\('chat-mode'\)/,
  'A head-hold PTT started in Avatar mode must retain that mode');
assert.match(source, /submitTurn\(heard, \{ keepAvatarMode: Boolean\(session\.keepAvatarMode\) \}\)/,
  'The completed PTT transcript must preserve its originating Avatar mode');
const startLiveTalkSource = source.match(
  /async function startLiveTalk\(\) \{([\s\S]*?)\n    function stopLiveTalk/,
);
assert.ok(startLiveTalkSource, 'Live Talk implementation must remain inspectable');
assert.doesNotMatch(startLiveTalkSource[1], /openChat\(false\)/,
  'Avatar double-click Live Talk must never navigate into Chat\/Talk mode');
assert.match(source, /const createWorkTimeline = \(\) =>/);
assert.match(source, /event\.type === 'work'[\s\S]{0,100}updateWorkTimeline/);
assert.match(source, /event\.type === 'attachment'[\s\S]{0,120}appendOpenClawAttachment/);
assert.match(source,
  /id="chatThreadHeading" role="status" aria-live="polite" aria-atomic="true"/,
  'the task title must announce paired-agent activity without replacing history titles');
assert.match(source,
  /const renderChatThreadHeading = \(\) => \{[\s\S]{0,700}\? 'Typing\.\.\.'[\s\S]{0,100}`OpenClaw - \$\{agentName\}`/,
  'OpenClaw task titles must use the exact active and idle labels');
assert.match(openClawStreamingSource[1],
  /turnControllerOrigin = options\.liveAgentBridge \? 'live-agent-bridge' : 'typed';[\s\S]{0,500}setOpenClawTurnHeading\(controller, true\);/,
  'the controller must own Typing status before bridge work begins');
assert.match(buttonMarkup('sendButton'), /data-action="send"/,
  'the composer action must begin in send mode');
assert.match(buttonMarkup('sendButton'), /class="send-stop-symbol"/,
  'the composer must reserve an explicit Stop glyph');
assert.match(source,
  /sendButton\.dataset\.action = working \? 'stop' : 'send';/,
  'Typing state must expose Stop through the existing composer action');
const stopOpenClawSource = inline[1].match(
  /(const requestOpenClawTurnStop = \(\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(stopOpenClawSource, 'the paired-agent Stop lifecycle must remain inspectable');
assert.match(stopOpenClawSource[1],
  /const controller = openClawTurnHeadingOwner;[\s\S]{0,180}turnController !== controller/,
  'Stop must target the exact controller that owns Typing state');
assert.match(stopOpenClawSource[1],
  /openClawTurnStopRequested = true;[\s\S]{0,180}controller\.abort\(\);/,
  'Stop must keep the working title until it aborts the active bridge request');
assert.match(source,
  /sendButton\.addEventListener\('click',[\s\S]{0,180}sendButton\.dataset\.action === 'stop'[\s\S]{0,100}requestOpenClawTurnStop\(\)/,
  'the visible Stop action must dispatch to the paired controller cancellation path');
assert.match(openClawStreamingSource[1],
  /event\.type === 'work'[\s\S]{0,300}event\.type === 'text'[\s\S]{0,700}event\.type === 'complete'/,
  'real work and assistant protocol events must update progressively before completion');
assert.match(openClawStreamingSource[1],
  /event\.type === 'complete'[\s\S]{0,180}completionReceived = true;[\s\S]{0,220}setOpenClawTurnHeading\(controller, false\);/,
  'only the explicit terminal event may restore the idle OpenClaw title');
assert.match(openClawStreamingSource[1],
  /if \(!completionReceived\) \{\s*throw new Error\('OpenClaw connection closed before completion\.'\);/,
  'bare stream EOF must never masquerade as a completed agent turn');
assert.match(openClawStreamingSource[1],
  /finally \{[\s\S]{0,160}setOpenClawTurnHeading\(controller, false\);[\s\S]{0,100}if \(turnController === controller\)/,
  'terminal cleanup must be controller-owned so an older turn cannot clear a replacement title');
assert.doesNotMatch(stopOpenClawSource[1], /setOpenClawTurnHeading\([^)]*false/,
  'requesting Stop must not restore the idle title before cancellation is terminal');

// A manual upward scroll suspends sticky follow. The global bottom-centre
// affordance remains above avatar visuals in both layer modes, jumps to the
// latest event, and resumes follow for subsequent text and work updates.
assert.match(source,
  /id="scrollToLatestButton"[^>]+aria-label="Go to latest message"[^>]+hidden/,
  'the latest-message affordance must be accessible and initially hidden');
assert.match(source,
  /html\.chat-mode #scrollToLatestButton:not\(\[hidden\]\) \{[\s\S]{0,180}position: fixed;[\s\S]{0,80}z-index: 52;/,
  'the latest-message affordance must stack globally above avatar visuals');
assert.match(source,
  /bottom: calc\(var\(--chat-workspace-bottom\) \+ 32px \+ var\(--composer-shell-height, 86px\)\);/,
  'the affordance must remain clear of the composer');
assert.doesNotMatch(source, /\.avatar-layer-top\s+#scrollToLatestButton/,
  'avatar-on-top mode must never hide the latest-message affordance');
assert.match(source,
  /const followConversationLatest = \(\{ force = false \} = \{\}\) => \{[\s\S]{0,260}if \(!force && !conversationAutoFollow\)[\s\S]{0,180}conversation\.scrollTop = conversation\.scrollHeight/,
  'streaming content may force-scroll only while sticky follow is active');
assert.match(source,
  /conversation\.addEventListener\('scroll',[\s\S]{0,220}conversationAutoFollow = !awayFromLatest;[\s\S]{0,180}scrollToLatestButton\.hidden = !root\.classList\.contains\('chat-mode'\) \|\| !awayFromLatest/,
  'manual upward scrolling must disable sticky follow and reveal the affordance');
assert.match(source,
  /scrollToLatestButton\.addEventListener\('click',[\s\S]{0,120}followConversationLatest\(\{ force: true \}\)/,
  'the latest-message affordance must jump to bottom and resume sticky follow');
assert.match(openClawStreamingSource[1],
  /event\.type === 'text'[\s\S]{0,700}followConversationLatest\(\);/,
  'incremental OpenClaw text must honor sticky follow');
assert.match(source,
  /const updateWorkTimeline = \([^)]*\) => \{[\s\S]{0,3200}followConversationLatest\(\);/,
  'incremental OpenClaw work steps must honor sticky follow');
assert.match(source, /textContent = step\.title/,
  'work details must use text nodes rather than executable markup');
assert.doesNotMatch(source, /innerHTML\s*=\s*step\./,
  'OpenClaw work updates must never write untrusted HTML');
assert.match(source, /if \(!root\.classList\.contains\('has-detail'\)\) event\.preventDefault\(\)/,
  'A status-only work step must not expand into an empty grey detail panel');
assert.match(source, /item\.detail\.hidden = !hasDetail;/,
  'Empty work details must be structurally hidden');
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
assert.match(source, /livekit_credential_store_unavailable/);
assert.match(source, /livekit_access_rejected/);
assert.match(source, /livekit_rate_limited/);
assert.match(source, /livekit_service_unavailable/);
assert.match(source, /livekit_broker_unreachable/);
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

// Live Talk mouth shapes follow the TTS transcript synchronizer. It supplies
// audio-paced TimedStrings (native provider alignment when available, LiveKit's
// audio pacing otherwise). The analyser remains a last-resort fallback and owns
// only playback lifecycle/status while synchronized words are healthy.
const liveMouthSyncSource = source.match(
  /\/\* live-mouth-sync:start \*\/([\s\S]*?)\/\* live-mouth-sync:end \*\//,
);
assert.ok(liveMouthSyncSource, 'Live Talk mouth helpers must remain independently testable');
const mouthSync = new Function(
  `'use strict'; ${liveMouthSyncSource[1]}; return { `
    + 'makeReactiveMouthState, measureAudioSignal, classifyAudioViseme, reactiveAudioViseme, '
    + 'makeLiveTalkAudioState, liveTalkAudioTransition, makeLiveTalkTTSTimingState, '
    + 'resetLiveTalkTTSTimingState, liveTalkTextVisemeCues, scaleLiveTalkTTSCues, '
    + 'parseLiveTalkTTSTimingPacket, acceptLiveTalkTTSTiming, '
    + 'liveTalkSynchronizedViseme, LIVE_MOUTH_RELEASE_MS, LIVE_MOUTH_DWELL_MS, '
    + 'LIVE_TALK_STATUS_RELEASE_MS, LIVE_TALK_TTS_TIMING_STALL_MS };',
)();
const fullVisemes = ['sil', 'PP', 'FF', 'TH', 'DD', 'kk', 'CH', 'SS', 'nn', 'RR', 'aa', 'E', 'ih', 'oh', 'ou'];

const phoneticCues = mouthSync.liveTalkTextVisemeCues('thoughtful', fullVisemes);
assert.equal(phoneticCues[0].viseme, 'TH', 'TTS text must select the authored TH plate');
assert.ok(phoneticCues.some(cue => cue.viseme === 'ou'),
  'a synchronized word must retain its rounded vowel instead of spectrum guessing');
assert.ok(phoneticCues.every(cue => cue.durationMs >= 70),
  'TTS cues must not chatter faster than a readable mouth pose');
const chineseCues = mouthSync.liveTalkTextVisemeCues('你好世界', fullVisemes);
assert.ok(chineseCues.length > 0 && chineseCues.every(cue => cue.viseme === 'aa'),
  'text without trustworthy local phoneme mapping must use one stable neutral shape');
assert.doesNotMatch(liveMouthSyncSource[1], /codePointAt\(0\)\s*%/,
  'CJK mouth motion must never be pseudo-randomized from Unicode code points');
const startPacket = mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1, generation: 7, segment: 7, sequence: 1, event: 'start',
}));
const timingPacket = mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1,
  generation: 7,
  segment: 7,
  sequence: 2,
  text: 'hello ',
  end_time: .42,
}));
assert.deepEqual(timingPacket, {
  event: 'cue', generation: 7, segment: 7, sequence: 2,
  text: 'hello ', startTime: null, endTime: .42,
});
const pacedStartPacket = mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1, generation: 8, segment: 8, sequence: 1, event: 'start',
}));
const pacedPacket = mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1,
  generation: 8,
  segment: 8,
  sequence: 2,
  text: 'thoughtful ',
  start_time: .5,
  end_time: .9,
}));
assert.equal(pacedPacket.endTime - pacedPacket.startTime, .4);
const endPacket = mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1, generation: 8, segment: 8, sequence: 3, event: 'end',
}));
assert.deepEqual(endPacket, {
  event: 'end', generation: 8, segment: 8, sequence: 3,
  text: '', startTime: null, endTime: null,
});
assert.equal(mouthSync.parseLiveTalkTTSTimingPacket('{bad-json'), null);
assert.equal(mouthSync.parseLiveTalkTTSTimingPacket(JSON.stringify({
  schema_version: 1, generation: 7, segment: 7, sequence: 3,
  text: 'x'.repeat(513), end_time: .5,
})), null, 'oversized synchronized text must fail closed');
const timedMouth = mouthSync.makeLiveTalkTTSTimingState();
assert.equal(mouthSync.acceptLiveTalkTTSTiming(timedMouth, timingPacket, 90, fullVisemes), false,
  'a cue must never create a generation without its explicit start lifecycle packet');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(timedMouth, startPacket, 95, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(timedMouth, timingPacket, 100, fullVisemes), true);
assert.notEqual(mouthSync.liveTalkSynchronizedViseme(timedMouth, 100), 'sil',
  'a synchronized TTS word must immediately own the mouth shape');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(timedMouth, timingPacket, 110, fullVisemes), false,
  'replayed timing packets must not rewind the mouth');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(timedMouth, {
  ...timingPacket, segment: 6, sequence: 99, endTime: 99,
}, 120, fullVisemes), false,
  'a delayed packet from an older segment must not rewind the mouth');
assert.equal(mouthSync.liveTalkSynchronizedViseme(timedMouth, 700), 'sil',
  'ordinary word gaps close the mouth instead of falling back to random spectrum shapes');
assert.equal(
  mouthSync.liveTalkSynchronizedViseme(
    timedMouth, 100 + mouthSync.LIVE_TALK_TTS_TIMING_STALL_MS + 1,
  ),
  null,
  'RMS becomes eligible only after the synchronized TTS lane has actually stalled',
);
const pacedMouth = mouthSync.makeLiveTalkTTSTimingState();
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, pacedStartPacket, 990, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, pacedPacket, 1000, fullVisemes), true);
const pacedRemainingMs = (pacedMouth.activeCue ? pacedMouth.activeCue.endsAt - 1000 : 0)
  + pacedMouth.queuedCues.reduce((sum, cue) => sum + cue.durationMs, 0);
assert.ok(pacedRemainingMs >= 150 && pacedRemainingMs <= 270,
  'packet start/end interval must scale the remaining playback-paced mouth cues');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, endPacket, 1100, fullVisemes), true);
assert.equal(mouthSync.liveTalkSynchronizedViseme(pacedMouth, 1100), 'sil',
  'an explicit utterance end must immediately clear queued mouth poses');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, {
  ...pacedPacket, sequence: 3,
}, 1110, fullVisemes), false,
  'a cue from an explicitly ended segment must never reopen the mouth');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, {
  ...pacedPacket, segment: 7, sequence: 99,
}, 1120, fullVisemes), false,
  'a lower segment identifier must never be treated as a fresh utterance');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, {
  ...pacedStartPacket, generation: 9, segment: 9,
}, 1130, fullVisemes), true,
  'only an increasing segment identifier may start a new utterance');
mouthSync.resetLiveTalkTTSTimingState(pacedMouth, 1140);
assert.equal(mouthSync.liveTalkSynchronizedViseme(pacedMouth, 1140), 'sil');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, {
  ...pacedPacket, segment: 9, sequence: 2,
}, 1150, fullVisemes), false,
  'barge-in must close the current segment against late queued cues');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(pacedMouth, {
  ...pacedStartPacket, generation: 10, segment: 10,
}, 1160, fullVisemes), true);
const unseenBarge = mouthSync.makeLiveTalkTTSTimingState();
mouthSync.resetLiveTalkTTSTimingState(unseenBarge, 2000, true);
mouthSync.resetLiveTalkTTSTimingState(unseenBarge, 2001, true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(unseenBarge, {
  ...startPacket, generation: 1, segment: 1,
}, 2010, fullVisemes), false,
  'barge-in must tombstone an old generation even before its first packet arrives');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(unseenBarge, {
  ...startPacket, generation: 2, segment: 2,
}, 2020, fullVisemes), true,
  'repeated interruption signals stay idempotent and keep the next generation eligible');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(unseenBarge, {
  ...timingPacket, generation: 2, segment: 2,
}, 2030, fullVisemes), true);
const postEndBarge = mouthSync.makeLiveTalkTTSTimingState();
assert.equal(mouthSync.acceptLiveTalkTTSTiming(postEndBarge, {
  ...startPacket, generation: 1, segment: 1,
}, 2100, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(postEndBarge, {
  ...endPacket, generation: 1, segment: 1,
}, 2110, fullVisemes), true);
mouthSync.resetLiveTalkTTSTimingState(postEndBarge, 2120, true);
mouthSync.resetLiveTalkTTSTimingState(postEndBarge, 2121, true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(postEndBarge, {
  ...startPacket, generation: 2, segment: 2,
}, 2130, fullVisemes), false,
  'barge-in after an ended utterance must tombstone the unseen next generation');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(postEndBarge, {
  ...startPacket, generation: 3, segment: 3,
}, 2140, fullVisemes), true,
  'the post-end unseen tombstone must remain idempotent and admit the later generation');
const ordinaryNextTurn = mouthSync.makeLiveTalkTTSTimingState();
assert.equal(mouthSync.acceptLiveTalkTTSTiming(ordinaryNextTurn, {
  ...startPacket, generation: 1, segment: 1,
}, 2200, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(ordinaryNextTurn, {
  ...endPacket, generation: 1, segment: 1,
}, 2210, fullVisemes), true);
mouthSync.resetLiveTalkTTSTimingState(ordinaryNextTurn, 2220, false);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(ordinaryNextTurn, {
  ...startPacket, generation: 2, segment: 2,
}, 2230, fullVisemes), true,
  'a normal next user turn after completed speech must admit its next timing generation');
const lostEndRecovery = mouthSync.makeLiveTalkTTSTimingState();
assert.equal(mouthSync.acceptLiveTalkTTSTiming(lostEndRecovery, {
  ...startPacket, generation: 1, segment: 1,
}, 2300, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(lostEndRecovery, {
  ...timingPacket, generation: 1, segment: 1,
}, 2310, fullVisemes), true);
assert.equal(mouthSync.acceptLiveTalkTTSTiming(lostEndRecovery, {
  ...startPacket, generation: 2, segment: 2,
}, 2310 + mouthSync.LIVE_TALK_TTS_TIMING_STALL_MS, fullVisemes), false,
  'a newer start must not pre-empt an authoritative lane before its stall boundary');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(lostEndRecovery, {
  ...startPacket, generation: 2, segment: 2,
}, 2311 + mouthSync.LIVE_TALK_TTS_TIMING_STALL_MS, fullVisemes), true,
  'a strictly newer start must recover after an end packet is lost and the lane stalls');
assert.equal(mouthSync.acceptLiveTalkTTSTiming(lostEndRecovery, {
  ...timingPacket, generation: 1, segment: 1, sequence: 3,
}, 2320 + mouthSync.LIVE_TALK_TTS_TIMING_STALL_MS, fullVisemes), false,
  'a late cue from the abandoned generation must remain tombstoned after recovery');

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
assert.notEqual(opened, 'sil', 'RMS fallback must open the mouth on older or broken timing lanes');
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
assert.match(source,
  /const synchronized = liveTalkSynchronizedViseme\(live && live\.ttsTimingState, now\);[\s\S]{0,100}if \(synchronized !== null\) return synchronized;[\s\S]{0,120}return reactiveAudioViseme/,
  'synchronized TTS must outrank the spectrum fallback in the actual render path');
assert.match(source,
  /RoomEvent\.DataReceived[\s\S]{0,180}handleLiveTalkTTSTimingData\(session, payload, participant, topic\)/,
  'the room must consume the dedicated synchronized TTS timing topic');
const mouthPriority = inline[1].match(
  /(const desiredViseme = now => \{[\s\S]*?\n    \};)/,
);
assert.ok(mouthPriority, 'mouth-source priority must remain independently inspectable');
assert.ok(
  mouthPriority[1].indexOf('speechSource && speechTrack.length')
    < mouthPriority[1].indexOf('liveTalkSynchronizedViseme'),
  'typed-chat exact timed visemes must retain first priority',
);
assert.ok(
  mouthPriority[1].indexOf('liveTalkSynchronizedViseme')
    < mouthPriority[1].indexOf('reactiveAudioViseme'),
  'Live Talk synchronized TTS must retain priority over RMS/spectrum fallback',
);
assert.match(source, /if \(live\) syncLiveTalkAudioStatus\(live, now\)/,
  'the render loop must apply the exact samples measured for reactive visemes to Live Talk status');
assert.match(source, /live !== session \|\| session\.ending \|\| !session\.agentReady \|\| !session\.audioAttachments\.size/,
  'audio status must be scoped to an attached, ready, current Live Talk session');
assert.match(source, /RoomEvent\.ActiveSpeakersChanged[\s\S]{0,180}nextAgentSpeaking = participants\.some\(participant => participant\.isAgent\)[\s\S]{0,180}agentSpeaking = nextAgentSpeaking/,
  'LiveKit active-speaker semantics must continue to drive body expression independently');
assert.match(source, /RoomEvent\.Reconnecting[\s\S]{0,220}session\.agentReady = false;[\s\S]{0,260}Live Talk · reconnecting…/,
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
assert.match(transcriptSource[1], /beginLiveTalkUserInput\(session, segmentID, now\)/,
  'the first user interim/final must cancel queued mouth cues at barge-in');
const userInputSource = inline[1].match(
  /(const beginLiveTalkUserInput = \(session, segmentID, now\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(userInputSource, 'Live Talk user-turn boundaries must remain independently inspectable');
assert.match(userInputSource[1],
  /const invalidatesUnseenTiming = interruptsAgentSpeech \|\| interruptsDelegatedTurn;/,
  'only an actual active interruption may tombstone a not-yet-seen timing generation');
assert.match(userInputSource[1],
  /resetLiveTalkTTSTimingState\(session\.ttsTimingState, now, invalidatesUnseenTiming\)/,
  'ordinary consecutive turns must preserve the next synchronized TTS generation');
assert.doesNotMatch(userInputSource[1],
  /resetLiveTalkTTSTimingState\(session\.ttsTimingState, now, interruptsAssistant\)/,
  'historical assistant output must never suppress every other timed response');
assert.match(source,
  /RoomEvent\.TrackUnsubscribed[\s\S]{0,320}resetLiveTalkTTSTimingState\(session\.ttsTimingState, performance\.now\(\), true\)/,
  'remote track teardown must close its timing segment immediately');
assert.match(source,
  /RoomEvent\.TrackMuted[\s\S]{0,260}resetLiveTalkTTSTimingState\(session\.ttsTimingState, performance\.now\(\), true\)/,
  'remote track interruption must clear queued mouth cues');
assert.match(source, /addEventListener\('ended', endedHandler/,
  'the browser media-track end must also close the timing segment');
assert.match(source, /audioMonitorGain\.gain\.value = 0/,
  'the shared analyser branch must remain inaudible while still being rendered');
assert.match(source, /source\.connect\(graph\.destination\)/,
  'regular timed speech must retain one explicit audible destination');

// The rail speaker is a playback toggle. During a long generated utterance it
// must stop the current Web Audio source immediately instead of starting a
// second /say request, and the same transition must close the timed mouth and
// expression state. Live Talk owns separate attached remote audio and must not
// be touched by this local read-aloud control.
assert.match(source,
  /id="speakerButton"[^>]+aria-pressed="false"[^>]+aria-label="Read latest reply aloud"/,
  'the speaker control must expose its inactive toggle state');
const speakerStateSource = inline[1].match(
  /(const setSpeakerPlaybackState = playing => \{[\s\S]*?\n    \};)/,
);
const stopSpeechSource = inline[1].match(
  /(const stopSpeech = \(\) => \{[\s\S]*?\n    \};)/,
);
const beginSpeechRequestSource = inline[1].match(
  /(const beginSpeechRequest = \(\) => \{[\s\S]*?\n    \};)/,
);
const speechRequestCurrentSource = inline[1].match(
  /(const speechRequestIsCurrent = request => Boolean\([\s\S]*?&& !live\);)/,
);
const playSpeechSource = inline[1].match(
  /(const playSpeech = async \(base64[\s\S]*?\n    \};)/,
);
assert.ok(speakerStateSource, 'speaker playback state helper must remain independently testable');
assert.ok(stopSpeechSource, 'speech stop lifecycle must remain independently testable');
assert.ok(beginSpeechRequestSource, 'speech request owner must remain independently testable');
assert.ok(speechRequestCurrentSource, 'speech cancellation guard must remain independently testable');
assert.ok(playSpeechSource, 'speech decode lifecycle must remain independently testable');
const stoppedSources = [];
const speakerAttributes = {};
const localSpeechStop = new Function(
  'speakerButton', 'initialSource', 'stoppedSources',
  `'use strict';
   let speechSource = initialSource;
   let speechRequest = null;
   let speechTrack = [[0, 'ah']];
   let speechTrackIndex = 3;
   let currentViseme = 'ah';
   let speechExpressionTimeline = [{ text: 'long reply' }];
   let speechExpressionPlan = { laughter: 1 };
   const reactiveMouthState = { viseme: 'ah', audibleUntil: 999 };
   const makeSpeechExpressionPlan = () => ({ neutral: true });
   ${speakerStateSource[1]}
   ${stopSpeechSource[1]}
   const stopped = stopSpeech();
   return { stopped, speechSource, speechTrack, speechTrackIndex, currentViseme,
     speechExpressionTimeline, speechExpressionPlan, reactiveMouthState };`,
)({
  setAttribute: (name, value) => { speakerAttributes[name] = value; },
  set title(value) { speakerAttributes.title = value; },
}, { stop: () => stoppedSources.push('stop') }, stoppedSources);
assert.equal(localSpeechStop.stopped, true);
assert.deepEqual(stoppedSources, ['stop'], 'mute must synchronously stop the active source');
assert.equal(localSpeechStop.speechSource, null);
assert.deepEqual(localSpeechStop.speechTrack, []);
assert.equal(localSpeechStop.speechTrackIndex, 0);
assert.equal(localSpeechStop.currentViseme, 'sil');
assert.deepEqual(localSpeechStop.speechExpressionTimeline, []);
assert.equal(localSpeechStop.reactiveMouthState.viseme, 'sil');
assert.equal(localSpeechStop.reactiveMouthState.audibleUntil, 0);
assert.equal(speakerAttributes['aria-pressed'], 'false');
assert.equal(speakerAttributes['aria-label'], 'Read latest reply aloud');
assert.equal(speakerAttributes.title, 'Read latest reply aloud');

// Exercise the actual async decode boundary. A mute or newer request while
// decodeAudioData is pending must make the old result inert; starting Live Talk
// must do the same without touching its independently attached remote audio.
const speechCancellationQA = new Function('assert',
  `'use strict';
   return (async () => {
     const speakerAttributes = {};
     const speakerButton = {
       setAttribute: (name, value) => { speakerAttributes[name] = value; },
       set title(value) { speakerAttributes.title = value; },
     };
     let live = null;
     let speechSource = null;
     let speechRequest = null;
     let speechRequestID = 0;
     let speechTrack = [];
     let speechTrackIndex = 0;
     let speechStart = 0;
     let currentViseme = 'sil';
     let speechExpressionTimeline = [];
     let speechExpressionPlan = {};
     const reactiveMouthState = { viseme: 'sil', audibleUntil: 0 };
     const makeSpeechExpressionPlan = () => ({});
     const makeSpeechExpressionTimeline = () => [];
     const speechExpressionPlanAt = (_timeline, _time, fallback) => fallback;
     const stabiliseTrack = value => value;
     const resumeChatSpeakingPose = () => {};
     const setStatus = () => {};
     const manifest = { visemes: ['sil', 'aa'] };
     const audioAnalyser = {};
     const decodeResolvers = [];
     const sources = [];
     const graph = {
       currentTime: 12,
       destination: {},
       decodeAudioData: () => new Promise(resolve => decodeResolvers.push(resolve)),
       createBufferSource: () => {
         const source = {
           connected: [], started: 0, stopped: 0, onended: null,
           connect(value) { this.connected.push(value); },
           start() { this.started += 1; },
           stop() { this.stopped += 1; },
         };
         sources.push(source);
         return source;
       },
     };
     const ensureAudioGraph = () => graph;
     ${speakerStateSource[1]}
     ${stopSpeechSource[1]}
     ${beginSpeechRequestSource[1]}
     ${speechRequestCurrentSource[1]}
     ${playSpeechSource[1]}

     const mutedOwner = beginSpeechRequest();
     const mutedDecode = playSpeech('YQ==', [[0, 'aa']], 'long reply', mutedOwner);
     assert.equal(decodeResolvers.length, 1);
     assert.equal(speakerAttributes['aria-pressed'], 'true');
     assert.equal(stopSpeech(), true, 'pending decode is an active mute target');
     assert.equal(mutedOwner.controller.signal.aborted, true);
     decodeResolvers.shift()({ duration: 3 });
     assert.equal(await mutedDecode, false);
     assert.equal(sources.length, 0, 'a muted decode must never create an audible source');

     const staleOwner = beginSpeechRequest();
     const staleDecode = playSpeech('YQ==', [], 'old reply', staleOwner);
     const currentOwner = beginSpeechRequest();
     const currentDecode = playSpeech('YQ==', [], 'new reply', currentOwner);
     assert.equal(staleOwner.controller.signal.aborted, true);
     const resolveStale = decodeResolvers.shift();
     const resolveCurrent = decodeResolvers.shift();
     resolveStale({ duration: 2 });
     assert.equal(await staleDecode, false);
     assert.equal(sources.length, 0, 'a replaced decode must stay inaudible');
     resolveCurrent({ duration: 2 });
     assert.equal(await currentDecode, true);
     assert.equal(sources.length, 1);
     assert.equal(sources[0].started, 1, 'only the newest utterance may start');

     const remoteAttachment = { released: false };
     const liveOwner = beginSpeechRequest();
     const liveDecode = playSpeech('YQ==', [], 'must not overlap call', liveOwner);
     stopSpeech();
     live = { audioAttachments: new Map([['remote', remoteAttachment]]) };
     decodeResolvers.shift()({ duration: 4 });
     assert.equal(await liveDecode, false);
     assert.equal(sources.length, 1, 'Live Talk must suppress a stale local decode');
     assert.equal(remoteAttachment.released, false,
       'local speech cancellation must not release Live Talk remote audio');
     return true;
   })();`,
)(assert);
const speakerHandlerSource = inline[1].match(
  /speakerButton\.addEventListener\('click', \(\) => \{([\s\S]*?)\n    \}\);/,
);
assert.ok(speakerHandlerSource, 'speaker click lifecycle must remain inspectable');
assert.ok(speakerHandlerSource[1].indexOf('if (speechSource || speechRequest)')
  < speakerHandlerSource[1].indexOf('readAloud(latestAssistantText)'),
  'active or pending playback must stop before the control can request another utterance');
assert.match(speakerHandlerSource[1], /stopSpeech\(\);[\s\S]*?return;/,
  'muting an active utterance must return without calling read-aloud');
assert.doesNotMatch(speakerHandlerSource[1], /hasAttachedAgentAudio|audioAttachments/,
  'the regular speaker toggle must not mute or release Live Talk audio');
assert.match(source, /speechSource = source;\s*setSpeakerPlaybackState\(true\);/,
  'successful read-aloud playback must expose the active stop control');
assert.match(source,
  /if \(speechSource === source && speechRequest === owner\) \{[\s\S]*?setSpeakerPlaybackState\(false\);/,
  'natural playback completion must restore the read-aloud control');
assert.match(source, /postJSON\('\/say', \{ text \}, request\.controller\.signal\)/,
  'long read-aloud fetches must be abortable from the speaker control');
assert.match(source, /if \(!speechRequestIsCurrent\(owner\)\) return false;/,
  'decoded audio must revalidate ownership before it becomes audible');

// A regular request must not create a second LLM/TTS lane while Live Talk owns
// the microphone and speaker. The composer keeps its text for after hang-up.
assert.match(source, /Hang up Live Talk before sending a regular chat message/);
assert.match(source, /Hang up Live Talk before playing a separate read-aloud voice/);
assert.match(source,
  /sendButton\.disabled = sendButton\.dataset\.action === 'stop'[\s\S]{0,80}\? openClawTurnStopRequested[\s\S]{0,140}: \(!composer\.value\.trim\(\) && !pendingComposerAttachments\.length\)[\s\S]{0,100}Boolean\(turnController\) \|\| Boolean\(live\)/,
  'OpenClaw file-only messages must remain sendable while active turns and Live Talk stay exclusive');

// The Mac composer supports both transports: OpenClaw files use authenticated
// handles, while ordinary local chat uses bounded image/text data and honest
// metadata-only cards for unsupported binary content.
for (const id of [
  'attachButton', 'attachmentMenu', 'addFilesButton', 'addPhotosButton',
  'takePhotoButton', 'attachmentDisclosure', 'filePreviewDialog', 'cameraDialog',
]) assert.match(source, new RegExp(`id=["']${id}["']`), `missing media control ${id}`);
assert.match(source, /input_handles: inputAttachments\.map\(attachment => attachment\.handle\)/);
assert.match(source, /if \(!agentID\) return stageLocalFiles\(files\)/,
  'ordinary local chat must stage attachments instead of disabling the Add button');
assert.match(source, /attachButton\.disabled = Boolean\(turnController\) \|\| Boolean\(live\)[\s\S]{0,80}pendingComposerAttachments\.length >= 8/);
assert.doesNotMatch(source, /attachButton\.disabled[^;]+!selectedOpenClawAgent\(\)/,
  'the attachment menu must remain available for ordinary local chat');
assert.match(source, /LOCAL_ATTACHMENT_MAX_IMAGE_CHARS = 900_000/);
assert.match(source, /LOCAL_ATTACHMENT_MAX_TEXT_CHARS = 48_000/);
assert.match(source, /const localTurnContent = \(value, attachments = \[\]\) => \{/);
assert.match(source, /metadata only; this file’s bytes will not be sent to the selected model provider/i,
  'unsupported binary cards must disclose that only metadata is available');
assert.match(source, /Files are sent to the model provider shown in Settings only after you press Send\./,
  'the attachment menu must disclose the external-provider boundary before a file is staged');
assert.match(source, /const chatGPTTextOnly = !openClaw && provider === 'openai' && authMode === 'chatgpt'/,
  'the composer must recognize the text-only ChatGPT OAuth chat route');
assert.match(source, /addPhotosButton\.disabled = directAttachmentVisionTextOnly;[\s\S]{0,100}takePhotoButton\.disabled = directAttachmentVisionTextOnly;/,
  'photo and camera input must be disabled when the selected route cannot carry pixels');
assert.match(source, /ChatGPT OAuth chat is text-only\. Photo and Camera are unavailable; an image chosen as a File stays metadata-only\./,
  'the unavailable vision boundary must be explained at the attachment controls');
assert.match(source, /if \(directAttachmentVisionTextOnly\) \{[\s\S]{0,180}transport: 'metadata'[\s\S]{0,80}vision_omitted: true/,
  'an image selected through File must fail closed to metadata on a text-only route');
assert.match(source, /await refreshAttachmentRouteCapability\(\);[\s\S]{0,420}directAttachmentVisionTextOnly && attachment\.transport === 'image'[\s\S]{0,180}transport: 'metadata'/,
  'the selected route must be rechecked and staged pixels re-sanitized immediately before send');
assert.match(source, /<option value="local">OpenClam<\/option>/,
  'the built-in provider route must not be mislabeled as on-device inference');
assert.doesNotMatch(source, /<option value="local">On this Mac<\/option>/,
  'the composer must not imply that cloud-routed model traffic stays on-device');
assert.match(source, /if \(!pendingComposerAttachments\.length && inputAttachments\.length\) \{[\s\S]{0,180}pendingComposerAttachments = inputAttachments;[\s\S]{0,180}renderPendingAttachments\(\);/,
  'failed built-in model requests must restore staged attachments for retry');
assert.ok(source.includes('/^api\\/openclaw\\/(?:artifacts|uploads)\\/[A-Za-z0-9_-]{20,32}$/'),
  'thread media URLs must remain limited to authenticated same-origin artifact/upload handles');
assert.match(source, /document\.createElement\('audio'\)/);
assert.match(source, /document\.createElement\('video'\)/);
assert.match(source, /document\.createElement\('iframe'\)/);
assert.match(source, /renderSafeMarkdown/);
assert.match(source, /showFilePreview/);
assert.match(source, /shareResource/);
assert.match(source, /downloadResource/);
assert.doesNotMatch(source, /markdown[\s\S]{0,300}innerHTML\s*=/i,
  'Markdown previews must never execute file content as HTML');

// Agent feedback is first-class Mac text: native selection remains enabled,
// every complete response exposes whole-entry Copy and Read Aloud, and a
// partial selection can be copied or quoted into the existing composer. Ask
// AI must prepare a draft only; it never starts a turn on the user's behalf.
assert.match(source, /\.bubble \{[\s\S]{0,360}unicode-bidi: plaintext;[\s\S]{0,120}user-select: text;/);
assert.match(source, /id="composer"[^>]*maxlength="12000"[^>]*dir="auto"/);
assert.match(source, /id="selectionActions" role="toolbar" aria-label="Selected response actions"/);
assert.match(source, /id="selectionCopy"[^>]*>Copy<\/button>/);
assert.match(source, /id="selectionAskAI"[^>]*aria-keyshortcuts="Meta\+Shift\+A Control\+Shift\+A">Ask AI<\/button>/);
assert.match(source, /const appendAssistantActions = \(row, text, route = null\) => \{[\s\S]{0,1900}'Copy this response'[\s\S]{0,1500}'Read this response aloud'/);
assert.match(source, /role === 'assistant' && text && options\.readable !== false[\s\S]{0,180}appendAssistantActions\(row, String\(text\), options\.route\)/);
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
  "['eyes', 'gaze', 'brow', 'forehead', 'cheek', 'eyebag']",
  'manifest.smile',
  'manifest.emotion_mouth',
  "['walk', 'idle', 'move']",
  'manifest.eyes.states',
  'manifest.gaze.dxs',
  'manifest.brow.dys',
  'motionPlaybackProfile',
  'edge_anchors',
]) {
  assert.ok(source.includes(capability), `missing avatar runtime capability: ${capability}`);
}

// Speech expression combines bounded semantic intent with the samples already
// measured for lip sync. It must remain deterministic, multilingual, and
// independently testable without adding another model or network request.
const expressionEngineSource = inline[1].match(
  /\/\* expression-engine:start \*\/([\s\S]*?)\/\* expression-engine:end \*\//,
);
assert.ok(expressionEngineSource, 'speech expression planner must remain independently testable');
const expressionEngine = new Function(
  `'use strict'; ${expressionEngineSource[1]}; return { makeSpeechExpressionPlan, `
    + 'makeSpeechExpressionTimeline, speechExpressionPlanAt, speechExpressionTarget };',
)();
const curiousPlan = expressionEngine.makeSpeechExpressionPlan('Would you like to try this?');
const warmPlan = expressionEngine.makeSpeechExpressionPlan('Thank you! I am very glad this worked.');
const seriousPlan = expressionEngine.makeSpeechExpressionPlan('Important warning: you must be careful.');
const playfulPlan = expressionEngine.makeSpeechExpressionPlan('Haha, I was joking — that was funny!');
const laughterPlan = expressionEngine.makeSpeechExpressionPlan('Haha, I am laughing so hard at that hilarious joke!');
const sorrowPlan = expressionEngine.makeSpeechExpressionPlan('I am heartbroken and crying with deep sorrow and grief.');
const horrorPlan = expressionEngine.makeSpeechExpressionPlan('I am horrified, terrified and afraid — this is a nightmare!');
const angerPlan = expressionEngine.makeSpeechExpressionPlan('I am furious and angry about this outrage!');
const surprisePlan = expressionEngine.makeSpeechExpressionPlan('I am shocked, astonished and completely surprised!');
const chineseEmpathyPlan = expressionEngine.makeSpeechExpressionPlan('抱歉，这确实很难。我理解你的担心。');
assert.ok(curiousPlan.curiosity > 0.5, 'questions must produce a clear curiosity intent');
assert.ok(warmPlan.warmth > 0.5 && warmPlan.energy > curiousPlan.energy,
  'warm emphatic language must brighten the expression plan');
assert.ok(seriousPlan.gravity > 0.5, 'warnings must produce a restrained serious plan');
assert.ok(playfulPlan.humor > 0.5,
  'humor and playful speech must engage the shared smile mouth intent');
assert.ok(laughterPlan.laughter > 0.8 && sorrowPlan.sadness > 0.8
  && horrorPlan.fear > 0.8 && angerPlan.anger > 0.8 && surprisePlan.surprise > 0.8,
  'the spoken text must classify distinct laughter, sorrow, horror, anger, and surprise intents');
assert.ok(chineseEmpathyPlan.empathy > 0.5,
  'Chinese empathy language must receive the same local expression treatment');
const mixedTimeline = expressionEngine.makeSpeechExpressionTimeline(
  'Haha, this is hilarious, but I am heartbroken with sorrow; then I am terrified '
    + 'by this nightmare. Finally I am furious and angry.',
  12,
);
assert.ok(mixedTimeline.length >= 4,
  'a multi-emotion paragraph must be divided into phrase-local expression plans');
const timelinePlans = mixedTimeline.map(entry => entry.plan);
assert.ok(timelinePlans[0].laughter > timelinePlans[0].sadness
  && timelinePlans.some(plan => plan.sadness > plan.laughter)
  && timelinePlans.some(plan => plan.fear > plan.anger)
  && timelinePlans.at(-1).anger > timelinePlans.at(-1).laughter,
  'laughter, sorrow, horror, and anger must each own their spoken phrase');
for (let index = 1; index < mixedTimeline.length; index += 1) {
  assert.equal(mixedTimeline[index - 1].end, mixedTimeline[index].start,
    'expression phrase timing must remain continuous');
}
assert.equal(
  expressionEngine.speechExpressionPlanAt(
    mixedTimeline, mixedTimeline[0].start + .01, null),
  mixedTimeline[0].plan,
  'the expression scheduler must select the plan spoken at the current audio time',
);
const voicedTarget = expressionEngine.speechExpressionTarget(
  warmPlan,
  { relative: 0.8, centroid: 0.55 },
  0.5,
  1.2,
);
assert.ok(voicedTarget.brow > 0 && voicedTarget.cheek > 0.35,
  'audible warm speech must engage brows and cheeks');
const emotionSignal = { relative: 0.82, centroid: 0.52 };
const laughterTarget = expressionEngine.speechExpressionTarget(
  laughterPlan, emotionSignal, 0.5, 1.2,
);
const sorrowTarget = expressionEngine.speechExpressionTarget(
  sorrowPlan, emotionSignal, 0.5, 1.2,
);
const horrorTarget = expressionEngine.speechExpressionTarget(
  horrorPlan, emotionSignal, 0.5, 1.2,
);
const angerTarget = expressionEngine.speechExpressionTarget(
  angerPlan, emotionSignal, 0.5, 1.2,
);
assert.ok(laughterTarget.smile === 0.18
  && laughterTarget.brow === 0 && laughterTarget.underEye === 0
  && laughterTarget.squeeze === 0 && laughterTarget.cheek === 0
  && laughterTarget.eyeSquint === 0 && laughterTarget.gazeX === 0
  && laughterTarget.gazeY === 0,
  'laughter and smile must share one corner-lift mouth while the upper face stays neutral');
assert.ok(sorrowTarget.brow > 0.22 && sorrowTarget.gazeY > 0.22
  && sorrowTarget.headPitch > 0.15 && sorrowTarget.cheek < 0.3
  && sorrowTarget.sorrowMouth > 0.5 && sorrowTarget.eyeSquint < 0.02,
  'sorrow must raise the brow, lower gaze and head, suppress smiling cheeks, and retain normal lashes');
assert.ok(horrorTarget.brow > 0.78 && horrorTarget.eyeSquint < 0.08
  && horrorTarget.headPitch < -0.24 && horrorTarget.cheek < 0.3
  && horrorTarget.squeeze > 0.55 && horrorTarget.horrorMouth > 0.34
  && horrorTarget.horrorMouth < 0.40,
  'horror must hold the eyes open, lift and knit the brow, restrain the jaw, and recoil the head');
assert.ok(angerTarget.brow > 0.72 && angerTarget.squeeze > 1.7
  && angerTarget.eyeSquint < 0.04
  && angerTarget.angerMouth > 0.8,
  'anger must lower and squeeze the brow, widen the frown, and retain the normal open lash plate');
assert.match(source,
  /Number\(speechExpressionPlan\.anger \|\| 0\) \* \.86/,
  'anger must suppress coincidental natural blinks instead of closing both eyes');
assert.match(source, /const activeBrowTop = laughterDominant \? Math\.min\(browTop, 9\.5\) : browTop;/,
  'the approved laughter brow range must remain isolated from dramatic emotion expansion');
const emotionVectors = [laughterTarget, sorrowTarget, horrorTarget, angerTarget]
  .map(target => ['brow', 'squeeze', 'cheek', 'eyeSquint', 'gazeY', 'headPitch']
    .map(key => target[key].toFixed(3)).join(':'));
assert.equal(new Set(emotionVectors).size, emotionVectors.length,
  'every primary emotion must resolve to a distinct rendered channel vector');
assert.ok(Math.abs(voicedTarget.headYaw) <= 1 && Math.abs(voicedTarget.headRoll) <= 1,
  'all conversational pose channels must remain bounded');
assert.match(source,
  /playSpeech\(\s*result\.audio, result\.track \|\| \[\], text, request\)/,
  'read-aloud speech must pass its words into the expression planner');
assert.match(source, /playSpeech\(result\.audio, result\.track \|\| \[\], answer\)/,
  'chat replies must pass the final answer into the expression planner');
assert.match(source, /speechExpressionTimeline = makeSpeechExpressionTimeline\(text\);/,
  'Live Talk assistant transcripts must update semantic expression intent');

const speechExpressionSource = inline[1].match(
  /(const speechExpressionAt = \(now, speaking, state, plan, signal, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(speechExpressionSource,
  'upper-face speech scheduler must remain independently testable');
const speechExpressionAt = new Function(
  `'use strict'; ${expressionEngineSource[1]}; const speechSource = null; `
    + 'const speechTime = () => 0; '
    + `${speechExpressionSource[1]}; return speechExpressionAt;`,
)();
const zeroExpression = { brow: 0, underEye: 0, squeeze: 0, smile: 0,
  sorrowMouth: 0, horrorMouth: 0, angerMouth: 0, cheek: 0, eyeSquint: 0, asymmetry: 0,
  gazeX: 0, gazeY: 0, headYaw: 0, headPitch: 0, headRoll: 0 };
const upperFaceState = {
  mode: 'idle', started: 0, duration: 1, nextAt: 0,
  from: { ...zeroExpression }, to: { ...zeroExpression }, value: { ...zeroExpression },
};
assert.deepEqual(
  speechExpressionAt(0, true, upperFaceState, warmPlan, { relative: .8 }, true),
  zeroExpression,
  'reduced motion must hold upper-face layers still even during speech',
);
speechExpressionAt(0, true, upperFaceState, warmPlan, { relative: .8, centroid: .5 }, false);
const firstUpperFace = speechExpressionAt(
  420, true, upperFaceState, warmPlan, { relative: .8, centroid: .5 }, false,
);
assert.ok(firstUpperFace.brow > 0 && firstUpperFace.underEye > 0,
  'speech must animate both brow and under-eye targets');
speechExpressionAt(900, true, upperFaceState, warmPlan, { relative: .4, centroid: .3 }, false);
const laterUpperFace = speechExpressionAt(
  1200, true, upperFaceState, warmPlan, { relative: .4, centroid: .3 }, false,
);
assert.notEqual(laterUpperFace.brow, firstUpperFace.brow,
  'upper-face phrase targets must follow changing voice energy');
speechExpressionAt(1600, false, upperFaceState, warmPlan, { relative: 0 }, false);
assert.deepEqual(
  speechExpressionAt(2000, false, upperFaceState, warmPlan, { relative: 0 }, false),
  zeroExpression,
  'upper-face speech motion must settle back to a still idle state',
);
const phraseState = {
  mode: 'idle', started: 0, duration: 1, nextAt: 0, planKey: '',
  from: { ...zeroExpression }, to: { ...zeroExpression }, value: { ...zeroExpression },
};
const laughterEntry = mixedTimeline.find(entry => entry.plan.laughter > .8);
const sorrowEntry = mixedTimeline.find(entry => entry.plan.sadness > .8);
assert.ok(laughterEntry && sorrowEntry, 'mixed-expression fixture must contain both phrases');
speechExpressionAt(laughterEntry.start * 1000, true, phraseState, laughterEntry.plan,
  emotionSignal, false);
const scheduledLaugh = speechExpressionAt(laughterEntry.start * 1000 + 360, true,
  phraseState, laughterEntry.plan, emotionSignal, false);
speechExpressionAt(sorrowEntry.start * 1000, true, phraseState, sorrowEntry.plan,
  emotionSignal, false);
const scheduledSorrow = speechExpressionAt(sorrowEntry.start * 1000 + 360, true,
  phraseState, sorrowEntry.plan, emotionSignal, false);
assert.ok(scheduledLaugh.smile > .15 && scheduledSorrow.sorrowMouth > .45
  && scheduledSorrow.smile < .1,
  'the scheduler must crossfade from laughter into the next phrase-local emotion');
assert.match(source, /const LIVE_RIG_KEY = 'openclam-live-rig';/,
  'the calibration panel must be able to preview live brow/under-eye targets');
assert.match(source, /for \(const key of \['brows', 'eyebags'\]\)/);
assert.match(source, /const eyebagGain = rigExpressionGain\('eyebags', 35, 35\);/);
assert.match(source, /const upperFaceSpeaking = speaking && !reducedMotion\.matches;/);
assert.match(source, /const semanticEyeOpen = upperFaceSpeaking[\s\S]{0,420}l: Math\.max\(blink\.l \* \(1 - semanticEyeOpen \* \.92\), semanticSquint\),[\s\S]{0,100}r: Math\.max\(blink\.r \* \(1 - semanticEyeOpen \* \.92\), semanticSquint\),/,
  'fear and surprise must hold the eyes open while other semantic squint uses the eyelid atlas');
assert.match(source, /const drawStripState2D = /,
  'brow and forehead axes must interpolate instead of snapping');
assert.match(source, /if \(manifest\.forehead\) \{/,
  'the runtime must compose a real forehead\/glabella layer');
assert.ok(source.indexOf('if (manifest.gaze) {') < source.indexOf('if (manifest.eyebag) {'),
  'under-eye tissue must be composed after gaze so it remains visible');

// Reduced Motion covers the decorative blink path as well as speech targets:
// otherwise the blink-fed under-eye strip continues animating even though the
// speech scheduler is correctly still.  The next blink stays deferred while
// the preference is active, so opting back in cannot resume half a blink.
const blinkAmountSource = inline[1].match(
  /(const blinkAmounts = \(now, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(blinkAmountSource, 'blink helper must expose a reduced-motion gate');
const deterministicMath = Object.create(Math);
deterministicMath.random = () => 0.5;
const blinkProbe = new Function(
  'Math',
  `'use strict'; let blinkStartedAt = 0; let nextBlinkAt = 0; `
    + `let blinkEyeDelay = { l: 0, r: 0 }; ${blinkAmountSource[1]};`
    + 'return { blinkAmounts, state: () => ({ blinkStartedAt, nextBlinkAt, blinkEyeDelay }) };',
)(deterministicMath);
assert.deepEqual(blinkProbe.blinkAmounts(100, true), { l: 0, r: 0 },
  'Reduced Motion must suppress a pending eyelid/under-eye blink');
assert.equal(blinkProbe.state().blinkStartedAt, 0);
assert.ok(blinkProbe.state().nextBlinkAt >= 1100,
  'Reduced Motion must defer rather than preserve an in-progress blink');
assert.deepEqual(blinkProbe.blinkAmounts(200, true), { l: 0, r: 0 });
assert.ok(blinkProbe.state().nextBlinkAt >= 1200);

const offsetMath = Object.create(Math);
const offsetSamples = [0.5, 0.25, 0.5];
offsetMath.random = () => offsetSamples.shift() ?? 0.5;
const offsetProbe = new Function(
  'Math',
  `'use strict'; let blinkStartedAt = 0; let nextBlinkAt = 0; `
    + `let blinkEyeDelay = { l: 0, r: 0 }; ${blinkAmountSource[1]};`
    + 'return { blinkAmounts, state: () => ({ blinkStartedAt, nextBlinkAt, blinkEyeDelay }) };',
)(offsetMath);
offsetProbe.blinkAmounts(100, false);
const offsetBlink = offsetProbe.blinkAmounts(180, false);
assert.ok(offsetBlink.l > offsetBlink.r && offsetBlink.r > 0,
  'one eyelid must lead the other by a subtle randomized delay');
offsetProbe.blinkAmounts(500, false);
const followingInterval = offsetProbe.state().nextBlinkAt - 500;
assert.ok(followingInterval >= 1450 && followingInterval <= 4650,
  `runtime blink interval must stay attentive and irregular: ${followingInterval}`);
assert.match(source, /const blink = blinkAmounts\(now, reducedMotion\.matches\);/,
  'the face compositor must pass the preference into the blink/under-eye path');
assert.match(source, /const closure = eyelidClosure\[key\];/,
  'each eye must sample its own blink clock');

// Horizon Walk and either Edge Idle road are avatar-only presentation states.
// A rendered frame is the authority: missing assets/failures restore the UI,
// and Moves deliberately keeps the controls visible.
assert.match(source, /for \(const kind of \['walk', 'idle', 'move'\]\) await loadMotion\(kind\);/,
  'large motion atlases must load sequentially so one decode spike cannot silently drop Walk');
assert.match(source, /const ensureMotion = async kind => \{/);
assert.match(source, /const chatScopedFallback = kind === 'idle' && root\.classList\.contains\('chat-mode'\);/);
assert.match(source, /spec\.button\.disabled = !available;/,
  'an unauthored motion stays disabled except for the safe Chat\/Talk edge posture');
assert.match(source, /`\$\{spec\.label\} · Not built`/);
assert.doesNotMatch(source, /notify\('Build an? (?:Walk|Edge Idle|Moves) clip/,
  'motion capability feedback belongs inside its picker, never in an avatar-covering dark toast');
assert.match(source, /const chatWindowMotionFit = \(kind, meta, width, height, now, clip = null, edge = 'right'\) => \{/);
assert.match(source, /const viewport = chatAvatarSafeViewport\(\{ reserveComposer: true, reserveRail: true \}\);[\s\S]{0,100}const floor = Math\.max\(viewport\.y \+ 190, viewport\.bottom - 4\);/,
  'Chat\/Talk motion must use the rail-cleared composer-safe workspace bottom as its lower edge');
assert.match(source, /const motionTravelAtPhase = \(clip, phase\) => \{/);
assert.match(source, /const motionTravelSincePhase = \(clip, startPhase, elapsedSeconds\) => \{[\s\S]{0,620}motionTravelAtPhase\(clip, phase\) - motionTravelAtPhase\(clip, initial\);/,
  'Horizon Walk screen travel must use the authored gait trajectory rather than a fixed conveyor-belt duration');
assert.match(source, /const left = viewport\.x \+ 3;[\s\S]{0,120}viewport\.right - 3 - crop\.w \* scale/,
  'Chat\/Talk Horizon Walk must traverse the full central-workspace width');
assert.match(source, /A saved conversational drag must not shift Walk[\s\S]{0,180}const offset = \{ x: 0, y: 0 \};/,
  'the chat-window motion lane must remain independent from the speaking pose offset');
assert.match(source, /const advanceChatWalkState = \(state, now, walkClip, idleClip, span\) => \{[\s\S]{0,1500}runtime\.mode = `ledge-\$\{edge\}`;[\s\S]{0,180}motionRoundSeconds\(idleClip\) \* 1000/,
  'Chat\/Talk Horizon Walk must enter one authored Edge Idle round at each edge');
assert.match(source, /const chatWalk = inChat && manualMotionKind === 'walk'[\s\S]{0,180}presentedKind = chatWalk \? chatWalk\.kind/,
  'the manual Walk control must render the state machine\'s Walk or Edge Idle presentation');
assert.match(source, /const phase = chatScoped && kind === 'walk' \? fit\.phase/,
  'the traversing body frames and its lower-edge travel must share one gait phase');
assert.match(source, /anchors\[`\$\{displayEdge\}_frames`\][\s\S]{0,620}viewport\.right - 3 - rightSupport \* fit\.scale/,
  'authored Edge Idle must pin its measured support point directly to either central-workspace side');
assert.match(source, /drawAvatar\(now, `chat-edge-idle-\$\{idleEdge\}`\)/,
  'Edge Idle must fall back to a standing lean at the selected chat-window edge');
assert.match(source, /html\.avatar-only-motion #rail[\s\S]{0,160}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /html\.avatar-only-motion #chatDock,[\s\S]{0,220}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /html\.avatar-only-motion #emptyState[\s\S]{0,160}opacity: 0;[\s\S]{0,160}pointer-events: none;/);
assert.match(source, /transition-duration: 160ms;/);
assert.match(source, /@media \(prefers-reduced-motion: reduce\)[\s\S]{0,700}html\.avatar-only-motion #rail/);

const motionTravelAtPhaseSource = inline[1].match(
  /(const motionTravelAtPhase = \(clip, phase\) => \{[\s\S]*?\n    \};)/,
);
const motionCycleSecondsSource = inline[1].match(
  /(const motionCycleSeconds = clip =>[\s\S]*?\n      \|\| Math\.max[\s\S]*?\);)/,
);
const motionRoundSecondsSource = inline[1].match(
  /(const motionRoundSeconds = clip => \{[\s\S]*?\n    \};)/,
);
const motionTravelSincePhaseSource = inline[1].match(
  /(const motionTravelSincePhase = \(clip, startPhase, elapsedSeconds\) => \{[\s\S]*?\n    \};)/,
);
const createChatWalkStateSource = inline[1].match(
  /(const createChatWalkState = now => \(\{[\s\S]*?\n    \}\);)/,
);
const advanceChatWalkStateSource = inline[1].match(
  /(const advanceChatWalkState = \(state, now, walkClip, idleClip, span\) => \{[\s\S]*?\n    \};)/,
);
for (const [name, match] of [
  ['motion travel', motionTravelAtPhaseSource],
  ['motion cadence', motionCycleSecondsSource],
  ['motion round', motionRoundSecondsSource],
  ['phase-aware travel', motionTravelSincePhaseSource],
  ['chat walk initialiser', createChatWalkStateSource],
  ['chat walk state machine', advanceChatWalkStateSource],
]) assert.ok(match, `${name} helper must remain independently testable`);
const chatWalkProbe = new Function(
  `'use strict'; ${motionTravelAtPhaseSource[1]}; ${motionCycleSecondsSource[1]}; `
    + `${motionRoundSecondsSource[1]}; ${motionTravelSincePhaseSource[1]}; `
    + `${createChatWalkStateSource[1]}; ${advanceChatWalkStateSource[1]}; `
    + 'return { createChatWalkState, advanceChatWalkState, motionRoundSeconds };',
)();
const chatWalkClip = {
  cycle_seconds: 1, cycle_distance: 100, ground_speed: 100,
  frames: 10, fps: 10,
};
const chatIdleClip = { frames: 20, fps: 10 };
const chatWalkRuntime = chatWalkProbe.createChatWalkState(0);
let chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 1000, chatWalkClip, chatIdleClip, 250);
assert.deepEqual(
  {kind: chatWalkStep.kind, direction: chatWalkStep.direction, position: chatWalkStep.position},
  {kind: 'walk', direction: 1, position: 100},
  'Chat\/Talk must walk toward the right edge first');
chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 2500, chatWalkClip, chatIdleClip, 250);
assert.deepEqual(
  {kind: chatWalkStep.kind, edge: chatWalkStep.edge, position: chatWalkStep.position},
  {kind: 'idle', edge: 'right', position: 250},
  'reaching the right edge must enter Edge Idle instead of bouncing');
assert.equal(chatWalkRuntime.holdUntil, 4500,
  'the right edge must hold for exactly one authored Edge Idle round');
chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 4499, chatWalkClip, chatIdleClip, 250);
assert.equal(chatWalkStep.kind, 'idle');
chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 4500, chatWalkClip, chatIdleClip, 250);
assert.deepEqual(
  {kind: chatWalkStep.kind, direction: chatWalkStep.direction, position: chatWalkStep.position},
  {kind: 'walk', direction: -1, position: 250},
  'one idle round later the avatar must turn and walk toward the opposite edge');
chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 7000, chatWalkClip, chatIdleClip, 250);
assert.deepEqual(
  {kind: chatWalkStep.kind, edge: chatWalkStep.edge, position: chatWalkStep.position},
  {kind: 'idle', edge: 'left', position: 0},
  'the return traversal must enter Edge Idle at the left chat-window edge');
chatWalkStep = chatWalkProbe.advanceChatWalkState(
  chatWalkRuntime, 9000, chatWalkClip, chatIdleClip, 250);
assert.deepEqual(
  {kind: chatWalkStep.kind, direction: chatWalkStep.direction, position: chatWalkStep.position},
  {kind: 'walk', direction: 1, position: 0},
  'the full Walk–Idle cycle must continue back toward the right edge');

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
  'motionPhaseAt', 'beginMotionPresentation', 'clearStage', 'root',
  'manualMotionKind', 'chatWindowMotionFit',
  `'use strict'; let paintedMotionKey = ''; ${motionFrameSource[1]}; ${drawMotionSource[1]}; return drawMotion;`,
)(walkMotion, () => ({ x: 0, y: 0, scale: 1 }),
  { enabled: true, mode: 'walk', direction: 1, phase: 0.5, sampledAt: performance.timeOrigin },
  paintContext, 1, 200, motionPhaseAt, kind => `${kind}:`, () => {},
  { classList: { contains: () => false } }, null, () => ({ x: 0, y: 0, scale: 1 }));
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
  'motionPhaseAt', 'beginMotionPresentation', 'clearStage', 'root',
  'manualMotionKind', 'chatWindowMotionFit',
  `'use strict'; let paintedMotionKey = ''; ${motionFrameSource[1]}; ${drawMotionSource[1]}; return drawMotion;`,
)(
  {move: {video: endedVideo, fps: 12, frames: 73, frame_width: 20, frame_height: 30, bounds: [0, 0, 20, 30]}},
  () => ({x: 0, y: 0, scale: 1}),
  {enabled: true, mode: 'idle', direction: 1}, endedContext, 1, 200,
  motionPhaseAt, () => 'move:', () => {},
  {classList: {contains: () => false}}, null, () => ({x: 0, y: 0, scale: 1}),
);
assert.equal(endedPainter('move', 7000), true);
assert.equal(endedPaints.length, 1, 'the final decoded Move frame must remain visible');
assert.equal(replayCalls, 0, 'the final decoded Move frame must not restart');

// Each mode owns its avatar canvas. Close-Up is the same bottom-right camera
// intent inside either the Chat/Talk window or the selected desktop display;
// ten seconds of genuine Chat inactivity selects the nearest window edge.
const numericAvatarZoomSource = inline[1].match(
  /(const numericAvatarZoom = \(value, fallback = 1\) => \{[\s\S]*?\n    \};)/,
);
const chatCloseUpGeometrySource = inline[1].match(
  /(const chatCloseUpGeometry = \(crop, viewportWidth, viewportHeight, zoom = 1\) => \{[\s\S]*?\n    \};)/,
);
const chatStandbyEdgeSource = inline[1].match(
  /(const chatStandbyEdge = value =>[^;]+;)/,
);
const standbyIdleDelaySource = inline[1].match(
  /(const standbyIdleDelay = inChat =>[^;]+;)/,
);
assert.ok(chatCloseUpGeometrySource, 'Chat\/Talk close-up geometry must remain independently testable');
assert.ok(numericAvatarZoomSource, 'numeric zoom validation must remain independently testable');
assert.ok(chatStandbyEdgeSource, 'Chat\/Talk idle edge selection must remain independently testable');
assert.ok(standbyIdleDelaySource, 'Chat\/Talk standby timing must remain independently testable');
const chatCloseUpGeometry = new Function(
  `'use strict'; ${numericAvatarZoomSource[1]}; ${chatCloseUpGeometrySource[1]}; return chatCloseUpGeometry;`,
)();
const chatStandbyEdge = new Function(
  `'use strict'; ${chatStandbyEdgeSource[1]}; return chatStandbyEdge;`,
)();
const standbyIdleDelay = new Function(
  `'use strict'; ${standbyIdleDelaySource[1]}; return standbyIdleDelay;`,
)();
const closeUp = chatCloseUpGeometry({x: 100, y: 50, w: 600, h: 900}, 1180, 860, 1);
const closeUpTop = closeUp.y + 50 * closeUp.scale;
const closeUpRight = closeUp.x + 700 * closeUp.scale;
const closeUpBottom = closeUp.y + 950 * closeUp.scale;
assert.ok(closeUpTop > 860 * .15 && closeUpTop < 860 * .35,
  'Chat\/Talk close-up must read as head-and-shoulders rather than a full-body fit');
assert.ok(closeUpRight > 1180 && closeUpBottom > 860,
  'Chat\/Talk close-up must crop softly through the right and bottom window edges');
const zoomedCloseUp = chatCloseUpGeometry({x: 100, y: 50, w: 600, h: 900}, 1180, 860, 1.5);
assert.ok(zoomedCloseUp.scale > closeUp.scale * 1.49,
  'pinch zoom must adjust the close-up preset rather than being discarded');
assert.match(source, /if \(fullChat && shellState\.chatCloseUp\)[\s\S]{0,520}requestedZoom \/ baseZoom[\s\S]{0,360}fit\.x \+ offset\.x[\s\S]{0,120}fit\.y \+ offset\.y/,
  'Chat\/Talk close-up must retain its own zoom baseline and dragged position');
assert.match(source, /if \(safeDesktop && shellState\.desktopCloseUp\)/,
  'the same close-up camera must be scoped to each mode\'s own canvas');
assert.match(source, /openclam\.chat\.close-up-offset\.v1/,
  'the close-up drag position must persist independently from standard framing');
assert.match(source, /const chatPoseRevisionChanged = Number\(value\.chatPoseRevision \|\| 0\)[\s\S]{0,160}Number\(shellState\.chatPoseRevision \|\| 0\)/,
  'an explicit close-up or standby selection must remain observable when its Boolean state is unchanged');
assert.match(source, /if \(closeUpChanged \|\| chatPoseRevisionChanged \|\| factoryResetChanged\) \{[\s\S]{0,220}clearLocalTransientDisplayMode\(\);[\s\S]{0,140}markActivity\(\{ preserveDisplayMode: true \}\);/,
  're-selecting a saved pose must immediately leave its temporary edge-idle presentation');
assert.match(source, /const factoryResetChanged = Number\(value\.factoryResetRevision \|\| 0\)[\s\S]{0,180}Number\(shellState\.factoryResetRevision \|\| 0\)/,
  'the explicit factory-reset action must publish a reset revision even when the current mode Boolean is unchanged');
assert.match(source, /if \(factoryResetChanged\) \{[\s\S]{0,420}chatAvatarOffsets\.standard = \{ x: 0, y: 0 \};[\s\S]{0,320}localStorage\.removeItem\('openclam\.chat\.avatar-offset\.v1'\)/,
  'factory reset must clear the remembered Chat\/Talk drag position rather than restoring it');
assert.match(source, /const resumeChatSpeakingPose = \(\) => \{[\s\S]{0,100}markActivity\(\);[\s\S]{0,80}lastFrame = 0;/,
  'conversation activity must resume the saved speaking pose from temporary Edge Idle');
assert.match(source, /const submitComposer = \(\) => \{[\s\S]{0,420}resumeChatSpeakingPose\(\);/,
  'sending a message must retain the selected close-up\/zoom\/drag pose');
assert.match(playSpeechSource[1],
  /speechSource = source;[\s\S]*?resumeChatSpeakingPose\(\);[\s\S]*?source\.onended[\s\S]*?resumeChatSpeakingPose\(\);/,
  'TTS start and end must restore the saved pose and restart the idle timer');
assert.equal(chatStandbyEdge({x: -1}), 'left');
assert.equal(chatStandbyEdge({x: 0}), 'right');
assert.equal(standbyIdleDelay(true), 10000,
  'Chat\/Talk Edge Idle must begin after ten seconds of inactivity');
assert.equal(standbyIdleDelay(false), 12000,
  'Avatar-mode automatic edge timing remains unchanged');
assert.match(source, /const edgeIdleActive = now => \{[\s\S]{0,420}\(motion\.idle \|\| inChat\)/,
  'Chat\/Talk must retain a standing-lean fallback when no authored idle clip is loaded');
assert.match(source, /if \(hit && !root\.classList\.contains\('chat-mode'\)\) markActivity\(\);/,
  'a stationary cursor inside Chat\/Talk must not keep resetting its idle timer');
assert.match(source, /const markActivity = \(\{ preserveDisplayMode = false \} = \{\}\) => \{[\s\S]{0,220}!preserveDisplayMode && exitTransientDisplayMode\(\)/,
  'avatar hover and ordinary chat activity must leave Walk, Edge Idle, or Moves');
assert.match(source, /const exitTransientDisplayMode = \(\) => \{[\s\S]{0,260}roaming \|\| manualMotionKind \|\| moveUntil > performance\.now\(\) \|\| idleDocked[\s\S]{0,260}clearLocalTransientDisplayMode\(\)/,
  'all temporary display modes must share one exit-to-Standby path');
assert.match(source, /Promise\.resolve\(shell\.setDisplayMode\('standby'\)\)/,
  'desktop Horizon Walk hover must ask Electron to restore its remembered Standby window');
assert.match(source, /const prepareTransientDisplayMode = async kind => \{[\s\S]{0,360}clearLocalTransientDisplayMode\(\);[\s\S]{0,120}await selectShellDisplayMode\('standby'\);/,
  'every temporary mode must start from remembered Standby, never mutate its camera geometry');
assert.match(source, /const saveChatAvatarOffset = \(\) => \{[\s\S]{0,800}chatAvatarOffsets\[presentation\] = \{ \.\.\.chatAvatarOffset \};[\s\S]{0,220}localStorage\.setItem\(key, JSON\.stringify\(chatAvatarOffset\)\)/,
  'a user drag in Standby must remain the next remembered Standby position');
assert.match(drawMotionSource[1], /anchors\[`\$\{displayEdge\}_frames`\]/,
  'Chat\/Talk Edge Idle must use authored anchors for both window edges');
assert.match(source, /#conversation::\-webkit-scrollbar \{[\s\S]{0,100}display: none;[\s\S]{0,100}width: 0;/,
  'the Chat\/Talk thread must scroll without painting a Chromium scrollbar');
assert.match(source, /#conversation \{[\s\S]{0,500}scrollbar-width: none;/,
  'the Chat\/Talk thread must also hide standards-based scrollbars');

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
assert.match(source, /if \(changed\) \{\s*lastFrame = 0;/,
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
  'context', 'pixelRatio', 'root', 'canvas', 'interactionLayer', 'markActivity', 'performance',
  `'use strict'; let dragging = false; let ptt = null; let avatarHit = false; `
    + `let petHit = false; let lastHitSent = 0; let avatarZoomGesture = null; ${updateHitSource[1]}; `
    + 'return { updateHit, avatar: () => avatarHit };',
)(
  { setPetHit: value => hitCalls.push(value) }, () => true,
  { x: 50, y: 50, inside: true }, true, 100, 100,
  { getImageData: () => ({ data: [0, 0, 0, 255] }) }, 1,
  { classList: {
    contains: () => false,
    toggle: (name, active) => hoverClasses.push([name, active]),
  } },
  { style: { opacity: '1' } }, 'thread',
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
  'shell', 'overControls', 'pointer', 'paintedAvatarAt', 'root', 'canvas',
  'interactionLayer', 'markActivity', 'performance',
  `'use strict'; let dragging = false; let ptt = null; let avatarHit = false; `
    + `let petHit = false; let lastHitSent = 0; let avatarZoomGesture = { frame: 0 }; `
    + `${updateHitSource[1]}; `
    + `return { update: () => updateHit(true), release: () => { avatarZoomGesture = null; updateHit(true); } };`,
)(
  { setPetHit: value => zoomHitCalls.push(value) }, () => false,
  { x: 50, y: 50, inside: true }, () => false,
  { classList: { contains: () => false, toggle() {} } },
  { style: { opacity: '1' } }, 'thread', () => {}, { now: () => 1000 },
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

// The replacement head and body must remain one rigid upright plate. Lip sync,
// gaze, upper-face expression and a tiny breath remain separate face/life
// channels, so removing tilt cannot flatten the avatar.
const bodyMotionSource = inline[1].match(
  /(const bodyMotionAt = \(now, speaking, state, reduce = false\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(bodyMotionSource, 'body-motion envelope must remain independently testable');
const bodyMotionAt = new Function(
  `'use strict'; ${bodyMotionSource[1]}; return bodyMotionAt;`,
)();
let speakingBreath = 0;
let idleBreath = 0;
const steadySpeechState = { speechBlend: 1, at: 1 };
const steadyIdleState = { speechBlend: 0, at: 1 };
for (let time = 25; time <= 20_000; time += 25) {
  const speaking = bodyMotionAt(time, true, steadySpeechState, false);
  const idle = bodyMotionAt(time, false, steadyIdleState, false);
  assert.equal(speaking.sway, 0, 'speech must never tilt the body/head plate');
  assert.equal(idle.sway, 0, 'idle life must never tilt the body/head plate');
  speakingBreath = Math.max(speakingBreath, Math.abs(speaking.breathe - 1));
  idleBreath = Math.max(idleBreath, Math.abs(idle.breathe - 1));
}
assert.ok(speakingBreath <= .000901, `speaking breath is too large: ${speakingBreath}`);
assert.ok(idleBreath > speakingBreath * 2,
  'idle breathing may remain more visible than the calm speech breath');
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
const drawAvatarSource = inline[1].match(
  /(const drawAvatar = \(now, presentation = ''\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(drawAvatarSource, 'avatar compositor must remain independently inspectable');
assert.doesNotMatch(drawAvatarSource[1], /context\.rotate|conversationalPose|headRoll|headYaw|headPitch/,
  'standby and edge presentation must never add body sway or conversational head tilt');
assert.match(drawAvatarSource[1], /context\.scale\(breathe, 1\);/,
  'upright registration must retain the subtle breathing channel');

// Flat cartoon line art cannot use the photographic identity dissolve: the
// generated body's ear/jaw strokes show through the live head as duplicate
// anatomy. The replacement path is deliberately metadata-gated so Cleo and
// every other photographic/legacy avatar retain their reviewed compositor.
const bodyHeadModeSource = inline[1].match(
  /(const bodyHeadCompositeMode = body => \{[\s\S]*?\n    \};)/,
);
assert.ok(bodyHeadModeSource, 'body/head composite policy must remain independently testable');
const bodyHeadCompositeMode = new Function(
  `'use strict'; ${bodyHeadModeSource[1]}; return bodyHeadCompositeMode;`,
)();
assert.equal(bodyHeadCompositeMode({options: {medium: 'anime'}}), 'replace');
assert.equal(bodyHeadCompositeMode({options: {medium: 'illustration'}}), 'replace');
assert.equal(bodyHeadCompositeMode({head_composite: 'replace'}), 'replace');
assert.equal(bodyHeadCompositeMode({options: {style: 'illustrated'}}), 'blend',
  'requested style alone must never opt a photo/legacy body into replacement');
assert.equal(bodyHeadCompositeMode({options: {medium: 'corrupt-future-value', style: 'anime'}}), 'blend',
  'unknown stored media must fail closed even when style requests anime');
assert.equal(bodyHeadCompositeMode({options: {medium: 'photograph', style: 'illustrated'}}), 'blend',
  'an explicit photograph must retain the legacy soft compositor regardless of style metadata');
assert.equal(bodyHeadCompositeMode({options: {medium: 'photograph'}}), 'blend',
  'Cleo and other photographic rigs must remain pixel-path compatible');
assert.equal(bodyHeadCompositeMode({}), 'blend',
  'unknown and legacy packages must not opt themselves into cartoon replacement');

// Drawn line art is discrete. Crossfading two mouth or eyelid drawings makes
// doubled lips and a smaller artificial eye for at least one captured frame.
const stylizedVisemeSelectorSource = inline[1].match(
  /(const selectStylizedVisemeImage = \(oldImage, newImage, blend\) => \([\s\S]*?\n    \);)/,
);
assert.ok(stylizedVisemeSelectorSource,
  'the stylized mouth-frame selector must remain independently testable');
const selectStylizedVisemeImage = new Function(
  `'use strict'; ${stylizedVisemeSelectorSource[1]}; return selectStylizedVisemeImage;`,
)();
const oldMouth = { id: 'old' };
const newMouth = { id: 'new' };
assert.equal(selectStylizedVisemeImage(oldMouth, newMouth, .49), oldMouth,
  'a stylized mouth must retain exactly one old drawing before the midpoint');
assert.equal(selectStylizedVisemeImage(oldMouth, newMouth, .50), newMouth,
  'a stylized mouth must hard-switch to exactly one new drawing at the midpoint');

const stylizedEmotionMouthSource = inline[1].match(
  /(const stylizedEmotionMouthSample = \(\n      states, rows, amount, emotionIndex, oldName, newName, blend\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(stylizedEmotionMouthSource,
  'the stylized emotional-mouth selector must remain independently testable');
const stylizedEmotionMouthSample = new Function(
  `'use strict'; const nearestIndex = (values, target) => values.reduce((best, value, index) => Math.abs(value - target) < Math.abs(values[best] - target) ? index : best, 0); ${stylizedEmotionMouthSource[1]}; return stylizedEmotionMouthSample;`,
)();
assert.deepEqual(
  stylizedEmotionMouthSample([0, .34, .68, 1], ['sil', 'aa'], .52, 2,
    'sil', 'aa', .49),
  { state: 2, row: 4, weight: 1 },
  'stylized emotion speech must select one old viseme/strength cell');
assert.deepEqual(
  stylizedEmotionMouthSample([0, .34, .68, 1], ['sil', 'aa'], .52, 2,
    'sil', 'aa', .50),
  { state: 2, row: 5, weight: 1 },
  'stylized emotion speech must hard-switch to one new viseme cell');

const stylizedEmotionPlacementSource = inline[1].match(
  /(const stylizedEmotionMouthPlacement = \(\n      spec, sample, selectedName\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(stylizedEmotionPlacementSource,
  'the stylized emotion-mouth crop/registration must remain independently testable');
const stylizedEmotionMouthPlacement = new Function(
  'runtimeBox', 'stylizedVisemeGeometry', 'stylizedMouthRegistration',
  `'use strict'; ${stylizedEmotionPlacementSource[1]}; return stylizedEmotionMouthPlacement;`,
)(
  value => value && value.box,
  () => [397, 662, 237, 121],
  name => (name === 'aa' ? -20 : 0),
);
assert.deepEqual(
  stylizedEmotionMouthPlacement(
    { box: [385, 631, 260, 145], states: [0, .34, .68, 1] },
    { state: 2, row: 5, weight: 1 },
    'aa',
  ),
  {
    sourceX: 32,
    sourceY: 3221,
    sourceWidth: 228,
    sourceHeight: 114,
    patchX: 0,
    patchY: 0,
    width: 237,
    height: 121,
    destinationX: 397,
    destinationY: 662,
  },
  'stylized emotion cells must clip to their own cell while retaining the full nose-safe lip box',
);
assert.match(source,
  /const drawStylizedEmotionMouthSample = \([\s\S]{0,1000}prepareStylizedMouthPatch\([\s\S]{0,160}image, spec, sample\);/,
  'stylized emotional mouths must resolve against their own viseme using the same lip ownership as speech');
assert.match(source, /if \(stylizedRuntime && !stylizedMouthDrawn\)/,
  'exactly one resolved stylized mouth may be painted over the canonical face');

const stylizedMouthMaskSource = inline[1].match(
  /(const stylizedMouthMaskAlpha = \(x, y, width, height\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(stylizedMouthMaskSource,
  'the stylized mouth handoff mask must remain independently testable');
const stylizedMouthMaskAlpha = new Function(
  `'use strict'; const expressionSmoothStep = value => { const amount = Math.max(0, Math.min(1, Number(value) || 0)); return amount * amount * (3 - 2 * amount); }; ${stylizedMouthMaskSource[1]}; return stylizedMouthMaskAlpha;`,
)();
assert.ok(stylizedMouthMaskAlpha(49, 51, 100, 100) > .99,
  'the authored lip core must be fully replaced');
assert.ok(stylizedMouthMaskAlpha(49, 0, 100, 100) < .01,
  'the provider patch must disappear before it reaches the nose');
assert.equal(stylizedMouthMaskAlpha(0, 0, 100, 100), 0,
  'the provider patch must have no rectangular corner coverage');
for (const [x, y] of [[41, 36], [202, 32], [40, 15], [122, 102]]) {
  assert.equal(stylizedMouthMaskAlpha(x, y, 242, 124), 1,
    'the entire neutral/voiced corner and lip union must be owned, not feathered');
}

const stylizedMouthToneSource = inline[1].match(
  /(const stylizedMouthToneShift = \(source, target, limit = 24\) => \([\s\S]*?\n    \);)/,
);
assert.ok(stylizedMouthToneSource,
  'the stylized mouth colour handoff must remain independently testable');
const stylizedMouthToneShift = new Function(
  `'use strict'; ${stylizedMouthToneSource[1]}; return stylizedMouthToneShift;`,
)();
assert.deepEqual(stylizedMouthToneShift([100, 200, 250], [160, 150, 0]),
  [24, -24, -24], 'provider skin correction must stay bounded');

const faceEyelidPolicySource = inline[1].match(
  /(const faceEyelidPolicy = \(stylized, stylizedBlinkReady, closure\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(faceEyelidPolicySource,
  'the cartoon/photo eyelid policy must remain independently testable');
const faceEyelidPolicy = new Function(
  `'use strict'; ${faceEyelidPolicySource[1]}; return faceEyelidPolicy;`,
)();
assert.equal(faceEyelidPolicy(true, false, 1), 'static-canonical',
  'a rejected/missing cartoon blink must keep the canonical full-size eyes');
assert.equal(faceEyelidPolicy(true, true, .77), 'static-canonical',
  'cartoon open and closed eye drawings must not be blended');
assert.equal(faceEyelidPolicy(true, true, .78), 'stylized-closed',
  'a reviewed semantic cartoon blink may switch only near full closure');
assert.equal(faceEyelidPolicy(false, false, 1), 'photo-strip',
  'photorealistic avatars must retain their existing smooth eyelid strips');

const hardenMaskSource = inline[1].match(
  /(const hardenMaskAlpha = \(pixels, threshold = 32\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(hardenMaskSource, 'stylized replacement matte must remain independently testable');
const hardenMaskAlpha = new Function(
  `'use strict'; ${hardenMaskSource[1]}; return hardenMaskAlpha;`,
)();
const replacementPixels = new Uint8ClampedArray([
  1, 2, 3, 0,
  4, 5, 6, 31,
  7, 8, 9, 32,
  10, 11, 12, 255,
]);
assert.equal(hardenMaskAlpha(replacementPixels), 2);
assert.deepEqual([...replacementPixels], [
  255, 255, 255, 0,
  255, 255, 255, 0,
  255, 255, 255, 255,
  255, 255, 255, 255,
]);
const preserveMaskSource = inline[1].match(
  /(const preserveMaskAlpha = pixels => \{[\s\S]*?\n    \};)/,
);
assert.ok(preserveMaskSource,
  'the authored jaw/neck feather must remain independently testable');
const preserveMaskAlpha = new Function(
  `'use strict'; ${preserveMaskSource[1]}; return preserveMaskAlpha;`,
)();
const featherPixels = new Uint8ClampedArray([
  1, 2, 3, 17,
  4, 5, 6, 128,
]);
assert.equal(preserveMaskAlpha(featherPixels), 2);
assert.deepEqual([...featherPixels], [
  255, 255, 255, 17,
  255, 255, 255, 128,
], 'a marker-v4 stylized body must retain the authored under-jaw alpha ramp');
const authoredHandoffSource = inline[1].match(
  /(const authoredHeadHandoffReady = \(body, clearMask, authoredMask\) => Boolean\([\s\S]*?\n      && body\.head_clear_mask && clearMask && authoredMask\);)/,
);
assert.ok(authoredHandoffSource,
  'the jaw handoff version gate must remain independently testable');
const authoredHeadHandoffReady = new Function(
  `'use strict'; const STYLIZED_HEAD_HANDOFF_VERSION = 4; ${authoredHandoffSource[1]}; return authoredHeadHandoffReady;`,
)();
const legacyHandoff = {
  head_composite: 'replace', head_clear_mask: 'assets/head-clear-mask.png',
};
const currentHandoff = {
  ...legacyHandoff, head_handoff_version: 4,
};
assert.equal(authoredHeadHandoffReady(legacyHandoff, {}, {}), false,
  'unversioned bodies must not claim the new v4 authoring contract');
assert.equal(authoredHeadHandoffReady(currentHandoff, {}, {}), true,
  'the reviewed v4 authored jaw handoff must preserve its alpha ramp');
assert.equal(authoredHeadHandoffReady(
  { ...legacyHandoff, head_handoff_version: 2 }, {}, {}), false,
  'v2 compatibility must not claim current v4 authoring');
assert.equal(authoredHeadHandoffReady(
  { ...legacyHandoff, head_handoff_version: 3 }, {}, {}), false,
  'v3 compatibility must not claim current v4 authoring');
assert.equal(authoredHeadHandoffReady(
  { ...legacyHandoff, head_handoff_version: 5 }, {}, {}), false,
  'future handoff versions must fail closed');
assert.match(source, /const replacementSource = authoredHandoff \|\| recoveredLegacyHandoff\n          \? headMask : \(cutoutImage \|\| headMask\);/,
  'a coordinated current or narrowly recovered stylized body must use its authored full-head/jaw handoff mask');
assert.match(source, /\? preserveMaskAlpha\(matte\.data\)\n          : hardenMaskAlpha\(matte\.data\)/,
  'only legacy stylized packages may harden the complete cutout fallback');
assert.match(source, /headReplacementContext\.drawImage\(\n          replacementSource/,
  'the selected complete stylized silhouette must become the live head matte');

// Execute the actual compositor setup, not just a version predicate: a cached
// v23 runtime can still contain a reviewed v2/v3 mask pair after an app update.
// Its paired feather must not silently become the wider, hardened neck cutout.
const handoffPolicySource = inline[1].match(
  /(const STYLIZED_SOURCE_MEDIA = new Set\([\s\S]*?const isStylizedFaceRuntime = value => \{[\s\S]*?\n    \};)/,
);
const compatibleHandoffSource = inline[1].match(
  /(const compatibleLegacyHeadHandoffReady = \([\s\S]*?&& body\.head_mask && body\.head_clear_mask && clearMask && authoredMask\);)/,
);
const unversionedHandoffSource = inline[1].match(
  /(const legacyStylizedHeadHandoffReady = \([\s\S]*?&& runtimeBox\(runtime\.stylized_mouth\)\);)/,
);
const prepareHandoffSource = inline[1].match(
  /(const prepareHeadReplacementMask = body => \{[\s\S]*?\n    \};)/,
);
for (const extracted of [handoffPolicySource, compatibleHandoffSource,
  unversionedHandoffSource, prepareHandoffSource]) {
  assert.ok(extracted, 'the complete mask-selection path must remain testable');
}
const prepareHandoffFixture = new Function('manifest', 'headMask', 'bodyHeadClearMask',
  `'use strict';
  const STYLIZED_HEAD_HANDOFF_VERSION = 4;
  const runtimeBox = value => Array.isArray(value && value.box)
    && value.box.length === 4 ? value.box : null;
  ${handoffPolicySource[1]}
  ${bodyHeadModeSource[1]}
  ${authoredHandoffSource[1]}
  ${compatibleHandoffSource[1]}
  ${unversionedHandoffSource[1]}
  ${hardenMaskSource[1]}
  ${preserveMaskSource[1]}
  let headReplacementActive = false;
  const portraitWidth = 2, portraitHeight = 1;
  const headReplacementCanvas = {};
  const cutoutImage = {id: 'wide-neck-cutout',
    pixels: new Uint8ClampedArray([1, 2, 3, 255, 4, 5, 6, 255])};
  const selected = [];
  let pixels = new Uint8ClampedArray(8);
  const headReplacementContext = {
    setTransform() {}, clearRect() { pixels.fill(0); },
    drawImage(image) { selected.push(image.id); pixels = image.pixels.slice(); },
    getImageData() { return {data: pixels}; },
    putImageData(image) { pixels = image.data; }
  };
  ${prepareHandoffSource[1]}
  prepareHeadReplacementMask(manifest.body);
  return {selected, alpha: [pixels[3], pixels[7]], active: headReplacementActive};
`);
const pairedHandoff = {
  ...legacyHandoff, head_mask: 'assets/head-mask.png',
};
const authoredFeather = {id: 'authored-jaw-feather',
  pixels: new Uint8ClampedArray([1, 2, 3, 17, 4, 5, 6, 128])};
const preparedMask = (body, medium = '3d render', head = authoredFeather,
  clear = {}, extra = {}) => prepareHandoffFixture(
  {v: 23, source_medium: medium, body, ...extra}, head, clear);
const authoredResult = {
  selected: ['authored-jaw-feather'], alpha: [17, 128], active: true,
};
const fallbackResult = {
  selected: ['wide-neck-cutout'], alpha: [255, 255], active: true,
};
for (const version of [2, 3, 4]) {
  for (const medium of ['3d render', 'illustration']) {
    assert.deepEqual(preparedMask({...pairedHandoff, head_handoff_version: version}, medium),
      authoredResult, `known v${version} ${medium} must keep its paired authored neck feather`);
  }
}
for (const version of [0, 1, 5, 2.5, '2', '3', null, true]) {
  assert.deepEqual(preparedMask({...pairedHandoff, head_handoff_version: version}),
    fallbackResult, `unknown/malformed handoff ${JSON.stringify(version)} must not gain compatibility`);
}
for (const version of [2, 3]) {
  const body = {...pairedHandoff, head_handoff_version: version};
  for (const medium of ['photograph', 'unknown', 'corrupt-future-value', null]) {
    assert.deepEqual(preparedMask(body, medium), fallbackResult,
      'known old mask versions must not override non-stylized classification');
  }
  assert.deepEqual(preparedMask({...body, head_mask: null}), fallbackResult);
  assert.deepEqual(preparedMask({...body, head_clear_mask: null}), fallbackResult);
  assert.deepEqual(preparedMask(body, '3d render', null), fallbackResult);
  assert.deepEqual(preparedMask(body, '3d render', authoredFeather, null), fallbackResult);
}
assert.deepEqual(preparedMask(pairedHandoff), fallbackResult,
  'unversioned bundles must not gain a new unconditional compatibility path');
assert.deepEqual(preparedMask(pairedHandoff, '3d render', authoredFeather, {}, {
  stylized_mouth: {basis: 'canonical-outer-lip-v1', box: [1, 2, 3, 4]},
}), authoredResult, 'the existing narrow unversioned handoff recovery must stay unchanged');
assert.deepEqual(preparedMask({options: {medium: 'photograph'}}, 'photograph'),
  {selected: [], alpha: [0, 0], active: false},
  'the ordinary photo compositor must not prepare a replacement mask');

const drawBodyHeadSource = inline[1].match(
  /(const drawBodyHeadLayer = \(target, head, replacementMask, mode, width, height\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(drawBodyHeadSource, 'body/head draw order must remain independently testable');
const drawBodyHeadLayer = new Function(
  `'use strict'; ${drawBodyHeadSource[1]}; return drawBodyHeadLayer;`,
)();
const headDrawCalls = [];
const headTarget = {
  globalCompositeOperation: 'source-over',
  stack: [],
  save() { this.stack.push(this.globalCompositeOperation); },
  restore() { this.globalCompositeOperation = this.stack.pop(); },
  drawImage(image) { headDrawCalls.push([image, this.globalCompositeOperation]); },
};
drawBodyHeadLayer(headTarget, 'animated-head', 'replacement-matte', 'replace', 1024, 1024);
assert.deepEqual(headDrawCalls, [
  ['replacement-matte', 'destination-out'],
  ['animated-head', 'source-over'],
], 'cartoon matte must erase the provider face before the one animated face is painted');
headDrawCalls.length = 0;
drawBodyHeadLayer(headTarget, 'cleo-head', 'unused-matte', 'blend', 1024, 1024);
assert.deepEqual(headDrawCalls, [['cleo-head', 'source-over']],
  'photographic heads must keep the unchanged single soft-blend draw');
assert.match(source, /if \(cutoutImage && !headReplacementActive\) \{/,
  'cartoon replacement must not pre-soften its hard silhouette with the photographic cutout');
assert.match(source, /const liveHeadMask = headReplacementActive \? headReplacementCanvas : headMask;/);
assert.match(source, /prepareHeadReplacementMask\(manifest\.body\);/);
assert.match(source, /loadImage\(manifest\.body\.head_clear_mask\)[\s\S]{0,100}bodyHeadClearMask = image/,
  'current stylized packages must load their authored body-space anatomy eraser');
assert.match(source, /const eraseBodyHeadAnatomy = \(target, clearMask, mode, width, height\) => \{/,
  'body-space anatomy erasure must remain an explicit compositor stage');
assert.match(source, /const erasedInBodySpace = eraseBodyHeadAnatomy\(\n          context, bodyHeadClearMask, compositeMode, width, height\);/,
  'the provider ears, cheeks and jaw must be erased before the face transform');
assert.match(source, /!erasedInBodySpace && headReplacementActive \? headReplacementCanvas : null/,
  'the transformed legacy eraser must not run on top of the authored body-space mask');

// Electron reports a macOS trackpad pinch as Ctrl+wheel. Only that modifier
// path changes size; ordinary scrolling is left alone. Values use the same
// canonical stand/roam policy as the persisted main-process geometry: no
// user-facing Standby/Close-up ceiling, bounded animation zoom unchanged.
const pinchZoomSource = inline[1].match(
  /(const pinchZoomValue = \(current, event, range, viewportHeight\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(pinchZoomSource, 'pinch zoom transform must remain independently testable');
const pinchZoomValue = new Function(
  `'use strict'; ${numericAvatarZoomSource[1]}; ${pinchZoomSource[1]}; return pinchZoomValue;`,
)();
assert.equal(pinchZoomValue(1, { ctrlKey: false, deltaY: -30 }, {}, 800), 1,
  'ordinary wheel input must never resize the avatar');
assert.ok(pinchZoomValue(16, { ctrlKey: true, deltaY: -20, deltaMode: 0 }, {}, 800) > 16);
assert.ok(pinchZoomValue(.08, { ctrlKey: true, deltaY: 20, deltaMode: 0 }, {}, 800) < .08);
assert.ok(pinchZoomValue(4, { ctrlKey: true, deltaY: -100, deltaMode: 2 }, {}, 800) > 4);
assert.equal(pinchZoomValue(.6, { ctrlKey: true, deltaY: 100, deltaMode: 2 }, { min: .5, max: 3 }, 800), .5);
assert.match(source, /if \(!event\.ctrlKey \|\| !shell \|\| typeof shell\.setPetZoomLive !== 'function'/,
  'the renderer must accept only Chromium\'s pinch-shaped modifier wheel');
const paintedAvatarSource = inline[1].match(
  /(const paintedAvatarAt = point => \{[\s\S]*?\n    \};)/,
);
assert.ok(paintedAvatarSource, 'fresh alpha acceptance must remain independently testable');
const sampledPixels = [];
const paintedAvatarAt = new Function(
  'ready', 'innerWidth', 'innerHeight', 'context', 'pixelRatio', 'avatarCanvasPoint',
  `'use strict'; ${paintedAvatarSource[1]}; return paintedAvatarAt;`,
)(true, 100, 100, {
  getImageData: (...args) => { sampledPixels.push(args); return { data: [0, 0, 0, 19] }; },
}, 2, point => point);
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

// A single painted-body tap keeps the two direct opacity gestures: chest
// raises opacity and the lower body lowers it. Head gestures are reserved for
// hold-to-PTT and double-click Live Talk, while motion lives in the menu.
const avatarTapSource = inline[1].match(
  /(const avatarBodyTapAction = \(local, geometry\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(avatarTapSource, 'body-relative tap policy must remain independently testable');
const avatarBodyTapAction = new Function(
  `'use strict'; ${avatarTapSource[1]}; return avatarBodyTapAction;`,
)();
const clickGeometry = {
  hasBody: true, width: 100, height: 100,
  metadata: { bounds: [20, 0, 60, 100], alignment: { face_bounds: [40, 5, 20, 20] } },
};
assert.equal(avatarBodyTapAction({ x: 50, y: 10 }, clickGeometry), null);
assert.equal(avatarBodyTapAction({ x: 50, y: 35 }, clickGeometry), 'opacity-up');
assert.equal(avatarBodyTapAction({ x: 50, y: 60 }, clickGeometry), 'opacity-down');
assert.equal(avatarBodyTapAction({ x: 50, y: 90 }, clickGeometry), 'opacity-down');
assert.equal(avatarBodyTapAction({ x: 10, y: 35 }, clickGeometry), null,
  'an arm-height click outside the chest must not change opacity');
assert.equal(avatarBodyTapAction({ x: 50, y: 10 }, {
  ...clickGeometry, hasBody: false,
}), null, 'a face-only avatar reserves its surface for PTT and Live Talk');
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
assert.equal(steppedAvatarOpacity(.15, -1), .03);
assert.equal(steppedAvatarOpacity(.03, -1), 0);
assert.equal(steppedAvatarOpacity(0, -1), 0);
assert.match(source, /if \(!geometry \|\| !paintedAvatarAt\(\{ \.\.\.point, inside: true \}\)\) return null;/,
  'transparent gaps must never acquire a body-region gesture');
assert.match(source, /if \(action === 'opacity-up'\) void adjustAvatarOpacity\(1\);/);
assert.match(source, /else if \(action === 'opacity-down'\) void adjustAvatarOpacity\(-1\);/);
assert.match(source, /const state = await shell\.setPetOpacity\(next\);/);
assert.match(source, /canvas\.addEventListener\('dblclick', event => \{\n      clearTimeout\(avatarTapTimer\);/,
  'the first opacity tap must not fire beneath a double-click Live Talk gesture');
assert.match(source, /canvas\.addEventListener\('dblclick',[\s\S]{0,360}paintedAvatarAt\([\s\S]{0,180}toggleLiveTalk\(\);/,
  'double-clicking any painted avatar pixel must own Live Talk');
assert.match(source, /if \(pointOnHead\([\s\S]{0,260}startRecording\(\);/,
  'holding the avatar head must retain push to talk');
assert.doesNotMatch(source, /avatarTapTimer = setTimeout\(\(\) => \{[\s\S]{0,180}openChat\(false\);/,
  'a body tap must no longer expose chat chrome in pure Avatar mode');

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

// The legacy Live Talk email tool remains review-only for older compatible
// agents: exact schema, caller/session/final transcript checks, replay defense,
// and two local actions with no send path.
assert.match(source, /openclam\.prepareEmailDraft\.v1/);
assert.match(source, /exactObject\(rootValue, \['schema_version', 'request_id', 'spoken_request', 'tool'\]\)/);
assert.match(source, /agents\[0\]\.identity === invocation\.callerIdentity/);
assert.match(source, /session\.latestFinalUserTranscript/);
assert.match(source, /waitForMatchingFinalUserTurn/);
assert.match(source, /Math\.min\(5000, Math\.max\(0, timeout - 1500\)\)/);
assert.match(source, /!trustedEmailInvocation\(session, invocation, timeout\)/);
assert.match(source, /claimLiveTalkRPCRequest\(\s*session\.replayedEmailRequests, request\.request_id, 64/);
assert.match(source, /warning\.textContent = 'Unsent/);
assert.match(source, /keep\.textContent = 'Keep in chat'/);
assert.match(source, /copy\.textContent = 'Copy draft'/);
assert.doesNotMatch(source, /prepareEmailDraft[\s\S]{0,9000}(openURL|sendMail|sendEmail|mailClient)/i);

// The current Live Talk action tool hands the exact finalized transcript to the
// same selected typed route. The renderer—not the cloud voice model—owns OpenClaw
// approvals, Work events, attachments, and the visible final message.
assert.match(source, /openclam\.submitAgentTurn\.v1/);
assert.match(source, /exactObject\(rootValue, \['schema_version', 'request_id', 'spoken_request'\]\)/);
assert.match(source, /const trustedAgentTurnInvocation =/);
assert.match(source, /waitForMatchingFinalUserTurn\(\s*session, request\.spoken_request, timeout/);
assert.match(source, /replayedAgentTurnRequests\.has\(request\.request_id\)/);
assert.match(source, /claimLiveTalkRPCRequest\(\s*session\.replayedAgentTurnRequests, request\.request_id, 128/);
assert.match(source,
  /const agentID = selectedOpenClawAgent\(\);[\s\S]{0,180}!agentID[\s\S]{0,260}LIVE_TALK_OPENCLAW_REQUIRED_MESSAGE/,
  'agentic Live Talk must fail closed with recovery guidance when OpenClaw is not selected');
assert.match(source,
  /submitOpenClawTurn\(request\.spoken_request, agentID, \{[\s\S]{0,180}liveAgentBridge: true,[\s\S]{0,100}userAlreadyRendered: true/,
  'agentic Live Talk requests must call the selected tool-capable OpenClaw route directly');
assert.doesNotMatch(source,
  /handleAgentTurnRPC[\s\S]*?submitLocalTurn\(request\.spoken_request/,
  'external-action requests must never fall through to a plain local LLM');
assert.match(source, /registerRpcMethod\(AGENT_TURN_RPC/);
assert.match(source, /unregisterRpcMethod\(AGENT_TURN_RPC/);
assert.match(source, /rememberExpectedDelegatedAssistantReply\(session, spokenReply, performance\.now\(\)\)/,
  'duplicate suppression must be bound to the exact delegated reply');
assert.match(source, /expiresAt: now \+ delegatedReplyExpiryMs\(text\)/,
  'duplicate suppression must scale to the duration of a long delegated spoken reply');
assert.doesNotMatch(source, /suppressDelegatedAssistantTranscript/,
  'a session-wide suppression boolean could hide an unrelated later answer');
assert.match(source,
  /const controller = new AbortController\(\);[\s\S]{0,140}turnController = controller;[\s\S]{0,160}turnControllerOrigin = options\.liveAgentBridge \? 'live-agent-bridge' : 'typed'/,
  'turn controllers must retain whether they originated from Live Talk');
assert.match(source,
  /function stopLiveTalk\(reason\) \{[\s\S]{0,260}turnControllerOrigin === 'live-agent-bridge'[\s\S]{0,240}delegatedController\.abort\(\)/,
  'hangup must abort a delegated OpenClaw job owned by Live Talk');
assert.match(source,
  /const beginLiveTalkUserInput = \(session, segmentID, now\) => \{[\s\S]{0,4500}turnControllerOrigin === 'live-agent-bridge'[\s\S]{0,1800}interruptedController\.abort\(\)/,
  'a new Live Talk user turn must abort the delegated job it interrupts');
assert.doesNotMatch(source,
  /function stopLiveTalk\(reason\) \{[\s\S]{0,300}turnControllerOrigin === 'typed'[\s\S]{0,120}abort\(\)/,
  'hangup must never abort an ordinary typed OpenClaw turn');
assert.match(source,
  /finally \{[\s\S]{0,180}setOpenClawTurnHeading\(controller, false\);\s*if \(turnController === controller\) \{\s*turnController = null;\s*turnControllerOrigin = null;/,
  'an older aborted turn must not clear a replacement controller in finally');
assert.match(source,
  /else if \(turnController\) \{\s*if \(!requestOpenClawTurnStop\(\)\) turnController\.abort\(\);\s*removeWorking\(\);\s*if \(!openClawTurnHeadingOwner\) setStatus\('Ready', 'good'\);/,
  'Escape must leave controller ownership intact for finally to restore controls');
assert.doesNotMatch(source,
  /else if \(turnController\) \{\s*turnController\.abort\(\);\s*turnController = null;/,
  'Escape must not bypass identity-safe controller cleanup');
assert.match(source,
  /const rpcDeadlineAt = performance\.now\(\)[\s\S]{0,120}timeout - LIVE_TALK_AGENT_RPC_DEADLINE_MARGIN_MS/,
  'the delegated job deadline must be owned by the incoming RPC timeout');
assert.match(source,
  /submitOpenClawTurn\(request\.spoken_request, agentID, \{[\s\S]{0,180}deadlineAt: rpcDeadlineAt/,
  'the selected OpenClaw stream must receive the RPC-owned deadline');
assert.match(source,
  /const delegatedDeadlineTimer = options\.liveAgentBridge[\s\S]{0,220}armDelegatedTurnDeadline\(controller, options\.deadlineAt\)/,
  'only Live Talk delegated jobs may arm the caller deadline');
assert.match(source,
  /if \(delegatedDeadlineTimer !== null\) clearTimeout\(delegatedDeadlineTimer\);[\s\S]{0,100}if \(turnController === controller\)/,
  'deadline cleanup must preserve identity-safe controller ownership');

const replayClaimSource = inline[1].match(
  /(const claimLiveTalkRPCRequest = \(requestIDs, requestID, maximum\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(replayClaimSource, 'the RPC replay claim must remain independently testable');
const claimLiveTalkRPCRequest = new Function(
  `'use strict'; ${replayClaimSource[1]}; return claimLiveTalkRPCRequest;`,
)();
const replayClaims = new Set();
for (let index = 0; index < 128; index += 1) {
  assert.equal(claimLiveTalkRPCRequest(replayClaims, `request-${index}`, 128), true);
}
assert.equal(claimLiveTalkRPCRequest(replayClaims, 'request-0', 128), false,
  'a claimed request must remain rejected for the whole Live Talk session');
assert.equal(claimLiveTalkRPCRequest(replayClaims, 'request-128', 128), false,
  'a full replay window must fail closed instead of evicting an older request');
assert.equal(replayClaims.has('request-0'), true,
  'reaching the cap must never make the first request replayable');

const deadlineHelperSource = inline[1].match(
  /(const armDelegatedTurnDeadline = \(controller, deadlineAt\) => setTimeout\([\s\S]*?\n    \}, Math\.max\(0, deadlineAt - performance\.now\(\)\)\);)/,
);
assert.ok(deadlineHelperSource, 'delegated deadline helper must remain independently testable');
const makeDeadlineHarness = new Function(
  'performance', 'setTimeout',
  `'use strict'; let turnController = null; let turnControllerOrigin = null; `
    + `${deadlineHelperSource[1]}; return { armDelegatedTurnDeadline, `
    + `own: (controller, origin) => { turnController = controller; turnControllerOrigin = origin; } };`,
);
let scheduledDelay = null;
let scheduledCallback = null;
const deadlineHarness = makeDeadlineHarness(
  { now: () => 40 },
  (callback, delay) => { scheduledCallback = callback; scheduledDelay = delay; return 7; },
);
const deadlineController = { aborts: 0, abort() { this.aborts += 1; } };
deadlineHarness.own(deadlineController, 'live-agent-bridge');
assert.equal(deadlineHarness.armDelegatedTurnDeadline(deadlineController, 100), 7);
assert.equal(scheduledDelay, 60, 'a never-resolving delegated fetch must stop before its caller deadline');
scheduledCallback();
assert.equal(deadlineController.aborts, 1, 'the deadline must abort its still-owned delegated job');
deadlineHarness.own({}, 'live-agent-bridge');
scheduledCallback();
assert.equal(deadlineController.aborts, 1, 'an old deadline must not abort a replacement job');

const agentContractParts = [
  inline[1].match(/const MAX_RPC_BYTES = 12000;\s*const MAX_AGENT_TURN_REPLY_BYTES = 6000;/),
  inline[1].match(/const utf8Size =[^;]+;/),
  inline[1].match(/const exactObject =[\s\S]*?;/),
  inline[1].match(/const parseAgentTurnRequest =[\s\S]*?\n    };\s*\n\s*const boundedAgentTurnReply =[\s\S]*?\n    };\s*\n\s*const agentTurnRPCAnswer =[\s\S]*?\n    }\);/),
];
assert.ok(agentContractParts.every(Boolean), 'agent-turn RPC contract must remain independently testable');
const agentContract = new Function(
  `'use strict'; ${agentContractParts.map(part => part[0]).join('\n')}; `
    + 'return { parseAgentTurnRequest, boundedAgentTurnReply, agentTurnRPCAnswer };',
)();
const agentRequest = JSON.stringify({
  schema_version: 1,
  request_id: 'a'.repeat(64),
  spoken_request: "Search for McDonald's nearby",
});
assert.deepEqual(agentContract.parseAgentTurnRequest(agentRequest), {
  request_id: 'a'.repeat(64),
  spoken_request: "Search for McDonald's nearby",
});
assert.equal(agentContract.parseAgentTurnRequest(JSON.stringify({
  schema_version: 1,
  request_id: 'a'.repeat(64),
  spoken_request: 'Email Emma',
  approve: true,
})), null, 'unknown authority fields must fail the exact request schema');
assert.deepEqual(JSON.parse(agentContract.agentTurnRPCAnswer('failed', 'pretend success')), {
  schema_version: 1,
  status: 'failed',
  spoken_reply: '',
});
assert.ok(new TextEncoder().encode(
  agentContract.boundedAgentTurnReply('界'.repeat(3000)),
).length <= 6000, 'foreground spoken replies must remain UTF-8 byte bounded');
assert.equal(
  agentContract.boundedAgentTurnReply(
    '<expr type="expression" label="angry"/><speak>[whisper] Safe result.</speak>',
  ),
  'Safe result.',
  'untrusted agent, file, or web markup must cross the Live Talk boundary as plain speech',
);
assert.equal(
  agentContract.boundedAgentTurnReply(
    '<p><say-as interpret-as="digits">123</say-as> <phoneme ph="həˈloʊ">hello</phoneme></p>',
  ),
  '123 hello',
  'all supported speech-control tags must be removed consistently across clients',
);
assert.equal(
  agentContract.boundedAgentTurnReply(
    "McDonald's (0.4 miles away) found [3] results; "
      + 'see [the menu](https://example.invalid/menu), and 2 < 3.',
  ),
  "McDonald's (0.4 miles away) found \uff3b3\uff3d results; see the menu, and 2 \uff1c 3.",
  'plain-speech hardening must preserve ordinary facts, parentheses, and link labels',
);
assert.equal(
  agentContract.boundedAgentTurnReply(
    'Contact <emma@example.com>, <voice@example.com>, or <s@example.com> about <alpha beta> now.',
  ),
  'Contact \uff1cemma@example.com\uff1e, \uff1cvoice@example.com\uff1e, or '
    + '\uff1cs@example.com\uff1e about \uff1calpha beta\uff1e now.',
  'ordinary angle-bracket facts must be retained while their delimiters are neutralized',
);

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
  /(const beginLiveTalkUserInput = \(session, segmentID, now\) => \{[\s\S]*?const assistantTranscriptDisposition = \(session, text, now\) => \{[\s\S]*?\n    \};)/,
);
assert.ok(turnAssembly, 'Live Talk turn-boundary helpers must remain independently testable');
const turnHelpers = new Function(
  'canonicalWords', 'resetLiveTalkTTSTimingState', 'reactiveMouthState',
  'LIVE_TALK_USER_SEGMENT_JOIN_MS', 'LIVE_TALK_DELEGATED_REPLY_EXPIRY_MS',
  `'use strict'; let currentViseme = 'sil'; let agentSpeaking = false; `
    + 'let turnController = null; let turnControllerOrigin = null; '
    + 'const agentModeSelect = { disabled: false }; '
    + `${turnAssembly[1]}; return { `
    + 'beginLiveTalkUserInput, updatePendingLiveTalkUserSegment, '
    + 'matchesFinalLiveTalkUserTurn, appendFinalUserTurnSegment, '
    + 'rememberExpectedDelegatedAssistantReply, consumeExpectedDelegatedAssistantReply, '
    + 'assistantTranscriptDisposition, '
    + 'setAgentSpeaking: value => { agentSpeaking = value; }, '
    + 'setController: (controller, origin) => { '
    + 'turnController = controller; turnControllerOrigin = origin; } };',
)(
  value => String(value || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim().replace(/\s+/g, ' '),
  state => { state.reset = true; },
  { viseme: 'sil', audibleUntil: 0 },
  1200,
  45000,
);
const splitTurn = {
  finalUserTurnSegments: [], userTurnFinalSegmentIDs: new Set(),
  seenUserTranscriptSegments: new Set(), userTurnOpen: false,
  latestFinalUserTranscript: '', lastUserFinalAt: -Infinity,
  assistantOutputSinceUser: false, ttsTimingState: {},
  expectedDelegatedAssistantReplies: [],
};
turnHelpers.beginLiveTalkUserInput(splitTurn, 'u1', 100);
for (const [index, segment] of [
  'Email Emma', 'Subject.', 'Project update.', 'Message,', 'please review the schedule.',
].entries()) {
  const id = `u1-${index}`;
  if (index) turnHelpers.beginLiveTalkUserInput(splitTurn, id, 100 + index * 20);
  turnHelpers.appendFinalUserTurnSegment(splitTurn, segment, id, 100 + index * 20);
}
assert.equal(
  splitTurn.latestFinalUserTranscript,
  'Email Emma Subject. Project update. Message, please review the schedule.',
);
splitTurn.assistantOutputSinceUser = true; // assistant began, then was interrupted
turnHelpers.beginLiveTalkUserInput(splitTurn, 'u2', 400);
turnHelpers.appendFinalUserTurnSegment(splitTurn, 'Search for McDonald\'s', 'u2', 430);
turnHelpers.beginLiveTalkUserInput(splitTurn, 'u2-tail', 450);
turnHelpers.appendFinalUserTurnSegment(splitTurn, 'nearby.', 'u2-tail', 460);
assert.equal(splitTurn.latestFinalUserTranscript, "Search for McDonald's nearby.",
  'a barge-in must start a new exact user turn while preserving its split final segments');

const activeSpeechTurn = {
  finalUserTurnSegments: ['Old request.'], userTurnFinalSegmentIDs: new Set(['old']),
  seenUserTranscriptSegments: new Set(), userTurnOpen: true,
  latestFinalUserTranscript: 'Old request.', lastUserFinalAt: 100,
  assistantOutputSinceUser: false, ttsTimingState: {},
  expectedDelegatedAssistantReplies: [],
  agentSpeechGeneration: 1, interruptedAgentSpeechGeneration: -1,
};
turnHelpers.setAgentSpeaking(true);
turnHelpers.beginLiveTalkUserInput(activeSpeechTurn, 'barge-1', 200);
turnHelpers.appendFinalUserTurnSegment(activeSpeechTurn, 'New request', 'barge-1', 210);
turnHelpers.beginLiveTalkUserInput(activeSpeechTurn, 'barge-2', 220);
turnHelpers.appendFinalUserTurnSegment(activeSpeechTurn, 'continued.', 'barge-2', 230);
turnHelpers.setAgentSpeaking(false);
assert.equal(activeSpeechTurn.latestFinalUserTranscript, 'New request continued.',
  'agent-audio-only barge-in must start one new turn without splitting its later segments');

const partialBargeTurn = {
  finalUserTurnSegments: ['Old request.'], userTurnFinalSegmentIDs: new Set(['old-final']),
  seenUserTranscriptSegments: new Set(), pendingUserTranscriptSegments: new Set(),
  userTurnOpen: true, latestFinalUserTranscript: 'Old request.', lastUserFinalAt: 100,
  assistantOutputSinceUser: false, ttsTimingState: {},
  expectedDelegatedAssistantReplies: [],
};
turnHelpers.beginLiveTalkUserInput(partialBargeTurn, 'new-partial', 200);
turnHelpers.updatePendingLiveTalkUserSegment(partialBargeTurn, 'new-partial', false);
assert.equal(
  turnHelpers.matchesFinalLiveTalkUserTurn(partialBargeTurn, 'Old request.'),
  false,
  'a newer unfinished utterance must immediately block an RPC for the prior final turn',
);
turnHelpers.updatePendingLiveTalkUserSegment(partialBargeTurn, 'new-partial', true);
turnHelpers.appendFinalUserTurnSegment(
  partialBargeTurn, 'No, use the new request.', 'new-partial', 230,
);
assert.equal(
  turnHelpers.matchesFinalLiveTalkUserTurn(partialBargeTurn, 'Old request.'),
  false,
  'finalizing a correction must not revive the delayed RPC for the prior request',
);

turnHelpers.rememberExpectedDelegatedAssistantReply(splitTurn, 'Three places are ready.', 500);
splitTurn.assistantOutputSinceUser = true;
turnHelpers.beginLiveTalkUserInput(splitTurn, 'u3', 520);
assert.equal(
  turnHelpers.consumeExpectedDelegatedAssistantReply(splitTurn, 'An unrelated answer.', 530),
  false,
  'an unrelated assistant final must never be hidden',
);
assert.equal(splitTurn.expectedDelegatedAssistantReplies.length, 1,
  'a new user turn must retain one bounded exact expectation for a late delegated echo');
assert.equal(
  turnHelpers.consumeExpectedDelegatedAssistantReply(splitTurn, 'Three places are ready!', 540),
  true,
  'the exact delegated TTS echo arriving after interruption must remain suppressed',
);
assert.equal(splitTurn.expectedDelegatedAssistantReplies.length, 0);

const lateFinalTurn = {
  finalUserTurnSegments: ['First fragment'], userTurnFinalSegmentIDs: new Set(['late-u1']),
  seenUserTranscriptSegments: new Set(['late-u1']), userTurnOpen: true,
  latestFinalUserTranscript: 'First fragment', lastUserFinalAt: 700,
  assistantOutputSinceUser: false, ttsTimingState: {},
  expectedDelegatedAssistantReplies: [],
  agentSpeechGeneration: 3, interruptedAgentSpeechGeneration: 3,
};
const lateDisposition = turnHelpers.assistantTranscriptDisposition(
  lateFinalTurn, 'Old interrupted answer.', 720,
);
assert.equal(lateDisposition.preserveUserTurn, true,
  'a late final from the interrupted speech generation must preserve the new user turn');
turnHelpers.beginLiveTalkUserInput(lateFinalTurn, 'late-u2', 740);
turnHelpers.appendFinalUserTurnSegment(lateFinalTurn, 'second fragment.', 'late-u2', 750);
assert.equal(lateFinalTurn.latestFinalUserTranscript, 'First fragment second fragment.',
  'user seg1, late assistant final, then user seg2 must remain one authoritative turn');

const longDelegatedReply = 'a'.repeat(1000);
turnHelpers.rememberExpectedDelegatedAssistantReply(splitTurn, longDelegatedReply, 600);
assert.equal(
  turnHelpers.consumeExpectedDelegatedAssistantReply(
    splitTurn, longDelegatedReply, 60600,
  ),
  true,
  'an exact transcript arriving after 45 seconds must still suppress a long delegated echo',
);

const delegatedTurn = {
  finalUserTurnSegments: [], userTurnFinalSegmentIDs: new Set(),
  seenUserTranscriptSegments: new Set(), userTurnOpen: false,
  latestFinalUserTranscript: '', lastUserFinalAt: -Infinity,
  assistantOutputSinceUser: false, ttsTimingState: {},
  expectedDelegatedAssistantReplies: [],
};
turnHelpers.beginLiveTalkUserInput(delegatedTurn, 'delegated-1', 1000);
turnHelpers.appendFinalUserTurnSegment(
  delegatedTurn, 'Search for the first place.', 'delegated-1', 1010,
);
const delegatedController = {
  aborted: false,
  abort() { this.aborted = true; },
};
turnHelpers.setController(delegatedController, 'live-agent-bridge');
turnHelpers.beginLiveTalkUserInput(delegatedTurn, 'delegated-2', 1050);
turnHelpers.appendFinalUserTurnSegment(
  delegatedTurn, 'Search for the second place.', 'delegated-2', 1060,
);
assert.equal(delegatedController.aborted, true,
  'a new user turn must abort its in-flight delegated job');
assert.equal(delegatedTurn.latestFinalUserTranscript, 'Search for the second place.',
  'speech after a delegated interruption must not append to the prior user turn');

// Keyboard and assistive labels cover the main desktop verbs.
assert.match(source, /event\.metaKey \|\| event\.ctrlKey/);
assert.match(source, /event\.code === 'Space'/);
assert.match(source, /event\.key === 'Escape'/);
assert.match(source, /aria-label="Hold to talk"/);
assert.match(source, /aria-label="Message"/);
assert.match(source, /prefers-reduced-motion/);

speechCancellationQA.then(() => {
  console.log('OpenClam desktop renderer QA passed');
}).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
