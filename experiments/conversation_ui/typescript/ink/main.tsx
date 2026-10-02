import React from "react";
import { render } from "ink";
import { createConversationStore } from "../shared/store.mjs";
import { createFixtureTransport } from "../shared/fixture.mjs";
import { ComparisonInkApp } from "./App.js";

const requestedCount = Number(process.argv[2] ?? "0");
if (!Number.isSafeInteger(requestedCount) || requestedCount < 0 || requestedCount > 10_000) {
  throw new Error("Usage: tsx ink/main.tsx [history count: 0..10000]");
}
const transport = createFixtureTransport({ entryCount: requestedCount });
const store = createConversationStore({ caller: "human_comparison", target: "agent_comparison", transport });
const app = render(<ComparisonInkApp store={store}
  onDropAcknowledgement={() => transport.failNextSubmit("admitted")}
  onExpireAccess={() => { transport.setUnauthorized(); void store.sync(); }} />);
void store.sync();
await app.waitUntilExit();
await store.disconnect();
