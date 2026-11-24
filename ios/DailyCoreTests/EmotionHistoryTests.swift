import XCTest
@testable import DailyCore

final class EmotionHistoryTests: XCTestCase {
    private let raw = "Önce gerildim, sonra rahatladım."
    private func record(date: String = "2026-11-06", emotional: JSONValue? = nil,
                        correction: JSONValue? = nil, result: JSONValue = .object([:])) throws -> WorkspaceRecord {
        var root: [String: JSONValue] = [
            "entry": .object(["id": .string("journal-" + date), "local_date": .string(date),
                "raw_text": .string(raw), "content_hash": .string(WorkspaceHash.sha256(raw)),
                "saved_at": .string(date + "T10:00:00Z"), "analysis_status": .string("complete"), "analysis_error": .null]),
            "questions": .array([]),
            "analyses": .array([.object(["id": .string("analysis-" + date), "journal_id": .string("journal-" + date),
                "version": .number(1), "provider": .string("fixture"), "reflection": .string("Gün içindeki değişim"),
                "confidence": .string("medium"), "created_at": .string(date + "T10:01:00Z"), "result": result])])
        ]
        root["emotional_memory"] = emotional
        root["emotion_override"] = correction
        return try WorkspaceRecord.make(key: "journal:" + date, kind: .journal, payload: .object(root))
    }
    private var observation: JSONValue {
        .object(["key": .string("tension"), "label": .string("Gerilim"), "intensity": .number(4),
            "event": .string("Sunum öncesi"), "quote": .string("Önce gerildim"), "sequence": .number(0)])
    }
    func testDuplicateSourceIDsAcrossDaysDoNotCrashTheEmotionProjection() throws {
        let first = try record(emotional: .object(["observations": .array([observation])]))
        let second = try record(date: "2026-11-07", emotional: .object(["observations": .array([observation])]))
        var fields = try second.payload().object!
        var entry = fields["entry"]!.object!
        let sharedID = try first.journal().id
        entry["id"] = .string(sharedID); fields["entry"] = .object(entry)
        var analysis = fields["analyses"]!.array![0].object!
        analysis["journal_id"] = .string(sharedID); fields["analyses"] = .array([.object(analysis)])
        let duplicate = try WorkspaceRecord.make(key: second.key, kind: .journal, payload: .object(fields))
        let days = EmotionHistory.days(records: [first, duplicate])
        XCTAssertEqual(days.map(\.date), ["2026-11-06", "2026-11-07"])
        XCTAssertTrue(days.allSatisfy { $0.connections.isEmpty })
    }
    func testTargetedCorrectionPreservesOtherEventsAndAIOriginal() throws {
        let id = EmotionObservation.identity(key: "tension", quote: "Önce gerildim", sequence: 0)
        XCTAssertEqual(id, "60f1e4b5a93de88dd886479107ad17136dd6f57e178245d40b1dabce3abf8e5d")
        let relief = JSONValue.object(["key": .string("relief"), "label": .string("Rahatlama"),
            "quote": .string("sonra rahatladım"), "event": .string("Sunum sonrası"), "sequence": .number(1)])
        let original = try record(emotional: .object(["observations": .array([observation, relief])]))
        var payload = try original.journal().payload.object!
        payload["emotion_observation_overrides"] = .object(["source_hash": .string(WorkspaceHash.sha256(raw)),
            "edits": .array([.object(["observation_id": .string(id), "original_key": .string("tension"),
                "quote": .string("Önce gerildim"), "sequence": .number(0), "choices": .array([.string("excitement")])])])])
        let saved = try WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(payload))
        let day = try XCTUnwrap(EmotionHistory.days(records: [saved]).first)
        XCTAssertEqual(day.observations.map(\.key), ["excitement", "relief"])
        XCTAssertEqual(day.observations.map(\.sequence), [0, 1])
        XCTAssertEqual(day.observations.first?.originalKey, "tension")
        XCTAssertNil(day.observations.first?.intensity)
        XCTAssertEqual(day.originalObservations.first?.key, "tension")
        XCTAssertFalse(day.observations[1].userSelected)
    }
    func testCalendarConsentDoesNotReplaceChronology() throws {
        let original = try record(emotional: .object(["observations": .array([observation])]))
        var payload = try original.journal().payload.object!
        payload["emotion_calendar_override"] = .object(["source_hash": .string(WorkspaceHash.sha256(raw)), "choices": .array([.string("hope")])])
        let day = try XCTUnwrap(EmotionHistory.days(records: [WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(payload))]).first)
        XCTAssertEqual(day.keys, ["hope"])
        XCTAssertEqual(day.observations.first?.key, "tension")
        XCTAssertEqual(day.observations.first?.quote, "Önce gerildim")
    }
    func testReadsCompletedChronologyAndSourceQuote() throws {
        let memory = JSONValue.object(["observations": .array([observation]), "helpful": .array([]),
            "source_hash": .string(WorkspaceHash.sha256(raw))])
        let days = EmotionHistory.days(records: [try record(emotional: memory)])
        XCTAssertEqual(days.first?.keys, ["tension"])
        XCTAssertEqual(days.first?.observations.first?.quote, "Önce gerildim")
        XCTAssertEqual(days.first?.observations.first?.intensity, 4)
    }
    func testStaleSourceAndInventedQuotesDoNotAppear() throws {
        let stale = JSONValue.object(["observations": .array([observation]), "source_hash": .string("stale")])
        XCTAssertTrue(EmotionHistory.days(records: [try record(emotional: stale)]).isEmpty)
        var invalid = observation.object!
        invalid["quote"] = .string("Böyle bir şey söylemedim")
        let memory = JSONValue.object(["observations": .array([.object(invalid)])])
        XCTAssertTrue(EmotionHistory.days(records: [try record(emotional: memory)]).first?.observations.isEmpty == true)
    }
    func testUserSelectionAndBlankSelectionOverrideAI() throws {
        let memory = JSONValue.object(["observations": .array([observation])])
        let correction = JSONValue.object(["source_hash": .string(WorkspaceHash.sha256(raw)),
            "choices": .array([.string("calm"), .string("hope")])])
        let day = try XCTUnwrap(EmotionHistory.days(records: [try record(emotional: memory, correction: correction)]).first)
        XCTAssertEqual(day.keys, ["calm", "hope"])
        XCTAssertTrue(day.userSelected)
        XCTAssertEqual(Set(day.observations.map(\.sequence)), [0])
        let empty = JSONValue.object(["source_hash": .string(WorkspaceHash.sha256(raw)), "choices": .array([])])
        XCTAssertTrue(EmotionHistory.days(records: [try record(emotional: memory, correction: empty)]).first?.keys.isEmpty == true)
    }
    func testOldEmotionsHaveNoInventedChronologyOrQuotes() throws {
        let legacy = JSONValue.object(["emotions": .array([
            .object(["key": .string("kaygi"), "label": .string("Kaygı"), "intensity": .number(3), "evidence_ref": .string("journal-id")]),
            .object(["key": .string("huzur"), "label": .string("Huzur"), "intensity": .number(2)])
        ])])
        let day = try XCTUnwrap(EmotionHistory.days(records: [try record(result: legacy)]).first)
        XCTAssertEqual(Set(day.keys), ["anxiety", "calm"])
        XCTAssertEqual(Set(day.observations.map(\.sequence)), [0])
        XCTAssertTrue(day.observations.allSatisfy { $0.quote.isEmpty })
    }
    func testOnlyExistingEarlierJournalConnectionsAreDisplayed() throws {
        let links = JSONValue.object(["connections": .array([
            .object(["target_journal_id": .string("journal-2026-11-05"), "target_date": .string("2026-11-05"), "reason": .string("Benzer deneyim")]),
            .object(["target_journal_id": .string("missing"), "target_date": .string("2026-11-04"), "reason": .string("Uydurma")])
        ])])
        let days = EmotionHistory.days(records: [try record(result: links), try record(date: "2026-11-05")])
        XCTAssertEqual(days.last?.connections.map(\.date), ["2026-11-05"])
    }
    func testDefinitionAliasesHaveStableIdentity() {
        XCTAssertEqual(EmotionDefinition.canonical("gerilim"), "tension")
        XCTAssertEqual(EmotionDefinition.canonical("relief"), "relief")
        XCTAssertEqual(EmotionDefinition.find("heyecan")?.emoji, "🤩")
    }
}
