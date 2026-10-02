import test from 'node:test';
import assert from 'node:assert/strict';
import {createSessionTransport} from '../shared/transport.mjs';
import {ConversationError} from '../shared/wire.mjs';
const engagement = 'eng_'+'e'.repeat(32);
const context = operation => ({operation,caller:'human_test',target:'agent_test',input:operation==='history'?null:0,
  options:operation==='history'?{after:0,limit:100}:{expected_engagement_id:engagement}});
const history = JSON.stringify({type:'conversation_history',data:{agent_id:'agent_test',engagement_id:engagement,entries:[],cursor:0,head:0,has_more:false}});
function channel() {
  let listener, closed = false; const frames=[];
  return {frames,get closed(){return closed;},send(frame){frames.push(frame);},subscribe(fn){listener=fn;return()=>{};},close(){closed=true;},emit(event){listener?.(event);}};
}
const turn = () => new Promise(resolve=>setImmediate(resolve));
test('a fresh authenticated channel only accepts history and serializes operations', async () => {
  const socket=channel(), transport=createSessionTransport({openChannel:async()=>socket});
  await assert.rejects(transport.request(context('events')),/transport_not_attached/);
  const pending=transport.request(context('history')); await turn();
  await assert.rejects(transport.request(context('history')),/transport_busy/);
  assert.equal(JSON.parse(socket.frames[0]).authentication,'conversation_session');
  socket.emit({type:'message',data:history}); assert.equal(await pending,history);
  await transport.close(); assert.equal(socket.closed,true);
});
test('timeout retires uncorrelated channel and ignores late old-generation frames', async () => {
  const first=channel(), second=channel(); let opens=0;
  const transport=createSessionTransport({openChannel:async()=>++opens===1?first:second,timeoutMs:10});
  const timed=transport.request(context('history')); await assert.rejects(timed,/transport_timeout/);
  assert.equal(first.closed,true);
  await assert.rejects(transport.request(context('events')),/transport_not_attached/);
  const next=transport.request(context('history')); await turn();
  first.emit({type:'message',data:history});
  second.emit({type:'message',data:history}); assert.equal(await next,history);
  await transport.close();
});
test('unsolicited session revocation invalidates idle owner and blocks later reconnect', async () => {
  const socket=channel(), transport=createSessionTransport({openChannel:async()=>socket}); let observed;
  transport.subscribe(code=>observed=code);
  const pending=transport.request(context('history')); await turn(); socket.emit({type:'message',data:history}); await pending;
  socket.emit({type:'message',data:JSON.stringify({type:'error',reason:'unauthorized'})});
  assert.equal(observed,'unauthorized'); assert.equal(socket.closed,true);
  await assert.rejects(transport.request(context('history')),/unauthorized/);
});
test('a denied handshake preserves authorization-loss classification', async () => {
  const transport=createSessionTransport({openChannel:async()=>{throw new ConversationError('unauthorized');}});
  await assert.rejects(transport.request(context('history')),/unauthorized/);
});
test('a timed-out channel opening cannot close a later successful generation', async () => {
  let release; const first=channel(),second=channel(); let opens=0;
  const transport=createSessionTransport({openChannel:()=>++opens===1?new Promise(resolve=>release=resolve):Promise.resolve(second),timeoutMs:10});
  await assert.rejects(transport.request(context('history')),/transport_timeout/);
  const next=transport.request(context('history')); await turn();
  release(first); await turn(); assert.equal(first.closed,true); assert.equal(second.closed,false);
  second.emit({type:'message',data:history}); assert.equal(await next,history); await transport.close();
});
