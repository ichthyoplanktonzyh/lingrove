/** Case-specific acceptance data stays here, outside skill/MCP instructions.
 * Uses the real CLI only for reads/dry-runs; it never commits learner material.
 * Semantic expectations are agent-reviewed fixtures, not a keyword classifier.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {Bridge} from '../bridge.mjs';
const config=JSON.parse(await readFile(join(homedir(),'Library/Application Support/Lingrove MCP/config.json'),'utf8'));
const b=new Bridge({...config,state:join(homedir(),'Library/Application Support/Lingrove MCP/validation-semantics')});
const cases=JSON.parse(await readFile(new URL('./semantic-regression.json',import.meta.url),'utf8'));
const initial=await b.call('notebook_status',{});
assert.equal(initial.ok,true);
const {revision,notebookScope}=initial.result;
const meanings=[],entries=[],report=[];
for(const [i,c] of cases.entries()) {
 const found=await b.call('notebook_search',{query:c.expression,language:'en',limit:20});
 assert.equal(found.ok,true); assert.equal(found.result.total,1,c.expression);
 const full=await b.call('notebook_read',{entryID:found.result.entries[0].entryID});
 const sense=full.result.entry.senses.find(s=>s.meaning===c.sense); assert.ok(sense,c.expression);
 assert.ok(sense.examples.some(e=>e.text===c.source),'Original source changed: '+c.expression);
 const mappings=await b.call('notebook_catalog_search',{resource:'mappings',related:sense.id,limit:100});
 assert.equal(mappings.ok,true);
 const candidates=await b.call('notebook_catalog_search',{resource:'nodes',query:c.nodeQuery,summary:true,limit:10});
 assert.equal(candidates.ok,true);
 const cat=await b.call('notebook_catalog_search',{resource:'categories',query:c.categoryKey,summary:true,limit:10});
 assert.equal(cat.ok,true);
 const category=cat.result.records.find(x=>x.key===c.categoryKey); assert.ok(category,c.categoryKey);
 const guidance=await b.call('notebook_catalog_read',{resource:'categories',id:category.id});
 assert.equal(guidance.ok,true);
 assert.equal(category.axis,c.node.kind==='function'?'function':'content');
 const ref='meaning-'+i;
 let meaning={ref,...c.node,categories:[category.key]};
 if(c.reuseExpected) {
  const selected=candidates.result.records.filter(x=>x.kind===c.node.kind && x.labels.some(l=>l.text===c.nodeQuery));
  assert.equal(selected.length,1,'Review changed node candidates: '+c.expression);
  const current=await b.call('notebook_catalog_read',{resource:'nodes',id:selected[0].id}); assert.equal(current.ok,true);
  meaning={ref,id:selected[0].id,categories:[category.key]};
 }
 for(const mapping of mappings.result.records) {
  const node=await b.call('notebook_catalog_read',{resource:'nodes',id:mapping.nodeID}); assert.equal(node.ok,true);
  const memberships=await b.call('notebook_catalog_search',{resource:'categoryMemberships',related:mapping.nodeID,limit:100}); assert.equal(memberships.ok,true);
 }
 meanings.push(meaning);
 // Examples already exist: do not duplicate them. Associate the exact sense.
 entries.push({expression:full.result.entry.expression,kind:full.result.entry.kind,language:'en',senses:[{id:sense.id,associations:[{meaning:ref,...(c.usage?{usage:c.usage}:{})}]}]});
 report.push({expression:c.expression,kind:c.node.kind,reuse:c.reuseExpected,category:category.key,needsExistingNodeReview:!c.reuseExpected});
}
const preview=await b.call('notebook_preview',{task:{version:1,notebookScope,expectedRevision:revision,defaults:{language:'en',meaningLanguage:'zh-Hans'},meanings,entries}});
assert.equal(preview.receipt.ok,true,JSON.stringify(preview.receipt.error));
assert.equal(preview.receipt.result.dryRun,true);
assert.equal(preview.requiresUserConfirmation,false);
const final=await b.call('notebook_status',{});
assert.equal(final.result.revision,revision); assert.equal(final.result.entryCount,initial.result.entryCount);
console.log(JSON.stringify({ok:true,caseCount:cases.length,revision,realWrites:0,cases:report}));
