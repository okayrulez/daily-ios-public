import Foundation
import XCTest
@testable import DailyCore

private actor CrossMapReplies {
    private var replies: [String]
    private(set) var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func next(_ prompt: String) throws -> String {
        prompts.append(prompt)
        guard !replies.isEmpty else { throw PhoneAnalysisError.invalidCheckpoint }
        return replies.removeFirst()
    }
}

@MainActor final class CrossMapRepairTests: XCTestCase {
    private let valid = #"{"insights":[],"retirements":[],"map_review":{"summary":"Seçili dallar denetlendi.","findings":[]}}"#
    private let malformed = #"{"insights":[{"topic_path":["Ortak"],"key":"rest","observation":"İki kaynak","supports":[{"node_id":"n0","source_id":"s0"},{"node_id":"n1","source_id":"s1"}]}],"retirements":[]}"#

    private func fixture() throws -> (MemoryScope, PortableMemory) {
        let sources: [[String: Any]] = (0..<5).map { i in
            ["id":"s\(i)", "kind":"journal", "title":"Günlük", "date":"2026-09-30",
             "text":"Kaynak \(i)", "revision":1, "createdAt":"2026-09-30T09:00:00Z",
             "updatedAt":"2026-09-30T09:00:00Z", "status":"complete", "error":NSNull(),
             "analysis":NSNull(), "answers":[], "warnings":[]]
        }
        let nodes: [[String: Any]] = (0..<2).map { i in
            ["id":"n\(i)", "key":"k\(i)", "label":"Not", "topicId":"t\(i)",
             "topicPath":["Konu \(i)"], "scope":"personal", "status":"observation", "corrections":[],
             "evidence":[["sourceId":"s\(i)", "date":"2026-09-30", "title":"Günlük",
                           "quote":"Kaynak \(i)", "observation":"Not", "nature":"observation"]]]
        }
        let topics: [[String: Any]] = (0..<2).map { i in
            ["id":"t\(i)", "path":["Konu \(i)"], "count":1, "sourceCount":1]
        }
        let object: [String: Any] = ["schemaVersion":1,"revision":1,"sources":sources,
            "graph":["topics":topics,"nodes":nodes,"edges":[]],"deadlines":[],
            "routing":["version":1,"bindings":[:]],
            "mapReview":["journalIds":(0..<5).map { "s\($0)" },"lastAttemptCount":0,"status":"waiting","reviewedFingerprints":[:]]]
        let memory = try PortableMemory(json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        let scope = try MemoryScope(projectID:"dailyx-test",uid:"alice")
        return (scope,memory)
    }

    func testMalformedResponseIsRepairedOnceAndCached() async throws {
        let (scope,memory) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let replies = CrossMapReplies([malformed,valid])
        let coordinator = try PhoneAnalysisCoordinator(root:root) { _,prompt in try await replies.next(prompt) }
        await coordinator.activate(scope:scope,accountID:"account")
        let first = try await coordinator.crossMap(scope: scope, accountID: "account", model: "fixture", memory: memory)
        let cached = try await coordinator.crossMap(scope: scope, accountID: "account", model: "fixture", memory: memory)
        XCTAssertEqual(first,cached)
        let prompts = await replies.prompts
        XCTAssertEqual(prompts.count,2)
        XCTAssertTrue(prompts[1].contains("rejected_output"))
    }

    func testBrokenJSONIsRepairedOnce() async throws {
        let (scope,memory) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let replies = CrossMapReplies(["{broken",valid])
        let coordinator = try PhoneAnalysisCoordinator(root:root) { _,prompt in try await replies.next(prompt) }
        await coordinator.activate(scope:scope,accountID:"account")
        _ = try await coordinator.crossMap(scope: scope, accountID: "account", model: "fixture", memory: memory)
        let prompts = await replies.prompts
        XCTAssertEqual(prompts.count,2)
        XCTAssertTrue(prompts[1].contains("invalid_json"))
    }

    func testMissingReorganizationReasonRequestsTargetedRepair() async throws {
        let (scope,memory) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let missingReason = #"{"insights":[{"topic_path":["Ortak"],"key":"rest","label":"Mola","observation":"İki kaynak","supports":[{"node_id":"n0","source_id":"s0"},{"node_id":"n1","source_id":"s1"}],"replaces":["old-inference"]}],"retirements":[],"map_review":{"summary":"Seçili dallar denetlendi.","findings":[]}}"#
        let replies = CrossMapReplies([missingReason,valid])
        let coordinator = try PhoneAnalysisCoordinator(root:root) { _,prompt in try await replies.next(prompt) }
        await coordinator.activate(scope:scope,accountID:"account")
        _ = try await coordinator.crossMap(scope: scope, accountID: "account", model: "fixture", memory: memory)
        let prompts = await replies.prompts
        XCTAssertEqual(prompts.count,2)
        XCTAssertTrue(prompts[1].contains("missing_reorganization_reason"))
    }

    func testSecondMalformedResponseFailsWithoutAnotherRetryOrCheckpoint() async throws {
        let (scope,memory) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let replies = CrossMapReplies([malformed,malformed])
        let coordinator = try PhoneAnalysisCoordinator(root:root) { _,prompt in try await replies.next(prompt) }
        await coordinator.activate(scope:scope,accountID:"account")
        do {
            _ = try await coordinator.crossMap(scope: scope, accountID: "account", model: "fixture", memory: memory)
            XCTFail("Still-invalid result must not be accepted")
        } catch let failure as AnalysisValidationFailure {
            XCTAssertEqual(failure.command,"validateCrossMap")
            XCTAssertEqual(failure.code,"schema_validation")
        }
        let prompts = await replies.prompts
        XCTAssertEqual(prompts.count,2)
        // Preparing a run creates the account-scoped directory, not a saved result.
        // Invalid output must leave that directory empty and no legacy root checkpoint.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path), [scope.storageIdentity])
        let directory = root.appendingPathComponent(scope.storageIdentity, isDirectory:true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty)
    }
}
