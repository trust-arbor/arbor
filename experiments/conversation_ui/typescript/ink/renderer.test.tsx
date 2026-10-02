import test, { after } from "node:test";
import assert from "node:assert/strict";
import React, { act } from "react";
import { render } from "ink-testing-library";
import { createConversationStore } from "../shared/store.mjs";
import { createFixtureTransport } from "../shared/fixture.mjs";
import { ComparisonInkApp, WINDOW_SIZE } from "./App.js";
import { hasFocusedEmptyMessageInput } from "./testing.js";

const previousActEnvironment = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { value: true, configurable: true });
after(() => {
  if (previousActEnvironment) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", previousActEnvironment);
  else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT");
});

async function settle(predicate: () => boolean, diagnostics?: () => unknown) {
  // A frame is committed before Ink's passive input-listener effects attach.
  // Flush the public React lifecycle even if the frame already matches.
  await act(async () => {});
  for (let index = 0; index < 200 && !predicate(); index++) {
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
  }
  assert.ok(predicate(), `Expected renderer state did not appear.${diagnostics ? ` ${JSON.stringify(diagnostics())}` : ""}`);
}
async function fixture(entryCount = 0, includeQuestion = true, onMessageRendered?: (id: string) => void) {
  const transport = createFixtureTransport({ entryCount, includeQuestion });
  const store = createConversationStore({ caller: "human_comparison", target: "agent_comparison", transport });
  const hydrationStarted = performance.now();
  assert.equal((await store.sync()).ok, true);
  const hydrationMs = performance.now() - hydrationStarted;
  const mountStarted = performance.now();
  let composerText: string | null = null;
  let app!: ReturnType<typeof render>;
  await act(async () => {
    app = render(<ComparisonInkApp store={store} onMessageRendered={onMessageRendered} onComposerText={(text) => { composerText = text; }} />);
  });
  await settle(() => hasFocusedEmptyMessageInput(app.lastFrame()));
  const mountMs = performance.now() - mountStarted;
  const diagnostics = () => ({ composerText, connection: store.getSnapshot().connection,
    savedStatus: store.getSnapshot().saved?.status ?? null,
    submitCount: transport.calls.filter((call) => call.operation === "submit").length,
    activeFrame: app.lastFrame()?.split("\n").slice(-24).join("\n") ?? null });
  return { transport, store, app, hydrationMs, mountMs, diagnostics, getComposerText: () => composerText, async key(value: string) {
    await act(async () => { app.stdin.write(value); });
  }, async close() {
    await act(async () => { app.unmount(); app.cleanup(); await store.destroy(); });
  } };
}

test("ink: choose and confirm uses the authoritative command and question state", async () => {
  const f = await fixture();
  try {
    const question = f.store.getSnapshot().question;
    assert.ok(question);
    await f.key("\t");
    assert.match(f.app.lastFrame()!, /Focus: question/);
    await f.key("2");
    assert.equal(f.store.getSnapshot().question?.selection, question.options[1]!.id);
    await f.key("\r");
    await settle(() => f.app.lastFrame()?.includes("Question: completed") ?? false);
    await f.key("\t");
    await f.key("r");
    await settle(() => f.store.getSnapshot().messages.some((message) => message.role === "user"));
    assert.equal(f.store.getSnapshot().messages.filter((message) => message.role === "user").length, 1);
  } finally { await f.close(); }
});

test("ink: auth loss clears the active transcript, question, and composer projection", async () => {
  const f = await fixture();
  try {
    f.transport.appendMessage("assistant", "PRIVATE-INK-TRANSCRIPT");
    await act(async () => { await f.store.sync(); });
    await settle(() => f.app.lastFrame()?.includes("PRIVATE-INK-TRANSCRIPT") ?? false);
    await f.key("PRIVATE-INK-DRAFT");
    await settle(() => f.app.lastFrame()?.includes("PRIVATE-INK-DRAFT") ?? false);
    await act(async () => { await f.store.loseAccess(); });
    await settle(() => f.app.lastFrame()?.includes("Access unavailable.") ?? false);
    assert.equal(f.getComposerText(), null);
    assert.doesNotMatch(f.app.lastFrame()!, /PRIVATE-INK-TRANSCRIPT|PRIVATE-INK-DRAFT|Question:/);
    assert.equal(f.store.getSnapshot().messages.length, 0);
    // lastFrame is the active screen only; terminal scrollback is not erased.
  } finally { await f.close(); }
});

