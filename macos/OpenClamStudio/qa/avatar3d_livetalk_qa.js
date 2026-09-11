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
  appendFinalUserTurnSegment(s,text){s.latestFinalUserTranscript=text;s.avatarReactionTurnID=text;},
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

now=50000;
session.avatarReactionTurnID='split-action';session.latestFinalUserTranscript='Can you run around?';
desktop.receive(session,[{id:'action-start',text:"Of course! I'll run around the screen.",final:true},
  {id:'action-followup',text:'Would you like anything else?',final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),'action:run-around','a following speech segment cannot erase the pending motion');
session.avatarReactionTurnID='revised-action';session.latestFinalUserTranscript='Can you sit?';
desktop.receive(session,[{id:'revised-final',text:'Of course!',final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),null);
desktop.receive(session,[{id:'revised-final',text:"Of course! I'll sit down.",final:true}],{isAgent:true});
assert.equal(desktop.controller.takeReaction(now,clips),'action:sit','a growing final also reaches the Mac motion controller');

const iosSource = fs.readFileSync('../../ios/OpenClamLiveKit/App/Avatar3D/avatar-ios.js','utf8')
  .replace(/^import .*;$/gm,'').replace(/export /g,'');
const messages=[], played=[];
let rendered;
const ios={console,URLSearchParams,location:{search:'?generation=1'},
  requestAnimationFrame(){},
  window:{webkit:{messageHandlers:{avatarStatus:{postMessage:v=>messages.push(v)}}},addEventListener(){},devicePixelRatio:1},
  document:{hidden:false,addEventListener(){},querySelector:()=>({remove(){}})},
  avatarFixture:{options:{select(){},walkingClip:()=> 'walking-woman',isTravelClip:id=>['walking-woman','walk','casual-walk','stage-walk','hello-run'].includes(id)},restBounds:{min:{y:0},max:{y:2}},studioDistance:5,orbit:{yaw:0,pitch:0},canvas:{getBoundingClientRect:()=>({width:300,height:600})},
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
assert.deepEqual(played,[],'the first draw must not consume a reply before the renderer is ready');
ios.drawFrame(1040);
assert.deepEqual(played,['cheer'],'a completed Live Talk reply plays while speech is active');
assert.deepEqual(rendered.visemeWeights,{aa:.7,PP:.3},'motion preserves synchronized mouth weights');
assert.equal(rendered.speaking,true);
assert.equal(rendered.expression.smile,.4,'motion and speech expression channels combine');
ios.drawFrame(1140);
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
  const spatialClips=new Map([['walking-woman',{id:'walking-woman'}],['walk',{id:'walk'}],['hello-run',{id:'hello-run'}]]);
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
  let manualTime=210200;
  for(const [dx,dy] of [[0,25],[0,-40],[30,0],[-20,20]]){
    const before={...crop},depth=stage.y,nativeScale=300/ios.frame.crop.w;
    ios.frame.crop={...ios.frame.crop,x:ios.frame.crop.x+dx,y:ios.frame.crop.y+dy};
    ios.drawFrame(manualTime);manualTime+=100;
    assert(Math.abs(crop.w-before.w)<1e-7,'native drag never changes avatar size');
    assert(Math.abs((-crop.x/crop.w+before.x/before.w)*300+dx*nativeScale)<1e-7,'native drag relocates horizontally');
    assert(Math.abs((-crop.y/crop.w+before.y/before.w)*300+dy*nativeScale)<1e-7,'native drag relocates vertically');
    assert(Math.abs(stage.y-depth)<1e-7,'native drag preserves studio depth');
  }
  await ios.nativeCommand('go-upper-left');
  ios.avatarFixture.canvas.getBoundingClientRect=()=>({width:300,height:450});
  ios.frame.crop={x:25,y:50,w:250,h:375};
  for(let t=211000;t<241000;t+=33)ios.drawFrame(t);
  assert(stage.x<.05&&stage.y<.05,'keyboard/surface resize preserves the destination');
  assert(Math.abs(crop.w/crop.h-2/3)<1e-9,'keyboard resize preserves the displayed aspect');
  console.log('iOS studio integration: corner/closer/center, two-axis manual drag, pinch and keyboard resize passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});

for(const [width,height,dpr] of [[393,852,3],[852,393,3],[1024,1366,2]]){
  const normal=ios.mobileAvatarBudget(width,height,dpr), hot=ios.mobileAvatarBudget(width,height,dpr,{thermal:2});
  assert(width*height*normal.density**2<=1200001,'mobile render pixels are bounded independently of Retina density');
  assert(hot.density<=normal.density&&hot.interval>=normal.interval,'thermal pressure reduces GPU work');
}

// Full-duplex Live Talk: the production user-turn tracker and assistant
// disposition, driven by the packet order a GPT-Live call actually produces.
// The model keeps its audio active while it listens and answers at once, so
// without the session flag the reply is tombstoned as a late interrupted
// transcript and the requested motion never reaches the controller.
(() => {
  const grab = (start, end) => {
    const a = page.indexOf(start); const b = page.indexOf(end, a);
    assert(a >= 0 && b > a, 'production turn tracker must exist');
    return page.slice(a, b);
  };
  const canonical = page.match(/const canonicalWords = [^\n]*\n/)[0];
  const turnFns = grab('    const beginLiveTalkUserInput = ', '    const claimLiveTalkRPCRequest = ');
  const tia = new Map([['kung-fu-punch', {id:'kung-fu-punch', label:'Kung Fu Punch'}], ['wave', {id:'wave', label:'Wave', reactions:['greeting']}]]);
  const run = fullDuplex => {
    let now = 0;
    const ctx = {console, performance:{now:()=>now}, Date,
      turnController:null, turnControllerOrigin:null, agentSpeaking:false,
      reactiveMouthState:{}, currentViseme:'sil', resetLiveTalkTTSTimingState(){}, makeLiveTalkTTSTimingState:()=>({}),
      agentModeSelect:{disabled:false}, LIVE_TALK_DELEGATED_REPLY_EXPIRY_MS:45000,
      avatarPresented:()=>true, shell:null, live:null, avatar3d:null,
      speechExpressionTimeline:null, speechExpressionPlan:null,
      makeSpeechExpressionTimeline:()=>[], makeSpeechExpressionPlan:()=>({}), speechExpressionPlanAt:()=>({}),
      addMessage(){}, setStatus(){}, handleAvatarCommand:async()=>false, avatarCompanionAPI:{}};
    vm.createContext(ctx);
    vm.runInContext(companion + '\n' + canonical + '\n' + turnFns + '\n' + handler + `
      globalThis.controller = new CompanionController();
      globalThis.avatar3d = { companion: controller, motion: { clips: null } };
      globalThis.considerAvatarReaction = (user, reply, suggestion, turnID='') =>
        avatar3d.companion.consider(user, reply, suggestion, performance.now(), {clips: avatar3d.motion.clips, turnID});
      globalThis.receive = handleTranscript;`, ctx);
    ctx.avatar3d.motion.clips = tia;
    const session = {finalTranscriptIDs:new Set(), finalUserTurnSegments:[], userTurnClaimed:false,
      userTurnFinalSegmentIDs:new Set(), seenUserTranscriptSegments:new Set(), pendingUserTranscriptSegments:new Set(),
      userTurnOpen:false, latestFinalUserTranscript:'', lastUserFinalAt:-Infinity, assistantOutputSinceUser:false,
      agentSpeechGeneration:0, interruptedAgentSpeechGeneration:-1, expectedDelegatedAssistantReplies:[], ttsTimingState:{}, fullDuplex};
    ctx.live = session;
    const agent = {isAgent:true}, user = {isAgent:false};
    const speakers = on => { if (on && !ctx.agentSpeaking) session.agentSpeechGeneration += 1; ctx.agentSpeaking = on; };
    const A = (t, id, text, final) => { now = t; ctx.receive(session, [{id, text, final}], agent); };
    const U = (t, id, text, final) => { now = t; ctx.receive(session, [{id, text, final}], user); };
    now = 5000; speakers(true);
    A(5200, 'SG_greet', " Hi, it's Tia.", false);
    A(7600, 'SG_greet', " Hi, it's Tia. What's on your mind?", true);
    // the user answers while the greeting audio is still active; the agent
    // backchannels and replies without its audio ever going inactive
    [' Hi', ' Hi Tia, can you do a Kung Fu', ' Hi Tia, can you do a Kung Fu punch for me'].forEach((t, i) => U(10000 + i * 500, 'SG_user', t, false));
    A(12700, 'SG_reply', " Sure, I'll", false);
    U(13300, 'SG_user', ' Hi Tia, can you do a Kung Fu punch for me', true);
    A(13400, 'SG_reply', " Sure, I'll try a kung fu punch.", false);
    now = 15300; speakers(false);
    A(15400, 'SG_reply', " Sure, I'll try a kung fu punch.", true);
    now = 15500;
    return ctx.controller.takeReaction(now, tia, false, {hasProp:false});
  };
  assert.equal(run(false), 'wave', 'pipeline sessions keep treating speech over agent audio as a barge-in (stale greeting reaction only)');
  assert.equal(run(true), 'action:clip:kung-fu-punch', 'a full-duplex session must not tombstone the reply it is waiting for');
  console.log('Full-duplex Live Talk: a request spoken over active agent audio still drives the requested motion.');
})();
