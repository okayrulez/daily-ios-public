import XCTest
@testable import DailyCore

final class JournalCalendarTests: XCTestCase {
    func testImmediateCheckpointWinsOverQueuedLongDraftWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkspaceDraftStore(root: directory)
        var draft = WorkspaceDraft(uid: "owner", date: "2026-11-17", base: nil)
        draft.text = String(repeating: "Uzun günlük. ", count: 20_000)
        store.saveInBackground(draft) { _ in }
        draft.text = (draft.text ?? "") + "En son yazdığım cümle."
        try store.save(draft)
        XCTAssertEqual(try store.load(uid: draft.uid, date: draft.date)?.text, draft.text)
    }

    func testPreviousDaysDeviceOnlyDraftRemainsVisibleAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = WorkspaceDraft(uid: "owner", date: "2026-11-17", base: nil)
        draft.text = "Dün yazdığım, henüz analiz edilmemiş günlük."
        try WorkspaceDraftStore(root: directory).save(draft)
        let reopened = try WorkspaceDraftStore(root: directory)
        XCTAssertEqual(try reopened.dates(uid: "owner"), ["2026-11-17"])
        let restored = try XCTUnwrap(reopened.load(uid: "owner", date: "2026-11-17"))
        XCTAssertNil(JournalPresentation.current(remote: nil, draft: restored), "A draft must not invent a committed journal or AI result")
        XCTAssertEqual(JournalDayState.resolve(date: restored.date, today: "2026-11-18", firstDate: restored.date,
            journal: nil, draftText: restored.text), .draft)
        XCTAssertEqual(restored.text, draft.text)
    }

    func testDailyReflectionWaitsUntilQuestionsAreSkippedOrReplacedWithTheFinalResult() throws {
        var payload = try XCTUnwrap(WorkspaceFixture.payload().object)
        let original = try JournalDocument(payload: .object(payload))
        XCTAssertTrue(original.awaitsDayReflectionQuestions)
        XCTAssertNil(original.dayReflection)

        var skipped = try XCTUnwrap(payload["questions"]?.array?.first?.object)
        skipped["session_closed_at"] = .string("2026-08-30T11:30:00Z")
        payload["questions"] = .array([.object(skipped)])
        XCTAssertEqual(try JournalDocument(payload: .object(payload)).dayReflection, "Sentetik değerlendirme")

        skipped["answer_boolean"] = .number(1)
        payload["questions"] = .array([.object(skipped)])
        XCTAssertNil(try JournalDocument(payload: .object(payload)).dayReflection)

        payload["question_history"] = payload["questions"]
        payload["questions"] = .array([])
        var finalAnalysis = try XCTUnwrap(payload["analyses"]?.array?.first?.object)
        finalAnalysis["id"] = .string("a-final")
        finalAnalysis["version"] = .number(2)
        finalAnalysis["reflection"] = .string("Yanıtını da dinleyince günün daha iyi anlaşılıyor.")
        finalAnalysis["result"] = .object(["living_memory": .object([
            "encouragement": .string("Kendine biraz alan açmışsın."),
            "next_step": .string("Yarın kısa bir yürüyüş deneyebilirsin."),
        ])])
        payload["analyses"] = .array((payload["analyses"]?.array ?? []) + [.object(finalAnalysis)])
        XCTAssertEqual(try JournalDocument(payload: .object(payload)).dayReflection,
                       "Yanıtını da dinleyince günün daha iyi anlaşılıyor.")
        XCTAssertEqual(try JournalDocument(payload: .object(payload)).dayAdvice,
                       ["Kendine biraz alan açmışsın.", "Yarın kısa bir yürüyüş deneyebilirsin."])
        let taskReply = "Ajandaya eklendi: İş"
        payload["daily_task"] = .object(["reply": .string(taskReply)])
        var taskAnalysis = finalAnalysis
        taskAnalysis["id"] = .string("a-task")
        taskAnalysis["version"] = .number(3)
        taskAnalysis["reflection"] = .string(taskReply)
        taskAnalysis["result"] = nil
        taskAnalysis["task_action"] = .string("manage")
        payload["analyses"] = .array([.object(finalAnalysis), .object(taskAnalysis)])
        XCTAssertEqual(try JournalDocument(payload: .object(payload)).dayReflection,
                       "Yanıtını da dinleyince günün daha iyi anlaşılıyor.")
        payload["analyses"] = .array([.object(taskAnalysis)])
        let taskJournal = try JournalDocument(payload: .object(payload))
        XCTAssertNil(taskJournal.dayReflection)
        XCTAssertTrue(taskJournal.dayAdvice.isEmpty)
    }

    func testBlankDraftDoesNotMarkAMissingDayWrittenOrHideSavedAnalysis() throws {
        XCTAssertEqual(JournalDayState.resolve(date: "2026-11-17", today: "2026-11-18", firstDate: "2026-11-16",
            journal: nil, draftText: "  "), .missed)
        let saved = try JournalDocument(payload: WorkspaceFixture.payload())
        XCTAssertEqual(JournalDayState.resolve(date: saved.date, today: "2026-11-18", firstDate: saved.date,
            journal: saved, draftText: nil), .written)
        XCTAssertEqual(saved.analyses.count, 1)
    }

    func testCloudQuestionsStayVisibleWhileDraftRetainsItsOriginalBase() throws {
        let old = try WorkspaceFixture.record()
        var draft = WorkspaceDraft(uid: "owner", date: "2026-08-30", base: old)
        draft.text = "Kaydedilmemiş düşüncem"
        var root = try old.payload().object!
        var questions = root["questions"]!.array!
        var newQuestion = questions[0].object!
        newQuestion["id"] = .string("new-question")
        newQuestion["prompt"] = .string("Yeni gelen soru?")
        questions.append(.object(newQuestion)); root["questions"] = .array(questions)
        let fresh = try WorkspaceRecord.make(key: old.key, kind: .journal, payload: .object(root))
        XCTAssertEqual(JournalPresentation.current(remote: fresh, draft: draft)?.questions.count, 3)
        XCTAssertEqual(draft.base?.hash, old.hash)
        XCTAssertEqual(draft.text, "Kaydedilmemiş düşüncem")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(JournalPresentation.current(remote: nil, draft: draft)?.questions.count, 2)
    }

    func testAnsweredHistorySurvivesNewQuestionsAndIncludesNoAnswers() throws {
        var root = try WorkspaceFixture.settingQuestion("answer_boolean", to: .number(0)).object!
        let previous = root["questions"]!.array!
        root["question_history"] = .array(previous + previous)
        root["questions"] = .array([])
        let journal = try JournalDocument(payload: .object(root))
        XCTAssertEqual(journal.answeredQuestions.count, 2)
        XCTAssertTrue(journal.answeredQuestions.contains { $0.answerBoolean == 0 })
        root["questions"] = .array(previous)
        XCTAssertTrue(try JournalDocument(payload: .object(root)).archivedAnsweredQuestions.isEmpty)
    }

    func testNoAnswerIsACompletedAnswer() throws {
        let journal = try JournalDocument(payload: WorkspaceFixture.settingQuestion("answer_boolean", to: .number(0)))
        XCTAssertEqual(JournalDayState.resolve(date: journal.date, today: "2026-09-01", firstDate: journal.date, journal: journal), .answered)
    }

    func testPartiallyAnsweredDayStaysWritten() throws {
        let journal = try JournalDocument(payload: WorkspaceFixture.payload())
        XCTAssertTrue(journal.questions.contains(where: \.isAnswered))
        XCTAssertTrue(journal.questions.contains { !$0.isAnswered })
        XCTAssertEqual(JournalDayState.resolve(date: journal.date, today: "2026-09-01", firstDate: journal.date, journal: journal), .written)
    }

    func testWrittenDayWithoutQuestionsIsNotAnswered() throws {
        var root = try WorkspaceFixture.payload().object!
        root["questions"] = .array([])
        let journal = try JournalDocument(payload: .object(root))
        XCTAssertEqual(JournalDayState.resolve(date: journal.date, today: "2026-09-01", firstDate: journal.date, journal: journal), .written)
    }

    func testOnlyPastDaysWithinRecordedHistoryAreMissed() {
        XCTAssertEqual(JournalDayState.resolve(date: "2026-09-28", today: "2026-09-30", firstDate: "2026-09-27", journal: nil), .missed)
        for date in ["2026-09-26", "2026-09-30", "2026-10-01"] {
            XCTAssertEqual(JournalDayState.resolve(date: date, today: "2026-09-30", firstDate: "2026-09-27", journal: nil), .empty)
        }
        XCTAssertEqual(JournalDayState.resolve(date: "2026-09-28", today: "2026-09-30", firstDate: nil, journal: nil), .empty)
    }

    func testLeapFebruaryAndMondayAlignment() throws {
        let calendar = JournalCalendar.calendar()
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 15)))
        let cells = JournalCalendar.cells(in: date)
        XCTAssertEqual(cells.compactMap { $0 }.count, 29)
        XCTAssertEqual(cells.count % 7, 0)
        XCTAssertNil(cells[0]); XCTAssertNil(cells[1]); XCTAssertNil(cells[2])
        XCTAssertEqual(JournalCalendar.key(try XCTUnwrap(cells[3])), "2024-02-01")
    }
}
