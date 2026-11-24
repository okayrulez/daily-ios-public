import type { JournalAnalysis, WorkEssence } from './schemas.js';
import type { CrossMapSynthesis, CrossMapSynthesisInput } from '../../shared/cross-map.js';

export interface ProjectAnalysisInput {
  projectId: string | null;
  projectName: string;
  sourceThreadIds: string[];
  completedText: string;
  ultrokayPrompt: string;
  evidenceRefs: string[];
}

export interface JournalAnalysisInput {
  finishingQuestionSession?: boolean;
  journalId: string;
  localDate: string;
  rawText: string;
  workContext: string;
  memoryContext?: string;
  previousDayReflection?: string;
  previousTextLength?: number;
}

export interface AnalysisProvider {
  supportsCrossMap?(): boolean;
  analyzeLiving?(input: JournalAnalysisInput): Promise<import('../../shared/living-memory.js').LivingAnalysis>;
  analyzeCrossMap?(input: CrossMapSynthesisInput): Promise<CrossMapSynthesis>;
  analyzeProject(input: ProjectAnalysisInput): Promise<WorkEssence>;
  analyzeJournal(input: JournalAnalysisInput): Promise<JournalAnalysis>;
}
