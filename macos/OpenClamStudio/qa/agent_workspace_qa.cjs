'use strict';
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {TaskWindow}=require('../electron/tasks.cjs');
const handlers=new Map();const opened=[];const windows=[];
class Window extends EventEmitter{
  constructor(options){super();windows.push(this);this.options=options;this.webContents=new EventEmitter();this.webContents.mainFrame={url:'http://127.0.0.1:9999/tasks'};this.webContents.setWindowOpenHandler=handler=>{this.openHandler=handler;};}
  isDestroyed(){return false;}show(){}focus(){}loadURL(url){this.url=url;}
}
(async()=>{
 const tasks=new TaskWindow({BrowserWindow:Window,ipcMain:{handle:(name,fn)=>handlers.set(name,fn)},
 dialog:{showOpenDialog:async()=>({canceled:false,filePaths:['/chosen/project']})},shell:{openExternal:url=>opened.push(url)},
 path:require('node:path'),baseUrl:()=> 'http://127.0.0.1:9999',showChat:()=>{}});
 tasks.open();const w=tasks.window;const owner={sender:w.webContents,senderFrame:w.webContents.mainFrame};
 assert.equal(w.options.webPreferences.nodeIntegration,false);assert.equal(w.options.webPreferences.sandbox,true);
 assert.equal(await handlers.get('openclam:tasks-folder')(owner),'/chosen/project');
 assert.equal(await handlers.get('openclam:tasks-folder')({...owner,senderFrame:{url:owner.senderFrame.url}}),null);
 assert.equal(await handlers.get('openclam:tasks-folder')({sender:{mainFrame:{}},senderFrame:{}}),null);
 handlers.get('openclam:tasks-link')(owner,'file:///etc/passwd');
 handlers.get('openclam:tasks-link')(owner,'javascript:alert(1)');
 assert.equal(opened.length,0);
 handlers.get('openclam:tasks-link')(owner,'https://developers.openai.com/codex');assert.equal(opened.length,1);
 handlers.get('openclam:tasks-link')(owner,'http://127.0.0.1:4000');
 assert.equal(windows.length,2);assert.match(windows[1].options.webPreferences.partition,/^openclam-preview-/);
 assert.equal(windows[1].options.webPreferences.preload,undefined);
 handlers.get('openclam:tasks-link')(owner,'http://untrusted.example:4000');assert.equal(windows.length,2);
 owner.senderFrame.url='http://127.0.0.1:9999/tasks-untrusted';
 assert.equal(await handlers.get('openclam:tasks-folder')(owner),null);
 console.log('Agent workspace ownership and native boundary QA passed');
})();
