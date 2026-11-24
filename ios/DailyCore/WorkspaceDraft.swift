import Foundation

public struct InlineJournalDraft: Codable, Equatable, Sendable {
    public var text: String
    public let editingTextHash: String?

    public init(text: String, editingTextHash: String? = nil) {
        self.text = text
        self.editingTextHash = editingTextHash
    }
}

public struct WorkspaceDraft: Codable, Equatable, Sendable {
    public let uid: String
    public let date: String
    public private(set) var base: WorkspaceRecord?
    public var text: String?
    public var inlineNote: InlineJournalDraft?
    public var answers: [String: DraftAnswer]
    public var closedQuestionIDs: [String] = []
    public var analyzeAfterClose = false
    public var needsPersistence: Bool { hasChanges || analyzeAfterClose || inlineNote != nil }
    public private(set) var requiresComparison: Bool
    public var hasChanges: Bool { text != nil || !answers.isEmpty || !closedQuestionIDs.isEmpty }

    public init(uid: String, date: String, base: WorkspaceRecord?) {
        self.uid = uid; self.date = date; self.base = base; self.text = nil; self.answers = [:]; self.requiresComparison = false
    }

    public mutating func closeQuestions(_ ids: [String], in journal: JournalDocument?) {
        let confirmed = Set(journal?.answeredQuestions.filter(\.isSessionClosed).map(\.id) ?? [])
        let changed = ids.filter { id in
            guard let pending = answers[id], let q = journal?.questions.first(where: { $0.id == id }) else { return false }
            let saved: DraftAnswer = q.kind == .boolean ? .boolean(q.answerBoolean) : .text(q.answerText)
            return pending != saved
        }
        let closing = Set(ids).subtracting(confirmed).union(changed)
        let answered = closing.contains { id in
            guard let question = journal?.questions.first(where: { $0.id == id }), !question.isFunctional else { return false }
            if let answer = answers[id] {
                switch answer {
                case .boolean(let value): return value != nil
                case .text(let value): return !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
            return journal?.questions.first(where: { $0.id == id })?.isAnswered ?? false
        }
        let editedText = text.map { $0 != journal?.rawText } ?? false
        analyzeAfterClose = analyzeAfterClose || answered || editedText
        closedQuestionIDs = Array(Set(closedQuestionIDs).union(closing)).sorted()
    }

    public mutating func applyInlineNote(to existing: String) throws {
        guard let inlineNote else { return }
        if let expected = inlineNote.editingTextHash {
            guard WorkspaceHash.sha256(existing) == expected else { throw WorkspaceError.conflict }
            text = inlineNote.text
        } else {
            let addition = inlineNote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addition.isEmpty else { throw WorkspaceError.invalidDraft }
            let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
            text = existing + separator + addition
        }
        self.inlineNote = nil
    }

    private enum CodingKeys: String, CodingKey { case uid, date, base, text, inlineNote, answers, requiresComparison, closedQuestionIDs, analyzeAfterClose }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uid = try values.decode(String.self, forKey: .uid)
        date = try values.decode(String.self, forKey: .date)
        base = try values.decodeIfPresent(WorkspaceRecord.self, forKey: .base)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        inlineNote = try values.decodeIfPresent(InlineJournalDraft.self, forKey: .inlineNote)
        answers = try values.decode([String: DraftAnswer].self, forKey: .answers)
        analyzeAfterClose = try values.decodeIfPresent(Bool.self, forKey: .analyzeAfterClose) ?? false
        closedQuestionIDs = try values.decodeIfPresent([String].self, forKey: .closedQuestionIDs) ?? []
        requiresComparison = try values.decodeIfPresent(Bool.self, forKey: .requiresComparison) ?? false
    }

    /// A partial explicit conflict resolution authorizes only the selected edits.
    /// Remaining edits must get their own fresh comparison, even if base advanced.
    public func checkSubmission(explicitlyCompared: Bool = false) throws {
        if requiresComparison && !explicitlyCompared { throw WorkspaceError.conflict }
    }

    /// Stop background retries until the user resolves this comparison explicitly.
    public mutating func markConflict() { requiresComparison = true }

    public mutating func receive(_ remote: WorkspaceRecord?) {
        // Realtime may refresh clean editors only. Pending answers count as dirty too.
        if !hasChanges { base = remote; requiresComparison = false }
    }

    /// Our own deterministic bookkeeping commit does not submit or discard pending user edits.
    public mutating func acknowledgeFunctional(_ saved: WorkspaceRecord, previousHash: String) {
        guard let prior = base, prior.hash == previousHash, prior.key == saved.key,
              let before = try? prior.journal(), let after = try? saved.journal(),
              before.rawText.utf8.elementsEqual(after.rawText.utf8), before.id == after.id else { return }
        base = saved
    }

    public mutating func acknowledge(_ saved: WorkspaceRecord, submittedText: String?, submittedAnswers: [String: DraftAnswer], expectedHash: String?) {
        if let submittedText, text == submittedText { text = nil }
        for (id, answer) in submittedAnswers where answers[id] == answer { answers.removeValue(forKey: id) }
        if let journal = try? saved.journal() {
            let confirmed = Set(journal.answeredQuestions.filter(\.isSessionClosed).map(\.id))
            closedQuestionIDs.removeAll { confirmed.contains($0) }
        }
        requiresComparison = hasChanges && (requiresComparison || expectedHash != base?.hash)
        base = saved
    }
}

/// Account-scoped atomic protected files. Passwords and Firebase tokens never enter this store.
public final class WorkspaceDraftStore: Sendable {
    private static let writes = DispatchQueue(label: "daily.workspace.drafts", qos: .utility)
    private let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    public func load(uid: String, date: String) throws -> WorkspaceDraft? {
        let file = try path(uid: uid, date: date)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let draft = try JSONDecoder().decode(WorkspaceDraft.self, from: Data(contentsOf: file))
        guard draft.uid == uid, draft.date == date,
              draft.base == nil || draft.base?.key == "journal:\(date)" else { throw WorkspaceError.invalidDraft }
        return draft
    }

    public func save(_ draft: WorkspaceDraft) throws {
        try Self.writes.sync { try write(draft) }
    }

    // Enqueue before returning so a later synchronous checkpoint always wins.
    public func saveInBackground(_ draft: WorkspaceDraft, completion: @escaping @Sendable (Bool) -> Void) {
        Self.writes.async {
            do {
                try self.write(draft)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    private func write(_ draft: WorkspaceDraft) throws {
        let file = try path(uid: draft.uid, date: draft.date)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: file, options: [.atomic, .completeFileProtection])
    }

    public func remove(uid: String, date: String) throws {
        let file = try path(uid: uid, date: date)
        try Self.writes.sync {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    public func dates(uid: String) throws -> [String] {
        try WorkspaceIdentity.validateUID(uid)
        let directory = root.appendingPathComponent(WorkspaceHash.sha256(uid), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
            .filter(WorkspaceIdentity.validDate).sorted(by: >)
    }

    private func path(uid: String, date: String) throws -> URL {
        try WorkspaceIdentity.validateUID(uid)
        guard WorkspaceIdentity.validDate(date) else { throw WorkspaceError.invalidDraft }
        return root.appendingPathComponent(WorkspaceHash.sha256(uid), isDirectory: true).appendingPathComponent(date + ".json")
    }
}
