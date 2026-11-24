import SwiftUI
import DailyCore

struct TaskResultCard: View {
    @EnvironmentObject private var model: WorkspaceModel
    let task: JSONValue
    var showContinuation = true
    var compact = false
    @State private var replyPresentation: AnalysisReplyPresentation?
    @State private var loading = false
    @State private var reportError = ""
    private var priorReports: [(id: String, round: Int)] {
        model.dates.compactMap { model.journal(date: $0) }.flatMap(\.analyses).compactMap { analysis -> (id: String, round: Int)? in
            guard analysis.fields["task_input_hash"] == fields["inputHash"],
                  let key = analysis.fields["task_report_key"]?.string,
                  let round = analysis.fields["task_round"]?.integer,
                  round < (fields["round"]?.integer ?? 1) else { return nil }
            return (id: key, round: round)
        }.sorted { $0.round < $1.round }
    }
    private var fields: [String: JSONValue] { task.object ?? [:] }
    private var title: String {
        switch fields["status"]?.string {
        case "needs_input": return "Görevin için bilgi gerekiyor"
        case "blocked": return "Görev tamamlanamadı"
        case "in_progress": return "Araştırma devam ediyor"
        default: return "Görevin sonucu hazır"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
            Label(title, systemImage: fields["status"]?.string == "needs_input" ? "bubble.left" : "doc.text.magnifyingglass")
                .font(.headline)
            Text(fields["goal"]?.string ?? "").font(.subheadline).foregroundStyle(DailyTheme.muted)
            }
            if showContinuation && fields["status"]?.string == "needs_input" {
                Text("Aşağıdaki soruları cevaplayıp Yanıtla’ya dokun; aynı görev devam eder.")
                    .font(.footnote)
            }
            Button("Yanıtı oku", systemImage: "doc.text") {
                if let reply = try? task.canonical() { replyPresentation = AnalysisReplyPresentation(reply: reply) }
            }
                .buttonStyle(DailySecondaryButtonStyle())
                .popover(item: $replyPresentation) { content in
                    AnalysisReplyPopover(reply: content.reply) { replyPresentation = nil }
                        .presentationCompactAdaptation(.popover)
                }
            if !priorReports.isEmpty {
                DisclosureGroup("Önceki araştırma aşamaları") {
                    ForEach(priorReports, id: \.id) { report in
                        Button("\(report.round). aşamayı oku", systemImage: "doc.text") {
                            loading = true; reportError = ""
                            Task { @MainActor in
                                defer { loading = false }
                                do { replyPresentation = AnalysisReplyPresentation(reply: try await model.fetchTaskReport(key: report.id)) }
                                catch { reportError = "Önceki rapor alınamadı. Bağlantını kontrol edip yeniden dene." }
                            }
                        }.padding(.vertical, 6).disabled(loading)
                    }
                }.font(.subheadline)
            }
            if loading { ProgressView("Rapor alınıyor…") }
            if !reportError.isEmpty { Text(reportError).font(.footnote) }
        }.dailyCard(accent: DailyTheme.cobalt, padding: compact ? 0 : 16)
    }
}
