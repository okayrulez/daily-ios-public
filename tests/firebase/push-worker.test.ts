import { afterAll,afterEach,beforeAll,expect,it,vi } from 'vitest';
import { initializeApp,deleteApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { createHash,randomUUID } from 'node:crypto';
import { FirebasePushWorker } from '../../src/main/push/firebase-push-worker';
import { CompanionCardSchema } from '../../src/shared/companion-inbox';
import type { PushResult } from '../../src/shared/push';
import {AgendaEntry,agendaKey} from '../../src/shared/mobile-agenda';
const hash=(s:string)=>createHash('sha256').update(s).digest('hex');
const now='2026-09-25T08:00:00.000Z';
// Test-only emulator. Never fall back to a live project/ADC.
process.env.FIRESTORE_EMULATOR_HOST='127.0.0.1:8089';
const app=initializeApp({projectId:'demo-dailyx'},'push-test-'+randomUUID());const db=getFirestore(app);
let uid='';
beforeAll(async()=>{await db.listCollections();});
afterEach(async()=>{if(uid)await db.recursiveDelete(db.collection('users').doc(uid));});
afterAll(async()=>{await db.terminate();await deleteApp(app);});
async function setup(limit=3) {
  uid='owner_'+randomUUID();const owner=db.collection('users').doc(uid);
  const put=async(key:string,value:unknown)=>{const content=JSON.stringify(JSON.stringify(value));await owner.collection('dailyXRecords').doc(hash(key)).set({schemaVersion:1,kind:'note',key,content,hash:hash(content)});};
  const makeCard=(id:string)=>CompanionCardSchema.parse({schemaVersion:1,id,kind:'deadline',title:'Görüşme',body:'Takip',question:'Nasıl geçti?',sourceIds:[],nodeIds:[],basis:'Kendi yazın',basisKey:id,fingerprint:id,notBefore:now,expiresAt:'2026-09-28T08:00:00.000Z',createdAt:now,deadlineId:null,notification:{reason:'Kaynak zamanı',basis:'explicit',sourceQuote:'Görüşme'}});
  const card=makeCard('one');await put('note:companion/cards/one.md',card);await put('note:companion/preferences.md',{enabled:true,dailyLimit:limit,hour:10,pinnedNodeIds:[]});
  const device=owner.collection('dailyXPushDevices').doc('phone');await device.set({schemaVersion:1,transport:'apns',token:'a'.repeat(64),environment:'production',enabled:true,updatedAt:now,expiresAt:'2026-10-02T08:00:00.000Z'});
  const sender={send:vi.fn(async():Promise<PushResult>=>({accepted:true,retryable:false,invalidToken:false,code:'accepted'}))};
  let time=new Date(now);const worker=()=>new FirebasePushWorker(db,uid,'demo-dailyx',sender,()=>time);
  return {owner,put,makeCard,card,device,sender,worker,setTime:(value:string)=>{time=new Date(value);}};
}
it('claims atomically across concurrent workers and remembers delivery across restarts',async()=>{
  const s=await setup();await Promise.all([s.worker().runOnce(),s.worker().runOnce()]);expect(s.sender.send).toHaveBeenCalledTimes(1);
  await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(1);
},30000);
it('closed cards and disabled devices cannot send; another UID has no access to this queue',async()=>{
  const s=await setup();await s.put('note:companion/events/reply.md',{schemaVersion:1,id:'reply',cardId:s.card.id,action:'answer',text:'Tamamlandı',at:now,until:null});
  expect((await s.worker().runOnce()).accepted).toBe(0);
  const other=new FirebasePushWorker(db,'nobody','demo-dailyx',s.sender,()=>new Date(now));expect((await other.runOnce()).accepted).toBe(0);expect(s.sender.send).not.toHaveBeenCalled();
});
it('never exceeds daily budget and does not starve new cards behind already-sent ones',async()=>{
  const s=await setup(1);await s.put('note:companion/cards/two.md',s.makeCard('two'));await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(1);
  await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(1);
  s.setTime('2026-09-26T08:00:00.000Z');await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(2);
});
it('backs off temporary errors, retains delivery identity and disables rejected device tokens',async()=>{
  const s=await setup();s.sender.send.mockResolvedValueOnce({accepted:false,retryable:true,invalidToken:false,code:'ServiceUnavailable'});
  await s.worker().runOnce();await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(1);
  s.setTime('2026-09-25T08:03:00.000Z');s.sender.send.mockResolvedValueOnce({accepted:false,retryable:false,invalidToken:true,code:'Unregistered'});await s.worker().runOnce();
  expect(s.sender.send).toHaveBeenCalledTimes(2);expect((await s.device.get()).data()?.enabled).toBe(false);expect(s.sender.send.mock.calls[0]).toEqual(s.sender.send.mock.calls[1]);
});
it('does not use expired registration, global disable or quiet hours to send stale prompts',async()=>{
  const s=await setup();await s.device.update({expiresAt:'2026-09-25T07:00:00.000Z'});await s.worker().runOnce();expect(s.sender.send).not.toHaveBeenCalled();
  await s.device.update({expiresAt:'2026-10-02T08:00:00.000Z'});
  s.setTime('2026-09-25T20:00:00.000Z');expect((await s.worker().runOnce()).reason).toBe('quiet_hours');
});

it('notifies journal questions with device consent even without companion preferences, and rechecks actual unanswered questions', async () => {
  const s=await setup(); await s.put('note:companion/preferences.md',{enabled:false,dailyLimit:3,hour:10,pinnedNodeIds:[]});
  const id='journal_questions_2026-09-25';await s.put('note:companion/cards/'+id+'.md',s.makeCard(id));
  const key='journal:2026-09-25';
  const journal={entry:{id:'j',local_date:'2026-09-25',raw_text:'Test',content_hash:hash('Test'),saved_at:now,analysis_status:'complete',analysis_error:null},analyses:[],questions_generated_at:now,
    questions:[{id:'q',journal_id:'j',kind:'boolean',position:1,prompt:'Soru?',rationale:'Test',source_ref:'j',answer_text:null,answer_boolean:null as number|null}]};
  const putJournal=async()=>{const content=JSON.stringify(journal);await s.owner.collection('dailyXRecords').doc(hash(key)).set({schemaVersion:1,kind:'journal',key,content,hash:hash(content)});};
  journal.questions[0].answer_boolean=0;await putJournal();expect((await s.worker().runOnce()).accepted).toBe(0);
  journal.questions[0].answer_boolean=null;await putJournal();expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledTimes(1);await s.worker().runOnce();expect(s.sender.send).toHaveBeenCalledTimes(1);
});

it('derives recurring agenda reminders from Firebase, deduplicates delivery and respects cancellation',async()=>{
  const s=await setup();
  await s.owner.collection('dailyXRecords').doc(hash('note:companion/cards/one.md')).delete();
  const entry=AgendaEntry.parse({id:'event_sport',title:'Spor',details:'',status:'active',excludedDates:[],sourceQuote:'Her gün 11:00 spor',
    sourceID:'journal-one',createdAt:now,updatedAt:now,revision:1,
    schedule:{startDate:'2026-09-25',endDate:null,time:'11:00',durationMinutes:60,frequency:'daily',interval:1,
      weekdays:[],reminderMinutes:0,timezone:'Europe/Istanbul'}});
  await s.put(agendaKey,{schemaVersion:1,entries:[entry]});
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect((await s.worker().runOnce()).accepted).toBe(0);
  entry.excludedDates=['2026-09-28'];entry.revision++;
  await s.put(agendaKey,{schemaVersion:1,entries:[entry]});
  expect((await s.worker().runOnce()).accepted).toBe(0); // Editing another day cannot resend today.
  s.setTime('2026-09-26T08:00:00.000Z');
  expect((await s.worker().runOnce()).accepted).toBe(1);
  entry.status='cancelled';entry.revision++;
  await s.put(agendaKey,{schemaVersion:1,entries:[entry]});
  s.setTime('2026-09-27T08:00:00.000Z');
  expect((await s.worker().runOnce()).accepted).toBe(0);
  expect(s.sender.send).toHaveBeenCalledTimes(2);
});

it('does not read atlas pages or memory while checking notifications',async()=>{
  const s=await setup();
  // Malformed unrelated data would fail decoding if the broad companion query returned it.
  for (const key of ['note:companion/atlas/index.md','note:companion/atlas/maps/test/page.md','note:companion/memory/manifest.md']) {
    await s.owner.collection('dailyXRecords').doc(hash(key)).set({key,content:'invalid'});
  }
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledTimes(1);
});

it('honors preferred followup hours while keeping explicit agenda timing',async()=>{
  const s=await setup();
  await s.put('note:companion/preferences.md',{enabled:true,dailyLimit:3,hour:15,pinnedNodeIds:[]});
  expect((await s.worker().runOnce()).accepted).toBe(0);
  const entry=AgendaEntry.parse({id:'event_morning',title:'Spor',details:'',status:'active',excludedDates:[],sourceQuote:'Saat 11:00 spor',
    sourceID:'journal-one',createdAt:now,updatedAt:now,revision:1,
    schedule:{startDate:'2026-09-25',endDate:null,time:'11:00',durationMinutes:60,frequency:'once',interval:1,
      weekdays:[],reminderMinutes:0,timezone:'Europe/Istanbul'}});
  await s.put(agendaKey,{schemaVersion:1,entries:[entry]});
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledTimes(1);
  s.setTime('2026-09-25T12:00:00.000Z');
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledTimes(2);
});

it('keeps native suppression on its device and delivers confirmed agenda with an exhausted budget', async () => {
  const s = await setup(1);
  await s.owner.collection('dailyXRecords').doc(hash('note:companion/cards/one.md')).delete();
  const entry = AgendaEntry.parse({id:'event_one', title:'Randevu', details:'', status:'active', excludedDates:[],
    sourceQuote:'Saat 11', sourceID:'journal-one', createdAt:now, updatedAt:now, revision:1,
    schedule:{startDate:'2026-09-25', endDate:null, time:'11:00', durationMinutes:60, frequency:'once',
      interval:1, weekdays:[], reminderMinutes:0, timezone:'Europe/Istanbul'}});
  await s.put(agendaKey, {schemaVersion:1, entries:[entry]});
  await s.put('note:companion/native-push/phone.json', [hash('event_one:' + Date.parse(now)/1000)]);
  await s.owner.collection('dailyXPushDevices').doc('tablet').set({...((await s.device.get()).data()!), token:'b'.repeat(64)});
  await s.owner.collection('dailyXPushBudgets').doc(hash('tablet:2026-09-25')).set({count:1,date:'2026-09-25'});
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledWith(expect.objectContaining({token:'b'.repeat(64)}));
  await s.put('note:companion/native-push/phone.json', []);
  expect((await s.worker().runOnce()).accepted).toBe(1);
  expect(s.sender.send).toHaveBeenCalledWith(expect.objectContaining({token:'a'.repeat(64)}));
});
