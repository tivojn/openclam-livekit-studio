'use strict';

// Run the real renderer listeners and Electron timer without opening an app,
// changing settings, or loading/rebuilding any avatar assets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const renderer = fs.readFileSync(path.join(root, 'web/index.html'), 'utf8');
const main = fs.readFileSync(path.join(root, 'electron/main.cjs'), 'utf8');
const declaration = name => {
  const match = renderer.match(new RegExp(
    `    const ${name} = [\\s\\S]*?\\n    \\};`));
  assert.ok(match, `${name} must remain independently testable`);
  return match[0];
};
const plain = value => JSON.parse(JSON.stringify(value));
let now = 100;
let activityCalls = 0;
let hitCalls = 0;
let engagementCalls = 0;
let sampledAvatarHit = false;
const listeners = [];
const context = vm.createContext({
  pointer: { x: -1, y: -1, inside: false, seen: false, at: 0 },
  lastFrame: 42,
  dragging: false,
  avatarHit: false,
  root: { classList: { contains: name => name === 'chat-mode' } },
  performance: { now: () => now },
  innerWidth: 800,
  innerHeight: 600,
  markActivity: () => { activityCalls += 1; },
  updateHit: () => { hitCalls += 1; context.avatarHit = sampledAvatarHit; },
  syncPetEngagement: () => { engagementCalls += 1; },
  document: { addEventListener: (type, callback, options) => {
    listeners.push({ type, callback, options });
  } },
});
const registration = renderer.match(
  /    document\.addEventListener\('pointermove', handleLocalPointerMove,[\s\S]*?\);/);
assert.ok(registration, 'local gaze must subscribe above the canvas');
vm.runInContext([
  declaration('handleGlobalPointer'), declaration('handleLocalPointerMove'),
  declaration('cursorGazeTarget'), declaration('smoothCursorGaze'),
  declaration('faceEyelidPolicy'), registration[0],
  'globalThis.gazeQA = { handleGlobalPointer, cursorGazeTarget, smoothCursorGaze, faceEyelidPolicy };',
].join('\n'), context);
assert.equal(listeners.length, 1);
assert.equal(listeners[0].type, 'pointermove');
assert.deepEqual(plain(listeners[0].options), { passive: true, capture: true },
  'gaze cannot prevent thread scrolling, selection, or gesture bubbling');
const move = listeners[0].callback;
const qa = context.gazeQA;
const mouse = (x, y, target = 'thread') => ({
  pointerType: 'mouse', clientX: x, clientY: y, buttons: 0, target,
  preventDefault: () => assert.fail('gaze must not consume a pointer event'),
  stopPropagation: () => assert.fail('gaze must not stop propagation'),
});

// The original bug: moving the mouse before any pointerdown did nothing.
// Capture delivery must work whichever element/layer is under the cursor.
for (const target of ['thread', 'avatar', 'composer', 'sidebar', 'rail']) {
  now += 16;
  move(mouse(650, 340 + now, target));
  assert.equal(context.pointer.seen, true);
  assert.equal(context.pointer.x, 650);
  assert.equal(context.pointer.at, now);
  assert.equal(context.lastFrame, 0, 'movement must schedule the next gaze paint');
}
assert.equal(context.dragging, false, 'hover must never start an avatar drag');
assert.equal(activityCalls, 0, 'movement away from the avatar must not cancel Walk/Moves');
const rightTarget = qa.cursorGazeTarget(context.pointer, { x: 400, y: 250 },
  { x: 9, y: 3.5 }, { width: 800, height: 600 });
assert.ok(rightTarget.x > 5 && rightTarget.y > 0, 'hover must drive actual gaze math');
now += 16;
move(mouse(80, 90));
const leftTarget = qa.cursorGazeTarget(context.pointer, { x: 400, y: 250 },
  { x: 9, y: 3.5 }, { width: 800, height: 600 });
assert.ok(leftTarget.x < -5 && leftTarget.y < 0,
  'reversing cursor direction without clicking must reverse both eye targets');
