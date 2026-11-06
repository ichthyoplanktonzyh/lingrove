/** A structural guard for the additive entry point, not a semantic classifier.
 * Unknown edits fail closed. The app's revision guard closes the read/write race.
 */
export async function assessWrite(mode,task,run,options={}) {
  if(mode==='capture') return {requiresReview:false,reasons:[]};
  const reasons=[]; const created=new Set();
  for(const [index,operation] of (task.operations??[]).entries()) {
    const actions=Object.keys(operation);
    if(actions.length!==1) { reasons.push({operation:index,reason:'Expected exactly one action.'}); continue; }
    const action=actions[0];
    if(['add','append','capture'].includes(action)) continue;
    if(action!=='put') { reasons.push({operation:index,reason:'Replacement, deletion or unknown action requires review.'}); continue; }
    const {resource,value}=operation.put??{};
    if(['categoryOverrides','categoryParents','frameworks'].includes(resource)) {
      reasons.push({operation:index,resource,reason:'Catalog overrides/hierarchy and read-only resources require review.'}); continue;
    }
    const id=value?.id??(resource==='collections'?value?.senseID:undefined);
    if(!id || !resource) { reasons.push({operation:index,reason:'Resource identity is missing.'}); continue; }
    const key=resource+':'+id;
    // Even an edit to an earlier new record is a put/replace operation; a normal
    // caller should supply its final value once, rather than relying on ordering.
    if(created.has(key)) { reasons.push({operation:index,resource,id,reason:'Repeated put requires review.'}); continue; }
    const current=await run(['data','get',resource,id],options);
    if(current.ok) reasons.push({operation:index,resource,id,reason:'Target already exists; put may overwrite saved fields.'});
    else if(current.error?.code==='not_found') created.add(key);
    else throw new Error('Cannot establish whether resource exists; additive write refused. '+(current.error?.code??''));
  }
  return {requiresReview:reasons.length>0,reasons};
}
