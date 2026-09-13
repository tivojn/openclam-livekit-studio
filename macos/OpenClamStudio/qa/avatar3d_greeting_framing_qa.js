// Exercise the real Mac and iOS command entry points without a WebGL renderer.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
(async()=>{
 const entries=new Map([['wave',{id:'wave',label:'Gentle Wave',portraitGesture:true}],['wave-one-hand',{id:'wave-one-hand',label:'Friendly Wave',portraitGesture:true}],['kung-fu-punch',{id:'kung-fu-punch',label:'Kung Fu Punch'}]]);
 const played=[];let expands=0,clears=0;
 const motion={clips:entries,isPortraitGesture:id=>entries.get(id)?.portraitGesture===true,stop(){},async play(id){played.push(id);return true;}};
 const fixture={motion,options:{selection:{}},companion:{command(){}},stopCameraApproach(){}};
 const mac={avatarPresented:()=>true,avatar3d:fixture,avatarCompanionAPI:{isSpatialAction:()=>false},live:false,performance:{now:()=>0},
  closeRailPickers(){},companionKey:()=>'',localStorage:{setItem(){}},window:{dispatchEvent(){}},Event:class{},publishMotionReadiness(){},
  clearLocalTransientDisplayMode(){clears++;},markActivity(){},async beginAvatarStudioTravel(){expands++;}};
 vm.createContext(mac);
 const page=fs.readFileSync('web/index.html','utf8');
 const start=page.indexOf('    const performAvatarAction ='),end=page.indexOf('    const considerAvatarReaction =',start);
 vm.runInContext(page.slice(start,end)+'\nglobalThis.command=performAvatarAction;',mac);
 for(const action of ['wave','clip:wave-one-hand'])await mac.command(action);
 assert.deepEqual(played,['wave','wave-one-hand']);assert.equal(expands,0);assert.equal(clears,0);
 await mac.command('clip:kung-fu-punch');assert.equal(expands,1,'full-body actions still expand to the safe stage');
 const messages=[];
 const ios={window:{},avatar:fixture,companion:fixture.companion,reported:true,failed:false,latest:{state:{reduce:false},options:{}},actionGeneration:0,stagePreparing:false,travelClip:false,approachWalking:false,lastMotion:null,
  isSpatialAction:()=>false,performance:{now:()=>0},preference(){},report:e=>messages.push(e),motionStatus(){}};
 const source=fs.readFileSync('../../ios/OpenClamLiveKit/App/Avatar3D/avatar-ios.js','utf8');
 const a=source.indexOf('window.avatarCommand ='),b=source.indexOf("document.addEventListener('visibilitychange'",a);
 vm.createContext(ios);vm.runInContext(source.slice(a,b),ios);
 await ios.window.avatarCommand('wave');await ios.window.avatarCommand('clip:wave-one-hand');
 assert.equal(messages.filter(x=>x.event==='motion-framing').length,0);
 await ios.window.avatarCommand('clip:kung-fu-punch');
 assert.equal(messages.filter(x=>x.event==='motion-framing').length,1);
 console.log('Mac and iOS command paths: greetings preserve framing; full-body actions retain stage expansion.');
})().catch(e=>{console.error(e);process.exitCode=1;});
