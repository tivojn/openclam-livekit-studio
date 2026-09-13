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
  onState: callback => {
    if(typeof callback!=='function')return ()=>{};
    const listener=(_event,payload)=>callback(payload);
    ipcRenderer.on('openclam:companion-state',listener);
    return ()=>ipcRenderer.removeListener('openclam:companion-state',listener);
  },
  action: value => ipcRenderer.invoke('openclam:bubble-action',value),
  resize: height => ipcRenderer.send('openclam:bubble-size',height),
});

contextBridge.exposeInMainWorld('openclamBubble', bubbleApi);
