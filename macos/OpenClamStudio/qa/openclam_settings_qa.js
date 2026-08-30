#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const file = path.join(root, 'web', 'settings.html');
const source = fs.readFileSync(file, 'utf8');

function includes(fragment, message) {
  assert.ok(source.includes(fragment), message || `Missing ${fragment}`);
}

function excludes(pattern, message) {
  assert.ok(!pattern.test(source), message || `Unexpected ${pattern}`);
}

includes('<title>OpenClam Studio · Settings</title>');
includes('placeholder="model:tag or model:cloud"');
includes('data-ollama-choice="${esc(field)}"');
includes('Choose a model added to Ollama');
includes('model confirmed');
includes("provider.id === 'ollama'");
includes('already added to this installation');
includes('<html lang="en">');
includes('Avatar Studio');
includes('Avatar Store');
includes('<button type="button" data-tab="store" hidden disabled aria-hidden="true" tabindex="-1">Avatar Store</button>');
includes('<section id="tab-store" hidden aria-hidden="true">');
includes('const AVATAR_STORE_AVAILABLE = false;');
includes('if (b.dataset.tab === \'store\' && !AVATAR_STORE_AVAILABLE) return;');
includes('if (!AVATAR_STORE_AVAILABLE) return;');
includes('id="importAvtr"');
includes('id="body-edit-card"');
includes('.body-edit-card{display:block;');
includes('id="body-edit-instruction" maxlength="600" aria-describedby="body-edit-note"');
includes('id="body-edit-apply"');
includes('Edit all 3 views');
includes('Sends the three body plates and identity reference to xAI for 3 image edits.');
includes('aria-labelledby="body-edit-title" aria-busy="false"');
includes("api('/api/avatar/body/edit'");
includes("startBodyProgress('body-edit')");
includes("BODY_JOB_KIND === 'body-edit'");
includes('job.done && BODY_EDIT_JOB_ID');
includes("normaliseJobKind(job.kind) === 'body-edit'");
includes("provider.name === 'xai' && provider.model === 'grok-imagine-image-2.0'");
const editBodySource = source.slice(
  source.indexOf('async function editBody()'),
  source.indexOf('\nasync function generateMotion(', source.indexOf('async function editBody()')),
);
const alreadyRunningBranch = editBodySource.slice(
  editBodySource.indexOf("response.reason === 'already building'"),
  editBodySource.indexOf('if (response.detail', editBodySource.indexOf("response.reason === 'already building'")),
);
assert.doesNotMatch(alreadyRunningBranch, /BODY_EDIT_JOB_ID\s*=/,
  'An unrelated already-running job must not claim or clear the edit draft');
const bodyEditAvailable = executableContract(
  '/* qa:body-edit-provider-gate:start */',
  '/* qa:body-edit-provider-gate:end */',
  'bodyEditAvailable');
assert.equal(bodyEditAvailable({
  has_body: true, has_turnaround: true, body_edit_available: true,
  provider: {name: 'xai', model: 'grok-imagine-image-2.0'},
}), true);
for (const provider of [
  {name: 'openai', model: 'gpt-image-1'},
  {name: 'xai', model: 'grok-imagine-image'},
  null,
]) {
  assert.equal(bodyEditAvailable({
    has_body: true, has_turnaround: true, body_edit_available: true, provider,
  }), false, 'Body editing must be visible only for exact xAI Image 2.0');
}
assert.equal(bodyEditAvailable({
  has_body: false, has_turnaround: false, body_edit_available: true,
  provider: {name: 'xai', model: 'grok-imagine-image-2.0'},
}), false, 'Body editing requires a complete existing turnaround');
includes('Curated · verified AVTR');
includes('Every download is checked against the');
includes('id="store-state" role="status" aria-live="polite"');
includes('id="store-list" aria-busy="false"');
includes('role="progressbar"');
includes('aria-valuemin="0"');
includes('aria-valuemax="100"');
includes('data-store-download');
includes('data-store-cancel');
includes('SHA-256 verified');
includes('Add update');
includes('is added as a separate library entry. Your current version stays in Avatar Studio until you remove it.');
includes("SHELL.avatarStoreCatalog({force})");
includes('SHELL.avatarStoreThumbnail(identifier)');
includes('SHELL.downloadAvatarStoreItem(identifier)');
includes('SHELL.cancelAvatarStoreItem(identifier)');
includes('SHELL.onAvatarStoreProgress(applyStoreProgress)');
const storeCardSource = source.slice(
  source.indexOf('function bindStoreActions(scope) {'),
  source.indexOf('\nfunction setStoreState(', source.indexOf('function storeCard(item) {')),
);
assert.match(storeCardSource,
  /function syncStoreAction\(card, item, progress\)[\s\S]*holder\.innerHTML = storeActionMarkup\(item, progress\);[\s\S]*bindStoreActions\(holder\);/,
  'Avatar Store progress must replace and rebind the card action in place');
const storeProgressSource = source.slice(
  source.indexOf('function applyStoreProgress(update) {'),
  source.indexOf('\nasync function loadAvatarStore(', source.indexOf('function applyStoreProgress(update) {')),
);
assert.match(storeProgressSource,
  /function applyStoreProgress\(update\)[\s\S]*syncStoreAction\(card, item, progress\);/,
  'Every Avatar Store progress event must refresh its phase-aware action');
const storeActionState = executableContract(
  '/* qa:avatar-store-action-state:start */',
  '/* qa:avatar-store-action-state:end */',
  'storeActionState');
for (const phase of ['preparing', 'downloading']) {
  const state = storeActionState({}, {phase});
  assert.equal(state.kind, 'cancel', `${phase} must expose the active Cancel action`);
  assert.equal(state.disabled, false);
}
for (const phase of ['validating', 'installing', 'cancelling']) {
  const state = storeActionState({}, {phase});
  assert.equal(state.kind, 'busy', `${phase} must replace Cancel with a busy action`);
  assert.equal(state.disabled, true, `${phase} must not remain cancellable in the DOM`);
}
assert.equal(storeActionState({}, {phase: 'complete'}).kind, 'installed');
assert.equal(storeActionState({}, {phase: 'complete'}).disabled, true);
assert.equal(storeActionState({}, {phase: 'failed'}).label, 'Retry');
const storeActionDomStart = source.indexOf('/* qa:avatar-store-action-dom:start */');
const storeActionDomEnd = source.indexOf('/* qa:avatar-store-action-dom:end */');
assert.ok(storeActionDomStart >= 0 && storeActionDomEnd > storeActionDomStart,
  'Expected the phase-aware Avatar Store action DOM contract');
