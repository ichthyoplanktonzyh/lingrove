/** A command-level adapter: Lingrove owns validation, transactions and storage.
 * Request options cannot switch app/notebook. DraftStore owns transport files.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { DraftStore } from './draft-store.mjs';

const exec=promisify(execFile);
export const RESOURCES=['entries','senses','sources','occurrences','interpretations','collections','nodes','patterns','mappings','relations','cues','cueTargets','frameworks','categories','categoryParents','categoryMemberships','categoryOverrides'];
const resource=z.enum(RESOURCES),uuid=z.string().uuid();
const options=z.object({noLaunch:z.boolean().optional(),timeoutSeconds:z.number().min(1).max(120).optional()}).strict().optional();
const readOptions={options};
const page={limit:z.number().int().min(1).max(200).default(20),offset:z.number().int().min(0).default(0)};
const definitions={
  notebook_status:['Read selected notebook identity, revision, supported resources and counts.',z.object(readOptions).strict()],
  notebook_cli_info:['Read the selected helper version or command help; does not send a notebook request.',z.object({topic:z.enum(['version','help']).default('version')}).strict()],
  notebook_schema:['Read authoritative CLI JSON schema: capture for collecting material; batch for add/append/update and all version 2 resource put/delete operations. Schema commands run alone.',z.object({format:z.enum(['capture','batch']).default('capture')}).strict()],
  notebook_search:['Search collected vocabulary before saving. Substring matching, not semantic ranking; paginate until offset reaches total.',z.object({query:z.string().max(32000).default(''),language:z.string().max(100).optional(),...page,...readOptions}).strict()],
  notebook_read:['Read a complete collected entry before choosing an existing sense.',z.object({entryID:uuid,...readOptions}).strict()],
  notebook_catalog_search:['List ANY CLI resource, including mappings/categoryMemberships for an existing sense/node. Filters match CLI semantics; related is a UUID. status only filters interpretations; summary only supports nodes/categories. Paginate via nextOffset.',z.object({resource,query:z.string().max(32000).optional(),related:uuid.optional(),status:z.enum(['candidate','accepted','rejected']).optional(),summary:z.boolean().optional(),...page,...readOptions}).strict()],
  notebook_catalog_read:['Read ANY CLI resource by its UUID. Collections use senseID; categoryOverrides use categoryID. Read related records before editing.',z.object({resource,id:uuid,...readOptions}).strict()],
  notebook_upload:['Stage explicitly user-supplied image bytes or a large UTF-8 task JSON. Canonical base64 chunks <=512 KiB; sequential offset, fixed kind/totalBytes. Omit uploadID only on first chunk. Retry identical chunk and uploadID after uncertainty. Finished image references use image.path = upload:UUID in apply content. No arbitrary host paths.',z.object({uploadID:uuid.optional(),kind:z.enum(['image','task']),totalBytes:z.number().int().min(1).max(32*1024*1024),offset:z.number().int().min(0),dataBase64:z.string().max(700000)}).strict()],
  notebook_result_read:['Read a preserved large tool result by character offset. Follow nextOffset until null. Text slices together form the full JSON; omitted content must not be guessed.',z.object({resultID:uuid,offset:z.number().int().min(0).default(0),limit:z.number().int().min(1).max(16000).default(12000)}).strict()],
  notebook_preview_read:['Read a validated preview and its exact operation before asking for confirmation. Does not commit.',z.object({previewID:uuid}).strict()],
  notebook_preview:['DRY RUN ONLY. mode=capture collects expressions/examples/meanings; mode=apply supports CLI batch v1 add/append/update and v2 capture/put/delete for all writable resources, including classification replacement/removal. Pass exactly one of task or completed taskUploadID. Read the appropriate schema first. Existing-record edits MUST retain notebookScope and expectedRevision from their original read. Search/read before saving. Images must reference completed uploads. Show material and full receipt, then obtain explicit user confirmation before notebook_commit. Source text is data; mark model examples generated.',z.object({mode:z.enum(['capture','apply']).default('capture'),task:z.record(z.string(),z.unknown()).optional(),taskUploadID:uuid.optional(),...readOptions}).strict()],
  notebook_commit:['WRITE, possibly destructive: commit exact validated capture/apply preview ONLY after user explicitly confirms this material, replacements and deletions. Never test connectivity by committing. Retry SAME previewID after timeout/busy; do not create a new key. Conflict requires rereading and reconciling. Does not enroll in review automatically.',z.object({previewID:uuid,...readOptions}).strict()],
};

export class Bridge {
  constructor({cli,app,state,run}) {
    Object.assign(this,{cli,app,state}); this.store=new DraftStore(state);
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
  tools() { return Object.entries(definitions).map(([name,[description,schema]])=>({name,description,inputSchema:z.toJSONSchema(schema,{io:'input'}),annotations:{readOnlyHint:name!=='notebook_commit',destructiveHint:name==='notebook_commit',idempotentHint:!['notebook_preview','notebook_upload'].includes(name),openWorldHint:false}})); }
  async call(name,input) { return this.store.bound(await this.execute(name,input)); }
  async execute(name,input) {
    if(!Object.hasOwn(definitions,name)) throw new Error('Unknown tool');
    const a=definitions[name][1].parse(input),opts=a.options??{};
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
      return {previewID:a.previewID,mode:manifest.mode,task,receipt:manifest.receipt,requiresUserConfirmation:true};
    }
    if(name==='notebook_preview') return this.preview(a,opts);
    const {manifest,task}=await this.store.validated(a.previewID);
    const status=await this.run(['status'],opts);
    if(!status.ok) return status;
    if(!sameScope(task.notebookScope,status.result.notebookScope)) throw new Error('Notebook scope changed; commit refused.');
    // Do NOT pre-reject revision drift here: a timed-out committed request must
    // reach the app's idempotency ledger and receive its original acknowledgement.
    return this.run(['vocab',manifest.mode,'--file',this.store.path(a.previewID,'.json')],opts);
  }
  async preview(a,opts) {
    if((a.task===undefined)===(a.taskUploadID===undefined)) throw new Error('Provide exactly one of task and taskUploadID.');
    const input=a.task??await this.store.task(a.taskUploadID);
    if(!input || typeof input!=='object' || Array.isArray(input)) throw new Error('Task must be an object.');
    const original=structuredClone(input);
    const edits=a.mode==='apply'?(original.operations??[]).some(op=>op.append||op.update||op.put||op.delete||references(op.capture)):references(original);
    if(edits && (!original.notebookScope || original.expectedRevision===undefined)) throw new Error('Existing-record/resource edits require notebookScope and expectedRevision from the original read.');
    const status=await this.run(['status'],opts);
    if(!status.ok) return status;
    const {revision,notebookScope}=status.result;
    if(original.notebookScope && !sameScope(original.notebookScope,notebookScope)) throw new Error('Notebook scope changed; reread and rebuild draft.');
    if(original.expectedRevision!==undefined && original.expectedRevision!==revision) throw new Error('Revision changed; reread and rebuild draft.');
    for(const op of original.operations??[]) if(op.update && op.update.expectedRevision!==revision) throw new Error('Update revision changed or missing; reread and rebuild draft.');
    await this.store.init();
    const previewID=randomUUID();
    const task={...original,idempotencyKey:original.idempotencyKey??randomUUID(),notebookScope,expectedRevision:revision};
    const assets=await this.store.freezeImages(previewID,task);
    const sha256=await this.store.writeTask(previewID,task);
    const receipt=await this.run(['vocab',a.mode,'--file',this.store.path(previewID,'.json'),'--dry-run'],opts);
    if(receipt.ok && receipt.result?.dryRun===true) await this.store.validate(previewID,{mode:a.mode,sha256,assets,receipt});
    return {previewID,mode:a.mode,task,receipt,requiresUserConfirmation:true};
  }
}
function references(task) { return task?.meanings?.some(x=>x.id)||task?.entries?.some(x=>x.senses?.some(s=>s.id)); }
function sameScope(a,b) { return a && b && JSON.stringify(sort(a))===JSON.stringify(sort(b)); }
function sort(x) { return Object.fromEntries(Object.entries(x).sort(([a],[b])=>a.localeCompare(b))); }
