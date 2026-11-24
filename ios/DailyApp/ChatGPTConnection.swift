import Foundation
import SwiftUI
import UIKit
import DailyCore

@MainActor final class ChatGPTConnection: ObservableObject {
    static let shared = ChatGPTConnection()
    let broker = ChatGPTTokenBroker()
    lazy var client = ChatGPTInferenceClient(token: { [broker] in try await broker.accessToken() }, usageScope: { [weak self] in
        guard let self else { return "unscoped" }
        return await self.usageScope
    }, diagnostics: { [weak self] event in await self?.recordInference(event) })
    @Published private(set) var accountID: String?
    @Published private(set) var accounts: [ChatGPTCredentials] = []
    @Published private(set) var accountReadState = AccountReadState.unread
    @Published private(set) var requiresSignIn = false
    enum AccountReadState: Equatable { case unread, loaded, unavailable }
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var model = ""
    @Published private(set) var reasoningEffort = ""
    var selectedReasoning: String? { models.first { $0.id == model }?.reasoning(reasoningEffort) }
    var reasoningLevels: [String] { models.first { $0.id == model }?.reasoningLevels ?? [] }
    private var preferenceKey: String? { active.map { ChatGPTModel.preferenceKey(scope:selectionScope,accountID:$0.accountID,clientID:$0.clientID) } }
    private var effortKey: String? { preferenceKey.map { $0 + "-effort-" + model } }
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var notice = "iPhone bağlantısı henüz doğrulanmadı."
    @Published private(set) var diagnostic = ""
    @Published private(set) var lastFailure: ChatGPTServiceFailure?
    @Published private(set) var diagnosticHistory = ""
    @Published private(set) var diagnosticStorageNotice = ""
    @Published private(set) var diagnosticCopyNotice = ""
    private var diagnosticLog: ConnectionDiagnosticLog?
    private var diagnosticStage = "CONNECTION"
    var usageScope: String { selectionScope }
    private var selectionScope = ""
    private var selectionKey: String { "dailyx-selected-chatgpt-" + selectionScope }
    private var active: ChatGPTCredentials?
    private var generation = UUID()
    private var login: Task<Void,Never>?
    private var loopback: ChatGPTLoopback?
    var registrationID: String? { active.map { $0.accountID+"\n"+$0.clientID } }
    private var savedAccount: ChatGPTCredentials? {
        guard let saved = UserDefaults.standard.string(forKey: selectionKey) else { return nil }
        return accounts.first { $0.accountID + "\n" + $0.clientID == saved }
    }
    var hasSelectedAccount: Bool { active != nil || savedAccount != nil }
    var selectedModelName: String? {
        if let selected = models.first(where: { $0.id == model }) { return selected.name }
        guard let savedAccount else { return nil }
        let key = ChatGPTModel.preferenceKey(scope: selectionScope, accountID: savedAccount.accountID, clientID: savedAccount.clientID)
        return UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }
    var canRetry: Bool { active != nil }
    func accountName(_ account: ChatGPTCredentials) -> String {
        let key = "daily-chatgpt-name-" + WorkspaceHash.sha256(account.identity)
        if let name = UserDefaults.standard.string(forKey: key), !name.isEmpty { return name }
        if let email = account.email, !email.isEmpty { return email }
        if let name = account.displayName, !name.isEmpty { return name }
        return "ChatGPT hesabı \((accounts.firstIndex(where: { $0.identity == account.identity }) ?? 0) + 1)"
    }
    func rename(_ account: ChatGPTCredentials, name: String) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        objectWillChange.send()
        UserDefaults.standard.set(value, forKey: "daily-chatgpt-name-" + WorkspaceHash.sha256(account.identity))
    }
    func retry() async { if let active { await use(active) } }
    func reconnect() { signIn(existing: active ?? savedAccount) }

    func reloadAccounts() async {
        let session = generation
        do {
            let stored = try await broker.store.accounts()
            guard generation == session, !Task.isCancelled else { return }
            accounts = stored
            if active == nil, savedAccount == nil, let saved = UserDefaults.standard.string(forKey: selectionKey) {
                let parts = saved.components(separatedBy: "\n")
                if parts.count == 2, let old = try await broker.store.load(accountID: parts[0], clientID: parts[1]),
                   let replacement = stored.first(where: { $0.identity == old.identity }), generation == session {
                    UserDefaults.standard.set(replacement.accountID + "\n" + replacement.clientID, forKey: selectionKey)
                }
            }
            accountReadState = .loaded
            if active == nil, savedAccount != nil, notice == "iPhone bağlantısı henüz doğrulanmadı." {
                notice = "Hesabın bu cihazda kayıtlı. Model erişimi analiz başlatıldığında kontrol edilir."
            }
        } catch {
            guard generation == session, !Task.isCancelled else { return }
            accountReadState = .unavailable
            notice = "Kayıtlı ChatGPT hesapları okunamadı."
        }
    }
    func signIn(existing: ChatGPTCredentials? = nil) {
        guard !busy else { return }
        logStep("SIGN_IN")
        // Reuse the app registration even when adding a different account. Only an explicit
        // reconnect pins the expected user; "add account" may authenticate another real user.
        let registration = existing ?? active ?? savedAccount ?? accounts.first
        busy=true;ready=false;notice="ChatGPT giriş penceresi açılıyor…"
        let session=generation
        login=Task {
            defer { if generation==session { busy=false;loopback=nil;login=nil } }
            do {
                let browser=ChatGPTLoopback();loopback=browser
                let host=try await broker.store.hostID()
                let (attempt,callback)=try await browser.run(hostID:host,clientID:registration?.clientID)
                guard generation==session else { return }
                logStep("TOKEN_EXCHANGE")
                let credentials=try await broker.exchange(attempt:attempt,callback:callback,expectedAccountID:existing?.accountID)
                guard generation==session else { return }
                if let previous = accounts.first(where: { $0.accountID == credentials.accountID || $0.identity == credentials.identity }),
                   let name = UserDefaults.standard.string(forKey: "daily-chatgpt-name-" + WorkspaceHash.sha256(previous.identity)) {
                    UserDefaults.standard.set(name, forKey: "daily-chatgpt-name-" + WorkspaceHash.sha256(credentials.identity))
                }
                try await verify(credentials,session:session)
            } catch {
                if generation==session { ready=false;recordFailure(error) }
            }
            if generation==session { await reloadAccounts() }
        }
    }
    func use(_ credentials: ChatGPTCredentials) async {
        guard !busy else { return }
        if credentials.accountID == active?.accountID, credentials.clientID == active?.clientID,
           let failure=lastFailure, let retryAt=failure.retryAt, retryAt>Date() {
            notice=failure.summary;return
        }
        busy=true;ready=false
        logStep("SAVED_SESSION")
        let session=generation
        defer { if generation==session { busy=false } }
        do {
            guard let fresh=try await broker.store.load(accountID:credentials.accountID,clientID:credentials.clientID) else {
                throw ChatGPTInferenceError.signInRequired
            }
            try await verify(fresh,session:session)
        }
        catch { if generation==session { recordFailure(error) } }
    }
    private func verify(_ credentials: ChatGPTCredentials, session: UUID) async throws {
        await broker.select(credentials)
        guard generation==session else { return }
        active=credentials;accountID=credentials.accountID
        UserDefaults.standard.set(credentials.accountID+"\n"+credentials.clientID, forKey: selectionKey)
        diagnostic="";lastFailure=nil;requiresSignIn=false
        models=[];model="";reasoningEffort=""
        notice="Plan erişimi ve model yanıtı doğrulanıyor…"
        logStep("MODEL_LIST")
        let available=try await client.models()
        guard generation==session else { return }
        guard !available.isEmpty else { throw ChatGPTServiceFailure(stage:"MODEL_LIST",fallbackCode:"no_available_models") }
        let preferred=preferenceKey.flatMap { UserDefaults.standard.string(forKey:$0) }
        guard let selected=ChatGPTModel.selected(in:available,preferred:preferred) else { throw ChatGPTInferenceError.permissionRequired }
        models=available;model=selected.id
        let savedEffort=effortKey.flatMap { UserDefaults.standard.string(forKey:$0) }
        reasoningEffort=selected.reasoning(savedEffort) ?? ""
        logStep("CONNECTION_PROBE")
        let prompt=try JSONValue.object(["instructions":.string("Reply briefly with OK."),
            "input":.array([.object(["role":.string("user"),"content":.string("Connection test. No personal data.")])])]).canonical()
        // The transport requires response.completed with nonempty assistant output.
        // Formatting a probe as Markdown or prose is not an authentication failure.
        _ = try await client.infer(model:selected.id,preparedJSON:ChatGPTModel.applyingReasoning(selectedReasoning,to:prompt))
        guard generation==session else { return }
        rememberModel()
        ready=true;notice="ChatGPT bağlantısı ve deneme analizi doğrulandı."
        logStep("CONNECTION_PROBE", outcome: "completed")
    }
    func reset(scope: String? = nil) {
        if let scope {
            selectionScope=scope
            diagnosticLog=nil;diagnosticHistory="";diagnosticStorageNotice="";diagnosticCopyNotice=""
            loadDiagnosticLog()
        }
        diagnosticStage="CONNECTION"
        generation=UUID();login?.cancel();login=nil;loopback=nil
        diagnostic="";lastFailure=nil;requiresSignIn=false;accountReadState = .unread
        notice = "iPhone bağlantısı henüz doğrulanmadı."
        ready=false;busy=false;active=nil;accountID=nil;models=[];model="";reasoningEffort=""
        Task { await broker.select(nil) }
    }
    func disconnect() async {
        let old=active;reset()
        busy=true
        defer { busy=false }
        if let old {
            let revoked=await broker.disconnect(old)
            notice=revoked ? "ChatGPT bağlantısı kaldırıldı." : "Bu cihazdaki bağlantı kaldırıldı. Uzak yetki iptali doğrulanamadı; ChatGPT bağlantı ayarlarından kaldırabilirsin."
        }
        await reloadAccounts()
    }
    func prepareForAnalysis() async -> Bool {
        guard !busy else { notice="ChatGPT bağlantısı kontrol ediliyor…";return false }
        if let failure=lastFailure, let retryAt=failure.retryAt, retryAt>Date() { notice=failure.summary;return false }
        if ready { lastFailure=nil;diagnostic="";return true }
        if let active { await use(active);return ready }
        let session = generation
        await reloadAccounts()
        guard generation == session, !Task.isCancelled else { return false }
        if accountReadState == .loaded, let credentials = savedAccount {
            await use(credentials)
        } else { notice="Analiz için Ayarlar > ChatGPT bağlantısı bölümünden hesabını bağla veya seç." }
        return ready
    }
    func recordFailure(_ error: Error) {
        lastFailure=error as? ChatGPTServiceFailure
        if (error as? ChatGPTInferenceError) == .signInRequired ||
            lastFailure?.status == 401 ||
            ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused"].contains(lastFailure?.code ?? "") {
            requiresSignIn = true
            ready = false
        }
        diagnostic=lastFailure?.diagnostic ?? (error as? ResponsesStreamError)?.diagnostic ?? (error as? AnalysisValidationFailure)?.diagnostic ?? ""
        notice=Self.message(error)
        let loggedError: Error
        if let inference = error as? ChatGPTInferenceError {
            loggedError=ChatGPTServiceFailure(stage:diagnosticStage,fallbackCode:inference.rawValue)
        } else { loggedError=error }
        appendDiagnostic(outcome:"failed",error:loggedError)
    }
    func logStep(_ stage: String, outcome: String = "started") {
        diagnosticStage=stage
        appendDiagnostic(outcome:outcome)
    }
    func recordAnalysisTimings(_ timings: AnalysisPhaseTimings) {
        for (phase, milliseconds) in timings.finish() {
            appendDiagnostic(outcome: "measured", stage: "ANALYSIS_PHASE_" + phase.rawValue.uppercased(),
                elapsedMilliseconds: milliseconds)
        }
    }
    private func recordInference(_ event: InferenceRequestDiagnostic) {
        guard event.scope == usageScope else { return }
        appendDiagnostic(outcome:event.error == nil ? "completed" : "failed",error:event.error,
            stage:"REQUEST_" + event.stage,requestModel:event.model,promptBytes:event.promptBytes,elapsedMilliseconds:event.elapsedMilliseconds)
    }
    private func loadDiagnosticLog() {
        do {
            let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,
                appropriateFor:nil,create:true).appendingPathComponent("ConnectionDiagnostics",isDirectory:true)
            diagnosticLog=try ConnectionDiagnosticLog(directory:directory,scope:selectionScope)
            updateDiagnosticHistory()
            diagnosticStorageNotice=""
        } catch { diagnosticStorageNotice="Cihazdaki hata günlüğü açılamadı." }
    }
    private func updateDiagnosticHistory() {
        diagnosticHistory=diagnosticLog?.entries.isEmpty == false ? diagnosticLog?.report ?? "" : ""
    }
    private func appendDiagnostic(outcome: String, error: Error? = nil, stage: String? = nil, requestModel: String? = nil,
                                  promptBytes: Int? = nil, elapsedMilliseconds: Int? = nil) {
        if diagnosticLog == nil { loadDiagnosticLog() }
        guard diagnosticLog != nil else { return }
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState="active"
        case .inactive: appState="inactive"
        case .background: appState="background"
        @unknown default: appState="unknown"
        }
        do {
            try diagnosticLog?.append(ConnectionDiagnosticEntry(stage:stage ?? diagnosticStage,outcome:outcome,
                model:requestModel ?? model,build:version+"."+build,appState:appState,osVersion:UIDevice.current.systemVersion,error:error,
                promptBytes:promptBytes,elapsedMilliseconds:elapsedMilliseconds))
            diagnosticStorageNotice=""
        } catch { diagnosticStorageNotice="Hata raporu bu oturumda hazır, ancak cihaza kaydedilemedi." }
        updateDiagnosticHistory()
        diagnosticCopyNotice=""
    }
    func copyDiagnosticReport() {
        guard !diagnosticHistory.isEmpty else { return }
        UIPasteboard.general.setItems([["public.utf8-plain-text":diagnosticHistory]],
            options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(600)])
        diagnosticCopyNotice="Hata raporu kopyalandı. Sohbete yapıştırabilirsin."
    }
    func clearDiagnosticReport() {
        do {
            try diagnosticLog?.clear()
            updateDiagnosticHistory()
            diagnosticStorageNotice="";diagnosticCopyNotice=""
        } catch { diagnosticStorageNotice="Hata günlüğü silinemedi." }
    }
    func selectModel(_ value: String) {
        guard !busy, models.contains(where: { $0.id == value }), value != model else { return }
        model=value
        reasoningEffort=models.first { $0.id == value }?.reasoning(effortKey.flatMap { UserDefaults.standard.string(forKey:$0) }) ?? ""
        ready=false;lastFailure=nil;diagnostic=""
        notice="Model seçildi. Analiz başlatıldığında erişimi kontrol edilecek."
        rememberModel()
    }
    func selectReasoning(_ value: String) {
        guard !busy, value.isEmpty || reasoningLevels.contains(value) else { return }
        reasoningEffort=value;ready=false;lastFailure=nil;diagnostic=""
        notice="Düşünme seviyesi seçildi. Sonraki analizde kullanılacak."
        rememberModel()
    }
    func rememberModel() {
        if let key=preferenceKey { UserDefaults.standard.set(model,forKey:key) }
        if let key=effortKey { UserDefaults.standard.set(reasoningEffort,forKey:key) }
    }
    static func message(_ error: Error) -> String {
        if let failure = error as? AnalysisScopeGuardFailure {
            switch failure.reason {
            case .sessionChanged, .workspaceChanged: return "İşlem sırasında açık veri alanı değişti. Sonuç farklı bir alana yazılmadı; kullandığın alanda yeniden deneyebilirsin."
            case .aiAccountChanged, .aiUnavailable: return "İşlem sırasında seçili AI bağlantısı değişti veya hazır değil. ChatGPT bağlantını kontrol edip yeniden deneyebilirsin."
            }
        }
        if let failure = error as? WorkspaceRequestError {
            switch failure {
            case .malformed: return "Kayıt isteğinin biçimi doğrulanamadı. Önceki kayıtların korunuyor; hata raporunda workspace_request_malformed kodu var."
            case .sourceChanged: return "İşlem sırasında kaynak kayıt değişti. Eski sonuç yeni yazının üzerine kaydedilmedi."
            case .accountChanged: return "İşlem sırasında çalışma alanı bağlantısı değişti. Sonuç farklı bir hesaba kaydedilmedi; aynı alanda yeniden deneyebilirsin."
            }
        }
        if let failure = error as? AnalysisValidationFailure {
            if ["unsupported_action_quote", "unsupported_reminder_quote"].contains(failure.code) {
                return "Ajanda işleminin dayandığı ifadeler doğrulanamadı. Bu denemede ajanda değişmedi. Hatırlatmak istediğin şeyleri ve saatlerini ayrı ayrı yazabilirsin."
            }
            if failure.code == "research_sources_missing" {
                return "ChatGPT yanıt verdi ama tamamlanmış web araması ve kaynaklar doğrulanamadı. Araştırma tamamlandı sayılmadı; haritana doğrulanmamış bilgi eklenmedi."
            }
            return "Analiz verisi doğrulanamadı (\(failure.command) · \(failure.code)). Bu denemenin sonucu kaydedilmedi; önceki kayıtların korunuyor. Hata raporunda ayrıntılar var."
        }
        if error is AnalysisCoreError {
            return "Analiz verisi işlenemedi. Önceki kayıtların korunuyor; hata raporunu paylaşabilirsin."
        }
        if let error = error as? ChatGPTServiceFailure { return error.summary }
        if error is ResponsesStreamError {
            return "ChatGPT yanıtı tamamlanamadı. Analiz kaydedilmedi; tekrar deneyebilirsin."
        }
        if error is CancellationError { return "İşlem durduruldu; kayıtların korunuyor." }
        if let error=error as? ChatGPTInferenceError {
            switch error {
            case .signInRequired:return "ChatGPT oturumu yenilenmeli. Yeniden giriş yap."
            case .permissionRequired:return "Bu bağlantıya ChatGPT plan kullanım izni verilmedi."
            case .usageLimit:return "ChatGPT kullanım sınırına ulaşıldı. Daha sonra yeniden dene."
            case .serviceUnavailable:return "ChatGPT şu anda yanıt vermiyor. Daha sonra yeniden dene."
            default:return "Yanıt doğrulanamadı. Mevcut kayıtların korundu."
            }
        }
        if error is ChatGPTOAuthError { return "iPhone girişi tamamlanamadı veya doğrulanamadı. Günlük analizi etkinleştirilmedi." }
        if (error as? WorkspaceError) == .conflict { return "Günlük veya hafıza değişti. Eski sonuç yeni kaydın üzerine yazılmadı." }
        return "İşlem tamamlanamadı. Kaydedilmiş sonucun varsa yeniden analiz yapmadan kaydı tekrar deneyebilirsin."
    }
}
