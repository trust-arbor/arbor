import React from "react";
import { createRoot } from "react-dom/client";
import { createConversationStore } from "../shared/store.mjs";
import { createFixtureTransport } from "../shared/fixture.mjs";
import { ComparisonWebApp } from "./App.js";
import "./style.css";

const requestedCount = Number(new URLSearchParams(window.location.search).get("history") ?? "0");
const entryCount = Number.isSafeInteger(requestedCount) && requestedCount >= 0 && requestedCount <= 10_000 ? requestedCount : 0;
const transport = createFixtureTransport({ entryCount });
const store = createConversationStore({ caller: "human_comparison", target: "agent_comparison", transport });
const root = document.getElementById("root");
if (!root) throw new Error("Missing comparison root.");
createRoot(root).render(<ComparisonWebApp store={store}
  onDropAcknowledgement={() => transport.failNextSubmit("admitted")}
  onExpireAccess={() => { transport.setUnauthorized(); void store.sync(); }} />);
void store.sync();
