'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const page = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const helper = name => {
  const start = page.indexOf(`    const ${name} = `);
  assert.ok(start >= 0, name);
  return page.slice(start, page.indexOf('\n    };', start) + 7);
};
function gestures(chat, desktopCloseUp = false) {
  const listeners = new Map(), calls = [], timers = new Map(); let timer = 0;
  const documentEvents = new Map(), windowEvents = new Map();
  const canvas = { style: { opacity: '1' }, setPointerCapture: id => calls.push(['capture', id]),
    addEventListener: (type, cb) => listeners.set(type, cb) };
  const s = { canvas, console, avatar3d: { orbit: { yaw: 0, pitch: 0 }, setOrbit(value) { this.orbit = value; } },
    document: { addEventListener: (type, cb) => documentEvents.set(type, cb) },
    window: { addEventListener: (type, cb) => windowEvents.set(type, cb) },
    avatar3dOrbitUntil: 0, avatarOrbitGesture: false, avatarOrbitTimer: 0,
    ready: true, avatarHit: false, dragging: false, canvasGesture: null, avatarTapTimer: 0,
    live:null,sharedLivePhase:'idle',startRecording:()=>calls.push(['record']),stopRecording:cancel=>calls.push(['release',cancel]),toggleLiveTalk:()=>calls.push(['live']),
    avatarZoomGesture: null, avatarZoomSettleTimer: 0, lastFrame: 1,
    root: { classList: { contains: value => value === 'chat-mode' && chat, add() {}, remove() {} } },
    interactionLayer: 'thread', chatWorkspace: { contains: () => true }, getSelection: () => null,
    shellState: { desktopCloseUp, pet: { enabled: true, opacity: 1, zoom: .6, roam: false } },
    chatAvatarOffset: { x: 0, y: 0 }, desktopCloseUpOffset: { x: 0, y: 0 },
    manualMotionKind: null, manualMotionStartedAt: 0, chatWalkState: null,
    markActivity() {}, updateHit: () => calls.push(['hit']), handleGlobalPointer() {},
    paintedAvatarAt: point => point.x > 0 && point.x < 100, pointOnHead: () => false,
    performance: { now: () => 1000 }, localStorage: { setItem() {} }, avatar3dOrbitKey: () => 'orbit',
    setTimeout: cb => { timers.set(++timer, cb); return timer; }, clearTimeout: id => timers.delete(id),
    requestAnimationFrame: cb => { timers.set(++timer, cb); return timer; }, cancelAnimationFrame: id => timers.delete(id),
    saveChatAvatarOffset: () => calls.push(['save']), AVATAR_ZOOM_SETTLE_MS: 140,
    PET_ZOOM_RANGES: { stand: {}, roam: { min: .5, max: 3 } }, innerHeight: 800,
    shell: { setPetZoomLive: value => calls.push(['zoom', value]),
      beginPetDrag: p => calls.push(['start', p]), movePetDrag: p => calls.push(['move', p]), endPetDrag: () => calls.push(['end']) },
  };
  vm.createContext(s);
  for (const name of ['boundedChatAvatarOffset','numericAvatarZoom','pinchZoomValue','activeAvatarZoom',
    'holdAvatarZoom','publishAvatarZoom','finishAvatarZoom','avatar3DGestureTarget','setAvatar3DOrbit',
    'handleAvatar3DWheel','handleAvatarPinch','endCanvasGesture','beginCanvasGesture','handleAvatarDoubleClick']) {
    vm.runInContext(helper(name) + `\nglobalThis.${name} = ${name};`, s);
  }
  const start = page.indexOf("    canvas.addEventListener('pointermove', event => {");
  vm.runInContext(page.slice(start, page.indexOf("    canvas.addEventListener('wheel'", start)), s);
  const event = (more = {}) => ({ button: 0, pointerId: 1, clientX: 50, clientY: 50, screenX: 150, screenY: 150,
    target: chat ? { closest: () => null } : canvas, preventDefault() { this.prevented = true; }, ...more });
  return { s, calls, timers, event, listeners, documentEvents, windowEvents, move: listeners.get('pointermove') };
}
// Speech regions remain consistent in both presentations. Moving wins over
// holding, head double-clicks never open ASR, and cancellation discards audio.
for(const chat of [false,true]) {
  const {s,calls,event,move,timers,documentEvents}=gestures(chat);
  s.pointOnHead=p=>p.y<30;
  s.beginCanvasGesture(event({clientY:50}));
  timers.get(s.canvasGesture.holdTimer)();
  assert(calls.some(c=>c[0]==='record'),'body hold starts ASR in either mode');
  move(event({clientX:80}));assert.equal(s.dragging,false,'recording owns a held body');
  documentEvents.get('pointerup')(event({type:'pointerup'}));
  assert.deepEqual(calls.at(-1),['release',false],'release on another surface submits ASR');
  s.beginCanvasGesture(event());timers.get(s.canvasGesture.holdTimer)();
  documentEvents.get('pointercancel')(event({type:'pointercancel'}));
  assert.deepEqual(calls.at(-1),['release',true],'cancel never submits an unintended voice turn');
  const recordings=calls.filter(c=>c[0]==='record').length;
  s.beginCanvasGesture(event());const hold=s.canvasGesture.holdTimer;move(event({clientX:80}));
  assert(!timers.has(hold),'drag cancels the pending body hold');s.endCanvasGesture(event());
  assert.equal(calls.filter(c=>c[0]==='record').length,recordings);
  s.beginCanvasGesture(event({clientY:15}));assert.equal(s.canvasGesture.holdTimer,0,'head is reserved for Live Talk');s.endCanvasGesture(event());
  s.handleAvatarDoubleClick(event({clientY:15}));assert.equal(calls.filter(c=>c[0]==='live').length,1);
  s.handleAvatarDoubleClick(event({clientY:50}));s.handleAvatarDoubleClick(event({clientX:-1,clientY:15}));
  if(chat)s.handleAvatarDoubleClick(event({clientY:15,target:{closest:()=> 'textarea'}}));
  assert.equal(calls.filter(c=>c[0]==='live').length,1,'body, transparent pixels and controls do not start Live Talk');
  s.avatarHit=true;s.beginCanvasGesture(event({clientX:-1}));assert.equal(s.canvasGesture,null,'stale hover cannot acquire a transparent pixel');
}
// A moving alpha surface can deliver release to the thread, or lose capture
// when a native window takes focus. Neither may leave reactions paused forever.
for (const [chat, closeUp] of [[true,false],[false,false],[false,true]]) {
  for (const release of ['thread-up','thread-cancel','lost-capture','blur']) {
    const {s,event,move,listeners,documentEvents,windowEvents,calls}=gestures(chat,closeUp);
    s.beginCanvasGesture(event());move(event({clientX:75,clientY:65}));
    assert.equal(s.dragging,true);
    documentEvents.get('pointerup')(event({pointerId:99}));
    assert.equal(s.dragging,true,'an unrelated pointer cannot end placement');
    if(release==='blur')windowEvents.get('blur')();
    else if(release==='lost-capture')listeners.get('lostpointercapture')(event());
    else documentEvents.get(release==='thread-up'?'pointerup':'pointercancel')(event());
    assert.equal(s.canvasGesture,null);assert.equal(s.dragging,false,'released input must not block automatic motions');
    assert(calls.some(c=>c[0]===(chat||closeUp?'save':'end')),'preserve placement and end native drag');
    // Duplicate native release/capture events are harmless.
    listeners.get('lostpointercapture')(event());documentEvents.get('pointerup')(event());
  }
}
for (const chat of [false, true]) {
  const { s, calls, event, move } = gestures(chat);
  s.beginCanvasGesture(event());
  assert.ok(s.canvasGesture, 'first click must work before a cached hover in either mode');
  move(event({ clientX: 75, clientY: 65, screenX: 175, screenY: 165 }));
  if (chat) assert.deepEqual(JSON.parse(JSON.stringify(s.chatAvatarOffset)), { x: 25, y: 15 });
  else assert.ok(calls.some(c => c[0] === 'move'), 'desktop drag reaches native placement');
  s.endCanvasGesture(event());
  assert.equal(s.dragging, false);
  s.beginCanvasGesture(event({ altKey: true }));
  const movesBefore = calls.filter(c => c[0] === 'move').length;
  move(event({ clientX: 80, clientY: 70 }));
  assert.ok(s.avatar3d.orbit.yaw < 0 && s.avatar3d.orbit.pitch > 0, 'Option-drag rotates in both axes');
  assert.equal(calls.filter(c => c[0] === 'move').length, movesBefore, 'orbit does not move the window');
  s.endCanvasGesture(event());
  const beforeSwipe = { ...s.avatar3d.orbit };
  const scroll = event({ deltaY: 30, deltaX: 20, deltaMode: 0 });
  s.handleAvatar3DWheel(scroll);
  assert.equal(scroll.prevented, true);
  assert.ok(s.avatar3d.orbit.yaw > beforeSwipe.yaw && s.avatar3d.orbit.pitch < beforeSwipe.pitch,
    'two-finger scrolling uses the opposite signs to direct dragging on both axes');
  s.handleAvatar3DWheel(event({ deltaY: -30, deltaX: -20, deltaMode: 0 }));
  assert.ok(Math.abs(s.avatar3d.orbit.yaw - beforeSwipe.yaw) < 1e-8
    && Math.abs(s.avatar3d.orbit.pitch - beforeSwipe.pitch) < 1e-8, 'reverse swipe restores the original view');
  assert.equal(s.avatarOrbitGesture, true, 'orbit keeps desktop wheel delivery after silhouette moves');
  const pinch = event({ ctrlKey: true, deltaY: -20, deltaMode: 0 });
  s.handleAvatarPinch(pinch);
  assert.ok(s.shellState.pet.zoom > .6, 'pinch enlarges in both modes, including thread-on-top');
  s.paintedAvatarAt = () => false;
  s.handleAvatarPinch(event({ ctrlKey: true, deltaY: 20, deltaMode: 0 }));
  assert.ok(Math.abs(s.shellState.pet.zoom - .6) < 1e-8, 'reverse pinch continues after pixels leave cursor');
  s.finishAvatarZoom();
  assert.equal(calls.filter(c => c[0] === 'zoom').at(-1)[1].phase, 'end');
  if (chat) {
    for (const tag of ['message', 'textarea', 'button', 'header']) {
      const control = event({ target: { closest: () => tag }, ctrlKey: true, deltaY: -20 });
      s.handleAvatarPinch(control); s.handleAvatar3DWheel(control); s.beginCanvasGesture(control);
      assert.equal(control.prevented, undefined, 'text and controls retain their gestures');
      assert.equal(s.canvasGesture, null);
    }
  }
}
// Swiping (including its settling timer) and modifier-dragging must never
// change the meaning of the next ordinary drag on any placement surface.
for (const [chat, closeUp] of [[true, false], [false, false], [false, true]]) {
  const { s, calls, event, move } = gestures(chat, closeUp);
  for (const rotation of ['swipe', 'option-drag']) {
    if (rotation === 'swipe') s.handleAvatar3DWheel(event({ deltaX: 20, deltaY: 30, deltaMode: 0 }));
    else {
      s.beginCanvasGesture(event({ altKey: true }));
      move(event({ clientX: 75, clientY: 65 }));
      s.endCanvasGesture(event());
    }
    const orbit = { ...s.avatar3d.orbit };
    const offset = { ...(closeUp ? s.desktopCloseUpOffset : s.chatAvatarOffset) };
    const nativeMoves = calls.filter(c => c[0] === 'move').length;
    s.beginCanvasGesture(event());
    assert.equal(s.canvasGesture.rotating, false, 'rotation never latches onto the next plain drag');
    move(event({ clientX: 75, clientY: 65, screenX: 175, screenY: 165 }));
    assert.deepEqual({ ...s.avatar3d.orbit }, orbit, 'single-finger dragging preserves body orientation');
    if (chat || closeUp) {
      const actual = closeUp ? s.desktopCloseUpOffset : s.chatAvatarOffset;
      assert.deepEqual({ ...actual }, { x: offset.x + 25, y: offset.y + 15 }, 'plain drag moves Tia after rotation');
    } else assert.equal(calls.filter(c => c[0] === 'move').length, nativeMoves + 1, 'plain drag moves the desktop avatar');
    s.endCanvasGesture(event());
    assert.equal(s.dragging, false, 'dropping releases placement');
  }
}
(async () => {
  const old = { orbit: { yaw: .2, pitch: .3 }, disposed: false, dispose() { this.disposed = true; } };
  let resolveLoad, loads = 0;
  const replacement = { async load() { loads++; await new Promise(resolve => { resolveLoad = resolve; }); },
    setOrbit(value) { this.orbit = value; }, dispose() { this.disposed = true; } };
  const initial = { renderer: '3d', model: 'assets/model.glb', model_revision: 'old', avatar: { slug: 'tia' } };
  const next = { ...initial, model_revision: 'new' };
  const s = { avatarPresented:()=>true, residentModelURL:async()=>'assets/resident/model.gltf', ready: true, avatar3d: old, avatar3dRefresh: null, manifest: initial, assetRevision: 1,
    location: { href: 'http://localhost/' }, URL, Date, lastFrame: 1, avatar3dGazeState: {},
    syncAvatar3DControls() {}, setupCompanion: async () => {}, avatar3dApi: async () => ({ create: () => replacement }),
    fetch: async () => ({ ok: true, json: async () => next }), };
  vm.createContext(s);
  for (const name of ['avatar3dIdentity', 'avatar3dModelURL', 'refreshAvatar3D']) vm.runInContext(helper(name) + `\nglobalThis.${name}=${name};`, s);
  s.is3DRuntime = value => value.renderer === '3d';
  const pending = s.refreshAvatar3D();
  assert.equal(s.refreshAvatar3D(), pending, 'simultaneous focus/mode changes share one load');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(s.avatar3d, old); assert.equal(old.disposed, false, 'retain current scene while downloading');
  assert.equal(loads, 1); resolveLoad(); await pending;
  assert.equal(s.avatar3d, replacement); assert.equal(old.disposed, true);
  assert.deepEqual(replacement.orbit, old.orbit);
  assert.equal(s.lastFrame, 0);
  await s.refreshAvatar3D(); assert.equal(loads, 1, 'unchanged revision never reloads GLB');
  assert.match(s.avatar3dModelURL(next), /revision=new/);
  s.fetch = async () => { throw new Error('offline'); };
  await s.refreshAvatar3D(); assert.equal(s.avatar3d, replacement, 'failed refresh retains current model');
  console.log('3D interaction QA: drag, pinch, orbit, control ownership and atomic model refresh passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
