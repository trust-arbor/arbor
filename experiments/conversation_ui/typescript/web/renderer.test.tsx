import test, { after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import React, { act } from "react";
import { createConversationStore } from "../shared/store.mjs";
import { createFixtureTransport } from "../shared/fixture.mjs";

// The DOM harness is intentionally untyped; production library bindings remain
// subject to strict typechecking against the installed package declarations.
const { JSDOM } = createRequire(import.meta.url)("jsdom");
const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://comparison.test", pretendToBeVisual: true });
for (const key of ["window", "document", "navigator", "HTMLElement", "HTMLTextAreaElement", "HTMLInputElement", "Element", "Node", "Event", "MutationObserver"] as const) {
  Object.defineProperty(globalThis, key, { value: dom.window[key], configurable: true });
}
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { value: true, configurable: true });
Object.defineProperty(globalThis, "ResizeObserver", { value: class { observe() {} unobserve() {} disconnect() {} }, configurable: true });
const { createRoot } = await import("react-dom/client");
const { ComparisonWebApp, WINDOW_SIZE } = await import("./App.js");
after(() => dom.window.close());

async function fixture(entryCount = 0, includeQuestion = true) {
  const transport = createFixtureTransport({ entryCount, includeQuestion });
  const store = createConversationStore({ caller: "human_comparison", target: "agent_comparison", transport });
  const hydrationStarted = performance.now();
  assert.equal((await store.sync()).ok, true);
  const hydrationMs = performance.now() - hydrationStarted;
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const mountStarted = performance.now();
  await act(async () => { root.render(<ComparisonWebApp store={store} />); });
  const mountMs = performance.now() - mountStarted;
  return { transport, store, container, hydrationMs, mountMs, async close() {
    await act(async () => root.unmount());
    await store.destroy();
    container.remove();
  } };
}

