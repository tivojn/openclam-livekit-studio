'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const listeners = new Map();

function subscribe(channel, callback) {
  if (typeof callback !== 'function') return () => {};
  const wrapped = (_event, value) => callback(value);
  let channelListeners = listeners.get(channel);
  if (!channelListeners) {
    channelListeners = new Map();
    listeners.set(channel, channelListeners);
  }
  channelListeners.set(callback, wrapped);
  ipcRenderer.on(channel, wrapped);
  return () => {
    const active = channelListeners.get(callback);
    if (active) ipcRenderer.removeListener(channel, active);
    channelListeners.delete(callback);
    if (channelListeners.size === 0) listeners.delete(channel);
  };
}

let liveTalkLease = null;
const api = Object.freeze({
  isElectron: true,
  getPresentation: () => ipcRenderer.invoke('openclam:get-presentation'),
  onPresentation: callback => subscribe('openclam:presentation',callback),
  relayAvatarEvent: value => ipcRenderer.invoke('openclam:avatar-event',value),
  onAvatarEvent: callback => subscribe('openclam:avatar-event',callback),
  getState: () => ipcRenderer.invoke('openclam:get-state'),
  copySettingsText: (value) => ipcRenderer.invoke(
    'openclam:copy-settings-text', String(value || '')),
  openSettings: () => ipcRenderer.invoke('openclam:open-settings'),
  openTasks: () => ipcRenderer.invoke('openclam:open-tasks'),
  openAppearance: () => ipcRenderer.invoke('openclam:open-appearance'),
  showAvatar: () => ipcRenderer.invoke('openclam:show-main'),
  showChat: () => ipcRenderer.invoke('openclam:show-chat'),
  hideAvatar: () => ipcRenderer.invoke('openclam:hide-main'),
  minimize: () => ipcRenderer.invoke('openclam:minimize'),
  toggleAlwaysOnTop: () => ipcRenderer.invoke('openclam:toggle-top'),
  showPetMenu: () => ipcRenderer.invoke('openclam:pet-menu'),
  setPetView: (value) => ipcRenderer.invoke('openclam:set-pet-view', String(value || '')),
  setPetOpacity: (value) => ipcRenderer.invoke('openclam:set-pet-opacity', Number(value)),
  setPetZoom: (value) => ipcRenderer.invoke('openclam:set-pet-zoom', Number(value)),
  setPetRoamZoom: (value) => ipcRenderer.invoke('openclam:set-pet-roam-zoom', Number(value)),
  setPetZoomLive: (payload) => ipcRenderer.send('openclam:pet-zoom-live', payload),
  setPetLock: (value) => ipcRenderer.invoke('openclam:set-pet-lock', Boolean(value)),
  setPetRoam: (value) => ipcRenderer.invoke('openclam:set-pet-roam', Boolean(value)),
  setDisplayMode: (value) => ipcRenderer.invoke(
    'openclam:set-display-mode', String(value || '')),
  setPetMotionReady: (value) => ipcRenderer.send('openclam:pet-motion-ready', value),
  showSpeechBubble: (value) => ipcRenderer.send('openclam:show-speech-bubble', String(value || '')),
  setCompanionState: value => ipcRenderer.send('openclam:companion-state',value),
  setCompanionAnchor: value => ipcRenderer.send('openclam:companion-anchor',value),
  onCompanionCommand: callback => subscribe('openclam:companion-command',callback),
  dockPet: () => ipcRenderer.send('openclam:pet-dock'),
  undockPet: () => ipcRenderer.send('openclam:pet-undock'),
  exportAvatar: (payload) => ipcRenderer.invoke('openclam:export-avatar', payload),
  avatarStoreCatalog: (options) => ipcRenderer.invoke('openclam:avatar-store-catalog', options),
  avatarStoreThumbnail: (id) => ipcRenderer.invoke('openclam:avatar-store-thumbnail', String(id || '')),
  downloadAvatarStoreItem: (id) => ipcRenderer.invoke('openclam:avatar-store-download', String(id || '')),
  cancelAvatarStoreItem: (id) => ipcRenderer.invoke('openclam:avatar-store-cancel', String(id || '')),
  setPetEngaged: (value) => ipcRenderer.send('openclam:pet-engaged', Boolean(value)),
  setPetHit: (value) => ipcRenderer.send('openclam:pet-hit', Boolean(value)),
  setPetControlRects: (rects) => ipcRenderer.send('openclam:pet-control-rects', rects),
  focusPetWindow: () => ipcRenderer.send('openclam:pet-focus'),
  setChatMode: (value) => ipcRenderer.invoke('openclam:set-chat-mode', Boolean(value)),
  beginPetDrag: (point) => ipcRenderer.send('openclam:drag-start', point),
  movePetDrag: (point) => ipcRenderer.send('openclam:drag-move', point),
  endPetDrag: () => ipcRenderer.send('openclam:drag-end'),
  moveCompanion: (step) => ipcRenderer.send('openclam:companion-step', step),
  avatarChanged: () => ipcRenderer.invoke('openclam:avatar-changed'),
  companionChanged: () => ipcRenderer.invoke('openclam:companion-changed'),
  restartBackend: () => ipcRenderer.invoke('openclam:restart-backend'),
  openMotionAsset: (asset) => ipcRenderer.invoke('openclam:open-motion-asset', asset),
  saveMotionAsset: (asset) => ipcRenderer.invoke('openclam:save-motion-asset', asset),
  onState: (callback) => subscribe('openclam:state', callback),
  onPetChat: (callback) => subscribe('openclam:pet-chat', callback),
  onPetPointer: (callback) => subscribe('openclam:pet-pointer', callback),
  onPetRoamMotion: (callback) => subscribe('openclam:pet-roam-motion', callback),
  onPetMoves: (callback) => subscribe('openclam:pet-moves', callback),
  onAvatarOptionsRequest: (callback) => subscribe('openclam:avatar-options-request', callback),
  onDisplayModeRequest: (callback) => subscribe('openclam:display-mode-request', callback),
  onLiveToggle: (callback) => subscribe('openclam:live-toggle', callback),
  onAvatarStoreProgress: (callback) => subscribe('openclam:avatar-store-progress', callback),
  claimLiveTalk: async () => {
    const lease = await ipcRenderer.invoke('openclam:live-claim');
    if (lease) liveTalkLease = lease;
    return Boolean(lease);
  },
  onLiveStop: callback => subscribe('openclam:live-stop', callback),
  endSharedLiveTalk: () => ipcRenderer.send('openclam:live-end'),
  getLiveTalkState: () => ipcRenderer.invoke('openclam:live-state'),
  onLiveTalkState: callback => subscribe('openclam:live-state',callback),
  onLiveTalkFrame: callback => subscribe('openclam:live-frame',callback),
  shareLiveTalkFrame: frame => ipcRenderer.send('openclam:live-frame',{lease:liveTalkLease,frame}),
  setLiveTalk: value => ipcRenderer.send('openclam:live-active',{lease:liveTalkLease,value}),
});

// The product bridge exposes app-local controls only: no device discovery,
// pairing, system-audio capture, credential reads, or clipboard reads.
contextBridge.exposeInMainWorld('openclam', api);
