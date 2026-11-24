import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';
import { invoke, invokeChecked } from '../src/shared/mobile-analysis-core.js';
import { journalAnalysisPrompt } from '../src/main/analysis/prompts.js';
import { exportPortableMemory } from '../src/main/memory/portable-memory-export.js';
import { analysis, snapshot } from './fixtures.js';

const source = { journalId: 'journal-one', localDate: '2026-09-30', rawText: 'Bugün yürüdüm.',
  workContext: 'Yalnız günlük.', memoryContext: 'Düzeltme: Bu kalıcı alışkanlığım değil.' };

describe('phone analysis core', () => {
  it('reports the failing validation field without private values or schema messages', () => {
    const result = { ...analysis(), reflection: 123, private_secret: 'secret-diary' };
    const failure = JSON.parse(invokeChecked('validateJournal', JSON.stringify({ rawText: 'secret-diary', result })));
    expect(failure.ok).toBe(false);
    expect(failure.error.code).toBe('schema_validation');
    expect(failure.error.issues).toContain('invalid_type:reflection');
    expect(JSON.stringify(failure)).not.toMatch(/secret-diary|private_secret|expected|received/);
  });
  it('distinguishes evidence rejection, bad JSON, and unknown commands', () => {
    const result = analysis();
    result.living_memory.notes[0].quote = 'secret unsupported quote';
    expect(JSON.parse(invokeChecked('validateJournal', JSON.stringify({ rawText: source.rawText, result }))).error.code).toBe('unsupported_source_quote');
    expect(JSON.parse(invokeChecked('validateJournal', '{secret diary')).error.code).toBe('invalid_json');
    expect(JSON.parse(invokeChecked('secret-command', '{}')).error.code).toBe('unknown_command');
    expect(invokeChecked('secret-command', '{}')).not.toContain('secret-command');
  });
  it('keeps the successful output identical through the checked bridge', () => {
    expect(JSON.parse(invokeChecked('prepareJournal', JSON.stringify(source)))).toEqual({ok:true,value:invoke('prepareJournal', JSON.stringify(source))});
  });
  it('retains the desktop prompt, corrections, and 3+5 question contract', () => {
    const prepared = JSON.parse(invoke('prepareJournal', JSON.stringify(source)));
    expect(prepared.input[0].content).toBe(journalAnalysisPrompt(source));
    expect(prepared.input[0].content).toContain(source.memoryContext);
    expect(prepared.input[0].content).toContain('3 açık uçlu ve 5 evet/hayır');
  });
  it('rejects unsupported quotes and excessive question sets while allowing fewer questions', () => {
    const result = analysis();
    expect(() => invoke('validateJournal', JSON.stringify({ rawText: source.rawText, result }))).not.toThrow();
    result.living_memory.notes[0].quote = 'Asla söylemediğim söz';
    expect(() => invoke('validateJournal', JSON.stringify({ rawText: source.rawText, result }))).toThrow(/quote/);
    result.living_memory.notes[0].quote = source.rawText;
    result.open_questions.push(result.open_questions[0]);
    expect(() => invoke('validateJournal', JSON.stringify({ rawText: source.rawText, result }))).toThrow();
  });
  it('runs the actual iOS bundle without Node, fetch, filesystem, or browser globals', () => {
    const bundle = readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js', import.meta.url), 'utf8');
    const sandbox: Record<string, any> = {};
    runInNewContext(bundle, sandbox, { timeout: 5000 });
    const call = sandbox.DailyXAnalysis.invoke;
    const checked = sandbox.DailyXAnalysis.invokeChecked;
    expect(JSON.parse(checked('prepareJournal', JSON.stringify(source)))).toEqual(JSON.parse(invokeChecked('prepareJournal', JSON.stringify(source))));
    expect(JSON.parse(checked('validateJournal', '{}')).error.code).toBe('schema_validation');
    expect(JSON.parse(call('prepareJournal', JSON.stringify(source)))).toEqual(JSON.parse(invoke('prepareJournal', JSON.stringify(source))));
    const finalSource = JSON.stringify({...source,answers:['İyi geldi.'],answerQuestions:['Nasıl hissettin?'],
      previousDayReflection:'İlk yorum burada.',finishingQuestionSession:true});
    expect(call('prepareJournal', finalSource)).toBe(invoke('prepareJournal', finalSource));
    const memory = exportPortableMemory(snapshot(), 1);
    expect(JSON.parse(call('validateMemory', JSON.stringify(memory)))).toEqual(memory);
    expect(JSON.parse(call('validateJournal', JSON.stringify({ rawText: source.rawText, result: analysis() })))).toEqual(analysis());
  });
  it('rejects missing context structure and unknown commands', () => {
    expect(() => invoke('prepareJournal', '{}')).toThrow();
    expect(() => invoke('runShell', '{}')).toThrow();
  });
  it('continues an earlier same-day reflection in both journal phases', () => {
    const previousDayReflection = 'İlk yorum: yürüyüş sana iyi gelmiş.';
    const rawText = source.rawText + '\n\nAkşam yine yürüyüşe çıktım.';
    const input = {...source, rawText, previousDayReflection};
    const initial = JSON.parse(invoke('prepareJournal', JSON.stringify(input)));
    expect(initial.input[0].content).toContain(rawText);
    expect(initial.input[0].content.split(previousDayReflection)).toHaveLength(2);
    const final = JSON.parse(invoke('prepareJournal', JSON.stringify({...input,finishingQuestionSession:true})));
    expect(JSON.parse(final.input[0].content)).toMatchObject({userText:rawText, previousDayReflection});
    const first = JSON.parse(invoke('prepareJournal', JSON.stringify({...source,finishingQuestionSession:true})));
    expect(JSON.parse(first.input[0].content)).not.toHaveProperty('previousDayReflection');
  });
  it('tells the model to finish the reflection with the answers and leave personal questions closed', () => {
    const answer = 'Yürüyüşten sonra sakinleştim.';
    const longAnswer = 'İkinci yanıtın tamamı. '.repeat(100)+'SON';
    const history = {mapCatalog: [{id:'cluster:dinlenme',title:'Dinlenme'}],
      existingGraphNotNewEvidence: [{id:'node-one',label:'Yürüyüş'}]};
    const memoryContext = JSON.stringify({...history,currentUserAnswers:[{question:'İlk soru?',answer}]});
    const input = {...source,memoryContext,answers:[answer,longAnswer]};
    const initial = invoke('prepareJournal', JSON.stringify(input));
    const final = invoke('prepareJournal', JSON.stringify({...input,finishingQuestionSession:true}));
    expect(Buffer.byteLength(final)).toBeLessThan(Buffer.byteLength(initial)*0.65);
    const request = JSON.parse(final);
    const content = JSON.parse(request.input[0].content);
    expect(request.instructions).toContain('open_questions boş olsun.');
    expect(content.userText).toBe(source.rawText);
    expect(content.historyContext).toEqual(history);
    expect(content.userAnswers).toEqual([{question:'İlk soru?',answer},{answer:longAnswer}]);
    expect(final.split(answer)).toHaveLength(2);
    expect(content.outputSchema.required).toEqual(expect.arrayContaining(['reflection','living_memory','emotional_memory']));
    expect(content.outputSchema.properties.living_memory.properties.notes).toBeDefined();
    expect(content.outputSchema.properties.boolean_questions.items.anyOf).toHaveLength(2);
    const fullQuestions = JSON.parse(invoke('prepareJournal', JSON.stringify({...input,finishingQuestionSession:true,
      answerQuestions:['İlk soru?','Uzun yanıtın sorusu?']})));
    expect(JSON.parse(fullQuestions.input[0].content).userAnswers)
      .toEqual([{question:'İlk soru?',answer},{question:'Uzun yanıtın sorusu?',answer:longAnswer}]);
  });

  it('validates final answers with only functional consents and returns a reusable canonical result', () => {
    const answer = 'Yarın 18:00 yürüyüş hatırlatması iyi olur.';
    const {reflection,confidence,connections,living_memory} = analysis();
    const result = {reflection,confidence,connections,living_memory,emotional_memory:{observations:[],helpful:[]},
      open_questions:[],boolean_questions:[
        {purpose:'reminder_consent',prompt:'Yürüyüşü hatırlatayım mı?',rationale:'Yürüyüş planı',source_ref:source.journalId,
          reminder_proposal:{title:'Yürüyüş',details:'',quote:answer,
            schedule:{startDate:'2026-10-01',endDate:null,time:'18:00',durationMinutes:null,frequency:'once',
              interval:1,weekdays:[],reminderMinutes:0,timezone:'Europe/Istanbul'}}},
        {purpose:'emotion_consent',prompt:'Takvime huzur ekleyeyim mi?',rationale:'Yürüyüş sonrası',source_ref:source.journalId,
          emotion_proposal:{key:'calm',label:'Huzur',quote:'İçim huzur doldu.'}},
      ]};
    const rawText = source.rawText+' İçim huzur doldu.';
    const input = {rawText,answers:[answer],result,finishingQuestionSession:true};
    const validated = invoke('validateJournal',JSON.stringify(input));
    const canonical = JSON.parse(validated);
    expect(canonical.events).toEqual([]);
    expect(canonical.boolean_questions).toEqual(result.boolean_questions);
    expect(invoke('validateJournal',JSON.stringify({...input,result:validated}))).toBe(validated);
    const secondText = ' İkinci bölüm.';
    const secondResult = {...canonical,reflection:'İkinci bölümün yorumu.',boolean_questions:[result.boolean_questions[0]],
      living_memory:{...canonical.living_memory,notes:[]}};
    const mergedResult = invoke('mergeJournalParts',JSON.stringify({
      parts:[{rawText,result:canonical},{rawText:secondText,result:secondResult}],answers:[answer],
    }));
    expect(JSON.parse(invoke('validateJournal',JSON.stringify({...input,rawText:rawText+secondText,result:mergedResult}))).boolean_questions)
      .toHaveLength(2);
    const invalid = {...result,boolean_questions:analysis().boolean_questions};
    expect(JSON.parse(invokeChecked('validateJournal',JSON.stringify({...input,result:invalid}))).error.code).toBe('schema_validation');
    expect(JSON.parse(invokeChecked('validateJournal',JSON.stringify({...input,rawText:source.rawText}))).error.code)
      .toBe('unsupported_emotion_quote');
  });

  it('repairs only questions after accepting a grounded reflection',()=>{
    const partial=analysis();partial.open_questions=[];
    const repair=JSON.parse(invoke('prepareQuestionRepair',JSON.stringify({rawText:source.rawText,answers:[],
      journalID:'journal-one',result:partial})));
    expect(repair.base.reflection).toBe(partial.reflection);
    const schema = JSON.parse(repair.input[0].content).questionSchema;
    expect(schema.type).toBe('object');
    expect(schema.required).toEqual(expect.arrayContaining(['open_questions', 'boolean_questions']));
    expect(schema.properties.open_questions.type).toBe('array');
    expect(schema.properties.boolean_questions.type).toBe('array');
    const complete=analysis();
    const repaired=JSON.parse(invoke('completeQuestionRepair',JSON.stringify({rawText:source.rawText,answers:[],
      base:repair.base,questions:{open_questions:complete.open_questions,boolean_questions:complete.boolean_questions}})));
    expect(repaired).toEqual(complete);
    partial.living_memory.notes[0].quote='Uydurulmuş kanıt';
    expect(()=>invoke('prepareQuestionRepair',JSON.stringify({rawText:source.rawText,answers:[],
      journalID:'journal-one',result:partial}))).toThrow(/quote/);
  });
});
