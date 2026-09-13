'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {CompanionBubble,companionBubbleBounds}=require('../electron/companion-bubble.cjs');
const makeWindow=()=>({visible:true,destroyed:false,webContents:{send(channel,value){this.sent.push({channel,value});},sent:[],isLoadingMainFrame:()=>false},
 isDestroyed(){return this.destroyed;},isVisible(){return this.visible;},getContentBounds:()=>({x:100,y:200}),
 hide(){this.visible=false;},showInactive(){this.visible=true;},moveTop(){this.raised=true;},show(){this.visible=true;},focus(){this.focused=true;},setBounds(value){this.bounds=value;}});
const main=makeWindow(),chat=makeWindow(),bubble=makeWindow(),packets=[];
bubble.visible=false;
let chatMode=false,owner=null,created=0,opened=0,now=100000;
const originalNow=Date.now;Date.now=()=>now;
const card=new CompanionBubble({windows:()=>[main,chat],main:()=>main,bubble:()=>bubble,
 create:()=>{created++;return bubble;},chatMode:()=>chatMode,liveOwner:()=>owner,
 area:()=>({x:0,y:0,width:1440,height:900}),post:(w,c,p)=>packets.push(p),openChat:()=>opened++});
try {
 card.setAnchor(main.webContents,{x:500,y:350});
 card.update(main.webContents,{status:'Ready'});
 assert.equal(created,0,'idle never creates or shows a bubble');
 card.update(chat.webContents,{status:'Live Talk · connected',live:true});
 assert.equal(created,0,'an idle connected call is not work');
 card.update(chat.webContents,{title:'Tia',activity:'Reading files',busy:true,canStop:true});
 assert.equal(bubble.visible,true);assert.equal(packets.at(-1).activity,'Reading files');
 const count=packets.length;card.setAnchor(main.webContents,{x:600,y:400});
 assert.equal(packets.length,count,'moving updates bounds without resending content');
 assert.equal(bubble.bounds.x,520);assert.equal(bubble.bounds.y,438);
 card.action({action:'dismiss'});assert.equal(bubble.visible,false);
 card.update(chat.webContents,{activity:'Writing reply',busy:true});assert.equal(bubble.visible,false,'dismiss holds through the current work');
 card.update(chat.webContents,{message:{id:'1',role:'assistant',text:'Done.'}});
 assert.equal(bubble.visible,true,'a new message may show after dismiss');
 now+=14001;card.refresh();assert.equal(bubble.visible,false,'completed reply expires');
 card.update(chat.webContents,{message:{id:'2',role:'assistant',text:'Another reply'}});
 card.hold(true);now+=15000;card.refresh();assert.equal(bubble.visible,true,'reading holds expiry');
 chatMode=true;card.refresh();assert.equal(bubble.visible,false);assert.equal(card.held,false);
 chatMode=false;card.refresh();assert.equal(bubble.visible,false,'mode switch cannot resurrect stale hover');
 card.update(chat.webContents,{message:{id:'3',role:'assistant',text:'Follow up here'}});
 card.action({action:'expand'});assert.equal(bubble.focused,true);now+=15000;card.refresh();assert.equal(bubble.visible,true);
 assert.equal(card.action({action:'followup',text:'  Please wave.  '}),true);
 assert.deepEqual(chat.webContents.sent.at(-1),{channel:'openclam:companion-command',value:{action:'followup',text:'Please wave.'}});
 assert.equal(main.webContents.sent.length,0,'follow-up goes to the same conversation owner');
 assert.equal(card.action({action:'followup',text:'Please wave.'}),false,'double send rejected while dispatching');
 card.update(main.webContents,{activity:'Speaking…',live:true,canStop:true});owner=main.webContents;
 assert.equal(card.action({action:'stop'}),true);assert.equal(main.webContents.sent.at(-1).value.action,'stop');
 assert.equal(card.action({action:'followup',text:'hi'}),false,'live and typed turns cannot race');
 const stranger=makeWindow();card.update(stranger.webContents,{activity:'Fake work'});
 assert.equal(card.states.has(stranger.webContents),false);
 const oldAnchor=card.anchor;card.setAnchor(chat.webContents,{x:0,y:0});assert.equal(card.anchor,oldAnchor);
 card.action({action:'chat'});assert.equal(opened,1);
 owner=null;card.update(main.webContents,{});card.source=chat.webContents;card.update(chat.webContents,{});
 assert.equal(card.action({action:'followup',text:'x'.repeat(8001)}),false);
 card.setAnchor(main.webContents,null);assert.equal(bubble.visible,false);
 for(const area of [{x:0,y:25,width:1440,height:850},{x:-1280,y:-700,width:1280,height:720},{x:0,y:0,width:280,height:300}]) {
  for(const anchor of [{x:area.x,y:area.y},{x:area.x+area.width,y:area.y+area.height},{x:area.x+200,y:area.y+180}]) {
   const b=companionBubbleBounds(anchor,area,250);
   assert(b.x>=area.x+8&&b.y>=area.y+8);
   assert(b.x+b.width<=area.x+area.width-8&&b.y+b.height<=area.y+area.height-8);
  }
 }
} finally {card.dispose();Date.now=originalNow;}
// Execute the real renderer publisher: no idle bubble from a connected call,
// no permanent partial-transcript bubble, and no duplicate IPC on unchanged state.
const page=fs.readFileSync('web/index.html','utf8'),sent=[];
const scope={shell:{setCompanionState:v=>sent.push(v)},manifest:{avatar:{name:'Tia'}},root:{dataset:{theme:'light'}},
 statusText:{textContent:'Ready'},statusLine:{dataset:{tone:'good'}},live:null,sharedLivePhase:'idle',
 ptt:null,turnController:null,agentSpeaking:false,speechSource:null,liveStarting:false,performance:{now:()=>now}};
vm.createContext(scope);
vm.runInContext(page.slice(page.indexOf('    let companionMessage ='),page.indexOf('    const conversationLatestGap ='))+'\nglobalThis.publish=publishCompanionState;globalThis.status=setStatus;',scope);
scope.publish();assert.equal(sent.at(-1).activity,'');scope.publish();assert.equal(sent.length,1);
scope.live={};scope.status('Live Talk · connected','live');assert.equal(sent.at(-1).activity,'');
scope.status('Hearing “hello”','live');assert.match(sent.at(-1).activity,/Hearing/);
now+=4001;scope.publish();assert.equal(sent.at(-1).activity,'');
scope.ptt={};scope.publish();assert.equal(sent.at(-1).activity,'Listening…');
scope.ptt=null;scope.live=null;scope.status('OpenClaw mode','busy');assert.equal(sent.at(-1).activity,'');
scope.turnController={};scope.status('Reading files','busy');assert.equal(sent.at(-1).activity,'Reading files');
console.log('Companion bubble: idle, expiry, mode switching, owner routing, bounds, dismiss and renderer publication passed.');