const storeActionDomContext = {
  esc: value => String(value),
  startStoreDownload() {},
  cancelStoreDownload() {},
};
vm.runInNewContext(
  source.slice(source.indexOf('/* qa:avatar-store-action-state:start */'),
    source.indexOf('/* qa:avatar-store-action-state:end */'))
  + source.slice(storeActionDomStart, storeActionDomEnd)
  + '\n;globalThis.syncAction = syncStoreAction;',
  storeActionDomContext,
  {filename: file},
);
const actionHolder = {
  innerHTML: '',
  querySelectorAll(selector) {
    const attribute = selector.slice(1, -1);
    return this.innerHTML.includes(attribute)
      ? [{closest: () => ({dataset: {storeId: 'fixture-avatar'}})}] : [];
  },
};
const actionCard = {querySelector: selector => selector === '.store-actions' ? actionHolder : null};
storeActionDomContext.syncAction(actionCard, {}, {phase: 'downloading'});
assert.match(actionHolder.innerHTML, /data-store-cancel/,
  'Downloading must render a clickable Cancel action');
for (const phase of ['validating', 'installing']) {
  storeActionDomContext.syncAction(actionCard, {}, {phase});
  assert.doesNotMatch(actionHolder.innerHTML, /data-store-cancel/,
    `${phase} must remove the stale Cancel action from the DOM`);
  assert.match(actionHolder.innerHTML, /disabled/,
    `${phase} must render a disabled phase action`);
}
const cancelStoreSource = source.slice(
  source.indexOf('async function cancelStoreDownload(identifier) {'),
  source.indexOf("\n$('#store-refresh').onclick", source.indexOf('async function cancelStoreDownload(identifier) {')),
);
assert.match(cancelStoreSource, /if \(!\['preparing', 'downloading'\]\.includes\(previous\.phase\)\)/,
  'A stale Avatar Store Cancel click must be rejected in the renderer');
assert.match(cancelStoreSource,
  /if \(!accepted\)[\s\S]*if \(current\.phase === 'cancelling'\)[\s\S]*applyStoreProgress\(\{id: identifier, \.\.\.previous\}\);/,
  'A rejected cancel must restore the last phase unless a newer authoritative event arrived');
includes('Chat · language model');
includes('Push to talk · speech recognition');
includes('Read aloud · speaking voice');
includes('Avatar creation · image generation &amp; editing');
includes('Avatar motion · video provider');
includes('Library files and AVTR exports stay');
includes('generation sends only the required portrait or avatar references');
excludes(/Nothing leaves the local library/,
  'Avatar Studio must disclose that provider-backed builds send required references');
includes('xAI Account');
includes('Other provider keys · Mac Keychain');
includes('stored values are never returned to this page');

for (const id of [
  'livekit-llm-source', 'livekit-llm-provider', 'livekit-llm',
  'livekit-stt-source', 'livekit-stt-provider', 'livekit-stt',
  'livekit-stt-language', 'livekit-tts-source', 'livekit-tts-provider',
  'livekit-tts', 'livekit-tts-voice', 'livekit-pilot-token',
]) includes(`id="${id}"`);
for (const id of [
  'livekit-llm-source', 'livekit-llm-provider', 'livekit-llm',
  'livekit-stt-source', 'livekit-stt-provider', 'livekit-stt',
  'livekit-stt-language', 'livekit-tts-source', 'livekit-tts-provider',
  'livekit-tts', 'livekit-tts-voice', 'livekit-broker-url',
  'livekit-server-host', 'livekit-pilot-token', 'newname', 'pname', 'psys',
]) includes(`for="${id}"`);
includes('id="livekit-state" role="status" aria-live="polite"');
includes('id="msg" role="status" aria-live="polite"');

includes('Managed by LiveKit. No personal provider key is needed for this stage.');
includes('The key is never placed in room metadata.');
includes('Export Mac project');
includes('Export full-expression iPhone AVTR');
includes('Second avatar (left)');
includes('Keep a second local avatar on the left side of this Mac’s desk');
includes("api('/api/avatar/companion'");
for (const id of [
  'rig-modal', 'rig-controls', 'body-modal', 'body-walk-styles',
  'body-motion-poses', 'body-move-styles', 'body-walk-generate',
  'body-idle-generate', 'body-move-generate', 'body-prompt-variation',
  'body-prompt-progress', 'body-prompt-stage', 'body-prompt-elapsed',
  'body-prompt-rail', 'body-prompt-bar',
]) includes(`id="${id}"`);
includes("const HEEL_IDLE_POSE_IDS = new Set(['back-heel', 'heel-up'])");
includes("const NON_FEMININE_IDLE_POSE = 'side-cross'");
includes('function bodyVisiblePresentation(state = BODY_STATE)');
includes("button.classList.toggle('hidden', !allowed)");
includes("pose = defaultIdlePose()");
includes("allSets.filter(set => !HEEL_IDLE_POSE_IDS.has(set.pose))");
includes('The previous Edge Idle used a heel-specific or unknown legacy pose.');
includes('✦ New luxury look');
includes("tailorBodyPrompt(BODY_SLUG, { refresh: true, force: true })");
includes("const promptPresentation = /\\b(?:woman|female|feminine-presenting)\\b/i.test(authoredPrompt)");
includes("/\\b(?:man|male|masculine-presenting)\\b/i.test(authoredPrompt)");
includes("fetch('/api/avatar/body/prompt/stream'");
includes("BODY_PROMPT_STAGE === 'analysis'");
includes('Edits you make while it works will not be overwritten.');
includes("const promptWasEdited = field.value !== promptAtStart");
includes('@media (prefers-reduced-motion:reduce)');
includes('data-motion-open="${index}"');
includes('data-motion-save="${index}"');
includes('id="body-view-open"');
includes('id="body-view-save"');
includes("scope: 'body'");
includes("typeof SHELL.openMotionAsset === 'function'");
includes('repeat(auto-fit,minmax(158px,1fr))');
includes('grid-template-columns:minmax(0,1fr) auto;align-items:baseline');

// Under-eye motion must survive a calibration round trip as an independent
// target. It used to borrow the Cheeks value, which hid the target entirely
// and made a rebuild publish a blink-only under-eye layer.
includes("key === 'brows' || key === 'eyebags'");
includes("slug: RIG_SLUG, brows: RIG_PROFILE.brows, eyebags: RIG_PROFILE.eyebags");
includes('under-eye ${RIG_PROFILE.eyebags}%');
excludes(/name === 'eyebags' \? 'cheeks' : name/);

const bodyResponsiveStart = source.indexOf('/* qa:body-responsive:start */');
const bodyResponsiveEnd = source.indexOf('/* qa:body-responsive:end */');
assert.ok(bodyResponsiveStart >= 0 && bodyResponsiveEnd > bodyResponsiveStart,
  'Expected the narrow Full Body Studio layout contract');
