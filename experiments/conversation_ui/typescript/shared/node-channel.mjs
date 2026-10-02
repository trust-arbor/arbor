import {ConversationError} from './wire.mjs';

// Kept separate from browser-imported modules. Node's built-in WebSocket cannot
// set the Authorization upgrade header used by Arbor.Client.Socket.
export async function openNodeChannel({gatewayUrl, credential, connectTimeoutMs = 5000, webSocketClass}) {
  const WebSocket = webSocketClass ?? (await import('ws')).default;
  const url = new URL(gatewayUrl);
  if (!['http:','https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash ||
      !['','/'].includes(url.pathname) || typeof credential !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(credential) ||
      Buffer.from(credential,'base64url').length !== 32 || Buffer.from(credential,'base64url').toString('base64url') !== credential ||
      url.protocol === 'http:' && !['127.0.0.1','localhost','[::1]'].includes(url.hostname)) throw new ConversationError('invalid_options');
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'; url.pathname = '/api/chat/socket';
  let socket;
  const deadline = Date.now() + connectTimeoutMs;
  while (!socket) {
    const candidate = new WebSocket(url, {headers: {authorization: `Conversation ${credential}`},
      perMessageDeflate: false, followRedirects: false, maxPayload: 8388608, handshakeTimeout: Math.max(deadline-Date.now(),1)});
    try {
      await new Promise((resolve, reject) => {
        candidate.once('open', resolve);
        candidate.once('error', () => { candidate.terminate(); reject(new ConversationError('conversation_unavailable')); });
        candidate.once('unexpected-response', (_request, response) => {
          response.resume(); candidate.terminate();
          reject(new ConversationError(response.statusCode === 401 || response.statusCode === 403 ? 'unauthorized' :
            response.statusCode === 409 ? 'attachment_pending' : 'conversation_unavailable'));
        });
      });
      socket = candidate;
    } catch (error) {
      // The existing SDK retries only an upgrade409 while the preceding owned
      // connection closes. No conversation frame is resent, and total time stays bounded.
      if (error.code !== 'attachment_pending' || Date.now() >= deadline) throw new ConversationError(error.code === 'unauthorized' ? 'unauthorized' : 'conversation_unavailable');
      await new Promise(resolve=>setTimeout(resolve,Math.min(50,Math.max(deadline-Date.now(),1))));
    }
  }
  const listeners = new Set();
  socket.on('message', (data, isBinary) => {
    const event = isBinary ? {type: 'invalid'} : {type: 'message', data: data.toString('utf8')};
    for (const listener of listeners) listener(event);
  });
  socket.on('close', code => { for (const listener of listeners) listener({type: 'closed', reason: code === 1008 ? 'unauthorized' : 'closed'}); });
  socket.on('error', () => { for (const listener of listeners) listener({type: 'closed', reason: 'closed'}); });
  return {send: frame => socket.send(frame), subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    close() { listeners.clear(); socket.terminate(); }};
}
