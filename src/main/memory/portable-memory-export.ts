import type { LibrarySnapshot } from '../../shared/living-memory.js';
import { PortableMemorySchema, type PortableMemoryV1 } from '../../shared/portable-memory.js';

export function exportPortableMemory(snapshot: LibrarySnapshot, revision: number): PortableMemoryV1 {
  return PortableMemorySchema.parse({ schemaVersion: 1, revision,
    sources: snapshot.writings, graph: snapshot.graph, deadlines: snapshot.deadlines,
    routing: snapshot.routing ?? { version: 1, bindings: {} },
  });
}
