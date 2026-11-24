import { z } from 'zod';
const id = z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/);
export const CompanionCardSchema = z.object({
  schemaVersion: z.literal(1), withdrawn: z.boolean().default(false), id, kind: z.enum(['checkin', 'advice', 'deadline', 'pinned', 'followup']),
  title: z.string().min(1).max(250), body: z.string().min(1).max(6000), question: z.string().max(2000),
  sourceIds: z.array(id).max(50), nodeIds: z.array(id).max(50), basis: z.string().max(2000),
  basisKey: z.string().max(200), fingerprint: z.string().max(100),
  notBefore: z.iso.datetime(), expiresAt: z.iso.datetime(), createdAt: z.iso.datetime(),
  deadlineId: id.nullable(),
  notification: z.object({reason:z.string().min(1).max(1200),basis:z.enum(['explicit','inferred','user_preference']),sourceQuote:z.string().max(2000)}).strict().nullable().default(null),
}).strict();
export type CompanionCard = z.infer<typeof CompanionCardSchema>;
export const CompanionEventSchema = z.object({
  schemaVersion: z.literal(1), id, cardId: id, action: z.enum(['answer', 'dismiss', 'snooze', 'done']),
  text: z.string().max(10000), at: z.iso.datetime(), until: z.iso.datetime().nullable(),
}).strict().superRefine((event, ctx) => {
  if (event.action === 'answer' && !event.text.trim()) ctx.addIssue({ code: 'custom', message: 'Cevap boş olamaz.' });
  if (event.action !== 'answer' && event.text) ctx.addIssue({ code: 'custom', message: 'Bu işlem cevap içeremez.' });
  if (event.action === 'snooze' ? !event.until || event.until <= event.at : event.until !== null) ctx.addIssue({ code: 'custom', message: 'Erteleme tarihi geçersiz.' });
});
export type CompanionEvent = z.infer<typeof CompanionEventSchema>;
export const CompanionPreferencesSchema = z.object({ enabled: z.boolean().default(true), dailyLimit: z.number().int().min(1).max(5).default(3), hour: z.number().int().min(8).max(21).default(10), pinnedNodeIds: z.array(id).max(100).default([]) }).strict();
export type CompanionPreferences = z.infer<typeof CompanionPreferencesSchema>;
export interface CompanionInbox { preferences: CompanionPreferences; cards: CompanionCard[]; events: CompanionEvent[]; pendingReplies: number; warnings: string[] }
// Terminal actions dominate snoozes, even when devices sync out of order.
export function companionCardState(card: CompanionCard, events: CompanionEvent[], now: string) {
  if (card.withdrawn) return 'closed';
  const relevant = events.filter(event => event.cardId === card.id);
  if (relevant.some(event => ['answer', 'dismiss', 'done'].includes(event.action))) return 'closed';
  if (card.expiresAt <= now) return 'expired';
  const latest = relevant.filter(event => event.action === 'snooze').sort((a,b) => b.at.localeCompare(a.at) || b.id.localeCompare(a.id))[0];
  return (latest?.until ?? card.notBefore) > now ? 'scheduled' : 'ready';
}
