import Foundation
import XCTest
@testable import DailyCore

private actor TaskInferenceCounter {
    var count = 0
    func called() { count += 1 }
}

final class PhoneTaskCoordinatorTests: XCTestCase {
    func testModelResponseRepairRunsOnceAndValidatesTheCorrectedJSON() async throws {
        let nodes: JSONValue = .array(["a", "b"].map { id in
            .object(["id": .string(id), "label": .string(id), "summary": .string(""), "topicPath": .array([])])
        })
        let prepared = try AnalysisCore.invoke("prepareMapQuestions", json: JSONValue.object(["nodes": nodes]).canonical())
        let questions: JSONValue = .array((1...3).map {
            .object(["prompt": .string("Soru \($0)"), "rationale": .string("Bağlantıyı açıkla")])
        })
        let corrected = try JSONValue.object(["open_questions": questions, "boolean_questions": questions]).canonical()
        let counter = TaskInferenceCounter()
        func validate(_ raw: String) throws -> String {
            try AnalysisCore.invoke("validateMapQuestions", json: raw)
        }

        let valid = try await AnalysisCore.validateModelResponse(corrected, prepared: prepared,
            command: "validateMapQuestions", reasoningEffort: nil, infer: { _ in
                await counter.called()
                return corrected
            }, validate: validate)
        let validCalls = await counter.count
        XCTAssertEqual(validCalls, 0)

        let repaired = try await AnalysisCore.validateModelResponse("{", prepared: prepared,
            command: "validateMapQuestions", reasoningEffort: nil, infer: { prompt in
                await counter.called()
                let request = try JSONValue.parse(prompt).object
                XCTAssertEqual(request?["usageStage"], .string("responseFormatRepair"))
                XCTAssertEqual(request?["webResearch"], .bool(false))
                return corrected
            }, validate: validate)
        XCTAssertEqual(valid, repaired)
        let repairedCalls = await counter.count
        XCTAssertEqual(repairedCalls, 1)

        do {
            _ = try await AnalysisCore.validateModelResponse("{", prepared: prepared,
                command: "validateMapQuestions", reasoningEffort: nil, infer: { _ in
                    await counter.called()
                    return "{"
                }, validate: validate)
            XCTFail("The second malformed response must fail")
        } catch let failure as AnalysisValidationFailure {
            XCTAssertEqual(failure.code, "invalid_json")
        }
        let totalCalls = await counter.count
        XCTAssertEqual(totalCalls, 2)
    }

