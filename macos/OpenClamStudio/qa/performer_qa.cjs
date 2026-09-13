'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {EventEmitter}=require('node:events');
(async()=>{
 const THREE=await import('three'),sandbox={THREE,performance};
 vm.createContext(sandbox);
 vm.runInContext(fs.readFileSync('web/performer-rig.js','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\nglobalThis.Rig=PerformerRig;globalThis.rotation=headRotation;globalThis.eyeDirection=eyeDirection;globalThis.armRotations=armRotations;globalThis.wristRotation=wristRotation;globalThis.BlinkDriver=BlinkDriver;globalThis.faceContactWeight=faceContactWeight;globalThis.shoulderRotation=shoulderRotation;globalThis.handHeadDepth=handHeadDepth;globalThis.expressionWeight=expressionWeight;',sandbox);
 const root=new THREE.Group(),model=new THREE.Group();root.add(model);
 const bone=(name,p,parent=model)=>{const n=new THREE.Bone();n.name=name;n.position.fromArray(p);parent.add(n);return n;};
 const head=bone('head.x',[0,1.6,0]),hair=bone('hair',[0,.2,0],head);
 const mouth=bone('c_lips_bot.x',[0,-.03,.1],head);
 bone('neck.x',[0,1.5,0]);bone('spine_03.x',[0,1.2,0]);
 const clavicle=bone('shoulder.l',[.04,1.45,0]);
 const upper=bone('c_arm_twist.l',[.2,1.45,0]);
 const twist=bone('c_arm_stretch.l',[.23,1.31,0]);
 const lower=bone('c_forearm_stretch.l',[.3,1.1,0]);
 const hand=bone('hand.l',[.34,.78,0]);
 const fingers=[];
 for(const [i,name] of ['index','middle','ring','pinky','thumb'].entries()){
  const base=name==='thumb'?hand:bone('c_'+name+'1_base.l',[(i-1.5)*.018,-.015,0],hand);
  const first=bone(name+'1.l',name==='thumb'?[.035,-.02,.01]:[0,-.06,0],base);
  const second=bone('c_'+name+'2.l',[0,-.035,0],first);
  const third=bone('c_'+name+'3.l',[0,-.025,0],second);
  fingers.push({base,first,second,third,length:first.position.length()});
 }
 const mesh={morphTargetDictionary:{eyeBlinkLeft:0,jawOpen:1,wardrobe:2},morphTargetInfluences:[0,0,.6]};
 const avatar={model,root,bones:{head},morphMeshes:[mesh],restBounds:new THREE.Box3(new THREE.Vector3(-.5,0,-.1),new THREE.Vector3(.5,1.8,.1))};
 const rig=new sandbox.Rig(avatar),pose=Array.from({length:33},()=>({x:0,y:0,z:0,visibility:0}));
 pose[11]={x:.2,y:-1.45,z:0,visibility:1};pose[13]={x:.55,y:-1.45,z:0,visibility:1};pose[15]={x:.55,y:-1.8,z:0,visibility:1};
 const matrix=new THREE.Matrix4().makeRotationY(.4).toArray();
 for(let t=0;t<1800;t+=33){rig.receive({face:true,blendshapes:{eyeBlinkLeft:1,jawOpen:.7},matrix,pose},t);rig.update(t);}
 const p=n=>n.getWorldPosition(new THREE.Vector3());
 const a=p(upper),b=p(lower),c=p(hand);
 assert.ok(b.x>a.x+.3&&Math.abs(b.y-a.y)<.001,'upper arm aims horizontally toward tracked elbow');
 assert.ok(c.y>b.y+.3&&Math.abs(c.x-b.x)<.001,'flat hand follows bent forearm');
 assert.ok(Math.abs(a.distanceTo(b)-Math.hypot(.1,.35))<1e-5,'upper-arm length is preserved');
 assert.ok(Math.abs(b.distanceTo(c)-Math.hypot(.04,.32))<1e-5,'forearm length is preserved');
 assert.ok(p(twist).x>.25,'twist chain follows the same segment');
 assert.ok(a.y>1.49,'a raised arm lifts the shoulder instead of pinching at a fixed pivot');
 assert.ok(Math.abs(p(clavicle).distanceTo(a)-.16)<1e-6,'clavicle length stays authored');
 assert.ok(mesh.morphTargetInfluences[0]>.99&&mesh.morphTargetInfluences[1]>.8,'speech boost makes the jaw more readable while full blinks remain independent');
 assert.equal(mesh.morphTargetInfluences[2],.6,'non-facial fit channels remain authored');
 assert.ok(Math.abs(p(hair).distanceTo(p(head))-.2)<1e-6,'hair remains attached to the moving head');
 // Exercise tracked fingers after the flat wrist has moved. Child world
 // matrices must be current before solving, even with matrixAutoUpdate=false.
 const image=Array.from({length:33},()=>({x:.5,y:.4,z:0}));
 const landmarks=Array.from({length:21},(_,i)=>({x:(Math.floor((i-1)/4)-1.5)*.018,y:-.025*(1+(i-1)%4),z:0}));
 landmarks[0]={x:0,y:0,z:0};
 const tracked={world:landmarks,image:image.slice(0,21)};
 for(let t=1800;t<3000;t+=33){rig.receive({pose,poseImage:image,hands:[tracked]},t);rig.update(t);}
 for(const finger of fingers){
  assert.ok(Math.abs(p(finger.first).distanceTo(p(finger.base))-finger.length)<1e-5,'finger base stays attached to the raised palm');
  assert.ok(Math.abs(p(finger.second).distanceTo(p(finger.first))-.035)<1e-5,'proximal finger length stays fixed');
  assert.ok(Math.abs(p(finger.third).distanceTo(p(finger.second))-.025)<1e-5,'distal finger length stays fixed');
 }
 // Contact retargeting uses Tia's proportions, rather than copying the
 // performer's elbow angles and leaving a hand beside the face.
 const facePoints={mouth:{x:.5,y:.4},left:{x:.44,y:.32},right:{x:.56,y:.32}};
 for(let t=3000;t<5000;t+=33){rig.receive({face:true,matrix,pose,poseImage:image,hands:[tracked],facePoints},t);rig.update(t);}
 const palm=p(hand).lerp(p(fingers[1].first),.5),contact=p(mouth).add(new THREE.Vector3(0,0,rig.faceClearance).applyQuaternion(rig.head));
 assert.ok(palm.distanceTo(contact)<.004,'hand over the mouth maps to Tia’s mouth with surface clearance');
 for(let t=5000;t<5300;t+=33){rig.receive({face:false,pose:[],hands:[]},t);rig.update(t);}
 assert.ok(p(hand).lerp(p(fingers[1].first),.5).distanceTo(palm)<.004,'brief face and wrist occlusion holds the hand at the mouth');
 // A behind-head wrist can remain reachable even when fingers are hidden.
 const behindPose=pose.map(p=>({...p}));
 behindPose[7]={x:.08,y:-1.7,z:0,visibility:1};behindPose[8]={x:-.08,y:-1.7,z:0,visibility:1};
 behindPose[12]={x:-.2,y:-1.45,z:0,visibility:1};
 behindPose[13]={x:.40,y:-1.8,z:0,visibility:1};
 behindPose[15]={x:0,y:-1.72,z:.12,visibility:.4};
 const behindImage=image.map(p=>({...p}));behindImage[15]={x:.5,y:.3,z:0};
 for(let t=5300;t<6800;t+=33){rig.receive({face:true,matrix:new THREE.Matrix4().toArray(),facePoints,pose:behindPose,poseImage:behindImage,hands:[]},t);rig.update(t);}
 assert.ok(p(hand).z<p(head).z-.08,'occluded wrist goes behind the head instead of snapping to the front face plane');
 const back=p(hand);
 for(let t=6800;t<7100;t+=33){rig.receive({face:false,pose:[],hands:[]},t);rig.update(t);}
 assert.ok(back.distanceTo(p(hand))<.005,'brief occlusion holds the behind-head reach');
 behindPose[15].z=-.14;behindPose[15].visibility=1;
 for(let t=7100;t<8200;t+=33){rig.receive({face:true,matrix:new THREE.Matrix4().toArray(),facePoints,pose:behindPose,poseImage:image,hands:[tracked]},t);rig.update(t);}
 assert.equal(rig.arms.l.behind,false,'bringing the hand forward releases behind-head hysteresis');
 assert.ok(p(hand).lerp(p(fingers[1].first),.5).distanceTo(p(mouth).add(new THREE.Vector3(0,0,rig.faceClearance)))<.004,'front contact still lands at the mouth');
 rig.receive({face:true,matrix,blendshapes:{}},8300);
 assert.equal(rig.calibrate(),true);
 const q=sandbox.rotation(matrix,rig.neutral);assert.ok(q.angleTo(new THREE.Quaternion())<1e-6);
 rig.stop();for(let t=8400;t<11900;t+=33)rig.update(t);
 assert.ok(p(hand).distanceTo(new THREE.Vector3(.34,.78,0))<.001,'tracking loss relaxes to rest without accumulated transforms');
 assert.ok(mesh.morphTargetInfluences[0]<.001,'lost face releases a blink');
 assert.ok(sandbox.rotation([NaN],null).angleTo(new THREE.Quaternion())<1e-6);

 for(let t=13000;t<14600;t+=100){rig.receive({face:true,blendshapes:{eyeBlinkLeft:t===13400?.95:.38,eyeBlinkRight:t===13400?.95:.27},matrix},t);rig.update(t);}
 assert.ok(mesh.morphTargetInfluences[0]<.015,'startup calibration learns naturally narrow eyes despite one intervening blink');
 rig.receive({face:true,blendshapes:{eyeBlinkLeft:.93,eyeBlinkRight:.91},matrix},14633);rig.update(14633);
 assert.equal(mesh.morphTargetInfluences[0],1,'full blink is preserved after personal calibration');
 rig.stop();rig.receive({face:true,blendshapes:{eyeBlinkLeft:1,eyeBlinkRight:1},matrix},15000);
 assert.equal(rig.calibrateEyes(),false,'a single closed-eye sample cannot replace neutral calibration');
 const restUpper=new THREE.Vector3(.2,-1,0),restLower=new THREE.Vector3(.1,-.9,.2);
 const raisedUpper=new THREE.Vector3(.8,-.4,.3),raisedLower=new THREE.Vector3(0,.9,.3);
 const rotations=sandbox.armRotations(restUpper,restLower,raisedUpper,raisedLower);
 const normal=new THREE.Vector3().crossVectors(restUpper,restLower).normalize();
 const wantedNormal=new THREE.Vector3().crossVectors(raisedUpper,raisedLower).normalize();
 assert.ok(normal.clone().applyQuaternion(rotations.upper).dot(wantedNormal)>.999,'humerus uses the measured bend plane');
 assert.ok(normal.clone().applyQuaternion(rotations.lower).dot(wantedNormal)>.999,'elbow bends in the same plane without axial counter-twist');
 const requested=new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1,0,0),1.8)
  .multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0,1,0),1.5));
 const wrist=sandbox.wristRotation(new THREE.Quaternion(),requested,new THREE.Vector3(0,1,0));
 assert.ok(Math.abs(wrist.twist.angleTo(new THREE.Quaternion())-1.5)<1e-6,'pronation is separated for the forearm twist chain');
 assert.ok(Math.abs(wrist.hand.clone().multiply(wrist.twist.clone().invert()).angleTo(new THREE.Quaternion())-Math.PI/3)<1e-6,'wrist bend is limited independently of forearm roll');
 const blink=new sandbox.BlinkDriver();
 assert.equal(blink.update(.02,100,33),0,'open eyes remain open');
 assert.equal(blink.update(.55,133,33),1,'a partial-confidence webcam blink fully closes the avatar eyelid');
 assert.equal(blink.update(.02,166,33),1,'brief detected closure survives the next tracking sample');
 assert.ok(blink.update(.02,350,100)<.15,'blink reopens promptly');
 assert.ok(blink.update(1,450,100,false)<.02,'lost face does not latch the eyes closed');
 assert.equal(sandbox.faceContactWeight(facePoints,{x:.5,y:.24}),1,'forehead contact is covered, not just mouth contact');
 assert.equal(sandbox.faceContactWeight(facePoints,{x:.9,y:.3}),0,'a hand away from the face is not pulled onto it');

 // Naturally narrow eyes are neutral, while a deliberate blink still closes fully.
 const narrow=new sandbox.BlinkDriver();narrow.calibrate(.38);
 assert.equal(narrow.update(.42,100,33),0,'resting eyelid variation is not mistaken for closure');
 assert.equal(narrow.update(.85,133,33),1,'calibrated narrow eyes still blink fully');
 assert.ok(narrow.update(.38,400,100)<.15,'relaxed open eyes reopen after a blink');
 const less=new sandbox.BlinkDriver();less.calibrate(.38);
 assert.ok(less.update(.69,100,33,true,.8)<1,'less-sensitive mode requires stronger closure');
 const natural=sandbox.expressionWeight('mouthFunnel',.25,{mouthStrength:1});
 const clear=sandbox.expressionWeight('mouthFunnel',.25,{});
 assert.equal(natural,.25);assert.ok(clear>.35&&clear<.5,'subtle rounded lips become visible without saturating');
 assert.ok(sandbox.expressionWeight('mouthSmileLeft',.3,{})>.38,'smile uses expression gain');
 assert.equal(sandbox.expressionWeight('jawOpen',0,{}),0,'silent neutral mouth stays closed');
 assert.equal(sandbox.expressionWeight('eyeBlinkLeft',.3,{expressionStrength:2,mouthStrength:2}),.3,'expression controls cannot boost blink');
 for(const score of [0,.2,.5,.8,1])assert.ok(sandbox.expressionWeight('jawOpen',score,{mouthStrength:2.5})<=1,'mouth coefficients remain within authored range');
 const gaze=sandbox.eyeDirection({eyeLookOutLeft:.9,eyeLookInRight:.1});assert.equal(gaze.x,.5,'paired eye estimates produce one gaze, not divergence');
 vm.runInContext('(function(){'+fs.readFileSync('web/performer-view.js','utf8').replace(/export /g,'')+';globalThis.view={cameraAngles,dragCamera,framePerformerCamera};})();',sandbox);
 const camera=new THREE.PerspectiveCamera(22,16/9,.01,100);
 const front=sandbox.view.framePerformerCamera(camera,{top:1.85,bottom:1.1});
 const dragged=sandbox.view.dragCamera({yaw:0,pitch:0},100,80);
 assert.equal(dragged.yaw,-35);assert.equal(dragged.pitch,20);
 const angle=sandbox.view.framePerformerCamera(camera,{top:1.85,bottom:1.1,...dragged});
 const center=new THREE.Vector3(0,angle.center,0);camera.updateMatrixWorld(true);
 assert.ok(Math.abs(camera.position.distanceTo(center)-front.distance)<1e-6,'manual orbit preserves framing distance and model scale');
 assert.ok(center.clone().project(camera).length()<1,'orbit keeps the framing target inside the output');
 assert.equal(sandbox.view.cameraAngles(370,95).yaw,10);assert.equal(sandbox.view.cameraAngles(370,95).pitch,60);

 const {PerformerWindows}=require('../electron/performer.cjs');
 const ipcMain=new EventEmitter(),sent=[];let entered=0,left=0;
 class W extends EventEmitter{
  constructor(){super();this.dead=false;this.webContents=new EventEmitter();Object.assign(this.webContents,{send:(_c,d)=>sent.push([this,d]),setWindowOpenHandler(){}});}
  isDestroyed(){return this.dead;}destroy(){this.dead=true;}loadURL(){}show(){}focus(){}
 }
 const windows=new PerformerWindows({BrowserWindow:W,ipcMain,path:require('node:path'),baseUrl:()=> 'http://127.0.0.1:1',enter:()=>entered++,leave:()=>left++});
 windows.open();assert.equal(entered,1);const controls=windows.controls,output=windows.output;
 ipcMain.emit('openclam:performer-data',{sender:{}},{type:'frame'});assert.equal(sent.length,0);
 ipcMain.emit('openclam:performer-data',{sender:controls.webContents},{type:'frame',face:true});assert.equal(sent.length,1);assert.equal(sent[0][0],output);
 ipcMain.emit('openclam:performer-data',{sender:controls.webContents},{type:'frame',bad:'x'.repeat(40000)});assert.equal(sent.length,1);
 ipcMain.emit('openclam:performer-data',{sender:output.webContents},{type:'frame'});assert.equal(sent.length,1,'output cannot inject camera frames');
 ipcMain.emit('openclam:performer-data',{sender:controls.webContents},{type:'settings',background:'green'});
 ipcMain.emit('openclam:performer-data',{sender:output.webContents},{type:'ready'});assert.equal(sent.at(-2)[1].background,'green');
 ipcMain.emit('openclam:performer-data',{sender:output.webContents},{type:'view',yaw:-35,pitch:20});
 assert.equal(sent.at(-1)[0],controls);assert.equal(sent.at(-1)[1].yaw,-35,'output drag updates the control panel');
 assert.equal(windows.settings.background,'green','manual orbit preserves other output settings');
 const count=sent.length;ipcMain.emit('openclam:performer-data',{sender:output.webContents},{type:'view',yaw:NaN,pitch:0});assert.equal(sent.length,count);
 output.webContents.emit('render-process-gone');assert.equal(controls.dead,true);assert.equal(output.dead,true);assert.equal(left,1);
 windows.close();assert.equal(left,1,'close is idempotent');
 console.log('Performer QA passed: shoulder lift, behind-head depth and occlusion, attached fingers, face contact, calibrated blinks, expression/mouth gains, camera orbit and IPC lifecycle.');
})().catch(error=>{console.error(error);process.exitCode=1;});
