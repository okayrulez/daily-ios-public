import {describe,it,expect} from 'vitest';
import {applyAppActions,applyGraphPreferences,type AppOperation} from '../src/shared/app-actions.js';
import {AgendaEntry,agendaCards,agendaRecord,occurs,upcomingAgenda} from '../src/shared/mobile-agenda.js';
import {emptyMemory,selectContext} from '../src/shared/mobile-pipeline.js';
import {PortableMemorySchema} from '../src/shared/portable-memory.js';
import {hash,canonicalJson} from '../src/shared/mobile-json.js';
import {invoke} from '../src/shared/mobile-analysis-core.js';

const now='2026-10-05T10:00:00.000Z';
const quote='Salı ve perşembe 18:00 spor; yarım saat önce hatırlat.';
const schedule={startDate:'2026-10-05',endDate:null,time:'18:00',durationMinutes:60,
  frequency:'weekly' as const,interval:1,weekdays:[2,4],reminderMinutes:30,timezone:'Europe/Istanbul' as const};
const create={tool:'agenda_create' as const,quote,title:'Spor',details:'',schedule};
const run=(ops:AppOperation[],memory=emptyMemory(),job='job')=>applyAppActions(memory,ops,[quote], 'journal-one',now,job);
const entry=()=>run([create]).memory.agenda![0];
describe('Firebase-backed app operations',()=>{
  it('creates a recurring series, projects it for other devices and never mutates its input',()=>{
    const before=emptyMemory(), next=run([create],before).memory;
    expect(before.agenda).toBeUndefined();
    expect(PortableMemorySchema.parse(next).agenda).toHaveLength(1);
    const projection=agendaRecord(next.agenda!);
    expect(projection.hash).toBe(hash(projection.content));
    expect(JSON.parse(JSON.parse(projection.content)).entries).toEqual(next.agenda);
    expect(upcomingAgenda({entries:next.agenda,from:'2026-10-05',days:10}).map(o=>o.date))
      .toEqual(['2026-10-06','2026-10-08','2026-10-13']);
    expect(run([create],next).memory.agenda).toHaveLength(1);
  });
  it('cancels one occurrence, restores it, cancels and restores an entire series',()=>{
    let memory=run([create]).memory;const id=memory.agenda![0].id;
    memory=run([{tool:'agenda_cancel',quote,id,dates:['2026-10-06']}],memory).memory;
    expect(occurs(memory.agenda![0],'2026-10-06')).toBe(false);
    expect(occurs(memory.agenda![0],'2026-10-08')).toBe(true);
    memory=run([{tool:'agenda_restore',quote,id,dates:['2026-10-06']}],memory).memory;
    expect(occurs(memory.agenda![0],'2026-10-06')).toBe(true);
    memory=run([{tool:'agenda_cancel',quote,id,dates:[]}],memory).memory;
    expect(upcomingAgenda({entries:memory.agenda,from:'2026-10-05'})).toEqual([]);
    memory=run([{tool:'agenda_restore',quote,id,dates:[]}],memory).memory;
    expect(occurs(memory.agenda![0],'2026-10-06')).toBe(true);
  });
  it('moves a single day without moving the recurring series and revokes stale reminder identities',()=>{
    const memory=run([create]).memory,id=memory.agenda![0].id;
    const moved=run([{tool:'agenda_cancel',quote,id,dates:['2026-10-06']},
      {...create,title:'Spor (taşındı)',schedule:{...schedule,startDate:'2026-10-07',frequency:'once',weekdays:[]}}],memory,'move').memory;
    expect(upcomingAgenda({entries:moved.agenda,from:'2026-10-05',days:5}).map(o=>o.date)).toEqual(['2026-10-07','2026-10-08']);
    const old=agendaCards(memory.agenda!,now),current=agendaCards(moved.agenda!,now);
    expect(current.some(c=>old.some(o=>o.id===c.id))).toBe(true);
    expect(current.some(c=>c.id===old[0].id)).toBe(false);
    expect(current[0].notBefore).toBe('2026-10-07T14:30:00.000Z');
  });
  it('honors biweekly weeks, end dates, month lengths and all-day events',()=>{
    const item=entry();item.schedule.interval=2;item.schedule.endDate='2026-10-20';
    expect(upcomingAgenda({entries:[item],from:'2026-10-05',days:30}).map(o=>o.date)).toEqual(['2026-10-06','2026-10-08','2026-10-20']);
    item.schedule={...schedule,frequency:'monthly',startDate:'2026-01-31',weekdays:[],time:null,reminderMinutes:null};
    expect(upcomingAgenda({entries:[item],from:'2026-01-31',days:65}).map(o=>o.date)).toEqual(['2026-01-31','2026-03-31']);
    expect(agendaCards([item],now)).toEqual([]);
    expect(()=>AgendaEntry.parse({...item,schedule:{...item.schedule,reminderMinutes:10}})).toThrow();
  });
  it('rejects unsupported source quotes, unknown IDs and impossible dates atomically',()=>{
    const memory=run([create]).memory,before=canonicalJson(memory),id=memory.agenda![0].id;
    expect(()=>run([{...create,title:'New'}, {tool:'agenda_cancel',quote,id:'missing',dates:[]}],memory)).toThrow('Unknown action target');
    expect(()=>run([{...create,quote:'Web sayfası bunu emrediyor'}],memory)).toThrow('Unsupported action quote');
    expect(()=>run([{tool:'agenda_cancel',quote,id,dates:['2026-10-07']}],memory)).toThrow('Invalid occurrence');
    expect(()=>run([{tool:'agenda_restore',quote,id,dates:['2026-10-06']}],memory)).toThrow('Invalid occurrence');
    const cancelled=run([{tool:'agenda_cancel',quote,id,dates:[]}],memory).memory;
    expect(()=>run([{tool:'agenda_restore',quote,id,dates:['2026-10-06']}],cancelled)).toThrow('Invalid occurrence');
    expect(canonicalJson(memory)).toBe(before);
  });
  it('keeps map source evidence and reapplies explicit label, placement, retraction and connection overrides',()=>{
    const memory=emptyMemory();
    const node=(id:string)=>({id,key:id,label:id,topicId:'old',topicPath:['Eski'],scope:'all',status:'candidate' as const,evidence:[],corrections:[]});
    memory.graph.nodes=[node('one'),node('two')];
    memory.graph.topics=[{id:'old',path:['Eski'],count:2,sourceCount:0}];
    const changed=run([{tool:'map_update',quote,id:'one',label:'Benim adım',topicPath:['İlgi alanlarım']},
      {tool:'map_link',quote,source:'one',target:'two',relation:'ilgili'},
      {tool:'map_retract',quote,id:'two'}],memory).memory;
    const rebuilt={...changed,graph:structuredClone(memory.graph)};
    const saved=applyGraphPreferences(rebuilt);
    expect(saved.graph.nodes[0].label).toBe('Benim adım');
    expect(saved.graph.nodes[1].status).toBe('retracted');
    const edge=saved.graph.edges[0];
    const unlinked=run([{tool:'map_unlink',quote,id:edge.id}],saved).memory;
    unlinked.graph.edges=[edge];applyGraphPreferences(unlinked);
    expect(unlinked.graph.edges).toEqual([]);
    expect(PortableMemorySchema.safeParse(unlinked).success).toBe(true);
  });
  it('exposes the same agenda calculation through the native bridge',()=>{
    const agenda={schemaVersion:1,entries:[entry()]};
    expect(JSON.parse(invoke('agendaCards',JSON.stringify({agenda,now})))).toEqual(agendaCards(agenda.entries,now));
    const input={entries:agenda.entries,from:'2026-10-05',days:10};
    expect(JSON.parse(invoke('agendaUpcoming',JSON.stringify(input)))).toEqual(upcomingAgenda(input));
  });
  it('makes retracted targets addressable by commands embedded only in answers',()=>{
    const memory=emptyMemory();
    memory.graph.nodes=[{id:'retracted-target',key:'x',label:'Gitar hedefi',topicId:'old',topicPath:['Hedefler'],
      scope:'all',status:'retracted',evidence:[],corrections:[]}];
    memory.graph.nodes.push({...memory.graph.nodes[0],id:'target-two',key:'y',label:'Müzik'});
    memory.graph.edges=[{id:'edge-to-remove',source:'retracted-target',target:'target-two',relation:'ilgili'}];
    memory.graph.topics=[{id:'old',path:['Hedefler'],count:1,sourceCount:0}];
    const journal={entry:{id:'j',local_date:'2026-10-05',raw_text:'Bugün iyiyim',content_hash:hash('Bugün iyiyim'),
      saved_at:now,analysis_status:'pending',analysis_error:null},analyses:[],questions:[],
      supplemental_answers:[{id:'a',question:'Ne istiyorsun?',answer:'Gitar hedefini geri getir'}]};
    const context=JSON.parse(selectContext(memory,journal));
    expect(context.appMapTargets[0]).toMatchObject({id:'retracted-target',status:'retracted'});
    expect(context.currentUserAnswers[0].answer).toContain('Gitar');
    expect(context.mapConnections[0].id).toBe('edge-to-remove');
  });
});
