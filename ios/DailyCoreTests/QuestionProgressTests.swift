import XCTest
@testable import DailyCore

final class QuestionProgressTests: XCTestCase {
    func testSeparatesThreeOpenAndTenBooleanQuestionsInDisplayOrder() {
        let questions = QuestionSnapshot.fixtures(openCount: 3, booleanCount: 10).shuffled()
        let progress = QuestionProgress(questions: questions)

        XCTAssertEqual(progress.openQuestions.map(\.position), [1, 2, 3])
        XCTAssertEqual(progress.booleanQuestions.map(\.position), Array(1...10))
        XCTAssertEqual(progress.answeredCount, 0)
        XCTAssertEqual(progress.totalCount, 13)
    }

    func testCountsTextAndBooleanAnswersWithoutTreatingEmptyTextAsAnswered() {
        let questions = [
            QuestionSnapshot.fixture(id: "open-1", kind: .open, position: 1, answerText: "  düşündüm  "),
            QuestionSnapshot.fixture(id: "open-2", kind: .open, position: 2, answerText: "   "),
            QuestionSnapshot.fixture(id: "bool-1", kind: .boolean, position: 1, answerBoolean: false)
        ]

        XCTAssertEqual(QuestionProgress(questions: questions).answeredCount, 2)
    }
}

extension QuestionProgressTests {
    func testPortableNoAnswerCountsAsAnsweredButBlankTextDoesNot() {
        let no = JournalQuestion(fields: ["kind": .string("boolean"), "answer_boolean": .number(0), "answer_text": .null])
        let blank = JournalQuestion(fields: ["kind": .string("open"), "answer_boolean": .null, "answer_text": .string("  ")])
        XCTAssertTrue(no.isAnswered)
        XCTAssertFalse(blank.isAnswered)
    }
}
