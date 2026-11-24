import XCTest
@testable import DailyCore

final class PhoneAnalysisReadinessTests: XCTestCase {
    func testQuestionLogoNeedsANewCurrentAnswerRatherThanJustExistingJournalText() throws {
        let saved = try journal()
        XCTAssertFalse(PhoneAnalysisReadiness.canStartQuestions(journal: saved, pendingAnswers: [:]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStartQuestions(journal: saved, pendingAnswers: ["orphan": .text("Yanıt")]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStartQuestions(journal: saved, pendingAnswers: ["q-1": .boolean(nil)]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStartQuestions(journal: saved, pendingAnswers: ["q-1": .boolean(0)]))
    }
    func testCompletedTaskFollowUpIsEligibleOnlyUntilThatAnswerIsConsumed() throws {
        let saved = try journal(answered: true, task: "completed")
        var root = saved.payload.object!
        var task = root["daily_task"]!.object!
        task["contextAnswers"] = .array([]); root["daily_task"] = .object(task)
        let fresh = try JournalDocument(payload: .object(root))
        XCTAssertTrue(PhoneAnalysisReadiness.canStartQuestions(journal: fresh, pendingAnswers: [:]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal: fresh, text: fresh.rawText, pendingAnswers: [:]))
        let question = try XCTUnwrap(fresh.questions.first(where: { $0.isAnswered }))
        task["contextAnswers"] = .array([.object(["question": .string(question.prompt), "answer": .string("Evet")])])
        root["daily_task"] = .object(task)
        let consumed = try JournalDocument(payload: .object(root))
        XCTAssertFalse(PhoneAnalysisReadiness.canStartQuestions(journal: consumed, pendingAnswers: [:]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal: consumed, text: consumed.rawText, pendingAnswers: [:]))
    }
    private func journal(status:String="complete",answered:Bool=false,task:String?=nil) throws -> JournalDocument {
        var root=try WorkspaceFixture.payload().object!
        var entry=root["entry"]!.object!;entry["analysis_status"] = .string(status);root["entry"] = .object(entry)
        root["questions"] = .array(root["questions"]!.array!.map { value in
            var q=value.object!;q["answer_text"] = .null;q["answer_boolean"] = .null
            if answered && q["kind"] == .string("boolean") { q["answer_boolean"] = .number(1) }
            return .object(q)
        })
        if let task { root["daily_task"] = .object(["status":.string(task)]) }
        return try JournalDocument(payload:.object(root))
    }
    func testEmptyAndAlreadyAnalyzedWritingDoNotStartNewCalls() throws {
        let saved=try journal()
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:nil,text:" \n",pendingAnswers:[:]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:saved,text:saved.rawText,pendingAnswers:[:]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:saved,text:"  "+saved.rawText+"\n",pendingAnswers:[:]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:nil,text:"Yeni günlük",pendingAnswers:[:]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:saved,text:"Değişen günlük",pendingAnswers:[:]))
    }
    func testOnlyChangedAnswersEnableTheAction() throws {
        let saved=try journal()
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:saved,text:saved.rawText,pendingAnswers:["q-1":.boolean(nil),"q-2":.text(" ")]))
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:saved,text:saved.rawText,pendingAnswers:["orphan":.text("Not a current question")]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:saved,text:saved.rawText,pendingAnswers:["q-1":.boolean(0)]))
        let answered=try journal(answered:true)
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:answered,text:answered.rawText,pendingAnswers:[:]))
    }
    func testCompletedTasksDoNotRestartButNewInputAndFailedAttemptsRemainAvailable() throws {
        let complete=try journal(answered:true,task:"completed")
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal:complete,text:complete.rawText,pendingAnswers:[:]))
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:complete,text:complete.rawText+" Yeni istek.",pendingAnswers:[:]))
        let failed=try journal(status:"failed")
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:failed,text:failed.rawText,pendingAnswers:[:]))
        let running=try journal(task:"in_progress")
        XCTAssertTrue(PhoneAnalysisReadiness.canStart(journal:running,text:running.rawText,pendingAnswers:[:]))
    }
}
