import Foundation
import XCTest
@testable import DailyCore

final class PhoneAnalysisJobTests: XCTestCase {
    func testIdentityIncludesAccountContextAndSourceRevision() throws {
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let source = try WorkspaceFixture.record()
        let hash = String(repeating: "a", count: 64)
        func job(_ account: String, _ context: String) throws -> PhoneAnalysisJob {
            try PhoneAnalysisJob(scope: scope, accountID: account, model: "fixture-model",
                source: source, memoryHash: hash, memoryContext: context, workContext: "")
        }
        XCTAssertEqual(try job("one", "context").id, try job("one", "context").id)
        XCTAssertNotEqual(try job("one", "context").id, try job("two", "context").id)
        XCTAssertNotEqual(try job("one", "context").id, try job("one", "corrected context").id)
    }

    func testReasoningChangesRequestAndCheckpointIdentity() throws {
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        func job(_ effort: String?) throws -> PhoneAnalysisJob {
            try PhoneAnalysisJob(scope: scope, accountID: "one", model: "fixture-model",
                source: WorkspaceFixture.record(), memoryHash: String(repeating: "a", count: 64),
                memoryContext: "", workContext: "", reasoningEffort: effort)
        }
        let low = try job("low"), high = try job("high"), automatic = try job(nil)
        XCTAssertNotEqual(low.id, high.id)
        XCTAssertNotEqual(low.id, automatic.id)
        XCTAssertEqual(try JSONValue.parse(high.preparedJSON).object?["reasoning"]?.object?["effort"]?.string, "high")
        XCTAssertNil(try JSONValue.parse(automatic.preparedJSON).object?["reasoning"])
    }

    func testFinalReflectionPairsTheWrittenAnswerAndUsesItsOwnUsageStage() throws {
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let original = try WorkspaceFixture.record()
        var payload = try XCTUnwrap(original.payload().object)
        var questions = try XCTUnwrap(payload["questions"]?.array)
        var written = try XCTUnwrap(questions[1].object)
        written["session_closed_at"] = .string("2026-08-30T12:00:00Z")
        questions[1] = .object(written)
        payload["questions"] = .array(questions)
        let source = try WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(payload))
        let context = #"{"currentUserAnswers":[{"question":"Yazılı soru?","answer":"Korunan yanıt"}]}"#
        let job = try PhoneAnalysisJob(scope: scope, accountID: "fixture", model: "fixture-model", source: source,
            memoryHash: String(repeating: "a", count: 64), memoryContext: context, workContext: "")

        let prepared = try XCTUnwrap(JSONValue.parse(job.preparedJSON).object)
        XCTAssertEqual(prepared["usageStage"], .string("dayReflection"))
        let prompt = try XCTUnwrap(prepared["input"]?.array?.first?.object?["content"]?.string)
        let promptFields = try XCTUnwrap(JSONValue.parse(prompt).object)
        XCTAssertEqual(promptFields["userAnswers"], .array([.object([
            "question": .string("Yazılı soru?"), "answer": .string("Korunan yanıt")
        ])]))
        XCTAssertEqual(prompt.components(separatedBy: "Korunan yanıt").count, 2)
    }

    func testNewTextKeepsThePublishedReflectionDuringReanalysis() throws {
        let original = try WorkspaceFixture.record()
        var payload = try XCTUnwrap(original.payload().object)
        payload["questions"] = .array([])
        let completed = try WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(payload))
        let first = try completed.journal()
        XCTAssertEqual(first.dayReflection, "Sentetik değerlendirme")
        XCTAssertNil(first.previousDayReflection)

        let newText = first.rawText + "\n\nEk bir not."
        let saved = try WorkspaceSavePlanner.plan(current: completed, expectedHash: completed.hash,
            date: first.date, text: newText, answers: [:], now: "2026-08-30T12:00:00Z", newID: first.id).record
        let pending = try saved.journal()
        XCTAssertEqual(pending.previousDayReflection, first.dayReflection)
        XCTAssertEqual(pending.analyses, first.analyses)
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let job = try PhoneAnalysisJob(scope: scope, accountID: "fixture", model: "fixture-model", source: saved,
            memoryHash: String(repeating: "a", count: 64), memoryContext: "", workContext: "")
        let prompt = try XCTUnwrap(JSONValue.parse(job.preparedJSON).object?["input"]?.array?.first?.object?["content"]?.string)
        XCTAssertEqual(pending.previousTextByteCount, first.rawText.utf8.count)
        XCTAssertTrue(prompt.contains(first.rawText))
        XCTAssertTrue(prompt.contains("Ek bir not."))
        XCTAssertTrue(prompt.contains("Önceki yorumdan sonra eklenen günlük bölümü"))
        let again = try WorkspaceSavePlanner.plan(current: saved, expectedHash: saved.hash,
            date: first.date, text: newText + " Bir not daha.", answers: [:], now: first.savedAt, newID: first.id).record
        XCTAssertEqual(try again.journal().previousTextByteCount, first.rawText.utf8.count)
        let edited = try WorkspaceSavePlanner.plan(current: again, expectedHash: again.hash,
            date: first.date, text: "Başlangıcı da değişti.", answers: [:], now: first.savedAt, newID: first.id).record
        XCTAssertNil(try edited.journal().previousTextByteCount)
        XCTAssertEqual(try edited.journal().previousDayReflection, first.dayReflection)
        XCTAssertEqual(pending.payload.object?["previous_day_reflection_ids"]?.array?.count, 1)
        XCTAssertEqual(prompt.components(separatedBy: "Sentetik değerlendirme").count, 2)
    }

    func testWrongSessionNeverCallsInference() async throws {
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try PhoneAnalysisCoordinator(root: root) { _, _ in
            XCTFail("An unselected account must not call the model")
            return "{}"
        }
        let job = try PhoneAnalysisJob(scope: scope, accountID: "account-one", model: "fixture-model",
            source: WorkspaceFixture.record(), memoryHash: String(repeating: "a", count: 64),
            memoryContext: "", workContext: "")
        do { _ = try await coordinator.run(job); XCTFail("Expected session mismatch") }
        catch { XCTAssertTrue(error is PhoneAnalysisError) }
    }
}
