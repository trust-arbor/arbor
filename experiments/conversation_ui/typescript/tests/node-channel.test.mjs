import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {openNodeChannel} from '../shared/node-channel.mjs';
const credential=Buffer.alloc(32,7).toString('base64url');
function makeSocketClass(responses=['open']) {
  const instances=[];
  class Socket extends EventEmitter {
    constructor(url,options){
      super(); this.url=String(url);this.options=options;this.sent=[];instances.push(this);
      const response=responses.shift()??'open';
      queueMicrotask(()=>response==='open'?this.emit('open'):this.emit('unexpected-response',{}, {statusCode:response,resume(){}}));
    }
    send(frame){this.sent.push(frame);}
    terminate(){this.terminated=true;}
  }
  return {Socket,instances};
}
test('Node socket keeps authority in upgrade header and mirrors SDK transport restrictions',async()=>{
  const {Socket,instances}=makeSocketClass();
  const channel=await openNodeChannel({gatewayUrl:'http://127.0.0.1:43121',credential,webSocketClass:Socket});
  const socket=instances[0];
  assert.equal(socket.url,'ws://127.0.0.1:43121/api/chat/socket');
  assert.equal(socket.options.headers.authorization,`Conversation ${credential}`);
  assert.ok(!socket.url.includes(credential));assert.equal(socket.options.followRedirects,false);assert.equal(socket.options.perMessageDeflate,false);
  let event;channel.subscribe(value=>event=value);socket.emit('message',Buffer.from('{"safe":true}'),false);
  assert.deepEqual(event,{type:'message',data:'{"safe":true}'});channel.close();assert.equal(socket.terminated,true);
  await assert.rejects(openNodeChannel({gatewayUrl:'http://remote.example',credential,webSocketClass:Socket}),/invalid_options/);
  await assert.rejects(openNodeChannel({gatewayUrl:'https://example.invalid/?credential=bad',credential,webSocketClass:Socket}),/invalid_options/);
});
test('Node connection retries only409 attachment race, without sending a conversation frame',async()=>{
  const {Socket,instances}=makeSocketClass([409,'open']);
  const channel=await openNodeChannel({gatewayUrl:'http://localhost:43121',credential,webSocketClass:Socket,connectTimeoutMs:200});
  assert.equal(instances.length,2);assert.equal(instances[0].terminated,true);assert.deepEqual(instances[0].sent,[]);channel.close();
});
test('Node connection preserves denied authority and does not retry401',async()=>{
  const {Socket,instances}=makeSocketClass([401,'open']);
  await assert.rejects(openNodeChannel({gatewayUrl:'http://127.0.0.1:43121',credential,webSocketClass:Socket}),/unauthorized/);
  assert.equal(instances.length,1);
});
