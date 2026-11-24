import type {PortableMemoryV1} from './portable-memory.js';
import {canonicalJson,hash} from './mobile-json.js';
import {mapCatalog} from './map-registry.js';
import {nodeMapId} from './map-clusters.js';
import {MapReviewReportSchema} from './map-metadata.js';
import {mapQualityNodes,mapQualityFingerprint} from './map-quality.js';

export const MAP_REVIEW_INTERVAL=5;
export function advanceMapReview(before:PortableMemoryV1,after:PortableMemoryV1,journalID:string):PortableMemoryV1 {
  const ids=before.sources.filter(s=>s.kind==='journal'&&s.status==='complete').map(s=>s.id);
  const state=before.mapReview??{journalIds:ids,lastAttemptCount:ids.length,status:'waiting' as const,reviewedFingerprints:{}};
  return {...after,mapReview:{...state,journalIds:[...new Set([...state.journalIds,journalID])]}};
}
export function mapReviewDue(memory:{mapReview?:Pick<NonNullable<PortableMemoryV1['mapReview']>,'journalIds'|'lastAttemptCount'>}) {
  const s=memory.mapReview;
  return !!s&&s.journalIds.length-s.lastAttemptCount>=MAP_REVIEW_INTERVAL;
}
export const nodeFingerprint=(node:PortableMemoryV1['graph']['nodes'][number])=>hash(canonicalJson(node));
export function failedMapReview(memory:PortableMemoryV1):PortableMemoryV1 {
  if(!mapReviewDue(memory))return memory;
  return {...memory,mapReview:{...memory.mapReview!,lastAttemptCount:memory.mapReview!.journalIds.length,status:'failed'}};
}
export function reviewContext(memory:PortableMemoryV1,selectedIDs:string[]) {
  const graph=memory.graph,ids=new Set(selectedIDs);
  const bounded=<T>(rows:T[],budget:number)=>{
    const result:T[]=[];
    for(const row of rows)if(canonicalJson([...result,row]).length<=budget)result.push(row);
    return result;
  };
  const catalog=mapCatalog(memory).map(m=>({id:m.id,title:m.title,aliases:m.aliases,description:m.description,
    nodeCount:graph.nodes.filter(n=>nodeMapId(n)===m.id).length}));
  return {scope:'Sınırlı değişen dal penceresi; tüm arşivin eksiksiz denetlendiğini iddia etme.',
    maps:bounded(catalog,6500),totalMaps:catalog.length,
    qualityScope:catalog.flatMap(m=>{const nodes=mapQualityNodes(memory,m.id),selectedNodeIDs=nodes.filter(n=>ids.has(n.id)).map(n=>n.id);
      return selectedNodeIDs.length?[{map_id:m.id,totalNodes:nodes.length,selectedNodeIDs}]:[];}),
    totalNodes:graph.nodes.length,totalEdges:graph.edges.length,
    selectedNodes:selectedIDs.length,omittedNodes:graph.nodes.length-selectedIDs.length,
    edges:bounded(graph.edges.filter(e=>ids.has(e.source)&&ids.has(e.target)).slice(0,100),6000),
    emotionalExperience:bounded(graph.nodes.filter(n=>ids.has(n.id)&&n.consumers?.includes('emotion')).map(n=>({
      nodeID:n.id,context:n.scope,sourceDays:[...new Set(n.evidence.map(e=>e.date))].slice(-4),
      hasUserCorrections:n.corrections.length>0,
    })),1800), // Full quoted evidence already travels with selectedNodes; do not duplicate it.
    previousReviewSummary:memory.mapReview?.report?.summary??null};
}
export function acceptMapReview(memory:PortableMemoryV1,report:unknown,selectedIDs:string[],basis:PortableMemoryV1=memory):PortableMemoryV1 {
  const parsed=MapReviewReportSchema.parse(report),catalog=mapCatalog(memory),maps=new Set(catalog.map(m=>m.id)),selected=new Set(selectedIDs);
  if(parsed.findings.some(f=>f.map_ids.some(id=>!maps.has(id))||f.node_ids.some(id=>!selected.has(id))))throw Error('Unknown map review reference');
  const assessed=new Set<string>();
  for(const assessment of parsed.assessments??[]) {
    const nodes=mapQualityNodes(basis,assessment.map_id),ids=new Set(nodes.map(n=>n.id));
    if(!maps.has(assessment.map_id)||assessed.has(assessment.map_id)||new Set(assessment.node_ids).size!==assessment.node_ids.length||
      assessment.node_ids.some(id=>!ids.has(id)||!selected.has(id)))throw Error('Unknown map quality reference');
    assessed.add(assessment.map_id);
    const {coverage,evidence,coherence,distinctness}=assessment.dimensions;
    catalog.find(m=>m.id===assessment.map_id)!.quality={dimensions:assessment.dimensions,rationale:assessment.rationale,
      strengths:assessment.strengths,gaps:assessment.gaps,percent:Math.round(coverage*.3+evidence*.3+coherence*.25+distinctness*.15),
      reviewedNodes:assessment.node_ids.length,totalNodes:nodes.length,scope:assessment.node_ids.length===nodes.length?'full':'partial',
      fingerprint:mapQualityFingerprint(basis,assessment.map_id),assessedAt:basis.sources.map(s=>s.updatedAt).sort().at(-1)??''};
  }
  if(!memory.mapReview)return memory;
  const fingerprints={...memory.mapReview.reviewedFingerprints};
  for(const node of memory.graph.nodes)if(selected.has(node.id))fingerprints[node.id]=nodeFingerprint(node);
  const existing=new Set(memory.graph.nodes.map(n=>n.id));
  for(const id of Object.keys(fingerprints))if(!existing.has(id))delete fingerprints[id];
  return {...memory,maps:catalog,mapReview:{...memory.mapReview,lastAttemptCount:memory.mapReview.journalIds.length,
    status:'complete',report:parsed,reviewedFingerprints:fingerprints,
    completedAt:memory.sources.map(s=>s.updatedAt).sort().at(-1)??''}};
}
