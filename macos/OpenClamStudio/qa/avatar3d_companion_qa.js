'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {companionStep}=require('../electron/companion-move.cjs');
const sandbox={};
vm.runInNewContext(fs.readFileSync('web/avatar3d-companion.js','utf8').replace(/export /g,'')+'\nglobalThis.Stage=AvatarStudioStage;globalThis.spatial=isSpatialAction;globalThis.Controller=CompanionController;globalThis.intent=avatarIntent;globalThis.motionIntent=motionIntent;globalThis.react=conversationReaction;globalThis.replyAction=replyAvatarAction;',sandbox);
for(const [text,expected] of [['Tia, wave!','wave'],['Can you show me a heart?','heart'],['sit down','sit'],['Please follow my cursor','follow'],['stay','stay'],['跳舞','dance'],['Tia, come here','come']])assert.equal(sandbox.intent(text),expected);
for(const text of ['walk with cursor','walk with cusor','Follow the mouse pointer around',
  'Hey Tia, could you please walk with my cursor around the screen?', 'Move with the mouse', 'Track my pointer',
  'I want you to follow my mouse', 'I’d like her to follow the cursor', 'Keep following my cursor please',
  'Start walking with my mouse', 'Follow wherever I move my mouse', 'Go wherever the cursor goes',
  'Make Tia follow my cursor', 'Can you please chase the cursor, thanks!', '请跟着我的鼠标移动']){
  assert.equal(sandbox.intent(text),'follow',text);
}
for(const text of ['Stop following my cursor','Do not follow my mouse','Don’t follow me','Stop walking with the mouse',
  'Tia, stay still please', '停止跟随鼠标'])assert.equal(sandbox.intent(text),'stay',text);
for(const text of ['What is a wave?','Write a poem about dance','Tell Bob to come here','Do not dance',
  'Do you think Tia could wave?','"wave"','Explain how to follow my cursor', 'She said follow my cursor',
  'I want you to explain cursor tracking', 'Follow my instructions', 'Follow my cursor when I ask later',
  'Please don’t start following my cursor', 'Can you tell me how to follow the mouse?', 'Tiara follow my cursor']){
  assert.equal(sandbox.intent(text),null,'do not intercept prose: '+text);
}
const controller=new sandbox.Controller();controller.command('follow');
let x=100,walking=false;
for(let t=1000;t<8000;t+=32){const s=controller.step(t,{cursorX:500,anchorX:x,minX:50,maxX:600,height:500});x+=s.dx;walking||=s.walking;}
assert(walking&&x>450&&x<490,'walk approaches the cursor and leaves personal space');
for(let t=8000;t<11000;t+=32){const s=controller.step(t,{cursorX:x+32,anchorX:x,height:500});assert(!s.walking,'dead zone must not chatter');}
controller.pause(11000);
assert.equal(controller.step(11032,{cursorX:900,anchorX:x}).dx,0,'manual interaction owns movement');
assert.equal(controller.step(15000,{cursorX:900,anchorX:x,reduce:true}).dx,0,'Reduce Motion stops walking');
controller.command('stay');assert.equal(controller.step(15032,{cursorX:900,anchorX:x}).dx,0);
controller.command('come');x=100;
for(let t=16000;t<26000;t+=32){const s=controller.step(t,{cursorX:900,anchorX:x,minX:40,maxX:300,height:500});x+=s.dx;}
assert(!controller.come&&x<300,'one-shot approach stops at the viewport boundary');
const bounds={x:700,y:40,width:300,height:600},area={x:0,y:24,width:1000,height:800};
assert.equal(companionStep(bounds,area,10000,0,10000).x,700,'native movement cannot leave right edge');
assert.equal(companionStep(bounds,area,-10000,0,32).x,694,'native IPC caps velocity independently');
assert.equal(companionStep(bounds,area,0,-10000,10000).y,24,'native movement cannot leave top edge');
assert.equal(companionStep({...bounds,y:224},area,0,10000,10000).y,224,'native movement cannot leave bottom edge');
assert.equal(companionStep(bounds,area,NaN,0,32),null);
assert.equal(companionStep(bounds,area,0,Infinity,32),null);
assert.equal(companionStep(bounds,area,10,10,0).x,700);
const diagonal=companionStep({...bounds,x:400},area,10000,10000,100);
assert(Math.hypot(diagonal.x-400,diagonal.y-40)<21,'native vector limit covers diagonal IPC');
let next={...bounds,x:400};
for(let i=0;i<100;i++)next=companionStep(next,area,.1,.2,32,next.remainder);
assert.equal(next.x,410);assert.equal(next.y,60,'subpixel steps accumulate instead of losing vertical motion');
// Use the actual IPC handler: a y-only change must reach setPosition, while
// hidden/locked avatars and the chat window cannot move native windows.
const main=fs.readFileSync('electron/main.cjs','utf8');
const ipcStart=main.indexOf('  const companionLastStep=new WeakMap();');
const ipcSource=main.slice(ipcStart,main.indexOf("  ipcMain.handle('openclam:get-state'",ipcStart));
let nativeNow=1000, handler, nativeBounds={...bounds,x:400}, locked=false, shown=true;
const sender={}, nativeWindow={isDestroyed:()=>false,isVisible:()=>shown,getBounds:()=>nativeBounds,
  setPosition(x,y){nativeBounds={...nativeBounds,x,y};}};
