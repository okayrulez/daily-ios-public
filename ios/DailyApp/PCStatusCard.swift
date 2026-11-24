import SwiftUI

// Kept under the existing name to preserve the copied screens' call sites.
struct PCStatusCard: View {
    @ObservedObject private var connection = ChatGPTConnection.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DailyX analiz bağlantısı", systemImage: "iphone").font(.headline)
            Text(connection.ready ? "ChatGPT bağlı. Analizi günlük ekranından başlatabilirsin." : "ChatGPT hesabını bağlayıp telefonla analizi etkinleştirebilirsin.")
                .font(.footnote).foregroundStyle(DailyTheme.muted)
            NavigationLink { PhoneAnalysisSettingsScreen() } label: {
                Label("Telefonla analiz", systemImage: "sparkles")
            }.buttonStyle(DailySecondaryButtonStyle())
        }.dailyCard(accent: DailyTheme.cobalt)
    }
}
