const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const page=fs.readFileSync('web/index.html','utf8');
const helper=name=>{const start=page.indexOf('    const '+name+' =');assert(start>=0);return page.slice(start,page.indexOf('\n    };',start)+7);};
const storage=new Map();let writes=0,resolveAgents;
const first={id:'chat-one',agentMode:'openclaw:main',openClawSessionID:'a'.repeat(32),records:[]};
storage.set('threads',JSON.stringify([first]));storage.set('active',first.id);
const s={console,conversationReady:null,conversationSync:null,chatThreads:[first],activeThreadID:first.id,
  CHAT_HISTORY_KEY:'threads',ACTIVE_CHAT_KEY:'active',history:[],latestAssistantText:'',openClawSessionID:'',restoringThread:false,
  localStorage:{getItem:key=>storage.get(key)||null,setItem:(key,value)=>{writes++;storage.set(key,value);}},
  agentModeSelect:{value:'local',options:[{value:'local'}],appendChild(option){this.options.push(option);}},
  document:{createElement:()=>({dataset:{},remove(){s.agentModeSelect.options=s.agentModeSelect.options.filter(o=>o!==this);}})},
  activeChatThread:()=>s.chatThreads.find(t=>t.id===s.activeThreadID),
  loadChatThreads:()=>JSON.parse(storage.get('threads')),
  fetch:async()=>{await new Promise(r=>{resolveAgents=r;});return {agents:[{agent_id:'main'},{agent_id:'work'}]};},safeJSON:r=>r,
  removeWorking(){},conversation:{replaceChildren(){}},composer:{},renderChatThreadHeading(){},renderChatHistory(){},followConversationLatest(){},refreshAttachmentRouteCapability(){},notify(){},
};
vm.createContext(s);
for(const name of ['selectedOpenClawAgent','restoreChatThread','syncConversationForVoice'])vm.runInContext(helper(name)+`\nglobalThis.${name}=${name};`,s);
const start=page.indexOf('    async function loadOpenClawAgents()');
vm.runInContext(page.slice(start,page.indexOf("    agentModeSelect.addEventListener('change'",start)),s);
(async()=>{
  // Execute the production startup order while the agent list is delayed.
  const init=page.match(/conversationReady=loadOpenClawAgents\(\)\.then\(\(\)=>restoreChatThread\(activeChatThread\(\)\)\);/);
  assert(init);vm.runInContext(init[0],s);
  assert.equal(s.agentModeSelect.value,'local');assert.equal(writes,0);
  const earlyVoice=s.syncConversationForVoice();resolveAgents();await earlyVoice;
  assert.equal(s.selectedOpenClawAgent(),'main');assert.equal(s.openClawSessionID,'a'.repeat(32));
  assert.equal(writes,0,'startup never replaces the saved connected agent with local');
  // A chat-window change must reach the separate avatar renderer before PTT/Live Talk.
  const second={id:'chat-two',agentMode:'openclaw:work',openClawSessionID:'b'.repeat(32),records:[]};
  storage.set('threads',JSON.stringify([second,first]));storage.set('active',second.id);
  const sync=s.syncConversationForVoice();await new Promise(r=>setImmediate(r));resolveAgents();await sync;
  assert.equal(s.selectedOpenClawAgent(),'work');assert.equal(s.activeThreadID,second.id);assert.equal(s.openClawSessionID,'b'.repeat(32));
  assert.equal(s.agentModeSelect.options.length,3,'refresh does not duplicate agent options');assert.equal(writes,0);
  // An explicitly selected local route must not silently fall back to an old agent.
  second.agentMode='local';storage.set('threads',JSON.stringify([second,first]));
  const local=s.syncConversationForVoice();await new Promise(r=>setImmediate(r));resolveAgents();await local;
  assert.equal(s.selectedOpenClawAgent(),'');assert.equal(writes,0);
  console.log('Avatar voice routes: delayed startup, saved agent, cross-window conversation/session sync, explicit local selection and deduplicated refresh passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
