import Foundation

public enum QuestionKind: String, Codable, Sendable {
    case open
    case boolean
}

public struct QuestionSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: QuestionKind
    public let position: Int
    public let prompt: String
    public let answerText: String?
    public let answerBoolean: Bool?

    public init(
        id: String,
        kind: QuestionKind,
        position: Int,
        prompt: String,
        answerText: String? = nil,
        answerBoolean: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.prompt = prompt
        self.answerText = answerText
        self.answerBoolean = answerBoolean
    }
}

public struct QuestionProgress: Equatable, Sendable {
    public let openQuestions: [QuestionSnapshot]
    public let booleanQuestions: [QuestionSnapshot]
    public let answeredCount: Int
    public let totalCount: Int

    public init(questions: [QuestionSnapshot]) {
        openQuestions = questions.filter { $0.kind == .open }.sorted { $0.position < $1.position }
        booleanQuestions = questions.filter { $0.kind == .boolean }.sorted { $0.position < $1.position }
        answeredCount = questions.reduce(into: 0) { count, question in
            switch question.kind {
            case .open:
                if let answer = question.answerText, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    count += 1
                }
            case .boolean:
                if question.answerBoolean != nil {
                    count += 1
                }
            }
        }
        totalCount = questions.count
    }
}
