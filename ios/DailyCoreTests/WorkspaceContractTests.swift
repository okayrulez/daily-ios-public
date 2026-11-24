import Foundation
import XCTest
@testable import DailyCore

final class WorkspaceContractTests: XCTestCase {
    func testSupplementalNoteSurvivesReopeningAndAppliesOnce() throws {
        let record = try WorkspaceFixture.record(), journal = try record.journal()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceDraftStore(root: root)
        var draft = WorkspaceDraft(uid: "alice", date: journal.date, base: record)
        draft.inlineNote = InlineJournalDraft(text: "Akşam rahatladım.")
        XCTAssertTrue(draft.needsPersistence)
        XCTAssertFalse(draft.hasChanges)
        try store.save(draft)
        var reopened = try XCTUnwrap(store.load(uid: "alice", date: journal.date))
        XCTAssertNil(try store.load(uid: "bob", date: journal.date))
        try reopened.applyInlineNote(to: journal.rawText)
        let combined = journal.rawText + "\n\nAkşam rahatladım."
        XCTAssertEqual(reopened.text, combined)
        try store.save(reopened)
        var restored = try XCTUnwrap(store.load(uid: "alice", date: journal.date))
        XCTAssertNil(restored.inlineNote)
        try restored.applyInlineNote(to: combined)
        XCTAssertEqual(restored.text, combined)
    }

    func testInlineRevisionKeepsDraftWhenOriginalChanged() throws {
        let record = try WorkspaceFixture.record(), journal = try record.journal()
        var draft = WorkspaceDraft(uid: "alice", date: journal.date, base: record)
        draft.inlineNote = InlineJournalDraft(text: "Düzeltilen not", editingTextHash: WorkspaceHash.sha256(journal.rawText))
        XCTAssertThrowsError(try draft.applyInlineNote(to: "Başka cihazdan değişti"))
        XCTAssertEqual(draft.inlineNote?.text, "Düzeltilen not")
        XCTAssertNil(draft.text)
        try draft.applyInlineNote(to: journal.rawText)
        XCTAssertEqual(draft.text, "Düzeltilen not")
    }