test("ink: 10000 messages stay windowed and full controls render 100 messages", { timeout: 60_000 }, async () => {
  const renderedIds = new Set<string>();
  const f = await fixture(10_000, false, (id) => renderedIds.add(id));
  try {
    const messages = f.store.getSnapshot().messages;
    assert.equal(messages.length, 10_000);
    await settle(() => renderedIds.size === WINDOW_SIZE);
    assert.deepEqual([...renderedIds], messages.slice(-WINDOW_SIZE).map((message) => message.id));
    assert.match(f.app.lastFrame()!, new RegExp(`Showing ${10_000 - WINDOW_SIZE + 1}–10000 of 10000`));
    assert.ok(f.app.lastFrame()!.includes(messages[10_000 - WINDOW_SIZE]!.text));
    assert.ok(!f.app.lastFrame()!.includes(messages[0]!.text));
    console.log(JSON.stringify({ renderer: "ink", mode: "window", messages: 10_000, visible: WINDOW_SIZE, mountMs: f.mountMs, hydrationMs: f.hydrationMs }));
    await f.key("\t");
    await f.key("p");
    assert.match(f.app.lastFrame()!, new RegExp(`Showing ${10_000 - 2 * WINDOW_SIZE + 1}–${10_000 - WINDOW_SIZE} of 10000`));
    await f.key("n");
    assert.match(f.app.lastFrame()!, new RegExp(`Showing ${10_000 - WINDOW_SIZE + 1}–10000 of 10000`));
    await f.key("l");
    assert.match(f.app.lastFrame()!, new RegExp(`Showing ${10_000 - WINDOW_SIZE + 1}–10000 of 10000`));
    assert.equal(f.store.getSnapshot().messages.length, 10_000);
  } finally { await f.close(); }

  // Full-history capacity belongs to scale.tsx; this checks the actual control.
  const smallIds = new Set<string>();
  const small = await fixture(100, false, (id) => smallIds.add(id));
  try {
    await small.key("\t");
    await small.key("f");
    await settle(() => smallIds.size === 100 && (small.app.lastFrame()?.includes("Showing 1–100 of 100") ?? false));
    assert.deepEqual([...smallIds].sort(), small.store.getSnapshot().messages.map((message) => message.id).sort());
    assert.ok(small.app.lastFrame()!.includes("History entry 1."));
    assert.ok(small.app.lastFrame()!.includes("History entry 100."));
    await small.key("l");
    assert.match(small.app.lastFrame()!, new RegExp(`Showing ${100 - WINDOW_SIZE + 1}–100 of 100`));
    assert.equal(small.store.getSnapshot().messages.length, 100);
  } finally { await small.close(); }
});

test("ink: lost acknowledgement stays uncertain until an explicit saved-request lookup", async () => {
  const f = await fixture(0, false);
  try {
    f.transport.failNextSubmit("admitted");
    await f.key("INK-UNCERTAIN-REQUEST");
    await settle(() => f.getComposerText() === "INK-UNCERTAIN-REQUEST" && (f.app.lastFrame()?.includes("INK-UNCERTAIN-REQUEST") ?? false), f.diagnostics);
    await f.key("\r");
    await settle(() => f.store.getSnapshot().saved?.status === "uncertain" && (f.app.lastFrame()?.includes("Saved request: uncertain") ?? false), f.diagnostics);
    const id = f.store.getSnapshot().saved!.id;
    assert.match(f.app.lastFrame()!, /Saved request: uncertain/);
    assert.equal(f.store.getSnapshot().messages.length, 0);
    // Sending while the original outcome is unknown must not consume a new
    // draft or create another command through the actual library composer.
    await settle(() => hasFocusedEmptyMessageInput(f.app.lastFrame()) && f.getComposerText() === "", f.diagnostics);
    await f.key("INK-BLOCKED-DRAFT");
    await settle(() => f.getComposerText() === "INK-BLOCKED-DRAFT" && (f.app.lastFrame()?.includes("INK-BLOCKED-DRAFT") ?? false), f.diagnostics);
    await f.key("\r");
    assert.equal(f.getComposerText(), "INK-BLOCKED-DRAFT", JSON.stringify(f.diagnostics()));
    assert.match(f.app.lastFrame()!, /INK-BLOCKED-DRAFT/);
    assert.equal(f.store.getSnapshot().saved!.id, id);
    assert.equal(f.store.getSnapshot().saved!.status, "uncertain");
    assert.equal(f.transport.calls.filter((call) => call.operation === "submit").length, 1);
    await f.key("\t");
    await f.key("c");
    await settle(() => f.store.getSnapshot().saved?.status === "completed");
    assert.equal(f.store.getSnapshot().saved!.id, id);
    await f.key("r");
    await settle(() => f.store.getSnapshot().messages.length === 2);
    assert.equal(f.store.getSnapshot().messages.filter((message) => message.text === "INK-UNCERTAIN-REQUEST").length, 1);
  } finally { await f.close(); }
});

test("ink: adjacent assistant rows retain their separate durable IDs", async () => {
  const renderedIds: string[] = [];
  const f = await fixture(0, false, (id) => renderedIds.push(id));
  try {
    f.transport.appendMessage("assistant", "ADJACENT-INK-ONE");
    f.transport.appendMessage("assistant", "ADJACENT-INK-TWO");
    await act(async () => { await f.store.sync(); });
    await settle(() => f.app.lastFrame()?.includes("ADJACENT-INK-TWO") ?? false);
    const expected = f.store.getSnapshot().messages.map((message) => message.id);
    assert.equal(expected.length, 2);
    await settle(() => new Set(renderedIds).size === 2);
    assert.deepEqual([...new Set(renderedIds)], expected);
    assert.match(f.app.lastFrame()!, /ADJACENT-INK-ONE/);
  } finally { await f.close(); }
});
