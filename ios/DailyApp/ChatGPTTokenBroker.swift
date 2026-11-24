import Foundation
import DailyCore

actor ChatGPTTokenBroker {
    let store = ChatGPTCredentialStore()
    private var current: ChatGPTCredentials?
    private var generation = UUID()
    private var refreshing: Task<ChatGPTCredentials, Error>?
    private let session = URLSession(configuration:.ephemeral, delegate: ChatGPTNoRedirects(), delegateQueue:nil)
    func select(_ credentials: ChatGPTCredentials?) async {
        let pending=refreshing, next=UUID()
        refreshing=nil;generation=next;current=nil
        pending?.cancel()
        _ = try? await pending?.value
        guard generation==next else { return }
        let selected: ChatGPTCredentials?
        if let credentials {
            selected=(try? await store.load(accountID:credentials.accountID,clientID:credentials.clientID)) ?? credentials
        } else { selected=nil }
        guard generation==next else { return }
        current=selected
    }
    func accessToken() async throws -> String {
        guard let current, current.scopes.contains("chatgpt.tokens.use.direct"),
              current.scopes.contains("resource.invoke") else { throw ChatGPTInferenceError.signInRequired }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let active = generation
        let task: Task<ChatGPTCredentials, Error>
        if let existing = refreshing { task=existing }
        else {
            let store = store
            task = Task {
                let data = try await self.post(["grant_type":"refresh_token","client_id":current.clientID,
                    "refresh_token":current.refreshToken,"resource":"https://api.openai.com/v1"])
                let updated = try Self.credentials(data,accountID:current.accountID,clientID:current.clientID,previous:current)
                try Task.checkCancellation()
                try await store.save(updated)
                return updated
            }
            refreshing=task
        }
        defer { if generation == active { refreshing=nil } }
        let updated = try await task.value
        guard generation == active else { throw ChatGPTInferenceError.signInRequired }
        self.current=updated
        return updated.accessToken
    }
    func exchange(attempt: ChatGPTOAuthAttempt, callback: URL, expectedAccountID: String? = nil) async throws -> ChatGPTCredentials {
        let code = try attempt.callback(callback)
        let data = try await post(["grant_type":"authorization_code","client_id":code.clientID,"code":code.code,
            "code_verifier":attempt.verifier,"redirect_uri":attempt.redirect,"resource":"https://api.openai.com/v1"])
        guard let token = try JSONValue.parse(String(decoding:data,as:UTF8.self)).object?["id_token"]?.string else { throw ChatGPTOAuthError.invalidToken }
        // Fetch fresh provider keys at each sign-in; unknown kid fails closed.
        let (keys,response) = try await session.data(from:URL(string:"https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let http=response as? HTTPURLResponse
            throw ChatGPTServiceFailure(stage:"TOKEN_SIGNING_KEYS",status:http?.statusCode,
                requestID:http?.value(forHTTPHeaderField:"x-request-id"),fallbackCode:"signing_keys_unavailable")
        }
        let profile = try ChatGPTIDToken.profile(token,jwks:keys,clientID:code.clientID,nonce:attempt.nonce)
        let sub = profile.subject
        guard expectedAccountID == nil || expectedAccountID == sub else { throw ChatGPTOAuthError.invalidToken }
        var credentials = try Self.credentials(data,accountID:sub,clientID:code.clientID,previous:nil)
        credentials.identityKey = profile.identityKey; credentials.email = profile.email
        credentials.displayName = profile.name; credentials.savedAt = Date()
        try Task.checkCancellation()
        try await store.save(credentials)
        return credentials
    }
    func disconnect(_ credentials: ChatGPTCredentials) async -> Bool {
        let pending=refreshing
        await select(nil)
        _ = try? await pending?.value
        var revoked=false
        do {
            let (data,response)=try await session.data(from:URL(string:"https://auth.openai.com/.well-known/openid-configuration")!)
            guard (response as? HTTPURLResponse)?.statusCode==200,data.count<1_000_000,
                  let value=try JSONValue.parse(String(decoding:data,as:UTF8.self)).object,
                  value["issuer"]?.string=="https://auth.openai.com",
                  let endpoint=value["revocation_endpoint"]?.string,let url=URL(string:endpoint),
                  url.scheme=="https",url.host=="auth.openai.com",url.user==nil,url.password==nil else { throw ChatGPTOAuthError.invalidToken }
            // A refresh may have completed before cancellation. Revoke the saved replacement.
            let latest=try await store.load(accountID:credentials.accountID,clientID:credentials.clientID) ?? credentials
            var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=30
            request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
            let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
            request.httpBody=Data(["token":latest.refreshToken,"client_id":latest.clientID,"token_type_hint":"refresh_token"]
                .map{key,value in key+"="+value.addingPercentEncoding(withAllowedCharacters:allowed)!}.joined(separator:"&").utf8)
            let (_,result)=try await session.data(for:request)
            revoked=(result as? HTTPURLResponse)?.statusCode==200
        } catch {}
        do { try await store.removeAccount(credentials) }
        catch { return false }
        return revoked
    }
    private func post(_ values: [String:String]) async throws -> Data {
        var request = URLRequest(url:URL(string:"https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod="POST"; request.timeoutInterval=45
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        request.httpBody=Data(values.sorted{$0.key<$1.key}.map { key,value in
            key.addingPercentEncoding(withAllowedCharacters:allowed)!+"="+value.addingPercentEncoding(withAllowedCharacters:allowed)!
        }.joined(separator:"&").utf8)
        let (data,response)=try await session.data(for:request)
        guard data.count<=1_000_000,let http=response as? HTTPURLResponse else { throw ChatGPTInferenceError.unexpectedResponse }
        guard http.statusCode==200 else {
            throw ChatGPTServiceFailure(stage: values["grant_type"] == "refresh_token" ? "TOKEN_REFRESH" : "TOKEN_EXCHANGE",
                status: http.statusCode, body: data,
                requestID: http.value(forHTTPHeaderField: "x-request-id"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"), contentType: http.value(forHTTPHeaderField: "Content-Type"))
        }
        return data
    }
    private static func credentials(_ data: Data, accountID: String, clientID: String, previous: ChatGPTCredentials?) throws -> ChatGPTCredentials {
        guard let value=try JSONValue.parse(String(decoding:data,as:UTF8.self)).object,
              let access=value["access_token"]?.string,!access.isEmpty,
              value["token_type"]?.string?.lowercased()=="bearer",
              let seconds=value["expires_in"]?.number,seconds>0,seconds<=86400,
              let refresh=value["refresh_token"]?.string ?? previous?.refreshToken,!refresh.isEmpty else { throw ChatGPTOAuthError.invalidToken }
        let scopes=value["scope"]?.string?.split(separator:" ").map(String.init) ?? previous?.scopes ?? []
        guard scopes.contains("chatgpt.tokens.use.direct"),scopes.contains("resource.invoke") else { throw ChatGPTInferenceError.permissionRequired }
        return ChatGPTCredentials(accountID:accountID,clientID:clientID,accessToken:access,refreshToken:refresh,
            expiresAt:Date().addingTimeInterval(seconds),scopes:scopes, identityKey:previous?.identityKey,
            email:previous?.email, displayName:previous?.displayName, savedAt:Date())
    }
}

final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
