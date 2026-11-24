import { createHash, randomUUID } from 'node:crypto';
import type { Firestore } from 'firebase-admin/firestore';
import { CompanionCardSchema,CompanionEventSchema,CompanionPreferencesSchema,companionCardState,type CompanionCard,type CompanionEvent } from '../../shared/companion-inbox.js';
import { PushDeviceSchema,pushWindow,type PushSender } from '../../shared/push.js';
import { z } from 'zod';
import {AgendaDocument,agendaCards,agendaKey} from '../../shared/mobile-agenda.js';
const PushJournalSchema = z.object({
  entry: z.object({ analysis_status: z.string() }), questions_generated_at: z.string(),
  questions: z.array(z.object({ kind: z.enum(['open','boolean']), session_closed_at: z.string().optional(), answer_text: z.string().nullable(), answer_boolean: z.union([z.literal(0),z.literal(1)]).nullable() })),
});
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
const isJournalNotice = (card: CompanionCard) => /^journal_questions_\d{4}-\d{2}-\d{2}$/.test(card.id);
export function pushTimePermitsCard(card: CompanionCard, now: Date, preferredHour: number) {
  return card.id.startsWith('agenda_') || (pushWindow(now) &&
    Number(new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Istanbul',hour:'2-digit',hourCycle:'h23'}).format(now)) >= preferredHour);
}
export function nativeCoversCard(keys: unknown, card: CompanionCard): boolean {
  if (!card.id.startsWith('agenda_') || !card.deadlineId || !Array.isArray(keys)) return false;
  const epoch = Math.floor(Date.parse(card.notBefore) / 1000);
  return keys.includes(hash(card.deadlineId + ':' + epoch));
}
export function decodePushRecord(record:Record<string,unknown>,documentId:string) {
  if(record.schemaVersion!==1||record.kind!=='note'||typeof record.key!=='string'||typeof record.content!=='string'||hash(record.content)!==record.hash||hash(record.key)!==documentId)throw Error('Bildirim kaynağı doğrulanamadı.');
  const text=JSON.parse(record.content);if(typeof text!=='string')throw Error('Bildirim kaynağı metin olmalı.');
  return {key:record.key,value:JSON.parse(text)};
}
export function readyPushCards(cards:CompanionCard[],events:CompanionEvent[],now:string) {
  return cards.filter(card=>card.kind!=='followup' && card.notification && companionCardState(card,events,now)==='ready').map(card=>{
    const snooze=events.filter(e=>e.cardId===card.id&&e.action==='snooze').sort((a,b)=>b.at.localeCompare(a.at)||b.id.localeCompare(a.id))[0];
    return {card,deliveryKey:hash(`${card.id}:${snooze?.until??card.notBefore}`)};
  }).sort((a,b)=>Number(b.card.id.startsWith('agenda_'))-Number(a.card.id.startsWith('agenda_')) || a.card.notBefore.localeCompare(b.card.notBefore));
}
/** One personal Firebase project + explicit UID. No cross-user scan and no model access. */
export class FirebasePushWorker {
  constructor(private readonly db:Firestore,private readonly uid:string,private readonly projectId:string,private readonly sender:PushSender,private readonly now=()=>new Date()) {
    if(!/^[a-zA-Z0-9_-]{1,128}$/.test(uid))throw Error('Bildirim kullanıcısı geçersiz.');
  }
  async runOnce() {
    const now=this.now();
    const owner=this.db.collection('users').doc(this.uid);
    const devices=await owner.collection('dailyXPushDevices').limit(21).get();if(devices.size>20)throw Error('Cihaz sınırı aşıldı.');
    const registered=devices.docs.filter(doc=>{const p=PushDeviceSchema.safeParse(doc.data());return p.success&&p.data.enabled&&Date.parse(p.data.updatedAt)<=now.getTime()+300000&&p.data.expiresAt>now.toISOString();});
    if(!registered.length)return {accepted:0,reason:'no_devices'};
    const records=owner.collection('dailyXRecords');
    const agendaRef=records.doc(hash(agendaKey)),preferencesRef=records.doc(hash('note:companion/preferences.md'));
    const overnightAgenda=pushWindow(now)?undefined:await agendaRef.get();
    const overnightCards=overnightAgenda?.exists?agendaCards(
      AgendaDocument.parse(decodePushRecord(overnightAgenda.data()!,overnightAgenda.id).value).entries,now.toISOString()):[];
    if(overnightAgenda&&!readyPushCards(overnightCards,[],now.toISOString()).length)return {accepted:0,reason:'quiet_hours'};
    // Notifications never scan atlas pages or the portable memory manifest.
    const ranges=[['note:companion/events/','note:companion/events0']];
    if(!overnightAgenda)ranges.push(['note:companion/cards/','note:companion/cards0']);
    const groups=await Promise.all(ranges.map(([start,end])=>records.where('key','>=',start).where('key','<',end).limit(5001).get()));
    const fixed=overnightAgenda?[await preferencesRef.get()]:await this.db.getAll(preferencesRef,agendaRef);
    const docs=[...groups.flatMap(group=>group.docs),...fixed.filter(doc=>doc.exists)];
    const snapshot={docs,size:docs.length};if(snapshot.size>5000)throw Error('Bildirim arşivi tarama sınırında; gönderim durduruldu.');
    const cards:CompanionCard[]=[...overnightCards],events:CompanionEvent[]=[];let preferences=CompanionPreferencesSchema.parse({});
    for(const doc of snapshot.docs){const item=decodePushRecord(doc.data()!,doc.id);if(item.key==='note:companion/preferences.md')preferences=CompanionPreferencesSchema.parse(item.value);else if(item.key.startsWith('note:companion/cards/')){const card=CompanionCardSchema.parse(item.value);if(item.key!==`note:companion/cards/${card.id}.md`)throw Error('Kart kimliği uyuşmuyor.');cards.push(card);}else if(item.key.startsWith('note:companion/events/')){const event=CompanionEventSchema.parse(item.value);if(item.key!==`note:companion/events/${event.id}.md`)throw Error('Yanıt kimliği uyuşmuyor.');events.push(event);}}
    const agendaDoc=snapshot.docs.find(doc=>doc.data()?.key===agendaKey);
    if(agendaDoc)cards.push(...agendaCards(AgendaDocument.parse(decodePushRecord(agendaDoc.data()!,agendaDoc.id).value).entries,now.toISOString()));
    const permittedCards = cards.filter(card => (preferences.enabled || isJournalNotice(card) || card.id.startsWith('agenda_')) &&
      pushTimePermitsCard(card,now,preferences.hour));
    if(!permittedCards.length)return {accepted:0,reason:'disabled'};
    let accepted=0;
    for(const doc of registered){const parsed=PushDeviceSchema.safeParse(doc.data());if(!parsed.success)continue;const device=parsed.data;if(!device.enabled||Date.parse(device.updatedAt)>now.getTime()+300000||device.expiresAt<=now.toISOString())continue;
      for(const {card,deliveryKey} of readyPushCards(permittedCards,events,now.toISOString())){
        const deliveryId=hash(`${doc.id}:${deliveryKey}`),delivery=owner.collection('dailyXPushDeliveries').doc(deliveryId),lease=randomUUID();
        const day=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Istanbul'}).format(now), budget=owner.collection('dailyXPushBudgets').doc(hash(`${doc.id}:${day}`));
        const claimed=await this.db.runTransaction(async tx=>{
          const old=await tx.get(delivery);
          const state=old.data();if(state?.status==='sent'||state?.status==='failed'||state?.leaseUntil>this.now().getTime()||state?.nextAttempt>this.now().getTime()||(state?.attempts??0)>=5)return false;
          const usage=await tx.get(budget),currentDevice=await tx.get(doc.ref),freshCard=await tx.get(records.doc(hash(card.id.startsWith('agenda_')?agendaKey:`note:companion/cards/${card.id}.md`))),freshPreferences=await tx.get(records.doc(hash('note:companion/preferences.md')));
          const freshEvents=await tx.get(records.where('key','>=','note:companion/events/').where('key','<','note:companion/events0').limit(5001));
          if(freshEvents.size>5000)return false;
          const latestDevice=PushDeviceSchema.safeParse(currentDevice.data());if(!latestDevice.success||!latestDevice.data.enabled||latestDevice.data.token!==device.token||latestDevice.data.environment!==device.environment||latestDevice.data.expiresAt<=this.now().toISOString())return false;
          if(!freshCard.exists)return false;
          const pref=CompanionPreferencesSchema.parse(freshPreferences.exists ? decodePushRecord(freshPreferences.data()!,freshPreferences.id).value : {});
          const decodedCard=decodePushRecord(freshCard.data()!,freshCard.id).value;
          const latestCard=card.id.startsWith('agenda_')
            ? agendaCards(AgendaDocument.parse(decodedCard).entries,this.now().toISOString()).find(c=>c.id===card.id)
            : CompanionCardSchema.parse(decodedCard);
          if(!latestCard)return false;
          if(latestCard.id.startsWith('agenda_') && latestCard.deadlineId) {
            const native = await tx.get(records.doc(hash('note:companion/native-push/' + doc.id + '.json')));
            if(native.exists && nativeCoversCard(decodePushRecord(native.data()!,native.id).value, latestCard))return false;
          }
          if(!pref.enabled && !isJournalNotice(latestCard) && !latestCard.id.startsWith('agenda_'))return false;
          if(!pushTimePermitsCard(latestCard,this.now(),pref.hour))return false;
          if (isJournalNotice(latestCard)) {
            const journalKey = 'journal:' + latestCard.id.slice('journal_questions_'.length);
            const currentJournal = (await tx.get(records.doc(hash(journalKey)))).data();
            if (!currentJournal || currentJournal.key !== journalKey || currentJournal.kind !== 'journal'
              || typeof currentJournal.content !== 'string' || hash(currentJournal.content) !== currentJournal.hash) return false;
            const journal = PushJournalSchema.parse(JSON.parse(currentJournal.content));
            if (journal.entry.analysis_status !== 'complete' || journal.questions_generated_at !== latestCard.notBefore
              || !journal.questions.some(q => !q.session_closed_at && (q.kind === 'boolean' ? q.answer_boolean === null : !q.answer_text?.trim()))) return false;
          }
          const latestEvents=freshEvents.docs.map(item=>{const decoded=decodePushRecord(item.data(),item.id);const event=CompanionEventSchema.parse(decoded.value);if(decoded.key!==`note:companion/events/${event.id}.md`)throw Error('Yanıt kimliği uyuşmuyor.');return event;});
          if(!readyPushCards([latestCard],latestEvents,this.now().toISOString()).some(item=>item.deliveryKey===deliveryKey))return false;
          const used=usage.data()?.count??0;if(!old.exists && !latestCard.id.startsWith('agenda_') && used>=pref.dailyLimit)return false;
          if(!old.exists)tx.set(budget,{count:used+1,date:day});
          tx.set(delivery,{status:'sending',lease,leaseUntil:this.now().getTime()+60000,attempts:(state?.attempts??0)+1,nextAttempt:0,cardId:card.id,deviceId:doc.id});
          return latestCard;
        });
        if(!claimed)continue;
        const result = await this.sender.send({
          token: device.token, environment: device.environment, scope: `${this.projectId}_${this.uid}`,
          cardId: claimed.id, deliveryId, expiresAt: claimed.expiresAt,
          kind: claimed.kind, hasQuestion: Boolean(claimed.question.trim()),
        }).catch(() => ({accepted:false,retryable:true,invalidToken:false,code:'transport_error'}));
        await this.db.runTransaction(async tx=>{const state=await tx.get(delivery),currentDevice=await tx.get(doc.ref);if(state.data()?.lease!==lease)return;
          tx.update(delivery,{status:result.accepted?'sent':result.retryable?'retry':'failed',leaseUntil:0,nextAttempt:this.now().getTime()+Math.min(3600000,60000*2**(state.data()?.attempts??1)),code:result.code});
          if(result.invalidToken&&currentDevice.data()?.token===device.token)tx.update(doc.ref,{enabled:false});
        });
        if(result.accepted)accepted++;
      }
    }
    return {accepted,reason:'checked'};
  }
}
