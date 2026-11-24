import Foundation
import XCTest
@testable import DailyCore

final class ManagedAgendaTests: XCTestCase {
    private let event = #"""
    {"id":"event_one","title":"Spor","details":"","status":"active","excludedDates":["2026-10-06"],
    "sourceQuote":"Salı perşembe spor","sourceID":"journal_one","createdAt":"2026-10-05T09:00:00Z",
    "updatedAt":"2026-10-05T09:00:00Z","revision":1,"schedule":{"startDate":"2026-10-05","endDate":null,
    "time":"18:00","durationMinutes":60,"frequency":"weekly","interval":1,"weekdays":[2,4],
    "reminderMinutes":30,"timezone":"Europe/Istanbul"}}
    """#

    func testFirebaseProjectionDecodesRecurringAgendaAndReminders() throws {
        let text = "{\"schemaVersion\":1,\"entries\":[\(event)]}"
        let record = try WorkspaceRecord.make(key: ManagedAgenda.key, kind: .note, payload: .string(text))
        let occurrences = try ManagedAgenda.upcoming(record, from: "2026-10-05")
        XCTAssertEqual(occurrences.first?.date, "2026-10-08")
        XCTAssertEqual(occurrences.first?.time, "18:00")
        XCTAssertEqual(occurrences.first?.schedule?.reminderMinutes, 30)
        XCTAssertEqual(occurrences.first?.schedule?.durationMinutes, 60)
        XCTAssertEqual(occurrences.first?.schedule?.timezone, "Europe/Istanbul")
        XCTAssertFalse(occurrences.contains { $0.date == "2026-10-06" })
        let now = try XCTUnwrap(CompanionCard.date("2026-10-05T09:00:00Z"))
        let reminders = try ManagedAgenda.reminders(record, now: now)
        XCTAssertEqual(reminders.first?.notBefore, "2026-10-08T14:30:00.000Z")
        XCTAssertTrue(reminders.first?.id.hasPrefix("agenda_") == true)
    }

    func testWrongRecordCannotBecomeAgenda() throws {
        let record = try WorkspaceRecord.make(key: "note:other", kind: .note, payload: .string("{}"))
        XCTAssertThrowsError(try ManagedAgenda.upcoming(record, from: "2026-10-05"))
    }
    func testCalendarCountsOnlyActiveOccurrencesInDisplayedMonth() throws {
        let second = event.replacingOccurrences(of: "event_one", with: "event_two")
        let cancelled = event.replacingOccurrences(of: "event_one", with: "event_cancelled")
            .replacingOccurrences(of: "\"status\":\"active\"", with: "\"status\":\"cancelled\"")
        let record = try WorkspaceRecord.make(key: ManagedAgenda.key, kind: .note,
            payload: .string("{\"schemaVersion\":1,\"entries\":[\(event),\(second),\(cancelled)]}"))
        let october = try ManagedAgenda.upcoming(record, from: "2026-10-01", days: 31)
        let counts = Dictionary(grouping: october, by: \.date).mapValues(\.count)
        XCTAssertEqual(counts["2026-10-08"], 2)
        XCTAssertNil(counts["2026-10-06"]) // Excluded occurrence: no badge.
        XCTAssertNil(counts["2026-10-07"]) // Empty day: no badge.
        XCTAssertTrue(october.allSatisfy { $0.date.hasPrefix("2026-10-") })
        let november = try ManagedAgenda.upcoming(record, from: "2026-11-01", days: 30)
        XCTAssertEqual(november.filter { $0.date == "2026-11-03" }.count, 2)
        XCTAssertTrue(november.allSatisfy { $0.date.hasPrefix("2026-11-") })
    }
    func testReschedulingRefundsPendingBudgetButNotDeliveredNotice() throws {
        let date = try XCTUnwrap(CompanionCard.date("2026-10-05T15:00:00Z"))
        let key = NotificationReservations.dayKey(date)
        let state = NotificationReservations.removing([.init(id: "pending", deliveryDate: date)],
            ledger: ["delivered", "pending"], counts: [key: 2])
        XCTAssertEqual(state.counts[key], 1)
        XCTAssertEqual(state.ledger, ["delivered"])
        let repeated = NotificationReservations.removing([.init(id: "pending", deliveryDate: date)],
            ledger: state.ledger, counts: state.counts)
        XCTAssertEqual(repeated.counts[key], 1)
    }
    func testReconciliationOwnsOnlyTheCurrentScopesOrdinaryRequests() {
        XCTAssertTrue(NotificationReservations.managedRequest("daily-companion-card", owner: "one", scope: "one"))
        XCTAssertFalse(NotificationReservations.managedRequest("daily-companion-card", owner: "two", scope: "one"))
        XCTAssertFalse(NotificationReservations.managedRequest("daily-setup-test-one", owner: "one", scope: "one"))
        XCTAssertFalse(NotificationReservations.managedRequest("other", owner: nil, scope: "one"))
    }
    func testConfirmedAgendaStillFiresAfterAutomaticBudgetIsFull() {
        XCTAssertTrue(NotificationReservations.permitsDelivery(confirmedAgenda: true, count: 3, limit: 3))
        XCTAssertFalse(NotificationReservations.permitsDelivery(confirmedAgenda: false, count: 3, limit: 3))
    }
    @MainActor
    func testResetEnumeratesOneWorkspacesAlarmsIncludingLegacyReceipts() throws {
        let scope = UUID().uuidString, other = UUID().uuidString
        defer { NativeAgendaDelivery.clear(scope: scope); NativeAgendaDelivery.clear(scope: other) }
        let due = try XCTUnwrap(CompanionCard.date("2026-10-04T23:00:00Z"))
        let legacyID = WorkspaceHash.sha256(scope + ":event_old_2026-10-12")
        let legacy = NativeAgendaReceipt(destination: "alarm", delivery: due, alarmID: UUID())
        let legacyAlarm = try XCTUnwrap(legacy.alarmID)
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: "daily-apple-receipt-" + legacyID)
        UserDefaults.standard.set([NativeAgendaDelivery.deliveryKey("event_old", due): due.timeIntervalSince1970],
            forKey: "daily-apple-delivery-" + WorkspaceHash.sha256(scope))
        let current = UUID(), unrelated = UUID()
        NativeAgendaDelivery.trackAlarm(current, scope: scope)
        NativeAgendaDelivery.trackAlarm(unrelated, scope: other)
        XCTAssertEqual(NativeAgendaDelivery.ownedAlarmIDs(scope: scope), Set([current, legacyAlarm]))
        NativeAgendaDelivery.clear(scope: scope)
        XCTAssertNil(NativeAgendaDelivery.receipt(for: legacyID))
        XCTAssertTrue(NativeAgendaDelivery.ownedAlarmIDs(scope: scope).isEmpty)
        XCTAssertEqual(NativeAgendaDelivery.ownedAlarmIDs(scope: other), Set([unrelated]))
    }
    @MainActor
    func testAlarmAndCalendarCanShareAnOccurrenceAcrossAnUpgradeAndCancellation() throws {
        let scope = UUID().uuidString, eventID = "plan", id = WorkspaceHash.sha256(scope + ":plan_2026-11-23")
        defer { NativeAgendaDelivery.clear(scope: scope) }
        let alarmID = UUID(), due = Date().addingTimeInterval(3600)
        let old = NativeAgendaReceipt(destination: "alarm", delivery: due, alarmID: alarmID)
        NativeAgendaDelivery.save(old, for: id, scope: scope, eventID: eventID)
        for _ in 0..<2 {
            XCTAssertEqual(NativeAgendaDelivery.alarmReceipt(for: id, scope: scope, eventID: eventID)?.alarmID, alarmID)
        }
        XCTAssertNil(NativeAgendaDelivery.receipt(for: id))
        let calendar = NativeAgendaReceipt(destination: "calendar", delivery: due, alarmID: nil)
        NativeAgendaDelivery.save(calendar, for: id, scope: scope, eventID: eventID)
        XCTAssertEqual(NativeAgendaDelivery.ownedAlarmIDs(scope: scope), [alarmID])
        let alarmKey = NativeAgendaDelivery.alarmReceiptID(for: id)
        NativeAgendaDelivery.remove(old, for: alarmKey, scope: scope, eventID: eventID, retainingDelivery: calendar.delivery)
        XCTAssertNil(NativeAgendaDelivery.receipt(for: alarmKey))
        XCTAssertEqual(NativeAgendaDelivery.receipt(for: id)?.destination, "calendar")
        XCTAssertTrue(NativeAgendaDelivery.ownedAlarmIDs(scope: scope).isEmpty)
        XCTAssertTrue(NativeAgendaDelivery.suppressionKeys(scope: scope).contains(
            WorkspaceHash.sha256(NativeAgendaDelivery.deliveryKey(eventID, due))))
    }

    @MainActor
    func testNewPushRegistrationOnlyTreatsFutureNativeDeliveriesAsOverlap() {
        let scope = UUID().uuidString, now = Date()
        defer { NativeAgendaDelivery.clear(scope: scope) }
        for (id, due) in [("past", now.addingTimeInterval(-60)), ("future", now.addingTimeInterval(60))] {
            NativeAgendaDelivery.save(.init(destination: "alarm", delivery: due, alarmID: UUID()),
                for: WorkspaceHash.sha256(scope + id), scope: scope, eventID: id)
        }
        XCTAssertEqual(NativeAgendaDelivery.suppressionKeys(scope: scope).count, 2)
        XCTAssertEqual(NativeAgendaDelivery.suppressionKeys(scope: scope, after: now),
            [WorkspaceHash.sha256(NativeAgendaDelivery.deliveryKey("future", now.addingTimeInterval(60)))])
        XCTAssertTrue(NativeAgendaDelivery.suppressionKeys(scope: scope, after: now.addingTimeInterval(61)).isEmpty)
    }
}
