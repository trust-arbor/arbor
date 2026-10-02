import {decodeReply, errorCode, exact, identifier, engagement, ordinal, text, fail} from './wire.mjs';
import {parseQuestion, parseAnswer, answerText} from './question.mjs';

const commandKeys = ['id','name','text','principal_id','agent_id','engagement_id','status','outcome','admitted_cursor','updated_cursor'];
const statuses = ['admitted', 'dispatch_started', 'completed', 'uncertain'];
const savedStatus = delivery => delivery.status === 'uncertain' ? 'uncertain_terminal' : delivery.status;
const freshStream = limit => ({cursor: 0, head: 0, through: null, limit});
const freshState = limit => ({messages: [], messageIds: new Set(), commands: new Map(), observed: new Map(),
  eventIds: new Set(), history: freshStream(limit), journal: freshStream(limit), engagementId: null, owner: null});
const copyState = state => ({...state, messages: [...state.messages], messageIds: new Set(state.messageIds),
  commands: new Map(state.commands), observed: new Map(state.observed), eventIds: new Set(state.eventIds),
  history: {...state.history}, journal: {...state.journal}});
const newer = (a, b) => !a || a.updatedCursor < b.updatedCursor ? b : a;

function bind(state, id) {
  if (!engagement(id)) fail('invalid_transport_response');
  if (state.engagementId && state.engagementId !== id) fail('conversation_scope_changed');
  state.engagementId = id;
}
function bounds(page, stream) {
  if (!ordinal(page.cursor) || !ordinal(page.head) || typeof page.has_more !== 'boolean' ||
      stream.cursor > page.cursor || page.cursor > page.head ||
      stream.through !== null && stream.through !== page.head ||
      page.has_more !== (page.cursor < page.head) || page.has_more && page.cursor === stream.cursor) fail('invalid_page_bounds');
}
function consumeHistory(state, page, target) {
  if (!exact(page, ['agent_id','engagement_id','entries','cursor','head','has_more']) || page.agent_id !== target ||
      !Array.isArray(page.entries) || page.entries.length > state.history.limit || !text(JSON.stringify(page), 1100000)) fail('invalid_history_page');
  bounds(page, state.history); bind(state, page.engagement_id);
  let last = state.history.cursor;
  for (const entry of page.entries) {
    if (!exact(entry, ['id','role','content','timestamp','entry_ordinal']) || !identifier(entry.id) ||
        !['user','assistant'].includes(entry.role) || !text(entry.content, 262144) ||
        typeof entry.timestamp !== 'string' || entry.timestamp.length > 64 ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(entry.timestamp) || !Number.isFinite(Date.parse(entry.timestamp)) ||
        !ordinal(entry.entry_ordinal) || entry.entry_ordinal <= last || state.messageIds.has(entry.id)) fail('invalid_history_entry');
    last = entry.entry_ordinal; state.messageIds.add(entry.id);
    state.messages.push(Object.freeze({id: entry.id, role: entry.role, text: entry.content,
      timestamp: entry.timestamp, ordinal: entry.entry_ordinal}));
  }
  if (last > page.cursor || page.has_more && (last <= state.history.cursor || last !== page.cursor) ||
      !page.has_more && page.cursor !== page.head) fail('invalid_history_page');
  Object.assign(state.history, {cursor: page.cursor, head: page.head, through: page.has_more ? page.head : null});
}
function normalizeCommand(state, raw, target) {
  if (!exact(raw, commandKeys) || !identifier(raw.id) || raw.name !== 'chat.send' ||
      !text(raw.text, 32768) || !raw.text.trim() || !identifier(raw.principal_id) || raw.agent_id !== target ||
      !statuses.includes(raw.status) || !ordinal(raw.admitted_cursor) || raw.admitted_cursor < 1 ||
      !ordinal(raw.updated_cursor) || raw.updated_cursor < raw.admitted_cursor) fail('invalid_command_response');
  bind(state, raw.engagement_id);
  if (state.owner && state.owner !== raw.principal_id) fail('conversation_scope_changed');
  state.owner = raw.principal_id;
  const {status, outcome} = raw;
  let resultText = null, reason = null;
  if (status === 'admitted' && raw.updated_cursor !== raw.admitted_cursor ||
      status === 'dispatch_started' && raw.updated_cursor <= raw.admitted_cursor ||
      ['completed','uncertain'].includes(status) && raw.updated_cursor < raw.admitted_cursor + 2) fail('invalid_command_response');
  if (['admitted','dispatch_started'].includes(status)) { if (outcome !== null) fail('invalid_command_response'); }
  else if (status === 'completed') {
    if (!exact(outcome, ['status','text']) || outcome.status !== 'completed' || !text(outcome.text, 131072)) fail('invalid_command_response');
    resultText = outcome.text;
  } else {
    if (!exact(outcome, ['status','reason']) || outcome.status !== 'uncertain' || outcome.reason !== 'delivery_unknown') fail('invalid_command_response');
    reason = outcome.reason;
  }
  return Object.freeze({id: raw.id, status, inputText: raw.text, resultText, reason,
    admittedCursor: raw.admitted_cursor, updatedCursor: raw.updated_cursor});
}
function immutableEqual(a, b) {
  return a.id === b.id && a.inputText === b.inputText && a.admittedCursor === b.admittedCursor;
}
function consistent(old, next) {
  if (!old) return;
  if (!immutableEqual(old, next)) fail('conflicting_response');
  const early = old.updatedCursor <= next.updatedCursor ? old : next;
  const late = early === old ? next : old;
  if (old.updatedCursor === next.updatedCursor ? JSON.stringify(old) !== JSON.stringify(next) :
      ['completed','uncertain'].includes(early.status) ||
      early.status === 'dispatch_started' && !['completed','uncertain'].includes(late.status) ||
      early.status === 'admitted' && !['dispatch_started','completed','uncertain'].includes(late.status)) fail('conflicting_response');
}
function observe(state, raw, target, expectedId, expectedText) {
  const delivery = normalizeCommand(state, raw, target);
  if (delivery.id !== expectedId || expectedText !== undefined && delivery.inputText !== expectedText) fail('conflicting_response');
  consistent(state.commands.get(delivery.id), delivery); consistent(state.observed.get(delivery.id), delivery);
  state.observed.set(delivery.id, newer(state.observed.get(delivery.id), delivery));
  return delivery;
}
function consumeEvents(state, page, target) {
  if (!exact(page, ['engagement_id','events','cursor','head','has_more']) ||
      !Array.isArray(page.events) || page.events.length > state.journal.limit || !text(JSON.stringify(page), 1100000)) fail('invalid_command_page');
  bounds(page, state.journal); bind(state, page.engagement_id);
  for (const event of page.events) {
    if (!exact(event, ['id','cursor','kind','command']) || !identifier(event.id) ||
        event.cursor !== state.journal.cursor + 1 || state.eventIds.has(event.id) ||
        !['admitted','dispatch_started','settled'].includes(event.kind)) fail('invalid_command_event');
    const delivery = normalizeCommand(state, event.command, target), old = state.commands.get(delivery.id);
    const transition = !old ? event.kind === 'admitted' && delivery.status === 'admitted' :
      immutableEqual(old, delivery) && (old.status === 'admitted' && event.kind === 'dispatch_started' && delivery.status === 'dispatch_started' ||
      old.status === 'dispatch_started' && event.kind === 'settled' && ['completed','uncertain'].includes(delivery.status));
    if (!transition || delivery.updatedCursor !== event.cursor) fail('invalid_command_transition');
    consistent(state.observed.get(delivery.id), delivery);
    state.commands.set(delivery.id, delivery); state.eventIds.add(event.id); state.journal.cursor = event.cursor;
  }
  if (state.journal.cursor !== page.cursor) fail('invalid_command_page');
  Object.assign(state.journal, {head: page.head, through: page.has_more ? page.head : null});
}

