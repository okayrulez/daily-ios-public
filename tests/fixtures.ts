import type { LibrarySnapshot, Writing } from '../src/shared/living-memory.js';

export function snapshot(): LibrarySnapshot {
  const source = (id: string, text: string): Writing => ({ id, kind: 'journal', title: id,
    date: '2026-09-30', text, revision: 1, createdAt: '2026-09-30T09:00:00Z',
    updatedAt: '2026-09-30T09:00:00Z', status: 'saved', error: null, analysis: null,
    answers: [{ question: 'Nasıldı?', answer: 'İyiydi.' }], warnings: [],
  });
  return {
    writings: [source('source-one', 'Bugün yürüdüm. Dinlenmek iyi geldi.'), source('source-two', 'Bugün kısa bir mola verdim.')],
    graph: {
      topics: [{ id: 'topic-one', path: ['Dinlenme'], count: 2, sourceCount: 2 }],
      nodes: [
        { id: 'node-one', key: 'walk', label: 'Yürüyüş', topicId: 'topic-one', topicPath: ['Dinlenme'], scope: 'personal',
          status: 'corrected', description: 'Düzeltilmiş yorum',
          evidence: [{ sourceId: 'source-one', date: '2026-09-30', title: 'Günlük',
            quote: 'Bugün yürüdüm.', observation: 'Yürüyüş yaptığını söylüyor.', nature: 'observation' }],
          corrections: [{ id: 'correction-one', nodeId: 'node-one', verdict: 'incorrect',
            text: 'Bu kalıcı alışkanlığım değil.', createdAt: '2026-09-30T11:00:00Z' }] },
        { id: 'node-two', key: 'rest', label: 'Mola', topicId: 'topic-one', topicPath: ['Dinlenme'], scope: 'personal',
          status: 'candidate', inference: { level: 1, rootNodeIds: ['node-one'], rootClusterIds: ['cluster:dinlenme'], parentIds: ['node-one'] },
          evidence: [{ sourceId: 'source-two', date: '2026-09-30', title: 'Günlük',
            quote: 'kısa bir mola', observation: 'Mola veriyor.', nature: 'inference' }], corrections: [] },
      ],
      edges: [{ id: 'edge-one', source: 'node-one', target: 'node-two', relation: 'related' }],
    },
    deadlines: [{ id: 'deadline-one', title: 'Kontrol et', dueDate: '2026-10-01',
      sourceId: 'source-one', status: 'confirmed', updatedAt: '2026-09-30T11:00:00Z' }],
    routing: { version: 1, bindings: { 'cluster:dinlenme': ['health'] } },
    suggestions: [], warnings: [],
  };
}

export function analysis() {
  return {
    reflection: 'Bugün yürüyüşten söz ediyorsun.', confidence: 'medium',
    emotions: [], events: [], memories: [], people: [], patterns: [], values: [],
    perspectives: [], profile_notes: [], inferences: [], connections: [],
    open_questions: Array.from({ length: 3 }, (_, i) => ({ prompt: 'Soru ' + i, rationale: 'Bağlam', source_ref: 'journal-one' })),
    boolean_questions: Array.from({ length: 5 }, (_, i) => ({ prompt: 'Evet/hayır ' + i, rationale: 'Bağlam', source_ref: 'journal-one' })),
    living_memory: { summary: 'Yürüyüş', encouragement: 'Dinlenebilirsin.', reflection_question: 'Nasıldı?',
      next_step: 'Not al.', notes: [{ topic_path: ['Dinlenme'], key: 'walk', label: 'Yürüyüş',
        observation: 'Yürüyüş yaptı.', quote: 'Bugün yürüdüm.', nature: 'observation', scope: 'personal',
        status: 'active', related_keys: [] }], deadlines: [], followups: [] },
  };
}
