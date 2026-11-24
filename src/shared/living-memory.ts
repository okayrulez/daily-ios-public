import { z } from 'zod';
import {MapSummaryProposals} from './map-metadata.js';

export const WritingKindSchema = z.enum(['journal', 'essay', 'thought', 'activity', 'conversation', 'conversation_batch', 'digest', 'research']);
export type WritingKind = z.infer<typeof WritingKindSchema>;
const safeId = z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/);
const topic = z.string().trim().min(1).max(180);
const SourceReferenceSchema = z.object({
  id: safeId, kind: WritingKindSchema, title: z.string().max(250), date: z.iso.date(),
}).strict();
export const FollowupTimingSchema = z.object({
  not_before: z.iso.datetime({offset:true}), expires_at: z.iso.datetime({offset:true}),
  reason: z.string().min(1).max(1200), quote: z.string().min(1).max(2000),
  basis: z.enum(['explicit','inferred']), intent: z.enum(['before_event','after_event','check_in']),
  event_at: z.iso.datetime({offset:true}).nullable(),
}).strict();
export type FollowupTiming = z.infer<typeof FollowupTimingSchema>;
export const LivingAnalysisSchema = z.object({
  map_summaries:MapSummaryProposals.optional(),
  summary: z.string().max(6000),
  encouragement: z.string().max(4000),
  reflection_question: z.string().max(2000),
  next_step: z.string().max(2000),
  notes: z.array(z.object({
    topic_path: z.array(topic).min(1).max(8),
    target_map_id: z.string().min(1).max(500).nullish(),
    existing_node_id: z.string().min(1).max(500).nullish(),
    new_map_reason: z.string().min(1).max(1000).nullish(),
    key: z.string().min(1).max(160),
    label: z.string().min(1).max(250),
    observation: z.string().min(1).max(4000),
    quote: z.string().min(1).max(2000),
    nature: z.enum(['observation', 'inference']),
    scope: z.string().min(1).max(200),
    status: z.enum(['active', 'weakening', 'retracted']),
    consumers: z.array(z.string().regex(/^[a-z][a-z0-9_-]{1,63}$/)).max(16).optional(),
    related_keys: z.array(z.string().min(1).max(160)).max(30),
  }).strict()),
  followups: z.array(z.object({
    key: z.string().min(1).max(120), title: z.string().min(1).max(250),
    question: z.string().min(1).max(2000), quote: z.string().min(1).max(2000),
    due_date: z.iso.date(), status: z.enum(['open', 'resolved']),
    timing: FollowupTimingSchema.nullable().optional(),
  }).strict()).optional(),
  deadlines: z.array(z.object({
    title: z.string().min(1).max(250),
    due_date: z.iso.date(),
    quote: z.string().min(1).max(2000),
  }).strict()),
}).strict();
export type LivingAnalysis = z.infer<typeof LivingAnalysisSchema>;
export const WritingSchema = z.object({
  id: safeId, kind: WritingKindSchema, title: z.string().max(250),
  date: z.iso.date(), text: z.string().min(1),
  revision: z.number().int().positive(), createdAt: z.string(), updatedAt: z.string(),
  status: z.enum(['saved', 'pending', 'processing', 'complete', 'failed']),
  error: z.string().nullable(), analysis: LivingAnalysisSchema.nullable(),
  answers: z.array(z.object({ question: z.string().max(2000), answer: z.string().max(10000) })),
  warnings: z.array(z.string()),
  importKey: z.string().max(250).optional(),
  userEvidence: z.string().optional(),
  sourceRefs: z.array(SourceReferenceSchema).max(20_000).optional(),
  researchSources: z.array(z.object({url:z.string().max(3000),title:z.string().max(1000)}).strict()).max(100).optional(),
}).strict();
export type Writing = z.infer<typeof WritingSchema>;
export const SaveWritingSchema = z.object({
  id: safeId.optional(), expectedRevision: z.number().int().nonnegative().optional(),
  kind: WritingKindSchema, title: z.string().max(250), date: z.iso.date(),
  text: z.string().min(1).refine(value => value.trim().length > 0),
  analyze: z.boolean().default(true),
}).strict();
export type SaveWriting = z.input<typeof SaveWritingSchema>;
export const CorrectionSchema = z.object({
  id: safeId, nodeId: z.string().max(200), text: z.string().min(1).max(4000),
  verdict: z.enum(['context', 'incorrect', 'no_longer']), createdAt: z.string(),
  subject: z.string().max(1000).optional(),
}).strict();
export type MemoryCorrection = z.infer<typeof CorrectionSchema>;
export const DeadlineSchema = z.object({
  id: safeId, title: z.string().min(1).max(250), dueDate: z.iso.date(),
  sourceId: safeId.nullable(), status: z.enum(['confirmed', 'done', 'dismissed']), updatedAt: z.string(),
}).strict();
export type MemoryDeadline = z.infer<typeof DeadlineSchema>;
export interface MemoryNode {
  key: string;
  id: string; label: string; topicId: string; topicPath: string[]; scope: string;
  mapId?: string;
  description?: string;
  consumers?: string[];
  inference?: { level: number; rootNodeIds: string[]; rootClusterIds: string[]; parentIds: string[] };
  status: 'observation' | 'candidate' | 'recurring' | 'weakening' | 'retracted' | 'corrected';
  evidence: Array<{ sourceId: string; sourceKind?: WritingKind; date: string; title: string; quote: string; observation: string; nature: 'observation' | 'inference' }>;
  corrections: MemoryCorrection[];
}
export interface MemoryTopic { id: string; path: string[]; count: number; sourceCount: number }
export interface MemoryGraph { topics: MemoryTopic[]; nodes: MemoryNode[]; edges: Array<{ id: string; source: string; target: string; relation: string }> }
export interface MapRoutingConfig { version: 1; bindings: Record<string, string[]> }
export interface AgendaMemoryContext { deadlineId: string; nodeIds: string[]; selectedMapIds: string[]; omitted: number }
export interface LibrarySnapshot {
  synthesis?: import('./cross-map.js').CrossMapStatus;
  routing?: MapRoutingConfig;
  writings: Writing[]; graph: MemoryGraph; deadlines: MemoryDeadline[];
  suggestions: Array<{ id: string; title: string; dueDate: string; sourceId: string; quote: string }>;
  warnings: string[];
}