const state = { x: rightTarget.x, y: rightTarget.y, at: now - 16 };
const eased = qa.smoothCursorGaze(state, leftTarget, now);
assert.ok(eased.x < rightTarget.x && eased.x > leftTarget.x,
  'cursor attention retains smooth bounded motion rather than jumping');

const lastMotion = context.pointer.at;
now += 300;
qa.handleGlobalPointer({ x: 80, y: 90, inside: true });
assert.equal(context.pointer.at, lastMotion, 'stationary IPC heartbeats must not prolong fast repaint');
const beforeIgnored = plain(context.pointer);
move({ pointerType: 'touch', clientX: 700, clientY: 500 });
move({ pointerType: 'mouse', clientX: NaN, clientY: 100 });
move({ pointerType: 'mouse', clientX: undefined, clientY: 100 });
assert.deepEqual(plain(context.pointer), beforeIgnored, 'touch/invalid events must not retarget the eyes');
context.dragging = true;
move(mouse(600, 300));
assert.deepEqual(plain(context.pointer), beforeIgnored, 'a drag retains its existing pointer ownership');
context.dragging = false;
sampledAvatarHit = true;
move(mouse(401, 251, 'avatar'));
assert.equal(activityCalls, 1, 'a real avatar hover still wakes its remembered standby pose');
assert.ok(hitCalls > 0 && engagementCalls > 0, 'existing hit-testing and roam engagement remain connected');

// Merely fixing the event source cannot opt cartoons into old tiny eye strips.
assert.equal(qa.faceEyelidPolicy(true, false, 1), 'static-canonical');
assert.equal(qa.faceEyelidPolicy(true, true, 0), 'static-canonical');
assert.equal(qa.faceEyelidPolicy(true, true, 1), 'stylized-closed');
assert.equal(qa.faceEyelidPolicy(false, false, 1), 'photo-strip');
assert.match(renderer, /shell\.onPetPointer\(handleGlobalPointer\)/,
  'desktop gaze must retain its global cursor feed');

// The framed Chat/Talk renderer is not mainWindow. Exercise the real single
// timer with only chat visible, including cursor travel outside its bounds.
const timerStart = main.indexOf('function startPetPointerTracking() {');
const timerEnd = main.indexOf('\nfunction applyPetOpacity(', timerStart);
assert.ok(timerStart >= 0 && timerEnd > timerStart);
let tick;
let desktopNow = 1000;
let screenPoint = { x: 340, y: 300 };
let chatVisible = true;
let chatDestroyed = false;
let petHitCalls = 0;
const posts = [];
const chat = {
  isDestroyed: () => chatDestroyed,
  isVisible: () => chatVisible,
  getContentBounds: () => ({ x: 100, y: 128, width: 800, height: 600 }),
  getBounds: () => assert.fail('chat coordinates must exclude its titlebar'),
};
const timerContext = vm.createContext({
  stopPetPointerTracking: () => {},
  petPointerTimer: null,
  setInterval: (callback, milliseconds) => {
    assert.equal(milliseconds, 32, 'do not add another perpetual timer');
    tick = callback;
    return { unref: () => {} };
  },
  screen: { getCursorScreenPoint: () => screenPoint },
  mainWindow: null, buddyWindow: null, chatWindow: chat,
  setPetHit: () => { petHitCalls += 1; },
  setBuddyHit: () => { petHitCalls += 1; },
  petControlRects: [], buddyControlRects: [], petDrag: false, buddyDrag: false,
  state: { petRoam: false },
  pointerLastSent: { pet: null, buddy: null, chat: null },
  Date: { now: () => desktopNow },
  post: (window, topic, point) => posts.push({ window, topic, point }),
});
vm.runInContext(main.slice(timerStart, timerEnd) + '\nstartPetPointerTracking();', timerContext);
tick();
assert.equal(posts.length, 1, 'the distinct chatWindow must receive cursor movement');
assert.equal(posts[0].window, chat);
assert.equal(posts[0].topic, 'openclam:pet-pointer');
assert.deepEqual(plain(posts[0].point), { x: 240, y: 172, inside: true });
desktopNow += 16;
tick();
assert.equal(posts.length, 1, 'a stationary cursor must not flood chat IPC');
desktopNow += 251;
tick();
assert.equal(posts.length, 2, 'the existing sparse heartbeat remains available');
screenPoint = { x: -200, y: 1000 };
tick();
assert.deepEqual(plain(posts.at(-1).point), { x: -300, y: 872, inside: false });
assert.equal(petHitCalls, 0, 'attention-only chat must never receive pet click-through changes');
chatVisible = false;
const beforeHidden = posts.length;
screenPoint = { x: 500, y: 500 };
tick();
assert.equal(posts.length, beforeHidden, 'hidden chat does not consume pointer IPC');
chatVisible = true;
chatDestroyed = true;
tick();
assert.equal(posts.length, beforeHidden, 'closed chat cannot receive cursor IPC');

