import { hash as fullHash } from '../../shared/mobile-json.js';
import type { CrossMapInsight, CrossMapRecord, CrossMapSynthesis } from '../../shared/cross-map.js';
import { nodeMapId, mapClusterId } from '../../shared/map-clusters.js';
import type { MemoryCorrection, MemoryGraph, MemoryNode } from '../../shared/living-memory.js';

const hash = (value: string) => fullHash(value).slice(0, 24);
const normalized = (value: string) => value.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/\s+/g, ' ').trim();
export const crossMapId = (insight: CrossMapInsight) => hash(JSON.stringify(['cross-map', insight.topic_path.map(normalized), normalized(insight.key)]));
export const nodeFingerprint = (node: MemoryNode) => hash(JSON.stringify([node.id, node.label, node.description, node.status, node.evidence, node.corrections, node.inference]));
const rejected = (node: MemoryNode) => node.status === 'retracted' || node.corrections.some(item => item.verdict === 'incorrect' || item.verdict === 'no_longer');

export function sourceFingerprints(graph: MemoryGraph, proposed: Pick<CrossMapSynthesis, 'insights'>): Record<string, string> {
  const nodes = new Map(graph.nodes.map(node => [node.id, node]));
  const fingerprints: Record<string, string> = {};
  for (const insight of proposed.insights) for (const ref of insight.supports) {
    const node = nodes.get(ref.node_id);
    const evidence = node?.evidence.find(item => item.sourceId === ref.source_id);
    if (evidence && node) fingerprints[`${ref.node_id}:${ref.source_id}`] = node.inference
      ? hash(JSON.stringify([evidence.quote, evidence.observation, evidence.nature, node.description, node.inference, node.corrections]))
      : hash(JSON.stringify([evidence.quote, evidence.observation, evidence.nature]));
  }
  return fingerprints;
}

// Resolve from original evidence upward. Missing, corrected or cyclic parents
// never silently become valid roots. There is no fixed abstraction depth.
function resolve(graph: MemoryGraph, record: CrossMapRecord, corrections: MemoryCorrection[]): CrossMapInsight[] {
  const byId = new Map(graph.nodes.map(node => [node.id, node]));
  let pending = [...new Map(record.insights.map(item => [crossMapId(item), item])).values()];
  const valid: CrossMapInsight[] = [];
  while (pending.length) {
    const remaining: CrossMapInsight[] = [];
    let progress = false;
    for (const insight of pending) {
      const id = crossMapId(insight);
      if (byId.has(id)) continue;
      const ownCorrections = corrections.filter(item => item.nodeId === id).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
      if (ownCorrections.some(item => item.verdict === 'incorrect' || item.verdict === 'no_longer')) continue;
      const refs = [...new Map(insight.supports.map(ref => [`${ref.node_id}:${ref.source_id}`, ref])).values()];
      if (refs.some(ref => !byId.has(ref.node_id))) { remaining.push(insight); continue; }
      if (refs.some(ref => rejected(byId.get(ref.node_id)!) || !byId.get(ref.node_id)!.evidence.some(item => item.sourceId === ref.source_id))) continue;
      const fingerprints = record.insightFingerprints?.[id] ?? record.sourceFingerprints;
      const current = sourceFingerprints(graph, { insights: [insight] });
      if (fingerprints && refs.some(ref => fingerprints[`${ref.node_id}:${ref.source_id}`] !== current[`${ref.node_id}:${ref.source_id}`])) continue;
      const branches = new Map<string, Set<string>>();
      const evidence = new Map<string, MemoryNode['evidence'][number]>();
      const roots = new Set<string>(), clusters = new Set<string>();
      let level = 1;
      for (const ref of refs) {
        const parent = byId.get(ref.node_id)!;
        const originals = parent.inference ? parent.evidence : parent.evidence.filter(item => item.sourceId === ref.source_id);
        const sources = branches.get(parent.id) ?? new Set<string>();
        for (const item of originals) { sources.add(item.sourceId); evidence.set(`${item.sourceId}:${normalized(item.quote)}`, { ...item, nature: 'inference' }); }
        branches.set(parent.id, sources);
        for (const root of parent.inference?.rootNodeIds ?? [parent.id]) roots.add(root);
        for (const cluster of parent.inference?.rootClusterIds ?? [mapClusterId(parent.topicPath)]) clusters.add(cluster);
        level = Math.max(level, (parent.inference?.level ?? 0) + 1);
      }
      const sets = [...branches.values()];
      const independent = sets.some((a, index) => sets.slice(index + 1).some(b => [...a].some(source => !b.has(source)) && [...b].some(source => !a.has(source))));
      if (!independent || clusters.size < 2 || new Set([...evidence.values()].map(item => normalized(item.quote))).size < 2) continue;
      if (level === 1 && clusters.has(mapClusterId(insight.topic_path))) continue;
      const node: MemoryNode = {
        id, key: insight.key, label: insight.label, description: insight.observation,
        topicId: hash(JSON.stringify(insight.topic_path.map(normalized))), topicPath: insight.topic_path,
        scope: 'Haritalar arası çıkarım', status: ownCorrections.length ? 'corrected' : 'candidate',
        evidence: [...evidence.values()], corrections: ownCorrections,
        inference: { level, rootNodeIds: [...roots].sort(), rootClusterIds: [...clusters].sort(), parentIds: [...branches.keys()].sort() },
      };
      byId.set(id, node); graph.nodes.push(node); valid.push({ ...insight, supports: refs }); progress = true;
      for (const parent of branches.keys()) graph.edges.push({ id: hash(`support:${id}:${parent}`), source: id, target: parent, relation: 'dayanak' });
    }
    if (!progress) break;
    pending = remaining;
  }
  for (const topicId of new Set(graph.nodes.map(node => node.topicId))) {
    const nodes = graph.nodes.filter(node => node.topicId === topicId);
    const topic = { id: topicId, path: nodes[0].topicPath, count: nodes.length, sourceCount: new Set(nodes.flatMap(node => node.evidence.map(item => item.sourceId))).size };
    const index = graph.topics.findIndex(item => item.id === topicId);
    if (index < 0) graph.topics.push(topic); else graph.topics[index] = topic;
  }
  graph.topics.sort((a, b) => a.path.join('/').localeCompare(b.path.join('/'), 'tr'));
  return valid;
}

export function validateCrossMapSynthesis(graph: MemoryGraph, proposed: Pick<CrossMapSynthesis, 'insights'>): CrossMapSynthesis {
  const replacing = new Set(proposed.insights.map(crossMapId));
  const clone: MemoryGraph = { nodes: graph.nodes.filter(node => !replacing.has(node.id)), topics: [], edges: [] };
  return { insights: resolve(clone, { ...proposed, signature: '0'.repeat(24), generatedAt: '' }, graph.nodes.flatMap(node => node.corrections)) };
}

export function mergeCrossMapGraph(graph: MemoryGraph, record: CrossMapRecord | null, corrections: MemoryCorrection[]): MemoryGraph {
  if (record) resolve(graph, record, corrections);
  return graph;
}
