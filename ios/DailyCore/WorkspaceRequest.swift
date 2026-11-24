import Foundation

public enum WorkspaceAnalysisKind: String, Sendable, CaseIterable { case initial, answers }
public enum WorkspaceRequestStatus: String, Sendable { case queued, processing, complete, failed, stale }
public enum WorkspaceRequestError: Error, Equatable, Sendable { case malformed, sourceChanged, accountChanged }

/// Timestamp fields are epoch seconds only inside DailyCore. The Firebase adapter
/// accepts real Firestore Timestamps and writes them back as Timestamps, never numbers.
public struct WorkspaceAnalysisRequest: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public var id: String { kind.rawValue + "-" + sourceHash }
    public var kind: WorkspaceAnalysisKind { WorkspaceAnalysisKind(rawValue: fields["kind"]!.string!)! }
    public var recordKey: String { fields["recordKey"]!.string! }
    public var sourceHash: String { fields["sourceHash"]!.string! }
    public var resultHash: String? { fields["resultHash"]?.string }
    public var status: WorkspaceRequestStatus { WorkspaceRequestStatus(rawValue: fields["status"]!.string!)! }
    public var updatedAt: Double { fields["updatedAt"]!.number! }

    public init(documentID: String, fields: [String: JSONValue]) throws {
        guard Set(fields.keys) == Set(["schemaVersion", "kind", "recordKey", "sourceHash", "status", "leaseOwner",
                                       "leaseUntil", "attemptCount", "createdAt", "updatedAt", "resultHash", "errorCode"]),
              fields["schemaVersion"] == .number(1),
              let kindText = fields["kind"]?.string, let kind = WorkspaceAnalysisKind(rawValue: kindText),
              let key = fields["recordKey"]?.string, key.hasPrefix("journal:"), WorkspaceIdentity.validDate(String(key.dropFirst(8))),
              let hash = fields["sourceHash"]?.string, WorkspaceHash.valid(hash),
              documentID == (try Self.identity(kind: kind, sourceHash: hash)),
              let statusText = fields["status"]?.string, let status = WorkspaceRequestStatus(rawValue: statusText),
              let attempts = fields["attemptCount"]?.integer, attempts >= 0,
              let created = fields["createdAt"]?.number, created.isFinite,
              let updated = fields["updatedAt"]?.number, updated.isFinite,
              fields["leaseUntil"] == .null || fields["leaseUntil"]?.number?.isFinite == true,
              fields["leaseOwner"] == .null || fields["leaseOwner"]?.string.map({ (try? WorkspaceIdentity.validateUID($0)) != nil }) == true,
              fields["resultHash"] == .null || fields["resultHash"]?.string.map(WorkspaceHash.valid) == true,
              fields["errorCode"] == .null || ["analysis_failed", "source_changed", "invalid_proposal"].contains(fields["errorCode"]?.string ?? "")
        else { throw WorkspaceRequestError.malformed }
        guard status == .processing || (fields["leaseOwner"] == .null && fields["leaseUntil"] == .null),
              status == .complete || fields["resultHash"] == .null else { throw WorkspaceRequestError.malformed }
        switch status {
        case .queued:
            guard ["leaseOwner", "leaseUntil", "resultHash", "errorCode"].allSatisfy({ fields[$0] == .null }) else { throw WorkspaceRequestError.malformed }
        case .processing:
            guard fields["leaseOwner"]?.string != nil, fields["leaseUntil"]?.number != nil, attempts >= 1,
                  fields["errorCode"] == .null else { throw WorkspaceRequestError.malformed }
        case .complete:
            guard fields["resultHash"]?.string != nil, fields["errorCode"] == .null else { throw WorkspaceRequestError.malformed }
        case .failed:
            guard fields["errorCode"]?.string != nil else { throw WorkspaceRequestError.malformed }
        case .stale:
            guard fields["errorCode"] == .string("source_changed") else { throw WorkspaceRequestError.malformed }
        }
        self.fields = fields
    }

    public static func identity(kind: WorkspaceAnalysisKind, sourceHash: String) throws -> String {
        guard WorkspaceHash.valid(sourceHash) else { throw WorkspaceRequestError.malformed }
        return kind.rawValue + "-" + sourceHash
    }

    public static func path(uid: String) throws -> String {
        try WorkspaceIdentity.validateUID(uid)
        return "users/\(uid)/dailyXRequests"
    }

    public func matches(_ record: WorkspaceRecord) -> Bool {
        record.kind == .journal && record.key.utf8.elementsEqual(recordKey.utf8)
            && (record.hash == sourceHash || (status == .complete && record.hash == resultHash))
    }

    public static func latest(_ requests: [WorkspaceAnalysisRequest], for record: WorkspaceRecord,
                              kind: WorkspaceAnalysisKind) -> WorkspaceAnalysisRequest? {
        requests.filter { $0.kind == kind && $0.matches(record) }.sorted {
            // A new request for the exact source outranks a previous completed result.
            if ($0.sourceHash == record.hash) != ($1.sourceHash == record.hash) { return $0.sourceHash == record.hash }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }.first
    }
}

