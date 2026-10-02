import {ConversationError, decodeReply, sessionFrame, exact, fail} from './wire.mjs';

/** An injected, privileged channel owns authentication; no credentials enter UI state. */
export function createSessionTransport({openChannel, timeoutMs = 5000}) {
  let channel = null, attached = null, pending = null, generation = 0, opening = null, fault = null;
  const listeners = new Set();
  function retire() {
    generation++; attached = null; opening = null;
    const previous = channel; channel = null;
    previous?.unsubscribe?.(); previous?.close?.();
  }
  function finish(error, value) {
    if (!pending) return;
    const previous = pending; pending = null; clearTimeout(previous.timer);
    error ? previous.reject(error) : previous.resolve(value);
  }
  function shutdown(code, notify = true) {
    if (code === 'unauthorized') fault = code;
    finish(new ConversationError(code)); retire();
    if (notify) for (const listener of listeners) listener(code === 'unauthorized' ? code : 'disconnected');
  }
  async function ensureChannel() {
    if (channel) return;
    const token = generation; opening = token;
    let opened;
    try { opened = await openChannel(); }
    finally { if (opening === token) opening = null; }
    if (token !== generation || !pending) { opened.close(); fail('stale_connection'); }
    channel = opened;
    channel.unsubscribe = channel.subscribe(event => {
      if (token !== generation) return;
      if (event.type === 'closed') { shutdown(event.reason === 'unauthorized' ? 'unauthorized' : 'conversation_unavailable'); return; }
      if (event.type !== 'message') { shutdown('invalid_transport_response'); return; }
      let control;
      try { control = JSON.parse(event.data); } catch { shutdown('invalid_transport_response'); return; }
      if (exact(control, ['type','reason']) && control.type === 'error' && control.reason === 'unauthorized') {
        shutdown('unauthorized'); return;
      }
      if (!pending) { shutdown('invalid_transport_response'); return; }
      try {
        const reply = decodeReply(event.data, pending.context);
        if (pending.context.operation === 'history') attached = reply.engagement_id;
        finish(null, event.data);
      } catch (error) {
        finish(error);
        if (['invalid_transport_response','conversation_scope_changed','transport_not_attached'].includes(error.code)) retire();
      }
    });
  }
  return {
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    async close() { finish(new ConversationError('conversation_unavailable')); retire(); },
    request(context) {
      if (fault) return Promise.reject(new ConversationError(fault));
      if (pending || opening !== null) return Promise.reject(new ConversationError('transport_busy'));
      if (context.operation !== 'history' && attached === null) return Promise.reject(new ConversationError('transport_not_attached'));
      if (attached && context.options.expected_engagement_id !== attached) {
        retire(); return Promise.reject(new ConversationError('conversation_scope_changed'));
      }
      let frame;
      try { frame = sessionFrame(context); } catch (error) { return Promise.reject(error); }
      return new Promise((resolve, reject) => {
        const request = {context, resolve, reject, timer: setTimeout(() => shutdown('transport_timeout', false), timeoutMs)};
        pending = request;
        ensureChannel().then(() => {
          if (pending !== request) return;
          try { channel.send(frame); } catch { shutdown('conversation_unavailable'); }
        }).catch(error => {
          if (pending === request) shutdown(error?.code === 'unauthorized' ? 'unauthorized' : 'conversation_unavailable');
        });
      });
    }
  };
}
