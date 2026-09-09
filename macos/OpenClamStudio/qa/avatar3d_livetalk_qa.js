'use strict';
// Drive the production transcript handler and iOS frame loop together with
// their shared reaction controller. Transport and WebGL are test doubles;
// the completed-turn, motion selection and speech-state paths are real.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const companion = fs.readFileSync('web/avatar3d-companion.js', 'utf8').replace(/export /g, '');
const clips = new Map([
  ['wave', {id:'wave', label:'Wave', reactions:['greeting']}],
  ['cheer', {id:'cheer', label:'Cheer', reactions:['celebration']}],
]);
const page = fs.readFileSync('web/index.html', 'utf8');
const handler = page.match(/const handleTranscript = \(session, segments, participant\) => \{[\s\S]*?\n    \};/)[0];
let now = 1000;
const session = {finalTranscriptIDs:new Set(), latestFinalUserTranscript:''};
const desktop = {avatarCompanionAPI:{avatarIntent:()=>null,motionIntent:()=>null},avatar3d:null,live:session, performance:{now:()=>now},
  beginLiveTalkUserInput(){}, updatePendingLiveTalkUserSegment(){},
  appendFinalUserTurnSegment(s,text){s.latestFinalUserTranscript=text;},
  handleAvatarCommand:async()=>false,
  assistantTranscriptDisposition:()=>({preserveUserTurn:false,suppress:false}),
  makeSpeechExpressionTimeline:()=>[], makeSpeechExpressionPlan:()=>({}), speechExpressionPlanAt:()=>({}),
  addMessage(){}, setStatus(){}};
vm.createContext(desktop);
vm.runInContext(companion + '\nglobalThis.controller=new CompanionController();' + handler
  + '\nglobalThis.receive=handleTranscript;'
  + '\nglobalThis.considerAvatarReaction=(user,reply)=>controller.consider(user,reply,undefined,performance.now());', desktop);
