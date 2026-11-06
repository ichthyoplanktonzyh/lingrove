import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,rm,readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from './bridge.mjs';

test('preview never commits; exact file and key survive restart and uncertain retry',async()=>{
  const state=await mkdtemp(join(tmpdir(),'lingrove-mcp-test-'));
  let scope={workspaceID:'synthetic',notebookID:'00000000-0000-4000-8000-000000000001',generation:'test'};
  const calls=[];
  const run=async args=>{ calls.push(args); return args[0]==='status'?{ok:true,result:{revision:7,notebookScope:scope}}:{ok:true,result:{dryRun:args.includes('--dry-run')}}; };
  try {
    const b=new Bridge({state,run});
    await assert.rejects(()=>b.call('notebook_preview',{task:{expectedRevision:6}}),/Revision changed/);
    const p=await b.call('notebook_preview',{task:{version:1,entries:[]}});
    assert.equal(p.receipt.result.dryRun,true);
    assert.equal(calls.filter(a=>a[0]==='vocab'&&!a.includes('--dry-run')).length,0);
    const before=await readFile(join(state,p.previewID+'.json'),'utf8');
    const restarted=new Bridge({state,run});
    await restarted.call('notebook_commit',{previewID:p.previewID});
    await restarted.call('notebook_commit',{previewID:p.previewID});
    assert.equal(await readFile(join(state,p.previewID+'.json'),'utf8'),before);
    assert.deepEqual(calls.at(-1),calls.at(-3));
    scope={...scope,generation:'different'};
    await assert.rejects(()=>restarted.call('notebook_commit',{previewID:p.previewID}),/scope changed/);
    await assert.rejects(()=>b.call('notebook_commit',{previewID:'../bad'}));
  } finally { await rm(state,{recursive:true,force:true}); }
});

test('failed previews cannot commit',async()=>{
  const state=await mkdtemp(join(tmpdir(),'lingrove-mcp-test-'));
  try {
    const b=new Bridge({state,run:async args=>args[0]==='status'?{ok:true,result:{revision:1,notebookScope:{generation:'test'}}}:{ok:false}});
    const p=await b.call('notebook_preview',{task:{version:1,entries:[]}});
    await assert.rejects(()=>b.call('notebook_commit',{previewID:p.previewID}),/ENOENT/);
  } finally { await rm(state,{recursive:true,force:true}); }
});

// The stub models a write that committed but whose acknowledgement was lost.
// A retry must reach the CLI ledger even though the revision has advanced.
test('apply classification changes preserve mode, baseline and uncertain commit identity',async()=>{
  const state=await mkdtemp(join(tmpdir(),'lingrove-mcp-test-'));
  const scope={workspaceID:'synthetic',notebookID:'00000000-0000-4000-8000-000000000001',generation:'test'};
  let revision=7,attempts=0; const material=[];
  const run=async args=>{
    if(args[0]==='status') return {ok:true,result:{revision,notebookScope:scope}};
    assert.equal(args[1],'apply');
    material.push(await readFile(args[3],'utf8'));
    if(args.includes('--dry-run')) return {ok:true,result:{dryRun:true}};
    if(++attempts===1) { revision=8; throw new Error('synthetic lost acknowledgement'); }
    return {ok:true,result:{replayed:true,dryRun:false}};
  };
  try {
    const b=new Bridge({state,run});
    const task={version:2,expectedRevision:7,notebookScope:scope,operations:[
      {delete:{resource:'categoryMemberships',id:'00000000-0000-4000-8000-000000000002'}},
      {put:{resource:'categoryMemberships',value:{id:'00000000-0000-4000-8000-000000000003',nodeID:'00000000-0000-4000-8000-000000000004',categoryID:'00000000-0000-4000-8000-000000000005'}}}
    ]};
    const p=await b.call('notebook_preview',{mode:'apply',task});
    assert.equal(attempts,0);
    await assert.rejects(()=>b.call('notebook_commit',{previewID:p.previewID}),/lost acknowledgement/);
    const result=await new Bridge({state,run}).call('notebook_commit',{previewID:p.previewID});
    assert.equal(result.result.replayed,true);
    assert.equal(new Set(material).size,1);
    assert.deepEqual((await b.call('notebook_preview_read',{previewID:p.previewID})).task.operations,task.operations);
    await assert.rejects(()=>b.call('notebook_preview',{mode:'apply',task:{...task,notebookScope:undefined}}),/original read/);
    await assert.rejects(()=>b.call('notebook_preview',{mode:'apply',task}),/Revision changed/);
  } finally { await rm(state,{recursive:true,force:true}); }
});

