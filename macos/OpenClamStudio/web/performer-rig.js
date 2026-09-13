import * as THREE from '/vendor/three/three.module.js';
const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
const point=p=>new THREE.Vector3(p.x,-p.y,-p.z);
const valid=p=>p&&[p.x,p.y,p.z].every(Number.isFinite)&&(p.visibility??1)>.55;
const pivot=(q,p,to=p)=>new THREE.Matrix4().makeTranslation(to.x,to.y,to.z)
 .multiply(new THREE.Matrix4().makeRotationFromQuaternion(q)).multiply(new THREE.Matrix4().makeTranslation(-p.x,-p.y,-p.z));
const identity=()=>new THREE.Quaternion();
// Keep exactly the same vertices, skin weights and triangles, but stop running
// facial morph shaders on body vertices whose deltas are zero in every shape.
export function splitStaticMorphGeometry(source){
 const morphs=Object.values(source.morphAttributes).flat(),count=source.attributes.position?.count||0;
 if(!source.index||!source.morphTargetsRelative||count<10000||!morphs.length
  ||source.drawRange.start!==0||source.drawRange.count!==Infinity
  ||[...Object.values(source.attributes),...morphs].some(a=>a.isInterleavedBufferAttribute))return null;
 const active=new Uint8Array(count);
 for(const attribute of morphs){
  const values=attribute.array,size=attribute.itemSize;
  for(let i=0;i<count;i++)if(!active[i])for(let k=0;k<size;k++)if(values[i*size+k]!==0){active[i]=1;break;}
 }
 const groups=source.groups.length?source.groups:[{start:0,count:source.index.count,materialIndex:0}];
 const lists=[[],[]],partGroups=[[],[]];
 for(const group of groups){
  const starts=lists.map(list=>list.length);
  for(let i=group.start;i<group.start+group.count;i+=3){
   const a=source.index.getX(i),b=source.index.getX(i+1),c=source.index.getX(i+2);
   lists[active[a]||active[b]||active[c]?1:0].push(a,b,c);
  }
  for(let part=0;part<2;part++)if(lists[part].length>starts[part])
   partGroups[part].push({start:starts[part],count:lists[part].length-starts[part],materialIndex:group.materialIndex});
 }
 if(!lists[1].length||lists[0].length<source.index.count*.2)return null;
 const build=part=>{
  const remap=new Int32Array(count).fill(-1),vertices=[],indices=lists[part].map(i=>{
   if(remap[i]<0){remap[i]=vertices.length;vertices.push(i);}return remap[i];
  });
  const copy=attribute=>{
   const size=attribute.itemSize,array=new attribute.array.constructor(vertices.length*size);
   vertices.forEach((v,i)=>{for(let k=0;k<size;k++)array[i*size+k]=attribute.array[v*size+k];});
   const result=new THREE.BufferAttribute(array,size,attribute.normalized);
   result.name=attribute.name;result.gpuType=attribute.gpuType;result.setUsage(attribute.usage);return result;
  };
  const geometry=new THREE.BufferGeometry();geometry.name=source.name+(part?' · face':' · body');
  for(const [name,attribute] of Object.entries(source.attributes))geometry.setAttribute(name,copy(attribute));
  geometry.setIndex(indices);geometry.groups=partGroups[part];geometry.morphTargetsRelative=true;
  if(part)for(const [name,attributes] of Object.entries(source.morphAttributes))geometry.morphAttributes[name]=attributes.map(copy);
  return {geometry,vertices};
 };
 return {body:build(0),face:build(1)};
}
export function optimizePerformerMorphs(avatar){
 let before=0,after=0;
 for(const mesh of avatar.morphMeshes){
  if(!mesh.isSkinnedMesh||!Number.isInteger(mesh.morphTargetDictionary?.jawOpen))continue;
  const source=mesh.geometry,split=splitStaticMorphGeometry(source);if(!split)continue;
  const body=new THREE.SkinnedMesh(split.body.geometry,mesh.material);
  body.name=mesh.name+' · static morph region';body.skeleton=mesh.skeleton;body.bindMode=mesh.bindMode;
  body.bindMatrix.copy(mesh.bindMatrix);body.bindMatrixInverse.copy(mesh.bindMatrixInverse);
  body.frustumCulled=false;body.renderOrder=mesh.renderOrder;body.layers.mask=mesh.layers.mask;
  mesh.geometry=split.face.geometry;mesh.add(body);
  before+=source.attributes.position.count;after+=split.face.geometry.attributes.position.count;
  source.dispose();
 }
 return {before,after};
}
export function headRotation(matrix,neutral){
 if(!matrix||matrix.length!==16||!matrix.every(Number.isFinite))return identity();
 const rotation=new THREE.Matrix4().extractRotation(new THREE.Matrix4().fromArray(matrix));
 const q=new THREE.Quaternion().setFromRotationMatrix(rotation);
 if(neutral)q.multiply(neutral.clone().invert());
 const e=new THREE.Euler().setFromQuaternion(q,'YXZ');
 return new THREE.Quaternion().setFromEuler(new THREE.Euler(clamp(e.x,-.6,.6),clamp(e.y,-.85,.85),clamp(e.z,-.45,.45),'YXZ'));
}
export function aim(from,to){
 if(from.lengthSq()<1e-8||to.lengthSq()<1e-8)return identity();
 return new THREE.Quaternion().setFromUnitVectors(from.clone().normalize(),to.clone().normalize());
}
export function eyeDirection(weights={}){
 const v=name=>clamp(Number(weights[name])||0,0,1);
 return {x:(v('eyeLookOutLeft')-v('eyeLookInLeft')+v('eyeLookInRight')-v('eyeLookOutRight'))*.5,
  y:(v('eyeLookUpLeft')-v('eyeLookDownLeft')+v('eyeLookUpRight')-v('eyeLookDownRight'))*.5};
}
export function expressionWeight(name,score,settings={}){
 score=clamp(Number(score)||0,0,1);
 const expressive=/^(brow|cheek|nose|mouth(Smile|Frown|Dimple))/.test(name);
 const speech=/^(jaw|mouth|tongue)/.test(name)&&!expressive;
 const gain=expressive?(settings.expressionStrength??1.4):speech?(settings.mouthStrength??1.65):1;
 // A bounded response curve makes small expressions readable without clipping
 // every stronger expression to the same maximum pose. Zero remains neutral.
 return Number(gain)===1?score:1-Math.pow(1-score,clamp(Number(gain)||1,.5,2.5));
}
export class BlinkDriver {
 constructor(){this.until=0;this.value=0;this.neutral=.02;}
 calibrate(score){
  this.neutral=clamp(Number(score)||0,0,.7);this.until=0;this.value=0;
 }
 update(score,now,dt,visible=true,sensitivity=1){
  score=visible?clamp(Number(score)||0,0,1):0;
  // Measure closure relative to this person's relaxed, open eyes. An absolute
  // threshold mistakes naturally narrow eyelids for a continuous blink.
  const travel=clamp((score-this.neutral)/Math.max(.25,1-this.neutral),0,1);
  const threshold=.44/clamp(Number(sensitivity)||1,.7,1.3);
  if(visible&&travel>=threshold)this.until=now+85;
  if(!visible)this.until=0;
  const target=now<this.until?1:clamp((travel-.10)/(threshold-.10),0,1);
  this.value=target===1?1:this.value+(target-this.value)*(1-Math.exp(-dt/(target>this.value?12:45)));
  return this.value;
 }
}
export function shoulderRotation(clavicle,upper,chest=identity()){
 const direction=upper.clone().applyQuaternion(chest.clone().invert()).normalize();
 const elevation=Math.acos(clamp(-direction.y,-1,1));
 // Let the clavicle rise with an overhead reach, before rotating the humerus.
 const lift=clamp((elevation-THREE.MathUtils.degToRad(35))*.38,0,THREE.MathUtils.degToRad(35));
 const forward=clamp(direction.z*.20,-.20,.20),side=Math.sign(clavicle.x)||1;
 const target=new THREE.Vector3(side*Math.cos(lift)*Math.cos(forward),Math.sin(lift),Math.sin(forward)*Math.cos(lift));
 return chest.clone().multiply(aim(clavicle,target));
}
export function handHeadDepth(pose,wristIndex){
 // These landmarks share the pose model's world origin. Hand-landmarker z is
 // wrist-relative, so it cannot tell whether a hand is in front of the head.
 if(!pose||![7,8,11,12].every(i=>valid(pose[i]))||!pose[wristIndex])return null;
 const wrist=pose[wristIndex];
 if(![wrist.x,wrist.y,wrist.z].every(Number.isFinite)||(wrist.visibility??1)<.25)return null;
 const left=point(pose[7]),right=point(pose[8]),across=left.clone().sub(right);
 const normal=new THREE.Vector3(-across.z,0,across.x).normalize();
 const span=point(pose[11]).distanceTo(point(pose[12]));
 if(span<.1||normal.lengthSq()<.5)return null;
 return -point(wrist).sub(left.add(right).multiplyScalar(.5)).dot(normal)/span;
}
export function solveArm(shoulder,goal,pole,a,b){
 const direction=goal.clone().sub(shoulder),length=clamp(direction.length(),Math.abs(a-b)+.001,a+b-.001);
 if(direction.lengthSq()<1e-8)direction.set(0,-1,0);direction.normalize();
 const along=(a*a-b*b+length*length)/(2*length);
 const perpendicular=pole.clone().sub(shoulder);perpendicular.addScaledVector(direction,-perpendicular.dot(direction));
 if(perpendicular.lengthSq()<1e-6){perpendicular.set(0,-1,.2);perpendicular.addScaledVector(direction,-perpendicular.dot(direction));}
 if(perpendicular.lengthSq()<1e-6)perpendicular.set(1,0,0);
 return {wrist:shoulder.clone().addScaledVector(direction,length),elbow:shoulder.clone().addScaledVector(direction,along)
  .addScaledVector(perpendicular.normalize(),Math.sqrt(Math.max(0,a*a-along*along)))};
}
export function faceContactWeight(face,palm){
 const span=Math.hypot(face.left.x-face.right.x,face.left.y-face.right.y);
 if(span<.01)return 0;
 const eyes=new THREE.Vector2((face.left.x+face.right.x)/2,(face.left.y+face.right.y)/2);
 const mouth=new THREE.Vector2(face.mouth.x,face.mouth.y),up=eyes.clone().sub(mouth).normalize();
 const forehead=eyes.addScaledVector(up,span*.65),line=forehead.sub(mouth);
 const offset=new THREE.Vector2(palm.x,palm.y).sub(mouth);
 const t=clamp(offset.dot(line)/Math.max(.0001,line.lengthSq()),0,1);
 const distance=offset.addScaledVector(line,-t).length()/span;
 return clamp((1.1-distance)/.35,0,1);
}
function palmFrame(forward,across){
 const y=forward.clone().normalize(),x=across.clone().addScaledVector(y,-across.dot(y)).normalize();
 if(y.lengthSq()<.1||x.lengthSq()<.1)return identity();
 return new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(x,y,new THREE.Vector3().crossVectors(x,y)));
}
export function armRotations(restUpper,restLower,upper,lower,previous=identity()){
 const u=upper.clone().normalize(),v=lower.clone().normalize();
 const restNormal=new THREE.Vector3().crossVectors(restUpper,restLower).normalize();
 if(restNormal.lengthSq()<.1)restNormal.crossVectors(restUpper,new THREE.Vector3(0,0,1)).normalize();
 const normal=new THREE.Vector3().crossVectors(u,v);
 // A nearly straight elbow has no reliable bend plane. Transport its previous
 // plane until the bend is observable, instead of letting noise flip the roll.
 const carried=restNormal.clone().applyQuaternion(previous);
 carried.addScaledVector(u,-carried.dot(u)).normalize();
 const confidence=clamp((normal.length()-.08)/.2,0,1);
 if(normal.lengthSq()>.0001)normal.normalize();else normal.copy(carried);
 normal.copy(carried.lerp(normal,confidence).normalize());
 if(normal.lengthSq()<.1)normal.crossVectors(u,new THREE.Vector3(0,0,1)).normalize();
 const q1=palmFrame(u,normal).multiply(palmFrame(restUpper,restNormal).invert());
 // The forearm inherits the upper arm's roll, then bends about the elbow.
 // Two independent shortest-arc aims can disagree by nearly half a turn.
 const q2=aim(restLower.clone().applyQuaternion(q1),v).multiply(q1);
 return {upper:q1,lower:q2};
}
export function wristRotation(lower,requested,axis){
 axis=axis.clone().normalize();
 const relative=lower.clone().invert().multiply(requested).normalize();
 if(relative.w<0)relative.set(-relative.x,-relative.y,-relative.z,-relative.w);
 const projection=relative.x*axis.x+relative.y*axis.y+relative.z*axis.z;
 let twist=new THREE.Quaternion(axis.x*projection,axis.y*projection,axis.z*projection,relative.w);
 if(twist.lengthSq()<1e-8)twist.identity();else twist.normalize();
 const swing=relative.clone().multiply(twist.clone().invert());
 const angle=identity().angleTo(swing),limit=THREE.MathUtils.degToRad(60);
 if(angle>limit)swing.copy(identity().slerp(swing,limit/angle));
 const roll=clamp(2*Math.atan2(twist.x*axis.x+twist.y*axis.y+twist.z*axis.z,twist.w),-1.92,1.92);
 twist.setFromAxisAngle(axis,roll);
 return {hand:lower.clone().multiply(swing).multiply(twist),twist};
}

