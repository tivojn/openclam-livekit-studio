'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
(async()=>{
 const THREE=await import('three');
 const sandbox={THREE,performance};
 vm.runInNewContext(fs.readFileSync('web/avatar3d-options.js','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\nglobalThis.Library=Avatar3DOptions;',sandbox);
 const root=new THREE.Group(),model=new THREE.Group();root.add(model);
 const shoulder=new THREE.Bone(),hand=new THREE.Bone(),finger=new THREE.Bone();shoulder.name='shoulder';hand.name='hand';finger.name='finger';hand.position.y=1;finger.position.y=.3;model.add(shoulder);shoulder.add(hand);hand.add(finger);
 const hair=new THREE.Mesh(new THREE.BoxGeometry(.2,.2,.2));hair.position.x=.1;hand.add(hair);
 const old=new THREE.Mesh(),dress=new THREE.Mesh(),prop=new THREE.Group();old.name='coat';dress.name='dress';prop.name='prop';model.add(old,dress);hand.add(prop);root.updateMatrixWorld(true);
 const rows=m=>[0,1,2,3].map(r=>[0,1,2,3].map(c=>m.elements[c*4+r]));
 const rest=Object.fromEntries([shoulder,hand,finger].map(n=>[n.name,rows(n.matrixWorld)]));
 const rotate=new THREE.Matrix4().makeRotationZ(.7),shear=new THREE.Matrix4().set(1,.15,0,.1,0,1,0,0,0,0,1,0,0,0,0,1);
 const lib=new sandbox.Library({model,root,bones:{},baseQuaternions:new Map()}, {version:1,rest,defaultOutfit:'original',outfits:[{id:'original',nodes:['coat']},{id:'dress',nodes:['dress']}],props:[{id:'prop',nodes:['prop']}],poses:[{id:'pose',label:'Standing',group:'body',deltas:{shoulder:rows(rotate),hand:rows(rotate),finger:rows(rotate.clone().multiply(shear))}},{id:'fist',group:'rightHand',deltas:{finger:rows(shear)}}]});
 lib.captureIdle();assert(old.visible&&!dress.visible&&!prop.visible);
 lib.avatar.restBounds=lib.restBounds=new THREE.Box3(new THREE.Vector3(-1,0,-1),new THREE.Vector3(1,2,1));
 lib.avatar.modelBounds=()=>assert.fail('Playing authored poses must not scan every deformed vertex on the render thread');
 const baseline=lib.bones.map(b=>b.world.clone());
 lib.select({body:'pose',outfit:'dress',prop:'prop'},100);lib.update(425);assert(lib.transition);lib.update(800);
 for(const [i,b] of lib.bones.entries()){const expected=(i===2?rotate.clone().multiply(shear):rotate.clone()).multiply(baseline[i]);assert(Math.max(...expected.elements.map((v,j)=>Math.abs(v-b.node.matrixWorld.elements[j])))<1e-10,'authored affine transforms must survive parent movement');}
 assert(dress.visible&&!old.visible&&prop.visible);
 lib.select({body:'pose',rightHand:'fist'},900);lib.update(1600);assert(lib.selection.body==='pose'&&lib.selection.rightHand==='fist');
 for(let n=0;n<30;n++){lib.select({body:'pose'},2000);lib.update(2100,true);lib.select({},2200);lib.update(2300,true);}
 for(const [i,b] of lib.bones.entries())assert(Math.max(...b.node.matrixWorld.elements.map((v,j)=>Math.abs(v-baseline[i].elements[j])))<1e-10,'reset cannot accumulate rotation or shear');
 lib.select({body:'missing',outfit:'missing'},3000);assert.equal(Object.keys(lib.selection).length,0);
 // Playback starts without a preference, respects Reduce Motion, and an
 // explicit opt-out survives the repeated frame selections used by iOS.
 lib.select({},0);lib.update(0,true);
 assert(lib.enabled('playTransitions')&&lib.enabled('followCursor'));
 lib.update(4100);assert(lib.transition,'default playback must start');lib.update(4800);
 assert(Math.abs(shoulder.matrixWorld.elements[0]-Math.cos(.7))<1e-9);
 lib.select({playTransitions:'false',followCursor:'false'},5000);lib.update(5700);
 for(const time of [10000,20000,30000]){lib.select({playTransitions:'false',followCursor:'false'},time);lib.update(time);}
 assert(!lib.transition&&!lib.enabled('followCursor'));
 assert(Math.abs(shoulder.matrixWorld.elements[0]-1)<1e-9,'paused playback stays neutral');
 lib.select({},31000);lib.update(36000,true);assert(!lib.transition,'Reduce Motion prevents autoplay');
 lib.update(40100);assert(lib.transition,'playback resumes after Reduce Motion');
 // A prop remains attached during playback, including between-keyframe
 // transforms, and equipping it does not implicitly disable either switch.
 lib.select({prop:'prop'},41000);lib.update(41700);
 const attachment=prop.matrix.clone(),worldBefore=prop.matrixWorld.clone();
 let moved=false;
 for(const time of [45100,45425,45800,49100,49425,49800]) {
  lib.select({prop:'prop'},time);lib.update(time);
  assert(prop.visible&&lib.selection.prop==='prop'&&lib.enabled('playTransitions'));
  const relative=hand.matrixWorld.clone().invert().multiply(prop.matrixWorld);
  assert(Math.max(...relative.elements.map((v,i)=>Math.abs(v-attachment.elements[i])))<1e-10,'the prop must move with its hand');
  moved ||= Math.max(...worldBefore.elements.map((v,i)=>Math.abs(v-prop.matrixWorld.elements[i])))>0.01;
 }
 assert(moved,'the prop must move through automatic pose transitions');
 lib.select({prop:'prop',playTransitions:'false'},50000);lib.update(50700);lib.update(55000);
 assert(prop.visible&&!lib.transition&&!lib.enabled('playTransitions'),'pausing keeps the prop');
 lib.select({prop:'prop'},56000);lib.update(60100);assert(prop.visible&&lib.transition,'resuming keeps the prop');
 lib.update(61000);lib.avatar.motion={pending:1,update:()=>false,stop(){throw Error('autoplay canceled a pending motion');}};
 lib.update(70000);assert(!lib.transition,'a loading motion defers the pose playlist');
 lib.avatar.motion.pending=null;lib.avatar.motion.stop=()=>{};lib.update(74100);assert(lib.transition,'autoplay can resume once loading finishes');
 assert.throws(()=>new sandbox.Library({model,root}, {version:2,rest,poses:[]}));
 console.log('3D options: authored affine poses, layered hands, wardrobe/props, reduced motion and repeated reset verified.');
})().catch(e=>{console.error(e);process.exitCode=1});
