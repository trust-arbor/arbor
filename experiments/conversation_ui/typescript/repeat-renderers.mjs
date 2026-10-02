import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

assert.equal(process.argv.length, 2, 'Renderer stability check accepts no arguments');
const REPEATS = 10, EXPECTED_TESTS = 11, LIMIT = 1024 * 1024, TIMEOUT_MS = 60_000;
const command = ['--import', 'tsx', '--test', '--test-reporter=tap', '--test-concurrency=1',
  'web/renderer.test.tsx', 'ink/renderer.test.tsx', 'web/renderer-journey.test.tsx'];
const cwd = fileURLToPath(new URL('./', import.meta.url));

function trial(index) {
  return new Promise((resolve) => {
    const started = performance.now();
    const child = spawn(process.execPath, command, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = []; let size = 0, reason = null, killTimer;
    function stop(value) {
      if (reason) return;
      reason = value; child.kill('SIGTERM');
      killTimer = setTimeout(() => child.kill('SIGKILL'), 500);
    }
    function collect(chunk) {
      size += chunk.length;
      if (size <= LIMIT) chunks.push(chunk);
      else stop('output_limit');
    }
    const timer = setTimeout(() => stop('command_timeout'), TIMEOUT_MS);
    child.stdout.on('data', collect); child.stderr.on('data', collect);
    child.on('error', () => { reason = 'process_start_failed'; });
    child.on('close', (code, signal) => {
      clearTimeout(timer); if (killTimer) clearTimeout(killTimer);
      const log = Buffer.concat(chunks).toString('utf8');
      const summary = {};
      for (const key of ['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo']) {
        const matches = [...log.matchAll(new RegExp('^# ' + key + ' (\\d+)\\s*$', 'gm'))];
        if (matches.length) summary[key] = Number(matches.at(-1)[1]);
      }
      const selected = summary.tests === EXPECTED_TESTS && summary.pass === EXPECTED_TESTS &&
        ['fail', 'cancelled', 'skipped', 'todo'].every((key) => summary[key] === 0);
      resolve({ index, status: reason ?? (code !== 0 ? 'command_failed' : selected ? 'passed' : 'unexpected_test_selection'),
        exit_code: code, signal, elapsed_ms: performance.now() - started, summary, log });
    });
  });
}

const runs = [];
for (let index = 1; index <= REPEATS; index++) {
  const run = await trial(index); runs.push(run);
  console.log(`renderer stability ${index}/${REPEATS}: ${run.status}`);
  // Any failure remains a failure; later successes cannot replace it.
  if (run.status !== 'passed') break;
}
const passed = runs.length === REPEATS && runs.every((run) => run.status === 'passed');
console.log(JSON.stringify({ schema: 'conversation-renderer-stability/v1', status: passed ? 'passed' : 'failed',
  repeats: REPEATS, expected_tests_per_run: EXPECTED_TESTS, runs }));
if (!passed) process.exitCode = 1;
