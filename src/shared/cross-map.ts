import { z } from 'zod';
import {MapReviewReportSchema} from './map-metadata.js';
import type { MemoryNode } from './living-memory.js';

export const CrossMapInsightSchema = z.object({
  topic_path: z.array(z.string().trim().min(1).max(180)).min(1).max(4),
  key: z.string().trim().min(1).max(160),
  label: z.string().trim().min(1).max(250),
  observation: z.string().trim().min(1).max(2000),
  supports: z.array(z.object({ node_id: z.string().min(1).max(200), source_id: z.string().min(1).max(100) }).strict()).min(2).max(12),
  replaces: z.array(z.string().min(1).max(200)).max(20).optional(),
  change_reason: z.string().max(2000).optional(),
}).strict();
export const CrossMapRetirementSchema = z.object({ node_id: z.string().min(1).max(200), reason: z.string().min(1).max(2000) }).strict();
export const CrossMapSynthesisSchema = z.object({ map_review:MapReviewReportSchema.nullish(), insights: z.array(CrossMapInsightSchema).max(10), retirements: z.array(CrossMapRetirementSchema).max(20).optional() }).strict();
export const CrossMapRecordSchema = z.object({ map_review:MapReviewReportSchema.nullish(), insights: z.array(CrossMapInsightSchema), signature: z.string().regex(/^[a-f0-9]{24}$/), generatedAt: z.string(),
  sourceFingerprints: z.record(z.string(), z.string()).optional(),
  insightFingerprints: z.record(z.string(), z.record(z.string(), z.string())).optional(),
}).strict();
export type CrossMapSynthesis = z.infer<typeof CrossMapSynthesisSchema>;
export type CrossMapInsight = CrossMapSynthesis['insights'][number];
export type CrossMapRecord = z.infer<typeof CrossMapRecordSchema>;
export interface CrossMapSynthesisInput { nodes: MemoryNode[]; previous: CrossMapInsight[]; corrections?: Array<{ nodeId: string; verdict: string; text: string }> }
export interface CrossMapStatus { available?: boolean; busy: boolean; pending: number; lastError: string | null; lastSuccess: string | null; archived: number }
