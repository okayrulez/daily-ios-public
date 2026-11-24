import Foundation

/// A navigation or repeated tap is not new AI input.
public enum PhoneAnalysisReadiness {
    public static func canStartQuestions(journal: JournalDocument?, pendingAnswers: [String: DraftAnswer]) -> Bool {
        guard let journal else { return false }
        for question in journal.questions where !question.isFunctional {
            if let answer = pendingAnswers[question.id] {
                switch answer {
                case .text(let value):
                    let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && text != (question.answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { return true }
                case .boolean(let value): if let value, value != question.answerBoolean { return true }
                }
            } else if question.isAnswered {
                let task = journal.payload.object?["daily_task"]?.object
                if let status = task?["status"]?.string, status == "completed" || status == "blocked" {
                    // Task output can leave a fresh question. Compare with the answers
                    // actually consumed by that task, rather than restarting old input.
                    guard let consumed = task?["contextAnswers"]?.array else { continue }
                    let answer = question.kind == .boolean ? (question.answerBoolean == 1 ? "Evet" : "Hayır") : (question.answerText ?? "")
                    if consumed.contains(where: { $0.object?["question"]?.string == question.prompt && $0.object?["answer"]?.string == answer }) { continue }
                }
                return true
            }
        }
        return false
    }
    public static func canStart(journal: JournalDocument?, text: String, pendingAnswers: [String: DraftAnswer]) -> Bool {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of:"\r\n",with:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
        }
        guard !clean(text).isEmpty else { return false }
        guard let journal else { return true }
        if clean(text) != clean(journal.rawText) { return true }
        for question in journal.questions where !question.isFunctional {
            guard let answer = pendingAnswers[question.id] else { continue }
            switch (question.kind, answer) {
            case (.open, .text(let value)):
                if clean(value ?? "") != clean(question.answerText ?? "") { return true }
            case (.boolean, .boolean(let value)):
                if value != question.answerBoolean { return true }
            default: continue
            }
        }
        if journal.analysisStatus != "complete" || journal.analyses.isEmpty { return true }
        if let phase=journal.payload.object?["map_link_session"]?.object?["phase"]?.string, phase != "answering" { return false }
        if let status=journal.payload.object?["daily_task"]?.object?["status"]?.string {
            if status == "in_progress" { return true }
            if status == "completed" || status == "blocked" { return canStartQuestions(journal: journal, pendingAnswers: [:]) }
        }
        // Main analyses replace processed answers with a fresh question set.
        return journal.questions.contains { $0.isAnswered && !$0.isFunctional }
    }
}
