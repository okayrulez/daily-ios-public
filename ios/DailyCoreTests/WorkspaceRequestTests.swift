import Foundation
import XCTest
@testable import DailyCore

final class WorkspaceRequestTests: XCTestCase {
    func testDeterministicIdentityUsesOuterHashAndSeparatesKinds() throws {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try WorkspaceAnalysisRequest.identity(kind: .initial, sourceHash: hash), "initial-" + hash)
        XCTAssertEqual(try WorkspaceAnalysisRequest.identity(kind: .answers, sourceHash: hash), "answers-" + hash)
        XCTAssertThrowsError(try WorkspaceAnalysisRequest.identity(kind: .initial, sourceHash: "not-a-hash"))
        XCTAssertEqual(try WorkspaceAnalysisRequest.path(uid: "account-A"), "users/account-A/dailyXRequests")
        XCTAssertThrowsError(try WorkspaceAnalysisRequest.path(uid: "../account-A"))
    }

    func testParserRejectsWrongIdentityUnknownFieldsMissingNullAndInvalidState() throws {
        let fields = RequestFixture.fields()
        XCTAssertNoThrow(try RequestFixture.request(fields))
        XCTAssertThrowsError(try WorkspaceAnalysisRequest(documentID: "answers-" + RequestFixture.hash, fields: fields))
        var invalid = fields
        invalid["extra"] = .null
        XCTAssertThrowsError(try RequestFixture.request(invalid))
        invalid = fields; invalid.removeValue(forKey: "resultHash")
        XCTAssertThrowsError(try RequestFixture.request(invalid))
        for (key, value) in [("schemaVersion", JSONValue.number(2)), ("attemptCount", .number(-1)),
                             ("attemptCount", .bool(false)), ("createdAt", .string("now")),
                             ("updatedAt", .number(.infinity)), ("recordKey", .string("journal:2026-02-30")),
                             ("leaseOwner", .string("worker")), ("resultHash", .string(RequestFixture.hash))] {
            invalid = fields; invalid[key] = value
            XCTAssertThrowsError(try RequestFixture.request(invalid), key)
        }
    }

    func testStateValidationRequiresProcessingLeaseCompleteResultAndSafeFailure() throws {
        var fields = RequestFixture.fields(status: "processing")
        XCTAssertThrowsError(try RequestFixture.request(fields))
        fields["leaseOwner"] = .string("pc-1"); fields["leaseUntil"] = .number(500); fields["attemptCount"] = .number(1)
        XCTAssertEqual(try RequestFixture.request(fields).status, .processing)
        fields = RequestFixture.fields(status: "complete")
        XCTAssertThrowsError(try RequestFixture.request(fields))
        fields["resultHash"] = .string(String(repeating: "b", count: 64))
        XCTAssertEqual(try RequestFixture.request(fields).status, .complete)
        fields["errorCode"] = .string("analysis_failed")
        XCTAssertThrowsError(try RequestFixture.request(fields))
        for (status, code) in [("failed", "analysis_failed"), ("stale", "source_changed")] {
            fields = RequestFixture.fields(status: status)
            XCTAssertThrowsError(try RequestFixture.request(fields))
            fields["errorCode"] = .string(code)
            XCTAssertNoThrow(try RequestFixture.request(fields))
            fields["errorCode"] = .string("private upstream error")
            XCTAssertThrowsError(try RequestFixture.request(fields))
        }
    }

    func testStatusMatchesOnlyThisJournalCurrentSourceOrCompletedResult() throws {
        let original = try WorkspaceFixture.record()
        let edited = try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash, date: "2026-08-30",
                                                   text: "Yeni metin", answers: [:], now: "later", newID: "unused").record
        var fields = RequestFixture.fields(sourceHash: original.hash)
        XCTAssertTrue(try RequestFixture.request(fields).matches(original))
        XCTAssertFalse(try RequestFixture.request(fields).matches(edited))
        fields["status"] = .string("complete"); fields["resultHash"] = .string(edited.hash)
        XCTAssertTrue(try RequestFixture.request(fields).matches(edited))
        fields["recordKey"] = .string("journal:2026-08-29")
        XCTAssertFalse(try RequestFixture.request(fields).matches(edited))
        fields["recordKey"] = .string("journal:2026-08-30")
        fields["status"] = .string("failed"); fields["errorCode"] = .string("analysis_failed")
        XCTAssertThrowsError(try RequestFixture.request(fields)) // Failed requests may not carry a result.
        fields["resultHash"] = .null
        XCTAssertFalse(try RequestFixture.request(fields).matches(edited))
    }

    func testParserRejectsRetainedLeaseNonCompleteResultAndProcessingError() throws {
        for status in ["queued", "complete", "failed", "stale"] {
            var fields = RequestFixture.fields(status: status)
            if status == "complete" { fields["resultHash"] = .string(String(repeating: "b", count: 64)) }
            if status == "failed" { fields["errorCode"] = .string("analysis_failed") }
            if status == "stale" { fields["errorCode"] = .string("source_changed") }
            XCTAssertNoThrow(try RequestFixture.request(fields))
            fields["leaseOwner"] = .string("pc-1"); fields["leaseUntil"] = .number(500)
            XCTAssertThrowsError(try RequestFixture.request(fields))
        }
        var processing = RequestFixture.fields(status: "processing")
        processing["leaseOwner"] = .string("pc-1"); processing["leaseUntil"] = .number(500); processing["attemptCount"] = .number(1)
        var invalid = processing; invalid["errorCode"] = .string("analysis_failed")
        XCTAssertThrowsError(try RequestFixture.request(invalid))
        invalid = processing; invalid["resultHash"] = .string(String(repeating: "b", count: 64))
        XCTAssertThrowsError(try RequestFixture.request(invalid))
        for owner in ["worker/other", "iPhone Çalışan", String(repeating: "a", count: 129)] {
            invalid = processing; invalid["leaseOwner"] = .string(owner)
            XCTAssertThrowsError(try RequestFixture.request(invalid))
        }
    }

    func testStatusSelectionPrefersCurrentSourceAndRejectsOtherKindAndOldText() throws {
        let original = try WorkspaceFixture.record()
        let current = try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash, date: "2026-08-30",
                                                   text: nil, answers: ["q-1": .boolean(0)], now: "now", newID: "unused").record
        var oldFields = RequestFixture.fields(sourceHash: original.hash, status: "complete", kind: "answers")
        oldFields["resultHash"] = .string(current.hash); oldFields["updatedAt"] = .number(999)
        let old = try RequestFixture.request(oldFields)
        let queued = try RequestFixture.request(RequestFixture.fields(sourceHash: current.hash, kind: "answers"))
        XCTAssertEqual(WorkspaceAnalysisRequest.latest([old, queued], for: current, kind: .answers)?.status, .queued)
        XCTAssertEqual(WorkspaceAnalysisRequest.latest([old], for: current, kind: .answers)?.status, .complete)
        XCTAssertNil(WorkspaceAnalysisRequest.latest([old, queued], for: current, kind: .initial))
        let edited = try WorkspaceSavePlanner.plan(current: current, expectedHash: current.hash, date: "2026-08-30",
                                                  text: "Başka metin", answers: [:], now: "now", newID: "unused").record
        XCTAssertNil(WorkspaceAnalysisRequest.latest([old, queued], for: edited, kind: .answers))
    }

    func testInitialEligibilityRequiresSavedPendingTextAndNoLocalDraft() throws {
        let complete = try WorkspaceFixture.record()
        let pending = try WorkspaceSavePlanner.plan(current: complete, expectedHash: complete.hash, date: "2026-08-30",
                                                    text: "Yeni metin", answers: [:], now: "later", newID: "unused").record
        XCTAssertEqual(RequestFixture.block(record: nil, kind: .initial), .saveFirst)
        XCTAssertEqual(RequestFixture.block(record: complete, kind: .initial), .alreadyAnalyzed)
        XCTAssertNil(RequestFixture.block(record: pending, kind: .initial))
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: pending)
        draft.text = "Kaydedilmemiş"
        XCTAssertEqual(RequestFixture.block(record: pending, draft: draft, kind: .initial), .saveFirst)
        draft.text = nil; draft.answers["q-1"] = .boolean(0)
        XCTAssertEqual(RequestFixture.block(record: pending, draft: draft, kind: .initial), .saveFirst)
        XCTAssertEqual(draft.answers["q-1"], .boolean(0))
        let empty = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-08-30",
                                                  text: " \n", answers: [:], now: "now", newID: "j-empty").record
        XCTAssertEqual(RequestFixture.block(record: empty, kind: .initial), .emptyText)
    }

    func testAnswerEligibilityRequiresSavedQuestionSetWithRelevantAnswerIncludingNo() throws {
        let answered = try WorkspaceFixture.record()
        XCTAssertNil(RequestFixture.block(record: answered, kind: .answers))
        let unanswered = try WorkspaceSavePlanner.plan(current: answered, expectedHash: answered.hash, date: "2026-08-30",
                                                       text: nil, answers: ["q-2": .text(" \n")], now: "later", newID: "unused").record
        XCTAssertEqual(RequestFixture.block(record: unanswered, kind: .answers), .answerFirst)
        let no = try WorkspaceSavePlanner.plan(current: unanswered, expectedHash: unanswered.hash, date: "2026-08-30",
                                               text: nil, answers: ["q-1": .boolean(0)], now: "later", newID: "unused").record
        XCTAssertNil(RequestFixture.block(record: no, kind: .answers))
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: answered)
        draft.answers["q-2"] = .text("Yerel yanıt")
        XCTAssertEqual(RequestFixture.block(record: answered, draft: draft, kind: .answers), .saveFirst)
        let fresh = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-08-30",
                                                  text: "Yeni günlük", answers: [:], now: "now", newID: "j-new").record
        XCTAssertEqual(RequestFixture.block(record: fresh, kind: .answers), .initialFirst)
    }

    func testChangedPendingTextCannotAnalyzeRetainedAnsweredQuestions() throws {
        let complete = try WorkspaceFixture.record()
        let pending = try WorkspaceSavePlanner.plan(current: complete, expectedHash: complete.hash, date: "2026-08-30",
                                                    text: "Yeni kaynak metin", answers: [:], now: "later", newID: "unused").record
        XCTAssertEqual(try pending.journal().questions[1].answerText, "Korunan yanıt")
        XCTAssertEqual(RequestFixture.block(record: pending, kind: .answers), .initialFirst)
        XCTAssertNil(RequestFixture.block(record: pending, kind: .initial))
        var root = try pending.payload().object!
        var entry = root["entry"]!.object!; entry["analysis_status"] = .string("failed")
        root["entry"] = .object(entry)
        let failed = try WorkspaceRecord.make(key: pending.key, kind: .journal, payload: .object(root))
        XCTAssertEqual(RequestFixture.block(record: failed, kind: .answers), .initialFirst)
        XCTAssertNil(RequestFixture.block(record: failed, kind: .initial))
    }

    func testEligibilityRejectsUnconfirmedServerOfflineWrongAccountAndStaleEditor() throws {
        let record = try WorkspaceFixture.record()
        XCTAssertEqual(RequestFixture.block(record: record, kind: .answers, serverReady: false), .connectionRequired)
        XCTAssertEqual(RequestFixture.block(record: record, kind: .answers, networkAvailable: false), .connectionRequired)
        let wrongAccount = WorkspaceDraft(uid: "B", date: "2026-08-30", base: record)
        XCTAssertEqual(RequestFixture.block(record: record, draft: wrongAccount, kind: .answers), .accountChanged)
        let staleEditor = WorkspaceDraft(uid: "A", date: "2026-08-30", base: nil)
        XCTAssertEqual(RequestFixture.block(record: record, draft: staleEditor, kind: .answers), .saveFirst)
    }

    func testEnqueuePlanCreatesOnlyQueuedContractAndRejectsChangedSource() throws {
        let source = try WorkspaceFixture.record()
        let planned = try XCTUnwrap(WorkspaceRequestPlanner.enqueue(current: source, expected: source, kind: .answers, existing: nil, now: 200))
        XCTAssertEqual(planned.sourceHash, source.hash)
        XCTAssertEqual(planned.recordKey, "journal:2026-08-30")
        XCTAssertEqual(planned.status, .queued)
        XCTAssertEqual(planned.fields["createdAt"], .number(200))
        XCTAssertEqual(planned.fields["attemptCount"], .number(0))
        XCTAssertEqual(planned.fields["leaseOwner"], .null)
        XCTAssertEqual(planned.fields["leaseUntil"], .null)
        XCTAssertEqual(planned.fields["resultHash"], .null)
        XCTAssertEqual(planned.fields["errorCode"], .null)
        XCTAssertEqual(planned.fields.count, 12)
        XCTAssertEqual(Set(planned.fields.keys), Set([
            "schemaVersion", "kind", "recordKey", "sourceHash", "status", "leaseOwner", "leaseUntil",
            "attemptCount", "createdAt", "updatedAt", "resultHash", "errorCode"
        ]))
        XCTAssertThrowsError(try WorkspaceRequestPlanner.enqueue(current: nil, expected: source, kind: .answers, existing: nil, now: 200))
        let changed = try WorkspaceSavePlanner.plan(current: source, expectedHash: source.hash, date: "2026-08-30",
                                                    text: "PC değişikliği", answers: [:], now: "now", newID: "unused").record
        XCTAssertThrowsError(try WorkspaceRequestPlanner.enqueue(current: changed, expected: source, kind: .answers, existing: nil, now: 200))
    }

    func testRepeatedQueuedProcessingCompleteRequestsAreNoOpAndFailuresCanExplicitlyRetry() throws {
        let source = try WorkspaceFixture.record()
        for status in ["queued", "processing", "complete", "failed", "stale"] {
            var fields = RequestFixture.fields(sourceHash: source.hash, status: status, kind: "answers")
            fields["createdAt"] = .number(123); fields["attemptCount"] = .number(4)
            if status == "processing" { fields["leaseOwner"] = .string("pc-1"); fields["leaseUntil"] = .number(500) }
            if status == "complete" { fields["resultHash"] = .string(String(repeating: "b", count: 64)) }
            if status == "failed" { fields["errorCode"] = .string("analysis_failed") }
            if status == "stale" { fields["errorCode"] = .string("source_changed") }
            let existing = try RequestFixture.request(fields)
            let result = try WorkspaceRequestPlanner.enqueue(current: source, expected: source, kind: .answers, existing: existing, now: 200)
            if ["failed", "stale"].contains(status) {
                let retry = try XCTUnwrap(result)
                XCTAssertEqual(retry.status, .queued)
                XCTAssertEqual(retry.fields["createdAt"], .number(123))
                XCTAssertEqual(retry.fields["attemptCount"], .number(4))
                XCTAssertEqual(retry.fields["updatedAt"], .number(200))
                XCTAssertEqual(retry.fields["errorCode"], .null)
                XCTAssertEqual(retry.fields["resultHash"], .null)
                XCTAssertEqual(retry.fields["leaseOwner"], .null)
                XCTAssertEqual(retry.fields["leaseUntil"], .null)
            } else { XCTAssertNil(result, status) }
        }
    }

    func testAccountAndListenerGenerationGateRejectsLateCallbacksAndTransactionRetries() throws {
        let gate = WorkspaceRequestSessionGate()
        let first = try WorkspaceRequestScope(uid: "A", session: UUID(), generation: UUID())
        gate.activate(first)
        XCTAssertTrue(gate.accepts(first, authenticatedUID: "A"))
        XCTAssertFalse(gate.accepts(first, authenticatedUID: "B"))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(first, authenticatedUID: "A"))
        let relogin = try WorkspaceRequestScope(uid: "A", session: UUID(), generation: UUID())
        gate.activate(relogin)
        XCTAssertFalse(gate.accepts(first, authenticatedUID: "A"))
        XCTAssertTrue(gate.accepts(relogin, authenticatedUID: "A"))
        let listenerRetry = try WorkspaceRequestScope(uid: "A", session: relogin.session, generation: UUID())
        gate.activate(listenerRetry)
        XCTAssertFalse(gate.accepts(relogin, authenticatedUID: "A"))
        XCTAssertTrue(gate.accepts(listenerRetry, authenticatedUID: "A"))
        XCTAssertThrowsError(try WorkspaceRequestScope(uid: "../escape", session: UUID(), generation: UUID()))
    }
}