// Tia's export has flat, affine deform bones. Retarget segments in WORLD
// space, including twist bones, rather than treating them as a Mixamo chain.
// The original matrices, mesh, hair and skin weights are never edited.
export class PerformerRig {
 constructor(avatar){
  this.avatar=avatar;this.packet=null;this.received=0;this.neutral=null;
  this.head=identity();this.chest=identity();this.arms={};this.weights={};this.neutralEyes={x:0,y:0};
  this.blinks={Left:new BlinkDriver(),Right:new BlinkDriver()};
  this.settings={smoothing:80,gaze:.65,blinkSensitivity:1,expressionStrength:1.4,mouthStrength:1.65};
  this.eyeSamples=[];this.eyesCalibrated=false;
  this.bones=[];this.names=new Map();this.bind=new Map();this.local=new Map();
  this.morphOptimization=optimizePerformerMorphs(avatar);
  avatar.options?.select({...avatar.options.selection,body:'',hands:'',leftHand:'',rightHand:'',prop:'',
   expression:'',playTransitions:'false',followCursor:'false'});
  avatar.options?.update(performance.now(),true);
  avatar.root.updateMatrixWorld(true);
  avatar.model.traverse(node=>{
   if(!node.isBone)return;
   this.bones.push(node);this.names.set(node.userData.sourceName||node.name,node);
   this.bind.set(node,node.matrixWorld.clone());this.local.set(node,node.matrix.clone());
  });
  this.morphs=[];
  for(const mesh of avatar.morphMeshes)for(const [name,index] of Object.entries(mesh.morphTargetDictionary))
   if(/^(eye|jaw|mouth|brow|cheek|nose|tongue)/.test(name))this.morphs.push({mesh,index,name});
  this.morphNames=[...new Set(this.morphs.map(m=>m.name))];
  this.height=avatar.restBounds.getSize(new THREE.Vector3()).y;
  this.faceClearance=this.height*.015;
  this.waist=new THREE.Vector3(0,this.height*.57,0);
  for(const side of ['l','r']){
   // c_arm_stretch is the FINAL third of the humerus, not the shoulder.
   // Using it as the pivot shortens the upper arm and crushes the elbow.
   const upper=this.names.get('c_arm_twist.'+side),lower=this.names.get('c_forearm_stretch.'+side),hand=this.names.get('hand.'+side);
   if(!upper||!lower||!hand)continue;
   const p=node=>new THREE.Vector3().setFromMatrixPosition(this.bind.get(node));
   const clavicle=this.names.get('shoulder.'+side);
   this.arms[side]={upper,lower,hand,clavicle,clavicleBase:clavicle?p(clavicle):p(upper),
    a:p(upper),b:p(lower),c:p(hand),q1:identity(),q2:identity(),qh:identity(),qs:identity(),behind:false,finger:{}};
   const arm=this.arms[side],down=new THREE.Vector3(0,-1,0);
   arm.idleUpper=arm.b.clone().sub(arm.a);arm.idleLower=arm.c.clone().sub(arm.b);
   if(arm.idleUpper.angleTo(down)>Math.PI/7){
    arm.idleUpper.set((side==='l'?1:-1)*.16,-1,.04);
    arm.idleLower.set((side==='l'?1:-1)*.05,-1,.12);
   }
  }
  avatar.performerRig=this;
 }
 receive(packet,now=performance.now()){
  this.packet=packet;this.received=now;
  if(packet.face){
   this.lastFace=packet;this.lastFaceAt=now;
   if(['Left','Right'].every(side=>Number.isFinite(packet.blendshapes?.['eyeBlink'+side]))){
    this.eyeSamples.push({at:now,left:packet.blendshapes.eyeBlinkLeft,right:packet.blendshapes.eyeBlinkRight});
    this.eyeSamples=this.eyeSamples.filter(sample=>now-sample.at<1800);
    if(!this.eyesCalibrated&&this.eyeSamples.length>=6&&now-this.eyeSamples[0].at>=1000)this.calibrateEyes();
   }
  }
 }
 calibrateEyes(){
  if(this.eyeSamples.length<4)return false;
  const neutral=key=>{
   const values=this.eyeSamples.map(sample=>sample[key]).sort((a,b)=>a-b);
   return values[Math.floor((values.length-1)*.25)];
  };
  const left=neutral('left'),right=neutral('right');
  if(Math.max(left,right)>.7)return false;
  this.blinks.Left.calibrate(left);this.blinks.Right.calibrate(right);this.eyesCalibrated=true;return true;
 }
 calibrate(){
  const m=this.packet?.matrix;
  if(!this.packet?.face||!m||m.length!==16)return false;
  this.neutral=new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().extractRotation(new THREE.Matrix4().fromArray(m)));
  this.neutralEyes=eyeDirection(this.packet.blendshapes);
  this.calibrateEyes();
  return true;
 }
 stop(){
  this.packet=null;this.received=0;this.lastFace=null;this.eyeSamples=[];
  for(const arm of Object.values(this.arms)){arm.observed=null;arm.trackedHand=null;arm.behind=false;}
 }
 put(node,world){
  if(!node)return;
  node.parent?.updateWorldMatrix(true,false);
  node.matrix.copy(node.parent?node.parent.matrixWorld.clone().invert().multiply(world):world);
  node.matrix.decompose(node.position,node.quaternion,node.scale);node.matrixAutoUpdate=false;
  // All deform bones use explicit matrices. Refresh descendants now: a later
  // getWorldPosition() on a clean child does not inherit a parent's dirty flag.
  // Otherwise finger solving reads the old, lowered hand and pins its joints
  // there while the wrist moves, stretching the palm between both positions.
  node.matrixWorldNeedsUpdate=true;node.updateWorldMatrix(false,true,true);
 }
 transformed(node,delta){if(node)this.put(node,delta.clone().multiply(this.bind.get(node)));}
 update(now){
  const dt=clamp(now-(this.last||now-33),1,100);this.last=now;
  const a=1-Math.exp(-dt/clamp(Number(this.settings.smoothing)||80,40,160)),faceA=1-Math.exp(-dt/55);
  const packet=now-this.received<450?this.packet:null;
  const facePose=packet?.face?packet:packet&&now-this.lastFaceAt<650?this.lastFace:null;
  for(const node of this.bones){node.matrix.copy(this.local.get(node));node.matrixAutoUpdate=false;node.matrixWorldNeedsUpdate=true;}
  this.avatar.root.updateMatrixWorld(true);
  const coefficients=packet?.face?{...packet.blendshapes}:{};
  const gaze=eyeDirection(coefficients),dead=v=>Math.abs(v)<.025?0:v;
  const gx=clamp(dead(gaze.x-this.neutralEyes.x)*(this.settings.gaze??.65),-.55,.55);
  const gy=clamp(dead(gaze.y-this.neutralEyes.y)*(this.settings.gaze??.65),-.45,.45);
  // Couple both eyes onto one viewing direction. Independent webcam eye
  // estimates otherwise produce visible divergence on Tia's large eyes.
  Object.assign(coefficients,{eyeLookOutLeft:Math.max(0,gx),eyeLookInRight:Math.max(0,gx),
   eyeLookInLeft:Math.max(0,-gx),eyeLookOutRight:Math.max(0,-gx),
   eyeLookUpLeft:Math.max(0,gy),eyeLookUpRight:Math.max(0,gy),
   eyeLookDownLeft:Math.max(0,-gy),eyeLookDownRight:Math.max(0,-gy)});
  for(const name of this.morphNames){
   const target=packet?.face?expressionWeight(name,coefficients[name],this.settings):0;
   const response=/^(jaw|mouth)/.test(name)?1-Math.exp(-dt/30):faceA;
   this.weights[name]=(this.weights[name]||0)+(target-(this.weights[name]||0))*response;
  }
  for(const side of ['Left','Right']){
   const blink=this.blinks[side].update(coefficients['eyeBlink'+side],now,dt,!!packet?.face,this.settings.blinkSensitivity);
   this.weights['eyeBlink'+side]=blink;
   this.weights['eyeWide'+side]=(this.weights['eyeWide'+side]||0)*(1-blink);
  }
  for(const {mesh,index,name} of this.morphs)mesh.morphTargetInfluences[index]=this.weights[name];
  const body=packet?.pose;
  let chestTarget=identity();
  if(body&&[11,12,23,24].every(i=>valid(body[i]))){
   const shoulders=point(body[11]).sub(point(body[12])).normalize();
   const roll=clamp(Math.atan2(shoulders.y,shoulders.x),-.25,.25);
   const yaw=clamp(Math.atan2(-shoulders.z,shoulders.x),-.5,.5);
   chestTarget.setFromEuler(new THREE.Euler(0,yaw,roll,'YXZ'));
  }
  this.chest.slerp(chestTarget,a);
  const torso=pivot(this.chest,this.waist);
  for(const node of this.bones){
   const name=node.userData.sourceName||node.name;
   if(/^(c_)?spine_0[1-5]/.test(name)){
    const y=new THREE.Vector3().setFromMatrixPosition(this.bind.get(node)).y;
    this.transformed(node,pivot(identity().slerp(this.chest,clamp((y-this.waist.y)/(this.height*.18),0,1)),this.waist));
   }else if(/^shoulder[.]/.test(name))this.transformed(node,torso);
  }
  this.head.slerp(facePose?headRotation(facePose.matrix,this.neutral):identity(),a);
  const head=this.names.get('head.x')||this.avatar.bones.head;
  if(head){
   const p=new THREE.Vector3().setFromMatrixPosition(this.bind.get(head)),to=p.clone().applyMatrix4(torso);
   const delta=pivot(this.head,p,to);
   this.transformed(head,delta);
   for(const name of ['neck.x','subneck_twist_1.x']){
    const node=this.names.get(name);if(node)this.transformed(node,pivot(identity().slerp(this.head,.35),p,to));
   }
  }
  for(const [side,arm] of Object.entries(this.arms)){
   const ids=side==='l'?[11,13,15]:[12,14,16];
   const depth=handHeadDepth(body,ids[2]),face=facePose?.facePoints;
   const currentImage=packet?.poseImage?.[ids[2]];
   const nearHead=face&&currentImage&&faceContactWeight(face,currentImage)>0;
   // A wrist hidden by the head may have lower visibility while the upper arm
   // and its depth are still tracked. Keep that reach instead of dropping it.
   const observed=body&&valid(body[ids[0]])&&valid(body[ids[1]])&&(valid(body[ids[2]])||nearHead&&depth>.12);
   if(observed){
    if(depth!==null&&nearHead){if(depth>.12)arm.behind=true;else if(depth<-.04)arm.behind=false;}
    else if(!nearHead)arm.behind=false;
    arm.observed={v1:point(body[ids[1]]).sub(point(body[ids[0]])),v2:point(body[ids[2]]).sub(point(body[ids[1]])),image:currentImage,at:this.received};
   }
   const seen=observed||packet&&arm.observed&&now-arm.observed.at<650;
   let v1=seen?arm.observed.v1.clone():arm.idleUpper.clone().applyQuaternion(this.chest);
   let v2=seen?arm.observed.v2.clone():arm.idleLower.clone().applyQuaternion(this.chest);
   const imageWrist=arm.observed?.image;
   let hand=seen&&imageWrist?(packet.hands||[]).filter(h=>h.image?.[0]&&h.world?.length===21&&h.world.every(p=>p&&[p.x,p.y,p.z].every(Number.isFinite)))
    .map(h=>({h,d:Math.hypot(h.image[0].x-imageWrist.x,h.image[0].y-imageWrist.y)}))
    .filter(x=>x.d<.2).sort((x,y)=>x.d-y.d)[0]?.h:null;
   if(hand)arm.trackedHand={data:hand,at:this.received};
   else if(seen&&arm.trackedHand&&now-arm.trackedHand.at<450)hand=arm.trackedHand.data;
   const middle=this.names.get('middle1.'+side),index=this.names.get('index1.'+side),pinky=this.names.get('pinky1.'+side);
   const restUpper=arm.b.clone().sub(arm.a),restLower=arm.c.clone().sub(arm.b);
   let rotations=armRotations(restUpper,restLower,v1,v2,arm.q1);
   let handTarget=rotations.lower.clone();
   if(hand&&middle&&index&&pinky){
    const pos=n=>new THREE.Vector3().setFromMatrixPosition(this.bind.get(n));
    handTarget=palmFrame(point(hand.world[9]).sub(point(hand.world[0])),point(hand.world[5]).sub(point(hand.world[17])))
     .multiply(palmFrame(pos(middle).sub(arm.c),pos(index).sub(pos(pinky))).invert());
   }
   const measuredHand=handTarget.clone();
   handTarget=wristRotation(rotations.lower,measuredHand,restLower).hand;
   const armA=seen?a:1-Math.exp(-dt/350);
   const clavicle=arm.a.clone().sub(arm.clavicleBase);
   arm.qs.slerp(arm.clavicle?shoulderRotation(clavicle,v1,this.chest):this.chest,armA);
   const shoulderDelta=pivot(arm.qs,arm.clavicleBase,arm.clavicleBase.clone().applyMatrix4(torso));
   const shoulder=arm.a.clone().applyMatrix4(shoulderDelta);
   this.transformed(arm.clavicle,shoulderDelta);
   const mouth=this.names.get('c_lips_bot.x');
   if((hand||seen&&arm.behind)&&face&&mouth&&middle&&imageWrist){
    const span=Math.hypot(face.left.x-face.right.x,face.left.y-face.right.y);
    const palm=hand?{x:imageWrist.x+(hand.image[9].x-hand.image[0].x)*.5,y:imageWrist.y+(hand.image[9].y-hand.image[0].y)*.5}:imageWrist;
    const mix=faceContactWeight(face,palm);
    if(mix>0){
     mouth.updateWorldMatrix(true,false);
     const center=mouth.getWorldPosition(new THREE.Vector3());
     const scale=this.height*.075/span;
     const dx=(palm.x-face.mouth.x)*scale,dy=-(palm.y-face.mouth.y)*scale;
     const normal=new THREE.Vector3(0,0,1).applyQuaternion(this.head);
     const dz=clamp(-(normal.x*dx+normal.y*dy)/Math.max(.4,normal.z),-this.height*.1,this.height*.1);
     const palmGoal=center.add(new THREE.Vector3(dx,dy,dz)).addScaledVector(normal,arm.behind?-this.height*.13:this.faceClearance);
     const pole=shoulder.clone().addScaledVector(v1.clone().normalize(),arm.a.distanceTo(arm.b));
     const sourceUpper=v1.clone().normalize(),sourceLower=v2.clone().normalize();
     // Reconcile wrist limits with palm contact, so limiting a wrist cannot
     // move the palm away from the mouth that it was supposed to cover.
     for(let i=0;i<5;i++){
      const palmOffset=hand?new THREE.Vector3().setFromMatrixPosition(this.bind.get(middle)).sub(arm.c).multiplyScalar(.5).applyQuaternion(handTarget):new THREE.Vector3();
      const solved=solveArm(shoulder,palmGoal.clone().sub(palmOffset),pole,restUpper.length(),restLower.length());
      v1=sourceUpper.clone().lerp(solved.elbow.clone().sub(shoulder).normalize(),mix);
      v2=sourceLower.clone().lerp(solved.wrist.clone().sub(solved.elbow).normalize(),mix);
      rotations=armRotations(restUpper,restLower,v1,v2,arm.q1);
      handTarget=wristRotation(rotations.lower,measuredHand,restLower).hand;
     }
    }
   }
   arm.q1.slerp(rotations.upper,armA);
   arm.q2.slerp(rotations.lower,armA);
   const elbow=arm.b.clone().sub(arm.a).applyQuaternion(arm.q1).add(shoulder);
   const wrist=arm.c.clone().sub(arm.b).applyQuaternion(arm.q2).add(elbow);
   const swung=aim(restUpper.clone().applyQuaternion(arm.qs),restUpper.clone().applyQuaternion(arm.q1)).multiply(arm.qs);
   arm.qh.slerp(hand?handTarget:arm.q2,armA);
   const wristPose=wristRotation(arm.q2,arm.qh,restLower);
   for(const node of this.bones){
    const name=node.userData.sourceName||node.name;
    if(name.endsWith('.'+side)&&/^c_arm_(stretch|twist)/.test(name)){
     const position=new THREE.Vector3().setFromMatrixPosition(this.bind.get(node));
     const fraction=clamp(position.clone().sub(arm.a).dot(restUpper)/restUpper.lengthSq(),0,1);
     // Spread humeral roll along the authored twist chain; applying all elbow
     // roll at the shoulder collapses the sleeve/skin at the armpit.
     const rotation=swung.clone().slerp(arm.q1,clamp(.25+fraction*1.125,0,1));
     const target=position.clone().sub(arm.a).applyQuaternion(arm.q1).add(shoulder);
     this.transformed(node,pivot(rotation,position,target));
    }
    if(name.endsWith('.'+side)&&/^c_forearm_(stretch|twist)/.test(name)){
     const position=new THREE.Vector3().setFromMatrixPosition(this.bind.get(node));
     const fraction=clamp(position.sub(arm.b).dot(restLower)/restLower.lengthSq(),0,1);
     const rotation=arm.q2.clone().multiply(identity().slerp(wristPose.twist,fraction));
     this.transformed(node,pivot(rotation,arm.b,elbow));
    }
   }
   // Pair hands to pose wrists in image space; model handedness labels assume
   // mirrored selfie input and would swap left/right for an ordinary webcam.
   this.transformed(arm.hand,pivot(wristPose.hand,arm.c,wrist));
   if(hand)for(const [finger,base] of [['index',5],['middle',9],['ring',13],['pinky',17],['thumb',1]]){
    // Retarget all three phalanges in palm space. A limited wrist must not
    // force the fingers to counter-rotate toward the raw camera direction.
    for(let segment=0;segment<3;segment++){
     const name=(segment?'c_':'')+finger+(segment+1)+'.'+side,node=this.names.get(name);
     const child=this.names.get('c_'+finger+(segment+2)+'.'+side);
     if(!node)continue;
     node.updateWorldMatrix(true,false);child?.updateWorldMatrix(true,false);
     const p=node.getWorldPosition(new THREE.Vector3());
     const direction=child?child.getWorldPosition(new THREE.Vector3()).sub(p):new THREE.Vector3().setFromMatrixColumn(node.matrixWorld,1);
     const wanted=point(hand.world[base+segment+1]).sub(point(hand.world[base+segment]))
      .applyQuaternion(measuredHand.clone().invert()).applyQuaternion(wristPose.hand);
     const target=aim(direction,wanted),angle=identity().angleTo(target),limit=THREE.MathUtils.degToRad([100,110,85][segment]);
     if(angle>limit)target.copy(identity().slerp(target,limit/angle));
     const key=finger+segment;
     const q=arm.finger[key]||(arm.finger[key]=identity());q.slerp(target,a);
     this.put(node,pivot(q,p).multiply(node.matrixWorld.clone()));
    }
   }
  }
  this.avatar.root.updateMatrixWorld(true);
 }
}
