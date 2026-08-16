'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const appearanceApi = Object.freeze({
  getState: () => ipcRenderer.invoke('openclam:get-state'),
  setSize: (value) => ipcRenderer.invoke('openclam:set-pet-zoom', Number(value)),
  setOpacity: (value) => ipcRenderer.invoke('openclam:set-pet-opacity', Number(value)),
  setMotionSize: (value) => ipcRenderer.invoke('openclam:set-pet-roam-zoom', Number(value)),
  onState: (callback) => {
    if (typeof callback !== 'function') return () => {};
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on('openclam:state', listener);
    return () => ipcRenderer.removeListener('openclam:state', listener);
  },
});

contextBridge.exposeInMainWorld('openclamAppearance', appearanceApi);
