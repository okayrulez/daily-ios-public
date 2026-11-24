import {describe,it,expect} from 'vitest';
import {selectContext,emptyMemory} from '../src/shared/mobile-pipeline.js';
import {exportPortableMemory} from '../src/main/memory/portable-memory-export.js';
import {snapshot} from './fixtures.js';
import {invoke,invokeChecked} from '../src/shared/mobile-analysis-core.js';
import {canonicalJson,hash} from '../src/shared/mobile-json.js';
import {applyAppActions} from '../src/shared/app-actions.js';
import {previousTaskContext} from '../src/shared/compact-context.js';

const journal=()=>({entry:{id:'compact-journal',local_date:'2026-11-12',raw_text:'Yürüyüş ve dinlenme planımı değerlendir.',
  content_hash:hash('Yürüyüş ve dinlenme planımı değerlendir.'),saved_at:'2026-11-12T08:00:00Z',analysis_status:'pending',analysis_error:null},
  analyses:[],questions:[]});
const call=(name:string,input:unknown)=>JSON.parse(invoke(name,JSON.stringify(input)));

describe('compact stage-specific personal context',()=>{
  it('summarizes clusters and bounds historical context independently of graph size',()=>{
    const memory=exportPortableMemory(snapshot(),1),node=memory.graph.nodes[0];
    memory.graph.nodes=Array.from({length:400},(_,i)=>({...node,id:'node-'+i,key:'key-'+i,
      topicId:'topic-'+(i%20),topicPath:['Küme '+(i%20)],description:'HISTORY_DETAIL '.repeat(300),
      evidence:[{...node.evidence[0],observation:'HISTORY_OBSERVATION '.repeat(200)}]}));
    memory.graph.edges=[];
    const text=selectContext(memory,journal()),context=JSON.parse(text);
    expect(text.length).toBeLessThanOrEqual(14000);
    expect(context.mapSummaries.length).toBeGreaterThan(0);
    expect(context.mapSummaries[0]).toHaveProperty('summary');
    expect(context.mapSummaries[0]).toHaveProperty('nodeCount');
    expect(context.existingGraphNotNewEvidence.length).toBeLessThanOrEqual(8);
    expect(text).not.toContain('HISTORY_DETAIL '.repeat(50));
    expect(memory.graph.nodes).toHaveLength(400);
  });
  it('keeps the router to cluster summaries and reserves action schemas and node details for execution',()=>{
    const context=JSON.stringify({currentDate:'2026-11-12',timezone:'Europe/Istanbul',
      mapSummaries:[{id:'map-work',title:'Çalışma',nodeCount:80,summary:'Yazı üslubu ve üretim alışkanlıkları'}],
      existingGraphNotNewEvidence:[{id:'node-1',description:'PRIVATE_DEEP_DETAIL'.repeat(800)}],
      appMapTargets:[{id:'node-1',label:'Çalışma'}]});
    const route=call('prepareTask',{journal:journal(),memoryContext:context});
    const input=JSON.parse(route.input[0].content);
    expect(input.appActionSchema).toBeUndefined();
    expect(route.input[0].content).not.toContain('PRIVATE_DEEP_DETAIL');
    expect(route.input[0].content).toContain('üretim alışkanlıkları');
    expect(route.input[0].content.length).toBeLessThan(5000);
    const execution=call('prepareTaskExecution',{journal:journal(),memoryContext:context,
      decision:{action:'respond',goal:'Yazı hazırla',reply:'',questions:[]}});
    const executeInput=JSON.parse(execution.input[0].content);
    expect(executeInput.appActionSchema).toBeUndefined();
    expect(JSON.stringify(executeInput.outputSchema)).not.toContain('agenda_cancel');
  });
  it('passes current written answers without shortening while excluding duplicated report history',()=>{
    const j:any=journal(),longAnswer='GÜNCEL_YANIT '.repeat(700);
    const decision={action:'respond',goal:'Yazı hazırla',reply:'',questions:[]};
    const previous=call('finishTask',{journal:j,decision,response:{text:JSON.stringify({
      status:'completed',reply:'OLD_REPORT '.repeat(4000)+'LAST_PARAGRAPH',findings:[]}),webSearchCalls:0,citations:[]}});
    j.daily_task=previous;
    j.supplemental_answers=[{id:'new-answer',question:'Ne ekleyelim?',answer:longAnswer}];
    const route=JSON.parse(call('prepareTask',{journal:j}).input[0].content);
    expect(route.userAnswers[0].answer).toBe(longAnswer);
    expect(JSON.stringify(route.previousTask).length).toBeLessThan(2500);
    expect(route.previousTask).not.toHaveProperty('contextAnswers');
    const editing=JSON.parse(call('prepareTaskExecution',{journal:j,decision}).input[0].content);
    expect(editing.previousOutput).toBe(previous.reply);
    const prompt=call('prepareJournal',{journalId:j.entry.id,localDate:j.entry.local_date,
      rawText:j.entry.raw_text,workContext:'',memoryContext:'{}',answers:[longAnswer]});
    expect(prompt.input[0].content).toContain(longAnswer);
  });
  it('prioritizes the requested existing agenda event over a large unrelated calendar',()=>{
    let memory=emptyMemory();
    const quote=journal().entry.raw_text;
    for(let i=0;i<30;i++)memory=applyAppActions(memory,[{
      tool:'agenda_create',title:i===29?'Yürüyüş':'İlgisiz toplantı '+i,details:'',quote,
      schedule:{startDate:'2026-11-12',endDate:null,time:'18:00',durationMinutes:30,
        frequency:'once',interval:1,weekdays:[],reminderMinutes:null,timezone:'Europe/Istanbul'},
    }],[quote],'source','2026-11-12T08:00:00Z','job-'+i).memory;
    const context=JSON.parse(selectContext(memory,journal()));
    expect(context.agendaEvents[0].title).toBe('Yürüyüş');
    expect(JSON.stringify(context).length).toBeLessThanOrEqual(14000);
    const execute=call('prepareTaskExecution',{journal:journal(),memoryContext:JSON.stringify(context),
      decision:{action:'manage',goal:'Yürüyüş planını değiştir',reply:'',questions:[]}});
    expect(JSON.parse(JSON.parse(execute.input[0].content).memoryContext).agendaEvents[0].title).toBe('Yürüyüş');
  });
  it('retains relevant cited research details without resending the growing research archive',()=>{
    const findings=Array.from({length:30},(_,i)=>({label:'Old topic '+i,
      detail:'UNRELATED_ARCHIVE '.repeat(180),urls:['https://example.com/old/'+i]}));
    findings.push({label:'Swimming schedule',detail:'Swimming is available Tuesday at 18:00.',
      urls:['https://example.com/swimming/timetable']});
    const context=previousTaskContext({action:'research',status:'in_progress',goal:'Find a swimming schedule',
      reply:'ARCHIVED_REPORT '.repeat(3000),round:2,nextQueries:['Swimming booking'],findings},'Swimming booking');
    expect(JSON.stringify(context).length).toBeLessThan(4500);
    expect(context?.findings).toContainEqual({label:'Swimming schedule',
      detail:'Swimming is available Tuesday at 18:00.',urls:['https://example.com/swimming/timetable']});
    expect(JSON.stringify(context)).not.toContain('ARCHIVED_REPORT '.repeat(40));
  });
  it('keeps unanswered management clarification without claiming that a change was made',()=>{
    const result=call('finishTask',{journal:journal(),decision:{action:'manage',goal:'Ajandayı düzenle',reply:'',questions:[]},
      response:{text:JSON.stringify({status:'completed',reply:'Hangi günü değiştireyim?',
        questions:['Hangi gün?'],findings:[],operations:[]}),webSearchCalls:0,citations:[]}});
    expect(result).toMatchObject({action:'clarify',status:'needs_input',operations:[],questions:['Hangi gün?']});
    const failure=JSON.parse(invokeChecked('finishTask',JSON.stringify({journal:journal(),
      decision:{action:'manage',goal:'Ajandayı düzenle',reply:'',questions:[]},
      response:{text:JSON.stringify({status:'completed',reply:'Yapıldı.',findings:[]}),webSearchCalls:0,citations:[]}})));
    expect(failure.error.issues).toContain('custom:root:task_missing_operations');
  });
});
