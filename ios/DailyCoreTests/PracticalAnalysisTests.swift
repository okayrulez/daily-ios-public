import XCTest
@testable import DailyCore

final class PracticalAnalysisTests: XCTestCase {
    func testFunctionalOnlyCloseDoesNotQueueInference() throws {
        var root = try WorkspaceFixture.payload().object!
        var q = root["questions"]!.array![0].object!
        q["reminder_proposal"] = .object(["title": .string("Yürüyüş")])
        root["questions"] = .array([.object(q)])
        let record = try WorkspaceRecord.make(key: "journal:2026-08-30", kind: .journal, payload: .object(root))
        let journal = try record.journal()
        var draft = WorkspaceDraft(uid: "user-one", date: journal.date, base: record)
        draft.answers[journal.questions[0].id] = .boolean(1)
        draft.closeQuestions([journal.questions[0].id], in: journal)
        XCTAssertFalse(draft.analyzeAfterClose)
        XCTAssertFalse(PhoneAnalysisReadiness.canStart(journal: journal, text: journal.rawText, pendingAnswers: draft.answers))
        q.removeValue(forKey: "reminder_proposal")
        root["questions"] = .array([.object(q)])
        let reflective = try JournalDocument(payload: .object(root))
        draft.closeQuestions([reflective.questions[0].id], in: reflective)
        XCTAssertTrue(draft.analyzeAfterClose)
    }

    func testRefreshPolicyCountsDistinctNewJournalsAndWeekElapsed() {
        let start = Date(timeIntervalSince1970: 0)
        var policy = WorkspaceRefreshPolicy(now: start)
        for _ in 0..<10 { policy.completedNewJournal("same-day") }
        XCTAssertFalse(policy.isDue(now: start))
        for i in 1...4 { policy.completedNewJournal("day-\(i)") }
        XCTAssertTrue(policy.isDue(now: start))
        policy.didSync(now: start)
        XCTAssertFalse(policy.isDue(now: start.addingTimeInterval(6 * 86400)))
        XCTAssertTrue(policy.isDue(now: start.addingTimeInterval(7 * 86400)))
        XCTAssertNotEqual(WorkspaceRefreshPolicy.cacheIdentity(projectID: "project-one", uid: "same"),
                          WorkspaceRefreshPolicy.cacheIdentity(projectID: "project-two", uid: "same"))
    }

    func testOwnFunctionalCommitKeepsPendingWrittenReplyAndAdvancesOnlyItsKnownBase() throws {
        let original = try WorkspaceFixture.record()
        var root = try original.journal().payload.object!
        root["reminder_results"] = .array([.string("Onay kaydedildi")])
        let saved = try WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(root))
        var draft = WorkspaceDraft(uid: "user-one", date: "2026-08-30", base: original)
        draft.answers["q-2"] = .text("Henüz gönderilmemiş yanıt")
        draft.acknowledgeFunctional(saved, previousHash: original.hash)
        XCTAssertEqual(draft.base, saved)
        XCTAssertEqual(draft.answers["q-2"], .text("Henüz gönderilmemiş yanıt"))
        XCTAssertFalse(draft.requiresComparison)
    }

    func testChunkedDiaryAndPartitionsKeepExactUnicode() throws {
        let text = String(repeating: "Günlüğüm 😀 e\u{0301} 🇹🇷\n", count: 40_000)
        let record = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-08-30", text: text,
            answers: [:], now: "2026-08-30T10:00:00Z", newID: "long-diary").record
        let storage = try WorkspaceRecordStorage(record)
        XCTAssertGreaterThan(storage.chunks.count, 1)
        let indexed = Dictionary(storage.chunks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let decoded = try WorkspaceRecordStorage.decode(storage.fields) { key in
            guard let part = indexed[key] else { throw WorkspaceError.malformedRecord }; return part
        }
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try decoded.journal().rawText, text)
        let segments = JournalTextPartitioner.segments(text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.joined(), text)
        XCTAssertTrue(segments.allSatisfy { $0.utf8.count <= 120_000 })
        let combining = "a" + String(repeating: "\u{0301}", count: 130_000)
        XCTAssertEqual(JournalTextPartitioner.segments(combining).joined(), combining)
    }
}
