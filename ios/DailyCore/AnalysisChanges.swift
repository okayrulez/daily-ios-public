import Foundation

public struct AnalysisChanges: Codable, Sendable {
    public let questions: Int
    public let newNotes: Int
    public let updatedNotes: Int
    public let newLinks: Int
    public let addedNodeIDs: [String]
    // Optional fields keep older saved outbox results decodable.
    public let updatedNodeIDs: [String]?
    public let addedEdgeIDs: [String]?
    public let updatedEdgeIDs: [String]?
    public var animationIdentity: String {
        (addedNodeIDs + (updatedNodeIDs ?? []) + (addedEdgeIDs ?? []) + (updatedEdgeIDs ?? [])).joined(separator: "|")
    }

    public static func combined(_ stages: [AnalysisChanges]) -> AnalysisChanges {
        let nodes = Set(stages.flatMap(\.addedNodeIDs))
        let updated = Set(stages.flatMap { $0.updatedNodeIDs ?? [] }).subtracting(nodes)
        let edges = Set(stages.flatMap { $0.addedEdgeIDs ?? [] })
        return AnalysisChanges(questions: stages.last?.questions ?? 0, newNotes: nodes.count,
            updatedNotes: updated.count, newLinks: edges.count, addedNodeIDs: nodes.sorted(),
            updatedNodeIDs: updated.sorted(), addedEdgeIDs: edges.sorted(),
            updatedEdgeIDs: Set(stages.flatMap { $0.updatedEdgeIDs ?? [] }).subtracting(edges).sorted())
    }

    private init(questions: Int, newNotes: Int, updatedNotes: Int, newLinks: Int, addedNodeIDs: [String],
                 updatedNodeIDs: [String], addedEdgeIDs: [String], updatedEdgeIDs: [String]) {
        self.questions = questions; self.newNotes = newNotes; self.updatedNotes = updatedNotes; self.newLinks = newLinks
        self.addedNodeIDs = addedNodeIDs; self.updatedNodeIDs = updatedNodeIDs
        self.addedEdgeIDs = addedEdgeIDs; self.updatedEdgeIDs = updatedEdgeIDs
    }

    public init(before: JSONValue, after: JSONValue, questionCount: Int) throws {
        func rows(_ graph: JSONValue, _ key: String) throws -> [String: JSONValue] {
            guard let items = graph.object?[key]?.array else { throw WorkspaceError.malformedRecord }
            var indexed: [String: JSONValue] = [:]
            for item in items {
                guard let id = item.object?["id"]?.string, indexed[id] == nil else { throw WorkspaceError.malformedRecord }
                indexed[id] = item
            }
            return indexed
        }
        let oldNodes = try rows(before, "nodes"), newNodes = try rows(after, "nodes")
        let oldEdges = try rows(before, "edges"), newEdges = try rows(after, "edges")
        addedNodeIDs = newNodes.keys.filter { oldNodes[$0] == nil }.sorted()
        newNotes = addedNodeIDs.count
        updatedNodeIDs = newNodes.filter { oldNodes[$0.key] != nil && oldNodes[$0.key] != $0.value }.keys.sorted()
        updatedNotes = updatedNodeIDs?.count ?? 0
        addedEdgeIDs = newEdges.keys.filter { oldEdges[$0] == nil }.sorted()
        updatedEdgeIDs = newEdges.filter { oldEdges[$0.key] != nil && oldEdges[$0.key] != $0.value }.keys.sorted()
        newLinks = addedEdgeIDs?.count ?? 0
        questions = questionCount
    }
}
