import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import React, { act } from "react";
import { createConversationStore } from "../shared/store.mjs";
import { createFixtureTransport } from "../shared/fixture.mjs";

type Renderer = "web" | "ink";
type Mode = "window" | "full";
type Lane = {
  renderer: Renderer; mode: Mode; requested_messages: number; retained_messages: number | null;
  rendered_message_blocks: number | null; expected_rendered_message_blocks: number;
  measurement: "jsdom_dom_mount" | "ink_active_screen_frame";
  status: string; duration_ms: number | null; output_bytes: number | null;
  hydration_ms?: number; error_class?: string; diagnostic_output_bytes?: number;
  active_output_record_count?: number; output_line_count?: number;
  terminal_geometry?: { columns: number; rows: null; source: string };
  renderer_stderr_bytes?: number;
};
const PREFIX = "@@conversation-ui-scale@@";
const COUNTS = [100, 1_000, 10_000];
const TIMEOUT_MS = 60_000;
const OUTPUT_LIMIT = 1024 * 1024;

function base(renderer: Renderer, count: number, mode: Mode): Lane {
  return { renderer, mode, requested_messages: count, retained_messages: null, rendered_message_blocks: null,
    expected_rendered_message_blocks: mode === "full" ? count : 20,
    measurement: renderer === "web" ? "jsdom_dom_mount" : "ink_active_screen_frame",
    status: "render_failed", duration_ms: null, output_bytes: null };
}

async function measure(renderer: Renderer, count: number, mode: Mode): Promise<Lane> {
  const result = base(renderer, count, mode);
  const transport = createFixtureTransport({ includeQuestion: false });
  for (let n = 1; n <= count; n++) transport.appendMessage(n % 2 ? "user" : "assistant", `Record ${n}: café 東京 🌿`);
  const store = createConversationStore({ caller: "human_comparison", target: "agent_comparison", transport });
  let cleanup = async () => {};
  let started: number | undefined;
  try {
    const hydrationStarted = performance.now();
    assert.equal((await store.sync()).ok, true);
    result.hydration_ms = performance.now() - hydrationStarted;
    result.retained_messages = store.getSnapshot().messages.length;
    assert.equal(result.retained_messages, count);
    const expected = (mode === "full" ? store.getSnapshot().messages : store.getSnapshot().messages.slice(-20)).map((message) => message.id);
    if (renderer === "web") {
      // Test-only DOM harness; App imports remain strictly typed against packages.
      const { JSDOM } = createRequire(import.meta.url)("jsdom");
      const dom = new JSDOM("<!doctype html><html><body><div id='app'></div></body></html>", { url: "http://comparison.test", pretendToBeVisual: true });
      for (const key of ["window", "document", "navigator", "HTMLElement", "HTMLTextAreaElement", "HTMLInputElement", "Element", "Node", "Event", "MutationObserver"] as const) {
        Object.defineProperty(globalThis, key, { value: dom.window[key], configurable: true });
      }
      Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { value: true, configurable: true });
      Object.defineProperty(globalThis, "ResizeObserver", { value: class { observe() {} unobserve() {} disconnect() {} }, configurable: true });
      const { createRoot } = await import("react-dom/client");
      const { ComparisonWebApp } = await import("./App.js");
      const container = document.getElementById("app")!;
      const root = createRoot(container);
      cleanup = async () => { await act(async () => root.unmount()); dom.window.close(); };
      started = performance.now();
      await act(async () => root.render(<ComparisonWebApp store={store} initialFullHistory={mode === "full"} />));
      result.duration_ms = performance.now() - started;
      const actual = [...container.querySelectorAll("[data-message-id]")].map((element) => element.getAttribute("data-message-id"));
      result.rendered_message_blocks = actual.length;
      result.output_bytes = Buffer.byteLength(container.innerHTML, "utf8");
      result.active_output_record_count = [...(container.textContent ?? "").matchAll(/Record (\d+): café 東京 🌿/g)].length;
      assert.deepEqual(actual, expected);
      assert.ok(container.textContent?.includes(`Record ${count}: café 東京 🌿`));
    } else {
      const { render } = await import("ink-testing-library");
      const { ComparisonInkApp } = await import("../ink/App.js");
      const actual = new Set<string>();
      started = performance.now();
      const app = render(<ComparisonInkApp store={store} initialFullHistory={mode === "full"} onMessageRendered={(id) => actual.add(id)} />);
      cleanup = async () => { app.unmount(); app.cleanup(); };
      while (actual.size !== expected.length || !app.lastFrame()?.includes(`Record ${count}: café 東京 🌿`)) {
        if (performance.now() - started > TIMEOUT_MS - 5_000) throw new Error("Render did not settle");
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      result.duration_ms = performance.now() - started;
      result.rendered_message_blocks = actual.size;
      result.output_bytes = Buffer.byteLength(app.lastFrame()!, "utf8");
      result.active_output_record_count = [...app.lastFrame()!.matchAll(/Record (\d+): café 東京 🌿/g)].length;
      result.output_line_count = app.lastFrame()!.split("\n").length;
      result.terminal_geometry = { columns: app.stdout.columns, rows: null, source: "ink-testing-library stdout; no rows supplied" };
      result.renderer_stderr_bytes = Buffer.byteLength(app.stderr.frames.join(""), "utf8");
      assert.deepEqual([...actual], expected);
    }
    result.status = "passed";
  } catch (error) {
    if (started !== undefined && result.duration_ms === null) result.duration_ms = performance.now() - started;
    result.error_class = error instanceof Error ? error.name : "UnknownError";
  } finally {
    try { await cleanup(); await store.destroy(); }
    catch { result.status = "cleanup_failed"; }
  }
  return result;
}