const bodyResponsive = source.slice(bodyResponsiveStart, bodyResponsiveEnd);
assert.match(bodyResponsive, /@media\(max-width:860px\)/,
  'Full Body Studio must adapt at the settings window narrow breakpoint');
assert.match(bodyResponsive, /#body-modal \.rig-dialog\{height:auto;min-height:100%;overflow:visible\}/,
  'The narrow modal must use its shell as the only page scroll surface');
assert.match(bodyResponsive, /#body-modal \.body-visual\{height:clamp\(360px,62vh,500px\);min-height:0/,
  'The narrow preview must not retain the 660px desktop minimum');
assert.match(bodyResponsive, /#body-modal \.body-preview\{position:relative;inset:auto;width:100%;height:100%;max-height:none\}/,
  'The generated full body must fit its reserved preview row instead of being cropped');
assert.match(bodyResponsive, /#body-modal \.body-mode-tabs,#body-modal \.body-view-tabs\{position:relative;inset:auto;transform:none\}/,
  'Body and view controls must consume layout space rather than covering the avatar');
assert.match(bodyResponsive, /#body-modal \.body-panel\{max-height:none;overflow:visible/,
  'The narrow inspector must not create an independent vertical scroller');
assert.match(bodyResponsive, /#body-modal \.rig-head\{position:sticky;top:0/,
  'The close control must remain reachable while the single modal surface scrolls');

excludes(/Vivieen/i);
excludes(/EnConvo/i);
excludes(/TestFlight/i);
excludes(/\bSolo\b/i);
for (const id of [
  'openclaw-pairing-card', 'openclaw-pairing-create',
  'openclaw-pairing-refresh', 'openclaw-pairing-code-card',
  'openclaw-pairing-code', 'openclaw-pairing-copy',
  'openclaw-pairing-countdown', 'openclaw-pairing-state',
  'openclaw-install-panel', 'openclaw-setup-key', 'openclaw-install',
  'openclaw-update-channel',
]) includes(`id="${id}"`);
includes('async function copySettingsText(value)');
includes("typeof SHELL.copySettingsText === 'function'");
includes('if (!await copySettingsText(code))');
includes("function showOpenClawCopyFeedback(state = 'idle')");
includes("showOpenClawCopyFeedback('copying')");
includes("showOpenClawCopyFeedback('copied')");
includes("button.textContent = '✓ Copied'");
includes("button.classList.add('is-copied')");
includes('setTimeout(() => showOpenClawCopyFeedback(), 1800)');
includes('button.btn.openclaw-copy.is-copied:hover');
includes("function showOpenClawUpdateFeedback(state = 'idle')");
includes("showOpenClawUpdateFeedback('updating')");
includes("showOpenClawUpdateFeedback('updated')");
includes("button.textContent = '✓ Updated'");
includes('button.btn.openclaw-update.is-updated:hover');
excludes(/openclaw-pairing-copy[\s\S]{0,400}navigator\.clipboard\.writeText\(code\)/,
  'The packaged pairing button must use the Electron clipboard bridge');
includes("api('/api/openclaw/pairing'");
includes("api('/api/openclaw/pairing', {method: 'POST'}");
includes("api('/api/openclaw/install'");
includes('function requireOpenClawRepair(message)');
includes('result && result.repair_required');
includes('body: JSON.stringify({setup_key: setupKey, repair: repairing})');
includes('Reconnect OpenClaw');
includes('Creating a code verifies the bridge connection.');
includes('all other channels stay unchanged');
includes('The code is not saved here');
includes('bridge setup key out of OpenClaw configuration and app storage');
includes('Enter this in OpenClam on iPhone');
excludes(/Valid for \$\{minutes\}:\$\{seconds\}/);
excludes(/Telegram|BotFather|bot token/i);
excludes(/relay/i);
excludes(/selfie|capture="user"|takeSelfie/i);
excludes(/\/api\/avatar\/store|\/api\/media\/defaults|\/api\/reveal/i);
excludes(/window\.vivieen|VIV_APP_|vivieen-theme|viv-ptt-edit/i);
excludes(/pttEditToggle|openclam-ptt-edit|Review the transcript before sending/i,
  'Settings must not advertise a PTT review mode the chat renderer does not implement');

const scripts = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .map(match => match[1]);
assert.ok(scripts.length >= 2, 'Expected settings scripts');
new vm.Script(scripts.join('\n'), {filename: file});

const payloadStart = source.indexOf('/* qa:regular-config-payload:start */');
const payloadEnd = source.indexOf('/* qa:regular-config-payload:end */');
assert.ok(payloadStart >= 0 && payloadEnd > payloadStart,
  'Expected executable regular-config payload contract');
const payloadAuthStart = source.indexOf('/* qa:avatar-media-contract:start */');
const payloadAuthEnd = source.indexOf('/* qa:avatar-media-contract:end */');
assert.ok(payloadAuthStart >= 0 && payloadAuthEnd > payloadAuthStart,
  'Expected API-key sanitation contract');
const payloadContract = source.slice(payloadAuthStart, payloadAuthEnd)
  + source.slice(payloadStart, payloadEnd)
  + `\n;globalThis.regularConfigPayloadForQA = regularConfigPayload;
    globalThis.sanitizeProviderForQA = sanitizeApiKeyProviderConfig;`;
const payloadContext = {};
vm.runInNewContext(payloadContract, payloadContext, {filename: file});
const payload = payloadContext.regularConfigPayloadForQA({
  llm: {provider: 'openai', model: 'gpt-test', api_key: '', has_key: true,
    accessToken: 'llm-access-secret', auth: {refresh_token: 'llm-refresh-secret'}},
  tts: {provider: 'system', voice: 'Samantha', has_key: false,
    oauthToken: 'tts-oauth-secret'},
  stt: {provider: 'mlx_whisper', model: 'whisper-test', has_key: false,
    credential_type: 'oauth2', authorization_code: 'stt-code-secret'},
  image: {provider: 'xai', model: 'image-test', api_key: '', has_key: true,
    base_url: 'https://legacy-image-proxy.example/v1', auth_method: 'oauth2_user',
    access_token: 'image-access-secret', refreshToken: 'image-refresh-secret',
    auth: {selected_method: 'oauth', tokens: {id_token: 'image-id-secret'}},
    legacy: {session_token: 'nested-session-secret'}},
  video: {provider: 'xai', model: 'video-test', has_key: true,
    id_token: 'video-id-secret'},
  persona: {name: 'Pearl', system: 'Be warm.'},
  ui: {theme: 'dark'},
  keys: {openai: 'typed-once'},
  key_checks: {openai: {ok: true}},
  livekit: {
    broker_url: 'https://must-not-leak.example',
    expected_server_host: 'must-not-leak.example',
    pilot_app_token: 'must-not-leak',
    has_pilot_app_token: true,
    llm: {source: 'byok', provider: 'openai', model: 'live-model'},
  },
  has_keys: {openai: true},
  catalog: {response: 'only'},
});
assert.deepEqual(Object.keys(payload).sort(), [
  'image', 'key_checks', 'keys', 'llm', 'persona', 'stt', 'tts', 'ui', 'video',
]);
assert.equal(Object.hasOwn(payload, 'livekit'), false,
  'Generic Save must never mutate LiveKit configuration');
