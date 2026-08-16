'use strict';

const assert = require('node:assert/strict');
const { effectivePetAlwaysOnTop } = require('../electron/pet-window-level.cjs');

// Standing pets follow the user's preference; walking pets float even when
// the preference is off.
assert.equal(effectivePetAlwaysOnTop(), false);
assert.equal(effectivePetAlwaysOnTop({ userAlwaysOnTop: true }), true);
assert.equal(effectivePetAlwaysOnTop({ roaming: true }), true);

// A visible Settings window wins over both sources of floating-window state.
// Closing or hiding Settings restores the exact prior semantics.
for (const userAlwaysOnTop of [false, true]) {
  for (const roaming of [false, true]) {
    assert.equal(effectivePetAlwaysOnTop({
      settingsVisible: true,
      userAlwaysOnTop,
      roaming,
    }), false);
    assert.equal(effectivePetAlwaysOnTop({
      settingsVisible: false,
      userAlwaysOnTop,
      roaming,
    }), userAlwaysOnTop || roaming);
  }
}

console.log('pet window level QA passed');
