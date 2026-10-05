import assert from "node:assert/strict";
import {test} from "node:test";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../../../arbor_web/priv/static/arbor_web.js", import.meta.url), "utf8");
const hookSource = source.slice(source.indexOf("ArborWebHooks.ConversationHome ="), source.indexOf("/**\n * Per-tab private"));

function home(storage) {
  const hooks = {}, events = {};
  vm.runInNewContext(hookSource, {
    ArborWebHooks: hooks,
    sessionStorage: {
      get length() { return storage.size; },
      key: index => [...storage.keys()][index],
      removeItem: key => storage.delete(key)
    }
  });
  const hook = Object.assign({}, hooks.ConversationHome, {
    handleEvent: (name, callback) => { events[name] = callback; }
  });
  hook.mounted();
  return events;
}

test("security regression denial during a composer-free switch erases only the exact subject's private state", () => {
  const storage = new Map([
    ["arbor-conversation:human_a:agent_a:eng_a", "private draft"],
    ["arbor-conversation:human_a:agent_b:eng_b", "saved request"],
    ["arbor-conversation:human_ab:agent_a:eng_a", "other subject"],
    ["arbor-conversation:human_b:agent_a:eng_a", "other subject"],
    ["unrelated-preference", "kept"]
  ]);
  const events = home(storage);
  // Mounting and ordinary target switches do not erase scope-local state.
  assert.equal(storage.size, 5);
  events["conversation-home-clear"]({subject: "human_a"});
  assert.deepEqual([...storage.keys()], [
    "arbor-conversation:human_ab:agent_a:eng_a",
    "arbor-conversation:human_b:agent_a:eng_a", "unrelated-preference"
  ]);
});

test("malformed or missing subject cannot expand a storage clearing prefix", () => {
  const storage = new Map([["arbor-conversation:human_a:agent_a:eng_a", "draft"]]);
  const events = home(storage);
  for (const subject of [undefined, null, "", "human_", "human_a:", "human_a:agent_a", "human_" + "x".repeat(256)]) {
    events["conversation-home-clear"]({subject});
    assert.equal(storage.size, 1);
  }
});
