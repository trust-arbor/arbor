// Mirrors the existing Arbor v2 conversation protocol; it is not a new login API.
export class ConversationError extends Error {
  constructor(code) { super(code); this.name = 'ConversationError'; this.code = code; }
}
export const fail = (code) => { throw new ConversationError(code); };
export const exact = (value, keys) => value !== null && typeof value === 'object' &&
  !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(k => Object.hasOwn(value, k));
export const identifier = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,256}$/.test(value);
export const engagement = value => typeof value === 'string' && /^eng_[0-9a-f]{32}$/.test(value);
export const ordinal = value => Number.isSafeInteger(value) && value >= 0;
export const text = (value, max) => typeof value === 'string' && new TextEncoder().encode(value).byteLength <= max;
const errors = new Set(['unauthorized', 'conversation_scope_changed', 'unsupported_conversation_capability',
  'not_found', 'command_conflict', 'conversation_unavailable', 'page_too_large', 'invalid_opts',
  'invalid_cursor', 'invalid_command', 'invalid_caller_id', 'invalid_agent_id', 'invalid_content',
  'invalid_message', 'invalid_sender', 'invalid_engagement_id']);
const allowedOptions = {history: ['after', 'through', 'limit'], events: ['through', 'limit'], submit: [], command: []};

export function sessionFrame(context) {
  const {operation, caller, target, input, options = {}} = context;
  if (!Object.hasOwn(allowedOptions, operation) || !identifier(caller) || !identifier(target)) fail('invalid_request');
  if (operation === 'history' && input !== null || operation === 'events' && !ordinal(input) ||
      operation === 'command' && !identifier(input) || operation === 'submit' &&
      (!exact(input, ['id', 'text']) || !identifier(input.id) || !text(input.text, 32768) || !input.text.trim())) fail('invalid_request');
  for (const [key, value] of Object.entries(options)) {
    if (key === 'expected_engagement_id' ? !engagement(value) : !allowedOptions[operation].includes(key) || !ordinal(value)) fail('invalid_request');
  }
  const payload = JSON.stringify(['arbor.conversation.v2', operation, caller, target,
    operation === 'submit' ? [input.id, input.text] : input,
    [options.after ?? null, options.through ?? null, options.limit ?? null], options.expected_engagement_id ?? null]);
  const frame = JSON.stringify({payload, authentication: 'conversation_session'});
  if (!text(frame, 262144)) fail('invalid_request');
  return frame;
}

// Only the operation's response is admitted. Legacy deltas never become history.
export function decodeReply(binary, context) {
  if (!text(binary, 8388608)) fail('invalid_transport_response');
  let envelope;
  try { envelope = JSON.parse(binary); } catch { fail('invalid_transport_response'); }
  if (exact(envelope, ['type', 'reason']) && envelope.type === 'error') {
    if (errors.has(envelope.reason)) fail(envelope.reason);
    if (envelope.reason === 'not_attached') fail('transport_not_attached');
    if (envelope.reason === 'server_commands_unavailable') fail('unsupported_conversation_capability');
    fail('invalid_transport_response');
  }
  if (!exact(envelope, ['type', 'data'])) fail('invalid_transport_response');
  if (envelope.type === 'conversation_rejected' && context.operation === 'submit' &&
      exact(envelope.data, ['id', 'reason']) && envelope.data.id === context.input.id &&
      ['invalid_command', 'command_conflict', 'unsupported_conversation_capability'].includes(envelope.data.reason)) fail(envelope.data.reason);
  const expected = {history: 'conversation_history', events: 'conversation_events', submit: 'conversation_command', command: 'conversation_command'};
  if (envelope.type !== expected[context.operation]) fail('invalid_transport_response');
  return envelope.data;
}

export function errorCode(error) {
  return error instanceof ConversationError ? error.code : 'conversation_unavailable';
}