assert.equal(Object.hasOwn(payload, 'has_keys'), false,
  'Generic Save must omit response-only Keychain presence');
for (const lane of ['llm', 'tts', 'stt', 'image', 'video']) {
  assert.equal(Object.hasOwn(payload[lane], 'has_key'), false,
    `${lane} must omit its response-only Keychain marker`);
}
assert.equal(payload.llm.provider, 'openai');
assert.equal(payload.keys.openai, 'typed-once');
assert.equal(Object.hasOwn(payload.image, 'auth_method'), false,
  'xAI image auth mode must come only from the global account manager');
assert.equal(Object.hasOwn(payload.image, 'api_key'), false,
  'xAI image config must not carry a lane credential');
assert.equal(payload.image.base_url, '',
  'Image saves must always resolve through the fixed provider endpoint');
for (const secret of [
  'llm-access-secret', 'llm-refresh-secret', 'tts-oauth-secret',
  'stt-code-secret', 'image-access-secret', 'image-refresh-secret',
  'image-id-secret', 'nested-session-secret', 'video-id-secret',
]) assert.ok(!JSON.stringify(payload).includes(secret), `Payload leaked ${secret}`);
for (const lane of ['llm', 'tts', 'stt', 'image', 'video']) {
  const laneText = JSON.stringify(payload[lane]);
  assert.ok(!/oauth|access.?token|refresh.?token|id.?token|credential_type|"auth"/i
    .test(laneText), `${lane} retained unsupported token-shaped auth data`);
}
const sanitizedApiKey = payloadContext.sanitizeProviderForQA({
  provider: 'openai', api_key: 'keep-api-key', auth_method: 'api_key',
  nested: {refreshToken: 'drop-me', harmless: 'keep-me'},
});
assert.equal(sanitizedApiKey.config.api_key, 'keep-api-key');
assert.equal(sanitizedApiKey.config.auth_method, 'api_key');
assert.equal(sanitizedApiKey.config.nested.harmless, 'keep-me');
assert.equal(Object.hasOwn(sanitizedApiKey.config.nested, 'refreshToken'), false);
assert.equal(sanitizedApiKey.removed, true);
const xaiPayload = payloadContext.regularConfigPayloadForQA({
  llm: {provider: 'xai', model: 'grok-test', web_search: true,
    api_key: 'lane-key-must-not-persist', auth_method: 'oauth2',
    auth: {bearer_token: 'lane-oauth-must-not-persist'}},
  tts: {provider: 'xai', voice: 'Ara', api_key: 'tts-lane-key'},
  stt: {provider: 'xai', model: 'grok-stt', access_token: 'stt-token'},
  image: {provider: 'xai', model: 'grok-imagine-image-2.0',
    credential_type: 'oauth2', oauth_token: 'image-token'},
  video: {provider: 'xai', model: 'grok-imagine-video-1.5',
    bearer: 'video-token'},
  keys: {xai: 'global-write-only-key'},
});
for (const lane of ['llm', 'tts', 'stt', 'image', 'video']) {
  assert.equal(Object.hasOwn(xaiPayload[lane], 'api_key'), false,
    `${lane} must use only the global xAI auth resolver`);
  assert.equal(Object.hasOwn(xaiPayload[lane], 'auth_method'), false);
  assert.ok(!/oauth|bearer|access.?token|credential.?type/i
    .test(JSON.stringify(xaiPayload[lane])));
}
assert.equal(xaiPayload.llm.web_search, true,
  'Grok web search must persist only its explicit boolean');
assert.equal(xaiPayload.keys.xai, 'global-write-only-key');
const nonXaiSearch = payloadContext.regularConfigPayloadForQA({
  llm: {provider: 'openai', model: 'gpt-test', web_search: true},
});
assert.equal(Object.hasOwn(nonXaiSearch.llm, 'web_search'), false,
  'The Grok web-search preference must not leak into another provider');
assert.equal(source.includes('body: JSON.stringify(CFG)\n  });'), false,
  'Generic Save must use the filtered payload');
includes('body: JSON.stringify(regularConfigPayload(CFG))');

function executableContract(startMarker, endMarker, exportedName) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker);
  assert.ok(start >= 0 && end > start, `Expected ${exportedName} contract`);
  const context = {};
  vm.runInNewContext(source.slice(start, end)
    + `\n;globalThis.__contract = ${exportedName};`, context, {filename: file});
  return context.__contract;
}

const xaiContractStart = source.indexOf('/* qa:xai-account-contract:start */');
const xaiContractEnd = source.indexOf('/* qa:xai-account-contract:end */');
assert.ok(xaiContractStart >= 0 && xaiContractEnd > xaiContractStart,
  'Expected executable shared xAI account contract');
const xaiContext = {URL};
vm.runInNewContext(source.slice(xaiContractStart, xaiContractEnd) + `
  ;globalThis.normalizeStatus = normalizeXaiAuthStatus;
  globalThis.validStatus = validXaiAuthStatusResponse;
  globalThis.normalizeFlow = normalizeXaiDeviceFlow;
  globalThis.errorCopy = xaiAuthErrorCopy;
  globalThis.safeUrl = xaiSafeVerificationUrl;
  globalThis.secondsLeft = xaiDeviceSecondsLeft;
  globalThis.usesGlobal = xaiLaneUsesGlobalAuth;
  globalThis.webSearch = xaiWebSearchValue;`, xaiContext, {filename: file});
const safeStatus = xaiContext.normalizeStatus({
  provider: 'xai', auth_mode: 'oauth2', state: 'connected', connected: true,
  has_api_key: true,
  oauth: {available: true, connected: true, refreshable: true,
    expires_at: '2026-08-15T12:00:00Z', persistence: 'session',
    access_token: 'nested-secret'},
  bearer_token: 'top-level-secret', refresh_token: 'refresh-secret',
  independent_notice: 'xAI is independent.',
});
assert.equal(safeStatus.auth_mode, 'oauth2');
assert.equal(safeStatus.connected, true);
assert.equal(safeStatus.oauth.available, true);
assert.equal(safeStatus.oauth.refreshable, true);
assert.equal(safeStatus.oauth.persistence, 'session');
assert.equal(xaiContext.validStatus({
  provider: 'xai', auth_mode: 'oauth2', state: 'connected', connected: true,
  has_api_key: false, oauth: {available: true, connected: true, refreshable: true,
    persistence: 'keychain'},
}), true);
assert.equal(xaiContext.validStatus({provider: 'xai'}), false,
  'Malformed local status responses must fail closed');
