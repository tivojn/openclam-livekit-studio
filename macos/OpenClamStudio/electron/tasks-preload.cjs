'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('openclamTasks',Object.freeze({
  chooseFolder:()=>ipcRenderer.invoke('openclam:tasks-folder'),
  showChat:()=>ipcRenderer.invoke('openclam:tasks-chat'),
  openLink:url=>ipcRenderer.invoke('openclam:tasks-link',url),
}));
