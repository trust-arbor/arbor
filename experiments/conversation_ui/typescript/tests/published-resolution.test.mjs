import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PACKAGE_NAMES,REGISTRY,resolvePublished} from '../shared/published-resolution.mjs';
const template=JSON.parse(await readFile(new URL('../package.template.json',import.meta.url),'utf8'));
const templateSha256='a'.repeat(64),sri='sha512-'+Buffer.alloc(64,1).toString('base64');
function metadata(name,version='1.2.3') {return {name,version,dist:{integrity:sri,tarball:`${REGISTRY}/${encodeURIComponent(name)}/-/package-${version}.tgz`},
  peerDependencies:{react:'^19.0.0'},engines:{node:'>=22'},scripts:{preinstall:'MUST NOT COPY'}};}
const resolve=options=>resolvePublished({template:structuredClone(template),templateSha256,
  fetchMetadata:async request=>({status:200,data:metadata(request.name,request.version??'1.2.3')}),...options});
test('all fifteen published stable versions become exact pins while authored scripts remain unchanged',async()=>{
  const result=await resolve();assert.equal(result.ok,true);assert.equal(result.resolution.packages.length,15);
  for(const name of PACKAGE_NAMES)assert.equal(result.manifest.dependencies[name]??result.manifest.devDependencies[name],'1.2.3');
  assert.deepEqual(result.manifest.scripts,template.scripts);assert.equal(Object.hasOwn(result.manifest,'preinstall'),false);
  assert.equal(JSON.stringify(result.manifest).includes('MUST NOT COPY'),false);
  assert.ok(result.resolution.packages.every(entry=>entry.source.startsWith(REGISTRY+'/')&&!entry.source.endsWith('/latest')));
});
test('unpublished404 does not use source-derived pins and all remaining packages are still inspected',async()=>{
  const seen=[];const result=await resolve({fetchMetadata:async request=>{seen.push(request.name);return request.name==='@assistant-ui/core'?{status:404}:{status:200,data:metadata(request.name)};}});
  assert.equal(result.ok,false);assert.equal(result.manifest,undefined);assert.equal(result.resolution,undefined);
  assert.deepEqual(seen,PACKAGE_NAMES);assert.equal(result.diagnostics.packages.length,15);
  assert.equal(result.diagnostics.packages.filter(entry=>entry.status==='verified').length,14);
  assert.equal(result.diagnostics.packages[0].reason,'unavailable');
});
test('prerelease latest version is rejected rather than promoted to stable',async()=>{
  const result=await resolve({fetchMetadata:async request=>({status:200,data:metadata(request.name,'1.2.3-beta.1')})});
  assert.equal(result.ok,false);assert.ok(result.diagnostics.packages.every(entry=>entry.reason==='invalid_name_or_stable_version'));
});
test('deprecated published release is rejected without exposing arbitrary metadata text',async()=>{
  const result=await resolve({fetchMetadata:async request=>({status:200,data:{...metadata(request.name),deprecated:'unsafe arbitrary body'}})});
  assert.equal(result.ok,false);assert.ok(result.diagnostics.packages.every(entry=>entry.reason==='deprecated_release'));
  assert.equal(JSON.stringify(result).includes('unsafe arbitrary body'),false);
});
test('fixed fifteen-name allowlist rejects added packages before any metadata fetch',async()=>{
  const changed=structuredClone(template);changed.dependencies['extra-package']='published-stable';let reads=0;
  const result=await resolve({template:changed,fetchMetadata:async()=>{reads++;}});
  assert.equal(result.ok,false);assert.equal(reads,0);assert.equal(result.diagnostics.reason,'invalid_authored_template');
});
test('source version guesses and injected template scripts are not valid resolution policies',async()=>{
  const guessed=structuredClone(template);guessed.dependencies['@assistant-ui/core']='0.3.22';
  assert.equal((await resolve({template:guessed})).diagnostics.reason,'invalid_authored_template');
  const scripts=structuredClone(template);scripts.scripts.preinstall='bad';
  assert.equal((await resolve({template:scripts})).diagnostics.reason,'invalid_authored_template');
});
test('rerun reuses exact selected versions and never queries latest again',async()=>{
  const first=await resolve(),seen=[];
  const second=await resolve({previousResolution:first.resolution,fetchMetadata:async request=>{
    seen.push(request);assert.equal(request.version,'1.2.3');assert.ok(request.source.endsWith('/1.2.3'));return {status:200,data:metadata(request.name)};}});
  assert.equal(second.ok,true);assert.equal(second.resolution.reusedSelection,true);assert.deepEqual(second.manifest,first.manifest);
  assert.equal(seen.length,15);
});
test('a previously selected distribution integrity cannot drift on reread',async()=>{
  const first=await resolve();const changed='sha512-'+Buffer.alloc(64,2).toString('base64');
  const result=await resolve({previousResolution:first.resolution,fetchMetadata:async request=>({status:200,data:{...metadata(request.name),dist:{...metadata(request.name).dist,integrity:changed}}})});
  assert.equal(result.ok,false);assert.ok(result.diagnostics.packages.every(entry=>entry.reason==='distribution_integrity_drift'));
});
test('metadata name, registry distribution URL and missing integrity are closed validation gates',async()=>{
  for(const change of [value=>({...value,name:'not-allowed'}),value=>({...value,dist:{...value.dist,tarball:'https://example.invalid/package.tgz'}}),value=>({...value,dist:{tarball:value.dist.tarball}})]){
    const result=await resolve({fetchMetadata:async request=>({status:200,data:change(metadata(request.name))})});assert.equal(result.ok,false);
    assert.equal(result.manifest,undefined);
  }
});
test('rejected reads produce closed diagnostics and still capture reachable package outcomes',async()=>{
  const result=await resolve({fetchMetadata:async request=>{if(request.name==='react')throw Error('PRIVATE BODY SHOULD NEVER APPEAR');return {status:200,data:metadata(request.name)};}});
  assert.equal(result.ok,false);assert.equal(result.diagnostics.packages.filter(entry=>entry.status==='verified').length,14);
  assert.equal(JSON.stringify(result).includes('PRIVATE BODY SHOULD NEVER APPEAR'),false);
  assert.equal(result.diagnostics.packages.find(entry=>entry.name==='react').reason,'registry_transport_error');
});
test('previous selection must bind the same template and exact allowlist before any reads',async()=>{
  const first=await resolve();first.resolution.template_sha256='b'.repeat(64);let reads=0;
  const result=await resolve({previousResolution:first.resolution,fetchMetadata:async()=>{reads++;}});
  assert.equal(result.ok,false);assert.equal(reads,0);assert.equal(result.diagnostics.reason,'invalid_previous_selection');
});
test('published peer or engine metadata cannot drift for an already selected exact release',async()=>{
  const first=await resolve();
  const result=await resolve({previousResolution:first.resolution,fetchMetadata:async request=>({status:200,data:{...metadata(request.name),engines:{node:'>=99'}}})});
  assert.equal(result.ok,false);assert.ok(result.diagnostics.packages.every(entry=>entry.reason==='published_metadata_drift'));
});
test('malformed persisted peer and engine maps are rejected before any reread',async()=>{
  for(const key of ['peerDependencies','engines']){
    const first=await resolve();first.resolution.packages[0][key]=null;let reads=0;
    const result=await resolve({previousResolution:first.resolution,fetchMetadata:async()=>{reads++;}});
    assert.equal(result.ok,false);assert.equal(reads,0);assert.equal(result.diagnostics.reason,'invalid_previous_selection');
  }
});
test('a synchronous fetch rejection cannot prevent inspection of the other fixed packages',async()=>{
  const seen=[];
  const result=await resolve({fetchMetadata:request=>{
    seen.push(request.name);if(request.name==='@assistant-ui/core')throw Error('untrusted failure');
    return {status:200,data:metadata(request.name)};
  }});
  assert.equal(result.ok,false);assert.deepEqual(seen,PACKAGE_NAMES);
  assert.equal(result.diagnostics.packages.length,15);
  assert.equal(result.diagnostics.packages.filter(entry=>entry.status==='verified').length,14);
});
