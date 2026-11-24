import Foundation

/// Versioned presentation contract: unsupported or incomplete snapshots never become partial graphs.
public struct MobileAtlas: Decodable, Sendable {
    public let schemaVersion: Int
    public let maps: [Map]
    public struct Map: Decodable, Identifiable, Sendable {
        public let id, title, updatedAt: String
        public let nodeCount, edgeCount: Int
        public let pages: [PageReference]
        public let detailPages: [PageReference]?
        public let quality: Quality?
    }
    public struct Quality: Decodable, Sendable {
        public let percent, reviewedNodes, totalNodes: Int
        public let current: Bool
        public let scope, rationale, assessedAt: String
        public let strengths, gaps: [String]
        public let dimensions: Dimensions
        public struct Dimensions: Decodable, Sendable {
            public let coverage, evidence, coherence, distinctness: Int
        }
        public var valid: Bool {
            (0...100).contains(percent) && reviewedNodes > 0 && reviewedNodes <= totalNodes &&
                ["full", "partial"].contains(scope) && (scope != "full" || reviewedNodes == totalNodes) &&
                [dimensions.coverage, dimensions.evidence, dimensions.coherence, dimensions.distinctness].allSatisfy { (0...100).contains($0) } &&
                rationale.utf16.count <= 1600 && strengths.count <= 4 && gaps.count <= 4 &&
                (strengths + gaps).allSatisfy { $0.utf16.count <= 500 }
        }
    }
    public struct PageReference: Decodable, Sendable {
        public let key, hash: String
        public func isNotePage(for mapID: String) -> Bool {
            key.range(of: "^note:companion/atlas/\(mapID)-notes-[0-9]+\\.md$", options: .regularExpression) != nil && WorkspaceHash.valid(hash)
        }
    }
    public struct Node: Codable, Equatable, Identifiable, Sendable {
        public let id, label, status, summary, updatedAt: String
        public let topicPath: [String]
        public var statusLabel: String {
            switch status {
            case "candidate": "Henüz bir çıkarım"
            case "recurring": "Tekrar eden"
            case "weakening": "Zayıflayan bağlantı"
            case "retracted": "Geri çekilmiş"
            case "corrected": "Düzeltilmiş"
            default: "Gözlem"
            }
        }
    }
    public struct Note: Decodable, Sendable {
        public let nodeId, kind, date, text: String
        public let quote, sourceId, sourceTitle: String?
        public let sourceKind: String?
        public let contentID: String?
        public let part: Int?
    }
    public static func notes(for map: Map, records: [WorkspaceRecord]) throws -> [Note] {
        var notes: [Note] = []
        for ref in map.detailPages ?? [] {
            try Task.checkCancellation()
            guard ref.isNotePage(for: map.id),
                  let record = records.first(where: { $0.key == ref.key }), record.hash == ref.hash else { throw WorkspaceError.conflict }
            let page = try decode(record, as: Page<Note>.self)
            guard page.schemaVersion == 1, page.mapId == map.id, page.kind == "notes", page.items.count <= 40,
                  page.items.allSatisfy({ $0.text.utf16.count <= 8000 && ["description","observation","inference","correction"].contains($0.kind) }) else { throw WorkspaceError.malformedRecord }
            notes += page.items
        }
        return notes
    }
    public struct Edge: Codable, Equatable, Identifiable, Sendable { public let id, source, target, relation: String }
    private struct Page<T: Decodable>: Decodable { let schemaVersion: Int; let mapId, kind: String; let items: [T] }
    public struct Graph: Codable, Equatable, Sendable {
        public let nodes: [Node]; public let edges: [Edge]
        public init(nodes: [Node], edges: [Edge]) { self.nodes = nodes; self.edges = edges }
        public func focused(on id: String) -> Graph {
            guard nodes.contains(where:{$0.id == id}) else { return self }
            let related=Set(edges.filter {$0.source == id || $0.target == id}.flatMap {[$0.source,$0.target]}+[id])
            return Graph(nodes:nodes.filter {related.contains($0.id)},edges:edges.filter {related.contains($0.source) && related.contains($0.target)})
        }
        public var revision: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let sorted = Graph(nodes: nodes.sorted { $0.id < $1.id }, edges: edges.sorted { $0.id < $1.id })
            return WorkspaceHash.sha256(String(decoding: (try? encoder.encode(sorted)) ?? Data(), as: UTF8.self))
        }
    }
    private static func decode<T: Decodable>(_ record: WorkspaceRecord, as type: T.Type) throws -> T {
        guard record.kind == .note, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    public static func load(records: [WorkspaceRecord]) throws -> MobileAtlas? {
        guard let record = records.first(where: { $0.key == "note:companion/atlas/index.md" }) else { return nil }
        let atlas = try decode(record, as: Self.self)
        guard atlas.schemaVersion == 1, Set(atlas.maps.map(\.id)).count == atlas.maps.count,
              atlas.maps.allSatisfy({ map in
                  map.id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil && map.title.utf16.count <= 160
                  && map.nodeCount >= 0 && map.edgeCount >= 0 && Set(map.pages.map(\.key)).count == map.pages.count
                  && (map.quality.map { $0.valid && (!$0.current || $0.totalNodes == map.nodeCount) } ?? true)
                  && map.pages.allSatisfy { $0.key.range(of: "^note:companion/atlas/\(map.id)-(nodes|edges)-[0-9]+\\.md$", options: .regularExpression) != nil }
              }) else { throw WorkspaceError.malformedRecord }
        return atlas
    }
    public static func graph(for map: Map, records: [WorkspaceRecord]) throws -> Graph {
        var nodes: [Node] = [], edges: [Edge] = []
        for reference in map.pages {
            try Task.checkCancellation()
            guard let record = records.first(where: { $0.key == reference.key }), record.hash == reference.hash else { throw WorkspaceError.conflict }
            if reference.key.contains("-nodes-") {
                let page = try decode(record, as: Page<Node>.self)
                guard page.schemaVersion == 1, page.mapId == map.id, page.kind == "nodes", page.items.count <= 60,
                      page.items.allSatisfy({ $0.label.utf16.count <= 160 && $0.summary.utf16.count <= 600 && $0.topicPath.count <= 12 }) else { throw WorkspaceError.malformedRecord }
                nodes += page.items
            } else {
                let page = try decode(record, as: Page<Edge>.self)
                guard page.schemaVersion == 1, page.mapId == map.id, page.kind == "edges", page.items.count <= 160 else { throw WorkspaceError.malformedRecord }
                edges += page.items
            }
        }
        let ids = Set(nodes.map(\.id))
        guard nodes.count == map.nodeCount, edges.count == map.edgeCount, ids.count == nodes.count,
              Set(edges.map(\.id)).count == edges.count,
              edges.allSatisfy({ ids.contains($0.source) && ids.contains($0.target) }) else { throw WorkspaceError.malformedRecord }
        return Graph(nodes: nodes, edges: edges)
    }
}
