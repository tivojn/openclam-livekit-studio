'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {
  boundsForPetZoom,
  boundsForPetZoomAtAnchor,
  clampPetZoom,
  dockedPetBounds,
  fitPetZoomToArea,
  fitPetWindowToArea,
  petZoomAnchor,
  petZoomSize,
  roamSizeForZoom,
} = require('../electron/pet-window-bounds.cjs');

const current = { x: 962, y: 63, width: 706, height: 904 };
const base = { width: 560, height: 760 };
const minimum = { width: 140, height: 190 };

function assertCenterPreserved(bounds) {
  assert.ok(Math.abs(
    bounds.x + bounds.width / 2 - (current.x + current.width / 2),
  ) <= 0.5);
  assert.ok(Math.abs(
    bounds.y + bounds.height / 2 - (current.y + current.height / 2),
  ) <= 0.5);
}

const enlarged = boundsForPetZoom(current, base, minimum, 1.5);
assert.deepEqual(enlarged, { x: 895, y: -55, width: 840, height: 1140 });
assertCenterPreserved(enlarged);

const oversized = boundsForPetZoom(current, base, minimum, 4);
assert.deepEqual(oversized, { x: 195, y: -1005, width: 2240, height: 3040 });
assertCenterPreserved(oversized);

const reduced = boundsForPetZoom(current, base, minimum, 0.1);
assert.deepEqual(reduced, { x: 1245, y: 420, width: 140, height: 190 });
assertCenterPreserved(reduced);

// A live pinch re-applies the zoom every frame. Measured from a fixed anchor
// the window stays put; measured from its own last bounds it walks away.
const anchor = petZoomAnchor(current);
let stepped = { ...current };
for (let step = 0; step <= 200; step += 1) {
  const zoom = 0.5 + step * 0.0175;
  const anchored = boundsForPetZoomAtAnchor(anchor, base, minimum, zoom);
  assert.ok(Math.abs(anchored.x + anchored.width / 2 - anchor.x) <= 0.5);
  assert.ok(Math.abs(anchored.y + anchored.height / 2 - anchor.y) <= 0.5);
  stepped = boundsForPetZoom(stepped, base, minimum, zoom);
}
assert.deepEqual(
  boundsForPetZoomAtAnchor(anchor, base, minimum, 1.5),
  { x: 895, y: -55, width: 840, height: 1140 });

const roamBase = { width: 250, height: 340 };
const roamMinimum = { width: 96, height: 130 };
assert.deepEqual(roamSizeForZoom(roamBase, roamMinimum, 1), { width: 250, height: 340 });
assert.deepEqual(roamSizeForZoom(roamBase, roamMinimum, 2.5), { width: 625, height: 850 });
assert.deepEqual(roamSizeForZoom(roamBase, roamMinimum, 0.2), { width: 96, height: 130 });

const roamRange = { min: 0.5, max: 3 };
assert.equal(clampPetZoom(9, roamRange), 3);
assert.equal(clampPetZoom(0.1, roamRange), 0.5);
assert.equal(clampPetZoom('nope', roamRange), 1);
assert.equal(clampPetZoom(1.33, { min: 0.25, max: 4 }), 1.33);
for (const zoom of [.0001,.08,4,16,64,256]) assert.equal(clampPetZoom(zoom, {}), zoom);
for (const bad of [NaN,Infinity,0,-1,Number.MAX_VALUE,Number.MIN_VALUE]) {
  assert.equal(clampPetZoom(bad, {}, 12), 12,
    'invalid or unrepresentable zoom keeps the last applied value, not an unseen overshoot');
}

// The stuck-companion scenario: a 4x pinch left the window at 2240x3040 on a
// 1512x944 work area, unreachable under the Dock. The fitted zoom must bring
// the window back inside the work area, and the docked bounds must sit fully
// on screen at the bottom-right corner.
const area = { x: 0, y: 38, width: 1512, height: 944 };
const margin = 28;
const fitted = fitPetZoomToArea(base, minimum, 4, area, margin);
assert.ok(fitted < 4);
const fittedSize = petZoomSize(base, minimum, fitted);
assert.ok(fittedSize.width <= area.width - margin * 2);
assert.ok(fittedSize.height <= area.height - margin * 2);