public enum WorkspaceRequestPlanner {
    /// Called with server reads inside a Firestore transaction. A nil plan is a
    /// successful idempotent duplicate, not a write or a locally invented result.
    public static func enqueue(current: WorkspaceRecord?, expected: WorkspaceRecord, kind: WorkspaceAnalysisKind,
                               existing: WorkspaceAnalysisRequest?, now: Double) throws -> WorkspaceAnalysisRequest? {
        guard let current, current.kind == .journal, expected.kind == .journal,
              current.key.utf8.elementsEqual(expected.key.utf8), current.hash == expected.hash else { throw WorkspaceRequestError.sourceChanged }
        let id = try WorkspaceAnalysisRequest.identity(kind: kind, sourceHash: expected.hash)
        if let existing {
            guard existing.id == id, existing.recordKey.utf8.elementsEqual(expected.key.utf8) else { throw WorkspaceRequestError.malformed }
            if existing.status != .failed && existing.status != .stale { return nil }
        }
        return try WorkspaceAnalysisRequest(documentID: id, fields: [
            "schemaVersion": .number(1), "kind": .string(kind.rawValue), "recordKey": .string(expected.key),
            "sourceHash": .string(expected.hash), "status": .string("queued"), "leaseOwner": .null, "leaseUntil": .null,
            "attemptCount": existing?.fields["attemptCount"] ?? .number(0),
            "createdAt": existing?.fields["createdAt"] ?? .number(now), "updatedAt": .number(now), "resultHash": .null, "errorCode": .null
        ])
    }
}

public enum WorkspaceRequestBlock: Equatable, Sendable {
    case saveFirst, emptyText, alreadyAnalyzed, answerFirst, initialFirst, connectionRequired, accountChanged
}

public enum WorkspaceRequestEligibility {
    public static func block(uid: String, date: String, record: WorkspaceRecord?, draft: WorkspaceDraft?,
                             kind: WorkspaceAnalysisKind, serverReady: Bool, networkAvailable: Bool) -> WorkspaceRequestBlock? {
        guard (try? WorkspaceIdentity.validateUID(uid)) != nil, draft == nil || draft?.uid == uid else { return .accountChanged }
        guard let record, record.key == "journal:\(date)", let journal = try? record.journal() else { return .saveFirst }
        if let draft, draft.date != date || draft.hasChanges || draft.requiresComparison || draft.base?.hash != record.hash { return .saveFirst }
        guard serverReady && networkAvailable else { return .connectionRequired }
        guard !journal.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyText }
        switch kind {
        case .initial:
            return journal.analysisStatus == "complete" ? .alreadyAnalyzed : nil
        case .answers:
            guard journal.analysisStatus == "complete" else { return .initialFirst }
            let answered = journal.questions.contains { question in
                switch question.kind {
                case .open: return !(question.answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .boolean: return question.answerBoolean != nil
                }
            }
            return answered ? nil : .answerFirst
        }
    }
}

public struct WorkspaceRequestScope: Equatable, Sendable {
    public let uid: String
    public let session: UUID
    public let generation: UUID
    public init(uid: String, session: UUID, generation: UUID) throws {
        try WorkspaceIdentity.validateUID(uid)
        self.uid = uid; self.session = session; self.generation = generation
    }
}

/// Transaction retries run off the main actor. Every access to the captured
/// account/listener scope is lock-protected, including logout invalidation.
public final class WorkspaceRequestSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: WorkspaceRequestScope?
    public init() {}
    public func activate(_ scope: WorkspaceRequestScope) { lock.lock(); defer { lock.unlock() }; active = scope }
    public func invalidate() { lock.lock(); defer { lock.unlock() }; active = nil }
    public func accepts(_ scope: WorkspaceRequestScope, authenticatedUID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == scope && authenticatedUID == scope.uid
    }
}