// Execute the real eye-layer ordering. New cartoon wet-eye masks are measured
// from artwork; legacy under-eye strips must not paint the neutral lower iris
// back over them. Ara/photo and unknown packages retain their approved order.
const eyeOrderStart = renderer.indexOf('      const gazeAfterUnderEye =');
const eyeOrderEnd = renderer.indexOf('      const stylizedBlinkReady =', eyeOrderStart);
assert.ok(eyeOrderStart >= 0 && eyeOrderEnd > eyeOrderStart);
const eyeOrderCode = renderer.slice(eyeOrderStart, eyeOrderEnd);
const gazeCalls = ['gaze-l', 'gaze-r'];
const underEyeCalls = ['eyebag-l', 'eyebag-r'];
for (const mode of [undefined, 'photo-rigid-iris-v1', 'unknown',
  'soft-3d-neutral-gaze-v1', 'soft-3d-rigid-iris-v1', 'soft-3d-authored-iris-v1',
  'authored-2d-rigid-iris-v1']) {
  for (const hasUnderEye of [false, true]) {
    for (const speaking of [false, true]) {
      const calls = [];
      const context = vm.createContext({
        manifest: {
          gaze: { mode, l: { box: [0, 0, 10, 10] }, r: { box: [10, 0, 10, 10] } },
          eyebag: hasUnderEye ? { ups: [0, 1, 2.3], l: {}, r: {} } : null,
        },
        layers: {
          gaze: { l: 'gaze-l', r: 'gaze-r' },
          eyebag: { l: 'eyebag-l', r: 'eyebag-r' },
        },
        faceContext: {},
        gazeXValues: [-9, 0, 9], gazeYValues: [-3.5, 0, 3.5],
        gaze: { x: 9, y: 3.5 }, nearestIndex: () => 2,
        upperFaceSpeaking: speaking, mouthOnlySmile: false,
        expression: { underEye: .5, asymmetry: .1 },
        eyebagGain: 1, eyelidClosure: { l: .2, r: .3 },
        drawStripState: (_target, image, _spec, _values, _value, row, interpolate) => {
          calls.push(image);
          if (image.startsWith('gaze-')) {
            assert.equal(row, 2);
            assert.equal(interpolate, undefined,
              'rigid irises must not crossfade two positions into a double pupil');
          }
        },
      });
      vm.runInContext(eyeOrderCode, context);
      const authored = ['soft-3d-rigid-iris-v1', 'soft-3d-authored-iris-v1',
        'authored-2d-rigid-iris-v1'].includes(mode);
      const band = hasUnderEye ? underEyeCalls : [];
      assert.deepEqual(calls, authored ? [...band, ...gazeCalls] : [...gazeCalls, ...band],
        `${mode || 'legacy'} owns its eye aperture and paints every eye exactly once`);
    }
  }
}

console.log('Cursor gaze QA: no-click movement, layer ownership, smoothing, mode preservation, photo/style isolation, and chat IPC passed.');
