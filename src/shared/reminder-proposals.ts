import {z} from 'zod';
import {AgendaEntry} from './mobile-agenda.js';
import {RequestedAgendaSchedule} from './app-actions.js';
import {canonicalJson,hash} from './mobile-json.js';
import type {PortableMemoryV1} from './portable-memory.js';

export const ReminderProposal=z.object({title:z.string().trim().min(1).max(200),details:z.string().max(2000),
  quote:z.string().trim().min(1).max(2000),schedule:RequestedAgendaSchedule}).strict().refine(
  p=>p.schedule.appleDestination==='calendar'||p.schedule.appleDestination==='reminders'||
    (p.schedule.time!==null&&(p.schedule.reminderMinutes!==null||p.schedule.appleDestination==='alarm')),
  'Reminder proposal needs a usable date, time and destination');
export const REMINDER_GUIDANCE=`Her günlük ve yanıt değerlendirmesinden sonra kullanıcının yapabileceği somut bir iş için yararlı bir hatırlatma olup olmadığını düşün. Uygunsa en fazla 3 öneriyi evet/hayır onayına sun. Her seferinde zorla alarm üretme; tekrar veya reddedilmiş öneriyi yineleme.
Günlükte boolean_questions içindeki öneri sorusuna reminder_proposal ekle; görev sonucunda reminderProposals dizisini kullan. Öneri title, details, kullanıcı yazısı/cevabından birebir quote ve schedule içerir. schedule: startDate, endDate (null olabilir), time (HH:mm), durationMinutes, frequency (once/daily/weekly/monthly), interval, weekdays (ISO 1-7, yalnız weekly için), reminderMinutes, timezone Europe/Istanbul. dAIly bildirimi için saat ve bildirim dakikası null olamaz. Tarih/saat/tekrar ve bildirim zamanını kullanıcıya açıkça öner; kullanıcının zaten söylediği gibi sunma. Belirsizse önce açık soru sor. Kullanıcının açıkça istediği ajanda hatırlatma saatini aynen koru; 08:00–22:00 sessiz saat sınırı otomatik takip bildirimlerine aittir. Yeni saat önerirken kullanıcının açık tercihi yoksa 08:00–22:00 aralığını tercih et. iPhone veya sunucu teslimatının durumunu varsayma.
Kullanıcı açıkça Apple Takvim, Apple Anımsatıcılar veya iPhone alarmı isterse schedule.appleDestination sırasıyla calendar, reminders veya alarm olsun. Belirtilmemiş hedefi uydurma. Calendar/reminders etkinliği tüm gün olabilir (time ve reminderMinutes null). Alarm için saat gerekir; kullanıcı alarmı tam o saatte istiyorsa reminderMinutes 0. Her önerinin hedefini ve saatini ayrı belirt. iPhone alarmının şu an kurulduğunu söyleme; aygıt sonucu gösterir.
Öneri henüz izin değildir. Evet onayı geldiğinde uygulama ilgili yapılandırılmış öneriyi kendisi ajandaya kaydeder; sırf bunun için manage işlemi üretme. Hayır veya boş cevapta hatırlatma oluşturma. Sağlık/ilaç dozunu veya kullanım düzenini icat etme. Sıradan sorularda reminder_proposal ekleme. Kullanıcının istediği diğer işlevler mevcut araçlarla mümkünse açıkça öner; desteklenmeyen eylemler için çalışacakmış gibi onay isteme.`;

export function reminderQuestion(value:z.infer<typeof ReminderProposal>):string {
  const {title,schedule:s}=ReminderProposal.parse(value);
  const days=['Pazartesi','Salı','Çarşamba','Perşembe','Cuma','Cumartesi','Pazar'];
  const repeat=s.frequency==='once'?'tek sefer':s.frequency==='weekly'?`${s.interval} haftada bir (${s.weekdays.map(d=>days[d-1]).join(', ')})`:s.frequency==='daily'?`${s.interval} günde bir`:`${s.interval} ayda bir`;
  const destination=s.appleDestination==='alarm'?'iPhone alarmı':s.appleDestination==='calendar'?'Apple Takvim kaydı':
    s.appleDestination==='reminders'?'Apple Anımsatıcılar kaydı':'ajanda hatırlatması';
  const alert=s.reminderMinutes===null?'':s.reminderMinutes===0?' Başlangıç saatinde uyarır.':
    ' Başlangıçtan '+s.reminderMinutes+' dakika önce uyarır.';
  return `${title} için ${s.startDate} ${s.time?'saat '+s.time:'tüm gün'}, ${repeat}${s.endDate?`, ${s.endDate} tarihine kadar`:''}${s.durationMinutes?`, ${s.durationMinutes} dakika süreyle`:''} ${destination} oluşturayım mı?${alert}${s.time?' (İstanbul saati)':''}`;
}

type ConsentJournal={entry:{id:string;raw_text:string};questions:Array<{id:string;kind:string;answer_boolean:number|null;reminder_proposal?:unknown}>};
/** Approval is interpreted from saved boolean answers, never inferred from model prose. */
export function applyApprovedReminders(memory:PortableMemoryV1,journal:ConsentJournal,now:string) {
  const next=JSON.parse(canonicalJson(memory)) as PortableMemoryV1,changes:string[]=[];
  const appleDestinations:Record<string,'calendar'|'reminders'|'alarm'>={};
  const appleApprovalIDs:Record<string,string>={};
  for(const q of journal.questions){
    if(q.kind!=='boolean'||q.answer_boolean!==1||q.reminder_proposal==null)continue;
    const p=ReminderProposal.parse(q.reminder_proposal),id='reminder_'+hash(journal.entry.id+':'+q.id).slice(0,32);
    if(next.agenda?.some(e=>e.id===id))continue; // A cancelled approval is not reactivated on retry.
    const start=Date.parse(p.schedule.startDate+'T'+(p.schedule.time??'00:00')+':00+03:00');
    const delivery=start-(p.schedule.reminderMinutes??0)*60000;
    const today=new Date(Date.parse(now)+3*3600000).toISOString().slice(0,10);
    if((p.schedule.frequency==='once'&&(p.schedule.time!==null?delivery<=Date.parse(now):p.schedule.startDate<today))||(p.schedule.endDate&&p.schedule.endDate<today)){
      changes.push('Hatırlatma zamanı geçti; oluşturulmadı: '+p.title);continue;
    }
    const {appleDestination,...schedule}=p.schedule;
    const existing=next.agenda?.find(e=>e.status==='active'&&e.title===p.title&&canonicalJson(e.schedule)===canonicalJson(schedule));
    if(existing){
      if(appleDestination) {
        appleDestinations[existing.id]=appleDestination;
        appleApprovalIDs[q.id]=existing.id;
      }
      changes.push('Bu hatırlatma zaten ajandanda: '+p.title);continue;
    }
    if(appleDestination) {
      appleDestinations[id]=appleDestination;
      appleApprovalIDs[q.id]=id;
    }
    const entry=AgendaEntry.parse({id,title:p.title,details:p.details,schedule,status:'active',excludedDates:[],
      sourceQuote:'Evet — '+reminderQuestion(p),sourceID:journal.entry.id,createdAt:now,updatedAt:now,revision:1});
    next.agenda=[...(next.agenda??[]),entry];
    changes.push((p.schedule.appleDestination?'Onayladığın plan ajandaya kaydedildi: ':'Onayladığın hatırlatma oluşturuldu: ')+p.title);
  }
  return {memory:next,changes,appleDestinations,appleApprovalIDs};
}
