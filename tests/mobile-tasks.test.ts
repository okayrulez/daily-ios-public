import { describe, expect, it } from 'vitest';
import { invoke } from '../src/shared/mobile-analysis-core.js';
import { canonicalJson, hash } from '../src/shared/mobile-json.js';
import { emptyMemory } from '../src/shared/mobile-pipeline.js';
import { agendaCards } from '../src/shared/mobile-agenda.js';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const call = (name:string, value:unknown) => JSON.parse(invoke(name,JSON.stringify(value)));
const journal = () => ({entry:{id:'journal-task',local_date:'2026-10-05',raw_text:'Instagramımı ayrıntılı araştır',
  content_hash:hash('Instagramımı ayrıntılı araştır'),saved_at:'2026-10-05T09:00:00Z',analysis_status:'pending',analysis_error:null},analyses:[],questions:[]});
const route = {action:'clarify',goal:'Instagram profilini araştır',reply:'Hangi profili inceleyeyim?',questions:['Profil adresin nedir?']};
const completed = {status:'completed',reply:'Profil hakkında kaynaklı rapor.',findings:[{label:'Profil',detail:'Herkese açık içerik.',
  urls:['https://www.instagram.com/example/']}]};
const transport = {text:JSON.stringify(completed),webSearchCalls:1,citations:[{url:'https://www.instagram.com/example/',title:'Profil'}]};
const finish = (j:unknown, decision=route, response:unknown=null) => call('finishTask',{journal:j,decision,response});
const apply = (j:unknown,result:unknown,memory=emptyMemory()) => call('applyTask',{journal:j,result,memory,
  expectedSourceHash:hash(canonicalJson(j)),expectedMemoryHash:hash(canonicalJson(memory)),jobID:hash(canonicalJson(result)),model:'fixture',now:'2026-10-05T09:01:00Z'});

