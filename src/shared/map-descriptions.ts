import type {PortableMemoryV1} from './portable-memory.js';
import type {z} from 'zod';
import type {MapSummaryProposals} from './map-metadata.js';
import {mapCatalog} from './map-registry.js';
import {nodeMapId} from './map-clusters.js';
import {canonicalJson,hash} from './mobile-json.js';
import {brief} from './compact-context.js';
import {mergeMapSummaryProposals} from './map-metadata.js';

const normalized=(s:string)=>s.normalize('NFKC').toLocaleLowerCase('tr').replace(/\s+/g,' ').trim();
export const descriptionNodes=(memory:PortableMemoryV1,id:string)=>memory.graph.nodes.filter(n=>nodeMapId(n)===id&&
  !n.inference&&n.status!=='retracted'&&!n.corrections.some(c=>c.verdict==='incorrect'||c.verdict==='no_longer'));
export function mapDescriptionFingerprint(memory:PortableMemoryV1,id:string,title:string) {
  const nodes=memory.graph.nodes.filter(n=>nodeMapId(n)===id&&!n.inference).sort((a,b)=>a.id.localeCompare(b.id));
  const ids=new Set(nodes.map(n=>n.id));
  return hash(canonicalJson({title,nodes,edges:memory.graph.edges.filter(e=>ids.has(e.source)||ids.has(e.target))
    .sort((a,b)=>a.id.localeCompare(b.id))}));
}

/** Called on writes: reuse unchanged summaries, refresh changed maps, never call AI here. */
export function refreshMapDescriptions(memory:PortableMemoryV1,proposals:z.infer<typeof MapSummaryProposals>=[],
                                      changedFrom?:PortableMemoryV1):PortableMemoryV1 {
  const catalog=mapCatalog(memory);
  const previousCatalog=changedFrom?mapCatalog(changedFrom):[];
  const maps=catalog.map(map=>{
    const fingerprint=mapDescriptionFingerprint(memory,map.id,map.title);
    const original=previousCatalog.find(m=>m.id===map.id);
    const unchanged=map.description&&map.descriptionFingerprint===fingerprint;
    // A later commit stage may have already built the local fallback for this graph.
    const changed=changedFrom ? !original||mapDescriptionFingerprint(changedFrom,map.id,original.title)!==fingerprint : !unchanged;
    if(unchanged&&!changed)return map;
    const eligible=descriptionNodes(memory,map.id);
    const proposed=changed&&eligible.length ? proposals.filter(p=>p.map_id ? p.map_id===map.id :
      [map.title,...map.aliases].some(t=>normalized(t)===normalized(p.title))&&
      catalog.filter(m=>[m.title,...m.aliases].some(t=>normalized(t)===normalized(p.title))).length===1) : [];
    const summary=mergeMapSummaryProposals(proposed.map(p=>({...p,map_id:map.id})))[0]?.summary;
    if(unchanged&&!summary)return map;
    const details=[...new Set(eligible.map(n=>brief(n.description||n.evidence.at(-1)?.observation||n.label,160)))].slice(0,3);
    return {...map,description:summary??brief(map.title+': '+(details.join('; ')||'Etkin gözlem bulunmuyor.'),500),
      descriptionFingerprint:fingerprint,descriptionSource:summary?'analysis' as const:'local' as const};
  });
  return {...memory,maps};
}
