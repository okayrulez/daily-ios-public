import Foundation

public struct CompanionCard: Codable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let withdrawn: Bool?
    public let id, kind, title, body, question: String
    public let sourceIds, nodeIds: [String]
    public let basis, basisKey, fingerprint, notBefore, expiresAt, createdAt: String
    public let deadlineId: String?
    public struct NotificationTiming: Codable, Sendable {
        public let reason, basis, sourceQuote: String
    }
    public let notification: NotificationTiming?
    public var journalDate: String? {
        let prefix = "journal_questions_"
        guard id.hasPrefix(prefix) else { return nil }
        let date = String(id.dropFirst(prefix.count))
        return WorkspaceIdentity.validDate(date) ? date : nil
    }
    public static func decode(_ record: WorkspaceRecord) throws -> CompanionCard {
        guard record.kind == .note, record.key.hasPrefix("note:companion/cards/"),
              let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        let card = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard card.schemaVersion == 1, validID(card.id), record.key == "note:companion/cards/\(card.id).md",
              ["checkin", "advice", "deadline", "pinned", "followup"].contains(card.kind), card.body.utf16.count <= 6000,
              card.question.utf16.count <= 2000, card.title.utf16.count <= 250,
              date(card.notBefore) != nil, date(card.expiresAt) != nil else { throw WorkspaceError.malformedRecord }
        return card
    }
    public static func validID(_ value: String) -> Bool { value.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) != nil }
    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
    public func state(events: [CompanionEvent], now: Date = Date()) -> String {
        if withdrawn == true { return "closed" }
        let mine = events.filter { $0.cardId == id }
        if mine.contains(where: { ["answer", "dismiss", "done"].contains($0.action) }) { return "closed" }
        if (Self.date(expiresAt) ?? .distantPast) <= now { return "expired" }
        return deliveryDate(events: events) > now ? "scheduled" : "ready"
    }
    public func deliveryDate(events: [CompanionEvent]) -> Date {
        let snooze = events.filter { $0.cardId == id && $0.action == "snooze" }.sorted { $0.at == $1.at ? $0.id > $1.id : $0.at > $1.at }.first
        return Self.date(snooze?.until ?? notBefore) ?? .distantPast
    }
}
public struct CompanionEvent: Codable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id, cardId, action, text, at: String
    public let until: String?
    public init(cardId: String, action: String, text: String = "", now: Date = Date()) throws {
        guard CompanionCard.validID(cardId), ["answer", "dismiss", "snooze", "done"].contains(action),
              text.utf16.count <= 10000, action != "answer" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              action == "answer" || text.isEmpty else { throw WorkspaceError.malformedRecord }
        schemaVersion = 1; id = UUID().uuidString.lowercased(); self.cardId = cardId; self.action = action; self.text = text
        at = CompanionCard.timestamp(now)
        // Next day at 10:00 Istanbul: avoid a reply at night producing a nighttime reminder.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        until = action == "snooze" ? CompanionCard.timestamp(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!) : nil
    }
    public static func decode(_ record: WorkspaceRecord) throws -> CompanionEvent {
        guard record.kind == .note, record.key.hasPrefix("note:companion/events/"),
              let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        let event = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard event.schemaVersion == 1, CompanionCard.validID(event.id), CompanionCard.validID(event.cardId),
              record.key == "note:companion/events/\(event.id).md", ["answer", "dismiss", "snooze", "done"].contains(event.action),
              CompanionCard.date(event.at) != nil, event.text.utf16.count <= 10000,
              event.action != "answer" || !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.action == "answer" || event.text.isEmpty,
              event.action == "snooze" ? (event.until.flatMap(CompanionCard.date) ?? .distantPast) > (CompanionCard.date(event.at) ?? .distantFuture) : event.until == nil
        else { throw WorkspaceError.malformedRecord }
        return event
    }
    public func record() throws -> WorkspaceRecord {
        let text = try JSONValue.object([
            "schemaVersion": .number(1), "id": .string(id), "cardId": .string(cardId),
            "action": .string(action), "text": .string(self.text), "at": .string(at),
            "until": until.map(JSONValue.string) ?? .null
        ]).canonical()
        return try WorkspaceRecord.make(key: "note:companion/events/\(id).md", kind: .note, payload: .string(text))
    }
}
