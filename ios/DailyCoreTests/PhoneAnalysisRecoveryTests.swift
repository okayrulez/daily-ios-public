import Foundation
import XCTest
@testable import DailyCore

private actor InferenceCounter {
    var count=0
    func reply(_ text: String) -> String { count+=1; return text }
}
private actor FormatRepairSequence {
    private var replies: [String]
    private(set) var calls = 0
    init(_ replies: [String]) { self.replies = replies }
    func next() -> String { let index = min(calls, replies.count - 1); calls += 1; return replies[index] }
}
@MainActor final class PhoneAnalysisRecoveryTests: XCTestCase {
    func testPhaseTimingsMeasureActualIntervalsOnce() async throws {
        let timings = AnalysisPhaseTimings()
        let start = DispatchTime.now()
        try await Task.sleep(for: .milliseconds(12))
        timings.record(.inference, since: start)
        let phases = Dictionary(uniqueKeysWithValues: timings.finish())
        XCTAssertEqual(phases.count, 4)
        XCTAssertGreaterThanOrEqual(phases[.inference] ?? 0, 10)
        XCTAssertEqual(phases[.commit], 0)
        XCTAssertTrue(timings.finish().isEmpty)
    }
    func testMalformedJournalIsRepairedOnceAndValidatedResultIsReused() async throws {
        let (scope,_,_,job) = try fixture(), valid = try output()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sequence = FormatRepairSequence(["```json\n{}\n```", valid])
        let coordinator = try PhoneAnalysisCoordinator(root: root) { _,_ in await sequence.next() }
        await coordinator.activate(scope: scope, accountID: "chatgpt-A")
        let first = try await coordinator.run(job), second = try await coordinator.run(job)
        XCTAssertEqual(first.contentHash, second.contentHash)
        let calls = await sequence.calls
        XCTAssertEqual(calls, 2)
    }
    func testUnsupportedJournalQuoteReceivesOnePatchAndCheckpointIsReused() async throws {
        let (scope,_,_,job) = try fixture()
        let original = try output().replacingOccurrences(of: "Eski metin", with: "Unsupported words")
        let sequence = FormatRepairSequence([original, #"{"quotes":["Eski metin"]}"#])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try PhoneAnalysisCoordinator(root: root) { _,_ in await sequence.next() }
        await coordinator.activate(scope: scope, accountID: job.accountID)
        let first = try await coordinator.run(job)
        let second = try await coordinator.run(job)
        XCTAssertFalse(first.validatedJSON.contains("Unsupported words"))
        XCTAssertEqual(first.contentHash, second.contentHash)
        let calls = await sequence.calls
        XCTAssertEqual(calls, 2)
    }
    func testSecondInvalidJournalResponseStopsInsteadOfLooping() async throws {
        let (scope,_,_,job) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try output()
        let sequence = FormatRepairSequence(["not json", "still not json", valid])
        let coordinator = try PhoneAnalysisCoordinator(root: root) { _,_ in await sequence.next() }
        await coordinator.activate(scope: scope, accountID: "chatgpt-A")
        do { _ = try await coordinator.run(job); XCTFail("Invalid repair must not be committed") } catch {}
        let calls = await sequence.calls
        XCTAssertEqual(calls, 2)
        let result = try await coordinator.run(job)
        let totalCalls = await sequence.calls
        XCTAssertEqual(totalCalls, 3, "Manual retry must use a fresh response")
        XCTAssertNotNil(try JSONValue.parse(result.validatedJSON).object?["reflection"]?.string)
    }
    private func output() throws -> String {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"analysis-fixture",withExtension:"json"))
        return try String(contentsOf:url,encoding:.utf8)
    }
    private func fixture() throws -> (MemoryScope,WorkspaceRecord,PortableMemory,PhoneAnalysisJob) {
        let scope=try MemoryScope(projectID:"dailyx-test",uid:"alice")
        let source=try WorkspaceFixture.record()
        let memory=try PortableMemory(json:AnalysisCore.invoke("emptyMemory",json:"{}"))
        let job=try PhoneAnalysisJob(scope:scope,accountID:"chatgpt-A",model:"fixture",source:source,
            memoryHash:memory.contentHash,memoryContext:"",workContext:"")
        return (scope,source,memory,job)
    }
    func testCheckpointAndOutboxResumeWithoutCallingModelAgain() async throws {
        let (scope,source,memory,job)=try fixture(),text=try output()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let counter=InferenceCounter()
        let coordinator=try PhoneAnalysisCoordinator(root:root.appendingPathComponent("results")) { _,_ in await counter.reply(text) }
        await coordinator.activate(scope:scope,accountID:"chatgpt-A")
        let first=try await coordinator.run(job),second=try await coordinator.run(job)
        let calls=await counter.count
        XCTAssertEqual(calls,1);XCTAssertEqual(first.contentHash,second.contentHash)
        let plan=try PhoneAnalysisCommit(job:job,result:first,source:source,memory:memory,expectedManifest:nil,now:first.createdAt)
        XCTAssertTrue(plan.chunks.isEmpty) // Full archive remains on the phone by default.
        XCTAssertEqual(try plan.journal.journal().questions.count,8)
        XCTAssertEqual(plan.changes?.questions,8)
        XCTAssertGreaterThan(try XCTUnwrap(plan.changes).newNotes,0)
        // Existing pending results must remain readable after the summary field is introduced.
        let encoded=try JSONEncoder().encode(plan)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        legacy.removeValue(forKey:"changes")
        let restored=try JSONDecoder().decode(PhoneAnalysisCommit.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(restored.changes)
        XCTAssertEqual(restored.receipt,plan.receipt)
        XCTAssertEqual(plan.memory.sourceCount,1)
        let outbox=try PhoneAnalysisOutbox(root:root.appendingPathComponent("outbox"))
        try await outbox.save(plan,scope:scope);try await outbox.save(plan,scope:scope)
        let reopened=try PhoneAnalysisOutbox(root:root.appendingPathComponent("outbox"))
        let pending=try await reopened.load(scope:scope)
        XCTAssertEqual(pending?.receipt,plan.receipt)
        XCTAssertEqual(pending?.changes?.newNotes,plan.changes?.newNotes)
        let other=try MemoryScope(projectID:"dailyx-test",uid:"bob")
        let none=try await reopened.load(scope:other);XCTAssertNil(none)
        try await reopened.remove(jobID:job.id,scope:scope)
        let removed=try await reopened.load(scope:scope);XCTAssertNil(removed)
    }
    func testSuppressedQuestionsCannotReenterTheSavedQueueAndReceiptIsDurable() async throws {
        let (scope,source,memory,job)=try fixture(),text=try output()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let coordinator=try PhoneAnalysisCoordinator(root:root){_,_ in text}
        await coordinator.activate(scope:scope,accountID:"chatgpt-A")
        let result=try await coordinator.run(job)
        let raw=try JSONValue.parse(result.validatedJSON)
        let prompts=(raw.object?["open_questions"]?.array ?? [])+(raw.object?["boolean_questions"]?.array ?? [])
        let known=prompts.compactMap{$0.object?["prompt"]?.string}
        let plan=try PhoneAnalysisCommit(job:job,result:result,source:source,memory:memory,expectedManifest:nil,now:result.createdAt,uploadMemory:true,suppressedQuestionPrompts:known)
        XCTAssertEqual(try plan.journal.journal().questions.count,0)
        XCTAssertFalse(plan.atlas.contains(where:{$0.key.hasPrefix("note:companion/cards/journal_questions_")}))
        let receipts=plan.atlas.compactMap{try? WorkspaceChangeReceipt.decode($0)}
        XCTAssertEqual(receipts.count,1)
        XCTAssertEqual(receipts.first?.resultHash,plan.journal.hash)
        XCTAssertEqual(receipts.first?.sourceHash,source.hash)
        XCTAssertEqual(receipts.first?.changes.questions,0)
    }
    func testExplicitCloudChunksRoundTripAndRejectTamper() async throws {
        let (scope,source,memory,job)=try fixture(),text=try output()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let coordinator=try PhoneAnalysisCoordinator(root:root) { _,_ in text }
        await coordinator.activate(scope:scope,accountID:"chatgpt-A")
        let result=try await coordinator.run(job)
        let plan=try PhoneAnalysisCommit(job:job,result:result,source:source,memory:memory,expectedManifest:nil,now:result.createdAt,uploadMemory:true)
        XCTAssertEqual(try PhoneAnalysisCommit.decodeMemory(manifest:plan.manifest,chunks:plan.chunks).contentHash,plan.memory.contentHash)
        XCTAssertThrowsError(try PhoneAnalysisCommit.decodeMemory(manifest:plan.manifest,chunks:[]))
        let changed=try WorkspaceSavePlanner.plan(current:source,expectedHash:source.hash,date:"2026-08-30",
            text:"Yeni metin",answers:[:],now:"2026-08-30T12:00:00Z",newID:"unused").record
        XCTAssertThrowsError(try PhoneAnalysisCommit(job:job,result:result,source:changed,memory:memory,expectedManifest:nil,now:result.createdAt))
    }
    func testAccountChangeCancelsAndNeverPersistsOldResult() async throws {
        let (scope,_,_,job)=try fixture(),text=try output()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let coordinator=try PhoneAnalysisCoordinator(root:root) { _,_ in
            try await Task.sleep(for:.seconds(30));return text
        }
        await coordinator.activate(scope:scope,accountID:"chatgpt-A")
        let run=Task { try await coordinator.run(job) }
        await Task.yield()
        await coordinator.activate(scope:scope,accountID:"chatgpt-B")
        do { _ = try await run.value;XCTFail("Old account result accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(job.id+".json").path))
    }
    func testCompanionReplyKeepsOriginalTextAndUsesIstanbulDate() throws {
        let at=try XCTUnwrap(CompanionCard.date("2026-08-29T22:30:00Z"))
        let event=try CompanionEvent(cardId:"followup",action:"answer",text:"Yanıtım",now:at)
        let cardText=#"{"schemaVersion":1,"withdrawn":false,"id":"followup","kind":"followup","title":"Takip","body":"Takip","question":"Nasıldı?","sourceIds":[],"nodeIds":[],"basis":"","basisKey":"f","fingerprint":"f","notBefore":"2026-08-29T10:00:00Z","expiresAt":"2026-08-31T10:00:00Z","createdAt":"2026-08-29T10:00:00Z","deadlineId":null,"notification":null}"#
        let card=try CompanionCard.decode(WorkspaceRecord.make(key:"note:companion/cards/followup.md",kind:.note,payload:.string(cardText)))
        XCTAssertEqual(try CompanionReplyPlanner.date(event),"2026-08-30")
        let old=try WorkspaceFixture.record()
        let next=try CompanionReplyPlanner.plan(current:old,card:card,event:event)
        XCTAssertEqual(try next.journal().rawText,"Eski metin")
        XCTAssertEqual(try next.payload().object?["supplemental_answers"]?.array?.count,1)
        XCTAssertEqual(try CompanionReplyPlanner.plan(current:next,card:card,event:event),next)
    }
}