async function isolatedLane(renderer: Renderer, count: number, mode: Mode): Promise<Lane> {
  return new Promise((resolve) => {
    // Keep children in the outer runner's process group so its cleanup covers all lanes.
    const child = spawn(process.execPath, ["--import", "tsx", fileURLToPath(import.meta.url), "--lane", renderer, String(count), mode], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderrBytes = 0, totalBytes = 0, forced: string | null = null;
    let killTimer: ReturnType<typeof setTimeout> | undefined;
    const stop = (reason: string) => {
      if (forced) return;
      forced = reason; child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 500);
    };
    const timer = setTimeout(() => stop("render_timeout"), TIMEOUT_MS);
    child.stdout.on("data", (data: Buffer) => {
      totalBytes += data.length;
      if (totalBytes > OUTPUT_LIMIT) stop("output_limit");
      else stdout += data.toString("utf8");
    });
    child.stderr.on("data", (data: Buffer) => {
      totalBytes += data.length; stderrBytes += data.length;
      if (totalBytes > OUTPUT_LIMIT) stop("output_limit");
    });
    child.on("error", () => { forced = "process_start_failed"; });
    child.on("close", (code) => {
      clearTimeout(timer); if (killTimer) clearTimeout(killTimer);
      const failure = { ...base(renderer, count, mode), status: forced ?? "process_failed", diagnostic_output_bytes: totalBytes };
      if (forced || code !== 0) { resolve(failure); return; }
      const lines = stdout.split("\n").filter((line) => line.startsWith(PREFIX));
      try {
        assert.equal(lines.length, 1);
        const result = JSON.parse(lines[0]!.slice(PREFIX.length)) as Lane;
        assert.equal(result.renderer, renderer); assert.equal(result.mode, mode);
        assert.equal(result.requested_messages, count);
        if (result.status === "passed") {
          assert.equal(result.retained_messages, count);
          assert.equal(result.rendered_message_blocks, result.expected_rendered_message_blocks);
          assert.equal(result.expected_rendered_message_blocks, mode === "full" ? count : 20);
          assert.ok(typeof result.duration_ms === "number" && Number.isFinite(result.duration_ms));
          assert.ok(typeof result.output_bytes === "number" && result.output_bytes > 0);
        }
        result.diagnostic_output_bytes = stderrBytes + Buffer.byteLength(stdout.replace(lines[0]! + "\n", ""), "utf8");
        resolve(result);
      } catch { resolve({ ...failure, status: "invalid_measurement" }); }
    });
  });
}

if (process.argv[2] === "--lane") {
  const renderer = process.argv[3], count = Number(process.argv[4]), mode = process.argv[5];
  assert.ok(process.argv.length === 6 && (renderer === "web" || renderer === "ink") && COUNTS.includes(count) && (mode === "window" || mode === "full"));
  process.stdout.write(PREFIX + JSON.stringify(await measure(renderer, count, mode)) + "\n");
} else {
  assert.equal(process.argv.length, 2, "Scale entrypoint accepts no arguments");
  const results: Lane[] = [];
  for (const renderer of ["web", "ink"] as const) for (const count of COUNTS) for (const mode of ["window", "full"] as const) {
    results.push(await isolatedLane(renderer, count, mode));
  }
  const windowPassed = results.filter((lane) => lane.mode === "window").every((lane) => lane.status === "passed");
  process.stdout.write(JSON.stringify({ schema: "conversation-ui-scale/v1", samples_per_lane: 1,
    default_window_messages: 20, delivery_blocks: 0, fixture_text: "Record n: café 東京 🌿",
    all_window_lanes_passed: windowPassed, full_failures: results.filter((lane) => lane.mode === "full" && lane.status !== "passed").length,
    limits: ["JSDOM DOM mount is not browser layout or LiveView HTML-string rendering", "Ink test active-screen frame is not a physical terminal or Breeze redraw", "Ink test stdout geometry is recorded per lane; it is not matched to Breeze 110 columns by 55 rows", "No Static history; existing terminal scrollback is not erased"], results }, null, 2) + "\n");
  if (!windowPassed) process.exitCode = 1;
}
