import type {PortableMemoryV1} from './portable-memory.js';
import type {LivingAnalysis} from './living-memory.js';
import {mapClusterName,nodeMapId} from './map-clusters.js';
import {hash} from './mobile-json.js';

const normalize=(s:string)=>s.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/\s+/g,' ').trim();
export function mapCatalog(memory:PortableMemoryV1) {
  const catalog=(memory.maps??[]).map(m=>({...m,aliases:[...m.aliases]}));
  for(const node of memory.graph.nodes) {
    if(node.inference)continue;
    const id=nodeMapId(node),name=mapClusterName(node.topicPath);
    const found=catalog.find(m=>m.id===id);
    if(!found)catalog.push({id,title:name,aliases:[]});
    else if(normalize(found.title)!==normalize(name)&&!found.aliases.some(a=>normalize(a)===normalize(name)))found.aliases.push(name);
  }
  return catalog;
}
export function oldNoteId(note:LivingAnalysis['notes'][number]) {
  return hash(JSON.stringify([note.topic_path.map(normalize),normalize(note.key),normalize(note.scope)])).slice(0,24);
}

/** Resolve model proposals against real IDs. A title never becomes an identity. */
export function placeNotes(memory:PortableMemoryV1,living:LivingAnalysis,jobID:string) {
  const maps=mapCatalog(memory);
  for(const [index,note] of living.notes.entries()) {
    const previous=note.existing_node_id ? memory.graph.nodes.find(n=>n.id===note.existing_node_id&&!n.inference) : undefined;
    if(note.existing_node_id&&!previous)throw Error('Unknown map placement target');
    const title=mapClusterName(note.topic_path);
    let map=note.target_map_id ? maps.find(m=>m.id===note.target_map_id) : undefined;
    if(note.target_map_id&&!map)throw Error('Unknown map placement target');
    // Ambiguous aliases must not merge maps silently.
    if(!map) {
      const matches=maps.filter(m=>[m.title,...m.aliases].some(a=>normalize(a)===normalize(title)));
      if(matches.length===1)map=matches[0];
      else if(previous)map=maps.find(m=>m.id===nodeMapId(previous));
    }
    if(!map) {
      map={id:'map:'+hash(jobID+':'+index).slice(0,24),title,aliases:[]};maps.push(map);
    }
    if(note.target_map_id && normalize(title)!==normalize(map.title)
      && !maps.some(m=>m.id!==map!.id&&[m.title,...m.aliases].some(a=>normalize(a)===normalize(title)))
      && !map.aliases.some(a=>normalize(a)===normalize(title)) && map.aliases.length<30)map.aliases.push(title);
    note.target_map_id=map.id;
    const offset=mapClusterName(note.topic_path)===note.topic_path[1]?1:0;
    note.topic_path=[map.title,...note.topic_path.slice(offset+1)];
    // Old models can omit placement fields: preserve an unambiguous prior identity.
    if(!note.existing_node_id) {
      const matches=memory.graph.nodes.filter(n=>!n.inference&&nodeMapId(n)===map!.id&&normalize(n.key)===normalize(note.key)&&normalize(n.scope)===normalize(note.scope));
      if(matches.length===1)note.existing_node_id=matches[0].id;
    }
  }
  return maps;
}

/** Annotate archived analyses once so rebuilding cannot rename their node IDs. */
export function stabilizeSources(memory:PortableMemoryV1) {
  return memory.sources.map(source=>({...source,analysis:source.analysis?{...source.analysis,notes:source.analysis.notes.map(note=>{
    const id=note.existing_node_id??oldNoteId(note);
    const originalIDs=new Set(source.kind==='conversation_batch'?(source.sourceRefs??[]).map(r=>r.id):[source.id]);
    const node=memory.graph.nodes.find(n=>n.id===id&&n.evidence.some(e=>originalIDs.has(e.sourceId)&&normalize(e.quote)===normalize(note.quote)));
    if(node)return {...note,existing_node_id:node.id,target_map_id:nodeMapId(node)};
    const {existing_node_id:_unbound,target_map_id:_unmapped,...unbound}=note;
    return unbound;
  })}:null}));
}
