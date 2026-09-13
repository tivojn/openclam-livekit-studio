'use strict';

const clamp=(n,min,max)=>Math.max(min,Math.min(max,n));
function companionBubbleBounds(anchor,area,height=152) {
  const width=Math.min(360,area.width-16);
  height=Math.min(height,area.height-16);
  const above=anchor.y-height-12;
  const x=above>=area.y+8?anchor.x-width/2
    :anchor.x+24+width<=area.x+area.width?anchor.x+24:anchor.x-width-24;
  return {x:Math.round(clamp(x,area.x+8,area.x+area.width-width-8)),
    y:Math.round(clamp(above>=area.y+8?above:anchor.y,area.y+8,area.y+area.height-height-8)),width,height};
}

// Reuses the speech window. No extra renderer or animation loop is created.
class CompanionBubble {
  constructor(api) {
    this.api=api;this.states=new Map();this.source=null;this.anchor=null;
    this.expires=0;this.timer=null;this.dismissed=false;this.expanded=false;
    this.held=false;this.packet='';this.bounds='';this.height=150;this.mode=false;
  }
  allowed(sender) { return this.api.windows().some(w=>w&&!w.isDestroyed()&&w.webContents===sender); }
  update(sender,value={}) {
    if(!this.allowed(sender))return;
    const text=x=>typeof x==='string'?x:'';
    const message={id:text(value.message?.id).slice(0,80),role:text(value.message?.role).slice(0,16),text:text(value.message?.text).slice(0,2000)};
    const previous=this.states.get(sender);
    const fresh=message.id&&message.id!==previous?.message.id;
    const state={title:text(value.title).slice(0,80)||'OpenClam',theme:value.theme==='light'?'light':'dark',status:text(value.status).slice(0,160),
      activity:text(value.activity).slice(0,160),busy:value.busy===true,live:value.live===true,
      canStop:value.canStop===true,message};
    this.states.set(sender,state);
    if(fresh||state.activity) {
      this.source=sender;
      if(fresh||!previous?.activity)this.dismissed=false;
      if(fresh)this.expires=Date.now()+14000;
    }
    this.refresh();
  }
  setAnchor(sender,value) {
    const main=this.api.main();
    if(!main||main.isDestroyed()||sender!==main.webContents)return;
    if(!value||!Number.isFinite(value.x)||!Number.isFinite(value.y)){this.anchor=null;this.refresh();return;}
    this.anchor={x:value.x,y:value.y};this.refresh();
  }
  current() {
    const owner=this.api.liveOwner();
    const sender=owner&&this.states.has(owner)?owner:this.source;
    return {sender,state:this.states.get(sender)};
  }
  refresh() {
    clearTimeout(this.timer);this.timer=null;
    const main=this.api.main(),{state}=this.current();
    // Hiding a window does not reliably deliver mouseleave. Do not carry
    // reading/focus state into the next visit to Avatar mode.
    if(this.api.chatMode()||!main||main.isDestroyed()||!main.isVisible()){
      this.held=false;this.expanded=false;
    }
    const visible=!this.api.chatMode()&&main&&!main.isDestroyed()&&main.isVisible()
      &&this.anchor&&!this.dismissed&&state
      &&(state.activity||this.expanded||this.held||Date.now()<this.expires);
    if(!visible) {
      if(this.mode)this.api.bubble()?.hide();
      this.mode=false;this.packet='';this.bounds='';return;
    }
    const window=this.api.create();this.mode=true;
    const origin=main.getContentBounds();
    const anchor={x:origin.x+this.anchor.x,y:origin.y+this.anchor.y};
    const bounds=companionBubbleBounds(anchor,this.api.area(anchor),this.height);
    const key=JSON.stringify(bounds);
    if(key!==this.bounds){this.bounds=key;window.setBounds(bounds,false);}
    const payload={...state,expanded:this.expanded,canSend:!state.live&&!state.busy};
    const packet=JSON.stringify(payload);
    if(!window.webContents.isLoadingMainFrame()&&packet!==this.packet) {
      this.packet=packet;this.api.post(window,'openclam:companion-state',payload);
    }
    if(!window.isVisible()){window.showInactive();window.moveTop();}
    if(!state.activity&&!this.expanded&&!this.held) {
      this.timer=setTimeout(()=>this.refresh(),Math.max(1,this.expires-Date.now()));
      this.timer.unref?.();
    }
  }
  action(value={}) {
    const {sender,state}=this.current();
    if(value.action==='dismiss') {this.dismissed=true;this.expanded=false;this.held=false;this.refresh();return true;}
    if(value.action==='expand'&&this.mode) {
      this.expanded=!this.expanded;this.refresh();
      if(this.expanded){this.api.bubble()?.show();this.api.bubble()?.focus();}
      return true;
    }
    if(value.action==='chat'){this.api.openChat();return true;}
    if(!sender||!this.allowed(sender)||!state)return false;
    if(value.action==='followup') {
      const text=typeof value.text==='string'?value.text.trim():'';
      if(!text||text.length>8000||state.busy||state.live)return false;
      state.busy=true;state.activity='Sending…';
      sender.send('openclam:companion-command',{action:'followup',text});
      this.expanded=false;this.expires=Date.now()+14000;this.refresh();return true;
    }
    if(value.action==='stop'&&state.canStop) {
      sender.send('openclam:companion-command',{action:'stop'});return true;
    }
    return false;
  }
  resize(height) {if(Number.isFinite(height)){this.height=clamp(Math.ceil(height),84,320);this.refresh();}}
  hold(value) {this.held=Boolean(value);if(!value)this.expires=Math.max(this.expires,Date.now()+2500);this.refresh();}
  dispose(){clearTimeout(this.timer);this.states.clear();}
}

module.exports={CompanionBubble,companionBubbleBounds};
