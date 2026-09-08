import '/avatar3d.js';
import {Avatar3DMotion} from '/avatar3d-motion.js';
import {CompanionController, avatarIntent, motionIntent} from '/avatar3d-companion.js';
let avatar, latest, loading, reported = false, failed = false;
let companion, lastConversation = '', actionGeneration = 0, lastMotion = '';
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
  const catalogue = avatar.options?.catalogue() || {poses:[],outfits:[],props:[]};
  if (avatar.options) {
    const motion = await new Avatar3DMotion(avatar.options, {cacheLimit:2}).load('/motions/library.json');
    if (motion.clips.size) {
      avatar.motion = motion;
      companion = new CompanionController();
      catalogue.motions = [...motion.clips.values()].map(({id,label,category}) => ({id,label,category}));
    }
  }
  report({event:'catalogue', catalogue});
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
const motionStatus = text => report({event:'motion-status', text});
const preference = (key,value) => {
  latest.options = {...latest.options, [key]:String(value)};
  report({event:'preference',key,value});
};
window.avatarCommand = async (value, isText = false) => {
  if (!companion || !reported || failed) return null;
  const action = isText ? avatarIntent(value) || motionIntent(value,avatar.motion.clips) : value;
  if (!action) return null;
  ++actionGeneration;
  if (action === 'reactions-on' || action === 'reactions-off') {
    companion.reactions = action === 'reactions-on'; companion.pendingReaction = null;
    preference('dynamicMotions',companion.reactions);
    return companion.reactions ? 'Dynamic motions are on.' : 'Dynamic motions are off.';
  }
  companion.command(action); avatar.motion.stop();
  if (action === 'stay') {
    preference('dynamicMotions',false); preference('playTransitions',false);
    motionStatus('Stopped'); return 'I’ll stay here.';
  }
  if (latest.state.reduce) return 'Turn off Reduce Motion in Accessibility to play body motions.';
  if (action === 'follow' || action === 'come') {
    preference('followCursor',true);
    return 'I’ll look toward your touch or pointer. Pinch to resize, or use two fingers to move me.';
  }
  report({event:'motion-framing'});
  const pose = {heart:'Ps001.heart',sit:'Ps004.sit',stand:''}[action];
  if (pose !== undefined) {
    preference('playTransitions',false);
    report({event:'pose',id:pose});
    motionStatus(action === 'heart' ? 'Heart pose' : action === 'sit' ? 'Seated' : 'Standing');
    return action === 'heart' ? 'A heart for you. ♥' : action === 'sit' ? 'Taking a seat.' : 'Standing up.';
  }
  let id = action.startsWith('clip:') ? action.slice(5) : action === 'dance' ? 'joyful-sway' : action;
  if (action === 'random-dance' || action === 'random-motion') {
    const choices = [...avatar.motion.clips.values()].filter(c =>
      (action !== 'random-dance' || c.category === 'Dances') && !(latest.options.prop && c.requiresFreeHands));
    const fresh = choices.filter(c => c.id !== lastMotion), pool = fresh.length ? fresh : choices;
    id = pool[Math.floor(Math.random()*pool.length)]?.id;
  }
  if (!avatar.motion.clips.has(id)) return null;
  const generation = actionGeneration;
  motionStatus('Loading motion…');
  try {
    const played = await avatar.motion.play(id,{loop:false});
    if (generation !== actionGeneration || !played) return 'Motion cancelled.';
    lastMotion = id;
    motionStatus('Playing: ' + avatar.motion.clips.get(id).label);
    return 'Here’s ' + avatar.motion.clips.get(id).label + '.';
  } catch (_) { motionStatus('Could not load motion. Try again.'); return 'I couldn’t load that motion. Please try again.'; }
};
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { ++actionGeneration; avatar?.motion?.stop(); if(companion)companion.pendingReaction=null; }
});
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
  if (companion) {
    companion.reactions = latest.options?.dynamicMotions !== 'false';
    const turn = latest.conversation;
    if (turn?.id && turn.id !== lastConversation) {
      lastConversation = turn.id;
      if (Date.now()-Number(turn.created)<15000 && !motionIntent(turn.user,avatar.motion.clips))
        companion.consider(turn.user,turn.reply,turn.suggestion,now);
    }
    const reaction = companion.takeReaction(now,avatar.motion.clips,
      state.reduce || Boolean(avatar.motion.active || avatar.motion.pending), {hasProp:Boolean(latest.options?.prop)});
    if (reaction) {
      const generation = actionGeneration;
      void avatar.motion.play(reaction,{loop:false}).then(played => {
        if (played && generation === actionGeneration) motionStatus('Playing: ' + avatar.motion.clips.get(reaction).label);
      }).catch(() => motionStatus('Could not load motion. Try again.'));
    }
  }
  avatar.setOrbit(latest.orbit);
  const surface = avatar.canvas.getBoundingClientRect();
  if (!(surface.width > 0 && surface.height > 0)) return;
  const density = Math.min(window.devicePixelRatio || 1, 2048 / Math.max(surface.width,surface.height));
  const viewport = fitAvatarViewport(latest.crop, surface.width, surface.height, density);
  const lookTarget = latest.pointer ? avatar.gazePoint({
    x:viewport.x + latest.pointer.x * viewport.w,
    y:viewport.y + latest.pointer.y * viewport.h,
  }) : null;
  const expression = {...state.expression}, mood = avatar.motion?.expression(now,state.reduce) || {};
  for (const key of Object.keys(mood)) expression[key] = Math.max(expression[key] || 0,mood[key]);
  avatar.render(now, {...state,expression,lookTarget}, viewport);
  if (!reported) {reported=true;document.querySelector('#status').remove();report({event:'rendered'});}
}
report({event:'page-ready'});
