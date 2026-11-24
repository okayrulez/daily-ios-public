import Foundation

/// One pending commit per Firebase account. Save BEFORE starting any remote write.
public actor PhoneAnalysisOutbox {
    private let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func path(_ scope: MemoryScope) -> URL { root.appendingPathComponent(scope.storageIdentity + ".json") }
    public func load(scope: MemoryScope) throws -> PhoneAnalysisCommit? {
        let file = path(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 60_000_000 else { throw WorkspaceError.oversizedRecord }
        let value = try JSONDecoder().decode(PhoneAnalysisCommit.self, from: Data(contentsOf: file))
        guard let manifestText=try value.manifest.payload().string,
              try JSONValue.parse(manifestText).object?["memoryHash"]?.string == value.memory.contentHash,
              value.source.key == value.journal.key,
              value.receipt.key == "note:dailyx/receipts/" + value.jobID else { throw WorkspaceError.malformedRecord }
        if !value.chunks.isEmpty {
            guard try PhoneAnalysisCommit.decodeMemory(manifest:value.manifest,chunks:value.chunks).contentHash == value.memory.contentHash else { throw WorkspaceError.invalidHash }
        }
        return value
    }
    public func save(_ plan: PhoneAnalysisCommit, scope: MemoryScope) throws {
        if let existing = try load(scope: scope) {
            guard existing.jobID == plan.jobID, existing.receipt == plan.receipt else { throw WorkspaceError.conflict }
            return
        }
        try JSONEncoder().encode(plan).write(to: path(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func remove(jobID: String, scope: MemoryScope) throws {
        guard let old = try load(scope: scope), old.jobID == jobID else { throw WorkspaceError.conflict }
        try FileManager.default.removeItem(at: path(scope))
    }
    public func archive(scope: MemoryScope) throws {
        guard let pending=try load(scope:scope) else { return }
        let archive=root.appendingPathComponent(scope.storageIdentity+"-"+pending.jobID+"-"+UUID().uuidString+".archived.json")
        try FileManager.default.moveItem(at:path(scope),to:archive)
    }
}