assert.ok(!JSON.stringify(safeStatus).includes('secret'),
  'The browser status model must allowlist safe fields and drop tokens');
assert.equal(xaiContext.normalizeStatus({
  independent_notice: 'Bearer accidental-secret',
}).independent_notice, '', 'A token-like server notice must never be rendered');
const safeFlow = xaiContext.normalizeFlow({
  flow_id: 'flow-1', state: 'pending', user_code: 'ABCD-EFGH',
  verification_uri: 'https://accounts.x.ai/device',
  verification_uri_complete: 'https://accounts.x.ai/device?code=ABCD-EFGH',
  expires_at: '2026-08-15T12:00:00Z', interval: 999,
  access_token: 'must-not-render',
});
assert.equal(safeFlow.flow_id, 'flow-1');
assert.equal(safeFlow.interval, 30, 'Device polling interval must be bounded');
assert.ok(!JSON.stringify(safeFlow).includes('must-not-render'));
assert.ok(xaiContext.safeUrl('https://accounts.x.ai/device').startsWith('https://'));
assert.ok(xaiContext.safeUrl('https://grok.com/device').startsWith('https://'));
assert.equal(xaiContext.safeUrl('https://attacker.example/device'), '');
assert.equal(xaiContext.safeUrl('http://accounts.x.ai/device'), '');
assert.equal(xaiContext.usesGlobal({provider: 'xai'}), true);
assert.equal(xaiContext.usesGlobal({provider: 'openai'}), false);
assert.equal(xaiContext.webSearch({provider: 'xai'}), false,
  'Grok web search must default off');
assert.equal(xaiContext.webSearch({provider: 'xai', web_search: true}), true);
assert.equal(xaiContext.webSearch({provider: 'xai', web_search: 'true'}), false,
  'Only a literal boolean may enable browsing');
assert.match(xaiContext.errorCopy('xai_oauth_entitlement_required'), /subscription/i);
assert.match(xaiContext.errorCopy('xai_oauth_device_expired'), /expired/i);
for (const code of [
  'xai_auth_mode_invalid', 'xai_oauth_flow_not_found',
  'xai_oauth_device_expired', 'xai_oauth_access_denied',
  'xai_oauth_not_connected', 'xai_api_key_missing',
  'xai_oauth_reconnect_required', 'xai_oauth_rate_limited',
  'xai_oauth_unavailable', 'xai_oauth_protocol_error',
  'xai_oauth_storage_unavailable', 'xai_oauth_client_config_invalid',
  'xai_oauth_entitlement_required',
]) {
  const copy = xaiContext.errorCopy(code);
  assert.ok(copy && !copy.includes(code), `${code} needs safe, human-readable copy`);
}
assert.equal(xaiContext.errorCopy('raw Bearer secret from provider'),
  'The xAI account action could not be completed. Try again.',
  'Unknown provider text must never be reflected into the UI');

for (const route of [
  '/api/xai/oauth/status', '/api/xai/oauth/device/start',
  '/api/xai/oauth/device/poll', '/api/xai/oauth/device/cancel',
  '/api/xai/oauth/mode',
  '/api/xai/oauth/logout',
]) includes(route);
includes('name="xai-auth-mode" value="api_key"');
includes('name="xai-auth-mode" value="oauth2"');
excludes(/name="xai-auth-mode" value="oauth2"[^>]*disabled/,
  'Grok Build compatibility must remain a selectable OAuth radio');
includes('Sign in with xAI (OAuth2)');
includes('The modes are mutually exclusive.');
includes('Grok Build compatibility');
includes('Uses xAI’s public Grok Build client identity.');
includes('OpenClam remains independent and keeps its own credentials.');
includes('connected for this session');
includes('forgotten on restart');
includes("status.oauth.persistence === 'session'");
includes('does not make');
includes('or imply a partnership.');
excludes(/data-xai-oauth-unavailable/,
  'The OAuth choice must be an enabled radio, not a disabled explainer control');
excludes(/xAI-authorized OpenClam|OpenClam native client ID/,
  'Compatibility UI must not claim an OpenClam-owned xAI registration');
includes('<legend>Authentication mode</legend>');
includes('for="xai-account-api-key"');
includes('id="xai-account-api-key" type="password"');
includes('aria-describedby="xai-api-key-help"');
includes('role="alert"');
includes('There is no lane-specific credential or silent fallback.');
includes('Grok chat');
includes('Grok web search');
includes('Speech recognition');
includes('Speaking voice');
includes('Image generate + edit');
includes('Video generate + edit');
includes('data-xai-cancel-device');
includes('data-xai-logout');
includes('id="xai-device-expiry" aria-live="polite"');
includes('data-xai-open-device');
includes('data-xai-copy-code');
includes('id="xai-web-search" type="checkbox"');
includes('for="xai-web-search"');
includes('Lets Grok browse live web pages for current information. Off by default.');
includes('provider.key && !usesGlobalAccount');
includes("provider.key === false || ['xai', 'openai'].includes(provider.id)");
includes("const credentialAvailable = usesGlobalXai ? XAI_ACCOUNT.status.connected");
includes('usesGlobalOpenAI ? OPENAI_ACCOUNT.status.connected');
includes("keys: {xai: typed || '__adopt__'}");
includes("xaiAuthRequest('/api/xai/oauth/device/start', null)");
includes("xaiAuthRequest('/api/xai/oauth/device/cancel', null)");
includes("xaiAuthRequest('/api/xai/oauth/logout', null)");
const xaiUiStart = source.indexOf('/* ---------------------------------------------------------------- xAI account */');
const xaiUiEnd = source.indexOf('/* The keyring is write-only:', xaiUiStart);
const xaiUiSource = source.slice(xaiUiStart, xaiUiEnd);
for (const tokenField of ['access_token', 'refresh_token', 'bearer_token']) {
  assert.ok(!xaiUiSource.includes(tokenField),
    `xAI Account UI must never read or render ${tokenField}`);
}
const logoutStart = source.indexOf('async function logoutXai(');
const logoutEnd = source.indexOf("document.addEventListener('click'", logoutStart);
assert.ok(!source.slice(logoutStart, logoutEnd).includes("{mode: 'api_key'}"),
  'Logging out must not silently fall back to a stored API key');
