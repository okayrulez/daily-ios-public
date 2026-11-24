import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';
import { ApplyInput, applyAnalysis, emptyMemory, selectContext, validateAnalysis } from '../src/shared/mobile-pipeline.js';
import { canonicalJson, hash, utf8 } from '../src/shared/mobile-json.js';
import { exportPortableMemory } from '../src/main/memory/portable-memory-export.js';
import { analysis, snapshot } from './fixtures.js';

function fixture() {
  const memory=exportPortableMemory(snapshot(),1);
  const journal={entry:{id:'journal-one',local_date:'2026-09-30',raw_text:'Bugün yürüdüm.',
    content_hash:hash('Bugün yürüdüm.'),saved_at:'2026-09-30T09:00:00Z',analysis_status:'pending',analysis_error:null},
    analyses:[],questions:[{id:'old-q',journal_id:'journal-one',kind:'open' as const,position:0,
      prompt:'Ne iyi geldi?',rationale:'Sebep',source_ref:'journal-one',answer_text:'Sessizlik iyi geldi.',answer_boolean:null}],
    futureExtension:{keep:true}};
  return ApplyInput.parse({memory,journal,result:analysis(),expectedMemoryHash:hash(canonicalJson(memory)),
    expectedSourceHash:hash(canonicalJson(journal)),jobID:hash('job'),model:'fixture-model',now:'2026-09-30T12:00:00Z'});
}
describe('phone-owned analysis pipeline',()=>{
  it('retains prior-day journal analysis and memory while analyzing the next day',()=>{
    const original=fixture(),first=applyAnalysis(original);
    const stored=JSON.stringify(first.journal);
    const journal={...original.journal,entry:{...original.journal.entry,id:'journal-next-day',local_date:'2026-10-01'},analyses:[],questions:[]};
    const second=applyAnalysis({...original,memory:first.memory,journal,jobID:hash('next-day-job'),now:'2026-10-01T12:00:00Z',
      expectedMemoryHash:hash(canonicalJson(first.memory)),expectedSourceHash:hash(canonicalJson(journal))});
    expect(JSON.stringify(first.journal)).toBe(stored);
    expect(first.journal.entry.analysis_status).toBe('complete');
    expect(first.journal.analyses[0].reflection).toBe(analysis().reflection);
    expect(first.journal.entry.local_date).toBe('2026-09-30');
    expect(second.journal.entry.local_date).toBe('2026-10-01');
    expect(second.memory.sources.find(s=>s.id==='journal-one')).toEqual(first.memory.sources.find(s=>s.id==='journal-one'));
    expect(second.memory.sources.some(s=>s.id==='journal-next-day')).toBe(true);
  });
  it('archives answers and blanks when the reflection is finished without opening a new personal question round',()=>{
    const input=fixture();
    input.journal.questions[0].session_closed_at='2026-09-30T11:00:00Z';
    input.journal.questions.push({...input.journal.questions[0],id:'blank-q',kind:'boolean',position:1,answer_text:null,answer_boolean:null});
    input.expectedSourceHash=hash(canonicalJson(input.journal));
    const context=JSON.parse(selectContext(input.memory,input.journal));
    expect(context.currentUserAnswers).toHaveLength(1);
    const result=applyAnalysis(input);
    const history=result.journal.question_history as Array<Record<string,unknown>>;
    expect(history).toHaveLength(2);
    expect(history.find(q=>q.id==='blank-q')).toMatchObject({answer_boolean:null,session_closed_at:'2026-09-30T11:00:00Z'});
    expect(result.journal.questions).toEqual([]);
    expect(result.journal.analyses.at(-1)?.reflection).toBe(analysis().reflection);
  });
  it('matches platform UTF8 and SHA256 including emoji and unpaired surrogates',()=>{
    for(const text of ['İzmir/ışık','😀','\ud800','a\u0000b']) {
      expect(Array.from(utf8(text))).toEqual(Array.from(Buffer.from(text)));
      expect(hash(text)).toBe(createHash('sha256').update(text).digest('hex'));
    }
  });
  it('includes corrections on rejected nodes and answers as separate evidence',()=>{
    const input=fixture(),context=selectContext(input.memory,input.journal);
    expect(JSON.parse(context).userCorrectionsOverrideModel[0].text).toBe('Bu kalıcı alışkanlığım değil.');
    expect(JSON.parse(context).currentUserAnswers[0].answer).toBe('Sessizlik iyi geldi.');
    expect(context.length).toBeLessThan(55000);
  });
  it('persists an approved reminder with the analysis and archives its consent',()=>{
    const input=fixture();
    input.journal.questions=[{id:'consent-1',journal_id:'journal-one',kind:'boolean',position:0,
      prompt:'Yarın 18:00 yürüyüş hatırlatması oluşturayım mı?',rationale:'Onay',source_ref:'journal-one',answer_text:null,answer_boolean:1,
      reminder_proposal:{title:'Yürüyüş',details:'Kısa yürüyüş',quote:'Bugün yürüdüm.',schedule:{startDate:'2026-10-01',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}}}];
    input.expectedSourceHash=hash(canonicalJson(input.journal));
    const output=applyAnalysis(input);
    expect(output.memory.agenda).toHaveLength(1);
    expect(JSON.parse(JSON.parse(output.atlas.find(r=>r.key==='note:companion/agenda.json')!.content)).entries).toHaveLength(1);
    expect(output.journal.reminder_results[0]).toContain('oluşturuldu');
    expect(output.journal.question_history).toEqual(input.journal.questions);
  });
  it('rejects invented reminder evidence and open-ended consent fields',()=>{
    const result:any=analysis();
    const proposal={title:'Yürüyüş',details:'Kısa yürüyüş',quote:'Kaynakta olmayan ifade',schedule:{startDate:'2026-10-01',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}};
    result.boolean_questions[0].reminder_proposal=proposal;
    expect(()=>validateAnalysis('Bugün yürüdüm.',result)).toThrow('Unsupported reminder quote');
    delete result.boolean_questions[0].reminder_proposal;result.open_questions[0].reminder_proposal=proposal;
    expect(()=>validateAnalysis('Bugün yürüdüm.',result)).toThrow('Reminder consent must be boolean');
  });
  it('publishes valid atlas pages, retains answers/history/extensions and confirmed deadlines',()=>{
    const input=fixture(),output=applyAnalysis(input);
    expect(output.memory.revision).toBe(2);
    expect(output.memory.deadlines).toEqual(input.memory.deadlines);
    expect(output.memory.graph.nodes.find(n=>n.id==='node-one')?.corrections).toEqual(input.memory.graph.nodes[0].corrections);
    expect(output.journal.question_history).toEqual(input.journal.questions);
    expect((output.journal as Record<string,unknown>).futureExtension).toEqual({keep:true});
    expect(output.journal.questions.filter(q=>q.kind==='open')).toHaveLength(3);
    expect(output.journal.questions.filter(q=>q.kind==='boolean')).toHaveLength(5);
    expect(output.memory.sources.find(s=>s.id==='journal-one')?.answers[0].answer).toBe('Sessizlik iyi geldi.');
    const index=JSON.parse(JSON.parse(output.atlas.at(-1)!.content));
    for(const map of index.maps) for(const page of [...map.pages,...map.detailPages]) {
      const row=output.atlas.find(r=>r.key===page.key)!;
      expect(hash(row.content)).toBe(page.hash);
    }
  });
  it('rejects stale source/memory hashes and unsupported question text as evidence',()=>{
    const input=fixture();
    expect(()=>applyAnalysis({...input,expectedSourceHash:hash('changed')})).toThrow(/changed/);
    expect(()=>applyAnalysis({...input,expectedMemoryHash:hash('changed')})).toThrow(/changed/);
    const result=analysis();result.living_memory.notes[0].quote='Ne iyi geldi?';
    expect(()=>validateAnalysis(input.journal.entry.raw_text,result,['Sessizlik iyi geldi.'])).toThrow(/quote/);
    result.living_memory.notes[0].quote='Sessizlik iyi geldi.';
    expect(()=>applyAnalysis({...input,result})).not.toThrow();
  });
  it('never strengthens a note by repeated analysis of the same source',()=>{
    const first=fixture(),a=applyAnalysis(first);
    const next=ApplyInput.parse({...first,memory:a.memory,journal:a.journal,jobID:hash('second'),
      expectedMemoryHash:hash(canonicalJson(a.memory)),expectedSourceHash:hash(canonicalJson(a.journal))});
    const b=applyAnalysis(next);
    expect(b.memory.graph.nodes.filter(n=>n.key==='walk')).toHaveLength(1);
    expect(b.memory.graph.nodes.find(n=>n.key==='walk')?.status).toBe('corrected');
    expect(b.memory.graph.nodes.find(n=>n.key==='walk')?.evidence.filter(e=>e.sourceId==='journal-one')).toHaveLength(1);
    expect(b.journal.analyses).toHaveLength(2);
  });
  it('runs context and apply in the actual JavaScriptCore-targeted bundle',()=>{
    const context: Record<string,any>={};
    runInNewContext(readFileSync('ios/DailyCore/Resources/dailyx-analysis.js','utf8'),context,{timeout:5000});
    const input=fixture();
    expect(JSON.parse(context.DailyXAnalysis.invoke('applyJournal',JSON.stringify(input)))).toEqual(applyAnalysis(input));
    expect(JSON.parse(context.DailyXAnalysis.invoke('emptyMemory','{}'))).toEqual(emptyMemory());
  });
});
