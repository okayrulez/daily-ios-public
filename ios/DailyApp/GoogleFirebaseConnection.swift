import Foundation
import UIKit
import DailyCore
@preconcurrency import GoogleSignIn

struct GoogleFirebaseProject: Identifiable, Codable, Sendable {
    let projectID: String
    let name: String
    var id: String { projectID }
}

struct GoogleAPIError: LocalizedError {
    let code: Int
    let status: String
    let reason: String?
    let operation: String?
    init(code: Int, status: String, reason: String? = nil, operation: String? = nil) {
        self.code = code; self.status = status; self.reason = reason; self.operation = operation
    }
    var errorDescription: String? {
        switch code {
        case 0: "Google bağlantısı için bu derlemede OAuth istemcisi yapılandırılmalı."
        case 401: "Google oturumu yenilenmeli. Google ile yeniden bağlan."
        case 403: "Google bu işleme izin vermedi. Proje yetkilerini, Google izinlerini veya API etkinleştirmesini kontrol et. [\(status)]"
        case 429: "Google proje veya istek kotası aşıldı. Yerel kayıtların korunuyor."
        default: "Google işlemi tamamlanamadı. Yerel kayıtların korunuyor. [\(operation ?? "Google") · \(status) · \(code)]"
        }
    }
}

@MainActor final class GoogleFirebaseConnection {
    private static var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DailyGoogleOAuthClientID") as? String,
              value.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return value
    }
    static let cloudScope = "https://www.googleapis.com/auth/cloud-platform"
    private(set) var googleUID: String?
    private(set) var email = ""

    func signIn() async throws {
        guard let presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { throw WorkspaceSyncError.disconnected }
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        guard let clientID = Self.clientID else { throw GoogleAPIError(code: 0, status: "oauth_client_unconfigured") }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: top, hint: nil, additionalScopes: [Self.cloudScope])
        try accept(result.user)
    }
    func restore(expectedGoogleUID: String) async throws {
        guard let clientID = Self.clientID else { throw GoogleAPIError(code: 0, status: "oauth_client_unconfigured") }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        guard user.userID == expectedGoogleUID else { throw WorkspaceSyncError.disconnected }
        try accept(user)
    }
    private func accept(_ user: GIDGoogleUser) throws {
        guard let id = user.userID, user.grantedScopes?.contains(Self.cloudScope) == true else { throw WorkspaceSyncError.disconnected }
        try WorkspaceIdentity.validateUID(id)
        googleUID = id; email = user.profile?.email ?? ""
    }
    func request(_ url: String, method: String = "GET", body: JSONValue? = nil, missingAllowed: Bool = false) async throws -> JSONValue? {
        guard let target = URL(string: url), let host = target.host,
              ["firebase.googleapis.com", "cloudresourcemanager.googleapis.com", "firestore.googleapis.com",
               "identitytoolkit.googleapis.com", "serviceusage.googleapis.com"].contains(host), target.scheme == "https",
              let uid = googleUID, let user = GIDSignIn.sharedInstance.currentUser, user.userID == uid else { throw WorkspaceSyncError.disconnected }
        let refreshed = try await user.refreshTokensIfNeeded()
        guard refreshed.userID == uid else { throw WorkspaceSyncError.disconnected }
        var request = URLRequest(url: target); request.httpMethod = method; request.timeoutInterval = 40
        request.setValue("Bearer " + refreshed.accessToken.tokenString, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = Data(try body.canonical().utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard googleUID == uid, GIDSignIn.sharedInstance.currentUser?.userID == uid,
              let http = response as? HTTPURLResponse else { throw WorkspaceSyncError.disconnected }
        if missingAllowed && http.statusCode == 404 { return nil }
        let value = data.isEmpty ? JSONValue.object([:]) : try JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(http.statusCode) else {
            let error = value.object?["error"]?.object
            let status = error?["message"]?.string == "CONFIGURATION_NOT_FOUND" ? "CONFIGURATION_NOT_FOUND" : error?["status"]?.string ?? "request_failed"
            let reason = error?["details"]?.array?.compactMap { $0.object?["reason"]?.string }.first
            let operation: String
            switch host {
            case "cloudresourcemanager.googleapis.com": operation = "Proje oluşturma"
            case "serviceusage.googleapis.com": operation = "Firestore etkinleştirme"
            case "firebase.googleapis.com": operation = method == "GET" ? "Firebase projeleri" : "Firebase kurulumu"
            case "identitytoolkit.googleapis.com": operation = "Hesap eşleştirme"
            default: operation = "Firestore bağlantısı"
            }
            throw GoogleAPIError(code: http.statusCode, status: status, reason: reason, operation: operation)
        }
        return value
    }
    func projects() async throws -> [GoogleFirebaseProject] {
        var result: [GoogleFirebaseProject] = [], token = ""
        repeat {
            let suffix = token.isEmpty ? "" : "&pageToken=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            let response = try await request("https://firebase.googleapis.com/v1beta1/projects?pageSize=100" + suffix)
            for row in response?.object?["results"]?.array ?? [] {
                guard let id = row.object?["projectId"]?.string, (try? MemoryScope(projectID: id, uid: googleUID ?? "")) != nil else { continue }
                result.append(GoogleFirebaseProject(projectID: id, name: row.object?["displayName"]?.string ?? id))
            }
            token = response?.object?["nextPageToken"]?.string ?? ""
        } while !token.isEmpty
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func workspaceUID(project: String, newlyCreated: Bool = false) async throws -> String {
        guard let googleUID else { throw WorkspaceSyncError.disconnected }
        _ = try MemoryScope(projectID: project, uid: googleUID)
        let document = "projects/\(project)/databases/(default)/documents/dailyXGoogleAccounts/" + WorkspaceHash.sha256(googleUID)
        func binding(_ value: JSONValue) throws -> String {
            guard let fields = value.object?["fields"], let row = try FirestoreDocumentCodec.decodeFields(fields).object,
                  row["googleUID"]?.string == googleUID, let uid = row["workspaceUID"]?.string else { throw WorkspaceError.invalidAccount }
            try WorkspaceIdentity.validateUID(uid); return uid
        }
        if let saved = try await request("https://firestore.googleapis.com/v1/" + document, missingAllowed: true) { return try binding(saved) }
        var targetUID = googleUID
        // Preserve the UID of an existing DailyX Firebase account. Never guess a different user's subtree.
        if !newlyCreated { do {
            let response = try await request("https://identitytoolkit.googleapis.com/v1/projects/\(project)/accounts:lookup", method: "POST",
                body: .object(["email": .array([.string(email)])]))
            let users = response?.object?["users"]?.array ?? []
            if let row = users.first?.object, let uid = row["localId"]?.string,
               row["email"]?.string?.lowercased() == email.lowercased() {
                try WorkspaceIdentity.validateUID(uid); targetUID = uid
            }
        } catch let error as GoogleAPIError where error.code == 404 || error.status == "CONFIGURATION_NOT_FOUND" || error.reason == "SERVICE_DISABLED" { } }
        // Persist identity once. Enabling Firebase Auth later must not silently switch to another empty UID.
        let fields = try FirestoreDocumentCodec.fields(.object(["googleUID": .string(googleUID), "workspaceUID": .string(targetUID)]))
        do {
            _ = try await request("https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents:commit", method: "POST", body: .object([
                "writes": .array([.object(["update": .object(["name": .string(document), "fields": fields]),
                    "currentDocument": .object(["exists": .bool(false)])])])]))
        } catch let error as GoogleAPIError where error.code == 409 {
            guard let saved = try await request("https://firestore.googleapis.com/v1/" + document) else { throw error }
            return try binding(saved)
        }
        return targetUID
    }
    func createProject(name: String, region: String, progress: (String) -> Void) async throws -> GoogleFirebaseProject {
        guard let uid = googleUID, ["eur3", "nam5"].contains(region) else { throw WorkspaceSyncError.disconnected }
        let key = "daily-pending-project-" + uid
        let pending = UserDefaults.standard.string(forKey: key)
        let project = pending ?? "daily-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        UserDefaults.standard.set(project, forKey: key)
        progress("Google hesabında proje hazırlanıyor…")
        // Create the same persisted candidate on retry; never generate another project after a timeout.
        do {
            let operation = try await request("https://cloudresourcemanager.googleapis.com/v1/projects", method: "POST", body: .object([
                "projectId": .string(project), "name": .string(GoogleProjectSetup.displayName(name))]))
            try await wait(operation, base: "https://cloudresourcemanager.googleapis.com/v1/")
        } catch let error as GoogleAPIError where error.code == 409 && pending != nil {
            guard let response = try await request("https://cloudresourcemanager.googleapis.com/v1/projects/\(project)"),
                  response.object?["projectId"]?.string == project,
                  response.object?["lifecycleState"]?.string == "ACTIVE" else { throw error }
        }
        progress("Firebase hizmetleri ekleniyor…")
        if try await request("https://firebase.googleapis.com/v1beta1/projects/\(project)", missingAllowed: true) == nil {
            let operation = try await request("https://firebase.googleapis.com/v1beta1/projects/\(project):addFirebase", method: "POST", body: .object([:]))
            try await wait(operation, base: "https://firebase.googleapis.com/v1beta1/")
        }
        progress("Firestore veritabanı hazırlanıyor…")
        // Service Usage requires the numeric resource, not the user-assigned project ID.
        let resource = try await request("https://cloudresourcemanager.googleapis.com/v1/projects/\(project)")
        guard let number = resource?.object?["projectNumber"]?.string else { throw WorkspaceError.malformedRecord }
        let operation = try await request(GoogleProjectSetup.serviceEnableURL(projectNumber: number), method: "POST")
        try await wait(operation, base: "https://serviceusage.googleapis.com/v1/")
        let database = "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)"
        if try await request(database, missingAllowed: true) == nil {
            let operation = try await request("https://firestore.googleapis.com/v1/projects/\(project)/databases?databaseId=(default)", method: "POST",
                body: .object(["type": .string("FIRESTORE_NATIVE"), "locationId": .string(region)]))
            try await wait(operation, base: "https://firestore.googleapis.com/v1/")
        }
        return GoogleFirebaseProject(projectID: project, name: name)
    }
    func confirmedConnection(project: String) {
        guard let uid = googleUID else { return }
        let key = "daily-pending-project-" + uid
        if UserDefaults.standard.string(forKey: key) == project { UserDefaults.standard.removeObject(forKey: key) }
    }
    private func wait(_ operation: JSONValue?, base: String) async throws {
        if let error = operation?.object?["error"]?.object {
            throw GoogleAPIError(code: error["code"]?.integer ?? 400, status: "project_setup_failed")
        }
        guard let name = operation?.object?["name"]?.string,
              name.range(of: "^[A-Za-z0-9_./()=-]+$", options: .regularExpression) != nil else { throw WorkspaceError.malformedRecord }
        if operation?.object?["done"] == .bool(true) { return }
        for _ in 0..<120 {
            try Task.checkCancellation()
            let response = try await request(base + name)
            if let error = response?.object?["error"]?.object {
                throw GoogleAPIError(code: error["code"]?.integer ?? 400, status: "project_setup_failed")
            }
            if response?.object?["done"] == .bool(true) { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw GoogleAPIError(code: 408, status: "setup_in_progress_retry")
    }
}
