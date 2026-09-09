'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {companionStep}=require('../electron/companion-move.cjs');
const near=(a,b,label)=>assert(Math.abs(a-b)<1e-7,`${label}: ${a} != ${b}`);
(async()=>{
  const THREE=await import('three');
  class Renderer{setPixelRatio(){}setSize(){}setClearColor(){}render(){}}
  const scene=new THREE.Scene();
  const model=new THREE.Mesh(new THREE.BoxGeometry(.5,2,.25),new THREE.MeshStandardMaterial());
  scene.add(model);
  const s={THREE:{...THREE,WebGLRenderer:Renderer},document:{createElement:()=>({})},
    window:{dispatchEvent(){}},Event:class{},GLTFLoader:class{async loadAsync(){return {scene,parser:{json:{nodes:[]},associations:new Map()}};}}};
  vm.runInNewContext(fs.readFileSync('web/avatar3d-options.js','utf8').replace(/^import .*;$/gm,'').replace(/export /g,''),s);
  vm.runInNewContext(fs.readFileSync('web/avatar3d.js','utf8').replace(/^import .*;$/gm,'')+'\nAvatar3D.prototype.lights=function(){};',s);
  vm.runInNewContext(fs.readFileSync('web/avatar3d-companion.js','utf8').replace(/export /g,'')+'\nglobalThis.Stage=AvatarStudioStage;globalThis.destinations=stageDestinations;globalThis.Controller=CompanionController;globalThis.intent=avatarIntent;globalThis.replyAction=replyAvatarAction;',s);
  const avatar=s.window.OpenClamAvatar3D.create();await avatar.load('fixture.glb');
  avatar.headRadius=.12;avatar.headCenter=new THREE.Vector3(0,1.8,0);avatar.restHeadCenter=avatar.headCenter.clone();avatar.restFaceCenter=avatar.headCenter.clone();avatar.frame();
  const cameraBefore=avatar.camera.matrixWorld.toArray(),layoutBefore=JSON.stringify(avatar.layout());
  const originalBounds=avatar.bounds.clone(),scale=model.scale.toArray();
  for(const extent of [2,5,10,1]){
    avatar.bounds=originalBounds.clone().expandByScalar(extent);avatar.frame();
    assert.deepEqual(avatar.camera.matrixWorld.toArray(),cameraBefore,'raised arms, kicks and motion bounds never zoom the camera');
    assert.equal(JSON.stringify(avatar.layout()),layoutBefore,'motion bounds never change compositor framing');
  }
  avatar.bounds=originalBounds.clone();
  const start={x:-400,y:-100,w:1800,h:1350};
  const pos=avatar.camera.position.clone();
  assert(avatar.approachCamera('closer',1000,start));
  const first=avatar.approachFrame(1000);near(first.camera.position.distanceTo(pos),0,'no jump at start');
  assert.deepEqual(JSON.parse(JSON.stringify(first.view)),start);
  const faceFraction=frame=>{
    const a=avatar.headCenter.clone().add(new THREE.Vector3(-.12,0,0)).project(frame.camera);
    const b=avatar.headCenter.clone().add(new THREE.Vector3(.12,0,0)).project(frame.camera);
    return Math.abs(b.x-a.x)*avatar.width/2/frame.view.w*Math.max(1,frame.view.w/frame.view.h);
  };
  let fraction=faceFraction(first);
  for(let t=1032;t<8000;t+=32){const frame=avatar.approachFrame(t);const next=faceFraction(frame);assert(next>=fraction-1e-8,'approach grows continuously');fraction=next;}
  near(fraction,.82,'first approach fills the limiting dimension without cropping the face');
  const arrived=avatar.approachFrame(8000);
  avatar.approachCamera('closer',8000,arrived.view);
  near(faceFraction(avatar.approachFrame(8000)),fraction,'repeated closer begins at the current size');
  const second=avatar.approachFrame(15000);assert(faceFraction(second)>fraction);
  near(faceFraction(second),.96,'second closer tightens the view');
  avatar.approachCamera('back',15000,second.view);
  const middle=avatar.approachFrame(15700);
  avatar.approachCamera('closer',15700,middle.view);
  near(faceFraction(avatar.approachFrame(15700)),faceFraction(middle),'mid-walk direction change does not jump');
  avatar.stopCameraApproach(16200);const stopped=avatar.approachFrame(16200);
  near(faceFraction(avatar.approachFrame(90000)),faceFraction(stopped),'stay freezes the current distance');
  avatar.resetCameraApproach();avatar.approachCamera('closer',100000,start);
  avatar.approachFrame(100500,{reduce:true});const reduced=avatar.approachFrame(100500);
  near(faceFraction(avatar.approachFrame(110000)),faceFraction(reduced),'Reduce Motion freezes travel');
  for(const aspect of [.46,1,1.8]){
    const f=avatar.approachFrame(110000,{aspect,zoom:1.25,panX:25,panY:-12});
    near(f.view.w/f.view.h,aspect,'window/keyboard changes preserve aspect');
    avatar.applyView({...f.view,pixelWidth:aspect*800,pixelHeight:800});
    const center=avatar.headCenter.clone().project(avatar.camera);
    const x=avatar.headCenter.clone().add(new THREE.Vector3(.01,0,0)).project(avatar.camera);
    const y=avatar.headCenter.clone().add(new THREE.Vector3(0,.01,0)).project(avatar.camera);
    near(Math.abs(x.x-center.x)*aspect,Math.abs(y.y-center.y),'face and hair cannot be squashed');
  }
  assert.deepEqual(model.scale.toArray(),scale,'locomotion leaves authored geometry scale unchanged');
  avatar.resetCameraApproach();
  const normalCamera=avatar.camera.clone();normalCamera.clearViewOffset();normalCamera.updateProjectionMatrix();
  const normalSize=faceFraction({camera:normalCamera,view:start});
  assert(avatar.approachCamera('back',120000,start),'step back can move farther than the normal position');
  const farther=avatar.approachFrame(130000);assert(faceFraction(farther)<normalSize*.8,'farther actors appear smaller through perspective');
  avatar.approachCamera('closer',130000,farther.view);
  near(faceFraction(avatar.approachFrame(140000)),normalSize,'returning to the original depth restores the normal size');
  for(const [user,action] of [['can u run around?','run-around'],['can u move around the screen','walk-around'],['closer again','closer'],['come even closer','closer'],['step back','back']]){
    assert.equal(s.intent(user),action,user);
    assert.equal(s.replyAction(user,'',null,new Map()),null,'input alone never starts movement');
    assert.equal(s.replyAction(user,"I'll do that.",null,new Map()),'action:'+action);
    assert.equal(s.replyAction(user,"I'll explain how it works.",'none',new Map()),null);
  }
  assert.equal(s.replyAction('run around',"I'll run tests.",null,new Map()),null);
  const repeated=new s.Controller();
  for(const id of ['one','two']){repeated.consider('closer',"I'll come closer.",null,1000,{turnID:id});assert.equal(repeated.takeReaction(1001,new Map()),'action:closer');}
  repeated.consider('closer',"I'll come closer.",null,1002,{turnID:'two'});assert.equal(repeated.takeReaction(1003,new Map()),null);
  repeated.command('stay');
  repeated.consider('closer',"I'll come closer.",null,1100,{turnID:'after-stop'});
  assert.equal(repeated.takeReaction(1101,new Map()),'action:closer','stopping automatic motions does not block a later LLM-led request');
  let seed=42;const random=()=>((seed=(1664525*seed+1013904223)>>>0)/4294967296);
  for(const mode of ['walk-around','run-around']){
    const c=new s.Controller({random});c.command(mode);let x=500,y=350,minX=x,maxX=x,minY=y,maxY=y,arrivals=0;
    for(let t=1000;t<90000;t+=32){const f=c.step(t,{anchorX:x,anchorY:y,minX:100,maxX:900,minY:80,maxY:620,height:300,seen:false});
      x+=f.dx;y+=f.dy;assert(x>=100&&x<=900&&y>=80&&y<=620,'roaming stays within the available surface');
      minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);arrivals+=f.arrived?1:0;
    }
    assert(maxX-minX>550&&maxY-minY>300&&arrivals>2,'roaming chooses multiple destinations on both axes without a pointer');
    c.pause(90001);assert(!c.roam,'manual drag cancels the route');
    assert.equal(c.step(90032,{anchorX:x,anchorY:y,cursorX:0,cursorY:0}).dx,0);
  }
  const speeds=[];
  for(const mode of ['walk-around','run-around']){const c=new s.Controller({random:()=>1});c.command(mode);let x=100,y=80;for(let t=1000;t<2000;t+=32){const f=c.step(t,{anchorX:x,anchorY:y,minX:100,maxX:900,minY:80,maxY:620,height:300});x+=f.dx;y+=f.dy;}speeds.push(Math.hypot(x-100,y-80));}
  assert(speeds[1]>speeds[0]*2,'running travels faster with the running gait');
  // Production stage projection: the entire vertical range owns perspective
  // distance. Same depth has identical size for every pose, route and side.
  const surface={x:220,y:70,width:1000,height:700};
  const layout={bounds:[250,60,520,1400],faceBounds:[400,110,230,220]};
  const initial={scale:.36,x:540-510*.36,y:420-760*.36};
  const stage=new s.Stage(initial,layout,surface);
  near(stage.project(surface).scale,initial.scale,'stage entry preserves size');
  near(stage.project(surface).x,initial.x,'stage entry preserves x');
  near(stage.project(surface).y,initial.y,'stage entry preserves y');
  const middleScale=stage.normalRatio*surface.height;
  let size=0;
  for(let y=0;y<=1;y+=.01){stage.y=y;const fit=stage.project(surface);assert(fit.scale>=size,'lower is continuously larger');size=fit.scale;}
  stage.y=.5;near(stage.project(surface).scale,middleScale,'middle is normal size');
  for(const x of [.04,.5,.96]){stage.x=x;near(stage.project(surface).scale,middleScale,'horizontal movement preserves distance');}
  // An approaching actor grows below the frame while the crown stays visible.
  for(const [width,height] of [[393,680],[1000,700],[1600,900]]){
    const viewport={x:50,y:70,width,height};
    const shot=new s.Stage({scale:height/1800,x:0,y:0},layout,viewport);
    shot.entryWeight=0;shot.x=.5;
    shot.crownAt=()=>layout.bounds[1]+45; // real hair is below the empty corner of its 3D box
    let priorFeet=-Infinity;
    for(let depth=.5;depth<=1;depth+=.005){
      shot.y=depth;const f=shot.project(viewport),crown=f.y+shot.crownAt()*f.scale;
      const feet=f.y+(layout.bounds[1]+layout.bounds[3])*f.scale;
      assert(crown>=viewport.y-1e-7,'approach never crops the crown');
      assert(feet>=priorFeet-1e-7,'approach advances feet downward rather than reversing the apparent gait');priorFeet=feet;
      if(layout.bounds[3]*f.scale>height){
        assert(crown<=viewport.y+height*.04,'close-up anchors the head at the upper edge, not the bottom');
        if((layout.bounds[1]+layout.bounds[3]-shot.crownAt())*f.scale>height)
          assert(feet>viewport.y+height,'the lower body, not the head, leaves the frame');
      }
    }
  }
  const travelTo=(action,begin)=>{
    const c=new s.Controller();c.command(action);c.destination=stage.destination(action,surface);
    for(let t=begin;t<begin+60000;t+=32){stage.step(c,t,surface);if(!c.destination)return;}
    assert.fail('destination did not settle: '+action);
  };
  // An approach/retreat must not stop and turn again after the initial turn.
  // Exercise the full-body/crown handoff, the middle-distance boundary and
  // saved placements that require a camera adjustment on the first walk.
  for(const [width,height] of [[393,680],[1100,760],[1600,980]])for(const fps of [30,60])
    for(const ratio of [.4,.72,.95])for(const offset of [-.12,0,.2]){
      const area={x:40,y:60,width,height},scale=height*ratio/layout.bounds[3];
      const shot=new s.Stage({scale,x:area.x+width*.35-510*scale,
        y:area.y+height*(.5+offset)-760*scale},layout,area);
      shot.crownAt=()=>layout.bounds[1]+45;
      const c=new s.Controller();let at=1000;
      for(const action of ['closer','back','back','back','closer']){
        c.command(action);c.destination=shot.destination(action,area);
        const goal=c.destination.y,direction=Math.sign(goal-shot.y);let moving=false;
        for(let frames=0;frames<fps*90;frames++,at+=1000/fps){
          const y=shot.y,step=shot.step(c,at,area),progress=(shot.y-y)*direction;
          assert(progress>=-1e-9,'camera reframing cannot reverse studio travel');
          if(moving&&step.walking)assert(progress>1e-9&&step.gaitRate>0,
            'no halfway pause or U-turn: '+JSON.stringify({width,height,fps,ratio,offset,action,y,step}));
          if(progress>1e-7)moving=true;
          if(!c.destination)break;
        }
        assert(!c.destination,'approach and retreat finish across framing/depth boundaries');
        assert(Math.abs(shot.y-goal)<.006,'arrive at the requested depth');
      }
    }
  for(const [action,target] of Object.entries(s.destinations)){
    travelTo(action,200000);
    assert(Math.abs(stage.x-target.x)<.006&&Math.abs(stage.y-target.y)<.006,'arrive directly without cursor: '+action);
    assert.equal(s.replyAction('can u go to the upper right corner?',"I'll go to the upper-right corner.",null,new Map()),'action:go-upper-right');
  }
  travelTo('closer',300000);const close=stage.project(surface).scale;
  travelTo('go-upper-right',400000);assert(stage.project(surface).scale<close*.2,'close-up walks to far corner and becomes small');
  travelTo('go-center',500000);assert(Math.abs(stage.project(surface).scale/middleScale-1)<.02,'returning to center restores normal size');
  const stable=stage.project(surface);
  // Manual drag is two-dimensional placement at a fixed displayed size,
  // including after coming close. Only an actual pinch changes the scale.
  for(const depth of [.2,.5,.9]){
    const placed=new s.Stage(initial,layout,surface);placed.y=depth;placed.entryWeight=0;
    let input={...initial};placed.manualFit=input;
    for(const [dx,dy] of [[0,80],[0,-120],[140,0],[-60,50]]){
      const before=placed.project(surface),previousDepth=placed.y;
      input={...input,x:input.x+dx,y:input.y+dy};placed.manual(input,surface);
      const after=placed.project(surface);
      near(after.x-before.x,dx,'drag follows horizontal displacement');
      near(after.y-before.y,dy,'drag follows vertical displacement');
      near(after.scale,before.scale,'drag never changes displayed size');
      near(placed.y,previousDepth,'drag does not walk to a different studio depth');
      placed.manual(input,surface);near(placed.project(surface).y,after.y,'stationary native frames do not drift');
    }
    const before=placed.project(surface);input={...input,scale:input.scale*1.2};placed.manual(input,surface);
    near(placed.project(surface).scale/before.scale,1.2,'pinch remains an explicit resize');
  }
  // Check actual displacement against the displayed heading on every frame,
  // including reversals and diagonals at different perspective distances.
  const turning=new s.Controller(),aligned=new s.Stage(initial,layout,surface);
  avatar.resetCameraApproach();avatar.setOrbit({yaw:0,pitch:0});
  avatar.lockStudioLens();
  aligned.calibrate(avatar);
  aligned.entryWeight=0; // measure gait after the separate initial camera adjustment
  const ground=avatar.restBounds.getCenter(new THREE.Vector3());ground.y=avatar.restBounds.min.y;
  const screen=(point=ground)=>{const p=avatar.project(point),fit=aligned.project(surface);return {x:p.x*fit.scale+fit.x,y:p.y*fit.scale+fit.y};};
  let at=700000,translated=0,turnFrames=0;
  for(const destination of ['go-right','go-upper-left','go-bottom','go-upper-right','closer']){
    turning.command(destination);turning.destination=aligned.destination(destination,surface);
    const until=at+5000;
    for(;at<until;at+=16){
      const before=screen(),oldYaw=avatar.orbit.yaw;
      const f=aligned.step(turning,at,surface,{strideSpeed:1.4});avatar.setOrbit({yaw:f.yaw,pitch:0});const after=screen();
      const x=after.x-before.x,y=after.y-before.y,length=Math.hypot(x,y);
      assert(Math.abs(Math.atan2(Math.sin(f.yaw-oldYaw),Math.cos(f.yaw-oldYaw)))<=2.8*.016+1e-6,'turn rate is bounded across +/- pi');
      if(length>1e-5){
        const forward=screen(ground.clone().add(new THREE.Vector3(0,0,.001)));
        const fx=forward.x-after.x,fy=forward.y-after.y,flen=Math.hypot(fx,fy);
        const dot=(fx*x+fy*y)/(flen*length);
        assert(dot>.999,`visible stride agrees with the rendered path: ${JSON.stringify({dot,destination,x,y,f})}`);
        assert(Math.abs(length/.016/(flen/.001*1.4)-f.gaitRate)<.05,'cadence follows the rendered ground speed');translated++;
      }else if(f.walking)turnFrames++;
    }
  }
  assert(translated>500&&turnFrames>10,'exercise movement and turning before translation');
  assert(turning.cameraFocus,'come closer attends to the camera');
  turning.pause(at);assert(!turning.cameraFocus,'manual control releases eye contact');
  turning.command('closer');turning.command('follow');assert(!turning.cameraFocus,'a new cursor request releases camera attention');
  const manual=new s.Controller();manual.command('go-upper-left');manual.pause(600000);
  stage.step(manual,610000,surface);near(stage.project(surface).scale,stable.scale,'drag cancels destination and preserves depth');
  const cues=['can u go to the upper right corner','walk to the top-left of the chat window','move to the bottom right corner','head to the center'];
  for(const [i,action] of ['go-upper-right','go-upper-left','go-lower-right','go-center'].entries()){
    assert.equal(s.intent(cues[i]),action,cues[i]);assert.equal(s.replyAction(cues[i],'',null,new Map()),null);
    assert.equal(s.replyAction(cues[i],"I'll do that.",null,new Map()),'action:'+action);
    assert.equal(s.replyAction(cues[i],"I cannot do that.",'action:'+action,new Map()),null);
  }
  assert.equal(s.replyAction('upper right',"Move your cursor to the upper-right corner, and I'll follow it.",'none',new Map()),null);
  const b={x:400,y:300,width:200,height:400},area={x:0,y:0,width:1600,height:1000};
  assert.equal(companionStep(b,area,100,0,100,undefined,true).x,434);
  assert.equal(companionStep(b,area,100,0,100,undefined,'true').x,420,'unvalidated values cannot raise native speed');
  const page=fs.readFileSync('web/index.html','utf8');
  const receiver=page.match(/const receiveSharedLiveFrame = frame => \{[\s\S]*?\n    \};/)[0];
  const commands=[],peerClips=[];
  const peer={live:null,sharedLivePhase:'connected',peerLiveFrame:null,peerMotionKey:'',peerActionKey:'',
    document:{hidden:true},performance:{now:()=>5000},notify:assert.fail,
    avatar3d:{companion:{},motion:{clips:new Map([['wave',{}]]),play:async id=>peerClips.push(id),stop(){}}},
    performAvatarAction:async action=>commands.push(action)};
  vm.createContext(peer);vm.runInContext(receiver+'\nglobalThis.receive=receiveSharedLiveFrame;',peer);
  const packet={action:{key:'first',action:'run-around'},motion:{key:'walk:1',id:'walk'}};
  peer.receive(packet);assert.equal(commands.length,0,'hidden peer does not open or move another mode');
  peer.document.hidden=false;peer.receive(packet);peer.receive(packet);
  assert.deepEqual(commands,['run-around'],'visible Live Talk peer follows each spatial intention once');
  assert.equal(peerClips.length,0,'peer owns its gait and route instead of replaying the owner in place');
  peer.receive({action:{key:'second',action:'closer'}});assert.deepEqual(commands,['run-around','closer']);
  peer.receive({action:{key:'third',action:'open-url'}});assert.equal(commands.length,2);
  peer.live={};peer.receive({action:{key:'fourth',action:'back'}});assert.equal(commands.length,2,'call owner cannot consume its own relay');
  console.log('Locomotion: stable framing, continuous perspective approach, repeated/back/stay, aspect, LLM routing, varied bounded routes and running speed passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
