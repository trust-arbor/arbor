import assert from "node:assert/strict";
import {test} from "node:test";
import {readFileSync} from "node:fs";
import vm from "node:vm";
const source = readFileSync(new URL("../../../arbor_web/priv/static/arbor_web.js", import.meta.url), "utf8");
const hookSource = source.slice(source.indexOf("ArborWebHooks.ConversationScroll ="), source.indexOf("ArborWebHooks.ClearOnSubmit ="));

function viewport(mode = "latest") {
  const hooks = {};
  vm.runInNewContext(hookSource, {ArborWebHooks: hooks});
  const listeners = new Map();
  const rows = [];
  const el = {
    dataset: {mode, window: "1:20"}, scrollTop: 0, scrollHeight: 1000, clientHeight: 300,
    getBoundingClientRect: () => ({top: 0}),
    querySelectorAll: () => rows,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name)
  };
  const hook = {...hooks.ConversationScroll, el};
  hook.mounted();
  return {hook, el, rows, listeners};
}

test("latest follows new content only while the reader stays at the bottom", () => {
  const v = viewport();
  assert.equal(v.el.scrollTop, 1000);
  v.hook.beforeUpdate(); v.el.scrollHeight = 1300; v.hook.updated();
  assert.equal(v.el.scrollTop, 1300);
  v.el.scrollTop = 250; v.listeners.get("scroll")();
  v.hook.beforeUpdate(); v.el.scrollHeight = 1700; v.hook.updated();
  assert.equal(v.el.scrollTop, 250);
});

test("an anchored visible message stays in place when surrounding content changes", () => {
  const v = viewport();
  let position = 20;
  v.rows.push({id: "row-15", getBoundingClientRect: () => ({top: position, bottom: position + 40})});
  v.el.scrollTop = 250; v.listeners.get("scroll")(); v.hook.beforeUpdate();
  position = 60; v.el.dataset.window = "2:21"; v.hook.updated();
  assert.equal(v.el.scrollTop, 290);
});

test("history navigation opens the older window without scrolling back to latest", () => {
  const v = viewport();
  v.hook.beforeUpdate(); v.el.dataset.mode = "browsing"; v.el.dataset.window = "1:10"; v.hook.updated();
  assert.equal(v.el.scrollTop, 0);
  v.el.scrollTop = 100; v.listeners.get("scroll")();
  v.hook.beforeUpdate(); v.hook.updated(); assert.equal(v.el.scrollTop, 100);
  v.hook.beforeUpdate(); v.el.dataset.mode = "latest"; v.hook.updated();
  assert.equal(v.el.scrollTop, v.el.scrollHeight);
});

test("destroy releases the native scroll listener", () => {
  const v = viewport(); v.hook.destroyed(); assert.equal(v.listeners.size, 0);
});
