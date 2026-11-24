import Foundation
import CryptoKit
import Security

public enum ChatGPTOAuthError: Error { case invalidCallback, denied, invalidToken, randomFailure }
public struct ChatGPTOAuthAttempt: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let redirect: String
    public let clientID: String?
    public init(port: UInt16, clientID: String? = nil) throws {
        guard port > 0, clientID != "dynamic_agent_client" else { throw ChatGPTOAuthError.invalidCallback }
        self.state = try Self.random(); self.nonce = try Self.random(); self.verifier = try Self.random()
        self.redirect = "http://127.0.0.1:\(port)/auth/callback"; self.clientID = clientID
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw ChatGPTOAuthError.randomFailure }
        return base64url(Data(bytes))
    }
    public func authorize(hostID: String) throws -> URL {
        guard hostID.hasPrefix("urn:uuid:") else { throw ChatGPTOAuthError.invalidCallback }
        var url = URLComponents(string:"https://auth.openai.com/api/accounts/authorize")!
        var params = ["client_id":clientID ?? "dynamic_agent_client","ext_agent_host_id":hostID,
            "response_type":"code","redirect_uri":redirect,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource":"https://api.openai.com/v1","state":state,"nonce":nonce,
            "code_challenge_method":"S256","code_challenge":Self.base64url(Data(SHA256.hash(data:Data(verifier.utf8))))]
        if clientID == nil { params["agent_name_hint"] = "DailyX" }
        url.queryItems = params.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        guard let value = url.url else { throw ChatGPTOAuthError.invalidCallback }; return value
    }
    public func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard let parts = URLComponents(url:url,resolvingAgainstBaseURL:false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.path == "/auth/callback",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == URLComponents(string:redirect)?.port else { throw ChatGPTOAuthError.invalidCallback }
        let query = parts.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count else { throw ChatGPTOAuthError.invalidCallback }
        let values = Dictionary(uniqueKeysWithValues:query.map{($0.name,$0.value ?? "")})
        guard values["state"] == state else { throw ChatGPTOAuthError.invalidCallback }
        if values["error"] != nil { throw ChatGPTOAuthError.denied }
        guard let code = values["code"], !code.isEmpty, code.utf8.count < 8192,
              let issued = values["client_id"] ?? clientID, !issued.isEmpty, issued != "dynamic_agent_client",
              issued.utf8.count < 500, clientID == nil || issued == clientID else { throw ChatGPTOAuthError.invalidCallback }
        return (code,issued)
    }
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
}

/// RS256 only. Signature verification is performed by Apple's Security framework.
/// Token-provided key URLs and algorithms are never followed.
public enum ChatGPTIDToken {
    public struct Profile: Sendable {
        public let subject: String
        public let identityKey: String
        public let email: String?
        public let name: String?
    }
    /// Identity claims are read only after the signature, issuer, audience, nonce and expiry pass.
    public static func profile(_ token: String, jwks: Data, clientID: String, nonce: String, now: Date = Date()) throws -> Profile {
        let subject = try verify(token, jwks: jwks, clientID: clientID, nonce: nonce, now: now)
        let parts = token.split(separator: ".").map(String.init)
        guard let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any] else { throw ChatGPTOAuthError.invalidToken }
        let email = (claims["email_verified"] as? Bool == true) ? (claims["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
        let verifiedEmail = email.flatMap { $0.contains("@") && !$0.contains("\n") && $0.count < 320 ? $0 : nil }
        let userID = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_user_id"] as? String
        let identity: String
        if let userID, !userID.isEmpty, !userID.contains("\n"), userID.count < 500 { identity = "openai-user:" + userID }
        else if let verifiedEmail { identity = "openai-email:" + verifiedEmail }
        else { identity = "openai-sub:" + subject }
        return Profile(subject: subject, identityKey: identity, email: verifiedEmail, name: (claims["name"] as? String).map { String($0.prefix(100)) })
    }
    private static func decode(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.allSatisfy({(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||$0==45||$0==95}) else { throw ChatGPTOAuthError.invalidToken }
        let padded = text.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/") + String(repeating:"=",count:(4-text.count%4)%4)
        guard let value = Data(base64Encoded:padded) else { throw ChatGPTOAuthError.invalidToken }; return value
    }
    public static func verify(_ token: String, jwks: Data, clientID: String, nonce: String, now: Date = Date()) throws -> String {
        guard token.utf8.count < 65536, jwks.count < 1_000_000 else { throw ChatGPTOAuthError.invalidToken }
        let parts = token.split(separator:".",omittingEmptySubsequences:false).map(String.init)
        guard parts.count == 3,
              let header = try JSONSerialization.jsonObject(with:decode(parts[0])) as? [String:Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with:jwks) as? [String:Any],
              let keys = set["keys"] as? [[String:Any]] else { throw ChatGPTOAuthError.invalidToken }
        let matches = keys.filter{$0["kid"] as? String == kid}
        guard matches.count == 1, let key = matches.first, key["kty"] as? String == "RSA",
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              let n = key["n"] as? String, let e = key["e"] as? String else { throw ChatGPTOAuthError.invalidToken }
        let modulus = try decode(n), exponent = try decode(e)
        guard modulus.count >= 256, modulus.count <= 1024, exponent.count <= 8 else { throw ChatGPTOAuthError.invalidToken }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            var length = bytes.count, size: [UInt8] = []
            repeat { size.insert(UInt8(length & 255),at:0); length >>= 8 } while length>0
            return Data([tag] + (bytes.count<128 ? [UInt8(bytes.count)] : [0x80|UInt8(size.count)]+size)) + bytes
        }
        func integer(_ bytes: Data) -> Data { der(0x02,(bytes.first! & 0x80 != 0 ? Data([0]) : Data()) + bytes) }
        let encoded = der(0x30,integer(modulus)+integer(exponent))
        let attributes: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
        guard let rsa = SecKeyCreateWithData(encoded as CFData,attributes as CFDictionary,nil),
              SecKeyVerifySignature(rsa,.rsaSignatureMessagePKCS1v15SHA256,Data((parts[0]+"."+parts[1]).utf8) as CFData,try decode(parts[2]) as CFData,nil),
              let claims = try JSONSerialization.jsonObject(with:decode(parts[1])) as? [String:Any],
              claims["iss"] as? String == "https://auth.openai.com",
              claims["nonce"] as? String == nonce,
              let sub = claims["sub"] as? String, !sub.isEmpty, !sub.contains("\n"),
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970 - 5 else { throw ChatGPTOAuthError.invalidToken }
        let audiences = (claims["aud"] as? String).map{[$0]} ?? (claims["aud"] as? [String] ?? [])
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970+5 else { throw ChatGPTOAuthError.invalidToken }
        return sub
    }
}
