import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const root = new URL('./', import.meta.url);
const read = async (path) => readFile(new URL(path, root));
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const prior = JSON.parse(await read('dependency-evidence/result.json'));
const required = ['node_runtime', 'shared_boundary', 'published_resolution_tests',
  'published_resolution', 'npm_lock', 'npm_install', 'published_exports'];
for (const id of required) assert.equal(prior.steps.find((step) => step.id === id)?.status, 'passed');
assert.deepEqual(prior.changed_frozen_inputs, []);
assert.deepEqual(prior.new_or_removed_input_paths, []);
assert.deepEqual(prior.changed_prepared_dependency_inputs, []);
for (const name of ['package.json', 'published-resolution.json', 'package-lock.json']) {
  const current = await read(name), accepted = await read('dependency-evidence/' + name);
  assert.equal(hash(current), prior.frozen_dependency_inputs[name]);
  assert.equal(hash(accepted), prior.frozen_dependency_inputs[name]);
}
const resolution = JSON.parse(await read('published-resolution.json'));
assert.equal(resolution.template_sha256, hash(await read('package.template.json')));
assert.deepEqual(resolution, prior.published_resolution);
assert.equal(hash(await read('dependency-evidence/published_exports.log')),
  prior.steps.find((step) => step.id === 'published_exports').log_sha256);
console.log(JSON.stringify({ status: 'passed', packages: resolution.packages.length,
  source: 'preserved operator registry/lock/install/export evidence',
  dependency_inputs_sha256: prior.frozen_dependency_inputs }));
