import '/avatar3d.js';
let avatar, latest, loading, reported = false, failed = false;
const originalError = console.error;
const generation = Number(new URLSearchParams(location.search).get('generation'));
const report = body => window.webkit.messageHandlers.avatarStatus.postMessage({...body,generation});
console.error = (...items) => { originalError(...items); report({error:items.map(String).join(' ')}); };
window.showAvatarError = message => {
  failed = true;
  let status = document.querySelector('#status');
  if (!status) { status = document.createElement('div'); status.id = 'status'; document.body.append(status); }
  status.textContent = message;
};
const fail = error => {
  const message = String(error?.message || error);
  window.showAvatarError(message);
  report({error:message});
};
window.addEventListener('error', event => fail(event.error || event.message));
window.addEventListener('unhandledrejection', event => fail(event.reason));
window.updateAvatar = frame => {
  latest = frame;
  if (!loading && !failed) loading = load(frame).catch(fail);
};
async function load(frame) {
  avatar = window.OpenClamAvatar3D.create(frame.frame);
  avatar.canvas.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    window.showAvatarError('Restarting 3D avatar…');
    report({event:'renderer-lost'});
  });
  await avatar.load('/model.gltf');
  if (failed) return;
  const releasedImages = await uploadAvatarTextures(avatar, () => failed);
  report({event:'textures-uploaded', releasedImages});
  if (failed) return;
  report({event:'catalogue', catalogue:avatar.options?.catalogue() || {poses:[],outfits:[],props:[]}});
  document.body.append(avatar.canvas);
  requestAnimationFrame(draw);
}
// Upload every wardrobe texture before the first frame allocates morph buffers.
// ImageBitmaps otherwise retain a second decoded copy of all 51 Tia images.
// Include hidden outfits and all textures sharing a bitmap before closing it.
// A lost WebGL context reloads the page/model instead of reusing closed bitmaps.
export async function uploadAvatarTextures(avatar, stopped = () => false) {
  const images = new Map();
  avatar.model.traverse(node => {
    for (const material of Array.isArray(node.material) ? node.material : [node.material]) {
      for (const texture of Object.values(material || {})) {
        if (!texture?.isTexture || typeof texture.image?.close !== 'function') continue;
        if (!images.has(texture.image)) images.set(texture.image, new Set());
        images.get(texture.image).add(texture);
      }
    }
  });
  for (const [image, textures] of images) {
    if (stopped()) return;
    for (const texture of textures) avatar.renderer.initTexture(texture);
    image.close();
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  return images.size;
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
  if (failed) return;
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
  const viewport = fitAvatarViewport(latest.crop, surface.width, surface.height, density);
  const lookTarget = latest.pointer ? avatar.gazePoint({
    x:viewport.x + latest.pointer.x * viewport.w,
    y:viewport.y + latest.pointer.y * viewport.h,
  }) : null;
  avatar.render(now, {...state,lookTarget}, viewport);
  if (!reported) {reported=true;document.querySelector('#status').remove();report({event:'rendered'});}
}
report({event:'page-ready'});
