// Pure validation and selection policy. Metadata I/O is injected by the shell.
export const RESOLUTION_SCHEMA = 'conversation-published-resolution/v1';
export const DIAGNOSTIC_SCHEMA = 'conversation-published-resolution-diagnostics/v1';
export const REGISTRY = 'https://registry.npmjs.org';
const dependencyNames = ['@assistant-ui/core','@assistant-ui/react','@assistant-ui/react-ink','ink','react','react-dom','ws'];
const developmentNames = ['@types/node','@types/react','@types/react-dom','esbuild','ink-testing-library','jsdom','tsx','typescript'];
export const PACKAGE_NAMES = Object.freeze([...dependencyNames, ...developmentNames]);
const authoredScripts = Object.freeze({
  typecheck:'tsc --noEmit',
  'test:shared':'node --test --test-reporter=tap tests/*.test.mjs',
  'test:renderers':'node --import tsx --test --test-reporter=tap web/renderer.test.tsx ink/renderer.test.tsx',
  'build:web':'esbuild web/main.tsx --bundle --outfile=web/dist/app.js --platform=browser --format=esm'
});
const exact = (value, keys) => value !== null && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === keys.length && keys.every(key=>Object.hasOwn(value,key));
const stable = value => typeof value === 'string' && value.length <= 64 && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value);
const pinUrl = (name, version) => `${REGISTRY}/${encodeURIComponent(name)}/${version}`;
const sorted = object => Object.fromEntries(Object.entries(object).sort(([a],[b])=>a<b?-1:a>b?1:0));
function same(a,b) { return JSON.stringify(a) === JSON.stringify(b); }
function recordMap(value) {
  if (value === undefined) return {};
  if (value === null || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length > 1000) return null;
  if (Object.entries(value).some(([key, entry])=>key.length > 256 || typeof entry !== 'string' || entry.length > 1024)) return null;
  return sorted(value);
}
function integrity(value) {
  if (typeof value !== 'string' || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(value)) return false;
  const encoded = value.slice(7), bytes = Buffer.from(encoded,'base64');
  return bytes.length === 64 && bytes.toString('base64') === encoded;
}
function tarball(value) {
  if (typeof value !== 'string' || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.origin === REGISTRY && !url.username && !url.password && !url.search && !url.hash && url.pathname.endsWith('.tgz');
  } catch { return false; }
}
export function validTemplate(template) {
  return exact(template,['name','private','version','type','scripts','dependencies','devDependencies']) &&
    template.name === 'arbor-conversation-ui-comparison' && template.private === true && template.version === '0.0.0' && template.type === 'module' &&
    exact(template.scripts,Object.keys(authoredScripts)) && Object.entries(authoredScripts).every(([key,value])=>template.scripts[key]===value) &&
    exact(template.dependencies,dependencyNames) && exact(template.devDependencies,developmentNames) &&
    PACKAGE_NAMES.every(name=>(template.dependencies[name]??template.devDependencies[name])==='published-stable');
}
function validPrevious(previous, templateSha256) {
  if (!exact(previous,['schema','template_sha256','packages','reusedSelection']) || previous.schema !== RESOLUTION_SCHEMA ||
      previous.template_sha256 !== templateSha256 || typeof previous.reusedSelection !== 'boolean' ||
      !Array.isArray(previous.packages) || previous.packages.length !== PACKAGE_NAMES.length) return false;
  const names = new Set();
  for (const entry of previous.packages) {
    const peers=recordMap(entry?.peerDependencies), engines=recordMap(entry?.engines);
    if (!exact(entry,['name','version','source','integrity','tarball','peerDependencies','engines']) || !PACKAGE_NAMES.includes(entry.name) ||
        names.has(entry.name) || !stable(entry.version) || entry.source !== pinUrl(entry.name,entry.version) ||
        !integrity(entry.integrity) || !tarball(entry.tarball) || peers===null || engines===null ||
        !same(entry.peerDependencies,peers) || !same(entry.engines,engines)) return false;
    names.add(entry.name);
  }
  return names.size === PACKAGE_NAMES.length;
}
function inspect(request, response, previous) {
  if (!response || !Number.isInteger(response.status)) return {status:'failed',reason:'invalid_fetch_result'};
  if (response.status !== 200) return {status:'failed',reason:response.status===404?'unavailable':'registry_http_error',http_status:response.status};
  const metadata = response.data;
  if (!metadata || typeof metadata !== 'object' || metadata.name !== request.name || !stable(metadata.version) ||
      request.version && metadata.version !== request.version) return {status:'failed',reason:'invalid_name_or_stable_version',http_status:200};
  if (metadata.deprecated !== undefined && metadata.deprecated !== null && metadata.deprecated !== false && metadata.deprecated !== '') {
    return {status:'failed',reason:'deprecated_release',http_status:200};
  }
  const peers=recordMap(metadata.peerDependencies), engines=recordMap(metadata.engines);
  if (!integrity(metadata.dist?.integrity) || !tarball(metadata.dist?.tarball) || peers === null || engines === null) {
    return {status:'failed',reason:'invalid_distribution_metadata',http_status:200};
  }
  const entry = {name:request.name,version:metadata.version,source:pinUrl(request.name,metadata.version),
    integrity:metadata.dist.integrity,tarball:metadata.dist.tarball,peerDependencies:peers,engines};
  if (previous) {
    if (entry.integrity !== previous.integrity || entry.tarball !== previous.tarball) return {status:'failed',reason:'distribution_integrity_drift',http_status:200};
    if (!same(entry.peerDependencies,previous.peerDependencies) || !same(entry.engines,previous.engines)) {
      return {status:'failed',reason:'published_metadata_drift',http_status:200};
    }
  }
  return {status:'verified',http_status:200,entry};
}

