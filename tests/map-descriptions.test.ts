import {describe,it,expect} from 'vitest';
import {refreshMapDescriptions} from '../src/shared/map-descriptions.js';
import {PortableMemorySchema} from '../src/shared/portable-memory.js';
import {exportPortableMemory} from '../src/main/memory/portable-memory-export.js';
import {applyAnalysis,ApplyInput,selectContext,emptyMemory} from '../src/shared/mobile-pipeline.js';
import {applyAppActions} from '../src/shared/app-actions.js';
import {canonicalJson,hash} from '../src/shared/mobile-json.js';
import {analysis,snapshot} from './fixtures.js';
import {MapSummaryProposals} from '../src/shared/map-metadata.js';
import {mergeJournalParts} from '../src/shared/journal-parts.js';

const proposals=[{title:'Dinlenme',summary:'Dinlenmenin günlük üretim ve rahatlama deneyimleriyle ilişkisi.'}];
const journal={entry:{id:'journal-description',local_date:'2026-11-12',raw_text:'Bugün yürüdüm.',
  content_hash:hash('Bugün yürüdüm.'),saved_at:'2026-11-12T08:00:00Z',analysis_status:'pending',analysis_error:null},
  analyses:[],questions:[]};
describe('persisted map descriptions',()=>{
  it('accepts empty new-map IDs and preserves summaries from all long-journal segments',()=>{
    expect(()=>MapSummaryProposals.parse([{...proposals[0],map_id:''}])).not.toThrow();
    const parts=[['Dinlenme','Dinlenme koşulları.'],['Çalışma','Üretim alışkanlıkları.'],['Dinlenme','Akşam rahatlama deneyimleri.']]
      .map(([title,summary])=>{const result=analysis();return {rawText:journal.entry.raw_text,
        result:{...result,living_memory:{...result.living_memory,map_summaries:[{title,summary}]}}};});
    const combined=mergeJournalParts({parts,answers:[]}).living_memory!.map_summaries!;
    expect(combined).toHaveLength(2);
    expect(combined.find(s=>s.title==='Çalışma')!.summary).toContain('Üretim alışkanlıkları.');
    expect(combined.find(s=>s.title==='Dinlenme')!.summary).toContain('Dinlenme koşulları.');
    expect(combined.find(s=>s.title==='Dinlenme')!.summary).toContain('Akşam rahatlama deneyimleri.');
  });
  it('stores a model description in the normal journal commit and uses it next time',()=>{
    const memory=emptyMemory(),result=analysis();
    const output=applyAnalysis(ApplyInput.parse({memory,journal,result:{...result,living_memory:{...result.living_memory,
      map_summaries:proposals}},expectedSourceHash:hash(canonicalJson(journal)),expectedMemoryHash:hash(canonicalJson(memory)),
      jobID:hash('descriptions'),model:'fixture',now:'2026-11-12T09:00:00Z'}));
    const saved=PortableMemorySchema.parse(output.memory).maps!.find(m=>m.title==='Dinlenme')!;
    expect(saved.description).toBe(proposals[0].summary);
    expect(saved.descriptionSource).toBe('analysis');
    expect(saved.descriptionFingerprint).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.parse(selectContext(output.memory,journal)).mapSummaries.find((m:any)=>m.id===saved.id).summary).toBe(saved.description);
  });
  it('reuses unchanged descriptions and updates only maps whose contents changed',()=>{
    const memory=exportPortableMemory(snapshot(),1);
    memory.graph.nodes[0].corrections=[];memory.graph.nodes[0].status='candidate';
    const first=refreshMapDescriptions(memory,proposals);
    first.maps!.push({id:'map:untouched',title:'Diğer alan',aliases:[],description:'Değişmeyen açıklama',
      descriptionSource:'local',descriptionFingerprint:hash(canonicalJson({title:'Diğer alan',nodes:[],edges:[]}))});
    const same=refreshMapDescriptions(first,[{...proposals[0],summary:'SHOULD_NOT_REPLACE_UNCHANGED'}]);
    expect(same.maps).toEqual(first.maps);
    const changed=structuredClone(first);
    changed.graph.nodes[0].description='Yeni gözlem';
    const next=refreshMapDescriptions(changed,[{...proposals[0],summary:'Güncellenmiş kapsam.'}]);
    expect(next.maps![0].description).toBe('Güncellenmiş kapsam.');
    expect(next.maps![0].descriptionFingerprint).not.toBe(first.maps![0].descriptionFingerprint);
    expect(next.maps!.find(m=>m.id==='map:untouched')).toEqual(first.maps!.find(m=>m.id==='map:untouched'));
  });
  it('invalidates stale summaries after retraction instead of repeating rejected observations',()=>{
    const memory=exportPortableMemory(snapshot(),1);
    memory.graph.nodes[0].corrections=[];memory.graph.nodes[0].status='candidate';
    const first=refreshMapDescriptions(memory,[{title:'Dinlenme',summary:'OLD_REJECTED_DESCRIPTION'}]);
    const next=applyAppActions(first,[{tool:'map_retract',id:'node-one',quote:journal.entry.raw_text}],
      [journal.entry.raw_text],journal.entry.id,'2026-11-12T09:00:00Z','retract').memory;
    expect(next.maps![0].description).not.toContain('OLD_REJECTED_DESCRIPTION');
    expect(next.maps![0].descriptionSource).toBe('local');
  });
  it('migrates legacy maps locally without modifying source evidence',()=>{
    const memory=exportPortableMemory(snapshot(),1),before=canonicalJson(memory.sources);
    const next=refreshMapDescriptions(memory);
    expect(next.maps![0].description).toBeTruthy();
    expect(next.maps![0].descriptionSource).toBe('local');
    expect(canonicalJson(next.sources)).toBe(before);
    expect(refreshMapDescriptions(next).maps).toEqual(next.maps);
    const unrelated=refreshMapDescriptions(memory,proposals,memory);
    expect(unrelated.maps![0].descriptionSource).toBe('local');
  });
  it('does not leak a sensitive whole-map description into an unrelated reflection',()=>{
    const memory=exportPortableMemory(snapshot(),1);
    memory.graph.nodes[0].corrections=[];memory.graph.nodes[0].status='candidate';
    memory.graph.nodes[0].consumers=['health'];
    const next=refreshMapDescriptions(memory,[{title:'Dinlenme',summary:'PRIVATE_HEALTH_DETAIL'}]);
    const unrelated={...journal,entry:{...journal.entry,raw_text:'Yeni yazılım projemi değerlendir.'}};
    expect(selectContext(next,unrelated)).not.toContain('PRIVATE_HEALTH_DETAIL');
  });
});
