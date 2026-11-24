import type { MemoryGraph, MemoryNode } from '../../shared/living-memory.js';
import { nodeMapId } from '../../shared/map-clusters.js';

export interface MemoryConsumer {
  id: string;
  matches(node: MemoryNode): boolean;
  acceptsSensitive: boolean;
  maxNodes: number;
  maxPerMap: number;
  maxChars: number;
  requireRelevance: boolean;
}

export interface MemoryRouteRequest {
  consumer: string;
  query?: string;
  linkedNodeIds?: readonly string[];
  // A future plugin may be explicitly attached to any newly created map.
  // Bindings never override the sensitive-data gate.
  mapBindings?: Readonly<Record<string, readonly string[]>>;
  sensitiveConsent?: boolean;
}

export interface MemoryRouteResult {
  consumer: string;
  nodes: MemoryNode[];
  edges: MemoryGraph['edges'];
  omitted: number;
  selectedMapIds: string[];
}

const normalize = (value: string) => value.normalize('NFKC').toLocaleLowerCase('tr-TR');
const terms = (value: string) => new Set(normalize(value).match(/[\p{L}\p{N}]{3,}/gu) ?? []);
const containsAny = (value: string, fragments: readonly string[]) => fragments.some(fragment => normalize(value).includes(fragment));
const healthTerms = ['sağlık', 'saglik', 'health', 'spor', 'egzersiz', 'antrenman', 'beslen', 'diyet', 'takviye', 'supplement', 'vitamin', 'kilo', 'beden', 'uyku'];
const agendaTerms = ['ajanda', 'takvim', 'randevu', 'toplantı', 'toplanti', 'deadline', 'son tarih', 'etkinlik', 'görüşme', 'gorusme'];
const writingTerms = ['yazı tarz', 'yazı üsl', 'yazi usl', 'üslup', 'uslup', 'anlatım', 'anlatim', 'konuşma biçim', 'konusma bicim', 'ifade tarz', 'dil kullan'];

function identity(node: MemoryNode): string { return `${node.topicPath.join(' / ')} ${node.label} ${node.scope} ${node.description ?? ''} ${node.evidence.slice(-3).map(item => item.observation).join(' ')}`; }
function healthNode(node: MemoryNode): boolean { return node.consumers?.includes('health') === true || containsAny(identity(node), healthTerms); }
function active(node: MemoryNode): boolean {
  return node.status !== 'retracted' && !node.corrections.some(item => item.verdict === 'incorrect' || item.verdict === 'no_longer');
}
function contextSize(node: MemoryNode): number {
  return JSON.stringify({ id: node.id, path: node.topicPath, label: node.label, scope: node.scope,
    description: node.description?.slice(0, 700),
    evidence: node.evidence.slice(-2).map(item => ({ sourceId: item.sourceId, date: item.date, observation: item.observation.slice(0, 350) })),
    corrections: node.corrections.slice(-3).map(item => item.text.slice(0, 500)),
  }).length;
}

export class MemoryRouter {
  private readonly consumers = new Map<string, MemoryConsumer>();
  constructor(consumers: MemoryConsumer[] = []) { for (const consumer of consumers) this.register(consumer); }

  register(consumer: MemoryConsumer): void {
    if (!/^[a-z][a-z0-9_-]{1,63}$/.test(consumer.id) || this.consumers.has(consumer.id)
      || consumer.maxNodes < 1 || consumer.maxPerMap < 1 || consumer.maxChars < 100) throw new Error('Geçersiz veya yinelenen hafıza tüketicisi.');
    this.consumers.set(consumer.id, consumer);
  }

  has(consumerId: string): boolean { return this.consumers.has(consumerId); }

  /** Whole-map summaries obey the same sensitivity gates as their constituent notes. */
  readableNodeIds(graph:MemoryGraph,request:MemoryRouteRequest):Set<string> {
    const consumer=this.consumers.get(request.consumer);
    if(!consumer)throw new Error('Bilinmeyen hafıza tüketicisi.');
    const byId=new Map(graph.nodes.map(n=>[n.id,n]));
    return new Set(graph.nodes.filter(node=>{
      const sensitive=healthNode(node)||(node.inference?.rootNodeIds??[]).some(id=>{
        const root=byId.get(id);return root!==undefined&&healthNode(root);
      });
      return active(node)&&(!sensitive||(request.sensitiveConsent&&(consumer.acceptsSensitive||
        (consumer.id==='reflection'&&containsAny(request.query??'',healthTerms)))))&&
        (request.mapBindings?.[nodeMapId(node)]?.includes(consumer.id)||node.consumers?.includes(consumer.id)||consumer.matches(node));
    }).map(n=>n.id));
  }

  select(graph: MemoryGraph, request: MemoryRouteRequest): MemoryRouteResult {
    const consumer = this.consumers.get(request.consumer);
    if (!consumer) throw new Error('Bilinmeyen hafıza tüketicisi.');
    const readable=this.readableNodeIds(graph,request);
    const queryTerms = terms(request.query ?? '');
    const linked = new Set(request.linkedNodeIds ?? []);
    const candidates = graph.nodes.flatMap(node => {
      if(!readable.has(node.id))return [];
      const nodeTerms = terms(`${identity(node)} ${node.description ?? ''}`);
      const overlap = [...queryTerms].filter(term => nodeTerms.has(term)).length;
      const correction = node.corrections.some(item => item.verdict === 'context');
      const score = (linked.has(node.id) ? 1000 : 0) + overlap * 10 + (correction ? 2 : 0);
      if (consumer.requireRelevance && !linked.has(node.id) && overlap === 0 && !(consumer.id === 'reflection' && correction)) return [];
      return [{ node, score, mapId: nodeMapId(node), latest: node.evidence.at(-1)?.date ?? '' }];
    }).sort((a, b) => b.score - a.score || b.latest.localeCompare(a.latest) || a.node.id.localeCompare(b.node.id));

    const nodes: MemoryNode[] = [], mapCounts = new Map<string, number>();
    let chars = 0;
    for (const item of candidates) {
      if (nodes.length >= consumer.maxNodes) break;
      if ((mapCounts.get(item.mapId) ?? 0) >= consumer.maxPerMap) continue;
      const size = contextSize(item.node);
      if (chars + size > consumer.maxChars) continue;
      nodes.push(item.node);
      chars += size;
      mapCounts.set(item.mapId, (mapCounts.get(item.mapId) ?? 0) + 1);
    }
    const ids = new Set(nodes.map(node => node.id));
    return { consumer: consumer.id, nodes, edges: graph.edges.filter(edge => ids.has(edge.source) && ids.has(edge.target)),
      omitted: candidates.length - nodes.length, selectedMapIds: [...mapCounts.keys()] };
  }
}

export function defaultMemoryRouter(): MemoryRouter {
  return new MemoryRouter([
    { id: 'reflection', matches: () => true, acceptsSensitive: false, maxNodes: 32, maxPerMap: 10, maxChars: 18_000, requireRelevance: true },
    { id: 'agenda', matches: node => containsAny(identity(node), agendaTerms), acceptsSensitive: false, maxNodes: 24, maxPerMap: 8, maxChars: 14_000, requireRelevance: true },
    { id: 'writing', matches: node => containsAny(identity(node), writingTerms), acceptsSensitive: false, maxNodes: 24, maxPerMap: 8, maxChars: 14_000, requireRelevance: false },
    { id: 'health', matches: healthNode, acceptsSensitive: true, maxNodes: 24, maxPerMap: 8, maxChars: 14_000, requireRelevance: false },
  ]);
}
