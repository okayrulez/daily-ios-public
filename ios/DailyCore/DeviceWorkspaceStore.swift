import Foundation

public struct WorkspaceExpected: Codable, Sendable {
    public let key: String
    public let hash: String?
    public init(key: String, hash: String?) { self.key = key; self.hash = hash }
}

public struct WorkspacePublication: Codable, Sendable, Identifiable {
    public let id: String
    public let records: [WorkspaceRecord]
    public let expected: [WorkspaceExpected]
    public let chunks: [WorkspaceRecord]
    public init(id: String, records: [WorkspaceRecord], expected: [WorkspaceExpected], chunks: [WorkspaceRecord]) {
        self.id = id
        self.records = records
        self.expected = expected
        self.chunks = chunks
    }
}

/// Atomic, account/project-isolated primary storage. Cloud publication is an optional durable queue.
public final class DeviceWorkspaceStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var records: [String: WorkspaceRecord] = [:]
        var versions: [String: [String: WorkspaceRecord]] = [:]
        var pending: [WorkspacePublication] = []
        var resetPending: Bool? = nil
    }
    public let scope: MemoryScope
    private let file: URL
    private let lock = NSRecursiveLock()
    private var snapshot: Snapshot

    public init(root: URL, scope: MemoryScope) throws {
        self.scope = scope
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        file = root.appendingPathComponent(scope.storageIdentity + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            for (key, record) in snapshot.records where key != record.key { throw WorkspaceError.invalidAddress }
        } else { snapshot = Snapshot() }
    }
    public func records() -> [WorkspaceRecord] { lock.withLock { Array(snapshot.records.values) } }
    public func record(_ key: String) -> WorkspaceRecord? { lock.withLock { snapshot.records[key] } }
    public func version(key: String, hash: String) -> WorkspaceRecord? { lock.withLock { snapshot.versions[key]?[hash] } }
    public func firstPublication() -> WorkspacePublication? { lock.withLock { snapshot.pending.first } }
    public var pendingCount: Int { lock.withLock { snapshot.pending.count } }
    public func hasPendingPublication(key: String) -> Bool {
        lock.withLock { snapshot.pending.contains { publication in publication.records.contains { $0.key == key } } }
    }
    public var resetPending: Bool { lock.withLock { snapshot.resetPending == true } }

    /// Durable fence: an interrupted reset cannot publish or re-import old records on restart.
    public func beginReset() throws {
        try lock.withLock {
            var next = snapshot; next.resetPending = true
            try persist(next); snapshot = next
        }
    }
    public func finishReset() throws {
        try lock.withLock {
            guard snapshot.resetPending == true else { throw WorkspaceError.conflict }
            let next = Snapshot()
            try persist(next); snapshot = next
        }
    }
    private func requireWritable() throws {
        guard snapshot.resetPending != true else { throw WorkspaceError.conflict }
    }

    @discardableResult
    public func apply(_ records: [WorkspaceRecord], expected: [WorkspaceExpected], chunks: [WorkspaceRecord] = [],
                      publish: Bool, id: String = UUID().uuidString.lowercased()) throws -> Bool {
        try lock.withLock {
            try requireWritable()
            if snapshot.pending.contains(where: { $0.id == id }) { return false }
            for condition in expected {
                guard snapshot.records[condition.key]?.hash == condition.hash else { throw WorkspaceError.conflict }
            }
            guard Set(records.map(\.key)).count == records.count else { throw WorkspaceError.malformedRecord }
            let changed = records.filter { snapshot.records[$0.key] != $0 }
            if changed.isEmpty && chunks.allSatisfy({ snapshot.records[$0.key] == $0 }) { return false }
            var next = snapshot
            for chunk in chunks {
                if let old = next.records[chunk.key], old != chunk { throw WorkspaceError.conflict }
                next.records[chunk.key] = chunk
            }
            let changedKeys = Set(changed.map(\.key))
            let baselines = changed.map { WorkspaceExpected(key: $0.key, hash: snapshot.records[$0.key]?.hash) }
                + expected.filter { !changedKeys.contains($0.key) }
            for record in changed {
                if let previous = next.records[record.key] {
                    next.versions[record.key, default: [:]][previous.hash] = previous
                }
                next.records[record.key] = record
            }
            if publish && !changed.isEmpty {
                next.pending.append(WorkspacePublication(id: id, records: changed, expected: baselines, chunks: chunks))
            }
            try persist(next); snapshot = next
            return true
        }
    }

    /// Read-only cloud reconciliation never overwrites unsent local changes.
    public func importCloud(_ records: [WorkspaceRecord]) throws {
        try lock.withLock {
            try requireWritable()
            guard snapshot.pending.isEmpty else { throw WorkspaceError.conflict }
            var next = snapshot
            for record in records {
                if let previous = next.records[record.key], previous != record { next.versions[record.key, default: [:]][previous.hash] = previous }
                next.records[record.key] = record
            }
            try persist(next); snapshot = next
        }
    }
    public func acknowledge(_ publication: WorkspacePublication) throws {
        try lock.withLock {
            try requireWritable()
            guard snapshot.pending.first?.id == publication.id else { throw WorkspaceError.conflict }
            var next = snapshot; next.pending.removeFirst()
            let marker = try WorkspaceRecord.make(key: "note:companion/sync-revision.json", kind: .note,
                payload: .string(JSONValue.object(["revision": .string(publication.id)]).canonical()))
            next.records[marker.key] = marker
            try persist(next); snapshot = next
        }
    }
    public func queueCurrentRecords() throws {
        try lock.withLock {
            try requireWritable()
            guard snapshot.pending.isEmpty else { return }
            let all = Array(snapshot.records.values)
            let manifest = snapshot.records[PhoneAnalysisCommit.manifestKey]
            let text = try manifest?.payload().string
            let references = try text.map { try JSONValue.parse($0).object?["chunks"]?.array ?? [] } ?? []
            let keys = Set(references.compactMap { $0.object?["key"]?.string })
            let chunks = all.filter { keys.contains($0.key) }
            let records = all.filter { !$0.key.hasPrefix("note:dailyx/chunks/") && $0.key != "note:companion/sync-revision.json" }
                .sorted { lhs, rhs in
                    func tail(_ key: String) -> Int { key == PhoneAnalysisCommit.manifestKey || key == "note:companion/atlas/index.md" ? 1 : 0 }
                    return tail(lhs.key) == tail(rhs.key) ? lhs.key < rhs.key : tail(lhs.key) < tail(rhs.key)
                }
            guard !records.isEmpty else { return }
            var next = snapshot
            var batches: [[WorkspaceRecord]] = [], current: [WorkspaceRecord] = [], bytes = 0
            for record in records {
                let size = try WorkspaceRecordStorage(record).fields.canonical().utf8.count
                if !current.isEmpty && (current.count >= 390 || bytes + size > 3_500_000) { batches.append(current); current = []; bytes = 0 }
                current.append(record); bytes += size
            }
            if !current.isEmpty { batches.append(current) }
            for (index, batch) in batches.enumerated() {
                next.pending.append(WorkspacePublication(id: UUID().uuidString.lowercased(), records: batch,
                    expected: batch.map { WorkspaceExpected(key: $0.key, hash: nil) }, chunks: index == 0 ? chunks : []))
            }
            try persist(next); snapshot = next
        }
    }
    public func copyDeviceWorkspace(from other: DeviceWorkspaceStore) throws {
        guard other.scope != scope else { return }
        guard !other.resetPending else { throw WorkspaceError.conflict }
        var copied = other.lock.withLock { other.snapshot }; copied.pending = []
        try lock.withLock {
            try requireWritable()
            guard snapshot.records.isEmpty, snapshot.pending.isEmpty else { throw WorkspaceError.conflict }
            try persist(copied); snapshot = copied
        }
    }
    /// Explicit conflict recovery: retain every local record and version in a separate durable area first.
    public func useCloudRecords(_ records: [WorkspaceRecord], preservingIn backup: DeviceWorkspaceStore) throws {
        guard backup.scope != scope else { throw WorkspaceError.conflict }
        try lock.withLock {
            try requireWritable()
            try backup.copyDeviceWorkspace(from: self)
            var next = Snapshot()
            for record in records {
                guard next.records[record.key] == nil else { throw WorkspaceError.malformedRecord }
                next.records[record.key] = record
            }
            try persist(next); snapshot = next
        }
    }
    private func persist(_ value: Snapshot) throws {
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func commitAnalysis(_ plan: PhoneAnalysisCommit, publish: Bool) throws {
        try lock.withLock {
            try requireWritable()
            if let receipt = snapshot.records[plan.receipt.key] {
                guard receipt == plan.receipt else { throw WorkspaceError.conflict }; return
            }
            try apply([plan.journal, plan.manifest, plan.receipt] + plan.atlas,
                expected: [WorkspaceExpected(key: plan.source.key, hash: plan.source.hash),
                           WorkspaceExpected(key: plan.manifest.key, hash: plan.expectedManifest?.hash)],
                chunks: plan.chunks, publish: publish, id: plan.jobID)
        }
    }
    public func commitMemoryEdit(_ plan: WorkspaceMemoryMutation, publish: Bool) throws {
        try lock.withLock {
            try requireWritable()
            if snapshot.records[plan.manifest.key] == plan.manifest { return }
            try apply([plan.manifest] + plan.records,
                expected: [WorkspaceExpected(key: plan.manifest.key, hash: plan.expectedManifest?.hash)] +
                    plan.expectedRecords.map { WorkspaceExpected(key: $0.key, hash: $0.hash) },
                chunks: plan.chunks, publish: publish)
        }
    }
    public func memory(manifest: WorkspaceRecord? = nil) throws -> (PortableMemory?, WorkspaceRecord?) {
        try lock.withLock {
            try requireWritable()
            guard let manifest = manifest ?? snapshot.records[PhoneAnalysisCommit.manifestKey] else { return (nil, nil) }
            guard let text = try manifest.payload().string, let refs = try JSONValue.parse(text).object?["chunks"]?.array else {
                throw WorkspaceError.malformedRecord
            }
            if try JSONValue.parse(text).object?["storage"] == .string("device") { return (nil, manifest) }
            let chunks = try refs.map { ref -> WorkspaceRecord in
                guard let key = ref.object?["key"]?.string, let chunk = snapshot.records[key] else { throw WorkspaceError.malformedRecord }
                return chunk
            }
            return (try PhoneAnalysisCommit.decodeMemory(manifest: manifest, chunks: chunks), manifest)
        }
    }
}
