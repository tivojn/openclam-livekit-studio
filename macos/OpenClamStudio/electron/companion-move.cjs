'use strict';

// Only move within the current display's work area, at a bounded speed.
// The renderer requests a small step, never arbitrary desktop coordinates.
function companionStep(bounds, area, dx, dy, elapsedMs, remainder={x:0,y:0}) {
  if (![bounds.x,bounds.y,bounds.width,bounds.height,area.x,area.y,area.width,area.height,dx,dy,elapsedMs,remainder.x,remainder.y].every(Number.isFinite)
    || Math.min(bounds.width,bounds.height,area.width,area.height)<=0) return null;
  const limit=200*Math.min(100,Math.max(0,elapsedMs))/1000;
  const ratio=Math.min(1,limit/Math.max(Math.hypot(dx,dy),1e-9));
  const x=Math.max(area.x,Math.min(area.x+Math.max(0,area.width-bounds.width),bounds.x+dx*ratio+remainder.x));
  const y=Math.max(area.y,Math.min(area.y+Math.max(0,area.height-bounds.height),bounds.y+dy*ratio+remainder.y));
  // Electron positions are integer pixels. Carry subpixel travel forward so
  // slow vertical/diagonal movement does not stall before reaching the cursor.
  return {...bounds,x:Math.round(x),y:Math.round(y),remainder:{x:x-Math.round(x),y:y-Math.round(y)}};
}
module.exports={companionStep};