for (const functionName of [
  'chooseXaiAuthMode', 'startXaiDeviceFlow', 'cancelXaiDeviceFlow', 'logoutXai',
]) {
  const start = source.indexOf(`function ${functionName}(`);
  const end = source.indexOf('\n}', start) + 2;
  const body = source.slice(start, end);
  assert.ok(body.includes('beginXaiDecision()'),
    `${functionName} must supersede older async account decisions`);
  assert.ok(body.includes('xaiDecisionIsCurrent(epoch)'),
    `${functionName} must discard responses from superseded decisions`);
}
includes('const observedEpoch = XAI_ACCOUNT.decisionEpoch;');
includes('if (!xaiDecisionIsCurrent(observedEpoch)) return;');
includes('pollingFlowId');
includes("void cancelXaiDeviceFlow('expired')");

const mediaContractStart = source.indexOf('/* qa:avatar-media-contract:start */');
const mediaContractEnd = source.indexOf('/* qa:avatar-media-contract:end */');
assert.ok(mediaContractStart >= 0 && mediaContractEnd > mediaContractStart,
  'Expected executable avatar-media contract');
const mediaContext = {};
vm.runInNewContext(source.slice(mediaContractStart, mediaContractEnd) + `
  ;globalThis.allowed = avatarMediaProviderAllowed;
  globalThis.catalogue = avatarMediaCatalog;
  globalThis.selected = selectedAvatarMediaProvider;
  globalThis.testEndpoint = avatarMediaTestEndpoint;
  globalThis.defaults = avatarMediaProviderDefaults;
  globalThis.authCapabilities = avatarMediaAuthCapabilities;
  globalThis.applyModel = applyAvatarMediaModel;
  globalThis.applyProvider = applyAvatarMediaProvider;
  globalThis.sanitizeProvider = sanitizeApiKeyProviderConfig;
  globalThis.checkConfig = avatarMediaCheckConfig;
  globalThis.checkVerdict = avatarMediaCheckVerdict;`, mediaContext,
  {filename: file});
const mediaCatalogue = {
  image: [
    {
      id: 'openai', base: 'https://api.openai.com/v1',
      recommended_model: 'gpt-image-2',
      models: [
        {id: 'gpt-image-2'},
        {id: 'gpt-image-1'},
      ],
      auth: {
        api_key: {supported: true},
        oauth: {supported: true, reason: 'Uses the local Codex account boundary.'},
      },
      image_options: {default_size: 'auto', default_quality: 'auto'},
    },
    {id: 'gemini'},
    {
      id: 'xai', base: 'https://api.x.ai/v1',
      recommended_model: 'grok-imagine-image-2.0',
      models: [
        {id: 'grok-imagine-image-2.0'},
        {id: 'grok-imagine-image-quality'},
        {id: 'grok-imagine-image'},
      ],
      auth: {
        api_key: {supported: true},
        oauth: {supported: true, status: 'supported_via_grok_build_compatibility',
          reason: 'Uses Grok Build compatibility.'},
      },
      auth_scope: 'global', auth_modes: ['api_key', 'oauth2'],
      image_options: {
        default_aspect_ratio: '1:1', default_resolution: '1k',
        default_quality: 'medium',
      },
    },
    {id: 'stability'},
    {id: 'bfl'}, {id: 'together_image'}, {id: 'recraft'},
  ],
  video: [
    {id: 'xai', base: 'https://api.x.ai/v1',
      models: [{id: 'grok-imagine-video'}, {id: 'grok-imagine-video-1.5'}]},
    {id: 'openai'}, {id: 'gemini'}, {id: 'luma'}, {id: 'runway'},
  ],
};
assert.deepEqual(Array.from(mediaContext.catalogue('image', mediaCatalogue), row => row.id),
  ['openai', 'gemini', 'xai']);
assert.deepEqual(Array.from(mediaContext.catalogue('video', mediaCatalogue), row => row.id),
  ['xai']);
assert.equal(mediaContext.selected('image', '', mediaCatalogue), null,
  'Fresh avatar image settings must remain visibly unconfigured');
assert.equal(mediaContext.selected('video', 'runway', mediaCatalogue), null,
  'An inherited unsupported avatar provider must not silently fall back');
assert.equal(mediaContext.testEndpoint('video', 'xai'), '/api/models',
  'xAI video must use the supported non-billable credential/model check');
assert.equal(mediaContext.testEndpoint('image', 'openai'), '/api/models');
assert.equal(mediaContext.testEndpoint('image', 'xai'), '/api/models',
  'Image access checks must list models instead of creating a billable image');
const openaiImage = mediaCatalogue.image.find(row => row.id === 'openai');
const xaiImage = mediaCatalogue.image.find(row => row.id === 'xai');
const openaiDefaults = mediaContext.defaults('image', openaiImage);
assert.equal(openaiDefaults.model, 'gpt-image-2');
assert.equal(Object.hasOwn(openaiDefaults, 'auth_method'), false,
  'OpenAI image defaults must not persist a lane auth mode');
assert.equal(openaiDefaults.size, 'auto');
assert.equal(openaiDefaults.quality, 'auto');
const xaiDefaults = mediaContext.defaults('image', xaiImage);
assert.equal(xaiDefaults.model, 'grok-imagine-image-2.0');
assert.equal(Object.hasOwn(xaiDefaults, 'auth_method'), false,
  'xAI image defaults must not persist a lane auth mode');
assert.equal(xaiDefaults.aspect_ratio, '1:1');
assert.equal(xaiDefaults.resolution, '1k');
assert.equal(xaiDefaults.quality, 'medium');
const xaiLegacy = {model: 'grok-imagine-image-2.0', quality: 'medium'};
mediaContext.applyModel(xaiImage, xaiLegacy, 'grok-imagine-image-quality');
assert.equal(xaiLegacy.model, 'grok-imagine-image-quality');
assert.equal(Object.hasOwn(xaiLegacy, 'quality'), false,
  'Legacy xAI models must not retain the 2.0-only quality parameter');
const checkedConfig = mediaContext.checkConfig('image', openaiImage, {
  provider: 'openai', model: 'gpt-image-2',
  base_url: 'https://legacy-image-proxy.example/v1',
  api_key: 'keep-api-key', access_token: 'drop-access-token',
  auth: {refresh_token: 'drop-refresh-token'},
});
assert.equal(checkedConfig.base_url, '');
assert.equal(Object.hasOwn(checkedConfig, 'api_key'), false,
  'OpenAI model checks must resolve the shared account, not a lane key');
