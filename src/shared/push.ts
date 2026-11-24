import { z } from 'zod';
import type { CompanionCard } from './companion-inbox.js';
export const PushDeviceSchema = z.object({
  schemaVersion:z.literal(1), token:z.string().regex(/^[a-f0-9]{32,256}$/), environment:z.enum(['development','production']),
  enabled:z.boolean(), transport:z.literal('apns'), updatedAt:z.iso.datetime(), expiresAt:z.iso.datetime(),
}).strict().refine(device => Date.parse(device.expiresAt) > Date.parse(device.updatedAt)
  && Date.parse(device.expiresAt) - Date.parse(device.updatedAt) <= 7 * 86400000,
  'Cihaz kaydı en fazla yedi gün geçerli olabilir.');
export type PushDevice=z.infer<typeof PushDeviceSchema>;
export interface PushResult { accepted:boolean; retryable:boolean; invalidToken:boolean; code:string }
export interface PushEnvelope {
  token: string;
  environment: PushDevice['environment'];
  scope: string;
  cardId: string;
  deliveryId: string;
  expiresAt: string;
  kind: CompanionCard['kind'];
  hasQuestion: boolean;
}
export interface PushSender { send(envelope:PushEnvelope):Promise<PushResult> }
export function pushWindow(now:Date) { const hour=Number(new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Istanbul',hour:'2-digit',hourCycle:'h23'}).format(now));return hour>=8&&hour<22; }