    func testProfileResearchGoesStraightToWebAndCommitsAsNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = SocialProfile().replacingIntroduction("Adım Deniz. GitHub: deniz-dev. " + String(repeating: "profil ", count: 1_250))
        profile.researchAllowed = true
        let clean = try profile.validated()
        XCTAssertEqual(clean.introductionText, profile.introductionText.trimmingCharacters(in: .whitespaces))
        let profileRecord = try WorkspaceRecord.make(key: SocialProfile.key, kind: .note, payload: .string("profile fixture"))
        let now = "2026-11-06T12:00:00Z"
        let source = try ProfileResearchSource.make(profile: profileRecord,
            request: XCTUnwrap(clean.researchRequest), date: "2026-11-06", now: now)
        let scope = try MemoryScope(projectID: "fixture", uid: "alice")
        let memory = try PortableMemory(json: AnalysisCore.invoke("emptyMemory", json: "{}"))
        let job = try PhoneAnalysisJob(scope: scope, accountID: "account", model: "fixture",
            source: source, memoryHash: memory.contentHash, memoryContext: "", workContext: "")
        let counter = TaskInferenceCounter()
        let coordinator = try PhoneTaskCoordinator(root: root) { _, prompt in
            await counter.called()
            XCTAssertEqual(try JSONValue.parse(prompt).object?["webResearch"], .bool(true))
            let response = #"{"status":"completed","reply":"Açık profil eşleşti.","findings":[{"label":"Açık profil","detail":"Kaynakta bir yazılım portföyü bulunuyor.","urls":["https://example.com/deniz"]}]}"#
            return try JSONValue.object(["text": .string(response), "webSearchCalls": .number(1),
                "citations": .array([.object(["url": .string("https://example.com/deniz"), "title": .string("Profil")])])]).canonical()
        }
        let output = try await coordinator.run(job, source: source, memory: memory)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
        let plan = try PhoneAnalysisCommit(job: job, result: XCTUnwrap(output), source: source,
            memory: memory, expectedManifest: nil, now: now)
        XCTAssertEqual(plan.journal.kind, .note)
        XCTAssertEqual(plan.journal.key, source.key)
        XCTAssertTrue(plan.journal.isProfileResearch)
        XCTAssertFalse(plan.atlas.contains { $0.key.hasPrefix("note:companion/changes/") })
        XCTAssertEqual(try plan.journal.analysisJournal().payload.object?["daily_task"]?.object?["status"], .string("completed"))
        XCTAssertTrue(plan.memory.json.contains("https://example.com/deniz"))
    }

    func testClarificationReusesValidatedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = TaskInferenceCounter()
        let source = try WorkspaceFixture.record()
        let scope = try MemoryScope(projectID: "fixture", uid: "alice")
        let job = try PhoneAnalysisJob(scope: scope, accountID: "account", model: "fixture",
            source: source, memoryHash: WorkspaceHash.sha256("memory"), memoryContext: "", workContext: "")
        let coordinator = try PhoneTaskCoordinator(root: root) { _, _ in
            await counter.called()
            return #"{"action":"clarify","goal":"Profili araştır","reply":"Profil adresin nedir?","questions":["Profil adresin nedir?"]}"#
        }
        let first = try await coordinator.run(job, source: source)
        let second = try await coordinator.run(job, source: source)
        XCTAssertEqual(first?.validatedJSON, second?.validatedJSON)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(first?.validatedJSON)).object?["status"], .string("needs_input"))
    }

    func testInvalidRoutingOutputIsNotCachedForever() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = TaskInferenceCounter()
        let source = try WorkspaceFixture.record()
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"),
            accountID: "account", model: "fixture", source: source,
            memoryHash: WorkspaceHash.sha256("memory"), memoryContext: "", workContext: "")
        let coordinator = try PhoneTaskCoordinator(root: root) { _, _ in
            await counter.called()
            return #"{"invented":"route"}"#
        }
        for _ in 0..<2 {
            do { _ = try await coordinator.run(job, source: source); XCTFail("Invalid output must fail") }
            catch { XCTAssertTrue(error is AnalysisValidationFailure) }
        }
        let calls = await counter.count
        XCTAssertEqual(calls, 4, "Each explicit attempt permits at most one separate format repair")
    }

    func testRoutingContractFailureRepairsOnlyRouteAndReusesTheValidatedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = TaskInferenceCounter(), source = try WorkspaceFixture.record()
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"),
            accountID: "account", model: "fixture", source: source,
            memoryHash: WorkspaceHash.sha256("memory"), memoryContext: "", workContext: "")
        let coordinator = try PhoneTaskCoordinator(root: root) { _, prompt in
            await counter.called()
            if try JSONValue.parse(prompt).object?["usageStage"] == .string("taskRepair") {
                XCTAssertEqual(try JSONValue.parse(prompt).object?["webResearch"], .bool(false))
                return #"{"action":"diary","goal":"","reply":"","questions":[]}"#
            }
            return #"{"action":"diary","goal":"","reply":"","questions":["Nasıl hissettin?"]}"#
        }
        let first = try await coordinator.run(job, source: source)
        let second = try await coordinator.run(job, source: source)
        XCTAssertNil(first); XCTAssertNil(second)
        let calls = await counter.count
        XCTAssertEqual(calls, 2, "A valid repaired route is reused without another model request")
    }

    func testAgendaQuoteFailureGetsOneScopedRepairAndThenReusesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try WorkspaceFixture.record()
        let memory = try PortableMemory(json: AnalysisCore.invoke("emptyMemory", json: "{}"))
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"),
            accountID: "account", model: "fixture", source: source,
            memoryHash: memory.contentHash, memoryContext: "", workContext: "")
        let counter = TaskInferenceCounter()
        let coordinator = try PhoneTaskCoordinator(root: root) { _, prompt in
            await counter.called()
            switch try JSONValue.parse(prompt).object?["usageStage"]?.string {
            case "routeTask":
                return #"{"action":"manage","goal":"Ajandaya ekle","reply":"","questions":[]}"#
            case "executeTask":
                return #"{"status":"completed","reply":"Ajanda planı hazır.","findings":[],"operations":[{"tool":"agenda_create","quote":"Modelin özeti","title":"Plan","details":"","schedule":{"startDate":"2026-08-30","endDate":null,"time":null,"durationMinutes":null,"frequency":"daily","interval":1,"weekdays":[],"reminderMinutes":null,"timezone":"Europe/Istanbul"}}]}"#
            case "taskRepair":
                return #"{"quotes":["Eski metin"]}"#
            default:
                XCTFail("Unexpected inference stage")
                return "{}"
            }
        }
        let first = try await coordinator.run(job, source: source, memory: memory)
        let second = try await coordinator.run(job, source: source, memory: memory)
        XCTAssertEqual(first?.validatedJSON, second?.validatedJSON)
        let result = try JSONValue.parse(XCTUnwrap(first?.validatedJSON))
        XCTAssertEqual(result.object?["operations"]?.array?.first?.object?["quote"], .string("Eski metin"))
        let calls = await counter.count
        XCTAssertEqual(calls, 3, "One route, one execution and one evidence repair")
    }

    func testProviderFailureIsNeverRetriedAsAFormattingProblem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = TaskInferenceCounter(), source = try WorkspaceFixture.record()
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"),
            accountID: "account", model: "fixture", source: source,
            memoryHash: WorkspaceHash.sha256("memory"), memoryContext: "", workContext: "")
        let coordinator = try PhoneTaskCoordinator(root: root) { _, _ in
            await counter.called()
            throw URLError(.timedOut)
        }
        do { _ = try await coordinator.run(job, source: source); XCTFail("Expected provider failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testResearchFormatRepairKeepsOriginalSearchEvidenceAndNeverSearchesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = SocialProfile().replacingIntroduction("Adım Deniz. GitHub: deniz-dev")
        profile.researchAllowed = true
        let source = try ProfileResearchSource.make(profile: WorkspaceRecord.make(key: SocialProfile.key, kind: .note, payload: .string("fixture")),
            request: XCTUnwrap(profile.validated().researchRequest), date: "2026-11-17", now: "2026-11-17T08:00:00Z")
        let memory = try PortableMemory(json: AnalysisCore.invoke("emptyMemory", json: "{}"))
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"), accountID: "account", model: "fixture",
            source: source, memoryHash: memory.contentHash, memoryContext: "", workContext: "")
        let counter = TaskInferenceCounter()
        let response = #"{"status":"completed","reply":"Kaynaklı rapor.","findings":[{"label":"Profil","detail":"Açık yazılım portföyü.","urls":["https://example.com/deniz"]}]}"#
        let coordinator = try PhoneTaskCoordinator(root: root) { _, prompt in
            await counter.called()
            if try JSONValue.parse(prompt).object?["usageStage"] == .string("taskRepair") {
                XCTAssertEqual(try JSONValue.parse(prompt).object?["webResearch"], .bool(false))
                return response
            }
            return try JSONValue.object(["text": .string("```json\n" + response + "\n```"), "webSearchCalls": .number(1),
                "citations": .array([.object(["url": .string("https://example.com/deniz"), "title": .string("Profil")])])]).canonical()
        }
        let result = try await coordinator.run(job, source: source, memory: memory)
        let json = try JSONValue.parse(XCTUnwrap(result?.validatedJSON))
        XCTAssertEqual(json.object?["webSearchCalls"], .number(1))
        XCTAssertEqual(json.object?["sources"]?.array?.count, 1)
        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    func testMissingResearchEvidenceDoesNotTriggerAFormattingRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = SocialProfile().replacingIntroduction("GitHub: deniz-dev")
        profile.researchAllowed = true
        let source = try ProfileResearchSource.make(profile: WorkspaceRecord.make(key: SocialProfile.key, kind: .note, payload: .string("fixture")),
            request: XCTUnwrap(profile.validated().researchRequest), date: "2026-11-17", now: "2026-11-17T08:00:00Z")
        let memory = try PortableMemory(json: AnalysisCore.invoke("emptyMemory", json: "{}"))
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"), accountID: "account", model: "fixture",
            source: source, memoryHash: memory.contentHash, memoryContext: "", workContext: "")
        let counter = TaskInferenceCounter()
        let coordinator = try PhoneTaskCoordinator(root: root) { _, _ in
            await counter.called()
            return #"{"text":"{\"status\":\"completed\",\"reply\":\"Rapor\",\"findings\":[]}","webSearchCalls":0,"citations":[]}"#
        }
        do { _ = try await coordinator.run(job, source: source, memory: memory); XCTFail("Unsearched research must fail") }
        catch { XCTAssertEqual((error as? AnalysisValidationFailure)?.code, "research_sources_missing") }
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testDiaryDecisionReturnsToOriginalPipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try WorkspaceFixture.record()
        let job = try PhoneAnalysisJob(scope: MemoryScope(projectID: "fixture", uid: "alice"),
            accountID: "account", model: "fixture", source: source,
            memoryHash: WorkspaceHash.sha256("memory"), memoryContext: "", workContext: "")
        let coordinator = try PhoneTaskCoordinator(root: root) { _, _ in
            #"{"action":"diary","goal":"","reply":"","questions":[]}"#
        }
        let result = try await coordinator.run(job, source: source)
        XCTAssertNil(result)
    }
}