assert.equal(Object.hasOwn(checkedConfig, 'access_token'), false);
assert.equal(Object.hasOwn(checkedConfig, 'auth'), false);
const checkedXaiConfig = mediaContext.checkConfig('image', xaiImage, {
  provider: 'xai', model: 'grok-imagine-image-2.0',
  api_key: 'lane-key', auth_method: 'api_key',
});
assert.equal(Object.hasOwn(checkedXaiConfig, 'api_key'), false);
assert.equal(Object.hasOwn(checkedXaiConfig, 'auth_method'), false);
const switchedConfig = {
  provider: 'xai', model: 'grok-imagine-image-2.0', size: '2048x2048',
  refreshToken: 'drop-refresh-token',
  legacy: {oauthToken: 'drop-nested-oauth-token', harmless: 'keep-me'},
  auth: {access_token: 'drop-access-token'},
};
mediaContext.applyProvider('image', switchedConfig, openaiImage);
assert.equal(switchedConfig.provider, 'openai');
assert.equal(switchedConfig.model, 'gpt-image-2');
assert.equal(Object.hasOwn(switchedConfig, 'auth_method'), false);
assert.equal(switchedConfig.size, 'auto');
assert.equal(switchedConfig.quality, 'auto');
assert.equal(switchedConfig.legacy.harmless, 'keep-me');
assert.equal(Object.hasOwn(switchedConfig, 'refreshToken'), false);
assert.equal(Object.hasOwn(switchedConfig, 'auth'), false);
assert.equal(Object.hasOwn(switchedConfig.legacy, 'oauthToken'), false);
const exactModelVerdict = mediaContext.checkVerdict(
  'image', openaiImage,
  {model: 'gpt-image-2', base_url: ''},
  {validated: true, models: ['gpt-image-1', 'gpt-image-2']},
);
assert.equal(exactModelVerdict.ok, true);
assert.ok(exactModelVerdict.detail.includes('gpt-image-2'));
assert.ok(exactModelVerdict.detail.includes('https://api.openai.com/v1'));
assert.equal(mediaContext.checkVerdict(
  'image', openaiImage,
  {model: 'gpt-image-2', base_url: ''},
  {validated: true, models: ['gpt-image-1']},
).ok, false, 'A valid key must not pass when the exact selected model is absent');
assert.equal(mediaContext.checkVerdict(
  'image', openaiImage,
  {model: 'gpt-image-2', base_url: 'https://proxy.example/v1'},
  {validated: true, models: ['gpt-image-2']},
).ok, false, 'A custom endpoint must not pass the fixed-endpoint check');
const xaiVideo = mediaCatalogue.video[0];
const exactVideoVerdict = mediaContext.checkVerdict(
  'video', xaiVideo,
  {model: 'grok-imagine-video-1.5', base_url: ''},
  {validated: true, provider_contacted: true,
    models: ['grok-imagine-video', 'grok-imagine-video-1.5']},
);
assert.equal(exactVideoVerdict.ok, true);
assert.match(exactVideoVerdict.detail, /grok-imagine-video-1\.5/);
assert.equal(mediaContext.checkVerdict(
  'video', xaiVideo,
  {model: 'grok-imagine-video-1.5', base_url: ''},
  {validated: true, provider_contacted: true, models: ['grok-imagine-video']},
).ok, false, 'xAI video readiness must check the exact selected model');
assert.equal(mediaContext.checkVerdict(
  'video', xaiVideo,
  {model: 'grok-imagine-video-1.5', base_url: ''},
  {validated: true, provider_contacted: false,
    models: ['grok-imagine-video-1.5']},
).ok, false, 'A local-only catalogue must not claim provider-checked video access');
const openaiAuth = mediaContext.authCapabilities(openaiImage);
assert.equal(openaiAuth.apiKey, true);
assert.equal(openaiAuth.oauth, true);
assert.ok(openaiAuth.oauthReason);
const xaiAuth = mediaContext.authCapabilities(xaiImage);
assert.equal(xaiAuth.apiKey, true);
assert.equal(xaiAuth.oauth, true);
includes('Choose a compatible provider');
includes('Nothing is selected or billed automatically.');
includes('GPT Image 2');
includes('Grok Imagine Image 2.0');
includes('class="f media-model-field"');
includes('aria-describedby="image-media-model-help"');
includes('id="image-media-model-help"');
includes("+ esc(model.label || model.id)");
excludes(/\+ esc\(\(model\.label \|\| model\.id\) \+ recommended \+ capability\)/,
  'The native model select must keep its visible option label concise');
includes("labels.push('Generation')");
includes("labels.push('Editing')");
includes('API key supported');
includes('ChatGPT via Codex');
includes('data-manage-openai-account');
includes('/api/openai/account/status');
includes('/api/openai/account/login');
includes('never receives its token');
includes('does not generate, edit, or bill for an image');
includes('Direct API endpoint');
includes('Check selected model');
includes('Checks the exact selected model at the provider’s fixed endpoint.');
includes('Legacy image settings were cleaned up.');
includes('Needs save');
includes('OpenAI and xAI sign-in are managed only by their shared account cards');
includes('body: JSON.stringify({ kind, cfg: checkConfig })');
excludes(/Check API key &amp; models/,
  'A generic key check must not imply the selected exact model was verified');
includes("provider.id === 'openai' ? openaiLaneAuthPanel(kind)");
for (const [labelFor, controlId] of [
  ['${kind}-media-provider', '${kind}-media-provider'],
  ['${kind}-media-api-key', '${kind}-media-api-key'],
  ['image-media-model', 'image-media-model'],
  ['image-media-size', 'image-media-size'],
]) {
  includes(`for="${labelFor}"`);
  includes(`id="${controlId}"`);
}
includes("const controlId = 'image-media-' + String(field)");
includes('const controlId = `${kind}-${field}-choice`;');
includes('<label for="${esc(controlId)}">${esc(label)}</label>');
includes('id="${kind}-provider" data-provider="${kind}"');
includes('id="${kind}-api-key" type="password"');
includes('id="${kind}-endpoint" data-endpoint="${kind}"');
includes('id="res-${kind}" role="status" aria-live="polite"');
includes('aria-label="${exactMediaCheck ? `Check selected ${kind} model at fixed provider endpoint`');
includes('id="res-${kind}" role="status" aria-live="polite"');
includes('Checks whether the provider returns the exact selected video model for this account.');
includes('id="video-authoring-profile-label"');
includes('6 seconds · 720p · framing follows the selected motion');
excludes(/data-media-field="seconds"/,
  'Avatar motion duration is fixed by the tuned authoring pipeline, not editable UI');
excludes(/data-media-field="resolution"/,
  'Avatar motion resolution is fixed by the tuned authoring pipeline, not editable UI');
includes("state.ready = Boolean((response.ready || response.validated) && !response.error);");
includes("state.providerContacted = response.provider_contacted === true;");
includes('<span class="pill warn">catalog ready</span>');
includes('<span class="pill ok">provider checked</span>');
includes('use Test to check the exact selected model.');
excludes(/validating with the provider/i,
  'Local-only OAuth catalogues must not be described as provider validation');
