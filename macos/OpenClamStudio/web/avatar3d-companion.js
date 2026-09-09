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

// Finite destinations are capabilities, never arbitrary code or coordinates
// supplied by the model. Coordinates are in the viewer's screen, top = far.
export const stageDestinations = Object.freeze({
  'go-upper-left':{x:.04,y:.04}, 'go-upper-right':{x:.96,y:.04},
  'go-lower-left':{x:.04,y:.96}, 'go-lower-right':{x:.96,y:.96},
  'go-top':{x:.5,y:.04}, 'go-bottom':{x:.5,y:.96},
  'go-left':{x:.04,y:.5}, 'go-right':{x:.96,y:.5}, 'go-center':{x:.5,y:.5},
});
export const isSpatialAction = action => ['closer','back','follow','come','walk-around','run-around','stay'].includes(action)
  || Object.hasOwn(stageDestinations,action);
const destinationIntent = value => {
  const match=value.replace(/-/g,' ').replace(/(left|right) (upper|top|lower|bottom)/g,'$2 $1').replace(/ and (?:stay|stop|wait)(?: (?:there|here))?$/,'').match(/^(?:go|walk|move|head|come|run|jog)(?: over| back)? (?:to|into|toward|towards) (?:the )?((?:upper|top|lower|bottom) (?:left|right)|(?:upper|top|lower|bottom|left|right|center|centre|middle))(?: (?:corner|side|edge))?(?: (?:of|in|on) (?:the |my |this )?(?:screen|chat(?: window)?|window|desktop))?$/);
  if(!match)return null;
  const name=match[1].replace('top','upper').replace('bottom','lower').replace(/centre|middle/,'center').replace(' ','-');
  return 'go-'+({upper:'top',lower:'bottom'}[name]||name);
};

