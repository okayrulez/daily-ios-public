import UIKit
import UserNotifications

@MainActor
final class RemotePushRegistration {
    static let shared = RemotePushRegistration()
    private var pending: CheckedContinuation<String, Error>?
    private var requestID = UUID()
    private var requesting = false
    // APNs can call back after our UI timeout. Forward that result instead of
    // silently discarding it; never persist a device token as a permanent cache.
    var onLateToken: ((String) -> Void)?
    enum Failure: LocalizedError {
        case denied, unavailable, busy
        var errorDescription: String? {
            switch self {
            case .denied: return "iPhone bildirim izni kapalı."
            case .unavailable: return "Apple bildirim cihaz adresini 20 saniye içinde iletmedi. Firebase kaydı henüz başlamadı. Apple’ın cevabı geç gelirse kayıt otomatik tamamlanacak; bağlantı geri geldiğinde de yeniden denenecek."
            case .busy: return "Apple bildirim kaydı zaten sürüyor."
            }
        }
    }

    func token() async throws -> String {
        guard !requesting else { throw Failure.busy }
        requesting = true
        defer { requesting = false }
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
        guard granted else { throw Failure.denied }
        // Ask APNs each time; device tokens must not be treated as permanent.
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); requestID = id; pending = continuation
            UIApplication.shared.registerForRemoteNotifications()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if self.requestID == id { self.finish(.failure(Failure.unavailable)) }
            }
        }
    }
    func finish(_ result: Result<String, Error>) {
        let continuation = pending; pending = nil; requestID = UUID()
        if let continuation { continuation.resume(with: result) }
        else if case .success(let token) = result { onLateToken?(token) }
    }
}

@MainActor
final class DailyPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushRegistration.shared.finish(.success(deviceToken.map { String(format: "%02x", $0) }.joined()))
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushRegistration.shared.finish(.failure(error))
    }
}