const mediaRenderStart = source.indexOf('function renderMediaDefault(kind)');
const mediaRenderEnd = source.indexOf('\nfunction choiceField(', mediaRenderStart);
assert.ok(!/if \(config\.provider !== provider\.id\) config\.provider = provider\.id/
  .test(source.slice(mediaRenderStart, mediaRenderEnd)),
  'Fresh avatar media settings must not be silently mutated');

const refreshStart = source.indexOf('/* qa:config-refresh-contract:start */');
const refreshEnd = source.indexOf('/* qa:config-refresh-contract:end */');
assert.ok(refreshStart >= 0 && refreshEnd > refreshStart,
  'Expected executable config-refresh contract');
const refreshContext = {};
vm.runInNewContext(source.slice(refreshStart, refreshEnd) + `
  ;globalThis.capture = captureLaneDrafts;
  globalThis.merge = mergeConfigRefresh;`, refreshContext, {filename: file});
const laneDrafts = refreshContext.capture({
  llm: {provider: 'xai', model: 'unsaved-chat', api_key: '', has_key: true},
  tts: {provider: 'system', voice: 'Samantha', has_key: false},
  stt: {provider: 'mlx_whisper', model: 'unsaved-stt', has_key: false},
  image: {provider: 'gemini', model: 'unsaved-image', has_key: true},
  video: {provider: 'xai', model: 'unsaved-video', has_key: false},
});
const refreshed = refreshContext.merge({config: {
  llm: {provider: 'openai', model: 'saved-chat', api_key: '', has_key: true},
  tts: {provider: 'system', voice: 'Alex', api_key: '', has_key: false},
  stt: {provider: 'mlx_whisper', model: 'saved-stt', api_key: '', has_key: false},
  image: {provider: 'gemini', model: 'saved-image', api_key: '', has_key: true},
  video: {provider: 'xai', model: 'saved-video', api_key: '', has_key: false},
  has_keys: {xai: true},
  key_checks: {xai: {ok: true}},
}}, laneDrafts);
assert.equal(refreshed.llm.provider, 'xai');
assert.equal(refreshed.llm.model, 'unsaved-chat');
assert.equal(refreshed.llm.has_key, false,
  'A refreshed lane-key marker must not cross an unsaved provider change');
assert.equal(refreshed.image.model, 'unsaved-image');
assert.equal(refreshed.image.has_key, true,
  'A refreshed lane-key marker is retained when the provider still matches');
assert.equal(refreshed.has_keys.xai, true);
assert.equal(refreshed.key_checks.xai.ok, true);
const checkPlatformStart = source.indexOf('async function checkPlatform(');
const checkPlatformEnd = source.indexOf('\nfunction collectKeys()', checkPlatformStart);
const checkPlatformSource = source.slice(checkPlatformStart, checkPlatformEnd);
assert.ok(checkPlatformSource.includes('mergeConfigRefresh(saved, laneDrafts)'));
assert.ok(checkPlatformSource.includes('mergeConfigRefresh(persisted, laneDrafts)'));
assert.ok(checkPlatformSource.includes("['image', 'video'].forEach(renderMediaDefault)"),
  'A key check must refresh both avatar provider cards');
includes('data-api-key="${kind}" value="${esc(config.api_key || \'\')}"');
includes('data-media-key="${kind}"');
includes('value="${esc(config.api_key || \'\')}"');

const missingLiveKitKeys = executableContract(
  '/* qa:livekit-key-readiness:start */',
  '/* qa:livekit-key-readiness:end */',
  'missingLiveKitKeyProviders');
assert.deepEqual(Array.from(missingLiveKitKeys({
  llm: {source: 'byok', provider: 'openai'},
  stt: {source: 'managed', provider: 'deepgram'},
  tts: {source: 'byok', provider: 'xai'},
}, {xai: true})), ['openai', 'xai'],
'An inactive stored xAI key must never satisfy a disconnected global OAuth mode');
assert.deepEqual(Array.from(missingLiveKitKeys({
  llm: {source: 'byok', provider: 'openai'},
  stt: {source: 'byok', provider: 'xai'},
  tts: {source: 'byok', provider: 'xai'},
}, {}, true)), ['openai'],
'A connected global xAI OAuth mode must satisfy every xAI Live Talk stage');
assert.deepEqual(Array.from(missingLiveKitKeys({
  llm: {source: 'byok', provider: 'openai'},
  stt: {source: 'byok', provider: 'openai'},
}, {})), ['openai'], 'Missing BYOK providers must be deduplicated');
const liveKitErrorMessage = executableContract(
  '/* qa:livekit-error-copy:start */',
  '/* qa:livekit-error-copy:end */',
  'liveKitErrorMessage');
const retiredSelectionCopy = 'This saved Live Talk combination is no longer supported. '
  + 'Choose one approved option for each stage, then save Live Talk.';
assert.equal(liveKitErrorMessage('livekit_selection_not_allowed', 'fallback'), retiredSelectionCopy);
assert.equal(liveKitErrorMessage({detail: 'livekit_selection_not_allowed'}, 'fallback'), retiredSelectionCopy);
assert.equal(liveKitErrorMessage(new Error('livekit_selection_not_allowed: retired tuple'), 'fallback'),
  retiredSelectionCopy);
assert.match(liveKitErrorMessage('livekit_credential_store_unavailable', 'fallback'), /unlock.*Keychain/i);
assert.match(liveKitErrorMessage('livekit_access_rejected', 'fallback'), /access token was rejected/i);
assert.match(liveKitErrorMessage('livekit_rate_limited', 'fallback'), /temporarily busy/i);
assert.match(liveKitErrorMessage('livekit_service_unavailable', 'fallback'), /temporarily unavailable/i);
assert.equal(liveKitErrorMessage('unknown_livekit_protocol_code', 'Safe fallback.'), 'Safe fallback.',
  'Unknown machine codes must not be rendered');
assert.equal(liveKitErrorMessage('LiveKit configuration is unavailable.', 'fallback'),
  'LiveKit configuration is unavailable.', 'An ordinary safe explanation should survive');
assert.ok((source.match(/setLiveKitState\(liveKitErrorMessage\(error,/g) || []).length >= 2,
  'Both LiveKit render and Save errors must use the friendly mapper');
includes('Live Talk cannot use a key pasted only into a Chat, PTT, or read-aloud lane.');
includes('Live Talk does not fall back to a lane credential.');
includes('Aura-2 Andromeda is English-only.');
includes('xAI recognition is automatic only within its exact 25-language list; Chinese is unavailable.');
includes('every selected personal provider account are available');
includes('install a build with the Live Talk service configured');
includes('unlock this Mac’s login Keychain');

console.log('OpenClam Studio settings QA passed.');
