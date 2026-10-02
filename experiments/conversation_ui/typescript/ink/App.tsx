import React, { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { Box, Text, useInput } from "ink";
import { useExternalStoreRuntime, useExternalMessageConverter } from "@assistant-ui/core/react";
import {
  AssistantRuntimeProvider, ComposerPrimitive, ThreadPrimitive, useAuiState,
  type AppendMessage, type ThreadMessageLike,
} from "@assistant-ui/react-ink";
import type { ConversationMessage, ConversationStore } from "../shared/store.mjs";
import { displayMessageText } from "../shared/question.mjs";

export const WINDOW_SIZE = 20;
type Snapshot = ReturnType<ConversationStore["getSnapshot"]>;
type Mode = "message" | "question" | "controls";
export type InkAppProps = {
  store: ConversationStore;
  initialFullHistory?: boolean;
  onDropAcknowledgement?: () => void;
  onExpireAccess?: () => void;
  /** Optional comparison measurement: reports actual scoped runtime IDs, never content. */
  onMessageRendered?: (id: string) => void;
  /** Test-only observation of the public composer projection; never controls it. */
  onComposerText?: (text: string | null) => void;
};

const convertMessage = (message: ConversationMessage): ThreadMessageLike => ({
  id: message.id, role: message.role, createdAt: new Date(message.timestamp),
  content: [{ type: "text", text: displayMessageText(message) }],
});

function Message({ onRendered }: { onRendered?: (id: string) => void }) {
  const message = useAuiState((state) => state.message);
  useEffect(() => { onRendered?.(message.id); }, [message.id, onRendered]);
  return <Box flexDirection="column" marginBottom={1}>
    <Text color={message.role === "user" ? "green" : "cyan"}>{message.role}</Text>
    <Text wrap="wrap">{message.content.filter((part) => part.type === "text").map((part) => part.text).join("")}</Text>
  </Box>;
}
function ComposerObservation({ onText }: { onText: (text: string | null) => void }) {
  const text = useAuiState((state) => state.composer.text);
  useEffect(() => { onText(text); return () => onText(null); }, [text, onText]);
  return null;
}
function RuntimeThread({ store, snapshot, messages, mode, onMessageRendered, onComposerText }: {
  store: ConversationStore; snapshot: Snapshot; messages: readonly ConversationMessage[]; mode: Mode;
  onMessageRendered?: (id: string) => void;
  onComposerText?: (text: string | null) => void;
}) {
  const onNew = useCallback(async (message: AppendMessage) => {
    if (message.content.some((part) => part.type !== "text")) throw new Error("Text only.");
    await store.submit(message.content.filter((part) => part.type === "text").map((part) => part.text).join(""));
  }, [store]);
  const blocked = snapshot.busy || snapshot.connection !== "connected" ||
    (snapshot.saved !== null && !["completed", "uncertain_terminal"].includes(snapshot.saved.status));
  // Keep the host-owned readonly snapshot separate from the converter's array.
  const externalMessages = useMemo(() => Array.from(messages), [messages]);
  const convertedMessages = useExternalMessageConverter({
    messages: externalMessages, callback: convertMessage, isRunning: false, joinStrategy: "none",
  });
  const runtime = useExternalStoreRuntime({ messages: convertedMessages, onNew, isDisabled: blocked, isSendDisabled: blocked, isRunning: false });
  const renderMessage = useCallback(() => <Message onRendered={onMessageRendered} />, [onMessageRendered]);
  return <AssistantRuntimeProvider runtime={runtime}>
    <ThreadPrimitive.Root>
      {/* No windowSize: Ink's Static scrollback is deliberately not used. */}
      <ThreadPrimitive.Messages>{renderMessage}</ThreadPrimitive.Messages>
      {messages.length === 0 && <Text dimColor>No conversation messages.</Text>}
      <ComposerPrimitive.Root borderStyle="single" paddingX={1}>
        {mode === "message" ? <ComposerPrimitive.Input submitOnEnter autoFocus placeholder="Message · Enter to send" /> :
          <Text dimColor>Message editor paused · Tab to change focus</Text>}
        {onComposerText && <ComposerObservation onText={onComposerText} />}
      </ComposerPrimitive.Root>
    </ThreadPrimitive.Root>
  </AssistantRuntimeProvider>;
}

export function ComparisonInkApp({ store, initialFullHistory = false, onDropAcknowledgement, onExpireAccess, onMessageRendered, onComposerText }: InkAppProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [mode, setMode] = useState<Mode>("message");
  const [pageBack, setPageBack] = useState(0);
  const [fullHistory, setFullHistory] = useState(initialFullHistory);
  const [actionFailed, setActionFailed] = useState(false);
  const lost = snapshot.connection === "unauthorized";
  const count = snapshot.messages.length;
  const page = Math.min(pageBack, Math.max(0, Math.ceil(count / WINDOW_SIZE) - 1));
  const end = Math.max(0, count - page * WINDOW_SIZE);
  const start = fullHistory ? 0 : Math.max(0, end - WINDOW_SIZE);
  const visible = fullHistory ? snapshot.messages : snapshot.messages.slice(start, end);
  const question = snapshot.question;
  const run = (action: () => unknown) => {
    setActionFailed(false);
    Promise.resolve().then(action).catch(() => setActionFailed(true));
  };

  useInput((input, key) => {
    if (key.tab) {
      setMode(mode === "message" ? (question ? "question" : "controls") : mode === "question" ? "controls" : "message");
      return;
    }
    if (lost) return;
    if (mode === "question" && question && !snapshot.busy && snapshot.connection === "connected" && question.status === "open") {
      const choice = Number(input) - 1;
      if (/^[123]$/.test(input) && question.options[choice]) run(() => store.selectOption(question.options[choice]!.id));
      if (key.return && question.selection) run(() => store.confirmQuestion());
    }
    if (mode !== "controls") return;
    if (input === "r") run(() => store.sync());
    if (input === "d") run(() => store.disconnect());
    if (input === "c" && snapshot.saved) run(() => store.checkSaved());
    if (input === "t" && snapshot.saved?.status === "not_found") run(() => store.retrySaved());
    if (input === "p" && !fullHistory && start > 0) setPageBack(page + 1);
    if (input === "n" && !fullHistory) setPageBack(Math.max(0, page - 1));
    if (input === "l") { setPageBack(0); setFullHistory(false); }
    if (input === "f") setFullHistory(!fullHistory);
    if (input === "u" && onDropAcknowledgement) onDropAcknowledgement();
    if (input === "x" && onExpireAccess) onExpireAccess();
  });

  return <Box flexDirection="column">
    <Text bold color="green">ARBOR / ASSISTANT-UI · INK · shared conversation</Text>
    <Text>{snapshot.connection} · explicit refresh</Text>
    {lost ? <Text color="yellow">Access unavailable. Private conversation data and the active draft have been cleared.</Text> : <>
      <Text dimColor>Showing {count === 0 ? 0 : start + 1}–{fullHistory ? count : end} of {count} · {fullHistory ? "full history" : `window ${WINDOW_SIZE}`}</Text>
      <RuntimeThread key={snapshot.engagementId ?? "unbound"} store={store} snapshot={snapshot} messages={visible} mode={mode} onMessageRendered={onMessageRendered} onComposerText={onComposerText} />
      {question && <Box flexDirection="column" borderStyle="single" paddingX={1}>
        <Text bold>{question.prompt}</Text>
        {question.options.map((option, index) => <Text key={option.id} color={question.selection === option.id ? "green" : undefined}>
          {question.selection === option.id ? "●" : "○"} {index + 1}. {option.label}
        </Text>)}
        <Text>Question: {question.status} · {mode === "question" ? "1/2/3 select · Enter confirms" : "Tab to focus question"}</Text>
      </Box>}
      {snapshot.saved && <Text>Saved request: {snapshot.saved.status}</Text>}
      {snapshot.deliveries.slice(-20).map((delivery) => <Text key={delivery.id}>Delivery {delivery.status}</Text>)}
    </>}
    <Text>Focus: {mode} · Tab changes focus · Ctrl+C exits</Text>
    <Text dimColor>Controls: r refresh/reconnect · d disconnect · c check saved · t retry saved</Text>
    <Text dimColor>History: p older · n newer · l latest · f full/window</Text>
    {(onDropAcknowledgement || onExpireAccess) && <Text dimColor>Fixture only: u lose next send acknowledgement · x expire access</Text>}
    <Text dimColor>Transcript {snapshot.transcriptCursor} · Journal {snapshot.journalCursor}</Text>
    {(snapshot.error || actionFailed) && <Text color="yellow">{snapshot.error ?? "Action could not complete."}</Text>}
  </Box>;
}
