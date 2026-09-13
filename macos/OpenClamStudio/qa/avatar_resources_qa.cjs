const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {EventEmitter}=require('node:events');
const {isPresented,watchPresentation,relayAvatarEvent}=require('../electron/avatar-resources.cjs');
const win=()=>{const w=new EventEmitter();w.shown=false;w.minimized=false;w.webContents=new EventEmitter();w.isDestroyed=()=>false;w.isVisible=()=>w.shown;w.isMinimized=()=>w.minimized;return w;};
const chat=win(),avatar=win(),sent=[];
const post=(w,ch,value)=>sent.push({w,ch,value});
watchPresentation(chat,post);chat.webContents.emit('did-finish-load');assert.equal(sent.at(-1).value.visible,false);
chat.shown=true;chat.emit('show');assert.equal(sent.at(-1).value.visible,true);
chat.minimized=true;chat.emit('minimize');assert.equal(isPresented(chat),false);
chat.minimized=false;chat.emit('restore');assert.equal(isPresented(chat),true);
assert.equal(chat.listenerCount('blur'),0,'unfocused companions remain visible');
assert.equal(relayAvatarEvent([chat,avatar],avatar.webContents,{kind:'reaction',reply:'Hello'},post),true);
assert.equal(sent.at(-1).w,chat);
assert.equal(relayAvatarEvent([chat,avatar],{}, {kind:'action',action:'wave'},post),false);
assert.equal(relayAvatarEvent([chat,avatar],avatar.webContents,{kind:'action',action:'x'.repeat(25000)},post),false);
chat.shown=false;assert.equal(relayAvatarEvent([chat,avatar],avatar.webContents,{kind:'action',action:'wave'},post),false);
const page=fs.readFileSync('web/index.html','utf8');
const functionSource=name=>{
 const start=page.indexOf('    const '+name+' =');assert(start>=0,name);
 return page.slice(start,page.indexOf('\n    };',start)+7);
};
(async()=>{
 const {craftInvoker,methodCaller,cspSafeBasis}=await import('../scripts/basis-csp-glue.mjs');
 const binding={usesDestructorStack:types=>types.slice(1).some(t=>t&&t.destructorFunction===undefined),
  createNamedFunction:(_name,fn)=>fn,throwBindingError:message=>{throw Error(message);},runDestructors:items=>{for(const fn of items)fn();}};
 vm.createContext(binding,{codeGeneration:{strings:false,wasm:true}});
 vm.runInContext(craftInvoker+';globalThis.make=craftInvokerFunction;',binding);
 const scalar={name:'int',toWireType:(_stack,value)=>value*2,fromWireType:value=>value+1,destructorFunction:null};
 const add=binding.make('add',[scalar,null,scalar,scalar],null,(_fn,a,b)=>a+b,0);
 assert.equal(add(2,3),11);assert.throws(()=>add(1),/expected 2/);
 let cleanup=0;
 const object={...scalar,toWireType:(stack,value)=>{stack.push(()=>cleanup++);return value;},destructorFunction:undefined};
 const call=binding.make('method',[scalar,object,scalar],{},(_fn,self,value)=>self.value+value,0);
 assert.equal(call.call({value:10},3),17);assert.equal(cleanup,1);
 const upstream=fs.readFileSync('node_modules/three/examples/jsm/libs/basis/basis_transcoder.js','utf8');
 assert(!cspSafeBasis(upstream).includes('newFunc(Function'));
 let stopped=0,drawn=0,disposed=0,loaded=0,raf=0;const timers=new Map();let timer=0;
 const initial={orbit:{yaw:.4,pitch:.2},companion:{follow:true},companionOffset:{x:2,y:3}};
 const s={conversationReady:null,avatar3d:initial,manifest:{renderer:'3d'},shell:{getPresentation(){},shareLiveTalkFrame:value=>{s.frame=value;}},document:{hidden:false},
  ready:true,lastFrame:10,lastBodyGeometry:{},live:{remoteAudioState:{speaking:true},stop(){stopped++;}},ptt:null,
  canvas:{width:2000,height:1600},faceCanvas:{width:1024,height:1536},headCanvas:{width:1024,height:1536},
  requestAnimationFrame:()=>++raf,cancelAnimationFrame(){},setTimeout:(fn,delay)=>{timers.set(++timer,{fn,delay});return timer;},clearTimeout:id=>timers.delete(id),
  avatar3dIdentity:()=> 'same',is3DRuntime:m=>m.renderer==='3d',setStatus(){},emptyState:{classList:{add(){}}},
  disposeAvatar3D(){disposed++;s.avatar3d=null;},async loadAvatar3D(){loaded++;s.avatar3d={...initial,setOrbit(){}};s.ready=true;},refreshAvatar3D(){},renderLoop(){drawn++;},
  considerAvatarReaction(){},performAvatarAction:async()=>{},notify(){},avatarCompanionAPI:null,
  performance:{now:()=>1000},sampleAudioSignal(){},syncLiveTalkAudioStatus(){},desiredViseme:()=> 'aa',audioSignal:{relative:.6},
  avatar3dExpression:()=>({smile:.2}),speechExpressionPlan:{},publishCompanionState(){},updateRecordingMeter(){}};
 vm.createContext(s);
 const start=page.indexOf('    let presentationVisible ='),end=page.indexOf('    let avatar3dOptionsMounted',start);
 vm.runInContext(page.slice(start,end)+'\nglobalThis.policy={setPresentation,unloadHiddenAvatar,ensurePresentedAvatar,receiveAvatarEvent,avatarPresented};',s);
 assert.equal(s.policy.avatarPresented(),false,'native-hidden startup overrides DOM visible');
 await s.policy.ensurePresentedAvatar();assert.equal(loaded,0);
 s.policy.setPresentation({visible:true});await Promise.resolve();assert.equal(loaded,0);assert.equal(raf,1);
 s.policy.setPresentation({visible:false});
 const release=[...timers.values()].find(t=>t.delay===45000);assert(release);release.fn();
 assert.equal(disposed,1);assert.equal(s.canvas.width,1);assert.equal(stopped,0,'unloading cannot hang up Live Talk');
 vm.runInContext(functionSource('maintainHiddenAudio')+'\nmaintainHiddenAudio();',s);
 assert.equal(s.frame.visualOnly,true);assert.equal(s.frame.visual.viseme,'aa');assert.equal(s.frame.visual.speaking,true);assert.equal(drawn,0);
 s.policy.setPresentation({visible:true});await new Promise(r=>setImmediate(r));assert.equal(loaded,1);assert.equal(stopped,0);
 await s.policy.ensurePresentedAvatar();assert.equal(loaded,1,'repeated show shares the same scene');
 s.manifest={renderer:'2d'};s.ready=true;s.canvas.width=640;
 s.policy.setPresentation({visible:false});s.policy.unloadHiddenAvatar();
 assert.equal(s.ready,true,'2D avatars keep their existing resume path');assert.equal(s.canvas.width,640);
 s.manifest={renderer:'3d'};s.policy.setPresentation({visible:true});
 s.avatar3d={options:{selection:{}},motion:{active:null},companion:{walking:false}};
 Object.assign(s,{speechSource:null,hasAttachedAgentAudio:()=>false,agentSpeaking:false,dragging:false,avatarZoomGesture:false,avatarOrbitGesture:false,
  pointer:{seen:false},blinkStartedAt:0,reducedMotion:{matches:false},shellState:{onBattery:false},STANDBY_GAZE_SETTLE_MS:300,STANDBY_MAINTENANCE_MS:1000});
 vm.runInContext(functionSource('avatar3dFrameDelay')+'\nglobalThis.delay=avatar3dFrameDelay;',s);
 assert.equal(s.delay(1000),1000/15);s.avatar3d.motion.active={};assert.equal(s.delay(1000),1000/30);
 s.avatar3d.options.selection.performance='eco';assert.equal(s.delay(1000),1000/24);s.avatar3d.motion.active=null;assert.equal(s.delay(1000),125);
 console.log('Resources: native visibility, deferred startup, hidden scene disposal, live audio continuity, event routing, single resume and adaptive cadence passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
