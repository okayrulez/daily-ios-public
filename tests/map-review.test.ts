import {describe,it,expect} from 'vitest';
import {applyAnalysis,emptyMemory,selectContext} from '../src/shared/mobile-pipeline.js';
import {canonicalJson,hash} from '../src/shared/mobile-json.js';
import {mapReviewDue,failedMapReview} from '../src/shared/map-review.js';
import {prepareCrossMap,applyCrossMap} from '../src/shared/mobile-cross-map.js';
import {placeNotes,mapCatalog} from '../src/shared/map-registry.js';
import {PortableMemorySchema,type PortableMemoryV1} from '../src/shared/portable-memory.js';
import {invoke} from '../src/shared/mobile-analysis-core.js';
import {analysis} from './fixtures.js';

function add(memory:PortableMemoryV1,id:string) {
  const raw='Bugün yürüdüm.';
  const journal={entry:{id,local_date:'2026-11-02',raw_text:raw,content_hash:hash(raw),saved_at:'2026-11-02T10:00:00Z',analysis_status:'pending',analysis_error:null},analyses:[],questions:[]};
  return applyAnalysis({memory,journal,result:analysis(),expectedMemoryHash:hash(canonicalJson(memory)),
    expectedSourceHash:hash(canonicalJson(journal)),jobID:hash(id),model:'fixture',now:'2026-11-02T11:00:00Z'}).memory;
}
function five() { let memory=emptyMemory();for(let i=0;i<5;i++)memory=add(memory,'entry-'+i);return memory; }
const report={summary:'Seçili dallar değerlendirildi.',findings:[]};
const reviewCommand=(command:string,value:unknown)=>JSON.parse(invoke(command,JSON.stringify(value)));

describe('standalone map review commit',()=>{
  it('reports due status from journal counts, including legacy memory without review state',()=>{
    expect(reviewCommand('mapReviewDue',emptyMemory())).toBe(false);
    expect(reviewCommand('mapReviewDue',add(emptyMemory(),'first'))).toBe(false);
    expect(reviewCommand('mapReviewDue',five())).toBe(true);
  });

  it('commits a validated report and atlas quality in one new memory revision',()=>{
    const memory=five(),node=memory.graph.nodes[0],map=mapCatalog(memory)[0];
    memory.closedFollowupKeys=['already-answered'];
    const assessment={map_id:map.id,node_ids:[node.id],dimensions:{coverage:80,evidence:90,coherence:70,distinctness:60},
      rationale:'Seçili notun kaynağı doğrulandı.',strengths:[],gaps:[]};
    const result={insights:[],map_review:{...report,assessments:[assessment]}};
    const applied=reviewCommand('applyMapReview',{memory,result:'```json\n'+JSON.stringify(result)+'\n```'});
    const {revision,mapReview,maps,...preserved}=applied.memory;
    const {revision:beforeRevision,mapReview:beforeReview,maps:beforeMaps,...original}=memory;
    expect(revision).toBe(beforeRevision+1);
    expect(preserved).toEqual(original);
    expect(mapReview).toMatchObject({status:'complete',lastAttemptCount:5,report:result.map_review});
    expect(reviewCommand('mapReviewDue',applied.memory)).toBe(false);
    expect(applied.atlas.every((record:{key:string})=>record.key.startsWith('note:companion/atlas/'))).toBe(true);
    const index=JSON.parse(JSON.parse(applied.atlas.at(-1).content));
    expect(index.maps[0].quality).toMatchObject({percent:78,current:true});
    expect(applied.cards).toEqual([]);
  });

  it('records a failed attempt while retaining the previous report and all journal memory',()=>{
    const memory=five(),prior=memory.mapReview!;
    memory.mapReview={...prior,status:'complete',report,completedAt:'2026-11-01T11:00:00Z'};
    const applied=reviewCommand('applyMapReview',{memory,result:null});
    expect(applied.memory).toEqual({...memory,revision:memory.revision+1,
      mapReview:{...memory.mapReview,status:'failed',lastAttemptCount:5}});
    expect(reviewCommand('mapReviewDue',applied.memory)).toBe(false);
    expect(applied.atlas).toEqual([]);
  });

  it('rejects premature attempts and invalid results without marking a failure',()=>{
    for(const result of [null,{insights:[],map_review:report}]) {
      expect(()=>reviewCommand('applyMapReview',{memory:emptyMemory(),result})).toThrow('Map review not due');
    }
    const memory=five();
    expect(()=>reviewCommand('applyMapReview',{memory})).toThrow();
    expect(()=>reviewCommand('applyMapReview',{memory,result:{insights:[]}})).toThrow('Missing map review report');
    const finding={kind:'misplaced',map_ids:['invented'],node_ids:[],explanation:'Test',recommendation:'Test'};
    expect(()=>reviewCommand('applyMapReview',{memory,result:{insights:[],map_review:{...report,findings:[finding]}}}))
      .toThrow('Unknown map review reference');
  });
});

