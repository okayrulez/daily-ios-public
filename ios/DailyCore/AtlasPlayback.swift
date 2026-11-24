import Foundation

/// Compare what this device actually displayed, regardless of which device wrote Firebase.
public struct AtlasPlayback: Sendable {
    public let addedNodes, updatedNodes, removedNodes, changedEdges, removedEdges: Set<String>
    public let previous: MobileAtlas.Graph
    public let current: MobileAtlas.Graph
    public var hasChanges: Bool { !addedNodes.isEmpty || !updatedNodes.isEmpty || !removedNodes.isEmpty || !changedEdges.isEmpty || !removedEdges.isEmpty }
    public var drawing: MobileAtlas.Graph {
        .init(nodes: current.nodes + previous.nodes.filter { removedNodes.contains($0.id) },
              edges: current.edges + previous.edges.filter { removedEdges.contains($0.id) })
    }
    public init(previous: MobileAtlas.Graph?, current: MobileAtlas.Graph) {
        let before = previous ?? .init(nodes: [], edges: [])
        self.previous = before; self.current = current
        let oldNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let oldEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
        let ids = Set(current.nodes.map(\.id)), edges = Set(current.edges.map(\.id))
        addedNodes = ids.subtracting(oldNodes.keys)
        updatedNodes = Set(current.nodes.filter { oldNodes[$0.id] != nil && oldNodes[$0.id] != $0 }.map(\.id))
        removedNodes = Set(oldNodes.keys).subtracting(ids)
        changedEdges = Set(current.edges.filter { oldEdges[$0.id] != $0 }.map(\.id))
        removedEdges = Set(oldEdges.keys).subtracting(edges)
    }
}

/// Local only: viewing a map never writes receipts to Firebase or triggers a remote read.
public struct AtlasPlaybackStore: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }
    private func file(scope: String, mapID: String) -> URL {
        root.appendingPathComponent(WorkspaceHash.sha256(scope + ":" + mapID) + ".json")
    }
    public func read(scope: String, mapID: String) -> MobileAtlas.Graph? {
        guard let data = try? Data(contentsOf: file(scope: scope, mapID: mapID)) else { return nil }
        guard let graph = try? JSONDecoder().decode(MobileAtlas.Graph.self, from: data),
              Set(graph.nodes.map(\.id)).count == graph.nodes.count,
              Set(graph.edges.map(\.id)).count == graph.edges.count else { return nil }
        let ids = Set(graph.nodes.map(\.id))
        return graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) } ? graph : nil
    }
    public func acknowledge(_ graph: MobileAtlas.Graph, scope: String, mapID: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(graph).write(to: file(scope: scope, mapID: mapID), options: .atomic)
    }
}
