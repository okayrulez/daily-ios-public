import Foundation
import Security

enum ChatGPTCredentialError: Error { case storageFailure, invalidCredentials }

struct ChatGPTCredentials: Codable, Sendable {
    let accountID: String
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: [String]
    var identityKey: String? = nil
    var email: String? = nil
    var displayName: String? = nil
    var savedAt: Date? = nil
    var identity: String { identityKey ?? "openai-sub:" + accountID }
}

/// Tokens remain native and device-only. Firebase UID is not the ChatGPT identity.
actor ChatGPTCredentialStore {
    private let service = "com.okayrulez.dailyx.chatgpt"
    private func registrations() throws -> [ChatGPTCredentials] {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [Data] else { throw ChatGPTCredentialError.storageFailure }
        return try rows.map { try JSONDecoder().decode(ChatGPTCredentials.self,from:$0) }
    }
    func accounts() throws -> [ChatGPTCredentials] {
        let stored = try registrations()
        // Keep legacy registrations in Keychain until a verified replacement is saved; list one
        // usable/latest registration per identity rather than one row per browser sign-in.
        var unique: [ChatGPTCredentials] = []
        for value in stored.sorted(by: { ($0.savedAt ?? $0.expiresAt) > ($1.savedAt ?? $1.expiresAt) }) {
            if !unique.contains(where: { $0.identity == value.identity || $0.accountID == value.accountID }) { unique.append(value) }
        }
        return unique.sorted { $0.identity < $1.identity }
    }

    func hostID() throws -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service+".host",kSecAttrAccount as String:"host",
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecSuccess, let data = result as? Data, let id = String(data:data,encoding:.utf8) { return id }
        guard status == errSecItemNotFound else { throw ChatGPTCredentialError.storageFailure }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        let item: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service+".host",kSecAttrAccount as String:"host",
            kSecValueData as String:Data(id.utf8),kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw ChatGPTCredentialError.storageFailure }
        return id
    }

    func save(_ value: ChatGPTCredentials) throws {
        guard !value.accountID.isEmpty, !value.clientID.isEmpty, !value.accessToken.isEmpty,
              !value.accountID.contains("\n"), !value.clientID.contains("\n"),
              !value.refreshToken.isEmpty else { throw ChatGPTCredentialError.invalidCredentials }
        let key = value.accountID + "\n" + value.clientID
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatGPTCredentialError.storageFailure }
        } else if status != errSecSuccess { throw ChatGPTCredentialError.storageFailure }
        // Write the replacement first. An interrupted cleanup must not lose the working session.
        for old in try registrations() where (old.identity == value.identity || old.accountID == value.accountID) && (old.clientID != value.clientID || old.accountID != value.accountID) {
            try remove(accountID: old.accountID, clientID: old.clientID)
        }
    }

    func load(accountID: String, clientID: String) throws -> ChatGPTCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: accountID + "\n" + clientID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTCredentialError.storageFailure }
        let value = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        guard value.accountID == accountID, value.clientID == clientID else { throw ChatGPTCredentialError.invalidCredentials }
        return value
    }

    func remove(accountID: String, clientID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: accountID + "\n" + clientID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTCredentialError.storageFailure }
    }
    func removeAccount(_ account: ChatGPTCredentials) throws {
        for value in try registrations() where value.accountID == account.accountID || value.identity == account.identity {
            try remove(accountID: value.accountID, clientID: value.clientID)
        }
    }
}
