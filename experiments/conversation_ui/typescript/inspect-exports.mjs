import { readFile } from 'node:fs/promises';

const lock = JSON.parse(await readFile(new URL('./package-lock.json', import.meta.url), 'utf8'));
const manifest = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));
const coreVersions = Object.entries(lock.packages)
  .filter(([name]) => /(?:^|\/)node_modules\/@assistant-ui\/core$/.test(name))
  .map(([path, data]) => ({ path, version: data.version }));
if (coreVersions.length !== 1 || coreVersions[0].version !== manifest.dependencies['@assistant-ui/core']) {
  throw new Error('Web and Ink must resolve one identical assistant-ui core');
}
const checks = [
  ['@assistant-ui/core/react', ['useExternalStoreRuntime', 'useExternalMessageConverter']],
  ['@assistant-ui/react', ['AssistantRuntimeProvider', 'ThreadPrimitive', 'MessagePrimitive', 'ComposerPrimitive', 'useExternalMessageConverter', 'useExternalStoreRuntime', 'useAuiState']],
  ['@assistant-ui/react-ink', ['AssistantRuntimeProvider', 'ThreadPrimitive', 'MessagePrimitive', 'ComposerPrimitive', 'useAuiState']],
  ['react-dom/client', ['createRoot']],
  ['ink', ['render', 'Box', 'Text', 'useInput']],
  ['ws', ['WebSocket']]
];
const exports = await Promise.all(checks.map(async ([name, required]) => {
  try {
    const module = await import(name);
    return { name, required, status: 'imported', missing: required.filter(key => !(key in module)) };
  } catch (error) {
    // Report every public surface even when the first requested subpath is absent.
    // Keep arbitrary exception text out of the retained evidence.
    const known = ['ERR_PACKAGE_PATH_NOT_EXPORTED', 'ERR_MODULE_NOT_FOUND', 'MODULE_NOT_FOUND'];
    return { name, required, status: 'import_failed', error_code: known.includes(error.code) ? error.code : 'PUBLIC_IMPORT_FAILED' };
  }
}));
process.stdout.write(JSON.stringify({ coreVersions, exports }, null, 2) + '\n');
if (exports.some(check => check.status !== 'imported' || check.missing.length)) process.exitCode = 1;
