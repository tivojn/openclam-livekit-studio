'use strict';

function clampPetZoom(zoom, range) {
  const value = Number(zoom);
  const safe = Number.isFinite(value) && value > 0 ? value : 1;
  const minimum = Number(range && range.min);
  const maximum = Number(range && range.max);
  if (!Number.isFinite(minimum) || !Number.isFinite(maximum)) return safe;
  return Math.max(minimum, Math.min(maximum, safe));
}

function petZoomSize(baseSize, minimumSize, zoom) {
  return {
    width: Math.max(minimumSize.width, Math.round(baseSize.width * zoom)),
    height: Math.max(minimumSize.height, Math.round(baseSize.height * zoom)),
  };
}

function boundsForPetZoom(current, baseSize, minimumSize, zoom) {
  const { width, height } = petZoomSize(baseSize, minimumSize, zoom);
  return {
    x: Math.round(current.x + (current.width - width) / 2),
    y: Math.round(current.y + (current.height - height) / 2),
    width,
    height,
  };
}

function petZoomAnchor(current) {
  return {
    x: current.x + current.width / 2,
    y: current.y + current.height / 2,
  };
}

// Live pinches re-apply the zoom dozens of times a second. Measuring every step
// from one anchor captured at gesture start keeps the rounding error from
// compounding, so the window grows in place instead of crawling across the desk.
function boundsForPetZoomAtAnchor(anchor, baseSize, minimumSize, zoom) {
  const { width, height } = petZoomSize(baseSize, minimumSize, zoom);
  return {
    x: Math.round(anchor.x - width / 2),
    y: Math.round(anchor.y - height / 2),
    width,
    height,
  };
}

function roamSizeForZoom(baseSize, minimumSize, zoom) {
  return petZoomSize(baseSize, minimumSize, zoom);
}

// A runaway pinch can leave the window larger than the screen, and the saved
// zoom then restores the same unreachable size on the next launch. Shrink the
// zoom until the window fits inside the work area (minus the margin) so the
// companion always comes back somewhere the pointer can reach it.
function fitPetZoomToArea(baseSize, minimumSize, zoom, area, margin = 0) {
  const value = Number(zoom);
  const safe = Number.isFinite(value) && value > 0 ? value : 1;
  const availableWidth = Math.max(minimumSize.width, area.width - margin * 2);
  const availableHeight = Math.max(minimumSize.height, area.height - margin * 2);
  const limit = Math.min(
    availableWidth / baseSize.width, availableHeight / baseSize.height);
  if (!Number.isFinite(limit) || limit <= 0) return safe;
  return Math.min(safe, limit);
}

// Bottom corner of the work area, which macOS already trims to exclude the
// Dock and the menu bar — the avatar lands above the Dock, not under it. The
// active avatar owns the right corner; a second on-desk avatar mirrors to
// the left one.
function dockedPetBounds(size, area, margin = 0, side = 'right') {
  return {
    x: Math.round(side === 'left'
      ? area.x + margin
      : area.x + area.width - size.width - margin),
    y: Math.round(area.y + area.height - size.height - margin),
    width: size.width,
    height: size.height,
  };
}

// Keep the native transparent canvas GPU/screen sized. The renderer retains
// the requested zoom and applies any excess inside this bounded canvas, with
// its anatomical crown/chin guard. This does not overwrite a saved zoom.
function fitPetWindowToArea(bounds, area) {
  const finite = (value, fallback) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const left = finite(area && area.x, 0), top = finite(area && area.y, 0);
  const availableWidth = Math.max(1, finite(area && area.width, 1));
  const availableHeight = Math.max(1, finite(area && area.height, 1));
  const wantedWidth = Math.max(1, finite(bounds && bounds.width, availableWidth));
  const wantedHeight = Math.max(1, finite(bounds && bounds.height, availableHeight));
  const factor = Math.min(1, availableWidth / wantedWidth, availableHeight / wantedHeight);
  const width = Math.max(1, Math.min(availableWidth, Math.round(wantedWidth * factor)));
  const height = Math.max(1, Math.min(availableHeight, Math.round(wantedHeight * factor)));
  return {
    x: Math.round(Math.max(left, Math.min(left + availableWidth - width,
      finite(bounds && bounds.x, left)))),
    y: Math.round(Math.max(top, Math.min(top + availableHeight - height,
      finite(bounds && bounds.y, top)))),
    width, height,
  };
}

module.exports = {
  boundsForPetZoom,
  boundsForPetZoomAtAnchor,
  clampPetZoom,
  dockedPetBounds,
  fitPetZoomToArea,
  fitPetWindowToArea,
  petZoomAnchor,
  petZoomSize,
  roamSizeForZoom,
};
