#if DEBUG
import Foundation
import DailyCore

@MainActor
enum AgendaPreview {
    static func records() throws -> [WorkspaceRecord] {
        let calendar = JournalCalendar.calendar()
        let today = JournalCalendar.key(Date())
        let now = ISO8601DateFormatter().string(from: Date())
        let samples = [(0, "Sabah yürüyüşü", "08:30"), (0, "Proje çalışması", "14:00"),
                       (0, "Akşam okuması", "20:00"), (2, "Arkadaşlarla buluşma", "19:00"),
                       (5, "Haftalık plan", "10:00"), (5, "Spor", "18:00")]
        let entries = samples.enumerated().map { index, sample in
            let date = JournalCalendar.key(calendar.date(byAdding: .day, value: sample.0, to: Date())!)
            return JSONValue.object([
                "id": .string("preview_event_\(index)"), "title": .string(sample.1),
                "details": .string("Ajandaya kaydedilmiş örnek aktivite."), "status": .string("active"),
                "excludedDates": .array([]), "sourceQuote": .string("Bu aktiviteyi ajandama ekle."),
                "sourceID": .string("preview-journal-\(today)"), "createdAt": .string(now), "updatedAt": .string(now),
                "revision": .number(1), "schedule": .object([
                    "startDate": .string(date), "endDate": .null, "time": .string(sample.2),
                    "durationMinutes": .number(60), "frequency": .string("once"), "interval": .number(1),
                    "weekdays": .array([]), "reminderMinutes": .number(30), "timezone": .string("Europe/Istanbul")
                ])
            ])
        }
        let agenda = try WorkspaceRecord.make(key: ManagedAgenda.key, kind: .note,
            payload: .string(try JSONValue.object(["schemaVersion": .number(1), "entries": .array(entries)]).canonical()))
        return try QuestionsPreview.records() + [agenda]
    }
}
#endif
