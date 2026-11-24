import type { PortableMemoryV1 } from './portable-memory.js';
import { CompanionCardSchema } from './companion-inbox.js';
import { groundedTiming, followupDelivery } from '../main/memory/followup-timing.js';
import { canonicalJson,hash,type SyncRecord } from './mobile-json.js';
export function followupRecords(memory:PortableMemoryV1,now:string):SyncRecord[] {
  const groups=new Map<string,{source:PortableMemoryV1['sources'][number];followup:NonNullable<NonNullable<PortableMemoryV1['sources'][number]['analysis']>['followups']>[number]}>();
  const closed=new Set([...(memory.closedFollowupKeys??[]),...memory.sources.flatMap(s=>(s.analysis?.followups??[]).filter(f=>f.status==='resolved').map(f=>f.key))]);
  for(const source of memory.sources.slice().sort((a,b)=>a.updatedAt.localeCompare(b.updatedAt)))
    for(const followup of source.analysis?.followups??[])groups.set(followup.key,{source,followup});
  return [...groups].map(([key,{source,followup}])=>{
    const texts=[source.text,...source.answers.map(a=>a.answer)];
    const timing=groundedTiming(followup.timing,q=>texts.some(t=>t.includes(q)),source.updatedAt);
    const delivery=timing?followupDelivery(timing,source.updatedAt):null;
    const card=CompanionCardSchema.parse({schemaVersion:1,id:'followup_'+hash(key).slice(0,24),kind:'followup',
      title:followup.title,body:source.analysis!.summary || followup.title,question:followup.question,
      sourceIds:[source.id],nodeIds:[],basis:followup.quote,basisKey:key,fingerprint:hash(canonicalJson(followup)),
      notBefore:delivery?.notBefore??source.updatedAt,expiresAt:delivery?.expiresAt??new Date(followup.due_date+'T23:59:59.999Z').toISOString(),
      createdAt:source.updatedAt,deadlineId:null,withdrawn:closed.has(key),
      notification:null});
    const content=canonicalJson(canonicalJson(card));
    return {key:'note:companion/cards/'+card.id+'.md',kind:'note',content,hash:hash(content)};
  });
}
