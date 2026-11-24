import { describe, expect, it } from 'vitest';
import { PortableMemorySchema } from '../src/shared/portable-memory.js';
import { exportPortableMemory } from '../src/main/memory/portable-memory-export.js';
import { snapshot } from './fixtures.js';

describe('portable memory', () => {
  it('preserves complete evidence, answers, rejected interpretations and ancestry on round-trip', () => {
    const source = snapshot();
    const exported = exportPortableMemory(source, 7);
    const restored = PortableMemorySchema.parse(JSON.parse(JSON.stringify(exported)));
    expect(restored.graph).toEqual(source.graph);
    expect(restored.sources).toEqual(source.writings);
    expect(restored.deadlines).toEqual(source.deadlines);
    expect(restored.routing).toEqual(source.routing);
  });

  it('does not accept a display atlas as complete source memory', () => {
    expect(() => PortableMemorySchema.parse({ schemaVersion: 1, maps: [] })).toThrow();
  });

  it.each(['source', 'edge', 'parent', 'correction', 'deadline'] as const)('rejects dangling %s references', kind => {
    const value = exportPortableMemory(snapshot(), 1);
    if (kind === 'source') value.sources = value.sources.slice(1);
    if (kind === 'edge') value.graph.edges[0].target = 'missing';
    if (kind === 'parent') value.graph.nodes[1].inference!.parentIds = ['missing'];
    if (kind === 'correction') value.graph.nodes[0].corrections[0].nodeId = 'missing';
    if (kind === 'deadline') value.deadlines[0].sourceId = 'missing';
    expect(() => PortableMemorySchema.parse(value)).toThrow();
  });

  it('rejects duplicate identities and cyclic inference', () => {
    const value = exportPortableMemory(snapshot(), 1);
    value.sources.push(value.sources[0]);
    expect(() => PortableMemorySchema.parse(value)).toThrow();
    value.sources.pop();
    value.graph.nodes[0].inference = { level: 2, rootNodeIds: [], rootClusterIds: [], parentIds: ['node-two'] };
    expect(() => PortableMemorySchema.parse(value)).toThrow(/Cyclic/);
  });

  it('never uses assistant text as user evidence', () => {
    const value = exportPortableMemory(snapshot(), 1);
    value.sources[0].kind = 'conversation';
    value.sources[0].text = 'Assistant: Bugün yürüdüm.';
    value.sources[0].userEvidence = 'User: Bugün evdeydim.';
    expect(() => PortableMemorySchema.parse(value)).toThrow(/quote/);
  });
});
