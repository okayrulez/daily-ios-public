import SwiftUI
import DailyCore

struct JournalAnalysisControl: View {
    var date: String? = nil
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @State private var replyPresentation: AnalysisReplyPresentation?
    private var reply: String {
        let target = date ?? model.phoneAnalysisDate
        if waitsForQuestions { return "" }
        if target == model.phoneAnalysisDate, let live = model.phoneAnalysisReply,
           !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return live }
        return target.flatMap { model.journal(date: $0)?.latestReply } ?? ""
    }
    private var waitsForQuestions: Bool {
        guard let target = date ?? model.phoneAnalysisDate else { return false }
        return model.journal(date: target)?.awaitsDayReflectionQuestions == true
    }
    private var hasReply: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spacer()
                Button { replyPresentation = AnalysisReplyPresentation(reply: reply) } label: {
                    HStack(spacing: 10) {
                    Text(hasReply ? "Yanıtı oku" : model.phoneAnalysisBusy ? "Yanıt bekleniyor" :
                        waitsForQuestions ? "Günün yorumu sorulardan sonra hazır." : "Henüz yanıt yok")
                        .font(.caption).foregroundStyle(DailyTheme.muted)
                    Image(systemName: "doc.text")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(hasReply ? DailyTheme.cobalt : DailyTheme.muted)
                        .frame(width: 44, height: 44)
                        .background(DailyTheme.cobalt.opacity(0.08), in: Circle())
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasReply)
                .accessibilityLabel("ChatGPT’nin son yanıtını oku")
                .accessibilityIdentifier("analysis-read-reply")
                .popover(item: $replyPresentation, arrowEdge: .top) { content in
                    AnalysisReplyPopover(reply: content.reply) { replyPresentation = nil }
                        .presentationCompactAdaptation(.popover)
                }
            }
            if model.phoneAnalysisBusy {
                ProgressView("Analiz sürüyor…").tint(DailyTheme.cobalt)
                Text("Analiz sırasında ekranın otomatik kapanmaz. Uygulamayı açık tutabilirsin.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
                Button("Analizi durdur") { model.cancelPhoneAnalysis() }
            }
            if !model.phoneAnalysisNotice.isEmpty {
                Text(model.phoneAnalysisNotice).font(.callout).foregroundStyle(DailyTheme.ink)
                    .accessibilityIdentifier("journal-analysis-status")
                if model.phoneAnalysisDisplayNeedsRetry && !model.phoneAnalysisBusy {
                    Button("Kaydedilen sonucu yeniden aç") { model.startPhoneAnalysis(date: date, retryOnly: true) }
                        .accessibilityIdentifier("analysis-display-retry")
                }
            } else if !hasReply && model.phoneAnalysisChanges == nil {
                Text("Bugün ekranındaki Daily butonu yeni yazını ve yanıtlarını kaydedip analizi başlatır.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
            }
            if connection.lastFailure?.isRateLimited == true {
                Link("ChatGPT kullanımını kontrol et", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    .font(.footnote)
            }
            if !model.phoneAnalysisBusy, let target = date ?? model.phoneAnalysisDate,
               target == model.phoneAnalysisDate, let changes = model.phoneAnalysisChanges {
                AnalysisCompletionCard(date: target, changes: changes)
            }
            if !model.phoneAnalysisBusy && model.phoneAnalysisChanges == nil && !model.phoneAnalysisNotice.isEmpty && !connection.diagnosticHistory.isEmpty {
                Button("Hata raporunu kopyala") { connection.copyDiagnosticReport() }.font(.footnote)
                if !connection.diagnosticCopyNotice.isEmpty {
                    Text(connection.diagnosticCopyNotice).font(.footnote)
                }
            }
        }
    }
}

struct AnalysisReplyPresentation: Identifiable {
    let id = UUID()
    let reply: String
}

struct AnalysisReplyPopover: View {
    let reply: String
    let close: () -> Void

    var body: some View {
        let content = AnalysisReplyText(raw: reply)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ChatGPT’nin yanıtı", systemImage: "doc.text").font(.headline)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Yanıtı kapat")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(content.text)
                        .font(.body).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("analysis-reply-text")
                    ResearchFindingsView(raw: reply)
                    ForEach(content.sources, id: \.url) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Label(source.title, systemImage: "link").font(.footnote)
                            }
                        }
                    }
                    if let fullText = content.fullText {
                        DisclosureGroup("Yanıtın tamamı") {
                            Text(fullText).font(.footnote).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }
                }
            }
            // A maximum alone lets a popover measure the scroll content at zero height.
            .frame(height: 220)
            .defaultScrollAnchor(.top)
            Button("Okudum", action: close)
                .buttonStyle(DailySecondaryButtonStyle())
        }
        .padding(16)
        .frame(width: 310)
        .foregroundStyle(DailyTheme.ink)
        .background(DailyTheme.paper)
    }
}
