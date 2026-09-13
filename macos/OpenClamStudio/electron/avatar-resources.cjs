'use strict';

// Native visibility remains reliable when the audio-owning page deliberately
// disables Chromium background throttling. Visibility is independent of focus:
// an unfocused desktop companion must still animate.
const isPresented = window => Boolean(window && !window.isDestroyed()
  && window.isVisible() && !window.isMinimized());

function watchPresentation(window, post) {
  const publish = () => post(window, 'openclam:presentation', {visible:isPresented(window)});
  for (const event of ['show','hide','minimize','restore']) window.on(event, publish);
  window.webContents.on('did-finish-load', publish);
}

// Forward conversation decisions, never generated replies, to the visible
// scene. The hidden page can keep its microphone while releasing every mesh.
function relayAvatarEvent(windows, sender, value, post) {
  const peers=windows.filter(w=>w&&!w.isDestroyed());
  if(!peers.some(w=>w.webContents===sender))return false;
  if(!value||!['reaction','action'].includes(value.kind))return false;
  try {if(JSON.stringify(value).length>24000)return false;}catch{return false;}
  const target=peers.find(w=>w.webContents!==sender&&isPresented(w));
  if(!target)return false;
  post(target,'openclam:avatar-event',value);
  return true;
}

module.exports={isPresented,watchPresentation,relayAvatarEvent};
