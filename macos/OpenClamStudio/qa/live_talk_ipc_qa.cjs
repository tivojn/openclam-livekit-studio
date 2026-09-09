'use strict';
// Run with Electron; no microphone, network service, credential or agent needed.
const {app,BrowserWindow,ipcMain}=require('electron');
const assert=require('node:assert/strict');
const path=require('node:path');
const {LiveTalkOwner}=require('../electron/live-talk-owner.cjs');
const windows=[];
const owner=new LiveTalkOwner(()=>windows,(w,c,v)=>w.webContents.send(c,v));
ipcMain.handle('openclam:live-claim',e=>owner.claim(e.sender));
ipcMain.handle('openclam:live-state',e=>owner.snapshot(e.sender));
ipcMain.on('openclam:live-active',(e,v)=>owner.setPhase(e.sender,v));
ipcMain.on('openclam:live-end',e=>owner.end(e.sender));
ipcMain.on('openclam:live-frame',(e,v)=>owner.shareFrame(e.sender,v));
const run=(w,code)=>w.webContents.executeJavaScript(code);
(async()=>{
 await app.whenReady();
 for(let i=0;i<2;i++){
   const w=new BrowserWindow({show:false,webPreferences:{preload:path.resolve(__dirname,'../electron/preload.cjs'),contextIsolation:true,sandbox:true,backgroundThrottling:false}});
   windows.push(w);await w.loadURL('data:text/html,<title>Live Talk IPC QA</title>');
   await run(w,"window.events=[];window.stops=0;openclam.onLiveTalkState(v=>events.push(v));openclam.onLiveStop(()=>stops++);void 0;");
 }
 const [chat,avatar]=windows;
 const claims=await Promise.all(windows.map(w=>run(w,'openclam.claimLiveTalk()')));
 assert.equal(claims.filter(Boolean).length,1);
 const first=windows[claims.indexOf(true)],peer=windows[claims.indexOf(false)];
 await run(first,"openclam.setLiveTalk('connected');openclam.shareLiveTalkFrame({visual:{viseme:'aa',speaking:true},action:{key:'route:1',action:'run-around'},motion:{id:'joyful-sway',key:'dance:1',elapsed:1000}})");
 const peerState=await run(peer,'openclam.getLiveTalkState()');
 assert.equal(peerState.phase,'connected');assert.equal(peerState.owned,false);assert.equal(peerState.frame.motion.id,'joyful-sway');
 assert.deepEqual(peerState.frame.action,{key:'route:1',action:'run-around'},'the visible mode receives the owner’s spatial intention');
 first.hide();
 assert.equal(await run(peer,'openclam.claimLiveTalk()'),false,'hidden owner retains the one media session');
 await run(peer,'openclam.endSharedLiveTalk();openclam.endSharedLiveTalk()');
 assert.equal((await run(peer,'openclam.getLiveTalkState()')).phase,'ending');
 assert.equal(await run(first,'stops'),1,'remote hang-up is explicit and idempotent');
 assert.equal(await run(peer,'openclam.claimLiveTalk()'),false);
 await run(first,'openclam.setLiveTalk(false)');
 assert.equal(await run(peer,'openclam.claimLiveTalk()'),true,'lease transfers only after media teardown');
 await run(peer,"openclam.setLiveTalk('connected')");
 await run(first,'openclam.endSharedLiveTalk()');
 assert.equal((await run(first,'openclam.getLiveTalkState()')).phase,'ending');
 assert.equal(await run(peer,'stops'),1);
 await run(peer,'openclam.setLiveTalk(false)');
 assert.equal((await run(first,'openclam.getLiveTalkState()')).phase,'idle');
 for(const w of windows)w.destroy();
 console.log('Real Electron IPC/preload passed: simultaneous acquisition, hidden owner, mirrored animation, hang-up in both views and one-session lease transfer.');
 app.quit();
})().catch(error=>{console.error(error);app.exit(1)});
