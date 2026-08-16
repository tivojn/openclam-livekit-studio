'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const bubbleApi = Object.freeze({
  onText: (callback) => {
    if (typeof callback !== 'function') return () => {};
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on('openclam:bubble-text', listener);
    return () => ipcRenderer.removeListener('openclam:bubble-text', listener);
  },
  hold: (value) => ipcRenderer.send('openclam:bubble-hold', Boolean(value)),
});

contextBridge.exposeInMainWorld('openclamBubble', bubbleApi);
