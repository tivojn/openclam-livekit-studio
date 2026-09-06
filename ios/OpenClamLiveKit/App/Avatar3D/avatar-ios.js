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
  document.body.append(avatar.canvas);
  requestAnimationFrame(draw);
}
let previous = 0;
function draw(now) {
  requestAnimationFrame(draw);
  if (!latest || document.hidden) return;
  const state = latest.state, interval = state.reduce ? 250 : state.speaking ? 16 : 33;
  if (now - previous < interval) return;
  previous = now;
  avatar.setOrbit(latest.orbit);
  const density = Math.min(window.devicePixelRatio || 1, 2048 / Math.max(innerWidth,innerHeight,1));
  avatar.render(now, state, {...latest.crop,
    pixelWidth:Math.max(8,Math.round(innerWidth*density)),
    pixelHeight:Math.max(8,Math.round(innerHeight*density))});
  if (!reported) {reported=true;document.querySelector('#status').remove();report({event:'rendered'});}
}
report({event:'page-ready'});
