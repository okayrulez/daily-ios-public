import { hash, utf8 } from '../../shared/mobile-json.js';
import type { MemoryGraph } from '../../shared/living-memory.js';
import { mapClusters, nodeInMapCluster } from '../../shared/map-clusters.js';
import { canonicalJson, type SyncRecord } from '../../shared/mobile-json.js';
import type {PortableMemoryV1} from '../../shared/portable-memory.js';
import {mapQualityProjection} from '../../shared/map-quality.js';
const prefix = 'note:companion/atlas/';
const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
function record(key: string, value: unknown): SyncRecord {
  const content = canonicalJson(canonicalJson(value));
  if (utf8(content).length > 700_000) throw Error('Telefon harita dizini aktarım sınırını aşıyor.');
  return { key: prefix + key + '.md', kind: 'note', content, hash: hash(content) };
}
/** A derived, read-only projection. Never serialize the graph or evidence wholesale. */
export function mobileAtlasRecords(graph: MemoryGraph, memory?:PortableMemoryV1): SyncRecord[] {
  const records: SyncRecord[] = [];
  const maps = mapClusters(graph).map(cluster => {
    const id = hash(cluster.id).slice(0, 32);
    const nodes = graph.nodes.filter(node => nodeInMapCluster(node, cluster.id)).sort((a,b) => compare(a.id,b.id)).map(node => {
      const evidence = [...node.evidence].sort((a,b) => compare(a.date,b.date)).at(-1);
      const correction = [...node.corrections].sort((a,b) => compare(a.createdAt,b.createdAt)).at(-1);
      return { id: node.id, label: node.label.slice(0,160), status: node.status,
        summary: (correction?.text ?? node.description ?? evidence?.observation ?? '').slice(0,600),
        topicPath: node.topicPath.slice(0,12).map(part => part.slice(0,160)),
        updatedAt: correction?.createdAt ?? evidence?.date ?? '' };
    });
    const ids = new Set(nodes.map(node => node.id));
    const edges = graph.edges.filter(edge => ids.has(edge.source) && ids.has(edge.target)).sort((a,b) => compare(a.id,b.id))
      .map(edge => ({ id: edge.id, source: edge.source, target: edge.target, relation: edge.relation.slice(0,160) }));
    const pages: Array<{key: string; hash: string}> = [];
    function chunk<T>(items: T[], kind: 'nodes'|'edges', size: number) {
      for (let offset = 0; offset < items.length; offset += size) {
        const item = record(id + '-' + kind + '-' + offset / size, { schemaVersion: 1, mapId: id, kind, items: items.slice(offset,offset+size) });
        records.push(item); pages.push({ key: item.key, hash: item.hash });
      }
    }
    chunk(nodes, 'nodes', 60); chunk(edges, 'edges', 160);
    // Separate optional pages keep v1 readers compatible and never truncate note history.
    const details: Array<{nodeId: string; kind: string; date: string; text: string; contentID:string; part:number}> = [];
    for (const node of graph.nodes.filter(node => ids.has(node.id)).sort((a,b) => compare(a.id,b.id))) {
      const values = [
        ...(node.description ? [{kind:'description',date:'',text:node.description}] : []),
        ...node.evidence.map(item => ({kind:item.nature,date:item.date,text:item.observation,quote:item.quote,sourceId:item.sourceId,sourceTitle:item.title,
          ...(item.sourceKind ? {sourceKind:item.sourceKind} : {})})),
        ...node.corrections.map(item => ({kind:'correction',date:item.createdAt,text:item.text})),
      ];
      for (const value of values) {
        const contentID=hash(canonicalJson({nodeId:node.id,...value}));
        const points = Array.from(value.text);
        for (let start=0; start<points.length; start+=4000) details.push({nodeId:node.id,...value,contentID,part:start/4000,text:points.slice(start,start+4000).join('')});
      }
    }
    const detailPages: Array<{key:string;hash:string}> = [];
    // At most 40 × 4000 Unicode characters, below the byte limit even for emoji.
    let batch: typeof details = [];
    const flush = () => {
      if (!batch.length) return;
      const page=record(id+'-notes-'+detailPages.length,{schemaVersion:1,mapId:id,kind:'notes',items:batch});
      records.push(page);detailPages.push({key:page.key,hash:page.hash});batch=[];
    };
    for (const detail of details) {
      if (batch.length >= 40 || utf8(canonicalJson(canonicalJson([...batch,detail]))).length > 600000) flush();
      batch.push(detail);
    }
    flush();
    const quality=memory?mapQualityProjection(memory,cluster.id):undefined;
    return { id, title: cluster.name.slice(0,160), nodeCount: nodes.length, edgeCount: edges.length,
      ...(quality?{quality}:{}),
      updatedAt: nodes.map(node => node.updatedAt).sort(compare).at(-1) ?? '', pages, detailPages };
  });
  // Publish the manifest last. It binds every page hash, so phones never mix revisions.
  records.push(record('index', { schemaVersion: 1, maps }));
  return records;
}
