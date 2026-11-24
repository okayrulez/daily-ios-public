import SwiftUI

struct WorkspaceResetScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var confirming = false
    @State private var confirmation = ""
    @State private var authorizeCloud = false
    @State private var alarmSummary = ""
    private func refreshAlarmSummary() {
        do {
            let count = try AppleAgendaBridge.shared.activeAlarms(scope: model.companionScope).count
            alarmSummary = String(localized: "Bu iPhone’da iptal edilecek dAIly alarmı: \(count).")
        } catch {
            alarmSummary = String(localized: "Bu iPhone’daki dAIly alarmları okunamadı. Sıfırlama sırasında tekrar kontrol edilecek.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 42)).foregroundStyle(DailyTheme.coral)
                Text("Temiz bir başlangıç.").font(.title.bold())
                Text("Bu çalışma alanındaki günlüklerin, taslakların, analizlerin, zihin haritaların, soruların, sosyal profil bilgilerin ve hatırlatmaların silinir.")
                    .foregroundStyle(DailyTheme.muted)
                Text(LocalizedStringKey(model.cloudConnected
                    ? "Bu cihazdaki ve bağlı Firebase alanındaki kayıtlar silinir. Diğer cihazlarda dAIly'yi kapat; eski yerel kayıtları yeniden yükleme."
                    : model.firebaseProjectID == "daily-local"
                        ? "Bu cihazdaki çalışma alanın sıfırlanır."
                        : "Bu alanın Firebase bağlantısı kapalı. Buluttaki kayıtların geri gelmemesi için önce aynı Firebase alanını yeniden bağla."))
                    .font(.subheadline)
                Text("ChatGPT ve Google girişlerin ile görünüm tercihlerin korunur. Başka çalışma alanları silinmez.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
                Text("Çalışma alanı: \(model.companionScope)").font(.footnote)
                Text(alarmSummary).font(.footnote)
                Text("Apple Takvim’e ve Anımsatıcılar’a aktardığın kayıtlar bu uygulamalarda kalır.").font(.footnote)
                if model.workspaceResetPending && !model.resettingWorkspace {
                    Label("Sıfırlama yarıda kaldı. Tamamlanana kadar kayıt ve eşitleme durduruldu.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.subheadline).foregroundStyle(DailyTheme.coral)
                }
                if !model.resetNotice.isEmpty { Text(LocalizedStringKey(model.resetNotice)).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("workspace-reset-result") }
                if model.resettingWorkspace { ProgressView(LocalizedStringKey(model.resetStage)).accessibilityIdentifier("workspace-reset-progress") }
                if model.resetNeedsGoogleAuthorization {
                    Button("Google ile silme yetkisini doğrula ve tekrar dene") { authorizeCloud = true; confirmation = ""; confirming = true }
                        .buttonStyle(DailySecondaryButtonStyle()).disabled(!model.canResetWorkspace)
                    Text("Sıfırlanacak alan değişmez. Seçtiğin Google hesabının bu Firebase projesini yönetme yetkisi doğrulanır.")
                        .font(.caption).foregroundStyle(DailyTheme.muted)
                }
                Button(role: .destructive) { authorizeCloud = false; confirmation = ""; confirming = true } label: {
                    Label(LocalizedStringKey(model.workspaceResetPending ? "Sıfırlamayı tamamla" : "Bütün verileri sıfırla"), systemImage: "trash")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent).tint(DailyTheme.coral)
                .disabled(!model.canResetWorkspace || (!model.cloudConnected && model.firebaseProjectID != "daily-local"))
                .accessibilityIdentifier("workspace-reset-all")
                if !model.canResetWorkspace && !model.resettingWorkspace {
                    Text("Devam eden işlemin tamamlanmasını bekle.").font(.footnote).foregroundStyle(DailyTheme.muted)
                }
            }.padding(24)
        }
        .background(DailyTheme.canvas).navigationTitle("Sıfırla").navigationBarTitleDisplayMode(.inline)
        .task(id: model.companionScope) { refreshAlarmSummary() }
        .onChange(of: model.resettingWorkspace) { _, busy in if !busy { refreshAlarmSummary() } }
        .interactiveDismissDisabled(model.resettingWorkspace)
        .alert("Bütün verilerin silinsin mi?", isPresented: $confirming) {
            TextField("SIFIRLA yaz", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Vazgeç", role: .cancel) {}
            Button("Kalıcı olarak sil", role: .destructive) { Task { await model.resetWorkspace(authorizeCloud: authorizeCloud) } }
                .disabled(confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "SIFIRLA")
        } message: { Text("Bu işlem geri alınamaz. Onaylamak için SIFIRLA yaz.") }
    }
}