    func testLeavingSessionRecognizesUnsavedNoAnswerButNotEmptyText() throws {
        let record = try WorkspaceFixture.record(), journal = try record.journal()
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: record)
        draft.answers["q-1"] = .boolean(0)
        draft.closeQuestions(["q-1"], in: journal)
        XCTAssertTrue(draft.analyzeAfterClose)
        XCTAssertEqual(draft.closedQuestionIDs, ["q-1"])
        var blank = WorkspaceDraft(uid: "A", date: "2026-08-30", base: record)
        blank.answers["q-2"] = .text("  ")
        blank.closeQuestions(["q-2"], in: journal)
        XCTAssertFalse(blank.analyzeAfterClose)
        XCTAssertEqual(blank.closedQuestionIDs, ["q-2"])
    }

    func testExitAnalysisIntentSurvivesSavingAnswersAndRestart() throws {
        let original = try WorkspaceFixture.record()
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: original)
        draft.answers["q-1"] = .boolean(1)
        draft.closedQuestionIDs = ["q-1", "q-2"]
        draft.analyzeAfterClose = true
        let submitted = draft.answers
        let saved = try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash, date: draft.date,
            text: nil, answers: submitted, now: "2026-10-13T10:00:00Z", newID: "unused", closedQuestionIDs: draft.closedQuestionIDs).record
        draft.acknowledge(saved, submittedText: nil, submittedAnswers: submitted, expectedHash: original.hash)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(draft.needsPersistence)
        let restored = try JSONDecoder().decode(WorkspaceDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertTrue(restored.analyzeAfterClose)
        XCTAssertTrue(try saved.journal().pendingQuestions.isEmpty)
        draft.analyzeAfterClose = false
        XCTAssertFalse(draft.needsPersistence)
    }

    func testLeavingSessionClosesOnlyVisitedQuestionsAndPersistsUntilAcknowledged() throws {
        let old = try WorkspaceFixture.record()
        var root = try old.payload().object!
        var second = root["questions"]!.array!.first!.object!
        second["id"] = .string("q-new")
        second["answer_boolean"] = .null
        second["answer_text"] = .null
        root["questions"] = .array(root["questions"]!.array! + [.object(second)])
        let record = try WorkspaceRecord.make(key: old.key, kind: .journal, payload: .object(root))
        var draft = WorkspaceDraft(uid: "owner", date: "2026-08-30", base: record)
        draft.closedQuestionIDs = ["q-1"]
        draft.answers["q-1"] = .boolean(nil)
        draft = try JSONDecoder().decode(WorkspaceDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertTrue(draft.hasChanges)
        let visible = try XCTUnwrap(JournalPresentation.current(remote: record, draft: draft))
        XCTAssertEqual(visible.pendingQuestions.map(\.id), ["q-new"])
        XCTAssertTrue(visible.answeredQuestions.contains { $0.id == "q-1" && $0.isSessionClosed && !$0.isAnswered })
        XCTAssertEqual(draft.base?.hash, record.hash)
        let saved = try WorkspaceSavePlanner.plan(current: record, expectedHash: record.hash, date: draft.date,
            text: nil, answers: draft.answers, now: "2026-10-12T10:00:00Z", newID: "unused", closedQuestionIDs: draft.closedQuestionIDs).record
        draft.acknowledge(saved, submittedText: nil, submittedAnswers: draft.answers, expectedHash: record.hash)
        XCTAssertTrue(draft.closedQuestionIDs.isEmpty)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(try saved.journal().pendingQuestions.map(\.id), ["q-new"])
    }

    func testSavedAnalysisReplyIsAvailableAfterRestart() throws {
        let old = try WorkspaceFixture.record()
        var root = try old.payload().object!
        root["daily_task"] = .object(["kind": .string("daily_task"), "reply": .string("Kaydedilmiş araştırma yanıtı")])
        root["analyses"] = .array([])
        let document = try JournalDocument(payload: .object(root))
        XCTAssertEqual(AnalysisReplyText(raw: try XCTUnwrap(document.latestReply)).text, "Kaydedilmiş araştırma yanıtı")
    }

    // Literal canonical bytes were hand-ordered; hashes independently checked with Node crypto.
    func testCanonicalUTF8MatchesJavaScriptWithoutEscapingSlashesOrTurkishText() throws {
        let value = try JSONValue.parse(#"{"z":[0,1,null],"slash":"İzmir/ışık\n","a":null}"#)
        let canonical = #"{"a":null,"slash":"İzmir/ışık\n","z":[0,1,null]}"#
        XCTAssertEqual(try value.canonical(), canonical)
        XCTAssertEqual(WorkspaceHash.sha256(canonical), "f8482ed2ed48e249407da1d4499b0ea04ffaa793aa7d0c02b761c1b492b3b33e")
        XCTAssertEqual(WorkspaceHash.sha256("journal:2026-08-30"), "09f27c91408833ea3bd4c11d0dcdfd5c632f2c66f448ead9a41979ebe20c4478")
    }

    func testCanonicalNumberAndUTF16KeyOrderingMatchesJavaScript() throws {
        let value = try JSONValue.parse(#"{"":1e21,"😀":1e-7,"a":[1.0,-0,0.000001,1e20]}"#)
        XCTAssertEqual(try value.canonical(), #"{"a":[1,0,0.000001,100000000000000000000],"😀":1e-7,"":1e+21}"#)
    }

    func testEnvelopeRejectsTamperWrongAddressUnsupportedVersionAndExtraFields() throws {
        let record = try WorkspaceRecord.make(key: "note:kişiler.md", kind: .note, payload: .string("Sentetik not"))
        XCTAssertNoThrow(try record.validated(documentID: record.documentID))
        XCTAssertThrowsError(try record.validated(documentID: String(repeating: "a", count: 64)))
        var json = record.json.object!
        json["content"] = .string(#""değiştirilmiş""#)
        XCTAssertThrowsError(try WorkspaceRecord(json: .object(json)))
        json = record.json.object!
        json["schemaVersion"] = .number(2)
        XCTAssertThrowsError(try WorkspaceRecord(json: .object(json)))
        json = record.json.object!
        json["extra"] = .null
        XCTAssertThrowsError(try WorkspaceRecord(json: .object(json)))
    }

    func testEnvelopeEnforcesUTF8ByteLimitNotCharacterCount() throws {
        XCTAssertNoThrow(try WorkspaceRecord.make(key: "note:a.md", kind: .note, payload: .string(String(repeating: "a", count: 699_998))))
        XCTAssertThrowsError(try WorkspaceRecord.make(key: "note:a.md", kind: .note, payload: .string(String(repeating: "ı", count: 350_000))))
    }

    func testNonCanonicalContentIsRejectedEvenWhenHashMatches() throws {
        let content = #" "not" "#
        let json: JSONValue = .object(["schemaVersion": .number(1), "key": .string("note:a.md"), "kind": .string("note"),
                                       "content": .string(content), "hash": .string(WorkspaceHash.sha256(content))])
        XCTAssertThrowsError(try WorkspaceRecord(json: json))
    }

    func testJournalRequiresExplicitNullAndZeroOneNotBoolean() throws {
        var payload = try WorkspaceFixture.payload()
        XCTAssertEqual(try JournalDocument(payload: payload).questions[0].answerBoolean, nil)
        let accepted: [JSONValue] = [.number(0), .number(1), .null]
        for value in accepted {
            payload = try WorkspaceFixture.settingQuestion("answer_boolean", to: value)
            XCTAssertNoThrow(try JournalDocument(payload: payload))
        }
        let rejected: [JSONValue] = [.bool(false), .number(2), .string("1")]
        for value in rejected {
            payload = try WorkspaceFixture.settingQuestion("answer_boolean", to: value)
            XCTAssertThrowsError(try JournalDocument(payload: payload))
        }
        var root = try WorkspaceFixture.payload().object!
        var entry = root["entry"]!.object!
        entry.removeValue(forKey: "analysis_error")
        root["entry"] = .object(entry)
        XCTAssertThrowsError(try JournalDocument(payload: .object(root)))
    }

    func testRejectsWrongJournalKeyChildOwnerDuplicateQuestionAndInvalidDate() throws {
        XCTAssertThrowsError(try WorkspaceRecord.make(key: "journal:2026-08-31", kind: .journal, payload: WorkspaceFixture.payload()))
        XCTAssertThrowsError(try JournalDocument(payload: WorkspaceFixture.settingQuestion("journal_id", to: .string("other"))))
        var root = try WorkspaceFixture.payload().object!
        let questions = root["questions"]!.array!
        root["questions"] = .array(questions + questions)
        XCTAssertThrowsError(try JournalDocument(payload: .object(root)))
        root = try WorkspaceFixture.payload().object!
        var entry = root["entry"]!.object!
        entry["local_date"] = .string("2026-02-30")
        root["entry"] = .object(entry)
        XCTAssertThrowsError(try JournalDocument(payload: .object(root)))
    }

    func testRejectsWrongInnerSourceHashEvenWithValidOuterHash() throws {
        var root = try WorkspaceFixture.payload().object!
        var entry = root["entry"]!.object!
        entry["content_hash"] = .string(String(repeating: "a", count: 64))
        root["entry"] = .object(entry)
        XCTAssertThrowsError(try WorkspaceRecord.make(key: "journal:2026-08-30", kind: .journal, payload: .object(root)))
    }

    func testChangedTextPreservesIDHistoryQuestionsAndUnknownFields() throws {
        let old = try WorkspaceFixture.record()
        let next = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30", text: "Yeni / metin\n", answers: [:], now: "2026-08-30T20:00:00.000Z", newID: "must-not-replace")
        let journal = try next.record.journal()
        XCTAssertEqual(journal.id, "j-1")
        XCTAssertEqual(journal.rawText, "Yeni / metin\n")
        XCTAssertEqual(journal.analysisStatus, "pending")
        XCTAssertEqual(journal.payload.object?["analyses"], try old.journal().payload.object?["analyses"])
        XCTAssertEqual(journal.payload.object?["questions"], try old.journal().payload.object?["questions"])
        XCTAssertEqual(journal.payload.object?["future"], .object(["retained": .bool(true)]))
        XCTAssertEqual(journal.payload.object?["entry"]?.object?["extension"], .string("keep"))
        XCTAssertEqual(next.previous, old)
    }

    func testClosingPartialSessionRetainsBlankAnswersAndHistory() throws {
        let old = try WorkspaceFixture.record()
        let plan = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30",
            text: nil, answers: ["q-1": .boolean(nil)], now: "2026-10-12T10:00:00Z", newID: "unused", closeQuestionSession: true)
        let journal = try plan.record.journal()
        XCTAssertTrue(journal.pendingQuestions.isEmpty)
        XCTAssertEqual(journal.answeredQuestions.count, journal.questions.count)
        XCTAssertNil(journal.questions[0].answerBoolean)
        XCTAssertFalse(journal.questions[0].isAnswered)
        XCTAssertTrue(journal.questions.allSatisfy(\.isSessionClosed))
        var root = journal.payload.object!
        root["question_history"] = root["questions"]
        root["questions"] = .array([])
        let archived = try JournalDocument(payload: .object(root))
        XCTAssertEqual(archived.archivedAnsweredQuestions.count, journal.questions.count)
        XCTAssertNil(archived.archivedAnsweredQuestions.first { $0.id == "q-1" }?.answerBoolean)
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: old, expectedHash: nil, date: "2026-08-30",
            text: nil, answers: [:], now: "now", newID: "unused", closeQuestionSession: true))
    }

    func testAnswerSavePreservesTextOtherAnswersAndAnalysisAndEncodesNull() throws {
        let old = try WorkspaceFixture.record()
        let next = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30", text: nil, answers: ["q-1": .boolean(0)], now: "later", newID: "unused")
        let journal = try next.record.journal()
        XCTAssertEqual(journal.rawText, "Eski metin")
        XCTAssertEqual(journal.analysisStatus, "complete")
        XCTAssertEqual(journal.questions[0].answerBoolean, 0)
        XCTAssertEqual(journal.questions[1].answerText, "Korunan yanıt")
        XCTAssertEqual(journal.analyses.count, 1)
        XCTAssertTrue(next.record.content.contains(#""answer_text":null"#))
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30", text: nil, answers: ["missing": .text("x")], now: "later", newID: "unused"))
    }

    func testStaleHashAndMissingServerCannotSilentlyOverwrite() throws {
        let old = try WorkspaceFixture.record()
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: old, expectedHash: nil, date: "2026-08-30", text: "draft", answers: [:], now: "now", newID: "id"))
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: nil, expectedHash: old.hash, date: "2026-08-30", text: "draft", answers: [:], now: "now", newID: "id"))
    }

    func testExplicitMissingJournalRecoveryPreservesSourceQuestionsAndAnalysis() throws {
        let original = try WorkspaceFixture.record()
        let plan = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil,
            date: "2026-08-30", text: nil, answers: ["q-1": .boolean(0)], now: "now",
            newID: "must-not-replace", closedQuestionIDs: ["q-1", "q-2"], restoring: original)
        let journal = try plan.record.journal()
        XCTAssertEqual(journal.id, try original.journal().id)
        XCTAssertEqual(journal.rawText, try original.journal().rawText)
        XCTAssertEqual(journal.analyses, try original.journal().analyses)
        XCTAssertEqual(journal.questions.count, 2)
        XCTAssertEqual(journal.questions[0].answerBoolean, 0)
        XCTAssertTrue(journal.pendingQuestions.isEmpty)
        XCTAssertNil(plan.previous) // A missing parent cannot authorize a server version archive.
    }

    func testRecoveryNeverReplacesRecreatedServerJournalOrWrongDate() throws {
        let original = try WorkspaceFixture.record()
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: original, expectedHash: nil,
            date: "2026-08-30", text: nil, answers: [:], now: "now", newID: "id", restoring: original))
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash,
            date: "2026-08-30", text: nil, answers: [:], now: "now", newID: "id", restoring: original))
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil,
            date: "2026-08-31", text: nil, answers: [:], now: "now", newID: "id", restoring: original))
    }

    func testConflictPauseSurvivesRestartAndRequiresExplicitResolution() throws {
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: try WorkspaceFixture.record())
        draft.answers["q-1"] = .boolean(0)
        draft.markConflict()
        let restored = try JSONDecoder().decode(WorkspaceDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertTrue(restored.requiresComparison)
        XCTAssertThrowsError(try restored.checkSubmission())
        XCTAssertNoThrow(try restored.checkSubmission(explicitlyCompared: true))
    }

    func testFirstSaveCreatesPortablePendingJournalWithoutInventedAnalysisOrQuestions() throws {
        let plan = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-08-30", text: "Sentetik ilk kayıt", answers: [:], now: "2026-08-30T20:00:00.000Z", newID: "new-id")
        let journal = try plan.record.journal()
        XCTAssertEqual(journal.id, "new-id")
        XCTAssertEqual(journal.analysisStatus, "pending")
        XCTAssertTrue(journal.analyses.isEmpty)
        XCTAssertTrue(journal.questions.isEmpty)
        XCTAssertNil(plan.previous)
        XCTAssertEqual(journal.entry["analysis_error"], .null)
    }

    func testExplicitOverrideOverlaysOnlySelectedEditOnFreshServerVersion() throws {
        let old = try WorkspaceFixture.record()
        let remote = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30", text: "PC yeni metin", answers: ["q-2": .text("PC yeni yanıt")], now: "now", newID: "unused").record
        let override = try WorkspaceSavePlanner.plan(current: remote, expectedHash: remote.hash, date: "2026-08-30", text: nil, answers: ["q-1": .boolean(1)], now: "now", newID: "unused")
        let journal = try override.record.journal()
        XCTAssertEqual(journal.rawText, "PC yeni metin")
        XCTAssertEqual(journal.questions[1].answerText, "PC yeni yanıt")
        XCTAssertEqual(journal.questions[0].answerBoolean, 1)
        XCTAssertEqual(override.previous, remote)
    }

    func testCleanDraftAdoptsRealtimeButPendingAnswerKeepsOriginalBaseline() throws {
        let old = try WorkspaceFixture.record()
        let remote = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: "2026-08-30", text: "PC yeni metin", answers: [:], now: "now", newID: "unused").record
        var clean = WorkspaceDraft(uid: "A", date: "2026-08-30", base: old)
        clean.receive(remote)
        XCTAssertEqual(clean.base, remote)
        var dirty = WorkspaceDraft(uid: "A", date: "2026-08-30", base: old)
        dirty.answers["q-1"] = .boolean(0)
        dirty.receive(remote)
        XCTAssertEqual(dirty.base, old)
        XCTAssertEqual(dirty.answers["q-1"], .boolean(0))
    }

    func testDraftStorageSurvivesReopenAndIsAccountScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceDraftStore(root: root)
        var draft = WorkspaceDraft(uid: "account-A", date: "2026-08-30", base: try WorkspaceFixture.record())
        draft.text = "yerel taslak"
        draft.answers["q-1"] = .boolean(0)
        try store.save(draft)
        let reopened = try WorkspaceDraftStore(root: root)
        XCTAssertEqual(try reopened.load(uid: "account-A", date: "2026-08-30"), draft)
        XCTAssertNil(try reopened.load(uid: "account-B", date: "2026-08-30"))
        XCTAssertThrowsError(try reopened.load(uid: "../escape", date: "2026-08-30"))
    }

    func testRealtimeAndAcknowledgementDoNotEraseUnsubmittedTypingOrAnswers() throws {
        let old = try WorkspaceFixture.record()
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: old)
        draft.text = "Yazmaya devam ettim"
        draft.answers["q-1"] = .boolean(1)
        let remote = try WorkspaceSavePlanner.plan(current: old, expectedHash: old.hash, date: draft.date, text: "Gönderilmiş metin", answers: [:], now: "now", newID: "id").record
        draft.receive(remote)
        XCTAssertEqual(draft.base?.hash, old.hash)
        XCTAssertEqual(draft.text, "Yazmaya devam ettim")
        draft.acknowledge(remote, submittedText: "Gönderilmiş metin", submittedAnswers: [:], expectedHash: old.hash)
        XCTAssertEqual(draft.text, "Yazmaya devam ettim")
        XCTAssertEqual(draft.answers["q-1"], .boolean(1))
        XCTAssertEqual(draft.base?.hash, remote.hash)
    }

    func testPartialTextConflictOverrideRequiresNewComparisonForRetainedAnswer() throws {
        let original = try WorkspaceFixture.record() // q-1 unanswered
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: original)
        draft.text = "Mobile text"
        draft.answers["q-1"] = .boolean(0)
        let pc = try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash, date: draft.date,
                                               text: nil, answers: ["q-1": .boolean(1)], now: "now", newID: "unused").record
        XCTAssertThrowsError(try WorkspaceSavePlanner.plan(current: pc, expectedHash: original.hash, date: draft.date,
                                                           text: draft.text, answers: [:], now: "now", newID: "unused"))
        // User compared PC answer=1 and explicitly overrides ONLY their text.
        let textOverride = try WorkspaceSavePlanner.plan(current: pc, expectedHash: pc.hash, date: draft.date,
                                                         text: draft.text, answers: [:], now: "now", newID: "unused").record
        draft.acknowledge(textOverride, submittedText: "Mobile text", submittedAnswers: [:], expectedHash: pc.hash)
        XCTAssertEqual(try draft.base?.journal().questions[0].answerBoolean, 1)
        XCTAssertEqual(draft.answers["q-1"], .boolean(0))
        XCTAssertTrue(draft.requiresComparison)
        XCTAssertThrowsError(try draft.checkSubmission()) // CAS against advanced base must not hide old answer conflict.
        XCTAssertNoThrow(try draft.checkSubmission(explicitlyCompared: true))
        let persisted = try JSONDecoder().decode(WorkspaceDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertThrowsError(try persisted.checkSubmission()) // restart must not forget the comparison gate.
        let answerOverride = try WorkspaceSavePlanner.plan(current: textOverride, expectedHash: textOverride.hash, date: draft.date,
                                                           text: nil, answers: draft.answers, now: "now", newID: "unused").record
        let submittedAnswers = draft.answers
        draft.acknowledge(answerOverride, submittedText: nil, submittedAnswers: submittedAnswers, expectedHash: textOverride.hash)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.requiresComparison)
    }

    func testOwnPartialSaveDoesNotRequireSpuriousConflictComparison() throws {
        let original = try WorkspaceFixture.record()
        var draft = WorkspaceDraft(uid: "A", date: "2026-08-30", base: original)
        draft.text = "Mobile text"
        draft.answers["q-1"] = .boolean(0)
        let saved = try WorkspaceSavePlanner.plan(current: original, expectedHash: original.hash, date: draft.date,
                                                  text: draft.text, answers: [:], now: "now", newID: "unused").record
        draft.acknowledge(saved, submittedText: "Mobile text", submittedAnswers: [:], expectedHash: original.hash)
        XCTAssertNoThrow(try draft.checkSubmission())
        XCTAssertEqual(draft.answers["q-1"], .boolean(0))
    }

    func testByteDistinctNormalizedNoteKeysHaveSeparateIndexAndUIIdentity() throws {
        let nfc = try WorkspaceRecord.make(key: "note:caf\u{00e9}.md", kind: .note, payload: .string("Sentetik not"))
        let nfd = try WorkspaceRecord.make(key: "note:cafe\u{0301}.md", kind: .note, payload: .string("Sentetik not"))
        let records = try WorkspaceRecord.index([nfc, nfd])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(nfc.id, "f6bec556157ffdc3a7994b7e63f10de8f4853628bde33d193bb25ce982efad49")
        XCTAssertEqual(nfd.id, "b76a40e8877c9432c68ec7a76047258ef3a12c6425f4c5327a7565f5452d1791")
        XCTAssertNotEqual(nfc.id, nfd.id)
        XCTAssertNotEqual(nfc, nfd)
        XCTAssertEqual(Array(records[nfc.id]!.key.utf8), Array("note:caf\u{00e9}.md".utf8))
        XCTAssertEqual(Array(records[nfd.id]!.key.utf8), Array("note:cafe\u{0301}.md".utf8))
        XCTAssertThrowsError(try WorkspaceRecord.index([nfc, nfc])) // reject duplicates instead of trapping or dropping one.
    }
}

