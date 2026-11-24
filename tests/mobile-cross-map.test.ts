import { expect,it } from 'vitest';
import { emptyMemory } from '../src/shared/mobile-pipeline.js';
import { prepareCrossMap,prepareCrossMapRepair,applyCrossMap } from '../src/shared/mobile-cross-map.js';
import { invoke,invokeChecked } from '../src/shared/mobile-analysis-core.js';
import { PortableMemorySchema } from '../src/shared/portable-memory.js';
import { snapshot,analysis } from './fixtures.js';
import { followupRecords } from '../src/shared/mobile-followups.js';
import { refreshMapDescriptions } from '../src/shared/map-descriptions.js';
function memory(){
  const s=snapshot(),m=emptyMemory();m.sources=s.writings;
  m.graph={topics:[{id:'t1',path:['İş'],count:1,sourceCount:1},{id:'t2',path:['Ev'],count:1,sourceCount:1}],
    nodes:s.graph.nodes.map((n,i)=>({...n,id:'n'+i,topicId:'t'+(i+1),topicPath:[i?'Ev':'İş'],inference:undefined,
      status:'observation' as const,corrections:[]})),edges:[]};
  return PortableMemorySchema.parse(m);
}
const proposal={insights:[{topic_path:['Dinlenme biçimim'],key:'rest',label:'Molalar',observation:'İki bağlamda mola anlatıyor.',
  supports:[{node_id:'n0',source_id:'source-one'},{node_id:'n1',source_id:'source-two'}],replaces:[] as string[],change_reason:''}],retirements:[]};
