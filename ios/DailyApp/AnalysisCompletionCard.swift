import SwiftUI
import DailyCore

struct AnalysisCompletionCard: View {
    let date: String
    let changes: AnalysisChanges
    @EnvironmentObject private var model: WorkspaceModel
    private var taskStatus: String? { model.journal(date: date)?.payload.object?["daily_task"]?.object?["status"]?.string }
    private var heading: String {
        switch taskStatus {
        case "needs_input": return "Görevin için bilgi gerekiyor"
        case "blocked": return "Görev tamamlanamadı"
        case "in_progress": return "Araştırma ilerliyor"
        case "completed": return "Görevin sonucu hazır"
        default: return "Son analizin hazır"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(heading, systemImage: taskStatus == "blocked" ? "exclamationmark.circle" : taskStatus == "needs_input" ? "bubble.left" : "checkmark.circle.fill")
                .font(.headline).foregroundStyle(DailyTheme.cobalt)
            Text("\(changes.newNotes) yeni not · \(changes.newLinks) yeni bağlantı")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if changes.updatedNotes > 0 {
                Text("\(changes.updatedNotes) not güncellendi.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
            }
            if changes.questions > 0 { NavigationLink {
                JournalQuestionsScreen(date: date, showAnswered: model.journal(date: date)?.pendingQuestions.isEmpty == true)
            } label: {
                Label("\(changes.questions) soruyu gör", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(DailySecondaryButtonStyle())
            }
            if let receipt=model.changeReceipts.first(where:{$0.date == date}) {
                ForEach(Array(receipt.agenda.enumerated()),id:\.offset) { _,item in
                    NavigationLink { PhoneAgendaScreen() } label: { Label(item,systemImage:"calendar") }
                }
            }
            if let journal = model.journal(date: date), let reflection = journal.dayReflection {
                JournalReflectionButton(date: date, reflection: reflection, advice: journal.dayAdvice,
                    previousReflection: journal.previousDayReflection)
            }
            JournalChangesLink(date: date)
            NavigationLink { AtlasScreen() } label: {
                Label("Haritaları aç", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(DailySecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dailyCard(accent: DailyTheme.cobalt, padding: 16)
        .accessibilityIdentifier("analysis-completion-summary")
    }
}
