import Foundation
import AuthenticationServices
@preconcurrency import Network
import DailyCore
import UIKit

/// Physical-device experiment using the documented HTTP loopback callback.
/// No custom-scheme substitution, embedded login form, or copied browser credentials.
@MainActor final class ChatGPTLoopback: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var listener: NWListener?
    private var browser: ASWebAuthenticationSession?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var attempt: ChatGPTOAuthAttempt?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []

    func run(hostID: String, clientID: String? = nil) async throws -> (ChatGPTOAuthAttempt,URL) {
        defer { cleanup() }
        return try await withTaskCancellationHandler {
            let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                ready=continuation
                do {
                    let params=NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                    let server=try NWListener(using:params)
                    listener=server
                    server.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port=self.listener?.port?.rawValue { self.ready?.resume(returning:port); self.ready=nil }
                        case .failed: self.fail(ChatGPTOAuthError.invalidCallback)
                        default: break
                        }
                    }}
                    server.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                    server.start(queue:.main)
                    timeout=Task { [weak self] in
                        do { try await Task.sleep(for:.seconds(180)); self?.fail(ChatGPTOAuthError.invalidCallback) } catch {}
                    }
                } catch { fail(error) }
            }
            try Task.checkCancellation()
            let pending=try ChatGPTOAuthAttempt(port:port,clientID:clientID); attempt=pending
            let url=try pending.authorize(hostID:hostID)
            let returned=try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                callback=continuation
                let session=ASWebAuthenticationSession(url:url,callbackURLScheme:nil) { [weak self] _,_ in
                    Task { @MainActor in self?.fail(CancellationError()) }
                }
                browser=session; session.presentationContextProvider=self
                session.prefersEphemeralWebBrowserSession=true
                if !session.start() { fail(ChatGPTOAuthError.invalidCallback) }
            }
            return (pending,returned)
        } onCancel: { Task { @MainActor [weak self] in self?.fail(CancellationError()) } }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first{$0.isKeyWindow} ?? ASPresentationAnchor()
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count<8 else { connection.cancel(); return }
        connections.append(connection); connection.start(queue:.main); receive(connection,data:Data())
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] bytes,_,complete,error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var all=data; if let bytes { all.append(bytes) }
                guard all.count<=16384,error==nil else { connection.cancel(); return }
                guard let text=String(data:all,encoding:.utf8),text.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection,data:all) } else { connection.cancel() }; return
                }
                let first=text.components(separatedBy:"\r\n")[0].split(separator:" ")
                guard let pending=self.attempt,first.count==3,first[0]=="GET",
                      first[1].hasPrefix("/auth/callback?"),
                      let base=URLComponents(string:pending.redirect),
                      let url=URL(string:"http://127.0.0.1:\(base.port!)"+String(first[1])) else { connection.cancel(); return }
                do {
                    _ = try pending.callback(url)
                    let reply="HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nDailyX girisi alindi. Uygulamaya donebilirsiniz."
                    connection.send(content:Data(reply.utf8),completion:.contentProcessed{_ in connection.cancel()})
                    let result=self.callback; self.callback=nil; result?.resume(returning:url)
                } catch ChatGPTOAuthError.denied { self.fail(ChatGPTOAuthError.denied); connection.cancel() }
                catch { connection.cancel() }
            }
        }
    }
    private func fail(_ error: Error) {
        ready?.resume(throwing:error);ready=nil;callback?.resume(throwing:error);callback=nil
        cleanup()
    }
    private func cleanup() {
        timeout?.cancel();timeout=nil;listener?.cancel();listener=nil
        connections.forEach{$0.cancel()};connections=[]
        let old=browser;browser=nil;old?.cancel();attempt=nil
    }
}