/** All independent fixed-name reads settle before any generated manifest is returned. */
export async function resolvePublished({template,templateSha256,previousResolution=null,fetchMetadata}) {
  const base = {schema:DIAGNOSTIC_SCHEMA,reusedSelection:previousResolution!==null,packages:[]};
  if (!validTemplate(template) || !/^[0-9a-f]{64}$/.test(templateSha256??'') || typeof fetchMetadata !== 'function') {
    return {ok:false,diagnostics:{...base,status:'failed',reason:'invalid_authored_template'}};
  }
  if (previousResolution !== null && !validPrevious(previousResolution,templateSha256)) {
    return {ok:false,diagnostics:{...base,status:'failed',reason:'invalid_previous_selection'}};
  }
  const previous = new Map((previousResolution?.packages??[]).map(entry=>[entry.name,entry]));
  const requests = PACKAGE_NAMES.map(name=>({name,version:previous.get(name)?.version??null,
    source:pinUrl(name,previous.get(name)?.version??'latest')}));
  const responses = await Promise.allSettled(requests.map(request=>Promise.resolve().then(()=>fetchMetadata(Object.freeze(request)))));
  const entries = [], diagnostics=[];
  for (let index=0;index<requests.length;index++) {
    const request=requests[index], response=responses[index];
    const inspected=response.status==='fulfilled'?inspect(request,response.value,previous.get(request.name)):
      {status:'failed',reason:['registry_timeout','registry_body_limit','invalid_registry_json'].includes(response.reason?.code)?response.reason.code:'registry_transport_error'};
    const {entry,...status}=inspected;
    diagnostics.push({name:request.name,selection:request.version?'exact':'latest-stable',source:request.source,...status});
    if (entry) entries.push(entry);
  }
  if (entries.length!==PACKAGE_NAMES.length) return {ok:false,diagnostics:{...base,status:'failed',packages:diagnostics}};
  const versions=new Map(entries.map(entry=>[entry.name,entry.version]));
  const manifest={...template,scripts:{...template.scripts},
    dependencies:Object.fromEntries(dependencyNames.map(name=>[name,versions.get(name)])),
    devDependencies:Object.fromEntries(developmentNames.map(name=>[name,versions.get(name)]))};
  return {ok:true,manifest,resolution:{schema:RESOLUTION_SCHEMA,template_sha256:templateSha256,packages:entries,reusedSelection:previousResolution!==null},
    diagnostics:{...base,status:'passed',packages:diagnostics}};
}
