// Small, deterministic behavior controller. Network generation is never on
// the frame path. Manual controls and explicit stop commands take priority.
export function avatarIntent(text) {
  let value=String(text||'').normalize('NFKC').trim().toLowerCase()
    .replace(/[’‘]/g,"'").replace(/\s+/g,' ').replace(/[.!?,，。！？]+$/u,'');
  // Accept ordinary requests and speech transcription variations, while
  // keeping the whole command anchored: quoted/reported prose is not an action.
  const prefix=/^(?:(?:hey |hi |hello )?tia\b[,，:]?\s+(?=\S)|(?:please|pls|plz)\s+|(?:can|could|would|will) you\s+|(?:i want|i would like|i'd like) (?:you|her|tia) to\s+|(?:have|make) (?:tia|her)\s+)/;
  for(let i=0;i<5;i++)value=value.replace(prefix,'');
  value=value.replace(/(?:[,，]? (?:please|pls|plz|thanks|thank you|tia))+$/,'')
    .replace(/\b(?:cusor|curser)\b/g,'cursor');
  const pointer='(?:(?:my|the|this) )?(?:mouse(?: cursor| pointer)?|cursor|pointer)';
  const suffix='(?: (?:around|around (?:the )?(?:screen|window|desktop)|on (?:the )?(?:screen|desktop)|across (?:the )?(?:screen|window)))?';
  const follow=new RegExp(`^(?:(?:follow|chase|track) (?:${pointer}|me)|(?:walk|move|come|go) (?:with|along with|after) (?:${pointer}|me)|(?:start|keep|continue) (?:following|chasing|tracking) (?:${pointer}|me)|(?:start|keep|continue) (?:walking|moving) (?:with|along with) (?:${pointer}|me)|(?:follow|move|walk|go) (?:wherever|where) (?:i move ${pointer}|${pointer} (?:goes|moves))|follow)${suffix}$`);
  const stop=new RegExp(`^(?:stop|stay|stay (?:there|here|still)|stop moving|freeze|(?:stop|quit) (?:following|chasing|tracking|walking with|moving with)(?: (?:${pointer}|me))?|(?:don't|do not) (?:follow|chase|track)(?: (?:${pointer}|me))?)$`);
  if(stop.test(value))return 'stay';
  if(follow.test(value))return 'follow';
  const commands=[
    ['stay',/^(?:别动|停下|停止跟随(?:鼠标|光标)?)$/],
    ['follow',/^(?:请)?(?:跟着我|跟随(?:我的)?(?:鼠标|光标)|跟着(?:我的)?(?:鼠标|光标)(?:走|移动)?)$/],
    ['come',/^(?:come here|come to me|walk here|walk to (?:me|my cursor|the cursor)|过来)$/],
    ['wave',/^(?:wave(?: to me| hello)?|say hi|say hello|hello tia|hi tia|挥手|打个招呼)$/],
    ['heart',/^(?:heart|heart pose|show (?:me )?(?:a |the )?heart(?: pose)?|make (?:a )?heart|比心)$/],
    ['sit',/^(?:sit|sit down|take a seat|坐下)$/],
    ['stand',/^(?:stand|stand up|standing pose|站起来)$/],
    ['dance',/^(?:dance|dance for me|do a dance|let'?s dance|跳舞)$/],
  ];
  return commands.find(([,pattern])=>pattern.test(value))?.[0]||null;
}

export class CompanionController {
  constructor(){this.follow=false;this.come=false;this.walking=false;this.yaw=0;this.at=0;this.pauseUntil=0;this.velocityX=0;this.velocityY=0;this.gestures=true;this.wasSpeaking=false;this.gestureAt=-Infinity;}
  gesture(now,speaking,reduce=false){
    if(speaking&&!this.wasSpeaking)this.gestureAt=now;
    this.wasSpeaking=speaking;
    const t=(now-this.gestureAt)/1200;
    return {pitch:this.gestures&&!reduce&&t>=0&&t<1?Math.sin(t*Math.PI*2)*Math.sin(t*Math.PI)*.065:0};
  }
  command(action){
    this.come=action==='come';
    this.follow=action==='follow';
    this.walking=false;this.velocityX=0;this.velocityY=0;
    if(action==='follow'||action==='come')this.pauseUntil=0;
  }
  pause(now){this.pauseUntil=now+3000;this.velocityX=0;this.velocityY=0;this.walking=false;}
  step(now,{cursorX,anchorX,cursorY=0,anchorY=0,minX=-Infinity,maxX=Infinity,minY=-Infinity,maxY=Infinity,height=500,blocked=false,reduce=false,seen=true}={}){
    const dt=this.at?Math.min(.05,Math.max(0,(now-this.at)/1000)):0;this.at=now;
    const valid=[cursorX,cursorY,anchorX,anchorY,height].every(Number.isFinite);
    const active=(this.follow||this.come)&&seen&&valid&&!reduce&&!blocked&&now>=this.pauseUntil;
    const dx=Math.max(minX,Math.min(maxX,cursorX))-anchorX;
    const dy=Math.max(minY,Math.min(maxY,cursorY))-anchorY;
    const distance=Math.hypot(dx,dy), stop=Math.max(18,Math.min(40,height*.06));
    const want=active&&distance>(this.walking?stop:stop+14);
    const speed=Math.max(40,Math.min(190,height*.28));
    // Limit the vector's length, so diagonal movement is not faster.
    const amount=want?Math.min(speed,Math.max(0,distance-stop)*2.5)/distance:0;
    const response=1-Math.exp(-dt/.16);
    this.velocityX+=((want?dx*amount:0)-this.velocityX)*response;
    this.velocityY+=((want?dy*amount:0)-this.velocityY)*response;
    this.walking=want||Math.hypot(this.velocityX,this.velocityY)>8;
    if(!active){this.velocityX=0;this.velocityY=0;this.walking=false;}
    if(this.come&&!this.walking&&active)this.come=false;
    // Face left/right on horizontal travel and away/toward the viewer on
    // vertical travel. Unwrap the angle to avoid a full spin at +/- pi.
    let yaw=this.walking?Math.atan2(-this.velocityX,this.velocityY):0;
    yaw=this.yaw+Math.atan2(Math.sin(yaw-this.yaw),Math.cos(yaw-this.yaw));
    this.yaw+=(yaw-this.yaw)*(1-Math.exp(-dt/.2));
    this.yaw=Math.atan2(Math.sin(this.yaw),Math.cos(this.yaw));
    return {dx:this.velocityX*dt,dy:this.velocityY*dt,walking:this.walking,yaw:this.yaw,arrived:active&&!this.walking};
  }
}

export function mountCompanionControls(container,avatar,key,onAction) {
  const details=document.createElement('details'), summary=document.createElement('summary');
  summary.textContent='Interactive motions';details.append(summary);
  const status=document.createElement('p');status.setAttribute('role','status');
  const buttons=document.createElement('div');buttons.className='avatar-motion-actions';
  const actions=[['follow','Walk with cursor'],['come','Come here'],['wave','Wave'],['heart','Heart'],['sit','Sit'],['stand','Stand'],['dance','Dance'],['stay','Stop / stay']];
  const follow=document.createElement('button');
  for(const [action,label] of actions){
    const button=action==='follow'?follow:document.createElement('button');
    button.type='button';button.textContent=label;
    if(['wave','dance','follow','come'].includes(action)&&!avatar.motion?.clips.has(action==='follow'||action==='come'?'walk':action))continue;
    button.addEventListener('click',async()=>{status.textContent='';try{status.textContent=await onAction(action,{toggleFollow:action==='follow'});}catch(error){status.textContent=error.message;}refresh();});
    buttons.append(button);
  }
  const hint=document.createElement('p');
  hint.textContent='Say “follow my cursor”, “walk with the mouse”, “Tia, wave”, “dance” or “stay”. Following moves in every direction. Dragging, resizing, or rotating pauses it.';
  const row=document.createElement('label'), label=document.createElement('span'), gestures=document.createElement('input');
  label.textContent='Conversational gestures';gestures.type='checkbox';gestures.checked=avatar.companion.gestures;
  gestures.setAttribute('aria-label','Conversational gestures');
  gestures.addEventListener('change',()=>{void onAction('gestures');gestures.checked=avatar.companion.gestures;});
  row.append(label,gestures);
  details.append(buttons,row,status,hint);container.append(details);
  const refresh=()=>{follow.setAttribute('aria-pressed',String(avatar.companion.follow));gestures.checked=avatar.companion.gestures;};
  window.addEventListener('openclam-avatar-controls-refresh',refresh);
  refresh();return ()=>{window.removeEventListener('openclam-avatar-controls-refresh',refresh);details.remove();};
}
