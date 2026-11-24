import {describe,it,expect} from 'vitest';
import {prioritizeQuestions,usefulQuestions,questionBasis,questionPlanningState} from '../src/shared/question-policy.js';
import {ApplyInput,applyAnalysis,emptyMemory,journalAnswers,JournalPayloadSchema,validateAnalysis,selectContext} from '../src/shared/mobile-pipeline.js';
import {isFunctionalQuestion,applyFunctionalAnswers} from '../src/shared/functional-answers.js';
import {mergeJournalParts} from '../src/shared/journal-parts.js';
import {canonicalJson,hash} from '../src/shared/mobile-json.js';
import {invoke} from '../src/shared/mobile-analysis-core.js';
import {analysis} from './fixtures.js';

const raw='Bugün yürüdüm. Yarın yine yürümek istiyorum.';
const proposal={title:'Yürüyüş',details:'Kısa yürüyüş',quote:'Yarın yine yürümek istiyorum.',
  schedule:{startDate:'2026-11-17',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}};
const q=(purpose:string,prompt=purpose)=>({prompt,purpose,rationale:'Cevap eksik bilgiyi netleştirir.',source_ref:'journal-one'});
const reminder={...q('reminder_consent'),reminder_proposal:proposal};
function input() {
  const memory=emptyMemory(),journal=JournalPayloadSchema.parse({entry:{id:'journal-one',local_date:'2026-11-16',raw_text:raw,
    content_hash:hash(raw),saved_at:'2026-11-16T10:00:00Z',analysis_status:'pending',analysis_error:null},analyses:[],questions:[]});
  return ApplyInput.parse({memory,journal,result:{...analysis(),open_questions:[],boolean_questions:[reminder]},
    expectedMemoryHash:hash(canonicalJson(memory)),expectedSourceHash:hash(canonicalJson(journal)),jobID:hash('question-job'),model:'fixture',now:'2026-11-16T10:01:00Z'});
}

