import {readFile,writeFile,rename,unlink,mkdir,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolvePublished} from './shared/published-resolution.mjs';

const root = new URL('./',import.meta.url), BODY_LIMIT=1024*1024, TIMEOUT_MS=30000;
function failure(code) { const error=new Error(code);error.code=code;return error; }
async function loadOptional(filename) {
  try { return JSON.parse(await readFile(new URL(filename,root),'utf8')); }
  catch(error) { if(error.code==='ENOENT')return null;throw failure('invalid_preparation_state'); }
}
async function save(filename,value) {
  // This exact staging directory is below the runner's declared generated tmp
  // path. Recover only our fixed, private regular staging files after interruption.
  const staging=new URL('tmp/published-resolution-staging/',root);
  for(const directory of [new URL('tmp/',root),staging]){
    await mkdir(directory,{mode:0o700}).catch(error=>{if(error.code!=='EEXIST')throw error;});
    const entry=await lstat(directory);
    if(!entry.isDirectory()||entry.isSymbolicLink()||(entry.mode&0o777)!==0o700||
       typeof process.getuid==='function'&&entry.uid!==process.getuid())throw failure('invalid_preparation_state');
  }
  const temporary=new URL(filename,staging),destination=new URL(filename,root);
  try{
    const entry=await lstat(temporary);
    if(!entry.isFile()||entry.isSymbolicLink()||entry.nlink!==1||(entry.mode&0o777)!==0o600||
       typeof process.getuid==='function'&&entry.uid!==process.getuid())throw failure('invalid_preparation_state');
    await unlink(temporary);
  }catch(error){if(error.code!=='ENOENT')throw error;}
  try {
    await writeFile(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
    await rename(temporary,destination);
  }finally{await unlink(temporary).catch(()=>{});}
}
async function fetchMetadata(request) {
  let response;
  try {
    response=await fetch(request.source,{signal:AbortSignal.timeout(TIMEOUT_MS),redirect:'error',credentials:'omit',
      headers:{accept:'application/json'}});
  } catch(error) { throw failure(['TimeoutError','AbortError'].includes(error.name)?'registry_timeout':'registry_transport_error'); }
  if(response.status!==200){await response.body?.cancel();return {status:response.status};}
  if(Number(response.headers.get('content-length'))>BODY_LIMIT){await response.body?.cancel();throw failure('registry_body_limit');}
  const reader=response.body.getReader(),parts=[];let bytes=0;
  try {
    while(true){const {done,value}=await reader.read();if(done)break;bytes+=value.byteLength;
      if(bytes>BODY_LIMIT){await reader.cancel();throw failure('registry_body_limit');}parts.push(value);}
  }catch(error){throw failure(error.code==='registry_body_limit'?error.code:['TimeoutError','AbortError'].includes(error.name)?'registry_timeout':'registry_transport_error');}
  const body=Buffer.concat(parts);
  let data;try{data=JSON.parse(body.toString('utf8'));}catch{throw failure('invalid_registry_json');}
  return {status:200,data};
}

try {
  if(process.argv.length!==2)throw failure('arguments_not_supported');
  const templateText=await readFile(new URL('package.template.json',root),'utf8'),template=JSON.parse(templateText);
  const templateSha256=createHash('sha256').update(templateText).digest('hex');
  const previousResolution=await loadOptional('published-resolution.json');
  const result=await resolvePublished({template,templateSha256,previousResolution,fetchMetadata});
  await save('published-resolution-diagnostics.json',result.diagnostics);
  if(!result.ok){console.log(JSON.stringify({status:'failed',reason:'published_package_resolution_failed',
    verified:result.diagnostics.packages.filter(entry=>entry.status==='verified').length,total:15}));process.exitCode=1;}
  else {
    const current=await loadOptional('package.json');
    if(previousResolution!==null&&current!==null&&JSON.stringify(current)!==JSON.stringify(result.manifest))throw failure('generated_manifest_drift');
    // Metadata can never supply scripts/config. Only authored template + exact version values are persisted.
    // Persist selection first, so interruption cannot leave a generated manifest
    // without the exact-version selection that future preparations must reuse.
    await save('published-resolution.json',result.resolution);await save('package.json',result.manifest);
    console.log(JSON.stringify({status:'passed',packages:result.resolution.packages.length,reusedSelection:result.resolution.reusedSelection}));
  }
}catch(error){
  const reason=['arguments_not_supported','invalid_preparation_state','generated_manifest_drift'].includes(error.code)?error.code:'published_preparation_failed';
  await save('published-resolution-diagnostics.json',{schema:'conversation-published-resolution-diagnostics/v1',status:'failed',reason,packages:[]}).catch(()=>{});
  console.log(JSON.stringify({status:'failed',reason}));process.exitCode=1;
}
