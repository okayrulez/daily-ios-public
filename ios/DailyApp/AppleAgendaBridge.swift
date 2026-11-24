import AlarmKit
import DailyCore
@preconcurrency import EventKit
import SwiftUI

@available(iOS 26.0, *)
private struct DailyAlarmMetadata: AlarmMetadata {}

@MainActor
final class AppleAgendaBridge {
    static let shared = AppleAgendaBridge()
    private let store = EKEventStore()

    struct Result: Equatable {
        let message: String
        let saved: Bool
    }

    private struct Receipt: Codable {
        let destination: String
        let identifier: String
        let signature: String
        let hasAlert: Bool
    }

    enum Failure: LocalizedError {
        case permission, target, requiresTime, unsupportedRepeat, unsupportedOS, alarmCancellation
        var errorDescription: String? {
            switch self {
            case .permission: String(localized: "Apple izni kapalı. iPhone Ayarları’ndan izin verebilirsin.")
            case .target: String(localized: "Yazılabilir bir Takvim veya Anımsatıcılar listesi bulunamadı.")
            case .requiresTime: String(localized: "Alarm için gelecekte bir tarih ve saat gerekiyor.")
            case .unsupportedRepeat: String(localized: "Bu tekrar düzeni Apple’a aktarılamadı.")
            case .unsupportedOS: String(localized: "iPhone alarmı için iOS 26 veya üzeri gerekiyor.")
            case .alarmCancellation: String(localized: "Çalışma alanının iPhone alarmları kaldırılamadı. Tekrar dene.")
            }
        }
    }

    private func key(_ scope: String) -> String {
        "daily-approved-apple-plans-" + WorkspaceHash.sha256(scope)
    }

    private func receipts(_ scope: String) -> [String: Receipt] {
        guard let data = UserDefaults.standard.data(forKey: key(scope)) else { return [:] }
        return (try? JSONDecoder().decode([String: Receipt].self, from: data)) ?? [:]
    }

    private func storeReceipts(_ receipts: [String: Receipt], scope: String) {
        if let data = try? JSONEncoder().encode(receipts) {
            UserDefaults.standard.set(data, forKey: key(scope))
        }
    }

    private func approvalsKey(_ scope: String) -> String { key(scope) + "-approved" }

