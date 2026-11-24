import SwiftUI
import UniformTypeIdentifiers
import DailyCore

struct PhoneAnalysisSettingsScreen: View {
    var connectionOnly = false
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @State private var importing = false
    @State private var memorySummary: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var exporting = false
    @State private var exportDocument: MemoryExportDocument?
    @State private var disconnecting = false
    @State private var namingAccount = false
    @State private var namedAccount: ChatGPTCredentials?
    @State private var accountName = ""
    private var connectionLocked: Bool { connection.busy || model.phoneAnalysisBusy || model.mapLinkBusy }

    private var scope: MemoryScope? {
        guard let uid = model.uid else { return nil }
        return try? MemoryScope(projectID: model.firebaseProjectID, uid: uid)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        DailyServiceIcon(kind: .chatGPT, symbol: "link", side: 38)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Kendi AI hesabın").font(.headline)
                            connection.settingsStatus.badge
                        }
                    }
                    Text(LocalizedStringKey(connection.notice))
                        .font(.footnote).foregroundStyle(DailyTheme.muted).textSelection(.enabled)
                    if connection.lastFailure?.isRateLimited == true {
                        Link("ChatGPT kullanımını kontrol et", destination: URL(string:"https://chatgpt.com/settings/usage")!)
                    }
                    if !connection.models.isEmpty {
                        Picker("Model", selection: Binding(get: { connection.model }, set: { connection.selectModel($0) })) {
                            ForEach(connection.models) { item in Text(item.name).tag(item.id) }
                        }.disabled(connection.busy || model.phoneAnalysisBusy || model.mapLinkBusy)
                        Picker("Düşünme seviyesi", selection: Binding(get: { connection.reasoningEffort }, set: { connection.selectReasoning($0) })) {
                            Text("Otomatik (modelin varsayılanı)").tag("")
                            ForEach(connection.reasoningLevels, id: \.self) { effort in
                                Text(ChatGPTModel.reasoningLabel(effort)).tag(effort)
                            }
                        }.disabled(connection.busy || model.phoneAnalysisBusy || model.mapLinkBusy || connection.reasoningLevels.isEmpty)
                        Text(connection.reasoningLevels.isEmpty
                             ? "Bu model düşünme seçeneklerini bildirmiyor; varsayılan ayarı kullanılır."
                             : "Daha yüksek düşünme seviyesi yanıt süresini ve kullanımını artırabilir.")
                            .font(.footnote).foregroundStyle(DailyTheme.muted)
                    }
                    if connection.hasSelectedAccount && !connection.ready && !connection.requiresSignIn {
                        Button("Kayıtlı hesabı doğrula") { Task { _ = await connection.prepareForAnalysis() } }
                            .buttonStyle(DailyPrimaryButtonStyle())
                            .disabled(connection.busy || scope == nil || model.phoneAnalysisBusy || model.mapLinkBusy)
                    } else if connection.canRetry {
                        Button(connection.ready ? "Hesabın modellerini yenile" : "Seçili modelle bağlantıyı dene") {
                            Task { await connection.retry() }
                        }.disabled(connection.busy || model.phoneAnalysisBusy || model.mapLinkBusy)
                    }
                    if !connection.hasSelectedAccount || connection.requiresSignIn {
                        Button("Continue with ChatGPT") { connection.reconnect() }
                            .buttonStyle(DailyPrimaryButtonStyle()).disabled(connection.busy || scope == nil || model.phoneAnalysisBusy || model.mapLinkBusy)
                            .accessibilityIdentifier("chatgpt-connect-account")
                    }
                    if connection.busy { ProgressView("Bağlantı kontrol ediliyor…") }
                }.padding(18).dailyGlass(accent: connection.ready ? DailyTheme.mint : DailyTheme.line)
                Text("Bugün ekranındaki Daily butonu, seçtiğin model ve düşünme seviyesiyle analiz başlatır.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
                VStack(spacing: 0) {
                    NavigationLink { accountManagement } label: {
                        Label("Hesabı değiştir veya yönet", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }.accessibilityIdentifier("chatgpt-manage-accounts")
                    Divider()
                    NavigationLink { diagnostics } label: {
                        Label("Bağlantı yardımı", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }.accessibilityIdentifier("chatgpt-diagnostics")
                }.font(.subheadline).padding(.horizontal, 18).dailyGlass()
                if !connectionOnly {
                    advancedSettings
                }
            }.padding(20)
        }
        .background(DailyTheme.canvas).navigationTitle("ChatGPT bağlantısı")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DailyTheme.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        .task(id: scope?.storageIdentity) {
            await connection.reloadAccounts()
            if !connectionOnly { await reload() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await importMemory(url) } }
        }
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:.json,defaultFilename:"dailyx-memory") { result in
            if case .failure = result { notice="Yedek dosyası kaydedilemedi." }
            exportDocument=nil
        }
    }

    private var accountManagement: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bu cihazda saklanan bağlantılarını buradan değiştirebilirsin.").font(.subheadline).foregroundStyle(DailyTheme.muted)
                ForEach(connection.accounts, id: \.identity) { account in
                    VStack(alignment: .leading, spacing: 12) {
                        let selected = connection.registrationID == account.accountID + "\n" + account.clientID
                        Label(connection.accountName(account), systemImage: selected ? "checkmark.circle.fill" : "person.crop.circle")
                            .font(.subheadline.bold())
                        Button("Bağlantı adını düzenle") { namedAccount = account; accountName = connection.accountName(account); namingAccount = true }
                            .font(.footnote).accessibilityIdentifier("chatgpt-rename-account")
                        if selected {
                            connection.settingsStatus.badge
                        } else {
                            Button("Bu hesaba geç") { Task { await connection.use(account) } }
                        }
                        Button("Yeniden giriş yap") { connection.signIn(existing: account) }
                            .font(.footnote)
                    }.padding(16).dailyGlass().disabled(connectionLocked)
                }
                Button("Başka ChatGPT hesabı ekle") { connection.signIn() }
                    .buttonStyle(DailySecondaryButtonStyle()).disabled(connectionLocked || scope == nil)
                Text("Aynı hesabına yeniden giriş yaptığında mevcut bağlantın yenilenir; ikinci bir hesap satırı oluşturulmaz.")
                    .font(.caption).foregroundStyle(DailyTheme.muted)
                if connection.canRetry {
                    Button("Seçili ChatGPT bağlantısını kaldır", role: .destructive) { disconnecting = true }
                        .font(.footnote).disabled(connectionLocked)
                }
                if connection.busy { ProgressView("Bağlantı kontrol ediliyor…") }
            }.padding(20)
        }.background(DailyTheme.canvas).navigationTitle("Hesap yönetimi").navigationBarTitleDisplayMode(.inline)
            .alert("Bağlantı adı", isPresented: $namingAccount) {
                TextField("Örneğin: Kişisel hesabım", text: $accountName)
                Button("Vazgeç", role: .cancel) {}
                Button("Kaydet") { if let namedAccount { connection.rename(namedAccount, name: accountName) } }
                    .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Seçili bağlantı kaldırılsın mı?", isPresented: $disconnecting, titleVisibility: .visible) {
                Button("Bağlantıyı kaldır", role: .destructive) { Task { await connection.disconnect() } }
            }
    }

    private var diagnostics: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if !connection.diagnostic.isEmpty {
                    Text(connection.diagnostic).font(.caption).textSelection(.enabled).padding(16).dailyGlass()
                }
                Text("Model seçenekleri seçtiğin hesaptan alınır. Kullanılabilirlik ve kullanım sınırlarını OpenAI belirler.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
                VStack(alignment:.leading,spacing:12) {
                    Label("Bağlantı hata günlüğü",systemImage:"doc.text.magnifyingglass").font(.headline)
                    Text("Son 50 olay bu cihazda saklanır. Günlük metnin, model yanıtları ve giriş anahtarların kaydedilmez.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                    if connection.diagnosticHistory.isEmpty {
                        Text("Henüz kayıt yok. Bağlantıyı veya analizi tekrar denediğinde burada görünecek.").font(.footnote)
                    } else {
                        Button("Hata raporunu kopyala") { connection.copyDiagnosticReport() }
                            .buttonStyle(DailySecondaryButtonStyle())
                        DisclosureGroup("Kayıtları göster") {
                            Text(connection.diagnosticHistory).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Hata günlüğünü temizle",role:.destructive) { connection.clearDiagnosticReport() }
                    }
                    if !connection.diagnosticStorageNotice.isEmpty { Text(connection.diagnosticStorageNotice).font(.footnote) }
                    if !connection.diagnosticCopyNotice.isEmpty { Text(connection.diagnosticCopyNotice).font(.footnote) }
                }.dailyCard()
            }.padding(20)
        }.background(DailyTheme.canvas).navigationTitle("Bağlantı yardımı").navigationBarTitleDisplayMode(.inline)
    }

    private var advancedSettings: some View {
        DisclosureGroup("Gelişmiş analiz ve yedekleme") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Analiz yönergeleri", systemImage: "doc.text").font(.headline)
                Text("Son kullanılan sürüm: \(model.phonePromptRevision)").font(.footnote)
                Text("Her yeni analizde Firebase’den alınır. Araştırma erişimi seçilen modelin ve hesabın desteklediği araçlara bağlıdır.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
            }.dailyCard()
            VStack(alignment:.leading,spacing:12) {
                Button("Bekleyen sonucu Firebase’e kaydet") { model.startPhoneAnalysis(date:nil,retryOnly:true) }
                    .buttonStyle(DailySecondaryButtonStyle()).disabled(model.phoneAnalysisBusy)
                DisclosureGroup("Çakışan sonuç") {
                    Button("Bekleyen sonucu arşivle") { Task { await model.archivePendingPhoneAnalysis() } }
                        .disabled(model.phoneAnalysisBusy)
                    Text("Günlük değiştiği için kaydedilemeyen sonucu cihazda korur ve yeni analize yer açar.").font(.footnote)
                }
                if model.phoneAnalysisBusy {
                    ProgressView()
                    Button("İşlemi durdur") { model.cancelPhoneAnalysis() }
                }
                if !model.phoneAnalysisNotice.isEmpty { Text(model.phoneAnalysisNotice).font(.footnote) }
            }.dailyCard()
            VStack(alignment: .leading, spacing: 12) {
                Label("Analiz geçmişinin yedeği", systemImage: "internaldrive").font(.headline)
                Text(memorySummary ?? "İlk analizinden sonra burada yedek alabilirsin. Yeni başlıyorsan dosya aktarman gerekmez.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
                DisclosureGroup("Hafıza aktarımı") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Telefon değiştirirken eski analiz geçmişini bu dosyayla taşıyabilirsin. Yedeği güvenli bir yerde tut; günlüklerinden içerik barındırır.")
                            .font(.footnote)
                        Button("Hafıza dosyasını seç") { importing = true }
                            .buttonStyle(DailySecondaryButtonStyle()).disabled(scope == nil || busy || model.phoneAnalysisBusy)
                        Button("Hafızanın yedeğini al") { Task { await exportMemory() } }
                            .buttonStyle(DailySecondaryButtonStyle()).disabled(scope == nil || busy || model.phoneAnalysisBusy)
                    }.padding(.top, 8)
                }
                if busy { ProgressView("Hafıza doğrulanıyor…") }
                if let notice { Text(notice).font(.footnote).foregroundStyle(DailyTheme.orange) }
            }.dailyCard()
        }.dailyCard()
    }

    private func store() throws -> MemoryStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("DailyXMemory", isDirectory: true)
        return try MemoryStore(root: root)
    }

    @MainActor private func reload() async {
        memorySummary = nil; notice = nil
        guard let active = scope else { return }
        do {
            let memory = try await store().load(scope: active)
            guard scope == active else { return }
            if let memory { memorySummary = "\(memory.sourceCount) kaynak · \(memory.nodeCount) not · sürüm \(memory.revision)" }
            else if model.records.values.contains(where: { $0.key == PhoneAnalysisCommit.manifestKey }) {
                memorySummary="Hesabında önceki analizler var. Devam etmek için eski telefonundan aldığın son analiz yedeğini içe aktar."
            }
        } catch { if scope == active { notice = "Hafıza okunamadı. Mevcut dosya korunuyor." } }
    }

    @MainActor private func importMemory(_ url: URL) async {
        guard let active = scope, !busy, !model.phoneAnalysisBusy, !model.phoneMemoryBusy else { return }
        busy = true; model.phoneMemoryBusy = true
        defer { busy = false; model.phoneMemoryBusy = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 16_000_000 else { throw WorkspaceError.oversizedRecord }
            let data = try Data(contentsOf: url)
            guard data.count <= 16_000_000, let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceError.malformedRecord
            }
            let memory = try await Task.detached(priority: .userInitiated) { try PortableMemory(json: text) }.value
            guard scope == active else { return }
            if let manifest=model.records.values.first(where:{$0.key==PhoneAnalysisCommit.manifestKey}),
               let manifestText=try manifest.payload().string,
               let expected=try JSONValue.parse(manifestText).object?["memoryHash"]?.string,
               expected != memory.contentHash {
                notice="Bu hesabın son analizindeki hafıza yedeğini seç. Farklı bir sürüm mevcut hafızanın üzerine yazılmadı."
                return
            }
            let store = try store()
            let previous = try await store.load(scope: active)
            guard scope == active else { return }
            try await store.save(memory, expectedHash: previous?.contentHash, scope: active)
            guard scope == active else { return }
            await reload()
            notice = "Hafıza bu cihazdaki hesabına kaydedildi."
        } catch {
            if scope == active { notice = "Dosya doğrulanamadı veya daha eski bir sürüm. Mevcut hafıza değiştirilmedi." }
        }
    }
    @MainActor private func exportMemory() async {
        guard let active=scope else { return }
        do {
            guard let memory=try await store().load(scope:active),scope==active else {
                notice="Henüz yedeklenecek hafıza yok.";return
            }
            exportDocument=MemoryExportDocument(json:memory.json);exporting=true
        } catch { notice="Hafıza okunamadı; mevcut dosya korundu." }
    }
}
