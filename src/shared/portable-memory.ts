import { z } from 'zod';
import {MapIdentitySchema,MapReviewStateSchema} from './map-metadata.js';
import { CorrectionSchema, DeadlineSchema, WritingSchema } from './living-memory.js';
import {AgendaEntry} from './mobile-agenda.js';
import {GraphPreferences} from './app-actions.js';

const id = z.string().min(1).max(500);
const normalizedQuote = (text: string) => text.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/\s+/g, ' ').trim();
const node = z.object({
  id, key: id, label: z.string(), topicId: id, topicPath: z.array(z.string()).min(1), scope: z.string(),
  mapId:id.optional(), description: z.string().optional(), consumers: z.array(z.string()).optional(),
  status: z.enum(['observation', 'candidate', 'recurring', 'weakening', 'retracted', 'corrected']),
  inference: z.object({ level: z.number().int().positive(), rootNodeIds: z.array(id),
    rootClusterIds: z.array(id), parentIds: z.array(id) }).strict().optional(),
  evidence: z.array(z.object({ sourceId: id, sourceKind: WritingSchema.shape.kind.optional(),
    date: z.iso.date(), title: z.string(), quote: z.string(), observation: z.string(),
    nature: z.enum(['observation', 'inference']) }).strict()),
  corrections: z.array(CorrectionSchema),
}).strict();

/** Full evidence, not the truncated mobile-atlas display projection. */
export const PortableMemorySchema = z.object({
  maps:z.array(MapIdentitySchema).optional(), mapReview:MapReviewStateSchema.optional(),
  schemaVersion: z.literal(1), revision: z.number().int().nonnegative(),
  sources: z.array(WritingSchema),
  graph: z.object({
    topics: z.array(z.object({ id, path: z.array(z.string()), count: z.number().int().nonnegative(),
      sourceCount: z.number().int().nonnegative() }).strict()),
    nodes: z.array(node),
    edges: z.array(z.object({ id, source: id, target: id, relation: z.string() }).strict()),
  }).strict(),
  deadlines: z.array(DeadlineSchema),
  agenda:z.array(AgendaEntry).max(1000).optional(),
  graphPreferences:GraphPreferences.optional(),
  closedFollowupKeys: z.array(z.string().min(1).max(120)).optional(),
  routing: z.object({ version: z.literal(1), bindings: z.record(z.string(), z.array(z.string())) }).strict(),
}).strict().superRefine((memory, ctx) => {
  const fail = (message: string) => ctx.addIssue({ code: 'custom', message });
  const unique = (rows: Array<{ id: string }>, label: string) => {
    const ids = new Set(rows.map(row => row.id));
    if (ids.size !== rows.length) fail(`Duplicate ${label} identity`);
    return ids;
  };
  unique(memory.maps??[], 'map');
  if(memory.mapReview) {
    const review=memory.mapReview;
    if(new Set(review.journalIds).size!==review.journalIds.length||review.lastAttemptCount>review.journalIds.length)fail('Invalid map review counter');
  }
  const sources = unique(memory.sources, 'source');
  const nodes = unique(memory.graph.nodes, 'node');
  const topics = unique(memory.graph.topics, 'topic');
  unique(memory.graph.edges, 'edge'); unique(memory.deadlines, 'deadline');
  unique(memory.agenda??[], 'agenda event');
  const writings = new Map(memory.sources.map(source => [source.id, source]));
  for (const item of memory.graph.nodes) {
    if (!topics.has(item.topicId)) fail('Missing topic');
    unique(item.corrections, 'correction');
    for (const correction of item.corrections) if (correction.nodeId !== item.id) fail('Correction owner mismatch');
    for (const evidence of item.evidence) {
      const source = writings.get(evidence.sourceId);
      if (!source) { fail('Missing original source'); continue; }
      // Conversation evidence must come from user-only text, never assistant text.
      const texts = source.kind === 'conversation' || source.kind === 'conversation_batch'
        ? [source.userEvidence ?? ''] : [source.text, ...source.answers.map(a => a.answer)];
      const quote = normalizedQuote(evidence.quote);
      if (!quote || !texts.some(text=>normalizedQuote(text).includes(quote))) fail('Unsupported evidence quote');
    }
    for (const ref of [...(item.inference?.rootNodeIds ?? []), ...(item.inference?.parentIds ?? [])]) {
      if (!nodes.has(ref) || ref === item.id) fail('Invalid inference reference');
    }
  }
  const byID = new Map(memory.graph.nodes.map(item => [item.id, item]));
  const visited = new Set<string>(), visiting = new Set<string>();
  const visit = (key: string, depth=0): void => {
    if(depth>128){fail('Inference depth exceeds portable limit');return;}
    if (visiting.has(key)) { fail('Cyclic inference'); return; }
    if (visited.has(key)) return;
    visiting.add(key);
    for (const parent of byID.get(key)?.inference?.parentIds ?? []) visit(parent,depth+1);
    visiting.delete(key); visited.add(key);
  };
  for (const key of nodes) visit(key);
  for (const edge of memory.graph.edges) if (!nodes.has(edge.source) || !nodes.has(edge.target)) fail('Missing edge endpoint');
  for (const deadline of memory.deadlines) if (deadline.sourceId && !sources.has(deadline.sourceId)) fail('Missing deadline source');
});
export type PortableMemoryV1 = z.infer<typeof PortableMemorySchema>;