describe('Daily tasks',()=>{
  it('repairs three separate daily reminders using only original journal and answer quotes', () => {
    const original = journal();
    const morning = 'Her gün 08:00 iş hazırlığı';
    const lunch = 'Her gün 12:00 öğle yemeği';
    const evening = 'Her gün 19:00 buz pateni';
    original.entry.raw_text = morning + '. ' + lunch + '.';
    original.entry.content_hash = hash(original.entry.raw_text);
    const j = {...original, questions: [{
      id: 'ask-evening', journal_id: original.entry.id, kind: 'open', position: 0,
      prompt: 'Akşam ne zaman?', rationale: 'Saati netleştir', source_ref: original.entry.id,
      answer_text: evening, answer_boolean: null,
    }]};
    const decision = {...route, action: 'manage', goal: 'Üç ayrı günlük hatırlatma', questions: []};
    const schedule = (time: string) => ({
      startDate: '2026-10-06', endDate: null, time, durationMinutes: null, frequency: 'daily',
      interval: 1, weekdays: [], reminderMinutes: 0, timezone: 'Europe/Istanbul',
    });
    const proposals = ['İş hazırlığı', 'Öğle yemeği', 'Buz pateni'].map((title, index) => ({
      title, details: '', quote: 'Modelin yeniden yazdığı ifade ' + index,
      schedule: schedule(['08:00', '12:00', '19:00'][index]),
    }));
    const response = {
      status: 'completed', reply: 'Hatırlatmalar hazır.', findings: [],
      reminderProposals: proposals.slice(0, 2), operations: [{tool: 'agenda_create', ...proposals[2]}],
    };
    const output = JSON.stringify(response);
    const wrap = (text: string) => ({text, webSearchCalls: 0, citations: []});
    expect(() => apply(j, finish(j, decision, wrap(output)))).toThrow('Unsupported reminder quote');
    const plainOperation = {...response.operations[0], schedule: {...proposals[2].schedule, reminderMinutes: null}};
    const plainOutput = JSON.stringify({...response, operations: [plainOperation], reminderProposals: []});
    expect(() => apply(j, finish(j, decision, wrap(plainOutput)))).toThrow('Unsupported action quote');
    const fixedPlan = call('finishAgendaQuoteRepair', {
      journal: j, output: plainOutput, repair: JSON.stringify({quotes: [evening]}),
    });
    expect(apply(j, finish(j, decision, wrap(JSON.stringify(fixedPlan)))).memory.agenda[0])
      .toMatchObject({title: 'Buz pateni', schedule: plainOperation.schedule});
    const request = call('prepareAgendaQuoteRepair', {journal: j, output});
    expect(request.webResearch).toBe(false);
    expect(JSON.parse(request.input[0].content).sources).toEqual([j.entry.raw_text, evening]);
    const repair = (quotes: Array<string | null>) =>
      call('finishAgendaQuoteRepair', {journal: j, output, repair: JSON.stringify({quotes})});
    const corrected = repair([evening, morning, lunch]);
    expect(corrected.operations[0]).toEqual({...response.operations[0], quote: evening});
    expect(corrected.reminderProposals).toEqual([
      {...proposals[0], quote: morning}, {...proposals[1], quote: lunch},
    ]);
    const prepared = apply(j, finish(j, decision, wrap(JSON.stringify(corrected))));
    expect(prepared.memory.agenda ?? []).toEqual([]);
    expect(prepared.journal.questions.map((q: any) => q.reminder_proposal.schedule.time)).toEqual(['08:00', '12:00', '19:00']);
    for (const q of prepared.journal.questions) q.answer_boolean = 1;
    const replay = call('prepareTask', {journal: prepared.journal}).reuse;
    const saved = apply(prepared.journal, replay, prepared.memory);
    expect(saved.memory.agenda.map((item: any) => [item.title, item.schedule.time, item.schedule.frequency]))
      .toEqual([['İş hazırlığı', '08:00', 'daily'], ['Öğle yemeği', '12:00', 'daily'], ['Buz pateni', '19:00', 'daily']]);
    expect(() => repair(['Akşam ne zaman?', morning, lunch])).toThrow('Unsupported action quote');
    const clarify = finish(j, decision, wrap(JSON.stringify(repair([null, morning, lunch]))));
    expect(clarify).toMatchObject({status: 'needs_input', operations: [], reminderProposals: []});
    expect(clarify.questions[0]).toContain('Buz pateni');
  });

  it('saves research map descriptions with sourced findings in the existing commit',()=>{
    const j=journal(),response={...transport,text:JSON.stringify({...completed,
      findings:[{...completed.findings[0],topicPath:['Dijital üretim']}],
      map_summaries:[{title:'Dijital üretim',summary:'Kaynaklarla doğrulanan dijital üretim çalışmaları.'}]})};
    const result=finish(j,{...route,action:'research',questions:[]},response);
    const saved=apply(j,result);
    expect(saved.memory.maps.find((m:any)=>m.title==='Dijital üretim')).toMatchObject({
      description:'Kaynaklarla doğrulanan dijital üretim çalışmaları.',descriptionSource:'analysis'});
    expect(saved.memory.sources[0].researchSources).toEqual(transport.citations);
  });
  it('routes real user requests separately from diary schemas without enabling tools during routing',()=>{
    const p=call('prepareTask',{journal:journal()});
    expect(p.input[0].content).toContain('Instagramımı');
    expect(p.tools).toBeUndefined();
    expect(p.input[0].role).toBe('user');
    expect(p.instructions).toContain('Günlük sorularının yanıtları');
    expect(p.instructions).toContain('research');
    expect(call('prepareTask',{journal:journal(),memoryContext:'Bilinen profil: @example'}).input[0].content).toContain('Bilinen profil');
  });
  it('persists clarification, reuses unchanged input and continues with answers',()=>{
    const a=apply(journal(),finish(journal()));
    expect(a.journal.questions).toHaveLength(1);
    expect(call('prepareTask',{journal:a.journal}).reuse.status).toBe('needs_input');
    a.journal.questions[0].answer_text='https://www.instagram.com/example/';
    const next=call('prepareTask',{journal:a.journal});
    expect(next.reuse).toBeUndefined();
    expect(next.input[0].content).toContain('https://www.instagram.com/example/');
    expect(next.input[0].content).toContain(route.goal);
  });
  it('publishes a question notification for clarification but never re-notifies a reused result',()=>{
    const first=apply(journal(),finish(journal()));
    expect(first.cards).toHaveLength(1);
    const card=JSON.parse(JSON.parse(first.cards[0].content));
    expect(card.id).toBe('journal_questions_2026-10-05');
    expect(card.notBefore).toBe(first.journal.questions_generated_at);
    const again=apply(first.journal,call('prepareTask',{journal:first.journal}).reuse,first.memory);
    expect(again.cards).toEqual([]);
    expect(again.journal.questions_generated_at).toBe(first.journal.questions_generated_at);
  });
  it('turns a task reminder proposal into an unanswered consent question without creating an event',()=>{
    const proposal={title:'Profilini incele',details:'Paylaşımlarını değerlendir',quote:'Instagramımı ayrıntılı araştır',
      schedule:{startDate:'2026-10-06',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,
        weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}};
    const result=finish(journal(),{...route,action:'respond',questions:[]},{text:JSON.stringify({status:'completed',reply:'Bir öneri hazırladım.',findings:[],reminderProposals:[proposal]}),webSearchCalls:0,citations:[]});
    const saved=apply(journal(),result);
    expect(saved.journal.questions[0].kind).toBe('boolean');
    expect(saved.journal.questions[0].answer_boolean).toBeNull();
    expect(saved.journal.questions[0].prompt).toContain('18:00');
    expect(saved.memory.agenda??[]).toEqual([]);
    expect(saved.cards).toHaveLength(1);
  });
  it('stores provider-sourced research as research, not a personal user quote',()=>{
    const decision={...route,action:'research',questions:[]};
    const result=finish(journal(),decision,transport);
    const a=apply(journal(),result);
    expect(a.journal.daily_task.status).toBe('completed');
    expect(a.journal.questions).toEqual([]);
    expect(a.memory.sources[0].kind).toBe('research');
    expect(a.memory.graph.nodes[0].evidence[0].sourceKind).toBe('research');
    expect(a.memory.graph.nodes[0].evidence[0].observation).toContain('https://www.instagram.com/example/');
    expect(call('prepareCrossMap',a.memory).selectedIDs).toEqual([]);
    expect(a.atlas.length).toBeGreaterThan(0);
    expect(()=>call('validateMemory',a.memory)).not.toThrow();
  });
  it('rejects invented URLs and research without actual search evidence',()=>{
    const decision={...route,action:'research',questions:[]};
    expect(()=>finish(journal(),decision,{...transport,webSearchCalls:0})).toThrow();
    expect(()=>finish(journal(),decision,{...transport,citations:[]})).toThrow();
    expect(()=>finish(journal(),decision,{...transport,text:JSON.stringify({...completed,findings:[{...completed.findings[0],urls:['https://fake.example/']}]})})).toThrow();
  });
  it('reports blocked research without inventing map nodes, keeps plain writing tasks tool-free',()=>{
    const blocked={...transport,webSearchCalls:0,citations:[],text:JSON.stringify({status:'blocked',reply:'Profil erişime kapalı.',findings:[]})};
    expect(apply(journal(),finish(journal(),{...route,action:'research',questions:[]},blocked)).memory.graph.nodes).toEqual([]);
    const prepared=call('prepareTaskExecution',{journal:journal(),decision:{...route,action:'respond',questions:[]}});
    expect(prepared.webResearch).toBe(false);
  });
  it('rejects stale source/memory and a task bound to edited text',()=>{
    const j=journal(),result=finish(j);
    const edited={...j,entry:{...j.entry,raw_text:'Başka görev',content_hash:hash('Başka görev')}};
    expect(()=>apply(edited,result)).toThrow();
    expect(()=>call('applyTask',{journal:j,result,memory:emptyMemory(),expectedSourceHash:hash('stale'),
      expectedMemoryHash:hash(canonicalJson(emptyMemory())),jobID:hash('job'),model:'fixture',now:'2026-10-05T09:01:00Z'})).toThrow();
  });
  it('runs routing and research commit in the actual iOS JS bundle',()=>{
    const sandbox:Record<string,any>={};
    runInNewContext(readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js',import.meta.url),'utf8'),sandbox,{timeout:5000});
    const args={journal:journal(),decision:{...route,action:'research',questions:[]},response:transport};
    expect(JSON.parse(sandbox.DailyXAnalysis.invoke('finishTask',JSON.stringify(args)))).toEqual(call('finishTask',args));
    expect(JSON.parse(sandbox.DailyXAnalysis.invoke('prepareTask',JSON.stringify({journal:journal()})))).toEqual(call('prepareTask',{journal:journal()}));
  });
  it('keeps earlier clarification answers across multiple rounds and retries blocked tasks',()=>{
    const first=apply(journal(),finish(journal())).journal;
    first.questions[0].answer_text='@example';
    const second=apply(first,finish(first,{...route,questions:['Hangi dönemi?']})).journal;
    second.questions[0].answer_text='Son üç ay';
    const prompt=call('prepareTask',{journal:second}).input[0].content;
    expect(prompt).toContain('@example');expect(prompt).toContain('Son üç ay');
    const result=finish(second,{...route,action:'blocked',reply:'Erişilemiyor',questions:[]});
    const blocked=apply(second,result).journal;
    expect(call('prepareTask',{journal:blocked}).reuse).toBeUndefined();
  });
  it('does not spend another research request on unchanged completed tasks or duplicate map notes',()=>{
    const result=finish(journal(),{...route,action:'research',questions:[]},transport);
    const a=apply(journal(),result);
    const cached=call('prepareTask',{journal:a.journal}).reuse;
    expect(cached).toEqual(result);
    a.memory.graph.nodes[0].corrections=[{id:'correction-one',nodeId:a.memory.graph.nodes[0].id,
      text:'Bu yorum doğru değil',verdict:'incorrect',createdAt:'2026-10-05T09:02:00Z'}];
    const b=apply(a.journal,cached,a.memory);
    expect(b.memory.graph.nodes).toEqual(a.memory.graph.nodes);
    expect(b.memory.sources).toEqual(a.memory.sources);
    expect(b.journal.analyses).toHaveLength(1);
  });
  it('can store a long report plus twenty detailed findings without exceeding source size',()=>{
    const report={...completed,reply:'R'.repeat(50000),
      findings:Array.from({length:20},(_,i)=>({...completed.findings[0],label:'Bulgu '+i,detail:String(i)+'x'.repeat(3990)}))};
    const result=finish(journal(),{...route,action:'research',questions:[]},{...transport,text:JSON.stringify(report)});
    const saved=apply(journal(),result);
    expect(saved.memory.graph.nodes).toHaveLength(20);
    expect(saved.journal.daily_task.reply).toHaveLength(50000);
    expect(saved.memory.sources[0].text.length).toBeLessThan(100000);
  });
  it('continues sourced research across Firebase stages beyond twenty findings, with bounded journal history',()=>{
    let j:any=journal(),memory=emptyMemory();
    for(let stage=0;stage<3;stage++){
      const report={status:stage===2?'completed':'in_progress',reply:'Aşama '+stage+' '+ 'R'.repeat(30000),
        findings:Array.from({length:50},(_,i)=>({...completed.findings[0],label:'Bulgu '+stage+'-'+i,
          detail:stage+'-'+i+' '+'x'.repeat(2800),topicPath:['İlgi alanları','Üretim']})),
        nextQueries:stage===2?[]:['Diğer kaynakları karşılaştır']};
      const result=finish(j,{...route,action:'research',questions:[]},{...transport,text:JSON.stringify(report)});
      expect(result.round).toBe(stage+1);
      const saved=apply(j,result,memory);j=saved.journal;memory=saved.memory;
      expect(saved.atlas.some((r:any)=>r.key.startsWith('note:dailyx/tasks/'))).toBe(true);
      expect(j.analyses.at(-1).task_report_key).toMatch(/^note:dailyx\/tasks\//);
      expect(j.analyses.at(-1).result).toBeUndefined();
      if(stage<2)expect(call('prepareTask',{journal:j}).decision.action).toBe('research');
    }
    expect(memory.graph.nodes).toHaveLength(150);
    expect(memory.sources.every(s=>s.text.length<100000)).toBe(true);
    expect(canonicalJson(j).length).toBeLessThan(210000);
    expect(call('prepareTask',{journal:j}).reuse.status).toBe('completed');
  });
  it('stops repeated research stages without removing earlier findings',()=>{
    const report={...completed,status:'in_progress',nextQueries:['Daha fazla kaynak']};
    const decision={...route,action:'research',questions:[]};
    const first=apply(journal(),finish(journal(),decision,{...transport,text:JSON.stringify(report)}));
    const second=apply(first.journal,finish(first.journal,decision,{...transport,text:JSON.stringify(report)}),first.memory);
    expect(second.journal.daily_task.status).toBe('completed');
    expect(second.journal.daily_task.reply).toContain('yeni bulgu elde edilemedi');
    expect(second.memory.graph.nodes).toHaveLength(1);
    expect(second.memory.sources).toEqual(first.memory.sources);
  });
  it('keeps stage identities monotonic after a blocked stage and successful retry',()=>{
    const decision={...route,action:'research',questions:[]};
    const first=apply(journal(),finish(journal(),decision,{...transport,text:JSON.stringify({
      ...completed,status:'in_progress',nextQueries:['Devam et']})}));
    const blocked=apply(first.journal,finish(first.journal,decision,{text:JSON.stringify({
      status:'blocked',reply:'Kaynağa erişilemedi.',findings:[]}),webSearchCalls:0,citations:[]}),first.memory);
    const retry=finish(blocked.journal,decision,{...transport,text:JSON.stringify({...completed,
      findings:[{...completed.findings[0],detail:'Yeni kaynaklı bulgu'}]})});
    expect(retry.round).toBe(3);
    const saved=apply(blocked.journal,retry,blocked.memory);
    expect(saved.memory.graph.nodes).toHaveLength(2);
    expect(saved.memory.sources).toHaveLength(2);
  });
  it('only reports app changes after applying validated operations and keeps them on replay',()=>{
    const j=journal();j.entry.raw_text='Salı perşembe spor yapıyorum';j.entry.content_hash=hash(j.entry.raw_text);
    const decision={...route,action:'manage',questions:[]};
    const op={tool:'agenda_create',quote:j.entry.raw_text,title:'Spor',details:'',schedule:{
      startDate:'2026-10-05',endDate:null,time:null,durationMinutes:null,frequency:'weekly',interval:1,
      weekdays:[2,4],reminderMinutes:null,timezone:'Europe/Istanbul'}};
    const result=finish(j,decision,{text:JSON.stringify({status:'completed',reply:'İşlemler hazır.',findings:[],operations:[op]}),webSearchCalls:0,citations:[]});
    const saved=apply(j,result);
    expect(saved.memory.agenda).toHaveLength(1);
    expect(saved.journal.daily_task.reply).toContain('Ajandaya eklendi: Spor');
    const replay=apply(saved.journal,call('prepareTask',{journal:saved.journal}).reuse,saved.memory);
    expect(replay.memory.agenda).toEqual(saved.memory.agenda);
    expect(replay.journal.analyses).toHaveLength(1);
    expect(()=>finish(j,decision,{text:JSON.stringify({status:'completed',reply:'Yapıldı',findings:[]}),webSearchCalls:0,citations:[]})).toThrow();
  });
  it('persists a reminder timing question after creating an event and updates that event after the answer',()=>{
    const j=journal();j.entry.raw_text='Yarın saat yedide buz patenindeyim, bildirim ekle';j.entry.content_hash=hash(j.entry.raw_text);
    const decision={...route,action:'manage',goal:'Buz pateni ve bildirim',questions:[]};
    const op={tool:'agenda_create',quote:j.entry.raw_text,title:'Buz pateni',details:'',schedule:{
      startDate:'2026-10-06',endDate:null,time:'19:00',durationMinutes:null,frequency:'once',interval:1,
      weekdays:[],reminderMinutes:null,timezone:'Europe/Istanbul'}};
    const response={text:JSON.stringify({status:'completed',reply:'Etkinlik hazır. Kaç dakika önce bildirim gelsin?',
      questions:['Buz pateni için bildirim kaç dakika önce gelsin?'],findings:[],operations:[op]}),webSearchCalls:0,citations:[]};
    const result=finish(j,decision,response),saved=apply(j,result);
    expect(saved.memory.agenda).toHaveLength(1);
    expect(saved.memory.agenda![0].schedule.reminderMinutes).toBeNull();
    expect(agendaCards(saved.memory.agenda!, '2026-10-05T09:01:00Z')).toEqual([]);
    expect(saved.journal.daily_task.reply).toContain('Bu kayıtta bildirim zamanı yok: Buz pateni');
    expect(saved.journal.questions).toHaveLength(1);
    expect(saved.journal.questions[0]).toMatchObject({kind:'open',answer_text:null,prompt:'Buz pateni için bildirim kaç dakika önce gelsin?'});
    expect(saved.cards).toHaveLength(1);
    const replay=apply(saved.journal,call('prepareTask',{journal:saved.journal}).reuse,saved.memory);
    expect(replay.journal.questions).toEqual(saved.journal.questions);
    expect(replay.cards).toEqual([]);
    saved.journal.questions[0].answer_text='30 dakika önce';
    expect(call('prepareTask',{journal:saved.journal}).reuse).toBeUndefined();
    const updated=finish(saved.journal,decision,{text:JSON.stringify({status:'completed',reply:'Bildirim zamanı hazır.',
      findings:[],questions:[],operations:[{...op,tool:'agenda_update',id:saved.memory.agenda![0].id,
        quote:'30 dakika önce',schedule:{...op.schedule,reminderMinutes:30}}]}),webSearchCalls:0,citations:[]});
    const final=apply(saved.journal,updated,saved.memory);
    expect(final.memory.agenda).toHaveLength(1);
    expect(final.memory.agenda![0].schedule.reminderMinutes).toBe(30);
    expect(agendaCards(final.memory.agenda!, '2026-10-05T09:01:00Z')).toEqual([
      expect.objectContaining({notBefore:'2026-10-06T15:30:00.000Z',title:'Buz pateni'})]);
    expect(final.journal.question_history).toContainEqual(expect.objectContaining({answer_text:'30 dakika önce'}));
    expect(final.journal.questions).toEqual([]);
    const sandbox:Record<string,any>={};
    runInNewContext(readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js',import.meta.url),'utf8'),sandbox,{timeout:5000});
    expect(JSON.parse(sandbox.DailyXAnalysis.invoke('finishTask',JSON.stringify({journal:j,decision,response})))).toEqual(result);
  });
  it('does not allow follow-up questions to interrupt an automatically continuing research stage',()=>{
    expect(()=>finish(journal(),{...route,action:'research',questions:[]},{...transport,text:JSON.stringify({
      ...completed,status:'in_progress',nextQueries:['Sonraki kaynak'],questions:['Devam edeyim mi?']})})).toThrow();
  });
});


it('turns direct alarm creation from a manage response into a yes/no proposal before any agenda write',()=>{
  const j=journal(),quote='Yarın 18:00 yürüyüşü hatırlat.';
  j.entry.raw_text=quote;j.entry.content_hash=hash(quote);
  const decision={action:'manage',goal:'Yürüyüş hatırlatması',reply:'',questions:[]};
  const response={text:JSON.stringify({status:'completed',reply:'Hatırlatma oluşturuldu.',findings:[],
    operations:[{tool:'agenda_create',quote,title:'Yürüyüş',details:'',schedule:{
      startDate:'2026-10-06',endDate:null,time:'18:00',durationMinutes:30,frequency:'once',interval:1,
      weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul'}}]}),webSearchCalls:0,citations:[]};
  const result=apply(j,finish(j,decision,response));
  expect(result.memory.agenda??[]).toEqual([]);
  expect(result.journal.questions).toHaveLength(1);
  expect(result.journal.questions[0]).toMatchObject({kind:'boolean',answer_boolean:null,reminder_proposal:{title:'Yürüyüş'}});
  expect(result.journal.daily_task.reply).toContain('onaylayabilirsin');
});
