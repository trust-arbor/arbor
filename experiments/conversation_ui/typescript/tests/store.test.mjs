import test from 'node:test';
import assert from 'node:assert/strict';
import {createConversationStore} from '../shared/store.mjs';
import {createFixtureTransport, FIXTURE_QUESTION} from '../shared/fixture.mjs';
import {QUESTION_PREFIX, answerText, displayMessageText} from '../shared/question.mjs';
import {sessionFrame, decodeReply} from '../shared/wire.mjs';

function setup(options = {}) {
  const transport = createFixtureTransport(options);
  let next = 0;
  return {transport, store: createConversationStore({caller:'human_comparison',target:'agent_comparison',transport,idFactory:()=>`cmd_${++next}`})};
}
test('v2 session payload binds operation, pagination and expected engagement exactly', () => {
  const context = {operation:'history',caller:'human_a',target:'agent_b',input:null,options:{after:4,through:8,limit:2,expected_engagement_id:'eng_'+'a'.repeat(32)}};
  const frame = JSON.parse(sessionFrame(context));
  assert.deepEqual(Object.keys(frame), ['payload','authentication']);
  assert.deepEqual(JSON.parse(frame.payload), ['arbor.conversation.v2','history','human_a','agent_b',null,[4,8,2],'eng_'+'a'.repeat(32)]);
  assert.throws(() => sessionFrame({...context,operation:'submit',input:{id:'cmd_1',text:'text'}}), /invalid_request/);
  assert.throws(() => decodeReply(JSON.stringify({type:'delta',text:'invented'}), context), /invalid_transport_response/);
});
test('host history and delivery journal have independent cursors; submit fabricates no transcript', async () => {
  const {store} = setup({entryCount:4,includeQuestion:false});
  assert.equal((await store.sync()).ok,true);
  assert.equal(store.getSnapshot().transcriptCursor,4);
  assert.equal(store.getSnapshot().journalCursor,0);
  const before = store.getSnapshot().messages;
  assert.equal((await store.submit('hello')).ok,true);
  assert.deepEqual(store.getSnapshot().messages,before);
  assert.equal(store.getSnapshot().deliveries[0].status,'completed');
  assert.equal(store.getSnapshot().journalCursor,0,'direct observation must not skip journal replay');
  await store.sync();
  assert.equal(store.getSnapshot().transcriptCursor,6);
  assert.equal(store.getSnapshot().journalCursor,3);
  assert.equal(store.getSnapshot().messages.at(-2).text,'hello');
  assert.equal(store.getSnapshot().deliveries.length,1);
  assert.ok(Object.isFrozen(store.getSnapshot()));
  assert.equal(store.getSnapshot(),store.getSnapshot(),'useSyncExternalStore gets a cached snapshot');
});
test('unknown admitted send is looked up and never resent', async () => {
  const {store,transport} = setup(); await store.sync(); transport.failNextSubmit('admitted');
  assert.equal((await store.submit('possibly delivered')).error,'transport_timeout');
  assert.equal(store.getSnapshot().connection,'disconnected');
  assert.equal(store.getSnapshot().saved.status,'uncertain');
  assert.equal(store.getSnapshot().saved.text,'','disconnected UI receives no private pending text');
  assert.equal((await store.retrySaved()).error,'lookup_required_before_retry');
  assert.equal((await store.checkSaved()).ok,true);
  assert.equal(store.getSnapshot().saved.status,'completed');
  assert.equal(transport.calls.filter(call=>call.operation==='submit').length,1);
  assert.equal(store.getSnapshot().messages.filter(message=>message.text==='possibly delivered').length,1);
});
test('unknown absent send retries only after authoritative not_found and keeps the same ID', async () => {
  const {store,transport} = setup(); await store.sync(); transport.failNextSubmit('not_found');
  await store.submit('retry with original identity');
  assert.equal((await store.retrySaved()).error,'lookup_required_before_retry');
  assert.equal((await store.checkSaved()).notFound,true);
  assert.equal((await store.retrySaved()).ok,true);
  const submissions = transport.calls.filter(call=>call.operation==='submit');
  assert.deepEqual(submissions.map(call=>call.input.id),['cmd_1','cmd_1']);
  assert.deepEqual(submissions.map(call=>call.input.text),['retry with original identity','retry with original identity']);
  await store.sync(); assert.equal(store.getSnapshot().messages.filter(message=>message.text==='retry with original identity').length,1);
});
test('authorization loss erases all display and recovery data and rejects late in-flight replies', async () => {
  const {store,transport} = setup({delayMs:5}); await store.sync();
  const pending = store.submit('private pending input');
  transport.setUnauthorized(); await pending;
  const snapshot = store.getSnapshot();
  assert.equal(snapshot.connection,'unauthorized');
  assert.deepEqual(snapshot.messages,[]); assert.deepEqual(snapshot.deliveries,[]);
  assert.equal(snapshot.saved,null); assert.equal(snapshot.question,null);
  assert.equal(snapshot.transcriptCursor,0); assert.equal(snapshot.journalCursor,0);
  assert.equal((await store.sync()).error,'unauthorized');
  assert.ok(!JSON.stringify(snapshot).includes('private pending input'));
});
test('disconnect clears UI data; reconnect reconstructs host history without duplicate entries', async () => {
  const {store,transport} = setup({entryCount:210}); await store.sync();
  transport.disconnect(); assert.deepEqual(store.getSnapshot().messages,[]);
  assert.equal(store.getSnapshot().question,null);
  await store.sync();
  assert.equal(store.getSnapshot().messages.length,211);
  assert.equal(new Set(store.getSnapshot().messages.map(message=>message.id)).size,211);
});
test('structured question is projected only from an authoritative assistant message', async () => {
  const {store,transport} = setup({includeQuestion:false});
  transport.appendMessage('user',QUESTION_PREFIX + JSON.stringify(FIXTURE_QUESTION)); await store.sync();
  assert.equal(store.getSnapshot().question,null);
  transport.appendMessage('assistant',QUESTION_PREFIX + JSON.stringify(FIXTURE_QUESTION)); await store.sync();
  assert.equal(store.getSnapshot().question.status,'open');
  assert.equal(store.selectOption('cedar'),true);
  assert.equal(store.getSnapshot().question.status,'open','local choice is not host acceptance');
  assert.equal((await store.confirmQuestion()).ok,true);
  assert.equal(store.getSnapshot().question.status,'completed');
  assert.equal(transport.calls.at(-1).input.text,answerText(FIXTURE_QUESTION,'cedar'));
  assert.equal(store.selectOption('birch'),false);
  const second = createConversationStore({caller:'human_comparison',target:'agent_comparison',transport});
  await second.sync(); assert.equal(second.getSnapshot().question.status,'completed');
  assert.equal(second.getSnapshot().question.selection,'cedar','another renderer reconstructs host-confirmed answer');
  assert.equal(displayMessageText(second.getSnapshot().messages.find(message=>message.text===answerText(FIXTURE_QUESTION,'cedar'))),'Selected cedar (question tree_question, revision 1).');
});
test('new question revision or source message invalidates a previous local selection', async () => {
  const {store,transport} = setup(); await store.sync(); store.selectOption('cedar');
  transport.replaceQuestion(2); await store.sync();
  assert.equal(store.getSnapshot().question.revision,2); assert.equal(store.getSnapshot().question.selection,null);
  assert.equal((await store.confirmQuestion()).error,'question_not_actionable');
  transport.replaceQuestion(2); await store.sync(); assert.equal(store.getSnapshot().question.selection,null);
});
test('both paged streams commit atomically; malformed journal cannot publish fetched history', async () => {
  const {store,transport} = setup({includeQuestion:false}); await store.sync();
  transport.appendMessage('assistant','new private history');
  const original = transport.request;
  transport.request = async context => context.operation === 'events' ? JSON.stringify({type:'conversation_events',data:{engagement_id:'eng_'+'c'.repeat(32),events:[],cursor:1,head:1,has_more:false}}) : original(context);
  assert.equal((await store.sync()).error,'invalid_command_page');
  assert.equal(store.getSnapshot().messages.length,0);
  assert.equal(store.getSnapshot().transcriptCursor,0);
});
test('scope-changing host response clears previous private data', async () => {
  const {store,transport} = setup(); await store.sync();
  transport.overrideNextFrame(JSON.stringify({type:'conversation_history',data:{agent_id:'agent_comparison',engagement_id:'eng_'+'d'.repeat(32),entries:[],cursor:1,head:1,has_more:false}}));
  assert.equal((await store.sync()).error,'conversation_scope_changed');
  assert.equal(store.getSnapshot().connection,'unauthorized'); assert.equal(store.getSnapshot().messages.length,0);
});
test('10,000 authoritative history entries retain stable IDs across refresh without manufactured speech', async () => {
  const {store} = setup({entryCount:10000,includeQuestion:false}); await store.sync();
  const first = store.getSnapshot(); assert.equal(first.messages.length,10000); assert.equal(first.transcriptCursor,10000);
  await store.sync(); assert.deepEqual(store.getSnapshot().messages,first.messages);
  assert.equal(store.getSnapshot().journalCursor,0); assert.equal(store.getSnapshot().deliveries.length,0);
});
test('manual disconnect during an in-flight send preserves unknown delivery ID for recovery lookup', async () => {
  const {store,transport} = setup(); await store.sync();
  const original = transport.request;
  transport.request = async context => {
    const result = await original(context);
    if (context.operation === 'submit') await new Promise(resolve=>setTimeout(resolve,5));
    return result;
  };
  const pending = store.submit('manual disconnect during send'); await store.disconnect(); await pending;
  assert.equal(store.getSnapshot().saved.status,'uncertain');
  assert.equal(store.getSnapshot().saved.id,'cmd_1'); assert.equal(store.getSnapshot().saved.text,'');
  assert.equal((await store.checkSaved()).ok,true);
  assert.equal(store.getSnapshot().saved.status,'completed');
  assert.equal(transport.calls.filter(call=>call.operation==='submit').length,1);
});
test('host-terminal uncertainty permits another turn but is never automatically retried', async () => {
  const {store,transport} = setup(); await store.sync(); transport.failNextSubmit('terminal_uncertain');
  await store.submit('terminal uncertain command');
  assert.equal(store.getSnapshot().saved.status,'uncertain_terminal');
  assert.equal((await store.retrySaved()).error,'lookup_required_before_retry');
  assert.equal((await store.submit('new independent turn')).ok,true);
  assert.deepEqual(transport.calls.filter(call=>call.operation==='submit').map(call=>call.input.id),['cmd_1','cmd_2']);
});
test('a reissued source message does not inherit the earlier source answer despite same question revision', async () => {
  const {store,transport} = setup(); await store.sync(); store.selectOption('cedar'); await store.confirmQuestion(); await store.sync();
  transport.replaceQuestion(1); await store.sync();
  assert.equal(store.getSnapshot().question.status,'open'); assert.equal(store.getSnapshot().question.selection,null);
});
test('not_found cannot authorize retry of a command already observed in authoritative history', async () => {
  const {store,transport} = setup(); await store.sync(); await store.submit('known delivered command'); await store.sync();
  const original = transport.request;
  transport.request = async context => context.operation === 'command' ? JSON.stringify({type:'error',reason:'not_found'}) : original(context);
  assert.equal((await store.checkSaved()).error,'conflicting_response');
  assert.equal(store.getSnapshot().connection,'unauthorized');
  assert.equal(store.getSnapshot().saved,null);
  assert.equal((await store.retrySaved()).error,'unauthorized');
  assert.equal(transport.calls.filter(call=>call.operation==='submit').length,1);
});
