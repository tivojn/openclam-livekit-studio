'use strict';
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const page=fs.readFileSync('web/index.html','utf8');
const start=page.indexOf('    const handleAgentTurnRPC =');
const end=page.indexOf('    const setLiveButton =', start);
assert.ok(start>0&&end>start);
const calls=[];
const expected=[];
const sandbox={
  performance:{now:()=>1000}, LIVE_TALK_AGENT_RPC_DEADLINE_MARGIN_MS:1000,
  parseAgentTurnRequest:JSON.parse,
  waitForMatchingFinalUserTurn:async()=>true, turnController:null,
  document:{querySelector:()=>null,visibilityState:'hidden'}, selectedOpenClawAgent:()=> 'different-agent',
  live:null,sharedLiveOwned:true,sharedLivePhase:'connected',
  trustedAgents:room=>[...room.remoteParticipants.values()].filter(p=>p.isAgent),
  claimLiveTalkRPCRequest:(ids,id)=>{ids.add(id);return true;},
  submitOpenClawTurn:async(text,agent,options)=>{calls.push({text,agent,options});return{ok:true,text:'I will wave hello.'};},
  boundedAgentTurnReply:x=>x, rememberExpectedDelegatedAssistantReply:(_s,text)=>expected.push(text),
  agentTurnRPCAnswer:(status,spoken_reply='')=>({status,spoken_reply}),
  setStatus:()=>{}, LIVE_TALK_OPENCLAW_REQUIRED_MESSAGE:'Choose OpenClaw.',
};
vm.createContext(sandbox);
const trustStart=page.indexOf('    const trustedAgentTurnInvocation =');
vm.runInContext(page.slice(trustStart,start),sandbox);
vm.runInContext(page.slice(start,end)+'\nglobalThis.handle=handleAgentTurnRPC;',sandbox);
(async()=>{
  const session={connectedAgentID:'pinned-agent',replayedAgentTurnRequests:new Set(),agentReady:true,
    room:{remoteParticipants:new Map([['voice-agent',{identity:'voice-agent',isAgent:true}]])}};
  sandbox.live=session;
  const invocation={callerIdentity:'voice-agent',responseTimeout:300000,payload:JSON.stringify({request_id:'turn-one',spoken_request:'Can you do confoot punching?'})};
  const result=await sandbox.handle(session,invocation);
  assert.equal(result.status,'completed','hidden call owner must dispatch after switching to Avatar mode');
  assert.equal(calls[0].agent,'pinned-agent');
  assert.equal(calls[0].text,'Can you do confoot punching?','the selected LLM receives the original ASR text');
  assert.equal(calls[0].options.liveAgentBridge,true);
  assert.equal(calls[0].options.userAlreadyRendered,true);
  assert.deepEqual(expected,['I will wave hello.']);
  assert.equal((await sandbox.handle(session,invocation)).status,'rejected');
  assert.equal(calls.length,1);
  const next={...invocation,payload:JSON.stringify({request_id:'turn-two',spoken_request:'Hello there'})};
  sandbox.sharedLiveOwned=false;
  assert.equal((await sandbox.handle(session,next)).status,'rejected','a hidden non-owner cannot dispatch');
  sandbox.sharedLiveOwned=true;sandbox.sharedLivePhase='ending';
  assert.equal((await sandbox.handle(session,next)).status,'rejected','hang-up revokes hidden-owner dispatch');
  sandbox.sharedLivePhase='connected';
  assert.equal((await sandbox.handle(session,{...next,callerIdentity:'stranger'})).status,'rejected');
  sandbox.waitForMatchingFinalUserTurn=async()=>false;
  assert.equal((await sandbox.handle(session,next)).status,'rejected','ownership never skips transcript validation');
  sandbox.waitForMatchingFinalUserTurn=async()=>true;
  sandbox.document.visibilityState='visible';sandbox.sharedLiveOwned=false;
  assert.equal((await sandbox.handle(session,next)).status,'completed','visible browser clients retain their route');
  assert.equal(calls.length,2);
  // Switching presentation while OpenClaw works must also preserve its result.
  sandbox.submitOpenClawTurn=async()=>{sandbox.document.visibilityState='hidden';return {ok:true,text:'The same call continues.'};};
  sandbox.sharedLiveOwned=true;
  assert.equal((await sandbox.handle(session,{...next,payload:JSON.stringify({request_id:'turn-three',spoken_request:'Keep going'})})).status,'completed');
  sandbox.document.visibilityState='visible';
  sandbox.selectedOpenClawAgent=()=>'';
  const localSession={...session,connectedAgentID:'',replayedAgentTurnRequests:new Set()};sandbox.live=localSession;
  assert.equal((await sandbox.handle(localSession,invocation)).spoken_reply,'Choose OpenClaw.');
  assert.equal(calls.length,2);
  console.log('Connected OpenClaw Live Talk: hidden-owner dispatch/completion, revoked ownership, caller/transcript/replay checks and pinned route passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