private enum RequestFixture {
    static let hash = String(repeating: "a", count: 64)
    static func fields(sourceHash: String = hash, status: String = "queued", kind: String = "initial") -> [String: JSONValue] {
        ["schemaVersion": .number(1), "kind": .string(kind), "recordKey": .string("journal:2026-08-30"),
         "sourceHash": .string(sourceHash), "status": .string(status), "leaseOwner": .null, "leaseUntil": .null,
         "attemptCount": .number(0), "createdAt": .number(100), "updatedAt": .number(100), "resultHash": .null, "errorCode": .null]
    }
    static func request(_ fields: [String: JSONValue]) throws -> WorkspaceAnalysisRequest {
        try WorkspaceAnalysisRequest(documentID: fields["kind"]!.string! + "-" + fields["sourceHash"]!.string!, fields: fields)
    }
    static func block(record: WorkspaceRecord?, draft: WorkspaceDraft? = nil, kind: WorkspaceAnalysisKind,
                      serverReady: Bool = true, networkAvailable: Bool = true) -> WorkspaceRequestBlock? {
        WorkspaceRequestEligibility.block(uid: "A", date: "2026-08-30", record: record, draft: draft,
                                           kind: kind, serverReady: serverReady, networkAvailable: networkAvailable)
    }
}