const ipcContext={WeakMap,Date:{now:()=>nativeNow},companionStep,
  ipcMain:{on:(name,callback)=>{handler=callback;}},BrowserWindow:{fromWebContents:()=>nativeWindow},
  isBuddySender:()=>false,mainWindow:nativeWindow,state:{get petLocked(){return locked;}},petDrag:false,desktopCloseUp:false,
  avatarRendererKinds:new Map([[sender,'3d']]),screen:{getDisplayMatching:()=>({workArea:area})},saveStateSoon(){}};
vm.runInNewContext(ipcSource,ipcContext);
for(let i=0;i<100;i++){nativeNow+=32;handler({sender},{dx:0,dy:1});}
assert.equal(nativeBounds.y,140,'native IPC moves vertically without an x change');
locked=true;handler({sender},{dx:10,dy:10});assert.equal(nativeBounds.y,140);
locked=false;shown=false;handler({sender},{dx:10,dy:10});assert.equal(nativeBounds.y,140);
shown=true;ipcContext.mainWindow={};handler({sender},{dx:10,dy:10});assert.equal(nativeBounds.y,140);
for(const [dx,dy] of [[300,0],[0,-300],[0,300],[300,300],[-300,300],[-300,-300]]){
  const c=new sandbox.Controller();c.command('follow');let x=500,y=500;
  for(let t=1000;t<12000;t+=32){
    const s=c.step(t,{cursorX:500+dx,cursorY:500+dy,anchorX:x,anchorY:y,height:300});
    assert(Math.hypot(s.dx,s.dy)<=84*.05+1e-8,'diagonal speed uses a vector limit');
    x+=s.dx;y+=s.dy;
  }
  assert(Math.hypot(500+dx-x,500+dy-y)<34,'arrive near cursor in all directions');
  assert(!c.walking,'settle after arrival');
  for(const block of [{blocked:true},{reduce:true},{seen:false},{cursorY:NaN}]){
    const s=c.step(14100,{cursorX:100,cursorY:100,anchorX:x,anchorY:y,...block});
    assert.equal(s.dx,0);assert.equal(s.dy,0);
  }
  c.pause(15000);
  assert.equal(c.step(15032,{cursorX:900,cursorY:900,anchorX:x,anchorY:y}).dy,0,'manual controls own both axes');
  c.command('follow');c.command('follow');assert(c.follow,'repeated follow is idempotent');
  c.command('stay');const stopped=c.step(19000,{cursorX:900,cursorY:900,anchorX:x,anchorY:y});
  assert.equal(stopped.dx,0);assert.equal(stopped.dy,0);
}
const c=new sandbox.Controller();c.command('come');x=100;let y=100;
for(let t=1000;t<16000;t+=32){
  const s=c.step(t,{cursorX:900,cursorY:900,anchorX:x,anchorY:y,minX:40,maxX:400,minY:50,maxY:300,height:300});
  x+=s.dx;y+=s.dy;assert(x<=400&&y<=300,'one-shot approach stays within both boundaries');
}
assert(!c.come&&x>370&&y>270,'come here completes near the nearest reachable point');