desktop.receive(session,[{id:'greeting',text:'Hello! How are you?',final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),'wave','a real Live Talk final greeting triggers motion');
desktop.receive(session,[{id:'greeting',text:'Hello! How are you?',final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),null,'duplicate finals do not replay');
now=24000;
desktop.receive(session,[{id:'user-1',text:'I got the job!',final:true}],{isAgent:false});
desktop.receive(session,[{id:'reply-1',text:'That’s wonderful news!',final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),'cheer');

const iosSource = fs.readFileSync('../../ios/OpenClamLiveKit/App/Avatar3D/avatar-ios.js','utf8')
  .replace(/^import .*;$/gm,'').replace(/export /g,'');
const messages=[], played=[];
let rendered;
const ios={console,URLSearchParams,location:{search:'?generation=1'},
  requestAnimationFrame(){},
  window:{webkit:{messageHandlers:{avatarStatus:{postMessage:v=>messages.push(v)}}},addEventListener(){},devicePixelRatio:1},
  document:{hidden:false,addEventListener(){},querySelector:()=>({remove(){}})},
  avatarFixture:{options:{select(){}},restBounds:{min:{y:0},max:{y:2}},studioDistance:5,orbit:{yaw:0,pitch:0},canvas:{getBoundingClientRect:()=>({width:300,height:600})},
    layout:()=>({bounds:[70,80,160,430],faceBounds:[110,90,80,100]}),
    motion:{clips,play:async id=>{played.push(id);return true;},expression:()=>({smile:.4}),setPlaybackRate(rate){assert(rate>=0&&rate<1.2);}},
    studioProjection:()=>({ground:{x:150,y:510},pixelsPerUnit:215,groundDepth:.2}),
    setOrbit(){},render:(time,state)=>{rendered=state;}},
  frame:{state:{speaking:true,reduce:false,visemeWeights:{aa:.7,PP:.3},expression:{smile:.1}},
    options:{dynamicMotions:'true'},crop:{x:0,y:0,w:300,h:600},orbit:{yaw:0,pitch:0},
    conversation:{id:'long-final',user:'I got the job!',reply:'That’s wonderful news!',created:Date.now()}},
  performance:{now:()=>1000},Date};
vm.createContext(ios);
vm.runInContext(companion + '\n' + iosSource
  + '\navatar=avatarFixture;companion=new CompanionController();latest=frame;globalThis.drawFrame=draw;globalThis.nativeCommand=window.avatarCommand;',ios);
ios.drawFrame(1000);
assert.deepEqual(played,['cheer'],'a completed Live Talk reply plays while speech is active');
assert.deepEqual(rendered.visemeWeights,{aa:.7,PP:.3},'motion preserves synchronized mouth weights');
assert.equal(rendered.speaking,true);
assert.equal(rendered.expression.smile,.4,'motion and speech expression channels combine');
ios.drawFrame(1100);
assert.equal(played.length,1,'frame updates do not replay the same final');
ios.frame.options.dynamicMotions='false';
ios.frame.conversation={id:'off',user:'',reply:'Hello!',created:Date.now()};
ios.drawFrame(24000);
assert.equal(played.length,1,'explicit opt-out survives incoming Live Talk finals');
ios.frame.options.dynamicMotions='true';ios.frame.state.reduce=true;
ios.frame.conversation={id:'reduced',user:'',reply:'Hello!',created:Date.now()};
ios.drawFrame(48000);
assert.equal(played.length,1,'Reduce Motion prevents body playback without disabling speech');
assert.deepEqual(rendered.visemeWeights,{aa:.7,PP:.3});
ios.frame.state.reduce=false;
ios.frame.conversation={id:'expired',user:'',reply:'Hello!',created:Date.now()-60000};
ios.drawFrame(80000);
assert.equal(played.length,1,'renderer recovery must not replay an expired reply');
console.log('Live Talk motion integration passed: desktop finals, iOS speech overlap, greeting, deduplication, opt-out, Reduce Motion and expiry.');

// Exercise the actual composer router: animation vocabulary reaches whichever
// LLM route the user selected. It must never resolve to a local canned reply.
const submitter=page.match(/async function submitTurn\(text, options = \{\}\) \{[\s\S]*?\n    \}/)[0];
const routed=[];
const route={turnController:null,avatarOnlyMotion:false,agentID:null,
  selectedOpenClawAgent:()=>route.agentID,
  submitLocalTurn:(text)=>{routed.push(['llm',text]);return {text:'An AI reply'};},
  submitOpenClawTurn:(text,id)=>{routed.push([id,text]);return {text:'An agent reply'};},
  handleAvatarCommand:()=>{throw Error('Must not intercept user input');},
  performAvatarAction:()=>{throw Error('Must not perform before the AI reply');}};
vm.createContext(route);vm.runInContext(submitter+'\nglobalThis.submit=submitTurn;',route);
(async()=>{
  for(const input of ['kungfu','Can you dance?','Explain kung fu','follow my cursor']){
    assert.equal((await route.submit(input)).text,'An AI reply');
    assert.deepEqual(routed.at(-1),['llm',input]);
  }
  route.agentID='selected-agent';
  assert.equal((await route.submit('kungfu')).text,'An agent reply');
  assert.deepEqual(routed.at(-1),['selected-agent','kungfu']);
  console.log('Production chat routing: every motion request reaches the selected LLM; no canned bypass.');
})().catch(error=>{console.error(error);process.exitCode=1;});
const chosen=[];
ios.window.avatarCommand=async action=>{chosen.push(action);};
ios.avatarFixture.motion.active={id:'ambient'};
ios.frame.conversation={id:'chosen',turnID:'chosen-turn',user:'show me',reply:"I'll demonstrate a cheer.",suggestion:'clip:cheer',created:Date.now()};
ios.drawFrame(105000);
assert.deepEqual(chosen,['clip:cheer'],'an LLM-chosen demonstration takes over ambient motion through the normal command path');
ios.drawFrame(105100);
assert.equal(chosen.length,1,'the LLM action is not replayed each frame');

(async()=>{
  const spatialClips=new Map([['walk',{id:'walk'}],['hello-run',{id:'hello-run'}]]);
  Object.assign(ios.avatarFixture.motion,{clips:spatialClips,prepare:async()=>{},
    stop(){this.active=null;},play:async function(id){this.active={id};return true;}});
  ios.avatarFixture.lockStudioLens=()=>{};ios.avatarFixture.stopCameraApproach=()=>{};
  let crop;
  ios.avatarFixture.render=(now,state,view)=>{crop=view;};
  ios.frame.conversation=null;ios.frame.crop={x:0,y:0,w:300,h:600};
  await ios.nativeCommand('go-upper-right');
  for(let t=120000;t<150000;t+=33)ios.drawFrame(t);
  const stage=ios.avatarFixture.studioStage;
  assert(stage.x>.95&&stage.y<.05,'actual iOS command and frame loop reach the far corner without touch input');
  const small=crop.w;
  await ios.nativeCommand('closer');
  for(let t=150000;t<180000;t+=33)ios.drawFrame(t);
  assert(crop.w<small*.3,'actual iOS approach grows in the same stage');
  await ios.nativeCommand('go-center');
  for(let t=180000;t<210000;t+=33)ios.drawFrame(t);
  assert(Math.abs(stage.y-.5)<.01,'actual iOS center restores normal depth');
  const normal=crop.w;
  ios.frame.crop={x:25,y:50,w:250,h:500};
  ios.drawFrame(210100);
  assert(crop.w<normal,'manual native pinch resizes the active studio projection');
  assert.equal(crop.w/crop.h,.5,'native pinch preserves proportions');
  await ios.nativeCommand('go-upper-left');
  ios.avatarFixture.canvas.getBoundingClientRect=()=>({width:300,height:450});
  ios.frame.crop={x:25,y:50,w:250,h:375};
  for(let t=211000;t<241000;t+=33)ios.drawFrame(t);
  assert(stage.x<.05&&stage.y<.05,'keyboard/surface resize preserves the destination');
  assert(Math.abs(crop.w/crop.h-2/3)<1e-9,'keyboard resize preserves the displayed aspect');
  console.log('iOS studio integration: corner/closer/center, manual pinch and keyboard resize passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
