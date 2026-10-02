import assert from 'node:assert/strict';
import {readFile,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {createConversationStore} from '../shared/store.mjs';
import {createSessionTransport} from '../shared/transport.mjs';
import {openNodeChannel} from '../shared/node-channel.mjs';
import {exact} from '../shared/wire.mjs';

// Called only by the isolated Elixir qualification test. Input is private,
// short-lived fixture authority; stdout never contains tokens, IDs or transcript.
let store, surfaces;
try {
  assert.equal(process.argv.length,3);
  const file = process.argv[2], metadata = await stat(file);
  assert.equal(metadata.mode & 0o777,0o600);
  const config = JSON.parse(await readFile(file,'utf8'));
  assert.ok(exact(config,['gatewayUrl','caller','target','credential']));
  const transport = createSessionTransport({openChannel:()=>openNodeChannel(config),timeoutMs:5000});
  let count=0;
  store=createConversationStore({caller:config.caller,target:config.target,transport,idFactory:()=>`cmd_ui_comparison_${++count}`});
  assert.equal((await store.sync()).ok,true);
  const initial=store.getSnapshot(); assert.equal(initial.connection,'connected'); assert.ok(initial.question);
  const {exerciseRealSurfaces}=await import('../web/real-surfaces.js');
  surfaces=await exerciseRealSurfaces(store);
  assert.equal(store.getSnapshot().saved.status,'completed');
  const completed=store.getSnapshot(); assert.equal(completed.question.status,'completed');
  const cursor=completed.journalCursor;
  await store.disconnect(); assert.equal(store.getSnapshot().messages.length,0);
  assert.equal((await store.sync()).ok,true); assert.equal(store.getSnapshot().journalCursor,cursor);
  const restored=store.getSnapshot();
  assert.equal(new Set(restored.messages.map(message=>message.id)).size,restored.messages.length);
  assert.deepEqual(restored.messages.map(message=>message.id),completed.messages.map(message=>message.id));
  const cleared=await surfaces.clearAccessAndClose();
  console.log(JSON.stringify({status:'passed',claims:['real_authenticated_v2_socket',...surfaces.claims,
    'disconnect_clear','reconnect_stable_ids',...cleared.claims],
    transcriptCount:restored.messages.length,journalCursor:restored.journalCursor,
    transcriptIdHash:createHash('sha256').update(JSON.stringify(restored.messages.map(message=>message.id))).digest('hex')}));
}catch{
  console.log(JSON.stringify({status:'failed',reason:'real_gateway_claim_failed'})); process.exitCode=1;
}finally{await surfaces?.dispose();await store?.destroy();}
