import {describe,it,expect} from 'vitest';
import {applyApprovedReminders,reminderQuestion} from '../src/shared/reminder-proposals.js';
import {emptyMemory} from '../src/shared/mobile-pipeline.js';
import {agendaCards} from '../src/shared/mobile-agenda.js';
const proposal=()=>({title:'Yürüyüş',details:'Kısa bir yürüyüş',quote:'Yürümek istiyorum',schedule:{startDate:'2026-10-11',endDate:null,time:'18:00',durationMinutes:30,frequency:'once' as const,interval:1,weekdays:[],reminderMinutes:10,timezone:'Europe/Istanbul' as const}});
const journal=(answer:number|null)=>({entry:{id:'journal-one',raw_text:'Yürümek istiyorum'},questions:[{id:'proposal-one',kind:'boolean',answer_boolean:answer,reminder_proposal:proposal()}]});
describe('explicit reminder consent',()=>{
 it('does not schedule unanswered or declined suggestions',()=>{for(const answer of [null,0])expect(applyApprovedReminders(emptyMemory(),journal(answer),'2026-10-10T10:00:00Z').memory.agenda??[]).toEqual([]);});
 it('applies yes once and preserves cancellation on retry',()=>{
  const first=applyApprovedReminders(emptyMemory(),journal(1),'2026-10-10T10:00:00Z');
  expect(first.memory.agenda).toHaveLength(1);expect(first.memory.agenda![0].schedule.reminderMinutes).toBe(10);
  expect(applyApprovedReminders(first.memory,journal(1),'2026-10-10T10:01:00Z').memory.agenda).toHaveLength(1);
  first.memory.agenda![0].status='cancelled';
  expect(applyApprovedReminders(first.memory,journal(1),'2026-10-10T10:02:00Z').memory.agenda![0].status).toBe('cancelled');
 });
 it('does not apply an expired one-off or invalid proposal',()=>{
  expect(applyApprovedReminders(emptyMemory(),journal(1),'2026-10-12T10:00:00Z').memory.agenda??[]).toEqual([]);
  const j=journal(1);j.questions[0].reminder_proposal.schedule.time='bad';
  expect(()=>applyApprovedReminders(emptyMemory(),j,'2026-10-10T10:00:00Z')).toThrow();
 });
 it('states the exact date, time and notification offset before approval',()=>{
  const question=reminderQuestion(proposal());
  expect(question).toContain('2026-10-11');expect(question).toContain('18:00');expect(question).toContain('10 dakika');
 });
 it('retains the approved Apple destination and keeps the request idempotent',()=>{
  const p=proposal();
  const source=journal(1);
  const accepted={...source,questions:[{...source.questions[0],
    reminder_proposal:{...p,schedule:{...p.schedule,appleDestination:'alarm' as const}}}]};
  const now='2026-10-10T10:00:00.000Z';
  expect(reminderQuestion(accepted.questions[0].reminder_proposal)).toContain('iPhone alarmı');
  const result=applyApprovedReminders(emptyMemory(),accepted,now);
  expect(Object.values(result.appleDestinations)).toEqual(['alarm']);
  expect(result.memory.agenda?.[0].schedule).not.toHaveProperty('appleDestination');
  expect(applyApprovedReminders(result.memory,accepted,now).memory.agenda).toHaveLength(1);
 });
 it('allows a calendar approval without inventing a notification or a time',()=>{
  const source=journal(1), p=proposal();
  const approved={...source,questions:[{...source.questions[0],
    reminder_proposal:{...p,schedule:{...p.schedule,time:null,reminderMinutes:null,appleDestination:'calendar' as const}}}]};
  const result=applyApprovedReminders(emptyMemory(),approved,'2026-10-10T10:00:00Z');
  expect(Object.values(result.appleDestinations)).toEqual(['calendar']);
  expect(agendaCards(result.memory.agenda??[],'2026-10-10T10:00:00Z')).toEqual([]);
 });
 it('retains a confirmed 06:45 local reminder for the separate 07:00 daily work event',()=>{
  const source=journal(1);
  const reminder=source.questions[0].reminder_proposal;
  reminder.title='İş';
  reminder.schedule.time='07:00';
  reminder.schedule.reminderMinutes=15;
  const recurring={...reminder,schedule:{...reminder.schedule,frequency:'daily' as const}};
  const now='2026-10-10T10:00:00.000Z';
  const approved=applyApprovedReminders(emptyMemory(),{...source,questions:[{...source.questions[0],reminder_proposal:recurring}]},now);
  const cards=agendaCards(approved.memory.agenda??[],now);
  expect(cards.slice(0,2).map(card=>card.notBefore)).toEqual([
   '2026-10-11T03:45:00.000Z','2026-10-12T03:45:00.000Z',
  ]);
 });
});
