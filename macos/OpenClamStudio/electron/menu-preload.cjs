'use strict';
const { contextBridge, ipcRenderer } = require('electron');

const menuApi = Object.freeze({
  onSpec: (callback) => ipcRenderer.on('openclam:menu-spec', (_event, value) => callback(value)),
  size: (value) => ipcRenderer.send('openclam:menu-size', value),
  action: (id) => ipcRenderer.send('openclam:menu-action', String(id || '')),
  close: () => ipcRenderer.send('openclam:menu-close'),
});

contextBridge.exposeInMainWorld('openclamMenu', menuApi);
