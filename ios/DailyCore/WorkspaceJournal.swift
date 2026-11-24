import Foundation

public struct JournalQuestion: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public var id: String { fields["id"]!.string! }
    public var kind: QuestionKind { QuestionKind(rawValue: fields["kind"]!.string!)! }
    public var position: Int { fields["position"]!.integer! }
    public var prompt: String { fields["prompt"]!.string! }
    public var rationale: String { fields["rationale"]!.string! }
    public var sourceRef: String { fields["source_ref"]!.string! }
    public var answerText: String? { fields["answer_text"]?.string }
    public var answerBoolean: Int? { fields["answer_boolean"]?.integer }
    public var isFunctional: Bool {
        kind == .boolean && (fields["reminder_proposal"]?.object != nil || fields["emotion_proposal"]?.object != nil)
    }
    public var hasPendingFunctionalAnswer: Bool { isFunctional && isAnswered && fields["functional_applied_answer"] != fields["answer_boolean"] }
    public var isSessionClosed: Bool { fields["session_closed_at"]?.string != nil }
    public var isAnswered: Bool { kind == .boolean ? answerBoolean != nil : !(answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct JournalAnalysis: Identifiable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    public var id: String { fields["id"]!.string! }
    public var version: Int { fields["version"]!.integer! }
    public var reflection: String { fields["reflection"]!.string! }
    public var provider: String { fields["provider"]!.string! }
    public var confidence: String { fields["confidence"]!.string! }
    public var createdAt: String { fields["created_at"]!.string! }
}

public struct JournalDocument: Codable, Equatable, Sendable {
    public let payload: JSONValue
    public let entry: [String: JSONValue]
    public let questions: [JournalQuestion]
    public let analyses: [JournalAnalysis]
    public var id: String { entry["id"]!.string! }
    public var date: String { entry["local_date"]!.string! }
    public var rawText: String { entry["raw_text"]!.string! }
    public var analysisStatus: String { entry["analysis_status"]!.string! }
    public var savedAt: String { entry["saved_at"]!.string! }
    public var analysisError: String? { entry["analysis_error"]?.string }
    public var awaitsDayReflectionQuestions: Bool {
        guard analysisStatus == "complete", payload.object?["daily_task"] == nil,
              payload.object?["map_link_session"]?.object?["phase"] != .string("answering") else { return false }
        return questions.contains { !$0.isFunctional && (!$0.isSessionClosed || $0.isAnswered) }
    }

    public var isFinishingDayReflection: Bool {
        awaitsDayReflectionQuestions && questions.contains { !$0.isFunctional && $0.isSessionClosed && $0.isAnswered }
    }

    fileprivate var reflectionAnalysis: JournalAnalysis? {
        guard analysisStatus == "complete", !awaitsDayReflectionQuestions else { return nil }
        let links = payload.object?["map_link_session"]?.object
        let currentTask = payload.object?["daily_task"]?.object
        let latestVersion = analyses.map(\.version).max()
        return analyses.filter { analysis in
            let fields = analysis.fields
            if fields["task_action"]?.string != nil || fields["task_report_key"]?.string != nil ||
                fields["result"]?.object?["kind"] == .string("daily_task") { return false }
            if analysis.version == latestVersion, let reply = currentTask?["reply"]?.string,
               !analysis.reflection.isEmpty, reply.hasPrefix(analysis.reflection) { return false }
            return links?["reflection"]?.string != analysis.reflection || links?["completedAt"]?.string != analysis.createdAt
        }.max { $0.version < $1.version }
    }

    public var dayReflection: String? {
        let reflection = reflectionAnalysis?.reflection.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reflection.isEmpty ? nil : reflection
    }

    public var previousDayReflection: String? {
        guard let previousID = payload.object?["previous_day_reflection_id"]?.string,
              let previous = analyses.first(where: { $0.id == previousID }) else { return nil }
        let text = previous.reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The saved hash lets subsequent draft saves verify the original prefix without retaining another copy.
    public var previousTextByteCount: Int? {
        guard previousDayReflection != nil,
              let count = payload.object?["previous_reflection_text_bytes"]?.integer,
              count >= 0, count <= rawText.utf8.count,
              let hash = payload.object?["previous_reflection_text_hash"]?.string,
              let prefix = String(bytes: rawText.utf8.prefix(count), encoding: .utf8),
              WorkspaceHash.sha256(prefix) == hash else { return nil }
        return count
    }

    public var dayAdvice: [String] {
        guard let analysis = reflectionAnalysis,
              let memory = analysis.fields["result"]?.object?["living_memory"]?.object else { return [] }
        let reflection = analysis.reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reflection.isEmpty else { return [] }
        var seen: Set<String> = [reflection]
        return ["encouragement", "next_step"].compactMap { field in
            guard let text = memory[field]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    public var latestReply: String? {
        let latest = analyses.max { $0.version < $1.version }
        if let result = latest?.fields["result"], result.object != nil,
           let text = try? result.canonical() { return text }
        if let task = payload.object?["daily_task"], task.object != nil,
           let text = try? task.canonical() { return text }
        let reflection = latest?.reflection.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reflection.isEmpty ? nil : reflection
    }

    /// New analysis rounds move answered questions into history, not out of the user's inbox.
    public var archivedAnsweredQuestions: [JournalQuestion] {
        var seen = Set(questions.map(\.id))
        return (payload.object?["question_history"]?.array ?? []).reversed().compactMap { value in
            guard let id = value.object?["id"]?.string, !seen.contains(id) else { return nil }
            var root = payload.object!
            root["questions"] = .array([value])
            root.removeValue(forKey: "question_history")
            guard let question = try? JournalDocument(payload: .object(root)).questions.first,
                  (question.isAnswered || question.isSessionClosed) else { return nil }
            seen.insert(id)
            return question
        }
    }
    public var pendingQuestions: [JournalQuestion] { questions.filter { !$0.isAnswered && !$0.isSessionClosed } }
    public var answeredQuestions: [JournalQuestion] { questions.filter { $0.isAnswered || $0.isSessionClosed } + archivedAnsweredQuestions }

    public init(payload: JSONValue) throws {
        guard let root = payload.object, let entry = root["entry"]?.object,
              let rawQuestions = root["questions"]?.array, let rawAnalyses = root["analyses"]?.array else { throw WorkspaceError.malformedRecord }
        try PortableRow.identifier(entry)
        try PortableRow.strings(entry, ["local_date", "raw_text", "content_hash", "saved_at"])
        try PortableRow.nullableStrings(entry, ["analysis_error"])
        try PortableRow.oneOf(entry, "analysis_status", ["pending", "complete", "failed"])
        guard WorkspaceIdentity.validDate(entry["local_date"]!.string!) else { throw WorkspaceError.malformedRecord }
        guard entry["content_hash"]?.string == WorkspaceHash.sha256(entry["raw_text"]!.string!) else { throw WorkspaceError.invalidHash }
        let id = entry["id"]!.string!
        var questionIDs = Set<String>()
        var questions: [JournalQuestion] = []
        for value in rawQuestions {
            guard let fields = value.object else { throw WorkspaceError.malformedRecord }
            try PortableRow.identifier(fields)
            try PortableRow.identifier(fields, "journal_id")
            try PortableRow.strings(fields, ["prompt", "rationale", "source_ref"])
            try PortableRow.nullableStrings(fields, ["answer_text"])
            try PortableRow.oneOf(fields, "kind", ["open", "boolean"])
            guard fields["journal_id"]?.string == id,
                  let position = fields["position"]?.integer, position >= 0,
                  fields["answer_boolean"] == .null || fields["answer_boolean"] == .number(0) || fields["answer_boolean"] == .number(1),
                  questionIDs.insert(fields["id"]!.string!).inserted else { throw WorkspaceError.malformedRecord }
            questions.append(JournalQuestion(fields: fields))
        }
        var analysisIDs = Set<String>()
        var analyses: [JournalAnalysis] = []
        for value in rawAnalyses {
            guard let fields = value.object else { throw WorkspaceError.malformedRecord }
            try PortableRow.identifier(fields)
            try PortableRow.identifier(fields, "journal_id")
            try PortableRow.strings(fields, ["provider", "reflection", "created_at"])
            try PortableRow.oneOf(fields, "confidence", ["low", "medium", "high"])
            guard fields["journal_id"]?.string == id, let version = fields["version"]?.integer, version > 0,
                  analysisIDs.insert(fields["id"]!.string!).inserted else { throw WorkspaceError.malformedRecord }
            analyses.append(JournalAnalysis(fields: fields))
        }
        self.payload = payload; self.entry = entry; self.questions = questions; self.analyses = analyses
    }

    public init(from decoder: Decoder) throws { try self.init(payload: JSONValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try payload.encode(to: encoder) }
}

public enum DraftAnswer: Codable, Equatable, Sendable {
    case text(String?)
    case boolean(Int?)
}

public struct WorkspaceWritePlan: Sendable {
    public let record: WorkspaceRecord
    public let previous: WorkspaceRecord?
}

public enum WorkspaceSavePlanner {
    /// Pure CAS plan. An explicit conflict override calls this with a freshly compared
    /// server record/hash, and overlays only the user's selected edits on that record.
    public static func plan(current: WorkspaceRecord?, expectedHash: String?, date: String, text: String?, answers: [String: DraftAnswer], now: String, newID: String, closeQuestionSession: Bool = false, closedQuestionIDs: [String] = [], restoring: WorkspaceRecord? = nil) throws -> WorkspaceWritePlan {
        guard current?.hash == expectedHash else { throw WorkspaceError.conflict }
        guard WorkspaceIdentity.validDate(date), current == nil || current?.key == "journal:\(date)" else { throw WorkspaceError.invalidAddress }
        let currentJournal = try current?.journal()
        var root: [String: JSONValue]
        // Recovery is an explicit create-if-still-absent operation, never an overwrite.
        if let restoring {
            guard current == nil, expectedHash == nil else { throw WorkspaceError.conflict }
            guard restoring.key == "journal:\(date)", restoring.kind == .journal else { throw WorkspaceError.invalidAddress }
            root = try restoring.journal().payload.object!
        }
        else if let currentJournal { root = currentJournal.payload.object! }
        else {
            guard text != nil, !newID.isEmpty else { throw WorkspaceError.malformedRecord }
            root = ["entry": .object([
                "id": .string(newID), "local_date": .string(date), "raw_text": .string(""),
                "content_hash": .string(WorkspaceHash.sha256("")), "saved_at": .string(now),
                "analysis_status": .string("pending"), "analysis_error": .null
            ]), "analyses": .array([]), "questions": .array([])]
        }
        var entry = root["entry"]!.object!
        if let text, text != entry["raw_text"]?.string || current == nil {
            if let journal = currentJournal, journal.dayReflection != nil,
               let previous = journal.reflectionAnalysis {
                var history = root["previous_day_reflection_ids"]?.array ?? []
                for id in [root["previous_day_reflection_id"]?.string, previous.id].compactMap({ $0 }) {
                    if !history.contains(.string(id)) { history.append(.string(id)) }
                }
                root["previous_day_reflection_ids"] = .array(history)
                root["previous_day_reflection_id"] = .string(previous.id)
                root["previous_reflection_text_bytes"] = .number(Double(journal.rawText.utf8.count))
                root["previous_reflection_text_hash"] = journal.entry["content_hash"]
            }
            entry["raw_text"] = .string(text)
            entry["content_hash"] = .string(WorkspaceHash.sha256(text))
            entry["saved_at"] = .string(now)
            entry["analysis_status"] = .string("pending")
            entry["analysis_error"] = .null
        }
        root["entry"] = .object(entry)
        var questions = root["questions"]!.array!
        for (id, answer) in answers {
            guard let index = questions.firstIndex(where: { $0.object?["id"]?.string == id }), var fields = questions[index].object else { throw WorkspaceError.missingQuestion }
            switch answer {
            case .text(let value):
                guard fields["kind"] == .string("open") else { throw WorkspaceError.malformedRecord }
                fields["answer_text"] = value.map(JSONValue.string) ?? .null
            case .boolean(let value):
                guard fields["kind"] == .string("boolean"), value == nil || value == 0 || value == 1 else { throw WorkspaceError.malformedRecord }
                fields["answer_boolean"] = value.map { .number(Double($0)) } ?? .null
            }
            questions[index] = .object(fields)
        }
        if closeQuestionSession || !closedQuestionIDs.isEmpty {
            let closing = Set(closedQuestionIDs)
            func close(_ value: JSONValue, all: Bool) -> JSONValue {
                guard var fields = value.object, all || closing.contains(fields["id"]?.string ?? "") else { return value }
                guard fields["session_closed_at"]?.string == nil else { return value }
                fields["session_closed_at"] = .string(now)
                return .object(fields)
            }
            questions = questions.map { close($0, all: closeQuestionSession) }
            if let history = root["question_history"]?.array {
                root["question_history"] = .array(history.map { close($0, all: false) })
            }
        }
        root["questions"] = .array(questions)
        let next = try WorkspaceRecord.make(key: "journal:\(date)", kind: .journal, payload: .object(root))
        // Only an existing server record can be archived under Firestore's version rules.
        // The recovery source remains in the protected local draft until acknowledgement.
        return WorkspaceWritePlan(record: next, previous: current?.hash == next.hash ? nil : current)
    }
}
