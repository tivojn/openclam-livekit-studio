'use strict';
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const vm = require('node:vm');
const { LiveTalkOwner } = require('../electron/live-talk-owner.cjs');
const html = fs.readFileSync(require('node:path').join(__dirname, '../web/index.html'), 'utf8');
const lifecycle = html.slice(html.indexOf('    async function startLiveTalk()'), html.indexOf('    const selectShellDisplayMode'));
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const windowFor = () => {
  const wc = new EventEmitter(); wc.isDestroyed = () => false; wc.send = (channel, value) => wc.emit(channel, value);
  return { webContents: wc, isDestroyed: () => false };
};
const chat = windowFor(), avatar = windowFor(), outsider = windowFor();
const owner = new LiveTalkOwner(() => [chat, avatar], (w, ch, value) => w.webContents.send(ch, value));
const rooms = [];
let microphoneGate = null, failConstructor = false, leaseGate = null;
function renderer(window) {
  let lease;
  class Room {
    constructor() {
      if (failConstructor) throw new Error('constructor failed');
      rooms.push(this); this.mic = false; this.connected = false;
      this.localParticipant = { setMicrophoneEnabled: async value => {
        if (value && microphoneGate) await microphoneGate.promise;
        this.mic = value;
      }};
    }
    on() {} registerRpcMethod() {} unregisterRpcMethod() {}
    async connect() { this.connected = true; }
    async disconnect() { this.connected = false; this.mic = false; }
  }
  const noop = () => {};
  const context = {
    window: { LivekitClient: { Room, RoomEvent: {}, Track: { Kind: { Audio: 'audio' } } } },
    shell: {
      claimLiveTalk: async () => { const result = owner.claim(window.webContents); lease = result || lease; if(leaseGate)await leaseGate.promise; return Boolean(result); },
      setLiveTalk: value => owner.setPhase(window.webContents, { lease, value }),
      endSharedLiveTalk: () => owner.end(window.webContents),
    },
    AbortController, setTimeout, clearTimeout, performance, Map, Set,
    fetch: async () => ({ server_url: 'mock', participant_token: 'mock' }), safeJSON: x => x,
    selectedOpenClawAgent: () => 'main',
    live: null, liveStarting: false, liveStopping: null, liveCancelRequested: false, sharedLivePhase: 'idle', ptt: null,
    turnController: null, turnControllerOrigin: null, speechExpressionTimeline: [], agentSpeaking: false,
    speechExpressionPlan: {}, reactiveMouthState: {}, currentViseme: 'sil',
    pttButton: {}, sendButton: {}, agentModeSelect: {}, EMAIL_RPC: 'email', AGENT_TURN_RPC: 'agent',
    roomAudioReady: async () => true,
    markAgentReady: session => { if(context.live === session) context.shell.setLiveTalk('connected'); },
  };
  for(const name of ['markActivity','notify','stopSpeech','ensureAudioGraph','setLiveButton','setStatus','startConnectionSound',
    'handleEmailRPC','handleAgentTurnRPC','attachAgentAudio','resetLiveTalkTTSTimingState',
    'releaseAgentAudioAttachment','handleLiveTalkTTSTimingData','handleTranscript','resumeChatSpeakingPose',
    'stopConnectionSound','resizeComposer','reportControlRects']) context[name] = noop;
  for(const name of ['makeLiveTalkAudioState','makeLiveTalkTTSTimingState','makeSpeechExpressionPlan'])context[name]=()=>({});
  context.liveTalkConnectionError = error => error.message;
  vm.createContext(context); vm.runInContext(lifecycle, context);
  const toggle = html.match(/const toggleLiveTalk = \(\) => \{[\s\S]*?\n    \};/);
  assert.ok(toggle, 'the visible Live Talk button handler must remain testable');
  vm.runInContext(toggle[0] + '\nthis.toggleLiveTalk = toggleLiveTalk;', context);
  window.webContents.on('openclam:live-state', state => { context.sharedLivePhase = state.phase; });
  window.webContents.on('openclam:live-stop', () => { context.liveCancelRequested = true; context.stopLiveTalk('ended'); });
  return context;
}
(async () => {
  const a = renderer(chat), b = renderer(avatar);
  assert.equal(owner.claim(outsider.webContents), null);
  await Promise.all([a.startLiveTalk(), b.startLiveTalk()]);
  assert.equal(rooms.length, 1, 'simultaneous windows must create exactly one room');
  assert.equal(rooms.filter(r=>r.mic).length, 1);
  assert.equal(owner.snapshot(avatar.webContents).phase, 'connected');
  assert.equal(owner.snapshot(avatar.webContents).owned, false);
  await b.startLiveTalk();
  assert.equal(rooms.length, 1, 'switching views must reuse the active call');
  b.toggleLiveTalk(); b.toggleLiveTalk();
  assert.equal(owner.phase, 'ending');
  await b.startLiveTalk();
  assert.equal(rooms.length, 1, 'no acquisition until the old microphone has stopped');
  await a.liveStopping;
  assert.equal(owner.phase, 'idle'); assert.equal(rooms.filter(r=>r.mic).length, 0);
  await b.startLiveTalk();
  assert.equal(owner.snapshot(avatar.webContents).owned, true);
  a.toggleLiveTalk(); await b.liveStopping;
  assert.equal(owner.phase, 'idle', 'handoff and hang-up work in reverse');
  // Permission resolving after cancellation must not leave a microphone active.
  microphoneGate = deferred();
  const starting = a.startLiveTalk(); await tick();
  owner.end(avatar.webContents);
  await tick();
  assert.equal(owner.phase, 'ending');
  await b.startLiveTalk();
  const count = rooms.length;
  microphoneGate.resolve(); await starting; await a.liveStopping; microphoneGate = null;
  assert.equal(rooms.filter(r=>r.mic).length, 0); assert.equal(rooms.length, count);
  assert.equal(owner.phase, 'idle');
  // Hang up even if the claim response hasn't reached the originating renderer.
  leaseGate = deferred(); const claiming = a.startLiveTalk(); await tick();
  owner.end(avatar.webContents); leaseGate.resolve(); await claiming; leaseGate = null;
  assert.equal(owner.phase, 'idle');
  failConstructor = true; await a.startLiveTalk(); failConstructor = false;
  assert.equal(owner.phase, 'idle', 'failed setup releases its lease');
  const stale = owner.claim(chat.webContents);
  chat.webContents.emit('did-start-navigation', {}, '/frame', false, false);
  assert.equal(owner.phase, 'connecting', 'iframe navigation does not end the call');
  chat.webContents.emit('did-start-navigation', {}, '/', false, true);
  assert.equal(owner.phase, 'idle', 'reload releases the old document');
  const fresh = owner.claim(chat.webContents);
  owner.release(chat.webContents, stale);
  assert.equal(owner.phase, 'connecting', 'old unload cannot release a new call');
  owner.setPhase(chat.webContents,{lease:fresh,value:'connected'});
  chat.webContents.emit('render-process-gone');
  assert.equal(owner.phase, 'idle');
  assert.equal(chat.webContents.listenerCount('did-start-navigation'), 0);
  console.log('Live Talk ownership passed: two views, simultaneous start, both directions, double hang-up, delayed microphone, pending claim, setup failure, reload, crash and stale lease.');
})().catch(error => { console.error(error); process.exitCode = 1; });