// The toolbar toggles; another spoken request must never switch follow off.
const page=fs.readFileSync('web/index.html','utf8');
const idleStart=page.indexOf('    const edgeIdleActive = ');
const idleSource=page.slice(idleStart,page.indexOf('\n    };',idleStart)+7);
const idle={avatar3d:{companion:new sandbox.Controller(),motion:{}},root:{classList:{contains:()=>true}},
  motion:{},roamState:{enabled:false},speechSource:null,agentSpeaking:false,live:null,ptt:null,turnController:null,
  lastActivity:0,standbyIdleDelay:()=>10000};
vm.createContext(idle);vm.runInContext(idleSource+'\nglobalThis.isIdle=edgeIdleActive;',idle);
assert(!idle.isIdle(20000),'3D rest preserves the chosen size and placement');
idle.avatar3d.companion.command('follow');assert(!idle.isIdle(600000),'following must not shrink/dock after the idle timeout');
idle.avatar3d.companion.command('come');assert(!idle.isIdle(600000));
idle.avatar3d.companion.command('stay');idle.avatar3d.motion.active={id:'dance'};
assert(!idle.isIdle(600000),'a playing clip also owns its presentation');
const drawStart=page.indexOf('      if (avatar3d.companion) {',page.indexOf('    const drawAvatar3D = '));
const travel=page.slice(drawStart,page.indexOf('      // The logical portrait',drawStart));
for(const mirrored of [false,true]){
  const s={fullChat:true,now:1000,fit:{x:400,y:300,scale:1},previewMetadata:{bounds:[0,0,100,200]},
    renderLeft:200,lastBodyGeometry:{},safeViewport:{x:200,y:80,width:700,height:600},innerWidth:1000,innerHeight:800,
    pointer:{x:280,y:200,seen:true},dragging:false,canvasGesture:null,avatarZoomGesture:null,avatarOrbitGesture:false,
    speaking:false,ptt:null,live:null,peerLiveFrame:null,reduce:false,shellState:{pet:{}},document:{getElementById:()=>null,hidden:false},
    notify:assert.fail,avatarCanvasPoint:p=>({x:mirrored?1100-p.x:p.x,y:p.y}),
    avatar3d:{companion:new sandbox.Controller(),companionOffset:{x:0,y:0},orbit:{yaw:0,pitch:0},
      options:{selection:{}},motion:{clips:new Map(),play:()=>Promise.resolve(),stop(){},setPlaybackRate(rate){assert(rate>=0&&rate<1.2);}},setOrbit(){}}};
  s.avatar3d.studioStage=new sandbox.Stage(s.fit,{bounds:[0,0,100,200],faceBounds:[25,0,50,40]},s.safeViewport);
  s.avatar3d.companion.command('follow');vm.createContext(s);
  const frame=()=>{s.fit={x:400,y:300,scale:1};vm.runInContext(travel,s);};
  for(;s.now<31000;s.now+=32)frame();
  const stage=s.avatar3d.studioStage;
  assert(mirrored?stage.x>.8:stage.x<.15,'mirrored and ordinary chat both approach the visible cursor');
  assert(stage.y<.25,'renderer applies vertical travel');
  const upperScale=s.fit.scale;
  s.pointer.y=600;
  for(;s.now<65000;s.now+=32)frame();
  assert(stage.y>.8,'same chat avatar can travel down again');
  assert(s.fit.scale>upperScale*2,'travelling down approaches the viewer');
  const before=[stage.x,stage.y];s.dragging=true;s.pointer={x:880,y:90,seen:true};
  for(;s.now<66000;s.now+=32)frame();
  assert.deepEqual([stage.x,stage.y],before,'manual gesture leaves follow placement untouched');
}
const start=page.indexOf('    const performAvatarAction = ');
const source=page.slice(start,page.indexOf('\n    };',start)+7);
const avatar={companion:new sandbox.Controller(),stopCameraApproach(){},motion:{stop(){},async prepare(){}},options:{selection:{},select(){}}};
const actions={avatarCompanionAPI:{isSpatialAction:sandbox.spatial},beginAvatarStudioTravel:async()=>{},avatar3d:avatar,live:null,manifest:{avatar:{slug:'tia'}},localStorage:{setItem(){}},
  performance:{now:()=>1000},clearLocalTransientDisplayMode(){},markActivity(){},
  publishMotionReadiness(){},companionKey:()=>'',window:{dispatchEvent(){}},Event:class{},closeRailPickers(){},async selectStandbyMode(){assert.fail('motions must preserve framing');}};