/** Host-owned durable history with connection-local, disposable presentation state. */
export function createConversationStore({caller, target, transport, pageLimit = 100, maxPages = 200,
  idFactory = () => `cmd_${globalThis.crypto.randomUUID().replaceAll('-', '')}`}) {
  if (!identifier(caller) || !identifier(target) || !transport || typeof transport.request !== 'function' ||
      !Number.isInteger(pageLimit) || pageLimit < 1 || pageLimit > 100 ||
      !Number.isInteger(maxPages) || maxPages < 1 || maxPages > 1000) fail('invalid_client_options');
  let state = freshState(pageLimit), fence = null, connection = 'disconnected', error = null;
  let saved = null, selection = null, busy = false, generation = 0, version = 0, destroyed = false;
  let snapshot; const listeners = new Set();
  function publish() {
    const privateVisible = connection === 'connected';
    const deliveries = new Map(state.commands);
    for (const [id, record] of state.observed) deliveries.set(id, newer(deliveries.get(id), record));
    const records = [...deliveries.values()].sort((a,b) => a.admittedCursor - b.admittedCursor || a.id.localeCompare(b.id));
    let question = null;
    for (let i = state.messages.length - 1; i >= 0 && !question; i--) question = parseQuestion(state.messages[i]);
    if (question) {
      const key = `${question.sourceMessageId}:${question.revision}`;
      if (selection?.key !== key) selection = null;
      const answerSources = new Set(state.messages.filter(message => message.role === 'user' &&
        message.ordinal > question.sourceOrdinal).map(message => message.text));
      const matches = records.filter(record => {
        const answer = parseAnswer(record.inputText);
        const sourceMatched = saved?.id === record.id && saved.questionKey === key ||
          answerSources.has(record.inputText);
        return sourceMatched && answer?.question_id === question.id && answer.revision === question.revision &&
          question.options.some(option => option.id === answer.option_id);
      });
      const hostAnswer = matches.at(-1);
      const localAnswer = saved && parseAnswer(saved.text);
      const localMatch = saved?.questionKey === key && localAnswer?.question_id === question.id;
      const status = hostAnswer ? hostAnswer.status === 'completed' ? 'completed' : hostAnswer.status === 'uncertain' ? 'uncertain' : 'accepted' :
        localMatch ? saved.status === 'sending' ? 'submitting' : saved.status === 'not_found' ? 'open' : 'uncertain' : 'open';
      question = Object.freeze({...question, options: Object.freeze(question.options.map(option => Object.freeze({...option}))),
        selection: selection?.optionId ?? (hostAnswer ? parseAnswer(hostAnswer.inputText).option_id : null), status});
    }
    snapshot = Object.freeze({connection, engagementId: privateVisible ? state.engagementId : null,
      transcriptCursor: privateVisible ? state.history.cursor : 0, journalCursor: privateVisible ? state.journal.cursor : 0,
      transcriptHasMore: privateVisible && state.history.through !== null, journalHasMore: privateVisible && state.journal.through !== null,
      messages: Object.freeze(privateVisible ? [...state.messages] : []), deliveries: Object.freeze(privateVisible ? records : []),
      saved: saved ? Object.freeze({id: saved.id, text: privateVisible ? saved.text : '', status: saved.status}) : null,
      question: privateVisible ? question : null, error, busy, version: ++version});
    for (const listener of listeners) listener();
  }
  publish();
  function clear(code, erase) {
    if (!erase && saved?.status === 'sending') saved.status = 'uncertain';
    generation++; state = freshState(pageLimit); selection = null; busy = false;
    connection = erase ? 'unauthorized' : 'disconnected'; error = code;
    if (erase) { saved = null; fence = null; }
    void transport.close?.(); publish();
  }
  const unlisten = transport.subscribe?.(code => {
    if (code === 'unauthorized') clear(code, true);
    else if (code === 'disconnected') { if (saved?.status === 'sending') saved.status = 'uncertain'; clear('conversation_unavailable', false); }
  });
  async function request(operation, input, options, working, currentGeneration) {
    const expected = working.engagementId ?? fence;
    const context = {operation, caller, target, input, options: {...options,
      ...(expected ? {expected_engagement_id: expected} : {})}};
    const binary = await transport.request(context);
    if (currentGeneration !== generation || destroyed) fail('stale_connection');
    return decodeReply(binary, context);
  }
  async function run(body) {
    if (destroyed || connection === 'unauthorized') return {ok: false, error: 'unauthorized'};
    if (busy) return {ok: false, error: 'transport_busy'};
    busy = true; error = null; publish(); const currentGeneration = generation;
    try {
      const result = await body(currentGeneration);
      if (currentGeneration !== generation) fail('stale_connection');
      busy = false; publish(); return {ok: true, ...result};
    } catch (caught) {
      const code = errorCode(caught);
      if (currentGeneration !== generation || destroyed) return {ok: false, error: 'stale_connection'};
      busy = false;
      if (['unauthorized','conversation_scope_changed','conflicting_response'].includes(code)) clear(code, true);
      else if (['transport_timeout','conversation_unavailable','transport_not_attached','invalid_transport_response',
        'invalid_page_bounds','invalid_history_page','invalid_history_entry','invalid_command_response',
        'invalid_command_page','invalid_command_event','invalid_command_transition'].includes(code)) clear(code, false);
      else { error = code; publish(); }
      return {ok: false, error: code};
    }
  }
  async function syncInternal(currentGeneration) {
    const next = copyState(state);
    for (const streamName of ['history','journal']) {
      for (let remaining = maxPages; remaining > 0;) {
        const stream = next[streamName], operation = streamName === 'history' ? 'history' : 'events';
        const options = {limit: stream.limit, ...(stream.through !== null ? {through: stream.through} : {}),
          ...(streamName === 'history' ? {after: stream.cursor} : {})};
        let page;
        try { page = await request(operation, operation === 'history' ? null : stream.cursor, options, next, currentGeneration); }
        catch (caught) {
          if (errorCode(caught) === 'page_too_large' && stream.limit > 1) { stream.limit = Math.max(Math.floor(stream.limit / 2), 1); continue; }
          throw caught;
        }
        if (operation === 'history') consumeHistory(next, page, target); else consumeEvents(next, page, target);
        remaining--; if (!page.has_more) break;
      }
    }
    state = next; fence = next.engagementId; connection = 'connected';
    if (saved && state.commands.has(saved.id)) saved.status = savedStatus(state.commands.get(saved.id));
    return {};
  }
  async function submitInternal(textValue, currentGeneration, existing = false, questionKey = null) {
    if (connection !== 'connected') fail('conversation_not_attached');
    if (!text(textValue, 32768) || !textValue.trim()) fail('invalid_command');
    if (!existing && saved && !['completed','uncertain_terminal'].includes(saved.status)) fail('saved_command_pending');
    if (!existing) {
      const id = idFactory(); if (!identifier(id)) fail('invalid_command');
      saved = {id, text: textValue, status: 'sending', questionKey};
    } else saved.status = 'sending';
    publish();
    try {
      const next = copyState(state), raw = await request('submit', {id: saved.id, text: saved.text}, {}, next, currentGeneration);
      const delivery = observe(next, raw, target, saved.id, saved.text);
      state = next; saved.status = savedStatus(delivery); return {delivery};
    } catch (caught) {
      if (saved && currentGeneration === generation) saved.status = 'uncertain';
      throw caught;
    }
  }
  const store = {
    getSnapshot: () => snapshot,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    sync: () => run(syncInternal),
    submit: value => run(generation => submitInternal(value, generation)),
    checkSaved: () => run(async currentGeneration => {
      if (!saved) fail('no_saved_command');
      if (connection !== 'connected') await syncInternal(currentGeneration);
      const next = copyState(state);
      try {
        const raw = await request('command', saved.id, {}, next, currentGeneration);
        const delivery = observe(next, raw, target, saved.id, saved.text);
        state = next; saved.status = savedStatus(delivery); return {delivery};
      } catch (caught) {
        if (errorCode(caught) !== 'not_found') throw caught;
        if (state.commands.has(saved.id) || state.observed.has(saved.id)) fail('conflicting_response');
        saved.status = 'not_found'; return {notFound: true};
      }
    }),
    retrySaved: () => run(async currentGeneration => {
      if (!saved || saved.status !== 'not_found') fail('lookup_required_before_retry');
      if (connection !== 'connected') await syncInternal(currentGeneration);
      // Explicit retry still uses the original ID and text; never a new turn ID.
      return submitInternal(saved.text, currentGeneration, true);
    }),
    selectOption(optionId) {
      const question = snapshot.question;
      if (!question || question.status !== 'open' || busy || !question.options.some(option => option.id === optionId)) return false;
      selection = {key: `${question.sourceMessageId}:${question.revision}`, optionId}; publish(); return true;
    },
    confirmQuestion: () => run(currentGeneration => {
      const question = snapshot.question;
      if (!question || question.status !== 'open' || !selection ||
          selection.key !== `${question.sourceMessageId}:${question.revision}`) fail('question_not_actionable');
      return submitInternal(answerText(question, selection.optionId), currentGeneration, false, selection.key);
    }),
    async disconnect() { clear(null, false); },
    async loseAccess() { clear('unauthorized', true); },
    async destroy() { destroyed = true; clear(null, true); unlisten?.(); listeners.clear(); }
  };
  return store;
}
