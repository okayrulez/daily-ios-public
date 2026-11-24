import Foundation
import UserNotifications

/// Local delivery adapter. No AI calls; only already-synced cards can be scheduled.
@MainActor
final class CompanionNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var scope = ""
    private var transferringCards: Set<String> = []
    private var mutations: Task<Void, Never>?
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let prior = mutations
        let task = Task { @MainActor in
            await prior?.value
            await operation()
        }
        mutations = task
        return task
    }
    private var permissionTask: Task<Bool, Error>?
    var onFailure: ((String) -> Void)?
    var onOpen: ((String, String) -> Void)?
    override init() { super.init(); center.delegate = self }
    private struct Notice: Sendable {
        let identifier: String
        let scope: String?
        var cardID: String? = nil
        var deliveryDate: Date? = nil
        var title = ""
        var body = ""
    }
    private func pendingRequests() async -> [Notice] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map { request in
                    let delivery = (request.content.userInfo["deliveryEpoch"] as? Double).map(Date.init(timeIntervalSince1970:))
                        ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                        ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    return Notice(identifier: request.identifier, scope: request.content.userInfo["companionScope"] as? String,
                        cardID: request.content.userInfo["companionCard"] as? String, deliveryDate: delivery, title: request.content.title, body: request.content.body)
                })
            }
        }
    }
    private func deliveredRequests() async -> [Notice] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map { Notice(identifier: $0.request.identifier, scope: $0.request.content.userInfo["companionScope"] as? String) })
            }
        }
    }
    func reset(scope: String) {
        let previous = self.scope
        self.scope = scope
        if !previous.isEmpty, previous != scope {
            _ = enqueue { await self.clearNotifications(scope: previous) }
        }
    }
    func requestPermission() async throws -> Bool {
        if let permissionTask { return try await permissionTask.value }
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                }
            }
        }
        permissionTask=task
        defer { permissionTask=nil }
        return try await task.value
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
    }
    func scheduleTest(scope: String) async throws {
        guard try await requestPermission(), self.scope == scope else { throw DailyCore.WorkspaceError.invalidAccount }
        let content=UNMutableNotificationContent()
        content.title="dAIly"
        content.body="Deneme bildirimi ulaştı. Yerel bildirim bağlantın çalışıyor."
        content.sound = .default
        content.userInfo=["companionScope":scope,"companionCard":"setup_test"]
        var failure: (any Error)? = DailyCore.WorkspaceError.invalidAccount
        await enqueue {
            guard self.scope == scope else { return }
            do {
                try await self.add(UNNotificationRequest(identifier:"daily-setup-test-"+scope,content:content,
                    trigger:UNTimeIntervalNotificationTrigger(timeInterval:10,repeats:false)))
                failure = nil
            } catch { failure = error }
        }.value
        if let failure { throw failure }
    }
    func statusSummary() async -> String {
        let permission: String = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let label: String
                switch settings.authorizationStatus {
                case .authorized: label = "iPhone izni: açık"
                case .provisional, .ephemeral: label = "iPhone izni: sessiz/geçici"
                case .denied: label = "iPhone izni: kapalı"
                case .notDetermined: label = "iPhone izni: henüz verilmedi"
                @unknown default: label = "iPhone izni: bilinmiyor"
                }
                continuation.resume(returning: label)
            }
        }
        let pending = await pendingRequests().filter { $0.scope == scope }.count
        return "\(permission) · Telefonda planlanan: \(pending)"
    }
    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func enabled(scope: String) -> Bool { UserDefaults.standard.bool(forKey: "companion-notifications-\(scope)") }
    func enable(scope: String) async throws -> Bool {
        let granted = try await requestPermission()
        guard self.scope == scope else { return false }
        UserDefaults.standard.set(granted, forKey: "companion-notifications-\(scope)"); return granted
    }
    func disable(scope: String) async {
        UserDefaults.standard.set(false, forKey: "companion-notifications-\(scope)")
        await enqueue { await self.clearNotifications(scope: scope) }.value
    }
    func useRemoteDelivery(scope: String) {
        UserDefaults.standard.set(false, forKey: "companion-notifications-\(scope)")
    }
    private func clearNotifications(scope: String) async {
        let pending = await pendingRequests().filter { $0.scope == scope }
        cancelPending(pending, scope: scope)
        let delivered = await deliveredRequests().filter { $0.scope == scope }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.identifier))
    }
    private func cancelPending(_ pending: [Notice], scope: String) {
        guard !pending.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
        refund(pending.map { .init(id: $0.identifier, deliveryDate: $0.deliveryDate) }, scope: scope)
    }
    private func refund(_ reservations: [DailyCore.NotificationReservations.Pending], scope: String) {
        guard !reservations.isEmpty else { return }
        let defaults = UserDefaults.standard
        let ledgerKey = "companion-scheduled-\(scope)", countsKey = "companion-delivery-counts-\(scope)"
        let state = DailyCore.NotificationReservations.removing(reservations,
            ledger: defaults.stringArray(forKey: ledgerKey) ?? [],
            counts: defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:])
        defaults.set(state.ledger, forKey: ledgerKey)
        defaults.set(state.counts, forKey: countsKey)
    }
    func pauseNativeTransfer(scope: String, cardIDs: Set<String>) async {
        transferringCards = cardIDs
        guard !cardIDs.isEmpty else { return }
        await enqueue {
            let pending = await self.pendingRequests().filter { notice in
                notice.scope == scope && notice.cardID.map(cardIDs.contains) == true
            }
            self.cancelPending(pending, scope: scope)
        }.value
    }
    func finishNativeTransfer() { transferringCards = [] }
    func reconcile(scope: String, cards: [DailyCore.CompanionCard], events: [DailyCore.CompanionEvent], active: Bool, dailyLimit: Int, preferredHour: Int = 10, agendaFallbackIDs: Set<String> = []) async {
        await enqueue {
            await self.update(scope: scope, cards: cards, events: events, active: active, dailyLimit: dailyLimit,
                preferredHour: preferredHour, agendaFallbackIDs: agendaFallbackIDs)
        }.value
    }
    private func update(scope: String, cards: [DailyCore.CompanionCard], events: [DailyCore.CompanionEvent], active: Bool, dailyLimit: Int, preferredHour: Int, agendaFallbackIDs: Set<String>) async {
        guard self.scope == scope else { return }
        let pending = await pendingRequests().filter { DailyCore.NotificationReservations.managedRequest($0.identifier, owner: $0.scope, scope: scope) }
        let permission = await authorizationStatus()
        guard self.scope == scope else { return }
        guard permission == .authorized || permission == .provisional || permission == .ephemeral else { return }
        let eligible = cards.filter {
            ((active && enabled(scope: scope)) || agendaFallbackIDs.contains($0.id))
                && !transferringCards.contains($0.id) && !NativeAgendaDelivery.covers($0, scope: scope)
                && $0.kind != "followup" && $0.notification != nil && !["closed", "expired"].contains($0.state(events: events))
        }.sorted {
            let firstAgenda = $0.id.hasPrefix("agenda_"), secondAgenda = $1.id.hasPrefix("agenda_")
            if firstAgenda != secondAgenda { return firstAgenda }
            return $0.deliveryDate(events: events) < $1.deliveryDate(events: events)
        }
        let identity: (DailyCore.CompanionCard) -> String = { card in "daily-companion-" + DailyCore.WorkspaceHash.sha256(scope + card.id + DailyCore.CompanionCard.timestamp(card.deliveryDate(events: events))) }
        let pendingIDs = Set(pending.map(\.identifier))
        var prior = Set(UserDefaults.standard.stringArray(forKey: "companion-scheduled-" + scope) ?? [])
        let now = Date()
        // Older releases cleared pending requests on disable without refunding the ledger.
        // A card whose earliest fire time is still in the future cannot already have fired.
        let missing = eligible.compactMap { card -> DailyCore.NotificationReservations.Pending? in
            let id = identity(card), earliest = card.deliveryDate(events: events)
            guard prior.contains(id), !pendingIDs.contains(id), earliest > now else { return nil }
            return .init(id: id, deliveryDate: self.fireDate(for: card, earliest: earliest, preferredHour: preferredHour))
        }
        refund(missing, scope: scope)
        prior.subtract(missing.map(\.id))
        let selected = eligible.lazy.filter { card in
            let id = identity(card)
            return !prior.contains(id) || pendingIDs.contains(id)
        }.prefix(30)
        let wanted = Set(selected.map(identity))
        let removed = pending.filter { !wanted.contains($0.identifier) }
        cancelPending(removed, scope: scope)
        let ledgerKey = "companion-scheduled-\(scope)"
        var ledger = UserDefaults.standard.stringArray(forKey: ledgerKey) ?? []
        let countsKey = "companion-delivery-counts-\(scope)"
        var perDay = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        for card in selected {
            guard self.scope == scope else { return }
            let id = identity(card)
            let content = notificationContent(for: card, scope: scope)
            if let existing = pending.first(where: { $0.identifier == id }) {
                // Replace already-scheduled copy in place, without changing its time or daily budget.
                if existing.title != content.title || existing.body != content.body,
                   let fireDate = existing.deliveryDate, fireDate.timeIntervalSinceNow > 1 {
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSinceNow, repeats: false)
                    do {
                        content.userInfo["deliveryEpoch"] = fireDate.timeIntervalSince1970
                        try await add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                        guard self.scope == scope else { return }
                    } catch {
                        onFailure?("Bildirim metni güncellenemedi. Bir sonraki açılışta yeniden denenecek.")
                    }
                }
                continue
            }
            if ledger.contains(id) { continue }
            let delivery = fireDate(for: card, earliest: max(card.deliveryDate(events: events), Date().addingTimeInterval(5)),
                preferredHour: preferredHour)
            let dayKey = DailyCore.NotificationReservations.dayKey(delivery)
            let count = perDay[dayKey, default: 0]
            guard DailyCore.NotificationReservations.permitsDelivery(confirmedAgenda: card.id.hasPrefix("agenda_"), count: count, limit: dailyLimit) else { continue }
            guard delivery < (DailyCore.CompanionCard.date(card.expiresAt) ?? .distantPast) else { continue }
            content.userInfo["deliveryEpoch"] = delivery.timeIntervalSince1970
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delivery.timeIntervalSinceNow), repeats: false)
            do {
                try await add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                perDay[dayKey] = count + 1
                if perDay.count > 60 { perDay = Dictionary(uniqueKeysWithValues: perDay.sorted { $0.key > $1.key }.prefix(60).map { ($0.key, $0.value) }) }
                UserDefaults.standard.set(perDay, forKey: countsKey)
                ledger.append(id); UserDefaults.standard.set(Array(ledger.suffix(1000)), forKey: ledgerKey)
            } catch { onFailure?("Hatırlatma iPhone’da planlanamadı. Bildirim iznini kontrol edip yeniden dene.") }
        }
    }
    private func fireDate(for card: CompanionCard, earliest: Date, preferredHour: Int) -> Date {
        guard !card.id.hasPrefix("agenda_") else { return earliest }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let hour = calendar.component(.hour, from: earliest), opening = min(21, max(8, preferredHour))
        if hour < opening {
            return calendar.date(bySettingHour: opening, minute: 0, second: 0, of: earliest) ?? earliest
        }
        if hour >= 22, let tomorrow = calendar.date(byAdding: .day, value: 1, to: earliest) {
            return calendar.date(bySettingHour: opening, minute: 0, second: 0, of: tomorrow) ?? earliest
        }
        return earliest
    }
    private func notificationContent(for card: CompanionCard, scope: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if card.journalDate != nil {
            content.title = String(localized: "Günlüğünün soruları hazır")
            content.body = String(localized: "Sorularını görmek için dAIly’yi aç.")
        } else if card.kind == "deadline" || card.kind == "pinned" {
            content.title = String(localized: "Hatırlatma")
            content.body = String(localized: "Ayrıntıları görmek için dAIly’yi aç.")
        } else if !card.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.kind == "followup" {
            content.title = String(localized: "Takip sorusu")
            content.body = String(localized: "Soruyu görmek için dAIly’yi aç.")
        } else {
            content.title = String(localized: "Günün önerisi")
            content.body = String(localized: "Öneriyi görmek için dAIly’yi aç.")
        }
        content.sound = .default
        content.userInfo = ["companionScope": scope, "companionCard": card.id]
        return content
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let scope = response.notification.request.content.userInfo["companionScope"] as? String
        let card = response.notification.request.content.userInfo["companionCard"] as? String
        Task { @MainActor [weak self] in if let scope, let card { self?.onOpen?(scope, card) } }
        completionHandler()
    }
}
import DailyCore
