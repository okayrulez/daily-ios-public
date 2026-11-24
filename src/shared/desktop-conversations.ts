import {z} from 'zod';
import {PortableMemorySchema} from './portable-memory';
import {WritingSchema} from './living-memory';
import {canonicalJson} from './mobile-json';
import {applyGraphPreferences} from './app-actions';
import {emptyMemory} from './mobile-pipeline';
/** Explicit Codex import publishes conversations only, preserving the phone workspace. */
export function mergeDesktopConversations(value:unknown){
 const {memory,snapshot}=z.object({memory:PortableMemorySchema.nullable(),snapshot:z.object({writings:z.array(WritingSchema),graph:z.unknown()}).passthrough()}).parse(value);
 const original=memory??emptyMemory(),next=JSON.parse(canonicalJson(original)) as typeof original;
 const sources=snapshot.writings.filter(s=>s.kind==='conversation'&&s.importKey?.startsWith('codex_')||s.kind==='conversation_batch');
 if(!sources.length)return {memory:original,changed:false,count:0};
 const selected=new Set(sources.map(s=>s.id));
 for(const s of sources){const i=next.sources.findIndex(old=>old.id===s.id);if(i>=0){
  if(!['conversation','conversation_batch'].includes(next.sources[i].kind))throw Error('Conversation source identity conflict');
  if(next.sources[i].revision>s.revision)continue;next.sources[i]=s;
 }else next.sources.push(s);}
 const graph=PortableMemorySchema.shape.graph.parse(snapshot.graph);
 const incoming=graph.nodes.filter(n=>n.evidence.length&&n.evidence.every(e=>selected.has(e.sourceId)));
 for(const n of incoming){const i=next.graph.nodes.findIndex(old=>old.id===n.id);
  if(i>=0){const old=next.graph.nodes[i];if(old.evidence.some(e=>!selected.has(e.sourceId)))continue;
   const corrections=[...new Map([...n.corrections,...old.corrections].map(c=>[c.id,c])).values()];next.graph.nodes[i]={...n,corrections};
  }else next.graph.nodes.push(n);}
 // Skip cross-map conclusions with excluded personal journal roots.
 let changed=true;while(changed){const ids=new Set(next.graph.nodes.map(n=>n.id)),before=next.graph.nodes.length;
  next.graph.nodes=next.graph.nodes.filter(n=>[...(n.inference?.parentIds??[]),...(n.inference?.rootNodeIds??[])].every(id=>ids.has(id)));changed=before!==next.graph.nodes.length;}
 const ids=new Set(next.graph.nodes.map(n=>n.id));
 for(const e of graph.edges)if(incoming.some(n=>n.id===e.source)&&incoming.some(n=>n.id===e.target)&&ids.has(e.source)&&ids.has(e.target)&&!next.graph.edges.some(old=>old.id===e.id))next.graph.edges.push(e);
 next.graph.edges=next.graph.edges.filter(e=>ids.has(e.source)&&ids.has(e.target));
 const merged=PortableMemorySchema.parse(applyGraphPreferences(next));
 const contentChanged=canonicalJson(merged)!==canonicalJson(original);
 if(contentChanged)merged.revision=original.revision+1;
 return {memory:merged,changed:contentChanged,count:sources.length};
}
