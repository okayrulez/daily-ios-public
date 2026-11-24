import type {PortableMemoryV1} from './portable-memory.js';
import {nodeInMapCluster} from './map-clusters.js';
import {canonicalJson,hash} from './mobile-json.js';

export const mapQualityNodes=(memory:PortableMemoryV1,mapID:string)=>memory.graph.nodes.filter(n=>nodeInMapCluster(n,mapID));
export function mapQualityFingerprint(memory:PortableMemoryV1,mapID:string) {
  const nodes=mapQualityNodes(memory,mapID).sort((a,b)=>a.id.localeCompare(b.id)),ids=new Set(nodes.map(n=>n.id));
  return hash(canonicalJson({nodes,edges:memory.graph.edges.filter(e=>ids.has(e.source)||ids.has(e.target)).sort((a,b)=>a.id.localeCompare(b.id))}));
}
export function mapQualityProjection(memory:PortableMemoryV1,mapID:string) {
  const quality=memory.maps?.find(m=>m.id===mapID)?.quality;
  if(!quality)return undefined;
  const {fingerprint,...display}=quality;
  return {...display,current:fingerprint===mapQualityFingerprint(memory,mapID)};
}