vm.createContext(actions);vm.runInContext(source+'\nglobalThis.perform=performAvatarAction;',actions);
(async()=>{
  await actions.perform('follow');await actions.perform('follow');assert(avatar.companion.follow);
  await actions.perform('follow',{toggleFollow:true});assert(!avatar.companion.follow);
  assert(avatar.companion.reactions,'turning off follow preserves conversation reactions');
  await actions.perform('stay');assert(!avatar.companion.reactions,'explicit stay disables automatic reactions');
  console.log('3D companion: varied commands, idempotent requests, 2D travel, manual ownership, bounds and fractional native movement passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});

const clips=new Map([['heart',{id:'heart',label:'Overhead Heart',aliases:['big heart'],reactions:['affection'],requiresFreeHands:true}],
  ['happy',{id:'happy',label:'Joyful Sway',aliases:['happy dance'],reactions:['celebration']}],
  ['cheer',{id:'cheer',reactions:['celebration']}]]);
for(const request of ['Could you please do a happy dance?', 'Tia, play joyful sway', 'can u try some happy dance'])assert.equal(sandbox.motionIntent(request,clips),'clip:happy');
for(const prose of ['Do not do a happy dance','Why is happy dance named that?','She said play joyful sway','Write about big heart'])assert.equal(sandbox.motionIntent(prose,clips),null);
assert.equal(sandbox.react('be happy','Let’s brighten things up!','none'),null);
assert.equal(sandbox.motionIntent('do kongfu',new Map([['kungfu',{id:'kungfu',label:'Kung Fu'}]])),'clip:kungfu');
assert.equal(sandbox.react('I got the job!','Congratulations!','celebration'),'celebration');
assert.equal(sandbox.react('I got the job!','That’s wonderful news!'),'celebration',
  'voice transcripts with typographic apostrophes use the same local reactions');
assert.equal(sandbox.react('Can you please be more cheerful?','Let’s brighten things up!'),'celebration');
assert.equal(sandbox.react('','Hello! How are you?'),'greeting','the opening Live Talk greeting has no preceding user');
assert.equal(sandbox.react('I’m not happy','Let’s celebrate!'),null,'normalization must preserve negative-context suppression');
assert.equal(sandbox.react('I love you','Sending you a hug.','affection'),'affection');
assert.equal(sandbox.react('What is a heart?','A heart pumps blood.','none'),null);
assert.equal(sandbox.react('My friend died.','I am sorry. Congratulations was a mistake.','celebration'),null);
assert.equal(sandbox.react('I am not happy','Let’s celebrate!','celebration'),null);
assert.equal(sandbox.react('Show me a heart','Of course!','affection'),'affection');
assert.equal(sandbox.react('Explain dance','Here is the explanation.','run-arbitrary-code'),null);
const reacting=new sandbox.Controller({random:()=>0});
reacting.consider('I got the job!','Congratulations!','celebration',1000);
assert.equal(reacting.takeReaction(1100,clips,true),null,'busy/manual state defers automatic motion');
assert.equal(reacting.takeReaction(1200,clips),'happy');
reacting.consider('I passed!','You did it!','celebration',2000);
assert.equal(reacting.takeReaction(2100,clips),null,'cooldown prevents constant reactions');
reacting.consider('I passed!','You did it!','celebration',24000);
assert.equal(reacting.takeReaction(24001,clips),'cheer','repeated categories vary the selected clip');
reacting.consider('Love you','Sending a hug','affection',50000);
assert.equal(reacting.takeReaction(50001,clips,false,{hasProp:true}),null,'heart gesture cannot displace a held prop');
reacting.consider('Thanks a lot','You are sweet','affection',80000);reacting.pause(80001);
assert.equal(reacting.takeReaction(90000,clips),null,'manual interaction clears pending reactions');
reacting.consider('Hi','Hello!','celebration',100000);reacting.command('stay');
assert.equal(reacting.takeReaction(100001,clips),null,'stay has priority');
console.log('Context reactions: provider hints, local fallback, manual priority, cooldown, varied choices, prop ownership and direct preset commands passed.');

// Desktop menu executes against the active owner and uses its installed catalog.
let menuItems,packet;
const owner={webContents:{},isDestroyed:()=>false};
const menus={avatarOptionCatalogues:new Map([[owner.webContents,{reactions:true,follow:false,
  motions:[{id:'jazz-dance',label:'Jazz Dance',group:'Dances'}]}]]),
  showMenuWindow:items=>{menuItems=items;},post:(...args)=>{packet=args;}};
vm.createContext(menus);
const menuStart=main.indexOf('function showAvatarMotionMenu(');
vm.runInContext(main.slice(menuStart,main.indexOf('function showPetMenu()',menuStart))+'\nglobalThis.show=showAvatarMotionMenu;',menus);
menus.show(owner);
assert.equal(menuItems[0].checked,true);
menuItems.find(item=>item.name==='Dances').submenu[0].click();
assert.equal(packet[0],owner);assert.equal(packet[1],'openclam:avatar-options-request');
assert.equal(packet[2].id,'clip:jazz-dance');
menuItems[0].click();assert.equal(packet[2].id,'reactions');

// Conversation first: input alone never owns speech or selects a motion.
const conversationClips=new Map([
  ['kung-fu-punch',{id:'kung-fu-punch',label:'Kung Fu Punch'}],
  ['jazz-dance',{id:'jazz-dance',label:'Jazz Dance'}]
]);
for(const reply of ['', 'Kung fu is a family of Chinese martial arts.', 'Do you want a demonstration?',
  "I'll explain kung fu.", "I'll show you how to learn kung fu.", "I'll show you a video of kung fu.",
  "I can't demonstrate kung fu.", "If you like, I'll demonstrate kung fu.", "Would you like me to demonstrate kung fu?"]){
  assert.equal(sandbox.replyAction('kungfu',reply,undefined,conversationClips),null,reply);
}
assert.equal(sandbox.replyAction('kungfu',"I'll demonstrate a kung fu punch.",undefined,conversationClips),'clip:kung-fu-punch');
assert.equal(sandbox.replyAction('kungfu',"I’ll try a kung fu punch!",undefined,conversationClips),'clip:kung-fu-punch');
assert.equal(sandbox.replyAction('kungfu','Want a demonstration?','none',conversationClips),null);
assert.equal(sandbox.replyAction('try that',"Let's give it a try.",'clip:kung-fu-punch',conversationClips),'clip:kung-fu-punch');
assert.equal(sandbox.replyAction('dance','Sure.','clip:not-installed',conversationClips),null);
assert.equal(sandbox.replyAction('dance',"I cannot dance.",'clip:jazz-dance',conversationClips),null);
assert.equal(sandbox.replyAction('go along with my mouse',"I'll walk with your cursor.",'action:follow',conversationClips),'action:follow');
assert.equal(sandbox.replyAction('hello','Hello','action:open-url',conversationClips),null);
assert.equal(sandbox.replyAction('Please walk to the upper-right corner.',
  'Sure, I’ll keep walking to the upper-right corner.',undefined,conversationClips),'action:go-upper-right');
assert.equal(sandbox.replyAction('run around','I will continue running around the screen.',undefined,conversationClips),'action:run-around');
assert.equal(sandbox.replyAction('Please walk back to the center.',
  'Sure, I’ll walk back to the center.',undefined,conversationClips),'action:go-center');
for(const reply of ['Would you like me to keep walking?', 'I’ll keep walking if you ask later.',
  'I cannot keep walking.', 'She said “keep walking”.'])
  assert.equal(sandbox.replyAction('walk to the upper right',reply,undefined,conversationClips),null,reply);
const conversationController=new sandbox.Controller();
conversationController.consider('kungfu','Want to talk about it or see a demonstration?','none',1000,{clips:conversationClips,turnID:'k1'});
assert.equal(conversationController.takeReaction(1001,conversationClips),null);
conversationController.consider('show me',"I'll demonstrate a kung fu punch.",'clip:kung-fu-punch',2000,{clips:conversationClips,turnID:'k2'});
assert.equal(conversationController.takeReaction(2001,conversationClips),'action:clip:kung-fu-punch');
conversationController.consider('show me',"I'll demonstrate a kung fu punch.",'clip:kung-fu-punch',3000,{clips:conversationClips,turnID:'k2'});
assert.equal(conversationController.takeReaction(3001,conversationClips),null);
console.log('LLM-owned motion decisions: no input-only playback, discussion/clarification/refusal stay still, validated choices play once.');

const realisticClips=new Map([['sit-cross-legged',{id:'sit-cross-legged',label:'Sit Cross-Legged'}],
  ['kung-fu-punch',{id:'kung-fu-punch',label:'Kung Fu Punch'}],['walk',{id:'walk',label:'Walk'}],
  ['wave',{id:'wave',label:'Wave',reactions:['greeting']}]]);
for(const [user,reply,hint,expected] of [
  ['Can you smile Can you sit?',"Of course! I'll sit cross-legged for you right now. Anything else you'd like to see?",undefined,'clip:sit-cross-legged'],
  ['sit',"Sure, I'll sit down.",'none','action:sit'],
  ['closer',"Of course! I'll walk a little closer to you.",undefined,'action:closer'],
  ['stand',"Sure, standing up now!",undefined,'action:stand'],
  ['come closer',"Of course, coming closer now.",undefined,'action:closer'],
  ['run around',"I'm running around the screen now!",undefined,'action:run-around'],
  ['dance',"Absolutely! Let me show you a dance. Would you like something else?",undefined,'action:dance'],
  ['run around',"I'll run around the chat window for you now.",undefined,'action:run-around'],
  ['kungfu',"I can explain kung fu if you'd like.",undefined,null],
  ['dance',"If you ask later, I'll dance.",undefined,null],
])assert.equal(sandbox.replyAction(user,reply,hint,realisticClips),expected,reply);
const upgrading=new sandbox.Controller({random:()=>0});
upgrading.consider('Can you sit?','Hello!',undefined,1000,{turnID:'one-turn',clips:realisticClips});
assert.equal(upgrading.takeReaction(1001,realisticClips),'wave');
upgrading.consider('Can you sit?',"Hello! I'll sit down.",undefined,1100,{turnID:'one-turn',clips:realisticClips});
assert.equal(upgrading.takeReaction(1101,realisticClips),'action:sit','a greeting must not consume the later performance decision');
upgrading.consider('Can you sit?',"Hello! I'll sit down. Anything else?",undefined,1200,{turnID:'one-turn',clips:realisticClips});
assert.equal(upgrading.takeReaction(1201,realisticClips),null,'the actual decision executes only once');

// A clip launched from the small desktop pet must first acquire the display.
const startStage=page.indexOf('    const beginAvatarStudioTravel = ');
const stageSource=page.slice(startStage,page.indexOf('    const performAvatarAction = ',startStage));
const stageAvatar={actionGeneration:1,layout:()=>({bounds:[0,0,100,200],faceBounds:[25,0,50,40]}),
  lockStudioLens(){},orbit:{yaw:0,pitch:0},restBounds:{min:{y:0},max:{y:2}},studioDistance:5,
  studioProjection:()=>({ground:{x:50,y:200},pixelsPerUnit:100,groundDepth:.2}),companion:{},
  motion:{prepare:()=>assert.fail('a stationary clip should not load an unrelated walk')}};
let expanded=0;
const expansion={avatar3d:stageAvatar,avatarCompanionAPI:{AvatarStudioStage:sandbox.Stage},
  reducedMotion:{matches:false},lastBodyGeometry:{fit:{x:10,y:20,scale:2}},
  root:{classList:{contains:()=>false}},shell:{setDisplayMode:async mode=>{assert.equal(mode,'approach');expanded++;return {approachOrigin:{x:700,y:30}};}},
  applyShellState(){},requestAnimationFrame:fn=>fn(),innerWidth:1400,innerHeight:900};
vm.createContext(expansion);vm.runInContext(stageSource+'globalThis.begin=beginAvatarStudioTravel;',expansion);
(async()=>{
  await expansion.begin(stageAvatar,'clip:kung-fu-punch',1,{stationary:true});
  assert.equal(expanded,1,'a non-spatial punch acquires the full native display before playing');
  const fit=stageAvatar.studioStage.project({x:0,y:0,width:1400,height:900});
  assert.equal(fit.scale,2,'native expansion preserves the resting actor size');
  assert(Math.abs(fit.x-710)<1e-8&&Math.abs(fit.y-50)<1e-8,'native expansion preserves screen placement');
  await expansion.begin(stageAvatar,'wave',1,{stationary:true});assert.equal(expanded,1,'an existing stage is not expanded/reset twice');
})().catch(error=>{console.error(error);process.exitCode=1;});
