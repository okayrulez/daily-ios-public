import Foundation

/// Full source snapshot; the display-only MobileAtlas is not interchangeable with it.
public struct PortableMemory: Sendable, Codable {
    public let json: String
    public let revision: Int
    public let sourceCount: Int
    public let nodeCount: Int
    public let contentHash: String
    public let latestCountedJournalDate: String?

    public init(json: String) throws {
        let validated = try AnalysisCore.invoke("validateMemory", json: json)
        let value = try JSONValue.parse(validated)
        guard let object = value.object, let revision = object["revision"]?.integer,
              let sources = object["sources"]?.array,
              let nodes = object["graph"]?.object?["nodes"]?.array else { throw WorkspaceError.malformedRecord }
        self.json = try value.canonical()
        self.revision = revision; self.sourceCount = sources.count; self.nodeCount = nodes.count
        self.contentHash = WorkspaceHash.sha256(self.json)
        let latestJournalID = object["mapReview"]?.object?["journalIds"]?.array?.last?.string
        self.latestCountedJournalDate = latestJournalID.flatMap { id in
            sources.first { $0.object?["id"]?.string == id }?.object?["date"]?.string
        }
    }
    public init(from decoder: Decoder) throws { try self.init(json: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(json) }
}

public struct MemoryScope: Equatable, Sendable {
    public let projectID: String
    public let uid: String
    public init(projectID: String, uid: String) throws {
        try WorkspaceIdentity.validateUID(uid)
        guard projectID.range(of: "^[a-z][a-z0-9-]{3,62}$", options: .regularExpression) != nil else {
            throw WorkspaceError.invalidAccount
        }
        self.projectID = projectID; self.uid = uid
    }
    public var storageIdentity: String { WorkspaceHash.sha256(projectID + "\n" + uid) }
}

/// Serializes compare-and-swap and writes protected files atomically.
public actor MemoryStore {
    private static let fileLock = NSLock()
    private let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func load(scope: MemoryScope) throws -> PortableMemory? {
        try Self.fileLock.withLock { try loadUnlocked(scope: scope) }
    }
    private func loadUnlocked(scope: MemoryScope) throws -> PortableMemory? {
        let url = path(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else {
            throw WorkspaceError.oversizedRecord
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 16_000_000, let text = String(data: bytes, encoding: .utf8) else {
            throw WorkspaceError.oversizedRecord
        }
        return try PortableMemory(json: text)
    }
    public func save(_ memory: PortableMemory, expectedHash: String?, scope: MemoryScope) throws {
        try Self.fileLock.withLock {
            let previous = try loadUnlocked(scope: scope)
            guard previous?.contentHash == expectedHash else { throw WorkspaceError.conflict }
            if previous?.contentHash == memory.contentHash { return }
            if let previous, memory.revision <= previous.revision { throw WorkspaceError.conflict }
            try Data(memory.json.utf8).write(to: path(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    private func path(_ scope: MemoryScope) -> URL { root.appendingPathComponent(scope.storageIdentity + ".json") }
}
