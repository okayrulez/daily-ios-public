import Foundation

public enum WorkspaceKind: String, Codable, Sendable { case journal, vision, feedback, inference, note }

public struct WorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let kind: WorkspaceKind
    public let content: String
    public let hash: String
    // Swift String equality normalizes Unicode; PC/Firestore identity is exact UTF-8 bytes.
    public var id: String { documentID }
    public var documentID: String { WorkspaceHash.sha256(key) }

    public static func == (lhs: WorkspaceRecord, rhs: WorkspaceRecord) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.kind == rhs.kind && lhs.hash == rhs.hash
            && lhs.content.utf8.elementsEqual(rhs.content.utf8)
    }

    public static func index(_ records: [WorkspaceRecord]) throws -> [String: WorkspaceRecord] {
        var result: [String: WorkspaceRecord] = [:]
        for record in records {
            let identity = record.documentID
            guard result[identity] == nil else { throw WorkspaceError.malformedRecord }
            result[identity] = record
        }
        return result
    }
    public var json: JSONValue {
        .object(["schemaVersion": .number(1), "key": .string(key), "kind": .string(kind.rawValue), "content": .string(content), "hash": .string(hash)])
    }

    public init(json: JSONValue) throws {
        guard let data = json.object,
              Set(data.keys) == Set(["schemaVersion", "key", "kind", "content", "hash"]),
              data["schemaVersion"] == .number(1), let key = data["key"]?.string,
              !key.isEmpty, key.utf16.count <= 500,
              let kindText = data["kind"]?.string, let kind = WorkspaceKind(rawValue: kindText),
              key.hasPrefix(kind.rawValue + ":"), key.count > kind.rawValue.count + 1,
              let content = data["content"]?.string, !content.isEmpty,
              let hash = data["hash"]?.string, WorkspaceHash.valid(hash) else { throw WorkspaceError.malformedRecord }
        // Firestore documents are bounded by WorkspaceRecordStorage; a logical diary is chunked.
        guard kind == .journal || content.utf8.count <= 700_000 else { throw WorkspaceError.oversizedRecord }
        guard WorkspaceHash.sha256(content) == hash else { throw WorkspaceError.invalidHash }
        self.key = key; self.kind = kind; self.content = content; self.hash = hash
        let payload = try JSONValue.parse(content)
        // All PC writers emit canonical JSON. Reject ambiguous duplicate-key/noncanonical
        // JSON rather than reinterpreting it differently and losing data on the next edit.
        guard try payload.canonical().utf8.elementsEqual(content.utf8) else { throw WorkspaceError.malformedRecord }
        switch kind {
        case .journal:
            let journal = try JournalDocument(payload: payload)
            guard key.utf8.elementsEqual("journal:\(journal.date)".utf8) else { throw WorkspaceError.invalidAddress }
        case .note:
            guard payload.string != nil else { throw WorkspaceError.malformedRecord }
        case .inference, .vision, .feedback:
            try PortableRow.validate(payload, kind: kind)
            guard let id = payload.object?["id"]?.string, key.utf8.elementsEqual("\(kind.rawValue):\(id)".utf8) else { throw WorkspaceError.invalidAddress }
        }
    }

    public init(from decoder: Decoder) throws { try self.init(json: JSONValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    public static func make(key: String, kind: WorkspaceKind, payload: JSONValue) throws -> WorkspaceRecord {
        let content = try payload.canonical()
        return try WorkspaceRecord(json: .object([
            "schemaVersion": .number(1), "key": .string(key), "kind": .string(kind.rawValue),
            "content": .string(content), "hash": .string(WorkspaceHash.sha256(content))
        ]))
    }

    @discardableResult public func validated(documentID: String) throws -> WorkspaceRecord {
        guard documentID == self.documentID else { throw WorkspaceError.invalidAddress }
        return self
    }

    public func journal() throws -> JournalDocument {
        guard kind == .journal else { throw WorkspaceError.malformedRecord }
        return try JournalDocument(payload: JSONValue.parse(content))
    }

    public func payload() throws -> JSONValue { try JSONValue.parse(content) }
}

/// Required PC fields are type-checked; additional fields are retained and never discarded.
enum PortableRow {
    static func strings(_ row: [String: JSONValue], _ keys: [String]) throws {
        guard keys.allSatisfy({ row[$0]?.string != nil }) else { throw WorkspaceError.malformedRecord }
    }
    static func nullableStrings(_ row: [String: JSONValue], _ keys: [String]) throws {
        guard keys.allSatisfy({ row[$0] == .null || row[$0]?.string != nil }) else { throw WorkspaceError.malformedRecord }
    }
    static func oneOf(_ row: [String: JSONValue], _ key: String, _ values: [String]) throws {
        guard let value = row[key]?.string, values.contains(value) else { throw WorkspaceError.malformedRecord }
    }
    static func identifier(_ row: [String: JSONValue], _ key: String = "id") throws {
        guard let value = row[key]?.string, !value.isEmpty, value.utf16.count <= 500 else { throw WorkspaceError.malformedRecord }
    }
    static func validate(_ payload: JSONValue, kind: WorkspaceKind) throws {
        guard let row = payload.object else { throw WorkspaceError.malformedRecord }
        try identifier(row)
        switch kind {
        case .inference:
            try strings(row, ["scope", "statement", "first_seen_at", "last_seen_at", "counter_evidence_json"])
            try nullableStrings(row, ["project_id"])
            try oneOf(row, "scope", ["project", "global"])
            guard let count = row["support_count"]?.integer, count >= 0,
                  row["active"] == .number(0) || row["active"] == .number(1) else { throw WorkspaceError.malformedRecord }
        case .vision:
            try strings(row, ["local_date", "project_name", "source_thread_ids_json", "observed_work_json", "decision_changes_json", "project_essence_now", "vision", "next_meaningful_move", "negative_drift", "evidence_refs_json"])
            try nullableStrings(row, ["project_id"])
            try oneOf(row, "confidence", ["low", "medium", "high"])
            guard WorkspaceIdentity.validDate(row["local_date"]!.string!) else { throw WorkspaceError.malformedRecord }
        case .feedback:
            try identifier(row, "project_vision_id")
            try strings(row, ["wrong_text", "correction_text", "created_at"])
            try nullableStrings(row, ["project_id", "synced_at", "error"])
            try oneOf(row, "verdict", ["iyi", "kotu", "gelistir"])
            try oneOf(row, "scope", ["project", "global"])
            try oneOf(row, "status", ["sync_pending", "synced", "failed"])
        default: throw WorkspaceError.malformedRecord
        }
    }
}