describe('five distinct journals and functional map review',()=>{
  it('runs after five journals even in one map; answers/reanalysis and restarts cannot increment it',()=>{
    let m=emptyMemory();
    for(let i=0;i<4;i++) {m=add(m,'entry-'+i);expect(mapReviewDue(m)).toBe(false);}
    m=add(m,'entry-0');expect(m.mapReview?.journalIds).toHaveLength(4);
    m=add(PortableMemorySchema.parse(JSON.parse(canonicalJson(m))),'entry-4');
    expect(mapReviewDue(m)).toBe(true);expect(prepareCrossMap(m,true).needed).toBe(true);
    const reviewed=applyCrossMap(m,{insights:[],map_review:report});
    expect(reviewed.mapReview).toMatchObject({status:'complete',lastAttemptCount:5,report});
    expect(mapReviewDue(add(reviewed,'entry-4'))).toBe(false);
    let next=reviewed;for(let i=5;i<10;i++)next=add(next,'entry-'+i);
    expect(mapReviewDue(next)).toBe(true);
  });
  it('baselines existing journals on migration rather than charging for old history',()=>{
    const m=five();delete m.mapReview;
    const next=add(m,'new-entry');expect(mapReviewDue(next)).toBe(false);
    expect(next.mapReview?.lastAttemptCount).toBe(5);
    expect(next.mapReview?.journalIds).toHaveLength(6);
  });
  it('records a failed secondary attempt and retains the primary analysis without retry loops',()=>{
    const m=five(),failed=failedMapReview(m);
    expect(failed.sources).toEqual(m.sources);expect(failed.graph).toEqual(m.graph);
    expect(failed.mapReview?.status).toBe('failed');expect(mapReviewDue(add(failed,'entry-4'))).toBe(false);
    let next=failed;for(let i=5;i<10;i++)next=add(next,'entry-'+i);
    expect(mapReviewDue(next)).toBe(true);
  });
  it('requires the report and rejects invented map/node references',()=>{
    const m=five();
    expect(()=>applyCrossMap(m,{insights:[]})).toThrow('Missing map review report');
    const finding={kind:'misplaced',map_ids:['invented'],node_ids:[],explanation:'Test',recommendation:'Test'};
    expect(()=>applyCrossMap(m,{insights:[],map_review:{...report,findings:[finding]}})).toThrow('Unknown map review reference');
    expect(()=>applyCrossMap(m,{insights:[],map_review:{...report,findings:[{...finding,map_ids:[],node_ids:['invented']}]}})).toThrow();
  });
  it('keeps placement stable through alternate titles and rejects fabricated targets',()=>{
    const m=add(emptyMemory(),'one'),first=m.graph.nodes[0],map=mapCatalog(m)[0];
    const living=analysis().living_memory as NonNullable<PortableMemoryV1['sources'][number]['analysis']>;
    living.notes[0]={...living.notes[0],topic_path:['Enerji'],target_map_id:map.id,existing_node_id:first.id};
    const maps=placeNotes(m,living,hash('two'));
    expect(living.notes[0].target_map_id).toBe(map.id);expect(living.notes[0].existing_node_id).toBe(first.id);
    expect(maps[0].aliases).toContain('Enerji');
    m.maps=maps;living.notes[0]={...living.notes[0],topic_path:['Enerji'],target_map_id:undefined,existing_node_id:undefined};
    expect(placeNotes(m,living,hash('three'))).toHaveLength(1);
    living.notes[0].existing_node_id='unknown';expect(()=>placeNotes(m,living,hash('four'))).toThrow('Unknown map placement target');
  });
  it('uses answers to retrieve relevant health evidence without adding it to unrelated writing',()=>{
    const m=add(emptyMemory(),'one');m.graph.nodes[0].consumers=['health'];m.graph.nodes[0].label='Spor yürüyüş';
    const raw='Bugün düşündüm.';
    const journal={entry:{id:'two',local_date:'2026-11-02',raw_text:raw,content_hash:hash(raw),saved_at:'2026-11-02T10:00:00Z',analysis_status:'pending',analysis_error:null},analyses:[],questions:[]};
    expect(JSON.parse(selectContext(m,journal)).existingGraphNotNewEvidence).toHaveLength(0);
    const answered={...journal,supplemental_answers:[{id:'a',question:'Ne yapmak istiyorsun?',answer:'Spor yürüyüş'}]};
    expect(JSON.parse(selectContext(m,answered)).existingGraphNotNewEvidence.map((n:{id:string})=>n.id)).toContain(m.graph.nodes[0].id);
  });
  it('prioritizes changed branches in bounded review windows and does not claim unseen ones were checked',()=>{
    const m=five(),node=m.graph.nodes[0];
    m.graph.nodes=Array.from({length:150},(_,i)=>({...node,id:'node-'+String(i).padStart(3,'0')}));
    m.graph.edges=[];
    const first=prepareCrossMap(m,true);expect(first.selectedIDs.length).toBeGreaterThan(0);expect(first.selectedIDs.length).toBeLessThanOrEqual(32);
    expect(canonicalJson(first).length).toBeLessThan(60000);
    const reviewed=applyCrossMap(m,{insights:[],map_review:report});
    expect(Object.keys(reviewed.mapReview!.reviewedFingerprints)).toHaveLength(first.selectedIDs.length);
    expect(prepareCrossMap(reviewed,true).selectedIDs.some(id=>!first.selectedIDs.includes(id))).toBe(true);
  });
});
