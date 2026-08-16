'use strict';

// Pet windows normally follow the user's always-on-top choice, while a
// walking pet must float above ordinary apps. Settings is the one local
// exception: it stays a normal macOS window, and the pets temporarily drop
// to the normal level so they cannot cover its controls.
function effectivePetAlwaysOnTop({
  settingsVisible = false,
  userAlwaysOnTop = false,
  roaming = false,
} = {}) {
  return !Boolean(settingsVisible)
    && (Boolean(userAlwaysOnTop) || Boolean(roaming));
}

module.exports = { effectivePetAlwaysOnTop };
