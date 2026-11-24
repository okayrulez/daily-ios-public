import { describe, expect, it } from 'vitest';
import {emotionObservationID,correctedEmotionObservations,EmotionalMemorySchema} from '../src/shared/emotional-memory.js';
import {mergeJournalParts} from '../src/shared/journal-parts.js';
import { analysis, snapshot } from './fixtures.js';
import { validateAnalysis, applyAnalysis, ApplyInput, emptyMemory, selectContext } from '../src/shared/mobile-pipeline.js';
import { canonicalJson, hash } from '../src/shared/mobile-json.js';
import { exportMindmapContext } from '../src/shared/mindmap-context-export.js';
import { exportPortableMemory } from '../src/main/memory/portable-memory-export.js';
import { invoke } from '../src/shared/mobile-analysis-core.js';
import { followupRecords } from '../src/shared/mobile-followups.js';

const raw = 'Bugün yürüdüm. Önce gerildim, sonra rahatladım.';
const emotional = {
  observations: [
    { key: 'tension', label: 'Gerilim', intensity: 4, event: 'Yürüyüş öncesi', quote: 'Önce gerildim', sequence: 0 },
    { key: 'calm', label: 'Huzur', intensity: 3, event: 'Yürüyüş sonrası', quote: 'sonra rahatladım', sequence: 1 },
  ],
  helpful: [{ action: 'Yürüyüş', quote: 'Bugün yürüdüm.' }],
};
function input() {
  const memory = emptyMemory();
  const journal = {
    entry: { id: 'journal-one', local_date: '2026-11-06', raw_text: raw, content_hash: hash(raw),
      saved_at: '2026-11-06T10:00:00Z', analysis_status: 'pending', analysis_error: null },
    analyses: [], questions: [], journal_stickers: ['🌊'], journal_media: [{id:'photo',data:'fixture'}],
  };
  return ApplyInput.parse({ memory, journal, result: {...analysis(), emotional_memory: emotional},
    expectedMemoryHash: hash(canonicalJson(memory)), expectedSourceHash: hash(canonicalJson(journal)),
    jobID: hash('emotion-job'), model: 'fixture', now: '2026-11-06T10:01:00Z' });
}
describe('source-grounded automatic emotional memory', () => {
  it('keeps unsupported intensity unknown and requests contextual event ordering in the normal prompt',()=>{
    const unknown={...emotional,observations:emotional.observations.map(o=>({...o,intensity:null,context_key:'walking',
      context_label:'Yürüyüş',kind:'emotion' as const,order_basis:'unknown' as const}))};
    const result=validateAnalysis(raw,{...analysis(),emotions:undefined,emotional_memory:unknown});
    expect(result.emotions).toEqual([]);
    expect(result.emotional_memory?.observations[0].intensity).toBeNull();
    const prompt=invoke('prepareJournal',JSON.stringify({journalId:'j',localDate:'2026-11-06',rawText:raw,workContext:''}));
    expect(prompt).toContain('context_key');expect(prompt).toContain('order_basis');expect(prompt).toContain('energy');
  });
  it('corrects just the chosen observation, retaining the other event and the AI source unchanged',()=>{
    const memory=EmotionalMemorySchema.parse(emotional),original=memory.observations[0];
    expect(emotionObservationID(original)).toBe('60f1e4b5a93de88dd886479107ad17136dd6f57e178245d40b1dabce3abf8e5d');
    const journal={entry:{content_hash:hash(raw)},emotion_observation_overrides:{source_hash:hash(raw),edits:[{
      observation_id:emotionObservationID(original),original_key:original.key,quote:original.quote,sequence:original.sequence,choices:['excitement'],
    }]}};
    const corrected=correctedEmotionObservations(memory,journal);
    expect(corrected[0]).toMatchObject({key:'excitement',quote:original.quote,sequence:0,intensity:null});
    expect(corrected[1]).toEqual(memory.observations[1]);
    expect(memory.observations[0].key).toBe('tension');
    const reordered=EmotionalMemorySchema.parse({...memory,observations:memory.observations.map(o=>({...o,sequence:o.sequence+2}))});
    expect(correctedEmotionObservations(reordered,journal)[0]).toMatchObject({key:'excitement',sequence:2});
    journal.emotion_observation_overrides.source_hash='stale';
    expect(correctedEmotionObservations(memory,journal)).toEqual(memory.observations);
  });
  it('groups repeated contextual experience without generating duplicate nodes for paraphrased event labels',()=>{
    const first=input();first.result={...analysis(),emotional_memory:{...emotional,observations:emotional.observations.map(o=>({...o,context_key:'daily-walking',context_label:'Yürüyüş'}))}};
    const saved=applyAnalysis(first),next=input();
    next.memory=saved.memory;next.journal.entry.id='journal-two';next.journal.entry.local_date='2026-11-07';
    next.result={...analysis(),emotional_memory:{...emotional,observations:emotional.observations.map(o=>({...o,event:o.event+' deneyimi',context_key:'daily-walking',context_label:'Yürüyüş'}))}};
    next.expectedMemoryHash=hash(canonicalJson(next.memory));next.expectedSourceHash=hash(canonicalJson(next.journal));next.jobID=hash('second-emotion');
    const updated=applyAnalysis(next).memory;
    const nodes=updated.graph.nodes.filter(n=>n.consumers?.includes('emotion'));
    expect(nodes).toHaveLength(2);
    expect(nodes.every(n=>new Set(n.evidence.map(e=>e.sourceId)).size===2)).toBe(true);
  });
  it('applies event corrections to memory notes without changing the original emotion analysis',()=>{
    const args=input(),o=emotional.observations[0];
    args.journal.emotion_observation_overrides={source_hash:hash(raw),edits:[{observation_id:emotionObservationID(o),
      original_key:o.key,quote:o.quote,sequence:o.sequence,choices:['excitement']}]};
    args.journal.emotion_override={source_hash:hash(raw),choices:['calm']}; // A new targeted edit supersedes the old global filter.
    args.expectedSourceHash=hash(canonicalJson(args.journal));
    const applied=applyAnalysis(args);
    expect(applied.memory.graph.nodes.filter(n=>n.consumers?.includes('emotion')).some(n=>n.label.startsWith('Gerilim'))).toBe(false);
    expect(applied.memory.graph.nodes.some(n=>n.label.startsWith('Heyecan'))).toBe(true);
    expect(applied.journal.emotional_memory?.observations[0].key).toBe('tension');
  });
  it('does not invent event ordering between separate long-journal segments',()=>{
    const merged=mergeJournalParts({parts:[0,1].map(()=>({rawText:raw,result:{...analysis(),emotional_memory:emotional}})),answers:[]});
    const observations=merged.emotional_memory!.observations;
    expect(new Set(observations.map(o=>o.order_group))).toEqual(new Set(['segment-0','segment-1']));
    expect(observations.map(o=>o.quote)).toEqual([...emotional.observations,...emotional.observations].map(o=>o.quote));
  });
  it('keeps old analyses valid and accepts mixed sequential emotions in the normal analysis', () => {
    expect(validateAnalysis(raw, analysis()).emotional_memory).toBeUndefined();
    expect(validateAnalysis(raw, {...analysis(), emotional_memory: emotional}).emotional_memory).toEqual(emotional);
  });
  it('rejects invented quotes, including helpful actions, and accepts actual user answers', () => {
    expect(() => validateAnalysis(raw, {...analysis(), emotional_memory: {...emotional,
      helpful: [{action:'Meditasyon',quote:'Meditasyon yaptım.'}]}})).toThrow('Unsupported emotion quote');
    expect(validateAnalysis(raw, {...analysis(), emotional_memory: {...emotional,
      helpful: [{action:'Mola',quote:'Mola iyi geldi.'}]}}, ['Mola iyi geldi.']).emotional_memory?.helpful[0].action).toBe('Mola');
  });
  it('atomically persists emotion chronology with the journal and memory while retaining media', () => {
    const args = input();
    const result = applyAnalysis(args);
    expect(result.journal.emotional_memory).toEqual({...emotional,source_hash:hash(raw)});
    expect(result.memory.sources[0].analysis?.notes.filter(note=>note.consumers?.includes("emotion"))).toHaveLength(2);
    expect(result.memory.sources[0]).not.toHaveProperty("emotional_memory");
    expect(result.journal).toHaveProperty('journal_stickers',['🌊']);
    expect(result.journal).toHaveProperty('journal_media',[{id:'photo',data:'fixture'}]);
    expect(() => applyAnalysis({...args,expectedSourceHash:hash('stale')})).toThrow('Source or memory changed');
  });
  it('supplies historical emotional experience and user corrections in the next normal analysis', () => {
    const applied = applyAnalysis(input());
    const next = input().journal;
    next.entry.id = 'next-journal';
    next.entry.local_date = '2026-11-07';
    next.emotion_override = {choices:['calm'],source_hash:hash(raw)};
    const context = JSON.parse(selectContext(applied.memory, next));
    expect(context.priorEmotionalExperience[0].observations.map((note:{quote:string})=>note.quote)).toEqual(emotional.observations.map(note=>note.quote));
    expect(context.currentEmotionCorrection.choices).toEqual(['calm']);
  });
  it('treats saved mood choices as explicit user evidence and prevents rejected emotion nodes from returning',()=>{
    const args=input();
    args.journal.emotion_override={source_hash:hash(raw),choices:['calm']};
    args.expectedSourceHash=hash(canonicalJson(args.journal));
    const applied=applyAnalysis(args);
    expect(applied.memory.sources[0].answers).toContainEqual({question:'Bu günün duygu etiketleri',answer:'Duygu seçimi: calm'});
    expect(applied.memory.graph.nodes.filter(node=>node.consumers?.includes('emotion')).map(node=>node.label)).toEqual(['Huzur · Yürüyüş sonrası']);
  });
  it('exports emotion history only on request, including corrected cached history', () => {
    const memory = exportPortableMemory(snapshot(), 1);
    memory.sources[0].analysis = {...analysis().living_memory,notes:[]};
    const exportedAt = '2026-11-06T10:00:00Z';
    expect(exportMindmapContext({memory,exportedAt}).markdown).not.toContain('emotionalHistory');
    const history = [{sourceID:'source-one',date:'2026-09-30',reflection:'Yansıma',userSelected:true,
      observations:[],helpful:[],helpfulEvidence:[{action:'Yürüyüş',quote:'Yürümek iyi geldi.',date:'2026-09-30'}]}];
    const included = exportMindmapContext({memory,exportedAt,includeEmotions:true,emotionHistory:history});
    expect(included.markdown).toContain('"userSelected": true');
    expect(included.markdown).toContain('Yürümek iyi geldi.');
    expect(included.markdown).not.toContain('"Yürüyüş öncesi"');
  });
  it('backfills only the emotion contract and validates evidence without executing old requests', () => {
    const prepared = JSON.parse(invoke('prepareEmotionBackfill', JSON.stringify({rawText:raw,date:'2026-11-06',answers:[]})));
    expect(prepared.usageStage).toBe('emotionBackfill');
    expect(prepared).not.toHaveProperty('webResearch');
    expect(JSON.parse(invoke('validateEmotionBackfill', JSON.stringify({rawText:raw,answers:[],result:emotional})))).toEqual(emotional);
    expect(() => invoke('validateEmotionBackfill', JSON.stringify({rawText:'Başka yazı',answers:[],result:emotional}))).toThrow();
    const request = {rawText:raw,answers:[]};
    const malformed = '{"observations":[';
    expect(() => invoke('validateEmotionBackfill', JSON.stringify({...request,result:malformed}))).toThrow(SyntaxError);
    const repair = JSON.parse(invoke('prepareModelResponseRepair', JSON.stringify({prepared,output:malformed,errorCode:'invalid_json'})));
    const {outputSchema, ...source} = JSON.parse(prepared.input[0].content);
    expect(repair.usageStage).toBe('responseFormatRepair');
    expect(repair.webResearch).toBe(false);
    expect(JSON.parse(repair.input[0].content)).toEqual({outputSchema,source,previousOutput:malformed,errorCode:'invalid_json'});
    expect(JSON.parse(invoke('validateEmotionBackfill', JSON.stringify({...request,result:JSON.stringify(emotional)})))).toEqual(emotional);
    expect(() => invoke('validateEmotionBackfill', JSON.stringify({
      ...request,rawText:'Başka yazı',result:JSON.stringify(emotional),
    }))).toThrow('Unsupported emotion quote');
  });
  it('keeps timed followup cards in the inbox without creating an unapproved alarm', () => {
    const memory = applyAnalysis(input()).memory;
    memory.sources[0].analysis!.followups = [{key:'check-in',title:'Nasıl geçti?',question:'Nasıldı?',
      quote:'Bugün yürüdüm.',due_date:'2026-11-07',status:'open',
      timing:{not_before:'2026-11-07T10:00:00+03:00',expires_at:'2026-11-07T12:00:00+03:00',
        reason:'Sonrasında',quote:'Bugün yürüdüm.',basis:'inferred',intent:'check_in',event_at:null}}];
    const cards = followupRecords(memory,'2026-11-06T10:00:00Z');
    expect(JSON.parse(JSON.parse(cards[0].content)).notification).toBeNull();
  });
});
