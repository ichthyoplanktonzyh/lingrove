/** Explicit integration check: real notebook reads and dry-runs only. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { Bridge,RESOURCES } from './bridge.mjs';
const config=JSON.parse(await readFile(join(homedir(),'Library/Application Support/Lingrove MCP/config.json'),'utf8'));
// Isolate validation previews from user drafts; no commit tool is ever called.
const bridge=new Bridge({...config,state:join(homedir(),'Library/Application Support/Lingrove MCP/validation-drafts')});
const initial=await bridge.call('notebook_status',{}); assert.equal(initial.ok,true);
const {revision,notebookScope}=initial.result;
assert.deepEqual([...RESOURCES].sort(),[...initial.result.resources].sort());
for(const resource of RESOURCES) {
 const result=await bridge.call('notebook_catalog_search',{resource,limit:1,offset:0});
 assert.equal(result.ok,true,resource+': '+JSON.stringify(result.error));
 const record=result.result.records[0];
 if(record) {
  const id=record.id??record.senseID??record.categoryID;
  const full=await bridge.call('notebook_catalog_read',{resource,id});
  assert.equal(full.ok,true,'get '+resource+': '+JSON.stringify(full.error));
 }
}
const batchSchema=await bridge.call('notebook_schema',{format:'batch'});
assert.equal(batchSchema.title,'Lingrove vocabulary and resource batch');
assert.match((await bridge.call('notebook_cli_info',{topic:'version'})).text,/CLI 4/);
assert.match((await bridge.call('notebook_cli_info',{topic:'help'})).text,/vocab apply/);
// Replace a membership inside one hypothetical resource transaction. All IDs are synthetic.
const node=randomUUID(),oldCategory=randomUUID(),newCategory=randomUUID(),oldMembership=randomUUID();
const put=(resource,value)=>({put:{resource,value}});
const labels=text=>[{id:randomUUID(),text,language:'en'}];
const batch={version:2,notebookScope,expectedRevision:revision,operations:[
 put('nodes',{id:node,kind:'concept',labels:labels('Synthetic MCP validation meaning')}),
 put('categories',{id:oldCategory,axis:'content',labels:labels('Synthetic old classification')}),
 put('categories',{id:newCategory,axis:'content',labels:labels('Synthetic new classification')}),
 put('categoryMemberships',{id:oldMembership,nodeID:node,categoryID:oldCategory}),
 {delete:{resource:'categoryMemberships',id:oldMembership}},
 put('categoryMemberships',{id:randomUUID(),nodeID:node,categoryID:newCategory})
]};
const classified=await bridge.call('notebook_preview',{mode:'apply',task:batch});
assert.equal(classified.receipt.ok,true,JSON.stringify(classified.receipt.error));
assert.equal(classified.receipt.result.dryRun,true);
// Exercise append/update routing with an existing sense, preserving original material.
const list=await bridge.call('notebook_search',{query:'figure out',limit:20});
const entry=await bridge.call('notebook_read',{entryID:list.result.entries[0].entryID});
const sense=entry.result.entry.senses[0];
const edit=await bridge.call('notebook_preview',{mode:'apply',task:{version:1,notebookScope,expectedRevision:revision,operations:[
 {update:{entryID:entry.result.entry.id,senseID:sense.id,expectedRevision:revision,note:sense.note??''}},
 {append:{entryID:entry.result.entry.id,senseID:sense.id,tags:['synthetic-dry-run-only']}}
]}});
assert.equal(edit.receipt.ok,true,JSON.stringify(edit.receipt.error));
assert.equal(edit.receipt.result.dryRun,true);
// Stage a user-supplied synthetic 1x1 PNG and pass its frozen path through CLI apply.
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=','base64');
const image=await bridge.call('notebook_upload',{kind:'image',totalBytes:png.length,offset:0,dataBase64:png.toString('base64')});
const rich=await bridge.call('notebook_preview',{mode:'apply',task:{version:1,operations:[{add:{expression:'synthetic-mcp-image-check',language:'en',kind:'expression',meaning:'Synthetic dry-run only',content:[{text:'Synthetic rich text',bold:true},{image:{path:'upload:'+image.uploadID,caption:'Synthetic PNG'}}]}}]}});
assert.equal(rich.receipt.ok,true,JSON.stringify(rich.receipt.error));
assert.equal(rich.receipt.result.dryRun,true);
const final=await bridge.call('notebook_status',{});
assert.equal(final.result.revision,revision);
assert.equal(final.result.entryCount,initial.result.entryCount);
console.log(JSON.stringify({ok:true,resourceKinds:RESOURCES.length,revision,entryCount:final.result.entryCount,dryRuns:['classification replacement','sense update/append','rich text/image add'],realWrites:0}));