enum WorkspaceFixture {
    static func payload() throws -> JSONValue {
        try JSONValue.parse(#"{"entry":{"id":"j-1","local_date":"2026-08-30","raw_text":"Eski metin","content_hash":"0fe5ff3ae88ad1ec0ef06a145d12fff405e79634e4012e614c84c12f0a291675","saved_at":"2026-08-30T10:00:00.000Z","analysis_status":"complete","analysis_error":null,"extension":"keep"},"analyses":[{"id":"a-1","journal_id":"j-1","version":1,"provider":"fixture","reflection":"Sentetik değerlendirme","confidence":"medium","created_at":"2026-08-30T11:00:00.000Z"}],"questions":[{"id":"q-1","journal_id":"j-1","kind":"boolean","position":0,"prompt":"Sentetik soru?","rationale":"Gerekçe","source_ref":"fixture","answer_text":null,"answer_boolean":null},{"id":"q-2","journal_id":"j-1","kind":"open","position":0,"prompt":"Yazılı soru?","rationale":"Gerekçe","source_ref":"fixture","answer_text":"Korunan yanıt","answer_boolean":null}],"future":{"retained":true}}"#)
    }

    static func record() throws -> WorkspaceRecord {
        try WorkspaceRecord.make(key: "journal:2026-08-30", kind: .journal, payload: payload())
    }

    static func settingQuestion(_ key: String, to value: JSONValue) throws -> JSONValue {
        var root = try payload().object!
        var questions = root["questions"]!.array!
        var question = questions[0].object!
        question[key] = value
        questions[0] = .object(question)
        root["questions"] = .array(questions)
        return .object(root)
    }
}
