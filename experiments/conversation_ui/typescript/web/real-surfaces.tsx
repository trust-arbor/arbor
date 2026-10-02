import assert from "node:assert/strict";
import { createRequire } from "node:module";
import React, { act } from "react";
import type { ConversationStore } from "../shared/store.mjs";
import { answerText } from "../shared/question.mjs";
import { hasFocusedEmptyMessageInput } from "../ink/testing.js";

const FOLLOWUP = "Ink follow-up: café 東京 🌿";
const WEB_DRAFT = "PRIVATE-WEB-REAL-SURFACE-DRAFT";
const INK_DRAFT = "PRIVATE-INK-REAL-SURFACE-DRAFT";
const delay = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function settle(predicate: () => boolean, timeout = 3_000) {
  const deadline = performance.now() + timeout;
  await surfaceAct(async () => {});
  while (!predicate() && performance.now() < deadline) await surfaceAct(async () => { await delay(10); });
  assert.ok(predicate(), "Expected surface state did not appear");
}

/** Complete public React commits and passive input effects before test events. */
async function surfaceAct(action: () => void | Promise<void>) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { value: true, configurable: true });
  try { await act(action); }
  finally {
    if (descriptor) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", descriptor);
    else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  }
}

/** Actual DOM and Ink test renderers over one authorized store; no credentials enter this module. */
export async function exerciseRealSurfaces(store: ConversationStore) {
  const initial = store.getSnapshot();
  assert.equal(initial.connection, "connected");
  assert.equal(initial.question?.status, "open");
  const question = initial.question!;
  assert.equal(question.options.length, 3);
  const choice = question.options[0]!;
  const answer = answerText(question, choice.id);
  const globals = new Map<string, PropertyDescriptor | undefined>();
  let disposeWeb = () => {}, disposeInk = () => {}, closeDom = () => {};
  let disposed = false;

  function installGlobal(name: string, value: unknown) {
    globals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { value, configurable: true });
  }
  async function dispose() {
    if (disposed) return;
    disposed = true;
    // Both renderers share React's scheduling queue. Flush their unmount work
    // before removing the DOM globals that deferred React work still reads.
    if (!globals.has("IS_REACT_ACT_ENVIRONMENT")) globals.set("IS_REACT_ACT_ENVIRONMENT", Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT"));
    Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { value: true, configurable: true });
    try { await act(async () => { try { disposeWeb(); } finally { disposeInk(); } }); }
    finally {
      closeDom();
      for (const [name, descriptor] of globals) {
        if (descriptor) Object.defineProperty(globalThis, name, descriptor);
        else Reflect.deleteProperty(globalThis, name);
      }
    }
  }

  try {
    // The DOM test helper is intentionally untyped; production bindings remain strict.
    const { JSDOM } = createRequire(import.meta.url)("jsdom");
    const dom = new JSDOM("<!doctype html><html><body><div id='app'></div></body></html>", { url: "http://comparison.test", pretendToBeVisual: true });
    closeDom = () => dom.window.close();
    for (const name of ["window", "document", "navigator", "HTMLElement", "HTMLTextAreaElement", "HTMLInputElement", "Element", "Node", "Event", "MutationObserver"] as const) installGlobal(name, dom.window[name]);
    installGlobal("ResizeObserver", class { observe() {} unobserve() {} disconnect() {} });
    // The caller's later reconnect checks also update both renderers. Enable
    // act only around harness-controlled actions and restore this between them.
    installGlobal("IS_REACT_ACT_ENVIRONMENT", false);
    const { createRoot } = await import("react-dom/client");
    const { ComparisonWebApp } = await import("./App.js");
    const { render } = await import("ink-testing-library");
    const { ComparisonInkApp } = await import("../ink/App.js");
    const container = document.getElementById("app")!;
    const root = createRoot(container);
    disposeWeb = () => root.unmount();
    const mountedInkIds = new Set<string>();
    let composerText: string | null = null;
    let ink!: ReturnType<typeof render>;
    await surfaceAct(async () => {
      root.render(<ComparisonWebApp store={store} />);
      ink = render(<ComparisonInkApp store={store} onMessageRendered={(id) => mountedInkIds.add(id)} onComposerText={(text) => { composerText = text; }} />);
      disposeInk = () => { ink.unmount(); ink.cleanup(); };
    });
    await settle(() => container.querySelector("textarea") !== null && hasFocusedEmptyMessageInput(ink.lastFrame()));

    function button(label: string) {
      const element = [...container.querySelectorAll("button")].find((candidate) => candidate.textContent === label);
      assert.ok(element, "Required surface control is missing");
      return element;
    }
    async function typeWeb(text: string) {
      const input = container.querySelector("textarea");
      assert.ok(input, "Web composer unavailable");
      await surfaceAct(async () => {
        Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!.call(input, text);
        input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
      });
      await settle(() => input.value === text);
    }
    async function completed(commandId: string) {
      const deadline = performance.now() + 12_000;
      while (store.getSnapshot().saved?.status !== "completed") {
        assert.ok(performance.now() < deadline, "Host delivery did not complete");
        assert.equal(store.getSnapshot().saved?.id, commandId);
        if (!store.getSnapshot().busy) await surfaceAct(async () => { assert.equal((await store.checkSaved()).ok, true); });
        await delay(30);
      }
      assert.equal(store.getSnapshot().saved?.id, commandId);
      await settle(() => !store.getSnapshot().busy);
      await surfaceAct(async () => { assert.equal((await store.sync()).ok, true); });
    }

    const option = [...container.querySelectorAll<HTMLButtonElement>("button[data-option-id]")].find((element) => element.dataset.optionId === choice.id);
    assert.ok(option);
    await surfaceAct(async () => option.click());
    await settle(() => option.getAttribute("aria-pressed") === "true");
    const confirm = button("Confirm selection");
    assert.equal(confirm.disabled, false);
    await surfaceAct(async () => confirm.click());
    await settle(() => store.getSnapshot().saved !== null && !store.getSnapshot().busy, 8_000);
    const questionCommandId = store.getSnapshot().saved!.id;
    await completed(questionCommandId);
    assert.equal(store.getSnapshot().messages.filter((message) => message.role === "user" && message.text === answer).length, 1);
    await settle(() => container.querySelector('[data-testid="question-status"]')?.textContent === "Question: completed" && (ink.lastFrame()?.includes("Question: completed") ?? false));

    await settle(() => hasFocusedEmptyMessageInput(ink.lastFrame()));
    await surfaceAct(async () => { ink.stdin.write(FOLLOWUP); });
    await settle(() => composerText === FOLLOWUP && (ink.lastFrame()?.includes(FOLLOWUP) ?? false));
    await surfaceAct(async () => { ink.stdin.write("\r"); });
    await settle(() => store.getSnapshot().saved !== null && store.getSnapshot().saved!.id !== questionCommandId && !store.getSnapshot().busy, 8_000);
    await completed(store.getSnapshot().saved!.id);
    const messages = store.getSnapshot().messages;
    const userRows = messages.filter((message) => message.role === "user" && message.text === FOLLOWUP);
    assert.equal(userRows.length, 1);
    const sent = userRows[0]!;
    const response = messages.find((message) => message.role === "assistant" && message.ordinal > sent.ordinal);
    assert.ok(response && response.text.length > 0, "Host follow-up response is missing");
    await settle(() => {
      const rows = [...container.querySelectorAll<HTMLElement>("[data-message-id]")];
      return rows.some((row) => row.dataset.messageId === sent.id && row.textContent?.includes(FOLLOWUP)) &&
        rows.some((row) => row.dataset.messageId === response.id && row.textContent?.includes(response.text)) &&
        mountedInkIds.has(sent.id) && mountedInkIds.has(response.id);
    });
    assert.ok(ink.lastFrame()?.includes(FOLLOWUP));
    await settle(() => ink.lastFrame()?.includes(response.text) ?? false);

    return {
      claims: ["actual_web_question_controls", "actual_ink_unicode_composer",
        "ink_observes_host_question_completion", "web_observes_host_ink_followup"],
      async clearAccessAndClose() {
        try {
          assert.equal(store.getSnapshot().connection, "connected");
          await settle(() => container.querySelector("textarea") !== null && hasFocusedEmptyMessageInput(ink.lastFrame()));
          await typeWeb(WEB_DRAFT);
          await surfaceAct(async () => { ink.stdin.write(INK_DRAFT); });
          await settle(() => composerText === INK_DRAFT && (ink.lastFrame()?.includes(INK_DRAFT) ?? false));
          await surfaceAct(async () => { await store.loseAccess(); });
          await settle(() => container.querySelector('[data-testid="access-cleared"]') !== null && (ink.lastFrame()?.includes("Access unavailable.") ?? false));
          assert.equal(composerText, null);
          assert.equal(container.querySelectorAll("[data-message-id]").length, 0);
          assert.equal(container.querySelector("textarea"), null);
          assert.equal(container.querySelector('[data-testid="question-status"]'), null);
          for (const text of [FOLLOWUP, WEB_DRAFT, INK_DRAFT, question.prompt]) {
            assert.ok(!container.textContent?.includes(text));
            assert.ok(!ink.lastFrame()?.includes(text));
          }
          assert.equal(store.getSnapshot().messages.length, 0);
          assert.equal(store.getSnapshot().deliveries.length, 0);
          assert.equal(store.getSnapshot().question, null);
          return { claims: ["both_active_surfaces_clear_on_local_access_loss"] };
        } finally { await dispose(); }
      },
      dispose,
    };
  } catch (error) {
    await dispose();
    throw error;
  }
}
