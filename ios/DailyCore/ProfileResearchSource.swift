import Foundation

/// Research has its own cloud note. The shared analysis engine receives the same
/// source shape as other tasks, but neither input nor output is a dated journal.
public enum ProfileResearchSource {
    public static let prefix = "note:dailyx/profile-research/"

    public static func key(for profile: WorkspaceRecord) -> String { prefix + profile.hash }

    public static func make(profile: WorkspaceRecord, request: String, date: String, now: String) throws -> WorkspaceRecord {
        let payload: JSONValue = .object([
            "entry": .object(["id": .string("profile-research-" + profile.hash),
                "local_date": .string(date), "raw_text": .string(request),
                "content_hash": .string(WorkspaceHash.sha256(request)), "saved_at": .string(now),
                "analysis_status": .string("pending"), "analysis_error": .null]),
            "questions": .array([]), "analyses": .array([])
        ])
        return try record(key: key(for: profile), payload: payload)
    }

    public static func record(key: String, payload: JSONValue) throws -> WorkspaceRecord {
        _ = try JournalDocument(payload: payload)
        return try WorkspaceRecord.make(key: key, kind: .note, payload: .string(payload.canonical()))
    }
}

extension WorkspaceRecord {
    public var isProfileResearch: Bool { kind == .note && key.hasPrefix(ProfileResearchSource.prefix) }

    public func analysisJournal() throws -> JournalDocument {
        guard isProfileResearch else { return try journal() }
        guard let text = try payload().string else { throw WorkspaceError.malformedRecord }
        return try JournalDocument(payload: JSONValue.parse(text))
    }
}
