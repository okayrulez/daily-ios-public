import {z} from 'zod';
import {canonicalJson,hash} from './mobile-json.js';
import {CompanionCardSchema} from './companion-inbox.js';

export const agendaKey='note:companion/agenda.json';
export const AgendaSchedule=z.object({
  startDate:z.iso.date(),endDate:z.iso.date().nullable(),time:z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).nullable(),
  durationMinutes:z.number().int().min(1).max(1440).nullable(),
  frequency:z.enum(['once','daily','weekly','monthly']),interval:z.number().int().min(1).max(52),
  weekdays:z.array(z.number().int().min(1).max(7)).max(7),reminderMinutes:z.number().int().min(0).max(10080).nullable(),
  timezone:z.literal('Europe/Istanbul'),
}).strict().superRefine((s,ctx)=>{
  if(s.endDate&&s.endDate<s.startDate||s.frequency==='weekly'&&!s.weekdays.length||
    new Set(s.weekdays).size!==s.weekdays.length||s.frequency!=='weekly'&&s.weekdays.length||
    s.time===null&&s.reminderMinutes!==null)ctx.addIssue({code:'custom',message:'Invalid agenda schedule'});
});
export const AgendaEntry=z.object({id:z.string().regex(/^[a-z0-9_-]{1,100}$/),title:z.string().min(1).max(250),
  details:z.string().max(4000),schedule:AgendaSchedule,status:z.enum(['active','cancelled']),
  excludedDates:z.array(z.iso.date()).max(3000),sourceQuote:z.string().min(1).max(2000),
  sourceID:z.string().min(1),createdAt:z.string(),updatedAt:z.string(),revision:z.number().int().positive(),
}).strict();
export const AgendaDocument=z.object({schemaVersion:z.literal(1),entries:z.array(AgendaEntry).max(1000)}).strict()
  .superRefine((d,c)=>{if(new Set(d.entries.map(e=>e.id)).size!==d.entries.length)c.addIssue({code:'custom',message:'Duplicate event'});});
export type AgendaItem=z.infer<typeof AgendaEntry>;
const day=(value:string)=>Date.parse(value+'T00:00:00Z');
const date=(value:number)=>new Date(value).toISOString().slice(0,10);
export function occurs(entry:AgendaItem,localDate:string) {
  const s=entry.schedule;
  if(entry.status!=='active'||localDate<s.startDate||(s.endDate&&localDate>s.endDate)||entry.excludedDates.includes(localDate))return false;
  const diff=Math.round((day(localDate)-day(s.startDate))/86400000);
  if(s.frequency==='once')return diff===0;
  if(s.frequency==='daily')return diff%s.interval===0;
  if(s.frequency==='weekly'){
    const weekday=(new Date(day(localDate)).getUTCDay()+6)%7+1;
    const startWeekday=(new Date(day(s.startDate)).getUTCDay()+6)%7;
    return Math.floor((diff+startWeekday)/7)%s.interval===0&&s.weekdays.includes(weekday);
  }
  const a=new Date(day(s.startDate)),b=new Date(day(localDate));
  return b.getUTCDate()===a.getUTCDate()&&((b.getUTCFullYear()-a.getUTCFullYear())*12+b.getUTCMonth()-a.getUTCMonth())%s.interval===0;
}
export function upcomingAgenda(value:unknown) {
  const {entries,from,days}=z.object({entries:z.array(AgendaEntry),from:z.iso.date(),days:z.number().int().min(1).max(366).default(90)}).parse(value);
  const items=[];
  for(let i=0;i<days;i++){
    const localDate=date(day(from)+i*86400000);
    for(const entry of entries)if(occurs(entry,localDate))items.push({id:entry.id+'_'+localDate,eventID:entry.id,title:entry.title,
      details:entry.details,date:localDate,time:entry.schedule.time,frequency:entry.schedule.frequency,
      startsAt:localDate+'T'+(entry.schedule.time??'00:00')+':00+03:00',schedule:entry.schedule});
  }
  return items.sort((a,b)=>a.startsAt.localeCompare(b.startsAt)||a.id.localeCompare(b.id));
}
export function agendaRecord(entries:AgendaItem[]) {
  const payload=AgendaDocument.parse({schemaVersion:1,entries});
  const content=canonicalJson(canonicalJson(payload));
  return {key:agendaKey,kind:'note',content,hash:hash(content)};
}
/** Both phone and push worker derive occurrences from durable recurrence rules. */
export function agendaCards(entries:AgendaItem[],now:string) {
  const today=new Date(Date.parse(now)+3*3600000).toISOString().slice(0,10);
  return upcomingAgenda({entries,from:date(day(today)-7*86400000),days:100}).flatMap(item=>{
    const entry=entries.find(e=>e.id===item.eventID)!;
    if(entry.schedule.reminderMinutes===null)return [];
    const start=Date.parse(item.startsAt),notBefore=new Date(start-entry.schedule.reminderMinutes*60000).toISOString();
    const expiresAt=new Date(start+(entry.schedule.durationMinutes??60)*60000).toISOString();
    if(expiresAt<=now)return [];
    // Editing another occurrence must not re-deliver an already sent reminder.
    const id='agenda_'+hash(canonicalJson({occurrence:item.id,notBefore,expiresAt})).slice(0,32);
    return [CompanionCardSchema.parse({schemaVersion:1,id,withdrawn:false,kind:'deadline',title:entry.title,
      body:entry.details||'Ajandandaki etkinlik zamanı.',question:'',sourceIds:[entry.sourceID],nodeIds:[],
      basis:'Ajanda etkinliği',basisKey:entry.id,fingerprint:hash(canonicalJson(entry)+item.date),
      notBefore,expiresAt,createdAt:entry.createdAt,deadlineId:entry.id,
      notification:{reason:'Ajandaya eklenen etkinliğin hatırlatması',basis:'explicit',sourceQuote:entry.sourceQuote}})];
  });
}
