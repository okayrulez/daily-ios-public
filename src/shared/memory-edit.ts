import {canonicalJson,hash} from './mobile-json.js';
import {z} from 'zod';
import {PortableMemorySchema} from './portable-memory.js';
import {applyAppActions} from './app-actions.js';
import {mobileAtlasRecords} from '../main/memory/mobile-atlas.js';
import {agendaRecord} from './mobile-agenda.js';
import {followupRecords} from './mobile-followups.js';
export function editMemory(value:unknown) {
 const args=z.object({memory:PortableMemorySchema,prior:PortableMemorySchema.optional(),
  nodeID:z.string().optional(),text:z.string().trim().min(1).max(2000).optional(),
  verdict:z.enum(['context','incorrect','no_longer']).optional(),now:z.iso.datetime({offset:true}),id:z.string().min(1),
  action:z.enum(['correct','rollback'])}).strict().parse(value);
 let next=args.memory;
 if(args.action==='correct') {
  if(!args.nodeID||!args.text||!args.verdict)throw Error('Missing correction');
  next=applyAppActions(next,[{tool:'map_correct',quote:args.text,id:args.nodeID,text:args.text,verdict:args.verdict}],
    [args.text],'user-correction',args.now,args.id).memory;
 }else {
  if(!args.prior)throw Error('Missing prior memory');
  next=args.prior;
 }
 next=PortableMemorySchema.parse({...next,revision:args.memory.revision+1});
 const cards=followupRecords(next,args.now);
 for(const old of followupRecords(args.memory,args.now))if(!cards.some(card=>card.key===old.key)) {
  // Serialize through the canonical helper below before crossing the bridge.
  const canonical=canonicalJson(canonicalJson({...JSON.parse(JSON.parse(old.content)),withdrawn:true}));
  cards.push({...old,content:canonical,hash:hash(canonical)});
 }

 return {memory:next,atlas:[agendaRecord(next.agenda??[]),...mobileAtlasRecords(next.graph,next)],cards};
}
