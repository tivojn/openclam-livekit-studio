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
function gestures(chat) {
  const listeners = new Map(), calls = [], timers = new Map(); let timer = 0;
  const canvas = { style: { opacity: '1' }, setPointerCapture: id => calls.push(['capture', id]),
    addEventListener: (type, cb) => listeners.set(type, cb) };
  const s = { canvas, console, avatar3d: { orbit: { yaw: 0, pitch: 0 }, setOrbit(value) { this.orbit = value; } },
    avatar3dRotateMode: false, avatar3dOrbitUntil: 0, avatarOrbitGesture: false, avatarOrbitTimer: 0,
    ready: true, avatarHit: false, dragging: false, canvasGesture: null, avatarTapTimer: 0,
    avatarZoomGesture: null, avatarZoomSettleTimer: 0, lastFrame: 1,
    root: { classList: { contains: value => value === 'chat-mode' && chat, add() {}, remove() {} } },
    interactionLayer: 'thread', chatWorkspace: { contains: () => true }, getSelection: () => null,
    shellState: { pet: { enabled: true, opacity: 1, zoom: .6, roam: false } },
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
    'handleAvatar3DWheel','handleAvatarPinch','endCanvasGesture','beginCanvasGesture']) {
    vm.runInContext(helper(name) + `\nglobalThis.${name} = ${name};`, s);
  }
  const start = page.indexOf("    canvas.addEventListener('pointermove', event => {");
  vm.runInContext(page.slice(start, page.indexOf("    canvas.addEventListener('pointerup'", start)), s);
  const event = (more = {}) => ({ button: 0, pointerId: 1, clientX: 50, clientY: 50, screenX: 150, screenY: 150,
    target: chat ? { closest: () => null } : canvas, preventDefault() { this.prevented = true; }, ...more });
  return { s, calls, timers, event, move: listeners.get('pointermove') };
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
(async () => {
  const old = { orbit: { yaw: .2, pitch: .3 }, disposed: false, dispose() { this.disposed = true; } };
  let resolveLoad, loads = 0;
  const replacement = { async load() { loads++; await new Promise(resolve => { resolveLoad = resolve; }); },
    setOrbit(value) { this.orbit = value; }, dispose() { this.disposed = true; } };
  const initial = { renderer: '3d', model: 'assets/model.glb', model_revision: 'old', avatar: { slug: 'tia' } };
  const next = { ...initial, model_revision: 'new' };
  const s = { ready: true, avatar3d: old, avatar3dRefresh: null, manifest: initial, assetRevision: 1,
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
