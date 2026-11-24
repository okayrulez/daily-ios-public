import { expect,it } from 'vitest';
import { createHash } from 'node:crypto';
import { apnsPayload,classifyApns } from '../src/main/push/apns-sender';
import { decodePushRecord,nativeCoversCard,pushTimePermitsCard,readyPushCards } from '../src/main/push/firebase-push-worker';
import { PushDeviceSchema,pushWindow } from '../src/shared/push';
import { CompanionCardSchema } from '../src/shared/companion-inbox';
const hash=(s:string)=>createHash('sha256').update(s).digest('hex');
const now='2026-09-25T08:00:00.000Z';
const card=CompanionCardSchema.parse({schemaVersion:1,id:'card1',kind:'deadline',title:'Private title',body:'Private diary',question:'Private question',sourceIds:[],nodeIds:[],basis:'private quote',basisKey:'topic',fingerprint:'fp',notBefore:now,expiresAt:'2026-09-28T08:00:00.000Z',createdAt:now,deadlineId:null,notification:{reason:'Kaynak zamanı',basis:'explicit',sourceQuote:'Görüşme'}});
it('labels the push by purpose and keeps private card text off the lock screen',()=>{
  const envelope={token:'a'.repeat(64),environment:'production' as const,scope:'project_uid',cardId:card.id,deliveryId:'b'.repeat(64),expiresAt:card.expiresAt};
  const payload=apnsPayload({...envelope,kind:card.kind,hasQuestion:true});
  expect(payload.aps.alert.title).toBe('Hatırlatma');
  expect(apnsPayload({...envelope,kind:'checkin',hasQuestion:true}).aps.alert.title).toBe('Takip sorusu');
  expect(apnsPayload({...envelope,kind:'checkin',hasQuestion:false,cardId:'journal_questions_2026-09-25'}).aps.alert.title).toBe('Günlüğünün soruları hazır');
  expect(payload.companionCard).toBe(card.id);expect(JSON.stringify(payload)).not.toContain('Private');expect(JSON.stringify(payload)).not.toContain('a'.repeat(64));
});
it('filters withdrawn, answered and snoozed cards, and gives resumed snoozes their own delivery identity',()=>{
  const event={schemaVersion:1 as const,id:'event',cardId:card.id,action:'answer' as const,text:'Evet',at:now,until:null};
  expect(readyPushCards([card],[event],now)).toEqual([]);expect(readyPushCards([{...card,withdrawn:true}],[],now)).toEqual([]);
  const snooze={...event,action:'snooze' as const,text:'',until:'2026-09-26T08:00:00.000Z'};
  expect(readyPushCards([card],[snooze],now)).toEqual([]);
  expect(readyPushCards([card],[snooze],snooze.until)[0].deliveryKey).not.toBe(readyPushCards([card],[],now)[0].deliveryKey);
});
it('checks source hash and record identity before parsing push candidates',()=>{
  const key='note:companion/cards/card1.md',content=JSON.stringify(JSON.stringify(card));const record={schemaVersion:1,kind:'note',key,content,hash:hash(content)};
  expect(decodePushRecord(record,hash(key)).value.id).toBe(card.id);
  expect(()=>decodePushRecord({...record,hash:'wrong'},hash(key))).toThrow();expect(()=>decodePushRecord(record,'wrong')).toThrow();
});
it('separates temporary Apple failures from invalid tokens and obeys quiet hours',()=>{
  expect(classifyApns(200,'').accepted).toBe(true);expect(classifyApns(429,'TooManyRequests').retryable).toBe(true);expect(classifyApns(503,'ServiceUnavailable').retryable).toBe(true);expect(classifyApns(410,'Unregistered').invalidToken).toBe(true);expect(classifyApns(403,'InvalidProviderToken').retryable).toBe(false);
  expect(pushWindow(new Date('2026-09-25T04:59:59Z'))).toBe(false);expect(pushWindow(new Date('2026-09-25T05:00:00Z'))).toBe(true);expect(pushWindow(new Date('2026-09-25T19:00:00Z'))).toBe(false);
});
it('expires unattended phone registrations within seven days',()=>{
  const device={schemaVersion:1,transport:'apns',token:'a'.repeat(64),environment:'production',enabled:true,updatedAt:now,expiresAt:'2026-10-02T08:00:00.000Z'};
  expect(PushDeviceSchema.safeParse(device).success).toBe(true);expect(PushDeviceSchema.safeParse({...device,expiresAt:'2027-01-01T00:00:00.000Z'}).success).toBe(false);
});

it('keeps an explicit 06:45 Istanbul agenda reminder outside the automatic follow-up window',()=>{
  const early=new Date('2026-09-25T03:45:00Z');
  expect(pushTimePermitsCard(card,early,10)).toBe(false);
  expect(pushTimePermitsCard({...card,id:'agenda_work'},early,10)).toBe(true);
  expect(pushTimePermitsCard(card,new Date('2026-09-25T07:00:00Z'),10)).toBe(true);
});

it('never turns an unscheduled inbox question into a push',()=>{
 expect(readyPushCards([{...card,notification:null}],[],now)).toEqual([]);
});

it('requires consent through an agenda reminder instead of inferred followup timing',()=>{expect(readyPushCards([{...card,kind:'followup'}],[],now)).toEqual([]);});

it('suppresses exactly one native occurrence and keeps other cards eligible on that device', () => {
  const occurrence = {...card, id:'agenda_one', deadlineId:'event_one'};
  const keys = [hash('event_one:' + Math.floor(Date.parse(now) / 1000))];
  expect(nativeCoversCard(keys, occurrence)).toBe(true);
  expect(nativeCoversCard([], occurrence)).toBe(false);
  expect(nativeCoversCard(keys, {...occurrence, deadlineId:'event_two'})).toBe(false);
  expect(nativeCoversCard(keys, {...occurrence, notBefore:'2026-09-26T08:00:00.000Z'})).toBe(false);
  expect(nativeCoversCard(keys, {...occurrence, id:'ordinary'})).toBe(false);
  expect(readyPushCards([card, occurrence], [], now).map(item => item.card.id)).toEqual(['agenda_one', 'card1']);
});
