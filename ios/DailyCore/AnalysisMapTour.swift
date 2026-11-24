import Foundation

/// An ephemeral presentation of one successfully committed result.
/// Every stop is backed by the exact validated atlas pages of that result.
public struct AnalysisMapTour: Identifiable, Sendable {
    public struct Stop: Identifiable, Sendable {
        public let id: String
        public let map: MobileAtlas.Map
        public var mapTitle: String { map.title }
        public let graph: MobileAtlas.Graph
        public let addedNodeIDs: Set<String>
        public let updatedNodeIDs: Set<String>
        public let addedEdgeIDs: Set<String>
        public let updatedEdgeIDs: Set<String>
    }
    public let id: String
    public let date: String
    public let stops: [Stop]
    public let graphs: [String: MobileAtlas.Graph]
    public let notes: [String: [MobileAtlas.Note]]
    private let isJournalAnalysis: Bool

    public struct ConnectionHint: Sendable {
        public let from: MobileAtlas.Node
        public let to: MobileAtlas.Node
    }

    @MainActor public func claimConnectionHint(at stop: Stop, defaults: UserDefaults = .standard) -> ConnectionHint? {
        let key = "dailyx-first-journal-connection-hint-shown"
        guard isJournalAnalysis, !stop.addedEdgeIDs.isEmpty, !defaults.bool(forKey: key),
              let graph = graphs[stop.id] else { return nil }
        for edge in graph.edges where stop.addedEdgeIDs.contains(edge.id) && edge.source != edge.target {
            guard let from = stop.graph.nodes.first(where: { $0.id == edge.source }),
                  let to = stop.graph.nodes.first(where: { $0.id == edge.target }),
                  !from.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !to.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            defaults.set(true, forKey: key)
            return ConnectionHint(from: from, to: to)
        }
        return nil
    }

    public static func make(id: String, date: String, changes: AnalysisChanges,
                            records: [WorkspaceRecord], isJournalAnalysis: Bool = false) throws -> AnalysisMapTour? {
        guard let atlas = try MobileAtlas.load(records: records) else { return nil }
        let added = Set(changes.addedNodeIDs)
        let updated = Set(changes.updatedNodeIDs ?? []).subtracting(added)
        let newEdges = Set(changes.addedEdgeIDs ?? [])
        let updatedEdges = Set(changes.updatedEdgeIDs ?? []).subtracting(newEdges)
        guard !added.isEmpty || !updated.isEmpty || !newEdges.isEmpty || !updatedEdges.isEmpty else { return nil }
        var stops: [Stop] = []
        var graphs: [String: MobileAtlas.Graph] = [:]
        var notes: [String: [MobileAtlas.Note]] = [:]
        for map in atlas.maps {
            let graph = try MobileAtlas.graph(for: map, records: records)
            let nodeIDs = Set(graph.nodes.map(\.id))
            let addedHere = added.intersection(nodeIDs)
            let updatedHere = updated.intersection(nodeIDs)
            var changedEdges: [MobileAtlas.Edge] = []
            var shownPairs: Set<[String]> = []
            for edge in graph.edges where newEdges.contains(edge.id) || updatedEdges.contains(edge.id) {
                // Several saved relationships can draw the same line on screen.
                if shownPairs.insert([edge.source, edge.target].sorted()).inserted {
                    changedEdges.append(edge)
                }
            }
            let visibleIDs = addedHere.union(updatedHere).union(changedEdges.flatMap { [$0.source, $0.target] })
            guard !visibleIDs.isEmpty else { continue }
            let changedGraph = MobileAtlas.Graph(
                nodes: graph.nodes.filter { visibleIDs.contains($0.id) },
                edges: changedEdges
            )
            graphs[map.id] = graph
            notes[map.id] = try? MobileAtlas.notes(for: map, records: records)
            let edgeIDs = Set(graph.edges.map(\.id))
            stops.append(Stop(id: map.id, map: map, graph: changedGraph,
                addedNodeIDs: addedHere, updatedNodeIDs: updatedHere,
                addedEdgeIDs: newEdges.intersection(edgeIDs), updatedEdgeIDs: updatedEdges.intersection(edgeIDs)))
        }
        guard !stops.isEmpty else { return nil }
        return AnalysisMapTour(id: id, date: date, stops: stops, graphs: graphs, notes: notes, isJournalAnalysis: isJournalAnalysis)
    }
}

/// A named change on this map, selected from saved non-reverted analyses.
public struct AtlasRecentChange: Sendable {
    public enum Kind: Equatable, Sendable { case added, updated, newLink, updatedLink, datedNote }
    public let kind: Kind
    public let title: String
    public let date: String?

    public static func latest(in graph: MobileAtlas.Graph, receipts: [WorkspaceChangeReceipt]) -> Self? {
        let labels = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.label) })
        let edges = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0) })
        for receipt in receipts where receipt.undone != true {
            let changes = receipt.changes
            for (kind, ids) in [(Kind.added, changes.addedNodeIDs), (.updated, changes.updatedNodeIDs ?? [])] {
                if let label = ids.lazy.compactMap({ labels[$0] }).first {
                    return Self(kind: kind, title: label, date: receipt.date)
                }
            }
            for (kind, ids) in [(Kind.newLink, changes.addedEdgeIDs ?? []), (.updatedLink, changes.updatedEdgeIDs ?? [])] {
                if let edge = ids.lazy.compactMap({ edges[$0] }).first,
                   let from = labels[edge.source], let to = labels[edge.target] {
                    return Self(kind: kind, title: "\(from) ↔ \(to)", date: receipt.date)
                }
            }
        }
        let dated = graph.nodes.filter { WorkspaceIdentity.validDate(String($0.updatedAt.prefix(10))) }
        guard let node = dated.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return Self(kind: .datedNote, title: node.label, date: String(node.updatedAt.prefix(10)))
    }
}
