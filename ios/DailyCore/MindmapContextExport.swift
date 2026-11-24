import Foundation

public struct MindmapContextSnapshot: Sendable {
    public let memory: PortableMemory
    public let emotionHistory: JSONValue

    public init(memory: PortableMemory, emotionHistory: JSONValue = .array([])) {
        self.memory = memory
        self.emotionHistory = emotionHistory
    }

    public func preview(purpose: String, includeEmotions: Bool, exportedAt: Date = Date()) throws -> MindmapContextPreview {
        let data = try request(purpose: purpose, includeEmotions: includeEmotions, exportedAt: exportedAt, preview: true)
        return try JSONDecoder().decode(MindmapContextPreview.self, from: Data(data.utf8))
    }

    fileprivate func request(purpose: String, includeEmotions: Bool, exportedAt: Date, preview: Bool = false,
                             selectedNoteIDs: Set<String>? = nil) throws -> String {
        var input: [String: JSONValue] = [
            "memory": try JSONValue.parse(memory.json),
            "purpose": .string(purpose),
            "includeEmotions": .bool(includeEmotions),
            "emotionHistory": includeEmotions && !preview ? emotionHistory : .array([]),
            "exportedAt": .string(exportedAt.ISO8601Format()),
            "preview": .bool(preview)
        ]
        if let selectedNoteIDs {
            input["selectedNoteIDs"] = .array(selectedNoteIDs.sorted().map(JSONValue.string))
        }
        return try AnalysisCore.invoke("exportMindmapContext", json: JSONValue.object(input).canonical())
    }
}

public struct MindmapContextPreview: Decodable, Sendable {
    public struct Quote: Decodable, Sendable {
        public let date: String
        public let quote: String
        public let sourceID: String
    }

    public struct Note: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let mapId: String
        public let mapTitle: String
        public let requiredNoteIDs: [String]
        public let quotes: [Quote]
    }

    public let notes: [Note]
    public let suggestedNoteIDs: [String]
}

/// Human-readable instructions plus a source-linked graph.
public struct MindmapContextExport: Sendable {
    public let markdown: String
    public let revision: Int
    public let mapCount: Int
    public let nodeCount: Int
    public let edgeCount: Int

    public init(memory: PortableMemory, purpose: String, exportedAt: Date = Date(), includeEmotions: Bool = false,
                emotionHistory: JSONValue = .array([])) throws {
        try self.init(snapshot: MindmapContextSnapshot(memory: memory, emotionHistory: emotionHistory),
                      purpose: purpose, exportedAt: exportedAt, includeEmotions: includeEmotions)
    }

    public init(snapshot: MindmapContextSnapshot, purpose: String, exportedAt: Date = Date(),
                includeEmotions: Bool, selectedNoteIDs: Set<String>? = nil) throws {
        let result = try snapshot.request(purpose: purpose, includeEmotions: includeEmotions, exportedAt: exportedAt,
                                          selectedNoteIDs: selectedNoteIDs)
        guard let value = try JSONValue.parse(result).object,
              let markdown = value["markdown"]?.string,
              let revision = value["revision"]?.integer,
              let mapCount = value["mapCount"]?.integer,
              let nodeCount = value["nodeCount"]?.integer,
              let edgeCount = value["edgeCount"]?.integer else { throw AnalysisCoreError.invalidOutput }
        self.markdown = markdown
        self.revision = revision
        self.mapCount = mapCount
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
    }
}
