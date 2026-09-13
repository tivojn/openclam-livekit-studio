import '/avatar3d.js';
import {PerformerRig} from '/performer/performer-rig.js';
import {cameraAngles,dragCamera,framePerformerCamera,performerBudget,hasPerformerTracking} from '/performer/performer-view.js';
import {preferenceKey,preferenceChoices,performerPreferences} from '/performer/performer-view.js';
const $=id=>document.getElementById(id),bridge=window.performer;
const output=new URLSearchParams(location.search).get('role')==='output';
if(!bridge)throw Error('Open Performer from the OpenClam app menu.');

if(output){
 document.body.classList.add('output');
 let avatar,rig,settings={framing:'bust',background:'dark',yaw:0,pitch:0},last=0,frames=0,fpsAt=0;
 const sendStatus=(message,extra={})=>bridge.send({type:'status',message,...extra});
 const sendCatalogue=()=>bridge.send({type:'ready',outfits:avatar.options?.outfits.map(({id,label})=>({id,label}))||[]});
 let broadcast=false,trackedAt=-Infinity,settleUntil=0,dirty=true,budget=performerBudget(),lastCatalogueRequest=null;
 function frameCamera(){
  if(!avatar)return;
  const h=rig.height,aspect=1280/720;
  const top=avatar.restBounds.max.y+h*.025;
  const bottom=settings.framing==='full'?-h*.025:settings.framing==='waist'?h*.43:h*.59;
  const {distance}=framePerformerCamera(avatar.camera,{top,bottom,aspect,yaw:settings.yaw,pitch:settings.pitch});
  avatar.camera.near=Math.max(.001,h*.005);avatar.camera.far=distance+h*5;avatar.camera.updateProjectionMatrix();
 }
 function configure(value){
  settings={...settings,...value};
  budget=performerBudget(settings.quality);dirty=true;
  const color={dark:'#18202a',light:'#e8ecf1',green:'#00b140'}[settings.background]||'#18202a';
  document.body.style.background=color;
  if(avatar){
   avatar.performerRenderBudget=budget;
   if(avatar.canvas.width!==budget.width||avatar.canvas.height!==budget.height)
    avatar.renderer.setSize(budget.width,budget.height,false);
   avatar.renderer.setClearColor(color,1);avatar.canvas.style.transform=settings.mirror?'scaleX(-1)':'';
   if(avatar.options&&settings.outfit!==undefined){
    avatar.options.applyVisibility({...avatar.options.selection,outfit:settings.outfit});
    avatar.options.selection.outfit=settings.outfit;
   }
   if(rig)rig.settings={smoothing:Number(settings.smoothing)||80,gaze:settings.gaze===undefined?.65:Number(settings.gaze),blinkSensitivity:Number(settings.blinkSensitivity)||1,
    expressionStrength:Number(settings.expressionStrength)||1.4,mouthStrength:Number(settings.mouthStrength)||1.65};
   frameCamera();
  }
 }
 const stage=$('stage');let drag=null;
 stage.addEventListener('contextmenu',event=>{event.preventDefault();bridge.command('controls');});
 stage.addEventListener('pointerdown',event=>{
  if(event.button!==0)return;
  drag={id:event.pointerId,x:event.clientX,y:event.clientY,yaw:settings.yaw,pitch:settings.pitch};
  stage.setPointerCapture(event.pointerId);stage.style.cursor='grabbing';event.preventDefault();
 });
 stage.addEventListener('pointermove',event=>{
  if(!drag||drag.id!==event.pointerId)return;
  const view=dragCamera(drag,event.clientX-drag.x,event.clientY-drag.y,settings.mirror);
  configure(view);bridge.send({type:'view',...view});
 });
 const endDrag=()=>{drag=null;stage.style.cursor='grab';};
 stage.addEventListener('pointerup',endDrag);stage.addEventListener('pointercancel',endDrag);
 stage.addEventListener('lostpointercapture',endDrag);
 bridge.onData(data=>{
  if(data.type==='settings'){
   configure(data);
   if(data.requestCatalogue&&rig&&data.requestCatalogue!==lastCatalogueRequest){
    lastCatalogueRequest=data.requestCatalogue;sendCatalogue();
   }
  }
  if(data.type==='frame'){
   broadcast=true;rig?.receive(data);
   if(hasPerformerTracking(data)){trackedAt=performance.now();settleUntil=trackedAt+1800;}
  }
  if(data.type==='stop'){broadcast=false;settleUntil=performance.now()+1800;rig?.stop();}
  if(data.type==='reset')sendStatus(rig?.calibrate()?(rig.eyesCalibrated?'Head and relaxed eyelids calibrated.':'Head calibrated. Keep your eyes naturally open for a moment to calibrate eyelids.'):'Look at the camera with relaxed, open eyes, then calibrate again.');
 });
 try{
  const response=await fetch('/assets/manifest.json');if(!response.ok)throw Error('Select a 3D Tia avatar in OpenClam first.');
  const manifest=await response.json();if(!manifest.model)throw Error('Select a 3D Tia avatar in OpenClam first.');
  const resident=await fetch('/api/avatar/resident?slug='+encodeURIComponent(manifest.avatar.slug));
  const model=resident.ok?(await resident.json()).model:new URL(manifest.model,location.origin+'/').href;
  avatar=window.OpenClamAvatar3D.create({width:1280,height:720});
  // Capture the authored affine arm chain; Performer supplies its own neutral
  // pose and must not retarget from the companion's procedural relaxed pose.
  await avatar.load(model,{resources:true,pose:'rest',yaw:manifest.yaw,appearanceLibrary:'/api/avatar/appearance'});
  rig=new PerformerRig(avatar);settleUntil=performance.now()+1800;configure(settings);$('stage').append(avatar.canvas);
  sendCatalogue();
  sendStatus('Tia is ready. Output is 1280 × 720.');
  const draw=now=>{
   requestAnimationFrame(draw);
   const animating=broadcast&&now-trackedAt<450||now<settleUntil;
   // A settled output is reusable even while the camera keeps checking for
   // a returning performer. OBS continues showing the last complete frame.
   if((animating||dirty||!avatar.resources?.ready)&&now-last>=1000/budget.fps-1){
    last=now;avatar.render(now);frames++;dirty=!avatar.resources?.ready;
   }
   if(now-fpsAt>3000){sendStatus('Tia is ready.',{fps:Math.round(frames*1000/(now-fpsAt)),width:budget.width,height:budget.height});frames=0;fpsAt=now;}
  };
  fpsAt=performance.now();requestAnimationFrame(draw);
  addEventListener('pagehide',()=>avatar.dispose(),{once:true});
 }catch(error){avatar?.dispose();sendStatus(String(error.message||error));}
}else{
 let worker=null,stream=null,generation=0,running=false,inFlight=false,ready=false;
 let timer=null,watchdog=null,lastVideo=-1,lastCapture=0,lastResult=0,nextInterval=66,cameraFrames=0,measureAt=0;
 const video=$('camera');
 let saved={};try{saved=performerPreferences(JSON.parse(localStorage.getItem(preferenceKey)||'{}'));}catch{}
 for(const [id,value] of Object.entries(saved)){
  if(id==='outfit')continue;
  if(typeof value==='boolean')$(id).checked=value;else $(id).value=value;
 }
 let preferredOutfit=saved.outfit||'',catalogueReady=false;
 const catalogueRequest=Date.now()+':'+Math.random();
 function savePreferences(){
  const value={outfit:preferredOutfit,...cameraAngles($('yaw').value,$('pitch').value)};
  for(const id of Object.keys(preferenceChoices))value[id]=$(id).value;
  for(const id of ['body','hands','mirror'])value[id]=$(id).checked;
  try{localStorage.setItem(preferenceKey,JSON.stringify(performerPreferences(value)));}catch{}
 }
 const tabs=[...document.querySelectorAll('[role=tab]')];
 function showTab(tab){
  for(const item of tabs){const active=item===tab;item.setAttribute('aria-selected',String(active));item.tabIndex=active?0:-1;$(item.getAttribute('aria-controls')).hidden=!active;}
 }
 for(const [index,tab] of tabs.entries()){
  tab.onclick=()=>showTab(tab);
  tab.onkeydown=event=>{
   const next=event.key==='ArrowRight'?(index+1)%tabs.length:event.key==='ArrowLeft'?(index+tabs.length-1)%tabs.length:event.key==='Home'?0:event.key==='End'?tabs.length-1:-1;
   if(next>=0){event.preventDefault();showTab(tabs[next]);tabs[next].focus();}
  };
 }
 const status=message=>{$('status').textContent=message;};
 const settings=()=>{savePreferences();bridge.send({type:'settings',requestCatalogue:catalogueReady?null:catalogueRequest,framing:$('framing').value,background:$('background').value,
  mirror:$('mirror').checked,outfit:preferredOutfit,smoothing:Number($('smoothing').value),gaze:Number($('gaze').value),blinkSensitivity:Number($('blinkSensitivity').value),
  expressionStrength:Number($('expressionStrength').value),mouthStrength:Number($('mouthStrength').value),quality:$('quality').value,
  ...cameraAngles($('yaw').value,$('pitch').value)});};
 function showAngles(value){
  for(const id of ['yaw','pitch']){$(id).value=value[id];$(id+'Value').textContent=Math.round(value[id])+'°';}
 }
 async function devices(){
  const previous=$('device').value,list=await navigator.mediaDevices.enumerateDevices();
  $('device').replaceChildren(new Option('System default',''));
  let n=0;for(const d of list)if(d.kind==='videoinput')$('device').add(new Option(d.label||`Camera ${++n}`,d.deviceId));
  $('device').value=previous;
 }
 function stop(message='Camera is off.'){
  generation++;running=false;ready=false;inFlight=false;
  clearTimeout(timer);clearTimeout(watchdog);worker?.terminate();worker=null;
  stream?.getTracks().forEach(track=>track.stop());stream=null;video.srcObject=null;
  $('start').textContent='Start camera';$('start').disabled=false;$('calibrate').disabled=true;
  for(const id of ['device','body','hands'])$(id).disabled=false;
  bridge.send({type:'stop'});status(message);
 }
 async function capture(token){
  if(token!==generation||!running)return;
  timer=setTimeout(()=>capture(token),20);
  const now=performance.now();
  if(inFlight||!ready||video.readyState<2||video.currentTime===lastVideo||now-lastCapture<nextInterval)return;
  inFlight=true;lastVideo=video.currentTime;lastCapture=now;
  try{
   const image=await createImageBitmap(video);
   if(token!==generation||!worker){image.close();return;}
   worker.postMessage({type:'frame',image,at:now},[image]);
  }catch(error){if(token===generation)stop('Camera capture stopped: '+error.message);}
 }
 async function start(){
  if(running){stop();return;}
  const token=++generation;running=true;lastVideo=-1;lastCapture=0;lastResult=performance.now();
  cameraFrames=0;measureAt=lastResult;nextInterval=66;
  $('start').textContent='Stop camera';$('calibrate').disabled=true;
  for(const id of ['device','body','hands'])$(id).disabled=true;
  status('Opening camera…');
  try{
   const id=$('device').value;
   const media=await navigator.mediaDevices.getUserMedia({audio:false,video:{width:{ideal:640},height:{ideal:480},frameRate:{ideal:24,max:30},...(id?{deviceId:{exact:id}}:{})}});
   if(token!==generation){media.getTracks().forEach(t=>t.stop());return;}
   stream=media;video.srcObject=stream;
   stream.getVideoTracks()[0].addEventListener('ended',()=>{if(token===generation)stop('Camera disconnected. Reconnect it, then start again.');});
   await video.play();if(token!==generation)return;
   void devices().catch(()=>{});status('Loading local tracking models…');
   worker=new Worker('/performer/performer-worker.js');
   worker.onerror=()=>{if(token===generation)stop('Tracking could not start. Check camera access, then try again.');};
   worker.onmessage=({data})=>{
    if(token!==generation)return;
    if(data.type==='error'){stop('Tracking stopped: '+data.message);return;}
    if(data.type==='ready'){
     ready=true;$('calibrate').disabled=false;lastResult=performance.now();
     status('Look ahead with naturally relaxed, open eyes, then click Calibrate.');capture(token);return;
    }
    if(data.type==='frame'){
     inFlight=false;lastResult=performance.now();nextInterval=Math.max(50,Math.min(160,data.cost*1.35));
     bridge.send(data);cameraFrames++;
     if(lastResult-measureAt>1500){
      const rate=Math.round(cameraFrames*1000/(lastResult-measureAt));
      status(data.face?`Tracking · ${rate} updates/s · ${Math.round(data.cost)} ms processing`:'Face not visible. Tia returns gently to neutral.');
      cameraFrames=0;measureAt=lastResult;
     }
    }
   };
   worker.postMessage({type:'init',body:$('body').checked,hands:$('hands').checked});
   const health=()=>{
    if(token!==generation)return;
    if(performance.now()-lastResult>(ready?10000:60000)){stop('Tracking timed out. Click Start camera to retry.');return;}
    watchdog=setTimeout(health,2000);
   };health();
  }catch(error){if(token===generation)stop(error.name==='NotAllowedError'?'Camera access was denied. Allow OpenClam in System Settings → Privacy & Security → Camera, then try again.':'Could not open camera: '+error.message);}
 }
 bridge.onData(data=>{
  if(data.type==='view'){showAngles(cameraAngles(data.yaw,data.pitch));savePreferences();}
  if(data.type==='ready'){
   catalogueReady=true;
   $('outfit').replaceChildren(new Option('Original appearance',''));
   for(const outfit of data.outfits||[])$('outfit').add(new Option(outfit.label,outfit.id));
   if([...$('outfit').options].some(option=>option.value===preferredOutfit))$('outfit').value=preferredOutfit;
   else preferredOutfit='';
   settings();
  }
  if(data.type==='status')$('renderStatus').textContent=Number.isFinite(data.fps)?
   `Output · ${data.fps?data.fps+' fps':'resting'} · ${data.width||1280} × ${data.height||720}`:data.message;
 });
 $('start').onclick=start;$('calibrate').onclick=()=>bridge.send({type:'reset'});
 $('preview').onchange=()=>video.classList.toggle('preview',$('preview').checked);
 for(const id of ['framing','background','mirror','smoothing','gaze','blinkSensitivity','expressionStrength','mouthStrength','quality'])$(id).onchange=settings;
 $('outfit').onchange=()=>{preferredOutfit=$('outfit').value;settings();};
 for(const id of ['body','hands'])$(id).onchange=savePreferences;
 for(const id of ['yaw','pitch'])$(id).oninput=()=>{showAngles(cameraAngles($('yaw').value,$('pitch').value));settings();};
 $('resetView').onclick=()=>{showAngles({yaw:0,pitch:0});settings();};
 $('output').onclick=()=>bridge.command('output');$('exit').onclick=()=>{stop();bridge.command('exit');};
 addEventListener('pagehide',()=>stop(),{once:true});
 navigator.mediaDevices.addEventListener('devicechange',()=>void devices().catch(()=>{}));
 showAngles(cameraAngles($('yaw').value,$('pitch').value));
 void devices().catch(()=>status('No camera found. Connect a webcam, then start.'));settings();
}
