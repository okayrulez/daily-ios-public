import {describe,it,expect} from 'vitest';
import {applyFunctionalAnswers} from '../src/shared/functional-answers.js';
import {ReminderProposal} from '../src/shared/reminder-proposals.js';
import {emptyMemory,journalAnswers,JournalPayloadSchema,validateAnalysis} from '../src/shared/mobile-pipeline.js';
import {canonicalJson,hash} from '../src/shared/mobile-json.js';
import {invoke} from '../src/shared/mobile-analysis-core.js';
import {analysis} from './fixtures.js';
import {mergeJournalParts} from '../src/shared/journal-parts.js';

const now='2026-11-06T10:00:00Z';
const text='Yürümek istiyorum. Bugün huzurluyum.';
function journal() {
  const question=(id:string)=>({id,journal_id:'journal-one',kind:'boolean',position:0,prompt:id,rationale:'Onay',source_ref:'journal-one',answer_boolean:1,answer_text:null});
  return JournalPayloadSchema.parse({entry:{id:'journal-one',local_date:'2026-11-06',raw_text:text,content_hash:hash(text),saved_at:now,analysis_status:'complete',analysis_error:null},
    analyses:[],questions:[{...question('alarm'),reminder_proposal:{title:'Yürüyüş',details:'Kısa yürüyüş',quote:'Yürümek istiyorum',
      schedule:{startDate:'2026-11-07',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}}},
      {...question('emotion'),emotion_proposal:{key:'calm',label:'Huzur',quote:'Bugün huzurluyum.'}},question('reflective'),
      {...question('written'),kind:'open',answer_boolean:null,answer_text:'Kısa bir mola iyi geldi.'}]});
}
function apply(j=journal(),memory=emptyMemory()) {
  return applyFunctionalAnswers({memory,journal:j,expectedMemoryHash:hash(canonicalJson(memory)),expectedSourceHash:hash(canonicalJson(j)),now});
}
describe('local functional decisions',()=>{
  it('keeps functional yes/no out of inference evidence and retains reflective and written answers',()=>{
    expect(journalAnswers(journal()).map(a=>a.question)).toEqual(['reflective','written']);
    expect(JSON.parse(invoke('journalPromptAnswers',JSON.stringify(journal())))).toEqual([
      {question:'reflective',answer:'Evet'},{question:'written',answer:'Kısa bir mola iyi geldi.'},
    ]);
  });
  it('creates an approved alarm and records the explicit emotion choice without generating an analysis',()=>{
    const j=journal(),result=apply(j);
    expect(result.memory.agenda).toHaveLength(1);
    expect(result.journal.emotion_calendar_override).toEqual({source_hash:hash(text),choices:['calm']});
    expect(result.journal.emotion_override).toBeUndefined();
    expect(journalAnswers(JournalPayloadSchema.parse(result.journal)).map(a=>a.question)).toEqual(['reflective','written']);
    expect(result.journal.analyses).toEqual([]);
    expect(result.journal.questions.slice(0,2).every(q=>q.functional_applied_answer===1)).toBe(true);
    expect(result.journal.questions[2].functional_applied_answer).toBeUndefined();
    const again=apply(JournalPayloadSchema.parse(result.journal),result.memory);
    expect(again.memory.agenda).toHaveLength(1);
  });
  it('projects the approved iPhone alarm and its revocation through the local bridge',()=>{
    const approved=journal();
    const proposal=ReminderProposal.parse(approved.questions[0].reminder_proposal);
    approved.questions[0].reminder_proposal={...proposal,schedule:{...proposal.schedule,appleDestination:'alarm'}};
    const first=apply(approved);
    const published=JSON.parse(JSON.parse(first.atlas[0].content)).entries;
    expect(published[0]).toMatchObject({status:'active',schedule:{time:'18:00'}});
    expect(published[0].schedule).not.toHaveProperty('appleDestination');
    expect(first.appleDestinations).toEqual({[published[0].id]:'alarm'});
    const declined=JournalPayloadSchema.parse(first.journal);
    declined.questions[0].answer_boolean=0;
    const result=apply(declined,first.memory);
    expect(JSON.parse(JSON.parse(result.atlas[0].content)).entries[0]).toMatchObject({
      id:published[0].id,status:'cancelled',
    });
    expect(result.appleRevocations).toEqual([published[0].id]);
    expect(result.journal.analyses).toEqual([]);
  });
  it('does not create declined alarms or guess emotions for unanswered choices',()=>{
    const j=journal();j.questions[0].answer_boolean=0;j.questions[1].answer_boolean=null;
    expect(apply(j).memory.agenda??[]).toEqual([]);
    expect(apply(j).journal.emotion_calendar_override).toBeUndefined();
  });
  it('revokes a previously approved alarm directly when its saved answer is changed to no',()=>{
    const first=apply(),j=JournalPayloadSchema.parse(first.journal);
    j.questions[0].answer_boolean=0;
    expect(apply(j,first.memory).memory.agenda![0].status).toBe('cancelled');
  });
  it('rejects source changes and unsupported functional emotion evidence',()=>{
    const j=journal();j.questions[1].emotion_proposal={key:'calm',label:'Huzur',quote:'Söylenmedi'};
    expect(()=>apply(j)).toThrow(/quote/);
    expect(()=>applyFunctionalAnswers({memory:emptyMemory(),journal:journal(),expectedMemoryHash:'wrong',expectedSourceHash:'wrong',now})).toThrow(/changed/);
  });
});
describe('one canonical analysis contract',()=>{
  it('combines all long-journal segment findings without dropping notes or adding inference calls',()=>{
    const parts=Array.from({length:4},(_,i)=>{
      const result=analysis();result.reflection='Yansıma '+i;
      result.living_memory.notes=result.living_memory.notes.map(n=>({...n,key:n.key+'-'+i,label:n.label+' '+i}));
      return {rawText:'Bugün yürüdüm.',result};
    });
    const combined=mergeJournalParts({parts,answers:[]});
    expect(combined.living_memory!.notes).toHaveLength(4);
    for(let i=0;i<4;i++)expect(combined.reflection).toContain('Yansıma '+i);
    expect(combined.open_questions.length).toBeLessThanOrEqual(3);
    expect(combined.boolean_questions.length).toBeLessThanOrEqual(5);
    parts[3].result.living_memory.notes[0].quote='Uydurulmuş alıntı';
    expect(()=>mergeJournalParts({parts,answers:[]})).toThrow(/quote/);
  });
  it('accepts compact output, fills legacy arrays locally and preserves old outputs',()=>{
    const full=analysis();
    const compact={reflection:full.reflection,confidence:full.confidence,living_memory:full.living_memory,
      emotional_memory:{observations:[],helpful:[]},connections:[],open_questions:[],boolean_questions:[]};
    const next=validateAnalysis('Bugün yürüdüm.',compact);
    expect(next.events).toEqual([]);expect(next.people).toEqual([]);
    expect(validateAnalysis('Bugün yürüdüm.',full)).toEqual(full);
    const prompt=JSON.parse(invoke('prepareJournal',JSON.stringify({journalId:'journal-one',localDate:'2026-11-06',rawText:'Bugün yürüdüm.',workContext:''}))).input[0].content;
    expect(prompt).toContain('JSON çıktı şeması:');
    expect(prompt).not.toContain('"people_keys"');
  });
  it('accepts source text beyond the old 100k editor/schema limit without truncation',()=>{
    const long='Bugün çok şey yazdım. '.repeat(6000);
    const j=journal();j.entry.raw_text=long;j.entry.content_hash=hash(long);
    expect(JournalPayloadSchema.parse(j).entry.raw_text).toBe(long);
    const prompt=JSON.parse(invoke('prepareJournal',JSON.stringify({journalId:'journal-one',localDate:'2026-11-06',rawText:long,workContext:''})));
    expect(prompt.input[0].content).toContain(long);
  });
});
