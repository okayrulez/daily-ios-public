import XCTest
@testable import DailyCore

final class AnalysisPromptConfigurationTests: XCTestCase {
    func testSeparateTaskConfigPreservesDiaryAndTaskContract() throws {
        let diary = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"diary-v1","enabled":true,"instructions":{"journal":"Diary only"}}"#)
        let config = try diary.addingTaskInstructions(json: #"{"schemaVersion":1,"revision":"task-v1","enabled":true,"instructions":{"routeTask":"Continue the user task"}}"#)
        XCTAssertEqual(try diary.applying(to: prepared, stage: "journal"), try config.applying(to: prepared, stage: "journal"))
        let result = try JSONValue.parse(config.applying(to: prepared, stage: "routeTask")).object
        XCTAssertTrue(result?["instructions"]?.string?.contains("original") == true)
        XCTAssertTrue(result?["instructions"]?.string?.contains("Continue the user task") == true)
        XCTAssertEqual(result?["input"], try JSONValue.parse(prepared).object?["input"])
        XCTAssertNotEqual(diary.fingerprint, config.fingerprint)
        XCTAssertThrowsError(try diary.addingTaskInstructions(json: #"{"schemaVersion":1,"revision":"bad","enabled":true,"instructions":{"journal":"Unexpected"}}"#))
    }
    private let prepared = #"{"instructions":"original","input":[{"role":"user","content":"source and schema"}],"base":{"reflection":"keep"}}"#

    func testOverridePreservesSourceAndRepairBase() throws {
        let config = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v2","enabled":true,"instructions":{"journal":"Brief Turkish analysis"}}"#)
        let value = try JSONValue.parse(config.applying(to: prepared, stage: "journal")).object
        XCTAssertTrue(value?["instructions"]?.string?.hasPrefix("Brief Turkish analysis") == true)
        XCTAssertEqual(value?["input"], try JSONValue.parse(prepared).object?["input"])
        XCTAssertEqual(value?["base"], try JSONValue.parse(prepared).object?["base"])
        let unchanged = try JSONValue.parse(config.applying(to:prepared,stage:"crossMap")).object
        XCTAssertEqual(unchanged?["instructions"], .string("original"))
        XCTAssertEqual(unchanged?["usageStage"], .string("crossMap"))
    }

    func testJournalOverrideKeepsEmotionAndReminderContract() throws {
        let config = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v3","enabled":true,"instructions":{"journal":"Personal guidance"}}"#)
        let original = #"{"instructions":"emotional_memory must be grounded; reminder_proposal requires explicit consent","input":[{"role":"user","content":"source"}]}"#
        let result = try JSONValue.parse(config.applying(to: original, stage: "journal")).object
        let instructions = try XCTUnwrap(result?["instructions"]?.string)
        XCTAssertTrue(instructions.contains("Personal guidance"))
        XCTAssertTrue(instructions.contains("emotional_memory must be grounded"))
        XCTAssertTrue(instructions.contains("reminder_proposal requires explicit consent"))
        XCTAssertEqual(result?["input"], try JSONValue.parse(original).object?["input"])
    }

    func testDisabledConfigurationRestoresBundledBehavior() throws {
        let config = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"rollback","enabled":false,"instructions":{"journal":"ignored"}}"#)
        XCTAssertEqual(config.revision, "bundled")
        XCTAssertEqual(config.fingerprint, "bundled")
        let bundled = try JSONValue.parse(config.applying(to:prepared,stage:"journal")).object
        XCTAssertEqual(bundled?["instructions"], .string("original"))
        XCTAssertEqual(bundled?["usageStage"], .string("journal"))
    }
    func testCrossMapSchemaCannotBeLostWhenOverridingInstructions() throws {
        let config = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v1","enabled":true,"instructions":{"crossMap":"New guidance"}}"#)
        let source = #"{"instructions":"Old guidance\nOUTPUT_JSON_SCHEMA={\"type\":\"object\"}","input":[]}"#
        let result = try JSONValue.parse(config.applying(to: source, stage: "crossMap")).object
        XCTAssertTrue(result?["instructions"]?.string?.contains(#"OUTPUT_JSON_SCHEMA={"type":"object"}"#) == true)
    }

    func testChangesInvalidateCheckpointsEvenWithoutRevisionBump() throws {
        let first = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v1","enabled":true,"instructions":{"crossMap":"First"}}"#)
        let second = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v1","enabled":true,"instructions":{"crossMap":"Second"}}"#)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testRejectsBadVersionUnknownStageAndEmptyInstructions() {
        for json in [
            #"{"schemaVersion":2,"revision":"v1","enabled":true,"instructions":{}}"#,
            #"{"schemaVersion":1,"revision":"v1","enabled":true,"instructions":{"typo":"text"}}"#,
            #"{"schemaVersion":1,"revision":"v1","enabled":true,"instructions":{"journal":" "}}"#
        ] { XCTAssertThrowsError(try AnalysisPromptConfiguration(json: json)) }
    }
    func testJobIdentityIncludesPromptsForLaterStages() throws {
        let scope = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let source = try WorkspaceFixture.record()
        let memoryHash = WorkspaceHash.sha256("memory")
        let override = try AnalysisPromptConfiguration(json: #"{"schemaVersion":1,"revision":"v2","enabled":true,"instructions":{"crossMap":"Updated synthesis"}}"#)
        let original = try PhoneAnalysisJob(scope: scope, accountID: "account", model: "fixture",
            source: source, memoryHash: memoryHash, memoryContext: "", workContext: "")
        let updated = try PhoneAnalysisJob(scope: scope, accountID: "account", model: "fixture",
            source: source, memoryHash: memoryHash, memoryContext: "", workContext: "", prompts: override)
        XCTAssertEqual(original.preparedJSON, updated.preparedJSON)
        XCTAssertNotEqual(original.id, updated.id)
    }
}
