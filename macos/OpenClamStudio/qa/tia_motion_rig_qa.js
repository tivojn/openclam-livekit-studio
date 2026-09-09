// Private-asset regression audit. No model or clip data is committed.
// node qa/tia_motion_rig_qa.js MODEL.glb BEFORE_MOTIONS AFTER_MOTIONS REPORT.json
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
(async()=>{
 const studio=path.resolve(__dirname,'..');
 const [modelPath,beforeDir,afterDir,reportPath]=process.argv.slice(2);
 assert(modelPath&&beforeDir&&afterDir&&reportPath,'Supply model, before/after motion directories and report path');
 let motionDir=afterDir;
 const THREE=await import(path.join(studio,'node_modules/three/build/three.module.js'));
 const file=fs.readFileSync(modelPath);const doc=JSON.parse(file.subarray(20,20+file.readUInt32LE(12)));
 const jointIds=new Set(doc.skins.flatMap(s=>s.joints)),byName=new Map();
 const nodes=doc.nodes.map((n,i)=>{const b=jointIds.has(i)?new THREE.Bone():new THREE.Group();b.name=n.name||'';b.userData.sourceName=b.name;
  if(n.matrix){b.matrix.fromArray(n.matrix);b.matrix.decompose(b.position,b.quaternion,b.scale);b.matrixAutoUpdate=false;}
  else {b.position.fromArray(n.translation||[0,0,0]);b.quaternion.fromArray(n.rotation||[0,0,0,1]);b.scale.fromArray(n.scale||[1,1,1]);b.updateMatrix();}
  byName.set(b.name,b);return b;});
 doc.nodes.forEach((n,i)=>(n.children||[]).forEach(j=>nodes[i].add(nodes[j])));
 const model=new THREE.Group();for(const i of doc.scenes[doc.scene||0].nodes)model.add(nodes[i]);model.updateMatrixWorld(true);
 class Renderer {setPixelRatio(){}setSize(){}setClearColor(){}render(){}}
 let time=0;
 const s={THREE:{...THREE,WebGLRenderer:Renderer},URL,Float32Array,performance:{now:()=>time},location:{href:'http://local/'},document:{createElement:()=>({})},window:{dispatchEvent(){}},Event:class{},console,
 fetch:async url=>({ok:true,json:async()=>JSON.parse(fs.readFileSync(path.join(motionDir,new URL(url).pathname.split('/').pop())))} )};
 const run=(file,exporter)=>vm.runInNewContext('(function(){'+fs.readFileSync(path.join(studio,'web',file),'utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\n'+exporter+'})();',s);
 run('avatar3d-options.js','globalThis.Avatar3DOptions=Avatar3DOptions;globalThis.mountAvatar3DOptions=mountAvatar3DOptions');
 run('avatar3d.js','globalThis.Avatar=Avatar3D;Avatar3D.prototype.lights=function(){}');
 run('avatar3d-motion.js','globalThis.Player=Avatar3DMotion');
 const avatar=new s.Avatar();avatar.model=model;avatar.root.add(model);avatar.collectBones();avatar.resolveChannels();
 avatar.options=new s.Avatar3DOptions(avatar,doc.extras.openclamAvatar);avatar.options.captureIdle();
 const positions=avatar.options.bones.map(b=>b.node.getWorldPosition(new THREE.Vector3()));avatar.bounds=new THREE.Box3().setFromPoints(positions);avatar.restBounds=avatar.bounds.clone();avatar.options.restBounds=avatar.bounds.clone();
 avatar.headRadius=avatar.bounds.getSize(new THREE.Vector3()).y*.075;avatar.headCenter=avatar.bones.head.getWorldPosition(new THREE.Vector3());avatar.restHeadCenter=avatar.headCenter.clone();avatar.headReferencePoint=new THREE.Vector3();avatar.frame();
 for(const side of ['l','r']){const eye=avatar.bones.eye[side];if(eye)avatar.eyeForward.set(eye,new THREE.Vector3(0,0,1).applyQuaternion(eye.getWorldQuaternion(new THREE.Quaternion()).invert()));}
 avatar.headForward=new THREE.Vector3(0,0,1).applyQuaternion(avatar.bones.head.getWorldQuaternion(new THREE.Quaternion()).invert());
 const rest=new Map(avatar.options.bones.map(b=>[b.name,b.node.getWorldQuaternion(new THREE.Quaternion())]));
 avatar.motion=new s.Player(avatar.options);await avatar.motion.load('/library.json');
 const delta=name=>byName.get(name).getWorldQuaternion(new THREE.Quaternion()).multiply(rest.get(name).clone().invert());
 const relative=()=>delta(avatar.bones.chest.name).invert().multiply(delta(avatar.bones.head.name)).angleTo(new THREE.Quaternion())*180/Math.PI;
 console.log('Driven bones',Object.fromEntries(['head','neck','chest','hips'].map(k=>[k,avatar.bones[k]?.name])));
 const report={modelSHA256:require('node:crypto').createHash('sha256').update(file).digest('hex'),clips:[],regressions:[]};
 const allNames=[...avatar.motion.clips.keys()];
 async function sample(id,{before=false,pose='',gaze=null}={}){
  motionDir=before?beforeDir:afterDir;avatar.motion.dispose();avatar.motion=new s.Player(avatar.options);await avatar.motion.load('/library.json');
  time=0;avatar.options.select({body:pose,playTransitions:'false',followCursor:gaze?undefined:'false'},0);avatar.options.update(1000);time=1000;
  const clip=await avatar.motion.prepare(id),duration=(clip.frames.length-1)/clip.fps*1000;
  await avatar.motion.play(id,{now:time,loop:false});
  const rows=[];
  for(time=1000;time<1000+duration+850;time+=16){
   avatar.render(time,{reduce:false,gaze:gaze||{x:0,y:0},breathe:1});
   assert(avatar.options.current.every(v=>v.m.elements.every(Number.isFinite)),id+' finite transforms');
   const elevations=['l','r'].map(side=>{const d=byName.get('toes_01.'+side).getWorldPosition(new THREE.Vector3()).sub(byName.get('foot.'+side).getWorldPosition(new THREE.Vector3()));return Math.atan2(d.y,Math.hypot(d.x,d.z))*180/Math.PI;});
   const toeElevations=['l','r'].map(side=>{
    const name='toes_01.'+side, bind=new THREE.Matrix4().set(...doc.extras.openclamAvatar.rest[name].flat());
    const direction=new THREE.Vector3(0,0,-1).transformDirection(bind).applyQuaternion(delta(name));
    return Math.atan2(direction.y,Math.hypot(direction.x,direction.z))*180/Math.PI;
   });
   rows.push({ms:time-1000,active:!!avatar.motion.active,head:relative(),elevations,toeElevations});
  }
  assert(!avatar.motion.active&&!avatar.options.transition,id+' finishes and returns to authored pose');
  const moving=rows.filter(r=>r.active&&r.ms>350);
  return {id,duration,maxHead:Math.max(...rows.map(r=>r.head)),exitHead:Math.max(...rows.filter(r=>!r.active).map(r=>r.head)),
   maxFootElevation:Math.max(...moving.flatMap(r=>r.elevations)),maxToeElevation:Math.max(...moving.flatMap(r=>r.toeElevations)),rows};
 }
 for(const id of allNames){
  const result=await sample(id);assert(result.maxHead<65,id+' head stays within torso-relative range: '+result.maxHead);
  if(id==='walk'||id==='wave')assert(result.maxToeElevation<45,id+' terminal SMPL-H display bones must not point the toes upwards');
  report.clips.push({...result,rows:undefined});
 }
 for(const id of ['kung-fu-punch','hello-run']){
  const before=await sample(id,{before:true}),after=await sample(id);
  if(id==='kung-fu-punch'){
   assert(before.maxHead>140,'reproduces original backward head');
   assert(after.maxHead<55&&after.exitHead<15,'punch ends without backward head');
  }else{
   assert(before.maxFootElevation>40,'reproduces upward-curling run foot');
   assert(after.maxFootElevation<5,'running foot no longer curls upwards');
  }
  report.regressions.push({id,before:{...before,rows:undefined},after:{...after,rows:undefined}});
 }
 for(const pose of ['', 'Ps001.heart'])for(const gaze of [{x:1,y:1},{x:-1,y:-1}]){
  const result=await sample('kung-fu-punch',{pose,gaze});
  assert(result.maxHead<90,'gaze never twists the head backward');
  assert(result.exitHead<45,'returns smoothly with gaze and selected pose');
  report.regressions.push({pose,gaze,...result,rows:undefined});
 }
 for(const id of ['walk','hello-run']){
  motionDir=afterDir;avatar.motion.stop({immediate:true});time=0;
  avatar.options.select({body:'',followCursor:'true',playTransitions:'false'},0);avatar.options.update(1000);
  time=1000;await avatar.motion.play(id,{now:time,loop:true});
  assert(avatar.motion.active.clip.forwardSpeed>.5&&avatar.motion.active.clip.forwardSpeed<5,id+' has measured stride speed');
  let maxHead=0,maxEye=0;
  for(time=1000;time<10000;time+=16){
   avatar.setOrbit({yaw:Math.sin(time/2500)*.2,pitch:0});
   avatar.render(time,{cameraFocus:true,gaze:{x:1,y:-1},lookTarget:new THREE.Vector3(-50,50,-50),breathe:1});
   if(time<1800)continue;
   const head=avatar.headForward.clone().applyQuaternion(avatar.bones.head.getWorldQuaternion(new THREE.Quaternion()));
   maxHead=Math.max(maxHead,head.angleTo(avatar.camera.position.clone().sub(avatar.headCenter).normalize())*180/Math.PI);
   for(const eye of Object.values(avatar.bones.eye)){
    const axis=avatar.eyeForward.get(eye).clone().applyQuaternion(eye.getWorldQuaternion(new THREE.Quaternion()));
    maxEye=Math.max(maxEye,axis.angleTo(avatar.camera.position.clone().sub(eye.getWorldPosition(new THREE.Vector3())).normalize())*180/Math.PI);
   }
  }
  assert(maxHead<12,id+' approaches with a camera-facing head: '+maxHead);
  assert(maxEye<1,id+' maintains optical eye contact: '+maxEye);
  report.regressions.push({id,cameraFocus:true,maxHeadError:maxHead,maxEyeError:maxEye});
 }
 // Sample three full locomotion loops, including interpolation and the seam.
 // The feet need clearance in the pelvis frame even while the body turns;
 // world-X alone gives false collisions when one foot is farther forward.
 for(const id of ['walk','hello-run']){
  const data=JSON.parse(fs.readFileSync(path.join(afterDir,id+'.json')));
  if(!data.retargeting?.gaitClearance)continue;
  motionDir=afterDir;avatar.motion.stop({immediate:true});time=0;
  avatar.setOrbit({yaw:0,pitch:0});
  avatar.options.select({body:'',followCursor:'false',playTransitions:'false'},0);avatar.options.update(1000);
  time=1000;await avatar.motion.play(id,{now:time,loop:true});
  const duration=(data.frames.length-1)/data.fps*1000, rows=[];
  const point=name=>byName.get(name).getWorldPosition(new THREE.Vector3());
  for(time=1400;time<1000+3*duration;time+=1000/60){
   avatar.render(time,{breathe:1,gaze:{x:0,y:0}});
   const axis=new THREE.Vector3(1,0,0).applyQuaternion(delta('root.x'));axis.y=0;axis.normalize();
   const left=point('foot.l'),right=point('foot.r');
   const torso=point('spine_05.x').sub(point('root.x'));
   const lean=Math.atan2(torso.z,torso.y)*180/Math.PI;
   const knees=['l','r'].map(side=>{
    const hip=point('c_thigh_stretch.'+side),knee=point('c_leg_stretch.'+side),ankle=point('foot.'+side);
    return 180-hip.sub(knee).angleTo(ankle.sub(knee))*180/Math.PI;
   });
   rows.push({gap:left.clone().sub(right).dot(axis),distance:left.distanceTo(right),lean,knees});
  }
  const minimumGap=Math.min(...rows.map(r=>r.gap)),minimumDistance=Math.min(...rows.map(r=>r.distance));
  const leanRange=[Math.min(...rows.map(r=>r.lean)),Math.max(...rows.map(r=>r.lean))];
  const kneeRanges=[0,1].map(side=>[Math.min(...rows.map(r=>r.knees[side])),Math.max(...rows.map(r=>r.knees[side]))]);
  assert(minimumGap>.12,id+' feet stay on separate sides throughout the loop: '+minimumGap);
  assert(minimumDistance>.14,id+' boot centers retain physical clearance: '+minimumDistance);
  for(const [min,max] of kneeRanges)assert(max-min>35&&max>60&&max<100,id+' knees continue flexing instead of locking');
  if(id==='walk')assert(leanRange[0]>-4.5&&leanRange[1]<5,'walking remains upright');
  else assert(leanRange[0]>5&&leanRange[1]<22,'running leans forward, never backward');
  report.regressions.push({id,gaitClearance:true,minimumGap,minimumDistance,leanRange,kneeRanges,samples:rows.length});
 }
 run('avatar3d-companion.js','globalThis.Stage=AvatarStudioStage;globalThis.Controller=CompanionController');
 for(const id of ['walk','hello-run']){
  avatar.motion.stop({immediate:true});time=0;avatar.options.select({body:'',followCursor:'false',playTransitions:'false'},0);avatar.options.update(1000);
  avatar.setOrbit({yaw:0,pitch:0});avatar.lockStudioLens();
  const layout=avatar.layout(),surface={x:0,y:0,width:1100,height:760},scale=300/layout.bounds[3];
  const stage=new s.Stage({scale,x:500-(layout.bounds[0]+layout.bounds[2]/2)*scale,y:400-(layout.bounds[1]+layout.bounds[3]/2)*scale},layout,surface);
  stage.calibrate(avatar);stage.entryWeight=0;stage.x=.4;stage.y=.5;
  const controller=new s.Controller();controller.command('go-upper-right');
  const ground=avatar.restBounds.getCenter(new THREE.Vector3());ground.y=avatar.restBounds.min.y;
  const screen=point=>{const p=avatar.project(point),fit=stage.project(surface);return {x:p.x*fit.scale+fit.x,y:p.y*fit.scale+fit.y};};
  time=1000;await avatar.motion.play(id,{loop:true,now:time});const speed=avatar.motion.active.clip.forwardSpeed;
  let maxError=0,samples=0;
  for(time=1000;time<37000;time+=16){
   const before=screen(ground),step=stage.step(controller,time,surface,{strideSpeed:speed});
   avatar.motion.setPlaybackRate(step.gaitRate,time);avatar.setOrbit({yaw:step.yaw,pitch:0});avatar.render(time,{breathe:1});
   const after=screen(ground),forward=screen(ground.clone().add(new THREE.Vector3(0,0,.01)));
   const x=after.x-before.x,y=after.y-before.y,fx=forward.x-after.x,fy=forward.y-after.y;
   if(Math.hypot(x,y)>1e-5){
    const angle=Math.acos(Math.max(-1,Math.min(1,(x*fx+y*fy)/(Math.hypot(x,y)*Math.hypot(fx,fy)))))*180/Math.PI;
    maxError=Math.max(maxError,angle);samples++;
    assert(step.gaitRate<1.16,'natural cadence caps movement and animation together');
   }
   if(!controller.destination)break;
  }
  assert(!controller.destination&&samples>100,id+' reaches the destination');
  assert(maxError<2,id+' visible gait points along the rendered ground path: '+maxError);
  report.regressions.push({id,screenTravel:true,maxProjectedHeadingError:maxError,samples});
 }
 // Use the real authored root translation, including the punch's long lunge.
 for(const [width,height] of [[1100,760],[393,680],[1600,980]]){
  avatar.motion.stop({immediate:true});time=0;avatar.options.select({body:'',playTransitions:'false',followCursor:'false'},0);avatar.options.update(1000);
  avatar.setOrbit({yaw:0,pitch:0});avatar.lockStudioLens();
  const layout=avatar.layout(),surface={x:30,y:60,width,height},scale=height*.68/layout.bounds[3];
  const fit={scale,x:surface.x+width*.9-(layout.bounds[0]+layout.bounds[2]/2)*scale,y:surface.y+height*.1-layout.bounds[1]*scale};
  time=1000;await avatar.motion.play('kung-fu-punch',{now:time,loop:false});let samples=0;
  for(time=1000;time<8600;time+=16){
   avatar.prepareMotionFrame(time,false);
   const adjusted=avatar.keepMotionInViewport(fit,surface);
   avatar.render(time,{breathe:1});
   // Measure the prepared pose before rendering, as both production hosts do.
   const points=avatar.options.bones.map(b=>avatar.project(b.node.getWorldPosition(new THREE.Vector3())));
   const span=(Math.max(...points.map(p=>p.x))-Math.min(...points.map(p=>p.x)))*scale;
   const checked=span+avatar.height*scale*.05<=width?points:[avatar.bones.head,avatar.bones.chest,avatar.bones.hips].map(n=>avatar.project(n.getWorldPosition(new THREE.Vector3())));
   for(const p of checked){const x=adjusted.x+p.x*scale,y=adjusted.y+p.y*scale;
    assert(x>=surface.x-8&&x<=surface.x+width+8,'punch cannot disappear horizontally: '+JSON.stringify({width,time,x}));
    assert(y>=surface.y-8&&y<=surface.y+height+8,'punch keeps its body inside the available height: '+JSON.stringify({width,height,time,y,adjusted}));
   }
   assert.equal(adjusted.scale,scale,'containment never shrinks the performer');samples++;
  }
  report.regressions.push({motion:'kung-fu-punch',containment:true,width,height,samples});
 }
 fs.writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
 console.log('PASS',allNames.length,'real Tia clips, punch endings, authored pose returns, gaze extremes, and running foot regression');
})().catch(e=>{console.error(e);process.exitCode=1;});
