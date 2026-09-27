import assert from "node:assert/strict";
import {test} from "node:test";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../../../arbor_web/priv/static/arbor_web.js", import.meta.url), "utf8");
const hookSource = source.slice(source.indexOf("ArborWebHooks.ConversationDraft ="), source.indexOf("/**\n * EventTimeline"));

function browser(storage = new Map(), scope = "human_a:agent_a:eng_a") {
  const hooks = {};
  let sequence = 0;
  vm.runInNewContext(hookSource, {
    ArborWebHooks: hooks,
    crypto: {randomUUID: () => `request-${++sequence}`},
    sessionStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key)
    }
  });
  const input = {value: ""};
  const id = {value: ""};
  const listeners = {};
  const events = {};
  const sent = [];
  const hook = Object.assign({}, hooks.ConversationDraft, {
    el: {
      dataset: {conversationAuthorized: "true", conversationKey: scope},
      querySelector: selector => selector.includes("command_id") ? id : input,
      addEventListener: (name, callback) => { listeners[name] = callback; },
      removeEventListener: name => { delete listeners[name]; }
    },
    handleEvent: (name, callback) => { events[name] = callback; },
    pushEvent: (name, data) => { sent.push({name, data}); }
  });
  hook.mounted();
  return {hook, input, id, listeners, events, sent, storage};
}

test("admission identity survives lost acknowledgement and reconnect never resubmits", () => {
  const first = browser();
  first.input.value = "original text";
  first.listeners.input();
  first.listeners.submit();
  assert.equal(first.id.value, "request-1");
  const reopened = browser(first.storage);
  assert.equal(reopened.input.value, "original text");
  assert.deepEqual(JSON.parse(JSON.stringify(reopened.sent)), [
    {name: "update-input", data: {message: "original text"}},
    {name: "conversation:restore", data: {id: "request-1", text: "original text"}}
  ]);
  assert.ok(reopened.sent.every(event => event.name !== "send-message"));
});

test("late completion clears only its own pending request and preserves a newer draft", () => {
  const b = browser();
  b.input.value = "original";
  b.listeners.submit();
  b.input.value = "newer draft";
  b.listeners.input();
  b.events["conversation-completed"]({id: "other-request", text: "newer draft"});
  assert.equal(b.hook.state.pending.id, "request-1");
  b.events["conversation-completed"]({id: "request-1", text: "original"});
  assert.equal(b.input.value, "newer draft");
  assert.equal(b.hook.state.draft, "newer draft");
  assert.equal(b.hook.state.pending, null);
});

test("foreign subject cannot restore another tab scope and access denial erases private local state", () => {
  const owner = browser();
  owner.input.value = "private";
  owner.listeners.submit();
  const foreign = browser(owner.storage, "human_b:agent_a:eng_a");
  assert.equal(foreign.input.value, "");
  assert.ok(foreign.sent.every(event => event.name !== "conversation:restore"));
  owner.events["conversation-access-denied"]({});
  assert.equal(owner.input.value, "");
  assert.equal(owner.hook.state.pending, null);
  assert.equal(owner.storage.has("arbor-conversation:human_a:agent_a:eng_a"), false);
});

test("a changed canonical engagement does not restore the prior engagement outbox", () => {
  const old = browser();
  old.input.value = "old owner draft";
  old.listeners.submit();
  const rebound = browser(old.storage, "human_a:agent_a:eng_b");
  assert.equal(rebound.input.value, "");
  assert.equal(rebound.hook.state.pending, null);
  assert.ok(rebound.sent.every(event => event.name !== "conversation:restore"));
});
