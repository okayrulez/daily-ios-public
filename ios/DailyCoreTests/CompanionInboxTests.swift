import XCTest
@testable import DailyCore
final class CompanionInboxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_222_400)
    func testAnswerRoundTripsWithExplicitNullAndBoundRecordIdentity() throws {
        let event = try CompanionEvent(cardId: "card_123", action: "answer", text: "Daha iyiyim.", now: now)
        let record = try event.record()
        let text = try XCTUnwrap(record.payload().string)
        XCTAssertEqual(try JSONValue.parse(text).object?["until"], .null)
        XCTAssertEqual(try CompanionEvent.decode(record).text, "Daha iyiyim.")
        let wrong = try WorkspaceRecord.make(key: "note:companion/events/other.md", kind: .note, payload: .string(text))
        XCTAssertThrowsError(try CompanionEvent.decode(wrong))
    }
    func testRejectsEmptyAnswersAndNonAnswerText() {
        XCTAssertThrowsError(try CompanionEvent(cardId: "card", action: "answer", text: "  "))
        XCTAssertThrowsError(try CompanionEvent(cardId: "card", action: "done", text: "injected"))
        XCTAssertThrowsError(try CompanionEvent(cardId: "../card", action: "dismiss"))
    }
    func testSnoozeIsFutureMorningInIstanbul() throws {
        let event = try CompanionEvent(cardId: "card", action: "snooze", now: now)
        let until = try XCTUnwrap(event.until.flatMap(CompanionCard.date))
        XCTAssertGreaterThan(until, now)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        XCTAssertEqual(calendar.component(.hour, from: until), 10)
    }
    func testTimedAndUntimedCardsRemainDistinctAfterSync() throws {
        let fields: [String: Any] = ["schemaVersion": 1, "id": "timed", "kind": "followup", "title": "Görüşme",
            "body": "Görüşme", "question": "Nasıl geçti?", "sourceIds": [], "nodeIds": [], "basis": "Yazın", "basisKey": "meeting",
            "fingerprint": "fp", "notBefore": "2026-09-26T16:30:00.000Z", "expiresAt": "2026-09-26T18:30:00.000Z", "createdAt": "2026-09-25T08:00:00.000Z"]
        func decode(_ fields: [String: Any]) throws -> CompanionCard {
            let text = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
            return try CompanionCard.decode(WorkspaceRecord.make(key: "note:companion/cards/timed.md", kind: .note, payload: .string(text)))
        }
        XCTAssertNil(try decode(fields).notification)
        var timed = fields
        timed["notification"] = ["reason": "Görüşme sonrasında", "basis": "inferred", "sourceQuote": "Yarın görüşmem var."]
        let card = try decode(timed)
        XCTAssertEqual(card.notification?.basis, "inferred")
        XCTAssertEqual(card.deliveryDate(events: []), CompanionCard.date("2026-09-26T16:30:00.000Z"))
    }
}

extension CompanionInboxTests {
    func testJournalNotificationRoutesOnlyAValidJournalDate() throws {
        func card(_ id: String) throws -> CompanionCard {
            let fields: [String: Any] = ["schemaVersion": 1, "id": id, "kind": "followup", "title": "Sorular",
                "body": "Sorular hazır", "question": "", "sourceIds": [], "nodeIds": [], "basis": "Günlük", "basisKey": "journal",
                "fingerprint": "fp", "notBefore": "2026-09-29T08:00:00.000Z", "expiresAt": "2026-10-06T08:00:00.000Z", "createdAt": "2026-09-29T08:00:00.000Z"]
            let text = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
            return try CompanionCard.decode(WorkspaceRecord.make(key: "note:companion/cards/\(id).md", kind: .note, payload: .string(text)))
        }
        XCTAssertEqual(try card("journal_questions_2026-09-29").journalDate, "2026-09-29")
        XCTAssertNil(try card("other_card").journalDate)
        XCTAssertNil(try card("journal_questions_2026-99-29").journalDate)
    }
}
