import {ConversationError} from './wire.mjs';
import {ANSWER_PREFIX, QUESTION_PREFIX, parseAnswer} from './question.mjs';
export const FIXTURE_QUESTION = Object.freeze({id: 'tree_question', revision: 1, prompt: 'Choose a tree for the next interface test.',
  options: Object.freeze([{id:'cedar',label:'Cedar'},{id:'birch',label:'Birch'},{id:'larch',label:'Larch'}])});
const encode = (type, data) => JSON.stringify({type, data});

/** Deterministic wire-shaped host double; it is not live Gateway evidence. */
export function createFixtureTransport({caller = 'human_comparison', target = 'agent_comparison', entryCount = 0, includeQuestion = true, delayMs = 0} = {}) {
  const engagementId = 'eng_' + 'c'.repeat(32), entries = [], events = [], commands = new Map(), listeners = new Set(), calls = [];
  let denied = false, attached = false, submitFault = null, frameOverride = null;
  function appendMessage(role, content) {
    const ordinal = entries.length + 1;
    entries.push({id: `msg_fixture_${ordinal}`, role, content, timestamp:'2026-10-01T00:00:00Z', entry_ordinal:ordinal});
  }
  for (let index = 0; index < entryCount; index++) appendMessage(index % 2 ? 'assistant' : 'user', `History entry ${index + 1}.`);
  if (includeQuestion) appendMessage('assistant', QUESTION_PREFIX + JSON.stringify(FIXTURE_QUESTION));
  function record(command, status, outcome) {
    const next = {...command, status, outcome, updated_cursor: events.length + 1};
    commands.set(next.id, next);
    events.push({id:`evt_fixture_${events.length + 1}`, cursor:events.length + 1,
      kind:status === 'admitted' ? 'admitted' : status === 'dispatch_started' ? 'dispatch_started' : 'settled', command:next});
    return next;
  }
  return {
    calls,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    close() { attached = false; },
    failNextSubmit(mode = 'admitted') { submitFault = mode; },
    overrideNextFrame(value) { frameOverride = value; },
    setUnauthorized() { denied = true; attached = false; for (const listener of listeners) listener('unauthorized'); },
    disconnect() { attached = false; for (const listener of listeners) listener('disconnected'); },
    appendMessage,
    replaceQuestion(revision) { appendMessage('assistant', QUESTION_PREFIX + JSON.stringify({...FIXTURE_QUESTION, revision})); },
    request: async context => {
      calls.push(structuredClone(context));
      if (delayMs) await new Promise(resolve => setTimeout(resolve, delayMs));
      if (denied) throw new ConversationError('unauthorized');
      if (frameOverride !== null) { const frame = frameOverride; frameOverride = null; return frame; }
      if (context.caller !== caller || context.target !== target || context.options.expected_engagement_id && context.options.expected_engagement_id !== engagementId) throw new ConversationError('unauthorized');
      const {operation, input, options} = context;
      if (operation !== 'history' && !attached) throw new ConversationError('transport_not_attached');
      if (operation === 'history' || operation === 'events') {
        if (operation === 'history') attached = true;
        const values = operation === 'history' ? entries : events;
        const after = operation === 'history' ? options.after ?? 0 : input;
        const head = options.through ?? values.length, cursor = Math.min(head, after + (options.limit ?? 100));
        const data = {engagement_id: engagementId, [operation === 'history' ? 'entries' : 'events']: values.slice(after, cursor), cursor, head, has_more:cursor < head};
        if (operation === 'history') data.agent_id = target;
        return encode(operation === 'history' ? 'conversation_history' : 'conversation_events', data);
      }
      if (operation === 'command') {
        const command = commands.get(input);
        return command ? encode('conversation_command', command) : JSON.stringify({type:'error',reason:'not_found'});
      }
      if (operation === 'submit') {
        const old = commands.get(input.id);
        if (old) return old.text === input.text ? encode('conversation_command', old) : encode('conversation_rejected', {id:input.id,reason:'command_conflict'});
        const fault = submitFault; submitFault = null;
        if (fault === 'not_found') { attached = false; throw new ConversationError('transport_timeout'); }
        const initial = {id:input.id,name:'chat.send',text:input.text,principal_id:caller,agent_id:target,engagement_id:engagementId,
          admitted_cursor:events.length + 1,updated_cursor:events.length + 1,status:'admitted',outcome:null};
        record(initial, 'admitted', null); record(initial, 'dispatch_started', null);
        appendMessage('user', input.text);
        const answer = parseAnswer(input.text), response = answer ? `Selected ${answer.option_id}.` : `Conversation received: ${input.text}`;
        appendMessage('assistant', response);
        const completed = fault === 'terminal_uncertain' ? record(initial, 'uncertain', {status:'uncertain',reason:'delivery_unknown'}) :
          record(initial, 'completed', {status:'completed',text:response});
        if (fault === 'admitted') { attached = false; throw new ConversationError('transport_timeout'); }
        return encode('conversation_command', completed);
      }
      throw new ConversationError('invalid_request');
    }
  };
}