it('supplies the exact cross-map schema including required label and forbidden extra fields',()=>{
  const request=prepareCrossMap(memory());
  const schema=JSON.parse(request.instructions.split('OUTPUT_JSON_SCHEMA=')[1]);
  const insight=schema.properties.insights.items;
  expect(insight.required).toContain('label');
  expect(insight.properties.label.type).toBe('string');
  expect(insight.additionalProperties).toBe(false);
  expect(schema.additionalProperties).toBe(false);
});
it('repairs the logged missing-label shape without relaxing validation or losing source context',()=>{
  const m=memory();
  const {label,...fields}=proposal.insights[0];
  const rejected=JSON.stringify({insights:[{...fields,title:label}],retirements:[]});
  expect(applyCrossMap(m,JSON.parse(rejected))).toEqual(applyCrossMap(m,proposal));
  const request=prepareCrossMapRepair(m,rejected);
  expect(request.input[0]).toEqual(prepareCrossMap(m).input[0]);
  expect(JSON.parse(request.input[1].content).rejected_output).toBe(rejected);
  const bridged=JSON.parse(invoke('prepareCrossMapRepair',JSON.stringify({memory:m,output:rejected})));
  expect(bridged).toEqual(request);
  expect(()=>applyCrossMap(m,proposal)).not.toThrow();
  const unsupported=structuredClone(proposal);unsupported.insights[0].supports[1].node_id='invented';
  expect(()=>applyCrossMap(m,unsupported)).toThrow();
});
it('eventually considers all notes in a large map while keeping retries stable',()=>{
  const m=memory(),base=m.graph.nodes;
  m.graph.nodes=Array.from({length:150},(_,i)=>({...base[i%2],id:'note-'+String(i).padStart(3,'0')}));
  const seen=new Set<string>();
  for(let revision=0;revision<8;revision++) {
    m.revision=revision;
    const prepared=prepareCrossMap(m);
    expect(prepared).toEqual(prepareCrossMap(m));
    expect(prepared.selectedIDs.length).toBeLessThanOrEqual(48);
    prepared.selectedIDs.forEach(id=>seen.add(id));
  }
  expect(seen.size).toBe(150);
});
it('requires independent sources and maps and keeps original ancestry',()=>{
  const m=memory();expect(prepareCrossMap(m).needed).toBe(true);
  const output=PortableMemorySchema.parse(applyCrossMap(m,proposal)),derived=output.graph.nodes.find(n=>n.inference)!;
  expect(derived.inference?.parentIds).toEqual(['n0','n1']);
  expect(derived.evidence.every(e=>e.nature==='inference')).toBe(true);
  const duplicate=structuredClone(proposal);duplicate.insights[0].supports[1]={node_id:'n0',source_id:'source-one'};
  expect(()=>applyCrossMap(m,duplicate)).toThrow(/independent/);
  expect(()=>applyCrossMap(m,{insights:[],retirements:[{node_id:'n0',reason:'remove'}]})).toThrow(/original/);
});
it('commits review insights with the refreshed map catalog and ancestry',()=>{
  const before=refreshMapDescriptions(memory());
  before.mapReview={journalIds:['a','b','c','d','e'],lastAttemptCount:0,status:'waiting',reviewedFingerprints:{}};
  const result={...proposal,map_review:{summary:'İş ve ev notları incelendi.',findings:[]}};
  const applied=JSON.parse(invoke('applyMapReview',JSON.stringify({memory:before,result})));
  const derived=applied.memory.graph.nodes.find((node:typeof before.graph.nodes[number])=>node.inference);
  expect(derived.inference.parentIds).toEqual(['n0','n1']);
  const workMap=before.maps!.find(map=>map.title==='İş')!;
  const nextWorkMap=applied.memory.maps.find((map:typeof workMap)=>map.id===workMap.id);
  expect(nextWorkMap.descriptionFingerprint).not.toEqual(workMap.descriptionFingerprint);
});
it('keeps user labels and removed edges when a review updates an existing inference',()=>{
  const before=applyCrossMap(memory(),proposal),derived=before.graph.nodes.find(node=>node.inference)!;
  const removedEdge=before.graph.edges.find(edge=>edge.source===derived.id)!;
  derived.label='Kendi verdiğim başlık';
  before.graph.edges=before.graph.edges.filter(edge=>edge.id!==removedEdge.id);
  before.graphPreferences={nodes:{[derived.id]:{label:derived.label}},removedEdges:[removedEdge.id],edges:[]};
  before.mapReview={journalIds:['a','b','c','d','e'],lastAttemptCount:0,status:'waiting',reviewedFingerprints:{}};
  const result={...proposal,map_review:{summary:'Bağlar gözden geçirildi.',findings:[]}};
  const {memory:after}=JSON.parse(invoke('applyMapReview',JSON.stringify({memory:before,result})));
  expect(after.graph.nodes).toContainEqual(expect.objectContaining({id:derived.id,label:'Kendi verdiğim başlık'}));
  expect(after.graph.edges).not.toContainEqual(expect.objectContaining({id:removedEdge.id}));
});
it('keeps resolved followups closed and never reschedules unchanged evidence',()=>{
  const m=memory();m.sources[0].analysis=analysis().living_memory as any;
  m.sources[0].analysis!.followups=[{key:'walk',title:'Yürüyüş',question:'Nasıldı?',quote:'Bugün yürüdüm.',
    due_date:'2026-10-01',status:'open',timing:{not_before:'2026-10-01T09:00:00Z',expires_at:'2026-10-01T12:00:00Z',
      reason:'Yürüyüş sonrası',quote:'Bugün yürüdüm.',basis:'inferred',intent:'check_in',event_at:null}}];
  const a=followupRecords(m,'2026-09-30T10:00:00Z'),b=followupRecords(m,'2026-10-01T10:00:00Z');
  expect(a).toEqual(b);
  m.closedFollowupKeys=['walk'];
  expect(JSON.parse(JSON.parse(followupRecords(m,'2026-09-30T10:00:00Z')[0].content)).withdrawn).toBe(true);
});

it('normalizes fenced JSON and label aliases but rejects conflicting labels',()=>{
  const m=memory(),aliased=structuredClone(proposal) as any;
  aliased.insights[0].title=aliased.insights[0].label;delete aliased.insights[0].label;
  const result=JSON.parse(invoke('validateCrossMap',JSON.stringify({memory:m,result:'```json\n'+JSON.stringify(aliased)+'\n```'})));
  expect(result).toEqual(proposal);
  aliased.insights[0].label='Different';
  expect(()=>applyCrossMap(m,aliased)).toThrow();
});
it('distinguishes missing reasons from self replacement and sends repair guidance',()=>{
  const m=applyCrossMap(memory(),proposal),node=m.graph.nodes.find(n=>n.inference)!;
  const self=structuredClone(proposal);self.insights[0].replaces=[node.id];
  const check=(result:unknown)=>JSON.parse(invokeChecked('validateCrossMap',JSON.stringify({memory:m,result})));
  expect(check(self).error.code).toBe('self_replacement');
  const replacement=structuredClone(self);replacement.insights[0].key='new-rest';
  expect(check(replacement).error.code).toBe('missing_reorganization_reason');
  const repair=prepareCrossMapRepair(m,JSON.stringify(replacement),'missing_reorganization_reason');
  expect(JSON.parse(repair.input[1].content).validation_error).toBe('missing_reorganization_reason');
  expect(m.graph.nodes.find(n=>n.id===node.id)?.status).not.toBe('retracted');
});
