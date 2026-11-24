import Foundation

/// Refund only cancelled pending reservations, never already delivered notices.
public enum NotificationReservations {
    public struct Pending: Sendable {
        public let id: String
        public let deliveryDate: Date?
        public init(id: String, deliveryDate: Date?) { self.id = id; self.deliveryDate = deliveryDate }
    }
    public static func managedRequest(_ id: String, owner: String?, scope: String) -> Bool {
        owner == scope && id.hasPrefix("daily-companion-")
    }
    public static func permitsDelivery(confirmedAgenda: Bool, count: Int, limit: Int) -> Bool {
        confirmedAgenda || count < max(1, min(5, limit))
    }
    public static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return "\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))-\(calendar.component(.day, from: date))"
    }
    public static func removing(_ pending: [Pending], ledger: [String], counts: [String: Int]) -> (ledger: [String], counts: [String: Int]) {
        var remaining = Set(ledger), updated = counts
        for request in pending where remaining.remove(request.id) != nil {
            guard let date = request.deliveryDate else { continue }
            let key = dayKey(date)
            updated[key] = max(0, updated[key, default: 0] - 1)
        }
        return (ledger.filter { remaining.contains($0) }, updated)
    }
}
