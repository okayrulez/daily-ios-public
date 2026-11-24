import Foundation
@testable import DailyCore

extension DaySnapshot {
    static func fixture(localDate: String, revision: Int) -> DaySnapshot {
        DaySnapshot(
            localDate: localDate,
            rawText: "Önceki metin",
            revision: revision,
            answerRevision: 0,
            status: .complete,
            processingReason: nil,
            deviceID: "fixture-device",
            updatedAt: Date(timeIntervalSince1970: 50)
        )
    }
}

extension QuestionSnapshot {
    static func fixture(
        id: String,
        kind: QuestionKind,
        position: Int,
        answerText: String? = nil,
        answerBoolean: Bool? = nil
    ) -> QuestionSnapshot {
        QuestionSnapshot(
            id: id,
            kind: kind,
            position: position,
            prompt: "Soru \(position)",
            answerText: answerText,
            answerBoolean: answerBoolean
        )
    }

    static func fixtures(openCount: Int, booleanCount: Int) -> [QuestionSnapshot] {
        let openQuestions = (1...openCount).map {
            fixture(id: "open-\($0)", kind: .open, position: $0)
        }
        let booleanQuestions = (1...booleanCount).map {
            fixture(id: "boolean-\($0)", kind: .boolean, position: $0)
        }
        return openQuestions + booleanQuestions
    }
}
