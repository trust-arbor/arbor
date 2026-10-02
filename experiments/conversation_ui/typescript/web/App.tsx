import React, { useCallback, useMemo, useState, useSyncExternalStore } from "react";
import {
  AssistantRuntimeProvider,
  ComposerPrimitive,
  ThreadPrimitive,
  useAuiState,
  useExternalMessageConverter,
  useExternalStoreRuntime,
  type AppendMessage,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import type { ConversationMessage, ConversationStore } from "../shared/store.mjs";
import { displayMessageText } from "../shared/question.mjs";

export const WINDOW_SIZE = 20;
type Snapshot = ReturnType<ConversationStore["getSnapshot"]>;

export type WebAppProps = {
  store: ConversationStore;
  initialFullHistory?: boolean;
  onDropAcknowledgement?: () => void;
  onExpireAccess?: () => void;
};

const convertMessage = (message: ConversationMessage): ThreadMessageLike => ({
  id: message.id,
  role: message.role,
  createdAt: new Date(message.timestamp),
  content: [{ type: "text", text: displayMessageText(message) }],
});

function Message() {
  const message = useAuiState((state) => state.message);
  return (
    <article className="message" data-message-id={message.id} data-role={message.role}>
      <span className="role">{message.role}</span>
      <p>{message.content.filter((part) => part.type === "text").map((part) => part.text).join("")}</p>
    </article>
  );
}

const renderMessage = () => <Message />;

function RuntimeThread({ store, snapshot, messages }: {
  store: ConversationStore;
  snapshot: Snapshot;
  messages: readonly ConversationMessage[];
}) {
  const onNew = useCallback(async (message: AppendMessage) => {
    if (message.content.some((part) => part.type !== "text")) {
      throw new Error("This comparison accepts text messages only.");
    }
    await store.submit(message.content.filter((part) => part.type === "text").map((part) => part.text).join(""));
  }, [store]);
  const blocked = snapshot.busy || snapshot.connection !== "connected" ||
    (snapshot.saved !== null && !["completed", "uncertain_terminal"].includes(snapshot.saved.status));
  // The released converter accepts a mutable array; give it an owned list while
  // retaining the immutable host message objects and their durable identities.
  const externalMessages = useMemo(() => Array.from(messages), [messages]);
  const convertedMessages = useExternalMessageConverter({
    messages: externalMessages, callback: convertMessage, isRunning: false, joinStrategy: "none",
  });
  const runtime = useExternalStoreRuntime({
    messages: convertedMessages,
    onNew,
    isDisabled: blocked,
    isSendDisabled: blocked,
    // Delivery state comes from Arbor. Do not invent an optimistic assistant row.
    isRunning: false,
  });

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root className="thread">
        <section className="transcript" aria-label="Conversation transcript" data-testid="transcript">
          <ThreadPrimitive.Messages>{renderMessage}</ThreadPrimitive.Messages>
          {messages.length === 0 && <p className="empty">No conversation messages.</p>}
        </section>
        <ComposerPrimitive.Root className="composer">
          <ComposerPrimitive.Input aria-label="Message" placeholder="Message" rows={2} />
          <ComposerPrimitive.Send>Send</ComposerPrimitive.Send>
        </ComposerPrimitive.Root>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

export function ComparisonWebApp({ store, initialFullHistory = false, onDropAcknowledgement, onExpireAccess }: WebAppProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [pageBack, setPageBack] = useState(0);
  const [fullHistory, setFullHistory] = useState(initialFullHistory);
  const [actionFailed, setActionFailed] = useState(false);
  const lost = snapshot.connection === "unauthorized";
  const count = snapshot.messages.length;
  const page = Math.min(pageBack, Math.max(0, Math.ceil(count / WINDOW_SIZE) - 1));
  const end = Math.max(0, count - page * WINDOW_SIZE);
  const start = fullHistory ? 0 : Math.max(0, end - WINDOW_SIZE);
  const visible = fullHistory ? snapshot.messages : snapshot.messages.slice(start, end);

  const run = (action: () => unknown) => {
    setActionFailed(false);
    Promise.resolve().then(action).catch(() => setActionFailed(true));
  };
  const question = snapshot.question;
  const questionDisabled = snapshot.busy || snapshot.connection !== "connected" || question?.status !== "open";

  return (
    <main>
      <header>
        <p className="eyebrow">ARBOR / ASSISTANT-UI · WEB</p>
        <h1>Shared conversation</h1>
        <p role="status">{snapshot.connection} · explicit refresh</p>
      </header>
      <nav aria-label="Conversation controls">
        <button onClick={() => run(() => store.sync())} disabled={lost}>Refresh / reconnect</button>
        <button onClick={() => run(() => store.disconnect())} disabled={lost}>Disconnect</button>
        <button onClick={() => run(() => store.checkSaved())} disabled={lost || !snapshot.saved}>Check saved request</button>
        <button onClick={() => run(() => store.retrySaved())} disabled={lost || snapshot.saved?.status !== "not_found"}>Retry saved request</button>
      </nav>

      {lost ? (
        <section role="alert" data-testid="access-cleared">
          Access unavailable. Private conversation data and the active draft have been cleared.
        </section>
      ) : (
        <>
          <div className="history-controls">
            <button onClick={() => setPageBack(page + 1)} disabled={fullHistory || start === 0}>Older</button>
            <button onClick={() => setPageBack(Math.max(0, page - 1))} disabled={fullHistory || page === 0}>Newer</button>
            <button onClick={() => { setPageBack(0); setFullHistory(false); }}>Latest</button>
            <label><input type="checkbox" checked={fullHistory} onChange={(event) => setFullHistory(event.target.checked)} /> Full history</label>
            <output data-testid="history-count">Showing {count === 0 ? 0 : start + 1}–{fullHistory ? count : end} of {count}</output>
          </div>
          <RuntimeThread key={snapshot.engagementId ?? "unbound"} store={store} snapshot={snapshot} messages={visible} />
          {question && (
            <section className="question" aria-label="Choose an option">
              <h2>{question.prompt}</h2>
              <div role="group" aria-label="Three options">
                {question.options.map((option) => (
                  <button key={option.id} data-option-id={option.id} aria-pressed={question.selection === option.id}
                    disabled={questionDisabled} onClick={() => run(() => store.selectOption(option.id))}>
                    {option.label}
                  </button>
                ))}
              </div>
              <button onClick={() => run(() => store.confirmQuestion())} disabled={questionDisabled || !question.selection}>Confirm selection</button>
              <p role="status" data-testid="question-status">Question: {question.status}</p>
            </section>
          )}
          <section className="delivery" aria-label="Delivery status">
            {snapshot.saved && <p data-testid="saved-status">Saved request: {snapshot.saved.status}</p>}
            {snapshot.deliveries.slice(-20).map((delivery) => <p key={delivery.id}>Delivery {delivery.status}</p>)}
          </section>
        </>
      )}
      <footer>
        <p>Transcript {snapshot.transcriptCursor} · Journal {snapshot.journalCursor}</p>
        {(snapshot.error || actionFailed) && <p role="alert">{snapshot.error ?? "Action could not complete."}</p>}
        {(onDropAcknowledgement || onExpireAccess) && <details><summary>Fixture controls</summary>
          {onDropAcknowledgement && <button onClick={onDropAcknowledgement}>Lose next send acknowledgement</button>}
          {onExpireAccess && <button onClick={onExpireAccess}>Expire access</button>}
          <p>Controlled comparison fixture. These controls do not change a live Arbor session.</p>
        </details>}
      </footer>
    </main>
  );
}
