'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('performer',Object.freeze({
 send:value=>ipcRenderer.send('openclam:performer-data',value),
 command:value=>ipcRenderer.send('openclam:performer-command',value),
 onData:callback=>{const fn=(_e,value)=>callback(value);ipcRenderer.on('openclam:performer-data',fn);return()=>ipcRenderer.removeListener('openclam:performer-data',fn);},
}));
