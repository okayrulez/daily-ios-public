import Foundation

public struct AgendaOccurrence: Decodable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let title: String
    public let details: String
    public let date: String
    public let time: String?
    public let frequency: String
    public let startsAt: String
    public let schedule: Schedule?

    public struct Schedule: Decodable, Sendable {
        public let durationMinutes: Int?
        public let reminderMinutes: Int?
        public let timezone: String
    }
}

public enum ManagedAgenda {
    public static let key = "note:companion/agenda.json"
    private static func document(_ record: WorkspaceRecord) throws -> JSONValue {
        guard record.key == key, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        return try JSONValue.parse(text)
    }
    public struct ApplePlan: Decodable, Sendable {
        public let id, title, details, status, sourceID: String
        public let excludedDates: [String]
        public let schedule: Schedule

        public struct Schedule: Decodable, Sendable {
            public let startDate, frequency, timezone: String
            public let endDate, time: String?
            public let interval: Int
            public let weekdays: [Int]
            public let durationMinutes, reminderMinutes: Int?
        }
    }

    public static func applePlans(_ record: WorkspaceRecord) throws -> [ApplePlan] {
        guard let entries = try document(record).object?["entries"]?.array else { throw WorkspaceError.malformedRecord }
        return try entries.map {
            try JSONDecoder().decode(ApplePlan.self, from: Data($0.canonical().utf8))
        }
    }

    public static func reminderSchedules(_ record: WorkspaceRecord?) -> [String: JSONValue] {
        guard let record, let entries = (try? document(record))?.object?["entries"]?.array else { return [:] }
        var schedules: [String: JSONValue] = [:]
        for entry in entries {
            guard let fields = entry.object, fields["status"] == .string("active"), let id = fields["id"]?.string,
                  let schedule = fields["schedule"], schedule.object?["reminderMinutes"]?.integer != nil else { continue }
            schedules[id] = schedule
        }
        return schedules
    }
    public static func upcoming(_ record: WorkspaceRecord, from: String, days: Int = 90) throws -> [AgendaOccurrence] {
        guard let entries = try document(record).object?["entries"] else { throw WorkspaceError.malformedRecord }
        let args = try JSONValue.object(["entries": entries, "from": .string(from), "days": .number(Double(days))]).canonical()
        return try JSONDecoder().decode([AgendaOccurrence].self, from: Data(AnalysisCore.invoke("agendaUpcoming", json: args).utf8))
    }
    public static func reminders(_ record: WorkspaceRecord, now: Date = Date()) throws -> [CompanionCard] {
        let args = try JSONValue.object(["agenda": document(record),
            "now": .string(ISO8601DateFormatter().string(from: now))]).canonical()
        return try JSONDecoder().decode([CompanionCard].self, from: Data(AnalysisCore.invoke("agendaCards", json: args).utf8))
    }

    /// Older workers defer overnight deliveries until 08:00. Use local delivery
    /// only when they cannot deliver that occurrence at all.
    public static func expiresBeforeLegacyPushWindow(_ card: CompanionCard) -> Bool {
        let calendar = JournalCalendar.calendar()
        guard let delivery = CompanionCard.date(card.notBefore), let expiry = CompanionCard.date(card.expiresAt) else { return false }
        let hour = calendar.component(.hour, from: delivery)
        guard hour < 8 || hour >= 22 else { return false }
        let day = calendar.startOfDay(for: delivery)
        guard let openingDay = calendar.date(byAdding: .day, value: hour >= 22 ? 1 : 0, to: day),
              let opening = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: openingDay) else { return false }
        return expiry <= opening
    }
}
