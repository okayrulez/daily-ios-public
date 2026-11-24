import { EmotionalMemorySchema } from '../../shared/emotional-memory.js';
import { z } from 'zod';
import {ReminderProposal} from '../../shared/reminder-proposals.js';
import {EmotionProposal} from '../../shared/functional-answers.js';
import {QuestionPurpose} from '../../shared/question-policy.js';
import { LivingAnalysisSchema } from '../../shared/living-memory.js';

const recommendationLanguage = /\b(gelecekte|yapılmalı|yapilmali|öneri|onerilir|planlanmalı|planlanmali)\b/iu;

export const WorkEssenceSchema = z.object({
  project_id: z.string().nullable(),
  source_thread_ids: z.array(z.string().min(1)).min(1),
  observed_work: z.array(z.string().min(1)).min(1),
  decision_changes: z.array(z.string().min(1)),
  project_essence_now: z.string().min(1),
  vision: z.string().min(1),
  next_meaningful_move: z.string().min(1),
  negative_drift: z.string().min(1),
  evidence_refs: z.array(z.string().min(1)).min(1),
  confidence: z.enum(['low', 'medium', 'high']),
}).strict().superRefine((value, context) => {
  value.observed_work.forEach((statement, index) => {
    if (recommendationLanguage.test(statement)) {
      context.addIssue({
        code: 'custom',
        path: ['observed_work', index],
        message: 'observed_work may not contain future recommendation language',
      });
    }
  });
});

export const QuestionSchema = z.object({
  purpose: QuestionPurpose.optional(),
  reminder_proposal: ReminderProposal.nullable().optional(),
  emotion_proposal: EmotionProposal.nullable().optional(),
  prompt: z.string().min(1),
  rationale: z.string().min(1),
  source_ref: z.string().min(1),
}).strict();

const EvidenceItemSchema = z.object({
  key: z.string().min(1),
  label: z.string().min(1),
  observation: z.string().min(1),
  evidence_ref: z.string().min(1),
}).strict();

export const JournalAnalysisSchema = z.object({
  emotional_memory: EmotionalMemorySchema.optional(),
  living_memory: LivingAnalysisSchema.optional(),
  reflection: z.string().min(1),
  confidence: z.enum(['low', 'medium', 'high']),
  emotions: z.array(z.object({
    key: z.string().min(1),
    label: z.string().min(1),
    intensity: z.number().int().min(1).max(5),
    trigger: z.string().min(1).nullable(),
    evidence_ref: z.string().min(1),
  }).strict()).default([]),
  events: z.array(z.object({
    key: z.string().min(1),
    title: z.string().min(1),
    summary: z.string().min(1),
    people_keys: z.array(z.string().min(1)),
    evidence_ref: z.string().min(1),
  }).strict()).default([]),
  memories: z.array(z.object({
    key: z.string().min(1),
    title: z.string().min(1),
    summary: z.string().min(1),
    people_keys: z.array(z.string().min(1)),
    emotion_keys: z.array(z.string().min(1)),
    evidence_ref: z.string().min(1),
  }).strict()).default([]),
  people: z.array(z.object({
    key: z.string().min(1),
    name: z.string().min(1),
    relationship: z.string().min(1).nullable(),
    observation: z.string().min(1),
    evidence_ref: z.string().min(1),
  }).strict()).default([]),
  patterns: z.array(EvidenceItemSchema.extend({
    kind: z.enum(['language', 'thinking', 'behavior']),
  }).strict()).default([]),
  values: z.array(EvidenceItemSchema).default([]),
  perspectives: z.array(EvidenceItemSchema).default([]),
  profile_notes: z.array(z.object({
    key: z.string().min(1),
    dimension: z.string().min(1),
    observation: z.string().min(1),
    evidence_ref: z.string().min(1),
  }).strict()).default([]),
  inferences: z.array(z.object({
    key: z.string().min(1),
    statement: z.string().min(1),
    scope: z.enum(['personal', 'relationship', 'context']),
    confidence: z.enum(['low', 'medium', 'high']),
    status: z.enum(['active', 'weakening', 'retracted']),
    supporting_evidence: z.array(z.string().min(1)),
    counter_evidence: z.array(z.string().min(1)),
  }).strict()).default([]),
  connections: z.array(z.object({
    target_journal_id: z.string().min(1),
    target_date: z.string().min(1),
    reason: z.string().min(1),
    confidence: z.enum(['low', 'medium', 'high']),
  }).strict()),
  open_questions: z.array(QuestionSchema).max(3),
  boolean_questions: z.array(QuestionSchema).max(5),
}).strict();

export type WorkEssence = z.infer<typeof WorkEssenceSchema>;
export type JournalAnalysis = z.infer<typeof JournalAnalysisSchema>;

/** The model emits this single contract. Legacy arrays are populated by the adapter. */
export const CanonicalJournalAnalysisSchema = JournalAnalysisSchema.pick({
  reflection:true, confidence:true, connections:true, open_questions:true, boolean_questions:true,
}).extend({living_memory:LivingAnalysisSchema, emotional_memory:EmotionalMemorySchema}).strict();

const ConsentQuestionSchema = QuestionSchema.pick({prompt:true, rationale:true, source_ref:true});

export const DayReflectionOutputSchema = CanonicalJournalAnalysisSchema.extend({
  open_questions: z.array(z.never()).max(0),
  boolean_questions: z.array(z.union([
    ConsentQuestionSchema.extend({purpose:z.literal('reminder_consent'), reminder_proposal:ReminderProposal,
      emotion_proposal:z.null().optional()}),
    ConsentQuestionSchema.extend({purpose:z.literal('emotion_consent'), emotion_proposal:EmotionProposal,
      reminder_proposal:z.null().optional()}),
  ])).max(5),
});
