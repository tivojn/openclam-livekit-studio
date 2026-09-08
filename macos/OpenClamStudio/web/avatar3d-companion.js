// Small, deterministic behavior controller. Network generation is never on
// the frame path. Manual controls and explicit stop commands take priority.
const normalizeRequest = text => {
  let value=String(text||'').normalize('NFKC').trim().toLowerCase()
    .replace(/[’‘]/g,"'").replace(/\s+/g,' ').replace(/[.!?,，。！？]+$/u,'');
  // Accept ordinary requests and speech transcription variations, while
  // keeping the whole command anchored: quoted/reported prose is not an action.
  const prefix=/^(?:(?:hey |hi |hello )?tia\b[,，:]?\s+(?=\S)|(?:please|pls|plz)[,，]?\s+|(?:can|could|would|will) (?:you|u)\s+|(?:i want|i would like|i'd like) (?:you|her|tia) to\s+|(?:have|make) (?:tia|her)\s+)/;
  for(let i=0;i<5;i++)value=value.replace(prefix,'');
  value=value.replace(/(?:[,，]? (?:please|pls|plz|thanks|thank you|tia))+$/,'')
    .replace(/\b(?:cusor|curser)\b/g,'cursor').replace(/\bkong[ -]?fu\b/g,'kung fu');
  return value;
};

export function avatarIntent(text) {
  const value=normalizeRequest(text);
  const pointer='(?:(?:my|the|this) )?(?:mouse(?: cursor| pointer)?|cursor|pointer)';
  const suffix='(?: (?:around|around (?:the )?(?:screen|window|desktop)|on (?:the )?(?:screen|desktop)|across (?:the )?(?:screen|window)))?';
  const follow=new RegExp(`^(?:(?:follow|chase|track) (?:${pointer}|me)|(?:walk|move|come|go) (?:with|along with|after) (?:${pointer}|me)|(?:start|keep|continue) (?:following|chasing|tracking) (?:${pointer}|me)|(?:start|keep|continue) (?:walking|moving) (?:with|along with) (?:${pointer}|me)|(?:follow|move|walk|go) (?:wherever|where) (?:i move ${pointer}|${pointer} (?:goes|moves))|follow)${suffix}$`);
  const stop=new RegExp(`^(?:stop|stay|stay (?:there|here|still)|stop moving|freeze|(?:stop|quit) (?:following|chasing|tracking|walking with|moving with)(?: (?:${pointer}|me))?|(?:don't|do not) (?:follow|chase|track)(?: (?:${pointer}|me))?)$`);
  if(stop.test(value))return 'stay';
  if(follow.test(value))return 'follow';
  const commands=[
    ['reactions-on',/^(?:enable|turn on|start) (?:dynamic motions|dynamic reactions|conversation reactions|reacting to (?:chat|conversation))$/],
    ['reactions-off',/^(?:(?:disable|turn off|stop) (?:dynamic motions|dynamic reactions|conversation reactions|reacting)|(?:don't|do not) react)$/],
    ['stay',/^(?:别动|停下|停止跟随(?:鼠标|光标)?)$/],
    ['follow',/^(?:请)?(?:跟着我|跟随(?:我的)?(?:鼠标|光标)|跟着(?:我的)?(?:鼠标|光标)(?:走|移动)?)$/],
    ['come',/^(?:come here|come to me|walk here|walk to (?:me|my cursor|the cursor)|过来)$/],
    ['wave',/^(?:wave(?: to me| hello)?|say hi|say hello|hello tia|hi tia|挥手|打个招呼)$/],
    ['heart',/^(?:heart|heart pose|show (?:me )?(?:a |the )?heart(?: pose| ?shape)?|make (?:a )?heart(?: ?shape)?|比心)$/],
    ['sit',/^(?:sit|sit down|take a seat|坐下)$/],
    ['stand',/^(?:stand|stand up|standing pose|站起来)$/],
    ['random-dance',/^(?:do|play|show|perform|try)(?: me)? (?:a |some )?random dance$/],
    ['random-motion',/^(?:do|play|show|perform|try)(?: me)? (?:a |some )?random (?:motion|motions|move|moves)$/],
    ['dance',/^(?:dance|dance for me|do a dance|let'?s dance|跳舞)$/],
  ];
  return commands.find(([,pattern])=>pattern.test(value))?.[0]||null;
}

export function motionIntent(text, clips) {
  const value=normalizeRequest(text).replace(/^(?:do|play|show|perform|try)(?: me)? (?:the |a |an |some )?/,'')
    .replace(/ (?:motion|animation|gesture|pose)$/,'');
  for(const clip of clips.values()){
    const names=[clip.label,clip.id.replace(/[-_]/g,' '),...(Array.isArray(clip.aliases)?clip.aliases:[])];
    if(names.some(name=>typeof name==='string'&&normalizeRequest(name)===value))return `clip:${clip.id}`;
  }
  return null;
}

// A direct-chat model can suggest a category in its normal reply. Other
// providers use conservative local context matching. Neither chooses URLs,
// runs tools, or spends generation credits. Negative context takes priority.
export function conversationReaction(user, reply, suggestion) {
  const clean=text=>String(text||'').slice(0,6000).replace(/```[\s\S]*?```/g,'').toLowerCase();
  const u=clean(user),a=clean(reply),both=u+' '+a;
  if(!a.trim()||avatarIntent(user))return null;
  if(/\b(?:died|death|grief|grieving|mourning|funeral|heartbroken|suicid\w*|cancer|devastated|terrified|heart attack)\b|去世|葬礼|悲痛|自杀|癌症/.test(both))return null;
  if(/\b(?:not happy|unhappy|not celebrating|don't celebrate|do not celebrate|not funny|isn't funny|stop reacting)\b|别庆祝|不开心|别跳舞/.test(both))return null;
  const allowed=['affection','celebration','amusement','greeting','agreement','gratitude','curiosity','empathy'];
  if(/^(?:please )?(?:be happy|cheer up|be cheerful|开心点|开心一点)[.!?。！]?$/i.test(u.trim())
    && /cheerful|upbeat|brighten|happy|celebrat|开心|快乐/.test(a))return 'celebration';
  if(suggestion==='none')return null;
  if(allowed.includes(suggestion))return suggestion;
  if(/\b(?:love you|you mean (?:a lot|so much) to me|sending (?:you )?(?:a hug|love)|you're (?:so )?(?:sweet|kind)|you are (?:so )?(?:sweet|kind))\b|爱你|给你一个拥抱|你真贴心/.test(both))return 'affection';
  if(/\b(?:congratulations|congrats|we did it|you did it|happy birthday|let's celebrate|that's wonderful news|so proud of you|so happy for you|well done|you nailed it|that's (?:great|fantastic|amazing|wonderful)(?: news)?)\b|恭喜|生日快乐|太棒了|为你骄傲/.test(a))return 'celebration';
  if(/\b(?:hahaha|haha|hehe|hilarious|made me laugh)\b|哈哈|笑出声/.test(a))return 'amusement';
  if(/^(?:hi|hello|hey|good morning|good evening|welcome back)\b|^(?:你好|早上好|欢迎回来)/.test(a))return 'greeting';
  if(/\b(?:thank you so much|really appreciate (?:you|your help)|thanks for being)\b|非常感谢|谢谢你的/.test(a))return 'gratitude';
  if(/\b(?:you're right|you are right|i agree|exactly right)\b|你说得对|我同意/.test(a))return 'agreement';
  return null;
}

export class CompanionController {
  constructor({random=Math.random}={}){this.random=random;this.follow=false;this.come=false;this.walking=false;this.yaw=0;this.at=0;this.pauseUntil=0;this.velocityX=0;this.velocityY=0;this.gestures=true;this.wasSpeaking=false;this.gestureAt=-Infinity;
    this.reactions=true;this.pendingReaction=null;this.reactionAt=-Infinity;this.reactionKey='';this.lastReactionClip='';}
  consider(user,reply,suggestion,now){
    const key=String(user).slice(-1000)+'\n'+String(reply).slice(0,2000);
    if(!this.reactions||now-this.reactionAt<20000||key===this.reactionKey)return;
    this.reactionKey=key;
    const kind=conversationReaction(user,reply,suggestion);
    this.pendingReaction=kind?{kind,expires:now+12000}:null;
  }
  takeReaction(now,clips,blocked=false,{hasProp=false}={}){
    const pending=this.pendingReaction;
    if(!this.reactions||!pending||now>pending.expires){this.pendingReaction=null;return null;}
    if(blocked||now<this.pauseUntil)return null;
    const choices=[...clips.values()].filter(c=>Array.isArray(c.reactions)&&c.reactions.includes(pending.kind)
      &&!(hasProp&&c.requiresFreeHands));
    const fresh=choices.filter(c=>c.id!==this.lastReactionClip);
    const pool=fresh.length?fresh:choices;
    const clip=pool[Math.min(pool.length-1,Math.floor(Math.max(0,this.random())*pool.length))];
    this.pendingReaction=null;
    if(!clip)return null;
    this.lastReactionClip=clip.id;this.reactionAt=now;
    return clip.id;
  }
  gesture(now,speaking,reduce=false){
    if(speaking&&!this.wasSpeaking)this.gestureAt=now;
    this.wasSpeaking=speaking;
    const t=(now-this.gestureAt)/1200;
    return {pitch:this.gestures&&!reduce&&t>=0&&t<1?Math.sin(t*Math.PI*2)*Math.sin(t*Math.PI)*.065:0};
  }
  command(action){
    this.pendingReaction=null;
    if(action==='stay')this.reactions=false;
    this.come=action==='come';
    this.follow=action==='follow';
    this.walking=false;this.velocityX=0;this.velocityY=0;
    if(action==='follow'||action==='come')this.pauseUntil=0;
  }
  pause(now){this.pauseUntil=now+3000;this.velocityX=0;this.velocityY=0;this.walking=false;this.pendingReaction=null;}
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
  summary.textContent='Dynamic motions';details.append(summary);
  const status=document.createElement('p');status.setAttribute('role','status');
  const buttons=document.createElement('div');buttons.className='avatar-motion-actions';
  const actions=[['follow','Walk with cursor'],['come','Come here'],['wave','Wave'],['heart','Heart'],['sit','Sit'],['stand','Stand'],['dance','Dance'],['stay','Stop / stay']];
  const follow=document.createElement('button');
  for(const [action,label] of actions){
    const button=action==='follow'?follow:document.createElement('button');
    button.type='button';button.textContent=label;
    const clip=action==='follow'||action==='come'?'walk':action==='dance'&&avatar.motion?.clips.has('joyful-sway')?'joyful-sway':action;
    if(['wave','dance','follow','come'].includes(action)&&!avatar.motion?.clips.has(clip))continue;
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
  const reactionRow=document.createElement('label'), reactionLabel=document.createElement('span'), reactions=document.createElement('input');
  reactionLabel.textContent='React to conversation';reactions.type='checkbox';reactions.setAttribute('aria-label','React to conversation');
  reactions.addEventListener('change',()=>{void onAction('reactions');reactions.checked=avatar.companion.reactions;});
  reactionRow.append(reactionLabel,reactions);
  const library=document.createElement('details'), libraryLabel=document.createElement('summary');
  libraryLabel.textContent='Browse motions';library.append(libraryLabel);
  const search=document.createElement('input');search.type='search';search.placeholder='Search dances, gestures, kung fu…';search.setAttribute('aria-label','Search motions');
  const category=document.createElement('select');category.setAttribute('aria-label','Motion category');
  for(const name of ['All motions',...new Set([...avatar.motion.clips.values()].map(c=>c.category||'Other'))]){
    const option=document.createElement('option');option.value=name;option.textContent=name;category.append(option);
  }
  const choose=document.createElement('select');choose.setAttribute('aria-label','Motion');
  const play=document.createElement('button');play.type='button';play.textContent='Play motion';
  const refreshLibrary=()=>{
    const selected=choose.value;choose.replaceChildren();
    for(const clip of avatar.motion.clips.values()){
      if(category.value!=='All motions'&&(clip.category||'Other')!==category.value)continue;
      if(!`${clip.label} ${clip.id} ${(clip.aliases||[]).join(' ')}`.toLowerCase().includes(search.value.toLowerCase()))continue;
      const option=document.createElement('option');option.value=clip.id;option.textContent=clip.label||clip.id;choose.append(option);
    }
    if([...choose.options].some(o=>o.value===selected))choose.value=selected;
    play.disabled=!choose.value;
  };
  search.addEventListener('input',refreshLibrary);category.addEventListener('change',refreshLibrary);
  play.addEventListener('click',()=>{if(choose.value)void onAction(`clip:${choose.value}`).then(message=>{status.textContent=message;refresh();}).catch(error=>{status.textContent=error.message;});});
  library.append(search,category,choose,play);refreshLibrary();
  details.append(buttons,library,row,reactionRow,status,hint);container.append(details);
  const refresh=()=>{follow.setAttribute('aria-pressed',String(avatar.companion.follow));gestures.checked=avatar.companion.gestures;reactions.checked=avatar.companion.reactions;};
  window.addEventListener('openclam-avatar-controls-refresh',refresh);
  refresh();return ()=>{window.removeEventListener('openclam-avatar-controls-refresh',refresh);details.remove();};
}
