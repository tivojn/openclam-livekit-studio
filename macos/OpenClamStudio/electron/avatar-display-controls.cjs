'use strict';

const DISPLAY_ZOOM_DEFAULT = 0.6;
const DISPLAY_ZOOM_KEYS = Object.freeze([
  'desktopStandby', 'desktopCloseUp', 'chatStandby', 'chatCloseUp',
]);

function displayZoomKey(chat, closeUp) {
  return `${chat ? 'chat' : 'desktop'}${closeUp ? 'CloseUp' : 'Standby'}`;
}

function normalizeDisplayZooms(saved, legacyZoom = DISPLAY_ZOOM_DEFAULT) {
  const bounded = (value, fallback) => {
    const n = Number(value);
    return Number.isFinite(n) && n > 0 ? Math.max(.25, Math.min(4, n)) : fallback;
  };
  const standby = bounded(legacyZoom, DISPLAY_ZOOM_DEFAULT);
  return Object.fromEntries(DISPLAY_ZOOM_KEYS.map(key => [key,
    bounded(saved && saved[key], key.endsWith('Standby') ? standby : DISPLAY_ZOOM_DEFAULT)]));
}

// Native roles act on the focused editable field, never an app-owned copy of
// its text or the clipboard. Read-only selections do not get destructive rows.
function nativeEditMenuTemplate(params) {
  if (!params || !params.isEditable) return null;
  const flags = params.editFlags || {};
  return [
    { role: 'undo', enabled: Boolean(flags.canUndo) },
    { role: 'redo', enabled: Boolean(flags.canRedo) },
    { type: 'separator' },
    { role: 'cut', enabled: Boolean(flags.canCut) },
    { role: 'copy', enabled: Boolean(flags.canCopy) },
    { role: 'paste', enabled: Boolean(flags.canPaste) },
    { role: 'pasteAndMatchStyle', enabled: Boolean(flags.canPaste) },
    { type: 'separator' },
    { role: 'selectAll', enabled: Boolean(flags.canSelectAll) },
  ];
}

module.exports = { DISPLAY_ZOOM_DEFAULT, displayZoomKey, normalizeDisplayZooms, nativeEditMenuTemplate };