    private func approvedDestinations(scope: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: approvalsKey(scope))?.compactMapValues { $0 as? String } ?? [:]
    }

    func applyApprovals(_ destinations: [String: String], revoking revoked: [String], scope: String) {
        var approved = approvedDestinations(scope: scope)
        for id in revoked { approved.removeValue(forKey: id) }
        approved.merge(destinations) { _, new in new }
        UserDefaults.standard.set(approved, forKey: approvalsKey(scope))
    }

    func hasWork(scope: String) -> Bool { !approvedDestinations(scope: scope).isEmpty || !receipts(scope).isEmpty }

    func coveredEvents(scope: String, agenda: WorkspaceRecord?) -> Set<String> {
        let saved = receipts(scope).filter { $0.value.hasAlert }
        guard !saved.isEmpty, let agenda, let plans = try? ManagedAgenda.applePlans(agenda) else { return [] }
        let approved = approvedDestinations(scope: scope)
        return Set(plans.compactMap { plan in
            guard plan.status == "active", let receipt = saved[plan.id],
                  let destination = approved[plan.id],
                  receipt.signature == (try? signature(for: plan, destination: destination)) else { return nil }
            return plan.id
        })
    }

    func reconcile(agenda: WorkspaceRecord?, scope: String) async throws -> [String: Result] {
        let approved = approvedDestinations(scope: scope)
        let plans = try (agenda.map(ManagedAgenda.applePlans) ?? []).filter { approved[$0.id] != nil }
        let active = Set(plans.filter { $0.status == "active" }.map(\.id))
        var saved = receipts(scope)
        var results: [String: Result] = [:]

        for id in saved.keys.sorted() where !active.contains(id) {
            guard let previous = saved[id] else { continue }
            do {
                try await remove(previous, scope: scope)
                saved.removeValue(forKey: id)
                storeReceipts(saved, scope: scope)
            } catch {
                results[id] = Result(message: error.localizedDescription, saved: false)
            }
        }

        for plan in plans where plan.status == "active" {
            guard let destination = approved[plan.id] else { continue }
            let signature = try signature(for: plan, destination: destination)
            let previous = saved[plan.id]
            do {
                if previous?.signature != signature {
                    if let previous, previous.destination != destination {
                        try await remove(previous, scope: scope)
                        saved.removeValue(forKey: plan.id)
                        storeReceipts(saved, scope: scope)
                    }
                    let receipt = try await deliver(plan, destination: destination,
                                                     previous: saved[plan.id], signature: signature, scope: scope)
                    saved[plan.id] = receipt
                    storeReceipts(saved, scope: scope)
                }
                let label: String
                switch destination {
                case "alarm": label = String(localized: "iPhone alarmı kuruldu")
                case "calendar": label = String(localized: "Apple Takvim’e eklendi")
                default: label = String(localized: "Apple Anımsatıcılar’a eklendi")
                }
                results[plan.id] = Result(message: label, saved: true)
            } catch {
                if let previous, let failure = error as? Failure {
                    switch failure {
                    case .requiresTime, .unsupportedRepeat:
                        do {
                            try await remove(previous, scope: scope)
                            saved.removeValue(forKey: plan.id)
                            storeReceipts(saved, scope: scope)
                        } catch {
                            results[plan.id] = Result(message: error.localizedDescription, saved: false)
                            continue
                        }
                    default: break
                    }
                }
                results[plan.id] = Result(message: error.localizedDescription, saved: false)
            }
        }
        return results
    }

    private func signature(for plan: ManagedAgenda.ApplePlan, destination: String) throws -> String {
        let s = plan.schedule
        let values: [String] = [plan.title, plan.details, s.startDate, s.endDate ?? "", s.time ?? "",
            s.frequency, String(s.interval), s.weekdays.map { String($0) }.joined(separator: ","),
            String(s.durationMinutes ?? 0), String(s.reminderMinutes ?? -1), s.timezone, destination]
        return WorkspaceHash.sha256(String(decoding: try JSONEncoder().encode(values + plan.excludedDates), as: UTF8.self))
    }

    private func deliver(_ plan: ManagedAgenda.ApplePlan, destination: String, previous: Receipt?,
                         signature: String, scope: String) async throws -> Receipt {
        let s = plan.schedule
        var calendar = JournalCalendar.calendar()
        if s.time != nil, let zone = TimeZone(identifier: s.timezone) { calendar.timeZone = zone }
        guard let anchor = date(s.startDate, time: s.time, calendar: calendar) else { throw Failure.requiresTime }
        var start = anchor
        if s.frequency == "weekly" {
            let weekday = (calendar.component(.weekday, from: anchor) + 5) % 7 + 1
            guard let first = s.weekdays.filter({ $0 >= weekday }).min() ?? s.weekdays.min() else {
                throw Failure.unsupportedRepeat
            }
            // For multi-week plans, skip to the next active week if this week has no remaining occurrence.
            let offset = first >= weekday ? first - weekday : 7 * s.interval + first - weekday
            guard let occurrence = calendar.date(byAdding: .day, value: offset, to: anchor) else {
                throw Failure.unsupportedRepeat
            }
            start = occurrence
        }
        if let end = s.endDate.flatMap({ date($0, time: "23:59", calendar: calendar) }), start > end {
            throw Failure.requiresTime
        }
        let delivery = start.addingTimeInterval(-TimeInterval((s.reminderMinutes ?? 0) * 60))
        let identifier: String
        switch destination {
        case "alarm":
            guard #available(iOS 26.0, *) else { throw Failure.unsupportedOS }
            let schedule = try alarmSchedule(plan, delivery: delivery, start: start, calendar: calendar)
            let manager = AlarmManager.shared
            guard try await manager.requestAuthorization() == .authorized else { throw Failure.permission }
            let id = alarmID(scope: scope, eventID: plan.id, signature: signature)
            if !(try manager.alarms).contains(where: { $0.id == id }) {
                let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: plan.title),
                    stopButton: AlarmButton(text: "Durdur", textColor: .white, systemImageName: "stop.fill"),
                    secondaryButton: nil, secondaryButtonBehavior: nil)
                let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: DailyAlarmMetadata(), tintColor: .blue)
                NativeAgendaDelivery.trackAlarm(id, scope: scope)
                do {
                    _ = try await manager.schedule(id: id, configuration: .alarm(schedule: schedule, attributes: attributes))
                } catch {
                    NativeAgendaDelivery.untrackAlarm(id, scope: scope)
                    throw error
                }
            }
            if let previous, previous.identifier != id.uuidString {
                do { try await remove(previous, scope: scope) }
                catch {
                    try? manager.cancel(id: id)
                    throw error
                }
            }
            identifier = id.uuidString
        case "calendar":
            let rule = try recurrence(plan, calendar: calendar)
            guard try await store.requestFullAccessToEvents() else { throw Failure.permission }
            let existing = previous.flatMap { $0.destination == destination ? store.event(withIdentifier: $0.identifier) : nil }
            let event = existing ?? EKEvent(eventStore: store)
            guard let target = existing?.calendar ?? store.defaultCalendarForNewEvents else { throw Failure.target }
            event.calendar = target
            event.title = plan.title
            event.notes = plan.details
            event.isAllDay = s.time == nil
            event.startDate = start
            event.endDate = event.isAllDay ? calendar.date(byAdding: .day, value: 1, to: start)
                : start.addingTimeInterval(TimeInterval((s.durationMinutes ?? 60) * 60))
            event.timeZone = event.isAllDay ? nil : calendar.timeZone
            event.recurrenceRules = rule.map { [$0] }
            event.alarms = s.reminderMinutes != nil ? [EKAlarm(relativeOffset: delivery.timeIntervalSince(start))] : nil
            try store.save(event, span: existing?.hasRecurrenceRules == true ? .futureEvents : .thisEvent)
            identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        case "reminders":
            let rule = try recurrence(plan, calendar: calendar)
            guard try await store.requestFullAccessToReminders() else { throw Failure.permission }
            let existing = previous.flatMap { $0.destination == destination ? store.calendarItem(withIdentifier: $0.identifier) as? EKReminder : nil }
            let reminder = existing ?? EKReminder(eventStore: store)
            guard let target = existing?.calendar ?? store.defaultCalendarForNewReminders() else { throw Failure.target }
            reminder.calendar = target
            reminder.title = plan.title
            reminder.notes = plan.details
            let parts: Set<Calendar.Component> = s.time == nil ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            var components = calendar.dateComponents(parts, from: start)
            components.calendar = calendar
            components.timeZone = s.time == nil ? nil : calendar.timeZone
            reminder.startDateComponents = rule == nil ? nil : components
            reminder.dueDateComponents = components
            reminder.recurrenceRules = rule.map { [$0] }
            reminder.alarms = s.reminderMinutes != nil ? [EKAlarm(relativeOffset: delivery.timeIntervalSince(start))] : nil
            try store.save(reminder, commit: true)
            identifier = reminder.calendarItemIdentifier
        default: throw Failure.target
        }
        return Receipt(destination: destination, identifier: identifier, signature: signature,
                       hasAlert: destination == "alarm" || s.reminderMinutes != nil)
    }

    private func date(_ day: String, time: String?, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: day + " " + (time ?? "00:00"))
    }

    private func recurrence(_ plan: ManagedAgenda.ApplePlan, calendar: Calendar) throws -> EKRecurrenceRule? {
        let s = plan.schedule
        guard plan.excludedDates.isEmpty else { throw Failure.unsupportedRepeat }
        guard s.frequency != "once" else { return nil }
        let frequency: EKRecurrenceFrequency = s.frequency == "daily" ? .daily : s.frequency == "weekly" ? .weekly : .monthly
        let days = s.weekdays.compactMap { EKWeekday(rawValue: $0 % 7 + 1) }.map { EKRecurrenceDayOfWeek($0) }
        let end = s.endDate.flatMap { date($0, time: "23:59", calendar: calendar) }.map { EKRecurrenceEnd(end: $0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: s.interval,
            daysOfTheWeek: days.isEmpty ? nil : days, daysOfTheMonth: nil, monthsOfTheYear: nil,
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    @available(iOS 26.0, *)
    private func alarmSchedule(_ plan: ManagedAgenda.ApplePlan, delivery: Date, start: Date, calendar: Calendar) throws -> Alarm.Schedule {
        let s = plan.schedule
        let now = Date()
        if s.frequency == "once" {
            guard delivery > now else { throw Failure.requiresTime }
            return .fixed(delivery)
        }
        guard s.interval == 1, s.endDate == nil, plan.excludedDates.isEmpty,
              s.frequency == "daily" || s.frequency == "weekly",
              calendar.timeZone.secondsFromGMT(for: now) == TimeZone.current.secondsFromGMT(for: now) else {
            throw Failure.unsupportedRepeat
        }

        let weekdays: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        // The weekly alarm weekday is the alert's day, which may precede the event.
        let shift = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                            to: calendar.startOfDay(for: delivery)).day ?? 0
        let selected = s.frequency == "daily" ? Array(1...7) : s.weekdays
        let indexes = selected.map { (($0 - 1 + shift) % 7 + 7) % 7 }
        let hour = calendar.component(.hour, from: delivery), minute = calendar.component(.minute, from: delivery)
        let next = indexes.compactMap {
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, weekday: ($0 + 1) % 7 + 1),
                              matchingPolicy: .nextTime)
        }.min()
        guard let next, next >= delivery else {
            throw Failure.unsupportedRepeat
        }
        return .relative(.init(time: .init(hour: hour, minute: minute), repeats: .weekly(indexes.map { weekdays[$0] })))
    }

    private func alarmID(scope: String, eventID: String, signature: String) -> UUID {
        let bytes = Array(WorkspaceHash.sha256(scope + ":" + eventID + ":" + signature).utf8)
        let hash = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16) ?? 0
        }
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    private func remove(_ receipt: Receipt, scope: String) async throws {
        switch receipt.destination {
        case "alarm":
            guard #available(iOS 26.0, *), let id = UUID(uuidString: receipt.identifier) else { return }
            let manager = AlarmManager.shared
            if (try manager.alarms).contains(where: { $0.id == id }) { try manager.cancel(id: id) }
            NativeAgendaDelivery.untrackAlarm(id, scope: scope)
        case "calendar":
            guard try await store.requestFullAccessToEvents() else { throw Failure.permission }
            if let event = store.event(withIdentifier: receipt.identifier) { try store.remove(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent) }
        case "reminders":
            guard try await store.requestFullAccessToReminders() else { throw Failure.permission }
            if let reminder = store.calendarItem(withIdentifier: receipt.identifier) as? EKReminder {
                try store.remove(reminder, commit: true)
            }
        default: break
        }
    }

    func activeAlarms(scope: String) throws -> Set<UUID> {
        guard #available(iOS 26.0, *) else { return [] }
        let owned = NativeAgendaDelivery.ownedAlarmIDs(scope: scope)
        guard !owned.isEmpty else { return [] }
        return try owned.intersection(AlarmManager.shared.alarms.map(\.id))
    }

    func cancelWorkspaceAlarms(scope: String) throws -> Int {
        guard #available(iOS 26.0, *) else { return 0 }
        let ids = try activeAlarms(scope: scope)
        for id in ids { try AlarmManager.shared.cancel(id: id) }
        guard try activeAlarms(scope: scope).isEmpty else { throw Failure.alarmCancellation }
        return ids.count
    }

    func clearWorkspaceReceipts(scope: String) {
        UserDefaults.standard.removeObject(forKey: key(scope))
        UserDefaults.standard.removeObject(forKey: approvalsKey(scope))
    }
}
