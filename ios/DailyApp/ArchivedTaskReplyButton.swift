import SwiftUI

struct ArchivedTaskReplyButton: View {
    @EnvironmentObject private var model: WorkspaceModel
    let key: String
    @State private var replyPresentation: AnalysisReplyPresentation?
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Yanıtın tamamını oku", systemImage: "doc.text") {
                loading = true; error = ""
                Task { @MainActor in
                    defer { loading = false }
                    do { replyPresentation = AnalysisReplyPresentation(reply: try await model.fetchTaskReport(key: key)) }
                    catch { self.error = "Rapor alınamadı. Bağlantını kontrol edip yeniden dene." }
                }
            }.buttonStyle(DailySecondaryButtonStyle()).disabled(loading)
                .popover(item: $replyPresentation) { content in
                    AnalysisReplyPopover(reply: content.reply) { replyPresentation = nil }
                        .presentationCompactAdaptation(.popover)
                }
            if loading { ProgressView("Rapor alınıyor…") }
            if !error.isEmpty { Text(error).font(.footnote) }
        }
    }
}
