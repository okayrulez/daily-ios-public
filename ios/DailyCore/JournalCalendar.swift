import Foundation

public enum JournalDayState: Equatable, Sendable {
    case empty, missed, draft, written, answered

    public static func resolve(date: String, today: String, firstDate: String?, journal: JournalDocument?, draftText: String? = nil) -> Self {
        // Drafts are durable device records too, even before the first AI request
        // creates a committed journal. Do not make yesterday disappear at midnight.
        if let draftText, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .draft }
        if let journal, !journal.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return !journal.questions.isEmpty && journal.pendingQuestions.isEmpty ? .answered : .written
        }
        return firstDate.map { date >= $0 && date < today } == true ? .missed : .empty
    }
}

/// Display cloud questions without moving the draft's conflict-comparison base.
public enum JournalPresentation {
    public static func current(remote: WorkspaceRecord?, draft: WorkspaceDraft?) -> JournalDocument? {
        guard let record = remote ?? draft?.base else { return nil }
        guard let draft, !draft.closedQuestionIDs.isEmpty else { return try? record.journal() }
        // Present locally completed sessions immediately, without advancing the CAS base.
        guard let journal = try? record.journal() else { return nil }
        let ids = Set(journal.questions.map(\.id))
        let answers = draft.answers.filter { ids.contains($0.key) }
        return (try? WorkspaceSavePlanner.plan(current: record, expectedHash: record.hash, date: draft.date,
            text: nil, answers: answers, now: "pending-sync", newID: "unused", closedQuestionIDs: draft.closedQuestionIDs).record.journal()) ?? journal
    }
}

public enum JournalCalendar {
    public static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    public static func key(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func day(forKey key: String) -> Date? {
        guard WorkspaceIdentity.validDate(key) else { return nil }
        return calendar().date(from: DateComponents(
            year: Int(key.prefix(4)), month: Int(key.dropFirst(5).prefix(2)), day: Int(key.suffix(2))))
    }

    public static func cells(in month: Date) -> [Date?] {
        let calendar = calendar()
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: offset)
        result += days.map { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }
}