describe('functional question planning',()=>{
  it('prioritizes actionable plans and emotional gaps before personal knowledge without filling a quota',()=>{
    const list=[q('personal_context'),q('emotion_clarification'),q('reminder_setup'),reminder];
    expect(prioritizeQuestions(list).map(q=>q.purpose)).toEqual(['reminder_consent','reminder_setup','emotion_clarification','personal_context']);
    expect(prioritizeQuestions([])).toEqual([]);
    expect(usefulQuestions([],{basis:'same',history:[],agenda:[]})).toEqual([]);
  });
  it('uses purpose only for planning and requires a real proposal for operational consent',()=>{
    expect(()=>validateAnalysis(raw,{...analysis(),boolean_questions:[q('reminder_consent')]})).toThrow('Missing reminder consent proposal');
    expect(()=>validateAnalysis(raw,{...analysis(),boolean_questions:[q('emotion_consent')]})).toThrow('Missing emotion consent proposal');
    const j=input().journal;
    j.questions=[{...q('emotion_clarification','Yürüyüşün ardından daha rahat hissettin mi?'),id:'feeling',journal_id:'journal-one',
      kind:'boolean',position:0,answer_boolean:1,answer_text:null}];
    expect(isFunctionalQuestion(j.questions[0])).toBe(false);
    expect(journalAnswers(j)).toHaveLength(1);
  });
  it('suppresses duplicate and resolved approvals for unchanged input and reopens a declined proposal after new input',()=>{
    const basis=questionBasis(raw,[]),history=[{...reminder,kind:'boolean',question_basis:basis,answer_boolean:0}];
    expect(usefulQuestions([reminder,reminder],{basis,history:[],agenda:[]})).toHaveLength(1);
    expect(usefulQuestions([reminder],{basis,history,agenda:[]})).toEqual([]);
    expect(usefulQuestions([reminder],{basis:questionBasis(raw+' Saatini değiştirdim.',[]),history,agenda:[]})).toHaveLength(1);
    expect(usefulQuestions([reminder],{basis,history:[],agenda:[{...proposal,status:'active'}]})).toEqual([]);
    expect(usefulQuestions([reminder],{basis,history:[],agenda:[],pending:[reminder]})).toEqual([]);
    const skipped={...reminder,kind:'boolean',question_basis:basis,answer_boolean:null,session_closed_at:'2026-11-16T10:00:00Z'};
    expect(usefulQuestions([reminder],{basis,history:[skipped],agenda:[]})).toEqual([]);
    expect(questionPlanningState([skipped])[0].state).toBe('skipped');
  });
  it('does not repeatedly ask for the same calendar emotion label',()=>{
    const emotion={...q('emotion_consent'),emotion_proposal:{key:'calm',label:'Huzur',quote:'Bugün yürüdüm.'}};
    expect(usefulQuestions([emotion,{...emotion,prompt:'Bu etiketi seçelim mi?'}],{basis:'same',history:[],agenda:[]})).toHaveLength(1);
    expect(usefulQuestions([emotion],{basis:'same',history:[{...emotion,kind:'boolean',question_basis:'same',answer_boolean:1}],agenda:[]})).toEqual([]);
  });
  it('separates completed decisions from reflective answers in bounded planning state',()=>{
    expect(questionPlanningState([{...reminder,answer_boolean:1},{...q('emotion_clarification'),answer_boolean:0},
      {...q('personal_context'),answer_text:'Müzik dinliyorum.'},{...q('reminder_setup'),answer_text:null}]).map(q=>q.state))
      .toEqual(['pending','answered','answered','approved']);
    const args=input();args.journal.questions=[{...reminder,id:'old',journal_id:'journal-one',kind:'boolean',position:0,answer_text:null,answer_boolean:0}];
    const context=selectContext(args.memory,args.journal,'');
    expect(context).toContain('questionPlanningStateNotPersonalEvidence');
    expect(context).toContain('declined');
    expect(questionPlanningState([{...reminder,question_basis:'old'}],'new')[0].inputChanged).toBe(true);
  });
  it('keeps useful questions from later long-journal segments ahead of generic questions',()=>{
    const first={...analysis(),open_questions:[q('personal_context','Sevdiğin müzik?'),q('personal_context','Sevdiğin film?'),q('personal_context','Sevdiğin kitap?')]};
    const last={...analysis(),open_questions:[q('reminder_setup','Yarın kaçta yürümek istersin?'),q('emotion_clarification','Yürürken hislerin nasıl değişti?')],boolean_questions:[reminder]};
    const merged=mergeJournalParts({parts:[{rawText:raw,result:first},{rawText:raw,result:last}],answers:[]});
    expect(merged.open_questions.map(q=>q.purpose)).toEqual(['reminder_setup','emotion_clarification','personal_context']);
    expect(merged.boolean_questions[0].reminder_proposal).toEqual(proposal);
  });
  it('keeps an unchanged pending approval and creates only one alarm after explicit consent',()=>{
    const initial=input(),first=applyAnalysis(initial),next=input();
    next.memory=first.memory;next.journal=JournalPayloadSchema.parse(first.journal);
    next.jobID=hash('question-job-again');next.now='2026-11-16T10:02:00Z';
    next.expectedMemoryHash=hash(canonicalJson(next.memory));next.expectedSourceHash=hash(canonicalJson(next.journal));
    const repeated=applyAnalysis(next);
    expect(repeated.journal.questions).toEqual(first.journal.questions);
    expect(repeated.journal.question_history).toEqual([]);
    expect(repeated.journal.questions_generated_at).toBe(first.journal.questions_generated_at);
    expect(repeated.cards.filter(n=>n.key.includes('journal_questions_'))).toEqual([]);
    const approved=JournalPayloadSchema.parse(repeated.journal);approved.questions[0].answer_boolean=1;
    const result=applyFunctionalAnswers({memory:repeated.memory,journal:approved,expectedMemoryHash:hash(canonicalJson(repeated.memory)),
      expectedSourceHash:hash(canonicalJson(approved)),now:next.now});
    expect(result.memory.agenda).toHaveLength(1);
    expect(journalAnswers(JournalPayloadSchema.parse(result.journal))).toEqual([]);
  });
  it('applies the same goal priority in normal generation and repair with past decision context',()=>{
    const normal=JSON.parse(invoke('prepareJournal',JSON.stringify({journalId:'journal-one',localDate:'2026-11-16',rawText:raw,workContext:''})));
    const repair=JSON.parse(invoke('prepareQuestionRepair',JSON.stringify({rawText:raw,answers:[],journalID:'journal-one',result:analysis(),historyContext:'Previously declined walking alarm'})));
    expect(normal.input[0].content).toContain('SORU ÖNCELİĞİ');
    expect(repair.instructions).toContain('SORU ÖNCELİĞİ');
    expect(repair.input[0].content).toContain('Previously declined walking alarm');
    expect(normal.input[0].content).toContain('üst sınırdır');
  });
  it('keeps decisions stable after personal answers move into source history and reevaluates new input',()=>{
    const initial=input();
    initial.journal.questions=[{...q('emotion_clarification','Yürüyüş sana nasıl geldi?'),id:'feeling',journal_id:'journal-one',
      kind:'open',position:0,answer_boolean:null,answer_text:'İyi geldi.'}];
    initial.expectedSourceHash=hash(canonicalJson(initial.journal));
    const first=applyAnalysis(initial),next=input();
    next.memory=first.memory;next.journal=JournalPayloadSchema.parse(first.journal);next.jobID=hash('after-answer-archived');
    next.expectedMemoryHash=hash(canonicalJson(next.memory));next.expectedSourceHash=hash(canonicalJson(next.journal));
    const repeated=applyAnalysis(next);
    expect(repeated.journal.questions[0].id).toBe(first.journal.questions[0].id);
    next.journal.entry.raw_text=raw+' Ama saati değiştirmek istiyorum.';
    next.journal.entry.content_hash=hash(next.journal.entry.raw_text);
    next.expectedSourceHash=hash(canonicalJson(next.journal));
    const context=JSON.parse(selectContext(next.memory,next.journal,''));
    expect(context.questionPlanningStateNotPersonalEvidence[0].inputChanged).toBe(true);
    const changed=applyAnalysis(next);
    expect(changed.journal.questions[0].id).not.toBe(first.journal.questions[0].id);
    expect(changed.journal.question_history).toEqual(expect.arrayContaining([expect.objectContaining({id:first.journal.questions[0].id})]));
  });
});