export function avatarIntent(text) {
  const value=normalizeRequest(text);
  const pointer='(?:(?:my|the|this) )?(?:mouse(?: cursor| pointer)?|cursor|pointer)';
  const suffix='(?: (?:around|around (?:the )?(?:screen|window|desktop)|on (?:the )?(?:screen|desktop)|across (?:the )?(?:screen|window)))?';
  const follow=new RegExp(`^(?:(?:follow|chase|track) (?:${pointer}|me)|(?:walk|move|come|go) (?:with|along with|after) (?:${pointer}|me)|(?:start|keep|continue) (?:following|chasing|tracking) (?:${pointer}|me)|(?:start|keep|continue) (?:walking|moving) (?:with|along with) (?:${pointer}|me)|(?:follow|move|walk|go) (?:wherever|where) (?:i move ${pointer}|${pointer} (?:goes|moves))|follow)${suffix}$`);
  const stop=new RegExp(`^(?:stop|stay|stay (?:there|here|still)|stop (?:moving|walking|running|wandering|roaming)(?: around)?|freeze|(?:stop|quit) (?:following|chasing|tracking|walking with|moving with)(?: (?:${pointer}|me))?|(?:don't|do not) (?:follow|chase|track)(?: (?:${pointer}|me))?)$`);
  if(stop.test(value))return 'stay';
  if(follow.test(value))return 'follow';
  const destination=destinationIntent(value);if(destination)return destination;
  const commands=[
    ['closer',/^(?:(?:(?:come|walk|move|step) )?(?:even |a (?:bit|little) )?closer(?: to (?:me|the camera))?(?: again)?|靠近(?:一点|点)?|走近一点)$/],
    ['back',/^(?:(?:step|walk|move|go) (?:back|(?:further|farther) away)(?: a (?:bit|little))?(?: again)?|back up|(?:further|farther)(?: away)?|退后(?:一点|点)?)$/],
    ['walk-around',/^(?:walk|start walking|(?:walk|move|wander|stroll|roam) around(?: (?:the |my |this )?(?:whole |entire )?(?:screen|chat(?: window)?|window|desktop))?|walk across (?:the |my )?(?:screen|window)|到处走走|在屏幕上走动)$/],
    ['run-around',/^(?:run|start running|(?:run|jog) around(?: (?:the |my |this )?(?:whole |entire )?(?:screen|chat(?: window)?|window|desktop))?|run across (?:the |my )?(?:screen|window)|到处跑跑|在屏幕上跑动)$/],
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

// Vocabulary describes installed animations, never an executable tool or URL.
// Keep this shared by iOS and macOS so older motion packages also benefit.
const motionVocabulary = {
  'kung-fu-punch':['kung fu','kungfu','martial arts','karate','kung fu punching','功夫','打功夫','打拳'],
  'boxing-practice':['boxing','box','shadow boxing','shadowboxing','practice boxing','练拳'],
  'boxing-warm-up':['boxing warmup','warm up','warmup','热身'],
  'simple-kick':['kick','kicking','踢腿'],
  'roundhouse-kick':['roundhouse','回旋踢'],
  'jump-rope':['skip rope','skipping rope','skipping','跳绳'],
  'jumping-jacks':['jumping jack','work out','workout','exercise','开合跳'],
  'happy-jump-female':['jump','jump for joy','happy jump','跳一下'],
  'sit-cross-legged':['sit cross legged','cross legged','sit on the floor','盘腿坐'],
  'kneel-on-one-knee-and-stand':['kneel','take a knee','单膝跪地'],
  'half-squat-with-thumb-up':['squat','thumbs up','thumb up','点赞','深蹲'],
  'gangnam-groove':['gangnam','gangnam style','江南style'],
  'hip-hop-dance':['hip hop','hiphop','街舞'],
  'jazz-dance':['jazz','爵士舞'],
  'ymca-dance':['ymca'],
  'joyful-sway':['happy dance','joyful dance','dance for me','跳舞'],
  'penguin-walk':['walk like a penguin','waddle like a penguin','penguin','企鹅走路'],
  'confident-strut':['strut','catwalk','walk confidently','走秀'],
  'casual-walk':['go for a walk','take a walk','散步'],
  'formal-bow':['bow','take a bow','鞠躬'],
  'shrug':['shrug your shoulders','耸肩'],
  'finger-wag-no':['wag your finger','shake your finger','摇手指'],
  'victory-fist-pump':['fist pump','pump your fist'],
  'heart-gesture':['overhead heart','make a big heart','比个大心'],
};
const motionWords = text => normalizeRequest(text).replace(/\b(?:kung|kong)[ -]?fu\b/g,'kung fu')
  .replace(/[-_]/g,' ').replace(/[^\p{L}\p{N}' ]/gu,' ').replace(/\s+/g,' ').trim();
const hasMotionWords = (text,name) => name && (` ${text} `.includes(` ${name} `)
  || /[\u3400-\u9fff]/.test(name) && text.includes(name));
const motionNames = clip => [...new Set([clip.label,clip.id,...(Array.isArray(clip.aliases)?clip.aliases:[]),
  ...(motionVocabulary[clip.id]||[])].filter(name=>typeof name==='string').map(motionWords))];

export function motionIntent(text, clips) {
  const raw=normalizeRequest(text), words=motionWords(text);
  if(!words||!clips?.size||/^["'`“”‘’>]|```/.test(raw)
    || /\b(?:not|don't|dont|never|stop|avoid|instead of|later|tomorrow|said|says|told|wrote|quote|explain|describe|history|meaning|write|teach|learn|tutorial|recipe|movie|video|song|lyrics)\b/.test(words)
    || /不要|别跳|别做|不能|解释|历史|教程|电影/.test(words))return null;
  const bare=words.replace(/^(?:do|play|show|perform|try|demonstrate)(?: me)? (?:the |a |an |some )?/,'')
    .replace(/ (?:motion|animation|gesture|pose)$/,'');
  let best=null,score=0;
  // Capability questions invite a demonstration. Educational or reported
  // mentions remain conversation, even if they contain an exact clip name.
  const invitation=/^(?:(?:do|did) (?:you|u) know(?: how to)?|(?:are|r) (?:you|u) (?:able to|good at)|(?:know|show|demonstrate|perform|try|do|play)|(?:let's|lets)|what about|how about)\b/.test(words)
    || /^(?:can|could|would|will) (?:you|u)\b/i.test(String(text).trim())
    || /^(?:你会|你能|会不会|能不能|来个|来一段|给我|表演|展示|试试|请)/.test(words);
  for(const clip of clips.values())for(const name of motionNames(clip)){
    const exact=name===bare;
    if(!exact&&!(invitation&&hasMotionWords(words,name)))continue;
    const rank=name.length+(exact?1000:0);
    if(rank>score){best=clip.id;score=rank;}
  }
  return best?`clip:${best}`:null;
}

const contextualClipTags = {
  confusion:['confused-scratch','shrug'],
  disagreement:['finger-wag-no'],
  explanation:['stand-and-chat','discuss-while-moving','talk-with-left-hand-raised','talk-with-hands-open','talk-with-right-hand-open'],
  encouragement:['motivational-cheer','cheer-with-one-hand-up','half-squat-with-thumb-up'],
  celebration:['victory-cheer','cheer-with-both-hands-up','cheer-with-one-hand-up','victory','victory-fist-pump','happy-jump-female'],
  amusement:['funny-dancing-1','happy-sway-standing'],
  curiosity:['short-breathe-and-look-around'],
  empathy:['listening-gesture'],
};

// A direct-chat model can suggest a category in its normal reply. Other
// providers use conservative local context matching. Neither chooses URLs,
// runs tools, or spends generation credits. Negative context takes priority.
// Conversation owns intent. A word in user input never starts an animation.
// Prefer a validated cue from the LLM's completed reply. Voice/connected agents
// without cue metadata can act only on an affirmative performance statement
// in the assistant's reply, using the user turn to resolve “I'll do that”.
const conversationalActions = new Set([...Object.keys(stageDestinations),'follow','come','closer','back','walk-around','run-around','wave','heart','sit','stand','dance','stay','random-dance','random-motion','reactions-on','reactions-off']);
export function replyAvatarAction(user, reply, suggestion, clips) {
  const text=String(reply||'').normalize('NFKC').replace(/[’‘]/g,"'").trim();
  if(!text || suggestion==='none')return null;
  const denied=/\b(?:can't|cannot|couldn't|won't|will not|unable|don't have a body|do not have a body|don't actually|only imagine|wish i could)\b|不能|无法|不会表演|没有身体/i.test(text);
  if(denied)return null;
  if(typeof suggestion==='string'){
    if(suggestion.startsWith('clip:') && clips?.has(suggestion.slice(5)))return suggestion;
    if(suggestion.startsWith('action:') && conversationalActions.has(suggestion.slice(7)))return suggestion;
  }
  // Questions, explanations and hypothetical/reported actions are not a
  // decision to perform. Acknowledging a topic such as “kung fu” is not one.
  // Repeated requests often receive “I'll keep walking…” from the LLM.
  // Normalize that affirmative continuation without acting on user input alone.
  const performanceText=text.replace(/\b(i(?:'ll| will)|let me)\s+(?:keep|continue)\s+(walking|running|moving|following)\b/gi,
    (_,speaker,verb)=>speaker+' '+({walking:'walk',running:'run',moving:'move',following:'follow'}[verb.toLowerCase()]));
  const performance = performanceText.match(/\b(?:i(?:'ll| will| am going to|'m going to)|let me|let's)\s+(?:(?:just|now|also|quickly)\s+)?((?:show|demonstrate|perform|try|do|give|dance|wave|follow|go|head|walk|run|jog|wander|stroll|roam|step|move|come|sit|stand|stop|stay|make|turn|enable|disable)\b[^.!?]*)(?:[.!]|$)/i);
  const presentation = text.match(/\bhere(?:'s| is) ((?:a |my |the )?(?:quick |little )?(?:dance|wave|heart|kung fu|punch|demonstration)\b[^.!?]*)(?:[.!]|$)/i);
  const chinese = text.match(/(?:我来|我会|给你表演)([^。！？?]+)/);
  const plain=performance?.[1]||presentation?.[1]||chinese?.[1];
  if(!plain || /\b(?:if|would|could|might|imagine|pretend|in my head|explain|describe|history|meaning|write|teach|learn|tutorial|movie|video|example|how to|about|code|script|tests|terminal|program|server)\b|假如|想象|解释|历史|教程/i.test(text))return null;
  const direct=avatarIntent(plain)||motionIntent(plain,clips);
  if(direct)return direct.startsWith('clip:')?direct:'action:'+direct;
  const words=motionWords(plain);
  let best=null,score=0;
  for(const clip of clips?.values()||[])for(const name of motionNames(clip)){
    if(hasMotionWords(words,name)&&name.length>score){best=clip.id;score=name.length;}
  }
  if(best)return 'clip:'+best;
  const requested=avatarIntent(user)||motionIntent(user,clips);
  if(requested && /\b(?:do that|give it a try|try it|do it|follow|dance|wave|sit|stand|heart|stop|closer|go|head|move|walk|run|jog|wander|stroll|step back)\b|试试|跳舞|比心|靠近|走走|跑跑/i.test(text))
    return requested.startsWith('clip:')?requested:'action:'+requested;
  return null;
}

export function conversationReaction(user, reply, suggestion) {
  const clean=text=>String(text||'').slice(0,6000).normalize('NFKC')
    .replace(/[’‘]/g,"'").replace(/```[\s\S]*?```/g,'').toLowerCase();
  const u=clean(user),a=clean(reply),both=u+' '+a;
  if(!a.trim()||suggestion==='none')return null;
  if(/\b(?:died|death|grief|grieving|mourning|funeral|heartbroken|suicid\w*|cancer|devastated|terrified|heart attack)\b|去世|葬礼|悲痛|自杀|癌症/.test(both))return null;
  if(/\b(?:not happy|unhappy|not celebrating|don't celebrate|do not celebrate|not funny|isn't funny|stop reacting)\b|别庆祝|不开心|别跳舞/.test(both))return null;
  const allowed=['affection','celebration','amusement','greeting','agreement','gratitude','curiosity','empathy'];
  if(/^(?:be (?:more )?(?:happy|cheerful|playful)|cheer up|开心点|开心一点)$/i.test(normalizeRequest(u))
    && /cheerful|upbeat|brighten|happy|celebrat|开心|快乐/.test(a))return 'celebration';
  if(suggestion==='none')return null;
  if(allowed.includes(suggestion))return suggestion;
  if(/\b(?:love you|you mean (?:a lot|so much) to me|sending (?:you )?(?:a hug|love)|you're (?:so )?(?:sweet|kind)|you are (?:so )?(?:sweet|kind))\b|爱你|给你一个拥抱|你真贴心/.test(both))return 'affection';
  if(/\b(?:congratulations|congrats|we did it|you did it|happy birthday|let's celebrate|that's wonderful news|so proud of you|so happy for you|well done|you nailed it|that's (?:great|fantastic|amazing|wonderful)(?: news)?)\b|恭喜|生日快乐|太棒了|为你骄傲/.test(a))return 'celebration';
  if(/\b(?:hahaha|haha|hehe|hilarious|made me laugh)\b|哈哈|笑出声/.test(a))return 'amusement';
  if(/^(?:hi|hello|hey|good morning|good evening|welcome back)\b|^(?:你好|早上好|欢迎回来)/.test(a))return 'greeting';
  if(/\b(?:thank you so much|really appreciate (?:you|your help)|thanks for being)\b|非常感谢|谢谢你的/.test(a))return 'gratitude';
  if(/\b(?:you're right|you are right|i agree|exactly right)\b|你说得对|我同意/.test(a))return 'agreement';
  if(/\b(?:i'm not sure|i am not sure|i don't know|i do not know|i'm confused|i am confused|i wonder|let me think)\b|我不确定|我不知道|让我想想/.test(a))return 'confusion';
  if(/\b(?:i disagree|that's not right|that isn't right|i don't think so)\b|我不同意|不是这样的/.test(a))return 'disagreement';
  if(/\b(?:you've got this|you can do it|keep going|don't give up|believe in you)\b|你可以的|加油|别放弃/.test(a))return 'encouragement';
  if(/\b(?:i'm here for you|i am here for you|that sounds (?:hard|difficult)|i understand how you feel)\b|我在听|理解你的感受/.test(a))return 'empathy';
  if(/\b(?:let me explain|here's how|here is how|for example|first of all|the reason is)\b|我来解释|举个例子|首先/.test(a))return 'explanation';
  return null;
}

export class CompanionController {
  constructor({random=Math.random}={}){this.random=random;this.follow=false;this.come=false;this.walking=false;this.yaw=0;this.at=0;this.pauseUntil=0;this.velocityX=0;this.velocityY=0;this.gestures=true;this.wasSpeaking=false;this.gestureAt=-Infinity;
    this.reactions=true;this.pendingReaction=null;this.reactionAt=-Infinity;this.reactionKey='';this.lastReactionClip='';this.reactedTurns=new Set();}
  consider(user,reply,suggestion,now,{clips,turnID=''}={}){
    const key=String(user).slice(-1000)+'\n'+String(reply).slice(0,2000);
    if(turnID?this.reactedTurns.has(turnID):key===this.reactionKey)return;
    const decision=replyAvatarAction(user,reply,suggestion,clips);
    if(!this.reactions&&(!decision||!(avatarIntent(user)||motionIntent(user,clips))))return;
    const clipID=decision?.startsWith('clip:')?decision.slice(5):null;
    const action=decision?.startsWith('action:')?decision:null;
    const kind=decision?null:conversationReaction(user,reply,suggestion);
    if(!decision&&now-this.reactionAt<20000)return;
    this.pendingReaction=kind||decision?{kind,clipID,action,key,turnID,expires:now+12000}:null;
  }
  takeReaction(now,clips,blocked=false,{hasProp=false}={}){
    const pending=this.pendingReaction;
    if(!pending||(!this.reactions&&!pending.action&&!pending.clipID)||now>pending.expires){this.pendingReaction=null;return null;}
    if(blocked||now<this.pauseUntil)return null;
    if(pending.action){
      this.pendingReaction=null;this.reactionKey=pending.key;this.reactionAt=now;
      if(pending.turnID){this.reactedTurns.add(pending.turnID);if(this.reactedTurns.size>64)this.reactedTurns.delete(this.reactedTurns.values().next().value);}
      return pending.action;
    }
    const choices=[...clips.values()].filter(c=>(pending.clipID?c.id===pending.clipID:
      (Array.isArray(c.reactions)&&c.reactions.includes(pending.kind))||contextualClipTags[pending.kind]?.includes(c.id))
      &&!(hasProp&&c.requiresFreeHands));
    const fresh=choices.filter(c=>c.id!==this.lastReactionClip);
    const pool=fresh.length?fresh:choices;
    const clip=pool[Math.min(pool.length-1,Math.floor(Math.max(0,this.random())*pool.length))];
    this.pendingReaction=null;
    if(!clip)return null;
    this.lastReactionClip=clip.id;this.reactionAt=now;this.reactionKey=pending.key;
    if(pending.turnID){this.reactedTurns.add(pending.turnID);if(this.reactedTurns.size>64)this.reactedTurns.delete(this.reactedTurns.values().next().value);}
    return pending.clipID?'action:clip:'+clip.id:clip.id;
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
    this.cameraFocus=action==='closer';
    this.follow=action==='follow';
    this.roam=['walk-around','run-around'].includes(action)?action:null;
    this.route=null; this.routePauseUntil=0;
    this.destination=stageDestinations[action]?{...stageDestinations[action]}:null;
    this.walking=false;this.speed=0;this.velocityX=0;this.velocityY=0;
    if(isSpatialAction(action))this.pauseUntil=0;
  }
  pause(now){this.pauseUntil=now+3000;this.speed=0;this.velocityX=0;this.velocityY=0;this.walking=false;this.cameraFocus=false;this.pendingReaction=null;this.roam=null;this.route=null;this.destination=null;}
  step(now,{cursorX,anchorX,cursorY=0,anchorY=0,minX=-Infinity,maxX=Infinity,minY=-Infinity,maxY=Infinity,height=500,blocked=false,reduce=false,seen=true,worldPoint=null,strideSpeed=0,projected=false}={}){
    const dt=this.at?Math.min(.05,Math.max(0,(now-this.at)/1000)):0;this.at=now;
    const areaValid=[minX,maxX,minY,maxY].every(Number.isFinite)&&maxX>=minX&&maxY>=minY;
    if(this.roam&&areaValid){
      if(!this.route){
        // Store fractions of the available area: native window movement and
        // resizing may change local coordinates while a route is underway.
        let best=null, farthest=-1;
        for(let i=0;i<8;i++){
          const candidate={x:.06+this.random()*.88,y:.06+this.random()*.88};
          const d=Math.hypot(minX+(maxX-minX)*candidate.x-anchorX,minY+(maxY-minY)*candidate.y-anchorY);
          if(d>farthest){farthest=d;best=candidate;}
        }
        this.route=best;
      }
      cursorX=minX+(maxX-minX)*this.route.x;cursorY=minY+(maxY-minY)*this.route.y;seen=true;
      if(now<this.routePauseUntil)blocked=true;
    }
    if(this.destination&&areaValid){
      cursorX=minX+(maxX-minX)*this.destination.x;cursorY=minY+(maxY-minY)*this.destination.y;seen=true;
    }
    const valid=[cursorX,cursorY,anchorX,anchorY,height].every(Number.isFinite);
    const active=(this.follow||this.come||((this.roam||this.destination)&&areaValid))&&seen&&valid&&!reduce&&!blocked&&now>=this.pauseUntil;
    const dx=Math.max(minX,Math.min(maxX,cursorX))-anchorX;
    const dy=Math.max(minY,Math.min(maxY,cursorY))-anchorY;
    const distance=Math.hypot(dx,dy), stop=this.destination?1:Math.max(18,Math.min(40,height*.06));
    const want=active&&distance>(this.walking||this.destination?stop:stop+14);
    const a=worldPoint?.(anchorX,anchorY),b=worldPoint?.(anchorX+dx,anchorY+dy);
    const wx=a&&b?b.x-a.x:dx,wz=a&&b?b.z-a.z:dy,worldDistance=Math.hypot(wx,wz);
    // Turning and translation share one heading. Brake before a sharp turn;
    // when moving, velocity always points along the body's forward axis.
    const goalYaw=want?Math.atan2(-wx,wz):0;
    const error=Math.atan2(Math.sin(goalYaw-this.yaw),Math.cos(goalYaw-this.yaw));
    this.yaw+=projected?error:Math.max(-dt*2.8,Math.min(dt*2.8,error));
    this.yaw=Math.atan2(Math.sin(this.yaw),Math.cos(this.yaw));
    const remaining=Math.abs(Math.atan2(Math.sin(goalYaw-this.yaw),Math.cos(goalYaw-this.yaw)));
    const cruise=strideSpeed>0?strideSpeed:this.roam==='run-around'?Math.max(80,Math.min(340,height*.7)):Math.max(40,Math.min(190,height*.28));
    const turnGain=Math.max(0,1-remaining/(Math.PI/4));
    const desired=want?Math.min(cruise,worldDistance*Math.max(0,1-stop/distance)*2.5)*turnGain:0;
    this.speed=(this.speed||0)+(desired-(this.speed||0))*(1-Math.exp(-dt/.16));
    if(!active||!want||remaining>Math.PI/4)this.speed=0;
    this.velocityY=Math.cos(this.yaw)*this.speed||0;
    this.velocityX=-Math.sin(this.yaw)*this.speed||0;
    this.walking=want;
    if(this.come&&!this.walking&&active)this.come=false;
    if(this.destination&&!this.walking&&active)this.destination=null;
    if(this.roam&&!this.walking&&active){this.route=null;this.routePauseUntil=now+(this.roam==='run-around'?200:750);}
    return {dx:this.velocityX*dt,dy:this.velocityY*dt,walking:this.walking,yaw:this.yaw,
      gaitRate:strideSpeed>0?this.speed/strideSpeed:1,arrived:active&&!this.walking};
  }
}

export function mountCompanionControls(container,avatar,key,onAction) {
  const details=document.createElement('details'), summary=document.createElement('summary');
  summary.textContent='Dynamic motions';details.append(summary);
  const status=document.createElement('p');status.setAttribute('role','status');
  const buttons=document.createElement('div');buttons.className='avatar-motion-actions';
  const actions=[['follow','Walk with cursor'],['come','Come here'],['closer','Come closer'],['back','Step back'],['walk-around','Walk around'],['run-around','Run around'],['wave','Wave'],['heart','Heart'],['sit','Sit'],['stand','Stand'],['dance','Dance'],['stay','Stop / stay']];
  const follow=document.createElement('button');
  for(const [action,label] of actions){
    const button=action==='follow'?follow:document.createElement('button');
    button.type='button';button.textContent=label;
    const clip=['follow','come','closer','back','walk-around'].includes(action)?'walk':action==='run-around'?'hello-run':action==='dance'&&avatar.motion?.clips.has('joyful-sway')?'joyful-sway':action;
    if(['wave','dance','follow','come','closer','back','walk-around','run-around'].includes(action)&&!avatar.motion?.clips.has(clip))continue;
    button.addEventListener('click',async()=>{status.textContent='';try{status.textContent=await onAction(action,{toggleFollow:action==='follow'});}catch(error){status.textContent=error.message;}refresh();});
    buttons.append(button);
  }
  const places=document.createElement('select');places.setAttribute('aria-label','Walk to');
  for(const [id,label] of [['','Walk to…'],['go-upper-left','Upper left'],['go-top','Top'],['go-upper-right','Upper right'],['go-left','Left'],['go-center','Center'],['go-right','Right'],['go-lower-left','Lower left'],['go-bottom','Bottom'],['go-lower-right','Lower right']]){
    const option=document.createElement('option');option.value=id;option.textContent=label;places.append(option);
  }
  places.addEventListener('change',()=>{const id=places.value;if(id)void onAction(id).catch(error=>{status.textContent=error.message;});places.value='';});
  buttons.append(places);
  const hint=document.createElement('p');
  hint.textContent='Try “go to the upper-right corner”, “go to the center”, “come closer”, “closer again”, “step back”, “walk around”, “run around”, “follow my cursor” or “stay”. Drag, pinch, and rotation take control of movement.';
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

// One studio coordinate owns both location and distance. The compositor uses
// reciprocal depth (the perspective size law), with a fixed lens and unchanged
// model/bone scales. Resting, dancing and walking use this same projection.
export class AvatarStudioStage {
  constructor(fit, layout, surface) {
    this.bounds=[...layout.bounds];this.face=[...(layout.faceBounds||layout.bounds)];
    this.x=.5;this.y=.5;
    this.normalRatio=fit.scale/surface.height;
    this.nearScale=this.clamp(Math.min(surface.width/(this.face[2]*fit.scale),surface.height/(this.face[3]*fit.scale))*1.12,2,32);
    const framing=this.framing(fit.scale,surface);
    const cx=fit.x+framing.point.x*fit.scale,cy=fit.y+framing.point.y*fit.scale;
    this.x=this.fraction(cx,surface.x,surface.width,framing.mx);
    // The user's chosen resting size defines the studio's middle distance,
    // even when the old 2D placement was low in the window. Ease its residual
    // placement into the stage on the first walk, without a startup jump.
    const centered=this.project(surface);
    this.entryOffset={x:fit.x-centered.x,y:fit.y-centered.y};
    this.entryWeight=1;
    this.manualFit=null;
  }
  clamp(value,min=0,max=1){return Math.max(min,Math.min(max,Number.isFinite(value)?value:0));}
  calibrate(avatar){
    const bounds=avatar.restBounds||avatar.bounds;
    this.modelHeight=bounds.max.y-bounds.min.y;
    this.cameraDistance=avatar.studioDistance;
    this.projection=avatar.studioProjection();this.facingYaw=avatar.orbit.yaw;
  }
  fraction(value,start,length,margin){return this.clamp((value-start-margin)/Math.max(1,length-2*margin));}
  depthScale(y=this.y){
    const t=this.clamp(y);
    const distance=t<=.5?3-(t*2)*2:1-((t-.5)*2)*(1-1/this.nearScale);
    return 1/distance;
  }
  depthForScale(scale){
    const distance=1/this.clamp(scale,1/3,this.nearScale);
    return distance>=1?(3-distance)/4:.5+(1-distance)/(2*(1-1/this.nearScale));
  }
  destination(action,surface){
    if(stageDestinations[action])return {...stageDestinations[action]};
    if(action==='back')return {x:this.x,y:Math.max(0,this.y-.22)};
    if(action==='closer'){
      const normal=this.normalRatio*surface.height;
      const faceFit=Math.min(surface.width/(this.face[2]*normal),surface.height/(this.face[3]*normal));
      const current=this.depthScale();
      const target=Math.max(current*1.18,faceFit*.82);
      return {x:.5,y:Math.max(this.y,this.depthForScale(target))};
    }
    return null;
  }
  framing(scale,surface){
    const b=this.bounds,f=this.face;
    // Keep the complete figure while it fits. On approach, smoothly favor
    // the face; legs can leave the shot without clipping the crown/eyes.
    const t=this.clamp((b[3]*scale/surface.height-.9)/1.1),u=t*t*(3-2*t);
    const rect=b.map((v,i)=>v+(f[i]-v)*u);
    return {point:{x:rect[0]+rect[2]/2,y:rect[1]+rect[3]/2},
      mx:Math.min(surface.width*.49,rect[2]*scale/2+12),
      my:Math.min(surface.height*.49,rect[3]*scale/2+12)};
  }
  project(surface){
    const scale=this.normalRatio*surface.height*this.depthScale();
    const f=this.framing(scale,surface);
    return {scale,x:surface.x+f.mx+this.x*(surface.width-2*f.mx)-f.point.x*scale+(this.entryOffset?.x||0)*(this.entryWeight||0),
      y:surface.y+f.my+this.y*(surface.height-2*f.my)-f.point.y*scale+(this.entryOffset?.y||0)*(this.entryWeight||0)};
  }
  // Screen pointer positions map to the whole stage, not only the narrow
  // leftover space around a large bounding box.
  step(controller,now,surface,{cursorX=0,cursorY=0,seen=false,blocked=false,reduce=false,strideSpeed=0}={}){
    const dt=this.at?this.clamp((now-this.at)/1000,0,.05):0;this.at=now;
    const modelHeight=this.modelHeight||2, cameraDistance=this.cameraDistance||modelHeight*2.5;
    const width=surface.width*modelHeight/(this.bounds[3]*this.normalRatio*surface.height);
    const worldPoint=(x,y)=>{const d=1/this.depthScale(y/surface.height);return {x:(x/surface.width-.5)*width*d,z:cameraDistance*(1-d)};};
    const result=controller.step(now,{cursorX:cursorX-surface.x,cursorY:cursorY-surface.y,
      anchorX:this.x*surface.width,anchorY:this.y*surface.height,minX:0,maxX:surface.width,minY:0,maxY:surface.height,
      height:this.bounds[3]*this.normalRatio*surface.height*this.depthScale(),seen,blocked,reduce,worldPoint,
      strideSpeed:strideSpeed||modelHeight*(controller.roam==='run-around'?1.25:.5),projected:true});
    // Integrate on the studio floor, then project the new position exactly.
    // This also crosses the middle-distance boundary without a heading kink.
    const before=worldPoint(this.x*surface.width,this.y*surface.height),oldX=this.x,oldY=this.y,oldEntry=this.entryWeight;
    const projection=this.projection||{ground:{x:this.bounds[0]+this.bounds[2]/2,y:this.bounds[1]+this.bounds[3]},
      pixelsPerUnit:this.bounds[3]/modelHeight,groundDepth:modelHeight*.5/cameraDistance};
    const foot=fit=>({x:fit.x+projection.ground.x*fit.scale,y:fit.y+projection.ground.y*fit.scale});
    const startFit=this.project(surface),startFoot=foot(startFit);
    const propose=factor=>{
      const depth=this.clamp(1-(before.z+result.dy*factor)/cameraDistance,1/this.nearScale,3);
      this.x=this.clamp((before.x+result.dx*factor)/(width*depth)+.5);this.y=this.depthForScale(1/depth);
      this.entryWeight=oldEntry*(result.walking?Math.exp(-dt*factor/.45):1);
      return foot(this.project(surface));
    };
    const candidate=propose(1),vx=candidate.x-startFoot.x,vy=candidate.y-startFoot.y;
    const pixels=Math.hypot(vx,vy);
    // The compositor reframes and scales the actor as depth changes. Aim
    // using that *visible* ground path, not the invisible planning plane.
    const desiredYaw=result.walking&&pixels>1e-7?Math.atan2(-vx,vy/projection.groundDepth):0;
    const previousYaw=this.facingYaw??0;
    const error=Math.atan2(Math.sin(desiredYaw-previousYaw),Math.cos(desiredYaw-previousYaw));
    const paused=blocked||reduce||now<controller.pauseUntil;
    this.facingYaw=previousYaw+(paused?0:Math.max(-dt*2.8,Math.min(dt*2.8,error)));
    this.facingYaw=Math.atan2(Math.sin(this.facingYaw),Math.cos(this.facingYaw));
    const remaining=Math.abs(Math.atan2(Math.sin(desiredYaw-this.facingYaw),Math.cos(desiredYaw-this.facingYaw)));
    const canMove=!paused&&remaining<.035&&result.walking;
    this.travelGain=(this.travelGain||0)+((canMove?1:0)-(this.travelGain||0))*(1-Math.exp(-dt/.16));
    if(!canMove)this.travelGain=0;
    const stride=strideSpeed||modelHeight*(controller.roam==='run-around'?1.25:.5);
    const pixelsPerStride=projection.pixelsPerUnit*startFit.scale
      *Math.hypot(Math.sin(this.facingYaw),projection.groundDepth*Math.cos(this.facingYaw))*stride;
    const requestedRate=dt>0&&pixelsPerStride>0?pixels/dt/pixelsPerStride:0;
    // Natural cadence limits translation as well as animation. Clamping the
    // clip alone would leave the avatar skating whenever depth compresses it.
    let factor=this.travelGain*Math.min(1,1.15/Math.max(requestedRate,1e-9));
    let finish=propose(factor);
    const limit=pixelsPerStride*dt*1.15;
    if(Math.hypot(finish.x-startFoot.x,finish.y-startFoot.y)>limit){
      let lo=0,hi=factor;
      for(let i=0;i<8;i++){
        const mid=(lo+hi)/2,p=propose(mid);
        if(Math.hypot(p.x-startFoot.x,p.y-startFoot.y)>limit)hi=mid;else lo=mid;
      }
      factor=lo;finish=propose(factor);
    }
    const actualRate=dt>0&&pixelsPerStride>0?Math.hypot(finish.x-startFoot.x,finish.y-startFoot.y)/dt/pixelsPerStride:0;
    return {...result,dx:(this.x-oldX)*surface.width,dy:(this.y-oldY)*surface.height,
      yaw:this.facingYaw,gaitRate:actualRate};
  }
  manual(fit,surface){
    const previous=this.manualFit;
    if(previous){
      this.normalRatio*=fit.scale/previous.scale;
      // Compare the same logical center so pinch does not accidentally pan.
      const b=this.bounds,cx=b[0]+b[2]/2,cy=b[1]+b[3]/2;
      this.x=this.clamp(this.x+(fit.x+cx*fit.scale-previous.x-cx*previous.scale)/surface.width);
      this.y=this.clamp(this.y+(fit.y+cy*fit.scale-previous.y-cy*previous.scale)/surface.height);
    }
    this.manualFit={...fit};
  }
}
