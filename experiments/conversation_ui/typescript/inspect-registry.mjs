import { readFile } from 'node:fs/promises';

const manifest = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));
const requested = { ...manifest.dependencies, ...manifest.devDependencies };
const evidence = [];
for (const [name, version] of Object.entries(requested)) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Unpinned package');
  const url = `https://registry.npmjs.org/${encodeURIComponent(name)}/${version}`;
  const response = await fetch(url, { signal: AbortSignal.timeout(30000), redirect: 'error' });
  if (!response.ok) throw new Error(`Registry version unavailable: ${name}@${version} (${response.status})`);
  const raw = await response.text();
  if (raw.length > 2 * 1024 * 1024) throw new Error('Registry metadata too large');
  const data = JSON.parse(raw);
  if (data.name !== name || data.version !== version ||
      !data.dist?.integrity || new URL(data.dist.tarball).origin !== 'https://registry.npmjs.org') {
    throw new Error('Unexpected package metadata');
  }
  evidence.push({ name, version, source: url, integrity: data.dist.integrity,
    tarball: data.dist.tarball, peerDependencies: data.peerDependencies ?? {}, engines: data.engines ?? {} });
}
process.stdout.write(JSON.stringify({ requested, evidence }, null, 2) + '\n');
