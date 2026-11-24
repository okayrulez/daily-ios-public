import { z } from 'zod';
import { PortableMemorySchema } from './portable-memory.js';
import {formatMindmapContext,previewMindmapContext} from './mindmap-context-format.js';

const Input = z.object({ memory: PortableMemorySchema, exportedAt: z.iso.datetime({ offset: true }),
  purpose: z.string().trim().max(2000).default(''), includeEmotions: z.boolean().default(false),
  preview: z.boolean().default(false), selectedNoteIDs: z.array(z.string().min(1).max(500)).optional(),
  emotionHistory: z.array(z.object({
    sourceID:z.string(),date:z.iso.date(),reflection:z.string(),userSelected:z.boolean(),
    observations:z.array(z.object({key:z.string(),label:z.string(),event:z.string(),quote:z.string(),
      sequence:z.number().int(),intensity:z.number().nullable(),contextKey:z.string().nullable().optional(),
      contextLabel:z.string().nullable().optional(),orderKnown:z.boolean().optional(),userSelected:z.boolean().optional(),
      kind:z.enum(['emotion','energy']).optional(),orderGroup:z.string().optional(),conditions:z.array(z.string()).optional()}).strict()),helpful:z.array(z.string()),
    helpfulEvidence:z.array(z.object({action:z.string(),quote:z.string(),date:z.iso.date()}).strict()).optional(),
  }).strict()).optional() }).strict();

function renderContext({memory,exportedAt,purpose,includeEmotions,emotionHistory,selectedNoteIDs}:z.output<typeof Input>) {
  return formatMindmapContext(memory,exportedAt,purpose,includeEmotions,emotionHistory,selectedNoteIDs);
}

/** Validated graph; raw diaries and conversation bodies stay out of the export. */
export function exportMindmapContext(input: unknown) {
  return renderContext(Input.parse(input));
}

export function mindmapContextRequest(input: unknown) {
  const request = Input.parse(input);
  return request.preview
    ? previewMindmapContext(request.memory,request.purpose,request.includeEmotions)
    : renderContext(request);
}