function button(container: HTMLElement, label: string): HTMLButtonElement {
  const found = [...container.querySelectorAll("button")].find((item) => item.textContent === label);
  assert.ok(found, `Missing button: ${label}`);
  return found;
}
async function click(element: HTMLElement) { await act(async () => element.click()); }
async function settle(predicate: () => boolean) {
  for (let index = 0; index < 200 && !predicate(); index++) {
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
  }
  assert.ok(predicate(), "Expected renderer state did not appear.");
}
async function type(container: HTMLElement, value: string) {
  const input = container.querySelector("textarea");
  assert.ok(input);
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

test("web: choose and confirm uses the authoritative command and question state", async () => {
  const f = await fixture();
  try {
    const question = f.store.getSnapshot().question;
    assert.ok(question);
    const selected = question.options[1]!;
    const option = f.container.querySelector<HTMLButtonElement>(`button[data-option-id="${selected.id}"]`)!;
    await click(option);
    assert.equal(option.getAttribute("aria-pressed"), "true");
    await click(button(f.container, "Confirm selection"));
    await settle(() => f.container.querySelector('[data-testid="question-status"]')?.textContent === "Question: completed");
    assert.equal(button(f.container, "Confirm selection").disabled, true);
    await click(button(f.container, "Refresh / reconnect"));
    await settle(() => f.store.getSnapshot().messages.some((message) => message.role === "user"));
    assert.equal(f.store.getSnapshot().question?.selection, selected.id);
    assert.equal(f.container.querySelectorAll('[data-role="user"]').length, 1);
  } finally { await f.close(); }
});

test("web: auth loss unmounts private transcript, structured choice, and active draft", async () => {
  const f = await fixture();
  try {
    f.transport.appendMessage("assistant", "PRIVATE-WEB-TRANSCRIPT");
    await act(async () => { await f.store.sync(); });
    await type(f.container, "PRIVATE-WEB-DRAFT");
    assert.match(f.container.textContent!, /PRIVATE-WEB-TRANSCRIPT/);
    assert.equal(f.container.querySelector("textarea")?.value, "PRIVATE-WEB-DRAFT");
    await act(async () => { await f.store.loseAccess(); });
    assert.ok(f.container.querySelector('[data-testid="access-cleared"]'));
    assert.doesNotMatch(f.container.textContent!, /PRIVATE-WEB-TRANSCRIPT|PRIVATE-WEB-DRAFT|Three options/);
    assert.equal(f.container.querySelector("textarea"), null);
    assert.equal(f.container.querySelectorAll("[data-message-id]").length, 0);
    assert.equal(f.store.getSnapshot().messages.length, 0);
  } finally { await f.close(); }
});

test("web: 10000 messages stay windowed and full controls render 100 messages", { timeout: 60_000 }, async () => {
  const f = await fixture(10_000, false);
  try {
    assert.equal(f.store.getSnapshot().messages.length, 10_000);
    assert.equal(f.container.querySelectorAll("[data-message-id]").length, WINDOW_SIZE);
    console.log(JSON.stringify({ renderer: "web", mode: "window", messages: 10_000, visible: WINDOW_SIZE, mountMs: f.mountMs, hydrationMs: f.hydrationMs }));
    await click(button(f.container, "Older"));
    assert.equal(f.container.querySelector("[data-message-id]")?.getAttribute("data-message-id"), f.store.getSnapshot().messages[10_000 - 2 * WINDOW_SIZE]!.id);
    await click(button(f.container, "Newer"));
    assert.equal(f.container.querySelector("[data-message-id]")?.getAttribute("data-message-id"), f.store.getSnapshot().messages[10_000 - WINDOW_SIZE]!.id);
    await click(button(f.container, "Latest"));
    assert.equal(f.container.querySelectorAll("[data-message-id]").length, WINDOW_SIZE);
    assert.equal(f.store.getSnapshot().messages.length, 10_000);
  } finally { await f.close(); }

  // Full-history capacity belongs to scale.tsx; this checks the actual control.
  const small = await fixture(100, false);
  try {
    await click(small.container.querySelector<HTMLInputElement>('input[type="checkbox"]')!);
    assert.deepEqual([...small.container.querySelectorAll("[data-message-id]")].map((element) => element.getAttribute("data-message-id")), small.store.getSnapshot().messages.map((message) => message.id));
    assert.equal(small.container.querySelectorAll("[data-message-id]").length, 100);
    await click(button(small.container, "Latest"));
    assert.equal(small.container.querySelectorAll("[data-message-id]").length, WINDOW_SIZE);
    assert.equal(small.store.getSnapshot().messages.length, 100);
  } finally { await small.close(); }
});

test("web: lost acknowledgement stays uncertain until an explicit saved-request lookup", async () => {
  const f = await fixture(0, false);
  try {
    f.transport.failNextSubmit("admitted");
    await type(f.container, "WEB-UNCERTAIN-REQUEST");
    await click(button(f.container, "Send"));
    await settle(() => f.store.getSnapshot().saved?.status === "uncertain");
    const id = f.store.getSnapshot().saved!.id;
    assert.match(f.container.textContent!, /Saved request: uncertain/);
    assert.equal(f.container.querySelectorAll("[data-message-id]").length, 0);
    await type(f.container, "WEB-BLOCKED-DRAFT");
    assert.equal(f.container.querySelector("textarea")?.value, "WEB-BLOCKED-DRAFT");
    assert.equal(button(f.container, "Send").disabled, true);
    await click(button(f.container, "Send"));
    assert.equal(f.container.querySelector("textarea")?.value, "WEB-BLOCKED-DRAFT");
    assert.equal(f.store.getSnapshot().saved!.id, id);
    assert.equal(f.transport.calls.filter((call) => call.operation === "submit").length, 1);
    await click(button(f.container, "Check saved request"));
    await settle(() => f.store.getSnapshot().saved?.status === "completed");
    assert.equal(f.store.getSnapshot().saved!.id, id);
    await click(button(f.container, "Refresh / reconnect"));
    await settle(() => f.store.getSnapshot().messages.length === 2);
    assert.equal(f.store.getSnapshot().messages.filter((message) => message.text === "WEB-UNCERTAIN-REQUEST").length, 1);
  } finally { await f.close(); }
});

test("web: adjacent assistant rows retain their separate durable IDs", async () => {
  const f = await fixture(0, false);
  try {
    f.transport.appendMessage("assistant", "ADJACENT-WEB-ONE");
    f.transport.appendMessage("assistant", "ADJACENT-WEB-TWO");
    await act(async () => { await f.store.sync(); });
    const expected = f.store.getSnapshot().messages.map((message) => message.id);
    assert.equal(expected.length, 2);
    assert.deepEqual([...f.container.querySelectorAll("[data-message-id]")].map((element) => element.getAttribute("data-message-id")), expected);
  } finally { await f.close(); }
});
