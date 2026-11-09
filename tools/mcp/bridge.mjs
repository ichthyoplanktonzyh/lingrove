/** A command-level adapter: Lingrove owns validation, transactions and storage.
 * Request options cannot switch app/notebook. DraftStore owns transport files.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID, createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { z } from 'zod';
import { DraftStore } from './draft-store.mjs';
import { assessWrite } from './write-policy.mjs';

const exec=promisify(execFile);
export const RESOURCES=['entries','senses','sources','occurrences','interpretations','collections','nodes','patterns','mappings','relations','cues','cueTargets','frameworks','categories','categoryParents','categoryMemberships','categoryOverrides'];
const resource=z.enum(RESOURCES),uuid=z.string().uuid();
const options=z.object({noLaunch:z.boolean().optional(),timeoutSeconds:z.number().min(1).max(120).optional()}).strict().optional();
const readOptions={options};
const page={limit:z.number().int().min(1).max(200).default(20),offset:z.number().int().min(0).default(0)};
const material={mode:z.enum(['capture','apply']).default('capture'),task:z.record(z.string(),z.unknown()).optional(),taskUploadID:uuid.optional(),...readOptions};
const definitions={
  notebook_guide:['Read shared language-material and semantic-modeling guidance before saving or semantic maintenance. This is the same source used by the CLI skill.',z.object({}).strict()],
  notebook_write:['WRITE authorized additions in one call: capture, add/append, or new resource records (including meaning mappings and category memberships). Read notebook_guide/schema and search/read first. No repeated user confirmation for already-authorized additions. Provide a fresh requestID before the first attempt; retain it and the identical task for busy/timeout retries. Internal dry-run and commit are automatic. Existing-record replacements, deletes, merges and catalog overrides/hierarchy are refused here; use preview/commit review. Read affected records from returned IDs. Never write merely to test connectivity.',z.object({requestID:uuid,...material}).strict()],
  notebook_status:['Read selected notebook identity, revision, supported resources and counts.',z.object(readOptions).strict()],
  notebook_cli_info:['Read the selected helper version or command help; does not send a notebook request.',z.object({topic:z.enum(['version','help']).default('version')}).strict()],
  notebook_schema:['Read authoritative CLI JSON schema: capture for collecting material; batch for add/append/update, explicit sense merge and all version 2 resource put/delete operations. Schema commands run alone.',z.object({format:z.enum(['capture','batch']).default('capture')}).strict()],
  notebook_search:['Search collected vocabulary before saving. Substring matching, not semantic ranking; paginate until offset reaches total.',z.object({query:z.string().max(32000).default(''),language:z.string().max(100).optional(),...page,...readOptions}).strict()],
  notebook_read:['Read a complete collected entry before choosing an existing sense.',z.object({entryID:uuid,...readOptions}).strict()],
  notebook_catalog_search:['List ANY CLI resource, including mappings/categoryMemberships for an existing sense/node. Filters match CLI semantics; related is a UUID. status only filters interpretations; summary only supports nodes/categories. Paginate via nextOffset.',z.object({resource,query:z.string().max(32000).optional(),related:uuid.optional(),status:z.enum(['candidate','accepted','rejected']).optional(),summary:z.boolean().optional(),...page,...readOptions}).strict()],
  notebook_catalog_read:['Read ANY CLI resource by its UUID. Collections use senseID; categoryOverrides use categoryID. Read related records before editing.',z.object({resource,id:uuid,...readOptions}).strict()],
  notebook_upload:['Stage explicitly user-supplied image bytes or a large UTF-8 task JSON. Canonical base64 chunks <=512 KiB; sequential offset, fixed kind/totalBytes. Omit uploadID only on first chunk. Retry identical chunk and uploadID after uncertainty. Finished image references use image.path = upload:UUID in apply content. No arbitrary host paths.',z.object({uploadID:uuid.optional(),kind:z.enum(['image','task']),totalBytes:z.number().int().min(1).max(32*1024*1024),offset:z.number().int().min(0),dataBase64:z.string().max(700000)}).strict()],
  notebook_result_read:['Read a preserved large tool result by character offset. Follow nextOffset until null. Text slices together form the full JSON; omitted content must not be guessed.',z.object({resultID:uuid,offset:z.number().int().min(0).default(0),limit:z.number().int().min(1).max(16000).default(12000)}).strict()],
  notebook_preview_read:['Read a validated preview and its review reasons. Check proposed differences and shared-node/category effects before obtaining any missing authorization. Does not commit.',z.object({previewID:uuid}).strict()],
  notebook_preview:['DRY RUN ONLY for requested previews and review of replacements/deletes/shared edits. mode=capture or apply; pass exactly one of task/taskUploadID. Existing edits preserve original notebookScope/expectedRevision. Inspect full receipt, relevant current records, mappings and categories. Obtain missing authorization for concrete high-risk changes; do not ask twice for the same reviewed authorized change. Use notebook_write for ordinary already-authorized additions.',z.object(material).strict()],
  notebook_commit:['WRITE, possibly destructive: commit an exact validated preview only within user authorization. Review differences, shared effects and any deletion/replacement before committing; obtain missing authorization, not repeated approval of the same reviewed change. Retry SAME previewID after busy/timeout. Conflict requires reread/reconciliation. Ordinary additions should use notebook_write. Does not enroll in review.',z.object({previewID:uuid,...readOptions}).strict()],
};

export class Bridge {
  constructor({cli,app,state,run,guidePath=new URL('../../skills/lingrove-cli/references/semantic-modeling.md',import.meta.url)}) {
    Object.assign(this,{cli,app,state}); this.store=new DraftStore(state);
    this.guidePath=guidePath; this.writeQueue=Promise.resolve();
    this.run=run??(async(args,opts={})=>{
      const info=['schema','--help','--version'].includes(args[0]);
      const cliArgs=info?args:['--app',app,...(opts.noLaunch?['--no-launch']:[]),'--timeout',String(opts.timeoutSeconds??30),...args];
      try {
        const {stdout}=await exec(cli,cliArgs,{timeout:((opts.timeoutSeconds??30)*2+10)*1000,maxBuffer:20*1024*1024});
        return args[0]==='--help'||args[0]==='--version'?{ok:true,text:stdout.trim()}:JSON.parse(stdout);
      } catch(e) {
        if(e.stdout) { try { return JSON.parse(e.stdout); } catch {} }
        throw new Error('CLI request failed or timed out. Preserve the same previewID/key and image bytes for retries.');
      }
    });
  }
  tools() { return Object.entries(definitions).map(([name,[description,schema]])=>({name,description,inputSchema:z.toJSONSchema(schema,{io:'input'}),annotations:{readOnlyHint:!['notebook_commit','notebook_write'].includes(name),destructiveHint:name==='notebook_commit',idempotentHint:!['notebook_preview','notebook_upload'].includes(name),openWorldHint:false}})); }
  async call(name,input) { return this.store.bound(await this.execute(name,input)); }
  async execute(name,input) {
    if(!Object.hasOwn(definitions,name)) throw new Error('Unknown tool');
    const a=definitions[name][1].parse(input),opts=a.options??{};
    if(name==='notebook_guide') return {guide:await readFile(this.guidePath,'utf8')};
    if(name==='notebook_write') {
      const next=this.writeQueue.then(()=>this.write(a,opts));
      this.writeQueue=next.catch(()=>{}); return next;
    }
    if(name==='notebook_status') return this.run(['status'],opts);
    if(name==='notebook_cli_info') return this.run([a.topic==='help'?'--help':'--version']);
    if(name==='notebook_schema') return this.run(a.format==='batch'?['schema']:['schema','capture']);
    if(name==='notebook_search') return this.run(['vocab','list','--query',a.query,...(a.language?['--language',a.language]:[]),'--limit',String(a.limit),'--offset',String(a.offset)],opts);
    if(name==='notebook_read') return this.run(['vocab','get',a.entryID],opts);
    if(name==='notebook_catalog_search') {
      if(a.summary && !['nodes','categories'].includes(a.resource)) throw new Error('summary is only supported for nodes/categories.');
      if(a.status && a.resource!=='interpretations') throw new Error('status is only supported for interpretations.');
      const args=['data','list',a.resource,'--limit',String(a.limit),'--offset',String(a.offset)];
      for(const [key,flag] of [['query','--query'],['related','--related'],['status','--status']]) if(a[key]!==undefined) args.push(flag,a[key]);
      if(a.summary) args.push('--summary');
      return this.run(args,opts);
    }
    if(name==='notebook_catalog_read') return this.run(['data','get',a.resource,a.id],opts);
    if(name==='notebook_upload') return this.store.upload(a);
    if(name==='notebook_result_read') return this.store.result(a);
    if(name==='notebook_preview_read') {
      const {manifest,task}=await this.store.validated(a.previewID);
      return {previewID:a.previewID,mode:manifest.mode,task,receipt:manifest.receipt,review:manifest.review,requiresUserConfirmation:manifest.review?.requiresReview??true};
    }
    if(name==='notebook_preview') return this.preview(a,opts);
    return this.commit(a.previewID,opts);
  }
  async commit(previewID,opts) {
    const {manifest,task}=await this.store.validated(previewID);
    const status=await this.run(['status'],opts);
    if(!status.ok) return status;
    if(!sameScope(task.notebookScope,status.result.notebookScope)) throw new Error('Notebook scope changed; commit refused.');
    // Do NOT pre-reject revision drift here: a timed-out committed request must
    // reach the app's idempotency ledger and receive its original acknowledgement.
    return this.run(['vocab',manifest.mode,'--file',this.store.path(previewID,'.json')],opts);
  }
  async input(a) {
    if((a.task===undefined)===(a.taskUploadID===undefined)) throw new Error('Provide exactly one of task and taskUploadID.');
    const input=a.task??await this.store.task(a.taskUploadID);
    if(!input || typeof input!=='object' || Array.isArray(input)) throw new Error('Task must be an object.');
    return structuredClone(input);
  }
  async prepare(original,mode,opts) {
    const edits=mode==='apply'?(original.operations??[]).some(op=>op.append||op.update||op.put||op.delete||op.merge||references(op.capture)):references(original);
    if(edits && (!original.notebookScope || original.expectedRevision===undefined)) throw new Error('Existing-record/resource edits require notebookScope and expectedRevision from the original read.');
    const status=await this.run(['status'],opts);
    if(!status.ok) return {error:status};
    const {revision,notebookScope}=status.result;
    if(original.notebookScope && !sameScope(original.notebookScope,notebookScope)) throw new Error('Notebook scope changed; reread and rebuild draft.');
    if(original.expectedRevision!==undefined && original.expectedRevision!==revision) throw new Error('Revision changed; reread and rebuild draft.');
    for(const op of original.operations??[]) if(op.update && op.update.expectedRevision!==revision) throw new Error('Update revision changed or missing; reread and rebuild draft.');
    const task={...original,idempotencyKey:original.idempotencyKey??randomUUID(),notebookScope,expectedRevision:revision};
    return {task};
  }
  async validate(previewID,task,mode,opts,review) {
    await this.store.init();
    const assets=await this.store.freezeImages(previewID,task);
    const sha256=await this.store.writeTask(previewID,task);
    const receipt=await this.run(['vocab',mode,'--file',this.store.path(previewID,'.json'),'--dry-run'],opts);
    if(receipt.ok && receipt.result?.dryRun===true) await this.store.validate(previewID,{mode,sha256,assets,receipt,review});
    return {previewID,mode,task,receipt,review,requiresUserConfirmation:review.requiresReview};
  }
  async preview(a,opts) {
    const prepared=await this.prepare(await this.input(a),a.mode,opts);
    if(prepared.error) return prepared.error;
    const review=await assessWrite(a.mode,prepared.task,this.run,opts);
    return this.validate(randomUUID(),prepared.task,a.mode,opts,review);
  }
  async write(a,opts) {
    const original=await this.input(a);
    if(original.idempotencyKey!==undefined && original.idempotencyKey!==a.requestID) throw new Error('For notebook_write, idempotencyKey must equal requestID or be omitted.');
    const fingerprint=createHash('sha256').update(JSON.stringify(canonical({mode:a.mode,task:original}))).digest('hex');
    let request=await this.store.optional(a.requestID,'.request.json');
    if(request) {
      if(request.fingerprint!==fingerprint || request.mode!==a.mode) throw new Error('Conflicting requestID reuse; retry the original request unchanged.');
      const status=await this.run(['status'],opts);
      if(!status.ok) return status;
      if(!sameScope(request.task.notebookScope,status.result.notebookScope)) throw new Error('Notebook scope changed; write retry refused.');
      if(await this.store.optional(a.requestID,'.ready')) {
        return {...await this.commit(a.requestID,opts),writeRequestID:a.requestID,requiresUserConfirmation:false};
      }
      if(request.task.expectedRevision!==status.result.revision) throw new Error('Revision changed before validation; reread and reconcile with a new requestID.');
    } else {
      const prepared=await this.prepare({...original,idempotencyKey:a.requestID},a.mode,opts);
      if(prepared.error) return prepared.error;
      const review=await assessWrite(a.mode,prepared.task,this.run,opts);
      if(review.requiresReview) return {ok:false,error:{code:'review_required',message:'This request may replace or delete saved material; use notebook_preview and the review route.',details:review.reasons},requiresUserConfirmation:true};
      request={fingerprint,mode:a.mode,task:prepared.task};
      await this.store.save(a.requestID,'.request.json',request);
    }
    // Work on a clone: image freezing must not change the durable original request.
    const preview=await this.validate(a.requestID,structuredClone(request.task),a.mode,opts,{requiresReview:false,reasons:[]});
    if(!preview.receipt.ok || preview.receipt.result?.dryRun!==true) return {...preview.receipt,writeRequestID:a.requestID,requiresUserConfirmation:false};
    return {...await this.commit(a.requestID,opts),writeRequestID:a.requestID,requiresUserConfirmation:false};
  }
}
function canonical(x) { return Array.isArray(x)?x.map(canonical):x && typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x; }
function references(task) { return task?.meanings?.some(x=>x.id)||task?.entries?.some(x=>x.senses?.some(s=>s.id)); }
function sameScope(a,b) { return a && b && JSON.stringify(sort(a))===JSON.stringify(sort(b)); }
function sort(x) { return Object.fromEntries(Object.entries(x).sort(([a],[b])=>a.localeCompare(b))); }