// A zoom that already fits passes through untouched.
assert.equal(fitPetZoomToArea(base, minimum, 1, area, margin), 1);
assert.equal(fitPetZoomToArea(base, minimum, 'nope', area, margin), 1);

const docked = dockedPetBounds(fittedSize, area, margin);
assert.equal(docked.x + docked.width, area.x + area.width - margin);
assert.equal(docked.y + docked.height, area.y + area.height - margin);
assert.ok(docked.x >= area.x);
assert.ok(docked.y >= area.y);

// Secondary display offsets carry through to the docked corner.
const shifted = dockedPetBounds({ width: 560, height: 760 },
  { x: 1512, y: 200, width: 1920, height: 1055 }, margin);
assert.deepEqual(shifted, { x: 2844, y: 467, width: 560, height: 760 });

// The second on-desk avatar mirrors to the LEFT corner: same size, same
// bottom line, x measured from the left work-area edge so the pair sits
// symmetrically around the screen center.
const dockedLeft = dockedPetBounds(fittedSize, area, margin, 'left');
assert.equal(dockedLeft.x, area.x + margin);
assert.equal(dockedLeft.y, docked.y);
assert.equal(dockedLeft.width, docked.width);
assert.equal(
  dockedLeft.x - area.x,
  area.x + area.width - (docked.x + docked.width));
const shiftedLeft = dockedPetBounds({ width: 560, height: 760 },
  { x: 1512, y: 200, width: 1920, height: 1055 }, margin, 'left');
assert.deepEqual(shiftedLeft, { x: 1540, y: 467, width: 560, height: 760 });
// An explicit 'right' and the legacy default agree.
assert.deepEqual(dockedPetBounds(fittedSize, area, margin, 'right'), docked);

// A manual pose may leave ANY edge except the top. Even a completely hidden
// left/right/bottom pose is deliberate and must not be silently redocked.
const topOnly = { placement: 'top-only' };
for (const display of [area, { x: -1920, y: -840, width: 1920, height: 1055 }]) {
  for (const x of [display.x - 2300, display.x - 200, display.x + 2200]) {
    for (const y of [display.y - 400, display.y + 80, display.y + 2200]) {
      const requested = { x, y, width: 336, height: 456 };
      const actual = fitPetWindowToArea(requested, display, topOnly);
      assert.deepEqual(actual, { ...requested, y: Math.max(display.y, y) });
      // Existing default policy is still used by automatic dock/edge states.
      const automatic = fitPetWindowToArea(requested, display);
      assert.ok(automatic.x >= display.x);
      assert.ok(automatic.x + automatic.width <= display.x + display.width);
      assert.ok(automatic.y >= display.y);
      assert.ok(automatic.y + automatic.height <= display.y + display.height);
    }
  }
}

// The physical canvas stops growing at the GPU/work-area limit, not the
// avatar's requested scale. Place the FITTED canvas around the gesture anchor:
// retaining the raw giant rectangle's x/y would fling it far offscreen.
for (const display of [area, { x: -1920, y: -840, width: 1920, height: 1055 }]) {
  for (const centre of [
    { x: display.x + 200, y: display.y + 500 },
    { x: display.x - 400, y: display.y + 1600 },
    { x: display.x + display.width + 250, y: display.y + 70 },
  ]) {
    for (const zoom of [.08, .6, 4, 16, 256, 1e20, 1e200, .6]) {
      const wanted = boundsForPetZoomAtAnchor(centre, base, minimum, zoom);
      const actual = fitPetWindowToArea(wanted, display,
        { placement: 'top-only', anchor: centre });
      assert.ok(actual.width <= display.width && actual.height <= display.height);
      assert.ok(actual.y >= display.y);
      assert.ok(Math.abs(actual.x + actual.width / 2 - centre.x) <= .5);
      const expectedY = Math.max(display.y, Math.round(centre.y - actual.height / 2));
      assert.equal(actual.y, expectedY);
      assert.equal(clampPetZoom(zoom, {}), zoom, 'canvas fitting cannot change the saved zoom');
    }
    const large = fitPetWindowToArea(boundsForPetZoomAtAnchor(centre, base, minimum, 256),
      display, { placement: 'top-only', anchor: centre });
    const smaller = fitPetWindowToArea(boundsForPetZoomAtAnchor(centre, base, minimum, .6),
      display, { placement: 'top-only', anchor: centre });
    assert.ok(smaller.height < large.height, 'reversing a pinch immediately shrinks the backing');
  }
}

