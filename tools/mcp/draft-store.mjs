/** Owns private transport artifacts, not notebook storage. Uploads are bounded,
 * retryable byte chunks. Validated drafts freeze JSON and image bytes together.
 */
import { mkdir, readFile, writeFile, open } from 'node:fs/promises';
import { randomUUID, createHash } from 'node:crypto';
import { join } from 'node:path';
import { z } from 'zod';

export const MAX_TASK_BYTES=32*1024*1024;
const uuid=z.string().uuid();
const hash=b=>createHash('sha256').update(b).digest('hex');
export class DraftStore {
  constructor(root) { this.root=root; this.queue=Promise.resolve(); }
  path(id,suffix) { uuid.parse(id); return join(this.root,id+suffix); }
  async init() { await mkdir(this.root,{recursive:true,mode:0o700}); }
  async save(id,suffix,value) {
    await this.init();
    await writeFile(this.path(id,suffix),JSON.stringify(value)+'\n',{mode:0o600,flag:'wx'});
  }
  async load(id,suffix) { return JSON.parse(await readFile(this.path(id,suffix),'utf8')); }
  // Serialize chunk mutations; a repeated offset must contain identical bytes.
  upload(a) {
    const next=this.queue.then(()=>this.uploadChunk(a));
    this.queue=next.catch(()=>{}); return next;
  }
  async uploadChunk({uploadID,kind,totalBytes,offset,dataBase64}) {
    await this.init();
    const bytes=Buffer.from(dataBase64,'base64');
    if(bytes.toString('base64')!==dataBase64 || !bytes.length || bytes.length>512*1024) throw new Error('Use canonical base64 chunks of 1–524288 bytes.');
    const limit=kind==='image'?16*1024*1024:MAX_TASK_BYTES;
    if(totalBytes>limit || offset+bytes.length>totalBytes) throw new Error('Upload exceeds its declared byte limit.');
    const id=uploadID??randomUUID();
    if(!uploadID) {
      if(offset!==0) throw new Error('New uploads start at offset 0.');
      await this.save(id,'.upload.json',{kind,totalBytes});
      await writeFile(this.path(id,'.upload'),Buffer.alloc(0),{mode:0o600,flag:'wx'});
    }
    const meta=await this.load(id,'.upload.json');
    if(meta.kind!==kind || meta.totalBytes!==totalBytes) throw new Error('Upload metadata cannot change.');
    const file=await open(this.path(id,'.upload'),'r+');
    let size;
    try {
      size=(await file.stat()).size;
      if(offset<size) {
        if(offset+bytes.length>size) throw new Error('Retry an unchanged chunk.');
        const saved=Buffer.alloc(bytes.length); await file.read(saved,0,saved.length,offset);
        if(!saved.equals(bytes)) throw new Error('Conflicting upload retry.');
      } else {
        if(offset!==size) throw new Error('Chunk offset must equal nextOffset.');
        let written=0;
        while(written<bytes.length) { const r=await file.write(bytes,written,bytes.length-written,offset+written); written+=r.bytesWritten; }
        await file.sync(); size+=bytes.length;
      }
    } finally { await file.close(); }
    return {uploadID:id,kind,totalBytes,nextOffset:size,complete:size===totalBytes};
  }
  async uploaded(id,kind) {
    const meta=await this.load(id,'.upload.json');
    const bytes=await readFile(this.path(id,'.upload'));
    if(meta.kind!==kind || bytes.length!==meta.totalBytes) throw new Error('Upload is incomplete or has the wrong kind.');
    return bytes;
  }
  async task(id) { return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await this.uploaded(id,'task'))); }
  async freezeImages(id,task) {
    const assets=[]; let count=0,total=0;
    for(const operation of task.operations??[]) for(const action of ['add','append']) {
      for(const block of operation[action]?.content??[]) {
        if(!block.image) continue;
        // MCP may reference only explicit staged images, never arbitrary host paths.
        const match=/^upload:([0-9a-f-]{36})$/i.exec(block.image.path??'');
        if(!match) throw new Error('Upload the user-selected image first; image.path must be upload:UUID. Local file paths are not accepted over MCP.');
        const bytes=await this.uploaded(match[1],'image');
        total+=bytes.length; count++;
        if(count>64 || total>16*1024*1024) throw new Error('CLI image batch limit exceeded.');
        const suffix='-image-'+count;
        const path=this.path(id,suffix);
        await writeFile(path,bytes,{mode:0o600,flag:'wx'});
        assets.push({suffix,sha256:hash(bytes)}); block.image.path=path;
      }
    }
    return assets;
  }
  async writeTask(id,task) {
    const bytes=Buffer.from(JSON.stringify(task,null,2)+'\n');
    if(bytes.length>MAX_TASK_BYTES) throw new Error('Task exceeds the CLI 32 MiB limit.');
    await writeFile(this.path(id,'.json'),bytes,{mode:0o600,flag:'wx'});
    return hash(bytes);
  }
  async validate(id,manifest) { await this.save(id,'.ready',manifest); }
  async validated(id) {
    const marker=await readFile(this.path(id,'.ready'),'utf8');
    // Preserve previews produced by the original capture-only adapter.
    const manifest=marker.trim()==='validated'?{mode:'capture',assets:[]}:JSON.parse(marker);
    if(!['capture','apply'].includes(manifest.mode)) throw new Error('Invalid preview operation.');
    const bytes=await readFile(this.path(id,'.json'));
    if(manifest.sha256 && hash(bytes)!==manifest.sha256) throw new Error('Preview material changed; commit refused.');
    for(const a of manifest.assets??[]) {
      if(!/^-image-[1-9][0-9]*$/.test(a.suffix)) throw new Error('Invalid image manifest.');
      if(hash(await readFile(this.path(id,a.suffix)))!==a.sha256) throw new Error('Preview image changed; commit refused.');
    }
    return {manifest,task:JSON.parse(bytes)};
  }
  async bound(result) {
    const text=JSON.stringify(result);
    if(Buffer.byteLength(text)<=512*1024) return result;
    const resultID=randomUUID();
    await this.save(resultID,'.result.json',result);
    return {ok:result.ok??result.receipt?.ok??true,resultID,totalCharacters:text.length,
      revision:result.result?.revision,notebookScope:result.result?.notebookScope,
      previewID:result.previewID,requiresUserConfirmation:result.requiresUserConfirmation,
      paged:true,message:'Full result preserved. Use notebook_result_read until nextOffset is null; do not infer omitted content.'};
  }
  async result({resultID,offset,limit}) {
    const text=JSON.stringify(await this.load(resultID,'.result.json'));
    const chunk=text.slice(offset,offset+limit);
    return {resultID,offset,totalCharacters:text.length,text:chunk,nextOffset:offset+chunk.length<text.length?offset+chunk.length:null};
  }
}
