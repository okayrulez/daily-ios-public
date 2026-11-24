import type { MemoryGraph, MemoryNode } from './living-memory.js';

const normalize = (value: string) => value.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/\s+/g, ' ').trim();
const wrappers = new Set(['projelerim', 'projeler', 'uygulamalar', 'projects', 'my projects']);

export function mapClusterName(path: string[]): string {
  if (!path.length) return 'Diğer konular';
  return wrappers.has(normalize(path[0])) && path[1] ? path[1] : path[0];
}

export function mapClusterId(path: string[]): string { return `cluster:${normalize(mapClusterName(path))}`; }
export function nodeMapId(node:{mapId?:string;topicPath:string[]}):string { return node.mapId??mapClusterId(node.topicPath); }
export function nodeInMapCluster(node: MemoryNode, id: string): boolean {
  return node.scope !== 'Haritalar arası çıkarım' && (!id || node.topicId === id || nodeMapId(node) === id);
}

export interface MapCluster { id: string; name: string; count: number; sourceCount: number; paths: string[][] }
export function mapClusters(graph: MemoryGraph): MapCluster[] {
  const clusters = new Map<string, { name: string; nodes: MemoryNode[]; paths: Map<string, string[]> }>();
  for (const node of graph.nodes) {
    if (node.scope === 'Haritalar arası çıkarım') continue;
    const id = nodeMapId(node);
    const item = clusters.get(id) ?? { name: mapClusterName(node.topicPath), nodes: [], paths: new Map<string, string[]>() };
    item.nodes.push(node); item.paths.set(JSON.stringify(node.topicPath), node.topicPath); clusters.set(id, item);
  }
  return [...clusters].map(([id, item]) => ({ id, name: item.name, count: item.nodes.length,
    sourceCount: new Set(item.nodes.flatMap(node => node.evidence.map(evidence => evidence.sourceId))).size,
    paths: [...item.paths.values()].sort((a, b) => a.join('/').localeCompare(b.join('/'), 'tr')),
  })).sort((a, b) => a.name.localeCompare(b.name, 'tr'));
}
