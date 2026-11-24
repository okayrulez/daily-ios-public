import Foundation

public struct NativeAgendaReceipt: Codable, Sendable {
    public let destination: String
    public let delivery: Date?
    public let alarmID: UUID?

    public init(destination: String, delivery: Date?, alarmID: UUID?) {
        self.destination = destination
        self.delivery = delivery
        self.alarmID = alarmID
    }
}

@MainActor
public enum NativeAgendaDelivery {
    private static func receiptIndex(_ scope: String) -> String { "daily-apple-receipts-" + WorkspaceHash.sha256(scope) }
    private static func alarmIndex(_ scope: String) -> String { "daily-apple-alarms-" + WorkspaceHash.sha256(scope) }

    public static func trackAlarm(_ id: UUID, scope: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: alarmIndex(scope)) ?? [])
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: alarmIndex(scope))
    }
    public static func untrackAlarm(_ id: UUID, scope: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: alarmIndex(scope)) ?? [])
        ids.remove(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: alarmIndex(scope))
    }
    public static func suppressionKeys(scope: String, after cutoff: Date = Date().addingTimeInterval(-8 * 86400)) -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: indexKey(scope: scope)) ?? [:]).compactMap { key, value in
            guard let epoch = value as? Double, epoch > cutoff.timeIntervalSince1970 else { return nil }
            return WorkspaceHash.sha256(key)
        })
    }
    private static func receiptIDs(scope: String) -> Set<String> {
        if let indexed = UserDefaults.standard.stringArray(forKey: receiptIndex(scope)) { return Set(indexed) }
        var ids = Set<String>()
        // Earlier versions indexed the delivery time, but hashed the occurrence date in the receipt.
        // A reminder can precede its event by up to seven days.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        for (key, value) in UserDefaults.standard.dictionary(forKey: indexKey(scope: scope)) ?? [:] {
            guard let epoch = value as? Double, let split = key.lastIndex(of: ":") else { continue }
            let event = String(key[..<split])
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: Date(timeIntervalSince1970: epoch)) else { continue }
                let id = WorkspaceHash.sha256(scope + ":" + event + "_" + formatter.string(from: day))
                if receipt(for: id) != nil { ids.insert(id) }
            }
        }
        return ids
    }
    public static func ownedAlarmIDs(scope: String) -> Set<UUID> {
        let saved = Set((UserDefaults.standard.stringArray(forKey: alarmIndex(scope)) ?? []).compactMap(UUID.init(uuidString:)))
        return saved.union(receiptIDs(scope: scope).compactMap { receipt(for: $0)?.alarmID })
    }
    public static func clear(scope: String) {
        for id in receiptIDs(scope: scope) { UserDefaults.standard.removeObject(forKey: "daily-apple-receipt-" + id) }
        for key in [receiptIndex(scope), alarmIndex(scope), indexKey(scope: scope)] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func indexKey(scope: String) -> String { "daily-apple-delivery-" + WorkspaceHash.sha256(scope) }

    public static func receipt(for id: String) -> NativeAgendaReceipt? {
        guard let data = UserDefaults.standard.data(forKey: "daily-apple-receipt-" + id) else { return nil }
        return try? JSONDecoder().decode(NativeAgendaReceipt.self, from: data)
    }

    public static func alarmReceiptID(for occurrenceID: String) -> String { occurrenceID + "-alarm" }

    public static func alarmReceipt(for occurrenceID: String, scope: String, eventID: String) -> NativeAgendaReceipt? {
        let id = alarmReceiptID(for: occurrenceID)
        if let legacy = receipt(for: occurrenceID), legacy.destination == "alarm" {
            // Older releases shared one receipt between Calendar, Reminders and the iPhone alarm.
            save(legacy, for: id, scope: scope, eventID: eventID)
            var ids = receiptIDs(scope: scope)
            ids.remove(occurrenceID)
            UserDefaults.standard.set(Array(ids), forKey: receiptIndex(scope))
            UserDefaults.standard.removeObject(forKey: "daily-apple-receipt-" + occurrenceID)
        }
        return receipt(for: id)
    }

    public static func save(_ receipt: NativeAgendaReceipt, for id: String, scope: String, eventID: String) {
        if let data = try? JSONEncoder().encode(receipt) {
            UserDefaults.standard.set(data, forKey: "daily-apple-receipt-" + id)
        }
        var ids = receiptIDs(scope: scope)
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: receiptIndex(scope))
        guard let delivery = receipt.delivery else { return }
        let key = indexKey(scope: scope)
        let now = Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970
        var index = UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { $0 as? Double } ?? [:]
        index = index.filter { $0.value > now }
        index[deliveryKey(eventID, delivery)] = delivery.timeIntervalSince1970
        UserDefaults.standard.set(index, forKey: key)
    }

    public static func remove(_ receipt: NativeAgendaReceipt, for id: String, scope: String, eventID: String,
                              retainingDelivery other: Date? = nil) {
        UserDefaults.standard.removeObject(forKey: "daily-apple-receipt-" + id)
        var ids = receiptIDs(scope: scope)
        ids.remove(id)
        UserDefaults.standard.set(Array(ids), forKey: receiptIndex(scope))
        if let alarmID = receipt.alarmID { untrackAlarm(alarmID, scope: scope) }
        guard let delivery = receipt.delivery, delivery != other else { return }
        let key = indexKey(scope: scope)
        var index = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        index.removeValue(forKey: deliveryKey(eventID, delivery))
        UserDefaults.standard.set(index, forKey: key)
    }

    public static func covers(_ card: CompanionCard, scope: String) -> Bool {
        guard card.id.hasPrefix("agenda_"), let event = card.deadlineId, let date = CompanionCard.date(card.notBefore) else { return false }
        return UserDefaults.standard.dictionary(forKey: indexKey(scope: scope))?[deliveryKey(event, date)] != nil
    }

    public static func deliveryKey(_ eventID: String, _ date: Date) -> String {
        eventID + ":" + String(Int(date.timeIntervalSince1970))
    }
}
