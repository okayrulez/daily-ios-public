import type { Writing, LivingAnalysis, MemoryCorrection, MemoryGraph } from '../../shared/living-memory.js';
import { nodeMapId } from '../../shared/map-clusters.js';
import { hash as fullHash } from '../../shared/mobile-json.js';
const hash = (value: string) => fullHash(value).slice(0, 24);
const normalized = (value: string) => value.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/\s+/g, ' ').trim();
const quoteExists = (source: string, quote: string) => quote.length > 0 && source.includes(quote);
const identity = (note: LivingAnalysis['notes'][number]) => note.existing_node_id ?? hash(JSON.stringify([note.topic_path.map(normalized), normalized(note.key), normalized(note.scope)]));
const topicIdentity = (parts: string[]) => hash(JSON.stringify(parts.map(normalized)));
export function buildMemoryGraph(writings: Writing[], corrections: MemoryCorrection[]): MemoryGraph {
  const graph: MemoryGraph = { nodes: [], topics: [], edges: [] };
  const byId = new Map(writings.map(entry => [entry.id, entry]));
  const groups = new Map<string, Array<{ entry: Writing; source: Writing; note: LivingAnalysis['notes'][number] }>>();
  for (const entry of writings.filter(entry => entry.kind !== 'digest')) for (const note of entry.analysis?.notes ?? []) {
    const matchingSources = entry.kind === 'conversation_batch'
      ? (entry.sourceRefs ?? []).map(reference => byId.get(reference.id)).filter((candidate): candidate is Writing => Boolean(candidate && quoteExists(candidate.userEvidence ?? '', note.quote)))
      : [entry];
    // A repeated quote in multiple captured parts cannot identify its original
    // source. Keep the raw record but omit that ambiguous map evidence.
    const source = matchingSources.length === 1 ? matchingSources[0] : undefined;
    if (!source || !(source.kind === 'conversation' ? [source.userEvidence ?? ''] : [source.text, ...source.answers.map(a=>a.answer)])
      .some(text=>quoteExists(text,note.quote))) continue;
    const id = identity(note); const values = groups.get(id) ?? [];
    // One source cannot strengthen itself by repeating an item in the same model output.
    const previous = values.findIndex(value => value.source.id === source.id);
    if (previous < 0) values.push({ entry, source, note });
    else if (values[previous].entry.updatedAt <= entry.updatedAt) values[previous] = { entry, source, note };
    groups.set(id, values);
  }
  for (const [id, items] of groups) {
    items.sort((a, b) => a.entry.date.localeCompare(b.entry.date) || a.entry.updatedAt.localeCompare(b.entry.updatedAt));
    const latest = items.at(-1)!;
    const ownCorrections = corrections.filter(item => item.nodeId === id).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    // Count distinct days AND distinct text, not model confidence or repeated imports.
    const distinctTexts = new Set<string>(); const dates = new Set<string>();
    for (const item of items) if (!distinctTexts.has(hash(normalized(item.source.text)))) { distinctTexts.add(hash(normalized(item.source.text))); dates.add(item.source.date); }
    const status = ownCorrections.length ? 'corrected' : latest.note.status === 'retracted' ? 'retracted' : latest.note.status === 'weakening' ? 'weakening' : dates.size >= 3 ? 'recurring' : dates.size >= 2 || latest.note.nature === 'inference' ? 'candidate' : 'observation';
    graph.nodes.push({ id, mapId:latest.note.target_map_id??undefined, key: latest.note.key, label: latest.note.label, topicId: topicIdentity(latest.note.topic_path), topicPath: latest.note.topic_path, scope: latest.note.scope, status, consumers: latest.note.consumers,
      evidence: items.map(({ source, note }) => ({ sourceId: source.id, sourceKind: source.kind, title: source.title, date: source.date, quote: note.quote, observation: note.observation, nature: note.nature })), corrections: ownCorrections });
  }
  for (const node of graph.nodes) if (!graph.topics.some(topic => topic.id === node.topicId)) {
    const siblings = graph.nodes.filter(item => item.topicId === node.topicId);
    graph.topics.push({ id: node.topicId, path: node.topicPath, count: siblings.length, sourceCount: new Set(siblings.flatMap(item => item.evidence.map(evidence => evidence.sourceId))).size });
  }
  for (const [, items] of groups) for (const { entry, note } of items) for (const related of note.related_keys) {
    const targets = [...groups.values()].filter(values => values.some(value => value.entry.id === entry.id && value.note.key === related));
    // Ambiguous key mappings never silently join people or topics.
    if (targets.length !== 1) continue;
    const target = identity(targets[0][0].note), source = identity(note);
    const id = hash([source, target].sort().join(':'));
    if (target !== source && !graph.edges.some(edge => edge.id === id)) graph.edges.push({ id, source, target, relation: 'ilişkili' });
  }
  // Shared provenance is a factual, weaker connection. It does not claim the
  // two observations mean the same thing, and it stays inside one 2D cluster.
  const bySource = new Map<string, MemoryGraph['nodes']>();
  for (const node of graph.nodes) for (const sourceId of new Set(node.evidence.map(item => item.sourceId))) {
    const key = `${sourceId}:${nodeMapId(node)}`;
    bySource.set(key, [...(bySource.get(key) ?? []), node]);
  }
  const pairs = new Set(graph.edges.map(edge => [edge.source, edge.target].sort().join(':')));
  for (const nodes of bySource.values()) for (let index = 1; index < nodes.length; index++) {
    const source = nodes[index - 1].id, target = nodes[index].id, pair = [source, target].sort().join(':');
    if (source === target || pairs.has(pair)) continue;
    pairs.add(pair); graph.edges.push({ id: hash(`co-source:${pair}`), source, target, relation: 'aynı kaynakta' });
  }
  // Topic paths themselves also carry a factual hierarchy. Connect adjacent
  // notes and branches in one 2D map without claiming a semantic agreement.
  const byCluster = new Map<string, Map<string, MemoryGraph['nodes']>>();
  for (const node of graph.nodes) {
    const cluster = nodeMapId(node);
    const paths = byCluster.get(cluster) ?? new Map<string, MemoryGraph['nodes']>();
    const key = JSON.stringify(node.topicPath.map(normalized));
    paths.set(key, [...(paths.get(key) ?? []), node]); byCluster.set(cluster, paths);
  }
  function structuralEdge(source: string, target: string, relation: string) {
    const pair = [source, target].sort().join(':');
    if (source === target || pairs.has(pair)) return;
    pairs.add(pair); graph.edges.push({ id: hash(`${relation}:${pair}`), source, target, relation });
  }
  for (const paths of byCluster.values()) {
    const branches = [...paths.entries()].sort(([a], [b]) => a.localeCompare(b));
    for (const [, nodes] of branches) for (let index = 1; index < nodes.length; index++) structuralEdge(nodes[index - 1].id, nodes[index].id, 'aynı alt konuda');
    for (let index = 1; index < branches.length; index++) {
      const current = JSON.parse(branches[index][0]) as string[];
      const previous = branches.slice(0, index).map(([key, nodes]) => {
        const parts = JSON.parse(key) as string[];
        let common = 0; while (common < Math.min(parts.length, current.length) && parts[common] === current[common]) common++;
        return { node: nodes[0], common };
      }).sort((a, b) => b.common - a.common)[0];
      structuralEdge(previous.node.id, branches[index][1][0].id, 'aynı konu haritasında');
    }
  }
  graph.topics.sort((a, b) => a.path.join('/').localeCompare(b.path.join('/'), 'tr'));
  return graph;
}
