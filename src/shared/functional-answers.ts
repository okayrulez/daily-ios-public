import {z} from 'zod';
import {canonicalJson,hash} from './mobile-json.js';
import {PortableMemorySchema} from './portable-memory.js';
import {applyApprovedReminders} from './reminder-proposals.js';
import {agendaRecord} from './mobile-agenda.js';

/** Only declared, locally supported actions bypass inference. Prose never grants authority. */
export const EmotionProposal=z.object({key:z.string().regex(/^[a-z][a-z0-9-]{0,99}$/),
  label:z.string().min(1).max(100),quote:z.string().min(1).max(2000)}).strict();
export function isFunctionalQuestion(q:{kind?:string;reminder_proposal?:unknown;emotion_proposal?:unknown}):boolean {
  return q.kind==='boolean'&&(q.reminder_proposal!=null||q.emotion_proposal!=null);
}
export function functionalPrompts(journal:{questions:unknown[];question_history?:unknown}):Set<string> {
  return new Set([...journal.questions,...(Array.isArray(journal.question_history)?journal.question_history:[])].flatMap(value=>{
    const q=value as {kind?:string;prompt?:string;reminder_proposal?:unknown;emotion_proposal?:unknown};
    return q&&isFunctionalQuestion(q)&&q.prompt?[q.prompt]:[];
  }));
}

export function applyFunctionalAnswers(value:unknown) {
  const args=z.object({memory:PortableMemorySchema,journal:z.object({entry:z.object({id:z.string(),raw_text:z.string(),
    content_hash:z.string()}).passthrough(),questions:z.array(z.object({id:z.string(),kind:z.string(),
      answer_boolean:z.number().nullable()}).passthrough())}).passthrough(),
    expectedMemoryHash:z.string(),expectedSourceHash:z.string(),now:z.iso.datetime({offset:true})}).passthrough().parse(value);
  const {memory,now}=args,journal=structuredCloneJSON(args.journal);
  if(hash(canonicalJson(memory))!==args.expectedMemoryHash||hash(canonicalJson(journal))!==args.expectedSourceHash)
    throw Error('Source or memory changed');
  const pending=journal.questions.filter(q=>isFunctionalQuestion(q)&&q.answer_boolean!==null&&q.functional_applied_answer!==q.answer_boolean);
  const base=structuredCloneJSON(memory),revoked:string[]=[],appleRevocations:string[]=[];
  for(const q of pending)if(q.answer_boolean===0&&q.reminder_proposal!=null) {
    const id='reminder_'+hash(journal.entry.id+':'+q.id).slice(0,32);
    const entry=base.agenda?.find(e=>e.id===id&&e.status==='active');
    if(typeof q.functional_apple_event_id==='string')appleRevocations.push(q.functional_apple_event_id);
    if(entry) { entry.status='cancelled';entry.updatedAt=now;entry.revision++;revoked.push('Onayını geri aldığın hatırlatma kaldırıldı: '+entry.title); }
  }
  const reminders=applyApprovedReminders(base,{entry:journal.entry,questions:pending},now);
  let choices:string[]|undefined;
  for(const q of pending) {
    if(q.emotion_proposal!=null) {
      const proposal=EmotionProposal.parse(q.emotion_proposal);
      if(!journal.entry.raw_text.includes(proposal.quote))throw Error('Unsupported emotion quote');
      if(!choices) {
        const prior=(journal.emotion_calendar_override??journal.emotion_override) as {source_hash?:string;choices?:string[]}|undefined;
        const emotional=journal.emotional_memory as {source_hash?:string;observations?:{key:string}[]}|undefined;
        choices=prior?.source_hash===journal.entry.content_hash ? [...(prior.choices??[])] :
          emotional?.source_hash===journal.entry.content_hash ? (emotional.observations??[]).map(o=>o.key) : [];
      }
      choices=choices.filter(key=>key!==proposal.key);
      if(q.answer_boolean===1)choices.push(proposal.key);
    }
    if(reminders.appleApprovalIDs[q.id])q.functional_apple_event_id=reminders.appleApprovalIDs[q.id];
    q.functional_applied_answer=q.answer_boolean;
    q.functional_applied_at=now;
  }
  if(choices)journal.emotion_calendar_override={source_hash:journal.entry.content_hash,choices:[...new Set(choices)]};
  journal.reminder_results=[...revoked,...reminders.changes];
  const prompts=functionalPrompts(journal);
  const next=PortableMemorySchema.parse({...reminders.memory,revision:memory.revision+1,
    sources:reminders.memory.sources.map(s=>s.id===journal.entry.id?{...s,answers:s.answers.filter(a=>!prompts.has(a.question))}:s)});
  return {memory:next,journal,appleDestinations:reminders.appleDestinations,appleRevocations,atlas:[agendaRecord(next.agenda??[])],cards:[]};
}
function structuredCloneJSON<T>(value:T):T {return JSON.parse(canonicalJson(value)) as T;}