test('resource filters, rich read schema and request options preserve CLI semantics',async()=>{
  const calls=[];
  const b=new Bridge({state:'/unused',run:async(args,opts)=>{calls.push({args,opts});return {ok:true};}});
  const id='00000000-0000-4000-8000-000000000001';
  await b.call('notebook_catalog_search',{resource:'interpretations',related:id,status:'candidate',offset:200,limit:200,options:{noLaunch:true,timeoutSeconds:120}});
  assert.deepEqual(calls[0],{args:['data','list','interpretations','--limit','200','--offset','200','--related',id,'--status','candidate'],opts:{noLaunch:true,timeoutSeconds:120}});
  await b.call('notebook_catalog_read',{resource:'categoryMemberships',id});
  assert.deepEqual(calls.at(-1).args,['data','get','categoryMemberships',id]);
  await b.call('notebook_schema',{format:'batch'}); assert.deepEqual(calls.at(-1).args,['schema']);
  await assert.rejects(()=>b.call('notebook_catalog_search',{resource:'mappings',summary:true}),/summary/);
  await assert.rejects(()=>b.call('notebook_catalog_search',{resource:'senses',status:'accepted'}),/status/);
  await assert.rejects(()=>b.call('constructor',{}),/Unknown tool/);
  const schemas=b.tools();
  assert.ok(!schemas.find(t=>t.name==='notebook_search').inputSchema.required?.includes('offset'));
  assert.equal(schemas.find(t=>t.name==='notebook_commit').annotations.destructiveHint,true);
});

test('chunk retries and image snapshots survive restart; host paths and tampering are rejected',async()=>{
  const state=await mkdtemp(join(tmpdir(),'lingrove-mcp-test-'));
  const scope={workspaceID:'synthetic',generation:'test'};
  const run=async args=>args[0]==='status'?{ok:true,result:{revision:7,notebookScope:scope}}:{ok:true,result:{dryRun:args.includes('--dry-run')}};
  try {
    const b=new Bridge({state,run});
    const first=await b.call('notebook_upload',{kind:'image',totalBytes:6,offset:0,dataBase64:Buffer.from('abc').toString('base64')});
    const restarted=new Bridge({state,run});
    await assert.rejects(()=>restarted.store.upload({uploadID:first.uploadID,kind:'image',totalBytes:6,offset:0,dataBase64:Buffer.from('bad').toString('base64')}),/Conflicting/);
    const tail={uploadID:first.uploadID,kind:'image',totalBytes:6,offset:3,dataBase64:Buffer.from('def').toString('base64')};
    assert.equal((await restarted.call('notebook_upload',tail)).complete,true);
    assert.equal((await restarted.call('notebook_upload',tail)).nextOffset,6);
    const task={version:1,operations:[{add:{expression:'synthetic',language:'en',kind:'word',meaning:'test',content:[{image:{path:'upload:'+first.uploadID}}]}}]};
    const p=await restarted.call('notebook_preview',{mode:'apply',task});
    const image=p.task.operations[0].add.content[0].image.path;
    assert.equal(await readFile(image,'utf8'),'abcdef');
    const {writeFile}=await import('node:fs/promises');
    await writeFile(restarted.store.path(first.uploadID,'.upload'),'xxxxxx');
    assert.equal(await readFile(image,'utf8'),'abcdef');
    await writeFile(image,'changed');
    await assert.rejects(()=>restarted.call('notebook_commit',{previewID:p.previewID}),/image changed/);
    task.operations[0].add.content[0].image.path='/etc/passwd';
    await assert.rejects(()=>restarted.call('notebook_preview',{mode:'apply',task}),/Local file paths/);
    const q=await restarted.call('notebook_preview',{task:{version:1,entries:[]}});
    await writeFile(restarted.store.path(q.previewID,'.json'),'{}');
    await assert.rejects(()=>restarted.call('notebook_commit',{previewID:q.previewID}),/material changed/);
  } finally { await rm(state,{recursive:true,force:true}); }
});

test('large UTF-8 tasks and responses remain readable without truncation',async()=>{
  const state=await mkdtemp(join(tmpdir(),'lingrove-mcp-test-'));
  const scope={workspaceID:'synthetic',generation:'test'};
  const run=async args=>args[0]==='status'?{ok:true,result:{revision:7,notebookScope:scope}}:{ok:true,result:{dryRun:true}};
  try {
    const b=new Bridge({state,run});
    const task={version:1,entries:[],defaults:{source:'中文与 emoji 🏦'}};
    const bytes=Buffer.from(JSON.stringify(task));
    const upload=await b.call('notebook_upload',{kind:'task',totalBytes:bytes.length,offset:0,dataBase64:bytes.toString('base64')});
    const p=await b.call('notebook_preview',{taskUploadID:upload.uploadID});
    assert.equal(p.task.defaults.source,task.defaults.source);
    const large={ok:true,result:{text:'中🏦'.repeat(180000)}};
    const bound=await b.store.bound(large);
    assert.equal(bound.paged,true);
    let text='',offset=0;
    for(;;) { const page=await b.call('notebook_result_read',{resultID:bound.resultID,offset,limit:16000}); text+=page.text; if(page.nextOffset===null) break; offset=page.nextOffset; }
    assert.deepEqual(JSON.parse(text),large);
  } finally { await rm(state,{recursive:true,force:true}); }
});