// Native-rectangle representability only; malformed data must never reach
// Electron as Infinity/NaN/unsafe int32. Finite everyday offscreen positions
// are not corrected merely because they do not intersect a display.
for (const value of [NaN, Infinity, -Infinity, Number.MAX_VALUE, -Number.MAX_VALUE]) {
  const actual = fitPetWindowToArea({ x: value, y: value, width: 300, height: 450 }, area, topOnly);
  assert.deepEqual(actual, { x: area.x, y: area.y, width: 300, height: 450 });
}
assert.deepEqual(fitPetWindowToArea({ x: -200000, y: 400000, width: 300, height: 450 }, area, topOnly),
  { x: -200000, y: 400000, width: 300, height: 450 });

// Execute only the actual native-event guard in a mocked window. Requiring
// main.cjs would start the real application/backend and is intentionally avoided.
const mainSource = fs.readFileSync(path.join(__dirname, '../electron/main.cjs'), 'utf8');
const nativeGuard = mainSource.match(/function guardManualPetBounds\([^\n]*\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(nativeGuard, 'native OS movement/resizing must use the same manual top-only guard');
const hooks = new Map();
let nativeBounds = { x: -1900, y: 2200, width: 336, height: 456 };
let manual = true, nativeSets = 0, prevented = 0;
const nativeWindow = {
  isDestroyed: () => false,
  on: (event, callback) => hooks.set(event, callback),
  getBounds: () => ({ ...nativeBounds }),
  setBounds: (bounds) => {
    nativeBounds = { ...bounds };
    nativeSets += 1;
    // Real setBounds also emits move/resize. Guard against recursive correction.
    hooks.get('move')?.();
    hooks.get('resize')?.();
  },
};
vm.runInNewContext(`${nativeGuard}\nguardManualPetBounds(window, isManual);`, {
  window: nativeWindow, isManual: () => manual, fitPetWindowToArea,
  screen: { getDisplayMatching: () => ({ workArea: area }) },
});
hooks.get('move')();
hooks.get('resize')();
assert.equal(nativeSets, 0, 'OS events must leave intentional left/bottom overflow untouched');
nativeBounds.y = -800;
hooks.get('move')();
assert.equal(nativeBounds.y, area.y);
assert.equal(nativeBounds.x, -1900);
assert.equal(nativeSets, 1, 'top correction must be reentrancy safe');
const resizeEvent = { preventDefault: () => { prevented += 1; } };
hooks.get('will-resize')(resizeEvent, { x: 2000, y: 2200, width: 5000, height: 4000 });
assert.equal(prevented, 1, 'oversized OS resizing is corrected before GPU allocation');
assert.equal(nativeBounds.x, 2000);
assert.equal(nativeBounds.y, 2200);
assert.ok(nativeBounds.width <= area.width && nativeBounds.height <= area.height);
manual = false;
const lastSets = nativeSets;
nativeBounds = { x: -20, y: -40, width: 300, height: 500 };
hooks.get('move')();
hooks.get('will-resize')(resizeEvent, { x: 10, y: -80, width: 5000, height: 4000 });
assert.equal(nativeSets, lastSets, 'automatic roaming/docking and fixed close-up canvas own their geometry');
assert.equal(prevented, 1);

console.log('pet window bounds QA passed');
