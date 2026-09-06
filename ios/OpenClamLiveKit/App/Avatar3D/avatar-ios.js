import '/avatar3d.js';
let avatar, latest, loading, reported = false;
const originalError = console.error;
console.error = (...items) => { originalError(...items); window.webkit.messageHandlers.avatarStatus.postMessage({error:items.map(String).join(' ')}); };
const report = body => window.webkit.messageHandlers.avatarStatus.postMessage(body);
window.updateAvatar = frame => {
  latest = frame;
  if (!loading) loading = load(frame).catch(error => {
    document.querySelector('#status').textContent = '3D avatar: '+String(error.message || error);
    report({error:String(error.message || error)});
  });
};
async function load(frame) {
  avatar = window.OpenClamAvatar3D.create(frame.frame);
  await avatar.load('/model.glb');
  report({event:'catalogue', catalogue:avatar.options?.catalogue() || {poses:[],outfits:[],props:[]}});
  document.body.append(avatar.canvas);
  requestAnimationFrame(draw);
}
let previous = 0;
// The camera crop and displayed CSS canvas must have the same aspect ratio.
// Read the actual surface, including keyboard/safe-area layout changes, and
// expand the crop uniformly if native layout and WebKit update out of step.
export function fitAvatarViewport(crop, width, height, density = 1) {
  const scale = Math.min(width / crop.w, height / crop.h);
  const w = width / scale, h = height / scale;
  return {x:crop.x + (crop.w-w)/2, y:crop.y + (crop.h-h)/2, w, h,
    pixelWidth:Math.max(8,Math.round(width*density)),
    pixelHeight:Math.max(8,Math.round(height*density))};
}
function draw(now) {
  requestAnimationFrame(draw);
  if (!latest || document.hidden) return;
  const state = latest.state, interval = state.reduce ? 250 : state.speaking ? 16 : 33;
  if (now - previous < interval) return;
  previous = now;
  avatar.options?.select(latest.options || {}, now);
  avatar.setOrbit(latest.orbit);
  const surface = avatar.canvas.getBoundingClientRect();
  if (!(surface.width > 0 && surface.height > 0)) return;
  const density = Math.min(window.devicePixelRatio || 1, 2048 / Math.max(surface.width,surface.height));
  avatar.render(now, state, fitAvatarViewport(latest.crop, surface.width, surface.height, density));
  if (!reported) {reported=true;document.querySelector('#status').remove();report({event:'rendered'});}
}
report({event:'page-ready'});
